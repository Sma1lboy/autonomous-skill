#!/usr/bin/env bash
# Tests for scripts/conductor-state.sh — state management for the multi-sprint conductor.
# Follows test_comms.sh framework pattern.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.sh"

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
SESSION_ID=$(bash "$CONDUCTOR" init "$T" "build feature X" 5)
assert_contains "$SESSION_ID" "conductor-" "init returns session ID"
assert_file_exists "$T/.autonomous/conductor-state.json" "state file created"

# Validate JSON structure
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
assert d['mission'] == 'build feature X'
assert d['phase'] == 'directed'
assert d['max_sprints'] == 5
assert d['max_directed_sprints'] == 3
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
bash "$CONDUCTOR" init "$T" "defaults" 5 > /dev/null
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

# ═══════════════════════════════════════════════════════════════════════════
# 23. explore-scan.sh scores all 8 dimensions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. Explore scan — scores all dimensions"
SCANNER="$SCRIPT_DIR/../scripts/explore-scan.sh"
T=$(new_tmp)

# Initialize conductor state
bash "$CONDUCTOR" init "$T" "scan test" 10 > /dev/null

# Create a minimal project structure
mkdir -p "$T/src" "$T/tests"
echo 'def hello(): pass' > "$T/src/app.py"
echo 'def test_hello(): pass' > "$T/tests/test_app.py"
echo '# TODO: fix this' > "$T/src/util.py"
cat > "$T/src/main.sh" << 'SH'
#!/usr/bin/env bash
echo "Usage: main.sh [options]"
if [ "$1" = "--help" ]; then echo "help"; fi
SH
echo '# My Project' > "$T/README.md"
# Initialize a git repo so README freshness check works
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

OUTPUT=$(bash "$SCANNER" "$T" "$CONDUCTOR" 2>&1)
assert_contains "$OUTPUT" "test_coverage:" "scan reports test_coverage"
assert_contains "$OUTPUT" "error_handling:" "scan reports error_handling"
assert_contains "$OUTPUT" "security:" "scan reports security"
assert_contains "$OUTPUT" "code_quality:" "scan reports code_quality"
assert_contains "$OUTPUT" "documentation:" "scan reports documentation"
assert_contains "$OUTPUT" "architecture:" "scan reports architecture"
assert_contains "$OUTPUT" "performance:" "scan reports performance"
assert_contains "$OUTPUT" "dx:" "scan reports dx"
assert_contains "$OUTPUT" "Exploration scan complete" "scan reports completion"

# Verify all dimensions are now audited in state
AUDITED=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
exp = d['exploration']
all_audited = all(exp[dim]['audited'] for dim in exp)
all_scored = all(isinstance(exp[dim]['score'], (int, float)) for dim in exp)
print('ok' if all_audited and all_scored else 'fail')
" 2>/dev/null || echo "fail")
assert_eq "$AUDITED" "ok" "all dimensions audited with numeric scores"

# ═══════════════════════════════════════════════════════════════════════════
# 24. explore-scan.sh test_coverage scoring
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. Explore scan — test_coverage scoring"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "coverage test" 10 > /dev/null

# Project with 1 test file and 4 source files → ratio 0.25 → score 2
mkdir -p "$T/src" "$T/tests"
echo 'x=1' > "$T/src/a.py"
echo 'x=2' > "$T/src/b.py"
echo 'x=3' > "$T/src/c.py"
echo 'x=4' > "$T/src/d.py"
echo 'test=1' > "$T/tests/test_a.py"
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
TC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(int(d['exploration']['test_coverage']['score']))
")
assert_eq "$TC" "2" "1 test / 4 src = score 2"

# ═══════════════════════════════════════════════════════════════════════════
# 25. explore-scan.sh security scoring (no issues = 10)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. Explore scan — security clean project"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "sec test" 10 > /dev/null

# Clean project, no security issues
mkdir -p "$T/src"
echo 'print("hello")' > "$T/src/app.py"
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
SEC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(int(d['exploration']['security']['score']))
")
assert_eq "$SEC" "10" "clean project gets security score 10"

# ═══════════════════════════════════════════════════════════════════════════
# 26. explore-scan.sh security scoring (issues lower score)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. Explore scan — security issues"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "sec issues test" 10 > /dev/null

mkdir -p "$T/src"
echo '# TODO: security fix needed' > "$T/src/app.py"
echo 'password = "hunter2"' > "$T/src/config.py"
echo 'DB_PASS=secret' > "$T/.env"
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
SEC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(int(d['exploration']['security']['score']))
")
# 3 issues * 2 = 6, 10 - 6 = 4
assert_eq "$SEC" "4" "3 security issues → score 4"

