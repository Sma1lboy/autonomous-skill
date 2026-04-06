#!/usr/bin/env bash
# Tests for scripts/metrics.sh — cross-session metrics dashboard.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS="$SCRIPT_DIR/../scripts/metrics.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_metrics.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create project with conductor state
setup_project() {
  local d
  d=$(new_tmp)
  git -C "$d" init -q 2>/dev/null || true
  mkdir -p "$d/.autonomous"
  echo "$d"
}

# Helper: write conductor state
write_state() {
  local project="$1"
  local json="$2"
  echo "$json" > "$project/.autonomous/conductor-state.json"
}

# Helper: setup metrics dir in temp
setup_metrics_dir() {
  local d
  d=$(new_tmp)
  echo "$d"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help output"

OUT=$(bash "$METRICS" --help 2>&1) || true
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "metrics.sh" "--help mentions script name"
assert_contains "$OUT" "collect" "--help documents collect command"
assert_contains "$OUT" "show" "--help documents show command"
assert_contains "$OUT" "trend" "--help documents trend command"
echo "$OUT" | grep -qF -- "--json" && ok "--help documents --json flag" || fail "--help documents --json flag"
echo "$OUT" | grep -qF -- "--project" && ok "--help documents --project flag" || fail "--help documents --project flag"

OUT=$(bash "$METRICS" -h 2>&1) || true
assert_contains "$OUT" "Usage" "-h also shows usage"

OUT=$(bash "$METRICS" help 2>&1) || true
assert_contains "$OUT" "Usage" "help also shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# 2. collect — basic metrics collection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. collect command — basic"

PROJECT=$(setup_project)
MDIR=$(setup_metrics_dir)
write_state "$PROJECT" '{
  "session_id": "test-1",
  "phase": "directed",
  "max_sprints": 5,
  "session_cost_usd": 1.50,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "add auth", "commits": ["abc123"], "cost_usd": 0.75},
    {"number": 2, "status": "complete", "direction": "add tests", "commits": ["def456", "ghi789"], "cost_usd": 0.75}
  ]
}'

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" collect "$PROJECT" 2>/dev/null)
assert_contains "$OUT" "Collected" "collect prints confirmation"
assert_contains "$OUT" "Sprints: 2" "collect shows sprint count"
assert_contains "$OUT" "Commits: 3" "collect shows commit count"
assert_contains "$OUT" "1.5000" "collect shows cost"
assert_contains "$OUT" "100%" "collect shows 100% success rate"

# Verify metrics file was created
assert_file_exists "$MDIR/metrics.json" "metrics.json created"

# Verify JSON content
ENTRY=$(python3 -c "
import json
with open('$MDIR/metrics.json') as f:
    d = json.load(f)
print(len(d))
print(d[0]['sprints'])
print(d[0]['commits'])
print(d[0]['cost_usd'])
")
LINES=$(echo "$ENTRY" | head -1)
assert_eq "$LINES" "1" "one session entry recorded"
SPRINTS=$(echo "$ENTRY" | sed -n '2p')
assert_eq "$SPRINTS" "2" "sprints count correct in JSON"
COMMITS=$(echo "$ENTRY" | sed -n '3p')
assert_eq "$COMMITS" "3" "commits count correct in JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 3. collect — JSON mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. collect — JSON output"

PROJECT=$(setup_project)
MDIR=$(setup_metrics_dir)
write_state "$PROJECT" '{
  "session_id": "json-test",
  "phase": "exploring",
  "session_cost_usd": 2.00,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "fix bugs", "commits": ["a1"]},
    {"number": 2, "status": "failed", "direction": "add feature", "commits": []}
  ]
}'

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" collect "$PROJECT" --json 2>/dev/null)
VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['sprints'])" 2>/dev/null || echo "invalid")
assert_eq "$VALID" "2" "JSON output is valid with correct sprints"

SR=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['success_rate'])" 2>/dev/null || echo "invalid")
assert_eq "$SR" "0.5" "success rate 0.5 with 1/2 complete"

# ═══════════════════════════════════════════════════════════════════════════
# 4. collect — missing state file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. collect — error cases"

PROJECT=$(setup_project)
MDIR=$(setup_metrics_dir)
rm -f "$PROJECT/.autonomous/conductor-state.json"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" collect "$PROJECT" 2>&1) || true
assert_contains "$OUT" "ERROR" "collect fails without state file"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" collect "/nonexistent/path" 2>&1) || true
assert_contains "$OUT" "ERROR" "collect fails with bad project dir"

# ═══════════════════════════════════════════════════════════════════════════
# 5. collect — zero sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. collect — edge cases"

PROJECT=$(setup_project)
MDIR=$(setup_metrics_dir)
write_state "$PROJECT" '{"session_id":"empty","phase":"directed","sprints":[]}'

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" collect "$PROJECT" 2>/dev/null)
assert_contains "$OUT" "Sprints: 0" "zero sprints handled"
assert_contains "$OUT" "Commits: 0" "zero commits with no sprints"

