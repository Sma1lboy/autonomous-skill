#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HISTORY="$SCRIPT_DIR/../scripts/history.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_history.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Helper: create a git repo with main branch ──────────────────────────

setup_project() {
  local dir="$1"
  mkdir -p "$dir"
  cd "$dir"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > init.txt
  git add init.txt
  git commit -q -m "initial commit"
  git branch -M main
  cd - > /dev/null
}

# Detect base branch (main or master)
get_base_branch() {
  local dir="$1"
  if git -C "$dir" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    echo "main"
  elif git -C "$dir" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    echo "master"
  else
    echo "main"
  fi
}

# Create an auto/ branch with conductor-state.json committed
create_auto_branch_with_state() {
  local dir="$1" branch="$2" state_json="$3"
  local base
  base=$(get_base_branch "$dir")
  cd "$dir"
  git checkout -q "$base"
  git checkout -q -b "$branch"
  mkdir -p .autonomous
  echo "$state_json" > .autonomous/conductor-state.json
  git add .autonomous/conductor-state.json
  git commit -q -m "feat: init conductor state"
  cd - > /dev/null
}

# Create an auto/ branch with no conductor-state.json
create_auto_branch_bare() {
  local dir="$1" branch="$2"
  local base
  base=$(get_base_branch "$dir")
  cd "$dir"
  git checkout -q "$base"
  git checkout -q -b "$branch"
  echo "content-$RANDOM" > "file-$RANDOM.txt"
  git add .
  git commit -q -m "feat: bare branch commit"
  cd - > /dev/null
}

make_commits() {
  local dir="$1"
  shift
  cd "$dir"
  for msg in "$@"; do
    local fname
    fname="file-$(date +%s%N)-$RANDOM.txt"
    echo "$msg" > "$fname"
    git add "$fname"
    git commit -q -m "$msg"
  done
  cd - > /dev/null
}

# Standard state JSON for testing
STATE_DIRECTED='{"session_id":"test-1","mission":"build REST API","phase":"directed","max_sprints":5,"max_directed_sprints":3,"sprints":[{"number":1,"direction":"add endpoints","status":"complete","commits":["abc123"],"summary":"added GET/POST","direction_complete":true,"quality_gate_passed":true,"retry_count":0}],"consecutive_complete":1,"consecutive_zero_commits":0,"exploration":{}}'

STATE_EXPLORING='{"session_id":"test-2","mission":"improve quality","phase":"exploring","max_sprints":5,"max_directed_sprints":3,"sprints":[{"number":1,"direction":"add tests","status":"complete","commits":["def456","ghi789"],"summary":"added tests","direction_complete":true,"quality_gate_passed":true,"retry_count":0},{"number":2,"direction":"fix linting","status":"complete","commits":["jkl012"],"summary":"fixed lint","direction_complete":false,"quality_gate_passed":false,"retry_count":1}],"consecutive_complete":0,"consecutive_zero_commits":0,"session_cost_usd":1.25,"exploration":{"test_coverage":{"audited":true,"score":8}}}'

STATE_MULTI_SPRINT='{"session_id":"test-3","mission":"full build","phase":"directed","max_sprints":10,"max_directed_sprints":7,"sprints":[{"number":1,"direction":"setup project","status":"complete","commits":["a1"],"summary":"project setup","direction_complete":true,"quality_gate_passed":true,"retry_count":0},{"number":2,"direction":"add auth","status":"complete","commits":["b1","b2"],"summary":"auth done","direction_complete":true,"quality_gate_passed":true,"retry_count":0},{"number":3,"direction":"add dashboard","status":"running","commits":[],"summary":"","direction_complete":false,"retry_count":0}],"consecutive_complete":2,"consecutive_zero_commits":0,"session_cost_usd":3.50,"exploration":{}}'

# ── 1. Help flags ────────────────────────────────────────────────────────

echo ""
echo "1. Help flags"

