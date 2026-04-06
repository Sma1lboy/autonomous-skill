#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$SCRIPT_DIR/../scripts/skill-registry.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_skill_registry.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Helper: create a skill dir with SKILL.md ─────────────────────────────

make_skill() {
  local dir="$1"
  local name="${2:-}"
  local content="${3:-}"
  mkdir -p "$dir"
  if [ -n "$content" ]; then
    printf '%b\n' "$content" > "$dir/SKILL.md"
  elif [ -n "$name" ]; then
    cat > "$dir/SKILL.md" << EOF
# $name

This skill does $name things.

## Setup

Install dependencies.

## Usage

Run the skill.

## Configuration

Set options.
EOF
  else
    cat > "$dir/SKILL.md" << EOF
# Test Skill

A test skill for testing.

## Commands

It has commands.
EOF
  fi
}

# ── 1. Register with --summary ──────────────────────────────────────────

echo ""
echo "1. Register with --summary"

T=$(new_tmp)
make_skill "$T/skills/deploy" "Deploy"
RESULT=$(bash "$REGISTRY" register "$T" "$T/skills/deploy" --summary "Deploy to production servers")
assert_eq "$RESULT" "deploy" "register returns skill name"
assert_file_exists "$T/.autonomous/skill-registry/deploy.json" "skill JSON file created"

# Verify JSON contents
JSON=$(cat "$T/.autonomous/skill-registry/deploy.json")
assert_contains "$JSON" '"name": "deploy"' "JSON has name"
assert_contains "$JSON" '"summary": "Deploy to production servers"' "JSON has summary"
assert_contains "$JSON" '"last_updated"' "JSON has last_updated"
assert_contains "$JSON" '"capabilities"' "JSON has capabilities"
assert_contains "$JSON" '"path"' "JSON has path"

# Verify capabilities extracted from headings
assert_contains "$JSON" "Setup" "capabilities include Setup heading"
assert_contains "$JSON" "Usage" "capabilities include Usage heading"
assert_contains "$JSON" "Configuration" "capabilities include Configuration heading"

# ── 2. Register without --summary (mock claude unavailable) ─────────────

echo ""
echo "2. Register without --summary (fallback)"

T=$(new_tmp)
make_skill "$T/skills/build" "Build" "# Build\n\nCompiles the project with optimization flags.\n\n## Steps\n\nRun build."

# Use PATH manipulation to ensure claude is not found
RESULT=$(PATH="/usr/bin:/bin" bash "$REGISTRY" register "$T" "$T/skills/build")
assert_eq "$RESULT" "build" "register without summary returns name"
assert_file_exists "$T/.autonomous/skill-registry/build.json" "skill file created without summary flag"

# Should have auto-generated summary from content
JSON=$(cat "$T/.autonomous/skill-registry/build.json")
assert_contains "$JSON" '"summary"' "auto summary present"

# ── 3. Register with failed claude (fallback summary) ───────────────────

echo ""
echo "3. Register with mock claude failure"

T=$(new_tmp)
make_skill "$T/skills/test-runner" "Test Runner" "# Test Runner\n\nRuns all test suites in parallel.\n\n## Options\n\nConfigure."

# Create a fake claude that always fails
FAKE_BIN="$T/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" << 'FAKEOF'
#!/usr/bin/env bash
exit 1
FAKEOF
chmod +x "$FAKE_BIN/claude"

RESULT=$(PATH="$FAKE_BIN:/usr/bin:/bin" bash "$REGISTRY" register "$T" "$T/skills/test-runner")
assert_eq "$RESULT" "test-runner" "register with failed claude returns name"
JSON=$(cat "$T/.autonomous/skill-registry/test-runner.json")
assert_contains "$JSON" '"summary"' "fallback summary present after claude failure"

# ── 4. Register extracts name from heading ──────────────────────────────

echo ""
echo "4. Name extraction"

