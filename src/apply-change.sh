#!/bin/bash
# src/apply-change.sh — Stage 5: gated (or autonomous) merge of a drafted proposal.
#
# Two modes:
#   1. GATED (default): Requires explicit approval (APPROVE_MODE=gated + an approval token/flag)
#   2. AUTONOMOUS (APPROVE_MODE=auto): Guardian-protected auto-merge (memory + service rollback on failure)
#
# Applies the diff to live code, re-smoke-tests, and commits. On smoke failure, reverts.
# On service health failure (autonomous only), auto-rolls-back the merge commit.
#
# Usage:
#   apply-change.sh <proposal-id>
#   APPROVE_MODE=auto apply-change.sh <proposal-id>  # autonomous mode (with guardians)
#
# Env: REPO_PATH, APPROVE_MODE, RESTART_CMD, HEALTH_CHECK, HEALTH_WINDOW, BUILD_CMD

set -uo pipefail
source "$(dirname "$0")/lib/memory-guardian.sh"
source "$(dirname "$0")/lib/relay-guardian.sh"

REPO_PATH="${REPO_PATH:-.}"
STAGING_DIR="${STAGING_DIR:-/tmp/agent-si-staging}"
LOG_FILE="${LOG_FILE:-/tmp/agent-si.log}"
BUILD_CMD="${BUILD_CMD:-bun build src/main.ts --target=bun --outfile=/dev/null}"
APPROVE_MODE="${APPROVE_MODE:-gated}"
RESTART_CMD="${RESTART_CMD:-}"
HEALTH_CHECK="${HEALTH_CHECK:-}"
HEALTH_WINDOW="${HEALTH_WINDOW:-20}"
DRY_RUN="${DRY_RUN:-0}"

log() { echo "[$(date)] apply-change: $*" >> "$LOG_FILE"; }
notify() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  [ -n "${NOTIFY_CMD:-}" ] && eval "$NOTIFY_CMD" "$1" >/dev/null 2>&1 || true
}

id="${1:-}"
[ -z "$id" ] && { echo "usage: $0 <proposal-id>"; exit 2; }

pdir="$STAGING_DIR/$id"
diff="$pdir/change.diff"

[ -f "$diff" ] || { log "apply-change: no proposal at $pdir"; echo "ERROR: no proposal found"; exit 1; }

cd "$REPO_PATH" || exit 1

# Refuse to apply onto a dirty tree.
if ! git diff --quiet -- src/ 2>/dev/null; then
  log "apply-change $id: src/ has uncommitted changes — clean the tree first"
  echo "ERROR: src/ has uncommitted changes. Commit or stash them first."
  exit 1
fi

log "apply-change $id (mode=$APPROVE_MODE)"

# ── GATED MODE: require approval token ──────────────────────────────────────
if [ "$APPROVE_MODE" = "gated" ]; then
  approve_file="$pdir/.approved"
  if [ ! -f "$approve_file" ]; then
    log "apply-change $id: not approved (no $approve_file)"
    echo "Proposal $id not approved. Create $approve_file to approve, then re-run."
    exit 1
  fi
fi

# ── SNAPSHOT & RECORD ROLLBACK SHA ─────────────────────────────────────────
snap="$STAGING_DIR/.snapshots/$id-$(date +%s)"
mkdir -p "$(dirname "$snap")"

if [ "$APPROVE_MODE" = "auto" ]; then
  memory_guardian snapshot "$snap" 2>/dev/null || log "apply-change: memory snapshot skipped (optional)"
  rollback_sha=$(relay_guardian snapshot-sha "$REPO_PATH" 2>/dev/null)
fi

# ── APPLY DIFF ─────────────────────────────────────────────────────────────
if ! git apply --include='src/*' --check "$diff" 2>>"$LOG_FILE"; then
  log "apply-change $id: diff no longer applies cleanly — needs re-draft"
  echo "ERROR: Diff no longer applies cleanly to src/. Needs re-draft."
  exit 1
fi

git apply --include='src/*' "$diff" 2>>"$LOG_FILE"

