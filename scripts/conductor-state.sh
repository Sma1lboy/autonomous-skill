#!/usr/bin/env bash
# conductor-state.sh — State management for the multi-sprint conductor.
# Manages .autonomous/conductor-state.json with atomic writes and PID locking.
# Layer: conductor

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: conductor-state.sh <command> <project-dir> [args...]

State management for the autonomous-skill conductor. Manages
.autonomous/conductor-state.json with atomic writes and PID locking.

Commands:
  init <project-dir> <mission> [max-sprints]
      Initialize a new conductor session (default max-sprints: 5)

  read <project-dir>
      Read current conductor state as JSON

  sprint-start <project-dir> <direction>
      Register a new sprint with the given direction

  sprint-end <project-dir> <status> <summary> [commits-json] [direction-complete] [quality-gate]
      Complete the current sprint, update counters, evaluate phase transition
      quality-gate: "true", "false", or "" (not run)

  phase <project-dir>
      Print current phase ("directed" or "exploring")

  explore-pick <project-dir>
      Pick the weakest unaudited dimension for exploration

  explore-score <project-dir> <dimension> <score>
      Score a dimension (0-10) after auditing it
      Dimensions: test_coverage, error_handling, security, code_quality,
                  documentation, architecture, performance, dx

  progress <project-dir>
      Print a one-line status string summarizing current session state
      Format: "Sprint N/M | phase | X commits | last: summary"

  retry-mark <project-dir> <sprint-num>
      Increment retry_count on the specified sprint entry

  get-sprint <project-dir> <sprint-num>
      Return a single sprint's data as JSON

  rate-limit <project-dir> <context>
      Record a rate limit event in the rate_limits array
      Appends {timestamp, context, attempt} to conductor-state.json

  lock <project-dir>
      Acquire PID lock (prevents concurrent conductors)

  unlock <project-dir>
      Release PID lock

Examples:
  bash scripts/conductor-state.sh init ./my-project "build REST API" 5
  bash scripts/conductor-state.sh read ./my-project
  bash scripts/conductor-state.sh sprint-start ./my-project "add auth middleware"
  bash scripts/conductor-state.sh progress ./my-project
  bash scripts/conductor-state.sh retry-mark ./my-project 3
  bash scripts/conductor-state.sh get-sprint ./my-project 2
  bash scripts/conductor-state.sh rate-limit ./my-project "sprint-3 dispatch"
  bash scripts/conductor-state.sh phase ./my-project
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

CMD="${1:-}"
PROJECT="${2:-.}"
STATE_DIR="$PROJECT/.autonomous"
STATE_FILE="$STATE_DIR/conductor-state.json"
LOCK_DIR="$STATE_DIR/conductor.lock"

# ── Cleanup ───────────────────────────────────────────────────────────────

cleanup() {
  # Remove tmp files left by atomic_write or write_state
  rm -f "$STATE_FILE.tmp.$$" 2>/dev/null || true
  # Release lock if we hold it
  if [ -d "$LOCK_DIR" ] 2>/dev/null; then
    local lock_pid=""
    [ -f "$LOCK_DIR/pid" ] && lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ "$lock_pid" = "$$" ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Atomic write: write to tmp, verify, then mv
atomic_write() {
  local file="$1" content="$2"
  local tmp="${file}.tmp.$$"
  echo "$content" > "$tmp"
  # Verify write succeeded (guards against disk full / truncation)
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" 2>/dev/null || true
    die "atomic_write failed: tmp file empty or missing after write"
  fi
  mv -f "$tmp" "$file"
}

# Read state, output JSON. Returns empty object on missing/corrupt file.
# Always exits 0. Outputs "{}" on missing/corrupt.
read_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "{}"
    return 0
  fi
  local content
  content=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    json.dump(d, sys.stdout)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(1)
" "$STATE_FILE" 2>/dev/null) || { echo "{}"; return 0; }
  echo "$content"
}

# Read state, returns 1 if missing/corrupt (no output on failure)
read_state_strict() {
  if [ ! -f "$STATE_FILE" ]; then
    return 1
  fi
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    json.dump(d, sys.stdout)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(1)
" "$STATE_FILE" 2>/dev/null || return 1
}

