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

usage() {
  echo "Usage: bash evaluate-sprint.sh <project_dir> <script_dir> <sprint_num> [last_commit]"
  echo ""
  echo "Read sprint summary JSON (or construct from git log), update conductor state."
  echo "Closes the sprint tmux window if still open. Runs quality gate check and"
  echo "appends [QUALITY GATE FAILED] to the summary if tests fail."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory (contains .autonomous/)"
  echo "  script_dir    Path to the autonomous-skill root (contains scripts/)"
  echo "  sprint_num    Sprint number (e.g., 1, 2, 3)"
  echo "  last_commit   Optional last known commit hash before sprint started;"
  echo "                used to detect new commits when summary file is missing"
  echo ""
  echo "Output (for eval):"
  echo "  STATUS=<complete|partial|blocked|unknown>"
  echo "  SUMMARY=<text>"
  echo "  DIR_COMPLETE=<true|false>"
  echo "  PHASE=<directed|exploring>"
  echo "  QG_PASSED=<true|false>"
  echo ""
  echo "Examples:"
  echo "  bash evaluate-sprint.sh /path/to/project /path/to/autonomous-skill 1"
  echo "  bash evaluate-sprint.sh . \$SCRIPT_DIR 3 abc1234"
  echo "  eval \"\$(bash evaluate-sprint.sh /project /skill 2)\""
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

PROJECT_DIR="${1:?Usage: evaluate-sprint.sh <project_dir> <script_dir> <sprint_num>}"
SCRIPT_DIR="${2:?Usage: evaluate-sprint.sh <project_dir> <script_dir> <sprint_num>}"
SPRINT_NUM="${3:?Usage: evaluate-sprint.sh <project_dir> <script_dir> <sprint_num>}"
LAST_COMMIT="${4:-}"

log_init "$PROJECT_DIR"
log_info "Evaluating sprint $SPRINT_NUM"

# Clean up any tmp files on exit
trap 'rm -f "$PROJECT_DIR/.autonomous/sprint-summary.json.tmp" 2>/dev/null || true' EXIT

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
  # Read all fields in a single python3 call to avoid inconsistent state from partial corruption
  if PARSED=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get('status', 'unknown'))
    print(json.dumps(d.get('commits', [])))
    print(str(d.get('direction_complete', False)).lower())
    # Summary last (may contain newlines in theory)
    print(d.get('summary', 'No summary'))
except Exception:
    sys.exit(1)
" "$SUMMARY_FILE" 2>/dev/null); then
    STATUS=$(echo "$PARSED" | sed -n '1p')
    COMMITS=$(echo "$PARSED" | sed -n '2p')
    DIR_COMPLETE=$(echo "$PARSED" | sed -n '3p')
    SUMMARY=$(echo "$PARSED" | sed -n '4p')
  else
    # JSON corrupt or python3 failed — fall through to git-based fallback
    STATUS=""
  fi
  # If parsing failed (empty status), use the git-based fallback below
  if [ -z "$STATUS" ]; then
    STATUS="unknown"
    LATEST=$(git log --oneline -1 2>/dev/null || echo "")
    if [ -n "$LAST_COMMIT" ] && [ "$LATEST" != "$LAST_COMMIT" ]; then
      SUMMARY="Sprint completed with new commits (corrupt summary file)."
      COMMITS=$(git log --oneline -5 2>/dev/null | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null || echo "[]")
      STATUS="complete"
    else
      SUMMARY="Sprint completed with no new commits (corrupt summary file)."
      COMMITS="[]"
      STATUS="partial"
    fi
    DIR_COMPLETE="false"
  fi
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

# Run quality gate (non-blocking — failure is recorded but doesn't stop evaluation)
QG_PASSED=""
if bash "$SCRIPT_DIR/scripts/quality-gate.sh" "$PROJECT_DIR" >/dev/null 2>&1; then
  QG_PASSED="true"
else
  # Exit code 1 means tests failed; quality-gate.sh exits 0 for "no test command"
  # so we only get here when tests actually ran and failed
  QG_PASSED="false"
  log_warn "Quality gate failed for sprint $SPRINT_NUM"
  SUMMARY="$SUMMARY [QUALITY GATE FAILED]"
fi

# Update conductor state
PHASE=$(bash "$SCRIPT_DIR/scripts/conductor-state.sh" sprint-end "$PROJECT_DIR" "$STATUS" "$SUMMARY" "$COMMITS" "$DIR_COMPLETE" "$QG_PASSED")

log_info "Sprint $SPRINT_NUM result: status=$STATUS phase=$PHASE qg=$QG_PASSED"

echo "STATUS=$STATUS"
echo "SUMMARY=$SUMMARY"
echo "DIR_COMPLETE=$DIR_COMPLETE"
echo "PHASE=$PHASE"
echo "QG_PASSED=$QG_PASSED"
echo "Phase after sprint $SPRINT_NUM: $PHASE" >&2
