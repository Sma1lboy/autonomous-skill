#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERCEPT="$SCRIPT_DIR/../scripts/intercept.py"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_intercept.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Empty queue + help ─────────────────────────────────────────────────

echo ""
echo "1. Empty queue + help"

T=$(new_tmp)
STATUS=$(python3 "$INTERCEPT" status "$T")
assert_eq "$STATUS" "none" "empty queue reports 'none'"

LIST=$(python3 "$INTERCEPT" list "$T" pending)
assert_eq "$LIST" "[]" "empty queue lists empty array"

HELP=$(python3 "$INTERCEPT" --help 2>&1)
assert_contains "$HELP" "Usage: intercept.py" "--help shows usage"
assert_contains "$HELP" "add <project>" "--help documents add"
assert_contains "$HELP" "pause <project>" "--help documents pause"
assert_contains "$HELP" "consume <project>" "--help documents consume"

# ── 2. Add directive + pause ──────────────────────────────────────────────

echo ""
echo "2. Add directive + pause"

T=$(new_tmp)
ID1=$(python3 "$INTERCEPT" add "$T" "focus on auth bug")
assert_contains "$ID1" "int-" "add directive returns ID with prefix"
assert_file_exists "$T/.autonomous/intercept.json" "queue file created on first add"

ID2=$(python3 "$INTERCEPT" pause "$T" "need to check design")
assert_contains "$ID2" "int-" "pause returns ID"

STATUS=$(python3 "$INTERCEPT" status "$T")
assert_contains "$STATUS" "1 directive" "status counts directive"
assert_contains "$STATUS" "1 pause" "status counts pause"

LIST=$(python3 "$INTERCEPT" list "$T" pending)
assert_contains "$LIST" "focus on auth bug" "pending list includes directive text"
assert_contains "$LIST" "need to check design" "pending list includes pause note"
assert_contains "$LIST" '"type": "directive"' "item type is directive"
assert_contains "$LIST" '"type": "pause"' "pause type preserved"

# Pause with no note is allowed
T2=$(new_tmp)
ID_EMPTY=$(python3 "$INTERCEPT" pause "$T2")
assert_contains "$ID_EMPTY" "int-" "pause allowed with no note"

# Add with empty string fails (whitespace-only rejected)
if python3 "$INTERCEPT" add "$T" "   " 2>/dev/null; then
  fail "add with whitespace-only directive should fail"
else
  ok "add with whitespace-only directive rejected"
fi

# ── 3. Consume flow ───────────────────────────────────────────────────────

echo ""
echo "3. Consume flow"

T=$(new_tmp)
python3 "$INTERCEPT" add "$T" "first directive" > /dev/null
python3 "$INTERCEPT" add "$T" "second directive" > /dev/null
python3 "$INTERCEPT" pause "$T" "pause note" > /dev/null

CONSUMED=$(python3 "$INTERCEPT" consume "$T" 5)
assert_contains "$CONSUMED" "first directive" "consume emits first item"
assert_contains "$CONSUMED" "second directive" "consume emits second item"
assert_contains "$CONSUMED" "pause note" "consume emits pause item"
assert_contains "$CONSUMED" '"consumed_in_sprint": 5' "sprint-num recorded"
assert_contains "$CONSUMED" '"status": "consumed"' "items marked consumed in output"

STATUS=$(python3 "$INTERCEPT" status "$T")
assert_eq "$STATUS" "none" "status none after consume"

# Second consume returns empty (no double-fire)
SECOND=$(python3 "$INTERCEPT" consume "$T" 6)
assert_eq "$SECOND" "[]" "second consume returns empty (no double-fire)"

# Persisted as consumed
LIST_ALL=$(python3 "$INTERCEPT" list "$T" all)
CONSUMED_COUNT=$(echo "$LIST_ALL" | grep -c '"status": "consumed"' || echo 0)
assert_eq "$CONSUMED_COUNT" "3" "all three items persisted as consumed"

# Consume with no sprint-num argument
T=$(new_tmp)
python3 "$INTERCEPT" add "$T" "solo" > /dev/null
CONSUMED=$(python3 "$INTERCEPT" consume "$T")
assert_contains "$CONSUMED" '"consumed_in_sprint": null' "missing sprint-num stored as null"

# Consume with invalid sprint-num fails
T=$(new_tmp)
python3 "$INTERCEPT" add "$T" "solo" > /dev/null
if python3 "$INTERCEPT" consume "$T" "not-a-number" 2>/dev/null; then
  fail "consume with non-integer sprint should fail"
else
  ok "consume rejects non-integer sprint-num"
fi

# ── 4. Clear flow ─────────────────────────────────────────────────────────

echo ""
echo "4. Clear flow"

T=$(new_tmp)
python3 "$INTERCEPT" add "$T" "to be cleared" > /dev/null
python3 "$INTERCEPT" add "$T" "also cleared" > /dev/null
CLEARED=$(python3 "$INTERCEPT" clear "$T")
assert_contains "$CLEARED" "cleared: 2" "clear reports count"

STATUS=$(python3 "$INTERCEPT" status "$T")
assert_eq "$STATUS" "none" "status none after clear"

# Cleared items don't fire on consume
CONSUMED=$(python3 "$INTERCEPT" consume "$T" 1)
assert_eq "$CONSUMED" "[]" "cleared items not consumed"

# Cleared items visible under scope=cleared
LIST_CLEARED=$(python3 "$INTERCEPT" list "$T" cleared)
assert_contains "$LIST_CLEARED" "to be cleared" "cleared list shows items"

# ── 5. Session scoping ────────────────────────────────────────────────────

echo ""
echo "5. Session scoping"

