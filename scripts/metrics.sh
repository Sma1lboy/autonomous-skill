#!/usr/bin/env bash
# metrics.sh — Cross-session metrics dashboard.
# Collects session metrics from conductor-state.json into ~/.autonomous/metrics.json.
# Shows aggregate dashboards, trends, and per-project filtering.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: metrics.sh <command> <project-dir> [options]

Cross-session metrics dashboard. Collects and displays aggregate metrics
from autonomous sessions across projects.

Commands:
  collect <project-dir>
      Collect metrics from the current session's conductor-state.json and
      append to ~/.autonomous/metrics.json. Reads sprints, commits, cost,
      and quality gate data.

  show [options]
      Display aggregate metrics dashboard: total sessions, sprints, commits,
      cost, success rate, top projects.

  trend [options]
      Show productivity trends over time: sessions per week, average commits
      per sprint, cost efficiency.

Options:
  --json              Machine-readable JSON output (works with all commands)
  --project <name>    Filter by project name
  -h, --help          Show this help message

Metrics storage: ~/.autonomous/metrics.json (array of session objects)
Each session: {project, branch, timestamp, sprints, commits, files_changed,
              cost_usd, success_rate, tests_added, dimensions_improved}

Examples:
  bash scripts/metrics.sh collect ./my-project
  bash scripts/metrics.sh show
  bash scripts/metrics.sh show --json
  bash scripts/metrics.sh show --project my-project
  bash scripts/metrics.sh trend
  bash scripts/metrics.sh trend --json --project my-project
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || die "python3 required but not found"
command -v git &>/dev/null || die "git required but not found"

METRICS_DIR="${AUTONOMOUS_METRICS_DIR:-$HOME/.autonomous}"
METRICS_FILE="$METRICS_DIR/metrics.json"

# ── Parse arguments ──────────────────────────────────────────────────────

CMD="${1:-}"
[ -z "$CMD" ] && die "command is required. Use: collect|show|trend"
shift

PROJECT_DIR=""
JSON_MODE=false
FILTER_PROJECT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --project)
      [ -z "${2:-}" ] && die "--project requires a name"
      FILTER_PROJECT="$2"
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

# ── Ensure metrics directory and file exist ──────────────────────────────

ensure_metrics_file() {
  if [ ! -d "$METRICS_DIR" ]; then
    mkdir -p "$METRICS_DIR"
  fi
  if [ ! -f "$METRICS_FILE" ]; then
    echo '[]' > "$METRICS_FILE"
  fi
}

# ── Collect command ──────────────────────────────────────────────────────

