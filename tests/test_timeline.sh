#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMELINE="$SCRIPT_DIR/../scripts/timeline.py"
CONDUCTOR="$SCRIPT_DIR/../scripts/conductor-state.py"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_timeline.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Empty file + help ──────────────────────────────────────────────────

echo ""
echo "1. Empty file + help"

T=$(new_tmp)
TAIL=$(python3 "$TIMELINE" tail "$T")
assert_eq "$TAIL" "" "tail of non-existent timeline is empty"

LIST=$(python3 "$TIMELINE" list "$T")
assert_eq "$LIST" "" "list of non-existent timeline is empty"

SESSIONS=$(python3 "$TIMELINE" sessions "$T")
assert_eq "$SESSIONS" "" "sessions on empty timeline is empty"

HELP=$(python3 "$TIMELINE" --help 2>&1)
assert_contains "$HELP" "Usage: timeline.py" "--help shows usage"
assert_contains "$HELP" "emit <project>" "--help documents emit"
assert_contains "$HELP" "sessions" "--help documents sessions"

# ── 2. Emit basic event ───────────────────────────────────────────────────

echo ""
echo "2. Emit basic event"

T=$(new_tmp)
RESULT=$(python3 "$TIMELINE" emit "$T" session-start mission='"build auth"' max_sprints=5)
assert_eq "$RESULT" "ok" "emit returns ok"
assert_file_exists "$T/.autonomous/timeline.jsonl" "timeline file created"

# Read back
LINE=$(cat "$T/.autonomous/timeline.jsonl")
assert_contains "$LINE" '"event":"session-start"' "event type recorded"
assert_contains "$LINE" '"mission":"build auth"' "string field preserved"
assert_contains "$LINE" '"max_sprints":5' "integer field preserved as int"
assert_contains "$LINE" '"ts":' "timestamp present"
assert_contains "$LINE" '"session_id":' "session_id field present"

# ── 3. Append-only behavior ───────────────────────────────────────────────

echo ""
echo "3. Append-only behavior"

T=$(new_tmp)
python3 "$TIMELINE" emit "$T" session-start mission='"m1"' > /dev/null
python3 "$TIMELINE" emit "$T" sprint-start sprint=1 direction='"d1"' > /dev/null
python3 "$TIMELINE" emit "$T" sprint-end sprint=1 status='"complete"' > /dev/null

LINES=$(wc -l < "$T/.autonomous/timeline.jsonl" | tr -d ' ')
assert_eq "$LINES" "3" "three writes produce three lines"

TAIL=$(python3 "$TIMELINE" tail "$T")
LINE_COUNT=$(echo "$TAIL" | wc -l | tr -d ' ')
assert_eq "$LINE_COUNT" "3" "tail returns all 3 events"

# ── 4. Tail with N ────────────────────────────────────────────────────────

echo ""
echo "4. Tail with N"

T=$(new_tmp)
for i in 1 2 3 4 5; do
  python3 "$TIMELINE" emit "$T" sprint-start sprint="$i" direction='"x"' > /dev/null
done

TAIL2=$(python3 "$TIMELINE" tail "$T" 2)
assert_contains "$TAIL2" '"sprint":4' "tail 2 includes second-to-last"
assert_contains "$TAIL2" '"sprint":5' "tail 2 includes last"
assert_not_contains "$TAIL2" '"sprint":1' "tail 2 excludes first"

TAIL_DEFAULT=$(python3 "$TIMELINE" tail "$T")
LINE_COUNT=$(echo "$TAIL_DEFAULT" | wc -l | tr -d ' ')
assert_eq "$LINE_COUNT" "5" "default tail returns all (default=20, 5 events)"

# ── 5. List with filters ──────────────────────────────────────────────────

echo ""
echo "5. List with filters"

