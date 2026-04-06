#!/usr/bin/env bash
# Tests for scripts/persona.sh
# Uses tests/claude mock binary — no real API calls.
#
# OWNER.md is now GLOBAL (lives in skill root dir, not per-project).
# Tests back up and restore the real OWNER.md to avoid side effects.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERSONA_SH="$REPO_ROOT/scripts/persona.sh"
GLOBAL_OWNER="$REPO_ROOT/OWNER.md"

# Intercept 'claude' with mock before real binary
export PATH="$REPO_ROOT/tests:$PATH"

# Back up existing global OWNER.md (restore at end)
OWNER_BACKUP=""
if [ -f "$GLOBAL_OWNER" ]; then
  OWNER_BACKUP=$(mktemp)
  cp "$GLOBAL_OWNER" "$OWNER_BACKUP"
fi

# Extend existing cleanup trap from test_helpers.sh
_orig_cleanup=$(trap -p EXIT | sed "s/trap -- '//;s/' EXIT//")
restore_and_cleanup() {
  if [ -n "$OWNER_BACKUP" ] && [ -f "$OWNER_BACKUP" ]; then
    cp "$OWNER_BACKUP" "$GLOBAL_OWNER"
    rm -f "$OWNER_BACKUP"
  fi
  eval "$_orig_cleanup"
}
trap restore_and_cleanup EXIT

# Helper: remove global OWNER.md so tests start clean
remove_global_owner() {
  rm -f "$GLOBAL_OWNER"
}

# ── Tests ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_persona.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. OWNER.md already exists → return path, do not overwrite
echo ""
echo "1. OWNER.md already exists (global)"
remove_global_owner
echo "# Existing Persona" > "$GLOBAL_OWNER"
T=$(new_tmp)
OUT=$(bash "$PERSONA_SH" "$T" 2>/dev/null)
# Output path may contain ../ — normalize both for comparison
REAL_OUT=$(cd "$(dirname "$OUT")" && echo "$(pwd)/$(basename "$OUT")")
REAL_EXPECT=$(cd "$(dirname "$GLOBAL_OWNER")" && echo "$(pwd)/$(basename "$GLOBAL_OWNER")")
assert_eq "$REAL_OUT" "$REAL_EXPECT" "returns global OWNER.md path"
assert_file_contains "$GLOBAL_OWNER" "Existing Persona" "does not overwrite existing content"

# 2. No context (no git, no CLAUDE.md, no README) → copies template to global
echo ""
echo "2. No context → copies template"
remove_global_owner
T=$(new_tmp)
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
assert_file_exists "$GLOBAL_OWNER" "OWNER.md created in skill dir"
assert_file_contains "$GLOBAL_OWNER" "Priorities" "template content present"

# 3. Has CLAUDE.md → invokes mock claude, writes generated persona to global
echo ""
echo "3. Has CLAUDE.md → claude generates persona"
remove_global_owner
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
  assert_file_exists "$GLOBAL_OWNER" "OWNER.md created in skill dir"
  assert_file_contains "$GLOBAL_OWNER" "Ship fast" "generated content written"
else
  echo "  skip (jq not installed)"
fi

# 4. Has git history → invokes mock claude, writes generated persona to global
echo ""
echo "4. Has git history → claude generates persona"
remove_global_owner
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
  assert_file_exists "$GLOBAL_OWNER" "OWNER.md created in skill dir"
  assert_file_contains "$GLOBAL_OWNER" "Code quality" "git-history-based persona written"
else
  echo "  skip (jq not installed)"
fi

# 5. Has README.md → invokes mock claude, writes generated persona to global
echo ""
echo "5. Has README.md → claude generates persona"
remove_global_owner
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
  assert_file_exists "$GLOBAL_OWNER" "OWNER.md created in skill dir"
  assert_file_contains "$GLOBAL_OWNER" "User experience" "README-based persona written"
else
  echo "  skip (jq not installed)"
fi

# 6. Claude fails (MOCK_CLAUDE_EXIT=1) → falls back to template
echo ""
echo "6. Claude fails → falls back to template"
remove_global_owner
T=$(new_tmp)
echo "# CLAUDE.md" > "$T/CLAUDE.md"
export MOCK_CLAUDE_OUTPUT="FAIL_TEST_SENTINEL_SHOULD_NOT_APPEAR"
export MOCK_CLAUDE_EXIT=1
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
unset MOCK_CLAUDE_EXIT MOCK_CLAUDE_OUTPUT
assert_file_exists "$GLOBAL_OWNER" "OWNER.md still created"
assert_file_contains "$GLOBAL_OWNER" "Priorities" "template used as fallback"
assert_file_not_contains "$GLOBAL_OWNER" "FAIL_TEST_SENTINEL_SHOULD_NOT_APPEAR" "generated content not written on failure"

# 7. Idempotent — second call does not regenerate
echo ""
echo "7. Idempotent — second call returns same file"
remove_global_owner
echo "# Fixed Content" > "$GLOBAL_OWNER"
T=$(new_tmp)
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
assert_file_contains "$GLOBAL_OWNER" "Fixed Content" "content unchanged after second call"

# 8. OWNER.md is NOT created in project dir
echo ""
echo "8. OWNER.md is global, not per-project"
remove_global_owner
T=$(new_tmp)
bash "$PERSONA_SH" "$T" >/dev/null 2>&1
assert_file_exists "$GLOBAL_OWNER" "OWNER.md created in skill dir"
assert_file_not_exists "$T/OWNER.md" "no OWNER.md in project dir"

# ═══════════════════════════════════════════════════════════════════════════
# 9. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. --help flag"
HELP=$(bash "$PERSONA_SH" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows usage"
assert_contains "$HELP" "OWNER.md" "--help mentions OWNER.md"
assert_contains "$HELP" "project-dir" "--help mentions project-dir arg"

bash "$PERSONA_SH" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits with code 0"

HELP_SHORT=$(bash "$PERSONA_SH" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h also shows usage"

print_results
