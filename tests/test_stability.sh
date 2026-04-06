#!/usr/bin/env bash
# Tests for scripts/test-stability.sh — flaky test detection tool.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STABILITY="$SCRIPT_DIR/../scripts/test-stability.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_stability.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# Helper: create mock test scripts
# ═══════════════════════════════════════════════════════════════════════════

TMP=$(new_tmp)

# A stable test script (always passes)
cat > "$TMP/stable_test.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "  ok  test alpha"
echo "  ok  test beta"
echo "  ok  test gamma"
echo ""
echo "Results: 3 passed, 0 failed"
SCRIPT
chmod +x "$TMP/stable_test.sh"

# A consistently failing test script
cat > "$TMP/failing_test.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "  ok  test one"
echo "  FAIL test two — got 'a', want 'b'"
echo "  FAIL test three — got '1', want '2'"
echo ""
echo "Results: 1 passed, 2 failed"
SCRIPT
chmod +x "$TMP/failing_test.sh"

# A flaky test script that alternates based on a counter file
cat > "$TMP/flaky_test.sh" << 'SCRIPT'
#!/usr/bin/env bash
COUNTER_FILE="${FLAKY_COUNTER_FILE:-/tmp/flaky_counter}"
COUNT=0
if [ -f "$COUNTER_FILE" ]; then
  COUNT=$(cat "$COUNTER_FILE")
fi
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"

echo "  ok  stable test"
if [ $((COUNT % 2)) -eq 0 ]; then
  echo "  ok  flaky test"
else
  echo "  FAIL flaky test — got 'odd', want 'even'"
fi
echo "  ok  another stable test"
SCRIPT
chmod +x "$TMP/flaky_test.sh"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help flag"

HELP=$(bash "$STABILITY" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
assert_contains "$HELP" "runs" "--help mentions runs"
assert_contains "$HELP" "fix" "--help mentions fix"
assert_contains "$HELP" "json" "--help mentions json"

bash "$STABILITY" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

bash "$STABILITY" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Missing args
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Missing args"

bash "$STABILITY" 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "no command exits 1"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Stable tests — --runs 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Stable tests — --runs 1"

OUT=$(bash "$STABILITY" "bash $TMP/stable_test.sh" --runs 1 2>/dev/null)
assert_contains "$OUT" "Runs:             1" "shows 1 run"
assert_contains "$OUT" "Total tests:      3" "shows 3 total tests"
assert_contains "$OUT" "Consistent pass:  3" "3 consistent passes"
assert_contains "$OUT" "Flaky:            0" "0 flaky tests"
assert_contains "$OUT" "All tests are stable" "stable message shown"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Stable tests — --runs 3
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Stable tests — --runs 3"

OUT=$(bash "$STABILITY" "bash $TMP/stable_test.sh" --runs 3 2>/dev/null)
assert_contains "$OUT" "Runs:             3" "shows 3 runs"
assert_contains "$OUT" "Consistent pass:  3" "3 consistent passes over 3 runs"
assert_contains "$OUT" "Flaky:            0" "0 flaky after 3 runs"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Consistently failing tests
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Consistently failing tests"

OUT=$(bash "$STABILITY" "bash $TMP/failing_test.sh" --runs 3 2>/dev/null)
assert_contains "$OUT" "Total tests:      3" "3 total tests"
assert_contains "$OUT" "Consistent pass:  1" "1 consistent pass"
assert_contains "$OUT" "Consistent fail:  2" "2 consistent fails"
assert_contains "$OUT" "Flaky:            0" "0 flaky (failures are consistent)"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Flaky test detection — --runs 3
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Flaky test detection — --runs 3"

# Reset counter
COUNTER="$TMP/flaky_counter_test6"
rm -f "$COUNTER"

OUT=$(FLAKY_COUNTER_FILE="$COUNTER" bash "$STABILITY" "FLAKY_COUNTER_FILE=$COUNTER bash $TMP/flaky_test.sh" --runs 3 2>/dev/null)
assert_contains "$OUT" "Flaky:" "shows flaky section"
# With 3 runs: run1=FAIL, run2=ok, run3=FAIL → flaky test has pass:1 fail:2
assert_contains "$OUT" "flaky test" "identifies the flaky test by name"
assert_contains "$OUT" "Consistent pass:  2" "2 stable tests"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Flaky test detection — --runs 5
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Flaky test detection — --runs 5"

COUNTER="$TMP/flaky_counter_test7"
rm -f "$COUNTER"

OUT=$(FLAKY_COUNTER_FILE="$COUNTER" bash "$STABILITY" "FLAKY_COUNTER_FILE=$COUNTER bash $TMP/flaky_test.sh" --runs 5 2>/dev/null)
assert_contains "$OUT" "Runs:             5" "shows 5 runs"
assert_contains "$OUT" "flaky test" "finds flaky test in 5 runs"
assert_contains "$OUT" "flaky test(s) detected" "detection message shown"

# ═══════════════════════════════════════════════════════════════════════════
# 8. JSON mode — stable tests
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. JSON mode — stable tests"

OUT=$(bash "$STABILITY" "bash $TMP/stable_test.sh" --runs 2 --json 2>/dev/null)

# Verify it's valid JSON
python3 -c "import json,sys; json.loads(sys.argv[1])" "$OUT" 2>/dev/null
assert_eq "$?" "0" "JSON output is valid JSON"

RUNS=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['runs'])" "$OUT")
assert_eq "$RUNS" "2" "JSON runs=2"

TOTAL=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['total_tests'])" "$OUT")
assert_eq "$TOTAL" "3" "JSON total_tests=3"

FLAKY=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['flaky'])" "$OUT")
assert_eq "$FLAKY" "0" "JSON flaky=0"