RESULT=$(bash "$HISTORY" --help 2>&1)
assert_contains "$RESULT" "Usage:" "--help shows usage"
assert_contains "$RESULT" "history.sh" "--help mentions script name"
echo "$RESULT" | grep -qF -- "--detail" && ok "--help mentions --detail" || fail "--help mentions --detail"
echo "$RESULT" | grep -qF -- "--compare" && ok "--help mentions --compare" || fail "--help mentions --compare"
echo "$RESULT" | grep -qF -- "--json" && ok "--help mentions --json" || fail "--help mentions --json"

RESULT2=$(bash "$HISTORY" -h 2>&1)
assert_contains "$RESULT2" "Usage:" "-h shows usage"

RESULT3=$(bash "$HISTORY" help 2>&1)
assert_contains "$RESULT3" "Usage:" "help shows usage"

# ── 2. Error handling ───────────────────────────────────────────────────

echo ""
echo "2. Error handling"

RESULT=$(bash "$HISTORY" 2>&1) || true
assert_contains "$RESULT" "ERROR" "missing project-dir shows error"

RESULT=$(bash "$HISTORY" /nonexistent/path 2>&1) || true
assert_contains "$RESULT" "ERROR" "nonexistent dir shows error"

T=$(new_tmp)
RESULT=$(bash "$HISTORY" "$T" 2>&1) || true
assert_contains "$RESULT" "ERROR" "non-git dir shows error"
assert_contains "$RESULT" "not a git repository" "mentions not a git repo"

# ── 3. No auto/ branches ────────────────────────────────────────────────

echo ""
echo "3. No auto/ branches"

T=$(new_tmp)
setup_project "$T"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT" "No auto/ branches" "shows message when no auto/ branches"

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
assert_eq "$RESULT" "[]" "JSON mode returns empty array when no branches"

# ── 4. Single auto/ branch listing ──────────────────────────────────────

echo ""
echo "4. Single branch listing"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-100" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT" "Session History" "shows header"
assert_contains "$RESULT" "auto/session-100" "shows branch name"
assert_contains "$RESULT" "directed" "shows phase"
assert_contains "$RESULT" "Total:" "shows total line"
assert_contains "$RESULT" "1 session" "shows session count"

# ── 5. Multiple branches sorted by date ─────────────────────────────────

echo ""
echo "5. Multiple branches sorted by date"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-old" "$STATE_DIRECTED"
# Small delay to ensure different timestamps
sleep 1
create_auto_branch_with_state "$T" "auto/session-new" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT" "auto/session-old" "shows old branch"
assert_contains "$RESULT" "auto/session-new" "shows new branch"
assert_contains "$RESULT" "2 session" "shows 2 sessions"

# Verify order: newer should appear first
RESULT_JSON=$(bash "$HISTORY" "$T" --json 2>&1)
ORDER=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
if len(d) >= 2 and d[0]['branch'] == 'auto/session-new':
    print('ok')
else:
    print('fail: ' + ','.join(s['branch'] for s in d))
" "$RESULT_JSON" 2>/dev/null || echo "fail")
assert_eq "$ORDER" "ok" "newer branch listed first"

# ── 6. JSON output for listing ──────────────────────────────────────────

echo ""
echo "6. JSON listing output"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-json-test" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)

VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    assert isinstance(d, list)
    assert len(d) == 1
    s = d[0]
    assert s['branch'] == 'auto/session-json-test'
    assert s['sprint_count'] == 2
    assert s['phase'] == 'exploring'
    assert s['cost'] == 1.25
    assert s['mission'] == 'improve quality'
    assert 'date' in s
    assert 'total_commits' in s
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "JSON listing has all required fields"

# ── 7. Branch with no conductor-state.json ──────────────────────────────

echo ""
echo "7. Branch without conductor-state.json"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_bare "$T" "auto/session-bare"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT" "auto/session-bare" "shows bare branch"
assert_contains "$RESULT" "no data" "shows 'no data' for missing state"

