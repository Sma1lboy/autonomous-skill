#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKPT="$SCRIPT_DIR/../scripts/checkpoint.py"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.py"
BACKLOG="$SCRIPT_DIR/../scripts/backlog.py"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_checkpoint.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Minimal git project setup for tests that need git state
make_project() {
  local p
  p=$(new_tmp)
  (cd "$p" && git init -q && git -c user.name=test -c user.email=t@t.com commit --allow-empty -q -m "init") >/dev/null
  echo "$p"
}

# ── 1. Help + basic CLI ───────────────────────────────────────────────────

echo ""
echo "1. Help + basic CLI"

HELP=$(python3 "$CKPT" --help 2>&1)
assert_contains "$HELP" "Usage: checkpoint.py" "--help shows usage"
assert_contains "$HELP" "save" "--help documents save"
assert_contains "$HELP" "list" "--help documents list"
assert_contains "$HELP" "latest" "--help documents latest"
assert_contains "$HELP" "show" "--help documents show"

if python3 "$CKPT" unknowncmd "$(new_tmp)" 2>/dev/null; then
  fail "unknown command should fail"
else
  ok "unknown command rejected"
fi

# ── 2. Save with no state (empty project) ────────────────────────────────

echo ""
echo "2. Save with no state"

T=$(make_project)
OUT=$(python3 "$CKPT" save "$T")
assert_file_exists "$OUT" "checkpoint file created even without conductor state"
assert_file_contains "$OUT" "session-start" "no-state checkpoint uses 'session-start' title"
assert_file_contains "$OUT" "(no session)" "no-state shows placeholder session"
assert_file_contains "$OUT" "(no mission)" "no-state shows placeholder mission"
assert_file_contains "$OUT" "No sprints yet" "no-state shows no sprints placeholder"
assert_file_contains "$OUT" "^---$" "file has YAML frontmatter"

# ── 3. Save with conductor state ─────────────────────────────────────────

echo ""
echo "3. Save with conductor state"

T=$(make_project)
python3 "$CONDUCTOR" init "$T" "build REST API" 10 > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "add user model" > /dev/null
python3 "$CONDUCTOR" sprint-end "$T" complete "Schema + migrations landed" '["abc001","abc002"]' true > /dev/null

OUT=$(python3 "$CKPT" save "$T")
assert_file_contains "$OUT" "build REST API" "mission in checkpoint"
assert_file_contains "$OUT" "add user model" "sprint direction in checkpoint"
assert_file_contains "$OUT" "Schema + migrations landed" "sprint summary in checkpoint"
assert_file_contains "$OUT" "1 / 10" "sprint count shown"
assert_file_contains "$OUT" "2 commits" "commit count shown"
# All YAML scalars are JSON-quoted now (frontmatter injection fix).
assert_file_contains "$OUT" 'phase: "directed"' "phase in frontmatter (JSON-quoted)"
assert_file_contains "$OUT" "sprint_count: 1" "sprint count in frontmatter"
assert_file_contains "$OUT" "commit_count: 2" "commit count in frontmatter"

# Auto-generated title based on latest sprint
assert_file_contains "$OUT" "sprint 1" "title mentions latest sprint"

# ── 4. Save with --title ─────────────────────────────────────────────────

echo ""
echo "4. Save with --title"

T=$(make_project)
python3 "$CONDUCTOR" init "$T" "mission" 5 > /dev/null
OUT=$(python3 "$CKPT" save "$T" --title "pre-refactor snapshot")
assert_file_contains "$OUT" "pre-refactor snapshot" "custom title appears in checkpoint"
BASENAME=$(basename "$OUT")
assert_contains "$BASENAME" "pre-refactor-snapshot" "filename includes slugged title"

# Title validation
if python3 "$CKPT" save "$T" --title 2>/dev/null; then
  fail "--title without value should fail"
else
  ok "--title without value rejected"
fi

if python3 "$CKPT" save "$T" --unknownflag x 2>/dev/null; then
  fail "unknown flag should fail"
