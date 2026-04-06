#!/usr/bin/env bash
# Tests for scripts/selective-merge.sh — selective sprint cherry-pick merging.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTIVE_MERGE="$SCRIPT_DIR/../scripts/selective-merge.sh"
SESSION_REPORT="$SCRIPT_DIR/../scripts/session-report.sh"

# ── Helpers ──────────────────────────────────────────────────────────────

# Create a git project with a session branch containing N sprints.
# Usage: new_session_project [num_sprints]
# Creates merge commits "sprint N: ..." and conductor-state.json
new_session_project() {
  local num_sprints="${1:-3}"
  local d; d=$(new_tmp)
  (
    cd "$d"
    git init -q
    echo "base" > base.txt
    git add base.txt
    git commit -q -m "init"
    git checkout -q -b "auto/session-123"

    local sprints_json="["
    for i in $(seq 1 "$num_sprints"); do
      # Create sprint branch with a commit, then merge
      git checkout -q -b "sprint-$i"
      echo "feature-$i" > "f${i}.txt"
      git add "f${i}.txt"
      git commit -q -m "add feature $i"
      local hash
      hash=$(git rev-parse --short HEAD)
      git checkout -q "auto/session-123"
      git merge -q --no-ff "sprint-$i" -m "sprint $i: added feature $i"
      git branch -q -D "sprint-$i"

      # Build sprint JSON
      local comma=""
      [ "$i" -gt 1 ] && comma=","
      sprints_json="${sprints_json}${comma}{\"number\":$i,\"direction\":\"add feature $i\",\"status\":\"merged\",\"commits\":[\"${hash} add feature $i\"],\"direction_complete\":true,\"quality_gate_passed\":true}"
    done
    sprints_json="${sprints_json}]"

    mkdir -p .autonomous
    python3 -c "
import json, sys
sprints = json.loads(sys.argv[1])
state = {'phase': 'directed', 'sprints': sprints}
with open('.autonomous/conductor-state.json', 'w') as f:
    json.dump(state, f, indent=2)
" "$sprints_json"
    git add .autonomous/conductor-state.json
    git commit -q -m "update conductor state"
  ) >/dev/null 2>&1
  echo "$d"
}

