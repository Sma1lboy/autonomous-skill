#!/usr/bin/env bash
# test-stability.sh — Run a test suite multiple times and identify flaky tests.
# Compares pass/fail status across runs to find tests that are inconsistent.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: test-stability.sh <test_command> [options]

Run a test suite multiple times and identify flaky tests.

Arguments:
  test_command   The test command to run (e.g., "bash tests/test_foo.sh")

Options:
  --runs N       Number of runs (default: 3)
  --fix          Analyze test file for common flakiness patterns
  --json         Output JSON report
  -h, --help     Show this help message

Output:
  Default: summary table showing total runs, consistent passes, consistent
           fails, and flaky tests with their pass/fail counts.
  --json:  Machine-readable JSON with per-test details.
  --fix:   Scan test file for common bash flakiness patterns with suggestions.

Examples:
  bash scripts/test-stability.sh "bash tests/test_parse_args.sh" --runs 5
  bash scripts/test-stability.sh "bash tests/test_comms.sh" --json
  bash scripts/test-stability.sh "bash tests/test_comms.sh" --fix
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

# ── Parse arguments ──────────────────────────────────────────────────────

TEST_CMD=""
NUM_RUNS=3
FIX_MODE=false
JSON_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --runs)
      [ -z "${2:-}" ] && die "--runs requires a number"
      NUM_RUNS="$2"
      shift 2
      ;;
    --fix)
      FIX_MODE=true
      shift
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    *)
      if [ -z "$TEST_CMD" ]; then
        TEST_CMD="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -z "$TEST_CMD" ] && die "Usage: test-stability.sh <test_command> [options]"