T=$(new_tmp)
# Two sessions worth of events
mkdir -p "$T/.autonomous"
cat > "$T/.autonomous/conductor-state.json" <<'EOF'
{"session_id": "session-A"}
EOF
python3 "$TIMELINE" emit "$T" session-start mission='"a"' > /dev/null
python3 "$TIMELINE" emit "$T" sprint-start sprint=1 direction='"x"' > /dev/null
python3 "$TIMELINE" emit "$T" sprint-end sprint=1 status='"complete"' > /dev/null

cat > "$T/.autonomous/conductor-state.json" <<'EOF'
{"session_id": "session-B"}
EOF
python3 "$TIMELINE" emit "$T" session-start mission='"b"' > /dev/null
python3 "$TIMELINE" emit "$T" sprint-start sprint=1 direction='"y"' > /dev/null

# Filter by session
LIST_A=$(python3 "$TIMELINE" list "$T" --session session-A)
LINE_COUNT=$(echo "$LIST_A" | wc -l | tr -d ' ')
assert_eq "$LINE_COUNT" "3" "session-A filter returns 3 events"
assert_contains "$LIST_A" '"session_id":"session-A"' "session-A events present"
assert_not_contains "$LIST_A" '"session_id":"session-B"' "session-B events excluded"

# Filter by event
LIST_START=$(python3 "$TIMELINE" list "$T" --event sprint-start)
LINE_COUNT=$(echo "$LIST_START" | wc -l | tr -d ' ')
assert_eq "$LINE_COUNT" "2" "sprint-start filter returns 2 events (one per session)"

# Combined filter
LIST_COMBO=$(python3 "$TIMELINE" list "$T" --session session-A --event sprint-end)
LINE_COUNT=$(echo "$LIST_COMBO" | wc -l | tr -d ' ')
assert_eq "$LINE_COUNT" "1" "session+event combined filter"
assert_contains "$LIST_COMBO" '"status":"complete"' "correct event returned"

# Sessions command
SESSIONS=$(python3 "$TIMELINE" sessions "$T")
assert_contains "$SESSIONS" "session-A" "sessions includes A"
assert_contains "$SESSIONS" "session-B" "sessions includes B"

# Order: session-A first (emitted earlier)
FIRST=$(echo "$SESSIONS" | head -1)
assert_eq "$FIRST" "session-A" "sessions lists in chronological order"

# ── 6. Auto session_id from conductor state ──────────────────────────────

echo ""
echo "6. Auto session_id from conductor state"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cat > "$T/.autonomous/conductor-state.json" <<'EOF'
{"session_id": "auto-session-xyz"}
EOF
python3 "$TIMELINE" emit "$T" session-start mission='"m"' > /dev/null

LINE=$(cat "$T/.autonomous/timeline.jsonl")
assert_contains "$LINE" '"session_id":"auto-session-xyz"' "session_id auto-filled from state"

# No state -> null session_id
T=$(new_tmp)
python3 "$TIMELINE" emit "$T" session-start mission='"m"' > /dev/null
LINE=$(cat "$T/.autonomous/timeline.jsonl")
assert_contains "$LINE" '"session_id":null' "missing state produces null session_id"

# Malformed state -> null session_id (no crash)
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "{bad json" > "$T/.autonomous/conductor-state.json"
RESULT=$(python3 "$TIMELINE" emit "$T" session-start mission='"m"' 2>/dev/null)
assert_eq "$RESULT" "ok" "emit survives malformed conductor state"
LINE=$(cat "$T/.autonomous/timeline.jsonl")
assert_contains "$LINE" '"session_id":null' "malformed state -> null session_id"

# ── 7. Validation ─────────────────────────────────────────────────────────

echo ""
echo "7. Validation"

T=$(new_tmp)
if python3 "$TIMELINE" emit "$T" bogus-event 2>/dev/null; then
  fail "unknown event type should fail"
else
  ok "unknown event type rejected"
fi

if python3 "$TIMELINE" emit "$T" 2>/dev/null; then
  fail "emit without event should fail"
else
  ok "emit without event rejected"
fi

if python3 "$TIMELINE" emit "$T" session-start nokey 2>/dev/null; then
  fail "kv arg without = should fail"