else
  ok "unknown flag rejected"
fi

# ── 5. Multiple saves → separate files ───────────────────────────────────

echo ""
echo "5. Multiple saves"

T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null
OUT1=$(python3 "$CKPT" save "$T" --title "first")
sleep 1  # ensure timestamp filenames differ (second-granularity)
OUT2=$(python3 "$CKPT" save "$T" --title "second")
OUT3=$(python3 "$CKPT" save "$T" --title "third-in-same-second")

[ "$OUT1" != "$OUT2" ] && ok "different timestamps produce different files" || fail "filenames collided"

LIST=$(python3 "$CKPT" list "$T")
LINE_COUNT=$(echo "$LIST" | wc -l | tr -d ' ')
assert_ge "$LINE_COUNT" "3" "list shows all 3 saves"
assert_contains "$LIST" "first" "list shows first title"
assert_contains "$LIST" "second" "list shows second title"
assert_contains "$LIST" "third" "list shows third title"

# Latest returns the most recent
LATEST=$(python3 "$CKPT" latest "$T")
assert_contains "$LATEST" "third" "latest shows most recent checkpoint"

# ── 6. Show by prefix ─────────────────────────────────────────────────────

echo ""
echo "6. Show by prefix"

T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null
OUT=$(python3 "$CKPT" save "$T" --title "unique-marker-xyz")
BASENAME=$(basename "$OUT" .md)

SHOWN=$(python3 "$CKPT" show "$T" "$BASENAME")
assert_contains "$SHOWN" "unique-marker-xyz" "show by exact prefix returns content"

# Substring fallback
SHOWN2=$(python3 "$CKPT" show "$T" "unique-marker")
assert_contains "$SHOWN2" "unique-marker-xyz" "show by substring fallback works"

# Not found
if python3 "$CKPT" show "$T" "nonexistent-xyz-qqq" 2>/dev/null; then
  fail "show of missing checkpoint should fail"
else
  ok "show of missing checkpoint rejected"
fi

# No-arg show fails
if python3 "$CKPT" show "$T" 2>/dev/null; then
  fail "show without query should fail"
else
  ok "show without query rejected"
fi

# Ambiguous show fails when 2+ match
T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null
python3 "$CKPT" save "$T" --title "ambiguous-one" > /dev/null
sleep 1
python3 "$CKPT" save "$T" --title "ambiguous-two" > /dev/null
if python3 "$CKPT" show "$T" "ambiguous" 2>/dev/null; then
  fail "ambiguous show should fail"
else
  ok "ambiguous show rejected"
fi

# ── 7. Latest/list when empty ────────────────────────────────────────────

echo ""
echo "7. Empty-checkpoint error paths"

T=$(make_project)
if python3 "$CKPT" latest "$T" 2>/dev/null; then
  fail "latest on empty should fail"
else
  ok "latest on empty rejected"
fi

LIST_EMPTY=$(python3 "$CKPT" list "$T" 2>&1)
assert_eq "$LIST_EMPTY" "" "list on empty project produces no output"

if python3 "$CKPT" show "$T" anything 2>/dev/null; then
  fail "show on empty should fail"
else
  ok "show on empty rejected"
fi

# ── 8. Backlog + exploration summary ─────────────────────────────────────

echo ""
echo "8. Backlog + exploration summary"

T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null
python3 "$BACKLOG" init "$T" > /dev/null
python3 "$BACKLOG" add "$T" "Rate-limit login endpoint" "detail" conductor 2 > /dev/null
python3 "$BACKLOG" add "$T" "Audit secrets" "detail2" worker 4 > /dev/null

OUT=$(python3 "$CKPT" save "$T")
assert_file_contains "$OUT" "Open\**: 2" "backlog open count shown"
assert_file_contains "$OUT" "Rate-limit login endpoint" "next-up item shown (highest priority)"
assert_file_contains "$OUT" "P2" "next-up priority shown"

