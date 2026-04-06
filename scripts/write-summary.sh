#!/usr/bin/env bash
# write-summary.sh — Write sprint-summary.json from git state
#
# Usage: bash write-summary.sh <project_dir> <status> <summary> [iterations] [direction_complete] [sprint_num]
#
# Generates sprint-summary.json with recent commits from git log.
# If sprint_num is provided, archives comms.json to comms-archive/sprint-{N}.json.
# Layer: sprint-master

set -euo pipefail

usage() {
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
  echo "  sprint_num          Sprint number (optional; archives comms.json and"
  echo "                      per-worker comms-worker-*.json files if provided)"
  echo ""
  echo "Examples:"
  echo "  bash write-summary.sh /path/to/project complete \"Added REST endpoints and tests\""
  echo "  bash write-summary.sh . partial \"Refactored auth module\" 3 false"
  echo "  bash write-summary.sh /project complete \"Built user dashboard\" 2 true 5"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

PROJECT_DIR="${1:?Usage: bash write-summary.sh <project_dir> <status> <summary> [iterations] [direction_complete] [sprint_num]}"
STATUS="${2:?Usage: bash write-summary.sh <project_dir> <status> <summary> [iterations] [direction_complete] [sprint_num]}"
SUMMARY="${3:?Usage: bash write-summary.sh <project_dir> <status> <summary> [iterations] [direction_complete] [sprint_num]}"
ITERATIONS="${4:-1}"
DIR_COMPLETE="${5:-true}"
SPRINT_NUM="${6:-}"

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# Clean up tmp file on exit
trap 'rm -f "$PROJECT_DIR/.autonomous/sprint-summary.json.tmp" 2>/dev/null || true' EXIT

log_init "$PROJECT_DIR"

cd "$PROJECT_DIR"

if ! python3 -c "
import json, subprocess, sys

commits = subprocess.run(['git', 'log', '--oneline', '-10'], capture_output=True, text=True).stdout.strip().split('\n')
recent = [c for c in commits[:5] if c]

summary = {
    'status': sys.argv[1],
    'commits': recent,
    'summary': sys.argv[2],
    'iterations_used': int(sys.argv[3]),
    'direction_complete': sys.argv[4].lower() == 'true'
}

tmp = '.autonomous/sprint-summary.json.tmp'
with open(tmp, 'w') as f:
    json.dump(summary, f, indent=2)
import os; os.replace(tmp, '.autonomous/sprint-summary.json')
print(json.dumps(summary, indent=2))
" "$STATUS" "$SUMMARY" "$ITERATIONS" "$DIR_COMPLETE"; then
  # python3 failed — write minimal fallback so conductor doesn't hang forever
  log_error "python3 failed in write-summary.sh — writing fallback summary"
  echo "WARNING: write-summary.sh python3 failed — check that python3 is installed and working (try: python3 --version). Writing fallback summary" >&2
  mkdir -p .autonomous
  cat > .autonomous/sprint-summary.json.tmp << FALLBACK_EOF
{"status":"blocked","commits":[],"summary":"write-summary.sh failed: python3 error","iterations_used":0,"direction_complete":false}
FALLBACK_EOF
  mv -f .autonomous/sprint-summary.json.tmp .autonomous/sprint-summary.json
fi

log_info "Sprint summary written: status=$STATUS"

# Archive comms.json for this sprint
if [ -n "$SPRINT_NUM" ] && [ -f "$PROJECT_DIR/.autonomous/comms.json" ]; then
  mkdir -p "$PROJECT_DIR/.autonomous/comms-archive" && chmod 700 "$PROJECT_DIR/.autonomous/comms-archive"
  cp "$PROJECT_DIR/.autonomous/comms.json" "$PROJECT_DIR/.autonomous/comms-archive/sprint-${SPRINT_NUM}.json"
fi

# Archive per-worker comms files (comms-worker-*.json)
if [ -n "$SPRINT_NUM" ]; then
  for wf in "$PROJECT_DIR"/.autonomous/comms-worker-*.json; do
    [ -f "$wf" ] || continue
    mkdir -p "$PROJECT_DIR/.autonomous/comms-archive" && chmod 700 "$PROJECT_DIR/.autonomous/comms-archive"
    # Extract worker-id: comms-worker-{id}.json -> worker-{id}
    BASENAME=$(basename "$wf" .json)
    WID="${BASENAME#comms-}"
    cp "$wf" "$PROJECT_DIR/.autonomous/comms-archive/sprint-${SPRINT_NUM}-${WID}.json"
  done
fi

# Kill registered worker windows
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SELF_DIR/cleanup-workers.sh" "$PROJECT_DIR"
