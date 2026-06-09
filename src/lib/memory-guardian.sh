#!/bin/bash
# lib/memory-guardian.sh — mechanical protector of the agent's memory stores.
#
# The memory guardian enforces a hard invariant: the agent's memory must survive
# any self-improvement merge. It snapshots memory before a merge and, after the
# merge, checks integrity. If memory was destroyed or corrupted, it restores from
# the snapshot automatically — no human needed.
#
# Usage:
#   source lib/memory-guardian.sh
#   memory_guardian snapshot <snapdir>   # call BEFORE applying a change
#   memory_guardian guard    <snapdir>   # call AFTER restart; returns 1 if restored
#
# Required env: MEMORY_FILE (path to the agent's primary memory file)
# Optional env: MEMORY_EXTRA_DIRS (space-separated extra dirs to snapshot)

memory_guardian() {
  local op="$1" snap="$2"
  local mem_file="${MEMORY_FILE:-}"

  case "$op" in
    snapshot)
      mkdir -p "$snap/mem"

      # Snapshot the primary memory file.
      if [ -n "$mem_file" ] && [ -f "$mem_file" ]; then
        cp -f "$mem_file" "$snap/mem/observations.md"
      fi

      # Snapshot any extra dirs (e.g. vector stores, sqlite DBs).
      for extra in ${MEMORY_EXTRA_DIRS:-}; do
        local name
        name=$(basename "$extra")
        if [ -f "$extra" ]; then
          cp -f "$extra" "$snap/mem/$name"
        elif [ -d "$extra" ]; then
          cp -a "$extra" "$snap/mem/$name"
        fi
      done

      # Write a fingerprint so the guard step can detect loss.
      {
        [ -f "$snap/mem/observations.md" ] \
          && echo "OBS_LINES=$(wc -l < "$snap/mem/observations.md")" \
          && echo "OBS_WORDS=$(wc -w < "$snap/mem/observations.md")" \
          && echo "OBS_CRITICAL=$(grep -c '🔴' "$snap/mem/observations.md" 2>/dev/null || echo 0)"
        echo "SNAP_TS=$(date -Iseconds)"
      } > "$snap/mem/fingerprint.txt"

      echo "[$(date)] memory-guardian: snapshot → $snap/mem" >&2
      return 0
      ;;

    guard)
      local restored=0 reason=""

      # Check the primary memory file still exists and hasn't shrunk dramatically.
      if [ -n "$mem_file" ] && [ -f "$snap/mem/observations.md" ]; then
        if [ ! -f "$mem_file" ]; then
          reason="observations.md missing"
          restored=1
        else
          local base_lines base_critical live_critical
          base_lines=$(grep -m1 '^OBS_LINES=' "$snap/mem/fingerprint.txt" 2>/dev/null | cut -d= -f2)
          base_critical=$(grep -m1 '^OBS_CRITICAL=' "$snap/mem/fingerprint.txt" 2>/dev/null | cut -d= -f2)
          live_critical=$(grep -c '🔴' "$mem_file" 2>/dev/null || echo 0)

          # A merge should never delete critical observations.
          if [ -n "$base_critical" ] && [ "$live_critical" -lt "$base_critical" ]; then
            reason="critical observations: $base_critical → $live_critical (lost)"
            restored=1
          fi

          # Catastrophic shrink (lost >80% of lines) = likely corruption.
          local live_lines
          live_lines=$(wc -l < "$mem_file" 2>/dev/null || echo 0)
          if [ -n "$base_lines" ] && [ "$base_lines" -gt 10 ] && [ "$live_lines" -lt $((base_lines / 5)) ]; then
            reason="${reason:+$reason; }observations collapsed: $base_lines → $live_lines lines"
            restored=1
          fi
        fi
      fi

      # Check extra dirs.
      for extra in ${MEMORY_EXTRA_DIRS:-}; do
        local name
        name=$(basename "$extra")
        if [ -f "$snap/mem/$name" ] && [ ! -f "$extra" ]; then
          reason="${reason:+$reason; }$name missing after merge"
          restored=1
        elif [ -d "$snap/mem/$name" ] && [ ! -d "$extra" ]; then
          reason="${reason:+$reason; }$name dir missing after merge"
          restored=1
        fi
      done

      if [ "$restored" -eq 1 ]; then
        echo "[$(date)] memory-guardian: GUARD TRIPPED ($reason) — RESTORING from $snap/mem" >&2
        if [ "${DRY_RUN:-0}" = "1" ]; then
          echo "[$(date)] memory-guardian: DRY_RUN — would restore, skipping" >&2
        else
          # Restore primary file.
          [ -f "$snap/mem/observations.md" ] && cp -f "$snap/mem/observations.md" "$mem_file"
          # Restore extra dirs/files.
          for extra in ${MEMORY_EXTRA_DIRS:-}; do
            local name
            name=$(basename "$extra")
            if [ -f "$snap/mem/$name" ]; then
              cp -f "$snap/mem/$name" "$extra"
            elif [ -d "$snap/mem/$name" ]; then
              rm -rf "$extra"
              cp -a "$snap/mem/$name" "$extra"
            fi
          done
        fi
        return 1   # caller: do NOT keep the merge
      fi

      echo "[$(date)] memory-guardian: guard OK" >&2
      return 0
      ;;

    *) echo "memory_guardian: unknown op $op" >&2; return 2 ;;
  esac
}
