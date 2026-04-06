#!/bin/bash
# session-init.sh — Create session branch, init conductor state + backlog
#
# Usage: bash session-init.sh <project_dir> <script_dir> <direction> <max_sprints>
#
# Output: SESSION_BRANCH=<branch_name>

set -euo pipefail

show_help() {
  echo "Usage: bash session-init.sh <project_dir> <script_dir> <direction> <max_sprints>"
  echo ""
  echo "Create a session branch, initialize conductor state and backlog."
  echo ""
  echo "Output: SESSION_BRANCH=auto/session-<timestamp>"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: session-init.sh <project_dir> <script_dir> <direction> <max_sprints>}"
SCRIPT_DIR="${2:?Usage: session-init.sh <project_dir> <script_dir> <direction> <max_sprints>}"
DIRECTION="${3:-}"
MAX_SPRINTS="${4:-10}"

cd "$PROJECT_DIR"

SESSION_BRANCH="auto/session-$(date +%s)"
git checkout -b "$SESSION_BRANCH"
mkdir -p .autonomous

bash "$SCRIPT_DIR/scripts/conductor-state.sh" init "$PROJECT_DIR" "$DIRECTION" "$MAX_SPRINTS"

# Initialize backlog (idempotent — preserves existing cross-session backlog)
bash "$SCRIPT_DIR/scripts/backlog.sh" init "$PROJECT_DIR"
# Prune stale items at session start
bash "$SCRIPT_DIR/scripts/backlog.sh" prune "$PROJECT_DIR" 30 2>/dev/null || true

echo "SESSION_BRANCH=$SESSION_BRANCH"
