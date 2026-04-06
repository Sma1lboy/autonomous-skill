#!/usr/bin/env bash
# monitor-sprint.sh — Poll for sprint completion via summary file + tmux liveness
#
# Usage: bash monitor-sprint.sh <project_dir> <sprint_num>
#
# Blocks until sprint-summary.json appears or sprint window/process exits.
# Output: Prints sprint summary content when found.
# Layer: conductor

set -euo pipefail

show_help() {
  echo "Usage: bash monitor-sprint.sh <project_dir> <sprint_num>"
  echo ""
  echo "Poll for sprint completion. Blocks until sprint-summary.json appears"
  echo "or the sprint tmux window closes."
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: monitor-sprint.sh <project_dir> <sprint_num>}"
SPRINT_NUM="${2:?Usage: monitor-sprint.sh <project_dir> <sprint_num>}"

SUMMARY_FILE="$PROJECT_DIR/.autonomous/sprint-$SPRINT_NUM-summary.json"
GENERIC_FILE="$PROJECT_DIR/.autonomous/sprint-summary.json"
COMMS_FILE="$PROJECT_DIR/.autonomous/comms.json"

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
  python3 -c "
import json, subprocess
commits = subprocess.run(['git', 'log', '--oneline', '-5'], capture_output=True, text=True, cwd='$PROJECT_DIR').stdout.strip().split('\n')
summary = {
    'status': 'complete',
    'commits': [c for c in commits[:5] if c],
    'summary': '''$comms_summary''',
    'iterations_used': 1,
    'direction_complete': True
}
with open('$SUMMARY_FILE', 'w') as f:
    json.dump(summary, f, indent=2)
" 2>/dev/null
}

while true; do
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
    COMMS_STATUS=$(python3 -c "import json; print(json.load(open('$COMMS_FILE')).get('status',''))" 2>/dev/null || echo "")
    if [ "$COMMS_STATUS" = "done" ]; then
      COMMS_SUMMARY=$(python3 -c "import json; print(json.load(open('$COMMS_FILE')).get('summary','Sprint completed (summary from comms)'))" 2>/dev/null || echo "Sprint completed")
      # Auto-generate sprint-summary.json from comms.json
      _generate_summary_from_comms "$COMMS_SUMMARY"
      echo "=== SPRINT $SPRINT_NUM COMPLETE (from comms.json fallback) ==="
      cat "$SUMMARY_FILE"
      break
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
        COMMS_STATUS=$(python3 -c "import json; print(json.load(open('$COMMS_FILE')).get('status',''))" 2>/dev/null || echo "")
        if [ "$COMMS_STATUS" = "done" ]; then
          COMMS_SUMMARY=$(python3 -c "import json; print(json.load(open('$COMMS_FILE')).get('summary','Sprint completed'))" 2>/dev/null || echo "Sprint completed")
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

  sleep 8
done
