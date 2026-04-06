#!/usr/bin/env bash
# cost-tracker.sh — Track costs per sprint and session total.
# Integrates with conductor-state.json for persistent cost tracking.
#
# Usage: bash cost-tracker.sh <command> <project-dir> [args...]
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: cost-tracker.sh <command> <project-dir> [args...]

Track costs per sprint and session total. Integrates with
.autonomous/conductor-state.json for persistent cost tracking.

Commands:
  record <project-dir> <sprint-num> <cost-usd>
      Record cost for a sprint. Accumulates into conductor-state.json
      (adds cost_usd to the sprint entry, updates session_cost_usd total)

  check <project-dir> <max-cost-usd>
      Check if session cost exceeds budget. Exit 0 if under, exit 1 if over.
      Output: COST_OK=true|false, SESSION_COST=X.XX, REMAINING_BUDGET=X.XX

  parse-output <json-file-or-stdin>
      Extract cost_usd from claude --output-format json output.
      Prints the cost as a number. Handles missing field (prints "0").

  report <project-dir>
      Print cost breakdown: per-sprint costs + session total.

Options:
  -h, --help     Show this help message

Examples:
  bash scripts/cost-tracker.sh record ./my-project 1 0.0523
  bash scripts/cost-tracker.sh check ./my-project 5.00
  bash scripts/cost-tracker.sh parse-output result.json
  echo '{"cost_usd": 0.12}' | bash scripts/cost-tracker.sh parse-output -
  bash scripts/cost-tracker.sh report ./my-project
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || die "python3 required but not found"

CMD="${1:-}"
[ -z "$CMD" ] && die "command is required. Use: record|check|parse-output|report"

# ── Record command ────────────────────────────────────────────────────────

cmd_record() {
  local project="${2:-}"
  local sprint_num="${3:-}"
  local cost="${4:-}"

  [ -z "$project" ] && die "Usage: cost-tracker.sh record <project-dir> <sprint-num> <cost-usd>"
  [ -z "$sprint_num" ] && die "Usage: cost-tracker.sh record <project-dir> <sprint-num> <cost-usd>"
  [ -z "$cost" ] && die "Usage: cost-tracker.sh record <project-dir> <sprint-num> <cost-usd>"

  # Validate sprint_num is a positive integer
  [[ "$sprint_num" =~ ^[0-9]+$ ]] || die "sprint-num must be a positive integer, got: $sprint_num"
  [ "$sprint_num" -gt 0 ] || die "sprint-num must be > 0, got: $sprint_num"

  # Validate cost is a number
  python3 -c "import sys; float(sys.argv[1])" "$cost" 2>/dev/null || die "cost-usd must be numeric, got: $cost"

  local state_file="$project/.autonomous/conductor-state.json"
  [ -f "$state_file" ] || die "No conductor-state.json found at $state_file"

  python3 -c "
import json, sys, os

state_file = sys.argv[1]
sprint_num = int(sys.argv[2])
cost = float(sys.argv[3])

try:
    with open(state_file) as f:
        d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f'ERROR: cannot read state: {e}', file=sys.stderr)
    sys.exit(1)

sprints = d.get('sprints', [])

# Find sprint by number and add cost
found = False
for s in sprints:
    if s.get('number') == sprint_num:
        s['cost_usd'] = cost
        found = True
        break

if not found:
    print(f'ERROR: sprint {sprint_num} not found in state', file=sys.stderr)
    sys.exit(1)

# Recalculate session total
d['session_cost_usd'] = round(sum(s.get('cost_usd', 0) for s in sprints), 4)

# Atomic write
tmp = state_file + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2)
os.rename(tmp, state_file)

print(f'recorded: sprint {sprint_num} = \${cost:.4f}, session total = \${d[\"session_cost_usd\"]:.4f}')
" "$state_file" "$sprint_num" "$cost"
}

# ── Check command ─────────────────────────────────────────────────────────

cmd_check() {
  local project="${2:-}"
  local max_cost="${3:-}"

  [ -z "$project" ] && die "Usage: cost-tracker.sh check <project-dir> <max-cost-usd>"
  [ -z "$max_cost" ] && die "Usage: cost-tracker.sh check <project-dir> <max-cost-usd>"

  # Validate max_cost is a number
  python3 -c "import sys; float(sys.argv[1])" "$max_cost" 2>/dev/null || die "max-cost-usd must be numeric, got: $max_cost"

  local state_file="$project/.autonomous/conductor-state.json"
  [ -f "$state_file" ] || die "No conductor-state.json found at $state_file"

  python3 -c "
import json, sys

state_file = sys.argv[1]
max_cost = float(sys.argv[2])

try:
    with open(state_file) as f:
        d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f'ERROR: cannot read state: {e}', file=sys.stderr)
    sys.exit(1)

session_cost = d.get('session_cost_usd', 0.0)
remaining = max_cost - session_cost
ok = session_cost <= max_cost

print(f'COST_OK={\"true\" if ok else \"false\"}')
print(f'SESSION_COST={session_cost:.2f}')
print(f'REMAINING_BUDGET={remaining:.2f}')

sys.exit(0 if ok else 1)
" "$state_file" "$max_cost"
}

# ── Parse-output command ──────────────────────────────────────────────────

cmd_parse_output() {
  local source="${2:-}"

  if [ -z "$source" ]; then
    die "Usage: cost-tracker.sh parse-output <json-file-or-stdin>"
  fi

  if [ "$source" = "-" ]; then
    # Read from stdin
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    cost = d.get('cost_usd', 0)
    if cost is None:
        cost = 0
    print(cost)
except (json.JSONDecodeError, ValueError):
    print(0)
"
  else
    # Read from file
    [ -f "$source" ] || die "File not found: $source"
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    cost = d.get('cost_usd', 0)
    if cost is None:
        cost = 0
    print(cost)
except (json.JSONDecodeError, ValueError, FileNotFoundError):
    print(0)
" "$source"
  fi
}

# ── Report command ────────────────────────────────────────────────────────

cmd_report() {
  local project="${2:-}"

  [ -z "$project" ] && die "Usage: cost-tracker.sh report <project-dir>"

  local state_file="$project/.autonomous/conductor-state.json"
  [ -f "$state_file" ] || die "No conductor-state.json found at $state_file"

  python3 -c "
import json, sys

state_file = sys.argv[1]

try:
    with open(state_file) as f:
        d = json.load(f)
except (json.JSONDecodeError, FileNotFoundError) as e:
    print(f'ERROR: cannot read state: {e}', file=sys.stderr)
    sys.exit(1)

sprints = d.get('sprints', [])
session_cost = d.get('session_cost_usd', 0.0)

print(f'{\"Sprint\":<7} | {\"Direction\":<30} | {\"Cost (USD)\":<10}')
print(f'{\"-\"*7}+{\"-\"*32}+{\"-\"*10}')

for s in sprints:
    num = s.get('number', '?')
    direction = s.get('direction', 'unknown')
    if len(direction) > 28:
        direction = direction[:25] + '...'
    cost = s.get('cost_usd', 0)
    print(f'{num:<7} | {direction:<30} | \${cost:.4f}')

print()
print(f'Session total: \${session_cost:.4f}')
" "$state_file"
}

# ── Dispatch ──────────────────────────────────────────────────────────────

case "$CMD" in
  record)       cmd_record "$@" ;;
  check)        cmd_check "$@" ;;
  parse-output) cmd_parse_output "$@" ;;
  report)       cmd_report "$@" ;;
  *)            die "Unknown command: $CMD. Use: record|check|parse-output|report" ;;
esac
