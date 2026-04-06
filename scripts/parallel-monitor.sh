#!/usr/bin/env bash
# parallel-monitor.sh — Monitor N worktree directories for sprint completion.
#
# Usage: bash parallel-monitor.sh <project_dir> <worktree_path_1> [worktree_path_2] ... [worktree_path_N]
#
# Polls all worktree paths for .autonomous/sprint-summary.json.
# Prints SPRINT_DONE: <path> as each completes, ALL_SPRINTS_DONE when all finish.
# Respects MONITOR_MAX_POLLS env var (default 225, ~30min at 8s intervals).
# Checks for shutdown-reason.json sentinel for early termination.
#
# Layer: conductor

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: bash parallel-monitor.sh <project_dir> <worktree_path_1> [worktree_path_2] ...

Monitor N worktree directories simultaneously for sprint completion.

Arguments:
  project_dir     Main project directory (checked for shutdown sentinel)
  worktree_path   One or more worktree directories to monitor

Each worktree is checked for .autonomous/sprint-summary.json.
When found, prints: SPRINT_DONE: <worktree_path>
When all complete, prints: ALL_SPRINTS_DONE followed by a JSON summary.

Environment:
  MONITOR_MAX_POLLS   Max poll iterations before timeout (default: 225)
  MONITOR_INTERVAL    Sleep seconds between polls (default: 8)

Output on timeout: MONITOR_TIMEOUT with list of pending worktrees.
Output on shutdown: MONITOR_SHUTDOWN (shutdown-reason.json detected).

Examples:
  bash parallel-monitor.sh /project /tmp/wt1 /tmp/wt2 /tmp/wt3
  MONITOR_MAX_POLLS=10 bash parallel-monitor.sh /project /tmp/wt1
  MONITOR_INTERVAL=5 bash parallel-monitor.sh /project /tmp/wt1 /tmp/wt2
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

PROJECT_DIR="${1:-}"
[ -z "$PROJECT_DIR" ] && die "Usage: parallel-monitor.sh <project_dir> <worktree_path_1> [...]"
shift

# Collect worktree paths
WORKTREES=("$@")
[ "${#WORKTREES[@]}" -eq 0 ] && die "At least one worktree path required"

MAX_POLLS="${MONITOR_MAX_POLLS:-225}"
INTERVAL="${MONITOR_INTERVAL:-8}"
SHUTDOWN_FILE="$PROJECT_DIR/.autonomous/shutdown-reason.json"

# Track completion: indexed array (0=pending, 1=complete), bash 3.2 compatible
TOTAL="${#WORKTREES[@]}"
FINISHED=()
for (( i=0; i<TOTAL; i++ )); do
  FINISHED+=("0")
done

COMPLETED=0
POLL_COUNT=0

while [ "$COMPLETED" -lt "$TOTAL" ]; do
  ((POLL_COUNT++)) || true

  if [ "$POLL_COUNT" -gt "$MAX_POLLS" ]; then
    echo "MONITOR_TIMEOUT"
    for (( i=0; i<TOTAL; i++ )); do
      if [ "${FINISHED[$i]}" -eq 0 ]; then
        echo "PENDING: ${WORKTREES[$i]}"
      fi
    done
    exit 1
  fi

  # Check for shutdown sentinel
  if [ -f "$SHUTDOWN_FILE" ]; then
    echo "MONITOR_SHUTDOWN"
    for (( i=0; i<TOTAL; i++ )); do
      if [ "${FINISHED[$i]}" -eq 0 ]; then
        echo "PENDING: ${WORKTREES[$i]}"
      fi
    done
    exit 1
  fi

  # Check each pending worktree for summary file
  for (( i=0; i<TOTAL; i++ )); do
    [ "${FINISHED[$i]}" -eq 1 ] && continue

    SUMMARY_FILE="${WORKTREES[$i]}/.autonomous/sprint-summary.json"
    if [ -f "$SUMMARY_FILE" ]; then
      # shellcheck disable=SC2190
      FINISHED[i]=1
      echo "SPRINT_DONE: ${WORKTREES[$i]}"
      ((COMPLETED++)) || true
    fi
  done

  # If all done, break before sleeping
  [ "$COMPLETED" -ge "$TOTAL" ] && break

  sleep "$INTERVAL"
done

# All sprints complete — output summary
echo "ALL_SPRINTS_DONE"
python3 -c "
import json, sys

worktrees = sys.argv[1:]
results = []
for wt in worktrees:
    summary_file = wt + '/.autonomous/sprint-summary.json'
    try:
        with open(summary_file) as f:
            data = json.load(f)
    except Exception:
        data = {'status': 'unknown'}
    data['worktree'] = wt
    results.append(data)

print(json.dumps(results, indent=2))
" "${WORKTREES[@]}"
