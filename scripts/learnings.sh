#!/usr/bin/env bash
# learnings.sh — Conductor learning system: stores sprint outcomes for cross-session learning.
# Records sprint direction/status/commits from conductor-state.json into ~/.autonomous/learnings.json.
# Supports querying, suggesting refined directions, and pruning old entries.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: learnings.sh <command> [options]

Cross-session learning system. Records sprint outcomes and uses them to
suggest refined directions for future sprints.

Commands:
  record <project-dir>
      Read conductor-state.json, extract each sprint's direction + status +
      commits count + dimension, append to ~/.autonomous/learnings.json.
      Max 200 entries (FIFO overflow: oldest dropped before recording).

  query [options]
      Filter learnings. Default: human-readable table output.

  suggest [options]
      Analyze past learnings to suggest refined directions. Finds dimensions
      with most failures or fewest commits, suggests avoiding failed approaches
      and building on successful ones. Outputs 1-3 suggestion lines.

  prune [options]
      Remove entries older than N days (default: 90). Reports count pruned.

Options:
  --dimension <dim>   Filter by exploration dimension (query/suggest)
  --status <status>   Filter by sprint status (query)
  --project <name>    Filter by project name (query/suggest)
  --max-age <days>    Max age in days for prune (default: 90)
  --json              Machine-readable JSON output (query)
  -h, --help          Show this help message

Storage: ~/.autonomous/learnings.json (array of learning entries)
Override: AUTONOMOUS_LEARNINGS_DIR env var

Each entry: {project, timestamp, direction, status, commits, dimension, sprint_number}

Examples:
  bash scripts/learnings.sh record ./my-project
  bash scripts/learnings.sh query --dimension test_coverage
  bash scripts/learnings.sh query --status complete --json
  bash scripts/learnings.sh query --project my-project
  bash scripts/learnings.sh suggest
  bash scripts/learnings.sh suggest --dimension security
  bash scripts/learnings.sh prune
  bash scripts/learnings.sh prune --max-age 30
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || die "python3 required but not found"

LEARNINGS_DIR="${AUTONOMOUS_LEARNINGS_DIR:-$HOME/.autonomous}"
LEARNINGS_FILE="$LEARNINGS_DIR/learnings.json"
MAX_ENTRIES=200

# ── Parse arguments ──────────────────────────────────────────────────────

CMD="${1:-}"
[ -z "$CMD" ] && die "command is required. Use: record|query|suggest|prune"
shift

PROJECT_DIR=""
JSON_MODE=false
FILTER_DIMENSION=""
FILTER_STATUS=""
FILTER_PROJECT=""
MAX_AGE_DAYS=90

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --dimension)
      [ -z "${2:-}" ] && die "--dimension requires a value"
      FILTER_DIMENSION="$2"
      shift 2
      ;;
    --status)
      [ -z "${2:-}" ] && die "--status requires a value"
      FILTER_STATUS="$2"
      shift 2
      ;;
    --project)
      [ -z "${2:-}" ] && die "--project requires a name"
      FILTER_PROJECT="$2"
      shift 2
      ;;
    --max-age)
      [ -z "${2:-}" ] && die "--max-age requires a number"
      MAX_AGE_DAYS="$2"
      shift 2
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

# ── Ensure learnings directory and file exist ────────────────────────────

ensure_learnings_file() {
  if [ ! -d "$LEARNINGS_DIR" ]; then
    mkdir -p "$LEARNINGS_DIR"
  fi
  if [ ! -f "$LEARNINGS_FILE" ]; then
    echo '[]' > "$LEARNINGS_FILE"
  fi
}

# ── Record command ───────────────────────────────────────────────────────