RESULT_JSON=$(bash "$HISTORY" "$T" --json 2>&1)
PHASE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d[0]['phase'])
" "$RESULT_JSON" 2>/dev/null)
assert_eq "$PHASE" "no data" "JSON shows 'no data' phase for bare branch"

# ── 8. Cost display ─────────────────────────────────────────────────────

echo ""
echo "8. Cost display"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-cost" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT" "1.25" "shows cost value"

# No cost
create_auto_branch_with_state "$T" "auto/session-nocost" "$STATE_DIRECTED"

RESULT_JSON=$(bash "$HISTORY" "$T" --json 2>&1)
NOCOST=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
for s in d:
    if s['branch'] == 'auto/session-nocost':
        print('null' if s['cost'] is None else 'has-cost')
        break
" "$RESULT_JSON" 2>/dev/null)
assert_eq "$NOCOST" "null" "JSON shows null cost when not tracked"

# ── 9. Detail mode: basic ───────────────────────────────────────────────

echo ""
echo "9. Detail mode basic"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-detail" "$STATE_EXPLORING"
make_commits "$T" "feat: extra commit"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-detail 2>&1)
assert_contains "$RESULT" "Session Detail" "detail shows header"
assert_contains "$RESULT" "auto/session-detail" "detail shows branch name"
assert_contains "$RESULT" "improve quality" "detail shows mission"
assert_contains "$RESULT" "exploring" "detail shows phase"
assert_contains "$RESULT" "add tests" "detail shows sprint direction"
assert_contains "$RESULT" "fix linting" "detail shows second sprint"
assert_contains "$RESULT" "complete" "detail shows sprint status"

# ── 10. Detail mode: sprint table ───────────────────────────────────────

echo ""
echo "10. Detail sprint table"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-table" "$STATE_MULTI_SPRINT"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-table 2>&1)
assert_contains "$RESULT" "setup project" "table shows sprint 1 direction"
assert_contains "$RESULT" "add auth" "table shows sprint 2 direction"
assert_contains "$RESULT" "add dashboard" "table shows sprint 3 direction"
assert_contains "$RESULT" "running" "table shows running status"
assert_contains "$RESULT" "3.50" "detail shows cost"

# ── 11. Detail mode: JSON ───────────────────────────────────────────────

echo ""
echo "11. Detail JSON"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-djson" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-djson --json 2>&1)

VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    assert d['branch'] == 'auto/session-djson'
    assert d['mission'] == 'improve quality'
    assert d['phase'] == 'exploring'
    assert d['sprint_count'] == 2
    assert d['max_sprints'] == 5
    assert d['cost'] == 1.25
    assert len(d['sprints']) == 2
    assert d['sprints'][0]['direction'] == 'add tests'
    assert d['sprints'][1]['direction'] == 'fix linting'
    assert 'date' in d
    assert 'total_commits' in d
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "detail JSON has all fields"

# ── 12. Detail mode: nonexistent branch ─────────────────────────────────

echo ""
echo "12. Detail nonexistent branch"

T=$(new_tmp)
setup_project "$T"

RESULT=$(bash "$HISTORY" "$T" --detail auto/no-such-branch 2>&1) || true
assert_contains "$RESULT" "ERROR" "detail nonexistent branch shows error"
assert_contains "$RESULT" "branch not found" "mentions branch not found"

# ── 13. Detail mode: branch with no state ───────────────────────────────

echo ""
echo "13. Detail branch without state"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_bare "$T" "auto/session-nostate"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-nostate 2>&1)
assert_contains "$RESULT" "Session Detail" "detail still shows header for bare branch"
assert_contains "$RESULT" "no data" "detail shows 'no data' for mission"
assert_contains "$RESULT" "No sprint data" "detail shows no sprint data message"

# ── 14. Compare mode: basic ─────────────────────────────────────────────

echo ""
echo "14. Compare mode basic"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-a" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/session-b" "$STATE_EXPLORING"
make_commits "$T" "feat: extra b commit"

