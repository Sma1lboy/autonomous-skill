#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$SCRIPT_DIR/../scripts/worktree.py"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_worktree.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: minimal git repo with one initial commit.
make_repo() {
  local p
  p=$(new_tmp)
  (cd "$p" && git init -q && git config user.email test@test && git config user.name test \
    && git commit -q --allow-empty -m init) >/dev/null
  echo "$p"
}

# ── 1. Help + unknown command ────────────────────────────────────────────

echo ""
echo "1. Help + unknown command"

HELP=$(python3 "$WT" --help 2>&1)
assert_contains "$HELP" "Usage: worktree.py" "--help shows usage"
assert_contains "$HELP" "create" "--help documents create"
assert_contains "$HELP" "remove" "--help documents remove"
assert_contains "$HELP" "ensure-gitignore" "--help documents ensure-gitignore"
assert_contains "$HELP" "prune" "--help documents prune"
assert_contains "$HELP" "path" "--help documents path"

if python3 "$WT" bogus "$(new_tmp)" 2>/dev/null; then
  fail "unknown command should fail"
else
  ok "unknown command rejected"
fi

# ── 2. ensure-gitignore ──────────────────────────────────────────────────

echo ""
echo "2. ensure-gitignore"

T=$(new_tmp)
# Empty project, no .gitignore
RESULT=$(python3 "$WT" ensure-gitignore "$T")
assert_eq "$RESULT" "added" "adds to fresh .gitignore"
assert_file_exists "$T/.gitignore" ".gitignore created"
assert_file_contains "$T/.gitignore" ".worktrees/" ".worktrees/ entry present"

# Idempotent
RESULT2=$(python3 "$WT" ensure-gitignore "$T")
assert_eq "$RESULT2" "already present" "second run is idempotent"
LINE_COUNT=$(grep -c "^\.worktrees" "$T/.gitignore" || echo 0)
assert_eq "$LINE_COUNT" "1" "no duplicate entry"

# Also detects .worktrees without trailing slash
T2=$(new_tmp)
echo ".worktrees" > "$T2/.gitignore"
RESULT3=$(python3 "$WT" ensure-gitignore "$T2")
assert_eq "$RESULT3" "already present" "detects bare .worktrees"

# Preserves existing content
T3=$(new_tmp)
echo "node_modules/" > "$T3/.gitignore"
echo "*.log" >> "$T3/.gitignore"
python3 "$WT" ensure-gitignore "$T3" > /dev/null
assert_file_contains "$T3/.gitignore" "node_modules/" "preserves existing entries"
assert_file_contains "$T3/.gitignore" "\*.log" "preserves all existing entries"
assert_file_contains "$T3/.gitignore" ".worktrees/" "adds new entry"

# ── 3. create: basic flow ────────────────────────────────────────────────

echo ""
echo "3. create basic flow"

T=$(make_repo)
WT_PATH=$(python3 "$WT" create "$T" 1 "auto/test-sprint-1")
assert_contains "$WT_PATH" ".worktrees/sprint-1" "path follows convention"
assert_file_exists "$WT_PATH/.git" "worktree has .git pointer"

# Symlink to main .autonomous
[ -L "$WT_PATH/.autonomous" ] && ok "worktree's .autonomous is a symlink" || fail ".autonomous not a symlink"

# Symlink target is main tree's .autonomous
mkdir -p "$T/.autonomous"
echo "marker" > "$T/.autonomous/test.txt"
CONTENT=$(cat "$WT_PATH/.autonomous/test.txt")
assert_eq "$CONTENT" "marker" "symlink resolves to main tree's .autonomous"

# git worktree list shows it
LIST=$(python3 "$WT" list "$T")
assert_contains "$LIST" "auto/test-sprint-1" "list shows the new sprint branch"

# Branch was created
BRANCH_IN_WT=$(cd "$WT_PATH" && git rev-parse --abbrev-ref HEAD)
assert_eq "$BRANCH_IN_WT" "auto/test-sprint-1" "worktree checked out on new branch"

