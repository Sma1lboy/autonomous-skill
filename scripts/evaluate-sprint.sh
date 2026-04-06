#!/usr/bin/env bash
# evaluate-sprint.sh — Read sprint summary, update conductor state, close tmux
#
# Usage: bash evaluate-sprint.sh <project_dir> <script_dir> <sprint_num> [last_commit]
#
# Output (for eval):
#   STATUS=<complete|partial|blocked|unknown>
#   SUMMARY=<text>
#   DIR_COMPLETE=<true|false>
#   PHASE=<directed|exploring>
# Layer: conductor

set -euo pipefail

show_help() {
  echo "Usage: bash evaluate-sprint.sh <project_dir> <script_dir> <sprint_num> [last_commit]"
  echo ""
  echo "Read sprint summary JSON (or construct from git log), update conductor state."
  echo "Closes the sprint tmux window if still open."
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: evaluate-sprint.sh <project_dir> <script_dir> <sprint_num>}"
SCRIPT_DIR="${2:?Usage: evaluate-sprint.sh <project_dir> <script_dir> <sprint_num>}"
SPRINT_NUM="${3:?Usage: evaluate-sprint.sh <project_dir> <script_dir> <sprint_num>}"
LAST_COMMIT="${4:-}"

cd "$PROJECT_DIR"

SUMMARY_FILE=".autonomous/sprint-$SPRINT_NUM-summary.json"

# Close tmux window if still open
if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
  tmux kill-window -t "sprint-$SPRINT_NUM" 2>/dev/null || true
fi

# Kill registered worker windows
bash "$SCRIPT_DIR/scripts/cleanup-workers.sh" "$PROJECT_DIR"

# Parse summary or construct fallback
if [ -f "$SUMMARY_FILE" ]; then
  STATUS=$(python3 -c "import json; print(json.load(open('$SUMMARY_FILE')).get('status','unknown'))" 2>/dev/null || echo "unknown")
  SUMMARY=$(python3 -c "import json; print(json.load(open('$SUMMARY_FILE')).get('summary','No summary'))" 2>/dev/null || echo "No summary")
  COMMITS=$(python3 -c "import json; print(json.dumps(json.load(open('$SUMMARY_FILE')).get('commits',[])))" 2>/dev/null || echo "[]")
  DIR_COMPLETE=$(python3 -c "import json; print(str(json.load(open('$SUMMARY_FILE')).get('direction_complete',False)).lower())" 2>/dev/null || echo "false")
else
  STATUS="unknown"
  LATEST=$(git log --oneline -1 2>/dev/null || echo "")
  if [ -n "$LAST_COMMIT" ] && [ "$LATEST" != "$LAST_COMMIT" ]; then
    SUMMARY="Sprint completed with new commits (no summary file)."
    COMMITS=$(git log --oneline -5 2>/dev/null | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo "[]")
    STATUS="complete"
  else
    SUMMARY="Sprint completed with no new commits."
    COMMITS="[]"
    STATUS="partial"
  fi
  DIR_COMPLETE="false"
fi

# Update conductor state
PHASE=$(bash "$SCRIPT_DIR/scripts/conductor-state.sh" sprint-end "$PROJECT_DIR" "$STATUS" "$SUMMARY" "$COMMITS" "$DIR_COMPLETE")

echo "STATUS=$STATUS"
echo "SUMMARY=$SUMMARY"
echo "DIR_COMPLETE=$DIR_COMPLETE"
echo "PHASE=$PHASE"
echo "Phase after sprint $SPRINT_NUM: $PHASE" >&2
