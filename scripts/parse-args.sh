#!/bin/bash
# parse-args.sh — Parse skill args into MAX_SPRINTS and DIRECTION
#
# Usage: eval "$(bash parse-args.sh "$ARGS")"
#
# Output (for eval):
#   _MAX_SPRINTS=<number|unlimited>
#   _DIRECTION=<string>

show_help() {
  echo "Usage: eval \"\$(bash parse-args.sh \"\$ARGS\")\""
  echo ""
  echo "Parse autonomous-skill arguments into _MAX_SPRINTS and _DIRECTION."
  echo ""
  echo "Examples:"
  echo "  '5'              → _MAX_SPRINTS=5, _DIRECTION=''"
  echo "  '5 build REST'   → _MAX_SPRINTS=5, _DIRECTION='build REST'"
  echo "  'unlimited'      → _MAX_SPRINTS=unlimited, _DIRECTION=''"
  echo "  'fix the bug'    → _MAX_SPRINTS=5, _DIRECTION='fix the bug'"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

ARGS="${1:-}"
_DIRECTION=""
_MAX_SPRINTS="5"

if [ -n "$ARGS" ]; then
  if echo "$ARGS" | grep -qi 'unlimited'; then
    _MAX_SPRINTS="unlimited"
  elif echo "$ARGS" | grep -qE '^[0-9]+$'; then
    _MAX_SPRINTS="$ARGS"
  else
    _NUM=$(echo "$ARGS" | grep -oE '^[0-9]+' | head -1)
    if [ -n "$_NUM" ]; then
      _MAX_SPRINTS="$_NUM"
      _DIRECTION=$(echo "$ARGS" | sed "s/^$_NUM[[:space:]]*//" )
    else
      _DIRECTION="$ARGS"
    fi
  fi
else
  echo "Hint: /autonomous-skill [sprints] [mission]" >&2
  echo "  Examples: /autonomous-skill 5 build REST API" >&2
  echo "            /autonomous-skill fix auth bugs" >&2
  echo "            /autonomous-skill 3" >&2
fi

echo "_MAX_SPRINTS=$_MAX_SPRINTS"
# Use printf to safely handle special characters in direction
printf '_DIRECTION=%s\n' "$_DIRECTION"
echo "MAX_SPRINTS: $_MAX_SPRINTS" >&2
[ -n "$_DIRECTION" ] && echo "DIRECTION: $_DIRECTION" >&2
