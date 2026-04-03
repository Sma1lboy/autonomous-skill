#!/usr/bin/env bash
# test_loop.sh — Integration tests for loop.sh
# Uses mock_claude to simulate CC responses without real API calls.
#
# Usage: tests/test_loop.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOOP="$PROJECT_ROOT/scripts/loop.sh"
MOCK_CLAUDE="$SCRIPT_DIR/mock_claude"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=""

# ─── Helpers ───────────────────────────────────────────────────────

pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  echo "  PASS: $1"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES="${FAILURES}  FAIL: $1\n"
  echo "  FAIL: $1"
}

assert_contains() {
  local output="$1" pattern="$2" label="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$output" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label (expected /$pattern/ in output)"
  fi
}

assert_not_contains() {
  local output="$1" pattern="$2" label="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$output" | grep -qE "$pattern"; then
    fail "$label (unexpected /$pattern/ in output)"
  else
    pass "$label"
  fi
}

assert_file_exists() {
  local path="$1" label="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$path" ]; then
    pass "$label"
  else
    fail "$label (file not found: $path)"
  fi
}

assert_branch_exists() {
  local repo="$1" branch="$2" label="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (branch $branch not found)"
  fi
}

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (got '$actual', expected '$expected')"
  fi
}

# Create a fresh temp git repo for each test
setup_repo() {
  local tmp
  tmp=$(mktemp -d /tmp/autonomous-test-XXXXXXXX)
  git -C "$tmp" init -b main --quiet 2>/dev/null
  git -C "$tmp" config user.email "test@test.com"
  git -C "$tmp" config user.name "Test"

  # Initial commit so we have a valid HEAD
  echo "# Test Project" > "$tmp/README.md"
  git -C "$tmp" add README.md
  git -C "$tmp" commit -m "init" --no-gpg-sign --quiet 2>/dev/null

  # Add a simple TODOS.md with one open task
  cat > "$tmp/TODOS.md" << 'EOF'
# TODOS
- [ ] Fix the widget
- [x] Already done task
EOF
  git -C "$tmp" add TODOS.md
  git -C "$tmp" commit -m "add TODOS.md" --no-gpg-sign --quiet 2>/dev/null

  echo "$tmp"
}

cleanup_repo() {
  local repo="$1"
  rm -rf "$repo"
}

# ═══════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════"
echo "  autonomous-skill — integration tests"
echo "═══════════════════════════════════════════════════"
echo ""

# ─── Test 1: dry-run mode ─────────────────────────────────────────
echo "── test_dry_run ──"
REPO=$(setup_repo)
OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "DRY RUN" "dry-run banner shows"
assert_contains "$OUTPUT" "Discovered Tasks" "dry-run shows tasks"
assert_contains "$OUTPUT" "task.*found" "dry-run shows task count"

# Verify no session branch was created
BRANCH_COUNT=$(git -C "$REPO" branch | grep -c "auto/session" || true)
assert_eq "$BRANCH_COUNT" "0" "dry-run creates no branch"

cleanup_repo "$REPO"
echo ""

# ─── Test 2: single iteration with commit ─────────────────────────
echo "── test_single_iteration_with_commit ──"
REPO=$(setup_repo)

# Run loop.sh with mock claude that commits
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.25 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Session.*[0-9]" "session header shows"
assert_contains "$OUTPUT" "Iteration 1" "iteration count shows"
assert_contains "$OUTPUT" "commit" "mentions commits"
assert_contains "$OUTPUT" "SESSION METRICS" "metrics block shows"
assert_contains "$OUTPUT" "Returned to main" "returns to main branch"

# Check log file was created
SLUG=$(basename "$REPO")
LOG_FILE="$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
assert_file_exists "$LOG_FILE" "log file created"

# Verify session_start and session_end events in log
if [ -f "$LOG_FILE" ]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  START_COUNT=$(grep -c '"session_start"' "$LOG_FILE" || true)
  END_COUNT=$(grep -c '"session_end"' "$LOG_FILE" || true)
  if [ "$START_COUNT" -ge 1 ] && [ "$END_COUNT" -ge 1 ]; then
    pass "log has session_start and session_end"
  else
    fail "log missing session events (start=$START_COUNT, end=$END_COUNT)"
  fi
fi

# Check TRACE.md was committed on the session branch
TESTS_RUN=$((TESTS_RUN + 1))
# TRACE.md lives on the session branch (loop.sh returns to main after committing it)
SESSION_BR=$(git -C "$REPO" branch | grep "auto/session" | sed 's/^[* ]*//' | head -1)
if [ -n "$SESSION_BR" ] && git -C "$REPO" show "$SESSION_BR:TRACE.md" >/dev/null 2>&1; then
  pass "TRACE.md committed on session branch"
