#!/usr/bin/env bash
# Tests for scripts/evaluate-sprint.sh — sprint result evaluation and conductor state updates.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALUATE="$SCRIPT_DIR/../scripts/evaluate-sprint.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Create a git project with conductor state initialized. Returns path.
new_eval_project() {
  local d; d=$(new_tmp)
  (
    cd "$d"
    git init -q
    git commit -q --allow-empty -m "init"
    mkdir -p .autonomous
    chmod 700 .autonomous
  )
  # Initialize conductor state and backlog
  bash "$SKILL_DIR/scripts/conductor-state.sh" init "$d" "test mission" "5" >/dev/null 2>&1
  bash "$SKILL_DIR/scripts/backlog.sh" init "$d" >/dev/null 2>&1
  echo "$d"
}

# Write a sprint summary JSON file
write_summary() {
  local project="$1" sprint_num="$2" status="$3" summary="$4" dir_complete="${5:-false}"
  local commits="${6:-[]}"
  python3 -c "
import json, sys
dc = sys.argv[1]
d = {
    'status': '$status',
    'summary': '$summary',
    'commits': json.loads('$commits'),
    'direction_complete': dc == 'true'
}
with open('$project/.autonomous/sprint-$sprint_num-summary.json', 'w') as f:
    json.dump(d, f)
" "$dir_complete"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_evaluate_sprint.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Valid summary → parses all fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Valid summary JSON"

T=$(new_eval_project)
# Start a sprint first so conductor-state expects it
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "add tests" >/dev/null 2>&1
write_summary "$T" "1" "complete" "Added 10 test cases" "false" '["abc1234 add tests"]'

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" 2>&1)
STDOUT=$(echo "$OUT" | grep -v "^Phase after")
assert_contains "$STDOUT" "STATUS=complete" "status parsed correctly"
assert_contains "$STDOUT" "SUMMARY=Added 10 test cases" "summary parsed correctly"
assert_contains "$STDOUT" "DIR_COMPLETE=false" "dir_complete parsed correctly"
assert_contains "$STDOUT" "PHASE=" "phase is output"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Direction complete flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Direction complete flag"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "fix bugs" >/dev/null 2>&1
write_summary "$T" "1" "complete" "All bugs fixed" "true" '["def5678 fix bugs"]'

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" 2>&1)
assert_contains "$OUT" "DIR_COMPLETE=true" "direction_complete=true parsed"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Missing summary + new commits → complete fallback
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Missing summary + new commits → complete"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "do work" >/dev/null 2>&1

# Record the current HEAD as last_commit
LAST_COMMIT=$(cd "$T" && git log --oneline -1)

# Make a new commit
(cd "$T" && echo "new work" > work.txt && git add work.txt && git commit -q -m "new work")

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" "$LAST_COMMIT" 2>&1)
assert_contains "$OUT" "STATUS=complete" "missing summary + new commits → complete"
assert_contains "$OUT" "new commits" "summary mentions new commits"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Missing summary + no new commits → partial
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Missing summary + no new commits → partial"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "do work" >/dev/null 2>&1

# Use current HEAD as last_commit — no new commits will be made
LAST_COMMIT=$(cd "$T" && git log --oneline -1)

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" "$LAST_COMMIT" 2>&1)
assert_contains "$OUT" "STATUS=partial" "missing summary + no new commits → partial"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Corrupt JSON summary → fallback to git detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Corrupt JSON → fallback"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "do work" >/dev/null 2>&1

LAST_COMMIT=$(cd "$T" && git log --oneline -1)

# Write corrupt JSON
echo "NOT VALID JSON {{{" > "$T/.autonomous/sprint-1-summary.json"

# Make a new commit so fallback detects activity
(cd "$T" && echo "fix" > fix.txt && git add fix.txt && git commit -q -m "fix")

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" "$LAST_COMMIT" 2>&1)
assert_contains "$OUT" "STATUS=complete" "corrupt JSON + new commits → complete"
assert_contains "$OUT" "corrupt" "summary mentions corrupt"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Corrupt JSON + no new commits → partial
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Corrupt JSON + no new commits → partial"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "do work" >/dev/null 2>&1

LAST_COMMIT=$(cd "$T" && git log --oneline -1)
echo "{invalid" > "$T/.autonomous/sprint-1-summary.json"

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" "$LAST_COMMIT" 2>&1)
assert_contains "$OUT" "STATUS=partial" "corrupt JSON + no new commits → partial"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Output format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Output format"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "work" >/dev/null 2>&1
write_summary "$T" "1" "complete" "done" "false" '["abc test"]'

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" 2>&1)
# Check all 4 output fields are present
STDOUT=$(echo "$OUT" | grep -c "^STATUS=\|^SUMMARY=\|^DIR_COMPLETE=\|^PHASE=")
assert_ge "$STDOUT" "4" "all 4 output fields present"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Phase output on stderr
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Phase info on stderr"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "test" >/dev/null 2>&1
write_summary "$T" "1" "complete" "done" "false" '["abc test"]'

ERR=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" 2>&1 1>/dev/null)
assert_contains "$ERR" "Phase after sprint 1" "stderr shows phase info"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Partial status summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Partial status from summary file"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "work" >/dev/null 2>&1
write_summary "$T" "1" "partial" "half done" "false" '[]'

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" 2>&1)
assert_contains "$OUT" "STATUS=partial" "partial status from summary"
assert_contains "$OUT" "SUMMARY=half done" "partial summary text"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Blocked status from summary file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Blocked status from summary file"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "work" >/dev/null 2>&1
write_summary "$T" "1" "blocked" "need credentials" "false" '[]'

OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" 2>&1)
assert_contains "$OUT" "STATUS=blocked" "blocked status from summary"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Missing summary + no last_commit arg → partial
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Missing summary + no last_commit → partial"

T=$(new_eval_project)
bash "$SKILL_DIR/scripts/conductor-state.sh" sprint-start "$T" "work" >/dev/null 2>&1

# No summary file, no last_commit arg
OUT=$(cd "$T" && bash "$EVALUATE" "$T" "$SKILL_DIR" "1" 2>&1)
assert_contains "$OUT" "STATUS=partial" "no summary + no last_commit → partial"

# ═══════════════════════════════════════════════════════════════════════════
# 12. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. --help flag"

HELP=$(bash "$EVALUATE" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
assert_contains "$HELP" "project_dir" "--help mentions project_dir"
assert_contains "$HELP" "sprint_num" "--help mentions sprint_num"
assert_contains "$HELP" "last_commit" "--help mentions last_commit"

bash "$EVALUATE" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 13. -h short flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. -h short flag"

HELP_SHORT=$(bash "$EVALUATE" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h shows Usage"

bash "$EVALUATE" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

print_results
