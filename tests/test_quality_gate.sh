#!/usr/bin/env bash
# Tests for scripts/quality-gate.sh — automated build/test verification.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QG="$SCRIPT_DIR/../scripts/quality-gate.sh"

# Helper: get a field from quality-gate JSON output
get_field() {
  local json="$1" field="$2"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); v=d.get(sys.argv[2]); print('None' if v is None else ('true' if v is True else ('false' if v is False else str(v))))" "$json" "$field"
}

# Helper: check JSON is valid
is_valid_json() {
  python3 -c "import json,sys; json.loads(sys.argv[1]); print('yes')" "$1" 2>/dev/null || echo "no"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_quality_gate.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help flag"
OUT=$(bash "$QG" --help 2>&1)
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "quality-gate" "--help mentions script name"
assert_contains "$OUT" "project-dir" "--help mentions project-dir"
assert_contains "$OUT" "dry-run" "--help mentions dry-run"
assert_contains "$OUT" "timeout" "--help mentions timeout"

bash "$QG" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 2. -h short flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. -h short flag"
OUT=$(bash "$QG" -h 2>&1)
assert_contains "$OUT" "Usage" "-h shows usage"

bash "$QG" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Missing project-dir argument fails
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Missing project-dir argument"
ERR=$(bash "$QG" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails without project-dir"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Nonexistent project dir fails
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Nonexistent project dir"
ERR=$(bash "$QG" "/nonexistent/path/xyz" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails on nonexistent dir"
assert_contains "$ERR" "not found" "error mentions not found"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Unknown framework (empty dir) → passed:true with null test_command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Unknown framework (empty dir)"
T=$(new_tmp)
OUT=$(bash "$QG" "$T")
EXIT=$?
PASSED=$(get_field "$OUT" "passed")
TEST_CMD=$(get_field "$OUT" "test_command")
OUTPUT=$(get_field "$OUT" "output")
assert_eq "$EXIT" "0" "unknown framework exits 0"
assert_eq "$PASSED" "true" "unknown framework → passed:true"
assert_eq "$TEST_CMD" "None" "unknown framework → null test_command"
assert_contains "$OUTPUT" "no test command" "output says no test command"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Bash framework detected → correct test_command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Bash framework detected"
T=$(new_tmp)
mkdir -p "$T/scripts" "$T/tests"
echo '#!/bin/bash' > "$T/scripts/foo.sh"
echo '#!/bin/bash' > "$T/tests/test_foo.sh"
# Use dry-run to see what would execute without actually running
OUT=$(bash "$QG" "$T" --dry-run)
TEST_CMD=$(get_field "$OUT" "test_command")
assert_contains "$TEST_CMD" "bash tests/test_" "bash framework → test command contains bash tests/"

# ═══════════════════════════════════════════════════════════════════════════
# 7. --dry-run shows command without executing
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. --dry-run mode"
T=$(new_tmp)
mkdir -p "$T/scripts" "$T/tests"
echo '#!/bin/bash' > "$T/scripts/foo.sh"
echo '#!/bin/bash' > "$T/tests/test_foo.sh"
OUT=$(bash "$QG" "$T" --dry-run)
EXIT=$?
assert_eq "$EXIT" "0" "dry-run exits 0"
DRY=$(get_field "$OUT" "dry_run")
assert_eq "$DRY" "true" "dry-run JSON has dry_run:true"
assert_contains "$OUT" "would run" "dry-run message says would run"

# ═══════════════════════════════════════════════════════════════════════════
# 8. skill-config.json override takes precedence
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. skill-config.json override"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo custom-test-pass"}' > "$T/.autonomous/skill-config.json"
# Also add package.json so detect-framework would find something different
echo '{"scripts":{"test":"jest"}}' > "$T/package.json"
OUT=$(bash "$QG" "$T" --dry-run)
TEST_CMD=$(get_field "$OUT" "test_command")
assert_eq "$TEST_CMD" "echo custom-test-pass" "skill-config override takes precedence"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Test command passes → passed:true, exit 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Test command passes"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo all-tests-pass"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T")
EXIT=$?
PASSED=$(get_field "$OUT" "passed")
assert_eq "$EXIT" "0" "passing tests → exit 0"
assert_eq "$PASSED" "true" "passing tests → passed:true"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Test command fails → passed:false, exit 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Test command fails"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo failing && exit 1"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T" || true)
# Get exit code separately
bash "$QG" "$T" >/dev/null 2>&1 && EXIT=0 || EXIT=$?
PASSED=$(get_field "$OUT" "passed")
assert_eq "$EXIT" "1" "failing tests → exit 1"
assert_eq "$PASSED" "false" "failing tests → passed:false"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Structured JSON output is valid
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Valid JSON output"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo hello-world"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T")
VALID=$(is_valid_json "$OUT")
assert_eq "$VALID" "yes" "output is valid JSON"

# Also check failing case produces valid JSON
T2=$(new_tmp)
mkdir -p "$T2/.autonomous"
echo '{"test_command":"exit 1"}' > "$T2/.autonomous/skill-config.json"
OUT2=$(bash "$QG" "$T2" || true)
VALID2=$(is_valid_json "$OUT2")
assert_eq "$VALID2" "yes" "failing output is also valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 12. duration_seconds is a number >= 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. duration_seconds is numeric"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo fast-test"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T")
DUR_CHECK=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
dur = d.get('duration_seconds', -1)
print('ok' if isinstance(dur, (int, float)) and dur >= 0 else 'bad')
" "$OUT")
assert_eq "$DUR_CHECK" "ok" "duration_seconds is a non-negative number"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Output field captures test output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Output captures stdout and stderr"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo stdout-marker && echo stderr-marker >&2"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T")
OUTPUT_FIELD=$(get_field "$OUT" "output")
assert_contains "$OUTPUT_FIELD" "stdout-marker" "output captures stdout"
assert_contains "$OUTPUT_FIELD" "stderr-marker" "output captures stderr"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Node.js project detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Node.js project detection"
T=$(new_tmp)
echo '{"scripts":{"test":"jest"}}' > "$T/package.json"
OUT=$(bash "$QG" "$T" --dry-run)
TEST_CMD=$(get_field "$OUT" "test_command")
assert_eq "$TEST_CMD" "npm test" "node with test script → npm test"

# ═══════════════════════════════════════════════════════════════════════════
# 15. Python project detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Python project detection"
T=$(new_tmp)
echo "flask" > "$T/requirements.txt"
OUT=$(bash "$QG" "$T" --dry-run)
TEST_CMD=$(get_field "$OUT" "test_command")
assert_eq "$TEST_CMD" "pytest" "python project → pytest"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Rust project detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Rust project detection"
T=$(new_tmp)
echo '[package]' > "$T/Cargo.toml"
OUT=$(bash "$QG" "$T" --dry-run)
TEST_CMD=$(get_field "$OUT" "test_command")
assert_eq "$TEST_CMD" "cargo test" "rust project → cargo test"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Go project detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Go project detection"
T=$(new_tmp)
echo 'module example.com/foo' > "$T/go.mod"
OUT=$(bash "$QG" "$T" --dry-run)
TEST_CMD=$(get_field "$OUT" "test_command")
assert_eq "$TEST_CMD" "go test ./..." "go project → go test ./..."

# ═══════════════════════════════════════════════════════════════════════════
# 18. Empty skill-config.json (no test_command) falls through to detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Empty skill-config falls through"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{}' > "$T/.autonomous/skill-config.json"
echo '[package]' > "$T/Cargo.toml"
OUT=$(bash "$QG" "$T" --dry-run)
TEST_CMD=$(get_field "$OUT" "test_command")
assert_eq "$TEST_CMD" "cargo test" "empty config falls through to detection"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Corrupt skill-config.json falls through to detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Corrupt skill-config falls through"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo 'NOT JSON {{{' > "$T/.autonomous/skill-config.json"
echo 'module example.com/foo' > "$T/go.mod"
OUT=$(bash "$QG" "$T" --dry-run)
TEST_CMD=$(get_field "$OUT" "test_command")
assert_eq "$TEST_CMD" "go test ./..." "corrupt config falls through"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Nonexistent test command → fail
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Nonexistent test command"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"nonexistent_command_xyz_123"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T" || true)
PASSED=$(get_field "$OUT" "passed")
assert_eq "$PASSED" "false" "nonexistent command → passed:false"

