#!/bin/bash
# src/review-gate.sh — Stage 2: LLM applicability gate.
#
# For each signal in signals.jsonl, asks the LLM: "Is this idea genuinely applicable
# to our agent's stack?" Appends results to applicable.jsonl (with .applicable field).
#
# Output format: each signal gets a .applicable=true|false and .reason added.
#
# Env: REVIEW_MODEL, AGENT_STACK_DESC (brief description of agent's tech stack)

set -uo pipefail
source "$(dirname "$0")/lib/llm.sh"

STAGING_DIR="${STAGING_DIR:-/tmp/agent-si-staging}"
LOG_FILE="${LOG_FILE:-/tmp/agent-si.log}"
SIGNALS="$STAGING_DIR/signals.jsonl"
APPLICABLE="$STAGING_DIR/applicable.jsonl"
REVIEW_MODEL="${REVIEW_MODEL:-gpt-4o-mini}"
AGENT_STACK_DESC="${AGENT_STACK_DESC:-A Node/TypeScript agent with SQLite memory, cron-driven updates, and API integrations.}"

[ ! -f "$SIGNALS" ] && { echo "review-gate: $SIGNALS not found — run gather-signals.sh first"; exit 1; }

: > "$APPLICABLE"  # clear it

log() { echo "[$(date)] review-gate: $*" >> "$LOG_FILE"; }

log "reviewing signals for applicability (model=$REVIEW_MODEL)"

reviewed=0; applicable=0
while IFS= read -r line; do
  [ -z "$line" ] && continue

  source=$(echo "$line" | jq -r '.source // ""')
  sha=$(echo "$line" | jq -r '.sha // ""')
  msg=$(echo "$line" | jq -r '.message // ""')
  repo=$(echo "$line" | jq -r '.repo // ""')

  [ -z "$sha" ] && continue

  prompt="You assess whether an improvement idea is applicable to an agent.

AGENT STACK: $AGENT_STACK_DESC

SIGNAL (from $source):
  Repo/Source: $repo
  SHA/ID: $sha
  Message: $msg

Is the underlying idea genuinely applicable to improving this agent's code, memory, or infrastructure? Be STRICT — most signals are not.

Reply ONLY with a JSON object on a single line (no markdown):
{\"applicable\": true|false, \"reason\": \"1-2 sentence explanation\"}"

  verdict=$(llm_call "review-$sha" 30 "$REVIEW_MODEL" "$prompt" 2>/dev/null || echo '{"applicable":false,"reason":"LLM call failed"}')

  is_app=$(echo "$verdict" | jq -r '.applicable // false' 2>/dev/null)
  reason=$(echo "$verdict" | jq -r '.reason // ""' 2>/dev/null)
  reviewed=$((reviewed+1))

  [ "$is_app" = "true" ] && applicable=$((applicable+1))

  # Append to applicable.jsonl with the verdict added.
  printf '%s\n' "$line" | jq --arg v "$is_app" --arg r "$reason" '. + {applicable:($v=="true"), review_reason:$r}' >> "$APPLICABLE"

  log "reviewed $sha (applicable=$is_app)"
done < "$SIGNALS"

log "review-gate complete: $reviewed reviewed, $applicable applicable"
echo "Reviewed $reviewed signals → $applicable applicable in $APPLICABLE"