else
  fail "TRACE.md not found on session branch"
fi

# Cleanup
rm -f "$LOG_FILE"
cleanup_repo "$REPO"
echo ""

# ─── Test 3: budget enforcement ───────────────────────────────────
echo "── test_budget_enforcement ──"
REPO=$(setup_repo)

# Mock claude reports $5.00 per iteration, budget is $2.00
# After first iteration ($5.00 >= $2.00), loop should stop
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=5.00 \
  MAX_ITERATIONS=10 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --max-cost 2.00 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Budget exceeded" "budget enforcement triggers"

# Verify budget_exceeded event in log file
SLUG_BUDGET=$(basename "$REPO")
BUDGET_LOG="$HOME/.autonomous-skill/projects/$SLUG_BUDGET/autonomous-log.jsonl"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$BUDGET_LOG" ] && grep -q '"budget_exceeded"' "$BUDGET_LOG"; then
  pass "budget_exceeded event logged"
else
  fail "budget_exceeded event not in log"
fi

# Should only have run 1 iteration (stopped after cost exceeded)
assert_contains "$OUTPUT" "Iteration 1" "ran first iteration"
assert_not_contains "$OUTPUT" "Iteration 3" "did not run iteration 3"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test 4: sentinel file shutdown ──────────────────────────────
echo "── test_sentinel_shutdown ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

# Create sentinel file BEFORE starting — loop should detect it on first check
touch "$DATA_DIR/.stop-autonomous"

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MAX_ITERATIONS=10 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Sentinel file detected" "sentinel shutdown detected"
# Should have 0 iterations completed
assert_not_contains "$OUTPUT" "Iteration 1" "no iterations ran"

rm -f "$DATA_DIR/.stop-autonomous"
rm -f "$DATA_DIR/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test 5: iteration with no commits (no-change) ───────────────
echo "── test_no_commit_iteration ──"
REPO=$(setup_repo)

# Mock claude does NOT commit
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=0 \
  MOCK_CLAUDE_COST=0.15 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "No commits" "no-commit iteration detected"
assert_contains "$OUTPUT" "Commits:.*0" "metrics show 0 commits"

SLUG=$(basename "$REPO")
# Verify no_change event in log
LOG_FILE="$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
if [ -f "$LOG_FILE" ]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q '"no_change"' "$LOG_FILE"; then
    pass "no_change event logged"
  else
    fail "no_change event not in log"
  fi
fi

rm -f "$LOG_FILE"
cleanup_repo "$REPO"
echo ""

# ─── Test 6: timeout handling ─────────────────────────────────────
echo "── test_timeout_handling ──"
REPO=$(setup_repo)

# Set very short timeout (2s) and have mock claude sleep longer (5s)
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_DELAY=10 \
  CC_TIMEOUT=2 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "TIMEOUT" "timeout detected"

SLUG=$(basename "$REPO")
LOG_FILE="$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
if [ -f "$LOG_FILE" ]; then
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q '"timeout"' "$LOG_FILE"; then
    pass "timeout event logged"
  else
    fail "timeout event not in log"
  fi
fi

rm -f "$LOG_FILE"
cleanup_repo "$REPO"
echo ""

# ─── Test 7: discover.sh output ──────────────────────────────────
echo "── test_discover ──"
REPO=$(setup_repo)

OUTPUT=$("$PROJECT_ROOT/scripts/discover.sh" "$REPO" 2>/dev/null)

# Should be valid JSON
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$OUTPUT" | jq empty 2>/dev/null; then
  pass "discover.sh outputs valid JSON"
else
  fail "discover.sh output is not valid JSON"
fi

# Should find the open TODO
TESTS_RUN=$((TESTS_RUN + 1))
TASK_COUNT=$(echo "$OUTPUT" | jq 'length' 2>/dev/null || echo 0)
if [ "$TASK_COUNT" -ge 1 ]; then
  pass "discover.sh found tasks ($TASK_COUNT)"
else
  fail "discover.sh found no tasks"
fi

# Should have the widget task from TODOS.md
assert_contains "$OUTPUT" "widget" "discover.sh found TODOS.md task"

# Should NOT include completed tasks
assert_not_contains "$OUTPUT" "Already done" "discover.sh skips completed tasks"

cleanup_repo "$REPO"
echo ""

# ─── Test 8: discover.sh with KANBAN.md ──────────────────────────
echo "── test_discover_kanban ──"
REPO=$(setup_repo)

cat > "$REPO/KANBAN.md" << 'EOF'
# KANBAN

## Todo
- [ ] Implement caching layer
- [ ] Add rate limiting

## Doing
- [ ] Refactor auth module

## Done
- [x] Set up CI pipeline
EOF
git -C "$REPO" add KANBAN.md
git -C "$REPO" commit -m "add KANBAN.md" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$("$PROJECT_ROOT/scripts/discover.sh" "$REPO" 2>/dev/null)