# Write state atomically via python3 (ensures valid JSON)
write_state() {
  local json_str="$1"
  python3 -c "
import json, sys, os
try:
    d = json.loads(sys.argv[1])
    state_file = sys.argv[2]
    tmp = state_file + '.tmp.' + str(os.getpid())
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=2)
    os.rename(tmp, state_file)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" "$json_str" "$STATE_FILE"
}

# ── Lock management ───────────────────────────────────────────────────────

acquire_lock() {
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  # mkdir is POSIX-atomic: only one process can create the directory
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Lock exists — check if holder is still alive
    local lock_pid=""
    if [ -d "$LOCK_DIR" ]; then
      # New format: PID in lock_dir/pid
      [ -f "$LOCK_DIR/pid" ] && lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    elif [ -f "$LOCK_DIR" ]; then
      # Old format: PID directly in the lock file
      lock_pid=$(cat "$LOCK_DIR" 2>/dev/null || echo "")
    fi
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      die "Another conductor is running (PID $lock_pid). Lock: $LOCK_DIR"
    fi
    # Stale lock, break it and re-acquire
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null || die "Cannot acquire conductor lock"
  fi
  echo $$ > "$LOCK_DIR/pid"
}

release_lock() {
  if [ -d "$LOCK_DIR" ] 2>/dev/null; then
    local lock_pid=""
    [ -f "$LOCK_DIR/pid" ] && lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ "$lock_pid" = "$$" ] || [ -z "$lock_pid" ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────

cmd_init() {
  local mission="${3:-}"
  local max_sprints="${4:-5}"
  [ -z "$mission" ] && die "Usage: conductor-state.sh init <project-dir> <mission> [max-sprints]"
  [[ "$max_sprints" =~ ^[0-9]+$ ]] || die "max-sprints must be a positive integer, got: $max_sprints"
  [ "$max_sprints" -gt 0 ] || die "max-sprints must be > 0, got: $max_sprints"

  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  # Clean stale sprint summaries from prior sessions
  rm -f "$STATE_DIR/sprint-summary.json"
  rm -f "$STATE_DIR"/sprint-*-summary.json
  acquire_lock

  local session_id
  session_id="conductor-$(date +%s)"
  local max_directed
  # 70% of total sprints for directed phase
  max_directed=$(python3 -c "import sys; print(max(1, int(int(sys.argv[1]) * 0.7)))" "$max_sprints")

  local state
  state=$(python3 -c "
import json, sys
d = {
    'session_id': sys.argv[1],
    'mission': sys.argv[2],
    'phase': 'directed',
    'max_sprints': int(sys.argv[3]),
    'max_directed_sprints': int(sys.argv[4]),
    'sprints': [],
    'consecutive_complete': 0,
    'consecutive_zero_commits': 0,
    'exploration': {
        'test_coverage': {'audited': False, 'score': None},
        'error_handling': {'audited': False, 'score': None},
        'security': {'audited': False, 'score': None},
        'code_quality': {'audited': False, 'score': None},
        'documentation': {'audited': False, 'score': None},
        'architecture': {'audited': False, 'score': None},
        'performance': {'audited': False, 'score': None},
        'dx': {'audited': False, 'score': None}
    }
}
print(json.dumps(d))
" "$session_id" "$mission" "$max_sprints" "$max_directed")

  write_state "$state"
  echo "$session_id"
}

cmd_read() {
  read_state
}

cmd_sprint_start() {
  local direction="${3:-}"
  [ -z "$direction" ] && die "Usage: conductor-state.sh sprint-start <project-dir> <direction>"

  local state
  state=$(read_state_strict) || die "No conductor state found. Run 'init' first."

  local updated
  updated=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
sprint_num = len(d.get('sprints', [])) + 1
d.setdefault('sprints', []).append({
    'number': sprint_num,
    'direction': sys.argv[2],
    'status': 'running',
    'commits': [],
    'summary': '',
    'retry_count': 0
})
print(json.dumps(d))
" "$state" "$direction")

  write_state "$updated"
  # Print sprint number
  python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['sprints']))" "$updated"
}

