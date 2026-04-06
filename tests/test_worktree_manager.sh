#!/usr/bin/env bash
# Tests for worktree-manager.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WTM="$SCRIPT_DIR/../scripts/worktree-manager.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_worktree_manager.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create a real git repo in a temp dir with an initial commit
init_repo() {
  local d
  d=$(new_tmp)
  git -C "$d" init -q
  git -C "$d" commit --allow-empty -m "init" -q
  echo "$d"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. Help/usage
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Help/usage"
OUT=$(bash "$WTM" --help 2>&1)
assert_contains "$OUT" "Usage" "help prints usage"
assert_contains "$OUT" "create" "help mentions create"
assert_contains "$OUT" "destroy" "help mentions destroy"
assert_contains "$OUT" "list" "help mentions list"
assert_contains "$OUT" "merge" "help mentions merge"
assert_contains "$OUT" "cleanup" "help mentions cleanup"
assert_contains "$OUT" "path" "help mentions path"

# -h also works
OUT2=$(bash "$WTM" -h 2>&1)
assert_contains "$OUT2" "Usage" "-h prints usage"

# help subcommand
OUT3=$(bash "$WTM" help 2>&1)
assert_contains "$OUT3" "Usage" "help subcommand prints usage"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Create worktree
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Create worktree"
REPO=$(init_repo)
OUT=$(bash "$WTM" create "$REPO" "test-branch-1" 2>&1)
assert_contains "$OUT" "WORKTREE_PATH=" "create prints WORKTREE_PATH"
WT_PATH=$(echo "$OUT" | grep '^WORKTREE_PATH=' | head -1 | cut -d= -f2-)
[ -d "$WT_PATH" ] && ok "worktree directory exists" || fail "worktree directory missing"
# Branch should exist in git
git -C "$REPO" rev-parse --verify "test-branch-1" &>/dev/null && ok "branch exists in git" || fail "branch not found"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Create with slashes in branch name (sanitization)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Branch name sanitization"
REPO=$(init_repo)
OUT=$(bash "$WTM" create "$REPO" "auto/sprint-1" 2>&1)
WT_PATH=$(echo "$OUT" | grep '^WORKTREE_PATH=' | head -1 | cut -d= -f2-)
assert_contains "$WT_PATH" "auto--sprint-1" "slash replaced with --"
[ -d "$WT_PATH" ] && ok "sanitized worktree dir exists" || fail "sanitized worktree dir missing"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Create duplicate fails gracefully
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Duplicate create fails"
REPO=$(init_repo)
bash "$WTM" create "$REPO" "dup-branch" &>/dev/null
OUT=$(bash "$WTM" create "$REPO" "dup-branch" 2>&1 || true)
assert_contains "$OUT" "already exists" "duplicate create reports error"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Destroy removes worktree
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Destroy worktree"
REPO=$(init_repo)
OUT=$(bash "$WTM" create "$REPO" "destroy-me" 2>&1)
WT_PATH=$(echo "$OUT" | grep '^WORKTREE_PATH=' | head -1 | cut -d= -f2-)
[ -d "$WT_PATH" ] && ok "worktree exists before destroy" || fail "worktree missing before destroy"

bash "$WTM" destroy "$REPO" "destroy-me" &>/dev/null
[ ! -d "$WT_PATH" ] && ok "worktree dir removed" || fail "worktree dir still exists after destroy"

# Verify worktree is gone from git worktree list
WT_LIST=$(git -C "$REPO" worktree list --porcelain 2>/dev/null)
echo "$WT_LIST" | grep -q "destroy-me" && fail "worktree still in git list" || ok "worktree gone from git list"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Destroy non-existent is safe
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Destroy non-existent"
REPO=$(init_repo)
OUT=$(bash "$WTM" destroy "$REPO" "nonexistent-branch" 2>&1)
assert_contains "$OUT" "nothing to destroy" "non-existent destroy is safe"

# ═══════════════════════════════════════════════════════════════════════════
# 7. List with no worktrees returns empty JSON array
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. List empty"
REPO=$(init_repo)
OUT=$(bash "$WTM" list "$REPO" 2>&1)
assert_eq "$OUT" "[]" "empty list returns []"

# ═══════════════════════════════════════════════════════════════════════════
# 8. List with worktrees returns JSON objects
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. List with worktrees"
REPO=$(init_repo)
bash "$WTM" create "$REPO" "list-branch-1" &>/dev/null
bash "$WTM" create "$REPO" "list-branch-2" &>/dev/null
OUT=$(bash "$WTM" list "$REPO" 2>&1)
# Should be a JSON array with 2 entries
COUNT=$(echo "$OUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
assert_eq "$COUNT" "2" "list shows 2 worktrees"
# Each entry should have path, branch, head
HAS_FIELDS=$(echo "$OUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ok = all('path' in d and 'branch' in d and 'head' in d for d in data)
print('yes' if ok else 'no')
" 2>/dev/null || echo "no")
assert_eq "$HAS_FIELDS" "yes" "list entries have path, branch, head"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Merge brings changes into target
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Merge"
REPO=$(init_repo)
# Create a target branch
git -C "$REPO" checkout -b "target-branch" -q
git -C "$REPO" checkout - -q

# Create worktree and make a commit in it
OUT=$(bash "$WTM" create "$REPO" "merge-src" 2>&1)
WT_PATH=$(echo "$OUT" | grep '^WORKTREE_PATH=' | head -1 | cut -d= -f2-)
touch "$WT_PATH/new-file.txt"
git -C "$WT_PATH" add new-file.txt
git -C "$WT_PATH" commit -m "add new-file" -q

# Merge into target
bash "$WTM" merge "$REPO" "merge-src" "target-branch" &>/dev/null

# Verify file exists on target branch
git -C "$REPO" checkout target-branch -q
[ -f "$REPO/new-file.txt" ] && ok "merged file exists on target" || fail "merged file missing from target"
git -C "$REPO" checkout - -q 2>/dev/null || true

# Worktree should be destroyed
[ ! -d "$WT_PATH" ] && ok "worktree destroyed after merge" || fail "worktree still exists after merge"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Merge with no commits succeeds
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Merge with no commits"
REPO=$(init_repo)
git -C "$REPO" checkout -b "empty-target" -q
git -C "$REPO" checkout - -q
bash "$WTM" create "$REPO" "empty-src" &>/dev/null
# Don't make any commits — merge should still work (no-op merge or already up-to-date)
OUT=$(bash "$WTM" merge "$REPO" "empty-src" "empty-target" 2>&1 || true)
# Should not fail catastrophically
assert_contains "$OUT" "erge\|already up" "no-commit merge handled"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Cleanup removes stale worktrees
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Cleanup"
REPO=$(init_repo)
bash "$WTM" create "$REPO" "cleanup-branch" &>/dev/null
WT_PATH="$REPO/.autonomous/worktrees/cleanup-branch"
# Manually corrupt the worktree by removing its .git file
rm -f "$WT_PATH/.git" 2>/dev/null || true
# Run cleanup
OUT=$(bash "$WTM" cleanup "$REPO" 2>&1)
assert_contains "$OUT" "lean" "cleanup reports results"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Path returns correct path
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Path command"
REPO=$(init_repo)
OUT=$(bash "$WTM" path "$REPO" "some-branch")
assert_eq "$OUT" "$REPO/.autonomous/worktrees/some-branch" "path returns correct dir"

# Path with slashes
OUT2=$(bash "$WTM" path "$REPO" "auto/sprint-5")
assert_eq "$OUT2" "$REPO/.autonomous/worktrees/auto--sprint-5" "path sanitizes slashes"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Invalid command exits 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Invalid command"
OUT=$(bash "$WTM" bogus 2>&1 || true)
assert_contains "$OUT" "unknown command" "invalid command reports error"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Missing args print usage
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Missing args"
OUT=$(bash "$WTM" 2>&1 || true)
assert_contains "$OUT" "command required" "no args reports error"
assert_contains "$OUT" "help" "no args mentions help"

OUT2=$(bash "$WTM" create 2>&1 || true)
assert_contains "$OUT2" "project_dir required\|Usage\|ERROR" "create without args reports error"

# ═══════════════════════════════════════════════════════════════════════════
# 15. Create with existing branch (not new)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Create with pre-existing branch"
REPO=$(init_repo)
git -C "$REPO" branch existing-branch -q
OUT=$(bash "$WTM" create "$REPO" "existing-branch" 2>&1)
assert_contains "$OUT" "WORKTREE_PATH=" "create uses existing branch"
WT_PATH=$(echo "$OUT" | grep '^WORKTREE_PATH=' | head -1 | cut -d= -f2-)
[ -d "$WT_PATH" ] && ok "worktree dir for existing branch exists" || fail "worktree dir for existing branch missing"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Cleanup with no worktrees dir is safe
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Cleanup with no worktrees dir"
REPO=$(init_repo)
OUT=$(bash "$WTM" cleanup "$REPO" 2>&1)
assert_contains "$OUT" "nothing to clean" "cleanup with no dir is safe"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Merge with non-existent branch fails
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Merge non-existent branch"
REPO=$(init_repo)
OUT=$(bash "$WTM" merge "$REPO" "no-such-branch" "main" 2>&1 || true)
assert_contains "$OUT" "does not exist" "merge reports non-existent branch"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Multiple worktrees coexist
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Multiple worktrees coexist"
REPO=$(init_repo)
bash "$WTM" create "$REPO" "wt-a" &>/dev/null
bash "$WTM" create "$REPO" "wt-b" &>/dev/null
bash "$WTM" create "$REPO" "wt-c" &>/dev/null
LIST=$(bash "$WTM" list "$REPO" 2>&1)
COUNT=$(echo "$LIST" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
assert_eq "$COUNT" "3" "three worktrees coexist"

# Destroy one, others remain
bash "$WTM" destroy "$REPO" "wt-b" &>/dev/null
LIST2=$(bash "$WTM" list "$REPO" 2>&1)
COUNT2=$(echo "$LIST2" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
assert_eq "$COUNT2" "2" "two worktrees remain after destroying one"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Special characters in branch names
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Special characters in branch names"
REPO=$(init_repo)
OUT=$(bash "$WTM" path "$REPO" "feat/add-auth@v2")
# @ should be stripped, / -> --
assert_contains "$OUT" "feat--add-authv2" "special chars sanitized"
assert_not_contains "$OUT" "@" "@ stripped from path"

print_results
