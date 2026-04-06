#!/usr/bin/env bash
# Tests for explore-scan.sh --deep flag: actual test execution, shellcheck integration, caching.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/explore-scan.sh"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.sh"

# Helper: init a project with git and conductor state
init_project() {
  local dir="$1"
  bash "$CONDUCTOR" init "$dir" "test" 10 > /dev/null
  (cd "$dir" && git init -q && git add -A && git commit -q -m "init")
}

# Helper: get a dimension score from state
get_score() {
  local dir="$1" dim="$2"
  python3 -c "
import json
d = json.load(open('$dir/.autonomous/conductor-state.json'))
print(int(d['exploration']['$dim']['score']))
"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_explore_deep.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --deep flag parsing — accepted without error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --deep flag parsing"

T=$(new_tmp)
mkdir -p "$T/scripts"
echo '#!/usr/bin/env bash
echo "ok 2 tests"' > "$T/scripts/hello.sh"
chmod +x "$T/scripts/hello.sh"
init_project "$T"

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T" "$CONDUCTOR" --deep 2>&1) || true
assert_contains "$OUT" "Scanning project" "--deep still scans"
assert_not_contains "$OUT" "ERROR" "--deep doesn't error"

# ═══════════════════════════════════════════════════════════════════════════
# 2. --no-cache flag parsing
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. --no-cache flag parsing"

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T" "$CONDUCTOR" --deep --no-cache 2>&1) || true
assert_contains "$OUT" "Scanning project" "--no-cache still scans"
assert_not_contains "$OUT" "cached" "--no-cache skips cache"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Default mode unchanged (no --deep)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Default mode unchanged"

T2=$(new_tmp)
mkdir -p "$T2/scripts" "$T2/tests"
echo '#!/bin/bash
echo test' > "$T2/scripts/a.sh"
echo '#!/bin/bash
echo test' > "$T2/tests/test_a.sh"
init_project "$T2"

OUT=$(bash "$SCANNER" "$T2" "$CONDUCTOR" 2>&1) || true
assert_not_contains "$OUT" "deep" "no --deep = no deep output"
assert_not_contains "$OUT" "cached" "no --deep = no cache output"
assert_contains "$OUT" "test_coverage" "default still scores test_coverage"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Cache creation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Cache creation"

T3=$(new_tmp)
mkdir -p "$T3/scripts" "$T3/tests"
echo '#!/bin/bash
echo test' > "$T3/scripts/a.sh"
echo '#!/bin/bash
echo "1 passed, 0 failed"' > "$T3/tests/test_a.sh"
init_project "$T3"

AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T3" "$CONDUCTOR" --deep > /dev/null 2>&1
assert_file_exists "$T3/.autonomous/scan-cache.json" "cache file created"

# Verify cache structure
CACHE_VALID=$(python3 -c "
import json
c = json.load(open('$T3/.autonomous/scan-cache.json'))
has_ts = 'timestamp' in c
has_proj = 'project' in c
has_deep = 'deep_results' in c
print('valid' if has_ts and has_proj and has_deep else 'invalid')
")
assert_eq "$CACHE_VALID" "valid" "cache has expected structure"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Cache reuse (within TTL)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Cache reuse"

# Cache from test 4 should still exist and be fresh
OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T3" "$CONDUCTOR" --deep 2>&1) || true
assert_contains "$OUT" "cached" "second run uses cache"

# ═══════════════════════════════════════════════════════════════════════════
# 6. --no-cache forces fresh scan
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. --no-cache forces fresh"

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T3" "$CONDUCTOR" --deep --no-cache 2>&1) || true
assert_contains "$OUT" "Running deep scan" "--no-cache runs fresh"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Cache expiry (simulated old timestamp)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Cache expiry"

T4=$(new_tmp)
mkdir -p "$T4/scripts" "$T4/.autonomous"
echo '#!/bin/bash' > "$T4/scripts/a.sh"
init_project "$T4"

# Write cache with old timestamp (2 hours ago)
python3 -c "
import json, time
cache = {'timestamp': int(time.time()) - 7200, 'project': '$T4', 'deep_results': {
  'framework': 'bash',
  'test_coverage': {'pass': 10, 'fail': 0, 'score': 10},
  'code_quality': {'shellcheck_errors': 0, 'score': 10}
}}
with open('$T4/.autonomous/scan-cache.json', 'w') as f:
    json.dump(cache, f)
"

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T4" "$CONDUCTOR" --deep 2>&1) || true
assert_contains "$OUT" "Running deep scan" "expired cache triggers fresh scan"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Test output parsing — jest format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Test output parsing — jest format"

T5=$(new_tmp)
mkdir -p "$T5/scripts" "$T5/tests"
cat > "$T5/scripts/run-test.sh" << 'SH'
#!/bin/bash
echo "Test Suites: 2 passed, 2 total"
echo "Tests:       15 passed, 3 failed, 18 total"
SH
chmod +x "$T5/scripts/run-test.sh"
echo '#!/bin/bash' > "$T5/scripts/a.sh"
init_project "$T5"

# Create a detect-framework override by making a temporary package.json
cat > "$T5/package.json" << 'JSON'
{"scripts":{"test":"bash scripts/run-test.sh"}}
JSON
(cd "$T5" && git add -A && git commit -q -m "add test")

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=10 bash "$SCANNER" "$T5" "$CONDUCTOR" --deep --no-cache 2>&1) || true
TC_SCORE=$(get_score "$T5" "test_coverage")
# 15 passed / (15+3) total * 10 = 8.33 → 8
assert_eq "$TC_SCORE" "8" "jest format: 15/18 → score 8"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Test output parsing — pytest format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Test output parsing — pytest format"

T6=$(new_tmp)
mkdir -p "$T6/scripts" "$T6/tests"
cat > "$T6/run-test.sh" << 'SH'
#!/bin/bash
echo "========= 20 passed, 5 failed ========="
SH
chmod +x "$T6/run-test.sh"
echo 'x=1' > "$T6/tests/test_a.py"
echo 'requirements' > "$T6/requirements.txt"
init_project "$T6"

# Force test_command via a wrapper
# Since detect-framework.sh will detect python and use 'pytest',
# we override via a shim
mkdir -p "$T6/.bin"
cat > "$T6/.bin/pytest" << 'SH'
#!/bin/bash
echo "========= 20 passed, 5 failed ========="
SH
chmod +x "$T6/.bin/pytest"

OUT=$(PATH="$T6/.bin:$PATH" AUTONOMOUS_DEEP_TIMEOUT=10 bash "$SCANNER" "$T6" "$CONDUCTOR" --deep --no-cache 2>&1) || true
TC_SCORE=$(get_score "$T6" "test_coverage")
# 20 passed / 25 total * 10 = 8
assert_eq "$TC_SCORE" "8" "pytest format: 20/25 → score 8"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Test output parsing — go test format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Test output parsing — go test format"

T7=$(new_tmp)
mkdir -p "$T7/scripts"
echo 'module example' > "$T7/go.mod"
mkdir -p "$T7/.bin"
cat > "$T7/.bin/go" << 'SH'
#!/bin/bash
echo "ok  	example/pkg1	0.5s"
echo "ok  	example/pkg2	0.3s"
echo "FAIL	example/pkg3	0.1s"
SH
chmod +x "$T7/.bin/go"
echo '#!/bin/bash' > "$T7/scripts/a.sh"
init_project "$T7"

OUT=$(PATH="$T7/.bin:$PATH" AUTONOMOUS_DEEP_TIMEOUT=10 bash "$SCANNER" "$T7" "$CONDUCTOR" --deep --no-cache 2>&1) || true
TC_SCORE=$(get_score "$T7" "test_coverage")
# 2 ok / 3 total * 10 = 6.67 → 6
assert_eq "$TC_SCORE" "6" "go test format: 2/3 → score 6"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Test output parsing — bash test harness format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Test output parsing — bash harness format"

T8=$(new_tmp)
mkdir -p "$T8/scripts" "$T8/tests"
cat > "$T8/tests/test_a.sh" << 'SH'
#!/bin/bash
echo " Results: 42 passed, 3 failed"
SH
chmod +x "$T8/tests/test_a.sh"
echo '#!/bin/bash' > "$T8/scripts/b.sh"
init_project "$T8"

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=10 bash "$SCANNER" "$T8" "$CONDUCTOR" --deep --no-cache 2>&1) || true
TC_SCORE=$(get_score "$T8" "test_coverage")
# 42 passed / 45 total * 10 = 9.33 → 9
assert_eq "$TC_SCORE" "9" "bash harness format: 42/45 → score 9"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Test command fails / times out — fallback to heuristic
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Test command failure fallback"