cmd_sprint_end() {
  local status="${3:-}"
  local summary="${4:-}"
  local commits_json="${5:-[]}"
  local direction_complete="${6:-false}"
  local quality_gate="${7:-}"

  [ -z "$status" ] && die "Usage: conductor-state.sh sprint-end <project-dir> <status> <summary> [commits-json] [direction-complete] [quality-gate]"

  local state
  state=$(read_state_strict) || die "No conductor state found."

  local updated
  updated=$(python3 -c "
import json, sys

d = json.loads(sys.argv[1])
status = sys.argv[2]
summary = sys.argv[3]
commits = json.loads(sys.argv[4])
direction_complete = sys.argv[5].lower() == 'true'
qg_raw = sys.argv[6]

# Parse quality gate: 'true' -> True, 'false' -> False, '' -> None
if qg_raw.lower() == 'true':
    quality_gate = True
elif qg_raw.lower() == 'false':
    quality_gate = False
else:
    quality_gate = None

sprints = d.get('sprints', [])
if not sprints:
    print(json.dumps(d))
    sys.exit(0)

# Update last sprint (preserve retry_count if already set)
sprints[-1]['status'] = status
sprints[-1]['summary'] = summary
sprints[-1]['commits'] = commits
sprints[-1]['direction_complete'] = direction_complete
sprints[-1]['quality_gate_passed'] = quality_gate
sprints[-1].setdefault('retry_count', 0)

# Update counters
if direction_complete:
    d['consecutive_complete'] = d.get('consecutive_complete', 0) + 1
else:
    d['consecutive_complete'] = 0

if len(commits) == 0:
    d['consecutive_zero_commits'] = d.get('consecutive_zero_commits', 0) + 1
else:
    d['consecutive_zero_commits'] = 0

# Phase transition decision tree
if d.get('phase') == 'directed':
    sprint_num = len(sprints)
    max_directed = d.get('max_directed_sprints', 7)
    consec_complete = d.get('consecutive_complete', 0)
    consec_zero = d.get('consecutive_zero_commits', 0)
    has_commits = any(len(s.get('commits', [])) > 0 for s in sprints)

    if sprint_num >= max_directed:
        d['phase'] = 'exploring'
        d['phase_transition_reason'] = 'max_directed_sprints reached'
    elif direction_complete and has_commits and consec_complete >= 2:
        d['phase'] = 'exploring'
        d['phase_transition_reason'] = 'direction_complete confirmed'
    elif consec_zero >= 2:
        d['phase'] = 'exploring'
        d['phase_transition_reason'] = 'consecutive_zero_commits'

print(json.dumps(d))
" "$state" "$status" "$summary" "$commits_json" "$direction_complete" "$quality_gate")

  write_state "$updated"

  # Print current phase
  python3 -c "import json,sys; print(json.loads(sys.argv[1])['phase'])" "$updated"
}

cmd_phase() {
  local state
  state=$(read_state)
  python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('phase','unknown'))" "$state"
}

cmd_explore_pick() {
  local state
  state=$(read_state_strict) || die "No conductor state found."

  python3 -c "
import json, sys

d = json.loads(sys.argv[1])
exploration = d.get('exploration', {})

# Priority order
priority = ['test_coverage', 'error_handling', 'security', 'code_quality',
            'documentation', 'architecture', 'performance', 'dx']

# Pick first never-audited dimension (in priority order)
for dim in priority:
    info = exploration.get(dim, {})
    if not info.get('audited', False):
        print(dim)
        sys.exit(0)

# All audited: pick lowest score
scored = [(dim, exploration[dim].get('score', 0) or 0) for dim in priority if dim in exploration]
if scored:
    scored.sort(key=lambda x: x[1])
    print(scored[0][0])
else:
    print(priority[0])
" "$state"
}

cmd_explore_score() {
  local dimension="${3:-}"
  local score="${4:-}"
  [ -z "$dimension" ] || [ -z "$score" ] && die "Usage: conductor-state.sh explore-score <project-dir> <dimension> <score>"
  # Validate score is a number (integer or float, including negative)
  python3 -c "import sys; float(sys.argv[1])" "$score" 2>/dev/null || die "score must be numeric, got: $score"
  # Validate dimension is known
  local valid_dims="test_coverage error_handling security code_quality documentation architecture performance dx"
  echo "$valid_dims" | grep -qw "$dimension" || die "unknown dimension: $dimension (valid: $valid_dims)"

  local state
  state=$(read_state_strict) || die "No conductor state found."

  local updated
  updated=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
dim = sys.argv[2]
score = float(sys.argv[3])
if dim in d.get('exploration', {}):
    d['exploration'][dim]['audited'] = True
    d['exploration'][dim]['score'] = score
print(json.dumps(d))
" "$state" "$dimension" "$score")

  write_state "$updated"
  echo "ok"
}