cmd_collect() {
  [ -z "$PROJECT_DIR" ] && die "collect requires project-dir"
  [ -d "$PROJECT_DIR" ] || die "project dir not found: $PROJECT_DIR"

  local state_file="$PROJECT_DIR/.autonomous/conductor-state.json"
  [ -f "$state_file" ] || die "conductor-state.json not found in $PROJECT_DIR/.autonomous/"

  ensure_metrics_file

  python3 - "$PROJECT_DIR" "$state_file" "$METRICS_FILE" "$JSON_MODE" << 'PYEOF'
import json, os, sys, time, subprocess

project_dir = os.path.abspath(sys.argv[1])
state_file = sys.argv[2]
metrics_file = sys.argv[3]
json_mode = sys.argv[4] == "true"

project_name = os.path.basename(project_dir)

with open(state_file) as f:
    state = json.load(f)

sprints = state.get("sprints", [])

# Count total commits across all sprints
total_commits = 0
for s in sprints:
    commits = s.get("commits", [])
    if isinstance(commits, list):
        total_commits += len(commits)
    elif isinstance(commits, int):
        total_commits += commits

# Success rate: completed sprints / total sprints
total_sprints = len(sprints)
completed = sum(1 for s in sprints if s.get("status") in ("complete", "done", "merged"))
success_rate = round(completed / total_sprints, 2) if total_sprints > 0 else 0.0

# Cost
cost_usd = state.get("session_cost_usd", 0.0)
if not cost_usd:
    cost_usd = sum(s.get("cost_usd", 0) for s in sprints)

# Files changed: count via git diff if possible
files_changed = 0
try:
    base_branch = "main"
    current = subprocess.check_output(
        ["git", "-C", project_dir, "rev-parse", "--abbrev-ref", "HEAD"],
        stderr=subprocess.DEVNULL
    ).decode().strip()
    if current.startswith("auto/"):
        diff_out = subprocess.check_output(
            ["git", "-C", project_dir, "diff", "--name-only", f"{base_branch}...HEAD"],
            stderr=subprocess.DEVNULL
        ).decode().strip()
        if diff_out:
            files_changed = len(diff_out.splitlines())
except Exception:
    pass

# Tests added: count test files in diff
tests_added = 0
try:
    if current.startswith("auto/"):
        diff_out = subprocess.check_output(
            ["git", "-C", project_dir, "diff", "--name-only", f"{base_branch}...HEAD"],
            stderr=subprocess.DEVNULL
        ).decode().strip()
        for line in diff_out.splitlines():
            if "test" in line.lower():
                tests_added += 1
except Exception:
    pass

# Dimensions improved
dimensions_improved = []
dims = state.get("exploration_dimensions", {})
for dim, info in dims.items():
    if isinstance(info, dict) and info.get("audited"):
        dimensions_improved.append(dim)

# Branch
branch = ""
try:
    branch = subprocess.check_output(
        ["git", "-C", project_dir, "rev-parse", "--abbrev-ref", "HEAD"],
        stderr=subprocess.DEVNULL
    ).decode().strip()
except Exception:
    branch = state.get("session_id", "unknown")

session_entry = {
    "project": project_name,
    "branch": branch,
    "timestamp": int(time.time()),
    "sprints": total_sprints,
    "commits": total_commits,
    "files_changed": files_changed,
    "cost_usd": round(cost_usd, 4) if cost_usd else 0,
    "success_rate": success_rate,
    "tests_added": tests_added,
    "dimensions_improved": dimensions_improved
}

# Load existing metrics and append
with open(metrics_file) as f:
    metrics = json.load(f)

metrics.append(session_entry)

# Atomic write
tmp = metrics_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(metrics, f, indent=2)
os.replace(tmp, metrics_file)

if json_mode:
    print(json.dumps(session_entry, indent=2))
else:
    print(f"Collected metrics for '{project_name}':")
    print(f"  Sprints: {total_sprints} ({completed} completed)")
    print(f"  Commits: {total_commits}")
    print(f"  Files changed: {files_changed}")
    print(f"  Cost: ${cost_usd:.4f}")
    print(f"  Success rate: {success_rate:.0%}")
    print(f"  Tests added: {tests_added}")
    if dimensions_improved:
        print(f"  Dimensions improved: {', '.join(dimensions_improved)}")
PYEOF
}

# ── Show command ─────────────────────────────────────────────────────────

cmd_show() {
  ensure_metrics_file

  python3 - "$METRICS_FILE" "$JSON_MODE" "$FILTER_PROJECT" << 'PYEOF'
import json, sys

metrics_file = sys.argv[1]
json_mode = sys.argv[2] == "true"
filter_project = sys.argv[3] if len(sys.argv) > 3 else ""

with open(metrics_file) as f:
    metrics = json.load(f)

if filter_project:
    metrics = [m for m in metrics if m.get("project") == filter_project]

if not metrics:
    if json_mode:
        print(json.dumps({"sessions": 0, "message": "no metrics data"}))
    else:
        print("No metrics data found.")
    sys.exit(0)

total_sessions = len(metrics)
total_sprints = sum(m.get("sprints", 0) for m in metrics)
total_commits = sum(m.get("commits", 0) for m in metrics)
total_files = sum(m.get("files_changed", 0) for m in metrics)
total_cost = sum(m.get("cost_usd", 0) for m in metrics)
total_tests = sum(m.get("tests_added", 0) for m in metrics)
avg_success = sum(m.get("success_rate", 0) for m in metrics) / total_sessions if total_sessions else 0
avg_commits_per_sprint = total_commits / total_sprints if total_sprints else 0
avg_cost_per_sprint = total_cost / total_sprints if total_sprints else 0

# Project breakdown
projects = {}
for m in metrics:
    p = m.get("project", "unknown")
    if p not in projects:
        projects[p] = {"sessions": 0, "sprints": 0, "commits": 0, "cost": 0}
    projects[p]["sessions"] += 1
    projects[p]["sprints"] += m.get("sprints", 0)
    projects[p]["commits"] += m.get("commits", 0)
    projects[p]["cost"] += m.get("cost_usd", 0)

if json_mode:
    result = {
        "total_sessions": total_sessions,
        "total_sprints": total_sprints,
        "total_commits": total_commits,
        "total_files_changed": total_files,
        "total_cost_usd": round(total_cost, 4),
        "total_tests_added": total_tests,
        "avg_success_rate": round(avg_success, 2),
        "avg_commits_per_sprint": round(avg_commits_per_sprint, 2),
        "avg_cost_per_sprint": round(avg_cost_per_sprint, 4),
        "projects": projects
    }
    if filter_project:
        result["filter"] = filter_project
    print(json.dumps(result, indent=2))
else:
    title = "Metrics Dashboard"
    if filter_project:
        title += f" (project: {filter_project})"
    print(f"\n{'=' * 50}")
    print(f" {title}")
    print(f"{'=' * 50}")
    print(f"  Sessions:            {total_sessions}")
    print(f"  Total sprints:       {total_sprints}")
    print(f"  Total commits:       {total_commits}")
    print(f"  Files changed:       {total_files}")
    print(f"  Tests added:         {total_tests}")
    print(f"  Total cost:          ${total_cost:.4f}")
    print(f"  Avg success rate:    {avg_success:.0%}")
    print(f"  Avg commits/sprint:  {avg_commits_per_sprint:.1f}")
    print(f"  Avg cost/sprint:     ${avg_cost_per_sprint:.4f}")
    if len(projects) > 1:
        print(f"\n  {'Project':<25} {'Sessions':>8} {'Sprints':>8} {'Commits':>8} {'Cost':>10}")
        print(f"  {'-' * 25} {'-' * 8} {'-' * 8} {'-' * 8} {'-' * 10}")
        for p in sorted(projects, key=lambda x: projects[x]["sessions"], reverse=True):
            d = projects[p]
            print(f"  {p:<25} {d['sessions']:>8} {d['sprints']:>8} {d['commits']:>8} ${d['cost']:>9.4f}")
    print()
PYEOF
}

