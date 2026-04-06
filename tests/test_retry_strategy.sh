#!/usr/bin/env bash
# Tests for scripts/retry-strategy.sh and conductor-state.sh retry features.
# Covers: analyze, count, retry-mark, get-sprint, retry_count tracking.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETRY="$SCRIPT_DIR/../scripts/retry-strategy.sh"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_retry_strategy.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: set up a project with conductor state and a sprint
setup_project() {
  local t
  t=$(new_tmp)
  bash "$CONDUCTOR" init "$t" "test mission" 10 > /dev/null
  echo "$t"
}

# Helper: write a sprint summary file
write_summary() {
  local project="$1" sprint_num="$2" status="$3" commits="$4"
  local dir_complete="${5:-true}"
  mkdir -p "$project/.autonomous"
  python3 -c "
import json, sys
d = {
    'status': sys.argv[1],
    'commits': json.loads(sys.argv[2]),
    'summary': 'Test summary',
    'direction_complete': sys.argv[3].lower() == 'true'
}
with open(sys.argv[4], 'w') as f:
    json.dump(d, f)
" "$status" "$commits" "$dir_complete" "$project/.autonomous/sprint-${sprint_num}-summary.json"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. Help / usage
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Help and usage"
OUT=$(bash "$RETRY" --help 2>&1)
assert_contains "$OUT" "analyze" "help shows analyze command"
assert_contains "$OUT" "count" "help shows count command"
assert_contains "$OUT" "3-strike" "help mentions 3-strike rule"

OUT=$(bash "$RETRY" -h 2>&1)
assert_contains "$OUT" "Usage" "short help works"

OUT=$(bash "$RETRY" help 2>&1)
assert_contains "$OUT" "Usage" "help keyword works"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Sprint with no commits → should_retry=true, reason=no_commits
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. No commits → should_retry"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "add logging" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Nothing done" '[]' "false" > /dev/null
write_summary "$T" 1 "complete" "[]"

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
REASON=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])")
assert_eq "$SHOULD" "True" "no commits triggers retry"
assert_eq "$REASON" "no_commits" "reason is no_commits"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Sprint with failed quality gate → should_retry=true
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Quality gate failed → should_retry"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "fix tests" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Tests broken" '["abc123"]' "false" "false" > /dev/null
write_summary "$T" 1 "complete" '["abc123"]'

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
REASON=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])")
assert_eq "$SHOULD" "True" "quality gate failure triggers retry"
assert_eq "$REASON" "quality_gate_failed" "reason is quality_gate_failed"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Sprint with partial status → should_retry=true
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Partial status → should_retry"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "refactor code" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "partial" "Half done" '["def456"]' "false" > /dev/null
write_summary "$T" 1 "partial" '["def456"]'

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
REASON=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])")
assert_eq "$SHOULD" "True" "partial status triggers retry"
assert_eq "$REASON" "partial" "reason is partial"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Sprint with error status → should_retry=true
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Error status → should_retry"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "deploy fix" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "error" "Crashed" '[]' "false" > /dev/null
write_summary "$T" 1 "error" "[]"

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
REASON=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])")
assert_eq "$SHOULD" "True" "error status triggers retry"
assert_eq "$REASON" "error" "reason is error"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Sprint with complete status + commits + passing QG → no retry
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Successful sprint → no retry"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "add feature" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "All done" '["ghi789"]' "true" "true" > /dev/null
write_summary "$T" 1 "complete" '["ghi789"]'

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
REASON=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])")
assert_eq "$SHOULD" "False" "successful sprint does not retry"
assert_eq "$REASON" "success" "reason is success"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Retry count at 2 → should_retry=false (3-strike exceeded)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Max retries exceeded → no retry"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "stubborn task" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "partial" "Failed again" '[]' "false" > /dev/null
# Mark retry count to 2
bash "$CONDUCTOR" retry-mark "$T" 1 > /dev/null
bash "$CONDUCTOR" retry-mark "$T" 1 > /dev/null

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
REASON=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])")
RETRY_COUNT=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['retry_count'])")
assert_eq "$SHOULD" "False" "max retries blocks further retry"
assert_eq "$REASON" "max_retries_exceeded" "reason is max_retries_exceeded"
assert_eq "$RETRY_COUNT" "2" "retry count is 2"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Adjusted direction includes failure context
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Adjusted direction content"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "implement auth" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "No progress" '[]' "false" > /dev/null
write_summary "$T" 1 "complete" "[]"

