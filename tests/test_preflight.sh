#!/usr/bin/env bash
# Tests for scripts/preflight.sh — dependency checker.
# Uses PATH manipulation to mock missing/present binaries.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT="$SCRIPT_DIR/../scripts/preflight.sh"

# ── Mock helpers ──────────────────────────────────────────────────────────

# Create a clean mock dir with specified binaries as no-op scripts.
# Usage: new_mock_env claude tmux python3 jq shellcheck
new_mock_env() {
  local d; d=$(new_tmp)
  for bin in "$@"; do
    if [ "$bin" = "claude" ]; then
      cat > "$d/claude" << 'CEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "claude-code 1.0.42"
  exit 0
fi
exit 0
CEOF
    elif [ "$bin" = "tmux" ]; then
      cat > "$d/tmux" << 'TEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "list-sessions" ]; then
  echo "0: 1 windows"
  exit 0
fi
exit 0
TEOF
    elif [ "$bin" = "brew" ]; then
      cat > "$d/brew" << 'BEOF'
#!/usr/bin/env bash
echo "mock-brew: install $*"
exit 0
BEOF
    elif [ "$bin" = "apt" ]; then
      cat > "$d/apt" << 'AEOF'
#!/usr/bin/env bash
echo "mock-apt: install $*"
exit 0
AEOF
    elif [ "$bin" = "sudo" ]; then
      cat > "$d/sudo" << 'SEOF'
#!/usr/bin/env bash
# Execute the command after 'sudo'
"$@"
SEOF
    else
      cat > "$d/$bin" << 'GEOF'
#!/usr/bin/env bash
exit 0
GEOF
    fi
    chmod +x "$d/$bin"
  done
  echo "$d"
}

# Build a "clean room" with only essential system utilities.
# This prevents real python3/jq/etc. on the host from leaking into tests.
new_clean_room() {
  local d; d=$(new_tmp)
  local bin real
  for bin in bash env uname grep cat echo dirname readlink chmod mkdir rm mktemp sed tr wc sort head tail; do
    real=$(command -v "$bin" 2>/dev/null || true)
    if [ -n "$real" ]; then
      ln -sf "$real" "$d/$bin"
    fi
  done
  echo "$d"
}

CLEAN_ROOM=$(new_clean_room)
BARE_PATH="$CLEAN_ROOM"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_preflight.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. All deps present → exit 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. All deps present → exit 0"
MOCK=$(new_mock_env claude tmux python3 jq shellcheck)

OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
RC=$?
assert_eq "$RC" "0" "exit 0 when all deps present"
assert_contains "$OUTPUT" "all dependencies present" "reports all deps OK"

# ═══════════════════════════════════════════════════════════════════════════
# 2. claude missing → exit non-zero
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. claude missing → exit non-zero"
MOCK=$(new_mock_env tmux python3 jq shellcheck)

OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1 || true)
RC=$?
# We need to capture exit code properly
set +e
PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" >/dev/null 2>&1
RC=$?
set -e
assert_eq "$RC" "1" "exit 1 when claude missing"
assert_contains "$OUTPUT" "REQUIRED" "claude marked as REQUIRED"
assert_contains "$OUTPUT" "FAIL" "output says FAIL"