T=$(new_tmp)
make_skill "$T/skills/my-dir" "" "# Custom Skill Name\n\nDoes stuff.\n\n## Features\n\nMany."
RESULT=$(bash "$REGISTRY" register "$T" "$T/skills/my-dir" --summary "Test")
assert_eq "$RESULT" "custom-skill-name" "name extracted from heading, not dir"

# Fallback to dir name when no heading
T2=$(new_tmp)
mkdir -p "$T2/skills/fallback-dir"
echo "No heading here, just content." > "$T2/skills/fallback-dir/SKILL.md"
RESULT2=$(bash "$REGISTRY" register "$T2" "$T2/skills/fallback-dir" --summary "Test")
assert_eq "$RESULT2" "fallback-dir" "name falls back to directory name"

# ── 5. Register overwrites existing ────────────────────────────────────

echo ""
echo "5. Re-register overwrites"

T=$(new_tmp)
make_skill "$T/skills/deploy" "Deploy"
bash "$REGISTRY" register "$T" "$T/skills/deploy" --summary "Version 1" > /dev/null

JSON1=$(cat "$T/.autonomous/skill-registry/deploy.json")
assert_contains "$JSON1" "Version 1" "first registration has V1 summary"

bash "$REGISTRY" register "$T" "$T/skills/deploy" --summary "Version 2" > /dev/null
JSON2=$(cat "$T/.autonomous/skill-registry/deploy.json")
assert_contains "$JSON2" "Version 2" "re-register overwrites with V2 summary"

# ── 6. List empty ───────────────────────────────────────────────────────

echo ""
echo "6. List"

T=$(new_tmp)
RESULT=$(bash "$REGISTRY" list "$T")
assert_eq "$RESULT" "" "list on empty registry is empty"

# List with skills
make_skill "$T/skills/alpha" "Alpha"
make_skill "$T/skills/beta" "Beta"
bash "$REGISTRY" register "$T" "$T/skills/alpha" --summary "Alpha skill" > /dev/null
bash "$REGISTRY" register "$T" "$T/skills/beta" --summary "Beta skill" > /dev/null

LIST=$(bash "$REGISTRY" list "$T")
assert_contains "$LIST" "alpha — Alpha skill" "list shows alpha"
assert_contains "$LIST" "beta — Beta skill" "list shows beta"

# Verify sorted order
ALPHA_LINE=$(echo "$LIST" | grep -n "alpha" | head -1 | cut -d: -f1)
BETA_LINE=$(echo "$LIST" | grep -n "beta" | head -1 | cut -d: -f1)
assert_eq "$([ "$ALPHA_LINE" -lt "$BETA_LINE" ] && echo "sorted" || echo "unsorted")" "sorted" "list is sorted alphabetically"

# ── 7. Get existing ────────────────────────────────────────────────────

echo ""
echo "7. Get"

T=$(new_tmp)
make_skill "$T/skills/deploy" "Deploy"
bash "$REGISTRY" register "$T" "$T/skills/deploy" --summary "Deploy to prod" > /dev/null

GOT=$(bash "$REGISTRY" get "$T" "deploy")
assert_contains "$GOT" '"name": "deploy"' "get returns correct name"
assert_contains "$GOT" '"summary": "Deploy to prod"' "get returns correct summary"
assert_contains "$GOT" '"capabilities"' "get returns capabilities"
assert_contains "$GOT" '"path"' "get returns path"
assert_contains "$GOT" '"last_updated"' "get returns last_updated"

# Verify it's valid JSON
VALID=$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('ok')" "$GOT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "get output is valid JSON"

# ── 8. Get missing ─────────────────────────────────────────────────────

echo ""
echo "8. Get missing"

T=$(new_tmp)
ERR=$(bash "$REGISTRY" get "$T" "nonexistent" 2>&1 || true)
assert_contains "$ERR" "ERROR" "get missing skill returns error"
assert_contains "$ERR" "not found" "get missing skill says not found"

# ── 9. Prompt block empty ──────────────────────────────────────────────

echo ""
echo "9. Prompt block"

T=$(new_tmp)
BLOCK=$(bash "$REGISTRY" prompt-block "$T")
assert_eq "$BLOCK" "" "prompt-block empty when no skills"

