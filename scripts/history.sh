#!/usr/bin/env bash
# history.sh — Sprint history viewer: list auto/ branches and session metadata.
# Reads conductor-state.json from each branch via `git show` without checkout.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: history.sh <project-dir> [options]

List all auto/ session branches and show metadata from each branch's
conductor-state.json. Reads state via `git show` without checking out branches.

Arguments:
  project-dir        Project directory (must be a git repo)

Options:
  --detail BRANCH    Show full session report for a specific auto/ branch
  --compare B1 B2    Side-by-side comparison of two auto/ branches
  --json             Machine-readable JSON output (works with all modes)
  -h, --help         Show this help message

Default mode (no options):
  Lists all auto/ branches sorted by date (most recent first) with:
  branch name, creation date, sprint count, phase, total commits, cost

Examples:
  bash scripts/history.sh ./my-project
  bash scripts/history.sh ./my-project --json
  bash scripts/history.sh ./my-project --detail auto/session-1234
  bash scripts/history.sh ./my-project --compare auto/session-1 auto/session-2
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v git &>/dev/null || die "git required but not found"
command -v python3 &>/dev/null || die "python3 required but not found"

# ── Parse arguments ──────────────────────────────────────────────────────

PROJECT_DIR=""
DETAIL_BRANCH=""
COMPARE_A=""
COMPARE_B=""
JSON_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --detail)
      [ -z "${2:-}" ] && die "--detail requires a branch name"
      DETAIL_BRANCH="$2"
      shift 2
      ;;
    --compare)
      [ -z "${2:-}" ] && die "--compare requires two branch names"
      [ -z "${3:-}" ] && die "--compare requires two branch names"
      COMPARE_A="$2"
      COMPARE_B="$3"
      shift 3
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -z "$PROJECT_DIR" ] && die "project-dir is required"
[ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"
[ -d "$PROJECT_DIR/.git" ] || die "not a git repository: $PROJECT_DIR"

# ── Core: read conductor-state.json from a branch ───────────────────────

# Output JSON string of conductor-state from a branch, or "{}" if unavailable.
read_branch_state() {
  local branch="$1"
  local raw
  raw=$(git -C "$PROJECT_DIR" show "$branch:.autonomous/conductor-state.json" 2>/dev/null) || { echo "{}"; return 0; }
  # Validate JSON
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(json.dumps(d))
except Exception:
    print('{}')
" "$raw"
}

# Get the date of the first commit unique to a branch (after diverging from any base).
# Falls back to the branch tip date if merge-base fails.
branch_creation_date() {
  local branch="$1"
  local date=""
  # Try to find the first commit after diverging from main/master
  for base in main master; do
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$base" 2>/dev/null; then
      local mb
      mb=$(git -C "$PROJECT_DIR" merge-base "$base" "$branch" 2>/dev/null) || continue
      date=$(git -C "$PROJECT_DIR" log --format="%aI" --reverse "$mb..$branch" 2>/dev/null | head -1)
      if [ -n "$date" ]; then
        echo "$date"
        return 0
      fi
    fi
  done
  # Fallback: tip commit date
  date=$(git -C "$PROJECT_DIR" log -1 --format="%aI" "$branch" 2>/dev/null) || echo ""
  echo "$date"
}

# Count commits unique to a branch (after diverging from base)
branch_commit_count() {
  local branch="$1"
  for base in main master; do
    if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$base" 2>/dev/null; then
      local mb
      mb=$(git -C "$PROJECT_DIR" merge-base "$base" "$branch" 2>/dev/null) || continue
      git -C "$PROJECT_DIR" rev-list --count "$mb..$branch" 2>/dev/null
      return 0
    fi
  done
  # Fallback: total commits on the branch
  git -C "$PROJECT_DIR" rev-list --count "$branch" 2>/dev/null || echo "0"
}

# ── Mode: list all auto/ branches ───────────────────────────────────────

list_sessions() {
  local branches
  branches=$(git -C "$PROJECT_DIR" branch --list 'auto/*' --format='%(refname:short)' 2>/dev/null) || true

  if [ -z "$branches" ]; then
    if [ "$JSON_MODE" = true ]; then
      echo "[]"
    else
      echo "No auto/ branches found."
    fi
    return 0
  fi

  python3 -c "
import json, sys, subprocess

project_dir = sys.argv[1]
branch_list = sys.argv[2].strip().split('\n')
json_mode = sys.argv[3] == 'true'

def git(*args):
    r = subprocess.run(['git'] + list(args), capture_output=True, text=True, cwd=project_dir)
    return r.stdout.strip()

def read_state(branch):
    try:
        raw = git('show', branch + ':.autonomous/conductor-state.json')
        if not raw:
            return {}
        return json.loads(raw)
    except Exception:
        return {}

def branch_date(branch):
    for base in ['main', 'master']:
        try:
            r = subprocess.run(['git', 'show-ref', '--verify', '--quiet', 'refs/heads/' + base],
                             capture_output=True, cwd=project_dir)
            if r.returncode != 0:
                continue
            mb = git('merge-base', base, branch)
            if not mb:
                continue
            date = git('log', '--format=%aI', '--reverse', mb + '..' + branch)
            first = date.split('\n')[0] if date else ''
            if first:
                return first
        except Exception:
            continue
    # Fallback: tip date
    return git('log', '-1', '--format=%aI', branch) or 'unknown'

def commit_count(branch):
    for base in ['main', 'master']:
        try:
            r = subprocess.run(['git', 'show-ref', '--verify', '--quiet', 'refs/heads/' + base],
                             capture_output=True, cwd=project_dir)
            if r.returncode != 0:
                continue
            mb = git('merge-base', base, branch)
            if not mb:
                continue
            return int(git('rev-list', '--count', mb + '..' + branch) or '0')
        except Exception:
            continue
    try:
        return int(git('rev-list', '--count', branch) or '0')
    except Exception:
        return 0

sessions = []
for branch in branch_list:
    if not branch.strip():
        continue
    state = read_state(branch)
    date = branch_date(branch)
    commits = commit_count(branch)

    sprint_count = len(state.get('sprints', []))
    phase = state.get('phase', 'no data')
    mission = state.get('mission', '')
    cost = state.get('session_cost_usd', None)

    sessions.append({
        'branch': branch,
        'date': date,
        'sprint_count': sprint_count,
        'phase': phase,
        'total_commits': commits,
        'cost': cost,
        'mission': mission
    })

# Sort by date descending
sessions.sort(key=lambda s: s['date'] or '', reverse=True)

if json_mode:
    print(json.dumps(sessions, indent=2))
else:
    if not sessions:
        print('No auto/ branches found.')
        sys.exit(0)

    sep = chr(9472) * 70
    print('Session History')
    print(sep)
    print(f\"\"\"{'Branch':<40} {'Date':<12} {'Sprints':>7} {'Phase':<11} {'Commits':>7} {'Cost':>8}\"\"\")
    print(sep)
    for s in sessions:
        date_short = s['date'][:10] if s['date'] and s['date'] != 'unknown' else 'unknown'
        cost_str = f\"\${s['cost']:.2f}\" if s['cost'] is not None else '-'
        branch_str = s['branch']
        if len(branch_str) > 38:
            branch_str = branch_str[:35] + '...'
        print(f\"{branch_str:<40} {date_short:<12} {s['sprint_count']:>7} {s['phase']:<11} {s['total_commits']:>7} {cost_str:>8}\")
    print(sep)
    print(f\"Total: {len(sessions)} session(s)\")
" "$PROJECT_DIR" "$branches" "$JSON_MODE"
}

# ── Mode: detail for a specific branch ──────────────────────────────────

detail_session() {
  local branch="$DETAIL_BRANCH"

  # Verify branch exists
  git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null \
    || die "branch not found: $branch"

  local state
  state=$(read_branch_state "$branch")
  local commits
  commits=$(branch_commit_count "$branch")
  local date
  date=$(branch_creation_date "$branch")

  python3 -c "
import json, sys

state = json.loads(sys.argv[1])
total_commits = int(sys.argv[2])
date = sys.argv[3]
branch = sys.argv[4]
json_mode = sys.argv[5] == 'true'

mission = state.get('mission', 'no data')
phase = state.get('phase', 'no data')
sprints = state.get('sprints', [])
sprint_count = len(sprints)
cost = state.get('session_cost_usd', None)
max_sprints = state.get('max_sprints', 0)

if json_mode:
    result = {
        'branch': branch,
        'date': date,
        'mission': mission,
        'phase': phase,
        'sprint_count': sprint_count,
        'max_sprints': max_sprints,
        'total_commits': total_commits,
        'cost': cost,
        'sprints': sprints
    }
    print(json.dumps(result, indent=2))
else:
    sep = chr(9472) * 60
    print(f'Session Detail: {branch}')
    print(sep)
    print(f'  Mission:     {mission}')
    print(f'  Date:        {date[:10] if date else \"unknown\"}')
    print(f'  Phase:       {phase}')
    print(f'  Sprints:     {sprint_count}/{max_sprints}')
    print(f'  Commits:     {total_commits}')
    cost_str = f'\${cost:.2f}' if cost is not None else '-'
    print(f'  Cost:        {cost_str}')
    print()

    if not sprints:
        print('  No sprint data available.')
    else:
        print(f\"\"\"  {'#':>3}  {'Direction':<30} {'Status':<12} {'Commits':>7} {'Rating'}\"\"\")
        print(f'  ' + chr(9472) * 56)
        for s in sprints:
            num = s.get('number', '?')
            direction = s.get('direction', '')
            if len(direction) > 28:
                direction = direction[:25] + '...'
            status = s.get('status', 'unknown')
            commit_count = len(s.get('commits', []))
            # Rating: direction_complete + quality_gate
            parts = []
            if s.get('direction_complete'):
                parts.append('complete')
            qg = s.get('quality_gate_passed')
            if qg is True:
                parts.append('QG:pass')
            elif qg is False:
                parts.append('QG:fail')
            rating = ', '.join(parts) if parts else '-'
            print(f'  {num:>3}  {direction:<30} {status:<12} {commit_count:>7} {rating}')
    print()
" "$state" "$commits" "$date" "$branch" "$JSON_MODE"
}

# ── Mode: compare two branches ──────────────────────────────────────────

compare_sessions() {
  local branch_a="$COMPARE_A"
  local branch_b="$COMPARE_B"

  # Verify both branches exist
  git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch_a" 2>/dev/null \
    || die "branch not found: $branch_a"
  git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch_b" 2>/dev/null \
    || die "branch not found: $branch_b"

  local state_a state_b commits_a commits_b date_a date_b
  state_a=$(read_branch_state "$branch_a")
  state_b=$(read_branch_state "$branch_b")
  commits_a=$(branch_commit_count "$branch_a")
  commits_b=$(branch_commit_count "$branch_b")
  date_a=$(branch_creation_date "$branch_a")
  date_b=$(branch_creation_date "$branch_b")

  python3 -c "
import json, sys

sa = json.loads(sys.argv[1])
sb = json.loads(sys.argv[2])
ca = int(sys.argv[3])
cb = int(sys.argv[4])
da = sys.argv[5]
db = sys.argv[6]
ba = sys.argv[7]
bb = sys.argv[8]
json_mode = sys.argv[9] == 'true'

def extract(state, commits, date, branch):
    return {
        'branch': branch,
        'date': date,
        'mission': state.get('mission', 'no data'),
        'phase': state.get('phase', 'no data'),
        'sprint_count': len(state.get('sprints', [])),
        'max_sprints': state.get('max_sprints', 0),
        'total_commits': commits,
        'cost': state.get('session_cost_usd', None)
    }

a = extract(sa, ca, da, ba)
b = extract(sb, cb, db, bb)

if json_mode:
    # Determine which is higher for each metric
    comparison = {
        'branch_a': a,
        'branch_b': b,
        'more_commits': ba if ca > cb else (bb if cb > ca else 'tie'),
        'more_sprints': ba if a['sprint_count'] > b['sprint_count'] else (bb if b['sprint_count'] > a['sprint_count'] else 'tie')
    }
    print(json.dumps(comparison, indent=2))
else:
    sep = chr(9472) * 60
    print('Session Comparison')
    print(sep)
    col = 25
    print(f\"\"\"{'Metric':<{col}} {ba:<20} {bb:<20}\"\"\")
    print(sep)
    print(f\"\"\"{'Date':<{col}} {(a['date'][:10] if a['date'] else 'unknown'):<20} {(b['date'][:10] if b['date'] else 'unknown'):<20}\"\"\")
    print(f\"\"\"{'Mission':<{col}} {(a['mission'][:18] if a['mission'] else '-'):<20} {(b['mission'][:18] if b['mission'] else '-'):<20}\"\"\")
    print(f\"\"\"{'Phase':<{col}} {a['phase']:<20} {b['phase']:<20}\"\"\")
    print(f\"\"\"{'Sprints':<{col}} {a['sprint_count']:<20} {b['sprint_count']:<20}\"\"\")
    print(f\"\"\"{'Commits':<{col}} {a['total_commits']:<20} {b['total_commits']:<20}\"\"\")
    cost_a = f\"\${a['cost']:.2f}\" if a['cost'] is not None else '-'
    cost_b = f\"\${b['cost']:.2f}\" if b['cost'] is not None else '-'
    print(f\"\"\"{'Cost':<{col}} {cost_a:<20} {cost_b:<20}\"\"\")
    print(sep)

    # Summary
    if ca > cb:
        print(f'{ba} had more commits ({ca} vs {cb})')
    elif cb > ca:
        print(f'{bb} had more commits ({cb} vs {ca})')
    else:
        print(f'Both had {ca} commits')

    sa_count = a['sprint_count']
    sb_count = b['sprint_count']
    if sa_count > sb_count:
        print(f'{ba} had more sprints ({sa_count} vs {sb_count})')
    elif sb_count > sa_count:
        print(f'{bb} had more sprints ({sb_count} vs {sa_count})')
    else:
        print(f'Both had {sa_count} sprints')
" "$state_a" "$state_b" "$commits_a" "$commits_b" "$date_a" "$date_b" "$branch_a" "$branch_b" "$JSON_MODE"
}

# ── Dispatch ─────────────────────────────────────────────────────────────

if [ -n "$DETAIL_BRANCH" ]; then
  detail_session
elif [ -n "$COMPARE_A" ]; then
  compare_sessions
else
  list_sessions
fi
