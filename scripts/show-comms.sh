#!/bin/bash
# show-comms.sh — Display archived comms logs from past sprints
#
# Usage: bash show-comms.sh <project_dir> <sprint_num>
#        bash show-comms.sh <project_dir> --list
#
# Reads .autonomous/comms-archive/sprint-{N}.json and pretty-prints it.
# --list shows all archived sprint numbers.

set -euo pipefail

show_help() {
  echo "Usage: bash show-comms.sh <project_dir> <sprint_num>"
  echo "       bash show-comms.sh <project_dir> --list"
  echo ""
  echo "Display archived comms logs from .autonomous/comms-archive/."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory"
  echo "  sprint_num    Sprint number to display"
  echo "  --list        List all archived sprint numbers"
  echo ""
  echo "Examples:"
  echo "  bash show-comms.sh /path/to/project 3"
  echo "  bash show-comms.sh /path/to/project --list"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: show-comms.sh <project_dir> <sprint_num|--list>}"
ACTION="${2:?Usage: show-comms.sh <project_dir> <sprint_num|--list>}"

ARCHIVE_DIR="$PROJECT_DIR/.autonomous/comms-archive"

if [ "$ACTION" = "--list" ]; then
  if [ ! -d "$ARCHIVE_DIR" ]; then
    echo "No comms archive found." >&2
    exit 1
  fi
  echo "Archived sprints:"
  for f in "$ARCHIVE_DIR"/sprint-*.json; do
    [ -f "$f" ] || continue
    NUM=$(basename "$f" | sed 's/sprint-//;s/\.json//')
    echo "  Sprint $NUM"
  done
  exit 0
fi

ARCHIVE_FILE="$ARCHIVE_DIR/sprint-${ACTION}.json"
if [ ! -f "$ARCHIVE_FILE" ]; then
  echo "ERROR: No comms archive for sprint $ACTION" >&2
  echo "File not found: $ARCHIVE_FILE" >&2
  exit 1
fi

python3 -c "import json; print(json.dumps(json.load(open('$ARCHIVE_FILE')), indent=2))"