# ═══════════════════════════════════════════════════════════════════════════
# 27. explore-scan.sh code_quality (TODOs lower score)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. Explore scan — code quality with TODOs"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "quality test" 10 > /dev/null

mkdir -p "$T/src"
echo '# TODO: refactor' > "$T/src/a.py"
echo '# FIXME: broken' > "$T/src/b.py"
echo '# HACK: workaround' > "$T/src/c.py"
echo 'clean = True' > "$T/src/d.py"
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
CQ=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(int(d['exploration']['code_quality']['score']))
")
assert_eq "$CQ" "7" "3 TODO files → score 7"

# ═══════════════════════════════════════════════════════════════════════════
# 28. explore-scan.sh documentation scoring
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. Explore scan — documentation"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "doc test" 10 > /dev/null

# Project with README (4pts) + docs/ (3pts) + fresh README (3pts) = 10
mkdir -p "$T/docs"
echo '# Docs' > "$T/README.md"
echo 'guide' > "$T/docs/guide.md"
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
DOC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(int(d['exploration']['documentation']['score']))
")
assert_eq "$DOC" "10" "README + docs/ + fresh commit = score 10"

# ═══════════════════════════════════════════════════════════════════════════
# 29. explore-scan.sh architecture (big files lower score)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Explore scan — architecture big files"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "arch test" 10 > /dev/null

mkdir -p "$T/src"
# Create a file with 350 lines (> 300 threshold)
python3 -c "
for i in range(350):
    print(f'line_{i} = {i}')
" > "$T/src/big.py"
echo 'small = 1' > "$T/src/small.py"
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
ARCH=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(int(d['exploration']['architecture']['score']))
")
assert_eq "$ARCH" "8" "1 big file → score 8"

# ═══════════════════════════════════════════════════════════════════════════
# 30. explore-scan.sh dx scoring (help patterns)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. Explore scan — dx with help patterns"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "dx test" 10 > /dev/null

mkdir -p "$T/scripts"
cat > "$T/scripts/run.sh" << 'SH'
#!/usr/bin/env bash
echo "Usage: run.sh [--help]"
SH
cat > "$T/scripts/build.sh" << 'SH'
#!/usr/bin/env bash
echo "Usage: build.sh"
SH
cat > "$T/scripts/deploy.sh" << 'SH'
#!/usr/bin/env bash
echo "deploying..."
SH
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
DX=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(int(d['exploration']['dx']['score']))
")
# 2 help files / 3 cli files = 6.67 → 6
assert_eq "$DX" "6" "2/3 scripts with help → score 6"

# ═══════════════════════════════════════════════════════════════════════════
# 31. explore-scan.sh scores are clamped 0-10
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. Explore scan — scores clamped"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "clamp test" 10 > /dev/null

# Many test files, few source files → ratio > 1 → should clamp to 10
mkdir -p "$T/tests"
echo 'x=1' > "$T/src.py"
for i in $(seq 1 20); do echo "t=$i" > "$T/tests/test_$i.py"; done
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
exp = d['exploration']
all_ok = all(0 <= exp[dim]['score'] <= 10 for dim in exp)
print('ok' if all_ok else 'fail')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "all scores within 0-10 range"

# ═══════════════════════════════════════════════════════════════════════════
# 32. explore-scan.sh + explore-pick integration
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "32. Explore scan + pick integration"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "integration test" 10 > /dev/null

# Create project where security is weakest
mkdir -p "$T/src" "$T/tests" "$T/docs"
echo '# Docs' > "$T/README.md"
echo 'guide' > "$T/docs/guide.md"
echo 'def test_a(): pass' > "$T/tests/test_a.py"
echo 'try: pass\nexcept: pass' > "$T/src/app.py"
echo 'password = "hunter2"\napi_key = "sk-123"' > "$T/src/secrets.py"
echo 'DB=x' > "$T/.env"
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

# Scan first
bash "$SCANNER" "$T" "$CONDUCTOR" > /dev/null 2>&1

# Now pick should choose the lowest-scored dimension
DIM=$(bash "$CONDUCTOR" explore-pick "$T")
# Security should be lowest due to hardcoded secrets + .env
SEC=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(int(d['exploration']['security']['score']))
")
PICK_SCORE=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
scores = {dim: d['exploration'][dim]['score'] for dim in d['exploration']}
lowest = min(scores, key=scores.get)
print(lowest)
")
assert_eq "$DIM" "$PICK_SCORE" "explore-pick selects lowest-scored dimension after scan"

# ═══════════════════════════════════════════════════════════════════════════
# 33. explore-scan.sh handles empty project
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "33. Explore scan — empty project"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "empty test" 10 > /dev/null
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