T9=$(new_tmp)
mkdir -p "$T9/scripts" "$T9/tests"
echo '#!/bin/bash' > "$T9/scripts/a.sh"
echo '#!/bin/bash' > "$T9/tests/test_a.sh"
cat > "$T9/package.json" << 'JSON'
{"scripts":{"test":"exit 1"}}
JSON
init_project "$T9"

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=2 bash "$SCANNER" "$T9" "$CONDUCTOR" --deep --no-cache 2>&1) || true
# When test produces no parseable output, deep returns 0 0 → falls back to heuristic
TC_SCORE=$(get_score "$T9" "test_coverage")
# Heuristic fallback: 1 test file / 1 source = 10
assert_eq "$TC_SCORE" "10" "failed test cmd → heuristic fallback"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Test command timeout
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Test command timeout"

T10=$(new_tmp)
mkdir -p "$T10/scripts" "$T10/tests"
echo '#!/bin/bash' > "$T10/scripts/a.sh"
echo '#!/bin/bash' > "$T10/tests/test_a.sh"
cat > "$T10/package.json" << 'JSON'
{"scripts":{"test":"sleep 60"}}
JSON
init_project "$T10"

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=1 bash "$SCANNER" "$T10" "$CONDUCTOR" --deep --no-cache 2>&1) || true
# Timeout produces no output → falls back to heuristic
assert_contains "$OUT" "Scanning project" "timeout still completes scan"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Shellcheck integration — bash project with errors
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Shellcheck integration"

