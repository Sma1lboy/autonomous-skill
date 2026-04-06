#!/usr/bin/env bash
# Tests for dispatch.sh worktree isolation mode

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.sh"

# Use the mock claude binary from tests/ dir
export PATH="$SCRIPT_DIR:$PATH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_dispatch_worktree.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create a real git repo in a temp dir with an initial commit
init_repo() {
  local d
  d=$(new_tmp)
  git -C "$d" init -q
  git -C "$d" commit --allow-empty -m "init" -q
  mkdir -p "$d/.autonomous"
  echo "test prompt" > "$d/.autonomous/prompt.md"
  echo "$d"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. Default DISPATCH_ISOLATION is branch — wrapper cd's to project dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Default isolation is branch"
T=$(init_repo)
unset DISPATCH_ISOLATION 2>/dev/null || true
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-1" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-wt-test-1.sh"
assert_file_exists "$WRAPPER" "wrapper created"
assert_file_contains "$WRAPPER" "$T" "wrapper cd's to project dir"
# Should NOT have worktree path
assert_file_not_contains "$WRAPPER" ".autonomous/worktrees" "no worktree path in branch mode"

# ═══════════════════════════════════════════════════════════════════════════
# 2. DISPATCH_ISOLATION=worktree creates worktree, wrapper cd's to it
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Worktree mode creates worktree"
T=$(init_repo)
OUT=$(DISPATCH_ISOLATION=worktree bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-2" 2>&1 &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true
echo "done")

WRAPPER="$T/.autonomous/run-wt-test-2.sh"
assert_file_exists "$WRAPPER" "wrapper created in worktree mode"
# Wrapper should cd to the worktree path
assert_file_contains "$WRAPPER" ".autonomous/worktrees" "wrapper cd's to worktree path"

# Worktree directory should exist
WT_DIR="$T/.autonomous/worktrees/auto--worker-wt-test-2"
[ -d "$WT_DIR" ] && ok "worktree directory created" || fail "worktree directory missing"

# ═══════════════════════════════════════════════════════════════════════════
# 3. skill-config.json dispatch_isolation overrides env var
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Config overrides env var"
T=$(init_repo)
echo '{"dispatch_isolation": "worktree"}' > "$T/.autonomous/skill-config.json"
# Env says branch, config says worktree — config wins
OUT=$(DISPATCH_ISOLATION=branch bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-3" 2>&1 &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true
echo "done")

WRAPPER="$T/.autonomous/run-wt-test-3.sh"
assert_file_exists "$WRAPPER" "wrapper created with config override"
assert_file_contains "$WRAPPER" ".autonomous/worktrees" "config worktree overrides env branch"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Worktree branch file created
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Worktree branch file created"
T=$(init_repo)
DISPATCH_ISOLATION=worktree bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-4" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

BRANCH_FILE="$T/.autonomous/worker-worktree-wt-test-4.txt"
assert_file_exists "$BRANCH_FILE" "worktree branch file created"
assert_file_contains "$BRANCH_FILE" "auto/worker-wt-test-4" "branch file has correct branch name"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Branch mode unchanged (backward compat)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Branch mode backward compat"
T=$(init_repo)
unset DISPATCH_ISOLATION 2>/dev/null || true
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-5" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-wt-test-5.sh"
# Wrapper should cd to PROJECT_DIR directly
FIRST_CD=$(grep '^cd ' "$WRAPPER" | head -1 || true)
assert_contains "$FIRST_CD" "$T" "branch mode cd's to project dir"
# No worktree branch file
BRANCH_FILE="$T/.autonomous/worker-worktree-wt-test-5.txt"
assert_file_not_exists "$BRANCH_FILE" "no worktree branch file in branch mode"

# Timeout should still work normally
assert_file_contains "$WRAPPER" "600" "timeout still present in branch mode"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Config dispatch_isolation=branch keeps branch mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Config branch keeps branch mode"
T=$(init_repo)
echo '{"dispatch_isolation": "branch"}' > "$T/.autonomous/skill-config.json"
DISPATCH_ISOLATION=worktree bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-6" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-wt-test-6.sh"
assert_file_not_contains "$WRAPPER" ".autonomous/worktrees" "config branch overrides env worktree"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Invalid DISPATCH_ISOLATION falls back to branch
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Invalid isolation falls back to branch"
T=$(init_repo)
OUT=$(DISPATCH_ISOLATION=invalid bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-7" 2>&1 &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true
echo "done")

WRAPPER="$T/.autonomous/run-wt-test-7.sh"
assert_file_exists "$WRAPPER" "wrapper created with invalid isolation"
assert_file_not_contains "$WRAPPER" ".autonomous/worktrees" "invalid isolation falls back to branch"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Worktree mode + worker-id: comms path still in original project dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Comms path stays in original project dir"
T=$(init_repo)
DISPATCH_ISOLATION=worktree bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-8" "w8" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-wt-test-8.sh"
# Comms path should reference PROJECT_DIR, not worktree
assert_file_contains "$WRAPPER" "$T/.autonomous/comms-w8.json" "comms path in original project dir"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Worktree mode + timeout both work together
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Worktree + timeout coexist"
T=$(init_repo)
echo '{"dispatch_isolation": "worktree", "worker_timeout": 999}' > "$T/.autonomous/skill-config.json"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "wt-test-9" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-wt-test-9.sh"
assert_file_contains "$WRAPPER" ".autonomous/worktrees" "worktree isolation active"
assert_file_contains "$WRAPPER" "999" "custom timeout coexists with worktree"

print_results
