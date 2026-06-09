#!/bin/bash
# lib/relay-guardian.sh — mechanical protector of the agent's live service.
#
# The relay guardian enforces a hard invariant: the agent's service (the
# "relay" — whatever process handles user-facing traffic) must survive any
# self-improvement merge. It records a rollback SHA before the merge and,
# after restart, health-checks the service for HEALTH_WINDOW seconds.
# If the service dies, it automatically reverts the merge commit.
#
# Usage:
#   source lib/relay-guardian.sh
#   relay_guardian snapshot-sha <repo_path>  # call BEFORE applying; prints SHA
#   relay_guardian guard <repo_path> <sha>   # call AFTER restart; returns 1 + rolls back on failure
#
# Required env:
#   RESTART_CMD    — shell command to restart the service
#   HEALTH_CHECK   — shell command that returns 0 when the service is healthy
# Optional env:
#   HEALTH_WINDOW  — seconds to poll (default: 20)
#   DRY_RUN        — 1 = skip actual rollback

relay_guardian() {
  local op="$1"; shift
  local health_window="${HEALTH_WINDOW:-20}"

  case "$op" in
    snapshot-sha)
      local repo_path="$1"
      local sha
      sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null)
      if [ -z "$sha" ]; then
        echo "relay_guardian: could not read HEAD sha from $repo_path" >&2
        return 1
      fi
      echo "$sha"
      echo "[$(date)] relay-guardian: rollback SHA = $sha" >&2
      return 0
      ;;

    guard)
      local repo_path="$1" rollback_sha="$2"
      local t=0 healthy=1

      # Poll for HEALTH_WINDOW seconds.
      while [ "$t" -lt "$health_window" ]; do
        if ! eval "${HEALTH_CHECK:-false}" >/dev/null 2>&1; then
          healthy=0
          break
        fi
        sleep 2
        t=$((t+2))
      done

      if [ "$healthy" -eq 1 ]; then
        echo "[$(date)] relay-guardian: guard OK (healthy for ${health_window}s)" >&2
        return 0
      fi

      echo "[$(date)] relay-guardian: GUARD TRIPPED — service not healthy after merge. Rolling back to $rollback_sha" >&2

      if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[$(date)] relay-guardian: DRY_RUN — would rollback, skipping" >&2
        return 1
      fi

      # Roll back to the known-good commit.
      git -C "$repo_path" reset --hard "$rollback_sha" 2>&1 >&2 || true

      # Restart with the old code.
      eval "${RESTART_CMD:-}" >/dev/null 2>&1 || true
      sleep 5

      # Report outcome.
      if eval "${HEALTH_CHECK:-false}" >/dev/null 2>&1; then
        echo "[$(date)] relay-guardian: rollback succeeded — service back up at $rollback_sha" >&2
        _relay_guardian_notify "ROLLBACK: self-merge broke the service. Auto-rolled back to $rollback_sha. Service is back up."
      else
        echo "[$(date)] relay-guardian: rollback done but service STILL down — manual intervention needed" >&2
        _relay_guardian_notify "CRITICAL: self-merge broke the service. Rollback to $rollback_sha attempted but service still down. Manual check required."
      fi

      return 1   # caller: do NOT keep the merge
      ;;

    *) echo "relay_guardian: unknown op $op" >&2; return 2 ;;
  esac
}

_relay_guardian_notify() {
  local msg="$1"
  if [ -n "${NOTIFY_CMD:-}" ]; then
    eval "$NOTIFY_CMD" "$msg" >/dev/null 2>&1 || true
  fi
}