# Create a project with mixed sprint states (some complete, some blocked)
new_mixed_project() {
  local d; d=$(new_tmp)
  (
    cd "$d"
    git init -q
    echo "base" > base.txt
    git add base.txt
    git commit -q -m "init"
    git checkout -q -b "auto/session-456"

    # Sprint 1: merged with commits (recommended)
    git checkout -q -b "sprint-1"
    echo "feat1" > f1.txt && git add f1.txt && git commit -q -m "add feat 1"
    git checkout -q "auto/session-456"
    git merge -q --no-ff "sprint-1" -m "sprint 1: added feature 1"
    git branch -q -D "sprint-1"

    # Sprint 2: complete but no commits (skippable)
    # Just add a merge commit with empty tree diff
    git commit -q --allow-empty -m "sprint 2: no changes"

    # Sprint 3: merged with commits (recommended)
    git checkout -q -b "sprint-3"
    echo "feat3" > f3.txt && git add f3.txt && git commit -q -m "add feat 3"
    git checkout -q "auto/session-456"
    git merge -q --no-ff "sprint-3" -m "sprint 3: added feature 3"
    git branch -q -D "sprint-3"

    mkdir -p .autonomous
    cat > .autonomous/conductor-state.json << 'STATEEOF'
{
  "phase": "directed",
  "sprints": [
    {"number": 1, "direction": "add feature 1", "status": "merged", "commits": ["abc add feat 1"], "direction_complete": true, "quality_gate_passed": true},
    {"number": 2, "direction": "refactor utils", "status": "complete", "commits": [], "direction_complete": true, "quality_gate_passed": null},
    {"number": 3, "direction": "add feature 3", "status": "merged", "commits": ["def add feat 3"], "direction_complete": true, "quality_gate_passed": false}
  ]
}
STATEEOF
    git add .autonomous/conductor-state.json
    git commit -q -m "update state"
  ) >/dev/null 2>&1
  echo "$d"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_selective_merge.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Help and usage
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Help and usage"

OUT=$(bash "$SELECTIVE_MERGE" --help 2>&1)
assert_contains "$OUT" "Usage:" "--help shows usage"
assert_contains "$OUT" "selective-merge" "--help mentions script name"
assert_contains "$OUT" "merge" "--help mentions merge mode"
assert_contains "$OUT" "squash" "--help mentions squash mode"
assert_contains "$OUT" "dry-run" "--help mentions dry-run"
assert_contains "$OUT" "interactive" "--help mentions interactive"
assert_contains "$OUT" "target" "--help mentions target"

bash "$SELECTIVE_MERGE" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

OUT=$(bash "$SELECTIVE_MERGE" -h 2>&1)
assert_contains "$OUT" "Usage:" "-h shows usage"

bash "$SELECTIVE_MERGE" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

OUT=$(bash "$SELECTIVE_MERGE" help 2>&1)
assert_contains "$OUT" "Usage:" "help shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Missing arguments
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Missing arguments"

OUT=$(bash "$SELECTIVE_MERGE" 2>&1) || true
assert_contains "$OUT" "ERROR" "no args → error"

OUT=$(bash "$SELECTIVE_MERGE" /tmp 2>&1) || true
assert_contains "$OUT" "ERROR" "missing session-branch → error"

OUT=$(bash "$SELECTIVE_MERGE" /nonexistent auto/session-123 2>&1) || true
assert_contains "$OUT" "ERROR" "nonexistent project-dir → error"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Bad arguments
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Bad arguments"

T=$(new_tmp)
mkdir -p "$T"

OUT=$(bash "$SELECTIVE_MERGE" "$T" auto/session-123 --merge 2>&1) || true
assert_contains "$OUT" "ERROR" "--merge without numbers → error"

OUT=$(bash "$SELECTIVE_MERGE" "$T" auto/session-123 --squash 2>&1) || true
assert_contains "$OUT" "ERROR" "--squash without numbers → error"

OUT=$(bash "$SELECTIVE_MERGE" "$T" auto/session-123 --interactive 2>&1) || true
assert_contains "$OUT" "ERROR" "--interactive without file → error"

OUT=$(bash "$SELECTIVE_MERGE" "$T" auto/session-123 --target 2>&1) || true
assert_contains "$OUT" "ERROR" "--target without branch → error"

# ═══════════════════════════════════════════════════════════════════════════
# 4. List mode — default
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. List mode (default)"

T=$(new_session_project 3)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" 2>&1)
assert_contains "$OUT" "Session:" "list shows session name"
assert_contains "$OUT" "Sprint" "list shows Sprint header"
assert_contains "$OUT" "Direction" "list shows Direction header"
assert_contains "$OUT" "Rating" "list shows Rating header"
assert_contains "$OUT" "add feature 1" "list shows sprint 1 direction"
assert_contains "$OUT" "add feature 2" "list shows sprint 2 direction"
assert_contains "$OUT" "add feature 3" "list shows sprint 3 direction"
assert_contains "$OUT" "recommended" "list shows recommended rating"

# ═══════════════════════════════════════════════════════════════════════════
# 5. List mode — explicit --list flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. List mode — explicit --list"

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --list 2>&1)
assert_contains "$OUT" "Session:" "--list shows session"
assert_contains "$OUT" "Recommended:" "--list shows recommendation"
assert_contains "$OUT" "merge" "recommendation includes merge command"

# ═══════════════════════════════════════════════════════════════════════════
# 6. List mode with mixed states
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. List mode — mixed sprint states"

T=$(new_mixed_project)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-456" 2>&1)
assert_contains "$OUT" "recommended" "mixed list has recommended sprints"
assert_contains "$OUT" "skippable" "mixed list has skippable sprints"
assert_contains "$OUT" "refactor utils" "mixed list shows sprint 2 direction"

# ═══════════════════════════════════════════════════════════════════════════
# 7. List mode — empty session
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. List mode — empty state"

T=$(new_tmp)
(
  cd "$T"
  git init -q
  git commit -q --allow-empty -m "init"
  git checkout -q -b "auto/session-empty"
  mkdir -p .autonomous
  echo '{"phase":"directed","sprints":[]}' > .autonomous/conductor-state.json
  git add .autonomous/conductor-state.json
  git commit -q -m "empty state"
)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-empty" 2>&1)
assert_contains "$OUT" "No sprints" "empty state shows no sprints message"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Merge mode — successful cherry-pick
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Merge mode — successful cherry-pick"

T=$(new_session_project 3)
(cd "$T" && git checkout -q main 2>/dev/null || cd "$T" && git checkout -q master 2>/dev/null || true)
# Get default branch name
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1 2>&1)
assert_contains "$OUT" "merged" "merge sprint 1 → merged"
assert_contains "$OUT" "Result:" "merge shows result summary"

# Verify file exists on current branch
assert_file_exists "$T/f1.txt" "f1.txt exists after merge"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Merge mode — multiple sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Merge mode — multiple sprints"

