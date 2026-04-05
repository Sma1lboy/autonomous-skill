#!/usr/bin/env bash
# Tests for scripts/conductor-state.sh — state management for the multi-sprint conductor.
# Follows test_comms.sh framework pattern.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.sh"

# ── Minimal test framework ──────────────────────────────────────────────────
PASS=0; FAIL=0

ok()   { echo "  ok  $*"; ((PASS++)) || true; }
fail() { echo "  FAIL $*"; ((FAIL++)) || true; }

assert_eq() {
  [ "$1" = "$2" ] && ok "$3" || fail "$3 — got '$1', want '$2'"
}
assert_contains() {
  echo "$1" | grep -q "$2" && ok "$3" || fail "$3 — '$2' not in output"
}
assert_not_contains() {
  echo "$1" | grep -q "$2" && fail "$3 — '$2' found in output" || ok "$3"
}
assert_file_exists() {
  [ -f "$1" ] && ok "$2" || fail "$2 — file not found: $1"
}

# ── Temp dir management ─────────────────────────────────────────────────────
TMPDIRS=()
new_tmp() { local d; d=$(mktemp -d); TMPDIRS+=("$d"); echo "$d"; }
cleanup() { [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf "${TMPDIRS[@]}" || true; }
trap cleanup EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_conductor.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. State init creates valid JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. State initialization"
T=$(new_tmp)
SESSION_ID=$(bash "$CONDUCTOR" init "$T" "build feature X" 10)
assert_contains "$SESSION_ID" "conductor-" "init returns session ID"
assert_file_exists "$T/.autonomous/conductor-state.json" "state file created"

# Validate JSON structure
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
assert d['mission'] == 'build feature X'
assert d['phase'] == 'directed'
assert d['max_sprints'] == 10
assert d['max_directed_sprints'] == 7
assert d['sprints'] == []
assert d['consecutive_complete'] == 0
assert d['consecutive_zero_commits'] == 0
assert 'test_coverage' in d['exploration']
assert 'security' in d['exploration']
assert d['exploration']['test_coverage']['audited'] == False
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "init creates valid JSON with all required fields"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Read returns state
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Read state"
STATE=$(bash "$CONDUCTOR" read "$T")
assert_contains "$STATE" "build feature X" "read returns mission"
assert_contains "$STATE" "directed" "read returns phase"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Sprint-start adds sprint entry
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Sprint-start"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "build API" 5 > /dev/null
NUM=$(bash "$CONDUCTOR" sprint-start "$T" "scaffold Express project")
assert_eq "$NUM" "1" "first sprint is number 1"

# Verify sprint in state
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
s = d['sprints'][0]
assert s['number'] == 1
assert s['direction'] == 'scaffold Express project'
assert s['status'] == 'running'
assert s['commits'] == []
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "sprint entry has correct fields"

# Second sprint
NUM2=$(bash "$CONDUCTOR" sprint-start "$T" "add CRUD routes")
assert_eq "$NUM2" "2" "second sprint is number 2"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Sprint-end updates sprint status
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Sprint-end"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "build tests" 5 > /dev/null
bash "$CONDUCTOR" sprint-start "$T" "write unit tests" > /dev/null
PHASE=$(bash "$CONDUCTOR" sprint-end "$T" "complete" "Added 10 unit tests" '["abc1234"]' "false")

VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
s = d['sprints'][0]
assert s['status'] == 'complete'
assert s['summary'] == 'Added 10 unit tests'
assert s['commits'] == ['abc1234']
assert s['direction_complete'] == False
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "sprint-end updates all fields"
assert_eq "$PHASE" "directed" "still in directed phase after one sprint"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Phase transition: direction_complete + 2 consecutive
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Phase transition — direction_complete"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "build feature" 10 > /dev/null

# Sprint 1: complete with commits, direction_complete=true
bash "$CONDUCTOR" sprint-start "$T" "build core" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Built core" '["a1"]' "true" > /dev/null

# Sprint 2: complete with commits, direction_complete=true (2nd consecutive)
bash "$CONDUCTOR" sprint-start "$T" "add tests" > /dev/null
PHASE=$(bash "$CONDUCTOR" sprint-end "$T" "complete" "Tests done" '["b2"]' "true")
assert_eq "$PHASE" "exploring" "transitions to exploring after 2 consecutive complete"

# Verify transition reason
REASON=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d.get('phase_transition_reason', ''))
" 2>/dev/null)
assert_eq "$REASON" "direction_complete confirmed" "reason is direction_complete"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Phase transition: max_directed_sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Phase transition — max_directed_sprints"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "long mission" 4 > /dev/null
# max_directed = 70% of 4 = 2 (rounded down, min 1) => actually int(4*0.7) = 2

