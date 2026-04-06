#!/usr/bin/env bash
# quality-gate.sh — Automated build/test verification after sprint merge.
# Runs the project's test command and reports pass/fail with structured JSON output.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: quality-gate.sh <project-dir> [--dry-run] [--timeout SECONDS] [--skip-shellcheck]

Run the project's test command and report pass/fail as structured JSON.
Also runs shellcheck on changed .sh files if shellcheck is available.

Uses detect-framework.sh to determine the test command, or reads a custom
test_command from .autonomous/skill-config.json if present.

Arguments:
  project-dir    Path to the project root

Options:
  --dry-run          Show what would run without executing
  --timeout N        Test command timeout in seconds (default: 300)
  --skip-shellcheck  Skip shellcheck integration
  -h, --help         Show this help message

Output (JSON to stdout):
  {"passed":true,"test_command":"npm test","output":"...","duration_seconds":5,
   "shellcheck":{"passed":true,"files_checked":3,"errors":[],"skipped":false,"skip_reason":null}}

Exit codes:
  0  Tests passed and shellcheck clean (or no test command available)
  1  Tests failed or shellcheck found errors

Examples:
  bash scripts/quality-gate.sh ./my-project
  bash scripts/quality-gate.sh ./my-project --dry-run
  bash scripts/quality-gate.sh ./my-project --timeout 60
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || die "python3 required but not found"

# ── Parse arguments ──────────────────────────────────────────────────────

PROJECT_DIR=""
DRY_RUN=false
TIMEOUT=300
SKIP_SHELLCHECK=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --timeout)
      [ -z "${2:-}" ] && die "--timeout requires a value"
      TIMEOUT="$2"
      shift 2
      ;;
    --skip-shellcheck)
      SKIP_SHELLCHECK=true
      shift
      ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -z "$PROJECT_DIR" ] && die "project-dir is required. Run with --help for usage."
[ -d "$PROJECT_DIR" ] || die "project dir not found: $PROJECT_DIR"

# Validate timeout is a positive integer
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "timeout must be a positive integer, got: $TIMEOUT"
[ "$TIMEOUT" -gt 0 ] || die "timeout must be > 0, got: $TIMEOUT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Determine test command ───────────────────────────────────────────────

TEST_CMD=""

# Check skill-config.json override first
CONFIG_FILE="$PROJECT_DIR/.autonomous/skill-config.json"
if [ -f "$CONFIG_FILE" ]; then
  OVERRIDE=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    cmd = d.get('test_command', '')
    if cmd:
        print(cmd)
except Exception:
    pass
" "$CONFIG_FILE" 2>/dev/null || true)
  [ -n "$OVERRIDE" ] && TEST_CMD="$OVERRIDE"
fi

# Fall back to detect-framework.sh
if [ -z "$TEST_CMD" ]; then
  DETECTION=$(bash "$SCRIPT_DIR/detect-framework.sh" "$PROJECT_DIR" 2>/dev/null || echo '{"framework":"unknown"}')
  TEST_CMD=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    cmd = d.get('test_command', '')
    if cmd:
        print(cmd)
except Exception:
    pass
" "$DETECTION" 2>/dev/null || true)
fi

# ── Shellcheck helper function ──────────────────────────────────────────

_find_changed_sh_files() {
  local pdir="$1"
  local files=""
  # Try git diff for recently changed .sh files (last 10 commits)
  if command -v git &>/dev/null && [ -d "$pdir/.git" ]; then
    files=$(cd "$pdir" && git diff --diff-filter=ACMR --name-only HEAD~10 -- '*.sh' 2>/dev/null || true)
  fi
  # Fall back to scripts/*.sh if git diff fails or returns empty
  if [ -z "$files" ]; then
    files=$(cd "$pdir" && find scripts -name '*.sh' -type f 2>/dev/null | sort || true)
  fi
  echo "$files"
}

_run_shellcheck() {
  local pdir="$1"
  local skip="$2"

  if [ "$skip" = "true" ]; then
    python3 -c "
import json
d = {'passed':True,'files_checked':0,'errors':[],'skipped':True,'skip_reason':'--skip-shellcheck flag'}
print(json.dumps(d))
"
    return
  fi

  if ! command -v shellcheck &>/dev/null; then
    python3 -c "
import json
d = {'passed':True,'files_checked':0,'errors':[],'skipped':True,'skip_reason':'shellcheck not installed'}
print(json.dumps(d))
"
    return
  fi

  local sh_files
  sh_files=$(_find_changed_sh_files "$pdir")

  if [ -z "$sh_files" ]; then
    python3 -c "
import json
d = {'passed':True,'files_checked':0,'errors':[],'skipped':False,'skip_reason':None}
print(json.dumps(d))
"
    return
  fi

  local file_count=0
  local errors=()
  local has_error=false

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -f "$pdir/$f" ] || continue
    ((file_count++)) || true
    local sc_out
    sc_out=$(shellcheck --severity=error "$pdir/$f" 2>&1 || true)
    if [ -n "$sc_out" ]; then
      has_error=true
      while IFS= read -r line; do
        [ -n "$line" ] && errors+=("$line")
      done <<< "$sc_out"
    fi
  done <<< "$sh_files"

  local passed=true
  [ "$has_error" = "true" ] && passed=false

  python3 -c "