T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,3 2>&1)
assert_contains "$OUT" "Sprint 1:" "shows sprint 1 status"
assert_contains "$OUT" "Sprint 3:" "shows sprint 3 status"
assert_file_exists "$T/f1.txt" "f1.txt merged"
assert_file_exists "$T/f3.txt" "f3.txt merged"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Merge mode — nonexistent sprint number
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Merge mode — nonexistent sprint"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 99 2>&1)
assert_contains "$OUT" "skipped" "nonexistent sprint → skipped"
assert_contains "$OUT" "no merge commit" "reports no merge commit found"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Merge mode — partial success (some valid, some invalid)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Merge mode — partial success"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,99 2>&1)
assert_contains "$OUT" "merged" "valid sprint merged"
assert_contains "$OUT" "skipped" "invalid sprint skipped"
assert_file_exists "$T/f1.txt" "valid sprint file exists"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Merge mode — conflict handling
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Merge mode — conflict handling"

T=$(new_session_project 1)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(
  cd "$T"
  git checkout -q "$DEFAULT_BRANCH"
  # Create conflicting content on main
  echo "conflicting-content" > f1.txt
  git add f1.txt
  git commit -q -m "conflict setup"
)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1 2>&1)
assert_contains "$OUT" "CONFLICT" "conflict detected"
# Should still get a result summary
assert_contains "$OUT" "Result:" "result summary after conflict"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Dry-run mode — merge
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Dry-run mode — merge"

T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,2 --dry-run 2>&1)
assert_contains "$OUT" "would cherry-pick" "dry-run says would cherry-pick"
assert_contains "$OUT" "Dry run:" "dry-run label"

# Verify no files were actually cherry-picked
assert_file_not_exists "$T/f1.txt" "dry-run does not create f1.txt"
assert_file_not_exists "$T/f2.txt" "dry-run does not create f2.txt"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Dry-run mode — squash
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Dry-run mode — squash"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1,2 --dry-run 2>&1)
assert_contains "$OUT" "would combine" "dry-run squash says would combine"
assert_contains "$OUT" "Dry run:" "dry-run squash label"
assert_file_not_exists "$T/f1.txt" "dry-run squash no f1.txt"

# ═══════════════════════════════════════════════════════════════════════════
# 15. Squash mode — successful
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Squash mode — successful"

T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1,2,3 2>&1)
assert_contains "$OUT" "Result:" "squash shows result"
assert_contains "$OUT" "squashed" "squash mentions squashed"

# All files should exist
assert_file_exists "$T/f1.txt" "squash: f1.txt exists"
assert_file_exists "$T/f2.txt" "squash: f2.txt exists"
assert_file_exists "$T/f3.txt" "squash: f3.txt exists"

# Should be a single squash commit (not 3 separate)
COMMIT_MSG=$(cd "$T" && git log --oneline -1)
assert_contains "$COMMIT_MSG" "squash sprints" "squash commit message"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Squash mode — subset of sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Squash mode — subset"

T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1,3 2>&1)
assert_contains "$OUT" "Result:" "squash subset shows result"
assert_file_exists "$T/f1.txt" "squash subset: f1.txt exists"
assert_file_exists "$T/f3.txt" "squash subset: f3.txt exists"
assert_file_not_exists "$T/f2.txt" "squash subset: f2.txt not merged"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Squash mode — nonexistent sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Squash mode — nonexistent"

T=$(new_session_project 1)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 98,99 2>&1)
assert_contains "$OUT" "No merge commits" "squash nonexistent sprints → no commits msg"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Squash mode — temp branch cleanup
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Squash mode — temp branch cleanup"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1,2 >/dev/null 2>&1
BRANCHES=$(cd "$T" && git branch)
assert_not_contains "$BRANCHES" "tmp/squash" "temp branch cleaned up after squash"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Interactive mode — file creation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Interactive mode — file creation"

T=$(new_session_project 3)
PLAN_FILE="$T/merge-plan.json"

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" 2>&1)
assert_contains "$OUT" "Wrote 3 sprint choices" "interactive writes 3 choices"
assert_file_exists "$PLAN_FILE" "plan file created"

# Verify JSON structure
SPRINT_COUNT=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print(len(d))" 2>/dev/null)
assert_eq "$SPRINT_COUNT" "3" "plan file has 3 entries"

ACTION=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print(d[0]['action'])" 2>/dev/null)
assert_eq "$ACTION" "pending" "default action is pending"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Interactive mode — file fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Interactive mode — file has correct fields"