else
  ok "kv arg without = rejected"
fi

if python3 "$TIMELINE" tail "$T" abc 2>/dev/null; then
  fail "tail with non-integer N should fail"
else
  ok "tail non-integer N rejected"
fi

if python3 "$TIMELINE" tail "$T" 0 2>/dev/null; then
  fail "tail 0 should fail"
else
  ok "tail 0 rejected"
fi

if python3 "$TIMELINE" list "$T" --session 2>/dev/null; then
  fail "--session with no value should fail"
else
  ok "--session without value rejected"
fi

if python3 "$TIMELINE" unknowncmd "$T" 2>/dev/null; then
  fail "unknown command should fail"
else
  ok "unknown command rejected"
fi

# ── 8. Conductor integration ─────────────────────────────────────────────

echo ""
echo "8. Conductor-state integration"

T=$(new_tmp)
python3 "$CONDUCTOR" init "$T" "build REST API" 5 > /dev/null
assert_file_exists "$T/.autonomous/timeline.jsonl" "init emits timeline event"

LIST=$(python3 "$TIMELINE" list "$T" --event session-start)
assert_contains "$LIST" '"mission":"build REST API"' "session-start captures mission"
assert_contains "$LIST" '"max_sprints":5' "session-start captures max_sprints"

python3 "$CONDUCTOR" sprint-start "$T" "add auth middleware" > /dev/null
LIST=$(python3 "$TIMELINE" list "$T" --event sprint-start)
assert_contains "$LIST" '"direction":"add auth middleware"' "sprint-start captures direction"
assert_contains "$LIST" '"sprint":1' "sprint-start captures number"
assert_contains "$LIST" '"phase":"directed"' "sprint-start captures phase"

python3 "$CONDUCTOR" sprint-end "$T" complete "done" '["abc commit"]' true > /dev/null
LIST=$(python3 "$TIMELINE" list "$T" --event sprint-end)
assert_contains "$LIST" '"status":"complete"' "sprint-end captures status"
assert_contains "$LIST" '"commits":1' "sprint-end captures commit count"
assert_contains "$LIST" '"direction_complete":true' "sprint-end captures direction_complete"

# ── 9. Phase transition event ─────────────────────────────────────────────

echo ""
echo "9. Phase transition event"

T=$(new_tmp)
python3 "$CONDUCTOR" init "$T" "small mission" 2 > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "direction 1" > /dev/null
# max_directed_sprints = max(1, int(2*0.7)) = 1, so after 1 sprint we hit it
python3 "$CONDUCTOR" sprint-end "$T" complete "done" '[]' false > /dev/null

LIST=$(python3 "$TIMELINE" list "$T" --event phase-transition)
assert_contains "$LIST" '"from":"directed"' "phase-transition has from field"
assert_contains "$LIST" '"to":"exploring"' "phase-transition has to field"
assert_contains "$LIST" '"reason":"max_directed_sprints reached"' "phase-transition has reason"

# No phase transition when phase unchanged
T=$(new_tmp)
python3 "$CONDUCTOR" init "$T" "mission" 10 > /dev/null
python3 "$CONDUCTOR" sprint-start "$T" "d1" > /dev/null
python3 "$CONDUCTOR" sprint-end "$T" complete "done" '["c1"]' false > /dev/null
LIST=$(python3 "$TIMELINE" list "$T" --event phase-transition)
assert_eq "$LIST" "" "no phase-transition event when phase unchanged"

# ── 10. Failure resilience ────────────────────────────────────────────────

echo ""
echo "10. Failure resilience"

# Read-only .autonomous dir — emit silently fails but doesn't crash
T=$(new_tmp)
mkdir -p "$T/.autonomous"
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../scripts')
import timeline
from pathlib import Path
ok = timeline.emit(Path('$T'), 'note', content='hello')
print('api-ok' if ok else 'api-silent-fail')
" > /tmp/timeline-api-test.out
RESULT=$(cat /tmp/timeline-api-test.out)
assert_eq "$RESULT" "api-ok" "direct API import works"
rm -f /tmp/timeline-api-test.out