# Should find KANBAN.md Todo items
assert_contains "$OUTPUT" "caching layer" "discover.sh finds KANBAN Todo items"
assert_contains "$OUTPUT" "rate limiting" "discover.sh finds second KANBAN Todo item"

# Should NOT include Doing or Done items
assert_not_contains "$OUTPUT" "Refactor auth" "discover.sh skips KANBAN Doing items"
assert_not_contains "$OUTPUT" "CI pipeline" "discover.sh skips KANBAN Done items"

cleanup_repo "$REPO"
echo ""

# ─── Test 9: report.sh with no log ───────────────────────────────
echo "── test_report_no_log ──"
REPO=$(setup_repo)

OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1 || true)

assert_contains "$OUTPUT" "No log file" "report.sh handles missing log gracefully"

cleanup_repo "$REPO"
echo ""

# ─── Test 10: report.sh with log data ────────────────────────────
echo "── test_report_with_log ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
DATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$DATA_DIR"

# Write synthetic log entries
cat > "$DATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-01T00:00:00Z","session":"100","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-100"}
{"ts":"2025-01-01T00:01:00Z","session":"100","iteration":1,"event":"success","cost_usd":0.25,"detail":"commits=1, elapsed=60s"}
{"ts":"2025-01-01T00:02:00Z","session":"100","iteration":2,"event":"no_change","cost_usd":0.15,"detail":"elapsed=45s"}
{"ts":"2025-01-01T00:03:00Z","session":"100","iteration":2,"event":"session_end","cost_usd":0,"detail":"iterations=2, commits=1, duration=180s"}
EOF

# Human-readable report
OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1)
assert_contains "$OUTPUT" "SESSION REPORT" "report.sh shows header"
assert_contains "$OUTPUT" "Sessions:.*1" "report.sh shows session count"
assert_contains "$OUTPUT" "Total commits:.*1" "report.sh shows commit count"
assert_contains "$OUTPUT" "Total duration:.*3m" "report.sh shows total duration"
assert_contains "$OUTPUT" "Cost/iter:" "report.sh shows cost per iteration"
assert_contains "$OUTPUT" "Cost/commit:" "report.sh shows cost per commit"
assert_contains "$OUTPUT" "DURATION" "report.sh per-session table has DURATION column"

# JSON report
JSON_OUTPUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --json 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq empty 2>/dev/null; then
  pass "report.sh --json outputs valid JSON"
else
  fail "report.sh --json output is not valid JSON"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_SESSIONS=$(echo "$JSON_OUTPUT" | jq '.totals.sessions' 2>/dev/null)
if [ "$JSON_SESSIONS" = "1" ]; then
  pass "report.sh --json has correct session count"
else
  fail "report.sh --json session count (got $JSON_SESSIONS, expected 1)"
fi

# Duration and efficiency metrics in JSON
TESTS_RUN=$((TESTS_RUN + 1))
JSON_DURATION=$(echo "$JSON_OUTPUT" | jq '.totals.total_duration_s' 2>/dev/null)
if [ "$JSON_DURATION" = "180" ]; then
  pass "report.sh --json has correct total_duration_s"
else
  fail "report.sh --json total_duration_s (got $JSON_DURATION, expected 180)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_AVG_ITER=$(echo "$JSON_OUTPUT" | jq '.totals.avg_cost_per_iter' 2>/dev/null)
if echo "$JSON_AVG_ITER" | grep -qE '^0\.[0-9]+$'; then
  pass "report.sh --json has avg_cost_per_iter"
else
  fail "report.sh --json avg_cost_per_iter (got $JSON_AVG_ITER)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_AVG_COMMIT=$(echo "$JSON_OUTPUT" | jq '.totals.avg_cost_per_commit' 2>/dev/null)
if echo "$JSON_AVG_COMMIT" | grep -qE '^0\.[0-9]+$'; then
  pass "report.sh --json has avg_cost_per_commit"
else
  fail "report.sh --json avg_cost_per_commit (got $JSON_AVG_COMMIT)"
fi

TESTS_RUN=$((TESTS_RUN + 1))
JSON_SESSION_DUR=$(echo "$JSON_OUTPUT" | jq '.sessions[0].duration_s' 2>/dev/null)
if [ "$JSON_SESSION_DUR" = "180" ]; then
  pass "report.sh --json session has duration_s"
else
  fail "report.sh --json session duration_s (got $JSON_SESSION_DUR, expected 180)"
fi

