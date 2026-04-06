#!/bin/bash
# monitor-worker.sh — Poll for worker completion via comms.json + tmux/process liveness
#
# Usage: bash monitor-worker.sh <project_dir> [window_name] [worker_pid] [worker-id]
#        bash monitor-worker.sh <project_dir> --all
#
# Blocks until worker finishes, asks a question, or exits unexpectedly.
# Output: Prints status lines. Final line is one of:
#   WORKER_DONE, WORKER_ASKING, WORKER_WINDOW_CLOSED, WORKER_PROCESS_EXITED
#
# If worker-id is provided, monitors .autonomous/comms-{worker-id}.json
# instead of comms.json.
#
# --all mode: scans all comms-worker-*.json files, returns when ANY worker
# has status "waiting" or "done". Output includes WORKER_ID=<id>.

set -euo pipefail

show_help() {
  echo "Usage: bash monitor-worker.sh <project_dir> [window_name] [worker_pid] [worker-id]"
  echo "       bash monitor-worker.sh <project_dir> --all"
  echo ""
  echo "Poll for worker completion via comms.json and tmux/process liveness."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory containing .autonomous/comms.json"
  echo "  window_name   tmux window name to monitor (default: 'worker')"
  echo "  worker_pid    PID to monitor in headless mode (optional)"
  echo "  worker-id     Worker identifier for per-worker comms isolation (optional)"
  echo "                Monitors .autonomous/comms-{worker-id}.json if provided"
  echo "  --all         Scan all comms-worker-*.json files, return on any activity"
  echo ""
  echo "Exit statuses printed to stdout:"
  echo "  WORKER_DONE           Worker wrote done status to comms.json"
  echo "  WORKER_ASKING         Worker has a question in comms.json"
  echo "  WORKER_WINDOW_CLOSED  tmux window disappeared"
  echo "  WORKER_PROCESS_EXITED Headless process exited"
  echo ""
  echo "In --all mode, WORKER_ID=<id> is printed before the status line."
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

# Max poll iterations before timeout (default ~225 = ~30 min at 8s intervals)
MAX_POLLS="${MONITOR_MAX_POLLS:-225}"

# Helper: read comms JSON status safely.
# Outputs one of: idle, waiting, done, answered, CORRUPT
# Distinguishes "file is idle" from "file is unreadable/corrupt"
_read_comms_status() {
  local file="$1"
  [ -f "$file" ] || { echo "idle"; return 0; }
  local result
  result=$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('status','idle'))
except (json.JSONDecodeError, ValueError, KeyError):
    print('CORRUPT')
" "$file" 2>/dev/null) || { echo "CORRUPT"; return 0; }
  echo "$result"
}

PROJECT_DIR="${1:?Usage: monitor-worker.sh <project_dir> [window_name] [worker_pid] [worker-id]}"

# --all mode: scan all per-worker comms files
if [ "${2:-}" = "--all" ]; then
  _all_polls=0
  _all_corrupt_streak=0
  while true; do
    ((_all_polls++)) || true
    if [ "$_all_polls" -gt "$MAX_POLLS" ]; then
      echo "=== MONITOR TIMEOUT (${MAX_POLLS} polls) ==="
      echo "WORKER_DONE"
      exit 0
    fi
    for f in "$PROJECT_DIR"/.autonomous/comms-worker-*.json; do
      [ -f "$f" ] || continue
      STATUS=$(_read_comms_status "$f")
      if [ "$STATUS" = "CORRUPT" ]; then
        ((_all_corrupt_streak++)) || true
        echo "WARNING: corrupt comms file: $f (streak: $_all_corrupt_streak)" >&2
        if [ "$_all_corrupt_streak" -ge 3 ]; then
          BASENAME=$(basename "$f" .json)
          WID="${BASENAME#comms-}"
          echo "WORKER_ID=$WID"
          echo "=== COMMS: CORRUPT JSON (3 consecutive) ==="
          echo "WORKER_ASKING"
          exit 0
        fi
        continue
      fi
      _all_corrupt_streak=0
      if [ "$STATUS" = "done" ] || [ "$STATUS" = "waiting" ]; then
        # Extract worker-id from filename: comms-worker-{id}.json -> worker-{id}
        BASENAME=$(basename "$f" .json)
        WID="${BASENAME#comms-}"
        echo "WORKER_ID=$WID"
        if [ "$STATUS" = "done" ]; then
          echo "=== WORKER DONE ($WID) ==="
          python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))" "$f" 2>/dev/null
          echo "WORKER_DONE"
        else
          echo "=== COMMS: WORKER ASKING ($WID) ==="
          python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))" "$f" 2>/dev/null
          echo "WORKER_ASKING"
        fi
        exit 0
      fi
    done
    sleep 8
  done