# Timeline survives malformed line in file
T=$(new_tmp)
mkdir -p "$T/.autonomous"
printf '%s\n' '{"valid":1}' '{not json}' '{"valid":2}' > "$T/.autonomous/timeline.jsonl"
TAIL=$(python3 "$TIMELINE" tail "$T")
assert_contains "$TAIL" '"valid":1' "malformed line skipped, first valid survives"
assert_contains "$TAIL" '"valid":2' "malformed line skipped, last valid survives"

# ── 11. Python API never raises (regression for SystemExit leak) ──────────

echo ""
echo "11. Python API safety (emit never raises)"

T=$(new_tmp)
# Unknown event via direct import must return False, not raise SystemExit.
# Regression guard for Codex finding: conductor's `_emit` caught Exception
# but SystemExit bypasses that, so a typo'd event name would kill the conductor.
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../scripts')
import timeline
from pathlib import Path
try:
    ok = timeline.emit(Path('$T'), 'not-a-real-event')
    print('returned:', ok)
except BaseException as e:
    print('raised:', type(e).__name__, e)
    sys.exit(7)
" > /tmp/timeline-api-unknown.out
RESULT=$(cat /tmp/timeline-api-unknown.out)
assert_contains "$RESULT" "returned: False" "emit() returns False on unknown event (does not raise)"
rm -f /tmp/timeline-api-unknown.out

# Simulate the conductor's _emit() wrapper (Exception catch, not BaseException)
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../scripts')
import timeline
from pathlib import Path
def _emit(proj, ev, **f):
    try:
        return timeline.emit(proj, ev, **f)
    except Exception:
        return None
r = _emit(Path('$T'), 'bogus-event-name')
print('conductor-safe:', r is False)
" > /tmp/timeline-api-conductor.out
RESULT=$(cat /tmp/timeline-api-conductor.out)
assert_contains "$RESULT" "conductor-safe: True" "conductor _emit() pattern survives unknown event"
rm -f /tmp/timeline-api-conductor.out

# Unserializable extra field returns False (doesn't raise TypeError)
python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/../scripts')
import timeline
from pathlib import Path

class NotSerializable:
    pass

ok = timeline.emit(Path('$T'), 'session-start', bad=NotSerializable())
print('unserializable:', ok)
" > /tmp/timeline-unserial.out
RESULT=$(cat /tmp/timeline-unserial.out)
assert_contains "$RESULT" "unserializable: False" "emit() returns False on unserializable field"
rm -f /tmp/timeline-unserial.out

# CLI path still validates loudly (unknown event → exit non-zero)
T=$(new_tmp)
if python3 "$TIMELINE" emit "$T" "bogus-event" 2>/dev/null; then
  fail "CLI emit with unknown event should exit non-zero"
else
  ok "CLI emit rejects unknown event"
fi

# ── 12. Bounded memory on tail (regression for O(N) list load) ────────────

echo ""
echo "12. Bounded tail memory"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
python3 -c "
import json
with open('$T/.autonomous/timeline.jsonl', 'w') as f:
    for i in range(5000):
        f.write(json.dumps({'event':'sprint-end','sprint':i,'session_id':'x','ts':'2026-04-19T00:00:00Z'}) + '\n')
"
TAIL=$(python3 "$TIMELINE" tail "$T" 3)
LINE_COUNT=$(echo "$TAIL" | wc -l | tr -d ' ')
assert_eq "$LINE_COUNT" "3" "tail 3 works on 5000-event file"
assert_contains "$TAIL" '"sprint":4999' "last event surfaces in tail"
assert_contains "$TAIL" '"sprint":4997' "third-to-last included"
# First event must NOT be in tail 3 of a 5000-event file
if echo "$TAIL" | grep -qE '"sprint":0[,}]'; then
  fail "tail 3 unexpectedly includes sprint 0"
else
  ok "early events excluded (deque bound works)"
fi

print_results