OUTPUT=$(bash "$SCANNER" "$T" "$CONDUCTOR" 2>&1)
assert_contains "$OUTPUT" "Exploration scan complete" "scan completes on empty project"

VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
exp = d['exploration']
all_ok = all(0 <= exp[dim]['score'] <= 10 for dim in exp)
print('ok' if all_ok else 'fail')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "empty project gets valid scores"

# ═══════════════════════════════════════════════════════════════════════════
# 34. explore-scan.sh requires initialized state
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "34. Explore scan — requires state"
T=$(new_tmp)
mkdir -p "$T"
ERR=$(bash "$SCANNER" "$T" "$CONDUCTOR" 2>&1 || true)
assert_contains "$ERR" "ERROR" "scan fails without initialized state"

# ═══════════════════════════════════════════════════════════════════════════
# 35. max_sprints validation rejects non-numeric
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "35. Init — max_sprints validation"
T=$(new_tmp)
ERR=$(bash "$CONDUCTOR" init "$T" "test" "abc" 2>&1 || true)
assert_contains "$ERR" "positive integer" "non-numeric max_sprints rejected"

ERR2=$(bash "$CONDUCTOR" init "$T" "test" "0" 2>&1 || true)
assert_contains "$ERR2" "must be > 0" "zero max_sprints rejected"

# Valid numeric should succeed
T2=$(new_tmp)
bash "$CONDUCTOR" init "$T2" "test" "5" > /dev/null 2>&1
assert_file_exists "$T2/.autonomous/conductor-state.json" "numeric max_sprints accepted"

# ═══════════════════════════════════════════════════════════════════════════
# 36. explore-score validates dimension and score
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "36. Explore-score — input validation"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "validate test" 10 > /dev/null

ERR=$(bash "$CONDUCTOR" explore-score "$T" "bogus_dim" "5" 2>&1 || true)
assert_contains "$ERR" "unknown dimension" "invalid dimension rejected"

ERR=$(bash "$CONDUCTOR" explore-score "$T" "security" "notanumber" 2>&1 || true)
assert_contains "$ERR" "must be numeric" "non-numeric score rejected"

# Valid should succeed
RESULT=$(bash "$CONDUCTOR" explore-score "$T" "security" "7.5" 2>&1)
assert_eq "$RESULT" "ok" "valid dimension + numeric score accepted"

# ═══════════════════════════════════════════════════════════════════════════
# 37. Trap handler cleans up lock file on exit
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "37. Trap cleanup — lock and tmp files"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "trap test" 10 > /dev/null

# Lock should be cleaned up after init (since trap EXIT fires)
# The lock is acquired in init, but cleanup runs on EXIT
LOCK="$T/.autonomous/conductor.lock"
if [ -f "$LOCK" ]; then
  fail "lock file should be cleaned up after script exits"
else
  ok "lock file cleaned up after script exits"
fi

# No stale tmp files
TMP_COUNT=$(find "$T/.autonomous" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMP_COUNT" "0" "no stale tmp files after operations"

# ═══════════════════════════════════════════════════════════════════════════
# 38. explore-scan.sh clamp handles edge cases
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "38. Explore scan — clamp edge cases"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "clamp edge test" 10 > /dev/null

# Create a project with NO source files at all (just a test file)
# This tests the division-by-zero guard in test_coverage and dx
mkdir -p "$T/tests"
echo 'test=1' > "$T/tests/test_only.py"
(cd "$T" && git init -q && git add -A && git commit -q -m "init")

OUTPUT=$(bash "$SCANNER" "$T" "$CONDUCTOR" 2>&1)
assert_contains "$OUTPUT" "Exploration scan complete" "scan completes with only test files"

# All scores should be valid (0-10)
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
exp = d['exploration']
all_ok = all(0 <= exp[dim]['score'] <= 10 for dim in exp)
print('ok' if all_ok else 'fail')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "all scores valid with only test files (no div-by-zero)"

# ═══════════════════════════════════════════════════════════════════════════
# 39. Security — path with single quotes
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "39. Security — path with single quotes"
T=$(new_tmp)
TRICKY="$T/it's a test"
mkdir -p "$TRICKY"
SESSION_ID=$(bash "$CONDUCTOR" init "$TRICKY" "test mission" 5 2>&1)
assert_contains "$SESSION_ID" "conductor-" "init works with single-quote path"
assert_file_exists "$TRICKY/.autonomous/conductor-state.json" "state created in quote path"

# Read state back
STATE=$(bash "$CONDUCTOR" read "$TRICKY" 2>&1)
MISSION=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('mission',''))" "$STATE")
assert_eq "$MISSION" "test mission" "read works with single-quote path"

