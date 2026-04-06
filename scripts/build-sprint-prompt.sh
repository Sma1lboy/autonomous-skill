#!/bin/bash
# build-sprint-prompt.sh — Build sprint-prompt.md by inlining SPRINT.md + params
#
# Usage: bash build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction> [prev_summary]
#
# Output: writes .autonomous/sprint-prompt.md

set -euo pipefail

show_help() {
  echo "Usage: bash build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction> [prev_summary]"
  echo ""
  echo "Build the sprint master prompt by inlining SPRINT.md with sprint parameters."
  echo "Writes to <project_dir>/.autonomous/sprint-prompt.md"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction>}"
SCRIPT_DIR="${2:?Usage: build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction>}"
SPRINT_NUM="${3:?Usage: build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction>}"
SPRINT_DIRECTION="${4:?Usage: build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction>}"
PREV_SUMMARY="${5:-}"

if [ ! -f "$SCRIPT_DIR/SPRINT.md" ]; then
  echo "ERROR: SPRINT.md not found at $SCRIPT_DIR/SPRINT.md" >&2
  exit 1
fi

# Get title-only backlog for sprint master context (lightweight, no descriptions)
BACKLOG_TITLES=$(bash "$SCRIPT_DIR/scripts/backlog.sh" list "$PROJECT_DIR" open titles-only 2>/dev/null || echo "")

# Use printf instead of echo — echo mangles content starting with -n/-e or containing \c
{
  printf '%s\n' "You are a sprint master. Follow the instructions below exactly."
  printf '\n'
  printf '%s\n' "SCRIPT_DIR: $SCRIPT_DIR"
  printf '%s\n' "PROJECT: $PROJECT_DIR"
  printf '%s\n' "SPRINT_NUMBER: $SPRINT_NUM"
  printf '%s\n' "SPRINT_DIRECTION: $SPRINT_DIRECTION"
  printf '%s\n' "PREVIOUS_SUMMARY: $PREV_SUMMARY"
  printf '%s\n' "BACKLOG_TITLES: $BACKLOG_TITLES"
  printf '\n'
  cat "$SCRIPT_DIR/SPRINT.md"
} > "$PROJECT_DIR/.autonomous/sprint-prompt.md"

echo "Sprint prompt written to $PROJECT_DIR/.autonomous/sprint-prompt.md"