# Exit code should be 0 even when empty
bash "$REGISTRY" prompt-block "$T"
assert_eq "$?" "0" "prompt-block exits 0 when empty"

# Prompt block with skills
make_skill "$T/skills/deploy" "Deploy"
make_skill "$T/skills/test" "Test"
bash "$REGISTRY" register "$T" "$T/skills/deploy" --summary "Deploy to prod" > /dev/null
bash "$REGISTRY" register "$T" "$T/skills/test" --summary "Run test suites" > /dev/null

BLOCK=$(bash "$REGISTRY" prompt-block "$T")
assert_contains "$BLOCK" "## Available Skills" "prompt-block has header"
assert_contains "$BLOCK" 'deploy' "prompt-block has deploy skill"
assert_contains "$BLOCK" 'test' "prompt-block has test skill"
assert_contains "$BLOCK" "Deploy to prod" "prompt-block has deploy summary"
assert_contains "$BLOCK" "Run test suites" "prompt-block has test summary"

# ── 10. Scan discovers skills ──────────────────────────────────────────

echo ""
echo "10. Scan"

T=$(new_tmp)
make_skill "$T/searchdir/skill-a" "Skill A" "# Skill A\n\nDoes A things.\n\n## Commands\n\nRun A."
make_skill "$T/searchdir/skill-b" "Skill B" "# Skill B\n\nDoes B things.\n\n## Commands\n\nRun B."
make_skill "$T/searchdir/nested/skill-c" "Skill C" "# Skill C\n\nDoes C things.\n\n## Commands\n\nRun C."

RESULT=$(bash "$REGISTRY" scan "$T" "$T/searchdir")
assert_contains "$RESULT" "3 new" "scan finds 3 new skills"

# Verify all registered
assert_file_exists "$T/.autonomous/skill-registry/skill-a.json" "skill-a registered by scan"
assert_file_exists "$T/.autonomous/skill-registry/skill-b.json" "skill-b registered by scan"
assert_file_exists "$T/.autonomous/skill-registry/skill-c.json" "skill-c registered by scan"

# ── 11. Scan idempotent ────────────────────────────────────────────────

echo ""
echo "11. Scan idempotent"

# Scan again — should skip all 3
RESULT2=$(bash "$REGISTRY" scan "$T" "$T/searchdir")
assert_contains "$RESULT2" "0 new" "rescan finds 0 new"
assert_contains "$RESULT2" "3 existing" "rescan shows 3 existing"

# ── 12. Scan with partial registration ─────────────────────────────────

echo ""
echo "12. Scan partial"

T=$(new_tmp)
make_skill "$T/searchdir/alpha" "Alpha" "# Alpha\n\nAlpha things.\n\n## Cmds\n\nRun."
make_skill "$T/searchdir/beta" "Beta" "# Beta\n\nBeta things.\n\n## Cmds\n\nRun."

# Pre-register alpha
bash "$REGISTRY" register "$T" "$T/searchdir/alpha" --summary "Already here" > /dev/null

RESULT=$(bash "$REGISTRY" scan "$T" "$T/searchdir")
assert_contains "$RESULT" "1 new" "scan finds only unregistered skills"
assert_contains "$RESULT" "1 existing" "scan reports existing count"

# ── 13. Unregister ─────────────────────────────────────────────────────

echo ""
echo "13. Unregister"

T=$(new_tmp)
make_skill "$T/skills/deploy" "Deploy"
bash "$REGISTRY" register "$T" "$T/skills/deploy" --summary "Deploy" > /dev/null
assert_file_exists "$T/.autonomous/skill-registry/deploy.json" "skill exists before unregister"

RESULT=$(bash "$REGISTRY" unregister "$T" "deploy")
assert_contains "$RESULT" "unregistered" "unregister confirms removal"
assert_file_not_exists "$T/.autonomous/skill-registry/deploy.json" "skill file removed after unregister"

