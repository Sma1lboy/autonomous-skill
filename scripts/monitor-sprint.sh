#!/usr/bin/env bash
# monitor-sprint.sh — Poll for sprint completion via summary file + tmux liveness
#
# Usage: bash monitor-sprint.sh <project_dir> <sprint_num>
#
# Blocks until sprint-summary.json appears or sprint window/process exits.
# Output: Prints sprint summary content when found.
# Layer: conductor

set -euo pipefail

usage() {
  echo "Usage: bash monitor-sprint.sh <project_dir> <sprint_num>"
  echo ""
  echo "Poll for sprint completion. Blocks until sprint-summary.json appears,"
  echo "the sprint tmux window closes, or a shutdown sentinel is detected."
  echo "Also handles comms.json 'done' status as a fallback completion signal."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory (contains .autonomous/)"
  echo "  sprint_num    Sprint number to monitor (e.g., 1, 2, 3)"
  echo ""
  echo "Environment:"
  echo "  MONITOR_MAX_POLLS   Max poll iterations before timeout (default: 225, ~30min)"
  echo ""
  echo "Examples:"
  echo "  bash monitor-sprint.sh /path/to/project 1"
  echo "  bash monitor-sprint.sh . 3"
  echo "  MONITOR_MAX_POLLS=10 bash monitor-sprint.sh /project 2"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

PROJECT_DIR="${1:?Usage: monitor-sprint.sh <project_dir> <sprint_num>}"
SPRINT_NUM="${2:?Usage: monitor-sprint.sh <project_dir> <sprint_num>}"

# Max poll iterations before timeout (default ~225 = ~30 min at 8s intervals)
MAX_POLLS="${MONITOR_MAX_POLLS:-225}"

source "$(dirname "${BASH_SOURCE[0]}")/comms-lib.sh"

# Signal handling: break out of poll loop on interrupt
_MONITOR_INTERRUPTED=0
trap '_MONITOR_INTERRUPTED=1' INT TERM

SUMMARY_FILE="$PROJECT_DIR/.autonomous/sprint-$SPRINT_NUM-summary.json"
GENERIC_FILE="$PROJECT_DIR/.autonomous/sprint-summary.json"
COMMS_FILE="$PROJECT_DIR/.autonomous/comms.json"
SHUTDOWN_FILE="$PROJECT_DIR/.autonomous/shutdown-reason.json"

# Record comms.json mtime at monitor start — only accept changes AFTER this point
COMMS_MTIME_AT_START=""
if [ -f "$COMMS_FILE" ]; then
  COMMS_MTIME_AT_START=$(stat -f %m "$COMMS_FILE" 2>/dev/null || stat -c %Y "$COMMS_FILE" 2>/dev/null || echo "")
fi

# Check if comms.json was modified after monitor started
_comms_changed_since_start() {
  if [ -z "$COMMS_MTIME_AT_START" ]; then return 0; fi
  if [ ! -f "$COMMS_FILE" ]; then return 1; fi
  local current_mtime
  current_mtime=$(stat -f %m "$COMMS_FILE" 2>/dev/null || stat -c %Y "$COMMS_FILE" 2>/dev/null || echo "")
  [ "$current_mtime" != "$COMMS_MTIME_AT_START" ]
}

# Generate sprint-summary.json from comms.json done status
_generate_summary_from_comms() {
  local comms_summary="$1"
  local commits
  commits=$(cd "$PROJECT_DIR" && git log --oneline -5 2>/dev/null | head -5)
  local commits_json
  commits_json=$(printf '%s\n' "$commits" | jq -R '[., inputs] | map(select(. != ""))' 2>/dev/null || echo '[]')
  jq -n --arg summary "$comms_summary" --argjson commits "$commits_json" \
    '{"status":"complete","commits":$commits,"summary":$summary,"iterations_used":1,"direction_complete":true}' \
    > "${SUMMARY_FILE}.tmp"
  mv -f "${SUMMARY_FILE}.tmp" "$SUMMARY_FILE"
}

_POLL_COUNT=0
_CORRUPT_STREAK=0

while true; do
  ((_POLL_COUNT++)) || true
  if [ "$_POLL_COUNT" -gt "$MAX_POLLS" ]; then
    echo "=== SPRINT $SPRINT_NUM MONITOR TIMEOUT (${MAX_POLLS} polls) ==="
    break
  fi

  # Check for shutdown marker file
  if [ -f "$SHUTDOWN_FILE" ]; then
    echo "=== SPRINT $SPRINT_NUM SHUTDOWN ==="
    break
  fi

  # Check for numbered sprint summary file
  if [ -f "$SUMMARY_FILE" ]; then
    echo "=== SPRINT $SPRINT_NUM COMPLETE ==="
    cat "$SUMMARY_FILE"
    break
  fi

  # Check for generic sprint-summary.json (sprint master may use this name)
  if [ -f "$GENERIC_FILE" ]; then
    cp "$GENERIC_FILE" "$SUMMARY_FILE"
    rm -f "$GENERIC_FILE"
    echo "=== SPRINT $SPRINT_NUM COMPLETE ==="
    cat "$SUMMARY_FILE"
    break
  fi

  # Check comms.json for worker/sprint-master "done" status (fallback if write-summary.sh was skipped)
  # Only accept if comms.json was modified AFTER monitor started (prevents stale reads)
  if [ -f "$COMMS_FILE" ] && _comms_changed_since_start; then
    COMMS_STATUS=$(_read_comms_status "$COMMS_FILE")
    if [ "$COMMS_STATUS" = "CORRUPT" ]; then
      ((_CORRUPT_STREAK++)) || true
      echo "WARNING: corrupt comms file: $COMMS_FILE (streak: $_CORRUPT_STREAK)" >&2
      if [ "$_CORRUPT_STREAK" -ge 3 ]; then
        echo "=== SPRINT $SPRINT_NUM COMMS CORRUPT (3 consecutive) ==="
        break
      fi
    else
      _CORRUPT_STREAK=0
      if [ "$COMMS_STATUS" = "done" ]; then
        COMMS_SUMMARY=$(jq -r '.summary // "Sprint completed (summary from comms)"' "$COMMS_FILE" 2>/dev/null || echo "Sprint completed")
        # Auto-generate sprint-summary.json from comms.json
        _generate_summary_from_comms "$COMMS_SUMMARY"
        echo "=== SPRINT $SPRINT_NUM COMPLETE (from comms.json fallback) ==="
        cat "$SUMMARY_FILE"
        break
      fi
    fi
  fi

  # Check if sprint tmux window is still alive
  if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
    if ! tmux list-windows 2>/dev/null | grep -q "sprint-$SPRINT_NUM"; then
      echo "=== SPRINT $SPRINT_NUM WINDOW CLOSED ==="
      # Grab generic summary if written before exit
      [ -f "$GENERIC_FILE" ] && cp "$GENERIC_FILE" "$SUMMARY_FILE"
      break
    fi
  fi

  # Check for headless process exit (no tmux)
  HEADLESS_PID_FILE="$PROJECT_DIR/.autonomous/sprint-${SPRINT_NUM}-pid"
  if [ -f "$HEADLESS_PID_FILE" ]; then
    HPID=$(cat "$HEADLESS_PID_FILE")
    if ! kill -0 "$HPID" 2>/dev/null; then
      # Process exited — check comms one more time (only if modified since start)
      if [ -f "$COMMS_FILE" ] && _comms_changed_since_start; then
        COMMS_STATUS=$(_read_comms_status "$COMMS_FILE")
        if [ "$COMMS_STATUS" = "done" ]; then
          COMMS_SUMMARY=$(jq -r '.summary // "Sprint completed"' "$COMMS_FILE" 2>/dev/null || echo "Sprint completed")
          _generate_summary_from_comms "$COMMS_SUMMARY"
          echo "=== SPRINT $SPRINT_NUM COMPLETE (headless exit + comms fallback) ==="
          cat "$SUMMARY_FILE"
          break
        fi
      fi
      echo "=== SPRINT $SPRINT_NUM PROCESS EXITED ==="
      break
    fi
  fi

  # Check if interrupted by signal
  if [ "$_MONITOR_INTERRUPTED" -eq 1 ]; then
    echo "=== SPRINT $SPRINT_NUM INTERRUPTED ==="
    # Check for summary files one last time before exiting
    if [ -f "$SUMMARY_FILE" ]; then
      cat "$SUMMARY_FILE"
    elif [ -f "$GENERIC_FILE" ]; then
      cp "$GENERIC_FILE" "$SUMMARY_FILE"
      cat "$SUMMARY_FILE"
    fi
    break
  fi

  sleep 8
done
