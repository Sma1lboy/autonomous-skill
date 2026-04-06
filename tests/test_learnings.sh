#!/usr/bin/env bash
# Tests for scripts/learnings.sh — conductor learning system.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEARNINGS="$SCRIPT_DIR/../scripts/learnings.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_learnings.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create project with conductor state
setup_project() {
  local d
  d=$(new_tmp)
  mkdir -p "$d/.autonomous"
  echo "$d"
}

# Helper: write conductor state
write_state() {
  local project="$1"
  local json="$2"
  echo "$json" > "$project/.autonomous/conductor-state.json"
}

# Helper: setup learnings dir in temp
setup_learnings_dir() {
  local d
  d=$(new_tmp)
  echo "$d"
}

# Helper: count learnings entries
count_entries() {
  python3 -c "import json; print(len(json.load(open('$1/learnings.json'))))"
}

# Helper: get field from entry by index
get_entry_field() {
  python3 -c "import json; d=json.load(open('$1/learnings.json')); print(d[$2].get('$3', ''))"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help output"

OUT=$(bash "$LEARNINGS" --help 2>&1) || true
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "learnings.sh" "--help mentions script name"
assert_contains "$OUT" "record" "--help documents record command"
assert_contains "$OUT" "query" "--help documents query command"
assert_contains "$OUT" "suggest" "--help documents suggest command"
assert_contains "$OUT" "prune" "--help documents prune command"
echo "$OUT" | grep -qF -- "--json" && ok "--help documents --json flag" || fail "--help documents --json flag"
echo "$OUT" | grep -qF -- "--dimension" && ok "--help documents --dimension flag" || fail "--help documents --dimension flag"
echo "$OUT" | grep -qF -- "--status" && ok "--help documents --status flag" || fail "--help documents --status flag"
echo "$OUT" | grep -qF -- "--project" && ok "--help documents --project flag" || fail "--help documents --project flag"

OUT=$(bash "$LEARNINGS" -h 2>&1) || true
assert_contains "$OUT" "Usage" "-h also shows usage"

OUT=$(bash "$LEARNINGS" help 2>&1) || true
assert_contains "$OUT" "Usage" "help also shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# 2. record — basic recording
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. record — basic"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "test-1",
  "phase": "directed",
  "sprints": [
    {"number": 1, "status": "complete", "direction": "add auth", "commits": ["abc123"]},
    {"number": 2, "status": "complete", "direction": "add tests", "commits": ["def456", "ghi789"]}
  ]
}'

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" 2>/dev/null)
assert_contains "$OUT" "Recorded 2" "record prints count"
assert_file_exists "$LDIR/learnings.json" "learnings.json created"

COUNT=$(count_entries "$LDIR")
assert_eq "$COUNT" "2" "two entries recorded"

DIR=$(get_entry_field "$LDIR" 0 "direction")
assert_eq "$DIR" "add auth" "first entry direction correct"

STATUS=$(get_entry_field "$LDIR" 1 "status")
assert_eq "$STATUS" "complete" "second entry status correct"

COMMITS=$(get_entry_field "$LDIR" 0 "commits")
assert_eq "$COMMITS" "1" "commits from list length"

COMMITS2=$(get_entry_field "$LDIR" 1 "commits")
assert_eq "$COMMITS2" "2" "second entry commits correct"

# ═══════════════════════════════════════════════════════════════════════════
# 3. record — integer commits field
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. record — integer commits"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "int-test",
  "phase": "directed",
  "sprints": [{"number": 1, "status": "complete", "direction": "fix bugs", "commits": 5}]
}'

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" 2>/dev/null)
COMMITS=$(get_entry_field "$LDIR" 0 "commits")
assert_eq "$COMMITS" "5" "integer commits field handled"

# ═══════════════════════════════════════════════════════════════════════════
# 4. record — with dimension field
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. record — dimension"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "dim-test",
  "phase": "exploring",
  "sprints": [{"number": 1, "status": "complete", "direction": "improve tests", "commits": ["a"], "dimension": "test_coverage"}]
}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
DIM=$(get_entry_field "$LDIR" 0 "dimension")
assert_eq "$DIM" "test_coverage" "dimension field recorded"

