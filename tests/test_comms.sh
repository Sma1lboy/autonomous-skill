#!/usr/bin/env bash
# Tests for the .autonomous/comms.json protocol.
# Covers the exact python3 snippets embedded in master-poll.sh,
# master-watch.sh, and the worker prompt in SKILL.md.
# No mock claude needed — pure JSON state machine tests.

set -euo pipefail

# ── Minimal test framework ──────────────────────────────────────────────────
PASS=0; FAIL=0

ok()   { echo "  ok  $*"; ((PASS++)) || true; }
fail() { echo "  FAIL $*"; ((FAIL++)) || true; }

assert_eq() {
  [ "$1" = "$2" ] && ok "$3" || fail "$3 — got '$1', want '$2'"
}
assert_contains() {
  echo "$1" | grep -q "$2" && ok "$3" || fail "$3 — '$2' not in output"
}

# ── Temp dir management ─────────────────────────────────────────────────────
TMPDIRS=()
new_tmp() { local d; d=$(mktemp -d); TMPDIRS+=("$d"); echo "$d"; }
cleanup() { [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf "${TMPDIRS[@]}" || true; }
trap cleanup EXIT

# Helper: write comms.json to a dir
write_comms() {
  # $1 = dir, $2 = JSON string
  mkdir -p "$1/.autonomous"
  echo "$2" > "$1/.autonomous/comms.json"
}

# Helper: read status using the exact snippet from master-watch.sh
read_status() {
  # $1 = comms.json path
  python3 -c "import json; print(json.load(open('$1')).get('status','?'))" 2>/dev/null || echo "?"
}

# ── Tests ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_comms.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Status detection — idle
echo ""
echo "1. Status detection"
T=$(new_tmp)
write_comms "$T" '{"status":"idle"}'
assert_eq "$(read_status "$T/.autonomous/comms.json")" "idle" "reads idle"

write_comms "$T" '{"status":"waiting"}'
assert_eq "$(read_status "$T/.autonomous/comms.json")" "waiting" "reads waiting"

write_comms "$T" '{"status":"answered"}'
assert_eq "$(read_status "$T/.autonomous/comms.json")" "answered" "reads answered"

# 2. Missing file or malformed JSON → returns "?"
echo ""
echo "2. Missing or malformed comms.json → returns '?'"
T=$(new_tmp)
STATUS=$(python3 -c "import json; print(json.load(open('$T/.autonomous/comms.json')).get('status','?'))" 2>/dev/null || echo "?")
assert_eq "$STATUS" "?" "gracefully handles missing file"

mkdir -p "$T/.autonomous"
echo '{"status":' > "$T/.autonomous/comms.json"   # truncated / malformed
assert_eq "$(read_status "$T/.autonomous/comms.json")" "?" "gracefully handles malformed JSON"

# 3. Worker writes waiting format (exact format from SKILL.md)
echo ""
echo "3. Worker writes waiting format"
T=$(new_tmp); mkdir -p "$T/.autonomous"
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [{
        'question': 'Which approach should I use?',
        'header': 'Architecture Decision',
        'options': [{'label': 'Monolith'}, {'label': 'Microservices'}],
        'multiSelect': False
    }],
    'rec': 'A'
}, open('$T/.autonomous/comms.json', 'w'))
"
assert_eq "$(read_status "$T/.autonomous/comms.json")" "waiting" "status is waiting"

# Validate structure with python3
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/comms.json'))
q = d['questions'][0]
assert d['status'] == 'waiting'
assert isinstance(d['questions'], list)
assert 'question' in q
assert 'header' in q
assert 'options' in q
assert isinstance(q['multiSelect'], bool)
assert 'rec' in d
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "waiting JSON has required fields"

# 4. Master writes answered format
echo ""
echo "4. Master writes answered format"
T=$(new_tmp); mkdir -p "$T/.autonomous"
python3 -c "
import json
json.dump({'status': 'answered', 'answers': ['A']}, open('$T/.autonomous/comms.json', 'w'))
"
assert_eq "$(read_status "$T/.autonomous/comms.json")" "answered" "status is answered"
VALID=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/comms.json'))
assert d['status'] == 'answered'
assert isinstance(d['answers'], list)
assert len(d['answers']) > 0
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "answered JSON has required fields"

# 5. Full round trip: idle → waiting → answered → idle
echo ""
echo "5. Full round trip"
T=$(new_tmp); mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"

# Init
echo '{"status":"idle"}' > "$COMMS"
assert_eq "$(read_status "$COMMS")" "idle" "starts idle"

# Worker asks
python3 -c "
import json
json.dump({'status':'waiting','questions':[{'question':'Proceed?','header':'Confirm','options':[{'label':'Yes'},{'label':'No'}],'multiSelect':False}],'rec':'A'}, open('$COMMS','w'))
"
assert_eq "$(read_status "$COMMS")" "waiting" "worker sets waiting"

