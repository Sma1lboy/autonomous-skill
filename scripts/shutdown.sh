#!/usr/bin/env bash
# shutdown.sh — Graceful shutdown propagation for autonomous workers
# Layer: shared
#
# Usage: bash shutdown.sh <signal> <project_dir>
#
# Reads .autonomous/worker-windows.txt, sends C-c to each tmux pane,
# waits up to 10s per window for graceful exit, force-kills survivors,
# and writes .autonomous/shutdown-reason.json with results.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  echo "Usage: bash shutdown.sh <signal> <project_dir>"
  echo ""
  echo "Graceful shutdown propagation for autonomous workers."
  echo ""
  echo "Sends C-c to each tmux worker window, waits up to 10s for"
  echo "graceful exit, force-kills survivors, and writes shutdown-reason.json."
  echo ""
  echo "Arguments:"
  echo "  signal       Signal name (e.g., SIGINT, SIGTERM, TIMEOUT)"
  echo "  project_dir  Path to the project directory"
  echo ""
  echo "Options:"
  echo "  --help, -h, help   Show this help message"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

SIGNAL="${1:?$(usage >&2; echo "ERROR: missing signal argument" >&2)}"
PROJECT_DIR="${2:?$(usage >&2; echo "ERROR: missing project_dir argument" >&2)}"

[ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"

WORKER_FILE="$PROJECT_DIR/.autonomous/worker-windows.txt"
SHUTDOWN_FILE="$PROJECT_DIR/.autonomous/shutdown-reason.json"
WAIT_SECONDS="${SHUTDOWN_WAIT_SECONDS:-10}"

WINDOWS_STOPPED=()
WINDOWS_FORCE_KILLED=()

# Check if a tmux window exists
_window_alive() {
  local win="$1"
  tmux list-windows 2>/dev/null | grep -q "$win"
}

# Process each worker window
if [ -f "$WORKER_FILE" ] && command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
  while IFS= read -r win; do
    [ -z "$win" ] && continue

    if ! _window_alive "$win"; then
      # Window already gone — count as stopped
      WINDOWS_STOPPED+=("$win")
      continue
    fi

    # Send C-c for graceful shutdown
    tmux send-keys -t "$win" C-c 2>/dev/null || true

    # Wait up to WAIT_SECONDS for window to close
    ELAPSED=0
    while [ "$ELAPSED" -lt "$WAIT_SECONDS" ]; do
      sleep 1
      ((ELAPSED++)) || true
      if ! _window_alive "$win"; then
        break
      fi
    done

    if _window_alive "$win"; then
      # Force kill survivor
      tmux kill-window -t "$win" 2>/dev/null || true
      WINDOWS_FORCE_KILLED+=("$win")
    else
      WINDOWS_STOPPED+=("$win")
    fi
  done < "$WORKER_FILE"
fi

# Write shutdown-reason.json (atomic: tmp+mv)
mkdir -p "$PROJECT_DIR/.autonomous"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 -c "
import json, sys

stopped = json.loads(sys.argv[1])
force_killed = json.loads(sys.argv[2])

data = {
    'signal': sys.argv[3],
    'timestamp': sys.argv[4],
    'windows_stopped': stopped,
    'windows_force_killed': force_killed
}

tmp = sys.argv[5] + '.tmp'
target = sys.argv[5]

with open(tmp, 'w') as f:
    json.dump(data, f, indent=2)

import os
os.rename(tmp, target)
" "$(printf '%s\n' "${WINDOWS_STOPPED[@]:-}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")" \
  "$(printf '%s\n' "${WINDOWS_FORCE_KILLED[@]:-}" | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")" \
  "$SIGNAL" \
  "$TIMESTAMP" \
  "$SHUTDOWN_FILE"

echo "Shutdown complete: signal=$SIGNAL stopped=${#WINDOWS_STOPPED[@]} force_killed=${#WINDOWS_FORCE_KILLED[@]}"
