#!/usr/bin/env bash
# Tests for the .autonomous/comms.json protocol.
# Covers the exact python3 snippets embedded in master-poll.sh,
# master-watch.sh, and the worker prompt in SKILL.md.
# No mock claude needed — pure JSON state machine tests.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

# Helper: write comms.json to a dir
write_comms() {
  # $1 = dir, $2 = JSON string
  mkdir -p "$1/.autonomous"
  echo "$2" > "$1/.autonomous/comms.json"
}

# Helper: read status using the exact snippet from master-watch.sh
read_status() {
  # $1 = comms.json path
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status','?'))" "$1" 2>/dev/null || echo "?"
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

# ═══════════════════════════════════════════════════════════════════════════
# --help flags for comms-related scripts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. master-watch.sh --help"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELP=$(bash "$SCRIPT_DIR/../scripts/master-watch.sh" --help 2>&1)
assert_contains "$HELP" "Usage:" "master-watch --help shows usage"
assert_contains "$HELP" "comms.json" "master-watch --help mentions comms.json"
assert_contains "$HELP" "worker-pid" "master-watch --help mentions worker-pid"

bash "$SCRIPT_DIR/../scripts/master-watch.sh" --help >/dev/null 2>&1
assert_eq "$?" "0" "master-watch --help exits 0"

echo ""
echo "15. master-poll.sh --help"
HELP=$(bash "$SCRIPT_DIR/../scripts/master-poll.sh" --help 2>&1)
assert_contains "$HELP" "Usage:" "master-poll --help shows usage"
assert_contains "$HELP" "comms.json" "master-poll --help mentions comms.json"
assert_contains "$HELP" "project-dir" "master-poll --help mentions project-dir"

bash "$SCRIPT_DIR/../scripts/master-poll.sh" --help >/dev/null 2>&1
assert_eq "$?" "0" "master-poll --help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# Worker window registry (dispatch.sh)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Worker window registry"
T=$(new_tmp)
mkdir -p "$T/.autonomous"

# Simulate what dispatch.sh does: append window names
echo "worker-1" >> "$T/.autonomous/worker-windows.txt"
echo "worker-2" >> "$T/.autonomous/worker-windows.txt"
assert_file_exists "$T/.autonomous/worker-windows.txt" "worker-windows.txt created"

COUNT=$(wc -l < "$T/.autonomous/worker-windows.txt" | tr -d ' ')
assert_eq "$COUNT" "2" "two worker windows registered"

assert_file_contains "$T/.autonomous/worker-windows.txt" "worker-1" "worker-1 in registry"
assert_file_contains "$T/.autonomous/worker-windows.txt" "worker-2" "worker-2 in registry"

# ═══════════════════════════════════════════════════════════════════════════
# Comms archive (write-summary.sh)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Comms archive via write-summary.sh"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
# Init a git repo so write-summary.sh can run git log
git -C "$T" init -q
git -C "$T" config user.email "test@test.com"
git -C "$T" config user.name "Test"
echo "init" > "$T/file.txt"
git -C "$T" add file.txt && git -C "$T" commit -q -m "init"

# Place a comms.json to archive
write_comms "$T" '{"status":"done","summary":"sprint done"}'

# Run write-summary.sh WITH sprint_num (arg 6) — should archive
bash "$SCRIPT_DIR/../scripts/write-summary.sh" "$T" "complete" "Test summary" 1 True 3 > /dev/null
assert_file_exists "$T/.autonomous/comms-archive/sprint-3.json" "comms archived for sprint 3"

# Verify content matches original
ARCHIVED_STATUS=$(python3 -c "import json; print(json.load(open('$T/.autonomous/comms-archive/sprint-3.json')).get('status','?'))" 2>/dev/null)
assert_eq "$ARCHIVED_STATUS" "done" "archived comms has correct status"

# Run write-summary.sh WITHOUT sprint_num — should NOT archive
T2=$(new_tmp)
mkdir -p "$T2/.autonomous"
git -C "$T2" init -q
git -C "$T2" config user.email "test@test.com"
git -C "$T2" config user.name "Test"
echo "init" > "$T2/file.txt"
git -C "$T2" add file.txt && git -C "$T2" commit -q -m "init"
write_comms "$T2" '{"status":"done","summary":"no archive"}'
bash "$SCRIPT_DIR/../scripts/write-summary.sh" "$T2" "complete" "Test" 1 True > /dev/null
assert_file_not_exists "$T2/.autonomous/comms-archive" "no archive dir when sprint_num omitted"

# ═══════════════════════════════════════════════════════════════════════════
# show-comms.sh
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. show-comms.sh reads archived comms"
# Reuse T from test 17 which has sprint-3.json archived
OUTPUT=$(bash "$SCRIPT_DIR/../scripts/show-comms.sh" "$T" 3)
assert_contains "$OUTPUT" "done" "show-comms displays archived status"
assert_contains "$OUTPUT" "sprint done" "show-comms displays archived summary"

echo ""
echo "19. show-comms.sh handles missing archive"
OUTPUT=$(bash "$SCRIPT_DIR/../scripts/show-comms.sh" "$T" 99 2>&1 || true)
assert_contains "$OUTPUT" "ERROR" "error on missing sprint"

echo ""
echo "20. show-comms.sh --help"
HELP=$(bash "$SCRIPT_DIR/../scripts/show-comms.sh" --help 2>&1)
assert_contains "$HELP" "Usage:" "show-comms --help shows usage"
assert_contains "$HELP" "comms-archive" "show-comms --help mentions comms-archive"

bash "$SCRIPT_DIR/../scripts/show-comms.sh" --help >/dev/null 2>&1
assert_eq "$?" "0" "show-comms --help exits 0"

echo ""
echo "21. show-comms.sh --list"
# Add a second archive entry
mkdir -p "$T/.autonomous/comms-archive"
echo '{"status":"done"}' > "$T/.autonomous/comms-archive/sprint-5.json"
LIST_OUTPUT=$(bash "$SCRIPT_DIR/../scripts/show-comms.sh" "$T" --list)
assert_contains "$LIST_OUTPUT" "Sprint 3" "--list shows sprint 3"
assert_contains "$LIST_OUTPUT" "Sprint 5" "--list shows sprint 5"

# --list with no archive dir
T3=$(new_tmp)
mkdir -p "$T3/.autonomous"
LIST_ERR=$(bash "$SCRIPT_DIR/../scripts/show-comms.sh" "$T3" --list 2>&1 || true)
assert_contains "$LIST_ERR" "No comms archive" "--list handles missing archive dir"

print_results
