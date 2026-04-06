#!/usr/bin/env bash
# retry-strategy.sh — Analyze sprint failures and suggest retry directions.
# Decides whether a failed sprint should be retried (up to 2 retries = 3-strike rule).
# Layer: conductor

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: retry-strategy.sh <command> <project-dir> [args...]

Analyze sprint failures and suggest retry directions. Implements the
3-strike rule: original attempt + 2 retries max.

Commands:
  analyze <project-dir> <sprint-num>
      Analyze a sprint's failure and decide whether to retry.
      Reads sprint summary and conductor state to determine failure type.
      Output: JSON with should_retry, reason, adjusted_direction, retry_count

  count <project-dir> <direction>
      Count how many times a similar direction has been attempted.
      Matches sprint entries with the same base direction prefix.

Examples:
  bash scripts/retry-strategy.sh analyze ./my-project 3
  bash scripts/retry-strategy.sh count ./my-project "add auth middleware"
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CMD="${1:-}"
PROJECT="${2:-.}"
STATE_DIR="$PROJECT/.autonomous"
STATE_FILE="$STATE_DIR/conductor-state.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Commands ──────────────────────────────────────────────────────────────

cmd_analyze() {
  local sprint_num="${3:-}"
  [ -z "$sprint_num" ] && die "Usage: retry-strategy.sh analyze <project-dir> <sprint-num>"
  [[ "$sprint_num" =~ ^[0-9]+$ ]] || die "sprint-num must be a positive integer, got: $sprint_num"

  # Get sprint data from conductor state
  local sprint_data
  sprint_data=$(bash "$SCRIPT_DIR/conductor-state.sh" get-sprint "$PROJECT" "$sprint_num" 2>/dev/null) || sprint_data=""

  # Read sprint summary file if it exists
  local summary_file="$STATE_DIR/sprint-${sprint_num}-summary.json"
  local summary_json="{}"
  if [ -f "$summary_file" ]; then
    summary_json=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    json.dump(d, sys.stdout)
except (json.JSONDecodeError, FileNotFoundError, Exception):
    print('{}')
" "$summary_file" 2>/dev/null) || summary_json="{}"
  fi

  python3 -c "
import json, sys

sprint_data_raw = sys.argv[1]
summary_raw = sys.argv[2]
sprint_num = int(sys.argv[3])

# Parse sprint data from conductor state
try:
    sprint = json.loads(sprint_data_raw) if sprint_data_raw else {}
except (json.JSONDecodeError, ValueError):
    sprint = {}

# Parse summary file
try:
    summary = json.loads(summary_raw) if summary_raw else {}
except (json.JSONDecodeError, ValueError):
    summary = {}

# Extract fields
status = sprint.get('status', summary.get('status', 'unknown'))
commits = sprint.get('commits', summary.get('commits', []))
direction = sprint.get('direction', '')
quality_gate = sprint.get('quality_gate_passed', None)
retry_count = sprint.get('retry_count', 0)

# Max retries: 2 (3-strike: original + 2 retries)
MAX_RETRIES = 2

# If sprint completed successfully, no retry needed
if status == 'complete' and quality_gate is not False and len(commits) > 0:
    result = {
        'should_retry': False,
        'reason': 'success',
        'adjusted_direction': '',
        'retry_count': retry_count
    }
    print(json.dumps(result))
    sys.exit(0)

# If already at max retries, don't retry
if retry_count >= MAX_RETRIES:
    result = {
        'should_retry': False,
        'reason': 'max_retries_exceeded',
        'adjusted_direction': '',
        'retry_count': retry_count
    }
    print(json.dumps(result))
    sys.exit(0)

# Determine failure type (check status first, then symptoms)
if status == 'error' or status == 'unknown':
    reason = 'error'
    failure_context = 'The previous attempt ended with an error.'
elif status == 'partial':
    reason = 'partial'
    failure_context = 'The previous attempt only partially completed.'
elif quality_gate is False:
    reason = 'quality_gate_failed'
    failure_context = 'The previous attempt failed the quality gate (build/test failures).'
elif len(commits) == 0:
    reason = 'no_commits'
    failure_context = 'The previous attempt produced no commits.'
else:
    # Fallback: something else went wrong
    reason = 'no_commits' if len(commits) == 0 else 'error'
    failure_context = 'The previous attempt did not complete successfully.'

# Build adjusted direction
adjusted = f'RETRY (attempt {retry_count + 2}/{MAX_RETRIES + 1}): {direction}\\n\\n{failure_context} Try a different approach.'

result = {
    'should_retry': True,
    'reason': reason,
    'adjusted_direction': adjusted,
    'retry_count': retry_count
}
print(json.dumps(result))
" "$sprint_data" "$summary_json" "$sprint_num"
}

cmd_count() {
  local direction="${3:-}"
  [ -z "$direction" ] && die "Usage: retry-strategy.sh count <project-dir> <direction>"
  [ ! -f "$STATE_FILE" ] && { echo "0"; return 0; }

  python3 -c "
import json, sys

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    print(0)
    sys.exit(0)

direction = sys.argv[2]
count = 0
for sprint in d.get('sprints', []):
    sprint_dir = sprint.get('direction', '')
    # Match if the base direction is a prefix (before any retry context)
    # Strip 'RETRY (...): ' prefix for comparison
    base_sprint = sprint_dir
    if base_sprint.startswith('RETRY'):
        idx = base_sprint.find(': ')
        if idx >= 0:
            base_sprint = base_sprint[idx + 2:].split('\n')[0]
    base_target = direction
    if base_target.startswith('RETRY'):
        idx = base_target.find(': ')
        if idx >= 0:
            base_target = base_target[idx + 2:].split('\n')[0]
    if base_sprint == base_target:
        count += 1
print(count)
" "$STATE_FILE" "$direction"
}

# ── Dispatch ──────────────────────────────────────────────────────────────

case "$CMD" in
  analyze)  cmd_analyze "$@" ;;
  count)    cmd_count "$@" ;;
  *)        die "Unknown command: $CMD. Use: analyze|count" ;;
esac