RESULT=$(bash "$HISTORY" "$T" --compare auto/session-a auto/session-b 2>&1)
assert_contains "$RESULT" "Session Comparison" "compare shows header"
assert_contains "$RESULT" "auto/session-a" "compare shows branch A"
assert_contains "$RESULT" "auto/session-b" "compare shows branch B"
assert_contains "$RESULT" "Phase" "compare shows phase row"
assert_contains "$RESULT" "Commits" "compare shows commits row"
assert_contains "$RESULT" "Sprints" "compare shows sprints row"

# ── 15. Compare mode: commit difference ─────────────────────────────────

echo ""
echo "15. Compare commit difference"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/cmp-less" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/cmp-more" "$STATE_EXPLORING"
make_commits "$T" "feat: more1" "feat: more2" "feat: more3"

RESULT=$(bash "$HISTORY" "$T" --compare auto/cmp-less auto/cmp-more 2>&1)
assert_contains "$RESULT" "more commits" "compare identifies which had more commits"

# ── 16. Compare mode: JSON ──────────────────────────────────────────────

echo ""
echo "16. Compare JSON"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/cmp-j1" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/cmp-j2" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --compare auto/cmp-j1 auto/cmp-j2 --json 2>&1)

VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    assert 'branch_a' in d
    assert 'branch_b' in d
    assert d['branch_a']['branch'] == 'auto/cmp-j1'
    assert d['branch_b']['branch'] == 'auto/cmp-j2'
    assert 'more_commits' in d
    assert 'more_sprints' in d
    assert d['branch_a']['phase'] == 'directed'
    assert d['branch_b']['phase'] == 'exploring'
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "compare JSON has all fields"

# ── 17. Compare mode: nonexistent branch ────────────────────────────────

echo ""
echo "17. Compare nonexistent branch"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/exists" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --compare auto/exists auto/nope 2>&1) || true
assert_contains "$RESULT" "ERROR" "compare nonexistent shows error"
assert_contains "$RESULT" "branch not found" "compare mentions branch not found"

RESULT=$(bash "$HISTORY" "$T" --compare auto/nope auto/exists 2>&1) || true
assert_contains "$RESULT" "ERROR" "compare first nonexistent shows error"

# ── 18. Compare mode: equal sessions ────────────────────────────────────

echo ""
echo "18. Compare equal sessions"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/eq-1" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/eq-2" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --compare auto/eq-1 auto/eq-2 2>&1)
assert_contains "$RESULT" "Both had" "compare shows tie for equal metrics"

# ── 19. --detail without value ──────────────────────────────────────────

echo ""
echo "19. Flag validation"

T=$(new_tmp)
setup_project "$T"

RESULT=$(bash "$HISTORY" "$T" --detail 2>&1) || true
assert_contains "$RESULT" "ERROR" "--detail without value shows error"

RESULT=$(bash "$HISTORY" "$T" --compare 2>&1) || true
assert_contains "$RESULT" "ERROR" "--compare without values shows error"

RESULT=$(bash "$HISTORY" "$T" --compare auto/only-one 2>&1) || true
assert_contains "$RESULT" "ERROR" "--compare with one value shows error"

# ── 20. Unexpected argument ─────────────────────────────────────────────

echo ""
echo "20. Unexpected argument"

T=$(new_tmp)
setup_project "$T"

RESULT=$(bash "$HISTORY" "$T" --bad-flag 2>&1) || true
assert_contains "$RESULT" "ERROR" "unexpected flag shows error"

# ── 21. Sprint count in listing ─────────────────────────────────────────

echo ""
echo "21. Sprint count accuracy"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-sprints" "$STATE_MULTI_SPRINT"

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
SPRINTS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d[0]['sprint_count'])
" "$RESULT" 2>/dev/null)
assert_eq "$SPRINTS" "3" "sprint count is 3 for multi-sprint state"

# ── 22. Listing table formatting ────────────────────────────────────────