import json, sys
passed = sys.argv[1] == 'true'
files_checked = int(sys.argv[2])
# Errors passed as remaining args
errors = sys.argv[3:]
d = {'passed':passed,'files_checked':files_checked,'errors':errors,'skipped':False,'skip_reason':None}
print(json.dumps(d))
" "$passed" "$file_count" "${errors[@]+"${errors[@]}"}"
}

# ── No test command available ────────────────────────────────────────────

if [ -z "$TEST_CMD" ]; then
  SC_RESULT=$(_run_shellcheck "$PROJECT_DIR" "$SKIP_SHELLCHECK")
  SC_PASSED=$(python3 -c "import json,sys; print('true' if json.loads(sys.argv[1]).get('passed',True) else 'false')" "$SC_RESULT")
  _NO_CMD_PASSED=true
  [ "$SC_PASSED" = "false" ] && _NO_CMD_PASSED=false
  python3 -c "
import json, sys
sc = json.loads(sys.argv[1])
passed = sys.argv[2] == 'true'
d = {'passed': passed, 'test_command': None, 'output': 'no test command detected for this project', 'duration_seconds': 0, 'shellcheck': sc}
print(json.dumps(d))
" "$SC_RESULT" "$_NO_CMD_PASSED"
  [ "$_NO_CMD_PASSED" = true ] && exit 0 || exit 1
fi

# ── Dry run ──────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  SC_FILES=$(_find_changed_sh_files "$PROJECT_DIR")
  SC_COUNT=0
  if [ -n "$SC_FILES" ]; then
    SC_COUNT=$(echo "$SC_FILES" | grep -c . || true)
  fi
  python3 -c "
import json, sys
d = {
    'dry_run': True,
    'test_command': sys.argv[1],
    'message': 'would run test command (dry-run mode)',
    'shellcheck': {
        'would_check': int(sys.argv[2]),
        'skip_shellcheck': sys.argv[3] == 'true',
        'shellcheck_available': sys.argv[4] == 'true'
    }
}
print(json.dumps(d))
" "$TEST_CMD" "$SC_COUNT" "$SKIP_SHELLCHECK" "$(command -v shellcheck &>/dev/null && echo true || echo false)"
  exit 0
fi

# ── Execute test command ─────────────────────────────────────────────────

START_TIME=$(python3 -c "import time; print(time.time())")

OUTPUT=""
EXIT_CODE=0
if command -v timeout &>/dev/null; then
  OUTPUT=$(cd "$PROJECT_DIR" && timeout "$TIMEOUT" bash -c "$TEST_CMD" 2>&1) || EXIT_CODE=$?
elif command -v gtimeout &>/dev/null; then
  OUTPUT=$(cd "$PROJECT_DIR" && gtimeout "$TIMEOUT" bash -c "$TEST_CMD" 2>&1) || EXIT_CODE=$?
else
  # No timeout command available — run without timeout
  OUTPUT=$(cd "$PROJECT_DIR" && bash -c "$TEST_CMD" 2>&1) || EXIT_CODE=$?
fi

END_TIME=$(python3 -c "import time; print(time.time())")

# Check for timeout exit code (124 for GNU timeout, 137 for killed)
TIMED_OUT=false
if [ "$EXIT_CODE" -eq 124 ] || [ "$EXIT_CODE" -eq 137 ]; then
  TIMED_OUT=true
fi

PASSED=false
[ "$EXIT_CODE" -eq 0 ] && PASSED=true

# ── Run shellcheck ───────────────────────────────────────────────────────

SC_RESULT=$(_run_shellcheck "$PROJECT_DIR" "$SKIP_SHELLCHECK")

# Check if shellcheck failed and update overall passed status
SC_PASSED=$(python3 -c "import json,sys; print('true' if json.loads(sys.argv[1]).get('passed',True) else 'false')" "$SC_RESULT")
OVERALL_PASSED="$PASSED"
if [ "$SC_PASSED" = "false" ]; then
  OVERALL_PASSED=false
fi

# ── Structured JSON output ───────────────────────────────────────────────

python3 -c "
import json, sys

start = float(sys.argv[1])
end = float(sys.argv[2])
duration = round(end - start, 1)
passed = sys.argv[3] == 'true'
test_cmd = sys.argv[4]
timed_out = sys.argv[5] == 'true'
sc_result = json.loads(sys.argv[7])

# Read output from stdin to handle arbitrary content
output = sys.stdin.read()

# Truncate very long output (keep last 4000 chars)
if len(output) > 4000:
    output = '...(truncated)...\n' + output[-4000:]

if timed_out:
    output = f'TIMEOUT: test command exceeded {sys.argv[6]}s limit\n' + output

d = {
    'passed': passed,
    'test_command': test_cmd,
    'output': output,
    'duration_seconds': duration,
    'shellcheck': sc_result
}
print(json.dumps(d))
" "$START_TIME" "$END_TIME" "$OVERALL_PASSED" "$TEST_CMD" "$TIMED_OUT" "$TIMEOUT" "$SC_RESULT" <<< "$OUTPUT"

# Exit with appropriate code
[ "$OVERALL_PASSED" = true ] && exit 0 || exit 1