# Exploration dimensions shown when in exploring phase
T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 2 > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "d" > /dev/null
python3 "$CONDUCTOR" sprint-end "$T" complete "done" '[]' false > /dev/null
# Now in exploring phase (max_directed=1 for 2 sprints)
python3 "$CONDUCTOR" explore-score "$T" security 7 > /dev/null

OUT=$(python3 "$CKPT" save "$T")
assert_file_contains "$OUT" "Exploration dimensions" "exploration section shown when exploring"
assert_file_contains "$OUT" "security.*7" "audited dimension score shown"
assert_file_contains "$OUT" "test_coverage.*not audited" "unaudited dimensions listed"

# ── 9. Git state ─────────────────────────────────────────────────────────

echo ""
echo "9. Git state reporting"

T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null
# Add an untracked file
echo "modified" > "$T/newfile.txt"

OUT=$(python3 "$CKPT" save "$T")
assert_file_contains "$OUT" "Current branch" "current branch reported"
assert_file_contains "$OUT" "init" "last commit reported"
assert_file_contains "$OUT" "Uncommitted changes" "uncommitted files reported"

# Non-git directory
T2=$(new_tmp)
OUT2=$(python3 "$CKPT" save "$T2")
assert_file_contains "$OUT2" "Not a git repo" "non-git project handled gracefully"

# ── 10. Slugify / filename safety ────────────────────────────────────────

echo ""
echo "10. Slugify + filename safety"

T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null

# Title with special chars — filename should stay safe
OUT=$(python3 "$CKPT" save "$T" --title 'weird/title with "quotes" and <brackets>!')
BASE=$(basename "$OUT")
# Filename should only contain safe chars
if echo "$BASE" | grep -qE '[/"<>!]'; then
  fail "filename contains unsafe chars: $BASE"
else
  ok "filename slugged to safe chars"
fi

# Title with only special chars → fallback to "checkpoint"
OUT2=$(python3 "$CKPT" save "$T" --title '!!!@@@###')
BASE2=$(basename "$OUT2")
assert_contains "$BASE2" "checkpoint" "all-special title falls back to 'checkpoint'"

# Title with unicode — survives, frontmatter escapes it
OUT3=$(python3 "$CKPT" save "$T" --title "中文 checkpoint")
assert_file_contains "$OUT3" "中文 checkpoint" "unicode title preserved in content"

# ── 11. Adversarial regression (Codex review findings) ──────────────────

echo ""
echo "11. Adversarial regression (Codex findings)"

# P1: `show` previously treated query as a glob, allowing path traversal.
T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null
python3 "$CKPT" save "$T" --title "legit" > /dev/null
# Create a file outside the checkpoints dir we could try to read
echo "SECRET" > "$T/.autonomous/secret.json"

# Path traversal via ../
if python3 "$CKPT" show "$T" "../secret.json" 2>/dev/null; then
  fail "show ../secret.json should be rejected"
else
  ok "show rejects path traversal via ../"
fi

# Glob metacharacters must be rejected (query is not a glob anymore)
if python3 "$CKPT" show "$T" "*" 2>/dev/null; then
  fail "show with * (glob) should be rejected"
else
  ok "show rejects * metacharacter"
fi

if python3 "$CKPT" show "$T" "?" 2>/dev/null; then
  fail "show with ? should be rejected"
else
  ok "show rejects ? metacharacter"
fi

if python3 "$CKPT" show "$T" "[abc]" 2>/dev/null; then
  fail "show with character class should be rejected"
else
  ok "show rejects character class"
fi

if python3 "$CKPT" show "$T" "dir/file" 2>/dev/null; then
  fail "show with / should be rejected"
else
  ok "show rejects path separator"
fi

# P1: Frontmatter injection via session_id/phase containing YAML-hostile chars
T=$(make_project)
mkdir -p "$T/.autonomous"
# conductor-state with colon, newline, and # in session_id → must not break YAML
cat > "$T/.autonomous/conductor-state.json" <<'EOF'
{"session_id": "malicious: injected\nkey: hijacked # comment", "phase": "[{broken", "mission": "ok", "sprints": [], "max_sprints": 5, "exploration": {}}
EOF
OUT=$(python3 "$CKPT" save "$T" --title "injection-test")
# The injected keys MUST NOT appear as top-level YAML keys
if grep -q "^key: hijacked" "$OUT"; then
  fail "YAML injection succeeded (new top-level key created)"
