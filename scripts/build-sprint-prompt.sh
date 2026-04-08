#!/bin/bash
# build-sprint-prompt.sh — Build sprint-prompt.md by inlining SPRINT.md + params
#
# Usage: bash build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction> [prev_summary]
#
# Output: writes .autonomous/sprint-prompt.md

set -euo pipefail

show_help() {
  echo "Usage: bash build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction> [prev_summary]"
  echo ""
  echo "Build the sprint master prompt by inlining SPRINT.md with sprint parameters."
  echo "Writes to <project_dir>/.autonomous/sprint-prompt.md"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction>}"
SCRIPT_DIR="${2:?Usage: build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction>}"
SPRINT_NUM="${3:?Usage: build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction>}"
SPRINT_DIRECTION="${4:?Usage: build-sprint-prompt.sh <project_dir> <script_dir> <sprint_num> <direction>}"
PREV_SUMMARY="${5:-}"

if [ ! -f "$SCRIPT_DIR/SPRINT.md" ]; then
  echo "ERROR: SPRINT.md not found at $SCRIPT_DIR/SPRINT.md" >&2
  exit 1
fi

# Get title-only backlog for sprint master context (lightweight, no descriptions)
BACKLOG_TITLES=$(bash "$SCRIPT_DIR/scripts/backlog.sh" list "$PROJECT_DIR" open titles-only 2>/dev/null || echo "")

# ── Template resolution ──────────────────────────────────────────────────
# Hierarchy: $PROJECT_DIR/.autonomous/skill-config.json overrides
#            $SCRIPT_DIR/skill-config.json. Falls back to "default".
TEMPLATE_NAME=$(python3 -c "
import json, sys
def load(p):
    try:
        with open(p) as f:
            d = json.load(f)
        v = d.get('template')
        return v if isinstance(v, str) and v else None
    except Exception:
        return None
proj = load(sys.argv[1])
root = load(sys.argv[2])
print(proj or root or 'default')
" "$PROJECT_DIR/.autonomous/skill-config.json" "$SCRIPT_DIR/skill-config.json")

# Path-traversal guard: reject slashes and dot-prefixes
case "$TEMPLATE_NAME" in
  */*|.*) TEMPLATE_NAME="default" ;;
esac

# Resolve template file: requested -> default -> empty (handled in renderer)
TEMPLATE_FILE="$SCRIPT_DIR/templates/$TEMPLATE_NAME/template.md"
if [ ! -f "$TEMPLATE_FILE" ]; then
  [ "$TEMPLATE_NAME" != "default" ] && echo "WARN: template '$TEMPLATE_NAME' not found, using default" >&2
  TEMPLATE_FILE="$SCRIPT_DIR/templates/default/template.md"
fi
[ -f "$TEMPLATE_FILE" ] || TEMPLATE_FILE=""

# Use printf instead of echo — echo mangles content starting with -n/-e or containing \c
{
  printf '%s\n' "You are a sprint master. Follow the instructions below exactly."
  printf '\n'
  printf '%s\n' "SCRIPT_DIR: $SCRIPT_DIR"
  printf '%s\n' "OWNER_FILE: $SCRIPT_DIR/OWNER.md"
  printf '%s\n' "PROJECT: $PROJECT_DIR"
  printf '%s\n' "SPRINT_NUMBER: $SPRINT_NUM"
  printf '%s\n' "SPRINT_DIRECTION: $SPRINT_DIRECTION"
  printf '%s\n' "PREVIOUS_SUMMARY: $PREV_SUMMARY"
  printf '%s\n' "BACKLOG_TITLES: $BACKLOG_TITLES"
  printf '\n'
  python3 -c "
import sys
sprint_path = sys.argv[1]
tpl_path = sys.argv[2]

with open(sprint_path) as f:
    sprint = f.read()

def extract(body, header):
    # Walk lines; capture content between '## {header}' and next '## ' (or EOF).
    lines = body.splitlines(keepends=True)
    capturing = False
    out = []
    for line in lines:
        if line.startswith('## '):
            if capturing:
                break
            if line.strip() == '## ' + header:
                capturing = True
                continue
        elif capturing:
            out.append(line)
    return ''.join(out).strip('\n')

allow, block = '', ''
if tpl_path:
    try:
        with open(tpl_path) as f:
            tpl = f.read()
        allow = extract(tpl, 'Allow')
        block = extract(tpl, 'Block')
    except Exception:
        pass

# Replace only the first occurrence of each marker (defends against
# self-injection loops if a template ever embeds the marker itself).
sprint = sprint.replace('<!-- AUTO:TEMPLATE_ALLOW -->', allow, 1)
sprint = sprint.replace('<!-- AUTO:TEMPLATE_BLOCK -->', block, 1)
sys.stdout.write(sprint)
" "$SCRIPT_DIR/SPRINT.md" "$TEMPLATE_FILE"
} > "$PROJECT_DIR/.autonomous/sprint-prompt.md"

echo "Sprint prompt written to $PROJECT_DIR/.autonomous/sprint-prompt.md"
