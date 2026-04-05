#!/usr/bin/env bash
# Tests for scripts/loop.sh — standalone launcher.
# Since loop.sh ends with `exec ... claude`, we can only test:
# - argument parsing and env var handling
# - persona.sh invocation
# - prompt construction
# We use a mock claude that captures the prompt it receives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$SCRIPT_DIR/../scripts/loop.sh"

# ── Minimal test framework ──────────────────────────────────────────────────
PASS=0; FAIL=0

ok()   { echo "  ok  $*"; ((PASS++)) || true; }
fail() { echo "  FAIL $*"; ((FAIL++)) || true; }

assert_eq() {
  [ "$1" = "$2" ] && ok "$3" || fail "$3 — got '$1', want '$2'"
}
assert_contains() {
  echo "$1" | grep -q "$2" && ok "$3" || fail "$3 — '$2' not in output"
}
assert_not_contains() {
  echo "$1" | grep -q "$2" && fail "$3 — '$2' found in output" || ok "$3"
}

# ── Temp dir management ─────────────────────────────────────────────────────
TMPDIRS=()
new_tmp() { local d; d=$(mktemp -d); TMPDIRS+=("$d"); echo "$d"; }
cleanup() { [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf "${TMPDIRS[@]}" || true; }
trap cleanup EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_loop.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. loop.sh calls persona.sh
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Persona generation"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

# Mock claude: just exit immediately, capturing nothing
MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
# mock claude — just capture args and exit
echo "MOCK_ARGS: $*" > "$(dirname "$0")/captured.txt"
cat > /dev/null  # drain stdin
exit 0
EOF
chmod +x "$MOCK_DIR/claude"

# Mock timeout too (macOS timeout may not exist)
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift  # skip the timeout value
exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

# Run loop.sh with mock claude on PATH
PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" "test direction" 2>/dev/null || true

# persona.sh should have been called — it creates OWNER.md if possible
# Even if it fails (no git log meaningful), it should not crash loop.sh
# The key test: loop.sh ran without error up to the exec claude
assert_eq "$([ -f "$MOCK_DIR/captured.txt" ] && echo 'yes' || echo 'no')" "yes" \
  "loop.sh invoked claude"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Direction from arg
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Direction from argument"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
echo "MOCK_PROMPT: $*" > "$(dirname "$0")/prompt.txt"
cat > /dev/null
exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

OUTPUT=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" "build REST API" 2>&1 || true)
assert_contains "$OUTPUT" "build REST API" "direction shown in startup banner"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Direction from env var
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Direction from AUTONOMOUS_DIRECTION env var"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

OUTPUT=$(AUTONOMOUS_DIRECTION="fix all bugs" PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$OUTPUT" "fix all bugs" "env var direction shown in banner"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Default max iterations
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Default max iterations"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

OUTPUT=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$OUTPUT" "Max iterations: 50" "default max iterations is 50"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Custom max iterations via env var
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Custom max iterations"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

OUTPUT=$(MAX_ITERATIONS=25 PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$OUTPUT" "Max iterations: 25" "custom max iterations from env"

# ═══════════════════════════════════════════════════════════════════════════
# 6. OWNER.md appended when present
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. OWNER.md loaded when present"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")
echo "# Test Owner" > "$T/OWNER.md"

MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
echo "$*" > "$(dirname "$0")/args.txt"
cat > /dev/null
exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" "test" 2>/dev/null || true
ARGS=$(cat "$MOCK_DIR/args.txt" 2>/dev/null || echo "")
assert_contains "$ARGS" "append-system-prompt" "OWNER.md appended to claude invocation"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Auto-generated OWNER.md still appended
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Auto-generated OWNER.md appended"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")
# No manual OWNER.md — persona.sh will auto-generate one

MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
echo "$*" > "$(dirname "$0")/args.txt"
cat > /dev/null
exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" "test" 2>/dev/null || true
# persona.sh auto-generates OWNER.md, so it should be appended
assert_eq "$([ -f "$T/OWNER.md" ] && echo 'yes' || echo 'no')" "yes" \
  "persona.sh auto-generates OWNER.md"
ARGS=$(cat "$MOCK_DIR/args.txt" 2>/dev/null || echo "")
assert_contains "$ARGS" "append-system-prompt" "auto-generated OWNER.md appended to claude"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Startup banner shows project name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Banner shows project name"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

BASENAME=$(basename "$T")
OUTPUT=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$OUTPUT" "$BASENAME" "banner shows project basename"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Missing project directory
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Missing project directory"
MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null; exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

ERR=$(PATH="$MOCK_DIR:$PATH" bash "$LOOP" "/nonexistent/path" 2>&1 || true)
assert_contains "$ERR" "not found" "missing project dir rejected"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Missing claude binary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Missing claude binary"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

# Empty PATH mock dir — no claude binary
EMPTY_DIR=$(new_tmp)
cat > "$EMPTY_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$EMPTY_DIR/timeout"

ERR=$(PATH="$EMPTY_DIR:/usr/bin:/bin" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$ERR" "claude CLI not found" "missing claude binary rejected"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Non-numeric MAX_ITERATIONS
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Non-numeric MAX_ITERATIONS"
T=$(new_tmp)
(cd "$T" && git init -q && git commit -q --allow-empty -m "init")

MOCK_DIR=$(new_tmp)
cat > "$MOCK_DIR/claude" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null; exit 0
EOF
chmod +x "$MOCK_DIR/claude"
cat > "$MOCK_DIR/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
chmod +x "$MOCK_DIR/timeout"

ERR=$(MAX_ITERATIONS="abc" PATH="$MOCK_DIR:$PATH" bash "$LOOP" "$T" 2>&1 || true)
assert_contains "$ERR" "positive integer" "non-numeric MAX_ITERATIONS rejected"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
[ "$FAIL" -eq 0 ]