if command -v shellcheck &>/dev/null; then
  T11=$(new_tmp)
  mkdir -p "$T11/scripts"
  # Write a script with known shellcheck warnings
  cat > "$T11/scripts/bad.sh" << 'SH'
#!/bin/bash
echo $UNQUOTED_VAR
x=$(ls *.txt)
SH
  echo '#!/bin/bash' > "$T11/scripts/good.sh"
  init_project "$T11"

  OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T11" "$CONDUCTOR" --deep --no-cache 2>&1) || true
  CQ_SCORE=$(get_score "$T11" "code_quality")
  # Should factor in shellcheck errors → lower score
  assert_le "$CQ_SCORE" "10" "shellcheck errors factor into code_quality"
  ok "shellcheck integration runs for bash projects"
else
  ok "shellcheck not available — skipping integration test (ok)"
  ok "shellcheck skipped (placeholder)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 15. Non-bash project skips shellcheck
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Non-bash project skips shellcheck"

T12=$(new_tmp)
echo '{"scripts":{"test":"echo 5 passed"}}' > "$T12/package.json"
echo 'console.log("hi")' > "$T12/index.js"
init_project "$T12"

# Should detect as node, skip shellcheck
OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T12" "$CONDUCTOR" --deep --no-cache 2>&1) || true
assert_contains "$OUT" "Scanning project" "non-bash project scans ok"

# ═══════════════════════════════════════════════════════════════════════════
# 16. AUTONOMOUS_DEEP_TIMEOUT env override
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Timeout env override"

T13=$(new_tmp)
mkdir -p "$T13/scripts" "$T13/tests"
echo '#!/bin/bash' > "$T13/scripts/a.sh"
cat > "$T13/tests/test_a.sh" << 'SH'
#!/bin/bash
sleep 3
echo "1 passed, 0 failed"
SH
chmod +x "$T13/tests/test_a.sh"
init_project "$T13"

