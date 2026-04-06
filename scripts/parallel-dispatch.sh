#!/usr/bin/env bash
# parallel-dispatch.sh — Dispatch N sprints simultaneously in separate worktrees.
#
# Usage: bash parallel-dispatch.sh <project_dir> <script_dir> <session_branch> <direction_1> [direction_2] ... [direction_N]
#
# For each direction:
#   1. Register sprint via conductor-state.sh sprint-start
#   2. Create worktree via worktree-manager.sh create
#   3. Build sprint prompt via build-sprint-prompt.sh (in worktree)
#   4. Dispatch via dispatch.sh (DISPATCH_ISOLATION=branch since worktree provides isolation)
#   5. Track in .autonomous/parallel-tracking.json
#
# After all dispatched, monitors via parallel-monitor.sh, merges results sequentially.
# Writes .autonomous/parallel-results.json with per-sprint results.
#
# Layer: conductor

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: bash parallel-dispatch.sh <project_dir> <script_dir> <session_branch> <direction_1> [direction_2] ...

Dispatch N sprints simultaneously in separate worktrees, monitor all,
and merge results sequentially back to the session branch.

Arguments:
  project_dir      Main project directory
  script_dir       Path to autonomous-skill root (contains scripts/, SPRINT.md)
  session_branch   Session branch to merge results into (e.g., auto/session-12345)
  direction_N      One or more sprint direction strings

Output:
  Per-sprint status lines and .autonomous/parallel-results.json

Environment:
  MONITOR_MAX_POLLS   Passed through to parallel-monitor.sh (default: 225)

Examples:
  bash parallel-dispatch.sh /project /skill auto/session-123 "add auth" "add tests"
  bash parallel-dispatch.sh /project /skill auto/session-123 "fix bug #42"
EOF
  exit 0
}

# Handle --help / -h
case "${1:-}" in
  -h|--help|help) usage ;;
esac

PROJECT_DIR="${1:-}"
[ -z "$PROJECT_DIR" ] && die "Usage: parallel-dispatch.sh <project_dir> <script_dir> <session_branch> <direction_1> [...]"
[ ! -d "$PROJECT_DIR" ] && die "Invalid project directory: $PROJECT_DIR"
shift

SCRIPT_DIR="${1:-}"
[ -z "$SCRIPT_DIR" ] && die "Usage: parallel-dispatch.sh <project_dir> <script_dir> <session_branch> <direction_1> [...]"
shift

SESSION_BRANCH="${1:-}"
[ -z "$SESSION_BRANCH" ] && die "Usage: parallel-dispatch.sh <project_dir> <script_dir> <session_branch> <direction_1> [...]"
shift

# Remaining args are directions
DIRECTIONS=("$@")
[ "${#DIRECTIONS[@]}" -eq 0 ] && die "At least one sprint direction required"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$PROJECT_DIR/.autonomous"
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"

# ── Phase 1: Register sprints + create worktrees + dispatch ──────────────

SPRINT_NUMS=()
WORKTREE_PATHS=()
WORKTREE_BRANCHES=()

for direction in "${DIRECTIONS[@]}"; do
  # Register sprint to get sprint number
  SPRINT_NUM=$(bash "$SELF_DIR/conductor-state.sh" sprint-start "$PROJECT_DIR" "$direction")
  SPRINT_NUMS+=("$SPRINT_NUM")

  # Create worktree branch
  WT_BRANCH="auto/parallel-sprint-${SPRINT_NUM}"
  WORKTREE_BRANCHES+=("$WT_BRANCH")

  WT_OUT=$(bash "$SELF_DIR/worktree-manager.sh" create "$PROJECT_DIR" "$WT_BRANCH" 2>&1) || die "Worktree creation failed for sprint $SPRINT_NUM: $WT_OUT"
  WT_PATH=$(echo "$WT_OUT" | grep '^WORKTREE_PATH=' | head -1 | cut -d= -f2-)
  [ -z "$WT_PATH" ] && die "Could not parse worktree path for sprint $SPRINT_NUM"
  WORKTREE_PATHS+=("$WT_PATH")

  # Ensure .autonomous dir exists in worktree
  mkdir -p "$WT_PATH/.autonomous" && chmod 700 "$WT_PATH/.autonomous"

  # Build sprint prompt — use worktree path as project dir
  bash "$SELF_DIR/build-sprint-prompt.sh" "$WT_PATH" "$SCRIPT_DIR" "$SPRINT_NUM" "$direction" >/dev/null 2>&1

  # Dispatch in worktree — use branch isolation since worktree already provides isolation
  DISPATCH_ISOLATION=branch bash "$SELF_DIR/dispatch.sh" "$WT_PATH" "$WT_PATH/.autonomous/sprint-prompt.md" "parallel-sprint-${SPRINT_NUM}" >/dev/null 2>&1 || true

  echo "DISPATCHED: sprint=$SPRINT_NUM worktree=$WT_PATH direction=$direction"
