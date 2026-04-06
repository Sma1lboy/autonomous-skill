#!/usr/bin/env bash
# session-report.sh — Generate a session-end report from sprint summary files.
# Reads sprint summaries, produces a compact table, and supports detail/JSON modes.
# Layer: shared

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: session-report.sh <project-dir> [--detail N] [--json] [--diff]

Generate a session report from sprint summary files.

Arguments:
  project-dir    Project directory containing .autonomous/ sprint data

Options:
  --detail N     Show full detail for sprint N
  --json         Output machine-readable JSON
  --diff         Append a diff summary (branch vs base) at the end
  -h, --help     Show this help message

Output modes:
  Default: compact table with sprint number, status, commits, rating, summary
  --detail N: full detail for a specific sprint (direction, summary, commits, files)
  --json: machine-readable JSON with all sprint data and totals
  --diff: appends session-diff.sh output after the normal report

Examples:
  bash scripts/session-report.sh ./my-project
  bash scripts/session-report.sh ./my-project --detail 2
  bash scripts/session-report.sh ./my-project --json
  bash scripts/session-report.sh ./my-project --diff
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

# ── Parse arguments ──────────────────────────────────────────────────────

PROJECT_DIR=""
DETAIL_NUM=""
JSON_MODE=false
DIFF_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --detail)
      [ -z "${2:-}" ] && { echo "ERROR: --detail requires a sprint number" >&2; exit 1; }
      DETAIL_NUM="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --diff)
      DIFF_MODE=true
      shift
      ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      else
        echo "ERROR: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

[ -z "$PROJECT_DIR" ] && { echo "ERROR: project-dir is required" >&2; exit 1; }

STATE_DIR="$PROJECT_DIR/.autonomous"

# ── Discover sprint summary files ────────────────────────────────────────

sprint_files=()
n=1
while true; do
  f="$STATE_DIR/sprint-${n}-summary.json"
  if [ -f "$f" ]; then
    sprint_files+=("$f")
    n=$((n + 1))
  else
    break
  fi
done