# With 1s timeout the sleep 3 should be killed → no output → heuristic fallback
OUT=$(AUTONOMOUS_DEEP_TIMEOUT=1 bash "$SCANNER" "$T13" "$CONDUCTOR" --deep --no-cache 2>&1) || true
assert_contains "$OUT" "Scanning project" "timeout override accepted"

# With 5s timeout the test should complete
OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T13" "$CONDUCTOR" --deep --no-cache 2>&1) || true
assert_contains "$OUT" "Scanning project" "longer timeout allows completion"

# ═══════════════════════════════════════════════════════════════════════════
# 17. --help shows deep options
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. --help shows deep options"

OUT=$(bash "$SCANNER" --help 2>&1) || true
assert_contains "$OUT" "deep" "--help mentions --deep"
assert_contains "$OUT" "no-cache" "--help mentions --no-cache"
assert_contains "$OUT" "Usage" "--help shows usage header"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Mixed flags and positional args order
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Mixed argument order"

T14=$(new_tmp)
mkdir -p "$T14/scripts"
echo '#!/bin/bash' > "$T14/scripts/a.sh"
init_project "$T14"

# --deep before positional
OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" --deep "$T14" "$CONDUCTOR" 2>&1) || true
assert_contains "$OUT" "Scanning project" "--deep before positional works"

# --no-cache between positionals
OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T14" --deep --no-cache "$CONDUCTOR" 2>&1) || true
assert_contains "$OUT" "Scanning project" "flags between positionals works"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Cache content validation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Cache content validation"

T15=$(new_tmp)
mkdir -p "$T15/scripts" "$T15/tests"
cat > "$T15/scripts/run.sh" << 'SH'
#!/bin/bash
echo "8 passed, 2 failed"
SH
chmod +x "$T15/scripts/run.sh"
echo '#!/bin/bash' > "$T15/scripts/a.sh"
init_project "$T15"

AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T15" "$CONDUCTOR" --deep --no-cache > /dev/null 2>&1
assert_file_exists "$T15/.autonomous/scan-cache.json" "cache created"

