#!/usr/bin/env bash
# merge-sprint.sh — Merge or discard a sprint branch
#
# Usage: bash merge-sprint.sh <session_branch> <sprint_branch> <sprint_num> <status> <summary>
#
# Switches to session branch, merges if sprint had commits, cleans up sprint branch.
# Layer: conductor

set -euo pipefail

usage() {
  echo "Usage: bash merge-sprint.sh <session_branch> <sprint_branch> <sprint_num> <status> <summary>"
  echo ""
  echo "Merge sprint branch into session branch (if commits exist), then clean up."
  echo "Only merges for 'complete' or 'partial' status; otherwise discards."
  echo "Deletes the sprint branch after merge or discard."
  echo ""
  echo "Arguments:"
  echo "  session_branch  Session branch to merge into (e.g., auto/session-1234567890)"
  echo "  sprint_branch   Sprint branch to merge from (e.g., auto/session-1234567890-sprint-1)"
  echo "  sprint_num      Sprint number (e.g., 1, 2, 3)"
  echo "  status          Sprint result: complete | partial | blocked | unknown"
  echo "  summary         One-line summary for the merge commit message"
  echo ""
  echo "Examples:"
  echo "  bash merge-sprint.sh auto/session-123 auto/session-123-sprint-1 1 complete \"added REST endpoints\""
  echo "  bash merge-sprint.sh auto/session-123 auto/session-123-sprint-2 2 blocked \"rate limited\""
  echo "  bash merge-sprint.sh auto/session-123 auto/session-123-sprint-3 3 partial \"partial refactor\""
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

SESSION_BRANCH="${1:?Usage: merge-sprint.sh <session_branch> <sprint_branch> <sprint_num> <status> <summary>}"
SPRINT_BRANCH="${2:?Usage: merge-sprint.sh <session_branch> <sprint_branch> <sprint_num> <status> <summary>}"
SPRINT_NUM="${3:?Usage: merge-sprint.sh <session_branch> <sprint_branch> <sprint_num> <status> <summary>}"
STATUS="${4:?Usage: merge-sprint.sh <session_branch> <sprint_branch> <sprint_num> <status> <summary>}"
SUMMARY="${5:-Sprint $SPRINT_NUM}"

# Switch back to conductor branch
git checkout "$SESSION_BRANCH"

if [ "$STATUS" = "complete" ] || [ "$STATUS" = "partial" ]; then
  # Merge sprint results into conductor branch
  HAS_COMMITS=$(git log "$SESSION_BRANCH".."$SPRINT_BRANCH" --oneline 2>/dev/null | head -1)
  if [ -n "$HAS_COMMITS" ]; then
    git merge --no-ff "$SPRINT_BRANCH" -m "sprint $SPRINT_NUM: $SUMMARY"
    echo "Sprint $SPRINT_NUM merged into $SESSION_BRANCH"
  else
    echo "Sprint $SPRINT_NUM had no commits, skipping merge"
  fi
else
  echo "Sprint $SPRINT_NUM discarded ($STATUS)"
fi

# Clean up sprint branch
git branch -D "$SPRINT_BRANCH" 2>/dev/null || true
