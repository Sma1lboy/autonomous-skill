#!/usr/bin/env bash
# progress-reporter.sh — Progress reporting for autonomous sessions.
# Reads conductor-state.json and writes/reads .autonomous/progress.json.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: progress-reporter.sh <command> <project-dir>

Progress reporting for autonomous sessions. Reads conductor-state.json
and writes/reads .autonomous/progress.json for external consumers.

Commands:
  update <project-dir>
      Read conductor-state.json, write progress.json with current status

  read <project-dir>
      Read progress.json and print it as JSON

  --watch <project-dir>
      Loop every 5s, printing human-readable one-line status.
      Exit when all sprints done or progress.json disappears.

Options:
  -h, --help     Show this help message

Examples:
  bash scripts/progress-reporter.sh update ./my-project
  bash scripts/progress-reporter.sh read ./my-project
  bash scripts/progress-reporter.sh --watch ./my-project
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || die "python3 required but not found"

CMD="${1:-}"
PROJECT="${2:-.}"
STATE_DIR="$PROJECT/.autonomous"
STATE_FILE="$STATE_DIR/conductor-state.json"
PROGRESS_FILE="$STATE_DIR/progress.json"

# Atomic write: write to tmp, then mv
atomic_write() {
  local file="$1" content="$2"
  local tmp="${file}.tmp.$$"
  echo "$content" > "$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null || true
    die "atomic_write failed: tmp file empty or missing after write"
  fi
  mv -f "$tmp" "$file"
}

cmd_update() {
  [ -z "$PROJECT" ] && die "Usage: progress-reporter.sh update <project-dir>"

  if [ ! -f "$STATE_FILE" ]; then
    die "No conductor-state.json found at $STATE_FILE"
  fi

  mkdir -p "$STATE_DIR"

  local progress
  progress=$(python3 -c "
import json, sys

state_file = sys.argv[1]
try:
    with open(state_file) as f:
        d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(json.dumps({'error': str(e)}))
    sys.exit(1)

sprints = d.get('sprints', [])
max_sprints = d.get('max_sprints', 0)
phase = d.get('phase', 'unknown')
current_sprint = len(sprints)
total_commits = sum(len(s.get('commits', [])) for s in sprints)

# Last completed sprint summary
last_summary = ''
for s in reversed(sprints):
    if s.get('summary', ''):
        last_summary = s['summary']
        break

progress = {
    'current_sprint': current_sprint,
    'total_sprints': max_sprints,
    'phase': phase,
    'last_sprint_summary': last_summary,
    'commits_so_far': total_commits,
    'estimated_time_remaining': None
}
print(json.dumps(progress))
" "$STATE_FILE") || die "Failed to read conductor state"

  atomic_write "$PROGRESS_FILE" "$progress"
  echo "ok"
}

cmd_read() {
  [ -z "$PROJECT" ] && die "Usage: progress-reporter.sh read <project-dir>"

  if [ ! -f "$PROGRESS_FILE" ]; then
    die "No progress.json found at $PROGRESS_FILE"
  fi

  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(json.dumps(d, indent=2))
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
    sys.exit(1)
" "$PROGRESS_FILE"
}

cmd_watch() {
  [ -z "$PROJECT" ] && die "Usage: progress-reporter.sh --watch <project-dir>"

  while true; do
    # Exit if progress.json disappears
    if [ ! -f "$PROGRESS_FILE" ]; then
      echo "No progress data — session may have ended."
      exit 0
    fi

    # Print one-line status
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
    if len(last) > 50:
        last = last[:47] + '...'
    if last:
        print(f'Sprint {current}/{total} | {phase} | {commits} commits | last: {last}')
    else:
        print(f'Sprint {current}/{total} | {phase} | {commits} commits')
except Exception as e:
    print(f'Error reading progress: {e}', file=sys.stderr)
" "$PROGRESS_FILE"

    # Check if all sprints are done
    if [ -f "$STATE_FILE" ]; then
      local all_complete
      all_complete=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    sprints = d.get('sprints', [])
    max_s = d.get('max_sprints', 0)
    all_done = len(sprints) >= max_s and all(
        s.get('status') in ('complete', 'failed', 'skipped')
        for s in sprints
    )
    print('true' if all_done else 'false')
except Exception:
    print('false')
" "$STATE_FILE" 2>/dev/null) || all_complete="false"
      if [ "$all_complete" = "true" ]; then
        echo "All sprints complete."
        exit 0
      fi
    fi

    sleep 5
  done
}

# ── Dispatch ──────────────────────────────────────────────────────────────

case "$CMD" in
  update)   cmd_update ;;
  read)     cmd_read ;;
  --watch)  cmd_watch ;;
  *)        die "Unknown command: $CMD. Use: update|read|--watch" ;;
esac
