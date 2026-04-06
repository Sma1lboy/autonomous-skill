#!/usr/bin/env bash
# Tests for scripts/progress-reporter.sh, scripts/autonomous-status.sh,
# and the conductor-state.sh progress command.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS="$SCRIPT_DIR/../scripts/progress-reporter.sh"
STATUS="$SCRIPT_DIR/../scripts/autonomous-status.sh"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_progress_reporter.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create project with conductor state
setup_project() {
  local d
  d=$(new_tmp)
  mkdir -p "$d/.autonomous"
  echo "$d"
}

# Helper: write conductor state JSON
write_state() {
  local project="$1" json="$2"
  echo "$json" > "$project/.autonomous/conductor-state.json"
}

# Helper: write progress JSON
write_progress() {
  local project="$1" json="$2"
  echo "$json" > "$project/.autonomous/progress.json"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. progress-reporter.sh --help
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. progress-reporter.sh --help"

OUT=$(bash "$PROGRESS" --help 2>&1) || true
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "progress-reporter" "--help mentions script name"
assert_contains "$OUT" "update" "--help documents update command"
assert_contains "$OUT" "read" "--help documents read command"
assert_contains "$OUT" "watch" "--help documents --watch command"

# ═══════════════════════════════════════════════════════════════════════════
# 2. progress-reporter.sh update — basic
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. progress-reporter.sh update — basic"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "session_id": "conductor-100",
  "mission": "build REST API",
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "scaffold", "commits": ["abc1234 init project"], "summary": "scaffolded Express project"},
    {"number": 2, "status": "complete", "direction": "add routes", "commits": ["def5678 add routes", "ghi9012 add tests"], "summary": "added CRUD routes"}
  ],
  "consecutive_complete": 0,
  "consecutive_zero_commits": 0
}'

OUT=$(bash "$PROGRESS" update "$PROJECT")
assert_eq "$OUT" "ok" "update returns ok"
assert_file_exists "$PROJECT/.autonomous/progress.json" "progress.json created"

# Validate JSON content
VALID=$(python3 -c "
import json
d = json.load(open('$PROJECT/.autonomous/progress.json'))
assert d['current_sprint'] == 2, f'current_sprint: {d[\"current_sprint\"]}'
assert d['total_sprints'] == 5, f'total_sprints: {d[\"total_sprints\"]}'
assert d['phase'] == 'directed', f'phase: {d[\"phase\"]}'
assert d['commits_so_far'] == 3, f'commits_so_far: {d[\"commits_so_far\"]}'
assert d['last_sprint_summary'] == 'added CRUD routes'
assert d['estimated_time_remaining'] is None
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "progress.json has correct field values"

# ═══════════════════════════════════════════════════════════════════════════
# 3. progress-reporter.sh update — empty sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. progress-reporter.sh update — empty sprints"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "session_id": "conductor-200",
  "mission": "explore",
  "phase": "directed",
  "max_sprints": 3,
  "sprints": []
}'

OUT=$(bash "$PROGRESS" update "$PROJECT")
assert_eq "$OUT" "ok" "update with empty sprints returns ok"

VALID=$(python3 -c "
import json
d = json.load(open('$PROJECT/.autonomous/progress.json'))
assert d['current_sprint'] == 0
assert d['total_sprints'] == 3
assert d['commits_so_far'] == 0
assert d['last_sprint_summary'] == ''
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "empty sprints produce correct zero values"

# ═══════════════════════════════════════════════════════════════════════════
# 4. progress-reporter.sh update — exploring phase
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. progress-reporter.sh update — exploring phase"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "session_id": "conductor-300",
  "mission": "improve",
  "phase": "exploring",
  "max_sprints": 10,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "d1", "commits": ["a1"], "summary": "done1"},
    {"number": 2, "status": "complete", "direction": "d2", "commits": [], "summary": "nothing found"},
    {"number": 3, "status": "running", "direction": "d3", "commits": ["b1", "b2"], "summary": ""}
  ]
}'