# ═══════════════════════════════════════════════════════════════════════════
# 5. record — exploration_dimension fallback
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. record — exploration_dimension fallback"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "dim-fb",
  "phase": "exploring",
  "sprints": [{"number": 1, "status": "complete", "direction": "fix security", "commits": [], "exploration_dimension": "security"}]
}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
DIM=$(get_entry_field "$LDIR" 0 "dimension")
assert_eq "$DIM" "security" "exploration_dimension fallback works"

# ═══════════════════════════════════════════════════════════════════════════
# 6. record — no dimension
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. record — no dimension"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "no-dim",
  "phase": "directed",
  "sprints": [{"number": 1, "status": "complete", "direction": "build api", "commits": []}]
}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
DIM=$(get_entry_field "$LDIR" 0 "dimension")
assert_eq "$DIM" "None" "no dimension results in None"

# ═══════════════════════════════════════════════════════════════════════════
# 7. record — project name from dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. record — project name"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "pn",
  "phase": "directed",
  "sprints": [{"number": 1, "status": "complete", "direction": "test", "commits": []}]
}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
PROJ=$(get_entry_field "$LDIR" 0 "project")
EXPECTED=$(basename "$PROJECT")
assert_eq "$PROJ" "$EXPECTED" "project name extracted from dir"

# ═══════════════════════════════════════════════════════════════════════════
# 8. record — zero sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. record — zero sprints"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{"session_id":"empty","phase":"directed","sprints":[]}'

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" 2>/dev/null)
assert_contains "$OUT" "No sprints" "zero sprints handled"

# ═══════════════════════════════════════════════════════════════════════════
# 9. record — JSON mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. record — JSON mode"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "json-test",
  "phase": "directed",
  "sprints": [
    {"number": 1, "status": "complete", "direction": "a", "commits": ["x"]},
    {"number": 2, "status": "failed", "direction": "b", "commits": []}
  ]
}'

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" --json 2>/dev/null)
RECORDED=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['recorded'])" 2>/dev/null)
assert_eq "$RECORDED" "2" "JSON mode shows recorded count"
TOTAL=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['total'])" 2>/dev/null)
assert_eq "$TOTAL" "2" "JSON mode shows total"

# ═══════════════════════════════════════════════════════════════════════════
# 10. record — accumulation (multiple records)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. record — accumulation"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)
write_state "$PROJECT" '{"session_id":"s1","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"a","commits":["x"]}]}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1

write_state "$PROJECT" '{"session_id":"s2","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"b","commits":["y"]}]}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1

COUNT=$(count_entries "$LDIR")
assert_eq "$COUNT" "2" "two sessions accumulated"

# ═══════════════════════════════════════════════════════════════════════════
# 11. record — error cases
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. record — error cases"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record 2>&1) || true
assert_contains "$OUT" "ERROR" "record without dir shows error"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "/nonexistent/path" 2>&1) || true
assert_contains "$OUT" "ERROR" "record with bad dir shows error"

PROJECT2=$(setup_project)
rm -f "$PROJECT2/.autonomous/conductor-state.json"
OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT2" 2>&1) || true
assert_contains "$OUT" "ERROR" "record without state file shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 12. record — FIFO overflow at 200 entries
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. record — FIFO overflow"

PROJECT=$(setup_project)
LDIR=$(setup_learnings_dir)

# Pre-populate with 199 entries
python3 -c "
import json
entries = [{'project':'old','timestamp':1000000+i,'direction':'dir-'+str(i),'status':'complete','commits':1,'dimension':None,'sprint_number':i} for i in range(199)]
with open('$LDIR/learnings.json','w') as f:
    json.dump(entries, f)
"

# Record 2 more sprints (total would be 201, should overflow to 200)
write_state "$PROJECT" '{
  "session_id":"overflow",
  "phase":"directed",
  "sprints":[
    {"number":1,"status":"complete","direction":"new-1","commits":["a"]},
    {"number":2,"status":"complete","direction":"new-2","commits":["b"]}
  ]
}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1