# Main tree stayed on original branch
MAIN_BRANCH=$(cd "$T" && git rev-parse --abbrev-ref HEAD)
[ "$MAIN_BRANCH" != "auto/test-sprint-1" ] && ok "main tree NOT switched" || fail "main tree unexpectedly moved"

# ── 4. create: validation ────────────────────────────────────────────────

echo ""
echo "4. create validation"

T=$(make_repo)
if python3 "$WT" create "$T" 2>/dev/null; then
  fail "create without sprint-num should fail"
else
  ok "create without sprint-num rejected"
fi

if python3 "$WT" create "$T" notanumber "branch" 2>/dev/null; then
  fail "non-integer sprint-num should fail"
else
  ok "non-integer sprint-num rejected"
fi

if python3 "$WT" create "$T" 1 "" 2>/dev/null; then
  fail "empty branch-name should fail"
else
  ok "empty branch-name rejected"
fi

# Non-git directory
TNG=$(new_tmp)
if python3 "$WT" create "$TNG" 1 "auto/x" 2>/dev/null; then
  fail "non-git dir should fail"
else
  ok "non-git dir rejected"
fi

# ── 5. create: collision detection ───────────────────────────────────────

echo ""
echo "5. create collision"

T=$(make_repo)
python3 "$WT" create "$T" 1 "auto/sprint-1" > /dev/null
if python3 "$WT" create "$T" 1 "auto/sprint-1-dup" 2>/dev/null; then
  fail "duplicate sprint-num should fail"
else
  ok "duplicate sprint-num rejected"
fi

# ── 6. remove: basic flow ────────────────────────────────────────────────

echo ""
echo "6. remove basic flow"

T=$(make_repo)
python3 "$WT" create "$T" 1 "auto/test-sprint-1" > /dev/null
RESULT=$(python3 "$WT" remove "$T" 1)
assert_contains "$RESULT" "removed" "remove reports success"
[ ! -d "$T/.worktrees/sprint-1" ] && ok "worktree directory gone" || fail "worktree still present"

# Idempotent
RESULT2=$(python3 "$WT" remove "$T" 1)
assert_contains "$RESULT2" "not present" "remove on non-existent is idempotent"

# git no longer tracks it
LIST=$(python3 "$WT" list "$T")
assert_not_contains "$LIST" "sprint-1" "git worktree list no longer shows it"

# ── 7. remove: with uncommitted changes ──────────────────────────────────

echo ""
echo "7. remove with dirty state"

T=$(make_repo)
WT_PATH=$(python3 "$WT" create "$T" 2 "auto/dirty")
# Write an uncommitted file
echo "dirty" > "$WT_PATH/wip.txt"
# --force path: should still succeed
RESULT=$(python3 "$WT" remove "$T" 2)
assert_contains "$RESULT" "removed" "remove --force handles dirty worktree"
[ ! -d "$T/.worktrees/sprint-2" ] && ok "dirty worktree removed" || fail "dirty worktree survived"

# ── 8. remove: validation ────────────────────────────────────────────────

echo ""
echo "8. remove validation"

T=$(make_repo)
if python3 "$WT" remove "$T" 2>/dev/null; then
  fail "remove without sprint-num should fail"
else
  ok "remove without sprint-num rejected"
fi

if python3 "$WT" remove "$T" notanumber 2>/dev/null; then
  fail "non-integer sprint-num should fail"
else
  ok "remove non-integer sprint-num rejected"
fi

# ── 9. path command ──────────────────────────────────────────────────────

echo ""
echo "9. path command"

T=$(make_repo)
P=$(python3 "$WT" path "$T" 5)
assert_contains "$P" ".worktrees/sprint-5" "path returns expected location"

# path doesn't create anything
[ ! -d "$T/.worktrees" ] && ok "path is a pure query (no side effects)" || fail "path created directory"

# ── 10. list on non-git dir ──────────────────────────────────────────────

echo ""
echo "10. list error paths"