cmd_retry_mark() {
  local sprint_num="${3:-}"
  [ -z "$sprint_num" ] && die "Usage: conductor-state.sh retry-mark <project-dir> <sprint-num>"
  [[ "$sprint_num" =~ ^[0-9]+$ ]] || die "sprint-num must be a positive integer, got: $sprint_num"

  local state
  state=$(read_state_strict) || die "No conductor state found."

  local updated
  updated=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
num = int(sys.argv[2])
found = False
for s in d.get('sprints', []):
    if s['number'] == num:
        s['retry_count'] = s.get('retry_count', 0) + 1
        found = True
        print(json.dumps(d))
        break
if not found:
    print(json.dumps(d))
    print('WARNING: sprint {} not found'.format(num), file=sys.stderr)
" "$state" "$sprint_num")

  write_state "$updated"
  # Print new retry_count
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
num = int(sys.argv[2])
for s in d.get('sprints', []):
    if s['number'] == num:
        print(s.get('retry_count', 0))
        break
" "$updated" "$sprint_num"
}

cmd_get_sprint() {
  local sprint_num="${3:-}"
  [ -z "$sprint_num" ] && die "Usage: conductor-state.sh get-sprint <project-dir> <sprint-num>"
  [[ "$sprint_num" =~ ^[0-9]+$ ]] || die "sprint-num must be a positive integer, got: $sprint_num"

  local state
  state=$(read_state_strict) || die "No conductor state found."

  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
num = int(sys.argv[2])
for s in d.get('sprints', []):
    if s['number'] == num:
        print(json.dumps(s))
        sys.exit(0)
print('{}')
" "$state" "$sprint_num"
}

cmd_rate_limit() {
  local context="${3:-}"
  [ -z "$context" ] && die "Usage: conductor-state.sh rate-limit <project-dir> <context>"

  local state
  state=$(read_state)

  local updated
  updated=$(python3 -c "
import json, sys, time

d = json.loads(sys.argv[1])
context = sys.argv[2]

if 'rate_limits' not in d:
    d['rate_limits'] = []

# Count existing events for this context to determine attempt number
attempt = sum(1 for e in d['rate_limits'] if e.get('context') == context) + 1

d['rate_limits'].append({
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%S'),
    'context': context,
    'attempt': attempt
})

print(json.dumps(d))
" "$state" "$context")

  write_state "$updated"
  echo "recorded"
}

cmd_progress() {
  local state
  state=$(read_state)

  python3 -c "
import json, sys

d = json.loads(sys.argv[1])
if not d or 'phase' not in d:
    print('No active session')
    sys.exit(0)

sprints = d.get('sprints', [])
max_sprints = d.get('max_sprints', 0)
phase = d.get('phase', 'unknown')
current = len(sprints)
total_commits = sum(len(s.get('commits', [])) for s in sprints)

# Last sprint summary (truncated)
last_summary = ''
for s in reversed(sprints):
    if s.get('summary', ''):
        last_summary = s['summary']
        break

if len(last_summary) > 50:
    last_summary = last_summary[:47] + '...'

if last_summary:
    print(f'Sprint {current}/{max_sprints} | {phase} | {total_commits} commits | last: {last_summary}')
else:
    print(f'Sprint {current}/{max_sprints} | {phase} | {total_commits} commits')
" "$state"
}

cmd_lock() {
  acquire_lock
  echo "locked (PID $$)"
}

cmd_unlock() {
  release_lock
  echo "unlocked"
}

# ── Dispatch ──────────────────────────────────────────────────────────────

case "$CMD" in
  init)          cmd_init "$@" ;;
  read)          cmd_read ;;
  sprint-start)  cmd_sprint_start "$@" ;;
  sprint-end)    cmd_sprint_end "$@" ;;
  phase)         cmd_phase ;;
  explore-pick)  cmd_explore_pick ;;
  explore-score) cmd_explore_score "$@" ;;
  progress)      cmd_progress ;;
  lock)          cmd_lock ;;
  unlock)        cmd_unlock ;;
  retry-mark)    cmd_retry_mark "$@" ;;
  get-sprint)    cmd_get_sprint "$@" ;;
  rate-limit)    cmd_rate_limit "$@" ;;
  *)             die "Unknown command: $CMD. Use: init|read|sprint-start|sprint-end|phase|explore-pick|explore-score|progress|retry-mark|get-sprint|rate-limit|lock|unlock" ;;
esac
