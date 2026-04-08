#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$REPO/scripts/build-sprint-prompt.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_build_sprint_prompt.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# make_skill: build an isolated skill dir with the files the script needs.
# $1: template name to omit (optional, for "missing template" tests)
make_skill() {
  local omit="${1:-}"
  local d; d=$(new_tmp)
  cp "$REPO/SPRINT.md" "$d/"
  mkdir -p "$d/scripts" "$d/templates"
  cp "$REPO/scripts/build-sprint-prompt.sh" "$d/scripts/"
  cp "$REPO/scripts/backlog.sh" "$d/scripts/"
  # Copy templates except the omitted one
  for t in "$REPO"/templates/*/; do
    local name; name="$(basename "$t")"
    [ "$name" = "$omit" ] && continue
    mkdir -p "$d/templates/$name"
    cp "$t/template.md" "$d/templates/$name/"
  done
  echo "$d"
}

make_project() {
  local d; d=$(new_tmp)
  mkdir -p "$d/.autonomous"
  echo "$d"
}

run_build() {
  local proj="$1" skill="$2"
  bash "$skill/scripts/build-sprint-prompt.sh" "$proj" "$skill" 1 "test direction" "" >/dev/null 2>&1
}

# ── 1. Default template when no config exists ───────────────────────────

echo ""
echo "1. default-when-no-config"
SKILL=$(make_skill)
PROJ=$(make_project)
run_build "$PROJ" "$SKILL"
assert_file_exists "$PROJ/.autonomous/sprint-prompt.md" "prompt written"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "default Allow content present"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "no gstack command leak"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "shipping or deployment commands" "default Block content present"

# ── 2. Skill-root config selects gstack ──────────────────────────────────

echo ""
echo "2. skill-root-config-picked"
SKILL=$(make_skill)
PROJ=$(make_project)
echo '{"template":"gstack"}' > "$SKILL/skill-config.json"
run_build "$PROJ" "$SKILL"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "gstack Allow inserted"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/ship" "gstack Block inserted"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "SPRINT_NUMBER: 1" "header preserved"

# ── 3. Project override beats skill-root config ─────────────────────────

echo ""
echo "3. project-override-beats-skill-root"
SKILL=$(make_skill)
PROJ=$(make_project)
echo '{"template":"gstack"}' > "$SKILL/skill-config.json"
echo '{"template":"default"}' > "$PROJ/.autonomous/skill-config.json"
run_build "$PROJ" "$SKILL"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "no gstack leak after override"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "shipping or deployment commands" "default Block used after override"

# ── 4. Unknown template name falls back to default ──────────────────────

echo ""
echo "4. unknown-template-falls-back-to-default"
SKILL=$(make_skill)
PROJ=$(make_project)
echo '{"template":"nonexistent"}' > "$SKILL/skill-config.json"
run_build "$PROJ" "$SKILL"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "fell back to default"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "no gstack leak on fallback"

# ── 5. Missing section in template.md leaves placeholder empty ──────────

echo ""
echo "5. missing-section-leaves-placeholder-empty"
SKILL=$(make_skill)
PROJ=$(make_project)
mkdir -p "$SKILL/templates/allowonly"
cat > "$SKILL/templates/allowonly/template.md" <<'EOF'
# allow only

## Allow

- Only-allow content here.
EOF
echo '{"template":"allowonly"}' > "$SKILL/skill-config.json"
run_build "$PROJ" "$SKILL"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Only-allow content here" "Allow section rendered"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_BLOCK" "missing Block marker replaced with empty"

# ── 6. Malformed JSON config treated as missing ─────────────────────────

echo ""
echo "6. malformed-json-treated-as-missing"
SKILL=$(make_skill)
PROJ=$(make_project)
echo '{not valid json' > "$PROJ/.autonomous/skill-config.json"
echo '{"template":"gstack"}' > "$SKILL/skill-config.json"
run_build "$PROJ" "$SKILL"
# Should fall through to skill-root config (gstack)
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "fell through to skill-root on bad project JSON"

# ── 7. Header params AND template content both present ─────────────────

echo ""
echo "7. header-and-template-both-present"
SKILL=$(make_skill)
PROJ=$(make_project)
echo '{"template":"gstack"}' > "$SKILL/skill-config.json"
bash "$SKILL/scripts/build-sprint-prompt.sh" "$PROJ" "$SKILL" 7 "build X" "last sprint did Y" >/dev/null 2>&1
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "SPRINT_NUMBER: 7" "sprint num in header"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "SPRINT_DIRECTION: build X" "direction in header"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "PREVIOUS_SUMMARY: last sprint did Y" "prev summary in header"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "/office-hours" "template also injected"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "# Sprint Master" "SPRINT.md body preserved"

# ── 8. No marker leakage in any rendered output ─────────────────────────

echo ""
echo "8. no-marker-leakage"
SKILL=$(make_skill)
PROJ=$(make_project)
run_build "$PROJ" "$SKILL"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_ALLOW" "no Allow marker leak (default)"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_BLOCK" "no Block marker leak (default)"
echo '{"template":"gstack"}' > "$SKILL/skill-config.json"
run_build "$PROJ" "$SKILL"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_ALLOW" "no Allow marker leak (gstack)"
assert_file_not_contains "$PROJ/.autonomous/sprint-prompt.md" "AUTO:TEMPLATE_BLOCK" "no Block marker leak (gstack)"

# ── 9. Path-traversal guard ─────────────────────────────────────────────

echo ""
echo "9. path-traversal-guard"
SKILL=$(make_skill)
PROJ=$(make_project)
echo '{"template":"../../etc"}' > "$PROJ/.autonomous/skill-config.json"
run_build "$PROJ" "$SKILL"
assert_file_contains "$PROJ/.autonomous/sprint-prompt.md" "Sketch the smallest version" "traversal rejected, default used"

# ── 10. CLI help ────────────────────────────────────────────────────────

echo ""
echo "10. CLI help"
OUT=$(bash "$SCRIPT" --help 2>&1)
assert_contains "$OUT" "Usage:" "help shows usage"

# ── Results ─────────────────────────────────────────────────────────────

print_results
