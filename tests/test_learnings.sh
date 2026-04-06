#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEARNINGS="$SCRIPT_DIR/../scripts/learnings.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_learnings.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Init + basic CRUD ─────────────────────────────────────────────────

echo ""
echo "1. Init + basic CRUD"

T=$(new_tmp)
RESULT=$(bash "$LEARNINGS" init "$T")
assert_eq "$RESULT" "initialized" "init creates learnings"
assert_file_exists "$T/.autonomous/learnings.json" "learnings file created"

# Idempotent init
RESULT2=$(bash "$LEARNINGS" init "$T")
assert_eq "$RESULT2" "exists" "init is idempotent"

# Verify JSON structure
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/learnings.json'))
assert d['version'] == 1
assert d['items'] == []
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "init creates valid JSON with version"

# Add basic item
ID=$(bash "$LEARNINGS" add "$T" success "Tests catch regressions early")
assert_contains "$ID" "ln-" "add returns item ID"

# Add with all args
ID2=$(bash "$LEARNINGS" add "$T" failure "Deploy without tests causes rollbacks" 8 "deploy,ci" "conductor" "3")
assert_contains "$ID2" "ln-" "add with all args returns ID"

# Verify item fields via list
ITEMS=$(bash "$LEARNINGS" list "$T")
assert_contains "$ITEMS" '"type": "failure"' "item has correct type"
assert_contains "$ITEMS" '"content": "Deploy without tests causes rollbacks"' "item has correct content"
assert_contains "$ITEMS" '"confidence": 8' "item has correct confidence"
assert_contains "$ITEMS" '"source": "conductor"' "item has correct source"
assert_contains "$ITEMS" '"sprint_ref": "3"' "item has correct sprint_ref"
assert_contains "$ITEMS" '"archived": false' "item not archived by default"

# Update confidence
URESULT=$(bash "$LEARNINGS" update "$T" "$ID" confidence 9)
assert_eq "$URESULT" "ok" "update returns ok"

# Stats
STATS=$(bash "$LEARNINGS" stats "$T")
assert_contains "$STATS" "total: 2" "stats shows total"
assert_contains "$STATS" "success: 1" "stats shows success count"
assert_contains "$STATS" "failure: 1" "stats shows failure count"

# ── 2. Type validation ──────────────────────────────────────────────────

echo ""
echo "2. Type validation"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null

# All 4 types work
ID_S=$(bash "$LEARNINGS" add "$T" success "Success learning")
assert_contains "$ID_S" "ln-" "success type accepted"
ID_F=$(bash "$LEARNINGS" add "$T" failure "Failure learning")
assert_contains "$ID_F" "ln-" "failure type accepted"
ID_Q=$(bash "$LEARNINGS" add "$T" quirk "Quirk learning")
assert_contains "$ID_Q" "ln-" "quirk type accepted"
ID_P=$(bash "$LEARNINGS" add "$T" pattern "Pattern learning")
assert_contains "$ID_P" "ln-" "pattern type accepted"

# Invalid type rejected
ERR=$(bash "$LEARNINGS" add "$T" badtype "content" 2>&1 || true)
assert_contains "$ERR" "Invalid type" "invalid type rejected"

# Type present in list output
LIST=$(bash "$LEARNINGS" list "$T")
assert_contains "$LIST" '"type": "quirk"' "type field present in list output"

# ── 3. Confidence validation ────────────────────────────────────────────

echo ""
echo "3. Confidence validation"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null

# Default confidence is 5
bash "$LEARNINGS" add "$T" success "Default conf" > /dev/null
DEF_CONF=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(d['items'][0]['confidence'])")
assert_eq "$DEF_CONF" "5" "default confidence is 5"

# Valid range boundaries
bash "$LEARNINGS" add "$T" success "Conf 1" 1 > /dev/null
bash "$LEARNINGS" add "$T" success "Conf 10" 10 > /dev/null
CONFS=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(' '.join(str(i['confidence']) for i in d['items']))")
assert_contains "$CONFS" "1" "confidence 1 accepted"
assert_contains "$CONFS" "10" "confidence 10 accepted"

# Invalid confidence rejected
ERR=$(bash "$LEARNINGS" add "$T" success "Bad" 0 2>&1 || true)
assert_contains "$ERR" "Invalid confidence" "confidence 0 rejected"
ERR=$(bash "$LEARNINGS" add "$T" success "Bad" 11 2>&1 || true)
assert_contains "$ERR" "Invalid confidence" "confidence 11 rejected"