bash "$PROGRESS" update "$PROJECT" > /dev/null
VALID=$(python3 -c "
import json
d = json.load(open('$PROJECT/.autonomous/progress.json'))
assert d['phase'] == 'exploring'
assert d['current_sprint'] == 3
assert d['total_sprints'] == 10
assert d['commits_so_far'] == 3
# Last sprint with non-empty summary is sprint 2
assert d['last_sprint_summary'] == 'nothing found'
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "exploring phase with mid-sprint produces correct values"

# ═══════════════════════════════════════════════════════════════════════════
# 5. progress-reporter.sh update — missing state file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. progress-reporter.sh update — missing state file"

PROJECT=$(setup_project)
OUT=$(bash "$PROGRESS" update "$PROJECT" 2>&1) || true
assert_contains "$OUT" "No conductor-state.json" "missing state file gives error"

# ═══════════════════════════════════════════════════════════════════════════
# 6. progress-reporter.sh read — basic
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. progress-reporter.sh read — basic"

PROJECT=$(setup_project)
write_progress "$PROJECT" '{"current_sprint":2,"total_sprints":5,"phase":"directed","last_sprint_summary":"added auth","commits_so_far":4,"estimated_time_remaining":null}'

OUT=$(bash "$PROGRESS" read "$PROJECT")
assert_contains "$OUT" "current_sprint" "read outputs current_sprint"
assert_contains "$OUT" "total_sprints" "read outputs total_sprints"
assert_contains "$OUT" "directed" "read outputs phase"
assert_contains "$OUT" "added auth" "read outputs last_sprint_summary"

# ═══════════════════════════════════════════════════════════════════════════
# 7. progress-reporter.sh read — missing progress.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. progress-reporter.sh read — missing progress.json"

PROJECT=$(setup_project)
OUT=$(bash "$PROGRESS" read "$PROJECT" 2>&1) || true
assert_contains "$OUT" "No progress.json" "missing progress.json gives error"

# ═══════════════════════════════════════════════════════════════════════════
# 8. progress-reporter.sh --watch — exits when no progress.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. progress-reporter.sh --watch — no progress.json"

PROJECT=$(setup_project)
OUT=$(bash "$PROGRESS" --watch "$PROJECT" 2>&1) || true
assert_contains "$OUT" "No progress data" "--watch exits cleanly when no progress.json"

# ═══════════════════════════════════════════════════════════════════════════
# 9. progress-reporter.sh --watch — prints status line
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. progress-reporter.sh --watch — prints status then detects done"

PROJECT=$(setup_project)
# Write progress file
write_progress "$PROJECT" '{"current_sprint":5,"total_sprints":5,"phase":"exploring","last_sprint_summary":"improved docs","commits_so_far":12,"estimated_time_remaining":null}'
# Write state file showing all sprints complete
write_state "$PROJECT" '{
  "phase": "exploring",
  "max_sprints": 5,
  "sprints": [
    {"number":1,"status":"complete","commits":["a"],"summary":"s1"},
    {"number":2,"status":"complete","commits":["b"],"summary":"s2"},
    {"number":3,"status":"complete","commits":["c"],"summary":"s3"},
    {"number":4,"status":"complete","commits":["d"],"summary":"s4"},
    {"number":5,"status":"complete","commits":["e"],"summary":"s5"}
  ]
}'

OUT=$(timeout 10 bash "$PROGRESS" --watch "$PROJECT" 2>&1) || true
assert_contains "$OUT" "Sprint 5/5" "--watch prints sprint progress"
assert_contains "$OUT" "exploring" "--watch prints phase"
assert_contains "$OUT" "12 commits" "--watch prints commit count"
assert_contains "$OUT" "All sprints complete" "--watch detects completion"

# ═══════════════════════════════════════════════════════════════════════════
# 10. progress-reporter.sh update — round-trip (update then read)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Round-trip: update then read"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "session_id": "conductor-rt",
  "mission": "test round-trip",
  "phase": "directed",
  "max_sprints": 4,
  "sprints": [
    {"number": 1, "status": "complete", "direction": "setup", "commits": ["x1", "x2"], "summary": "initial setup complete"}
  ]
}'

