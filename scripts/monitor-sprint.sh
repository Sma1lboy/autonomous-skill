#!/bin/bash
# monitor-sprint.sh — Poll for sprint completion via summary file + tmux liveness
#
# Usage: bash monitor-sprint.sh <project_dir> <sprint_num>
#
# Blocks until sprint-summary.json appears or sprint window/process exits.
# Output: Prints sprint summary content when found.

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

  # Check if sprint tmux window is still alive
  if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
    if ! tmux list-windows 2>/dev/null | grep -q "sprint-$SPRINT_NUM"; then
      echo "=== SPRINT $SPRINT_NUM WINDOW CLOSED ==="
      # Grab generic summary if written before exit
      [ -f "$GENERIC_FILE" ] && cp "$GENERIC_FILE" "$SUMMARY_FILE"
      break
    fi
  fi

  sleep 8
done