# Extract the exact files this diff touches (for precise commit).
mapfile -t CHANGED < <(git apply --include='src/*' --numstat "$diff" 2>/dev/null | awk '{print $3}' | grep '^src/' || true)

if [ "${#CHANGED[@]}" -eq 0 ]; then
  git checkout -- src/ 2>>"$LOG_FILE"
  log "apply-change $id: proposal touched no src/ files — rejected"
  echo "ERROR: Proposal touched no src/ files (out of scope)."
  exit 1
fi

log "apply-change $id: applied (${#CHANGED[@]} file(s))"

# ── SMOKE TEST ─────────────────────────────────────────────────────────────
smoke_out=$(bash "$(dirname "$0")/smoke-test.sh" "$REPO_PATH" 2>&1 || echo "FAIL")
smoke_status=$(echo "$smoke_out" | head -1)

if [ "$smoke_status" != "PASS" ]; then
  git checkout -- src/ 2>>"$LOG_FILE"
  log "apply-change $id: smoke FAILED → reverted"
  echo "ERROR: Smoke test failed. Working tree reverted."
  echo "$smoke_out" | tail -10
  exit 1
fi

log "apply-change $id: smoke PASS"

# ── DRY RUN: stop here ─────────────────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  git checkout -- src/ 2>>"$LOG_FILE"
  log "apply-change $id: DRY_RUN — reverted (no commit/restart)"
  echo "DRY_RUN OK: applied + smoke-passed + reverted"
  exit 0
fi

# ── COMMIT ─────────────────────────────────────────────────────────────────
before=$(git rev-parse HEAD)
msg_line=$(grep -m1 '^- Message:' "$pdir/PROPOSAL.md" | sed 's/^- Message: //' | head -c 80)

git add -- "${CHANGED[@]}"
git commit -q -m "self-improve: apply $id

Drafted from signal and applied with smoke-test confirmation.
Source message: ${msg_line:-n/a}

Co-Authored-By: Crowork Agent <agent@crowork.ai>" || {
  log "apply-change $id: git commit failed"
  echo "ERROR: Failed to commit"
  exit 1
}
after=$(git rev-parse HEAD)
log "apply-change $id: committed $before → $after"

# ── RESTART & HEALTH CHECK (if configured) ─────────────────────────────────
if [ -n "$RESTART_CMD" ]; then
  log "apply-change $id: restarting service"
  eval "$RESTART_CMD" >/dev/null 2>&1 || true
  sleep 3

  # Check health (if HEALTH_CHECK is configured).
  if [ -n "$HEALTH_CHECK" ]; then
    if ! eval "$HEALTH_CHECK" >/dev/null 2>&1; then
      # Service is down. In gated mode, report the problem and stop.
      # In autonomous mode, use relay-guardian to auto-rollback.
      if [ "$APPROVE_MODE" = "auto" ]; then
        log "apply-change $id: health check failed — invoking relay-guardian rollback"
        relay_guardian guard "$REPO_PATH" "$rollback_sha" 2>/dev/null || true
      else
        log "apply-change $id: health check failed — manual restart required"
        echo "WARNING: Service is not healthy after restart. Manual check needed."
      fi
      exit 1
    fi
  fi
  log "apply-change $id: service restarted OK"
fi

# ── AUTONOMOUS MODE: verify memory + service guardians ───────────────────────
if [ "$APPROVE_MODE" = "auto" ]; then
  memory_guardian guard "$snap" 2>/dev/null || {
    log "apply-change $id: memory integrity check failed — reverting merge"
    git reset --hard "$before" 2>>"$LOG_FILE"
    [ -n "$RESTART_CMD" ] && eval "$RESTART_CMD" >/dev/null 2>&1 || true
    exit 1
  }
  log "apply-change $id: memory + service invariants held"
fi

# ── SUCCESS ────────────────────────────────────────────────────────────────
log "apply-change $id: SUCCESS → $after"
echo "[$(date)] APPLIED commit=$after" >> "$pdir/PROPOSAL.md"
notify "Self-improvement proposal $id merged and deployed. Rollback: git revert $after"
echo "SUCCESS: Proposal $id applied and deployed."
exit 0
