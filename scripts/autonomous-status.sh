#!/usr/bin/env bash
# autonomous-status.sh — Quick status check for autonomous sessions.
# Reads .autonomous/progress.json and prints current state.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: autonomous-status.sh <project-dir> [--json]

Print current autonomous session status from .autonomous/progress.json.
If no active session, prints "No active session".

Arguments:
  project-dir    Project directory containing .autonomous/

Options:
  --json         Output raw JSON instead of human-readable text
  -h, --help     Show this help message

Examples:
  bash scripts/autonomous-status.sh ./my-project
  bash scripts/autonomous-status.sh ./my-project --json
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || die "python3 required but not found"

# ── Parse arguments ──────────────────────────────────────────────────────

PROJECT=""
JSON_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --json) JSON_MODE=true; shift ;;
    *)
      if [ -z "$PROJECT" ]; then
        PROJECT="$1"
      fi
      shift
      ;;
  esac
done

[ -z "$PROJECT" ] && die "Usage: autonomous-status.sh <project-dir> [--json]"

PROGRESS_FILE="$PROJECT/.autonomous/progress.json"

# ── No session ───────────────────────────────────────────────────────────

if [ ! -f "$PROGRESS_FILE" ]; then
  if [ "$JSON_MODE" = true ]; then
    echo '{"status":"no_session"}'
  else
    echo "No active session"
  fi
  exit 0
fi

# ── JSON mode ────────────────────────────────────────────────────────────

if [ "$JSON_MODE" = true ]; then
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(json.dumps(d, indent=2))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
    sys.exit(1)
" "$PROGRESS_FILE"
  exit 0
fi

# ── Human-readable mode ─────────────────────────────────────────────────

python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    current = d.get('current_sprint', 0)
    total = d.get('total_sprints', 0)
    phase = d.get('phase', 'unknown')
    commits = d.get('commits_so_far', 0)
    last = d.get('last_sprint_summary', '')
    if len(last) > 60:
        last = last[:57] + '...'

    print(f'Autonomous session: Sprint {current}/{total} ({phase} phase)')
    print(f'Commits so far: {commits}')
    if last:
        print(f'Last sprint: {last}')
    etr = d.get('estimated_time_remaining')
    if etr is not None:
        print(f'ETA: {etr}')
except Exception as e:
    print(f'Error reading progress: {e}', file=sys.stderr)
    sys.exit(1)
" "$PROGRESS_FILE"