# Confidence in stats
STATS=$(bash "$LEARNINGS" stats "$T")
assert_contains "$STATS" "avg_confidence:" "confidence shown in stats"

# ── 4. Tags ─────────────────────────────────────────────────────────────

echo ""
echo "4. Tags"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null

# Comma-separated tags parsed
bash "$LEARNINGS" add "$T" success "Tagged learning" 5 "testing,ci,workflow" > /dev/null
TAGS=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(json.dumps(d['items'][0]['tags']))")
assert_contains "$TAGS" '"testing"' "first tag parsed"
assert_contains "$TAGS" '"ci"' "second tag parsed"
assert_contains "$TAGS" '"workflow"' "third tag parsed"

# Empty tags ok
bash "$LEARNINGS" add "$T" failure "No tags" 5 "" > /dev/null
EMPTY_TAGS=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(d['items'][1]['tags'])")
assert_eq "$EMPTY_TAGS" "[]" "empty tags produces empty array"

# Tags in search
SEARCH=$(bash "$LEARNINGS" search "$T" "testing")
assert_contains "$SEARCH" "Tagged learning" "tags searchable"

# Tags in summary
SUMMARY=$(bash "$LEARNINGS" summary "$T")
assert_contains "$SUMMARY" "tags:testing,ci,workflow" "tags shown in summary"

# ── 5. Search ───────────────────────────────────────────────────────────

echo ""
echo "5. Search"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null
bash "$LEARNINGS" add "$T" success "Running tests immediately catches bugs" 8 "testing" > /dev/null
bash "$LEARNINGS" add "$T" failure "Skipping linting causes style drift" 6 "linting,quality" > /dev/null
bash "$LEARNINGS" add "$T" quirk "macOS sed behaves differently" 5 "macos,shell" > /dev/null
bash "$LEARNINGS" add "$T" pattern "Always run shellcheck before commit" 7 "shell,ci" > /dev/null

# Content match
RESULT=$(bash "$LEARNINGS" search "$T" "tests")
assert_contains "$RESULT" "Running tests" "content search finds match"

# Tag match
RESULT=$(bash "$LEARNINGS" search "$T" "linting")
assert_contains "$RESULT" "Skipping linting" "tag search finds match"

# Case insensitive
RESULT=$(bash "$LEARNINGS" search "$T" "TESTS")
assert_contains "$RESULT" "Running tests" "search is case insensitive"

# No results
RESULT=$(bash "$LEARNINGS" search "$T" "nonexistent")
assert_eq "$RESULT" "" "search returns empty for no matches"

# Multiple matches
RESULT=$(bash "$LEARNINGS" search "$T" "shell")
assert_contains "$RESULT" "macOS sed" "search finds first multi-match"
assert_contains "$RESULT" "shellcheck" "search finds second multi-match"

# Partial match
RESULT=$(bash "$LEARNINGS" search "$T" "lint")
assert_contains "$RESULT" "linting" "partial content match works"

# Tag partial match
RESULT=$(bash "$LEARNINGS" search "$T" "mac")
assert_contains "$RESULT" "macOS sed" "partial tag match works"

# Missing query
ERR=$(bash "$LEARNINGS" search "$T" 2>&1 || true)
assert_contains "$ERR" "ERROR" "search without query errors"

# ── 6. Summary format ───────────────────────────────────────────────────

echo ""
echo "6. Summary format"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null
bash "$LEARNINGS" add "$T" success "Success item" 8 "a" > /dev/null
bash "$LEARNINGS" add "$T" failure "Failure item" 7 "b" > /dev/null
bash "$LEARNINGS" add "$T" quirk "Quirk item" 5 "" > /dev/null
bash "$LEARNINGS" add "$T" pattern "Pattern item" 9 "c" > /dev/null

SUMMARY=$(bash "$LEARNINGS" summary "$T")

# Header line
assert_contains "$SUMMARY" "[LEARNINGS: 4 items]" "summary has header line"

# Type symbols
assert_contains "$SUMMARY" "✓ Success item" "success symbol ✓"
assert_contains "$SUMMARY" "✗ Failure item" "failure symbol ✗"
assert_contains "$SUMMARY" "? Quirk item" "quirk symbol ?"
assert_contains "$SUMMARY" "⟳ Pattern item" "pattern symbol ⟳"

