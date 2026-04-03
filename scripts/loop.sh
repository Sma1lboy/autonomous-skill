#!/usr/bin/env bash
# loop.sh — Thin harness for autonomous CC iterations.
# All intelligence lives in CC's prompt. This script only handles:
# branching, spawning, timeout, cost logging, and interrupt handling.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Argument parsing ──────────────────────────────────────────────
DRY_RUN=0
PROJECT_DIR="."

MAX_COST_ARG=""
MAX_ITER_ARG=""
DIRECTION_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --max-cost) MAX_COST_ARG="$2"; shift 2 ;;
    --max-cost=*) MAX_COST_ARG="${1#*=}"; shift ;;
    --max-iterations) MAX_ITER_ARG="$2"; shift 2 ;;
    --max-iterations=*) MAX_ITER_ARG="${1#*=}"; shift ;;
    --direction) DIRECTION_ARG="$2"; shift 2 ;;
    --direction=*) DIRECTION_ARG="${1#*=}"; shift ;;
    -*) echo "[loop] ERROR: unknown flag: $1" >&2; exit 1 ;;
    *) PROJECT_DIR="$1"; shift ;;
  esac
done

MAX_ITERATIONS="${MAX_ITER_ARG:-${MAX_ITERATIONS:-50}}"  # 0 = unlimited; --max-iterations or env var
CC_TIMEOUT="${CC_TIMEOUT:-900}"
MAX_COST_USD="${MAX_COST_ARG:-${MAX_COST_USD:-0}}"  # 0 = unlimited; --max-cost or env var
DIRECTION="${DIRECTION_ARG:-${AUTONOMOUS_DIRECTION:-}}"

# Paths
SLUG=$(basename "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")")
DATA_DIR="${AUTONOMOUS_SKILL_HOME:-$HOME/.autonomous-skill}/projects/$SLUG"
LOG_FILE="$DATA_DIR/autonomous-log.jsonl"
SENTINEL_FILE="$DATA_DIR/.stop-autonomous"
OWNER_FILE="$PROJECT_DIR/OWNER.md"
SESSION_ID=$(date +%s)
SESSION_BRANCH="auto/session-$SESSION_ID"

mkdir -p "$DATA_DIR"

# ─── Dependency check ───────────────────────────────────────────────
for dep in jq claude git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "[loop] ERROR: $dep not found" >&2; exit 1; }
done

# ─── Signal handling ────────────────────────────────────────────────
INTERRUPTED=0
trap 'INTERRUPTED=1; echo "" ; echo "[loop] SIGINT — finishing current iteration..." >&2' INT
CC_STREAM_FILE=""
trap 'rm -f "$CC_STREAM_FILE" 2>/dev/null' EXIT

# ─── Logging ────────────────────────────────────────────────────────
log_event() {
  local event="$1" cost="${2:-0}" detail="${3:-}"
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"session\":\"$SESSION_ID\",\"iteration\":${ITERATION:-0},\"event\":\"$event\",\"cost_usd\":$cost,\"detail\":$(printf '%s' "$detail" | jq -Rs .)}" >> "$LOG_FILE"
}

# ─── Trace ──────────────────────────────────────────────────────────
write_trace() {
  local trace_file="$PROJECT_DIR/TRACE.md"
  local commit_count="$1"
  local iterations="$2"
  local cost="$3"
  local duration_fmt="$4"

  # Create header if file doesn't exist
  if [ ! -f "$trace_file" ]; then
    cat > "$trace_file" << 'EOF'
# TRACE — Session History

Automatically maintained by `loop.sh`. Each entry records one autonomous session.

EOF
  fi

  # Collect commits made in this session
  local commits_section=""
  if [ "$commit_count" -gt 0 ] 2>/dev/null; then
    commits_section=$(git -C "$PROJECT_DIR" log --oneline "$MAIN_BRANCH..$SESSION_BRANCH" 2>/dev/null | sed 's/^/  - `/' | sed 's/ /` /' || true)
  fi

  # Append session entry
  {
    echo "## Session $SESSION_ID"
    echo "- **Branch**: \`$SESSION_BRANCH\`"
    echo "- **Date**: $(date +%Y-%m-%d)"
    echo "- **Iterations**: $iterations"
    echo "- **Cost**: \$$cost"
    echo "- **Duration**: $duration_fmt"
    if [ -n "$DIRECTION" ]; then
      echo "- **Direction**: $DIRECTION"
    fi
    if [ -n "$commits_section" ]; then
      echo "- **Commits**:"
      echo "$commits_section"
    else
      echo "- **Commits**: _(none)_"
    fi
    echo ""
  } >> "$trace_file"
}