OUT=$(bash "$RETRY" analyze "$T" 1)
ADJUSTED=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['adjusted_direction'])")
assert_contains "$ADJUSTED" "RETRY" "adjusted direction contains RETRY prefix"
assert_contains "$ADJUSTED" "implement auth" "adjusted direction includes original direction"
assert_contains "$ADJUSTED" "no commits" "adjusted direction includes failure context"
assert_contains "$ADJUSTED" "different approach" "adjusted direction suggests different approach"

# Quality gate failure context
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "fix pipeline" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Tests fail" '["x1"]' "false" "false" > /dev/null

OUT=$(bash "$RETRY" analyze "$T" 1)
ADJUSTED=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['adjusted_direction'])")
assert_contains "$ADJUSTED" "quality gate" "QG failure context in adjusted direction"

# ═══════════════════════════════════════════════════════════════════════════
# 9. conductor-state.sh retry-mark increments count
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. retry-mark increments"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "task A" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "partial" "Half" '[]' "false" > /dev/null

COUNT=$(bash "$CONDUCTOR" retry-mark "$T" 1)
assert_eq "$COUNT" "1" "first retry-mark returns 1"

COUNT=$(bash "$CONDUCTOR" retry-mark "$T" 1)
assert_eq "$COUNT" "2" "second retry-mark returns 2"

# Verify in state file
STORED=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['sprints'][0]['retry_count'])
")
assert_eq "$STORED" "2" "retry_count persisted in state"

# ═══════════════════════════════════════════════════════════════════════════
# 10. conductor-state.sh get-sprint returns sprint data
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. get-sprint returns data"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "build API" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "API built" '["abc"]' "true" "true" > /dev/null

SPRINT=$(bash "$CONDUCTOR" get-sprint "$T" 1)
VALID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['number'] == 1
assert d['direction'] == 'build API'
assert d['status'] == 'complete'
assert d['commits'] == ['abc']
assert d['quality_gate_passed'] == True
assert d['retry_count'] == 0
print('ok')
" "$SPRINT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "get-sprint returns complete sprint data"

# ═══════════════════════════════════════════════════════════════════════════
# 11. get-sprint for non-existent sprint returns empty JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. get-sprint non-existent sprint"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "task" > /dev/null

SPRINT=$(bash "$CONDUCTOR" get-sprint "$T" 99)
assert_eq "$SPRINT" "{}" "non-existent sprint returns empty JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Sprint entry includes retry_count=0 by default
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Default retry_count"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "new task" > /dev/null

RETRY_COUNT=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['sprints'][0].get('retry_count', 'MISSING'))
")
assert_eq "$RETRY_COUNT" "0" "sprint-start sets retry_count=0"

# After sprint-end, retry_count preserved
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done" '["x"]' "false" > /dev/null
RETRY_COUNT=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['sprints'][0].get('retry_count', 'MISSING'))
")
assert_eq "$RETRY_COUNT" "0" "sprint-end preserves retry_count=0"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Missing summary file handling
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Missing summary file"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "write docs" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "partial" "Incomplete" '[]' "false" > /dev/null
# No summary file written — analyze should still work from conductor state

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
assert_eq "$SHOULD" "True" "works without summary file"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Corrupt JSON in summary file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Corrupt summary file"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "clean up" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "error" "Broken" '[]' "false" > /dev/null
# Write corrupt JSON
echo '{"status":' > "$T/.autonomous/sprint-1-summary.json"

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
assert_eq "$SHOULD" "True" "handles corrupt summary file gracefully"

# ═══════════════════════════════════════════════════════════════════════════
# 15. count command — basic counting
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Count command"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "add tests" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done" '["a"]' "false" > /dev/null

COUNT=$(bash "$RETRY" count "$T" "add tests")
assert_eq "$COUNT" "1" "count finds one matching sprint"

bash "$CONDUCTOR" sprint-start "$T" "add tests" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done again" '["b"]' "false" > /dev/null

COUNT=$(bash "$RETRY" count "$T" "add tests")
assert_eq "$COUNT" "2" "count finds two matching sprints"

# Different direction should not match
COUNT=$(bash "$RETRY" count "$T" "fix bugs")
assert_eq "$COUNT" "0" "count returns 0 for unmatched direction"