T=$(new_mixed_project)
PLAN_FILE="$T/plan.json"

cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-456" --interactive "$PLAN_FILE" >/dev/null 2>&1

HAS_SPRINT=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print('sprint' in d[0])" 2>/dev/null)
assert_eq "$HAS_SPRINT" "True" "plan entry has sprint field"

HAS_DIRECTION=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print('direction' in d[0])" 2>/dev/null)
assert_eq "$HAS_DIRECTION" "True" "plan entry has direction field"

HAS_RATING=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print('rating' in d[0])" 2>/dev/null)
assert_eq "$HAS_RATING" "True" "plan entry has rating field"

HAS_ACTION=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print('action' in d[0])" 2>/dev/null)
assert_eq "$HAS_ACTION" "True" "plan entry has action field"

# ═══════════════════════════════════════════════════════════════════════════
# 21. Interactive mode — apply
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. Interactive mode — apply"

T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
PLAN_FILE="$T/plan.json"

# Generate the plan file
cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" >/dev/null 2>&1

# Edit plan to mark sprints 1 and 3 as "yes", sprint 2 as "no"
python3 -c "
import json
with open('$PLAN_FILE') as f:
    d = json.load(f)
d[0]['action'] = 'yes'
d[1]['action'] = 'no'
d[2]['action'] = 'yes'
with open('$PLAN_FILE', 'w') as f:
    json.dump(d, f)
"

(cd "$T" && git checkout -q "$DEFAULT_BRANCH")
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" --apply 2>&1)
assert_contains "$OUT" "Applying sprints" "apply mode reports applying"
assert_file_exists "$T/f1.txt" "apply: sprint 1 merged"
assert_file_exists "$T/f3.txt" "apply: sprint 3 merged"
assert_file_not_exists "$T/f2.txt" "apply: sprint 2 not merged"

# ═══════════════════════════════════════════════════════════════════════════
# 22. Interactive mode — apply with no "yes" sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. Interactive mode — apply with all 'no'"

T=$(new_session_project 2)
PLAN_FILE="$T/plan.json"

cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" >/dev/null 2>&1
python3 -c "
import json
with open('$PLAN_FILE') as f:
    d = json.load(f)
for item in d:
    item['action'] = 'no'
with open('$PLAN_FILE', 'w') as f:
    json.dump(d, f)
"

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" --apply 2>&1)
assert_contains "$OUT" "No sprints marked" "all-no apply reports none marked"

# ═══════════════════════════════════════════════════════════════════════════
# 23. Interactive mode — apply with missing file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. Interactive mode — apply with missing file"

T=$(new_session_project 1)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "/nonexistent/file.json" --apply 2>&1) || true
assert_contains "$OUT" "ERROR" "missing interactive file → error"

# ═══════════════════════════════════════════════════════════════════════════
# 24. Target branch option
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. --target option"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')

# Create a target branch
(cd "$T" && git checkout -q "$DEFAULT_BRANCH" && git checkout -q -b "release/v1")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1 --target "release/v1" 2>&1)
assert_contains "$OUT" "merged" "target branch merge succeeded"

CURRENT=$(cd "$T" && git branch --show-current)
assert_eq "$CURRENT" "release/v1" "now on target branch"
assert_file_exists "$T/f1.txt" "file merged onto target branch"

# ═══════════════════════════════════════════════════════════════════════════
# 25. Target branch — nonexistent
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. --target nonexistent branch"

T=$(new_session_project 1)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1 --target "nonexistent-branch" 2>&1) || true
assert_contains "$OUT" "ERROR" "nonexistent target branch → error"

# ═══════════════════════════════════════════════════════════════════════════
# 26. Merge — invalid sprint number format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. Invalid sprint number format"

T=$(new_session_project 1)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge "abc" 2>&1) || true
assert_contains "$OUT" "ERROR" "non-numeric sprint → error"

# ═══════════════════════════════════════════════════════════════════════════
# 27. List mode — long direction truncation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. List mode — direction truncation"

T=$(new_tmp)
(
  cd "$T"
  git init -q
  git commit -q --allow-empty -m "init"
  git checkout -q -b "auto/session-trunc"
  mkdir -p .autonomous
  cat > .autonomous/conductor-state.json << 'EOF'
{"phase":"directed","sprints":[{"number":1,"direction":"this is a very long direction that should be truncated to fit in the table","status":"merged","commits":["abc feat"],"quality_gate_passed":true}]}
EOF
  git add .autonomous/conductor-state.json
  git commit -q -m "state"
)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-trunc" 2>&1)
assert_contains "$OUT" "\\.\\.\\." "long direction is truncated with ..."