cmd_record() {
  [ -z "$PROJECT_DIR" ] && die "record requires project-dir"
  [ -d "$PROJECT_DIR" ] || die "project dir not found: $PROJECT_DIR"

  local state_file="$PROJECT_DIR/.autonomous/conductor-state.json"
  [ -f "$state_file" ] || die "conductor-state.json not found in $PROJECT_DIR/.autonomous/"

  ensure_learnings_file

  python3 - "$PROJECT_DIR" "$state_file" "$LEARNINGS_FILE" "$MAX_ENTRIES" "$JSON_MODE" << 'PYEOF'
import json, os, sys, time

project_dir = os.path.abspath(sys.argv[1])
state_file = sys.argv[2]
learnings_file = sys.argv[3]
max_entries = int(sys.argv[4])
json_mode = sys.argv[5] == "true"

project_name = os.path.basename(project_dir)

with open(state_file) as f:
    state = json.load(f)

sprints = state.get("sprints", [])

if not sprints:
    if json_mode:
        print(json.dumps({"recorded": 0, "message": "no sprints to record"}))
    else:
        print("No sprints to record.")
    sys.exit(0)

# Load existing learnings
with open(learnings_file) as f:
    learnings = json.load(f)

if not isinstance(learnings, list):
    learnings = []

now = int(time.time())
new_entries = []

for s in sprints:
    direction = s.get("direction", "")
    status = s.get("status", "unknown")
    commits = s.get("commits", 0)
    if isinstance(commits, list):
        commits = len(commits)
    dimension = s.get("dimension", None)
    if dimension is None:
        dimension = s.get("exploration_dimension", None)
    sprint_number = s.get("number", 0)

    entry = {
        "project": project_name,
        "timestamp": now,
        "direction": direction,
        "status": status,
        "commits": commits,
        "dimension": dimension,
        "sprint_number": sprint_number
    }
    new_entries.append(entry)

# FIFO overflow: drop oldest entries to make room
total_after = len(learnings) + len(new_entries)
if total_after > max_entries:
    overflow = total_after - max_entries
    learnings = learnings[overflow:]

learnings.extend(new_entries)

# Atomic write
tmp = learnings_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(learnings, f, indent=2)
os.replace(tmp, learnings_file)

if json_mode:
    print(json.dumps({"recorded": len(new_entries), "total": len(learnings)}))
else:
    print(f"Recorded {len(new_entries)} sprint(s) from '{project_name}'")
    print(f"Total learnings: {len(learnings)}")
PYEOF
}

# ── Query command ────────────────────────────────────────────────────────

cmd_query() {
  ensure_learnings_file

  python3 - "$LEARNINGS_FILE" "$JSON_MODE" "$FILTER_DIMENSION" "$FILTER_STATUS" "$FILTER_PROJECT" << 'PYEOF'
import json, sys

learnings_file = sys.argv[1]
json_mode = sys.argv[2] == "true"
filter_dim = sys.argv[3] if sys.argv[3] else ""
filter_status = sys.argv[4] if sys.argv[4] else ""
filter_project = sys.argv[5] if sys.argv[5] else ""

with open(learnings_file) as f:
    learnings = json.load(f)

if not isinstance(learnings, list):
    learnings = []

# Apply filters
if filter_dim:
    learnings = [e for e in learnings if e.get("dimension") == filter_dim]
if filter_status:
    learnings = [e for e in learnings if e.get("status") == filter_status]
if filter_project:
    learnings = [e for e in learnings if e.get("project") == filter_project]

if json_mode:
    print(json.dumps(learnings, indent=2))
else:
    if not learnings:
        print("No matching learnings found.")
        sys.exit(0)

    import time
    print(f"{'Project':<20} {'Sprint':>6} {'Status':<12} {'Commits':>7} {'Dimension':<16} {'Direction'}")
    print("-" * 90)
    for e in learnings:
        proj = e.get("project", "?")
        if len(proj) > 18:
            proj = proj[:15] + "..."
        sprint = e.get("sprint_number", "?")
        status = e.get("status", "?")
        commits = e.get("commits", 0)
        dim = e.get("dimension") or "-"
        direction = e.get("direction", "")
        if len(direction) > 30:
            direction = direction[:27] + "..."
        print(f"{proj:<20} {sprint:>6} {status:<12} {commits:>7} {dim:<16} {direction}")
    print(f"\nTotal: {len(learnings)} entries")
PYEOF
}

# ── Suggest command ──────────────────────────────────────────────────────

