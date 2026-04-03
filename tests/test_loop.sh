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