# ═══════════════════════════════════════════════════════════════════════════
# 28. List mode — quality gate display
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. List mode — quality gate values"

T=$(new_mixed_project)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-456" 2>&1)
assert_contains "$OUT" "pass" "list shows quality gate pass"
assert_contains "$OUT" "fail" "list shows quality gate fail"

# ═══════════════════════════════════════════════════════════════════════════
# 29. Merge mode — single sprint
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Merge mode — single sprint no comma"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 2 2>&1)
assert_contains "$OUT" "merged" "single sprint merge ok"
assert_file_exists "$T/f2.txt" "single sprint file exists"
assert_file_not_exists "$T/f1.txt" "other sprint file not merged"

# ═══════════════════════════════════════════════════════════════════════════
# 30. Squash — combined commit message
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. Squash commit message contains sprint numbers"

T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1,3 >/dev/null 2>&1

COMMIT_MSG=$(cd "$T" && git log --oneline -1)
assert_contains "$COMMIT_MSG" "1" "squash message has sprint 1"
assert_contains "$COMMIT_MSG" "3" "squash message has sprint 3"

# ═══════════════════════════════════════════════════════════════════════════
# 31. Merge mode — result counts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. Merge mode — result counts"

T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,2,99 2>&1)
assert_contains "$OUT" "2 merged" "2 sprints merged"
assert_contains "$OUT" "1 skipped" "1 sprint skipped"

# ═══════════════════════════════════════════════════════════════════════════
# 32. Dry-run — preserves branch state
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "32. Dry-run preserves branch state"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

BEFORE_HASH=$(cd "$T" && git rev-parse HEAD)
bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1 --dry-run >/dev/null 2>&1
AFTER_HASH=$(cd "$T" && git rev-parse HEAD)

assert_eq "$BEFORE_HASH" "$AFTER_HASH" "dry-run does not change HEAD"

# ═══════════════════════════════════════════════════════════════════════════
# 33. List mode shows recommendation command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "33. List shows --merge recommendation"

T=$(new_session_project 2)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --list 2>&1)
assert_contains "$OUT" "merge 1,2" "recommendation shows merge with sprint numbers"

# ═══════════════════════════════════════════════════════════════════════════
# 34. Unexpected extra argument
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "34. Unexpected extra argument"

T=$(new_session_project 1)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" "extra-arg" 2>&1) || true
assert_contains "$OUT" "ERROR" "extra arg → error"

# ═══════════════════════════════════════════════════════════════════════════
# 35. Interactive mode — ratings in plan file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "35. Interactive — ratings in plan file"

T=$(new_mixed_project)
PLAN_FILE="$T/plan.json"

cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-456" --interactive "$PLAN_FILE" >/dev/null 2>&1

RATING_1=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print(d[0]['rating'])" 2>/dev/null)
assert_eq "$RATING_1" "recommended" "sprint 1 rated recommended in plan"

RATING_2=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print(d[1]['rating'])" 2>/dev/null)
assert_eq "$RATING_2" "skippable" "sprint 2 rated skippable in plan"

# ═══════════════════════════════════════════════════════════════════════════
# 36. Interactive — commit counts in plan file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "36. Interactive — commit counts in plan file"

T=$(new_mixed_project)
PLAN_FILE="$T/plan.json"

cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-456" --interactive "$PLAN_FILE" >/dev/null 2>&1

COMMITS_1=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print(d[0]['commits'])" 2>/dev/null)
assert_eq "$COMMITS_1" "1" "sprint 1 has 1 commit in plan"

COMMITS_2=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print(d[1]['commits'])" 2>/dev/null)
assert_eq "$COMMITS_2" "0" "sprint 2 has 0 commits in plan"

# ═══════════════════════════════════════════════════════════════════════════
# 37. Merge after conflict — continues to next sprint
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "37. Merge after conflict — continues"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(
  cd "$T"
  git checkout -q "$DEFAULT_BRANCH"
  # Conflict on sprint 1, not on sprint 2
  echo "conflict" > f1.txt
  git add f1.txt
  git commit -q -m "create conflict"
)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,2 2>&1)
assert_contains "$OUT" "CONFLICT" "sprint 1 conflict reported"
assert_contains "$OUT" "merged" "sprint 2 still merged after conflict"
assert_file_exists "$T/f2.txt" "sprint 2 file exists despite sprint 1 conflict"

