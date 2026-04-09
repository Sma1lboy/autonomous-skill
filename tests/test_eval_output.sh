#!/usr/bin/env bash
# Tests for eval-safe output from session-init.py, evaluate-sprint.py,
# and tmux cleanup in monitor-sprint.py.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_INIT="$SCRIPT_DIR/../scripts/session-init.py"
EVALUATE="$SCRIPT_DIR/../scripts/evaluate-sprint.py"
MONITOR="$SCRIPT_DIR/../scripts/monitor-sprint.py"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.py"

# Pre-declare variables that eval will set, to satisfy set -u
STATUS="" ; SUMMARY="" ; DIR_COMPLETE="" ; PHASE="" ; SESSION_BRANCH=""

init_git_repo() {
  local d
  d=$(new_tmp)
  git -C "$d" init -q
  git -C "$d" commit --allow-empty -m "init" -q
  echo "$d"
}

# Eval output in current shell. Returns 0 if no stderr, 1 if stderr produced.
# Usage: try_eval "$OUTPUT"   (then check $LAST_EVAL_ERR for stderr text)
LAST_EVAL_ERR=""
try_eval() {
  local tmp_err
  tmp_err=$(mktemp)
  eval "$1" 2>"$tmp_err" || true
  LAST_EVAL_ERR=$(cat "$tmp_err")
  rm -f "$tmp_err"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_eval_output.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# session-init.py — stdout must only contain eval-safe lines
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. session-init.py output cleanliness"

T=$(init_git_repo)
OUTPUT=$(python3 "$SESSION_INIT" "$T" "$SCRIPT_DIR/.." "test mission" "3" 2>/dev/null)
assert_contains "$OUTPUT" "SESSION_BRANCH=" "output contains SESSION_BRANCH assignment"

LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
assert_eq "$LINE_COUNT" "1" "exactly one line of output"

try_eval "$OUTPUT"
assert_eq "$LAST_EVAL_ERR" "" "eval produces no errors"
assert_contains "$SESSION_BRANCH" "auto/session-" "SESSION_BRANCH is set after eval"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. session-init.py — subprocess output suppressed"

T=$(init_git_repo)
OUTPUT=$(python3 "$SESSION_INIT" "$T" "$SCRIPT_DIR/.." "another mission" "5" 2>/dev/null)
assert_not_contains "$OUTPUT" "conductor-" "conductor session_id not in stdout"
assert_not_contains "$OUTPUT" "exists" "backlog 'exists' not in stdout"
assert_not_contains "$OUTPUT" "initialized" "backlog 'initialized' not in stdout"
assert_not_contains "$OUTPUT" "pruned" "backlog 'pruned' not in stdout"

# ═══════════════════════════════════════════════════════════════════════════
# evaluate-sprint.py — output must be eval-safe with shell quoting
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. evaluate-sprint.py — simple summary"

T=$(init_git_repo)
mkdir -p "$T/.autonomous"
python3 "$CONDUCTOR" init "$T" "test" "3" > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "do stuff" > /dev/null

cat > "$T/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"complete","summary":"All good","commits":[],"direction_complete":true}
EOF

OUTPUT=$(python3 "$EVALUATE" "$T" "$SCRIPT_DIR/.." "1" 2>/dev/null)
assert_contains "$OUTPUT" "STATUS=" "output has STATUS"
assert_contains "$OUTPUT" "SUMMARY=" "output has SUMMARY"
assert_contains "$OUTPUT" "PHASE=" "output has PHASE"

try_eval "$OUTPUT"
assert_eq "$LAST_EVAL_ERR" "" "eval produces no errors for simple summary"
assert_eq "$STATUS" "complete" "STATUS parsed correctly"
assert_eq "$SUMMARY" "All good" "SUMMARY parsed correctly"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. evaluate-sprint.py — summary with spaces and quotes"

T=$(init_git_repo)
mkdir -p "$T/.autonomous"
python3 "$CONDUCTOR" init "$T" "test" "3" > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "print hello" > /dev/null

cat > "$T/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"complete","summary":"Worker successfully printed 'hello world' to stdout.","commits":["abc123 feat: add hello"],"direction_complete":true}
EOF

OUTPUT=$(python3 "$EVALUATE" "$T" "$SCRIPT_DIR/.." "1" 2>/dev/null)

try_eval "$OUTPUT"
assert_eq "$LAST_EVAL_ERR" "" "eval produces no errors for summary with spaces and quotes"
assert_eq "$STATUS" "complete" "STATUS correct after eval"
assert_contains "$SUMMARY" "hello world" "SUMMARY preserves 'hello world'"
assert_contains "$SUMMARY" "successfully" "SUMMARY preserves 'successfully' (not executed as command)"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. evaluate-sprint.py — summary with special shell characters"

T=$(init_git_repo)
mkdir -p "$T/.autonomous"
python3 "$CONDUCTOR" init "$T" "test" "3" > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "fix stuff" > /dev/null

cat > "$T/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"partial","summary":"Fixed $PATH issue; added `backticks` & pipes | redirects > /dev/null","commits":[],"direction_complete":false}
EOF

OUTPUT=$(python3 "$EVALUATE" "$T" "$SCRIPT_DIR/.." "1" 2>/dev/null)

try_eval "$OUTPUT"
assert_eq "$LAST_EVAL_ERR" "" "eval handles shell metacharacters safely"
assert_eq "$STATUS" "partial" "STATUS correct for partial sprint"
assert_contains "$SUMMARY" "PATH" "SUMMARY preserves PATH reference"
assert_contains "$SUMMARY" "backticks" "SUMMARY preserves backticks content"
assert_eq "$DIR_COMPLETE" "false" "DIR_COMPLETE is false"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. evaluate-sprint.py — no summary file (fallback)"

T=$(init_git_repo)
mkdir -p "$T/.autonomous"
python3 "$CONDUCTOR" init "$T" "test" "3" > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "do something" > /dev/null

OUTPUT=$(python3 "$EVALUATE" "$T" "$SCRIPT_DIR/.." "1" 2>/dev/null)
try_eval "$OUTPUT"
assert_eq "$LAST_EVAL_ERR" "" "eval works for fallback path (no summary file)"
assert_contains "$SUMMARY" "Sprint completed" "SUMMARY has fallback text"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. evaluate-sprint.py — empty summary string"

T=$(init_git_repo)
mkdir -p "$T/.autonomous"
python3 "$CONDUCTOR" init "$T" "test" "3" > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "nothing" > /dev/null

cat > "$T/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"complete","summary":"","commits":[],"direction_complete":false}
EOF

OUTPUT=$(python3 "$EVALUATE" "$T" "$SCRIPT_DIR/.." "1" 2>/dev/null)
try_eval "$OUTPUT"
assert_eq "$LAST_EVAL_ERR" "" "eval works for empty summary"

# ═══════════════════════════════════════════════════════════════════════════
# monitor-sprint.py — detects completion and kills tmux window
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. monitor-sprint.py — detects numbered summary file"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cat > "$T/.autonomous/sprint-1-summary.json" << 'EOF'
{"status":"complete","summary":"done","commits":[],"direction_complete":true}
EOF

OUTPUT=$(python3 "$MONITOR" "$T" "1" 2>/dev/null)
assert_contains "$OUTPUT" "SPRINT 1 COMPLETE" "detects numbered summary file"
assert_contains "$OUTPUT" "complete" "prints summary content"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. monitor-sprint.py — renames generic summary to numbered"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cat > "$T/.autonomous/sprint-summary.json" << 'EOF'
{"status":"complete","summary":"via generic","commits":[],"direction_complete":true}
EOF

OUTPUT=$(python3 "$MONITOR" "$T" "2" 2>/dev/null)
assert_contains "$OUTPUT" "SPRINT 2 COMPLETE" "detects generic summary and renames"
assert_file_exists "$T/.autonomous/sprint-2-summary.json" "numbered file created"
assert_file_not_exists "$T/.autonomous/sprint-summary.json" "generic file removed"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. monitor-sprint.py — has tmux_kill function"

SCRIPT_CONTENT=$(cat "$MONITOR")
assert_contains "$SCRIPT_CONTENT" "def tmux_kill" "monitor-sprint.py defines tmux_kill"
assert_contains "$SCRIPT_CONTENT" "tmux_kill(window_name)" "calls tmux_kill on completion"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. monitor-sprint.py — tmux_kill called before printing"

# In the main loop, tmux_kill(window_name) should appear before the COMPLETE print
KILL_LINE=$(grep -n "tmux_kill(window_name)" "$MONITOR" | head -1 | cut -d: -f1)
# Find the COMPLETE print that follows the first tmux_kill call (skip the print_summary helper)
PRINT_LINE=$(grep -n "SPRINT.*COMPLETE" "$MONITOR" | while IFS=: read -r ln _; do
  if [ "$ln" -gt "$KILL_LINE" ]; then echo "$ln"; break; fi
done)
if [ "$KILL_LINE" -lt "$PRINT_LINE" ]; then
  ok "tmux_kill called before completion print"
else
  fail "tmux_kill should be called before completion print"
fi

KILL_COUNT=$(grep -c "tmux_kill(window_name)" "$MONITOR" || true)
assert_ge "$KILL_COUNT" "2" "tmux_kill called in both completion branches"

# ═══════════════════════════════════════════════════════════════════════════
print_results