# Unregister missing skill
ERR=$(bash "$REGISTRY" unregister "$T" "nonexistent" 2>&1 || true)
assert_contains "$ERR" "ERROR" "unregister missing skill returns error"

# ── 14. Missing SKILL.md ──────────────────────────────────────────────

echo ""
echo "14. Missing SKILL.md"

T=$(new_tmp)
mkdir -p "$T/skills/empty-dir"
ERR=$(bash "$REGISTRY" register "$T" "$T/skills/empty-dir" --summary "Test" 2>&1 || true)
assert_contains "$ERR" "ERROR" "register without SKILL.md fails"
assert_contains "$ERR" "SKILL.md not found" "error mentions SKILL.md"

# ── 15. Invalid paths ─────────────────────────────────────────────────

echo ""
echo "15. Invalid paths"

T=$(new_tmp)
ERR=$(bash "$REGISTRY" register "$T" "$T/nonexistent" --summary "Test" 2>&1 || true)
assert_contains "$ERR" "ERROR" "register with nonexistent dir fails"

ERR=$(bash "$REGISTRY" scan "$T" "$T/nonexistent" 2>&1 || true)
assert_contains "$ERR" "ERROR" "scan with nonexistent dir fails"

# ── 16. Empty args ─────────────────────────────────────────────────────

echo ""
echo "16. Empty args"

T=$(new_tmp)
ERR=$(bash "$REGISTRY" register "$T" 2>&1 || true)
assert_contains "$ERR" "ERROR" "register without skill-dir fails"

ERR=$(bash "$REGISTRY" get "$T" 2>&1 || true)
assert_contains "$ERR" "ERROR" "get without skill-name fails"

ERR=$(bash "$REGISTRY" scan "$T" 2>&1 || true)
assert_contains "$ERR" "ERROR" "scan without search-dir fails"

ERR=$(bash "$REGISTRY" unregister "$T" 2>&1 || true)
assert_contains "$ERR" "ERROR" "unregister without skill-name fails"

# ── 17. Unknown command ────────────────────────────────────────────────

echo ""
echo "17. Unknown command"

T=$(new_tmp)
ERR=$(bash "$REGISTRY" badcmd "$T" 2>&1 || true)
assert_contains "$ERR" "Unknown command" "unknown command rejected"

# No command
ERR=$(bash "$REGISTRY" 2>&1 || true)
assert_contains "$ERR" "ERROR" "no command rejected"

# ── 18. Help flags ─────────────────────────────────────────────────────

echo ""
echo "18. Help flags"

HELP1=$(bash "$REGISTRY" --help 2>&1)
assert_contains "$HELP1" "Usage:" "--help shows usage"
assert_contains "$HELP1" "register" "--help mentions register"
assert_contains "$HELP1" "scan" "--help mentions scan"

HELP2=$(bash "$REGISTRY" -h 2>&1)
assert_contains "$HELP2" "Usage:" "-h shows usage"

HELP3=$(bash "$REGISTRY" help 2>&1)
assert_contains "$HELP3" "Usage:" "help shows usage"

# ── 19. --summary requires value ───────────────────────────────────────

echo ""
echo "19. --summary validation"

T=$(new_tmp)
make_skill "$T/skills/deploy" "Deploy"
ERR=$(bash "$REGISTRY" register "$T" "$T/skills/deploy" --summary 2>&1 || true)
assert_contains "$ERR" "ERROR" "--summary without value fails"

# ── 20. Unknown flag ───────────────────────────────────────────────────

echo ""
echo "20. Unknown flag"

T=$(new_tmp)
make_skill "$T/skills/deploy" "Deploy"
ERR=$(bash "$REGISTRY" register "$T" "$T/skills/deploy" --badflag 2>&1 || true)
assert_contains "$ERR" "ERROR" "unknown flag rejected"

# ── 21. Capabilities extraction ────────────────────────────────────────

echo ""
echo "21. Capabilities extraction"

T=$(new_tmp)
mkdir -p "$T/skills/multi"
cat > "$T/skills/multi/SKILL.md" << 'EOF'
# Multi Skill