T=$(new_tmp)
mkdir -p "$T/.autonomous"

# No conductor state — item has session_id=null, gets consumed
python3 "$INTERCEPT" add "$T" "pre-session item" > /dev/null
LIST=$(python3 "$INTERCEPT" list "$T" pending)
assert_contains "$LIST" '"session_id": null' "pre-session item has null session"

# Write conductor state with session A
cat > "$T/.autonomous/conductor-state.json" <<EOF
{"session_id": "conductor-sessionA", "phase": "directed"}
EOF

# null-session item still consumable (unbound items pick up in first session)
CONSUMED=$(python3 "$INTERCEPT" consume "$T" 1)
assert_contains "$CONSUMED" "pre-session item" "null-session items consumed by current session"

# Add item during session A — tagged with session A
python3 "$INTERCEPT" add "$T" "session-A item" > /dev/null
LIST=$(python3 "$INTERCEPT" list "$T" pending)
assert_contains "$LIST" '"session_id": "conductor-sessionA"' "new item tagged with current session"

# Switch to session B — session A's items no longer in scope
cat > "$T/.autonomous/conductor-state.json" <<EOF
{"session_id": "conductor-sessionB", "phase": "directed"}
EOF

STATUS=$(python3 "$INTERCEPT" status "$T")
assert_eq "$STATUS" "none" "session B ignores session A's items"

CONSUMED=$(python3 "$INTERCEPT" consume "$T" 1)
assert_eq "$CONSUMED" "[]" "session B consume does not drain session A items"

# Session A items still visible under list-all
LIST=$(python3 "$INTERCEPT" list "$T" all)
assert_contains "$LIST" "session-A item" "session A items still visible via list-all"

# ── 6. Concurrent writes ──────────────────────────────────────────────────

echo ""
echo "6. Concurrent writes"

T=$(new_tmp)
(python3 "$INTERCEPT" add "$T" "concurrent 1" > /dev/null) &
(python3 "$INTERCEPT" add "$T" "concurrent 2" > /dev/null) &
(python3 "$INTERCEPT" add "$T" "concurrent 3" > /dev/null) &
wait

COUNT=$(python3 -c "import json; d=json.load(open('$T/.autonomous/intercept.json')); print(len(d['items']))")
assert_eq "$COUNT" "3" "all 3 concurrent writes succeeded"

# No stale lock dir
[ ! -d "$T/.autonomous/intercept.lock" ] && ok "no stale lock dir after concurrent writes" || fail "stale lock dir"

# ── 7. Malformed state + corruption resilience ────────────────────────────

echo ""
echo "7. Malformed state + corruption"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "not json at all" > "$T/.autonomous/intercept.json"
STATUS=$(python3 "$INTERCEPT" status "$T")
assert_eq "$STATUS" "none" "malformed queue treated as empty"

# Add still works after corruption (overwrites bad file)
ID=$(python3 "$INTERCEPT" add "$T" "after corruption")
assert_contains "$ID" "int-" "add recovers after corrupted queue"

# Malformed conductor state treated as no session
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "{invalid" > "$T/.autonomous/conductor-state.json"
python3 "$INTERCEPT" add "$T" "resilient add" > /dev/null
LIST=$(python3 "$INTERCEPT" list "$T" pending)
assert_contains "$LIST" '"session_id": null' "malformed conductor state falls back to null session"

# ── 8. Input validation ───────────────────────────────────────────────────

echo ""
echo "8. Input validation"

T=$(new_tmp)
if python3 "$INTERCEPT" add "$T" 2>/dev/null; then
  fail "add without directive should fail"
else
  ok "add without directive rejected"
fi

if python3 "$INTERCEPT" list "$T" invalid-scope 2>/dev/null; then
  fail "list with invalid scope should fail"
else
  ok "list rejects invalid scope"
fi

if python3 "$INTERCEPT" unknowncmd "$T" 2>/dev/null; then
  fail "unknown command should fail"
else
  ok "unknown command rejected"
fi

# Control characters stripped from directive
T=$(new_tmp)
printf -v EVIL 'clean\x01injected'
python3 "$INTERCEPT" add "$T" "$EVIL" > /dev/null
LIST=$(python3 "$INTERCEPT" list "$T" pending)
# should contain "cleaninjected" (control char removed) but NOT the raw ctrl byte
assert_contains "$LIST" "cleaninjected" "control characters stripped from directive"

# Long directive truncated (MAX_DIRECTIVE_LEN = 2000)
T=$(new_tmp)
LONG=$(python3 -c "print('x' * 3000)")
python3 "$INTERCEPT" add "$T" "$LONG" > /dev/null
STORED_LEN=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/intercept.json'))
print(len(d['items'][0]['directive']))
")
assert_eq "$STORED_LEN" "2000" "long directive truncated to MAX_DIRECTIVE_LEN"

# ── 9. status formatting ──────────────────────────────────────────────────

echo ""
echo "9. Status formatting"

T=$(new_tmp)
python3 "$INTERCEPT" add "$T" "a" > /dev/null
STATUS=$(python3 "$INTERCEPT" status "$T")
assert_eq "$STATUS" "1 directive" "1 directive, no pause"

python3 "$INTERCEPT" pause "$T" > /dev/null
STATUS=$(python3 "$INTERCEPT" status "$T")
assert_eq "$STATUS" "1 directive + 1 pause" "1 each with both types"

python3 "$INTERCEPT" add "$T" "b" > /dev/null
python3 "$INTERCEPT" pause "$T" > /dev/null
STATUS=$(python3 "$INTERCEPT" status "$T")
assert_eq "$STATUS" "2 directive + 2 pause" "plural counts"

print_results