echo ""
echo "22. Table formatting"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-fmt" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT" "Branch" "table header has Branch"
assert_contains "$RESULT" "Date" "table header has Date"
assert_contains "$RESULT" "Sprints" "table header has Sprints"
assert_contains "$RESULT" "Phase" "table header has Phase"
assert_contains "$RESULT" "Commits" "table header has Commits"
assert_contains "$RESULT" "Cost" "table header has Cost"

# ── 23. Detail mode: quality gate display ───────────────────────────────

echo ""
echo "23. Quality gate in detail"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-qg" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-qg 2>&1)
assert_contains "$RESULT" "QG:pass" "detail shows QG:pass"
assert_contains "$RESULT" "QG:fail" "detail shows QG:fail"

# ── 24. Detail mode: direction_complete display ─────────────────────────

echo ""
echo "24. Direction complete in detail"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-dc" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-dc 2>&1)
assert_contains "$RESULT" "complete" "detail shows direction complete"

# ── 25. Long branch name truncation ────────────────────────────────────

echo ""
echo "25. Long branch name"

T=$(new_tmp)
setup_project "$T"
LONG_BRANCH="auto/session-this-is-a-very-long-branch-name-that-exceeds-normal-width"
create_auto_branch_with_state "$T" "$LONG_BRANCH" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT" "..." "long branch name is truncated"

# JSON should have full name
RESULT_JSON=$(bash "$HISTORY" "$T" --json 2>&1)
FULL_NAME=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d[0]['branch'])
" "$RESULT_JSON" 2>/dev/null)
assert_eq "$FULL_NAME" "$LONG_BRANCH" "JSON has full branch name"

# ── 26. Mixed branches: some with state, some without ───────────────────

echo ""
echo "26. Mixed branches"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-with" "$STATE_DIRECTED"
create_auto_branch_bare "$T" "auto/session-without"

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
MIXED=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert len(d) == 2
has_state = [s for s in d if s['branch'] == 'auto/session-with'][0]
no_state = [s for s in d if s['branch'] == 'auto/session-without'][0]
checks = []
checks.append(has_state['phase'] == 'directed')
checks.append(no_state['phase'] == 'no data')
checks.append(has_state['sprint_count'] == 1)
checks.append(no_state['sprint_count'] == 0)
print('ok' if all(checks) else f'fail')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$MIXED" "ok" "mixed branches both listed with correct data"

# ── 27. Non-auto branches ignored ──────────────────────────────────────

echo ""
echo "27. Non-auto branches ignored"

T=$(new_tmp)
setup_project "$T"
cd "$T"
git checkout -q -b feature/something
echo "feature" > feature.txt
git add feature.txt
git commit -q -m "feat: feature branch"
cd - > /dev/null
create_auto_branch_with_state "$T" "auto/session-only" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
COUNT=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(len(d))
" "$RESULT" 2>/dev/null)
assert_eq "$COUNT" "1" "only auto/ branches listed"

NAMES=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d[0]['branch'])
" "$RESULT" 2>/dev/null)
assert_eq "$NAMES" "auto/session-only" "non-auto branch not in list"

# ── 28. Detail: sprint direction truncation ─────────────────────────────

echo ""
echo "28. Long direction truncation"

LONG_DIR_STATE='{"session_id":"t","mission":"m","phase":"directed","max_sprints":5,"max_directed_sprints":3,"sprints":[{"number":1,"direction":"this is a very long sprint direction that should be truncated in the table display","status":"complete","commits":["x"],"summary":"done","direction_complete":true,"quality_gate_passed":true,"retry_count":0}],"consecutive_complete":1,"consecutive_zero_commits":0,"exploration":{}}'

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-longdir" "$LONG_DIR_STATE"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-longdir 2>&1)
assert_contains "$RESULT" "..." "long direction is truncated in detail table"

# ── 29. Commit count from git (not just state) ──────────────────────────

echo ""
echo "29. Git commit count"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-commits" "$STATE_DIRECTED"
make_commits "$T" "feat: extra1" "feat: extra2"

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
COMMITS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d[0]['total_commits'])
" "$RESULT" 2>/dev/null)
# 1 state commit + 2 extra commits = 3
assert_eq "$COMMITS" "3" "commit count comes from git history"

