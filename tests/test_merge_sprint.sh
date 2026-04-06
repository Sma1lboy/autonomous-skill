#!/usr/bin/env bash
# Tests for scripts/merge-sprint.sh — sprint branch merge/discard logic.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE_SPRINT="$SCRIPT_DIR/../scripts/merge-sprint.sh"

# Create a git project with a session branch and sprint branch.
# Returns: project_dir
# After calling, cwd is project_dir on sprint branch.
new_sprint_project() {
  local d; d=$(new_tmp)
  (
    cd "$d"
    git init -q
    git commit -q --allow-empty -m "init"
    git checkout -q -b "auto/session-12345"
    git checkout -q -b "auto/sprint-1"
  )
  echo "$d"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_merge_sprint.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Complete status with commits → merge
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Complete with commits → merge"

T=$(new_sprint_project)
(
  cd "$T"
  # Make a commit on the sprint branch
  echo "feature" > feature.txt
  git add feature.txt
  git commit -q -m "add feature"
)

OUT=$(cd "$T" && bash "$MERGE_SPRINT" "auto/session-12345" "auto/sprint-1" "1" "complete" "added new feature" 2>&1)
assert_contains "$OUT" "merged" "output says merged"

# Verify merge commit exists on session branch
MERGE_MSG=$(cd "$T" && git log --oneline -1)
assert_contains "$MERGE_MSG" "sprint 1" "merge commit contains sprint number"
assert_contains "$MERGE_MSG" "added new feature" "merge commit contains summary"

# Verify we're on the session branch
BRANCH=$(cd "$T" && git branch --show-current)
assert_eq "$BRANCH" "auto/session-12345" "now on session branch"

# Verify feature file exists after merge
assert_file_exists "$T/feature.txt" "feature file exists after merge"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Complete status with NO commits → skip
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Complete with no commits → skip"

T=$(new_sprint_project)
# No commits on sprint branch beyond what session branch has

OUT=$(cd "$T" && bash "$MERGE_SPRINT" "auto/session-12345" "auto/sprint-1" "2" "complete" "nothing done" 2>&1)
assert_contains "$OUT" "no commits" "output says no commits"

BRANCH=$(cd "$T" && git branch --show-current)
assert_eq "$BRANCH" "auto/session-12345" "back on session branch"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Blocked status → discard
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Blocked → discard"

T=$(new_sprint_project)
(
  cd "$T"
  echo "wip" > wip.txt
  git add wip.txt
  git commit -q -m "wip commit"
)

OUT=$(cd "$T" && bash "$MERGE_SPRINT" "auto/session-12345" "auto/sprint-1" "3" "blocked" "hit a wall" 2>&1)
assert_contains "$OUT" "discarded" "output says discarded"
assert_contains "$OUT" "blocked" "output mentions blocked status"

# Verify WIP file is NOT on session branch (not merged)
assert_file_not_exists "$T/wip.txt" "blocked sprint work not merged"

BRANCH=$(cd "$T" && git branch --show-current)
assert_eq "$BRANCH" "auto/session-12345" "back on session branch after discard"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Sprint branch deleted after merge
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Sprint branch deleted after merge"

T=$(new_sprint_project)
(
  cd "$T"
  echo "x" > x.txt
  git add x.txt
  git commit -q -m "add x"
)

cd "$T" && bash "$MERGE_SPRINT" "auto/session-12345" "auto/sprint-1" "4" "complete" "done" >/dev/null 2>&1

BRANCHES=$(cd "$T" && git branch)
assert_not_contains "$BRANCHES" "auto/sprint-1" "sprint branch deleted after merge"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Sprint branch deleted after discard
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Sprint branch deleted after discard"

T=$(new_sprint_project)

cd "$T" && bash "$MERGE_SPRINT" "auto/session-12345" "auto/sprint-1" "5" "blocked" "blocked" >/dev/null 2>&1

BRANCHES=$(cd "$T" && git branch)
assert_not_contains "$BRANCHES" "auto/sprint-1" "sprint branch deleted after discard"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Partial status with commits → merge
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Partial with commits → merge"

T=$(new_sprint_project)
(
  cd "$T"
  echo "partial" > partial.txt
  git add partial.txt
  git commit -q -m "partial work"
)

OUT=$(cd "$T" && bash "$MERGE_SPRINT" "auto/session-12345" "auto/sprint-1" "6" "partial" "partial progress" 2>&1)
assert_contains "$OUT" "merged" "partial with commits → merged"
assert_file_exists "$T/partial.txt" "partial work merged"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Unknown status → discard
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Unknown status → discard"

T=$(new_sprint_project)
(
  cd "$T"
  echo "unknown" > unknown.txt
  git add unknown.txt
  git commit -q -m "unknown work"
)

OUT=$(cd "$T" && bash "$MERGE_SPRINT" "auto/session-12345" "auto/sprint-1" "7" "unknown" "mystery" 2>&1)
assert_contains "$OUT" "discarded" "unknown status → discarded"
assert_file_not_exists "$T/unknown.txt" "unknown status work not merged"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Default summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Default summary fallback"

T=$(new_sprint_project)
(
  cd "$T"
  echo "y" > y.txt
  git add y.txt
  git commit -q -m "add y"
)

# Pass empty summary to test default
OUT=$(cd "$T" && bash "$MERGE_SPRINT" "auto/session-12345" "auto/sprint-1" "8" "complete" "" 2>&1)
MERGE_MSG=$(cd "$T" && git log --oneline -1)
assert_contains "$MERGE_MSG" "sprint 8" "default summary includes sprint number"

# ═══════════════════════════════════════════════════════════════════════════
# 9. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. --help flag"

HELP=$(bash "$MERGE_SPRINT" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
assert_contains "$HELP" "session_branch" "--help mentions session_branch"
assert_contains "$HELP" "sprint_branch" "--help mentions sprint_branch"
assert_contains "$HELP" "status" "--help mentions status"

bash "$MERGE_SPRINT" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 10. -h short flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. -h short flag"

HELP_SHORT=$(bash "$MERGE_SPRINT" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h shows Usage"

bash "$MERGE_SPRINT" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

print_results