fi

WINDOW_NAME="${2:-worker}"
WORKER_PID="${3:-}"
WORKER_ID="${4:-}"

# Determine which comms file to monitor
if [ -n "$WORKER_ID" ]; then
  COMMS_FILE="$PROJECT_DIR/.autonomous/comms-${WORKER_ID}.json"
else
  COMMS_FILE="$PROJECT_DIR/.autonomous/comms.json"
fi

_LAST_COMMIT=$(cd "$PROJECT_DIR" && git log --oneline -1 2>/dev/null || echo "")
_POLL_COUNT=0
_CORRUPT_STREAK=0

while true; do
  ((_POLL_COUNT++)) || true
  if [ "$_POLL_COUNT" -gt "$MAX_POLLS" ]; then
    echo "=== MONITOR TIMEOUT (${MAX_POLLS} polls) ==="
    echo "WORKER_DONE"
    exit 0
  fi

  # Check comms.json status
  STATUS=$(_read_comms_status "$COMMS_FILE")

  if [ "$STATUS" = "CORRUPT" ]; then
    ((_CORRUPT_STREAK++)) || true
    echo "WARNING: corrupt comms file: $COMMS_FILE (streak: $_CORRUPT_STREAK)" >&2
    if [ "$_CORRUPT_STREAK" -ge 3 ]; then
      echo "=== COMMS: CORRUPT JSON (3 consecutive) ==="
      echo "WORKER_ASKING"
      exit 0
    fi
  else
    _CORRUPT_STREAK=0

    if [ "$STATUS" = "done" ]; then
      echo "=== WORKER DONE ==="
      python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))" "$COMMS_FILE" 2>/dev/null
      echo "WORKER_DONE"
      exit 0
    fi

    if [ "$STATUS" = "waiting" ]; then
      echo "=== COMMS: WORKER ASKING ==="
      python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))" "$COMMS_FILE" 2>/dev/null
      echo "WORKER_ASKING"
      exit 0
    fi
  fi

  # Channel 2: tmux/process liveness check
  if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
    if ! tmux list-windows 2>/dev/null | grep -q "$WINDOW_NAME"; then
      echo "=== WORKER WINDOW CLOSED ==="
      echo "WORKER_WINDOW_CLOSED"
      exit 0
    fi
    # Detect idle TUI with new commits (worker forgot to write done)
    PANE=$(tmux capture-pane -t "$WINDOW_NAME" -p -S -5 2>/dev/null | tail -5)
    LATEST_COMMIT=$(cd "$PROJECT_DIR" && git log --oneline -1 2>/dev/null || echo "")
    if [ -n "$LATEST_COMMIT" ] && [ "$LATEST_COMMIT" != "$_LAST_COMMIT" ] && echo "$PANE" | grep -qE '(^❯|Cogitated|idle)'; then
      echo "=== WORKER DONE (detected via new commit + idle TUI) ==="
      echo "Latest commit: $LATEST_COMMIT"
      echo "WORKER_DONE"
      exit 0
    fi
    [ -n "$LATEST_COMMIT" ] && _LAST_COMMIT="${_LAST_COMMIT:-$LATEST_COMMIT}"
    echo "=== WORKER TUI ($(date +%H:%M:%S)) ==="
    echo "$PANE"
    echo "=== COMMS: ${STATUS:-idle} ==="
  elif [ -n "$WORKER_PID" ]; then
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
      echo "=== WORKER PROCESS EXITED ==="
      tail -30 "$PROJECT_DIR/.autonomous/${WINDOW_NAME}-output.log" 2>/dev/null
      echo "WORKER_PROCESS_EXITED"
      exit 0
    fi
  fi

  sleep 8
done
