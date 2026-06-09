#!/bin/bash
# src/draft-change.sh — Stage 3: LLM-driven change drafting in an isolated worktree.
#
# For each applicable signal in applicable.jsonl (not yet drafted), creates a new
# git worktree, prompts the LLM to implement a minimal change, and writes the
# resulting diff + PROPOSAL.md. Live code is NEVER touched.
#
# Output: $STAGING_DIR/<id>/change.diff and PROPOSAL.md for each drafted signal.
#
# Env: REPO_PATH, DRAFT_MODEL, BUILD_CMD, MAX_PER_RUN, ENTRYPOINT

set -uo pipefail
source "$(dirname "$0")/lib/llm.sh"

REPO_PATH="${REPO_PATH:-.}"
STAGING_DIR="${STAGING_DIR:-/tmp/agent-si-staging}"
LOG_FILE="${LOG_FILE:-/tmp/agent-si.log}"
APPLICABLE="$STAGING_DIR/applicable.jsonl"
DRAFTED="$STAGING_DIR/drafted.jsonl"
DRAFT_MODEL="${DRAFT_MODEL:-gpt-4o}"
BUILD_CMD="${BUILD_CMD:-bun build src/main.ts --target=bun --outfile=/dev/null}"
ENTRYPOINT="${ENTRYPOINT:-src/main.ts}"
MAX_PER_RUN="${MAX_PER_RUN:-2}"

[ ! -f "$APPLICABLE" ] && { echo "draft-change: $APPLICABLE not found — run review-gate.sh first"; exit 1; }

mkdir -p "$STAGING_DIR"
touch "$DRAFTED"

log() { echo "[$(date)] draft-change: $*" >> "$LOG_FILE"; }

# Worktree cleanup on exit.
CURRENT_WT=""
cleanup_wt() {
  [ -n "${CURRENT_WT:-}" ] && { git -C "$REPO_PATH" worktree remove --force "$CURRENT_WT" 2>/dev/null; rm -rf "$CURRENT_WT"; }
  CURRENT_WT=""
}
trap 'cleanup_wt; git -C "$REPO_PATH" worktree prune 2>/dev/null' EXIT INT TERM

log "drafting changes (model=$DRAFT_MODEL, max=$MAX_PER_RUN per run)"

drafted=0
jq -c 'select(.applicable==true)' "$APPLICABLE" 2>/dev/null | while IFS= read -r item; do
  [ -z "$item" ] && continue
  [ "$drafted" -ge "$MAX_PER_RUN" ] && break

  source=$(echo "$item" | jq -r '.source // ""')
  sha=$(echo "$item" | jq -r '.sha // ""')
  msg=$(echo "$item" | jq -r '.message // ""')
  repo=$(echo "$item" | jq -r '.repo // ""')

  [ -z "$sha" ] && continue

  # Skip if already drafted.
  if grep -q "\"$sha\"" "$DRAFTED" 2>/dev/null; then
    log "draft: $sha already drafted, skipping"
    continue
  fi

  short=$(echo "$sha" | cut -c1-8)
  id="$(date +%Y%m%d-%H%M%S)-${short}"
  pdir="$STAGING_DIR/$id"
  wt="/tmp/si-draft-${id}"

  mkdir -p "$pdir"
  rm -rf "$wt"

  log "drafting $id (from $source: $sha)"

  # Create an isolated worktree off current HEAD.
  if ! git -C "$REPO_PATH" worktree add -q --detach "$wt" HEAD 2>>"$LOG_FILE"; then
    log "draft $id: worktree add failed, skipping"
    echo "$sha" >> "$DRAFTED"
    continue
  fi
  CURRENT_WT="$wt"

  # Link node_modules (or equivalent) so the LLM can build.
  if [ -d "$REPO_PATH/node_modules" ]; then
    ln -s "$REPO_PATH/node_modules" "$wt/node_modules" 2>/dev/null || true
  fi

  # Read relevant source files to give LLM context (cap at 10KB per file).
  local context=""
  if [ -f "$wt/$ENTRYPOINT" ]; then
    context="$(head -c 10000 "$wt/$ENTRYPOINT")"
  fi

  prompt="You are improving an agent application. You have access to an isolated copy of the repo in your current working directory.

SIGNAL: (source=$source)
  Repo/Source: $repo
  SHA: $sha
  Message: $msg

ENTRYPOINT: $ENTRYPOINT
RELEVANT CODE (first 10KB):
\`\`\`
${context}
\`\`\`

TASK:
1. Understand the agent's current code and structure.
2. If this signal suggests a genuine, MINIMAL improvement, implement ONLY that change.
3. Touch only source files under src/ (or equivalent). Never touch package.json, config, or build files.
4. After your change, run the build command to verify no errors:
   $BUILD_CMD
5. If the idea doesn't apply or the build fails, revert all changes (git checkout .) and reply:
   NO_CHANGE: <one-line reason>
6. Otherwise, do NOT git commit. Reply with a 2-line summary:
   CHANGED: <what changed>
   WHY: <why it improves the agent>"

  # Run the draft in the worktree.
  summary=$(cd "$wt" && timeout 300 llm_call "draft-$id" 300 "$DRAFT_MODEL" "$prompt" 2>/dev/null || echo "NO_CHANGE: LLM draft failed")

  echo "$sha" >> "$DRAFTED"  # mark as drafted regardless of outcome

  # Extract diff from worktree.
  diff=$(git -C "$wt" diff -- src/ 2>/dev/null || true)

  if [ -z "$diff" ] || echo "$summary" | grep -q "NO_CHANGE"; then
    reason=$(echo "$summary" | grep "NO_CHANGE:" || echo "(no diff)")
    log "draft $id: NO_CHANGE — $reason"
    cleanup_wt
    rm -rf "$pdir"
    continue
  fi

  # Write proposal.
  printf '%s\n' "$diff" > "$pdir/change.diff"
  {
    echo "# Self-Improvement Proposal: $id"
    echo ""
    echo "- Source: $source"
    echo "- SHA: $sha"
    echo "- Message: $msg"
    echo "- Repo: $repo"
    echo "- Status: DRAFTED (pending smoke-test)"
    echo ""
    echo "## Summary"
    echo "$summary"
    echo ""
    echo "## Diff (src/ only)"
    echo "\`\`\`diff"
    cat "$pdir/change.diff"
    echo "\`\`\`"
  } > "$pdir/PROPOSAL.md"

  cleanup_wt
  drafted=$((drafted+1))

  lines=$(wc -l < "$pdir/change.diff" | tr -d ' ')
  log "draft $id: written ($lines diff lines) → $pdir"

done

log "drafted $drafted proposals this run"
echo "Drafted $drafted proposals"
