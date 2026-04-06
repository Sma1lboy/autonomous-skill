#!/usr/bin/env bash
# test_edge_cases.sh — Edge case tests: non-git dirs, empty repos, missing deps,
# corrupted JSON, long inputs, special characters in paths.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$SCRIPT_DIR/scripts"

# ── 1. Non-git directory ──────────────────────────────────────────────────────
echo "=== Non-git directory ==="

tmp=$(new_tmp)
plain_dir="$tmp/not-a-repo"
mkdir -p "$plain_dir"

# conductor-state.sh init works without git (just writes JSON)
bash "$SCRIPTS/conductor-state.sh" init "$plain_dir" "test mission" 5 >/dev/null 2>&1 || true
assert_file_exists "$plain_dir/.autonomous/conductor-state.json" "conductor-state.sh init creates state in non-git dir"

# write-summary.sh handles non-git dir gracefully (writes summary with empty commits)
rc=0; out=$(bash "$SCRIPTS/write-summary.sh" "$plain_dir" "complete" "test summary" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "write-summary.sh handles non-git dir (rc=$rc)" \
                    || fail "write-summary.sh crashed in non-git dir (rc=$rc)"
assert_file_exists "$plain_dir/.autonomous/sprint-summary.json" "write-summary.sh creates summary in non-git dir"

# session-init.sh needs git checkout — should fail in non-git dir
rc=0; out=$(bash "$SCRIPTS/session-init.sh" "$plain_dir" "$SCRIPT_DIR" "test" 3 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "session-init.sh exits non-zero in non-git dir" \
                  || fail "session-init.sh should fail in non-git dir"

# startup.sh should still output SCRIPT_DIR even in non-git (it's tolerant)
out=$(bash "$SCRIPTS/startup.sh" "$plain_dir" 2>&1) || true
assert_contains "$out" "SCRIPT_DIR=" "startup.sh outputs SCRIPT_DIR in non-git dir"

# detect-framework.sh in non-git dir — should produce "unknown" or fail gracefully
rc=0; out=$(bash "$SCRIPTS/detect-framework.sh" "$plain_dir" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  assert_contains "$out" "unknown" "detect-framework.sh returns unknown for plain dir"
else
  [ "$rc" -lt 128 ] && ok "detect-framework.sh exits gracefully for non-git dir (rc=$rc)" \
                      || fail "detect-framework.sh crashed in non-git dir (rc=$rc)"
fi

# build-worker-hints.sh in non-git dir
rc=0; out=$(bash "$SCRIPTS/build-worker-hints.sh" "$plain_dir" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "build-worker-hints.sh handles non-git dir (rc=$rc)" \
                    || fail "build-worker-hints.sh crashed in non-git dir (rc=$rc)"

# ── 2. Empty repo (git init, no commits) ─────────────────────────────────────
echo "=== Empty repo (no commits) ==="

tmp2=$(new_tmp)
empty_repo="$tmp2/empty-repo"
mkdir -p "$empty_repo"
git -C "$empty_repo" init -q

# explore-scan.sh in empty repo — should handle empty git log
mkdir -p "$empty_repo/.autonomous"
cat > "$empty_repo/.autonomous/conductor-state.json" << 'CSTATE'
{"phase":"exploring","mission":"test","max_sprints":5,"current_sprint":0,
"sprints":[],"exploration":{"dimensions":{},"audited":[]},"session_cost_usd":0}
CSTATE
rc=0; out=$(bash "$SCRIPTS/explore-scan.sh" "$empty_repo" "$SCRIPTS/conductor-state.sh" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "explore-scan.sh handles empty repo (rc=$rc)" \
                    || fail "explore-scan.sh crashed in empty repo (rc=$rc)"

# session-diff.sh in empty repo — needs commits to diff against a base branch
git -C "$empty_repo" checkout -b "auto/session-test" 2>/dev/null || true
rc=0; out=$(bash "$SCRIPTS/session-diff.sh" "$empty_repo" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "session-diff.sh exits non-zero in empty repo" \
                  || fail "session-diff.sh should fail in empty repo (no base)"

# history.sh in empty repo
rc=0; out=$(bash "$SCRIPTS/history.sh" "$empty_repo" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "history.sh handles empty repo (rc=$rc)" \
                    || fail "history.sh crashed in empty repo (rc=$rc)"

# conductor-state.sh progress in empty repo (state exists but no sprints)
rc=0; out=$(bash "$SCRIPTS/conductor-state.sh" progress "$empty_repo" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "conductor-state.sh progress handles empty repo (rc=$rc)" \
                    || fail "conductor-state.sh progress crashed in empty repo"

# ── 3. Missing python3 ───────────────────────────────────────────────────────
echo "=== Missing python3 ==="

tmp3=$(new_tmp)
py_repo="$tmp3/py-test"
mkdir -p "$py_repo"
git -C "$py_repo" init -q

# Create a restricted PATH without python3
SAFE_PATH=""
while IFS= read -r -d ':' p; do
  if [ -n "$p" ] && [ -d "$p" ] && [ -x "$p/python3" ]; then
    continue
  fi
  SAFE_PATH="${SAFE_PATH:+$SAFE_PATH:}$p"
done <<< "${PATH}:"

# preflight.sh — should warn about missing python3 but not crash (python3 is optional)
rc=0; out=$(env PATH="$SAFE_PATH" bash "$SCRIPTS/preflight.sh" 2>&1) || rc=$?
assert_contains "$out" "python3" "preflight.sh mentions python3 when missing"

# explore-scan.sh requires python3 — should error clearly
mkdir -p "$py_repo/.autonomous"
cat > "$py_repo/.autonomous/conductor-state.json" << 'CSTATE2'
{"phase":"exploring","mission":"test","max_sprints":5,"current_sprint":0,
"sprints":[],"exploration":{"dimensions":{},"audited":[]},"session_cost_usd":0}
CSTATE2
rc=0; out=$(env PATH="$SAFE_PATH" bash "$SCRIPTS/explore-scan.sh" "$py_repo" "$SCRIPTS/conductor-state.sh" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "explore-scan.sh fails without python3" \
                  || fail "explore-scan.sh should fail without python3"
assert_contains "$out" "python3" "explore-scan.sh mentions python3 in error"

# detect-framework.sh requires python3
rc=0; out=$(env PATH="$SAFE_PATH" bash "$SCRIPTS/detect-framework.sh" "$py_repo" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "detect-framework.sh fails without python3" \
                  || fail "detect-framework.sh should fail without python3"

# ── 4. Missing tmux ──────────────────────────────────────────────────────────
echo "=== Missing tmux ==="

tmp4=$(new_tmp)
tmux_repo="$tmp4/tmux-test"
mkdir -p "$tmux_repo/.autonomous"
git -C "$tmux_repo" init -q

# Create a minimal prompt file for dispatch
echo "test prompt" > "$tmux_repo/.autonomous/test-prompt.md"

# Create a restricted PATH without tmux
NOTMUX_PATH=""
while IFS= read -r -d ':' p; do
  if [ -n "$p" ] && [ -d "$p" ] && [ -x "$p/tmux" ]; then
    continue
  fi
  NOTMUX_PATH="${NOTMUX_PATH:+$NOTMUX_PATH:}$p"
done <<< "${PATH}:"

# dispatch.sh — needs claude CLI (critical); without it, should error before tmux check
rc=0; out=$(env PATH="$NOTMUX_PATH" bash "$SCRIPTS/dispatch.sh" "$tmux_repo" "$tmux_repo/.autonomous/test-prompt.md" "test-win" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "dispatch.sh fails gracefully without claude/tmux" \
                  || fail "dispatch.sh should fail without claude CLI"
assert_contains "$out" "not found" "dispatch.sh error mentions missing tool"

# preflight.sh should note tmux missing
rc=0; out=$(env PATH="$NOTMUX_PATH" bash "$SCRIPTS/preflight.sh" 2>&1) || rc=$?
assert_contains "$out" "tmux" "preflight.sh mentions tmux when missing"

# ── 5. Corrupted JSON files ──────────────────────────────────────────────────
echo "=== Corrupted JSON ==="

# 5a: conductor-state.sh — returns {} fallback on corrupted JSON (graceful handling)
tmp5=$(new_tmp)
corrupt_repo="$tmp5/corrupt-test"
mkdir -p "$corrupt_repo/.autonomous"
git -C "$corrupt_repo" init -q
git -C "$corrupt_repo" commit --allow-empty -m "init" -q

# Initialize valid state
bash "$SCRIPTS/conductor-state.sh" init "$corrupt_repo" "test" 5 >/dev/null

# Truncated JSON — script returns {} fallback
echo '{"broken' true > "$corrupt_repo/.autonomous/conductor-state.json"
rc=0; out=$(bash "$SCRIPTS/conductor-state.sh" read "$corrupt_repo" 2>&1) || rc=$?
assert_contains "$out" "{}" "conductor-state.sh read returns {} for truncated JSON"

# Empty file — same fallback
true > "$corrupt_repo/.autonomous/conductor-state.json"
rc=0; out=$(bash "$SCRIPTS/conductor-state.sh" read "$corrupt_repo" 2>&1) || rc=$?
assert_contains "$out" "{}" "conductor-state.sh read returns {} for empty file"

# Binary garbage — same fallback
printf '\x00\x01\xff\xfe' > "$corrupt_repo/.autonomous/conductor-state.json"
rc=0; out=$(bash "$SCRIPTS/conductor-state.sh" read "$corrupt_repo" 2>&1) || rc=$?
assert_contains "$out" "{}" "conductor-state.sh read returns {} for binary garbage"

# sprint-start on corrupted state should not crash
echo '{"broken' true > "$corrupt_repo/.autonomous/conductor-state.json"
rc=0; out=$(bash "$SCRIPTS/conductor-state.sh" sprint-start "$corrupt_repo" "test sprint" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "conductor-state.sh sprint-start handles corrupted JSON (rc=$rc)" \
                    || fail "conductor-state.sh sprint-start crashed on corrupted JSON"

# 5b: backlog.sh — returns [] fallback on corrupted JSON (graceful handling)
bash "$SCRIPTS/conductor-state.sh" init "$corrupt_repo" "test" 5 >/dev/null
echo '{"broken' true > "$corrupt_repo/.autonomous/backlog.json"
rc=0; out=$(bash "$SCRIPTS/backlog.sh" list "$corrupt_repo" 2>&1) || rc=$?
assert_eq "$out" "[]" "backlog.sh list returns [] for corrupted JSON"

# Empty backlog file
true > "$corrupt_repo/.autonomous/backlog.json"
rc=0; out=$(bash "$SCRIPTS/backlog.sh" list "$corrupt_repo" 2>&1) || rc=$?
assert_eq "$out" "[]" "backlog.sh list returns [] for empty file"

# Binary garbage in backlog
printf '\x00\x01\xff\xfe' > "$corrupt_repo/.autonomous/backlog.json"
rc=0; out=$(bash "$SCRIPTS/backlog.sh" list "$corrupt_repo" 2>&1) || rc=$?
assert_eq "$out" "[]" "backlog.sh list returns [] for binary garbage"

# 5c: cost-tracker.sh report on corrupted state
bash "$SCRIPTS/conductor-state.sh" init "$corrupt_repo" "test" 5 >/dev/null
echo '{"broken' true > "$corrupt_repo/.autonomous/conductor-state.json"
rc=0; out=$(bash "$SCRIPTS/cost-tracker.sh" report "$corrupt_repo" 2>&1) || rc=$?
[ "$rc" -ne 0 ] && ok "cost-tracker.sh report fails on corrupted JSON" \
                  || fail "cost-tracker.sh report should fail on corrupted JSON"

# cost-tracker parse-output with garbage — returns "0" as graceful default
echo '{"broken' > "$tmp5/garbage-output.json"
rc=0; out=$(bash "$SCRIPTS/cost-tracker.sh" parse-output "$tmp5/garbage-output.json" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  assert_contains "$out" "0" "cost-tracker.sh parse-output returns 0 for garbage"
else
  ok "cost-tracker.sh parse-output fails on garbage (rc=$rc)"
fi

# ── 6. Very long sprint direction ────────────────────────────────────────────
echo "=== Very long sprint direction ==="

# Generate a 1500-char direction string
LONG_DIR=$(python3 -c "print('Build a comprehensive REST API with ' + 'feature ' * 180)")
assert_ge "${#LONG_DIR}" 1200 "long direction is 1200+ chars"

# parse-args.sh with long direction
rc=0; out=$(bash "$SCRIPTS/parse-args.sh" "5 $LONG_DIR" 2>&1) || rc=$?
assert_eq "$rc" "0" "parse-args.sh succeeds with long direction"
assert_contains "$out" "_MAX_SPRINTS=" "parse-args.sh outputs _MAX_SPRINTS with long input"
assert_contains "$out" "_DIRECTION=" "parse-args.sh outputs _DIRECTION with long input"

# Eval only the variable-assignment lines (skip debug output)
eval "$(echo "$out" | grep '^_[A-Z_]*=')"
assert_ge "${#_DIRECTION}" 1200 "parse-args.sh preserves long direction (${#_DIRECTION} chars)"

# build-sprint-prompt.sh with long direction
tmp6=$(new_tmp)
long_repo="$tmp6/long-test"
mkdir -p "$long_repo/.autonomous"
git -C "$long_repo" init -q
git -C "$long_repo" commit --allow-empty -m "init" -q
rc=0; out=$(bash "$SCRIPTS/build-sprint-prompt.sh" "$long_repo" "$SCRIPT_DIR" 1 "$LONG_DIR" 2>&1) || rc=$?
assert_eq "$rc" "0" "build-sprint-prompt.sh succeeds with long direction"
assert_file_exists "$long_repo/.autonomous/sprint-prompt.md" "sprint-prompt.md created with long direction"
assert_file_contains "$long_repo/.autonomous/sprint-prompt.md" "comprehensive REST API" "long direction present in sprint prompt"

# ── 7. Special characters in paths ───────────────────────────────────────────
echo "=== Special characters in paths ==="

tmp7=$(new_tmp)

# Dir with spaces
space_dir="$tmp7/my project dir"
mkdir -p "$space_dir"
git -C "$space_dir" init -q
git -C "$space_dir" commit --allow-empty -m "init" -q

rc=0; out=$(bash "$SCRIPTS/detect-framework.sh" "$space_dir" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  assert_contains "$out" "unknown" "detect-framework.sh works with spaces in path"
else
  [ "$rc" -lt 128 ] && ok "detect-framework.sh handles spaces in path (rc=$rc)" \
                      || fail "detect-framework.sh crashed with spaces in path (rc=$rc)"
fi

rc=0; out=$(bash "$SCRIPTS/build-worker-hints.sh" "$space_dir" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "build-worker-hints.sh handles spaces in path" \
                    || fail "build-worker-hints.sh crashed with spaces in path"

out=$(bash "$SCRIPTS/startup.sh" "$space_dir" 2>&1) || true
assert_contains "$out" "SCRIPT_DIR=" "startup.sh works with spaces in path"

# Dir with hyphens and dots (common edge case)
dotdir="$tmp7/my.project-v2.0"
mkdir -p "$dotdir"
git -C "$dotdir" init -q
git -C "$dotdir" commit --allow-empty -m "init" -q

rc=0; out=$(bash "$SCRIPTS/detect-framework.sh" "$dotdir" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "detect-framework.sh handles dots/hyphens in path" \
                    || fail "detect-framework.sh crashed with dots/hyphens in path"

out=$(bash "$SCRIPTS/startup.sh" "$dotdir" 2>&1) || true
assert_contains "$out" "SCRIPT_DIR=" "startup.sh works with dots/hyphens in path"

# Dir with parentheses and brackets
paren_dir="$tmp7/test (v2) [final]"
mkdir -p "$paren_dir"
git -C "$paren_dir" init -q
git -C "$paren_dir" commit --allow-empty -m "init" -q

rc=0; out=$(bash "$SCRIPTS/detect-framework.sh" "$paren_dir" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "detect-framework.sh handles parens/brackets in path" \
                    || fail "detect-framework.sh crashed with parens/brackets in path"

rc=0; out=$(bash "$SCRIPTS/build-worker-hints.sh" "$paren_dir" 2>&1) || rc=$?
[ "$rc" -lt 128 ] && ok "build-worker-hints.sh handles parens/brackets in path" \
                    || fail "build-worker-hints.sh crashed with parens/brackets in path"

out=$(bash "$SCRIPTS/startup.sh" "$paren_dir" 2>&1) || true
assert_contains "$out" "SCRIPT_DIR=" "startup.sh works with parens/brackets in path"

# conductor-state.sh init in path with spaces
space_repo="$tmp7/project with spaces"
mkdir -p "$space_repo"
git -C "$space_repo" init -q
git -C "$space_repo" commit --allow-empty -m "init" -q
rc=0; bash "$SCRIPTS/conductor-state.sh" init "$space_repo" "test" 5 >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "conductor-state.sh init works with spaces in path"
assert_file_exists "$space_repo/.autonomous/conductor-state.json" "state file created in spaced path"

# ── Done ──────────────────────────────────────────────────────────────────────
print_results