# ═══════════════════════════════════════════════════════════════════════════
# 6. collect — dimensions improved
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. collect — dimensions"

PROJECT=$(setup_project)
MDIR=$(setup_metrics_dir)
write_state "$PROJECT" '{
  "session_id": "dims-test",
  "phase": "exploring",
  "sprints": [{"number": 1, "status": "complete", "direction": "test", "commits": []}],
  "exploration_dimensions": {
    "test_coverage": {"audited": true, "score": 7},
    "security": {"audited": false, "score": 3},
    "dx": {"audited": true, "score": 8}
  }
}'

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" collect "$PROJECT" --json 2>/dev/null)
DIMS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['dimensions_improved']))" 2>/dev/null)
assert_eq "$DIMS" "2" "two audited dimensions detected"

# ═══════════════════════════════════════════════════════════════════════════
# 7. collect — accumulation (multiple sessions)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. collect — accumulation"

PROJECT=$(setup_project)
MDIR=$(setup_metrics_dir)
write_state "$PROJECT" '{"session_id":"s1","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"a","commits":["x"]}],"session_cost_usd":1.0}'

AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" collect "$PROJECT" >/dev/null 2>&1

write_state "$PROJECT" '{"session_id":"s2","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"b","commits":["y","z"]}],"session_cost_usd":2.0}'

AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" collect "$PROJECT" >/dev/null 2>&1

COUNT=$(python3 -c "import json; d=json.load(open('$MDIR/metrics.json')); print(len(d))")
assert_eq "$COUNT" "2" "two sessions accumulated"

# ═══════════════════════════════════════════════════════════════════════════
# 8. show — basic dashboard
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. show command — basic"

MDIR=$(setup_metrics_dir)
echo '[
  {"project":"proj-a","branch":"auto/s1","timestamp":1700000000,"sprints":3,"commits":10,"files_changed":5,"cost_usd":1.50,"success_rate":1.0,"tests_added":2,"dimensions_improved":["test_coverage"]},
  {"project":"proj-b","branch":"auto/s2","timestamp":1700100000,"sprints":2,"commits":4,"files_changed":3,"cost_usd":0.80,"success_rate":0.5,"tests_added":0,"dimensions_improved":[]}
]' > "$MDIR/metrics.json"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" show 2>/dev/null)
assert_contains "$OUT" "Dashboard" "show prints dashboard header"
assert_contains "$OUT" "Sessions:" "show displays sessions count"
assert_contains "$OUT" "2" "show shows 2 sessions"
assert_contains "$OUT" "5" "show shows total sprints"
assert_contains "$OUT" "14" "show shows total commits"

# ═══════════════════════════════════════════════════════════════════════════
# 9. show — JSON output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. show — JSON output"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" show --json 2>/dev/null)
SESSIONS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['total_sessions'])" 2>/dev/null)
assert_eq "$SESSIONS" "2" "JSON show has correct total_sessions"

COST=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['total_cost_usd'])" 2>/dev/null)
assert_eq "$COST" "2.3" "JSON show has correct total cost"

# ═══════════════════════════════════════════════════════════════════════════
# 10. show — project filter
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. show — project filter"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" show --project proj-a 2>/dev/null)
assert_contains "$OUT" "proj-a" "filtered show mentions project"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" show --json --project proj-a 2>/dev/null)
SESSIONS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['total_sessions'])" 2>/dev/null)
assert_eq "$SESSIONS" "1" "filtered JSON show has 1 session"

FILTER=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d.get('filter',''))" 2>/dev/null)
assert_eq "$FILTER" "proj-a" "JSON output includes filter field"

# ═══════════════════════════════════════════════════════════════════════════
# 11. show — empty metrics
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. show — empty metrics"

MDIR2=$(setup_metrics_dir)
echo '[]' > "$MDIR2/metrics.json"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR2" bash "$METRICS" show 2>/dev/null)
assert_contains "$OUT" "No metrics" "show handles empty metrics"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR2" bash "$METRICS" show --json 2>/dev/null)
assert_contains "$OUT" '"sessions": 0' "JSON show handles empty"

# ═══════════════════════════════════════════════════════════════════════════
# 12. show — nonexistent project filter
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. show — nonexistent project filter"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" show --project nonexistent 2>/dev/null)
assert_contains "$OUT" "No metrics" "show with unknown project shows no data"

# ═══════════════════════════════════════════════════════════════════════════
# 13. trend — basic output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. trend command — basic"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" trend 2>/dev/null)
assert_contains "$OUT" "Trends" "trend prints header"
assert_contains "$OUT" "Week" "trend shows week column"

# ═══════════════════════════════════════════════════════════════════════════
# 14. trend — JSON output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. trend — JSON output"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" trend --json 2>/dev/null)
VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d))" 2>/dev/null || echo "invalid")
[ "$VALID" != "invalid" ] && ok "trend JSON is valid" || fail "trend JSON is invalid"