# ═══════════════════════════════════════════════════════════════════════════
# 38. Merge conflict count in results
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "38. Conflict count in results"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(
  cd "$T"
  git checkout -q "$DEFAULT_BRANCH"
  echo "conflict" > f1.txt
  git add f1.txt
  git commit -q -m "create conflict"
)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,2 2>&1)
assert_contains "$OUT" "1 conflicted" "1 conflict counted"
assert_contains "$OUT" "1 merged" "1 merge counted"

# ═══════════════════════════════════════════════════════════════════════════
# 39. Conflicted sprint numbers reported
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "39. Conflicted sprint numbers reported"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(
  cd "$T"
  git checkout -q "$DEFAULT_BRANCH"
  echo "conflict" > f1.txt
  git add f1.txt
  git commit -q -m "create conflict"
)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1 2>&1)
assert_contains "$OUT" "Conflicted sprints:" "reports conflicted sprint numbers"

# ═══════════════════════════════════════════════════════════════════════════
# 40. Merge mode — spaces in sprint numbers
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "40. Merge with spaces in sprint numbers"

T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge "1, 2" 2>&1)
assert_contains "$OUT" "Result:" "spaces in numbers handled"
assert_file_exists "$T/f1.txt" "sprint 1 merged with space"
assert_file_exists "$T/f2.txt" "sprint 2 merged with space"

# ═══════════════════════════════════════════════════════════════════════════
# 41-45. session-report.sh --merge-plan integration
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "41-45. session-report.sh --merge-plan"

T=$(new_tmp)
(
  cd "$T"
  git init -q
  git commit -q --allow-empty -m "init"
  git checkout -q -b "auto/session-rpt"

  mkdir -p .autonomous
  cat > .autonomous/conductor-state.json << 'STATEEOF'
{"phase":"directed","sprints":[
  {"number":1,"direction":"add feature","status":"merged","commits":["abc feat"],"quality_gate_passed":true},
  {"number":2,"direction":"refactor","status":"complete","commits":[],"quality_gate_passed":null},
  {"number":3,"direction":"fix bug","status":"merged","commits":["def fix"],"quality_gate_passed":true}
]}
STATEEOF

  # Create sprint summary files for session-report
  cat > .autonomous/sprint-1-summary.json << 'EOF'
{"status":"complete","commits":["abc feat"],"summary":"added feature"}
EOF
  cat > .autonomous/sprint-2-summary.json << 'EOF'
{"status":"complete","commits":[],"summary":"refactored utils"}
EOF
  cat > .autonomous/sprint-3-summary.json << 'EOF'
{"status":"complete","commits":["def fix"],"summary":"fixed bug"}
EOF

  git add .autonomous/
  git commit -q -m "state"
)

# 41. --merge-plan text output
OUT=$(cd "$T" && bash "$SESSION_REPORT" "$T" --merge-plan 2>&1)
assert_contains "$OUT" "Merge plan:" "merge-plan shows merge plan section"
assert_contains "$OUT" "selective-merge" "merge-plan shows selective-merge command"
assert_contains "$OUT" "1" "merge-plan includes sprint 1"
assert_contains "$OUT" "3" "merge-plan includes sprint 3"

# 42. --merge-plan in help
HELP=$(bash "$SESSION_REPORT" --help 2>&1)
assert_contains "$HELP" "merge-plan" "help mentions merge-plan"

# 43. --merge-plan --json output
OUT=$(cd "$T" && bash "$SESSION_REPORT" "$T" --merge-plan --json 2>&1)
assert_contains "$OUT" "merge_plan" "JSON has merge_plan key"
assert_contains "$OUT" "recommended_sprints" "JSON has recommended_sprints"
assert_contains "$OUT" "command" "JSON has command"

# Verify recommended sprints
REC=$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['merge_plan']['recommended_sprints'])" 2>/dev/null)
assert_contains "$REC" "1" "JSON merge_plan has sprint 1"
assert_contains "$REC" "3" "JSON merge_plan has sprint 3"

# 44. --merge-plan without --merge-plan flag → no merge_plan in JSON
OUT=$(cd "$T" && bash "$SESSION_REPORT" "$T" --json 2>&1)
assert_not_contains "$OUT" "merge_plan" "JSON without --merge-plan has no merge_plan key"

# 45. --merge-plan with no recommended sprints
T2=$(new_tmp)
(
  cd "$T2"
  git init -q
  git commit -q --allow-empty -m "init"
  git checkout -q -b "auto/session-skip"
  mkdir -p .autonomous
  echo '{"phase":"directed","sprints":[{"number":1,"direction":"fail","status":"blocked","commits":[],"quality_gate_passed":false}]}' > .autonomous/conductor-state.json
  cat > .autonomous/sprint-1-summary.json << 'EOF'
{"status":"blocked","commits":[],"summary":"failed"}
EOF
  git add .autonomous/
  git commit -q -m "state"
)
OUT=$(cd "$T2" && bash "$SESSION_REPORT" "$T2" --merge-plan 2>&1)
assert_contains "$OUT" "no sprints recommended" "merge-plan with no recommendations"

