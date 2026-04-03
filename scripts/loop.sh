#!/usr/bin/env bash
# loop.sh — Main autonomous loop driver
# Drives iterations by spawning fresh CC invocations, managing state, and handling cleanup.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-.}"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"  # 0 = unlimited
CC_TIMEOUT="${CC_TIMEOUT:-900}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-5}"
DIRECTION="${AUTONOMOUS_DIRECTION:-}"

# Derive SLUG and paths — self-contained, no gstack dependency
SLUG=$(basename "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")")
DATA_DIR="${AUTONOMOUS_SKILL_HOME:-$HOME/.autonomous-skill}/projects/$SLUG"
STATE_FILE="$DATA_DIR/autonomous-state.json"
LOG_FILE="$DATA_DIR/autonomous-log.jsonl"
SENTINEL_FILE="$DATA_DIR/.stop-autonomous"
OWNER_FILE="$PROJECT_DIR/OWNER.md"
SESSION_ID=$(date +%s)
SESSION_BRANCH="auto/session-$SESSION_ID"

mkdir -p "$DATA_DIR"

# Excluded workflows (dangerous in autonomous mode)
EXCLUDED_WORKFLOWS="/ship /land-and-deploy /careful /guard"

# ─── Signal handling ────────────────────────────────────────────────
INTERRUPTED=0
trap 'INTERRUPTED=1; echo "[loop] SIGINT received, finishing current task..." >&2' INT

# ─── Logging ──────────────────────────────────────────────────────��─
log_event() {
  local event="$1"
  local details="${2:-}"
  local cost="${3:-0}"
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"session\":\"$SESSION_ID\",\"iteration\":${ITERATION:-0},\"event\":\"$event\",\"details\":$(echo "$details" | jq -Rs .),\"cost_usd\":$cost}" >> "$LOG_FILE"
}

# ─── State management ───────────────────────────────────────────────
init_state() {
  local tasks="$1"
  jq -n \
    --arg sid "$SESSION_ID" \
    --arg branch "$SESSION_BRANCH" \
    --argjson max "$MAX_ITERATIONS" \
    --argjson tasks "$tasks" \
    '{
      session_id: $sid,
      branch: $branch,
      iteration: 0,
      max_iterations: $max,
      total_cost_usd: 0,
      tasks: $tasks,
      completed: [],
      skipped: []
    }' > "$STATE_FILE"
}