TNG=$(new_tmp)
if python3 "$WT" list "$TNG" 2>/dev/null; then
  fail "list on non-git dir should fail"
else
  ok "list on non-git rejected"
fi

# ── 11. Multiple sprint worktrees coexist ────────────────────────────────

echo ""
echo "11. Multiple sprints coexist"

T=$(make_repo)
WT1=$(python3 "$WT" create "$T" 1 "auto/s-1")
WT2=$(python3 "$WT" create "$T" 2 "auto/s-2")
WT3=$(python3 "$WT" create "$T" 3 "auto/s-3")

LIST=$(python3 "$WT" list "$T")
COUNT=$(echo "$LIST" | grep -c "sprint-" || echo 0)
assert_eq "$COUNT" "3" "three sprint worktrees listed"

# Each worktree is on its own branch
B1=$(cd "$WT1" && git rev-parse --abbrev-ref HEAD)
B2=$(cd "$WT2" && git rev-parse --abbrev-ref HEAD)
B3=$(cd "$WT3" && git rev-parse --abbrev-ref HEAD)
assert_eq "$B1" "auto/s-1" "sprint-1 branch correct"
assert_eq "$B2" "auto/s-2" "sprint-2 branch correct"
assert_eq "$B3" "auto/s-3" "sprint-3 branch correct"

# Remove one, others stay
python3 "$WT" remove "$T" 2 > /dev/null
LIST2=$(python3 "$WT" list "$T")
assert_contains "$LIST2" "auto/s-1" "sprint-1 survives after sprint-2 removed"
assert_contains "$LIST2" "auto/s-3" "sprint-3 survives after sprint-2 removed"
assert_not_contains "$LIST2" "auto/s-2" "sprint-2 gone"

# ── 12. Prune handles external worktree deletion ────────────────────────

echo ""
echo "12. Prune handles external deletion"

T=$(make_repo)
WT_PATH=$(python3 "$WT" create "$T" 1 "auto/vanish")
# Simulate someone rm -rf'ing the worktree outside git's knowledge
rm -rf "$WT_PATH"
# git worktree list would show it as "prunable"
python3 "$WT" prune "$T" > /dev/null
LIST=$(python3 "$WT" list "$T")
assert_not_contains "$LIST" "vanish" "prune removed the stale worktree entry"

# ── 13. Integration: .autonomous symlink survives writes ─────────────────

echo ""
echo "13. .autonomous symlink write-through"

T=$(make_repo)
mkdir -p "$T/.autonomous"
WT_PATH=$(python3 "$WT" create "$T" 1 "auto/wts")

# Write from worktree side — should land in main tree
echo '{"status":"idle"}' > "$WT_PATH/.autonomous/comms.json"
assert_file_contains "$T/.autonomous/comms.json" "idle" "worktree write visible in main tree"

# Write from main side — should be visible in worktree
echo '{"sprint":3}' > "$T/.autonomous/conductor-state.json"
READBACK=$(cat "$WT_PATH/.autonomous/conductor-state.json")
assert_contains "$READBACK" "sprint" "main tree write visible in worktree"

# ── 14. Adversarial regression (Codex review findings) ──────────────────

echo ""
echo "14. Adversarial regression (Codex findings)"

# P1: .worktrees/ pre-existing as a symlink must be refused
T=$(make_repo)
VICTIM=$(new_tmp)
mkdir -p "$VICTIM/would-be-pwned"
ln -s "$VICTIM" "$T/.worktrees"
if python3 "$WT" create "$T" 1 "auto/symlink-escape" 2>/dev/null; then
  fail "create must refuse when .worktrees/ is a pre-existing symlink"
else
  ok "create refuses symlinked .worktrees/"
fi
[ ! -d "$VICTIM/sprint-1" ] && ok "no escape: nothing written into symlink target" || fail "symlink escape occurred"