# ─── Owner persona ──────────────────────────────────────────────────
if [ ! -f "$OWNER_FILE" ]; then
  "$SCRIPT_DIR/persona.sh" "$PROJECT_DIR" >/dev/null 2>&1
fi
OWNER_CONTENT=""
[ -f "$OWNER_FILE" ] && OWNER_CONTENT=$(cat "$OWNER_FILE")

# ─── Build the autonomous prompt ────────────────────────────────────
build_prompt() {
  local iter="$1" max="$2"

  cat << 'PROMPT'
You are an autonomous project agent. You have FULL permissions to read, write, edit,
and run commands in this project.

YOUR WORKFLOW (every iteration):
1. Assess: Read TODOS.md, KANBAN.md, recent git log. Understand what's been done and what's next.
2. Pick ONE task — the highest-impact thing you can do right now.
3. Implement it. Read the relevant code, make the fix or improvement.
4. Verify: Run tests if they exist (check package.json scripts.test, Makefile, pytest, cargo test).
5. If tests pass (or no tests exist): git add + git commit with a clear message.
   If tests fail: revert your changes (git checkout -- .), log why, pick a different task.
6. Update TODOS.md: mark completed items [x], add new issues you discovered.

RULES:
- ONE task per iteration. Small, focused commits.
- ALWAYS commit your work if it's correct. Don't leave uncommitted changes.
- NEVER invoke /ship, /land-and-deploy, /careful, /guard.
- If you can't make progress on a task after 2 attempts, skip it and try something else.
- If you find bugs in the project, add them to TODOS.md and fix the most critical one.
PROMPT

  if [ -n "$DIRECTION" ]; then
    echo ""
    echo "SESSION DIRECTION: $DIRECTION"
    echo "Focus your work on this. Adapt tasks to fit this direction."
  fi

  echo ""
  echo "This is iteration $iter$([ "$max" -gt 0 ] && echo " of $max" || echo " (unlimited)")."
}

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════

# Verify git repo
git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || { echo "[loop] ERROR: not a git repo" >&2; exit 1; }

# Detect main branch
MAIN_BRANCH=$(git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/main 2>/dev/null && echo "main" || echo "master")
if ! git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$MAIN_BRANCH" 2>/dev/null; then
  MAIN_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
fi

# ─── Dry run ───────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  echo "═══════════════════════════════════════════════════"
  echo "  Autonomous Skill — DRY RUN"
  echo "  Project: $(basename "$PROJECT_DIR")"
  [ -n "$DIRECTION" ] && echo "  Direction: $DIRECTION"
  [ "$MAX_ITERATIONS" -eq 0 ] 2>/dev/null && echo "  Iterations: unlimited" || echo "  Iterations: $MAX_ITERATIONS"
  echo "  Timeout: ${CC_TIMEOUT}s per iteration"
  echo "$MAX_COST_USD" | grep -qE '^0(\.0+)?$' && echo "  Budget: unlimited" || echo "  Budget: \$$MAX_COST_USD"
  echo "  Branch: $SESSION_BRANCH (would create)"
  echo "═══════════════════════════════════════════════════"
  echo ""

  echo "─── Discovered Tasks ───"
  TASKS=$("$SCRIPT_DIR/discover.sh" "$PROJECT_DIR" 2>/dev/null || echo "[]")
  TASK_COUNT=$(echo "$TASKS" | jq 'length' 2>/dev/null || echo 0)

  if [ "$TASK_COUNT" -eq 0 ]; then
    echo "  (no tasks found)"
  else
    echo "$TASKS" | jq -r '.[] | "  [P\(.priority)] \(.description) (\(.source))"' 2>/dev/null
  fi

  echo ""
  echo "─── Owner Persona ───"
  if [ -f "$OWNER_FILE" ]; then
    echo "  Loaded from $OWNER_FILE"
  else
    echo "  Would auto-generate via persona.sh"
  fi

  echo ""
  echo "$TASK_COUNT task(s) found. Run without --dry-run to start."
  exit 0
fi

# Create session branch (always base off main)
if ! git -C "$PROJECT_DIR" checkout -b "$SESSION_BRANCH" "$MAIN_BRANCH" 2>/dev/null; then
  SESSION_BRANCH="auto/session-${SESSION_ID}-$$"
  git -C "$PROJECT_DIR" checkout -b "$SESSION_BRANCH" "$MAIN_BRANCH" 2>/dev/null