bash "$PROGRESS" update "$PROJECT" > /dev/null
OUT=$(bash "$PROGRESS" read "$PROJECT")
VALID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['current_sprint'] == 1
assert d['total_sprints'] == 4
assert d['commits_so_far'] == 2
assert d['last_sprint_summary'] == 'initial setup complete'
print('ok')
" "$OUT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "round-trip produces consistent data"

# ═══════════════════════════════════════════════════════════════════════════
# 11. progress-reporter.sh update — sprints with no commits
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. progress-reporter.sh update — zero-commit sprints"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed", "max_sprints": 3,
  "sprints": [
    {"number":1,"status":"complete","commits":[],"summary":"nothing to do"},
    {"number":2,"status":"complete","commits":[],"summary":"still nothing"}
  ]
}'

bash "$PROGRESS" update "$PROJECT" > /dev/null
VALID=$(python3 -c "
import json
d = json.load(open('$PROJECT/.autonomous/progress.json'))
assert d['commits_so_far'] == 0
assert d['last_sprint_summary'] == 'still nothing'
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "zero-commit sprints count correctly"

# ═══════════════════════════════════════════════════════════════════════════
# 12. progress-reporter.sh update — overwrites existing progress.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. progress-reporter.sh update — overwrites existing"

PROJECT=$(setup_project)
write_progress "$PROJECT" '{"current_sprint":1,"total_sprints":5,"phase":"directed","last_sprint_summary":"old","commits_so_far":1,"estimated_time_remaining":null}'
write_state "$PROJECT" '{
  "phase": "exploring", "max_sprints": 5,
  "sprints": [
    {"number":1,"status":"complete","commits":["a","b","c"],"summary":"new summary"}
  ]
}'