# Sprint 1
bash "$CONDUCTOR" sprint-start "$T" "step 1" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done step 1" '["c1"]' "false" > /dev/null

# Sprint 2 (should hit max_directed=2)
bash "$CONDUCTOR" sprint-start "$T" "step 2" > /dev/null
PHASE=$(bash "$CONDUCTOR" sprint-end "$T" "complete" "Done step 2" '["c2"]' "false")

# max_directed_sprints = int(4 * 0.7) = 2, sprint_num = 2, so 2 >= 2 → transition
assert_eq "$PHASE" "exploring" "transitions at max_directed_sprints"

REASON=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d.get('phase_transition_reason', ''))
")
assert_eq "$REASON" "max_directed_sprints reached" "reason is max_directed"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Phase transition: consecutive zero commits
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Phase transition — consecutive zero commits"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "explore stuff" 10 > /dev/null

# Sprint 1: has commits
bash "$CONDUCTOR" sprint-start "$T" "initial" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Built initial" '["d1"]' "false" > /dev/null

# Sprint 2: zero commits
bash "$CONDUCTOR" sprint-start "$T" "refine" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Nothing to do" '[]' "false" > /dev/null

# Sprint 3: zero commits (2nd consecutive)
bash "$CONDUCTOR" sprint-start "$T" "more refine" > /dev/null
PHASE=$(bash "$CONDUCTOR" sprint-end "$T" "complete" "Still nothing" '[]' "false")
assert_eq "$PHASE" "exploring" "transitions after 2 consecutive zero-commit sprints"

# ═══════════════════════════════════════════════════════════════════════════
# 8. NO transition with only 1 direction_complete signal
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. No premature transition"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "careful build" 10 > /dev/null

# Sprint 1: direction_complete=true
bash "$CONDUCTOR" sprint-start "$T" "build" > /dev/null
PHASE=$(bash "$CONDUCTOR" sprint-end "$T" "complete" "Built it" '["e1"]' "true")
assert_eq "$PHASE" "directed" "stays directed with only 1 complete signal"

# Sprint 2: direction_complete=false (resets consecutive counter)
bash "$CONDUCTOR" sprint-start "$T" "fix bug" > /dev/null
PHASE=$(bash "$CONDUCTOR" sprint-end "$T" "complete" "Fixed" '["e2"]' "false")
assert_eq "$PHASE" "directed" "stays directed when complete signal interrupted"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Exploration dimension selection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Exploration dimension pick"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "test" 10 > /dev/null

# First pick: should be test_coverage (first in priority, never audited)
DIM=$(bash "$CONDUCTOR" explore-pick "$T")
assert_eq "$DIM" "test_coverage" "picks first priority unaudited dimension"

# Mark test_coverage as audited
bash "$CONDUCTOR" explore-score "$T" "test_coverage" "7.5" > /dev/null

# Next pick: error_handling (second in priority)
DIM=$(bash "$CONDUCTOR" explore-pick "$T")
assert_eq "$DIM" "error_handling" "picks next unaudited dimension"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Exploration picks lowest scored when all audited
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Exploration picks lowest scored"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "test" 10 > /dev/null

# Audit all dimensions with various scores
for dim in test_coverage error_handling security code_quality documentation architecture performance dx; do
  bash "$CONDUCTOR" explore-score "$T" "$dim" "8" > /dev/null
done
# Set security low
bash "$CONDUCTOR" explore-score "$T" "security" "3" > /dev/null

DIM=$(bash "$CONDUCTOR" explore-pick "$T")
assert_eq "$DIM" "security" "picks lowest scored dimension"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Graceful handling of missing state
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Missing state handling"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
STATE=$(bash "$CONDUCTOR" read "$T" 2>/dev/null)
assert_eq "$STATE" "{}" "read returns empty on missing state"

PHASE=$(bash "$CONDUCTOR" phase "$T" 2>/dev/null)
assert_eq "$PHASE" "unknown" "phase returns unknown on missing state"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Graceful handling of corrupt JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Corrupt state handling"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"phase":' > "$T/.autonomous/conductor-state.json"
STATE=$(bash "$CONDUCTOR" read "$T" 2>/dev/null)
assert_eq "$STATE" "{}" "read returns empty on corrupt JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Multiple sprints accumulate correctly
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Sprint accumulation"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "big project" 10 > /dev/null