rm -rf "$DATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test 11: --max-iterations CLI flag ──────────────────────────
echo "── test_max_iterations_flag ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --max-iterations 2 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*2" "--max-iterations shows in banner"
assert_contains "$OUTPUT" "Iteration 1" "ran iteration 1"
assert_contains "$OUTPUT" "Iteration 2" "ran iteration 2"
assert_not_contains "$OUTPUT" "Iteration 3" "stopped after 2 iterations"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test 12: --direction CLI flag ───────────────────────────────
echo "── test_direction_flag ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --direction "Fix all security bugs" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Direction:.*Fix all security bugs" "--direction shows in banner"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test 13: --direction in dry-run ─────────────────────────────
echo "── test_direction_dry_run ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run --direction "Improve test coverage" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Direction:.*Improve test coverage" "--direction shows in dry-run banner"

cleanup_repo "$REPO"
echo ""

# ─── Test 14: --max-iterations overrides env var ─────────────────
echo "── test_max_iterations_overrides_env ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MAX_ITERATIONS=99 \
  bash "$LOOP" --dry-run --max-iterations 3 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*3" "--max-iterations overrides MAX_ITERATIONS env var"

cleanup_repo "$REPO"
echo ""

# ─── Test 15: session branch based off main ──────────────────────
echo "── test_session_branch_off_main ──"
REPO=$(setup_repo)

# Create a feature branch with a different commit
git -C "$REPO" checkout -b feature/something 2>/dev/null
echo "feature work" > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -m "feature work" --no-gpg-sign --quiet 2>/dev/null
FEATURE_HEAD=$(git -C "$REPO" rev-parse HEAD)
MAIN_HEAD=$(git -C "$REPO" rev-parse main)

# Run loop from the feature branch — session should branch off main, not feature
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=0 \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

# After loop, check that the session branch's parent is main, not feature
SESSION_BR=$(git -C "$REPO" branch | grep "auto/session" | sed 's/^[* ]*//' | head -1)
TESTS_RUN=$((TESTS_RUN + 1))
if [ -n "$SESSION_BR" ]; then
  SESSION_BASE=$(git -C "$REPO" merge-base "$SESSION_BR" main 2>/dev/null)
  if [ "$SESSION_BASE" = "$MAIN_HEAD" ]; then
    pass "session branch based off main (not feature branch)"
  else
    fail "session branch not based off main (base=$SESSION_BASE, main=$MAIN_HEAD)"
  fi
else
  fail "no session branch found"
fi

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_help_flag ──────────────────────────────────────────────────
echo "── test_help_flag ──"

OUTPUT=$(bash "$LOOP" --help 2>&1)
assert_contains "$OUTPUT" "Usage: loop.sh" "--help shows usage header"
assert_contains "$OUTPUT" "dry-run" "--help lists --dry-run"
assert_contains "$OUTPUT" "max-iterations" "--help lists --max-iterations"
assert_contains "$OUTPUT" "max-cost" "--help lists --max-cost"
assert_contains "$OUTPUT" "direction" "--help lists --direction"
assert_contains "$OUTPUT" "timeout" "--help lists --timeout"
assert_contains "$OUTPUT" "Examples:" "--help shows examples section"

OUTPUT_H=$(bash "$LOOP" -h 2>&1)
assert_contains "$OUTPUT_H" "Usage: loop.sh" "-h also shows usage"
echo ""

# ── test_unknown_flag_error ─────────────────────────────────────────
echo "── test_unknown_flag_error ──"

OUTPUT=$(bash "$LOOP" --bogus 2>&1 || true)
assert_contains "$OUTPUT" "unknown flag" "unknown flag shows error"
assert_contains "$OUTPUT" "help" "unknown flag suggests --help"
echo ""

# ── test_timeout_flag ────────────────────────────────────────────────
echo "── test_timeout_flag ──"

REPO=$(setup_repo)
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_COST=0.05 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --timeout 120 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Timeout:.*120s" "--timeout shows in banner"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_resume_specific_branch ──────────────────────────────────────
echo "── test_resume_specific_branch ──"
REPO=$(setup_repo)

# First, create a session branch with a commit on it
git -C "$REPO" checkout -b "auto/session-999" main 2>/dev/null
echo "session work" > "$REPO/session-work.txt"
git -C "$REPO" add session-work.txt
git -C "$REPO" commit -m "session work" --no-gpg-sign --quiet 2>/dev/null
git -C "$REPO" checkout main 2>/dev/null

# Resume that specific branch
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --resume auto/session-999 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Resuming Session" "--resume shows resuming banner"
assert_contains "$OUTPUT" "auto/session-999" "--resume uses specified branch"
assert_contains "$OUTPUT" "Resuming branch" "--resume prints resuming message"

# Verify we're back on main and the session branch still exists
CURRENT=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)
assert_eq "$CURRENT" "main" "resume returns to main after completion"
assert_branch_exists "$REPO" "auto/session-999" "session branch still exists after resume"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_resume_latest_branch ────────────────────────────────────────
echo "── test_resume_latest_branch ──"
REPO=$(setup_repo)