fi

echo "═══════════════════════════════════════════════════"
echo "  Autonomous Skill — Session $SESSION_ID"
echo "  Project: $(basename "$PROJECT_DIR")"
[ -n "$DIRECTION" ] && echo "  Direction: $DIRECTION"
[ "$MAX_ITERATIONS" -eq 0 ] 2>/dev/null && echo "  Iterations: unlimited" || echo "  Iterations: $MAX_ITERATIONS"
echo "  Timeout: ${CC_TIMEOUT}s per iteration"
echo "$MAX_COST_USD" | grep -qE '^0(\.0+)?$' && echo "  Budget: unlimited" || echo "  Budget: \$$MAX_COST_USD"
echo "  Branch: $SESSION_BRANCH"
echo "═══════════════════════════════════════════════════"
echo ""

log_event "session_start" 0 "branch=$SESSION_BRANCH"

# ─── Main loop ──────────────────────────────────────────────────────
ITERATION=0
TOTAL_COST=0
TOTAL_COMMITS=0

while [ "$MAX_ITERATIONS" -eq 0 ] 2>/dev/null || [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  # Interrupts & sentinel
  [ "$INTERRUPTED" -eq 1 ] && break
  [ -f "$SENTINEL_FILE" ] && { rm -f "$SENTINEL_FILE"; echo "[loop] Sentinel file detected. Stopping."; break; }

  ITERATION=$((ITERATION + 1))
  [ "$MAX_ITERATIONS" -eq 0 ] 2>/dev/null && echo "─── Iteration $ITERATION ───" || echo "─── Iteration $ITERATION/$MAX_ITERATIONS ───"

  # Snapshot HEAD
  HEAD_BEFORE=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)

  # Build prompt
  TASK_PROMPT=$(build_prompt "$ITERATION" "$MAX_ITERATIONS")

  # Build CC args
  CC_ARGS=(-p "$TASK_PROMPT" --dangerously-skip-permissions --output-format stream-json --verbose)
  [ -n "$OWNER_CONTENT" ] && CC_ARGS+=(--append-system-prompt "$OWNER_CONTENT")

  # Spawn CC
  echo "[loop] CC running..."
  CC_START=$(date +%s)
  CC_STREAM_FILE=$(mktemp /tmp/autonomous-cc-XXXXXXXX)
  mv "$CC_STREAM_FILE" "${CC_STREAM_FILE}.jsonl"; CC_STREAM_FILE="${CC_STREAM_FILE}.jsonl"
  LAST_TOOL=""

  timeout "$CC_TIMEOUT" claude "${CC_ARGS[@]}" < /dev/null > "$CC_STREAM_FILE" 2>/dev/null &
  CC_PID=$!

  # Live progress
  while kill -0 "$CC_PID" 2>/dev/null; do
    if [ -s "$CC_STREAM_FILE" ]; then
      NEW_TOOL=$(jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$CC_STREAM_FILE" 2>/dev/null | tail -1)
      if [ -n "$NEW_TOOL" ] && [ "$NEW_TOOL" != "$LAST_TOOL" ]; then
        echo "  [cc] $NEW_TOOL"
        LAST_TOOL="$NEW_TOOL"
      fi
    fi
    sleep 2
  done

  wait "$CC_PID" 2>/dev/null; EXIT_CODE=$?
  CC_END=$(date +%s)
  CC_ELAPSED=$(( CC_END - CC_START ))

  # Timeout?
  if [ "$EXIT_CODE" -eq 124 ]; then
    echo "[loop] TIMEOUT (${CC_TIMEOUT}s)"
    log_event "timeout" 0 "elapsed=${CC_ELAPSED}s"
    rm -f "$CC_STREAM_FILE"
    continue
  fi

  # Extract result + cost from stream
  CC_RESULT=$(jq -c 'select(.type == "result")' "$CC_STREAM_FILE" 2>/dev/null | tail -1)
  COST=$(echo "$CC_RESULT" | jq -r '.total_cost_usd // 0' 2>/dev/null | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1)
  [ -z "$COST" ] && COST="0"
  TOTAL_COST=$(echo "$TOTAL_COST + $COST" | bc 2>/dev/null || echo "$TOTAL_COST")

  # Tool summary
  TOOL_SUMMARY=$(jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$CC_STREAM_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -5)

  # Result preview
  RESULT_TEXT=$(echo "$CC_RESULT" | jq -r '.result // empty' 2>/dev/null | head -c 300)

  rm -f "$CC_STREAM_FILE"

  # Did CC commit?
  HEAD_AFTER=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
  if [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]; then
    NEW_COMMITS=$(git -C "$PROJECT_DIR" rev-list --count "$HEAD_BEFORE..$HEAD_AFTER" 2>/dev/null || echo 0)
    TOTAL_COMMITS=$((TOTAL_COMMITS + NEW_COMMITS))
    echo "[loop] ✓ $NEW_COMMITS commit(s) in ${CC_ELAPSED}s (\$$COST)"
    git -C "$PROJECT_DIR" log --oneline "$HEAD_BEFORE..$HEAD_AFTER" 2>/dev/null | sed 's/^/  /'
    log_event "success" "$COST" "commits=$NEW_COMMITS, elapsed=${CC_ELAPSED}s"
  else
    echo "[loop] ✗ No commits in ${CC_ELAPSED}s (\$$COST)"
    [ -n "$RESULT_TEXT" ] && echo "  CC: ${RESULT_TEXT:0:200}"
    log_event "no_change" "$COST" "elapsed=${CC_ELAPSED}s"
  fi

  # Show tool summary
  if [ -n "$TOOL_SUMMARY" ]; then
    echo "  Tools: $(echo "$TOOL_SUMMARY" | awk '{printf "%s×%s ", $2, $1}' | sed 's/ $//')"
  fi
  echo ""

  # Budget check
  if ! echo "$MAX_COST_USD" | grep -qE '^0(\.0+)?$'; then
    OVER_BUDGET=$(echo "$TOTAL_COST >= $MAX_COST_USD" | bc 2>/dev/null || echo 0)
    if [ "$OVER_BUDGET" -eq 1 ]; then
      echo "[loop] Budget exceeded (\$$TOTAL_COST >= \$$MAX_COST_USD). Stopping."
      log_event "budget_exceeded" "$TOTAL_COST" "limit=$MAX_COST_USD"
      break
    fi
  fi
done

# ─── Metrics ────────────────────────────────────────────────────────
SESSION_END=$(date +%s)
DURATION=$(( SESSION_END - SESSION_ID ))
COMMIT_COUNT=$(git -C "$PROJECT_DIR" rev-list --count "$MAIN_BRANCH..$SESSION_BRANCH" 2>/dev/null || echo 0)
FILES_CHANGED=$(git -C "$PROJECT_DIR" diff --stat "$MAIN_BRANCH..$SESSION_BRANCH" 2>/dev/null | tail -1 | grep -oE '[0-9]+ file' | head -1 || echo "0 file")

# Duration format
if [ "$DURATION" -ge 3600 ]; then
  DUR_FMT="$((DURATION/3600))h $((DURATION%3600/60))m"
elif [ "$DURATION" -ge 60 ]; then
  DUR_FMT="$((DURATION/60))m $((DURATION%60))s"
else
  DUR_FMT="${DURATION}s"
fi

log_event "session_end" "$TOTAL_COST" "iterations=$ITERATION, commits=$COMMIT_COUNT, duration=${DURATION}s"

echo "═══════════════════════════════════════════════════"
echo "  SESSION METRICS"
echo "═══════════════════════════════════════════════════"
echo "  Duration:      $DUR_FMT"
echo "  Iterations:    $ITERATION"
echo "  Commits:       $COMMIT_COUNT"
echo "  Files changed: $FILES_CHANGED"
echo "  Total cost:    \$$TOTAL_COST"
[ "$ITERATION" -gt 0 ] && echo "  Avg cost/iter: \$$(echo "scale=4; $TOTAL_COST / $ITERATION" | bc 2>/dev/null || echo '?')"
echo "───────────────────────────────────────────────────"
echo "  Review: git log $MAIN_BRANCH..$SESSION_BRANCH --oneline"
echo "  Merge:  git checkout $MAIN_BRANCH && git merge $SESSION_BRANCH"
echo "───────────────────────────────────────────────────"

# Write trace entry
write_trace "$COMMIT_COUNT" "$ITERATION" "$TOTAL_COST" "$DUR_FMT"
echo "[loop] Trace appended to TRACE.md"

# Commit trace update
git -C "$PROJECT_DIR" add TRACE.md 2>/dev/null && \
  git -C "$PROJECT_DIR" commit -m "trace: session $SESSION_ID — $COMMIT_COUNT commit(s), $DUR_FMT" 2>/dev/null || true

# Return to main
git -C "$PROJECT_DIR" checkout "$MAIN_BRANCH" 2>/dev/null
echo "[loop] Returned to $MAIN_BRANCH"