bash "$PROGRESS" update "$PROJECT" > /dev/null
VALID=$(python3 -c "
import json
d = json.load(open('$PROJECT/.autonomous/progress.json'))
assert d['phase'] == 'exploring'
assert d['commits_so_far'] == 3
assert d['last_sprint_summary'] == 'new summary'
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "update overwrites stale progress.json"

# ═══════════════════════════════════════════════════════════════════════════
# 13. progress-reporter.sh — unknown command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. progress-reporter.sh — unknown command"

PROJECT=$(setup_project)
OUT=$(bash "$PROGRESS" invalid "$PROJECT" 2>&1) || true
assert_contains "$OUT" "Unknown command" "unknown command gives error"

# ═══════════════════════════════════════════════════════════════════════════
# 14. autonomous-status.sh --help
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. autonomous-status.sh --help"

OUT=$(bash "$STATUS" --help 2>&1) || true
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "autonomous-status" "--help mentions script name"
assert_contains "$OUT" "json" "--help documents --json flag"

# ═══════════════════════════════════════════════════════════════════════════
# 15. autonomous-status.sh — no session
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. autonomous-status.sh — no session"

PROJECT=$(setup_project)
OUT=$(bash "$STATUS" "$PROJECT")
assert_eq "$OUT" "No active session" "no progress.json prints no active session"

# ═══════════════════════════════════════════════════════════════════════════
# 16. autonomous-status.sh — no session with --json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. autonomous-status.sh — no session --json"

PROJECT=$(setup_project)
OUT=$(bash "$STATUS" "$PROJECT" --json)
VALID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d.get('status') == 'no_session'
print('ok')
" "$OUT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "--json no-session returns {status: no_session}"

# ═══════════════════════════════════════════════════════════════════════════
# 17. autonomous-status.sh — human-readable output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. autonomous-status.sh — human-readable output"

PROJECT=$(setup_project)
write_progress "$PROJECT" '{"current_sprint":3,"total_sprints":5,"phase":"directed","last_sprint_summary":"added auth middleware","commits_so_far":8,"estimated_time_remaining":null}'

OUT=$(bash "$STATUS" "$PROJECT")
assert_contains "$OUT" "Sprint 3/5" "shows sprint progress"
assert_contains "$OUT" "directed" "shows phase"
assert_contains "$OUT" "Commits so far: 8" "shows commit count"
assert_contains "$OUT" "added auth middleware" "shows last sprint summary"

# ═══════════════════════════════════════════════════════════════════════════
# 18. autonomous-status.sh — --json output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. autonomous-status.sh — --json output"

PROJECT=$(setup_project)
write_progress "$PROJECT" '{"current_sprint":2,"total_sprints":4,"phase":"exploring","last_sprint_summary":"improved tests","commits_so_far":6,"estimated_time_remaining":null}'

OUT=$(bash "$STATUS" "$PROJECT" --json)
VALID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['current_sprint'] == 2
assert d['total_sprints'] == 4
assert d['phase'] == 'exploring'
assert d['commits_so_far'] == 6
print('ok')
" "$OUT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "--json returns valid parseable JSON with correct values"

# ═══════════════════════════════════════════════════════════════════════════
# 19. autonomous-status.sh — no last sprint summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. autonomous-status.sh — no last sprint summary"

PROJECT=$(setup_project)
write_progress "$PROJECT" '{"current_sprint":0,"total_sprints":5,"phase":"directed","last_sprint_summary":"","commits_so_far":0,"estimated_time_remaining":null}'

OUT=$(bash "$STATUS" "$PROJECT")
assert_contains "$OUT" "Sprint 0/5" "shows zero progress"
assert_not_contains "$OUT" "Last sprint:" "no last sprint line when empty"

# ═══════════════════════════════════════════════════════════════════════════
# 20. autonomous-status.sh — long summary truncation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. autonomous-status.sh — long summary truncation"

PROJECT=$(setup_project)
LONG="This is a very long sprint summary that exceeds sixty characters and should be truncated by the status display"
write_progress "$PROJECT" "{\"current_sprint\":1,\"total_sprints\":5,\"phase\":\"directed\",\"last_sprint_summary\":\"$LONG\",\"commits_so_far\":1,\"estimated_time_remaining\":null}"

OUT=$(bash "$STATUS" "$PROJECT")
# Truncation means the full string should NOT appear
assert_not_contains "$OUT" "should be truncated by the status display" "long summary is truncated"
assert_contains "$OUT" "..." "truncated summary has ellipsis"

# ═══════════════════════════════════════════════════════════════════════════
# 21. conductor-state.sh progress — basic one-line output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. conductor-state.sh progress — basic"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number":1,"status":"complete","commits":["a1","a2"],"summary":"added auth middleware"}
  ]
}'

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "Sprint 1/5" "progress shows sprint count"
assert_contains "$OUT" "directed" "progress shows phase"
assert_contains "$OUT" "2 commits" "progress shows commit count"
assert_contains "$OUT" "last: added auth middleware" "progress shows last summary"

# ═══════════════════════════════════════════════════════════════════════════
# 22. conductor-state.sh progress — missing state file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. conductor-state.sh progress — missing state file"

PROJECT=$(setup_project)
OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "No active session" "missing state shows no session"

# ═══════════════════════════════════════════════════════════════════════════
# 23. conductor-state.sh progress — empty sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. conductor-state.sh progress — empty sprints"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed",
  "max_sprints": 3,
  "sprints": []
}'

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "Sprint 0/3" "empty sprints shows 0/N"
assert_contains "$OUT" "0 commits" "empty sprints shows 0 commits"
assert_not_contains "$OUT" "last:" "empty sprints has no last summary"

# ═══════════════════════════════════════════════════════════════════════════
# 24. conductor-state.sh progress — exploring phase
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. conductor-state.sh progress — exploring phase"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "exploring",
  "max_sprints": 8,
  "sprints": [
    {"number":1,"status":"complete","commits":["a"],"summary":"done1"},
    {"number":2,"status":"complete","commits":["b","c"],"summary":"done2"},
    {"number":3,"status":"complete","commits":[],"summary":"nothing"},
    {"number":4,"status":"running","commits":["d","e","f"],"summary":""}
  ]
}'

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "Sprint 4/8" "progress shows current sprint count"
assert_contains "$OUT" "exploring" "progress shows exploring phase"
assert_contains "$OUT" "6 commits" "progress counts all commits (1+2+0+3)"
assert_contains "$OUT" "last: nothing" "progress shows last non-empty summary"