# Create two session branches — latest should be picked
git -C "$REPO" checkout -b "auto/session-100" main 2>/dev/null
echo "old" > "$REPO/old.txt"
git -C "$REPO" add old.txt
git -C "$REPO" commit -m "old session" --no-gpg-sign --quiet 2>/dev/null
git -C "$REPO" checkout main 2>/dev/null

sleep 1  # ensure creatordate differs

git -C "$REPO" checkout -b "auto/session-200" main 2>/dev/null
echo "new" > "$REPO/new.txt"
git -C "$REPO" add new.txt
git -C "$REPO" commit -m "new session" --no-gpg-sign --quiet 2>/dev/null
git -C "$REPO" checkout main 2>/dev/null

# Resume without specifying branch — should pick auto/session-200
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --resume "$REPO" 2>&1)

assert_contains "$OUTPUT" "auto/session-200" "--resume picks latest session branch"
assert_contains "$OUTPUT" "Resuming Session" "--resume latest shows resuming banner"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_resume_nonexistent_branch ───────────────────────────────────
echo "── test_resume_nonexistent_branch ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --resume auto/session-nonexistent "$REPO" 2>&1 || true)

assert_contains "$OUTPUT" "not found" "--resume nonexistent branch shows error"

cleanup_repo "$REPO"
echo ""

# ── test_resume_no_branches ──────────────────────────────────────────
echo "── test_resume_no_branches ──"
REPO=$(setup_repo)