# ═══════════════════════════════════════════════════════════════════════════
# 21. JSON output has all required fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. JSON has all required fields"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo check-fields"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T")
FIELDS_OK=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
required = ['passed', 'test_command', 'output', 'duration_seconds']
missing = [f for f in required if f not in d]
print('ok' if not missing else 'missing: ' + ','.join(missing))
" "$OUT")
assert_eq "$FIELDS_OK" "ok" "all required fields present"

# ═══════════════════════════════════════════════════════════════════════════
# 22. Test runs in project directory (cwd)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. Test runs in project directory"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"pwd -P"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T")
OUTPUT_FIELD=$(get_field "$OUT" "output")
# Resolve the real path to handle macOS /private/var symlinks
REAL_T=$(cd "$T" && pwd -P)
assert_contains "$OUTPUT_FIELD" "$REAL_T" "test command runs in project dir"

# ═══════════════════════════════════════════════════════════════════════════
# 23. Invalid --timeout value
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. Invalid --timeout value"
T=$(new_tmp)
ERR=$(bash "$QG" "$T" --timeout "abc" 2>&1 || true)
assert_contains "$ERR" "ERROR" "non-numeric timeout rejected"

ERR2=$(bash "$QG" "$T" --timeout "0" 2>&1 || true)
assert_contains "$ERR2" "ERROR" "zero timeout rejected"