# ═══════════════════════════════════════════════════════════════════════════
# 25. conductor-state.sh progress — long summary truncation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. conductor-state.sh progress — long summary truncation"

PROJECT=$(setup_project)
LONG="This is a very long summary that should definitely be truncated to fifty characters"
write_state "$PROJECT" "{
  \"phase\": \"directed\",
  \"max_sprints\": 5,
  \"sprints\": [
    {\"number\":1,\"status\":\"complete\",\"commits\":[\"a\"],\"summary\":\"$LONG\"}
  ]
}"

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "..." "long summary truncated with ellipsis"
assert_not_contains "$OUT" "truncated to fifty characters" "long part removed"

# ═══════════════════════════════════════════════════════════════════════════
# 26. conductor-state.sh progress — multiple sprints, various commits
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. conductor-state.sh progress — commit counting"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed",
  "max_sprints": 10,
  "sprints": [
    {"number":1,"status":"complete","commits":["a","b","c","d","e"],"summary":"s1"},
    {"number":2,"status":"complete","commits":["f"],"summary":"s2"},
    {"number":3,"status":"complete","commits":["g","h"],"summary":"s3"}
  ]
}'

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "8 commits" "counts commits across all sprints (5+1+2)"
assert_contains "$OUT" "Sprint 3/10" "shows correct sprint count"

# ═══════════════════════════════════════════════════════════════════════════
# 27. progress-reporter.sh update — atomic write (tmp file cleaned up)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. Atomic write — no tmp files left"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed", "max_sprints": 2,
  "sprints": [{"number":1,"status":"complete","commits":["x"],"summary":"ok"}]
}'

bash "$PROGRESS" update "$PROJECT" > /dev/null
TMP_COUNT=$(find "$PROJECT/.autonomous" -name "progress.json.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMP_COUNT" "0" "no tmp files left after atomic write"

# ═══════════════════════════════════════════════════════════════════════════
# 28. progress-reporter.sh read — valid JSON output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. progress-reporter.sh read — valid JSON"

PROJECT=$(setup_project)
write_progress "$PROJECT" '{"current_sprint":1,"total_sprints":3,"phase":"directed","last_sprint_summary":"test","commits_so_far":1,"estimated_time_remaining":null}'

OUT=$(bash "$PROGRESS" read "$PROJECT")
VALID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert isinstance(d, dict)
assert 'current_sprint' in d
print('ok')
" "$OUT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "read output is valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 29. progress-reporter.sh update — single sprint with many commits
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Single sprint with many commits"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed", "max_sprints": 1,
  "sprints": [
    {"number":1,"status":"complete","commits":["a","b","c","d","e","f","g","h","i","j"],"summary":"big sprint"}
  ]
}'

bash "$PROGRESS" update "$PROJECT" > /dev/null
VALID=$(python3 -c "
import json
d = json.load(open('$PROJECT/.autonomous/progress.json'))
assert d['commits_so_far'] == 10
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "counts many commits in single sprint"

# ═══════════════════════════════════════════════════════════════════════════
# 30. conductor-state.sh progress — only empty summaries
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. conductor-state.sh progress — all empty summaries"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed",
  "max_sprints": 2,
  "sprints": [
    {"number":1,"status":"running","commits":["a"],"summary":""}
  ]
}'

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "Sprint 1/2" "shows sprint count"
assert_not_contains "$OUT" "last:" "no last: when all summaries empty"

# ═══════════════════════════════════════════════════════════════════════════
# 31. autonomous-status.sh — missing project dir argument
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. autonomous-status.sh — missing project dir"

OUT=$(bash "$STATUS" 2>&1) || true
assert_contains "$OUT" "Usage" "missing arg shows usage error"

# ═══════════════════════════════════════════════════════════════════════════
# 32. progress-reporter.sh update — corrupt conductor-state.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "32. progress-reporter.sh update — corrupt state"

PROJECT=$(setup_project)
echo "not json{{{" > "$PROJECT/.autonomous/conductor-state.json"