# ── 30. Detail: max_sprints in output ───────────────────────────────────

echo ""
echo "30. Max sprints in detail"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-max" "$STATE_MULTI_SPRINT"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-max 2>&1)
assert_contains "$RESULT" "3/10" "detail shows sprint count / max"

RESULT_JSON=$(bash "$HISTORY" "$T" --detail auto/session-max --json 2>&1)
MAX=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['max_sprints'])
" "$RESULT_JSON" 2>/dev/null)
assert_eq "$MAX" "10" "JSON detail has max_sprints"

# ── 31. Compare: sprint difference ──────────────────────────────────────

echo ""
echo "31. Compare sprint difference"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/few-sprints" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/many-sprints" "$STATE_MULTI_SPRINT"

RESULT=$(bash "$HISTORY" "$T" --compare auto/few-sprints auto/many-sprints 2>&1)
assert_contains "$RESULT" "more sprints" "compare identifies sprint difference"

# ── 32. Compare: cost display ───────────────────────────────────────────

echo ""
echo "32. Compare cost"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/cost-a" "$STATE_EXPLORING"
create_auto_branch_with_state "$T" "auto/cost-b" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --compare auto/cost-a auto/cost-b 2>&1)
assert_contains "$RESULT" "Cost" "compare shows cost row"
assert_contains "$RESULT" "1.25" "compare shows cost value"

# ── 33. Compare JSON: more_commits field ────────────────────────────────

echo ""
echo "33. Compare JSON more_commits"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/less-c" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/more-c" "$STATE_EXPLORING"
make_commits "$T" "feat: x1" "feat: x2"

RESULT=$(bash "$HISTORY" "$T" --compare auto/less-c auto/more-c --json 2>&1)
MORE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['more_commits'])
" "$RESULT" 2>/dev/null)
assert_eq "$MORE" "auto/more-c" "JSON identifies branch with more commits"

# ── 34. Compare JSON: tie ───────────────────────────────────────────────

echo ""
echo "34. Compare JSON tie"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/tie-1" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/tie-2" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --compare auto/tie-1 auto/tie-2 --json 2>&1)
TIE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['more_commits'])
" "$RESULT" 2>/dev/null)
assert_eq "$TIE" "tie" "JSON shows tie when commits equal"

# ── 35. Listing: separator lines ────────────────────────────────────────

echo ""
echo "35. Separator lines"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-sep" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
# Check for horizontal line character
LINE_COUNT=$(echo "$RESULT" | grep -c "─" || true)
assert_ge "$LINE_COUNT" "2" "listing has separator lines"

# ── 36. Detail: separator lines ─────────────────────────────────────────

echo ""
echo "36. Detail separator lines"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-dsep" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-dsep 2>&1)
LINE_COUNT=$(echo "$RESULT" | grep -c "─" || true)
assert_ge "$LINE_COUNT" "1" "detail has separator lines"

# ── 37. Compare: separator lines ───────────────────────────────────────

echo ""
echo "37. Compare separator lines"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/s1" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/s2" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --compare auto/s1 auto/s2 2>&1)
LINE_COUNT=$(echo "$RESULT" | grep -c "─" || true)
assert_ge "$LINE_COUNT" "1" "compare has separator lines"

# ── 38. Detail: no cost shows dash ──────────────────────────────────────

echo ""
echo "38. Detail no-cost shows dash"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-nc" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-nc 2>&1)
assert_contains "$RESULT" "Cost:" "detail has cost label"
# The cost line should show - not $
COST_LINE=$(echo "$RESULT" | grep "Cost:" || echo "")
assert_contains "$COST_LINE" "-" "no-cost shows dash"

# ── 39. Listing: no-cost shows dash ────────────────────────────────────

echo ""
echo "39. Listing no-cost shows dash"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-ncd" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
# In the table, cost column should have "-"
assert_contains "$RESULT" " -" "listing shows dash for no cost"

