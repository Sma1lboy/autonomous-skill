#!/usr/bin/env bash
# rate-limiter.sh — Rate limit detection and exponential backoff for dispatch retries.
# Detects rate limit errors in stderr, calculates backoff, records events in conductor state.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: rate-limiter.sh <command> [args...]

Rate limit detection and exponential backoff for autonomous-skill dispatch.

Commands:
  check <stderr_output>
      Detect rate limit patterns in stderr text.
      Exit 0 if rate-limited, 1 if not.
      Patterns: 429, rate_limit, overloaded, Rate limit, Too many requests, capacity

  wait <project_dir> [attempt_num]
      Calculate and sleep for exponential backoff.
      Initial 30s, factor 2x, max 5min, max 5 retries.
      Prints wait time (seconds) to stdout. Exits 1 if max retries exceeded.

  record <project_dir> <context>
      Append a rate limit event to conductor-state.json.
      Adds {timestamp, context, attempt} to the rate_limits array.

  report <project_dir>
      Print rate limit summary from conductor-state.json.

Options:
  -h, --help     Show this help message

Examples:
  bash scripts/rate-limiter.sh check "Error 429 Too Many Requests"
  bash scripts/rate-limiter.sh wait ./my-project 2
  bash scripts/rate-limiter.sh record ./my-project "sprint-3 dispatch"
  bash scripts/rate-limiter.sh report ./my-project
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

CMD="${1:-}"
[ -z "$CMD" ] && die "Usage: rate-limiter.sh <check|wait|record|report> [args...]"

# ── check: detect rate limit patterns in stderr ─────────────────────────

cmd_check() {
  local stderr_text="${2:-}"
  [ -z "$stderr_text" ] && die "Usage: rate-limiter.sh check <stderr_output>"

  # Match any of these patterns (case-insensitive where appropriate)
  if echo "$stderr_text" | grep -qiE '429|rate_limit|overloaded|rate limit|too many requests|capacity'; then
    exit 0
  fi
  exit 1
}

# ── wait: exponential backoff ────────────────────────────────────────────

cmd_wait() {
  local project_dir="${2:-}"
  local attempt="${3:-1}"
  [ -z "$project_dir" ] && die "Usage: rate-limiter.sh wait <project_dir> [attempt_num]"

  # Validate attempt is a positive integer
  [[ "$attempt" =~ ^[0-9]+$ ]] || die "attempt_num must be a positive integer, got: $attempt"
  [ "$attempt" -lt 1 ] && attempt=1

  local max_retries=5
  if [ "$attempt" -gt "$max_retries" ]; then
    echo "ERROR: max retries ($max_retries) exceeded" >&2
    exit 1
  fi

  # Exponential backoff: 30 * 2^(attempt-1), capped at 300
  local base=30
  local factor=1
  local i=1
  while [ "$i" -lt "$attempt" ]; do
    factor=$((factor * 2))
    i=$((i + 1))
  done
  local wait_secs=$((base * factor))
  [ "$wait_secs" -gt 300 ] && wait_secs=300

  echo "$wait_secs"

  # Actually sleep unless DRY_RUN is set (for testing)
  if [ "${DRY_RUN:-}" != "1" ]; then
    sleep "$wait_secs"
  fi
}

# ── record: append rate limit event to conductor-state.json ──────────────

cmd_record() {
  local project_dir="${2:-}"
  local context="${3:-}"
  [ -z "$project_dir" ] && die "Usage: rate-limiter.sh record <project_dir> <context>"
  [ -z "$context" ] && die "Usage: rate-limiter.sh record <project_dir> <context>"

  command -v python3 &>/dev/null || die "python3 required but not found"

  local state_file="$project_dir/.autonomous/conductor-state.json"
  mkdir -p "$project_dir/.autonomous" && chmod 700 "$project_dir/.autonomous"

  python3 -c "
import json, sys, os, time

state_file = sys.argv[1]
context = sys.argv[2]

# Read existing state
d = {}
if os.path.isfile(state_file):
    try:
        with open(state_file) as f:
            d = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        d = {}

# Append rate limit event
if 'rate_limits' not in d:
    d['rate_limits'] = []

# Count existing events for this context to determine attempt number
attempt = sum(1 for e in d['rate_limits'] if e.get('context') == context) + 1

d['rate_limits'].append({
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%S'),
    'context': context,
    'attempt': attempt
})

# Atomic write via tmp + rename
tmp = state_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
os.rename(tmp, state_file)
print('recorded')
" "$state_file" "$context"
}

# ── report: print rate limit summary ─────────────────────────────────────

cmd_report() {
  local project_dir="${2:-}"
  [ -z "$project_dir" ] && die "Usage: rate-limiter.sh report <project_dir>"

  local state_file="$project_dir/.autonomous/conductor-state.json"
  if [ ! -f "$state_file" ]; then
    echo "No rate limit events recorded."
    return 0
  fi

  python3 -c "
import json, sys

state_file = sys.argv[1]
try:
    with open(state_file) as f:
        d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    print('No rate limit events recorded.')
    sys.exit(0)

events = d.get('rate_limits', [])
if not events:
    print('No rate limit events recorded.')
    sys.exit(0)

count = len(events)
first = events[0].get('timestamp', 'unknown')
last = events[-1].get('timestamp', 'unknown')

print(f'Rate limits: {count} events')
print(f'  First: {first}')
print(f'  Last:  {last}')
for e in events:
    print(f'  - [{e.get(\"timestamp\", \"?\")}] {e.get(\"context\", \"?\")} (attempt {e.get(\"attempt\", \"?\")})')
" "$state_file"
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "$CMD" in
  check)  cmd_check "$@" ;;
  wait)   cmd_wait "$@" ;;
  record) cmd_record "$@" ;;
  report) cmd_report "$@" ;;
  *)      die "Unknown command: $CMD. Use: check|wait|record|report" ;;
esac
