#!/usr/bin/env bash
# loop.sh — Launcher for autonomous-skill master mind session.
# In the master mind architecture, SKILL.md IS the master.
# This script is only needed when running outside of CC's skill system
# (e.g., direct bash invocation for testing).
set -euo pipefail

PROJECT_DIR="${1:-.}"
DIRECTION="${AUTONOMOUS_DIRECTION:-${2:-}}"
MAX_ITERS="${MAX_ITERATIONS:-50}"
TIMEOUT="${CC_TIMEOUT:-900}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"

# Generate persona if missing
bash "$SCRIPT_DIR/persona.sh" "$PROJECT_DIR" >/dev/null 2>&1

OWNER=""
[ -f "$PROJECT_DIR/OWNER.md" ] && OWNER=$(cat "$PROJECT_DIR/OWNER.md")

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
