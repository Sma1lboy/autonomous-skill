#!/usr/bin/env bash
# Tests for scripts/session-init.sh — session branch creation and state initialization.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_INIT="$SCRIPT_DIR/../scripts/session-init.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Create a git-initialized temp project dir. Returns path.
new_git_project() {
  local d; d=$(new_tmp)
  (cd "$d" && git init -q && git commit -q --allow-empty -m "init")
  echo "$d"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_session_init.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Creates session branch
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Creates session branch"

T=$(new_git_project)
OUT=$(bash "$SESSION_INIT" "$T" "$SKILL_DIR" "test direction" "5" 2>&1)
assert_contains "$OUT" "SESSION_BRANCH=auto/session-" "output contains SESSION_BRANCH"

# Verify we're on the session branch
BRANCH=$(cd "$T" && git branch --show-current)
assert_contains "$BRANCH" "auto/session-" "git is on session branch"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Creates .autonomous directory with 700 permissions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. .autonomous directory with permissions"

T=$(new_git_project)
bash "$SESSION_INIT" "$T" "$SKILL_DIR" "test" "3" >/dev/null 2>&1

assert_eq "$([ -d "$T/.autonomous" ] && echo 'yes' || echo 'no')" "yes" \
  ".autonomous dir exists"

PERMS=$(stat -f '%Lp' "$T/.autonomous" 2>/dev/null || stat -c '%a' "$T/.autonomous" 2>/dev/null)
assert_eq "$PERMS" "700" ".autonomous has 700 permissions"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Conductor state initialized
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Conductor state initialized"

T=$(new_git_project)
bash "$SESSION_INIT" "$T" "$SKILL_DIR" "build REST API" "5" >/dev/null 2>&1

assert_file_exists "$T/.autonomous/conductor-state.json" "conductor-state.json exists"

# Verify JSON is valid and has expected fields
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
assert d['phase'] == 'directed'
assert d['mission'] == 'build REST API'
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "conductor-state.json has correct phase and mission"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Backlog initialized
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Backlog initialized"

T=$(new_git_project)
bash "$SESSION_INIT" "$T" "$SKILL_DIR" "test" "3" >/dev/null 2>&1

assert_file_exists "$T/.autonomous/backlog.json" "backlog.json exists"

VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/backlog.json'))
assert d['version'] == 1
assert isinstance(d['items'], list)
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "backlog.json has valid structure"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Session branch name format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Session branch name format"

T=$(new_git_project)
OUT=$(bash "$SESSION_INIT" "$T" "$SKILL_DIR" "test" "5" 2>&1)

# Extract the branch name
BRANCH_LINE=$(echo "$OUT" | grep "SESSION_BRANCH=")
BRANCH_NAME=${BRANCH_LINE#SESSION_BRANCH=}
assert_contains "$BRANCH_NAME" "auto/session-" "branch starts with auto/session-"

# The timestamp part should be numeric
TIMESTAMP=${BRANCH_NAME#auto/session-}
if [[ "$TIMESTAMP" =~ ^[0-9]+$ ]]; then
  ok "branch timestamp is numeric"
else
  fail "branch timestamp is numeric — got '$TIMESTAMP'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 6. Different direction
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Different direction"

T=$(new_git_project)
OUT=$(bash "$SESSION_INIT" "$T" "$SKILL_DIR" "fix all bugs" "5" 2>&1)
assert_contains "$OUT" "SESSION_BRANCH=" "direction accepted and branch created"

MISSION=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d.get('mission', ''))
" 2>/dev/null || echo "fail")
assert_eq "$MISSION" "fix all bugs" "mission stored in conductor state"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Default max_sprints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Default max_sprints"

T=$(new_git_project)
# Omit max_sprints — should default to 10 per session-init.sh
bash "$SESSION_INIT" "$T" "$SKILL_DIR" "test" >/dev/null 2>&1

MAXS=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/conductor-state.json'))
print(d.get('max_sprints', 'missing'))
" 2>/dev/null || echo "fail")
assert_eq "$MAXS" "10" "default max_sprints is 10"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Backlog preserves existing items (idempotent)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Backlog preserves existing items"

T=$(new_git_project)
mkdir -p "$T/.autonomous"
# Pre-seed a backlog
bash "$SKILL_DIR/scripts/backlog.sh" init "$T" >/dev/null 2>&1
bash "$SKILL_DIR/scripts/backlog.sh" add "$T" "Pre-existing item" >/dev/null 2>&1

bash "$SESSION_INIT" "$T" "$SKILL_DIR" "test" "3" >/dev/null 2>&1

# Verify the pre-existing item is still there
ITEMS=$(bash "$SKILL_DIR/scripts/backlog.sh" list "$T" open titles-only 2>/dev/null)
assert_contains "$ITEMS" "Pre-existing item" "backlog preserved existing items"

# ═══════════════════════════════════════════════════════════════════════════
# 9. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. --help flag"

HELP=$(bash "$SESSION_INIT" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
assert_contains "$HELP" "project_dir" "--help mentions project_dir"
assert_contains "$HELP" "SESSION_BRANCH" "--help mentions SESSION_BRANCH"

bash "$SESSION_INIT" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 10. -h short flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. -h short flag"

HELP_SHORT=$(bash "$SESSION_INIT" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h shows Usage"

bash "$SESSION_INIT" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

print_results
