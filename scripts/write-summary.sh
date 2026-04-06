#!/bin/bash
# write-summary.sh — Write sprint-summary.json from git state
#
# Usage: bash write-summary.sh <project_dir> <status> <summary> [iterations] [direction_complete] [sprint_num]
#
# Generates sprint-summary.json with recent commits from git log.
# If sprint_num is provided, archives comms.json to comms-archive/sprint-{N}.json.

set -euo pipefail

show_help() {
  echo "Usage: bash write-summary.sh <project_dir> <status> <summary> [iterations] [direction_complete] [sprint_num]"
  echo ""
  echo "Write sprint-summary.json with recent commits and sprint results."
  echo ""
  echo "Arguments:"
  echo "  project_dir         Project directory"
  echo "  status              complete | partial | blocked"
  echo "  summary             2-3 sentence summary of what was accomplished"
  echo "  iterations          Number of iterations used (default: 1)"
  echo "  direction_complete  true | false (default: true)"
  echo "  sprint_num          Sprint number (optional; archives comms.json if provided)"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: write-summary.sh <project_dir> <status> <summary>}"
STATUS="${2:?Usage: write-summary.sh <project_dir> <status> <summary>}"
SUMMARY="${3:?Usage: write-summary.sh <project_dir> <status> <summary>}"
ITERATIONS="${4:-1}"
DIR_COMPLETE="${5:-true}"
SPRINT_NUM="${6:-}"

cd "$PROJECT_DIR"

python3 -c "
import json, subprocess

commits = subprocess.run(['git', 'log', '--oneline', '-10'], capture_output=True, text=True).stdout.strip().split('\n')
recent = [c for c in commits[:5] if c]

summary = {
    'status': '$STATUS',
    'commits': recent,
    'summary': '''$SUMMARY''',
    'iterations_used': $ITERATIONS,
    'direction_complete': $DIR_COMPLETE
}

with open('.autonomous/sprint-summary.json', 'w') as f:
    json.dump(summary, f, indent=2)
print(json.dumps(summary, indent=2))
"

# Archive comms.json for this sprint
if [ -n "$SPRINT_NUM" ] && [ -f "$PROJECT_DIR/.autonomous/comms.json" ]; then
  mkdir -p "$PROJECT_DIR/.autonomous/comms-archive"
  cp "$PROJECT_DIR/.autonomous/comms.json" "$PROJECT_DIR/.autonomous/comms-archive/sprint-${SPRINT_NUM}.json"
fi

# Kill registered worker windows
if [ -f "$PROJECT_DIR/.autonomous/worker-windows.txt" ]; then
  if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
    while IFS= read -r win; do
      tmux kill-window -t "$win" 2>/dev/null || true
    done < "$PROJECT_DIR/.autonomous/worker-windows.txt"
  fi
  rm -f "$PROJECT_DIR/.autonomous/worker-windows.txt"
fi
