#!/usr/bin/env bash
# status.sh — Quick status check for autonomous-skill sessions.
# Shows active/latest session branch, commits, cost, and recent activity.
#
# Usage: status.sh [PROJECT_DIR] [--json]
set -euo pipefail

PROJECT_DIR="."
OUTPUT_JSON=0

for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT_JSON=1 ;;
    *) [ -d "$arg" ] && PROJECT_DIR="$arg" ;;
  esac
done

# ─── Dependency check ─────────────────────────────────────────────
for dep in jq git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "[status] ERROR: $dep not found" >&2; exit 1; }
done

# ─── Resolve project ──────────────────────────────────────────────
if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "[status] ERROR: not a git repo" >&2
  exit 1
fi

SLUG=$(basename "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")")
DATA_DIR="${AUTONOMOUS_SKILL_HOME:-$HOME/.autonomous-skill}/projects/$SLUG"
LOG_FILE="$DATA_DIR/autonomous-log.jsonl"
SENTINEL_FILE="$DATA_DIR/.stop-autonomous"

# Detect main branch
MAIN_BRANCH=$(git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/main 2>/dev/null && echo "main" || echo "master")
if ! git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$MAIN_BRANCH" 2>/dev/null; then
  MAIN_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
fi

# ─── Session branches ────────────────────────────────────────────
# Find all auto/session-* branches, sorted newest first
BRANCHES=$(git -C "$PROJECT_DIR" for-each-ref --sort=-creatordate --format='%(refname:short)' 'refs/heads/auto/session-*' 2>/dev/null || true)
BRANCH_COUNT=$(echo "$BRANCHES" | grep -c 'auto/session' 2>/dev/null) || BRANCH_COUNT=0
LATEST_BRANCH=$(echo "$BRANCHES" | head -1)

# Check if current branch is a session branch
CURRENT_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "")
ACTIVE_SESSION=""
if echo "$CURRENT_BRANCH" | grep -qE '^auto/session-'; then
  ACTIVE_SESSION="$CURRENT_BRANCH"
fi

# ─── Latest branch stats ─────────────────────────────────────────
LATEST_COMMITS=0
LATEST_FILES=""
LATEST_LAST_COMMIT=""
LATEST_LAST_COMMIT_AGO=""

if [ -n "$LATEST_BRANCH" ]; then
  LATEST_COMMITS=$(git -C "$PROJECT_DIR" rev-list --count "$MAIN_BRANCH..$LATEST_BRANCH" 2>/dev/null || echo 0)
  LATEST_FILES=$(git -C "$PROJECT_DIR" diff --stat "$MAIN_BRANCH..$LATEST_BRANCH" 2>/dev/null | tail -1 | grep -oE '[0-9]+ file' | head -1 || echo "0 file")
  [ -z "$LATEST_FILES" ] && LATEST_FILES="0 files"
  LATEST_LAST_COMMIT=$(git -C "$PROJECT_DIR" log -1 --format='%s' "$LATEST_BRANCH" 2>/dev/null || echo "")
  LATEST_LAST_COMMIT_AGO=$(git -C "$PROJECT_DIR" log -1 --format='%cr' "$LATEST_BRANCH" 2>/dev/null || echo "unknown")
fi

# ─── Log stats ────────────────────────────────────────────────────
TOTAL_SESSIONS=0
TOTAL_COST="0"
TOTAL_COMMITS_ALL=0
TOTAL_ITERATIONS=0
LAST_SESSION_DATE=""
LAST_SESSION_STATUS=""

