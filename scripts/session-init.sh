#!/usr/bin/env bash
# session-init.sh — Create session branch, init conductor state + backlog
#
# Usage: bash session-init.sh <project_dir> <script_dir> <direction> <max_sprints>
#
# Output: SESSION_BRANCH=<branch_name>
# Layer: conductor

set -euo pipefail

usage() {
  echo "Usage: bash session-init.sh <project_dir> <script_dir> <direction> <max_sprints>"
  echo ""
  echo "Create a session branch, initialize conductor state and backlog."
  echo "Checks out a new auto/session-<timestamp> branch, initializes"
  echo "conductor-state.json, and prunes stale backlog items."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory to create session in"
  echo "  script_dir    Path to the autonomous-skill root (contains scripts/)"
  echo "  direction     Sprint direction / mission statement (can be empty for exploration)"
  echo "  max_sprints   Maximum number of sprints for this session (default: 10)"
  echo ""
  echo "Output: SESSION_BRANCH=auto/session-<timestamp>"
  echo ""
  echo "Examples:"
  echo "  bash session-init.sh /path/to/project /path/to/autonomous-skill \"build REST API\" 5"
  echo "  bash session-init.sh . \$SCRIPT_DIR \"\" 10"
  echo "  eval \"\$(bash session-init.sh /project /skill 'fix auth bug' 3)\""
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

PROJECT_DIR="${1:?Usage: session-init.sh <project_dir> <script_dir> <direction> <max_sprints>}"
SCRIPT_DIR="${2:?Usage: session-init.sh <project_dir> <script_dir> <direction> <max_sprints>}"
DIRECTION="${3:-}"
MAX_SPRINTS="${4:-10}"

cd "$PROJECT_DIR"

SESSION_BRANCH="auto/session-$(date +%s)"
git checkout -b "$SESSION_BRANCH"
mkdir -p .autonomous && chmod 700 .autonomous

bash "$SCRIPT_DIR/scripts/conductor-state.sh" init "$PROJECT_DIR" "$DIRECTION" "$MAX_SPRINTS"

# Initialize backlog (idempotent — preserves existing cross-session backlog)
bash "$SCRIPT_DIR/scripts/backlog.sh" init "$PROJECT_DIR"
# Prune stale items at session start
bash "$SCRIPT_DIR/scripts/backlog.sh" prune "$PROJECT_DIR" 30 2>/dev/null || true

echo "SESSION_BRANCH=$SESSION_BRANCH"