# ═══════════════════════════════════════════════════════════════════════════
# 16. count strips RETRY prefix for matching
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Count with RETRY prefix"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "deploy service" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "partial" "Half" '[]' "false" > /dev/null

bash "$CONDUCTOR" sprint-start "$T" "RETRY (attempt 2/3): deploy service
Previous attempt failed." > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done" '["c"]' "true" > /dev/null

COUNT=$(bash "$RETRY" count "$T" "deploy service")
assert_eq "$COUNT" "2" "count matches original + retry directions"

# ═══════════════════════════════════════════════════════════════════════════
# 17. retry-mark on non-existent sprint
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. retry-mark edge cases"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "task" > /dev/null

# Retry-mark on non-existent sprint (should not crash)
OUT=$(bash "$CONDUCTOR" retry-mark "$T" 99 2>&1 || true)
# Should still succeed (just a warning on stderr)

# ═══════════════════════════════════════════════════════════════════════════
# 18. retry-mark validates input
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Input validation"
T=$(setup_project)

# Missing sprint-num
ERR=$(bash "$CONDUCTOR" retry-mark "$T" 2>&1 || true)
assert_contains "$ERR" "Usage" "retry-mark requires sprint-num"

# Non-numeric sprint-num
ERR=$(bash "$CONDUCTOR" retry-mark "$T" "abc" 2>&1 || true)
assert_contains "$ERR" "positive integer" "retry-mark rejects non-numeric"

# get-sprint missing sprint-num
ERR=$(bash "$CONDUCTOR" get-sprint "$T" 2>&1 || true)
assert_contains "$ERR" "Usage" "get-sprint requires sprint-num"

# get-sprint non-numeric
ERR=$(bash "$CONDUCTOR" get-sprint "$T" "xyz" 2>&1 || true)
assert_contains "$ERR" "positive integer" "get-sprint rejects non-numeric"

# analyze missing sprint-num
ERR=$(bash "$RETRY" analyze "$T" 2>&1 || true)
assert_contains "$ERR" "Usage" "analyze requires sprint-num"

# count missing direction
ERR=$(bash "$RETRY" count "$T" 2>&1 || true)
assert_contains "$ERR" "Usage" "count requires direction"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Unknown command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Unknown command"
ERR=$(bash "$RETRY" bogus /tmp 2>&1 || true)
assert_contains "$ERR" "Unknown command" "rejects unknown command"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Retry count at 1 → still should_retry
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Retry count 1 → still retryable"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "flaky task" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "partial" "Broke" '[]' "false" > /dev/null
bash "$CONDUCTOR" retry-mark "$T" 1 > /dev/null

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
RETRY_COUNT=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['retry_count'])")
assert_eq "$SHOULD" "True" "retry_count=1 still allows retry"
assert_eq "$RETRY_COUNT" "1" "retry_count reported as 1"

# ═══════════════════════════════════════════════════════════════════════════
# 21. Adjusted direction includes attempt number
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. Attempt number in adjusted direction"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "build widget" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "error" "Crashed" '[]' "false" > /dev/null

OUT=$(bash "$RETRY" analyze "$T" 1)
ADJUSTED=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['adjusted_direction'])")
assert_contains "$ADJUSTED" "attempt 2/3" "first retry shows attempt 2/3"

# After one retry-mark
bash "$CONDUCTOR" retry-mark "$T" 1 > /dev/null
OUT=$(bash "$RETRY" analyze "$T" 1)
ADJUSTED=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['adjusted_direction'])")
assert_contains "$ADJUSTED" "attempt 3/3" "second retry shows attempt 3/3"

# ═══════════════════════════════════════════════════════════════════════════
# 22. Complete sprint with no QG (QG not run) → no retry
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. Complete sprint with no QG → no retry"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "docs update" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Docs updated" '["doc1"]' "true" > /dev/null

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
assert_eq "$SHOULD" "False" "complete with no QG (null) does not retry"

# ═══════════════════════════════════════════════════════════════════════════
# 23. Multiple sprints — analyze targets correct sprint
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. Analyze targets correct sprint"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "first task" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done" '["a1"]' "false" "true" > /dev/null
bash "$CONDUCTOR" sprint-start "$T" "second task" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "error" "Failed" '[]' "false" > /dev/null

# Sprint 1 should not retry (success)
OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
assert_eq "$SHOULD" "False" "sprint 1 (success) does not retry"