# ── 40. Multiple branches: all JSON fields present ──────────────────────

echo ""
echo "40. JSON completeness"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/j1" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/j2" "$STATE_EXPLORING"
create_auto_branch_bare "$T" "auto/j3"

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
VALID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert len(d) == 3
for s in d:
    assert 'branch' in s
    assert 'date' in s
    assert 'sprint_count' in s
    assert 'phase' in s
    assert 'total_commits' in s
    assert 'cost' in s
    assert 'mission' in s
print('ok')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "all 3 branches have all JSON fields"

# ── 41. Detail JSON: sprints array structure ────────────────────────────

echo ""
echo "41. Detail sprint structure"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/sprint-struct" "$STATE_MULTI_SPRINT"

RESULT=$(bash "$HISTORY" "$T" --detail auto/sprint-struct --json 2>&1)
VALID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
sprints = d['sprints']
assert len(sprints) == 3
s1 = sprints[0]
assert s1['number'] == 1
assert s1['direction'] == 'setup project'
assert s1['status'] == 'complete'
assert len(s1['commits']) == 1
s3 = sprints[2]
assert s3['status'] == 'running'
assert len(s3['commits']) == 0
print('ok')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "detail JSON sprints have correct structure"

# ── 42. Compare: mission display ────────────────────────────────────────

echo ""
echo "42. Compare mission"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/mission-a" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/mission-b" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --compare auto/mission-a auto/mission-b 2>&1)
assert_contains "$RESULT" "Mission" "compare shows mission row"
assert_contains "$RESULT" "build REST API" "compare shows mission A"
assert_contains "$RESULT" "improve quality" "compare shows mission B"

# ── 43. Compare: date display ───────────────────────────────────────────

echo ""
echo "43. Compare date"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/date-a" "$STATE_DIRECTED"
create_auto_branch_with_state "$T" "auto/date-b" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --compare auto/date-a auto/date-b 2>&1)
assert_contains "$RESULT" "Date" "compare shows date row"

# ── 44. master branch fallback ──────────────────────────────────────────

echo ""
echo "44. Master branch fallback"

T=$(new_tmp)
mkdir -p "$T"
cd "$T"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "initial"
git branch -M master
cd - > /dev/null
create_auto_branch_with_state "$T" "auto/session-master" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
assert_contains "$RESULT" "auto/session-master" "works with master branch"

COMMITS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d[0]['total_commits'])
" "$RESULT" 2>/dev/null)
assert_ge "$COMMITS" "1" "commit count works with master base"

# ── 45. Detail: retry_count preserved ───────────────────────────────────

echo ""
echo "45. Retry count in detail"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-retry" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-retry --json 2>&1)
RETRY=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['sprints'][1]['retry_count'])
" "$RESULT" 2>/dev/null)
assert_eq "$RETRY" "1" "detail preserves retry_count"

# ── 46. Empty state JSON handling ───────────────────────────────────────

echo ""
echo "46. Empty state JSON"

T=$(new_tmp)
setup_project "$T"
cd "$T"
git checkout -q -b "auto/session-empty"
mkdir -p .autonomous
echo '{}' > .autonomous/conductor-state.json
git add .autonomous/conductor-state.json
git commit -q -m "feat: empty state"
cd - > /dev/null

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
PHASE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d[0]['phase'])
" "$RESULT" 2>/dev/null)
assert_eq "$PHASE" "no data" "empty JSON object shows 'no data' phase"

# ── 47. Corrupt JSON on branch ──────────────────────────────────────────

echo ""
echo "47. Corrupt JSON handling"

T=$(new_tmp)
setup_project "$T"
cd "$T"
git checkout -q -b "auto/session-corrupt"
mkdir -p .autonomous
echo '{not valid json' > .autonomous/conductor-state.json
git add .autonomous/conductor-state.json
git commit -q -m "feat: corrupt state"
cd - > /dev/null

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
PHASE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d[0]['phase'])
" "$RESULT" 2>/dev/null)
assert_eq "$PHASE" "no data" "corrupt JSON gracefully falls back to 'no data'"

