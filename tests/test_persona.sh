#!/usr/bin/env bash
# Tests for scripts/persona.sh
# Uses tests/claude mock binary — no real API calls.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERSONA_SH="$REPO_ROOT/scripts/persona.sh"

# Intercept 'claude' with mock before real binary
export PATH="$REPO_ROOT/tests:$PATH"

# ── Minimal test framework ──────────────────────────────────────────────────
PASS=0; FAIL=0

ok()   { echo "  ok  $*"; ((PASS++)) || true; }
fail() { echo "  FAIL $*"; ((FAIL++)) || true; }

assert_eq() {
  [ "$1" = "$2" ] && ok "$3" || fail "$3 — got '$1', want '$2'"
}
assert_file_exists() {
  [ -f "$1" ] && ok "$2" || fail "$2 — file missing: $1"
}
assert_file_contains() {
  grep -q "$2" "$1" 2>/dev/null && ok "$3" || fail "$3 — '$2' not in $1"
}
assert_file_not_contains() {
  grep -q "$2" "$1" 2>/dev/null && fail "$3 — '$2' unexpectedly in $1" || ok "$3"
}

# ── Temp dir management ─────────────────────────────────────────────────────
TMPDIRS=()
new_tmp() { local d; d=$(mktemp -d); TMPDIRS+=("$d"); echo "$d"; }
cleanup() { [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf "${TMPDIRS[@]}" || true; }
trap cleanup EXIT

# ── Tests ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_persona.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. OWNER.md already exists → return path, do not overwrite
echo ""
echo "1. OWNER.md already exists"
T=$(new_tmp)
echo "# Existing Persona" > "$T/OWNER.md"
OUT=$(bash "$PERSONA_SH" "$T" 2>/dev/null)
assert_eq "$OUT" "$T/OWNER.md" "returns existing path"
assert_file_contains "$T/OWNER.md" "Existing Persona" "does not overwrite existing content"

# 2. No context (no git, no CLAUDE.md, no README) → copies template
echo ""
echo "2. No context → copies template"
T=$(new_tmp)
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
assert_file_exists "$T/OWNER.md" "OWNER.md created"
assert_file_contains "$T/OWNER.md" "Priorities" "template content present"

# 3. Has CLAUDE.md → invokes mock claude, writes generated persona
echo ""
echo "3. Has CLAUDE.md → claude generates persona"
T=$(new_tmp)
echo "# Project instructions" > "$T/CLAUDE.md"
if command -v jq >/dev/null 2>&1; then
  export MOCK_CLAUDE_OUTPUT="# Owner Persona

## Priorities
Ship fast

## Style
Clean bash

## Avoid
Breaking tests

## Current focus
Test coverage"
  bash "$PERSONA_SH" "$T" >/dev/null 2>&1
  unset MOCK_CLAUDE_OUTPUT
  assert_file_exists "$T/OWNER.md" "OWNER.md created"
  assert_file_contains "$T/OWNER.md" "Ship fast" "generated content written"
else
  echo "  skip (jq not installed)"
fi

# 4. Has git history → invokes mock claude, writes generated persona
echo ""
echo "4. Has git history → claude generates persona"
T=$(new_tmp)
git -C "$T" init -q
git -C "$T" -c user.email="t@t.com" -c user.name="T" commit -m "init" --allow-empty -q
if command -v jq >/dev/null 2>&1; then
  export MOCK_CLAUDE_OUTPUT="# Owner Persona

## Priorities
Code quality

## Style
Typed, tested

## Avoid
Big rewrites

## Current focus
Refactor auth"
  bash "$PERSONA_SH" "$T" >/dev/null 2>&1
  unset MOCK_CLAUDE_OUTPUT
  assert_file_exists "$T/OWNER.md" "OWNER.md created"
  assert_file_contains "$T/OWNER.md" "Code quality" "git-history-based persona written"
else
  echo "  skip (jq not installed)"
fi

# 5. Has README.md → invokes mock claude, writes generated persona
echo ""
echo "5. Has README.md → claude generates persona"
T=$(new_tmp)
echo "# My Project" > "$T/README.md"
if command -v jq >/dev/null 2>&1; then
  export MOCK_CLAUDE_OUTPUT="# Owner Persona

## Priorities
User experience

## Style
Minimal

## Avoid
Over-engineering

## Current focus
Onboarding flow"
  bash "$PERSONA_SH" "$T" >/dev/null 2>&1
  unset MOCK_CLAUDE_OUTPUT
  assert_file_exists "$T/OWNER.md" "OWNER.md created"
  assert_file_contains "$T/OWNER.md" "User experience" "README-based persona written"
else
  echo "  skip (jq not installed)"
fi

# 6. Claude fails (MOCK_CLAUDE_EXIT=1) → falls back to template
# MOCK_CLAUDE_OUTPUT is set to a sentinel so the not_contains assertion
# actually tests something: if persona.sh mistakenly wrote generated
# content despite failure, this string would appear in OWNER.md.
echo ""
echo "6. Claude fails → falls back to template"
T=$(new_tmp)
echo "# CLAUDE.md" > "$T/CLAUDE.md"
export MOCK_CLAUDE_OUTPUT="FAIL_TEST_SENTINEL_SHOULD_NOT_APPEAR"
export MOCK_CLAUDE_EXIT=1
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
unset MOCK_CLAUDE_EXIT MOCK_CLAUDE_OUTPUT
assert_file_exists "$T/OWNER.md" "OWNER.md still created"
assert_file_contains "$T/OWNER.md" "Priorities" "template used as fallback"
assert_file_not_contains "$T/OWNER.md" "FAIL_TEST_SENTINEL_SHOULD_NOT_APPEAR" "generated content not written on failure"

# 7. Idempotent — second call does not regenerate
echo ""
echo "7. Idempotent — second call returns same file"
T=$(new_tmp)
echo "# Fixed Content" > "$T/OWNER.md"
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
assert_file_contains "$T/OWNER.md" "Fixed Content" "content unchanged after second call"

# 8. Default PROJECT_DIR is current directory
echo ""
echo "8. Default PROJECT_DIR is '.'"
T=$(new_tmp)
(cd "$T" && bash "$PERSONA_SH" >/dev/null 2>&1) || true
assert_file_exists "$T/OWNER.md" "OWNER.md created in cwd"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
[ "$FAIL" -eq 0 ]
