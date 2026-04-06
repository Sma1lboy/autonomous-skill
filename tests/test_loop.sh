#!/usr/bin/env bash
# Tests for scripts/loop.sh — standalone launcher.
# Since loop.sh ends with `exec ... claude`, we can only test:
# - argument parsing and env var handling
# - persona.sh invocation
# - prompt construction
# We use a mock claude that captures the prompt it receives.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$SCRIPT_DIR/../scripts/loop.sh"

# ── Mock helpers (loop.sh specific) ────────────────────────────────────────

# Create a mock dir with timeout shim pre-installed. Returns mock dir path.
new_mock_dir() {
  local d; d=$(new_tmp)
  cat > "$d/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
  chmod +x "$d/timeout"
  echo "$d"
}

# Write a basic mock claude that drains stdin and exits 0.
# Optional $2: extra lines inserted before 'cat > /dev/null'.
write_mock_claude() {
  local dir="$1"
  local extra="${2:-}"
  { echo '#!/usr/bin/env bash'
    [ -n "$extra" ] && echo "$extra"
    echo 'cat > /dev/null; exit 0'
  } > "$dir/claude"
  chmod +x "$dir/claude"
}

# Create a git-initialized temp project dir. Returns path.
new_git_project() {
  local d; d=$(new_tmp)
  (cd "$d" && git init -q && git commit -q --allow-empty -m "init")
  echo "$d"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_loop.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. loop.sh calls persona.sh
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Persona generation"
T=$(new_git_project)
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR" 'echo "MOCK_ARGS: $*" > "$(dirname "$0")/captured.txt"'

PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" "test direction" 2>/dev/null || true
assert_eq "$([ -f "$MOCK_DIR/captured.txt" ] && echo 'yes' || echo 'no')" "yes" \
  "loop.sh invoked claude"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Direction from arg
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Direction from argument"
T=$(new_git_project)
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

OUTPUT=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" "build REST API" 2>&1 || true)
assert_contains "$OUTPUT" "build REST API" "direction shown in startup banner"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Direction from env var
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Direction from AUTONOMOUS_DIRECTION env var"
T=$(new_git_project)
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

OUTPUT=$(AUTONOMOUS_DIRECTION="fix all bugs" PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$OUTPUT" "fix all bugs" "env var direction shown in banner"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Default max iterations
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Default max iterations"
T=$(new_git_project)
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

OUTPUT=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$OUTPUT" "Max iterations: 50" "default max iterations is 50"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Custom max iterations via env var
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Custom max iterations"
T=$(new_git_project)
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

OUTPUT=$(MAX_ITERATIONS=25 PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$OUTPUT" "Max iterations: 25" "custom max iterations from env"

# ═══════════════════════════════════════════════════════════════════════════
# 6. OWNER.md appended when present
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. OWNER.md loaded when present"
T=$(new_git_project)
echo "# Test Owner" > "$T/OWNER.md"
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR" 'echo "$*" > "$(dirname "$0")/args.txt"'

PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" "test" 2>/dev/null || true
ARGS=$(cat "$MOCK_DIR/args.txt" 2>/dev/null || echo "")
assert_contains "$ARGS" "append-system-prompt" "OWNER.md appended to claude invocation"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Auto-generated OWNER.md still appended
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Auto-generated OWNER.md appended"
T=$(new_git_project)
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR" 'echo "$*" > "$(dirname "$0")/args.txt"'

PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" "test" 2>/dev/null || true
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assert_eq "$([ -f "$REPO_ROOT/OWNER.md" ] && echo 'yes' || echo 'no')" "yes" \
  "persona.sh auto-generates OWNER.md (global)"
ARGS=$(cat "$MOCK_DIR/args.txt" 2>/dev/null || echo "")
assert_contains "$ARGS" "append-system-prompt" "auto-generated OWNER.md appended to claude"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Startup banner shows project name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Banner shows project name"
T=$(new_git_project)
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

BASENAME=$(basename "$T")
OUTPUT=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$OUTPUT" "$BASENAME" "banner shows project basename"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Missing project directory
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Missing project directory"
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

ERR=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "/nonexistent/path" 2>&1 || true)
assert_contains "$ERR" "not found" "missing project dir rejected"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Missing claude binary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Missing claude binary"
T=$(new_git_project)
# Mock dir with only timeout — no claude binary
EMPTY_DIR=$(new_mock_dir)

ERR=$(PATH="$EMPTY_DIR:/usr/bin:/bin" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$ERR" "claude CLI not found" "missing claude binary rejected"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Non-numeric MAX_ITERATIONS
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Non-numeric MAX_ITERATIONS"
T=$(new_git_project)
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

ERR=$(MAX_ITERATIONS="abc" PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$ERR" "positive integer" "non-numeric MAX_ITERATIONS rejected"

# ═══════════════════════════════════════════════════════════════════════════
# 12. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. --help flag"
HELP=$(bash "$LOOP" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows usage"
assert_contains "$HELP" "project-dir" "--help mentions project-dir arg"
assert_contains "$HELP" "AUTONOMOUS_DIRECTION" "--help mentions env vars"
assert_contains "$HELP" "Examples" "--help includes examples"

# ═══════════════════════════════════════════════════════════════════════════
# 13. -h flag (short form)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. -h short flag"
HELP_SHORT=$(bash "$LOOP" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h also shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# 14. --help exits 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. --help exits 0"
bash "$LOOP" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits with code 0"

# ═══════════════════════════════════════════════════════════════════════════
# 15. Error messages include fix suggestions
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Error messages include fix suggestions"
MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

ERR=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "/nonexistent/path" 2>&1 || true)
assert_contains "$ERR" "valid path" "missing dir error suggests fix"

EMPTY_DIR=$(new_mock_dir)
ERR=$(PATH="$EMPTY_DIR:/usr/bin:/bin" bash "$LOOP" "$(new_git_project)" 2>&1 || true)
assert_contains "$ERR" "Install Claude Code" "missing claude error shows install hint"

print_results
