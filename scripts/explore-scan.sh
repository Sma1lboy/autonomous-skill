#!/usr/bin/env bash
# explore-scan.sh — Scan a project and score all 8 exploration dimensions.
# Called by the Conductor (SKILL.md) before explore-pick to replace blind
# priority-order selection with data-driven scoring.
# Layer: conductor

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: explore-scan.sh <project-dir> [conductor-state-script] [--deep] [--no-cache]

Scan a project and score all 8 exploration dimensions (0-10, higher = better).
Scores are written to conductor-state.json via conductor-state.sh explore-score.

Dimensions scored:
  test_coverage    Ratio of test files to source files
  error_handling   Files with error-handling patterns (try/catch/rescue)
  security         Hardcoded secrets, TODO-security markers, .env files
  code_quality     TODO/FIXME/HACK/XXX markers
  documentation    README existence, freshness, docs/ directory
  architecture     Files over 300 lines (fewer = better)
  performance      Sleep/N+1 antipatterns
  dx               CLI scripts with --help/usage patterns

Arguments:
  project-dir            Path to the project to scan (default: current directory)
  conductor-state-script Path to conductor-state.sh (default: auto-detected)

Options:
  --deep       Run actual test/lint commands for more accurate scoring.
               Uses detect-framework.sh to find test_command and lint_command.
               Results are cached in .autonomous/scan-cache.json (1 hour TTL).
  --no-cache   Force fresh deep scan (ignore cached results).

Requires: an initialized conductor state (.autonomous/conductor-state.json)
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

ARCH_LINE_THRESHOLD=300
SECONDS_PER_DAY=86400
STALENESS_DAYS=180

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments (positional + flags) ─────────────────────────────────
DEEP_MODE=false
NO_CACHE=false
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --deep)    DEEP_MODE=true; shift ;;
    --no-cache) NO_CACHE=true; shift ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done

PROJECT="${POSITIONAL[0]:-.}"
CONDUCTOR="${POSITIONAL[1]:-$SCRIPT_DIR/conductor-state.sh}"

[ -d "$PROJECT" ] || { echo "ERROR: project dir not found: $PROJECT" >&2; exit 1; }
[ -f "$CONDUCTOR" ] || { echo "ERROR: conductor-state.sh not found: $CONDUCTOR" >&2; exit 1; }

DEEP_TIMEOUT="${AUTONOMOUS_DEEP_TIMEOUT:-30}"
SCAN_CACHE="$PROJECT/.autonomous/scan-cache.json"
CACHE_TTL=3600  # 1 hour

# ── Common exclusion patterns for find/grep ───────────────────────────────
# Directories to exclude from all scanning (noise dirs that inflate counts).
EXCLUDE_PATHS=(
  -not -path '*/node_modules/*'
  -not -path '*/.git/*'
  -not -path '*/.autonomous/*'
  -not -path '*/vendor/*'
  -not -path '*/dist/*'
  -not -path '*/build/*'
)

# Grep --exclude-dir flags — prevents grep from descending into noise
# directories at all, rather than scanning them then filtering with sed.
# On large repos (e.g. node_modules with 100k+ files) this is 10-100x faster.
GREP_EXCLUDE_DIRS=(
  --exclude-dir=node_modules
  --exclude-dir=.git
  --exclude-dir=.autonomous
  --exclude-dir=vendor
  --exclude-dir=dist
  --exclude-dir=build
)

# ── Helpers ────────────────────────────────────────────────────────────────

