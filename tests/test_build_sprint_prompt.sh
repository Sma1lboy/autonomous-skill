#!/usr/bin/env bash
# Tests for scripts/build-sprint-prompt.sh — sprint prompt generation.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_PROMPT="$SCRIPT_DIR/../scripts/build-sprint-prompt.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_build_sprint_prompt.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Basic invocation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Basic invocation"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
# Initialize backlog so backlog.sh list doesn't fail
bash "$SKILL_DIR/scripts/backlog.sh" init "$T" >/dev/null 2>&1

OUT=$(bash "$BUILD_PROMPT" "$T" "$SKILL_DIR" "1" "build REST API" 2>&1)
assert_contains "$OUT" "sprint-prompt.md" "output mentions sprint-prompt.md"
assert_file_exists "$T/.autonomous/sprint-prompt.md" "prompt file created"

# Check content has all parameters
CONTENT=$(cat "$T/.autonomous/sprint-prompt.md")
assert_contains "$CONTENT" "SCRIPT_DIR: $SKILL_DIR" "prompt contains SCRIPT_DIR"
assert_contains "$CONTENT" "PROJECT: $T" "prompt contains PROJECT"
assert_contains "$CONTENT" "SPRINT_NUMBER: 1" "prompt contains SPRINT_NUMBER"
assert_contains "$CONTENT" "SPRINT_DIRECTION: build REST API" "prompt contains SPRINT_DIRECTION"
assert_contains "$CONTENT" "sprint master" "prompt contains sprint master header"

# ═══════════════════════════════════════════════════════════════════════════
# 2. SPRINT.md content is inlined
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. SPRINT.md content is inlined"

# Use a temporary SCRIPT_DIR with a known SPRINT.md
T=$(new_tmp)
mkdir -p "$T/.autonomous"
FAKE_SKILL=$(new_tmp)
mkdir -p "$FAKE_SKILL/scripts"
echo "# Unique Sprint Marker XYZ-123" > "$FAKE_SKILL/SPRINT.md"
# Create a minimal backlog.sh stub so the script doesn't fail
cat > "$FAKE_SKILL/scripts/backlog.sh" << 'EOF'
#!/usr/bin/env bash
echo ""
EOF
chmod +x "$FAKE_SKILL/scripts/backlog.sh"

bash "$BUILD_PROMPT" "$T" "$FAKE_SKILL" "2" "test direction" >/dev/null 2>&1
assert_file_contains "$T/.autonomous/sprint-prompt.md" "Unique Sprint Marker XYZ-123" \
  "SPRINT.md content is inlined in prompt"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Previous summary included
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Previous summary included"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
bash "$SKILL_DIR/scripts/backlog.sh" init "$T" >/dev/null 2>&1

bash "$BUILD_PROMPT" "$T" "$SKILL_DIR" "3" "continue work" "Sprint 2 added auth middleware" >/dev/null 2>&1
assert_file_contains "$T/.autonomous/sprint-prompt.md" "Sprint 2 added auth middleware" \
  "previous summary included in prompt"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Empty previous summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Empty previous summary"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
bash "$SKILL_DIR/scripts/backlog.sh" init "$T" >/dev/null 2>&1

bash "$BUILD_PROMPT" "$T" "$SKILL_DIR" "1" "first sprint" >/dev/null 2>&1
assert_file_contains "$T/.autonomous/sprint-prompt.md" "PREVIOUS_SUMMARY:" \
  "PREVIOUS_SUMMARY key present even when empty"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Missing SPRINT.md → error exit 1
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Missing SPRINT.md → error"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
EMPTY_DIR=$(new_tmp)
mkdir -p "$EMPTY_DIR/scripts"
cat > "$EMPTY_DIR/scripts/backlog.sh" << 'EOF'
#!/usr/bin/env bash
echo ""
EOF
chmod +x "$EMPTY_DIR/scripts/backlog.sh"

ERR=$(bash "$BUILD_PROMPT" "$T" "$EMPTY_DIR" "1" "test" 2>&1 || true)
assert_contains "$ERR" "SPRINT.md not found" "missing SPRINT.md produces error"

# Verify exit code is 1
RC=0
bash "$BUILD_PROMPT" "$T" "$EMPTY_DIR" "1" "test" >/dev/null 2>&1 || RC=$?
assert_eq "$RC" "1" "missing SPRINT.md exits 1"

# ═══════════════════════════════════════════════════════════════════════════
# 6. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. --help flag"

HELP=$(bash "$BUILD_PROMPT" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
assert_contains "$HELP" "project_dir" "--help mentions project_dir"
assert_contains "$HELP" "sprint_num" "--help mentions sprint_num"
assert_contains "$HELP" "prev_summary" "--help mentions prev_summary"

bash "$BUILD_PROMPT" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 7. -h short flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. -h short flag"

HELP_SHORT=$(bash "$BUILD_PROMPT" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h shows Usage"

bash "$BUILD_PROMPT" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Backlog titles included
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Backlog titles included"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
bash "$SKILL_DIR/scripts/backlog.sh" init "$T" >/dev/null 2>&1
bash "$SKILL_DIR/scripts/backlog.sh" add "$T" "Backlog item alpha" >/dev/null 2>&1

bash "$BUILD_PROMPT" "$T" "$SKILL_DIR" "1" "check backlog" >/dev/null 2>&1
assert_file_contains "$T/.autonomous/sprint-prompt.md" "BACKLOG_TITLES:" \
  "prompt contains BACKLOG_TITLES key"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Missing required args
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Missing required args"

ERR=$(bash "$BUILD_PROMPT" 2>&1 || true)
assert_contains "$ERR" "Usage:" "missing all args shows usage"

ERR=$(bash "$BUILD_PROMPT" "/tmp" 2>&1 || true)
assert_contains "$ERR" "Usage:" "missing script_dir shows usage"

print_results