# ═══════════════════════════════════════════════════════════════════════════
# 15. trend — project filter
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. trend — project filter"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR" bash "$METRICS" trend --project proj-a 2>/dev/null)
assert_contains "$OUT" "proj-a" "trend filter shows project name"

# ═══════════════════════════════════════════════════════════════════════════
# 16. trend — empty metrics
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. trend — empty metrics"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR2" bash "$METRICS" trend 2>/dev/null)
assert_contains "$OUT" "No metrics" "trend handles empty metrics"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR2" bash "$METRICS" trend --json 2>/dev/null)
assert_contains "$OUT" "weeks" "trend JSON handles empty"

# ═══════════════════════════════════════════════════════════════════════════
# 17. error handling — missing command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. error handling"

OUT=$(bash "$METRICS" 2>&1) || true
assert_contains "$OUT" "ERROR" "no command shows error"

OUT=$(bash "$METRICS" badcmd 2>&1) || true
assert_contains "$OUT" "ERROR" "unknown command shows error"
assert_contains "$OUT" "badcmd" "error mentions bad command"

# ═══════════════════════════════════════════════════════════════════════════
# 18. collect — cost from sprints fallback
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. collect — cost fallback"

PROJECT=$(setup_project)
MDIR3=$(setup_metrics_dir)
write_state "$PROJECT" '{
  "session_id":"cost-fallback",
  "phase":"directed",
  "sprints":[
    {"number":1,"status":"complete","direction":"a","commits":[],"cost_usd":0.50},
    {"number":2,"status":"complete","direction":"b","commits":[],"cost_usd":0.30}
  ]
}'

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR3" bash "$METRICS" collect "$PROJECT" --json 2>/dev/null)
COST=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['cost_usd'])" 2>/dev/null)
assert_eq "$COST" "0.8" "cost fallback sums sprint costs"

# ═══════════════════════════════════════════════════════════════════════════
# 19. metrics dir auto-creation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. metrics dir auto-creation"

MDIR4=$(new_tmp)
rm -rf "$MDIR4"
PROJECT=$(setup_project)
write_state "$PROJECT" '{"session_id":"auto-dir","phase":"directed","sprints":[{"number":1,"status":"complete","direction":"x","commits":[]}]}'

AUTONOMOUS_METRICS_DIR="$MDIR4" bash "$METRICS" collect "$PROJECT" >/dev/null 2>&1
assert_file_exists "$MDIR4/metrics.json" "metrics dir auto-created"

# ═══════════════════════════════════════════════════════════════════════════
# 20. show — multiple projects breakdown
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. show — multi-project breakdown"

MDIR5=$(setup_metrics_dir)
echo '[
  {"project":"alpha","branch":"auto/1","timestamp":1700000000,"sprints":2,"commits":5,"files_changed":3,"cost_usd":1.0,"success_rate":1.0,"tests_added":1,"dimensions_improved":[]},
  {"project":"beta","branch":"auto/2","timestamp":1700100000,"sprints":3,"commits":8,"files_changed":6,"cost_usd":2.0,"success_rate":0.67,"tests_added":2,"dimensions_improved":[]},
  {"project":"alpha","branch":"auto/3","timestamp":1700200000,"sprints":1,"commits":2,"files_changed":1,"cost_usd":0.5,"success_rate":1.0,"tests_added":0,"dimensions_improved":[]}
]' > "$MDIR5/metrics.json"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR5" bash "$METRICS" show 2>/dev/null)
assert_contains "$OUT" "alpha" "multi-project shows alpha"
assert_contains "$OUT" "beta" "multi-project shows beta"
assert_contains "$OUT" "Project" "multi-project shows table header"

# ═══════════════════════════════════════════════════════════════════════════
# 21. collect — integer commits field
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. collect — integer commits"

PROJECT=$(setup_project)
MDIR6=$(setup_metrics_dir)
write_state "$PROJECT" '{
  "session_id":"int-commits",
  "phase":"directed",
  "sprints":[{"number":1,"status":"complete","direction":"a","commits":5}]
}'

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR6" bash "$METRICS" collect "$PROJECT" --json 2>/dev/null)
COMMITS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['commits'])" 2>/dev/null)
assert_eq "$COMMITS" "5" "integer commits field handled"

# ═══════════════════════════════════════════════════════════════════════════
# 22. show — avg calculations
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. show — avg calculations"

OUT=$(AUTONOMOUS_METRICS_DIR="$MDIR5" bash "$METRICS" show --json 2>/dev/null)
AVG_SR=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['avg_success_rate'])" 2>/dev/null)
assert_eq "$AVG_SR" "0.89" "avg success rate calculated"

AVG_CPS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['avg_commits_per_sprint'])" 2>/dev/null)
assert_eq "$AVG_CPS" "2.5" "avg commits per sprint calculated"

# ═══════════════════════════════════════════════════════════════════════════
# 23. collect — missing project-dir arg
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. collect — missing args"

OUT=$(bash "$METRICS" collect 2>&1) || true
assert_contains "$OUT" "ERROR" "collect without dir shows error"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

print_results