# Master answers
python3 -c "import json; json.dump({'status':'answered','answers':['A']}, open('$COMMS','w'))"
assert_eq "$(read_status "$COMMS")" "answered" "master sets answered"

# Worker reads answer and resets
ANSWER=$(python3 -c "
import json
d = json.load(open('$COMMS'))
if d.get('status') == 'answered':
    for a in d.get('answers', []): print(a)
" 2>/dev/null)
assert_eq "$ANSWER" "A" "worker reads correct answer"

# Reset to idle
echo '{"status":"idle"}' > "$COMMS"
assert_eq "$(read_status "$COMMS")" "idle" "resets to idle"

# 6. Question display (exact snippet from master-poll.sh)
echo ""
echo "6. Question display rendering"
T=$(new_tmp); mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [{
        'question': 'Pick a deployment strategy',
        'header': 'Deploy',
        'options': [{'label': 'Blue-green'}, {'label': 'Rolling'}],
        'multiSelect': False
    }],
    'rec': 'B'
}, open('$COMMS', 'w'))
"

DISPLAY=$(python3 << PYEOF
import json
d = json.load(open('$COMMS'))
for q in d.get('questions', []):
    print(f"  [{q.get('header','')}]")
    print(f"  {q['question'][:500]}")
    print()
    for i, o in enumerate(q.get('options', [])):
        label = o['label'] if isinstance(o, dict) else o
        print(f"    {chr(65+i)}) {label}")
print(f"\n  rec: {d.get('rec','—')}")
PYEOF
)
assert_contains "$DISPLAY" "[Deploy]"                   "header rendered"
assert_contains "$DISPLAY" "Pick a deployment strategy" "question text rendered"
assert_contains "$DISPLAY" "A) Blue-green"              "first option is A"
assert_contains "$DISPLAY" "B) Rolling"                 "second option is B"
assert_contains "$DISPLAY" "rec: B"                     "recommendation shown"

# 7. Question display handles plain string options (not dicts)
echo ""
echo "7. Display handles plain string options"
T=$(new_tmp); mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [{'question': 'Choose','header': 'H','options': ['Alpha','Beta'],'multiSelect': False}],
    'rec': 'A'
}, open('$COMMS', 'w'))
"
DISPLAY=$(python3 << PYEOF
import json
d = json.load(open('$COMMS'))
for q in d.get('questions', []):
    for i, o in enumerate(q.get('options', [])):
        label = o['label'] if isinstance(o, dict) else o
        print(f"    {chr(65+i)}) {label}")
PYEOF
)
assert_contains "$DISPLAY" "A) Alpha" "plain string option A rendered"
assert_contains "$DISPLAY" "B) Beta"  "plain string option B rendered"

# 8. multiSelect flag round-trips correctly
echo ""
echo "8. multiSelect flag"
T=$(new_tmp); mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"
python3 -c "
import json
json.dump({'status':'waiting','questions':[{'question':'Pick all that apply','header':'Multi','options':[{'label':'A1'},{'label':'A2'}],'multiSelect':True}],'rec':'A'}, open('$COMMS','w'))
"
MS=$(python3 -c "import json; print(json.load(open('$COMMS'))['questions'][0]['multiSelect'])")
assert_eq "$MS" "True" "multiSelect=True preserved"

# 9. Multiple questions in one batch
echo ""
echo "9. Multiple questions in one batch"
T=$(new_tmp); mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [
        {'question': 'Q1','header': 'H1','options': [{'label':'Yes'}],'multiSelect': False},
        {'question': 'Q2','header': 'H2','options': [{'label':'No'}],'multiSelect': False}
    ],
    'rec': 'A'
}, open('$COMMS', 'w'))
"
COUNT=$(python3 -c "import json; print(len(json.load(open('$COMMS'))['questions']))")
assert_eq "$COUNT" "2" "two questions stored"
DISPLAY=$(python3 << PYEOF
import json
d = json.load(open('$COMMS'))
for q in d.get('questions', []):
    print(f"  [{q.get('header','')}]")
PYEOF
)
assert_contains "$DISPLAY" "[H1]" "first question header rendered"
assert_contains "$DISPLAY" "[H2]" "second question header rendered"

# 10. Worker answer poll loop reads correctly on pre-answered state
echo ""
echo "10. Worker reads answered status immediately"
T=$(new_tmp); mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"
python3 -c "import json; json.dump({'status':'answered','answers':['B']}, open('$COMMS','w'))"

ANSWER=$(python3 << PYEOF
import json, time
for _ in range(1):   # one iteration only (already answered)
    d = json.load(open('$COMMS'))
    if d.get('status') == 'answered':
        for a in d.get('answers', []):
            print(a)
        break
PYEOF
)
assert_eq "$ANSWER" "B" "worker reads answer B"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
[ "$FAIL" -eq 0 ]