update_state() {
  local field="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)
  jq "$field = $value" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

get_next_task() {
  jq -r '[.tasks[] | select(.status == "pending")] | sort_by(.priority) | .[0] // empty' "$STATE_FILE"
}

mark_task() {
  local task_id="$1"
  local status="$2"
  local error="${3:-null}"
  local tmp
  tmp=$(mktemp)
  if [ "$status" = "strike" ]; then
    # Increment strikes
    jq --arg id "$task_id" '
      .tasks |= map(if .id == $id then .strikes += 1 | .last_error = "'"$error"'" |
        (if .strikes >= 3 then .status = "skipped" else . end) else . end) |
      if (.tasks[] | select(.id == $id) | .status) == "skipped" then .skipped += [$id] else . end
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  elif [ "$status" = "done" ]; then
    jq --arg id "$task_id" '
      .tasks |= map(if .id == $id then .status = "done" else . end) |
      .completed += [$id]
    ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi
}

add_cost() {
  local cost="$1"
  local tmp
  tmp=$(mktemp)
  jq --argjson c "$cost" '.total_cost_usd += $c' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ─── Test command detection ─────────────────────────────────────────
detect_test_command() {
  local dir="$1"
  if [ -f "$dir/package.json" ]; then
    local test_script
    test_script=$(jq -r '.scripts.test // empty' "$dir/package.json" 2>/dev/null)
    if [ -n "$test_script" ] && [ "$test_script" != "echo \"Error: no test specified\" && exit 1" ]; then
      echo "cd '$dir' && npm test"
      return
    fi
  fi
  if [ -f "$dir/Makefile" ] && grep -q '^test:' "$dir/Makefile" 2>/dev/null; then
    echo "cd '$dir' && make test"
    return
  fi
  if [ -f "$dir/pytest.ini" ] || [ -f "$dir/pyproject.toml" ] && grep -q 'pytest' "$dir/pyproject.toml" 2>/dev/null; then
    echo "cd '$dir' && pytest"
    return
  fi
  if [ -f "$dir/Cargo.toml" ]; then
    echo "cd '$dir' && cargo test"
    return
  fi
  # No test command found
  echo ""
}

# ─── Verify result ──────────────────────────────────────────────────
verify_result() {
  local cc_output="$1"
  local task_desc="$2"

  # Parse JSON
  local is_error
  is_error=$(echo "$cc_output" | jq -r '.is_error // true' 2>/dev/null)
  local cost
  cost=$(echo "$cc_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)

  if [ "$is_error" = "true" ]; then
    local error_msg
    error_msg=$(echo "$cc_output" | jq -r '.result // .errors[0] // "unknown error"' 2>/dev/null)
    echo "error:$cost:$error_msg"
    return 1
  fi

  # Check if there are actual code changes
  if ! git -C "$PROJECT_DIR" diff --quiet HEAD 2>/dev/null && [ -n "$(git -C "$PROJECT_DIR" diff --name-only HEAD 2>/dev/null)" ]; then
    # There are changes — run tests if available
    local test_cmd
    test_cmd=$(detect_test_command "$PROJECT_DIR")

    if [ -n "$test_cmd" ]; then
      if eval "$test_cmd" >/dev/null 2>&1; then
        # Tests pass — commit
        git -C "$PROJECT_DIR" add -A
        git -C "$PROJECT_DIR" commit -m "auto: $task_desc" --no-verify >/dev/null 2>&1
        echo "pass:$cost:committed"
        return 0
      else
        # Tests fail — reset
        git -C "$PROJECT_DIR" checkout -- . 2>/dev/null
        git -C "$PROJECT_DIR" clean -fd >/dev/null 2>&1
        echo "fail:$cost:tests failed"
        return 1
      fi
    else
      # No tests — accept the change
      git -C "$PROJECT_DIR" add -A
      git -C "$PROJECT_DIR" commit -m "auto: $task_desc" --no-verify >/dev/null 2>&1
      echo "pass:$cost:committed (no tests)"
      return 0
    fi
  else
    # No code changes — CC may have only done analysis
    echo "pass:$cost:no changes (analysis only)"
    return 0
  fi
}

# ─── Build task prompt ──────────────────────────────────────────────
build_prompt() {
  local task_desc="$1"
  local task_source="$2"

  local direction_line=""
  if [ -n "$DIRECTION" ]; then
    direction_line="SESSION DIRECTION: $DIRECTION
Focus your work on this direction. If the task doesn't align, adapt it to fit.

"
  fi

  cat << PROMPT
You are an autonomous project agent working on this codebase.

${direction_line}YOUR TASK: $task_desc
(Source: $task_source)

INSTRUCTIONS:
1. Understand the task by reading relevant files.
2. Implement the fix or improvement.
3. Make sure your changes are correct and complete.
4. Do not create new files unless necessary.
5. Keep changes minimal and focused on the task.
PROMPT
}

# ─── Autonomous system prompt ───────────────────────────────────────
AUTONOMOUS_PROMPT="AUTONOMOUS MODE: You are an autonomous project agent.
RULES:
1. When any workflow asks a question via AskUserQuestion, automatically select the recommended option. Never wait for user input.
2. NEVER invoke these workflows: $EXCLUDED_WORKFLOWS
3. If a dangerous operation is needed, SKIP IT. Do not delete files, force push, or deploy.
4. All code changes go to the current branch. Commit with descriptive messages.
5. Follow the owner persona for style and priority decisions.
6. Be efficient. Focus on one task at a time. Make minimal, correct changes."

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════"
echo "  Autonomous Skill — Session $SESSION_ID"
echo "  Project: $PROJECT_DIR"
if [ -n "$DIRECTION" ]; then echo "  Direction: $DIRECTION"; fi
if [ "$MAX_ITERATIONS" -eq 0 ] 2>/dev/null; then echo "  Max iterations: unlimited"; else echo "  Max iterations: $MAX_ITERATIONS"; fi
echo "  Timeout per iteration: ${CC_TIMEOUT}s"
echo "═══════════════════════════════════════════════════"

# Ensure we're in a git repo
if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "[loop] ERROR: $PROJECT_DIR is not a git repository" >&2
  exit 1
fi

# Ensure OWNER.md exists
"$SCRIPT_DIR/persona.sh" "$PROJECT_DIR" >/dev/null

# Read OWNER.md
OWNER_CONTENT=""
if [ -f "$OWNER_FILE" ]; then
  OWNER_CONTENT=$(cat "$OWNER_FILE")
fi

# Discover tasks
echo "[loop] Discovering tasks..."
TASKS=$("$SCRIPT_DIR/discover.sh" "$PROJECT_DIR")
TASK_COUNT=$(echo "$TASKS" | jq 'length')
echo "[loop] Found $TASK_COUNT tasks"

# Initialize state
init_state "$TASKS"

# Create session branch
MAIN_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
git -C "$PROJECT_DIR" checkout -b "$SESSION_BRANCH" 2>/dev/null
echo "[loop] Created branch: $SESSION_BRANCH"

log_event "session_start" "tasks=$TASK_COUNT, branch=$SESSION_BRANCH"

# ─── Main loop ──────────────────────────────────────────────────────
ITERATION=0
while [ "$MAX_ITERATIONS" -eq 0 ] 2>/dev/null || [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  # Check for interrupts
  if [ "$INTERRUPTED" -eq 1 ]; then
    echo "[loop] Interrupted. Cleaning up..."
    break
  fi

  # Check sentinel file
  if [ -f "$SENTINEL_FILE" ]; then
    echo "[loop] Sentinel file detected. Stopping..."
    rm -f "$SENTINEL_FILE"
    break
  fi

  # Update iteration in state
  update_state '.iteration' "$ITERATION"

  # Get next task
  TASK_JSON=$(get_next_task)
  if [ -z "$TASK_JSON" ] || [ "$TASK_JSON" = "null" ]; then
    echo "[loop] No more pending tasks. Exiting."
    break
  fi

  TASK_ID=$(echo "$TASK_JSON" | jq -r '.id')
  TASK_DESC=$(echo "$TASK_JSON" | jq -r '.description')
  TASK_SOURCE=$(echo "$TASK_JSON" | jq -r '.source')
  TASK_STRIKES=$(echo "$TASK_JSON" | jq -r '.strikes')

  echo ""
  if [ "$MAX_ITERATIONS" -eq 0 ] 2>/dev/null; then echo "─── Iteration $((ITERATION + 1)) ───"; else echo "─── Iteration $((ITERATION + 1))/$MAX_ITERATIONS ───"; fi
  echo "Task: $TASK_DESC"
  echo "Source: $TASK_SOURCE (strikes: $TASK_STRIKES)"

  # Build the prompt
  TASK_PROMPT=$(build_prompt "$TASK_DESC" "$TASK_SOURCE")

  # Build CC invocation args (stream-json for live progress)
  CC_ARGS=(-p "$TASK_PROMPT" --permission-mode auto --output-format stream-json --verbose)
  if [ -n "$OWNER_CONTENT" ]; then
    CC_ARGS+=(--append-system-prompt "$OWNER_CONTENT")
  fi
  CC_ARGS+=(--append-system-prompt "$AUTONOMOUS_PROMPT")

  # Run CC with timeout, streaming progress to stderr
  echo "[loop] Running CC... (timeout: ${CC_TIMEOUT}s)"
  CC_START=$(date +%s)
  CC_STREAM_FILE=$(mktemp /tmp/autonomous-cc-XXXXXXXX)
  mv "$CC_STREAM_FILE" "${CC_STREAM_FILE}.jsonl"
  CC_STREAM_FILE="${CC_STREAM_FILE}.jsonl"

  timeout "$CC_TIMEOUT" claude "${CC_ARGS[@]}" < /dev/null > "$CC_STREAM_FILE" 2>/dev/null &
  CC_PID=$!
  LAST_TOOL=""

  # Live progress: tail the stream and print tool uses + text
  while kill -0 "$CC_PID" 2>/dev/null; do
    # Parse latest events and show progress
    if [ -s "$CC_STREAM_FILE" ]; then
      # Show tool calls as they happen
      NEW_TOOLS=$(jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$CC_STREAM_FILE" 2>/dev/null | tail -1)
      if [ -n "$NEW_TOOLS" ] && [ "$NEW_TOOLS" != "$LAST_TOOL" ]; then
        echo "  [cc] Using tool: $NEW_TOOLS"
        LAST_TOOL="$NEW_TOOLS"
      fi
    fi
    sleep 2
  done
  LAST_TOOL=""

  wait "$CC_PID" 2>/dev/null
  EXIT_CODE=$?
  CC_END=$(date +%s)
  CC_ELAPSED=$(( CC_END - CC_START ))

  if [ "$EXIT_CODE" -eq 124 ]; then
    echo "[loop] TIMEOUT after ${CC_TIMEOUT}s"
    log_event "timeout" "$TASK_DESC" 0
    mark_task "$TASK_ID" "strike" "timeout after ${CC_TIMEOUT}s"
    rm -f "$CC_STREAM_FILE"
    ITERATION=$((ITERATION + 1))
    continue
  fi

  # Extract the result line (last line with type=result)
  CC_OUTPUT=$(jq -c 'select(.type == "result")' "$CC_STREAM_FILE" 2>/dev/null | tail -1)
  if [ -z "$CC_OUTPUT" ]; then
    if [ "$EXIT_CODE" -ne 0 ]; then
      echo "[loop] CC exited with code $EXIT_CODE"
      CC_OUTPUT='{"is_error":true,"result":"CC process failed with exit code '"$EXIT_CODE"'","total_cost_usd":0}'
    else
      CC_OUTPUT='{"is_error":true,"result":"No result in CC output","total_cost_usd":0}'
    fi
  fi

  # Show summary of what CC did
  TOOL_SUMMARY=$(jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$CC_STREAM_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -5)
  echo "[loop] CC finished in ${CC_ELAPSED}s. Tools used:"
  echo "$TOOL_SUMMARY" | while read -r count tool; do
    echo "  $tool × $count"
  done

  # Show preview of result
  CC_RESULT_PREVIEW=$(echo "$CC_OUTPUT" | jq -r '.result // empty' 2>/dev/null | head -c 300)
  if [ -n "$CC_RESULT_PREVIEW" ]; then
    echo "[loop] CC says: ${CC_RESULT_PREVIEW}"
  fi

  rm -f "$CC_STREAM_FILE"

  # Handle malformed JSON
  if ! echo "$CC_OUTPUT" | jq . >/dev/null 2>&1; then
    echo "[loop] Malformed JSON from CC"
    log_event "malformed_json" "$(echo "$CC_OUTPUT" | head -c 500)" 0
    mark_task "$TASK_ID" "strike" "malformed JSON response"
    ITERATION=$((ITERATION + 1))
    continue
  fi

  # Verify result
  VERIFY_RESULT=$(verify_result "$CC_OUTPUT" "$TASK_DESC")
  VERIFY_STATUS=$(echo "$VERIFY_RESULT" | cut -d: -f1)
  VERIFY_COST=$(echo "$VERIFY_RESULT" | cut -d: -f2)
  VERIFY_MSG=$(echo "$VERIFY_RESULT" | cut -d: -f3-)

  # Record cost
  add_cost "$VERIFY_COST"

  if [ "$VERIFY_STATUS" = "pass" ]; then
    echo "[loop] SUCCESS: $VERIFY_MSG (cost: \$$VERIFY_COST)"
    log_event "success" "$TASK_DESC — $VERIFY_MSG" "$VERIFY_COST"
    mark_task "$TASK_ID" "done"
  elif [ "$VERIFY_STATUS" = "error" ] || [ "$VERIFY_STATUS" = "fail" ]; then
    echo "[loop] FAILURE: $VERIFY_MSG (cost: \$$VERIFY_COST)"
    log_event "failure" "$TASK_DESC — $VERIFY_MSG" "$VERIFY_COST"
    mark_task "$TASK_ID" "strike" "$VERIFY_MSG"
  fi

  # Refresh task list periodically
  if [ $(( (ITERATION + 1) % REFRESH_INTERVAL )) -eq 0 ]; then
    echo "[loop] Refreshing task list..."
    NEW_TASKS=$("$SCRIPT_DIR/discover.sh" "$PROJECT_DIR")
    # Merge: keep existing strike counts, add new tasks
    MERGED=$(jq -s '
      . as [$new, $state] |
      $state.tasks as $existing |
      ($existing | map(.id) | unique) as $known_ids |
      $existing + [$new[] | select(.id as $id | $known_ids | index($id) | not)]
    ' <(echo "$NEW_TASKS") <(cat "$STATE_FILE"))
    update_state '.tasks' "$MERGED"
    echo "[loop] Task list refreshed"
  fi

  ITERATION=$((ITERATION + 1))
done

# ─── Cleanup ────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo "  Session complete"
echo "═══════════════════════════════════════════════════"

# Handle any uncommitted changes
if ! git -C "$PROJECT_DIR" diff --quiet 2>/dev/null; then
  TEST_CMD=$(detect_test_command "$PROJECT_DIR")
  if [ -n "$TEST_CMD" ] && eval "$TEST_CMD" >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -m "auto: WIP — session interrupted" --no-verify >/dev/null 2>&1
    echo "[loop] Committed partial work"
  else
    git -C "$PROJECT_DIR" stash >/dev/null 2>&1
    echo "[loop] Stashed uncommitted changes (tests didn't pass)"
  fi
fi

# Write summary
TOTAL_COST=$(jq -r '.total_cost_usd' "$STATE_FILE")
COMPLETED_COUNT=$(jq -r '.completed | length' "$STATE_FILE")
SKIPPED_COUNT=$(jq -r '.skipped | length' "$STATE_FILE")
COMMIT_COUNT=$(git -C "$PROJECT_DIR" rev-list --count "$MAIN_BRANCH..$SESSION_BRANCH" 2>/dev/null || echo 0)

log_event "session_end" "iterations=$ITERATION, completed=$COMPLETED_COUNT, skipped=$SKIPPED_COUNT, commits=$COMMIT_COUNT, cost=\$$TOTAL_COST"

echo ""
echo "Results:"
if [ "$MAX_ITERATIONS" -eq 0 ] 2>/dev/null; then echo "  Iterations:  $ITERATION (unlimited)"; else echo "  Iterations:  $ITERATION / $MAX_ITERATIONS"; fi
echo "  Completed:   $COMPLETED_COUNT tasks"
echo "  Skipped:     $SKIPPED_COUNT tasks (3-strike rule)"
echo "  Commits:     $COMMIT_COUNT on $SESSION_BRANCH"
echo "  Total cost:  \$$TOTAL_COST"
echo ""
echo "Review: git log $MAIN_BRANCH..$SESSION_BRANCH --oneline"
echo "Merge:  git checkout $MAIN_BRANCH && git merge $SESSION_BRANCH"

# Return to main branch
git -C "$PROJECT_DIR" checkout "$MAIN_BRANCH" 2>/dev/null
echo "[loop] Returned to $MAIN_BRANCH"