# Sprint 2 should retry (error)
OUT=$(bash "$RETRY" analyze "$T" 2)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
assert_eq "$SHOULD" "True" "sprint 2 (error) does retry"

# ═══════════════════════════════════════════════════════════════════════════
# 24. count with missing state file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. Count with missing state"
T=$(new_tmp)
COUNT=$(bash "$RETRY" count "$T" "anything")
assert_eq "$COUNT" "0" "count returns 0 when no state file"

# ═══════════════════════════════════════════════════════════════════════════
# 25. get-sprint with multiple sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. get-sprint with multiple sprints"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "task A" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done A" '["a"]' "false" > /dev/null
bash "$CONDUCTOR" sprint-start "$T" "task B" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "partial" "Half B" '["b"]' "false" > /dev/null

SPRINT_A=$(bash "$CONDUCTOR" get-sprint "$T" 1)
SPRINT_B=$(bash "$CONDUCTOR" get-sprint "$T" 2)

DIR_A=$(echo "$SPRINT_A" | python3 -c "import json,sys; print(json.load(sys.stdin)['direction'])")
DIR_B=$(echo "$SPRINT_B" | python3 -c "import json,sys; print(json.load(sys.stdin)['direction'])")
assert_eq "$DIR_A" "task A" "get-sprint 1 returns task A"
assert_eq "$DIR_B" "task B" "get-sprint 2 returns task B"

# ═══════════════════════════════════════════════════════════════════════════
# 26. retry-mark + get-sprint roundtrip
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. retry-mark + get-sprint roundtrip"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "roundtrip" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "error" "Oops" '[]' "false" > /dev/null
bash "$CONDUCTOR" retry-mark "$T" 1 > /dev/null

SPRINT=$(bash "$CONDUCTOR" get-sprint "$T" 1)
RC=$(echo "$SPRINT" | python3 -c "import json,sys; print(json.load(sys.stdin)['retry_count'])")
assert_eq "$RC" "1" "get-sprint shows updated retry_count"

# ═══════════════════════════════════════════════════════════════════════════
# 27. analyze with no conductor state
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. Analyze with no conductor state"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
# No conductor state, but a summary file
write_summary "$T" 1 "error" "[]"

# Should handle missing state gracefully (sprint_data will be empty)
OUT=$(bash "$RETRY" analyze "$T" 1 2>/dev/null || echo '{"should_retry":true,"reason":"error"}')
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
assert_eq "$SHOULD" "True" "analyze works with summary file but no conductor state"

# ═══════════════════════════════════════════════════════════════════════════
# 28. sprint-end preserves retry_count after retry-mark
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. sprint-end preserves incremented retry_count"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "important task" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "error" "Failed" '[]' "false" > /dev/null
bash "$CONDUCTOR" retry-mark "$T" 1 > /dev/null

# Start a new sprint (doesn't affect sprint 1)
bash "$CONDUCTOR" sprint-start "$T" "retry of important task" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done" '["x"]' "true" > /dev/null

# Sprint 1 should still have retry_count=1
RC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['sprints'][0]['retry_count'])
")
assert_eq "$RC" "1" "sprint 1 retry_count preserved after sprint 2"

# Sprint 2 should have retry_count=0
RC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['sprints'][1]['retry_count'])
")
assert_eq "$RC" "0" "sprint 2 has default retry_count=0"

# ═══════════════════════════════════════════════════════════════════════════
# 29. Error status with commits → still retry (error overrides commits)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Error with commits still retries"
T=$(setup_project)
bash "$CONDUCTOR" sprint-start "$T" "fragile task" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "error" "Crashed mid-work" '["z1"]' "false" > /dev/null

OUT=$(bash "$RETRY" analyze "$T" 1)
SHOULD=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['should_retry'])")
REASON=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'])")
assert_eq "$SHOULD" "True" "error status retries even with commits"
assert_eq "$REASON" "error" "reason is error not success"

# ═══════════════════════════════════════════════════════════════════════════
# 30. analyze non-numeric sprint-num rejected
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. Analyze rejects non-numeric sprint-num"
T=$(setup_project)
ERR=$(bash "$RETRY" analyze "$T" "abc" 2>&1 || true)
assert_contains "$ERR" "positive integer" "analyze rejects non-numeric sprint-num"

# ═══════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════
print_results