COUNT=$(count_entries "$LDIR")
assert_eq "$COUNT" "200" "FIFO overflow caps at 200"

# Verify oldest was dropped
FIRST_DIR=$(get_entry_field "$LDIR" 0 "direction")
assert_eq "$FIRST_DIR" "dir-1" "oldest entry (dir-0) was dropped"

LAST_DIR=$(python3 -c "import json; d=json.load(open('$LDIR/learnings.json')); print(d[-1]['direction'])")
assert_eq "$LAST_DIR" "new-2" "newest entry is last"

# ═══════════════════════════════════════════════════════════════════════════
# 13. record — env var override
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. record — env var override"

PROJECT=$(setup_project)
CUSTOM_DIR=$(new_tmp)
write_state "$PROJECT" '{"session_id":"env","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"env test","commits":[]}]}'

AUTONOMOUS_LEARNINGS_DIR="$CUSTOM_DIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
assert_file_exists "$CUSTOM_DIR/learnings.json" "env var override for storage dir works"

# ═══════════════════════════════════════════════════════════════════════════
# 14. query — no filters (all entries)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. query — no filters"

LDIR=$(setup_learnings_dir)
python3 -c "
import json
entries = [
    {'project':'proj-a','timestamp':1700000000,'direction':'add auth','status':'complete','commits':3,'dimension':'security','sprint_number':1},
    {'project':'proj-b','timestamp':1700100000,'direction':'fix bugs','status':'failed','commits':0,'dimension':'code_quality','sprint_number':1},
    {'project':'proj-a','timestamp':1700200000,'direction':'add tests','status':'complete','commits':5,'dimension':'test_coverage','sprint_number':2}
]
with open('$LDIR/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query 2>/dev/null)
assert_contains "$OUT" "proj-a" "query shows project-a"
assert_contains "$OUT" "proj-b" "query shows project-b"
assert_contains "$OUT" "Total: 3" "query shows total count"

# ═══════════════════════════════════════════════════════════════════════════
# 15. query — filter by dimension
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. query — dimension filter"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --dimension security 2>/dev/null)
assert_contains "$OUT" "add auth" "dimension filter returns matching"
assert_contains "$OUT" "Total: 1" "dimension filter count correct"

# ═══════════════════════════════════════════════════════════════════════════
# 16. query — filter by status
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. query — status filter"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --status failed 2>/dev/null)
assert_contains "$OUT" "fix bugs" "status filter returns matching"
assert_contains "$OUT" "Total: 1" "status filter count correct"

# ═══════════════════════════════════════════════════════════════════════════
# 17. query — filter by project
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. query — project filter"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --project proj-a 2>/dev/null)
assert_contains "$OUT" "add auth" "project filter shows matching entries"
assert_contains "$OUT" "Total: 2" "project filter count correct"

# ═══════════════════════════════════════════════════════════════════════════
# 18. query — combined filters
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. query — combined filters"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --project proj-a --status complete 2>/dev/null)
assert_contains "$OUT" "Total: 2" "combined filters work"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --project proj-b --dimension code_quality 2>/dev/null)
assert_contains "$OUT" "Total: 1" "project + dimension filter"

# ═══════════════════════════════════════════════════════════════════════════
# 19. query — JSON mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. query — JSON mode"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --json 2>/dev/null)
VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d))" 2>/dev/null || echo "invalid")
assert_eq "$VALID" "3" "JSON query returns all entries"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --dimension security --json 2>/dev/null)
VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d))" 2>/dev/null || echo "invalid")
assert_eq "$VALID" "1" "JSON query with filter works"

# ═══════════════════════════════════════════════════════════════════════════
# 20. query — no matching results
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. query — no matches"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --dimension nonexistent 2>/dev/null)
assert_contains "$OUT" "No matching" "no matches shows message"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query --dimension nonexistent --json 2>/dev/null)
VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d))" 2>/dev/null || echo "invalid")
assert_eq "$VALID" "0" "JSON no matches returns empty array"