# Sprint start/end with quote path
SPRINT=$(bash "$CONDUCTOR" sprint-start "$TRICKY" "test direction" 2>&1)
assert_eq "$SPRINT" "1" "sprint-start works with single-quote path"

PHASE=$(bash "$CONDUCTOR" sprint-end "$TRICKY" "complete" "done" "[]" "false" 2>&1)
assert_eq "$PHASE" "directed" "sprint-end works with single-quote path"

# ═══════════════════════════════════════════════════════════════════════════
# 40. Security — mission with special characters
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "40. Security — mission with special characters"
T=$(new_tmp)
SESSION_ID=$(bash "$CONDUCTOR" init "$T" "build 'feature' with \"quotes\" & \$vars" 5 2>&1)
assert_contains "$SESSION_ID" "conductor-" "init with special char mission"
STATE=$(bash "$CONDUCTOR" read "$T" 2>&1)
MISSION=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('mission',''))" "$STATE")
assert_contains "$MISSION" "feature" "mission with quotes preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 41. Security — direction with special characters
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "41. Security — direction with special characters"
T=$(new_tmp)
bash "$CONDUCTOR" init "$T" "test" 5 > /dev/null
SPRINT=$(bash "$CONDUCTOR" sprint-start "$T" "fix 'bug' in module" 2>&1)
assert_eq "$SPRINT" "1" "sprint-start with single-quote direction"
STATE=$(bash "$CONDUCTOR" read "$T" 2>&1)
DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['sprints'][0]['direction'])" "$STATE")
assert_contains "$DIR" "bug" "direction with quotes preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 42. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "42. --help flag"
HELP=$(bash "$CONDUCTOR" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows usage"
assert_contains "$HELP" "init" "--help lists init command"
assert_contains "$HELP" "sprint-start" "--help lists sprint-start command"
assert_contains "$HELP" "explore-pick" "--help lists explore-pick command"
assert_contains "$HELP" "Examples" "--help includes examples"

echo ""
echo "43. -h and help variants"
HELP_SHORT=$(bash "$CONDUCTOR" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h also shows usage"
HELP_WORD=$(bash "$CONDUCTOR" help 2>&1)
assert_contains "$HELP_WORD" "Usage:" "'help' subcommand also shows usage"

echo ""
echo "44. --help exits 0"
bash "$CONDUCTOR" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits with code 0"

# ═══════════════════════════════════════════════════════════════════════════
# 45. init cleans stale sprint-summary.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "45. init cleans stale sprint-summary.json"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"status":"complete","summary":"stale from prior session"}' > "$T/.autonomous/sprint-summary.json"
echo '{"status":"complete","summary":"stale sprint 1"}' > "$T/.autonomous/sprint-1-summary.json"
bash "$CONDUCTOR" init "$T" "fresh mission" 5 >/dev/null
assert_file_not_exists "$T/.autonomous/sprint-summary.json" "stale sprint-summary.json removed"
assert_file_not_exists "$T/.autonomous/sprint-1-summary.json" "stale sprint-1-summary.json removed"
assert_file_exists "$T/.autonomous/conductor-state.json" "fresh conductor-state.json created"
MISSION=$(python3 -c "import json; print(json.load(open('$T/.autonomous/conductor-state.json'))['mission'])")
assert_eq "$MISSION" "fresh mission" "conductor-state has new mission"

# ═══════════════════════════════════════════════════════════════════════════
# 46. init preserves backlog.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "46. init preserves backlog.json"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"items":[{"title":"keep me"}]}' > "$T/.autonomous/backlog.json"
echo '{"status":"complete"}' > "$T/.autonomous/sprint-summary.json"
bash "$CONDUCTOR" init "$T" "new session" 5 >/dev/null
assert_file_exists "$T/.autonomous/backlog.json" "backlog.json preserved"
TITLE=$(python3 -c "import json; print(json.load(open('$T/.autonomous/backlog.json'))['items'][0]['title'])")
assert_eq "$TITLE" "keep me" "backlog content intact"
assert_file_not_exists "$T/.autonomous/sprint-summary.json" "stale summary cleaned"

# ═══════════════════════════════════════════════════════════════════════════
# 47. init cleans all numbered summaries
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "47. init cleans all numbered summaries"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
for i in 1 2 3 4 5; do
  echo "{\"status\":\"complete\",\"sprint\":$i}" > "$T/.autonomous/sprint-$i-summary.json"
done
bash "$CONDUCTOR" init "$T" "clean slate" 5 >/dev/null
for i in 1 2 3 4 5; do
  assert_file_not_exists "$T/.autonomous/sprint-$i-summary.json" "sprint-$i-summary.json removed"
done

print_results