for i in 1 2 3; do
  bash "$CONDUCTOR" sprint-start "$T" "task $i" > /dev/null
  bash "$CONDUCTOR" sprint-end "$T" "complete" "Done task $i" "[\"commit$i\"]" "false" > /dev/null
done

COUNT=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(len(d['sprints']))
")
assert_eq "$COUNT" "3" "3 sprints accumulated"

# Verify each sprint has correct number
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
for i, s in enumerate(d['sprints']):
    assert s['number'] == i + 1, f'sprint {i} has wrong number'
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "sprint numbers sequential"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Atomic write verification
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Atomic write"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "atomic test" 5 > /dev/null

# Verify no .tmp files left behind
TMP_COUNT=$(find "$T/.autonomous" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMP_COUNT" "0" "no tmp files left after write"

# Write a few more times
bash "$CONDUCTOR" sprint-start "$T" "task 1" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "Done" '["x"]' "false" > /dev/null
TMP_COUNT=$(find "$T/.autonomous" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMP_COUNT" "0" "no tmp files after multiple operations"

# ═══════════════════════════════════════════════════════════════════════════
# 15. PID lock prevents concurrent access
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. PID lock"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "lock test" 5 > /dev/null

# Simulate a lock from another process (use current shell PID which is alive)
echo "$$" > "$T/.autonomous/conductor.lock"

# Try to init again — should fail
ERR=$(bash "$CONDUCTOR" init "$T" "second conductor" 5 2>&1 || true)
assert_contains "$ERR" "Another conductor is running" "lock blocks concurrent access"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Stale lock cleanup
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Stale lock cleanup"
T=$(new_tmp)
mkdir -p "$T/.autonomous"

# Write a lock with a dead PID
echo "999999" > "$T/.autonomous/conductor.lock"

# Init should succeed (stale lock cleaned up)
SESSION=$(bash "$CONDUCTOR" init "$T" "fresh start" 5 2>/dev/null)
assert_contains "$SESSION" "conductor-" "stale lock is cleaned up"

# ═══════════════════════════════════════════════════════════════════════════
# 17. explore-score updates dimension
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Explore score update"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "score test" 5 > /dev/null
RESULT=$(bash "$CONDUCTOR" explore-score "$T" "security" "6.5")
assert_eq "$RESULT" "ok" "explore-score returns ok"

VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
sec = d['exploration']['security']
assert sec['audited'] == True
assert sec['score'] == 6.5
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "dimension marked audited with correct score"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Phase command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Phase command"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "phase test" 5 > /dev/null
PHASE=$(bash "$CONDUCTOR" phase "$T")
assert_eq "$PHASE" "directed" "phase returns directed initially"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Sprint-end with default commits (empty)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Sprint-end default commits"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "defaults" 10 > /dev/null
bash "$CONDUCTOR" sprint-start "$T" "task" > /dev/null
PHASE=$(bash "$CONDUCTOR" sprint-end "$T" "blocked" "Couldn't proceed")
assert_eq "$PHASE" "directed" "blocked sprint keeps directed phase"

VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
s = d['sprints'][0]
assert s['status'] == 'blocked'
assert s['commits'] == []
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "blocked sprint recorded with empty commits"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Consecutive counters reset correctly
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Counter reset"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "counter test" 10 > /dev/null

# direction_complete=true
bash "$CONDUCTOR" sprint-start "$T" "s1" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "done" '["a"]' "true" > /dev/null

CONSEC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['consecutive_complete'])
")
assert_eq "$CONSEC" "1" "consecutive_complete is 1"

# direction_complete=false (resets)
bash "$CONDUCTOR" sprint-start "$T" "s2" > /dev/null
bash "$CONDUCTOR" sprint-end "$T" "complete" "partial" '["b"]' "false" > /dev/null

CONSEC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['consecutive_complete'])
")
assert_eq "$CONSEC" "0" "consecutive_complete reset to 0"

# ═══════════════════════════════════════════════════════════════════════════
# 21. Unknown command error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. Unknown command"
ERR=$(bash "$CONDUCTOR" foobar "$T" 2>&1 || true)
assert_contains "$ERR" "Unknown command" "unknown command errors cleanly"

# ═══════════════════════════════════════════════════════════════════════════
# 22. Init with different max_sprints calculates max_directed correctly
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. Max directed calculation"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "calc test" 20 > /dev/null
MAX_DIR=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d['max_directed_sprints'])
")
assert_eq "$MAX_DIR" "14" "70% of 20 = 14 max directed sprints"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
[ "$FAIL" -eq 0 ]