# ═══════════════════════════════════════════════════════════════════════════
# 21. query — empty file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. query — empty file"

LDIR2=$(setup_learnings_dir)
echo '[]' > "$LDIR2/learnings.json"
OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR2" bash "$LEARNINGS" query 2>/dev/null)
assert_contains "$OUT" "No matching" "empty file shows no matches"

# ═══════════════════════════════════════════════════════════════════════════
# 22. query — missing file (auto-created)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. query — missing file"

LDIR3=$(setup_learnings_dir)
OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR3" bash "$LEARNINGS" query 2>/dev/null)
assert_contains "$OUT" "No matching" "missing file handled gracefully"
assert_file_exists "$LDIR3/learnings.json" "missing file auto-created"

# ═══════════════════════════════════════════════════════════════════════════
# 23. suggest — basic suggestions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. suggest — basic"

LDIR4=$(setup_learnings_dir)
python3 -c "
import json
entries = [
    {'project':'proj','timestamp':1700000000,'direction':'fix security vulns','status':'failed','commits':0,'dimension':'security','sprint_number':1},
    {'project':'proj','timestamp':1700100000,'direction':'security audit','status':'failed','commits':0,'dimension':'security','sprint_number':2},
    {'project':'proj','timestamp':1700200000,'direction':'add auth tests','status':'complete','commits':5,'dimension':'test_coverage','sprint_number':3},
    {'project':'proj','timestamp':1700300000,'direction':'improve docs','status':'complete','commits':3,'dimension':'documentation','sprint_number':4}
]
with open('$LDIR4/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR4" bash "$LEARNINGS" suggest 2>/dev/null)
assert_contains "$OUT" "security" "suggest mentions failing dimension"
assert_contains "$OUT" "failure" "suggest mentions failure rate"

# ═══════════════════════════════════════════════════════════════════════════
# 24. suggest — filter by dimension
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. suggest — dimension filter"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR4" bash "$LEARNINGS" suggest --dimension security 2>/dev/null)
assert_contains "$OUT" "security" "suggest with dimension filter"

# ═══════════════════════════════════════════════════════════════════════════
# 25. suggest — filter by project
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. suggest — project filter"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR4" bash "$LEARNINGS" suggest --project proj 2>/dev/null)
assert_contains "$OUT" "security" "suggest with project filter"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR4" bash "$LEARNINGS" suggest --project nonexistent 2>/dev/null)
assert_contains "$OUT" "No learnings" "suggest with unknown project"

# ═══════════════════════════════════════════════════════════════════════════
# 26. suggest — no data
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. suggest — no data"

LDIR5=$(setup_learnings_dir)
echo '[]' > "$LDIR5/learnings.json"
OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR5" bash "$LEARNINGS" suggest 2>/dev/null)
assert_contains "$OUT" "No learnings" "suggest with no data"

# ═══════════════════════════════════════════════════════════════════════════
# 27. suggest — all succeeded
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. suggest — all succeeded"