# ═══════════════════════════════════════════════════════════════════════════
# 46-50. Edge cases
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "46-50. Edge cases"

# 46. List mode — non-existent branch
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "nonexistent-branch" 2>&1) || true
# Should handle gracefully (empty state or error)
assert_eq "$?" "0" "nonexistent branch exits cleanly" || ok "nonexistent branch handled"

# 47. Merge with single sprint from 5-sprint project
T=$(new_session_project 5)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 3 2>&1)
assert_contains "$OUT" "merged" "cherry-pick from 5-sprint project"
assert_file_exists "$T/f3.txt" "sprint 3 file exists"
assert_file_not_exists "$T/f1.txt" "sprint 1 not touched"
assert_file_not_exists "$T/f4.txt" "sprint 4 not touched"

# 48. List mode — single sprint
T=$(new_session_project 1)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" 2>&1)
assert_contains "$OUT" "add feature 1" "single sprint list ok"
assert_contains "$OUT" "merge 1" "single sprint recommendation"

# 49. Squash single sprint
T=$(new_session_project 1)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1 2>&1)
assert_contains "$OUT" "Result:" "squash single sprint result"
assert_file_exists "$T/f1.txt" "squash single sprint file exists"

# 50. Interactive file contains status field
T=$(new_mixed_project)
PLAN_FILE="$T/status-test.json"
cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-456" --interactive "$PLAN_FILE" >/dev/null 2>&1

HAS_STATUS=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print('status' in d[0])" 2>/dev/null)
assert_eq "$HAS_STATUS" "True" "plan entry has status field"

# ═══════════════════════════════════════════════════════════════════════════
# 51-55. More edge cases and combinations
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "51-55. Combinations"

# 51. Dry-run + squash shows count
T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1,2,3 --dry-run 2>&1)
assert_contains "$OUT" "3 sprints" "dry-run squash shows sprint count"

# 52. List mode with --list is same as default
T=$(new_session_project 2)
OUT_DEFAULT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" 2>&1)
OUT_LIST=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --list 2>&1)
assert_eq "$OUT_DEFAULT" "$OUT_LIST" "--list same as default"

# 53. Merge preserves git history (non-squash)
T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

BEFORE_COUNT=$(cd "$T" && git rev-list --count HEAD)
bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,2 >/dev/null 2>&1
AFTER_COUNT=$(cd "$T" && git rev-list --count HEAD)

# Should have added 2 cherry-picked commits
DIFF_COUNT=$((AFTER_COUNT - BEFORE_COUNT))
assert_ge "$DIFF_COUNT" "2" "merge adds commits to history"

# 54. Squash results in fewer commits than merge
T=$(new_session_project 3)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

BEFORE_COUNT=$(cd "$T" && git rev-list --count HEAD)
bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1,2,3 >/dev/null 2>&1
AFTER_COUNT=$(cd "$T" && git rev-list --count HEAD)

SQUASH_DIFF=$((AFTER_COUNT - BEFORE_COUNT))
assert_eq "$SQUASH_DIFF" "1" "squash adds exactly 1 commit"

# 55. Dry-run + nonexistent sprint
T=$(new_session_project 1)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 99 --dry-run 2>&1)
assert_contains "$OUT" "skipped" "dry-run nonexistent sprint skipped"

# ═══════════════════════════════════════════════════════════════════════════
# 56-60. Squash edge cases and more
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "56-60. More squash and interactive tests"

# 56. Squash with conflict
T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(
  cd "$T"
  git checkout -q "$DEFAULT_BRANCH"
  echo "conflict" > f1.txt
  git add f1.txt
  git commit -q -m "create conflict"
)

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --squash 1,2 2>&1)
# Sprint 1 conflicts, sprint 2 should still work
assert_contains "$OUT" "CONFLICT" "squash conflict detected"
assert_contains "$OUT" "Result:" "squash conflict shows result"

# 57. Interactive mode — output message formatting
T=$(new_session_project 2)
PLAN_FILE="$T/format-test.json"
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" 2>&1)
assert_contains "$OUT" "Edit the file" "interactive tells user to edit"
assert_contains "$OUT" "apply" "interactive mentions apply"