if [ -f "$LOG_FILE" ]; then
  # Aggregate from log
  STATS=$(jq -s '
    group_by(.session) as $groups |
    {
      sessions: ($groups | length),
      total_cost: ([.[].cost_usd] | map(select(. > 0)) | add // 0 | . * 100 | round / 100),
      total_commits: ([$groups[] | [.[] | select(.event == "session_end") | .detail // "" |
        capture("commits=(?<n>[0-9]+)") | .n | tonumber] | first // 0] | add // 0),
      total_iterations: ([$groups[] | [.[] | select(.event == "session_end") | .detail // "" |
        capture("iterations=(?<n>[0-9]+)") | .n | tonumber] | first // 0] | add // 0),
      last_session_date: ($groups | last | [.[] | select(.event == "session_start")] | .[0].ts // null),
      last_session_had_commits: ($groups | last |
        [.[] | select(.event == "session_end") | .detail // "" |
        capture("commits=(?<n>[0-9]+)") | .n | tonumber] | first // 0 | . > 0)
    }
  ' "$LOG_FILE" 2>/dev/null || echo '{}')

  TOTAL_SESSIONS=$(echo "$STATS" | jq -r '.sessions // 0')
  TOTAL_COST=$(echo "$STATS" | jq -r '.total_cost // 0')
  TOTAL_COMMITS_ALL=$(echo "$STATS" | jq -r '.total_commits // 0')
  TOTAL_ITERATIONS=$(echo "$STATS" | jq -r '.total_iterations // 0')
  LAST_SESSION_DATE=$(echo "$STATS" | jq -r '.last_session_date // empty' 2>/dev/null | cut -dT -f1 || echo "")
  LAST_HAD_COMMITS=$(echo "$STATS" | jq -r '.last_session_had_commits // false')
  if [ "$LAST_HAD_COMMITS" = "true" ]; then
    LAST_SESSION_STATUS="ok"
  else
    LAST_SESSION_STATUS="no commits"
  fi
fi

# Sentinel check
SENTINEL_ACTIVE="false"
[ -f "$SENTINEL_FILE" ] && SENTINEL_ACTIVE="true"

# ─── JSON output ──────────────────────────────────────────────────
if [ "$OUTPUT_JSON" -eq 1 ]; then
  jq -n \
    --arg project "$SLUG" \
    --arg main_branch "$MAIN_BRANCH" \
    --arg active_session "$ACTIVE_SESSION" \
    --arg latest_branch "$LATEST_BRANCH" \
    --argjson latest_commits "$LATEST_COMMITS" \
    --arg latest_files "$LATEST_FILES" \
    --arg latest_last_commit "$LATEST_LAST_COMMIT" \
    --arg latest_last_commit_ago "$LATEST_LAST_COMMIT_AGO" \
    --argjson session_branches "$BRANCH_COUNT" \
    --argjson total_sessions "$TOTAL_SESSIONS" \
    --arg total_cost "$TOTAL_COST" \
    --argjson total_commits "$TOTAL_COMMITS_ALL" \
    --argjson total_iterations "$TOTAL_ITERATIONS" \
    --arg last_session_date "$LAST_SESSION_DATE" \
    --arg last_session_status "$LAST_SESSION_STATUS" \
    --argjson sentinel_active "$SENTINEL_ACTIVE" \
    --arg log_file "$LOG_FILE" \
    '{
      project: $project,
      main_branch: $main_branch,
      active_session: (if $active_session == "" then null else $active_session end),
      latest_branch: (if $latest_branch == "" then null else $latest_branch end),
      latest_commits: $latest_commits,
      latest_files: $latest_files,
      latest_last_commit: (if $latest_last_commit == "" then null else $latest_last_commit end),
      latest_last_commit_ago: $latest_last_commit_ago,
      session_branches: $session_branches,
      total_sessions: $total_sessions,
      total_cost: ($total_cost | tonumber),
      total_commits: $total_commits,
      total_iterations: $total_iterations,
      last_session_date: (if $last_session_date == "" then null else $last_session_date end),
      last_session_status: (if $last_session_status == "" then null else $last_session_status end),
      sentinel_active: $sentinel_active,
      log_file: $log_file
    }'
  exit 0
fi

# ─── Human-readable output ────────────────────────────────────────
echo "═══════════════════════════════════════════════════"
echo "  AUTONOMOUS STATUS — $SLUG"
echo "═══════════════════════════════════════════════════"
echo ""

# Active session
if [ -n "$ACTIVE_SESSION" ]; then
  echo "  Active session: $ACTIVE_SESSION"
else
  echo "  Active session: (none)"
fi

# Sentinel
if [ "$SENTINEL_ACTIVE" = "true" ]; then
  echo "  Stop sentinel:  ACTIVE (will stop after current iteration)"
fi

echo ""

# Latest branch info
if [ -n "$LATEST_BRANCH" ]; then
  echo "─── Latest Branch ──────────────────────────────────"
  echo "  Branch:      $LATEST_BRANCH"
  echo "  Commits:     $LATEST_COMMITS ahead of $MAIN_BRANCH"
  echo "  Files:       $LATEST_FILES changed"
  echo "  Last commit: $LATEST_LAST_COMMIT"
  echo "  Activity:    $LATEST_LAST_COMMIT_AGO"
  echo ""
else
  echo "  No session branches found."
  echo ""
fi

# Cumulative stats (from log)
if [ -f "$LOG_FILE" ]; then
  echo "─── Cumulative Stats ───────────────────────────────"
  echo "  Sessions:    $TOTAL_SESSIONS"
  echo "  Iterations:  $TOTAL_ITERATIONS"
  echo "  Commits:     $TOTAL_COMMITS_ALL"
  echo "  Total cost:  \$$TOTAL_COST"
  [ -n "$LAST_SESSION_DATE" ] && echo "  Last run:    $LAST_SESSION_DATE ($LAST_SESSION_STATUS)"
  echo ""
else
  echo "  No log file found. Run a session first."
  echo ""
fi

# Quick actions
echo "───────────────────────────────────────────────────"
if [ -n "$LATEST_BRANCH" ] && [ "$LATEST_COMMITS" -gt 0 ]; then
  echo "  Review: git log $MAIN_BRANCH..$LATEST_BRANCH --oneline"
  echo "  Merge:  git checkout $MAIN_BRANCH && git merge $LATEST_BRANCH"
fi
echo "  Report: bash scripts/report.sh"
echo "  JSON:   bash scripts/status.sh --json"
echo "───────────────────────────────────────────────────"