if [ ${#sprint_files[@]} -eq 0 ]; then
  echo "No sprint data found."
  exit 0
fi

# ── Read conductor state for directions ──────────────────────────────────

CONDUCTOR_STATE="$STATE_DIR/conductor-state.json"

get_direction() {
  local sprint_num="$1"
  if [ -f "$CONDUCTOR_STATE" ]; then
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    idx = int(sys.argv[2]) - 1
    sprints = d.get('sprints', [])
    if 0 <= idx < len(sprints):
        print(sprints[idx].get('direction', 'unknown'))
    else:
        print('unknown')
except Exception:
    print('unknown')
" "$CONDUCTOR_STATE" "$sprint_num" 2>/dev/null
  else
    echo "unknown"
  fi
}

# ── Get files changed for a set of commits ───────────────────────────────

get_files_changed() {
  local commits_json="$1"
  if ! command -v git &>/dev/null; then
    echo "0"
    return
  fi
  python3 -c "
import json, subprocess, sys, os

commits = json.loads(sys.argv[1])
project = sys.argv[2]
if not commits:
    print(0)
    sys.exit(0)

files = set()
for c in commits:
    # commits are in 'hash message' format — extract hash
    h = c.strip().split()[0] if c.strip() else ''
    if not h:
        continue
    try:
        r = subprocess.run(
            ['git', 'log', '--format=', '--name-only', '-1', h],
            capture_output=True, text=True, cwd=project
        )
        for line in r.stdout.strip().split('\n'):
            if line.strip():
                files.add(line.strip())
    except Exception:
        pass
print(len(files))
" "$commits_json" "$PROJECT_DIR" 2>/dev/null || echo "0"
}

get_files_list() {
  local commits_json="$1"
  if ! command -v git &>/dev/null; then
    echo "[]"
    return
  fi
  python3 -c "
import json, subprocess, sys

commits = json.loads(sys.argv[1])
project = sys.argv[2]
if not commits:
    print('[]')
    sys.exit(0)

files = set()
for c in commits:
    h = c.strip().split()[0] if c.strip() else ''
    if not h:
        continue
    try:
        r = subprocess.run(
            ['git', 'log', '--format=', '--name-only', '-1', h],
            capture_output=True, text=True, cwd=project
        )
        for line in r.stdout.strip().split('\n'):
            if line.strip():
                files.add(line.strip())
    except Exception:
        pass
print(json.dumps(sorted(files)))
" "$commits_json" "$PROJECT_DIR" 2>/dev/null || echo "[]"
}

# ── Collect sprint data ──────────────────────────────────────────────────

collect_sprints() {
  python3 -c "
import json, sys, subprocess, os

project_dir = sys.argv[1]
state_file = sys.argv[2]
sprint_count = int(sys.argv[3])

# Load conductor state for directions, quality gate results, and costs
directions = {}
qg_results = {}
sprint_costs = {}
session_cost_usd = 0.0
if os.path.isfile(state_file):
    try:
        with open(state_file) as f:
            state = json.load(f)
        session_cost_usd = state.get('session_cost_usd', 0.0)
        for s in state.get('sprints', []):
            directions[s.get('number', 0)] = s.get('direction', 'unknown')
            qg_results[s.get('number', 0)] = s.get('quality_gate_passed', None)
            sprint_costs[s.get('number', 0)] = s.get('cost_usd', 0)
    except Exception:
        pass

sprints = []
total_commits = 0
all_files = set()

for n in range(1, sprint_count + 1):
    summary_file = os.path.join(project_dir, '.autonomous', f'sprint-{n}-summary.json')
    try:
        with open(summary_file) as f:
            data = json.load(f)
    except Exception:
        continue

    status = data.get('status', 'unknown')
    commits = data.get('commits', [])
    summary = data.get('summary', '')
    direction = directions.get(n, 'unknown')
    qg_passed = qg_results.get(n, None)
    cost_usd = sprint_costs.get(n, 0)
    commit_count = len(commits)
    total_commits += commit_count

    # Rating
    if status == 'complete' and commit_count > 0:
        rating = 'recommended'
    else:
        rating = 'skippable'

    # Files changed from git
    files_changed = 0
    files_list = []
    for c in commits:
        h = c.strip().split()[0] if c.strip() else ''
        if not h:
            continue
        try:
            r = subprocess.run(
                ['git', 'log', '--format=', '--name-only', '-1', h],
                capture_output=True, text=True,
                cwd=project_dir
            )
            for line in r.stdout.strip().split('\n'):
                if line.strip():
                    all_files.add(line.strip())
                    files_list.append(line.strip())
        except Exception:
            pass
    files_set = set(files_list)
    files_changed = len(files_set)

    sprints.append({
        'number': n,
        'status': status,
        'direction': direction,
        'commits': commits,
        'commit_count': commit_count,
        'files_changed': files_changed,
        'files_list': sorted(files_set),
        'summary': summary,
        'rating': rating,
        'quality_gate_passed': qg_passed,
        'cost_usd': cost_usd
    })

result = {
    'sprints': sprints,
    'totals': {
        'sprints': len(sprints),
        'commits': total_commits,
        'files_changed': len(all_files),
        'session_cost_usd': session_cost_usd
    }
}
print(json.dumps(result))
" "$PROJECT_DIR" "$CONDUCTOR_STATE" "${#sprint_files[@]}"
}

DATA=$(collect_sprints)

# ── Resolve SCRIPT_DIR for sibling scripts ──────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── JSON mode ────────────────────────────────────────────────────────────

# ── Load rate limits from conductor state ────────────────────────────────

RATE_LIMITS_JSON="[]"
if [ -f "$CONDUCTOR_STATE" ]; then
  RATE_LIMITS_JSON=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    rl = d.get('rate_limits', [])
    print(json.dumps(rl))
except Exception:
    print('[]')
" "$CONDUCTOR_STATE" 2>/dev/null || echo "[]")
fi

if [ "$JSON_MODE" = true ]; then
  if [ "$DIFF_MODE" = true ]; then
    DIFF_JSON=$(bash "$SCRIPT_DIR/session-diff.sh" "$PROJECT_DIR" --json 2>/dev/null || echo '{}')
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for s in data['sprints']:
    s.pop('files_list', None)
try:
    data['diff'] = json.loads(sys.argv[2])
except Exception:
    data['diff'] = {}
data['rate_limits'] = json.loads(sys.argv[3])
print(json.dumps(data, indent=2))
" "$DATA" "$DIFF_JSON" "$RATE_LIMITS_JSON"
  else
    # Output clean JSON (without files_list in sprint objects)
    python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for s in data['sprints']:
    s.pop('files_list', None)
data['rate_limits'] = json.loads(sys.argv[2])
print(json.dumps(data, indent=2))
" "$DATA" "$RATE_LIMITS_JSON"
  fi
  exit 0
fi

# ── Detail mode ──────────────────────────────────────────────────────────

if [ -n "$DETAIL_NUM" ]; then
  python3 -c "
import json, sys

data = json.loads(sys.argv[1])
n = int(sys.argv[2])
sprints = data['sprints']

if n < 1 or n > len(sprints):
    print(f'ERROR: sprint {n} out of range (1-{len(sprints)})', file=sys.stderr)
    sys.exit(1)

s = sprints[n - 1]
print(f'Sprint {s[\"number\"]}')
print(f'  Direction: {s[\"direction\"]}')
print(f'  Status:    {s[\"status\"]}')
qg = s.get('quality_gate_passed')
if qg is True:
    print(f'  Quality:   pass')
elif qg is False:
    print(f'  Quality:   FAIL')
else:
    print(f'  Quality:   not run')
cost = s.get('cost_usd', 0)
print(f'  Cost:      \${cost:.4f}')
print(f'  Rating:    {s[\"rating\"]}', end='')
if s['rating'] == 'recommended':
    print(' (complete with commits)')
else:
    reason = []
    if s['status'] != 'complete':
        reason.append(f'status={s[\"status\"]}')
    if s['commit_count'] == 0:
        reason.append('no commits')
    msg = ', '.join(reason) if reason else 'incomplete or no commits'
    print(f' ({msg})')
print(f'  Commits:   {s[\"commit_count\"]}')
for c in s.get('commits', []):
    print(f'    - {c}')
print(f'  Files changed: {s[\"files_changed\"]}')
for f in s.get('files_list', []):
    print(f'    - {f}')
print(f'  Summary:')
print(f'    {s[\"summary\"]}')
" "$DATA" "$DETAIL_NUM"
  exit $?
fi

# ── Table mode (default) ────────────────────────────────────────────────

python3 -c "
import json, sys

data = json.loads(sys.argv[1])
sprints = data['sprints']
totals = data['totals']

def qg_label(val):
    if val is True:
        return 'pass'
    elif val is False:
        return 'fail'
    return '—'

# Header
print(f'{\"Sprint\":<7} | {\"Status\":<10} | {\"Commits\":<7} | {\"QG\":<4} | {\"Cost\":<8} | {\"Rating\":<11} | Summary')
print(f'{\"-\"*7}+{\"-\"*12}+{\"-\"*9}+{\"-\"*6}+{\"-\"*10}+{\"-\"*13}+{\"-\"*30}')

for s in sprints:
    summary = s['summary']
    if len(summary) > 60:
        summary = summary[:57] + '...'
    qg = qg_label(s.get('quality_gate_passed'))
    cost = s.get('cost_usd', 0)
    cost_str = '\$' + f'{cost:.2f}' if cost else '—'
    print(f'{s[\"number\"]:<7} | {s[\"status\"]:<10} | {s[\"commit_count\"]:<7} | {qg:<4} | {cost_str:<8} | {s[\"rating\"]:<11} | {summary}')

session_cost = totals.get('session_cost_usd', 0)
cost_line = ', \$' + f'{session_cost:.2f} cost' if session_cost else ''
print()
print(f'Total: {totals[\"sprints\"]} sprints, {totals[\"commits\"]} commits, {totals[\"files_changed\"]} files changed{cost_line}')

import json as _json
rl = _json.loads(sys.argv[2])
if rl:
    first = rl[0].get('timestamp', 'unknown')
    last = rl[-1].get('timestamp', 'unknown')
    print(f'Rate limits: {len(rl)} events (first: {first}, last: {last})')
" "$DATA" "$RATE_LIMITS_JSON"

# ── Append diff summary (text/table mode only) ─────────────────────────

if [ "$DIFF_MODE" = true ]; then
  echo ""
  bash "$SCRIPT_DIR/session-diff.sh" "$PROJECT_DIR" 2>/dev/null || true
fi