# ═══════════════════════════════════════════════════════════════════════════
# 24. Conductor state integration — quality_gate_passed stored
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. Conductor state integration"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONDUCTOR="$SKILL_DIR/scripts/conductor-state.sh"

T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "test mission" 5 >/dev/null 2>&1
bash "$CONDUCTOR" sprint-start "$T" "do work" >/dev/null 2>&1

# Sprint end with quality_gate_passed=true
bash "$CONDUCTOR" sprint-end "$T" "complete" "done" '["abc test"]' "false" "true" >/dev/null 2>&1

QG_VAL=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['sprints'][0].get('quality_gate_passed', 'missing'))
")
assert_eq "$QG_VAL" "True" "quality_gate_passed=true stored in conductor state"

# Sprint end with quality_gate_passed=false
bash "$CONDUCTOR" sprint-start "$T" "more work" >/dev/null 2>&1
bash "$CONDUCTOR" sprint-end "$T" "complete" "done" '["def test"]' "false" "false" >/dev/null 2>&1

QG_VAL2=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['sprints'][1].get('quality_gate_passed', 'missing'))
")
assert_eq "$QG_VAL2" "False" "quality_gate_passed=false stored in conductor state"

# Sprint end with no quality gate (empty string)
bash "$CONDUCTOR" sprint-start "$T" "last work" >/dev/null 2>&1
bash "$CONDUCTOR" sprint-end "$T" "complete" "done" '["ghi test"]' "false" "" >/dev/null 2>&1

QG_VAL3=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['sprints'][2].get('quality_gate_passed', 'missing'))
")
assert_eq "$QG_VAL3" "None" "quality_gate_passed=null stored when not run"

# ═══════════════════════════════════════════════════════════════════════════
# 25. Session report — table mode shows QG column
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. Session report table mode"
REPORT="$SKILL_DIR/scripts/session-report.sh"

# Reuse the project from test 24 — it has 3 sprints with varying QG states
# Write summary files so session-report can find them
for n in 1 2 3; do
  python3 -c "
import json
d = {'status':'complete','summary':'sprint $n done','commits':['abc$n test'],'direction_complete':False}
with open('$T/.autonomous/sprint-$n-summary.json','w') as f:
    json.dump(d, f)
"
done

TABLE_OUT=$(bash "$REPORT" "$T" 2>&1)
assert_contains "$TABLE_OUT" "QG" "table header shows QG column"
assert_contains "$TABLE_OUT" "pass" "table shows pass for sprint 1"
assert_contains "$TABLE_OUT" "fail" "table shows fail for sprint 2"

# ═══════════════════════════════════════════════════════════════════════════
# 26. Session report — JSON mode includes quality_gate_passed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. Session report JSON mode"
JSON_OUT=$(bash "$REPORT" "$T" --json 2>&1)
QG_JSON=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
sprints = d['sprints']
results = [s.get('quality_gate_passed') for s in sprints]
print(json.dumps(results))
" "$JSON_OUT")
assert_eq "$QG_JSON" "[true, false, null]" "JSON mode has correct quality_gate_passed values"

# ═══════════════════════════════════════════════════════════════════════════
# 27. Session report — detail mode shows quality gate
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. Session report detail mode"
DETAIL_OUT=$(bash "$REPORT" "$T" --detail 1 2>&1)
assert_contains "$DETAIL_OUT" "Quality" "detail mode shows Quality line"
assert_contains "$DETAIL_OUT" "pass" "detail mode shows pass for sprint 1"

DETAIL_OUT2=$(bash "$REPORT" "$T" --detail 2 2>&1)
assert_contains "$DETAIL_OUT2" "FAIL" "detail mode shows FAIL for sprint 2"

DETAIL_OUT3=$(bash "$REPORT" "$T" --detail 3 2>&1)
assert_contains "$DETAIL_OUT3" "not run" "detail mode shows not run for sprint 3"

# ═══════════════════════════════════════════════════════════════════════════
# 28. Multi-line test output captured correctly
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. Multi-line output"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo line1 && echo line2 && echo line3"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T")
OUTPUT_FIELD=$(get_field "$OUT" "output")
assert_contains "$OUTPUT_FIELD" "line1" "multi-line captures line1"
assert_contains "$OUTPUT_FIELD" "line3" "multi-line captures line3"

# ═══════════════════════════════════════════════════════════════════════════
# 29. Dry-run JSON is valid
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Dry-run JSON validity"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"test_command":"echo test"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$QG" "$T" --dry-run)
VALID=$(is_valid_json "$OUT")
assert_eq "$VALID" "yes" "dry-run output is valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 30. No test command + dry-run still exits 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. No test command (empty dir) + various flags"
T=$(new_tmp)
OUT=$(bash "$QG" "$T")
EXIT=$?
assert_eq "$EXIT" "0" "no test command → exits 0"
VALID=$(is_valid_json "$OUT")
assert_eq "$VALID" "yes" "no test command → valid JSON"

print_results