# ── Trend command ────────────────────────────────────────────────────────

cmd_trend() {
  ensure_metrics_file

  python3 - "$METRICS_FILE" "$JSON_MODE" "$FILTER_PROJECT" << 'PYEOF'
import json, sys, time
from collections import defaultdict

metrics_file = sys.argv[1]
json_mode = sys.argv[2] == "true"
filter_project = sys.argv[3] if len(sys.argv) > 3 else ""

with open(metrics_file) as f:
    metrics = json.load(f)

if filter_project:
    metrics = [m for m in metrics if m.get("project") == filter_project]

if not metrics:
    if json_mode:
        print(json.dumps({"weeks": [], "message": "no metrics data"}))
    else:
        print("No metrics data for trends.")
    sys.exit(0)

# Group by week (ISO week number)
weeks = defaultdict(lambda: {"sessions": 0, "sprints": 0, "commits": 0, "cost": 0, "success_sum": 0})
for m in metrics:
    ts = m.get("timestamp", 0)
    if ts == 0:
        continue
    t = time.gmtime(ts)
    week_key = f"{t.tm_year}-W{t.tm_yday // 7 + 1:02d}"
    w = weeks[week_key]
    w["sessions"] += 1
    w["sprints"] += m.get("sprints", 0)
    w["commits"] += m.get("commits", 0)
    w["cost"] += m.get("cost_usd", 0)
    w["success_sum"] += m.get("success_rate", 0)

# Sort by week
sorted_weeks = sorted(weeks.items())

if json_mode:
    result = []
    for week, data in sorted_weeks:
        avg_sr = data["success_sum"] / data["sessions"] if data["sessions"] else 0
        avg_cps = data["commits"] / data["sprints"] if data["sprints"] else 0
        result.append({
            "week": week,
            "sessions": data["sessions"],
            "sprints": data["sprints"],
            "commits": data["commits"],
            "cost_usd": round(data["cost"], 4),
            "avg_success_rate": round(avg_sr, 2),
            "avg_commits_per_sprint": round(avg_cps, 2)
        })
    print(json.dumps(result, indent=2))
else:
    title = "Productivity Trends"
    if filter_project:
        title += f" (project: {filter_project})"
    print(f"\n{'=' * 60}")
    print(f" {title}")
    print(f"{'=' * 60}")
    print(f"  {'Week':<12} {'Sessions':>8} {'Sprints':>8} {'Commits':>8} {'Cost':>10} {'Success':>8}")
    print(f"  {'-' * 12} {'-' * 8} {'-' * 8} {'-' * 8} {'-' * 10} {'-' * 8}")
    for week, data in sorted_weeks:
        avg_sr = data["success_sum"] / data["sessions"] if data["sessions"] else 0
        print(f"  {week:<12} {data['sessions']:>8} {data['sprints']:>8} {data['commits']:>8} ${data['cost']:>9.4f} {avg_sr:>7.0%}")
    print()
PYEOF
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "$CMD" in
  collect)  cmd_collect ;;
  show)     cmd_show ;;
  trend)    cmd_trend ;;
  *)        die "unknown command: $CMD. Use: collect|show|trend" ;;
esac
