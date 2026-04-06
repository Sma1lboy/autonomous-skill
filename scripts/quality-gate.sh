#!/usr/bin/env bash
# quality-gate.sh — Automated build/test verification after sprint merge.
# Runs the project's test command and reports pass/fail with structured JSON output.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: quality-gate.sh <project-dir> [--dry-run] [--timeout SECONDS]

Run the project's test command and report pass/fail as structured JSON.

Uses detect-framework.sh to determine the test command, or reads a custom
test_command from .autonomous/skill-config.json if present.

Arguments:
  project-dir    Path to the project root

Options:
  --dry-run      Show what would run without executing
  --timeout N    Test command timeout in seconds (default: 300)
  -h, --help     Show this help message

Output (JSON to stdout):
  {"passed":true,"test_command":"npm test","output":"...","duration_seconds":5}

Exit codes:
  0  Tests passed (or no test command available)
  1  Tests failed

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

# ── No test command available ────────────────────────────────────────────

if [ -z "$TEST_CMD" ]; then
  python3 -c "
import json
d = {'passed': True, 'test_command': None, 'output': 'no test command detected for this project', 'duration_seconds': 0}
print(json.dumps(d))
"
  exit 0
fi

# ── Dry run ──────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  python3 -c "
import json, sys
d = {'dry_run': True, 'test_command': sys.argv[1], 'message': 'would run test command (dry-run mode)'}
print(json.dumps(d))
" "$TEST_CMD"
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

# ── Structured JSON output ───────────────────────────────────────────────

python3 -c "
import json, sys

start = float(sys.argv[1])
end = float(sys.argv[2])
duration = round(end - start, 1)
passed = sys.argv[3] == 'true'
test_cmd = sys.argv[4]
timed_out = sys.argv[5] == 'true'

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
    'duration_seconds': duration
}
print(json.dumps(d))
" "$START_TIME" "$END_TIME" "$PASSED" "$TEST_CMD" "$TIMED_OUT" "$TIMEOUT" <<< "$OUTPUT"

# Exit with appropriate code
[ "$PASSED" = true ] && exit 0 || exit 1