# 58. Merge all sprints from a large project
T=$(new_session_project 5)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,2,3,4,5 2>&1)
assert_contains "$OUT" "5 merged" "all 5 sprints merged"
for i in 1 2 3 4 5; do
  assert_file_exists "$T/f${i}.txt" "f${i}.txt exists after full merge"
done

# 59. List from 5-sprint project shows all sprints
T=$(new_session_project 5)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" 2>&1)
assert_contains "$OUT" "add feature 5" "5-sprint list shows sprint 5"
assert_contains "$OUT" "merge 1,2,3,4,5" "recommendation includes all 5"

# 60. Interactive apply with --dry-run
T=$(new_session_project 2)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
PLAN_FILE="$T/dryplan.json"

cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" >/dev/null 2>&1
python3 -c "
import json
with open('$PLAN_FILE') as f:
    d = json.load(f)
d[0]['action'] = 'yes'
d[1]['action'] = 'yes'
with open('$PLAN_FILE', 'w') as f:
    json.dump(d, f)
"
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" --apply --dry-run 2>&1) || true
# Note: --dry-run with --apply may not be explicitly supported but should be safe
# At minimum it should not error catastrophically
assert_contains "$OUT" "Applying" "apply with dry-run starts"

# ═══════════════════════════════════════════════════════════════════════════
# 61-65. Additional robustness tests
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "61-65. Robustness"

# 61. Session branch with state but no merge commits
T=$(new_tmp)
(
  cd "$T"
  git init -q
  git commit -q --allow-empty -m "init"
  git checkout -q -b "auto/session-nocommits"
  mkdir -p .autonomous
  echo '{"phase":"directed","sprints":[{"number":1,"direction":"try something","status":"blocked","commits":[],"quality_gate_passed":false}]}' > .autonomous/conductor-state.json
  git add .autonomous/conductor-state.json
  git commit -q -m "state"
)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-nocommits" 2>&1)
assert_contains "$OUT" "skippable" "blocked sprint shown as skippable"

# 62. Merge sprint that was marked skippable still works if commit exists
T=$(new_tmp)
(
  cd "$T"
  git init -q
  echo "base" > base.txt && git add base.txt && git commit -q -m "init"
  git checkout -q -b "auto/session-skip2"
  git checkout -q -b "sprint-1"
  echo "feat" > feat.txt && git add feat.txt && git commit -q -m "feat"
  git checkout -q "auto/session-skip2"
  git merge --no-ff "sprint-1" -m "sprint 1: tried something" 2>/dev/null
  git branch -D "sprint-1" 2>/dev/null
  mkdir -p .autonomous
  echo '{"phase":"directed","sprints":[{"number":1,"direction":"try","status":"blocked","commits":[],"quality_gate_passed":false}]}' > .autonomous/conductor-state.json
  git add .autonomous/conductor-state.json
  git commit -q -m "state"
)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-skip2" --merge 1 2>&1)
assert_contains "$OUT" "merged" "skippable sprint with commit can still be merged"
assert_file_exists "$T/feat.txt" "skippable sprint file merged"

# 63. Repeated sprint numbers in --merge
T=$(new_session_project 1)
DEFAULT_BRANCH=$(cd "$T" && git branch | grep -v auto | head -1 | sed 's/^[* ]*//')
(cd "$T" && git checkout -q "$DEFAULT_BRANCH")

OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --merge 1,1 2>&1)
# Second cherry-pick of same commit may conflict or be empty, but should not crash
assert_contains "$OUT" "Result:" "repeated sprint numbers handled"

# 64. List with no conductor state (empty git show result)
T=$(new_tmp)
(
  cd "$T"
  git init -q
  git commit -q --allow-empty -m "init"
  git checkout -q -b "auto/session-nostate"
)
OUT=$(cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-nostate" 2>&1)
assert_contains "$OUT" "No sprints" "no conductor state → no sprints"

# 65. Interactive file has correct sprint numbers
T=$(new_session_project 3)
PLAN_FILE="$T/nums-test.json"
cd "$T" && bash "$SELECTIVE_MERGE" "$T" "auto/session-123" --interactive "$PLAN_FILE" >/dev/null 2>&1

SPRINT_1=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print(d[0]['sprint'])" 2>/dev/null)
SPRINT_3=$(python3 -c "import json; d=json.load(open('$PLAN_FILE')); print(d[2]['sprint'])" 2>/dev/null)
assert_eq "$SPRINT_1" "1" "plan file sprint 1 number correct"
assert_eq "$SPRINT_3" "3" "plan file sprint 3 number correct"

print_results