# Confidence shown
assert_contains "$SUMMARY" "confidence:8" "confidence shown in summary"

# Tags shown
assert_contains "$SUMMARY" "tags:a" "tags shown in summary items"

# Top-20 limit
T2=$(new_tmp)
bash "$LEARNINGS" init "$T2" > /dev/null
for i in $(seq 1 25); do
  bash "$LEARNINGS" add "$T2" success "Learning $i" "$((i % 10 + 1))" "" > /dev/null
done
SUMMARY2=$(bash "$LEARNINGS" summary "$T2")
LINE_COUNT=$(echo "$SUMMARY2" | wc -l | tr -d ' ')
# 1 header + up to 20 items = max 21 lines
assert_le "$LINE_COUNT" "21" "summary limited to top 20 items"

# Empty summary
T3=$(new_tmp)
bash "$LEARNINGS" init "$T3" > /dev/null
EMPTY_SUMMARY=$(bash "$LEARNINGS" summary "$T3")
assert_contains "$EMPTY_SUMMARY" "[LEARNINGS: 0 items]" "empty summary shows zero count"

# ── 7. List formats ─────────────────────────────────────────────────────

echo ""
echo "7. List formats"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null
bash "$LEARNINGS" add "$T" success "Success one" 8 "a" > /dev/null
bash "$LEARNINGS" add "$T" failure "Failure one" 6 "b" > /dev/null
bash "$LEARNINGS" add "$T" success "Success two" 9 "" > /dev/null

# Full JSON
FULL=$(bash "$LEARNINGS" list "$T")
assert_contains "$FULL" '"content": "Success one"' "full list has JSON content"
assert_contains "$FULL" '"confidence": 8' "full list has confidence"

# Compact one-liners
COMPACT=$(bash "$LEARNINGS" list "$T" all compact)
assert_contains "$COMPACT" "✓ Success two (confidence:9)" "compact shows items"
assert_contains "$COMPACT" "✗ Failure one (confidence:6" "compact shows failure"

# Type filter
SUCCESSES=$(bash "$LEARNINGS" list "$T" success compact)
assert_contains "$SUCCESSES" "Success one" "type filter shows matching items"
assert_not_contains "$SUCCESSES" "Failure one" "type filter excludes non-matching"

# All filter
ALL=$(bash "$LEARNINGS" list "$T" all)
assert_contains "$ALL" "Success one" "all filter shows everything"
assert_contains "$ALL" "Failure one" "all filter includes all types"

# Format shorthand (format as first filter arg)
COMPACT2=$(bash "$LEARNINGS" list "$T" compact)
assert_contains "$COMPACT2" "✓" "format shorthand works"

# Archived items excluded
ID=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(d['items'][0]['id'])")
bash "$LEARNINGS" update "$T" "$ID" archived true > /dev/null
AFTER=$(bash "$LEARNINGS" list "$T" all compact)
assert_not_contains "$AFTER" "Success one" "archived items excluded from list"

# ── 8. Prune ────────────────────────────────────────────────────────────

echo ""
echo "8. Prune"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null
bash "$LEARNINGS" add "$T" success "High conf" 8 "" > /dev/null
bash "$LEARNINGS" add "$T" failure "Low conf" 2 "" > /dev/null
bash "$LEARNINGS" add "$T" quirk "Medium conf" 5 "" > /dev/null
bash "$LEARNINGS" add "$T" pattern "Very low conf" 1 "" > /dev/null

# Default threshold (3) archives items below 3
bash "$LEARNINGS" prune "$T" > /dev/null

# Check: confidence 1 and 2 should be archived
ARCHIVED_COUNT=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(sum(1 for i in d['items'] if i.get('archived')))")
assert_eq "$ARCHIVED_COUNT" "2" "prune archives below threshold"

ACTIVE_COUNT=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(sum(1 for i in d['items'] if not i.get('archived')))")
assert_eq "$ACTIVE_COUNT" "2" "prune keeps above threshold"

# Custom threshold
T2=$(new_tmp)
bash "$LEARNINGS" init "$T2" > /dev/null
bash "$LEARNINGS" add "$T2" success "Conf 6" 6 "" > /dev/null
bash "$LEARNINGS" add "$T2" failure "Conf 4" 4 "" > /dev/null
bash "$LEARNINGS" add "$T2" quirk "Conf 7" 7 "" > /dev/null

