#!/usr/bin/env bash
# cleanup-workers.sh — Kill registered tmux worker windows and remove the tracking file
# Layer: shared
#
# Usage: bash cleanup-workers.sh <project_dir>
#
# Reads .autonomous/worker-windows.txt, kills each tmux window, removes the file.
# No-op if the file doesn't exist or tmux is not available.

usage() {
  echo "Usage: bash cleanup-workers.sh <project_dir>"
  echo ""
  echo "Kill registered tmux worker windows and remove the tracking file."
  echo "Reads .autonomous/worker-windows.txt, kills each tmux window listed,"
  echo "then removes the file. No-op if the file doesn't exist or tmux is"
  echo "not available."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory containing .autonomous/worker-windows.txt"
  echo ""
  echo "Examples:"
  echo "  bash cleanup-workers.sh /path/to/project"
  echo "  bash cleanup-workers.sh ."
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

PROJECT_DIR="${1:?Usage: cleanup-workers.sh <project_dir>}"

if [ -f "$PROJECT_DIR/.autonomous/worker-windows.txt" ]; then
  if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
    while IFS= read -r win; do
      tmux kill-window -t "$win" 2>/dev/null || true
    done < "$PROJECT_DIR/.autonomous/worker-windows.txt"
  fi
  rm -f "$PROJECT_DIR/.autonomous/worker-windows.txt"
fi