RC=0
OUT=$(bash "$PROGRESS" update "$PROJECT" 2>&1) || RC=$?
[ "$RC" -ne 0 ] && ok "corrupt state returns non-zero exit" || fail "corrupt state should return non-zero"

# ═══════════════════════════════════════════════════════════════════════════
# 33. progress-reporter.sh read — corrupt progress.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "33. progress-reporter.sh read — corrupt progress.json"

PROJECT=$(setup_project)
echo "broken json!!!" > "$PROJECT/.autonomous/progress.json"

RC=0
OUT=$(bash "$PROGRESS" read "$PROJECT" 2>&1) || RC=$?
[ "$RC" -ne 0 ] && ok "corrupt progress.json returns non-zero exit" || fail "corrupt progress.json should return non-zero"

# ═══════════════════════════════════════════════════════════════════════════
# 34. conductor-state.sh progress — corrupt state falls back gracefully
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "34. conductor-state.sh progress — corrupt state"

PROJECT=$(setup_project)
echo "bad json" > "$PROJECT/.autonomous/conductor-state.json"

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "No active session" "corrupt state falls back to no session"

# ═══════════════════════════════════════════════════════════════════════════
# 35. Full integration: init → sprint-start → sprint-end → progress
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "35. Full integration via conductor-state.sh"

PROJECT=$(setup_project)
bash "$CONDUCTOR" init "$PROJECT" "full integration test" 5 > /dev/null
bash "$CONDUCTOR" sprint-start "$PROJECT" "setup project scaffold" > /dev/null
bash "$CONDUCTOR" sprint-end "$PROJECT" "complete" "scaffolded the project" '["abc123 init"]' "false" > /dev/null

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "Sprint 1/5" "integration: sprint count correct"
assert_contains "$OUT" "directed" "integration: phase correct"
assert_contains "$OUT" "1 commits" "integration: commit count correct"
assert_contains "$OUT" "last: scaffolded the project" "integration: summary correct"

# ═══════════════════════════════════════════════════════════════════════════
# 36. Full integration: init → sprints → update → status
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "36. Full integration: conductor → progress-reporter → status"

PROJECT=$(setup_project)
bash "$CONDUCTOR" init "$PROJECT" "e2e test" 3 > /dev/null
bash "$CONDUCTOR" sprint-start "$PROJECT" "add feature A" > /dev/null
bash "$CONDUCTOR" sprint-end "$PROJECT" "complete" "feature A done" '["c1 feat","c2 test"]' "false" > /dev/null
bash "$CONDUCTOR" sprint-start "$PROJECT" "add feature B" > /dev/null
bash "$CONDUCTOR" sprint-end "$PROJECT" "complete" "feature B done" '["c3 impl"]' "false" > /dev/null

bash "$PROGRESS" update "$PROJECT" > /dev/null
OUT=$(bash "$STATUS" "$PROJECT")
assert_contains "$OUT" "Sprint 2/3" "e2e: status shows correct sprint"
assert_contains "$OUT" "Commits so far: 3" "e2e: status shows correct commits"
assert_contains "$OUT" "feature B done" "e2e: status shows latest summary"

# ═══════════════════════════════════════════════════════════════════════════
# 37. autonomous-status.sh — estimated_time_remaining placeholder
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "37. autonomous-status.sh — ETA placeholder is null"

PROJECT=$(setup_project)
write_progress "$PROJECT" '{"current_sprint":1,"total_sprints":5,"phase":"directed","last_sprint_summary":"test","commits_so_far":1,"estimated_time_remaining":null}'

OUT=$(bash "$STATUS" "$PROJECT")
assert_not_contains "$OUT" "ETA" "null ETA is not shown"

# ═══════════════════════════════════════════════════════════════════════════
# 38. progress-reporter.sh update — sprints missing commits key
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "38. progress-reporter.sh update — sprints missing commits key"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed", "max_sprints": 2,
  "sprints": [{"number":1,"status":"complete","summary":"no commits key"}]
}'