bash "$LEARNINGS" prune "$T2" 5 > /dev/null
ARCHIVED=$(python3 -c "import json; d=json.load(open('$T2/.autonomous/learnings.json')); print(sum(1 for i in d['items'] if i.get('archived')))")
assert_eq "$ARCHIVED" "1" "custom threshold prunes correctly"

# Already archived items skipped
bash "$LEARNINGS" prune "$T2" 5 > /dev/null
STILL_ARCHIVED=$(python3 -c "import json; d=json.load(open('$T2/.autonomous/learnings.json')); print(sum(1 for i in d['items'] if i.get('archived')))")
assert_eq "$STILL_ARCHIVED" "1" "already archived items not double-pruned"

# Prune on empty
T3=$(new_tmp)
bash "$LEARNINGS" init "$T3" > /dev/null
PRUNE_EMPTY=$(bash "$LEARNINGS" prune "$T3")
assert_contains "$PRUNE_EMPTY" "pruned:" "prune on empty succeeds"

# ── 9. Overflow cap ─────────────────────────────────────────────────────

echo ""
echo "9. Overflow cap"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null

# Add 100 items with varying confidence
for i in $(seq 1 100); do
  CONF=$(( (i % 10) + 1 ))
  bash "$LEARNINGS" add "$T" success "Learning $i" "$CONF" "" > /dev/null
done

ACTIVE=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(sum(1 for i in d['items'] if not i.get('archived')))")
assert_eq "$ACTIVE" "100" "100 items added successfully"

# Add one more — should trigger overflow
OVERFLOW_ERR=$(bash "$LEARNINGS" add "$T" success "Learning 101" 10 "" 2>&1 >/dev/null || true)
assert_contains "$OVERFLOW_ERR" "WARNING" "overflow warns on stderr"

FINAL_ACTIVE=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(sum(1 for i in d['items'] if not i.get('archived')))")
assert_eq "$FINAL_ACTIVE" "100" "active count stays at 100 after overflow"

# The new high-confidence item should exist
HAS_NEW=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print('yes' if any(i['content']=='Learning 101' and not i.get('archived') for i in d['items']) else 'no')")
assert_eq "$HAS_NEW" "yes" "new high-confidence item survives overflow"

# ── 10. Concurrency ─────────────────────────────────────────────────────

echo ""
echo "10. Concurrency"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null

# Simultaneous adds via background processes
bash "$LEARNINGS" add "$T" success "Concurrent A" 5 "" > /dev/null &
PID1=$!
bash "$LEARNINGS" add "$T" failure "Concurrent B" 5 "" > /dev/null &
PID2=$!
wait $PID1 $PID2 2>/dev/null || true

TOTAL=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(len(d['items']))")
assert_ge "$TOTAL" "1" "concurrent adds produce at least 1 item"

# Stale lock recovery
T2=$(new_tmp)
bash "$LEARNINGS" init "$T2" > /dev/null
mkdir -p "$T2/.autonomous/learnings.lock"
echo "99999999" > "$T2/.autonomous/learnings.lock/pid"  # Dead PID
ID=$(bash "$LEARNINGS" add "$T2" success "After stale lock" 5 "" 2>/dev/null)
assert_contains "$ID" "ln-" "stale lock recovered, add succeeds"

# Lock dir cleaned up after operation
assert_eq "$([ -d "$T2/.autonomous/learnings.lock" ] && echo "exists" || echo "clean")" "clean" "lock cleaned up after operation"