CPASS=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['consistent_pass'])" "$OUT")
assert_eq "$CPASS" "3" "JSON consistent_pass=3"

# ═══════════════════════════════════════════════════════════════════════════
# 9. JSON mode — flaky tests
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. JSON mode — flaky tests"

COUNTER="$TMP/flaky_counter_test9"
rm -f "$COUNTER"

OUT=$(FLAKY_COUNTER_FILE="$COUNTER" bash "$STABILITY" "FLAKY_COUNTER_FILE=$COUNTER bash $TMP/flaky_test.sh" --runs 4 --json 2>/dev/null)

python3 -c "import json,sys; json.loads(sys.argv[1])" "$OUT" 2>/dev/null
assert_eq "$?" "0" "flaky JSON is valid"

FLAKY=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['flaky'])" "$OUT")
assert_eq "$FLAKY" "1" "JSON flaky=1"

# Check that flaky test has passes and failures
HAS_FLAKY=$(python3 -c "
import json,sys
d = json.loads(sys.argv[1])
for t in d['tests']:
    if t['flaky']:
        print(f\"{t['passes']}:{t['failures']}\")
        break
" "$OUT")
assert_contains "$HAS_FLAKY" ":" "flaky test has pass:fail counts"

# Verify test entries have expected fields
HAS_NAME=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('name' in d['tests'][0])" "$OUT")
assert_eq "$HAS_NAME" "True" "JSON test entries have name field"

HAS_PASSES=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('passes' in d['tests'][0])" "$OUT")
assert_eq "$HAS_PASSES" "True" "JSON test entries have passes field"

HAS_FLAKY_FIELD=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('flaky' in d['tests'][0])" "$OUT")
assert_eq "$HAS_FLAKY_FIELD" "True" "JSON test entries have flaky field"

# ═══════════════════════════════════════════════════════════════════════════
# 10. --fix mode — detect sleep patterns
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. --fix mode — detect patterns"

cat > "$TMP/flaky_patterns.sh" << 'SCRIPT'
#!/usr/bin/env bash
sleep 2
assert_eq "$OUT" "value" "test after sleep"
PID_VAL=$$
assert_eq "$PID_VAL" "12345" "PID check"
START=$(date +%s)
echo "port :8080"
echo "connect to :3000"
echo "use /tmp/mytest for data"
SCRIPT

OUT=$(bash "$STABILITY" "$TMP/flaky_patterns.sh" --fix 2>/dev/null)
assert_contains "$OUT" "Race condition" "fix detects sleep pattern"
assert_contains "$OUT" "Suggestion" "fix provides suggestions"

echo ""
echo "11. --fix mode — detect PID assertions"

assert_contains "$OUT" "PID-dependent" "fix detects PID assertion"

echo ""
echo "12. --fix mode — detect timing"

assert_contains "$OUT" "Timing-dependent" "fix detects timing pattern"

echo ""
echo "13. --fix mode — detect port conflicts"

assert_contains "$OUT" "Port conflict" "fix detects port conflict"

echo ""
echo "14. --fix mode — detect shared temp dirs"

assert_contains "$OUT" "Shared temp dir" "fix detects shared temp dir"

echo ""
echo "15. --fix mode — clean file"

cat > "$TMP/clean_test.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "  ok  clean test"
SCRIPT

OUT=$(bash "$STABILITY" "$TMP/clean_test.sh" --fix 2>/dev/null)
assert_contains "$OUT" "No common flakiness patterns" "fix reports clean file"

echo ""
echo "16. --fix mode — shows line numbers"

OUT=$(bash "$STABILITY" "$TMP/flaky_patterns.sh" --fix 2>/dev/null)
assert_contains "$OUT" "Line" "fix shows line numbers"

echo ""
echo "17. --fix mode — pattern count"

assert_contains "$OUT" "potential flakiness pattern" "fix shows pattern count"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Real test suite — test_parse_args.sh
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Real test suite — test_parse_args.sh"

REAL_TEST="$SCRIPT_DIR/test_parse_args.sh"
if [ -f "$REAL_TEST" ]; then
  OUT=$(bash "$STABILITY" "bash $REAL_TEST" --runs 2 2>/dev/null)
  assert_contains "$OUT" "Flaky:            0" "test_parse_args.sh has 0 flaky tests"
  assert_contains "$OUT" "All tests are stable" "test_parse_args.sh is stable"
else
  ok "test_parse_args.sh not found — skipped"
  ok "test_parse_args.sh stability — skipped"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 19. Invalid --runs
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Invalid --runs"

bash "$STABILITY" "echo test" --runs 0 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "--runs 0 exits 1"

bash "$STABILITY" "echo test" --runs abc 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "--runs abc exits 1"

bash "$STABILITY" "echo test" --runs -1 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "--runs -1 exits 1"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Empty test output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Empty test output"

OUT=$(bash "$STABILITY" "echo nothing" --runs 1 2>/dev/null)
assert_contains "$OUT" "Total tests:      0" "empty output → 0 tests"
assert_contains "$OUT" "Flaky:            0" "empty output → 0 flaky"

# ═══════════════════════════════════════════════════════════════════════════
# 21. --runs 1 with flaky (no flaky possible with 1 run)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. Single run — no flaky possible"

COUNTER="$TMP/flaky_counter_test21"
rm -f "$COUNTER"

OUT=$(FLAKY_COUNTER_FILE="$COUNTER" bash "$STABILITY" "FLAKY_COUNTER_FILE=$COUNTER bash $TMP/flaky_test.sh" --runs 1 2>/dev/null)
assert_contains "$OUT" "Flaky:            0" "single run cannot detect flaky"

print_results
