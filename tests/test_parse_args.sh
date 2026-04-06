#!/usr/bin/env bash
# Tests for scripts/parse-args.sh — argument parsing into _MAX_SPRINTS and _DIRECTION.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_ARGS="$SCRIPT_DIR/../scripts/parse-args.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_parse_args.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Just a number
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Just a number"

OUT=$(bash "$PARSE_ARGS" "5" 2>/dev/null) || true
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "5" "number-only → _MAX_SPRINTS=5"
assert_eq "$_DIRECTION" "" "number-only → empty direction"

OUT=$(bash "$PARSE_ARGS" "10" 2>/dev/null) || true
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "10" "number 10 → _MAX_SPRINTS=10"

OUT=$(bash "$PARSE_ARGS" "1" 2>/dev/null) || true
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "1" "number 1 → _MAX_SPRINTS=1"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Number + direction
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Number + direction"

OUT=$(bash "$PARSE_ARGS" "5 build REST" 2>/dev/null)
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "5" "number+direction → _MAX_SPRINTS=5"
assert_eq "$_DIRECTION" "build REST" "number+direction → _DIRECTION='build REST'"

OUT=$(bash "$PARSE_ARGS" "3 fix auth bugs" 2>/dev/null)
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "3" "3 fix auth → _MAX_SPRINTS=3"
assert_eq "$_DIRECTION" "fix auth bugs" "3 fix auth → _DIRECTION='fix auth bugs'"

# ═══════════════════════════════════════════════════════════════════════════
# 3. "unlimited" keyword
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. unlimited keyword"

OUT=$(bash "$PARSE_ARGS" "unlimited" 2>/dev/null) || true
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "unlimited" "unlimited → _MAX_SPRINTS=unlimited"

# Case insensitive
OUT=$(bash "$PARSE_ARGS" "Unlimited" 2>/dev/null) || true
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "unlimited" "Unlimited (capitalized) → _MAX_SPRINTS=unlimited"

OUT=$(bash "$PARSE_ARGS" "UNLIMITED" 2>/dev/null) || true
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "unlimited" "UNLIMITED (uppercase) → _MAX_SPRINTS=unlimited"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Text-only direction (no number)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Text-only direction"

OUT=$(bash "$PARSE_ARGS" "fix the bug" 2>/dev/null)
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "5" "text-only → _MAX_SPRINTS=5 (default)"
assert_eq "$_DIRECTION" "fix the bug" "text-only → _DIRECTION='fix the bug'"

OUT=$(bash "$PARSE_ARGS" "build REST API" 2>/dev/null)
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "5" "text-only build → default _MAX_SPRINTS"
assert_eq "$_DIRECTION" "build REST API" "text-only build → direction preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Empty args
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Empty args"

OUT=$(bash "$PARSE_ARGS" "" 2>/dev/null) || true
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "5" "empty → _MAX_SPRINTS=5 (default)"
assert_eq "$_DIRECTION" "" "empty → empty direction"

# Empty args produce hint on stderr
ERR=$(bash "$PARSE_ARGS" "" 2>&1 1>/dev/null) || true
assert_contains "$ERR" "Hint" "empty args emit hint on stderr"

# ═══════════════════════════════════════════════════════════════════════════
# 6. No args at all (missing arg)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. No args at all"

OUT=$(bash "$PARSE_ARGS" 2>/dev/null) || true
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "5" "no arg → _MAX_SPRINTS=5 (default)"
assert_eq "$_DIRECTION" "" "no arg → empty direction"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Special characters in direction
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Special characters in direction"

OUT=$(bash "$PARSE_ARGS" "fix bug & add tests" 2>/dev/null)
eval "$OUT"
assert_eq "$_DIRECTION" "fix bug & add tests" "ampersand in direction preserved"

OUT=$(bash "$PARSE_ARGS" "3 handle 'quotes' properly" 2>/dev/null)
eval "$OUT"
assert_eq "$_MAX_SPRINTS" "3" "special chars → number still parsed"
assert_contains "$_DIRECTION" "quotes" "single quotes in direction handled"

OUT=$(bash "$PARSE_ARGS" "add feature (v2)" 2>/dev/null)
eval "$OUT"
assert_contains "$_DIRECTION" "feature" "parens in direction handled"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Stderr output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Stderr output"

ERR=$(bash "$PARSE_ARGS" "5 build REST" 2>&1 1>/dev/null)
assert_contains "$ERR" "MAX_SPRINTS: 5" "stderr shows MAX_SPRINTS"
assert_contains "$ERR" "DIRECTION: build REST" "stderr shows DIRECTION"

ERR=$(bash "$PARSE_ARGS" "7" 2>&1 1>/dev/null) || true
assert_contains "$ERR" "MAX_SPRINTS: 7" "number-only stderr shows MAX_SPRINTS"

# ═══════════════════════════════════════════════════════════════════════════
# 9. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. --help flag"

HELP=$(bash "$PARSE_ARGS" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
assert_contains "$HELP" "_MAX_SPRINTS" "--help mentions _MAX_SPRINTS"
assert_contains "$HELP" "_DIRECTION" "--help mentions _DIRECTION"
assert_contains "$HELP" "Examples" "--help includes examples"

bash "$PARSE_ARGS" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 10. -h short flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. -h short flag"

HELP_SHORT=$(bash "$PARSE_ARGS" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h shows Usage"

bash "$PARSE_ARGS" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Output is eval-safe
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Output is eval-safe"

OUT=$(bash "$PARSE_ARGS" "5 build REST API" 2>/dev/null)
assert_contains "$OUT" "_MAX_SPRINTS=" "output contains _MAX_SPRINTS="
assert_contains "$OUT" "_DIRECTION=" "output contains _DIRECTION="

# Verify eval doesn't fail
eval "$OUT" 2>/dev/null
assert_eq "$?" "0" "eval of output succeeds"

print_results