# ═══════════════════════════════════════════════════════════════════════════
# 3. tmux missing → exit 0 but warning printed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. tmux missing → exit 0 with warning"
MOCK=$(new_mock_env claude python3 jq shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "exit 0 even if tmux missing"
assert_contains "$OUTPUT" "tmux" "mentions tmux"
assert_contains "$OUTPUT" "optional" "tmux marked optional"

# ═══════════════════════════════════════════════════════════════════════════
# 4. python3 missing → exit 0 but warning printed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. python3 missing → exit 0 with warning"
MOCK=$(new_mock_env claude tmux jq shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "exit 0 even if python3 missing"
assert_contains "$OUTPUT" "python3" "mentions python3"
assert_contains "$OUTPUT" "optional" "python3 marked optional"

# ═══════════════════════════════════════════════════════════════════════════
# 5. jq missing → exit 0 but warning printed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. jq missing → exit 0 with warning"
MOCK=$(new_mock_env claude tmux python3 shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "exit 0 even if jq missing"
assert_contains "$OUTPUT" "jq" "mentions jq"

# ═══════════════════════════════════════════════════════════════════════════
# 6. shellcheck missing → exit 0 but warning printed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. shellcheck missing → exit 0 with warning"
MOCK=$(new_mock_env claude tmux python3 jq)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "exit 0 even if shellcheck missing"
assert_contains "$OUTPUT" "shellcheck" "mentions shellcheck"

# ═══════════════════════════════════════════════════════════════════════════
# 7. --help flag shows usage and exits 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. --help flag"
set +e
HELP=$(bash "$PREFLIGHT" --help 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "--help exits 0"
assert_contains "$HELP" "Usage:" "--help shows usage"
assert_contains "$HELP" "preflight" "--help mentions script name"
assert_contains "$HELP" "Dependencies checked" "--help lists dependencies"
assert_contains "$HELP" "Examples" "--help includes examples"

# ═══════════════════════════════════════════════════════════════════════════
# 8. -h flag works too
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. -h short flag"
set +e
HELP_SHORT=$(bash "$PREFLIGHT" -h 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "-h exits 0"
assert_contains "$HELP_SHORT" "Usage:" "-h shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# 9. --setup on macOS (mock brew) — verify install attempt
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. --setup on macOS tries brew install"
MOCK=$(new_mock_env claude python3 jq shellcheck brew)
# tmux missing — should try to brew install it

# Force macOS platform by providing a mock uname
cat > "$MOCK/uname" << 'UEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then echo "Darwin"; else command uname "$@"; fi
UEOF
chmod +x "$MOCK/uname"

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" --setup 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "--setup exits 0 (claude present)"
assert_contains "$OUTPUT" "brew install tmux" "tries to brew install tmux"

# ═══════════════════════════════════════════════════════════════════════════
# 10. --setup on Linux (mock apt) — verify install attempt
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. --setup on Linux tries apt install"
MOCK=$(new_mock_env claude python3 jq shellcheck sudo apt)
# tmux missing — should try to apt install it

cat > "$MOCK/uname" << 'UEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then echo "Linux"; else command uname "$@"; fi
UEOF
chmod +x "$MOCK/uname"

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" --setup 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "--setup exits 0 on Linux"
assert_contains "$OUTPUT" "apt install" "tries to apt install"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Install instructions mention brew on macOS
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Install hints show brew on macOS"
MOCK=$(new_mock_env claude python3)
# tmux, jq, shellcheck missing

cat > "$MOCK/uname" << 'UEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then echo "Darwin"; else command uname "$@"; fi
UEOF
chmod +x "$MOCK/uname"

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
assert_contains "$OUTPUT" "brew install tmux" "install hint for tmux uses brew"
assert_contains "$OUTPUT" "brew install jq" "install hint for jq uses brew"
assert_contains "$OUTPUT" "brew install shellcheck" "install hint for shellcheck uses brew"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Install instructions mention apt on Linux
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Install hints show apt on Linux"
MOCK=$(new_mock_env claude python3)

cat > "$MOCK/uname" << 'UEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then echo "Linux"; else command uname "$@"; fi
UEOF
chmod +x "$MOCK/uname"

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
assert_contains "$OUTPUT" "apt install tmux" "install hint for tmux uses apt"
assert_contains "$OUTPUT" "apt install jq" "install hint for jq uses apt"
assert_contains "$OUTPUT" "apt install shellcheck" "install hint for shellcheck uses apt"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Claude version detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Claude version detection"
MOCK=$(new_mock_env claude tmux python3 jq shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
assert_contains "$OUTPUT" "claude-code 1.0.42" "detects and prints claude version"
assert_contains "$OUTPUT" "Claude CLI version" "version label present"

# ═══════════════════════════════════════════════════════════════════════════
# 14. tmux server status — running
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. tmux server status — running"
MOCK=$(new_mock_env claude tmux python3 jq shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
assert_contains "$OUTPUT" "tmux server: running" "detects tmux server running"

# ═══════════════════════════════════════════════════════════════════════════
# 15. tmux server status — not running
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. tmux server status — not running"
MOCK=$(new_mock_env claude python3 jq shellcheck)
# Create tmux that fails list-sessions (server not running)
cat > "$MOCK/tmux" << 'TEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "list-sessions" ]; then
  echo "no server running on /tmp/tmux-501/default" >&2
  exit 1
fi
exit 0
TEOF
chmod +x "$MOCK/tmux"

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
assert_contains "$OUTPUT" "not running" "detects tmux server not running"
assert_contains "$OUTPUT" "first dispatch" "notes it will start on dispatch"

# ═══════════════════════════════════════════════════════════════════════════
# 16. claude missing install link shown
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Claude missing shows install link"
MOCK=$(new_mock_env tmux python3 jq shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
assert_contains "$OUTPUT" "docs.anthropic.com" "claude install link shown"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Multiple optional deps missing — count reported
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Multiple missing optional deps counted"
MOCK=$(new_mock_env claude)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "exit 0 with only optional deps missing"
assert_contains "$OUTPUT" "optional dep" "reports count of missing optional deps"

# ═══════════════════════════════════════════════════════════════════════════
# 18. --setup with no missing optional deps
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. --setup with nothing to install"
MOCK=$(new_mock_env claude tmux python3 jq shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" --setup 2>&1)
RC=$?
set -e
assert_eq "$RC" "0" "--setup exits 0"
assert_contains "$OUTPUT" "already installed" "reports all deps already installed"

# ═══════════════════════════════════════════════════════════════════════════
# 19. --setup with claude missing still shows manual install note
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. --setup doesn't auto-install claude"
MOCK=$(new_mock_env tmux python3 jq shellcheck brew)

cat > "$MOCK/uname" << 'UEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then echo "Darwin"; else command uname "$@"; fi
UEOF
chmod +x "$MOCK/uname"

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" --setup 2>&1)
RC=$?
set -e
assert_eq "$RC" "1" "--setup still fails if claude missing"
assert_contains "$OUTPUT" "manually" "tells user to install claude manually"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Checkmark symbols for present deps
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Checkmarks for present deps"
MOCK=$(new_mock_env claude tmux python3 jq shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
# Count checkmarks
CHECKS=$(echo "$OUTPUT" | grep -c "✓" || true)
assert_eq "$CHECKS" "5" "5 checkmarks for 5 present deps"

# ═══════════════════════════════════════════════════════════════════════════
# 21. X symbols for missing deps
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. X marks for missing deps"
MOCK=$(new_mock_env claude)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
CROSSES=$(echo "$OUTPUT" | grep -c "✗" || true)
assert_eq "$CROSSES" "4" "4 crosses for 4 missing optional deps"

# ═══════════════════════════════════════════════════════════════════════════
# 22. Banner format present
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. Banner format"
MOCK=$(new_mock_env claude tmux python3 jq shellcheck)

set +e
OUTPUT=$(PATH="$MOCK:$BARE_PATH" bash "$PREFLIGHT" 2>&1)
set -e
assert_contains "$OUTPUT" "Preflight Check" "banner title present"
assert_contains "$OUTPUT" "═══" "banner border present"

print_results