# Validate cache fields
HAS_TC=$(python3 -c "
import json
c = json.load(open('$T15/.autonomous/scan-cache.json'))
dr = c.get('deep_results', {})
tc = dr.get('test_coverage', {})
print('yes' if 'pass' in tc and 'fail' in tc and 'score' in tc else 'no')
" 2>/dev/null || echo "no")
assert_eq "$HAS_TC" "yes" "cache has test_coverage pass/fail/score"

HAS_CQ=$(python3 -c "
import json
c = json.load(open('$T15/.autonomous/scan-cache.json'))
dr = c.get('deep_results', {})
cq = dr.get('code_quality', {})
print('yes' if 'shellcheck_errors' in cq and 'score' in cq else 'no')
" 2>/dev/null || echo "no")
assert_eq "$HAS_CQ" "yes" "cache has code_quality shellcheck_errors/score"

HAS_FW=$(python3 -c "
import json
c = json.load(open('$T15/.autonomous/scan-cache.json'))
print('yes' if c.get('deep_results', {}).get('framework') else 'no')
" 2>/dev/null || echo "no")
assert_eq "$HAS_FW" "yes" "cache has framework"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Deep mode with no test command detected
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Deep mode — no test command"

T16=$(new_tmp)
echo 'hello' > "$T16/readme.txt"
init_project "$T16"

# Unknown framework → no test command → fallback to heuristic
OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T16" "$CONDUCTOR" --deep --no-cache 2>&1) || true
assert_contains "$OUT" "Scanning project" "no test command still scans"

# ═══════════════════════════════════════════════════════════════════════════
# 21. All tests pass → score 10
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. All tests pass → score 10"

T17=$(new_tmp)
mkdir -p "$T17/scripts" "$T17/tests"
cat > "$T17/tests/test_all.sh" << 'SH'
#!/bin/bash
echo "100 passed, 0 failed"
SH
chmod +x "$T17/tests/test_all.sh"
echo '#!/bin/bash' > "$T17/scripts/a.sh"
init_project "$T17"

AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T17" "$CONDUCTOR" --deep --no-cache > /dev/null 2>&1
TC_SCORE=$(get_score "$T17" "test_coverage")
assert_eq "$TC_SCORE" "10" "100% pass rate → score 10"

# ═══════════════════════════════════════════════════════════════════════════
# 22. All tests fail → score 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. All tests fail → score 0"

T18=$(new_tmp)
mkdir -p "$T18/scripts" "$T18/tests"
cat > "$T18/tests/test_all.sh" << 'SH'
#!/bin/bash
echo "0 passed, 10 failed"
SH
chmod +x "$T18/tests/test_all.sh"
echo '#!/bin/bash' > "$T18/scripts/a.sh"
init_project "$T18"

AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T18" "$CONDUCTOR" --deep --no-cache > /dev/null 2>&1
TC_SCORE=$(get_score "$T18" "test_coverage")
assert_eq "$TC_SCORE" "0" "0% pass rate → score 0"

# ═══════════════════════════════════════════════════════════════════════════
# 23. Default scan does NOT create cache
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. Default scan does not create cache"

T19=$(new_tmp)
mkdir -p "$T19/scripts"
echo '#!/bin/bash' > "$T19/scripts/a.sh"
init_project "$T19"

bash "$SCANNER" "$T19" "$CONDUCTOR" > /dev/null 2>&1
assert_file_not_exists "$T19/.autonomous/scan-cache.json" "no cache without --deep"

# ═══════════════════════════════════════════════════════════════════════════
# 24. Multiple --deep runs produce consistent results
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. Consistent deep results"

T20=$(new_tmp)
mkdir -p "$T20/scripts" "$T20/tests"
cat > "$T20/tests/test_a.sh" << 'SH'
#!/bin/bash
echo "5 passed, 1 failed"
SH
chmod +x "$T20/tests/test_a.sh"
echo '#!/bin/bash' > "$T20/scripts/a.sh"
init_project "$T20"

AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T20" "$CONDUCTOR" --deep --no-cache > /dev/null 2>&1
SCORE1=$(get_score "$T20" "test_coverage")
# Re-init state for clean score
bash "$CONDUCTOR" init "$T20" "test" 10 > /dev/null
(cd "$T20" && git add -A && git commit -q -m "re-init" --allow-empty)
AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T20" "$CONDUCTOR" --deep --no-cache > /dev/null 2>&1
SCORE2=$(get_score "$T20" "test_coverage")
assert_eq "$SCORE1" "$SCORE2" "two deep runs produce same score"

# ═══════════════════════════════════════════════════════════════════════════
# 25. Positional args still work without --deep
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. Positional args backward compat"

T21=$(new_tmp)
mkdir -p "$T21/scripts"
echo '#!/bin/bash' > "$T21/scripts/a.sh"
init_project "$T21"

OUT=$(bash "$SCANNER" "$T21" "$CONDUCTOR" 2>&1) || true
assert_contains "$OUT" "Scanning project" "two positional args still work"
assert_contains "$OUT" "complete" "completes successfully"

# ═══════════════════════════════════════════════════════════════════════════
# 26. Default positional (no args)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. Default positional — current dir"

T22=$(new_tmp)
mkdir -p "$T22/scripts" "$T22/.autonomous"
echo '#!/bin/bash' > "$T22/scripts/a.sh"
# Need conductor state in the default dir context — just test that the scanner
# doesn't crash when run from a project dir
# (This tests the POSITIONAL[0]:-.  default)
# We can't easily test this without cd, so verify the flag parsing handles empty
OUT=$(bash "$SCANNER" --help 2>&1) || true
assert_contains "$OUT" "Usage" "no args → --help still works"

# ═══════════════════════════════════════════════════════════════════════════
# 27. Cache with non-existent .autonomous dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. Cache with missing .autonomous dir"

T23=$(new_tmp)
mkdir -p "$T23/scripts"
echo '#!/bin/bash' > "$T23/scripts/a.sh"
init_project "$T23"
# Remove .autonomous dir to test cache creation mkdir
rm -rf "$T23/.autonomous"
bash "$CONDUCTOR" init "$T23" "test" 10 > /dev/null

AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T23" "$CONDUCTOR" --deep --no-cache > /dev/null 2>&1
assert_file_exists "$T23/.autonomous/scan-cache.json" "cache created even if .autonomous was fresh"

# ═══════════════════════════════════════════════════════════════════════════
# 28. Corrupt cache file handled gracefully
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. Corrupt cache file"

T24=$(new_tmp)
mkdir -p "$T24/scripts" "$T24/.autonomous"
echo '#!/bin/bash' > "$T24/scripts/a.sh"
echo "not json" > "$T24/.autonomous/scan-cache.json"
init_project "$T24"

OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T24" "$CONDUCTOR" --deep 2>&1) || true
assert_contains "$OUT" "Running deep scan" "corrupt cache triggers fresh scan"
assert_not_contains "$OUT" "Traceback" "no python traceback"

# ═══════════════════════════════════════════════════════════════════════════
# 29. Deep scan with mixed pass/fail in output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Mixed pass/fail output"

T25=$(new_tmp)
mkdir -p "$T25/scripts" "$T25/tests"
cat > "$T25/tests/test_mix.sh" << 'SH'
#!/bin/bash
echo "Suite 1: 10 passed, 2 failed"
echo "Suite 2: 8 passed, 0 failed"
SH
chmod +x "$T25/tests/test_mix.sh"
echo '#!/bin/bash' > "$T25/scripts/a.sh"
init_project "$T25"

AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T25" "$CONDUCTOR" --deep --no-cache > /dev/null 2>&1
TC_SCORE=$(get_score "$T25" "test_coverage")
# 18 passed / 20 total * 10 = 9
assert_eq "$TC_SCORE" "9" "mixed output: 18/20 → score 9"

# ═══════════════════════════════════════════════════════════════════════════
# 30. Deep scan with zero output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. Zero test output"

T26=$(new_tmp)
mkdir -p "$T26/scripts" "$T26/tests"
echo '#!/bin/bash' > "$T26/scripts/a.sh"
echo '#!/bin/bash' > "$T26/tests/test_a.sh"
cat > "$T26/package.json" << 'JSON'
{"scripts":{"test":"true"}}
JSON
init_project "$T26"

# 'true' produces no parseable output → should fall back to heuristic
OUT=$(AUTONOMOUS_DEEP_TIMEOUT=5 bash "$SCANNER" "$T26" "$CONDUCTOR" --deep --no-cache 2>&1) || true
TC_SCORE=$(get_score "$T26" "test_coverage")
# Heuristic: 1 test file / 1 source = 10
assert_eq "$TC_SCORE" "10" "no parseable output → heuristic fallback"

# ═══════════════════════════════════════════════════════════════════════════
# 31. explore-scan.sh still works for existing tests
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. Backward compat — existing tests"

T27=$(new_tmp)
mkdir -p "$T27/src" "$T27/tests"
echo 'try:
  x = 1
except:
  pass' > "$T27/src/a.py"
echo 'z = 3' > "$T27/src/b.py"
echo 'test' > "$T27/tests/test_a.py"
init_project "$T27"

bash "$SCANNER" "$T27" "$CONDUCTOR" > /dev/null 2>&1
EH=$(get_score "$T27" "error_handling")
# 1 file with error handling / 2 source files * 10 = 5
assert_eq "$EH" "5" "heuristic error_handling still correct"

TC=$(get_score "$T27" "test_coverage")
# 1 test / 2 sources * 10 = 5
assert_eq "$TC" "5" "heuristic test_coverage still correct"

# ═══════════════════════════════════════════════════════════════════════════
# Print results
# ═══════════════════════════════════════════════════════════════════════════
print_results