else
  ok "YAML frontmatter resists : + newline injection"
fi
# The weird phase value must be quoted as a string, not interpreted as a list
assert_file_contains "$OUT" 'phase: "\[{broken"' "hostile phase value is JSON-quoted"

# P1: read_json type safety — non-dict conductor-state.json doesn't crash
T=$(make_project)
mkdir -p "$T/.autonomous"
echo '["this","is","a","list","not","a","dict"]' > "$T/.autonomous/conductor-state.json"
OUT=$(python3 "$CKPT" save "$T" 2>&1) && RC=0 || RC=$?
assert_eq "$RC" "0" "non-dict state.json doesn't crash save"
assert_file_exists "$OUT" "checkpoint written despite bad state shape"

# sprints field as a dict (not list) — previous code iterated and crashed
T=$(make_project)
mkdir -p "$T/.autonomous"
cat > "$T/.autonomous/conductor-state.json" <<'EOF'
{"session_id":"s","mission":"m","phase":"directed","sprints":{"wrong":"shape"},"exploration":"also wrong"}
EOF
OUT=$(python3 "$CKPT" save "$T" 2>&1) && RC=0 || RC=$?
assert_eq "$RC" "0" "wrong-shape sprints doesn't crash save"

# P2: Same-second same-title saves don't silently overwrite
T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null
OUT1=$(python3 "$CKPT" save "$T" --title "same-name")
OUT2=$(python3 "$CKPT" save "$T" --title "same-name")
[ "$OUT1" != "$OUT2" ] && ok "same-second same-title saves produce different files" || fail "silent overwrite"
# Both files should exist
[ -f "$OUT1" ] && [ -f "$OUT2" ] && ok "both same-name checkpoints retained" || fail "one checkpoint lost"
# Second filename should have -1 suffix
BASE2=$(basename "$OUT2" .md)
assert_contains "$BASE2" "same-name-1" "collision resolved with numeric suffix"

# P2: list title extraction decodes JSON escapes
T=$(make_project)
python3 "$CONDUCTOR" init "$T" "m" 5 > /dev/null
python3 "$CKPT" save "$T" --title '中文 title with spaces' > /dev/null
LIST=$(python3 "$CKPT" list "$T")
# Title should display the actual unicode, not the \uXXXX escape
assert_contains "$LIST" "中文 title with spaces" "list shows unicode title verbatim (not JSON-escaped)"
# Shouldn't show raw escapes
if echo "$LIST" | grep -q '\\u4e2d'; then
  fail "list shows raw \\uXXXX escape (JSON decode failed)"
else
  ok "list did not leak \\uXXXX escape"
fi

# P2: Non-UTF8 checkpoint file doesn't crash latest/show
T=$(make_project)
mkdir -p "$T/.autonomous/checkpoints"
printf '\xff\xfe\x00\x00garbage' > "$T/.autonomous/checkpoints/20260419-000001-binary.md"
LATEST=$(python3 "$CKPT" latest "$T" 2>&1) && RC=0 || RC=$?
assert_eq "$RC" "0" "latest survives non-UTF8 file"
SHOWN=$(python3 "$CKPT" show "$T" "binary" 2>&1) && RC=0 || RC=$?
assert_eq "$RC" "0" "show survives non-UTF8 file"

# Malformed conductor-state.json (valid JSON, missing fields) doesn't crash
T=$(make_project)
mkdir -p "$T/.autonomous"
echo 'null' > "$T/.autonomous/conductor-state.json"
OUT=$(python3 "$CKPT" save "$T" 2>&1) && RC=0 || RC=$?
assert_eq "$RC" "0" "null top-level state doesn't crash"

print_results
