#!/usr/bin/env bash
# run-all-tests.sh — Parallel test runner with summary
#
# Usage: bash scripts/run-all-tests.sh [--help] [--sequential] [--filter PATTERN]
#
# Discovers all tests/test_*.sh files, runs them (in parallel by default),
# and prints a summary with per-suite and aggregate pass/fail counts.
# Skips test_integration.sh unless INTEGRATION_TEST=1 is set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$PROJECT_DIR/tests"

usage() {
  echo "Usage: bash scripts/run-all-tests.sh [--help] [--sequential] [--filter PATTERN]"
  echo ""
  echo "Run all test suites and print a summary."
  echo ""
  echo "Options:"
  echo "  --help         Show this help message"
  echo "  --sequential   Run tests sequentially (default: parallel)"
  echo "  --filter PAT   Only run test files whose name matches PATTERN"
  echo ""
  echo "Environment:"
  echo "  INTEGRATION_TEST=1   Include test_integration.sh (skipped by default)"
}

SEQUENTIAL=0
FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h|help)
      usage
      exit 0
      ;;
    --sequential)
      SEQUENTIAL=1
      shift
      ;;
    --filter)
      FILTER="${2:?--filter requires a PATTERN argument}"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Discover test files
TEST_FILES=()
for f in "$TESTS_DIR"/test_*.sh; do
  [ -f "$f" ] || continue

  BASENAME=$(basename "$f")

  # Skip integration tests unless explicitly enabled
  if [ "$BASENAME" = "test_integration.sh" ] && [ "${INTEGRATION_TEST:-}" != "1" ]; then
    continue
  fi

  # Apply filter
  if [ -n "$FILTER" ] && ! echo "$BASENAME" | grep -q "$FILTER"; then
    continue
  fi

  TEST_FILES+=("$f")
done

if [ ${#TEST_FILES[@]} -eq 0 ]; then
  echo "No test files found."
  exit 0
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " run-all-tests.sh — ${#TEST_FILES[@]} suites"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create temp dir for outputs
TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# ── Run a single test suite, capture output + exit code ──────────────────
run_one() {
  local test_file="$1"
  local basename
  basename=$(basename "$test_file" .sh)
  local outfile="$TMPDIR_RUN/${basename}.out"
  local rcfile="$TMPDIR_RUN/${basename}.rc"

  bash "$test_file" > "$outfile" 2>&1 || true
  echo $? > "$rcfile"
}

# ── Execute suites ───────────────────────────────────────────────────────
if [ "$SEQUENTIAL" -eq 1 ]; then
  for f in "${TEST_FILES[@]}"; do
    run_one "$f"
  done
else
  # Determine parallelism
  NCPU=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

  # Export for xargs subshells
  export TMPDIR_RUN
  export -f run_one 2>/dev/null || true

  # Write a helper script for xargs to invoke
  XARGS_HELPER="$TMPDIR_RUN/_run_one.sh"
  cat > "$XARGS_HELPER" << HELPEREOF
#!/usr/bin/env bash
set -euo pipefail
test_file="\$1"
basename=\$(basename "\$test_file" .sh)
outfile="$TMPDIR_RUN/\${basename}.out"
rcfile="$TMPDIR_RUN/\${basename}.rc"
bash "\$test_file" > "\$outfile" 2>&1 || true
echo \$? > "\$rcfile"
HELPEREOF
  chmod +x "$XARGS_HELPER"

  # Use xargs -P for parallel execution; fall back to sequential
  if printf '%s\n' "${TEST_FILES[@]}" | xargs -P "$NCPU" -I{} bash "$XARGS_HELPER" {} 2>/dev/null; then
    : # parallel succeeded
  else
    # Fallback to sequential
    for f in "${TEST_FILES[@]}"; do
      run_one "$f"
    done
  fi
fi

# ── Collect results ──────────────────────────────────────────────────────
TOTAL_SUITES=0
TOTAL_PASS=0
TOTAL_FAIL=0
SUITES_PASSED=0
SUITES_FAILED=0
ANY_FAIL=0

echo ""
for f in "${TEST_FILES[@]}"; do
  BASENAME=$(basename "$f" .sh)
  OUTFILE="$TMPDIR_RUN/${BASENAME}.out"
  RCFILE="$TMPDIR_RUN/${BASENAME}.rc"

  ((TOTAL_SUITES++)) || true

  RC=1
  [ -f "$RCFILE" ] && RC=$(cat "$RCFILE")

  # Parse "Results: X passed, Y failed" from output
  SUITE_PASS=0
  SUITE_FAIL=0
  if [ -f "$OUTFILE" ]; then
    RESULTS_LINE=$(grep -E 'Results:.*passed.*failed' "$OUTFILE" | tail -1 || true)
    if [ -n "$RESULTS_LINE" ]; then
      SUITE_PASS=$(echo "$RESULTS_LINE" | sed -E 's/.*Results: *([0-9]+) *passed.*/\1/' || echo 0)
      SUITE_FAIL=$(echo "$RESULTS_LINE" | sed -E 's/.*passed, *([0-9]+) *failed.*/\1/' || echo 0)
    fi
  fi

  TOTAL_PASS=$((TOTAL_PASS + SUITE_PASS))
  TOTAL_FAIL=$((TOTAL_FAIL + SUITE_FAIL))

  if [ "$RC" -eq 0 ] && [ "$SUITE_FAIL" -eq 0 ]; then
    echo "  PASS  ${BASENAME}  (${SUITE_PASS} passed, ${SUITE_FAIL} failed)"
    ((SUITES_PASSED++)) || true
  else
    echo "  FAIL  ${BASENAME}  (${SUITE_PASS} passed, ${SUITE_FAIL} failed)  [exit $RC]"
    ((SUITES_FAILED++)) || true
    ANY_FAIL=1
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Total suites: $TOTAL_SUITES ($SUITES_PASSED passed, $SUITES_FAILED failed)"
echo " Total assertions: $((TOTAL_PASS + TOTAL_FAIL)) ($TOTAL_PASS passed, $TOTAL_FAIL failed)"
if [ "$ANY_FAIL" -eq 0 ]; then
  echo " Overall: PASS"
else
  echo " Overall: FAIL"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Print output of failed suites for debugging
if [ "$ANY_FAIL" -eq 1 ]; then
  for f in "${TEST_FILES[@]}"; do
    BASENAME=$(basename "$f" .sh)
    RCFILE="$TMPDIR_RUN/${BASENAME}.rc"
    OUTFILE="$TMPDIR_RUN/${BASENAME}.out"
    RC=1
    [ -f "$RCFILE" ] && RC=$(cat "$RCFILE")
    if [ "$RC" -ne 0 ]; then
      echo "─── FAIL output: ${BASENAME} ───"
      tail -20 "$OUTFILE" 2>/dev/null || true
      echo ""
    fi
  done
fi

exit "$ANY_FAIL"
