#!/usr/bin/env bash
# loop.sh — Launcher for autonomous-skill master mind session.
# In the master mind architecture, SKILL.md IS the master.
# This script is only needed when running outside of CC's skill system
# (e.g., direct bash invocation for testing).
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat << 'EOF'
Usage: loop.sh [project-dir] [direction]

Standalone launcher for autonomous-skill. Starts a conductor session
that autonomously improves the target project.

Arguments:
  project-dir   Path to the git repo to work on (default: current directory)
  direction     What to focus on (e.g., "build REST API", "fix auth bugs")

Environment variables:
  AUTONOMOUS_DIRECTION   Session focus (overrides direction argument)
  MAX_ITERATIONS         Max iterations per session (default: 50)
  CC_TIMEOUT             Timeout per claude invocation in seconds (default: 900)

Examples:
  bash scripts/loop.sh /path/to/project
  bash scripts/loop.sh . "fix all auth bugs"
  AUTONOMOUS_DIRECTION="add tests" bash scripts/loop.sh /path/to/project
  MAX_ITERATIONS=25 bash scripts/loop.sh .

Inside Claude Code, use /autonomous-skill instead:
  /autonomous-skill 5 build REST API
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

PROJECT_DIR="${1:-.}"
DIRECTION="${AUTONOMOUS_DIRECTION:-${2:-}}"
MAX_ITERS="${MAX_ITERATIONS:-50}"
TIMEOUT="${CC_TIMEOUT:-900}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# Validate prerequisites
[ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR
  Provide a valid path to a git repository as the first argument."
command -v claude &>/dev/null || die "claude CLI not found in PATH
  Install Claude Code: https://docs.anthropic.com/en/docs/claude-code"
command -v timeout &>/dev/null || die "timeout command not found in PATH
  On macOS: brew install coreutils"
[ -f "$SKILL_DIR/SKILL.md" ] || die "SKILL.md not found at $SKILL_DIR/SKILL.md
  Ensure autonomous-skill is properly installed. See README.md for setup."
[[ "$MAX_ITERS" =~ ^[0-9]+$ ]] || die "MAX_ITERATIONS must be a positive integer, got: $MAX_ITERS"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "CC_TIMEOUT must be a positive integer, got: $TIMEOUT"

# Generate persona if missing
bash "$SCRIPT_DIR/persona.sh" "$PROJECT_DIR" >/dev/null 2>&1

OWNER=""
[ -f "$SCRIPT_DIR/../OWNER.md" ] && OWNER=$(cat "$SCRIPT_DIR/../OWNER.md")

# Build the master prompt — just point CC at the SKILL.md identity
PROMPT="You are the autonomous master mind for this project.
Your identity and instructions are defined in SKILL.md at $SKILL_DIR/SKILL.md.
Read it, then begin your loop. Direction: ${DIRECTION:-explore freely}. Max iterations: $MAX_ITERS."

echo "═══════════════════════════════════════════════════"
echo "  Autonomous Skill (direct launch)"
echo "  Project: $(basename "$PROJECT_DIR")"
[ -n "$DIRECTION" ] && echo "  Direction: $DIRECTION"
echo "  Max iterations: $MAX_ITERS"
echo "═══════════════════════════════════════════════════"

exec timeout "$TIMEOUT" claude -p "$PROMPT" \
  --dangerously-skip-permissions \
  --output-format stream-json \
  --verbose \
  ${OWNER:+--append-system-prompt "$OWNER"} \
  < /dev/null