OUTPUT=$(cd "$REPO" && \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" --resume "$REPO" 2>&1 || true)

assert_contains "$OUTPUT" "no auto/session" "--resume with no branches shows error"

cleanup_repo "$REPO"
echo ""

# ── test_resume_in_dry_run ───────────────────────────────────────────
echo "── test_resume_in_dry_run ──"
REPO=$(setup_repo)

# Create a session branch
git -C "$REPO" checkout -b "auto/session-555" main 2>/dev/null
git -C "$REPO" checkout main 2>/dev/null

OUTPUT=$(cd "$REPO" && bash "$LOOP" --dry-run --resume auto/session-555 "$REPO" 2>&1)

assert_contains "$OUTPUT" "would resume" "--resume in dry-run shows would resume"
assert_contains "$OUTPUT" "auto/session-555" "--resume in dry-run shows branch name"

cleanup_repo "$REPO"
echo ""

# ── test_help_lists_resume ───────────────────────────────────────────
echo "── test_help_lists_resume ──"
OUTPUT=$(bash "$LOOP" --help 2>&1)
assert_contains "$OUTPUT" "resume" "--help lists --resume"
echo ""

# ── test_config_file_sets_defaults ────────────────────────────────────
echo "── test_config_file_sets_defaults ──"
REPO=$(setup_repo)

# Create a config file that sets max_iterations to 2 and direction
cat > "$REPO/.autonomous-skill.yml" << 'EOF'
max_iterations: 2
direction: Fix config bugs
timeout: 120
max_cost: 3.50
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

# Run dry-run (no CLI flags) — config file should set the values
# Clear inherited env vars so config file takes effect
OUTPUT=$(cd "$REPO" && MAX_ITERATIONS= AUTONOMOUS_DIRECTION= CC_TIMEOUT= MAX_COST_USD= bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*2" "config file sets max_iterations"
assert_contains "$OUTPUT" "Direction:.*Fix config bugs" "config file sets direction"
assert_contains "$OUTPUT" "Timeout:.*120s" "config file sets timeout"
assert_contains "$OUTPUT" "Budget:.*3.50" "config file sets max_cost"
assert_contains "$OUTPUT" "Config:.*autonomous-skill.yml" "dry-run shows config file loaded"

cleanup_repo "$REPO"
echo ""

# ── test_cli_flag_overrides_config ───────────────────────────────────
echo "── test_cli_flag_overrides_config ──"
REPO=$(setup_repo)

cat > "$REPO/.autonomous-skill.yml" << 'EOF'
max_iterations: 2
direction: From config
timeout: 120
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

# CLI flags should override config (clear env vars to isolate)
OUTPUT=$(cd "$REPO" && MAX_ITERATIONS= AUTONOMOUS_DIRECTION= CC_TIMEOUT= MAX_COST_USD= bash "$LOOP" --dry-run --max-iterations 7 --direction "From CLI" --timeout 999 "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*7" "CLI --max-iterations overrides config"
assert_contains "$OUTPUT" "Direction:.*From CLI" "CLI --direction overrides config"
assert_contains "$OUTPUT" "Timeout:.*999s" "CLI --timeout overrides config"

cleanup_repo "$REPO"
echo ""

# ── test_env_var_overrides_config ────────────────────────────────────
echo "── test_env_var_overrides_config ──"
REPO=$(setup_repo)

cat > "$REPO/.autonomous-skill.yml" << 'EOF'
max_iterations: 2
direction: From config
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

# Env vars should override config (but not CLI flags)
OUTPUT=$(cd "$REPO" && MAX_ITERATIONS=15 AUTONOMOUS_DIRECTION="From env" bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*15" "env var MAX_ITERATIONS overrides config"
assert_contains "$OUTPUT" "Direction:.*From env" "env var AUTONOMOUS_DIRECTION overrides config"

cleanup_repo "$REPO"
echo ""

# ── test_config_file_in_run_mode ─────────────────────────────────────
echo "── test_config_file_in_run_mode ──"
REPO=$(setup_repo)

cat > "$REPO/.autonomous-skill.yml" << 'EOF'
max_iterations: 1
direction: Config-driven run
timeout: 300
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.10 \
  MAX_ITERATIONS= \
  AUTONOMOUS_DIRECTION= \
  CC_TIMEOUT= \
  MAX_COST_USD= \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*1" "config file max_iterations works in run mode"
assert_contains "$OUTPUT" "Direction:.*Config-driven run" "config file direction works in run mode"
assert_contains "$OUTPUT" "Config:.*autonomous-skill.yml" "run mode shows config loaded"
assert_not_contains "$OUTPUT" "Iteration 2" "config max_iterations stops after 1"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ── test_no_config_file ──────────────────────────────────────────────
echo "── test_no_config_file ──"
REPO=$(setup_repo)

# No config file — defaults should apply (clear env vars)
OUTPUT=$(cd "$REPO" && MAX_ITERATIONS= AUTONOMOUS_DIRECTION= CC_TIMEOUT= MAX_COST_USD= bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "Iterations:.*50" "default max_iterations without config"
assert_contains "$OUTPUT" "Timeout:.*900s" "default timeout without config"
assert_not_contains "$OUTPUT" "Config:" "no config line when file absent"

cleanup_repo "$REPO"
echo ""

# ── test_config_quoted_values ────────────────────────────────────────
echo "── test_config_quoted_values ──"
REPO=$(setup_repo)

# Test that quoted values are handled correctly
cat > "$REPO/.autonomous-skill.yml" << 'EOF'
direction: "Fix all the things"
max_iterations: 3
EOF
git -C "$REPO" add .autonomous-skill.yml
git -C "$REPO" commit -m "add config" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$(cd "$REPO" && MAX_ITERATIONS= AUTONOMOUS_DIRECTION= CC_TIMEOUT= MAX_COST_USD= bash "$LOOP" --dry-run "$REPO" 2>&1)

assert_contains "$OUTPUT" "Direction:.*Fix all the things" "config handles double-quoted values"
assert_contains "$OUTPUT" "Iterations:.*3" "config handles unquoted numeric values"

cleanup_repo "$REPO"
echo ""

# ── test_help_lists_config ───────────────────────────────────────────
echo "── test_help_lists_config ──"
OUTPUT=$(bash "$LOOP" --help 2>&1)
assert_contains "$OUTPUT" "autonomous-skill.yml" "--help mentions config file"
assert_contains "$OUTPUT" "max_iterations" "--help shows config keys"
assert_contains "$OUTPUT" "Priority.*CLI.*env.*config.*default" "--help shows priority chain"
echo ""

# ─── Test: discover.sh scans extended file types ─────────────────
echo "── test_discover_extended_filetypes ──"
REPO=$(setup_repo)

# Create files with TODO comments in newly-supported file types
cat > "$REPO/App.tsx" << 'EOF'
// TODO: migrate to server components
export default function App() { return <div /> }
EOF

cat > "$REPO/Button.jsx" << 'EOF'
// FIXME: accessibility aria-label missing
export const Button = () => <button />
EOF

cat > "$REPO/main.c" << 'EOF'
// TODO: free allocated memory in cleanup
int main() { return 0; }
EOF

cat > "$REPO/engine.cpp" << 'EOF'
// HACK: workaround for race condition in renderer
void render() {}
EOF

cat > "$REPO/NOTES.md" << 'EOF'
<!-- TODO: document the deploy process -->
# Notes
EOF

git -C "$REPO" add -A
git -C "$REPO" commit -m "add multi-lang source files" --no-gpg-sign --quiet 2>/dev/null

OUTPUT=$("$PROJECT_ROOT/scripts/discover.sh" "$REPO" 2>/dev/null)

assert_contains "$OUTPUT" "server components" "discover.sh finds TODO in .tsx"
assert_contains "$OUTPUT" "aria-label" "discover.sh finds FIXME in .jsx"
assert_contains "$OUTPUT" "free allocated memory" "discover.sh finds TODO in .c"
assert_contains "$OUTPUT" "race condition" "discover.sh finds HACK in .cpp"
assert_contains "$OUTPUT" "deploy process" "discover.sh finds TODO in .md"

cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh basic output ─────────────────────────────────
echo "── test_status_basic ──"
REPO=$(setup_repo)

# Run a session to create a branch and log file
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=0.50 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

# Now run status.sh
STATUS_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" 2>&1)

assert_contains "$STATUS_OUTPUT" "AUTONOMOUS STATUS" "status.sh shows header"
assert_contains "$STATUS_OUTPUT" "Latest Branch" "status.sh shows latest branch section"
assert_contains "$STATUS_OUTPUT" "auto/session-" "status.sh shows session branch"
assert_contains "$STATUS_OUTPUT" "ahead of main" "status.sh shows commit count"
assert_contains "$STATUS_OUTPUT" "Cumulative Stats" "status.sh shows cumulative section"

SLUG=$(basename "$REPO")
rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh JSON output ──────────────────────────────────
echo "── test_status_json ──"
REPO=$(setup_repo)

# Run a session
OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MOCK_CLAUDE_COST=1.25 \
  MAX_ITERATIONS=1 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

# Get JSON status
JSON_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" --json 2>&1)

# Validate JSON structure
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq -e '.project' >/dev/null 2>&1; then
  pass "status.sh --json produces valid JSON with project field"
else
  fail "status.sh --json invalid JSON"
fi

TESTS_RUN=$((TESTS_RUN + 1))
PROJ=$(echo "$JSON_OUTPUT" | jq -r '.project' 2>/dev/null)
SLUG=$(basename "$REPO")
if [ "$PROJ" = "$SLUG" ]; then
  pass "status.sh --json project matches slug"
else
  fail "status.sh --json project mismatch (got '$PROJ', expected '$SLUG')"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq -e '.latest_branch | test("auto/session-")' >/dev/null 2>&1; then
  pass "status.sh --json latest_branch is a session branch"
else
  fail "status.sh --json latest_branch missing or wrong"
fi

TESTS_RUN=$((TESTS_RUN + 1))
COST=$(echo "$JSON_OUTPUT" | jq -r '.total_cost' 2>/dev/null)
if echo "$COST" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
  pass "status.sh --json total_cost is numeric"
else
  fail "status.sh --json total_cost not numeric (got '$COST')"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq -e '.sentinel_active == false' >/dev/null 2>&1; then
  pass "status.sh --json sentinel_active is false"
else
  fail "status.sh --json sentinel_active not false"
fi

rm -f "$HOME/.autonomous-skill/projects/$SLUG/autonomous-log.jsonl"
cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh no sessions ──────────────────────────────────
echo "── test_status_no_sessions ──"
REPO=$(setup_repo)

STATUS_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" 2>&1)

assert_contains "$STATUS_OUTPUT" "AUTONOMOUS STATUS" "status.sh works with no sessions"
assert_contains "$STATUS_OUTPUT" "No session branches" "status.sh says no branches found"
assert_contains "$STATUS_OUTPUT" "No log file" "status.sh says no log file"

cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh sentinel detection ───────────────────────────
echo "── test_status_sentinel ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
SDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$SDATA_DIR"
touch "$SDATA_DIR/.stop-autonomous"

STATUS_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" 2>&1)

assert_contains "$STATUS_OUTPUT" "Stop sentinel.*ACTIVE" "status.sh detects sentinel file"

# JSON sentinel check
JSON_OUTPUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" --json 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$JSON_OUTPUT" | jq -e '.sentinel_active == true' >/dev/null 2>&1; then
  pass "status.sh --json sentinel_active is true when sentinel exists"
else
  fail "status.sh --json sentinel_active should be true"
fi

rm -f "$SDATA_DIR/.stop-autonomous"
cleanup_repo "$REPO"
echo ""

# ─── Test: loop.sh --status flag ──────────────────────────────────
echo "── test_loop_status_flag ──"
REPO=$(setup_repo)

STATUS_OUTPUT=$(cd "$REPO" && bash "$LOOP" --status "$REPO" 2>&1)
assert_contains "$STATUS_OUTPUT" "AUTONOMOUS STATUS" "--status flag invokes status.sh"
assert_contains "$STATUS_OUTPUT" "No session branches" "--status works on fresh repo"

cleanup_repo "$REPO"
echo ""

# ─── Test: loop.sh --stop creates sentinel ────────────────────────
echo "── test_loop_stop_flag ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
SDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"

# --stop should create sentinel file
STOP_OUTPUT=$(bash "$LOOP" --stop "$REPO" 2>&1)
assert_contains "$STOP_OUTPUT" "Stop sentinel created" "--stop shows confirmation"
assert_contains "$STOP_OUTPUT" "$SLUG" "--stop shows project slug"

TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$SDATA_DIR/.stop-autonomous" ]; then
  pass "--stop creates sentinel file"
else
  fail "--stop did not create sentinel file"
fi

rm -rf "$SDATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: --stop + running session stops loop ────────────────────
echo "── test_stop_sentinel_stops_loop ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
SDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$SDATA_DIR"

# Pre-create sentinel, then run loop — should stop immediately
touch "$SDATA_DIR/.stop-autonomous"

OUTPUT=$(cd "$REPO" && \
  MOCK_CLAUDE_COMMIT=1 \
  MOCK_CLAUDE_REPO="$REPO" \
  MAX_ITERATIONS=5 \
  PATH="$SCRIPT_DIR:$PATH" \
  bash "$LOOP" "$REPO" 2>&1)

assert_contains "$OUTPUT" "Sentinel file detected" "pre-existing sentinel stops loop"

# Verify sentinel was cleaned up
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -f "$SDATA_DIR/.stop-autonomous" ]; then
  pass "sentinel file removed after detection"
else
  fail "sentinel file not cleaned up"
fi

rm -rf "$SDATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: report.sh color flags ─────────────────────────────────
echo "── test_report_color_flags ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
CDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$CDATA_DIR"

cat > "$CDATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-01T00:00:00Z","session":"200","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-200"}
{"ts":"2025-01-01T00:01:00Z","session":"200","iteration":1,"event":"success","cost_usd":0.10,"detail":"commits=1, elapsed=30s"}
{"ts":"2025-01-01T00:02:00Z","session":"200","iteration":1,"event":"session_end","cost_usd":0,"detail":"iterations=1, commits=1, duration=60s"}
EOF

# --no-color should produce no ANSI escapes
NO_COLOR_OUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --no-color 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$NO_COLOR_OUT" | grep -q $'\033\['; then
  fail "report.sh --no-color still has ANSI escapes"
else
  pass "report.sh --no-color strips ANSI escapes"
fi

# --color should force ANSI escapes even when piped
COLOR_OUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" --color 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$COLOR_OUT" | grep -q $'\033\['; then
  pass "report.sh --color forces ANSI escapes"
else
  fail "report.sh --color did not produce ANSI escapes"
fi

# Default (piped) should have no ANSI escapes
DEFAULT_OUT=$("$PROJECT_ROOT/scripts/report.sh" "$REPO" 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$DEFAULT_OUT" | grep -q $'\033\['; then
  fail "report.sh default (piped) has ANSI escapes"
else
  pass "report.sh default (piped) has no ANSI escapes"
fi

rm -rf "$CDATA_DIR"
cleanup_repo "$REPO"
echo ""

# ─── Test: status.sh color flags ─────────────────────────────────
echo "── test_status_color_flags ──"
REPO=$(setup_repo)
SLUG=$(basename "$REPO")
CDATA_DIR="$HOME/.autonomous-skill/projects/$SLUG"
mkdir -p "$CDATA_DIR"

cat > "$CDATA_DIR/autonomous-log.jsonl" << 'EOF'
{"ts":"2025-01-01T00:00:00Z","session":"300","iteration":0,"event":"session_start","cost_usd":0,"detail":"branch=auto/session-300"}
{"ts":"2025-01-01T00:01:00Z","session":"300","iteration":1,"event":"session_end","cost_usd":0.05,"detail":"iterations=1, commits=0, duration=30s"}
EOF

# --no-color should produce no ANSI escapes
NO_COLOR_OUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" --no-color 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$NO_COLOR_OUT" | grep -q $'\033\['; then
  fail "status.sh --no-color still has ANSI escapes"
else
  pass "status.sh --no-color strips ANSI escapes"
fi

# --color should force ANSI escapes even when piped
COLOR_OUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" --color 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$COLOR_OUT" | grep -q $'\033\['; then
  pass "status.sh --color forces ANSI escapes"
else
  fail "status.sh --color did not produce ANSI escapes"
fi

# Default (piped) should have no ANSI escapes
DEFAULT_OUT=$(bash "$PROJECT_ROOT/scripts/status.sh" "$REPO" 2>&1)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$DEFAULT_OUT" | grep -q $'\033\['; then
  fail "status.sh default (piped) has ANSI escapes"
else
  pass "status.sh default (piped) has no ANSI escapes"
fi

rm -rf "$CDATA_DIR"
cleanup_repo "$REPO"
echo ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════"
echo "  Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
echo "═══════════════════════════════════════════════════"

if [ "$TESTS_FAILED" -gt 0 ]; then
  echo ""
  echo "Failures:"
  printf "%b" "$FAILURES"
  exit 1
fi

exit 0