# ── 48. Listing: cost with dollars ──────────────────────────────────────

echo ""
echo "48. Cost formatting"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-costfmt" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT" '$1.25' "listing formats cost with dollar sign"

# ── 49. Compare JSON: cost fields ───────────────────────────────────────

echo ""
echo "49. Compare JSON cost"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/cj1" "$STATE_EXPLORING"
create_auto_branch_with_state "$T" "auto/cj2" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --compare auto/cj1 auto/cj2 --json 2>&1)
COSTS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
a_cost = d['branch_a']['cost']
b_cost = d['branch_b']['cost']
checks = []
checks.append(a_cost == 1.25)
checks.append(b_cost is None)
print('ok' if all(checks) else f'fail: a={a_cost} b={b_cost}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$COSTS" "ok" "compare JSON has correct cost values"

# ── 50. Detail: date field present ──────────────────────────────────────

echo ""
echo "50. Detail date"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-date" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-date 2>&1)
assert_contains "$RESULT" "Date:" "detail shows date label"
# Date should be a real YYYY-MM-DD
DATE_LINE=$(echo "$RESULT" | grep "Date:" || echo "")
assert_contains "$DATE_LINE" "20" "date contains year prefix"

# ── 51. Listing: date formatting ────────────────────────────────────────

echo ""
echo "51. Listing date format"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-datefmt" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" 2>&1)
# The date in the table should be YYYY-MM-DD format (10 chars)
assert_contains "$RESULT" "20" "listing date starts with year"

# ── 52. Many branches performance ───────────────────────────────────────

echo ""
echo "52. Many branches"

T=$(new_tmp)
setup_project "$T"
for i in $(seq 1 5); do
  create_auto_branch_with_state "$T" "auto/session-perf-$i" "$STATE_DIRECTED"
done

RESULT=$(bash "$HISTORY" "$T" --json 2>&1)
COUNT=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(len(d))
" "$RESULT" 2>/dev/null)
assert_eq "$COUNT" "5" "lists all 5 branches"

RESULT_TEXT=$(bash "$HISTORY" "$T" 2>&1)
assert_contains "$RESULT_TEXT" "5 session" "total shows 5 sessions"

# ── 53. Detail: sprint summary in JSON ──────────────────────────────────

echo ""
echo "53. Sprint summary field"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-summ" "$STATE_EXPLORING"

RESULT=$(bash "$HISTORY" "$T" --detail auto/session-summ --json 2>&1)
SUMM=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['sprints'][0]['summary'])
" "$RESULT" 2>/dev/null)
assert_eq "$SUMM" "added tests" "sprint summary preserved in detail JSON"

# ── 54. Compare: mission truncation ─────────────────────────────────────

echo ""
echo "54. Compare mission truncation"

LONG_MISSION_STATE='{"session_id":"t","mission":"this is a very long mission description that should be truncated in compare view","phase":"directed","max_sprints":5,"max_directed_sprints":3,"sprints":[],"consecutive_complete":0,"consecutive_zero_commits":0,"exploration":{}}'

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/long-m" "$LONG_MISSION_STATE"
create_auto_branch_with_state "$T" "auto/short-m" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --compare auto/long-m auto/short-m 2>&1)
assert_contains "$RESULT" "Mission" "compare shows mission even when long"

# ── 55. Detail with --json flag placement ───────────────────────────────

echo ""
echo "55. JSON flag before --detail"

T=$(new_tmp)
setup_project "$T"
create_auto_branch_with_state "$T" "auto/session-flagorder" "$STATE_DIRECTED"

RESULT=$(bash "$HISTORY" "$T" --json --detail auto/session-flagorder 2>&1)
VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    assert 'branch' in d
    assert 'sprints' in d
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "JSON flag works before --detail"

# ── Print results ────────────────────────────────────────────────────────

print_results
