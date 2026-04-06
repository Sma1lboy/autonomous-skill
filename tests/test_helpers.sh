#!/usr/bin/env bash
# test_helpers.sh — Shared test framework for all test suites.
# Source this at the top of each test file:
#   source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

# ── Counters ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0

# ── Assertions ─────────────────────────────────────────────────────────────────

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
assert_ge() {
  [ "$1" -ge "$2" ] && ok "$3" || fail "$3 — got '$1', want >= '$2'"
}
assert_le() {
  [ "$1" -le "$2" ] && ok "$3" || fail "$3 — got '$1', want <= '$2'"
}
assert_file_exists() {
  [ -f "$1" ] && ok "$2" || fail "$2 — file not found: $1"
}
assert_file_contains() {
  grep -q "$2" "$1" 2>/dev/null && ok "$3" || fail "$3 — '$2' not in $1"
}
assert_file_not_contains() {
  grep -q "$2" "$1" 2>/dev/null && fail "$3 — '$2' unexpectedly in $1" || ok "$3"
}
assert_file_not_exists() {
  [ ! -e "$1" ] && ok "$2" || fail "$2 — file exists: $1"
}

# ── Temp dir management ───────────────────────────────────────────────────────
TMPDIRS=()
new_tmp() { local d; d=$(mktemp -d); TMPDIRS+=("$d"); echo "$d"; }
cleanup() { [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf "${TMPDIRS[@]}" || true; }
trap cleanup EXIT

# ── Summary helper ─────────────────────────────────────────────────────────────
print_results() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Results: $PASS passed, $FAIL failed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  [ "$FAIL" -eq 0 ]
}