# Clamp a value to 0-10 integer. Returns 0 on empty/non-numeric input.
# Uses AST-based safe eval — only allows numeric constants and arithmetic operators.
clamp() {
  local expr="${1:-0}"
  python3 -c "
import sys, ast, operator
def safe_eval(expr):
    ops = {ast.Add: operator.add, ast.Sub: operator.sub,
           ast.Mult: operator.mul, ast.Div: operator.truediv,
           ast.FloorDiv: operator.floordiv, ast.USub: operator.neg}
    def _eval(node):
        if isinstance(node, ast.Expression): return _eval(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.BinOp) and type(node.op) in ops:
            return ops[type(node.op)](_eval(node.left), _eval(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in ops:
            return ops[type(node.op)](_eval(node.operand))
        raise ValueError('unsafe expression')
    return _eval(ast.parse(expr, mode='eval'))
try:
    print(max(0, min(10, int(safe_eval(sys.argv[1])))))
except Exception:
    print(0)
" "$expr"
}

# Count files matching a find pattern (uses shared EXCLUDE_PATHS)
count_files() {
  find "$PROJECT" -type f "$@" "${EXCLUDE_PATHS[@]}" \
    2>/dev/null | wc -l | tr -d ' '
}

# Count files containing a grep pattern (uses shared GREP_EXCLUDE_DIRS).
# The || true prevents exit-code-1-on-no-match from failing under pipefail.
count_grep() {
  local pattern="$1"; shift
  { grep -rl "$pattern" "$PROJECT" "${GREP_EXCLUDE_DIRS[@]}" "$@" 2>/dev/null || true; } \
    | wc -l | tr -d ' '
}

# Score a dimension
score() {
  local dim="$1" val="$2"
  bash "$CONDUCTOR" explore-score "$PROJECT" "$dim" "$val" >/dev/null
  echo "  $dim: $val"
}

# ── Deep scan helpers ──────────────────────────────────────────────────────

# Read cached deep results if valid (< 1 hour old). Outputs JSON or empty string.
read_deep_cache() {
  if [ "$NO_CACHE" = true ]; then
    echo ""
    return 0
  fi
  if [ ! -f "$SCAN_CACHE" ]; then
    echo ""
    return 0
  fi
  python3 -c "
import json, sys, time
try:
    with open(sys.argv[1]) as f:
        cache = json.load(f)
    ts = cache.get('timestamp', 0)
    if (int(time.time()) - ts) < int(sys.argv[2]):
        print(json.dumps(cache.get('deep_results', {})))
    else:
        print('')
except Exception:
    print('')
" "$SCAN_CACHE" "$CACHE_TTL"
}

# Write deep results to cache.
write_deep_cache() {
  local results_json="$1"
  python3 -c "
import json, os, sys, time
results = json.loads(sys.argv[1])
project = os.path.abspath(sys.argv[2])
cache = {'timestamp': int(time.time()), 'project': project, 'deep_results': results}
cache_file = sys.argv[3]
os.makedirs(os.path.dirname(cache_file), exist_ok=True)
tmp = cache_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(cache, f, indent=2)
os.replace(tmp, cache_file)
" "$results_json" "$PROJECT" "$SCAN_CACHE"
}

# Run test command and parse output for pass/fail counts.
# Output: "pass fail" (two integers) or "0 0" on failure/timeout.
deep_test_coverage() {
  local test_cmd="$1"
  if [ -z "$test_cmd" ] || [ "$test_cmd" = "null" ]; then
    echo "0 0"
    return 0
  fi
  local output
  output=$(cd "$PROJECT" && timeout "$DEEP_TIMEOUT" bash -c "$test_cmd" 2>&1) || true

  python3 -c "
import re, sys
output = sys.argv[1]

passed = 0
failed = 0

# Jest/vitest: 'N passed', 'N failed'
for m in re.finditer(r'(\d+)\s+passed', output):
    passed += int(m.group(1))
for m in re.finditer(r'(\d+)\s+failed', output):
    failed += int(m.group(1))

# pytest: 'N passed', 'N failed' (same pattern)
# go test: 'ok' lines = pass, 'FAIL' lines = fail
if passed == 0 and failed == 0:
    passed += len(re.findall(r'^ok\s', output, re.MULTILINE))
    failed += len(re.findall(r'^FAIL\s', output, re.MULTILINE))

# Bash test harness: 'N passed, N failed'
if passed == 0 and failed == 0:
    m = re.search(r'(\d+)\s+passed.*?(\d+)\s+failed', output)
    if m:
        passed = int(m.group(1))
        failed = int(m.group(2))

# Generic: 'Tests: N' or 'N tests'
if passed == 0 and failed == 0:
    for m in re.finditer(r'(\d+)\s+tests?', output, re.IGNORECASE):
        passed += int(m.group(1))
    for m in re.finditer(r'failures?:\s*(\d+)', output, re.IGNORECASE):
        failed += int(m.group(1))

print(f'{passed} {failed}')
" "$output"
}

# Run shellcheck and count errors/warnings.
# Output: integer count.
deep_code_quality() {
  local framework="$1"
  if [ "$framework" != "bash" ]; then
    echo "0"
    return 0
  fi
  if ! command -v shellcheck &>/dev/null; then
    echo "0"
    return 0
  fi
  local count
  count=$(cd "$PROJECT" && shellcheck scripts/*.sh 2>&1 | grep -c 'error\|warning' || true)
  echo "${count:-0}"
}

# ── Source file extensions (used by multiple heuristics) ───────────────────

SRC_EXTS=(-name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.tsx' \
          -o -name '*.rb' -o -name '*.go' -o -name '*.rs' -o -name '*.sh' \
          -o -name '*.java')

# ── Deep scan: detect framework and run real commands ─────────────────────

DEEP_TEST_PASS=0
DEEP_TEST_FAIL=0
DEEP_SC_ERRORS=0
DEEP_FRAMEWORK=""
DEEP_RESULTS_JSON="{}"

if [ "$DEEP_MODE" = true ]; then
  CACHED=$(read_deep_cache)
  if [ -n "$CACHED" ] && [ "$CACHED" != "{}" ]; then
    echo "Using cached deep scan results."
    DEEP_TEST_PASS=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('test_coverage',{}).get('pass',0))" "$CACHED")
    DEEP_TEST_FAIL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('test_coverage',{}).get('fail',0))" "$CACHED")
    DEEP_SC_ERRORS=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('code_quality',{}).get('shellcheck_errors',0))" "$CACHED")
    DEEP_FRAMEWORK=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('framework',''))" "$CACHED")
  else
    echo "Running deep scan..."
    DETECT_SCRIPT="$SCRIPT_DIR/detect-framework.sh"
    if [ -f "$DETECT_SCRIPT" ]; then
      FW_JSON=$(bash "$DETECT_SCRIPT" "$PROJECT" 2>/dev/null) || FW_JSON='{"framework":"unknown"}'
      DEEP_FRAMEWORK=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('framework','unknown'))" "$FW_JSON")
      TEST_CMD=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('test_command',''))" "$FW_JSON")

      # Run test command
      COUNTS=$(deep_test_coverage "$TEST_CMD")
      DEEP_TEST_PASS=$(echo "$COUNTS" | cut -d' ' -f1)
      DEEP_TEST_FAIL=$(echo "$COUNTS" | cut -d' ' -f2)

      # Run shellcheck for bash projects
      DEEP_SC_ERRORS=$(deep_code_quality "$DEEP_FRAMEWORK")
    fi

    # Compute deep scores
    DEEP_TC_TOTAL=$((DEEP_TEST_PASS + DEEP_TEST_FAIL))
    if [ "$DEEP_TC_TOTAL" -gt 0 ]; then
      DEEP_TC_SCORE=$(clamp "$DEEP_TEST_PASS * 10 / $DEEP_TC_TOTAL")
    else
      DEEP_TC_SCORE=0
    fi
    DEEP_CQ_SCORE=$(clamp "10 - $DEEP_SC_ERRORS")

    DEEP_RESULTS_JSON=$(python3 -c "
import json, sys
results = {
    'framework': sys.argv[1],
    'test_coverage': {'pass': int(sys.argv[2]), 'fail': int(sys.argv[3]), 'score': int(sys.argv[4])},
    'code_quality': {'shellcheck_errors': int(sys.argv[5]), 'score': int(sys.argv[6])}
}
print(json.dumps(results))
" "$DEEP_FRAMEWORK" "$DEEP_TEST_PASS" "$DEEP_TEST_FAIL" "$DEEP_TC_SCORE" "$DEEP_SC_ERRORS" "$DEEP_CQ_SCORE")

    write_deep_cache "$DEEP_RESULTS_JSON"
  fi
fi

# ── Scoring ────────────────────────────────────────────────────────────────

echo "Scanning project: $PROJECT"

# Always compute _s (source file count) — needed by error_handling even in deep mode
_srcs=$(find "$PROJECT" -type f \( "${SRC_EXTS[@]}" \) \
  "${EXCLUDE_PATHS[@]}" -not -name '*test*' -not -name '*spec*' \
  2>/dev/null | wc -l | tr -d ' ')
_s=${_srcs:-0}
[ "$_s" -eq 0 ] && _s=1

# 1. test_coverage: ratio of test files to non-test source files
# --deep: use actual test pass/fail counts instead of file ratio
if [ "$DEEP_MODE" = true ] && [ $((DEEP_TEST_PASS + DEEP_TEST_FAIL)) -gt 0 ]; then
  _tc_total=$((DEEP_TEST_PASS + DEEP_TEST_FAIL))
  score "test_coverage" "$(clamp "$DEEP_TEST_PASS * 10 / $_tc_total")"
else
  _tests=$(count_files \( -name '*test*' -o -name '*spec*' -o -name '*_test.*' \))
  score "test_coverage" "$(clamp "$_tests * 10 / $_s")"
fi

# 2. error_handling: files with error-handling patterns per source file
_errs=$(count_grep 'try\|catch\|rescue\|except\|raise\|throw' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' \
  --include='*.go' --include='*.rs' --include='*.sh')
score "error_handling" "$(clamp "$_errs * 10 / $_s")"

# 3. security: fewer issues = higher score (inverted)
_sec_issues=$(count_grep 'TODO.*secur\|FIXME.*secur' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' --include='*.sh')
_secrets=$(count_grep 'password\s*=\s*["'"'"']\|api_key\s*=\s*["'"'"']\|secret\s*=\s*["'"'"']' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' --include='*.sh')
_envf=$(find "$PROJECT" -maxdepth 3 -name '.env' "${EXCLUDE_PATHS[@]}" 2>/dev/null | wc -l | tr -d ' ')
score "security" "$(clamp "10 - ($_sec_issues + $_secrets + $_envf) * 2")"

# 4. code_quality: fewer TODO/FIXME/HACK = higher score (inverted)
# --deep + bash: factor in shellcheck error/warning count
_todos=$(count_grep 'TODO\|FIXME\|HACK\|XXX' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' \
  --include='*.sh' --include='*.go' --include='*.rs')
if [ "$DEEP_MODE" = true ] && [ "$DEEP_SC_ERRORS" -gt 0 ]; then
  score "code_quality" "$(clamp "10 - $_todos - $DEEP_SC_ERRORS")"
else
  score "code_quality" "$(clamp "10 - $_todos")"
fi

# 5. documentation: README existence + freshness + docs/ directory
_ds=0
[ -f "$PROJECT/README.md" ] && _ds=$((_ds + 4))
[ -d "$PROJECT/docs" ] && _ds=$((_ds + 3))
if [ -f "$PROJECT/README.md" ] && command -v git &>/dev/null; then
  _rf=$(python3 -c "
import subprocess, datetime, sys
r = subprocess.run(['git','log','-1','--format=%ct','--','README.md'],
                   capture_output=True, text=True, cwd=sys.argv[1])
ts = int(r.stdout.strip()) if r.stdout.strip() else 0
days = (datetime.datetime.now().timestamp() - ts) / $SECONDS_PER_DAY if ts else 999
print(min(3, round(3 * max(0, 1 - days / $STALENESS_DAYS))))
" "$PROJECT" 2>/dev/null || echo "0")
  _ds=$((_ds + _rf))
fi
score "documentation" "$(clamp "$_ds")"

# 6. architecture: fewer files > 300 lines = better
# Uses -exec wc -l {} + to batch all files into one wc invocation,
# instead of forking one awk per file (avoids thousands of forks on large repos).
_big=$(find "$PROJECT" -type f \( "${SRC_EXTS[@]}" \) \
  "${EXCLUDE_PATHS[@]}" \
  -exec wc -l {} + 2>/dev/null \
  | awk -v threshold="$ARCH_LINE_THRESHOLD" '$1 > threshold && !/total$/' \
  | wc -l | tr -d ' ')
score "architecture" "$(clamp "10 - $_big * 2")"

# 7. performance: fewer sleep/N+1 antipatterns = better
_perf=$(count_grep 'sleep\|\.each.*\.save\|\.each.*\.update\|N+1\|n+1' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb')
score "performance" "$(clamp "10 - $_perf * 2")"

# 8. dx: CLI scripts with --help/usage patterns
_help=$(count_grep '\-\-help\|usage()\|Usage:\|usage:' \
  --include='*.sh' --include='*.py' --include='*.js')
_cli=$(find "$PROJECT" -type f -name '*.sh' "${EXCLUDE_PATHS[@]}" \
  2>/dev/null | wc -l | tr -d ' ')
_c=${_cli:-0}
[ "$_c" -eq 0 ] && _c=1
score "dx" "$(clamp "$_help * 10 / $_c")"

echo "Exploration scan complete."
