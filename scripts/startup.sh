#!/usr/bin/env bash
# startup.sh — Resolve SCRIPT_DIR, display project context
#
# Usage: eval "$(bash scripts/startup.sh [project_dir])"
#   or:  bash scripts/startup.sh [project_dir]
#
# When eval'd, exports SCRIPT_DIR. When run directly, prints project context.
# Shared by conductor (SKILL.md) and sprint master (SPRINT.md).
# Layer: shared

show_help() {
  echo "Usage: bash startup.sh [project_dir]"
  echo ""
  echo "Resolve SCRIPT_DIR and display project context (OWNER.md, git log)."
  echo "If project_dir is omitted, uses current directory."
  echo ""
  echo "Output:"
  echo "  SCRIPT_DIR=<path>   (first line, for eval)"
  echo "  Project context      (OWNER.md, branch, recent commits)"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:-$(pwd)}"

# Resolve SCRIPT_DIR — find the autonomous-skill root
_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$(dirname "$_SELF")")"

if [ ! -d "$SCRIPT_DIR/scripts" ]; then
  for dir in ~/.claude/skills/autonomous-skill ${AUTONOMOUS_SKILL_DIR:-}; do
    if [ -d "$dir/scripts" ]; then SCRIPT_DIR="$dir"; break; fi
  done
fi

echo "SCRIPT_DIR=$SCRIPT_DIR"

# Display project context
cd "$PROJECT_DIR" 2>/dev/null || true
[ -f OWNER.md ] && cat OWNER.md
echo "PROJECT: $(basename "$PROJECT_DIR")"
echo "BRANCH: $(git branch --show-current 2>/dev/null)"
git log --oneline -10 2>/dev/null
