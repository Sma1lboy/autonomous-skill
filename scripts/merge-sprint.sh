#!/bin/bash
# merge-sprint.sh — Merge or discard a sprint branch
#
# Usage: bash merge-sprint.sh <session_branch> <sprint_branch> <sprint_num> <status> <summary>
#
# Switches to session branch, merges if sprint had commits, cleans up sprint branch.

set -euo pipefail

show_help() {
  echo "Usage: bash merge-sprint.sh <session_branch> <sprint_branch> <sprint_num> <status> <summary>"
  echo ""
  echo "Merge sprint branch into session branch (if commits exist), then clean up."
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
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
