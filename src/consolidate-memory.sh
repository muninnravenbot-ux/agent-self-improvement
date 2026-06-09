#!/bin/bash
# src/consolidate-memory.sh — Stage 6: memory deduplication with critical-entry guard.
#
# For agents that maintain an observation/memory file (growing over time), this
# consolidates + merges redundant observations while NEVER dropping critical entries.
#
# Critical entries (marked 🔴) are verified before and after consolidation.
# An aggressive consolidation (>80% reduction) is rejected as suspicious.
#
# Env: MEMORY_FILE, CONSOLIDATE_MODEL, VERIFY_MODEL

set -uo pipefail
source "$(dirname "$0")/lib/llm.sh"

MEMORY_FILE="${MEMORY_FILE:-}"
LOG_FILE="${LOG_FILE:-/tmp/agent-si.log}"
CONSOLIDATE_MODEL="${CONSOLIDATE_MODEL:-gpt-4o-mini}"
VERIFY_MODEL="${VERIFY_MODEL:-gpt-4o-mini}"

[ -z "$MEMORY_FILE" ] && { echo "consolidate-memory: MEMORY_FILE not set — skipping"; exit 0; }
[ ! -f "$MEMORY_FILE" ] && { echo "consolidate-memory: $MEMORY_FILE not found — skipping"; exit 0; }

log() { echo "[$(date)] consolidate-memory: $*" >> "$LOG_FILE"; }

word_count=$(wc -w < "$MEMORY_FILE")

# Threshold: consolidate if file is larger than a reasonable working set.
# Adjust to taste (e.g. 3000 words ~ 15KB).
threshold="${CONSOLIDATE_THRESHOLD:-3000}"

if [ "$word_count" -lt "$threshold" ]; then
  log "memory at $word_count words (threshold: $threshold) — skipping consolidation"
  exit 0
fi

log "consolidating memory ($word_count words)"

# Backup original.
backup="$MEMORY_FILE.backup-$(date +%Y%m%d-%H%M%S)"
cp "$MEMORY_FILE" "$backup"

# Cap at 256KB for LLM processing (large enough to consolidate most files).
current=$(head -c 262144 "$MEMORY_FILE")
full_size=$(wc -c < "$MEMORY_FILE")

if [ "$full_size" -gt 262144 ]; then
  log "memory file is $full_size bytes (>256KB) — truncating for consolidation"
fi

# Count critical entries before consolidation.
critical_before=$(echo "$current" | grep -c '🔴' || echo 0)

prompt="You consolidate and deduplicate observations while preserving critical information.

OBSERVATIONS TO CONSOLIDATE:
$current

RULES:
1. Merge related observations about the same topic/person into single entries.
2. NEVER drop any 🔴 (critical) observations — every single one MUST appear in output.
3. Keep recent 🟡 (important) observations; merge older redundant ones only.
4. Keep 🟢 (reference) observations unless they are exact duplicates.
5. Update timestamps to the most recent mention.
6. Only merge observations genuinely about the same topic AND within 7 days.
7. Format: emoji YYYY-MM-DD HH:MM — text [source:tag]
8. Target: 30-50% reduction. Conservative merging is better than losing information.
9. Output ONLY observation lines. No headers, no blank lines, no preamble.

CRITICAL: Count 🔴 entries before and after. If you drop even one, consolidation fails.

Output format must start with an emoji and be clean observation lines."

consolidated=$(llm_call "consolidate-memory" 300 "$CONSOLIDATE_MODEL" "$prompt" 2>/dev/null || echo "FAILED")

if [ "$consolidated" = "FAILED" ]; then
  log "consolidation LLM call failed — keeping original"
  exit 1
fi

# Count critical entries in consolidated version.
critical_after=$(echo "$consolidated" | grep -c '🔴' || echo 0)

if [ "$critical_before" -gt 0 ] && [ "$critical_after" -lt "$critical_before" ]; then
  log "verification: $critical_before critical entries before, $critical_after after — REJECTED"

  # Ask verifier to check.
  verify_prompt="Original critical (🔴) entries:
$(echo "$current" | grep '🔴' || echo "(none)")

Consolidated critical (🔴) entries:
$(echo "$consolidated" | grep '🔴' || echo "(none)")

Are all critical entries from the original preserved in the consolidated version (they may be merged)?
Reply ONLY: PASS or FAIL: [list of missing]"

  verify=$(llm_call "verify-memory" 60 "$VERIFY_MODEL" "$verify_prompt" 2>/dev/null || echo "FAIL: verifier error")

  if echo "$verify" | grep -qi "FAIL"; then
    log "verification REJECTED — critical entries missing. Keeping backup at $backup"
    exit 1
  fi
  log "verification passed (critical entries preserved via merge)"
fi

# Check for over-aggressive consolidation.
original_words=$(echo "$current" | wc -w)
consolidated_words=$(echo "$consolidated" | wc -w)
retention=$((consolidated_words * 100 / original_words))

if [ "$retention" -lt 20 ]; then
  log "consolidation too aggressive ($retention% retention) — REJECTED"
  exit 1
fi

# Strip any line-number prefixes (from tool contamination) and blank lines.
consolidated=$(echo "$consolidated" | sed 's/^[[:space:]]*[0-9]*→//; /^[[:space:]]*$/d; /^#/d; s/^[[:space:]]*//' | sed '1{/^$/d}')

# Write back.
printf '%s' "$consolidated" > "$MEMORY_FILE"
new_words=$(wc -w < "$MEMORY_FILE")
reduction=$(( (original_words - new_words) * 100 / original_words ))

log "consolidation complete: $original_words → $new_words words ($reduction% reduction). Backup: $backup"
echo "Memory consolidated: $original_words → $new_words words ($reduction% reduction)"
exit 0
