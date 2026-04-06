#!/usr/bin/env bash
# Tests for scripts/run-all-tests.sh — the parallel test runner.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/../scripts/run-all-tests.sh"

# Helper: create a mini project with test files for runner to discover
new_test_project() {
  local d; d=$(new_tmp)
  mkdir -p "$d/tests" "$d/scripts"
  # Copy the runner into the mini project
  cp "$RUNNER" "$d/scripts/run-all-tests.sh"
  echo "$d"
}

# Helper: create a passing test file
write_passing_test() {
  local dir="$1" name="$2"
  cat > "$dir/tests/${name}.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
ok() { echo "  ok  $*"; ((PASS++)) || true; }
echo "  ok passing test"
PASS=1
echo ""
echo " Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
EOF
  chmod +x "$dir/tests/${name}.sh"
}

# Helper: create a failing test file
write_failing_test() {
  local dir="$1" name="$2"
  cat > "$dir/tests/${name}.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
echo "  FAIL failing test"
FAIL=1
echo ""
echo " Results: $PASS passed, $FAIL failed"
exit 1
EOF
  chmod +x "$dir/tests/${name}.sh"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_run_all_tests.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help flag shows usage
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help flag"

HELP=$(bash "$RUNNER" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
echo "$HELP" | grep -qF -- "--sequential" && ok "--help mentions --sequential" || fail "--help mentions --sequential"
echo "$HELP" | grep -qF -- "--filter" && ok "--help mentions --filter" || fail "--help mentions --filter"

bash "$RUNNER" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Discovers test files correctly
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Discovers test files"

P=$(new_test_project)
write_passing_test "$P" "test_alpha"
write_passing_test "$P" "test_beta"
write_passing_test "$P" "test_gamma"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "3 suites" "discovers 3 test files"
assert_contains "$OUT" "test_alpha" "output mentions test_alpha"
assert_contains "$OUT" "test_beta" "output mentions test_beta"
assert_contains "$OUT" "test_gamma" "output mentions test_gamma"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Sequential mode works
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Sequential mode"

P=$(new_test_project)
write_passing_test "$P" "test_one"
write_passing_test "$P" "test_two"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "PASS" "sequential mode produces PASS"
assert_contains "$OUT" "2 suites" "sequential finds 2 suites"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Filter mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Filter mode"

P=$(new_test_project)
write_passing_test "$P" "test_backlog_ops"
write_passing_test "$P" "test_conductor_ops"
write_passing_test "$P" "test_backlog_extra"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential --filter "backlog" 2>&1) || true
assert_contains "$OUT" "2 suites" "filter 'backlog' finds 2 suites"
assert_contains "$OUT" "test_backlog_ops" "filter includes test_backlog_ops"
assert_not_contains "$OUT" "test_conductor_ops" "filter excludes test_conductor_ops"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Reports correct pass/fail counts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Pass/fail counts"

P=$(new_test_project)
write_passing_test "$P" "test_good"
write_failing_test "$P" "test_bad"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "1 passed, 1 failed" "suite counts: 1 passed, 1 failed"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Exit code 0 when all pass
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Exit 0 when all pass"

P=$(new_test_project)
write_passing_test "$P" "test_ok1"
write_passing_test "$P" "test_ok2"

(cd "$P" && bash scripts/run-all-tests.sh --sequential >/dev/null 2>&1)
assert_eq "$?" "0" "exit 0 when all suites pass"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Exit code 1 when any fail
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Exit 1 when any fail"

P=$(new_test_project)
write_passing_test "$P" "test_ok"
write_failing_test "$P" "test_nok"

RC=0
(cd "$P" && bash scripts/run-all-tests.sh --sequential >/dev/null 2>&1) || RC=$?
assert_eq "$RC" "1" "exit 1 when a suite fails"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Skips test_integration.sh by default
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Skips test_integration.sh by default"

P=$(new_test_project)
write_passing_test "$P" "test_normal"
write_passing_test "$P" "test_integration"

OUT=$(cd "$P" && INTEGRATION_TEST="" bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "1 suites" "only 1 suite found (integration skipped)"
assert_not_contains "$OUT" "test_integration" "test_integration not in output"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Runs test_integration.sh when INTEGRATION_TEST=1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Includes test_integration.sh when INTEGRATION_TEST=1"

P=$(new_test_project)
write_passing_test "$P" "test_normal"
write_passing_test "$P" "test_integration"

OUT=$(cd "$P" && INTEGRATION_TEST=1 bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "2 suites" "2 suites with INTEGRATION_TEST=1"
assert_contains "$OUT" "test_integration" "test_integration in output"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Summary output format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Summary output format"

P=$(new_test_project)
write_passing_test "$P" "test_fmt1"
write_passing_test "$P" "test_fmt2"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "Total suites:" "summary has Total suites"
assert_contains "$OUT" "Total assertions:" "summary has Total assertions"
assert_contains "$OUT" "Overall:" "summary has Overall"

# ═══════════════════════════════════════════════════════════════════════════
# 11. No test files found
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. No test files found"

P=$(new_test_project)
# Remove any test files (none were created yet anyway)
rm -f "$P"/tests/test_*.sh 2>/dev/null || true

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "No test files found" "reports no test files"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Empty tests directory
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Empty tests directory"

P=$(new_test_project)
rm -f "$P"/tests/test_*.sh 2>/dev/null || true

RC=0
OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || RC=$?
assert_eq "$RC" "0" "empty dir exits 0"
assert_contains "$OUT" "No test files found" "empty dir reports no files"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Parallel mode works (default)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Parallel mode (default)"

P=$(new_test_project)
write_passing_test "$P" "test_par1"
write_passing_test "$P" "test_par2"
write_passing_test "$P" "test_par3"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh 2>&1) || true
assert_contains "$OUT" "3 suites" "parallel mode discovers 3 suites"
assert_contains "$OUT" "Overall: PASS" "parallel mode overall PASS"

# ═══════════════════════════════════════════════════════════════════════════
# 14. PASS label in output for passing suites
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. PASS/FAIL labels"

P=$(new_test_project)
write_passing_test "$P" "test_labeled"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "PASS  test_labeled" "PASS label for passing suite"

# ═══════════════════════════════════════════════════════════════════════════
# 15. FAIL label in output for failing suites
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. FAIL label"

P=$(new_test_project)
write_failing_test "$P" "test_broken"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "FAIL  test_broken" "FAIL label for failing suite"

# ═══════════════════════════════════════════════════════════════════════════
# 16. -h short flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. -h short flag"

HELP=$(bash "$RUNNER" -h 2>&1)
assert_contains "$HELP" "Usage:" "-h shows Usage"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Assertion totals aggregate across suites
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Assertion totals aggregate"

P=$(new_test_project)
# Create a test with 3 passes
cat > "$P/tests/test_multi.sh" << 'EOF'
#!/usr/bin/env bash
PASS=0; FAIL=0
ok() { echo "  ok  $*"; ((PASS++)) || true; }
ok "a"; ok "b"; ok "c"
echo " Results: $PASS passed, $FAIL failed"
EOF
chmod +x "$P/tests/test_multi.sh"

# Create a test with 2 passes
cat > "$P/tests/test_duo.sh" << 'EOF'
#!/usr/bin/env bash
PASS=0; FAIL=0
ok() { echo "  ok  $*"; ((PASS++)) || true; }
ok "x"; ok "y"
echo " Results: $PASS passed, $FAIL failed"
EOF
chmod +x "$P/tests/test_duo.sh"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "5 passed" "total assertions: 5 passed"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Unknown argument errors
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Unknown argument"

RC=0
OUT=$(bash "$RUNNER" --bogus 2>&1) || RC=$?
assert_eq "$RC" "1" "unknown arg exits 1"
assert_contains "$OUT" "ERROR" "unknown arg prints ERROR"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Filter with no matches
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Filter with no matches"

P=$(new_test_project)
write_passing_test "$P" "test_alpha"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential --filter "zzzzz" 2>&1) || true
assert_contains "$OUT" "No test files found" "filter with no matches reports no files"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Overall FAIL when mixed results
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Overall FAIL with mixed results"

P=$(new_test_project)
write_passing_test "$P" "test_mixed_ok"
write_failing_test "$P" "test_mixed_bad"

OUT=$(cd "$P" && bash scripts/run-all-tests.sh --sequential 2>&1) || true
assert_contains "$OUT" "Overall: FAIL" "mixed results → Overall: FAIL"

print_results