bash "$PROGRESS" update "$PROJECT" > /dev/null
VALID=$(python3 -c "
import json
d = json.load(open('$PROJECT/.autonomous/progress.json'))
assert d['commits_so_far'] == 0
assert d['last_sprint_summary'] == 'no commits key'
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "handles missing commits key gracefully"

# ═══════════════════════════════════════════════════════════════════════════
# 39. conductor-state.sh progress — sprints missing commits key
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "39. conductor-state.sh progress — missing commits key"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed",
  "max_sprints": 3,
  "sprints": [{"number":1,"status":"running","summary":"working"}]
}'

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "0 commits" "missing commits key counted as 0"

# ═══════════════════════════════════════════════════════════════════════════
# 40. progress-reporter.sh update — large sprint count
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "40. progress-reporter.sh update — large sprint count"

PROJECT=$(setup_project)
# Build a state with 20 sprints
python3 -c "
import json
sprints = []
for i in range(1, 21):
    sprints.append({'number': i, 'status': 'complete', 'commits': [f'c{i}'], 'summary': f'sprint {i} done'})
state = {'phase': 'exploring', 'max_sprints': 20, 'sprints': sprints}
json.dump(state, open('$PROJECT/.autonomous/conductor-state.json', 'w'))
"

bash "$PROGRESS" update "$PROJECT" > /dev/null
VALID=$(python3 -c "
import json
d = json.load(open('$PROJECT/.autonomous/progress.json'))
assert d['current_sprint'] == 20
assert d['total_sprints'] == 20
assert d['commits_so_far'] == 20
assert d['last_sprint_summary'] == 'sprint 20 done'
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "handles 20 sprints correctly"

# ═══════════════════════════════════════════════════════════════════════════
# 41. autonomous-status.sh — project dir with no .autonomous dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "41. autonomous-status.sh — no .autonomous dir"

PROJECT=$(new_tmp)
OUT=$(bash "$STATUS" "$PROJECT")
assert_eq "$OUT" "No active session" "no .autonomous dir shows no session"

# ═══════════════════════════════════════════════════════════════════════════
# 42. conductor-state.sh progress — single sprint zero commits
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "42. conductor-state.sh progress — single sprint zero commits"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed",
  "max_sprints": 5,
  "sprints": [
    {"number":1,"status":"complete","commits":[],"summary":"nothing changed"}
  ]
}'

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "0 commits" "zero commits shown"
assert_contains "$OUT" "last: nothing changed" "summary still shown"

# ═══════════════════════════════════════════════════════════════════════════
# 43. conductor-state.sh progress — in help text
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "43. conductor-state.sh --help includes progress"

OUT=$(bash "$CONDUCTOR" --help 2>&1) || true
assert_contains "$OUT" "progress" "help text mentions progress command"

# ═══════════════════════════════════════════════════════════════════════════
# 44. progress-reporter.sh update then autonomous-status.sh --json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "44. update → status --json pipeline"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed", "max_sprints": 7,
  "sprints": [
    {"number":1,"status":"complete","commits":["a","b"],"summary":"first sprint"},
    {"number":2,"status":"complete","commits":["c"],"summary":"second sprint"}
  ]
}'

bash "$PROGRESS" update "$PROJECT" > /dev/null
OUT=$(bash "$STATUS" "$PROJECT" --json)
VALID=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
assert d['current_sprint'] == 2
assert d['total_sprints'] == 7
assert d['phase'] == 'directed'
assert d['commits_so_far'] == 3
print('ok')
" "$OUT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "pipeline from update to --json status works"

# ═══════════════════════════════════════════════════════════════════════════
# 45. conductor-state.sh progress — max_sprints shows in output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "45. progress output format consistency"

PROJECT=$(setup_project)
write_state "$PROJECT" '{
  "phase": "directed",
  "max_sprints": 99,
  "sprints": [
    {"number":1,"status":"complete","commits":["z"],"summary":"short"}
  ]
}'

OUT=$(bash "$CONDUCTOR" progress "$PROJECT")
assert_contains "$OUT" "Sprint 1/99" "shows large max_sprints"
assert_contains "$OUT" "|" "uses pipe separators"

# ═══════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════

print_results