cmd_suggest() {
  ensure_learnings_file

  python3 - "$LEARNINGS_FILE" "$FILTER_DIMENSION" "$FILTER_PROJECT" << 'PYEOF'
import json, sys
from collections import defaultdict

learnings_file = sys.argv[1]
filter_dim = sys.argv[2] if sys.argv[2] else ""
filter_project = sys.argv[3] if sys.argv[3] else ""

with open(learnings_file) as f:
    learnings = json.load(f)

if not isinstance(learnings, list):
    learnings = []

if filter_project:
    learnings = [e for e in learnings if e.get("project") == filter_project]

if not learnings:
    print("No learnings data available for suggestions.")
    sys.exit(0)

# If filtering by dimension, narrow scope
if filter_dim:
    dim_learnings = [e for e in learnings if e.get("dimension") == filter_dim]
    if not dim_learnings:
        print(f"No learnings for dimension '{filter_dim}'.")
        sys.exit(0)
else:
    dim_learnings = learnings

# Analyze by dimension
dim_stats = defaultdict(lambda: {"total": 0, "failed": 0, "commits": 0, "directions_failed": [], "directions_succeeded": []})

for e in dim_learnings:
    dim = e.get("dimension") or "general"
    dim_stats[dim]["total"] += 1
    status = e.get("status", "")
    commits = e.get("commits", 0)
    dim_stats[dim]["commits"] += commits
    direction = e.get("direction", "")
    if status in ("failed", "error", "timeout", "retry"):
        dim_stats[dim]["failed"] += 1
        if direction and direction not in dim_stats[dim]["directions_failed"]:
            dim_stats[dim]["directions_failed"].append(direction)
    elif status in ("complete", "done", "merged") and commits > 0:
        if direction and direction not in dim_stats[dim]["directions_succeeded"]:
            dim_stats[dim]["directions_succeeded"].append(direction)

suggestions = []

# Find dimensions with high failure rates
for dim, stats in sorted(dim_stats.items(), key=lambda x: -x[1]["failed"]):
    if stats["failed"] == 0:
        continue
    fail_rate = stats["failed"] / stats["total"] if stats["total"] > 0 else 0
    if fail_rate >= 0.5 and stats["total"] >= 2:
        failed_dirs = stats["directions_failed"][:2]
        failed_str = ", ".join(f"'{d[:40]}'" for d in failed_dirs)
        suggestions.append(f"Dimension '{dim}' has {fail_rate:.0%} failure rate. Avoid approaches like: {failed_str}")
        if len(suggestions) >= 3:
            break

# Find dimensions with low commit output
if len(suggestions) < 3:
    for dim, stats in sorted(dim_stats.items(), key=lambda x: x[1]["commits"] / max(x[1]["total"], 1)):
        if stats["total"] == 0:
            continue
        avg_commits = stats["commits"] / stats["total"]
        if avg_commits < 1 and stats["total"] >= 2:
            suggestions.append(f"Dimension '{dim}' averages {avg_commits:.1f} commits/sprint. Consider smaller, more focused tasks.")
            if len(suggestions) >= 3:
                break

# Suggest building on successful approaches
if len(suggestions) < 3:
    for dim, stats in sorted(dim_stats.items(), key=lambda x: -x[1]["commits"]):
        if stats["directions_succeeded"]:
            good_dir = stats["directions_succeeded"][-1][:50]
            suggestions.append(f"Build on successful approach in '{dim}': '{good_dir}'")
            if len(suggestions) >= 3:
                break

if not suggestions:
    print("No specific suggestions — learnings look balanced.")
else:
    for s in suggestions:
        print(s)
PYEOF
}

# ── Prune command ────────────────────────────────────────────────────────

cmd_prune() {
  ensure_learnings_file

  # Validate max-age
  python3 -c "
import sys
v = int(sys.argv[1])
if v < 0:
    raise ValueError('negative')
" "$MAX_AGE_DAYS" 2>/dev/null || die "max-age must be a non-negative integer, got: $MAX_AGE_DAYS"

  python3 - "$LEARNINGS_FILE" "$MAX_AGE_DAYS" << 'PYEOF'
import json, os, sys, time

learnings_file = sys.argv[1]
max_age_days = int(sys.argv[2])

with open(learnings_file) as f:
    learnings = json.load(f)

if not isinstance(learnings, list):
    learnings = []

cutoff = int(time.time()) - (max_age_days * 86400)

kept = []
pruned = 0
for e in learnings:
    ts = e.get("timestamp", 0)
    if ts < cutoff:
        pruned += 1
    else:
        kept.append(e)

# Atomic write
tmp = learnings_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(kept, f, indent=2)
os.replace(tmp, learnings_file)

print(f"Pruned {pruned} entries older than {max_age_days} days.")
print(f"Remaining: {len(kept)} entries.")
PYEOF
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "$CMD" in
  record)  cmd_record ;;
  query)   cmd_query ;;
  suggest) cmd_suggest ;;
  prune)   cmd_prune ;;
  *)       die "unknown command: $CMD. Use: record|query|suggest|prune" ;;
esac
