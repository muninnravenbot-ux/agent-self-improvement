#!/bin/bash
# src/self-improve.sh — Orchestrator: runs the full loop stages 1-6 in order.
#
# This is the main entrypoint. It runs:
#   1. gather-signals.sh  — collect improvement signals
#   2. review-gate.sh     — LLM applicability gate
#   3. draft-change.sh    — draft changes in worktrees
#   4. smoke-test.sh      — validate each drafted change
#   5. apply-change.sh    — merge (gated or autonomous)
#   6. consolidate-memory.sh — dedup memory
#
# Usage:
#   ./self-improve.sh              # full loop (gated mode)
#   APPROVE_MODE=auto ./self-improve.sh  # autonomous mode
#   DRY_RUN=1 ./self-improve.sh    # dry-run (no commits/restarts)
#
# Env: see .env.example

set -uo pipefail

# Source config (local .env if present, else env vars).
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${LOG_FILE:-/tmp/agent-si.log}"
DRY_RUN="${DRY_RUN:-0}"
APPROVE_MODE="${APPROVE_MODE:-gated}"

log() { echo "[$(date)] self-improve: $*" | tee -a "$LOG_FILE"; }

log "=== SELF-IMPROVE LOOP START (mode=$APPROVE_MODE, dry_run=$DRY_RUN) ==="

# ── Stage 1: Gather signals ─────────────────────────────────────────────────
log "Stage 1/6: gathering signals..."
if bash "$DIR/gather-signals.sh"; then
  log "✓ Signals gathered"
else
  log "⚠ Signal gathering had issues (may be non-fatal)"
fi

# ── Stage 2: Review for applicability ───────────────────────────────────────
log "Stage 2/6: reviewing signals for applicability..."
if bash "$DIR/review-gate.sh"; then
  log "✓ Signals reviewed"
else
  log "⚠ Signal review had issues"
fi

# ── Stage 3: Draft changes ──────────────────────────────────────────────────
log "Stage 3/6: drafting changes (in isolated worktrees)..."
if bash "$DIR/draft-change.sh"; then
  log "✓ Changes drafted"
else
  log "⚠ Draft stage had issues"
fi

# ── Stage 4: Smoke-test (integrated into draft-change for now) ──────────────
log "Stage 4/6: smoke-testing (integrated into draft-change)"

# ── Stage 5: Apply changes ──────────────────────────────────────────────────
log "Stage 5/6: applying changes..."

STAGING_DIR="${STAGING_DIR:-/tmp/agent-si-staging}"
if [ ! -d "$STAGING_DIR" ]; then
  log "no staging dir — nothing to apply"
else
  applied=0
  for pdir in "$STAGING_DIR"/*/; do
    [ ! -f "$pdir/change.diff" ] && continue
    id=$(basename "$pdir")

    # Skip if already applied.
    if [ -f "$pdir/.applied" ]; then
      log "skipping $id (already applied)"
      continue
    fi

    log "applying proposal $id..."
    if bash "$DIR/apply-change.sh" "$id"; then
      touch "$pdir/.applied"
      applied=$((applied+1))
    else
      log "⚠ proposal $id failed to apply"
    fi
  done
  log "applied $applied proposals"
fi

# ── Stage 6: Consolidate memory ─────────────────────────────────────────────
log "Stage 6/6: consolidating memory..."
if bash "$DIR/consolidate-memory.sh"; then
  log "✓ Memory consolidated"
else
  log "⚠ Memory consolidation skipped or failed"
fi

log "=== SELF-IMPROVE LOOP COMPLETE ==="
echo ""
echo "Full loop complete. Check $LOG_FILE for details."