# .autonomous/ pre-existing as a symlink must be refused
T=$(make_repo)
VICTIM=$(new_tmp)
ln -s "$VICTIM" "$T/.autonomous"
if python3 "$WT" create "$T" 1 "auto/autonomous-escape" 2>/dev/null; then
  fail "create must refuse when .autonomous/ is a pre-existing symlink"
else
  ok "create refuses symlinked .autonomous/"
fi

# P1: remove requires a git repo
TNG=$(new_tmp)
mkdir -p "$TNG/.worktrees/sprint-1"
echo "user data" > "$TNG/.worktrees/sprint-1/important.txt"
if python3 "$WT" remove "$TNG" 1 2>/dev/null; then
  fail "remove on non-git directory should fail"
else
  ok "remove rejects non-git directory"
fi
[ -f "$TNG/.worktrees/sprint-1/important.txt" ] && \
  ok "user data untouched when remove refused" || \
  fail "CATASTROPHIC: user data deleted"

# P1: remove refuses to delete a directory that isn't a registered worktree
T=$(make_repo)
mkdir -p "$T/.worktrees/sprint-99"
echo "not a real worktree" > "$T/.worktrees/sprint-99/data.txt"
if python3 "$WT" remove "$T" 99 2>/dev/null; then
  fail "remove must refuse unregistered directory"
else
  ok "remove refuses directory not tracked by git worktree"
fi
[ -f "$T/.worktrees/sprint-99/data.txt" ] && ok "unregistered dir preserved" || fail "unregistered dir deleted"

# P2: branch name validation (delegates to git check-ref-format)
T=$(make_repo)
for BAD_NAME in "-bad" "bad..name" "bad~name" "HEAD"; do
  if python3 "$WT" create "$T" 99 "$BAD_NAME" 2>/dev/null; then
    fail "invalid branch name '$BAD_NAME' should be rejected"
  else
    ok "invalid branch name rejected: $BAD_NAME"
  fi
done

# P2: sprint-num must be >= 1
T=$(make_repo)
if python3 "$WT" create "$T" 0 "auto/zero" 2>/dev/null; then
  fail "sprint-num 0 should be rejected"
else
  ok "sprint-num 0 rejected"
fi
if python3 "$WT" create "$T" -5 "auto/neg" 2>/dev/null; then
  fail "negative sprint-num should be rejected"
else
  ok "negative sprint-num rejected"
fi

# Regression: idempotent remove doesn't lie about which case it hit
T=$(make_repo)
python3 "$WT" create "$T" 1 "auto/lie-check" > /dev/null
OUT=$(python3 "$WT" remove "$T" 1)
assert_contains "$OUT" "removed" "success message on real removal"
OUT2=$(python3 "$WT" remove "$T" 1)
assert_contains "$OUT2" "not present" "idempotent remove says 'not present', not 'removed'"

# P1 verification: merge-sprint.py --keep-branch flag exists + skips branch -D
T=$(make_repo)
(cd "$T" && git checkout -b auto/session-test) > /dev/null 2>&1
python3 "$WT" create "$T" 1 "auto/keeptest-sprint-1" > /dev/null
# Add a commit in the sprint worktree so merge has something to do
(cd "$T/.worktrees/sprint-1" && echo "data" > f.txt && git add f.txt && \
  git -c user.email=t@t -c user.name=t commit -q -m "sprint work") > /dev/null
MERGE_OUT=$(python3 "$SCRIPT_DIR/../scripts/merge-sprint.py" --keep-branch \
  "auto/session-test" "auto/keeptest-sprint-1" 1 complete "test merge" \
  --project-dir "$T" 2>&1)
# Branch should STILL exist because we used --keep-branch
BRANCH_EXISTS=$(cd "$T" && git show-ref --verify --quiet refs/heads/auto/keeptest-sprint-1 && echo yes || echo no)
assert_eq "$BRANCH_EXISTS" "yes" "--keep-branch preserves sprint branch after merge"
# Clean up
python3 "$WT" remove "$T" 1 > /dev/null
(cd "$T" && git branch -D auto/keeptest-sprint-1) > /dev/null 2>&1

print_results