done

# Write tracking file
python3 -c "
import json, sys

sprint_nums = json.loads(sys.argv[1])
worktree_paths = json.loads(sys.argv[2])
worktree_branches = json.loads(sys.argv[3])
directions = json.loads(sys.argv[4])

tracking = []
for i in range(len(sprint_nums)):
    tracking.append({
        'sprint_num': sprint_nums[i],
        'worktree_path': worktree_paths[i],
        'worktree_branch': worktree_branches[i],
        'direction': directions[i],
        'status': 'running'
    })

with open(sys.argv[5], 'w') as f:
    json.dump(tracking, f, indent=2)
" "$(printf '%s\n' "${SPRINT_NUMS[@]}" | python3 -c "import sys,json; print(json.dumps([int(x.strip()) for x in sys.stdin if x.strip()]))")" \
  "$(printf '%s\n' "${WORKTREE_PATHS[@]}" | python3 -c "import sys,json; print(json.dumps([x.strip() for x in sys.stdin if x.strip()]))")" \
  "$(printf '%s\n' "${WORKTREE_BRANCHES[@]}" | python3 -c "import sys,json; print(json.dumps([x.strip() for x in sys.stdin if x.strip()]))")" \
  "$(printf '%s\n' "${DIRECTIONS[@]}" | python3 -c "import sys,json; print(json.dumps([x.strip() for x in sys.stdin if x.strip()]))")" \
  "$STATE_DIR/parallel-tracking.json"

# Record parallel group in conductor state
NUMS_JSON=$(printf '%s\n' "${SPRINT_NUMS[@]}" | python3 -c "import sys,json; print(json.dumps([int(x.strip()) for x in sys.stdin if x.strip()]))")
bash "$SELF_DIR/conductor-state.sh" mark-parallel "$PROJECT_DIR" "$NUMS_JSON" >/dev/null 2>&1 || true

echo "ALL_DISPATCHED: ${#DIRECTIONS[@]} sprints"

# ── Phase 2: Monitor all worktrees ──────────────────────────────────────

MONITOR_OUT=$(bash "$SELF_DIR/parallel-monitor.sh" "$PROJECT_DIR" "${WORKTREE_PATHS[@]}" 2>&1) || true
echo "$MONITOR_OUT"

# ── Phase 3: Merge results sequentially ─────────────────────────────────

RESULTS=()
MERGE_ERRORS=0

for i in "${!SPRINT_NUMS[@]}"; do
  SPRINT_NUM="${SPRINT_NUMS[$i]}"
  WT_PATH="${WORKTREE_PATHS[$i]}"
  WT_BRANCH="${WORKTREE_BRANCHES[$i]}"
  DIRECTION="${DIRECTIONS[$i]}"

  # Read sprint summary from worktree
  SUMMARY_FILE="$WT_PATH/.autonomous/sprint-summary.json"
  if [ -f "$SUMMARY_FILE" ]; then
    SUMMARY_JSON=$(cat "$SUMMARY_FILE")
    STATUS=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('status','unknown'))" "$SUMMARY_JSON" 2>/dev/null || echo "unknown")
  else
    SUMMARY_JSON='{"status":"unknown","summary":"No summary file found"}'
    STATUS="unknown"
  fi

  # Attempt merge back to session branch
  MERGE_OK="true"
  MERGE_MSG=""
  if bash "$SELF_DIR/worktree-manager.sh" merge "$PROJECT_DIR" "$WT_BRANCH" "$SESSION_BRANCH" >/dev/null 2>&1; then
    MERGE_MSG="merged"
  else
    MERGE_OK="false"
    MERGE_MSG="merge_failed"
    ((MERGE_ERRORS++)) || true
    # Destroy worktree even on merge failure
    bash "$SELF_DIR/worktree-manager.sh" destroy "$PROJECT_DIR" "$WT_BRANCH" >/dev/null 2>&1 || true
  fi

  RESULTS+=("{\"sprint_num\":$SPRINT_NUM,\"direction\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$DIRECTION"),\"status\":\"$STATUS\",\"merged\":$MERGE_OK,\"merge_msg\":\"$MERGE_MSG\"}")

  echo "SPRINT_RESULT: sprint=$SPRINT_NUM status=$STATUS merged=$MERGE_OK"
done

# Write results JSON
python3 -c "
import json, sys
state_dir = sys.argv[1]
results = []
for arg in sys.argv[2:]:
    results.append(json.loads(arg))
with open(state_dir + '/parallel-results.json', 'w') as f:
    json.dump(results, f, indent=2)
print(json.dumps(results, indent=2))
" "$STATE_DIR" "${RESULTS[@]}"

if [ "$MERGE_ERRORS" -gt 0 ]; then
  echo "WARNING: $MERGE_ERRORS merge(s) failed"
  exit 1
fi

exit 0
