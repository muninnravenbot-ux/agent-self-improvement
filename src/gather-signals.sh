#!/bin/bash
# src/gather-signals.sh — Stage 1: collect improvement signals from multiple sources.
#
# Scans for signals from:
#   1. Agent error log (if it exists)
#   2. Upstream GitHub repos (via gh tool or curl to GitHub API)
#   3. Custom anomaly files (if the agent logs them)
#
# Outputs: signals.jsonl (one signal per line, newline-delimited JSON)
#   Each line: {"source":"error_log"|"upstream_commit"|"anomaly", "sha":"...", "message":"...", "repo":"..."}
#
# Env: REPO_PATH, WATCH_REPOS (comma-separated owner/repo), AGENT_ERROR_LOG, ANOMALY_DIR

set -uo pipefail
source "$(dirname "$0")/lib/llm.sh" 2>/dev/null || true

REPO_PATH="${REPO_PATH:-.}"
WATCH_REPOS="${WATCH_REPOS:-}"
AGENT_ERROR_LOG="${AGENT_ERROR_LOG:-}"
ANOMALY_DIR="${ANOMALY_DIR:-}"
STAGING_DIR="${STAGING_DIR:-/tmp/agent-si-staging}"
LOG_FILE="${LOG_FILE:-/tmp/agent-si.log}"
SIGNALS="$STAGING_DIR/signals.jsonl"

mkdir -p "$STAGING_DIR"
: > "$SIGNALS"  # clear it

log() { echo "[$(date)] gather: $*" >> "$LOG_FILE"; }

# ── Gather from agent error log ───────────────────────────────────────────────
if [ -n "$AGENT_ERROR_LOG" ] && [ -f "$AGENT_ERROR_LOG" ]; then
  log "scanning agent error log: $AGENT_ERROR_LOG"

  # Look for patterns like "ERROR: ...", "EXCEPTION: ...", and extract the last 5 errors.
  tail -100 "$AGENT_ERROR_LOG" | grep -iE 'error|exception|panic|fatal' | tail -5 | while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Generate a stable hash for this error line (for deduplication).
    sha=$(echo "$line" | sha256sum | cut -c1-8)
    msg=$(echo "$line" | cut -c1-100)  # truncate to 100 chars
    printf '%s\n' "{\"source\":\"error_log\",\"sha\":\"$sha\",\"message\":\"$msg\",\"repo\":\"(agent)\"}"
  done >> "$SIGNALS"
  log "gathered error-log signals"
fi

# ── Gather from upstream GitHub repos ─────────────────────────────────────────
if [ -n "$WATCH_REPOS" ]; then
  IFS=',' read -ra REPOS <<< "$WATCH_REPOS"
  for repo in "${REPOS[@]}"; do
    repo=$(echo "$repo" | xargs)  # trim whitespace
    [ -z "$repo" ] && continue

    log "fetching recent commits from $repo"

    # Try GitHub API: list commits in the default branch.
    # Requires: GITHUB_TOKEN or anonymous access (rate-limited to 60 req/hr).
    # If gh tool is available, use it; otherwise curl.
    if command -v gh >/dev/null 2>&1; then
      gh api "repos/${repo}/commits" --jq '.[] | "\(.sha)\t\(.commit.message)"' 2>/dev/null | head -20 || true
    else
      # Fallback: raw HTTPS (no auth, so rate-limited).
      curl -s "https://api.github.com/repos/${repo}/commits?per_page=20" 2>/dev/null \
        | python3 -c 'import json,sys; data=json.load(sys.stdin); [print(f"{c[\"sha\"]}\t{c[\"commit\"][\"message\"]}") for c in data[:20]]' 2>/dev/null || true
    fi | while IFS=$'\t' read -r sha msg; do
      [ -z "$sha" ] && continue
      msg=$(echo "$msg" | head -c 100)  # first line, truncate to 100 chars
      printf '%s\n' "{\"source\":\"upstream_commit\",\"sha\":\"$sha\",\"message\":\"$msg\",\"repo\":\"$repo\"}"
    done >> "$SIGNALS"
  done
  log "gathered upstream-commit signals"
fi

# ── Gather from anomaly files ──────────────────────────────────────────────────
if [ -n "$ANOMALY_DIR" ] && [ -d "$ANOMALY_DIR" ]; then
  log "scanning anomaly dir: $ANOMALY_DIR"

  find "$ANOMALY_DIR" -type f -name "*.jsonl" -o -name "*.log" 2>/dev/null | while IFS= read -r file; do
    [ -z "$file" ] && continue

    # If it's JSONL, assume it has {sha, message, ...} fields.
    if [[ "$file" == *.jsonl ]]; then
      tail -20 "$file" | jq -c 'select(.sha != null) | {source:"anomaly", sha:.sha, message:.message//(.reason//(.error//"")), repo:"(agent)"}' 2>/dev/null >> "$SIGNALS" || true
    else
      # Plain log — scan for anomalies and hash them.
      tail -50 "$file" | grep -iE 'timeout|unhandled|panic|leak' | head -10 | while IFS= read -r line; do
        [ -z "$line" ] && continue
        sha=$(echo "$line" | sha256sum | cut -c1-8)
        msg=$(echo "$line" | cut -c1-100)
        printf '%s\n' "{\"source\":\"anomaly\",\"sha\":\"$sha\",\"message\":\"$msg\",\"repo\":\"(agent)\"}"
      done >> "$SIGNALS"
    fi
  done
  log "gathered anomaly signals"
fi

# ── Dedup by SHA ──────────────────────────────────────────────────────────────
wc_before=$(wc -l < "$SIGNALS")
sort -u -t'"' -k6,6 "$SIGNALS" > "${SIGNALS}.dedup" 2>/dev/null || true
if [ -f "${SIGNALS}.dedup" ]; then
  mv "${SIGNALS}.dedup" "$SIGNALS"
fi
wc_after=$(wc -l < "$SIGNALS")

log "gathered $wc_before signals, $wc_after unique"
echo "Gathered $wc_after unique signals → $SIGNALS"