# No tmp files left
TMPS=$(find "$T2/.autonomous" -name "*.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$TMPS" "0" "no tmp files left after operations"

# ── 11. Edge cases ──────────────────────────────────────────────────────

echo ""
echo "11. Edge cases"

# Empty project
T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null
EMPTY_SUMMARY=$(bash "$LEARNINGS" summary "$T")
assert_contains "$EMPTY_SUMMARY" "[LEARNINGS: 0 items]" "empty project summary works"

# Special characters in content
bash "$LEARNINGS" add "$T" success 'Fix "quotes" & <angles> work' 5 "" > /dev/null
SPECIAL=$(bash "$LEARNINGS" list "$T" all compact)
assert_contains "$SPECIAL" 'Fix "quotes"' "special characters preserved in content"

# Very long content
LONG_CONTENT=$(python3 -c "print('A' * 500)")
bash "$LEARNINGS" add "$T" quirk "$LONG_CONTENT" 5 "" > /dev/null
LONG_LEN=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(max(len(i['content']) for i in d['items']))")
assert_ge "$LONG_LEN" "500" "long content preserved"

# Corrupt JSON recovery
T2=$(new_tmp)
mkdir -p "$T2/.autonomous"
echo "not json{{{" > "$T2/.autonomous/learnings.json"
RECOVERED=$(bash "$LEARNINGS" summary "$T2")
assert_contains "$RECOVERED" "[LEARNINGS: 0 items]" "corrupt JSON recovers gracefully"

# ── 12. Help flags ──────────────────────────────────────────────────────

echo ""
echo "12. Help flags"

HELP1=$(bash "$LEARNINGS" --help 2>&1)
assert_contains "$HELP1" "Usage:" "--help shows usage"

HELP2=$(bash "$LEARNINGS" -h 2>&1)
assert_contains "$HELP2" "Usage:" "-h shows usage"

HELP3=$(bash "$LEARNINGS" help 2>&1)
assert_contains "$HELP3" "Usage:" "help shows usage"

# Unknown command
ERR=$(bash "$LEARNINGS" badcmd "$T" 2>&1 || true)
assert_contains "$ERR" "Unknown command" "unknown command rejected"

# ── 13. Update all fields ──────────────────────────────────────────────

echo ""
echo "13. Update all fields"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null
ID=$(bash "$LEARNINGS" add "$T" success "Update test" 5 "initial")

# Update confidence
bash "$LEARNINGS" update "$T" "$ID" confidence 10 > /dev/null
UPDATED=$(bash "$LEARNINGS" list "$T")
assert_contains "$UPDATED" '"confidence": 10' "update confidence works"

# Update tags
bash "$LEARNINGS" update "$T" "$ID" tags "new,tags,here" > /dev/null
UPDATED=$(bash "$LEARNINGS" list "$T")
assert_contains "$UPDATED" '"new"' "update tags works"

# Update type
bash "$LEARNINGS" update "$T" "$ID" type pattern > /dev/null
UPDATED=$(bash "$LEARNINGS" list "$T")
assert_contains "$UPDATED" '"type": "pattern"' "update type works"

# Update archived
bash "$LEARNINGS" update "$T" "$ID" archived true > /dev/null
ARCHIVED=$(python3 -c "import json; d=json.load(open('$T/.autonomous/learnings.json')); print(d['items'][0]['archived'])")
assert_eq "$ARCHIVED" "True" "update archived works"

# Nonexistent ID
ERR=$(bash "$LEARNINGS" update "$T" "ln-nonexistent" confidence 5 2>&1 || true)
assert_contains "$ERR" "ERROR" "nonexistent ID rejected for update"

# Invalid field
ERR=$(bash "$LEARNINGS" update "$T" "$ID" badfield value 2>&1 || true)
assert_contains "$ERR" "Invalid field" "invalid field rejected"

# ── 14. Input validation ───────────────────────────────────────────────

echo ""
echo "14. Input validation"

T=$(new_tmp)
bash "$LEARNINGS" init "$T" > /dev/null

# Empty type
ERR=$(bash "$LEARNINGS" add "$T" "" "content" 2>&1 || true)
assert_contains "$ERR" "ERROR" "empty type rejected"

# Empty content
ERR=$(bash "$LEARNINGS" add "$T" success "" 2>&1 || true)
assert_contains "$ERR" "ERROR" "empty content rejected"

# Invalid source
ERR=$(bash "$LEARNINGS" add "$T" success "test" 5 "" "badSource" 2>&1 || true)
assert_contains "$ERR" "Invalid source" "invalid source rejected"

# Invalid prune threshold
ERR=$(bash "$LEARNINGS" prune "$T" 0 2>&1 || true)
assert_contains "$ERR" "ERROR" "prune threshold 0 rejected"

ERR=$(bash "$LEARNINGS" prune "$T" 11 2>&1 || true)
assert_contains "$ERR" "ERROR" "prune threshold 11 rejected"

# ── Done ─────────────────────────────────────────────────────────────────

print_results