A skill with many sections.

## Installation

Install it.

## Configuration

Configure it.

## Advanced Usage

Use advanced features.

## Troubleshooting

Fix problems.
EOF

bash "$REGISTRY" register "$T" "$T/skills/multi" --summary "Multi-feature skill" > /dev/null
JSON=$(cat "$T/.autonomous/skill-registry/multi-skill.json")
assert_contains "$JSON" "Installation" "capabilities include Installation"
assert_contains "$JSON" "Configuration" "capabilities include Configuration"
assert_contains "$JSON" "Advanced Usage" "capabilities include Advanced Usage"
assert_contains "$JSON" "Troubleshooting" "capabilities include Troubleshooting"

# ── 22. Atomic writes (no tmp files left) ──────────────────────────────

echo ""
echo "22. Atomic writes"

T=$(new_tmp)
make_skill "$T/skills/atomic" "Atomic"
bash "$REGISTRY" register "$T" "$T/skills/atomic" --summary "Test atomic" > /dev/null

TMPS=$(find "$T/.autonomous/skill-registry" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMPS" "0" "no tmp files left after register"

# ── 23. Path stored as absolute ────────────────────────────────────────

echo ""
echo "23. Absolute paths"

T=$(new_tmp)
make_skill "$T/skills/abs" "Abs"
bash "$REGISTRY" register "$T" "$T/skills/abs" --summary "Test" > /dev/null
JSON=$(cat "$T/.autonomous/skill-registry/abs.json")
assert_contains "$JSON" '"path": "/' "path is absolute"

# ── 24. Scan with no SKILL.md files ───────────────────────────────────

echo ""
echo "24. Scan empty directory"

T=$(new_tmp)
mkdir -p "$T/empty-search"
RESULT=$(bash "$REGISTRY" scan "$T" "$T/empty-search")
assert_contains "$RESULT" "0 new" "scan of empty dir finds 0"
assert_contains "$RESULT" "0 existing" "scan of empty dir shows 0 existing"

# ── 25. List after unregister ──────────────────────────────────────────

echo ""
echo "25. List after unregister"

T=$(new_tmp)
make_skill "$T/skills/alpha" "Alpha"
make_skill "$T/skills/beta" "Beta"
bash "$REGISTRY" register "$T" "$T/skills/alpha" --summary "Alpha" > /dev/null
bash "$REGISTRY" register "$T" "$T/skills/beta" --summary "Beta" > /dev/null

LIST1=$(bash "$REGISTRY" list "$T")
assert_contains "$LIST1" "alpha" "alpha in list before unregister"

bash "$REGISTRY" unregister "$T" "alpha" > /dev/null
LIST2=$(bash "$REGISTRY" list "$T")
assert_not_contains "$LIST2" "alpha" "alpha removed from list after unregister"
assert_contains "$LIST2" "beta" "beta still in list after unregistering alpha"

# ── 26. Prompt block after unregister ──────────────────────────────────

echo ""
echo "26. Prompt block after unregister"

bash "$REGISTRY" unregister "$T" "beta" > /dev/null
BLOCK=$(bash "$REGISTRY" prompt-block "$T")
assert_eq "$BLOCK" "" "prompt-block empty after all skills unregistered"

# ── 27. Register skill with special chars in heading ───────────────────

echo ""
echo "27. Special characters in name"

T=$(new_tmp)
make_skill "$T/skills/weird" "" "# My Cool Skill! (v2.0)\n\nDoes cool stuff.\n\n## Features\n\nMany."
RESULT=$(bash "$REGISTRY" register "$T" "$T/skills/weird" --summary "Cool")
# Name should be sanitized
assert_contains "$RESULT" "my-cool-skill" "special chars sanitized in name"

# ── 28. Scan with nested deep structure ────────────────────────────────

echo ""
echo "28. Deep nested scan"

T=$(new_tmp)
make_skill "$T/search/a/b/c/deep-skill" "Deep Skill" "# Deep Skill\n\nVery deep.\n\n## API\n\nCall it."
RESULT=$(bash "$REGISTRY" scan "$T" "$T/search")
assert_contains "$RESULT" "1 new" "scan finds deeply nested skill"

# ── 29. Multiple registrations build registry ─────────────────────────

echo ""
echo "29. Multiple registrations"

T=$(new_tmp)
for name in alpha beta gamma delta epsilon; do
  make_skill "$T/skills/$name" "$(echo "$name" | sed 's/./\U&/')"
  bash "$REGISTRY" register "$T" "$T/skills/$name" --summary "Skill $name" > /dev/null
done

LIST=$(bash "$REGISTRY" list "$T")
LINE_COUNT=$(echo "$LIST" | wc -l | tr -d ' ')
assert_eq "$LINE_COUNT" "5" "5 skills listed after 5 registrations"

BLOCK=$(bash "$REGISTRY" prompt-block "$T")
assert_contains "$BLOCK" "## Available Skills" "prompt-block header with 5 skills"
BLOCK_LINES=$(echo "$BLOCK" | grep -c '^\- \*\*')
assert_eq "$BLOCK_LINES" "5" "prompt-block has 5 skill entries"

# ── 30. Corrupt JSON file handling ─────────────────────────────────────

echo ""
echo "30. Corrupt JSON handling"

T=$(new_tmp)
make_skill "$T/skills/good" "Good"
bash "$REGISTRY" register "$T" "$T/skills/good" --summary "Good skill" > /dev/null

# Corrupt one file
echo "not json{{{" > "$T/.autonomous/skill-registry/corrupt.json"

# List should still work (skip corrupt files)
LIST=$(bash "$REGISTRY" list "$T")
assert_contains "$LIST" "good" "list works despite corrupt file"

# Prompt block should still work
BLOCK=$(bash "$REGISTRY" prompt-block "$T")
assert_contains "$BLOCK" "good" "prompt-block works despite corrupt file"

# ── 31. Scan generates reasonable auto-summary ─────────────────────────

echo ""
echo "31. Scan auto-summary quality"

T=$(new_tmp)
mkdir -p "$T/searchdir/auto-sum"
cat > "$T/searchdir/auto-sum/SKILL.md" << 'SKILLEOF'
# Auto Summary

This skill automatically generates summaries from content.
It reads the first few lines and creates a description.

## How It Works

Magic.
SKILLEOF

bash "$REGISTRY" scan "$T" "$T/searchdir" > /dev/null
JSON=$(cat "$T/.autonomous/skill-registry/auto-summary.json")
assert_contains "$JSON" "automatically generates summaries" "scan auto-summary captures content"

# ── 32. Register preserves last_updated timestamp ──────────────────────

echo ""
echo "32. Timestamp"

T=$(new_tmp)
make_skill "$T/skills/ts" "Ts"
bash "$REGISTRY" register "$T" "$T/skills/ts" --summary "V1" > /dev/null
TS1=$(python3 -c "import json; print(json.load(open('$T/.autonomous/skill-registry/ts.json'))['last_updated'])")
assert_contains "$TS1" "T" "timestamp has ISO format"
assert_contains "$TS1" "Z" "timestamp is UTC"

# ── 33. Get returns parseable JSON with all fields ─────────────────────

echo ""
echo "33. JSON structure"

T=$(new_tmp)
make_skill "$T/skills/full" "Full"
bash "$REGISTRY" register "$T" "$T/skills/full" --summary "Full test" > /dev/null

FIELDS=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/skill-registry/full.json'))
required = ['name', 'path', 'summary', 'capabilities', 'last_updated']
missing = [f for f in required if f not in d]
if missing:
    print('missing: ' + ', '.join(missing))
else:
    print('ok')
")
assert_eq "$FIELDS" "ok" "all required fields present in JSON"

CAPS_TYPE=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/skill-registry/full.json'))
print(type(d['capabilities']).__name__)
")
assert_eq "$CAPS_TYPE" "list" "capabilities is a list"

# ── Done ─────────────────────────────────────────────────────────────────

print_results