[[ "$NUM_RUNS" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer, got: $NUM_RUNS"

# ── Fix mode: static analysis for flakiness patterns ─────────────────────

if [ "$FIX_MODE" = true ]; then
  # Extract the test file path from the command
  TEST_FILE=""
  for word in $TEST_CMD; do
    if [ -f "$word" ]; then
      TEST_FILE="$word"
      break
    fi
  done

  if [ -z "$TEST_FILE" ]; then
    die "Cannot find test file in command: $TEST_CMD"
  fi

  echo "Scanning $TEST_FILE for flakiness patterns..."
  echo ""

  FOUND=0

  # Pattern 1: Race conditions — sleep followed by assertions
  while IFS= read -r line; do
    LINENO_NUM=$(echo "$line" | cut -d: -f1)
    echo "  Line $LINENO_NUM: Race condition — sleep before assertion"
    echo "    Suggestion: Use a polling loop with timeout instead of fixed sleep"
    echo ""
    FOUND=$((FOUND + 1))
  done < <(grep -n 'sleep' "$TEST_FILE" 2>/dev/null | grep -v '^#' || true)

  # Pattern 2: Shared temp dirs — tests using the same directory
  while IFS= read -r line; do
    LINENO_NUM=$(echo "$line" | cut -d: -f1)
    CONTENT=$(echo "$line" | cut -d: -f2-)
    if echo "$CONTENT" | grep -qE '/tmp/[a-zA-Z]|TMPDIR|/var/tmp'; then
      echo "  Line $LINENO_NUM: Shared temp dir — hardcoded temp path"
      echo "    Suggestion: Use mktemp -d for isolated temp directories per test"
      echo ""
      FOUND=$((FOUND + 1))
    fi
  done < <(grep -n -E '/tmp/[a-zA-Z]|TMPDIR|/var/tmp' "$TEST_FILE" 2>/dev/null | grep -v '^#' || true)

  # Pattern 3: PID-dependent assertions
  while IFS= read -r line; do
    LINENO_NUM=$(echo "$line" | cut -d: -f1)
    echo "  Line $LINENO_NUM: PID-dependent assertion"
    echo "    Suggestion: Avoid comparing exact PIDs across runs; check process liveness instead"
    echo ""
    FOUND=$((FOUND + 1))
  done < <(grep -n -E 'assert.*(PID|\$\$|\$!)' "$TEST_FILE" 2>/dev/null | grep -v '^#' || true)

  # Pattern 4: Timing-dependent assertions
  while IFS= read -r line; do
    LINENO_NUM=$(echo "$line" | cut -d: -f1)
    echo "  Line $LINENO_NUM: Timing-dependent — wall clock assertion"
    echo "    Suggestion: Use relative time comparisons or generous tolerances"
    echo ""
    FOUND=$((FOUND + 1))
  done < <(grep -n -E 'date \+%s|SECONDS|time |elapsed' "$TEST_FILE" 2>/dev/null | grep -v '^#' || true)

  # Pattern 5: Port conflicts
  while IFS= read -r line; do
    LINENO_NUM=$(echo "$line" | cut -d: -f1)
    echo "  Line $LINENO_NUM: Port conflict — hardcoded port number"
    echo "    Suggestion: Use port 0 or a random available port"
    echo ""
    FOUND=$((FOUND + 1))
  done < <(grep -n -E ':(3000|4000|5000|8000|8080|9090|[0-9]{4,5})' "$TEST_FILE" 2>/dev/null | grep -v '^#' || true)

  if [ "$FOUND" -eq 0 ]; then
    echo "  No common flakiness patterns detected."
  else
    echo "Found $FOUND potential flakiness pattern(s)."
  fi
  exit 0
fi

# ── Run tests multiple times, collect raw results ────────────────────────

RESULTS_DIR=$(mktemp -d)
trap 'rm -rf "$RESULTS_DIR"' EXIT

for run in $(seq 1 "$NUM_RUNS"); do
  echo "Run $run/$NUM_RUNS..." >&2
  eval "$TEST_CMD" 2>/dev/null > "$RESULTS_DIR/run-$run.txt" || true
done

# ── Aggregate results via python3 (avoids bash 4 associative arrays) ─────

python3 -c "
import json, re, sys, os, glob

results_dir = sys.argv[1]
num_runs = int(sys.argv[2])
json_mode = sys.argv[3] == 'true'

# Collect per-test pass/fail across all runs
# test_name -> {'pass': N, 'fail': N}
tests = {}

for run in range(1, num_runs + 1):
    run_file = os.path.join(results_dir, f'run-{run}.txt')
    if not os.path.isfile(run_file):
        continue
    with open(run_file) as f:
        for line in f:
            # Match '  ok  <test_name>'
            m = re.match(r'^\s*ok\s+(.+)$', line)
            if m:
                name = m.group(1).strip()
                tests.setdefault(name, {'pass': 0, 'fail': 0})
                tests[name]['pass'] += 1
                continue
            # Match '  FAIL <test_name> — got ...'
            m = re.match(r'^\s*FAIL\s+(.+)$', line)
            if m:
                raw = m.group(1).strip()
                # Strip ' — got ...' suffix
                name = re.sub(r'\s*—\s*got\s.*$', '', raw)
                tests.setdefault(name, {'pass': 0, 'fail': 0})
                tests[name]['fail'] += 1

# Classify
consistent_pass = 0
consistent_fail = 0
flaky_count = 0
flaky_tests = []

for name, counts in sorted(tests.items()):
    if counts['fail'] == 0:
        consistent_pass += 1
    elif counts['pass'] == 0:
        consistent_fail += 1
    else:
        flaky_count += 1
        flaky_tests.append((name, counts['pass'], counts['fail']))

total = len(tests)

if json_mode:
    all_tests = []
    for name, counts in sorted(tests.items()):
        is_flaky = counts['pass'] > 0 and counts['fail'] > 0
        all_tests.append({
            'name': name,
            'passes': counts['pass'],
            'failures': counts['fail'],
            'flaky': is_flaky
        })
    all_tests.sort(key=lambda t: (not t['flaky'], t['name']))

    result = {
        'runs': num_runs,
        'total_tests': total,
        'consistent_pass': consistent_pass,
        'consistent_fail': consistent_fail,
        'flaky': flaky_count,
        'tests': all_tests
    }
    print(json.dumps(result, indent=2))
else:
    print()
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
    print(' Test Stability Report')
    print('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
    print()
    print(f'Runs:             {num_runs}')
    print(f'Total tests:      {total}')
    print(f'Consistent pass:  {consistent_pass}')
    print(f'Consistent fail:  {consistent_fail}')
    print(f'Flaky:            {flaky_count}')

    if flaky_tests:
        print()
        print('Flaky tests:')
        for name, p, f in flaky_tests:
            print(f'  - {name} (pass: {p}, fail: {f})')

    print()
    if flaky_count == 0:
        print('All tests are stable.')
    else:
        print(f'{flaky_count} flaky test(s) detected.')
" "$RESULTS_DIR" "$NUM_RUNS" "$JSON_MODE"