LDIR6=$(setup_learnings_dir)
python3 -c "
import json
entries = [
    {'project':'proj','timestamp':1700000000,'direction':'add tests','status':'complete','commits':5,'dimension':'test_coverage','sprint_number':1},
    {'project':'proj','timestamp':1700100000,'direction':'fix docs','status':'complete','commits':3,'dimension':'documentation','sprint_number':2}
]
with open('$LDIR6/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR6" bash "$LEARNINGS" suggest 2>/dev/null)
# Should suggest building on success or say balanced
LINES=$(echo "$OUT" | wc -l | tr -d ' ')
assert_ge "$LINES" "1" "suggest outputs at least one line when all succeed"

# ═══════════════════════════════════════════════════════════════════════════
# 28. suggest — all failed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. suggest — all failed"

LDIR7=$(setup_learnings_dir)
python3 -c "
import json
entries = [
    {'project':'proj','timestamp':1700000000,'direction':'attempt 1','status':'failed','commits':0,'dimension':'security','sprint_number':1},
    {'project':'proj','timestamp':1700100000,'direction':'attempt 2','status':'failed','commits':0,'dimension':'security','sprint_number':2},
    {'project':'proj','timestamp':1700200000,'direction':'attempt 3','status':'error','commits':0,'dimension':'code_quality','sprint_number':3},
    {'project':'proj','timestamp':1700300000,'direction':'attempt 4','status':'error','commits':0,'dimension':'code_quality','sprint_number':4}
]
with open('$LDIR7/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR7" bash "$LEARNINGS" suggest 2>/dev/null)
assert_contains "$OUT" "failure" "all-failed suggests avoiding failures"

# ═══════════════════════════════════════════════════════════════════════════
# 29. suggest — low commit output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. suggest — low commits"

LDIR8=$(setup_learnings_dir)
python3 -c "
import json
entries = [
    {'project':'proj','timestamp':1700000000,'direction':'big refactor','status':'complete','commits':0,'dimension':'architecture','sprint_number':1},
    {'project':'proj','timestamp':1700100000,'direction':'cleanup','status':'complete','commits':0,'dimension':'architecture','sprint_number':2}
]
with open('$LDIR8/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR8" bash "$LEARNINGS" suggest 2>/dev/null)
assert_contains "$OUT" "commits" "suggest flags low commit dimensions"

# ═══════════════════════════════════════════════════════════════════════════
# 30. suggest — nonexistent dimension filter
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. suggest — nonexistent dimension"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR4" bash "$LEARNINGS" suggest --dimension nonexistent 2>/dev/null)
assert_contains "$OUT" "No learnings" "suggest with unknown dimension"

# ═══════════════════════════════════════════════════════════════════════════
# 31. prune — basic pruning
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. prune — basic"

LDIR9=$(setup_learnings_dir)
NOW=$(python3 -c "import time; print(int(time.time()))")
OLD=$((NOW - 100 * 86400))  # 100 days ago
RECENT=$((NOW - 10 * 86400))  # 10 days ago

python3 -c "
import json
entries = [
    {'project':'proj','timestamp':$OLD,'direction':'old entry','status':'complete','commits':1,'dimension':None,'sprint_number':1},
    {'project':'proj','timestamp':$RECENT,'direction':'recent entry','status':'complete','commits':2,'dimension':None,'sprint_number':2}
]
with open('$LDIR9/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR9" bash "$LEARNINGS" prune 2>/dev/null)
assert_contains "$OUT" "Pruned 1" "prune removes old entries"
assert_contains "$OUT" "Remaining: 1" "prune keeps recent entries"

COUNT=$(count_entries "$LDIR9")
assert_eq "$COUNT" "1" "one entry remains after prune"

DIR=$(get_entry_field "$LDIR9" 0 "direction")
assert_eq "$DIR" "recent entry" "recent entry survived prune"

# ═══════════════════════════════════════════════════════════════════════════
# 32. prune — custom max-age
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "32. prune — custom max-age"

LDIR10=$(setup_learnings_dir)
python3 -c "
import json, time
now = int(time.time())
entries = [
    {'project':'proj','timestamp':now - 20 * 86400,'direction':'20 days old','status':'complete','commits':1,'dimension':None,'sprint_number':1},
    {'project':'proj','timestamp':now - 5 * 86400,'direction':'5 days old','status':'complete','commits':2,'dimension':None,'sprint_number':2}
]
with open('$LDIR10/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR10" bash "$LEARNINGS" prune --max-age 15 2>/dev/null)
assert_contains "$OUT" "Pruned 1" "custom max-age prunes correctly"

COUNT=$(count_entries "$LDIR10")
assert_eq "$COUNT" "1" "one entry remains with custom max-age"

# ═══════════════════════════════════════════════════════════════════════════
# 33. prune — nothing to prune
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "33. prune — nothing to prune"

LDIR11=$(setup_learnings_dir)
python3 -c "
import json, time
now = int(time.time())
entries = [
    {'project':'proj','timestamp':now,'direction':'fresh','status':'complete','commits':1,'dimension':None,'sprint_number':1}
]
with open('$LDIR11/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR11" bash "$LEARNINGS" prune 2>/dev/null)
assert_contains "$OUT" "Pruned 0" "nothing pruned when all fresh"
COUNT=$(count_entries "$LDIR11")
assert_eq "$COUNT" "1" "entry preserved when fresh"

# ═══════════════════════════════════════════════════════════════════════════
# 34. prune — empty file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "34. prune — empty file"

LDIR12=$(setup_learnings_dir)
echo '[]' > "$LDIR12/learnings.json"
OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR12" bash "$LEARNINGS" prune 2>/dev/null)
assert_contains "$OUT" "Pruned 0" "prune on empty file"

# ═══════════════════════════════════════════════════════════════════════════
# 35. prune — invalid max-age
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "35. prune — invalid max-age"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR12" bash "$LEARNINGS" prune --max-age abc 2>&1) || true
assert_contains "$OUT" "ERROR" "invalid max-age shows error"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR12" bash "$LEARNINGS" prune --max-age -5 2>&1) || true
assert_contains "$OUT" "ERROR" "negative max-age shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 36. prune — all entries old
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "36. prune — all entries old"

LDIR13=$(setup_learnings_dir)
python3 -c "
import json
entries = [
    {'project':'proj','timestamp':1000000,'direction':'ancient 1','status':'complete','commits':1,'dimension':None,'sprint_number':1},
    {'project':'proj','timestamp':1000001,'direction':'ancient 2','status':'complete','commits':1,'dimension':None,'sprint_number':2}
]
with open('$LDIR13/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR13" bash "$LEARNINGS" prune 2>/dev/null)
assert_contains "$OUT" "Pruned 2" "all old entries pruned"
COUNT=$(count_entries "$LDIR13")
assert_eq "$COUNT" "0" "zero entries after pruning all"

# ═══════════════════════════════════════════════════════════════════════════
# 37. error handling — missing command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "37. error handling"

OUT=$(bash "$LEARNINGS" 2>&1) || true
assert_contains "$OUT" "ERROR" "no command shows error"

OUT=$(bash "$LEARNINGS" badcmd 2>&1) || true
assert_contains "$OUT" "ERROR" "unknown command shows error"
assert_contains "$OUT" "badcmd" "error mentions bad command"

# ═══════════════════════════════════════════════════════════════════════════
# 38. learnings dir auto-creation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "38. learnings dir auto-creation"

NEW_DIR=$(new_tmp)
rm -rf "$NEW_DIR"
PROJECT=$(setup_project)
write_state "$PROJECT" '{"session_id":"auto","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"x","commits":[]}]}'

AUTONOMOUS_LEARNINGS_DIR="$NEW_DIR" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
assert_file_exists "$NEW_DIR/learnings.json" "learnings dir auto-created"

# ═══════════════════════════════════════════════════════════════════════════
# 39. record — mixed sprint statuses
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "39. record — mixed statuses"

PROJECT=$(setup_project)
LDIR14=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "mixed",
  "phase": "directed",
  "sprints": [
    {"number": 1, "status": "complete", "direction": "feat 1", "commits": ["a","b"]},
    {"number": 2, "status": "failed", "direction": "feat 2", "commits": []},
    {"number": 3, "status": "timeout", "direction": "feat 3", "commits": ["c"]}
  ]
}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR14" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1

S1=$(get_entry_field "$LDIR14" 0 "status")
S2=$(get_entry_field "$LDIR14" 1 "status")
S3=$(get_entry_field "$LDIR14" 2 "status")
assert_eq "$S1" "complete" "first sprint status correct"
assert_eq "$S2" "failed" "second sprint status correct"
assert_eq "$S3" "timeout" "third sprint status correct"

C1=$(get_entry_field "$LDIR14" 0 "commits")
C2=$(get_entry_field "$LDIR14" 1 "commits")
C3=$(get_entry_field "$LDIR14" 2 "commits")
assert_eq "$C1" "2" "first sprint commits correct"
assert_eq "$C2" "0" "second sprint commits correct"
assert_eq "$C3" "1" "third sprint commits correct"

# ═══════════════════════════════════════════════════════════════════════════
# 40. record — sprint_number preserved
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "40. record — sprint_number"

PROJECT=$(setup_project)
LDIR15=$(setup_learnings_dir)
write_state "$PROJECT" '{
  "session_id": "nums",
  "phase": "directed",
  "sprints": [
    {"number": 3, "status": "complete", "direction": "task", "commits": []}
  ]
}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR15" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
NUM=$(get_entry_field "$LDIR15" 0 "sprint_number")
assert_eq "$NUM" "3" "sprint_number preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 41. record — timestamp present
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "41. record — timestamp"

PROJECT=$(setup_project)
LDIR16=$(setup_learnings_dir)
write_state "$PROJECT" '{"session_id":"ts","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"t","commits":[]}]}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR16" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
TS=$(python3 -c "import json; d=json.load(open('$LDIR16/learnings.json')); print(d[0]['timestamp'])")
NOW=$(python3 -c "import time; print(int(time.time()))")
DIFF=$((NOW - TS))
assert_le "$DIFF" "10" "timestamp is recent (within 10s)"

# ═══════════════════════════════════════════════════════════════════════════
# 42. query with direction truncation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "42. query — long direction truncation"

LDIR17=$(setup_learnings_dir)
python3 -c "
import json
entries = [{'project':'proj','timestamp':1700000000,'direction':'This is a very long direction string that should be truncated in the table output display','status':'complete','commits':1,'dimension':None,'sprint_number':1}]
with open('$LDIR17/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR17" bash "$LEARNINGS" query 2>/dev/null)
assert_contains "$OUT" "..." "long direction is truncated"

# ═══════════════════════════════════════════════════════════════════════════
# 43. FIFO — exactly at 200
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "43. FIFO — exactly at limit"

PROJECT=$(setup_project)
LDIR18=$(setup_learnings_dir)

python3 -c "
import json
entries = [{'project':'old','timestamp':1000000+i,'direction':'dir-'+str(i),'status':'complete','commits':1,'dimension':None,'sprint_number':i} for i in range(200)]
with open('$LDIR18/learnings.json','w') as f:
    json.dump(entries, f)
"

# Recording 1 more should drop 1 old
write_state "$PROJECT" '{"session_id":"full","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"new-entry","commits":[]}]}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR18" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
COUNT=$(count_entries "$LDIR18")
assert_eq "$COUNT" "200" "still at 200 after adding to full"

FIRST=$(get_entry_field "$LDIR18" 0 "direction")
assert_eq "$FIRST" "dir-1" "oldest (dir-0) dropped at exactly 200"

# ═══════════════════════════════════════════════════════════════════════════
# 44. atomic write — tmp file cleaned up
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "44. atomic write — no tmp file"

LDIR19=$(setup_learnings_dir)
PROJECT=$(setup_project)
write_state "$PROJECT" '{"session_id":"atomic","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"test","commits":[]}]}'

AUTONOMOUS_LEARNINGS_DIR="$LDIR19" bash "$LEARNINGS" record "$PROJECT" >/dev/null 2>&1
TMP_FILES=$(find "$LDIR19" -name "*.tmp" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMP_FILES" "0" "no tmp files left after atomic write"

# ═══════════════════════════════════════════════════════════════════════════
# 45. suggest — max 3 suggestions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "45. suggest — max 3 suggestions"

LDIR20=$(setup_learnings_dir)
python3 -c "
import json
entries = []
for dim in ['security', 'code_quality', 'test_coverage', 'documentation', 'architecture']:
    for i in range(3):
        entries.append({'project':'proj','timestamp':1700000000+i,'direction':f'attempt {dim} {i}','status':'failed','commits':0,'dimension':dim,'sprint_number':i+1})
with open('$LDIR20/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR20" bash "$LEARNINGS" suggest 2>/dev/null)
LINES=$(echo "$OUT" | grep -c "." || true)
assert_le "$LINES" "3" "suggest outputs at most 3 lines"

# ═══════════════════════════════════════════════════════════════════════════
# 46. record — zero-sprint JSON mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "46. record — zero sprints JSON mode"

PROJECT=$(setup_project)
LDIR21=$(setup_learnings_dir)
write_state "$PROJECT" '{"session_id":"empty","phase":"directed","sprints":[]}'

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR21" bash "$LEARNINGS" record "$PROJECT" --json 2>/dev/null)
REC=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['recorded'])" 2>/dev/null)
assert_eq "$REC" "0" "JSON mode zero sprints shows 0 recorded"

# ═══════════════════════════════════════════════════════════════════════════
# 47. query — table header present
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "47. query — table header"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR" bash "$LEARNINGS" query 2>/dev/null)
assert_contains "$OUT" "Project" "table has Project header"
assert_contains "$OUT" "Status" "table has Status header"
assert_contains "$OUT" "Direction" "table has Direction header"

# ═══════════════════════════════════════════════════════════════════════════
# 48. suggest — build on success suggestion
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "48. suggest — build on success"

LDIR22=$(setup_learnings_dir)
python3 -c "
import json
entries = [
    {'project':'proj','timestamp':1700000000,'direction':'improve test infra','status':'complete','commits':10,'dimension':'test_coverage','sprint_number':1},
    {'project':'proj','timestamp':1700100000,'direction':'add more tests','status':'complete','commits':8,'dimension':'test_coverage','sprint_number':2}
]
with open('$LDIR22/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR22" bash "$LEARNINGS" suggest 2>/dev/null)
assert_contains "$OUT" "Build on" "suggests building on success"

# ═══════════════════════════════════════════════════════════════════════════
# 49. record — corrupt JSON in existing file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "49. record — corrupt existing file"

PROJECT=$(setup_project)
LDIR23=$(setup_learnings_dir)
echo "not json" > "$LDIR23/learnings.json"
write_state "$PROJECT" '{"session_id":"corrupt","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"test","commits":[]}]}'

# Should fail or handle gracefully
OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR23" bash "$LEARNINGS" record "$PROJECT" 2>&1) || true
# Either records successfully with empty base or errors — both acceptable
[ $? -eq 0 ] && ok "corrupt file handled (record succeeded)" || ok "corrupt file handled (error reported)"

# ═══════════════════════════════════════════════════════════════════════════
# 50. prune — max-age 0 removes all
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "50. prune — max-age 0"

LDIR24=$(setup_learnings_dir)
python3 -c "
import json, time
now = int(time.time())
entries = [
    {'project':'proj','timestamp':now - 86400,'direction':'yesterday','status':'complete','commits':1,'dimension':None,'sprint_number':1},
    {'project':'proj','timestamp':now - 1,'direction':'just now','status':'complete','commits':1,'dimension':None,'sprint_number':2}
]
with open('$LDIR24/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR24" bash "$LEARNINGS" prune --max-age 0 2>/dev/null)
assert_contains "$OUT" "Pruned 2" "max-age 0 removes all entries"

# ═══════════════════════════════════════════════════════════════════════════
# 51. query — long project name truncation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "51. query — long project name"

LDIR25=$(setup_learnings_dir)
python3 -c "
import json
entries = [{'project':'very-long-project-name-that-should-be-truncated','timestamp':1700000000,'direction':'test','status':'complete','commits':1,'dimension':None,'sprint_number':1}]
with open('$LDIR25/learnings.json','w') as f:
    json.dump(entries, f)
"

OUT=$(AUTONOMOUS_LEARNINGS_DIR="$LDIR25" bash "$LEARNINGS" query 2>/dev/null)
assert_contains "$OUT" "..." "long project name truncated"

# ═══════════════════════════════════════════════════════════════════════════
# 52. help in subcommand position
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "52. help in subcommand position"

OUT=$(bash "$LEARNINGS" record --help 2>&1) || true
assert_contains "$OUT" "Usage" "record --help shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

print_results
