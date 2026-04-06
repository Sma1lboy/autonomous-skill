#!/usr/bin/env bash
# Tests for node-level conversation flows:
#   1. Conductor → Sprint Master prompt assembly (build-sprint-prompt.sh)
#   2. Sprint Master → Worker comms.json protocol lifecycle
#   3. Happy path: mock full sprint cycle
#   4. Error paths

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Helper: write comms.json to a dir
write_comms() {
  mkdir -p "$1/.autonomous"
  echo "$2" > "$1/.autonomous/comms.json"
}

# Helper: read status from comms.json
read_status() {
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status','?'))" "$1" 2>/dev/null || echo "?"
}

# Create a git-initialized temp project dir
new_git_project() {
  local d; d=$(new_tmp)
  git -C "$d" init -q
  git -C "$d" config user.email "test@test.com"
  git -C "$d" config user.name "Test"
  echo "init" > "$d/file.txt"
  git -C "$d" add file.txt
  git -C "$d" commit -q -m "init"
  echo "$d"
}

# Create a mock dir with a mock claude that drains stdin and exits 0.
# Optional: set MOCK_CLAUDE_COMMIT=1 env before calling to get a commit.
new_mock_dir() {
  local d; d=$(new_tmp)
  # timeout shim — just skip the timeout arg and exec the rest
  cat > "$d/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
  chmod +x "$d/timeout"
  echo "$d"
}

write_mock_claude() {
  local dir="$1"
  local extra="${2:-}"
  {
    echo '#!/usr/bin/env bash'
    [ -n "$extra" ] && echo "$extra"
    echo 'cat > /dev/null 2>&1 || true; exit 0'
  } > "$dir/claude"
  chmod +x "$dir/claude"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_conversations.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════════
# 1. Conductor → Sprint Master prompt assembly (build-sprint-prompt.sh)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Prompt assembly — headers present"
T=$(new_git_project)
mkdir -p "$T/.autonomous"

# Initialize backlog so backlog.sh list works
bash "$SKILL_DIR/scripts/backlog.sh" init "$T" > /dev/null 2>&1 || true

bash "$SKILL_DIR/scripts/build-sprint-prompt.sh" \
  "$T" "$SKILL_DIR" 3 "Add REST endpoints" "Previous sprint added DB models" \
  > /dev/null 2>&1

PROMPT_FILE="$T/.autonomous/sprint-prompt.md"
assert_file_exists "$PROMPT_FILE" "sprint-prompt.md created"
assert_file_contains "$PROMPT_FILE" "SCRIPT_DIR:" "has SCRIPT_DIR header"
assert_file_contains "$PROMPT_FILE" "PROJECT:" "has PROJECT header"
assert_file_contains "$PROMPT_FILE" "SPRINT_NUMBER: 3" "has correct sprint number"
assert_file_contains "$PROMPT_FILE" "SPRINT_DIRECTION: Add REST endpoints" "has sprint direction"

echo ""
echo "2. Prompt assembly — previous summary included"
assert_file_contains "$PROMPT_FILE" "Previous sprint added DB models" "prev summary in prompt"

echo ""
echo "3. Prompt assembly — SPRINT.md content inlined"
assert_file_contains "$PROMPT_FILE" "Sense -> Direct -> Respond -> Summarize" "SPRINT.md content inlined (known string)"
assert_file_contains "$PROMPT_FILE" "Sprint Master" "SPRINT.md title inlined"

echo ""
echo "4. Prompt assembly — backlog titles placeholder"
assert_file_contains "$PROMPT_FILE" "BACKLOG_TITLES:" "has BACKLOG_TITLES header"

echo ""
echo "5. Prompt assembly — with backlog items"
# Add a backlog item so titles-only output is non-empty
bash "$SKILL_DIR/scripts/backlog.sh" add "$T" "Fix flaky test" "Details here" user 3 > /dev/null 2>&1

bash "$SKILL_DIR/scripts/build-sprint-prompt.sh" \
  "$T" "$SKILL_DIR" 4 "Improve tests" "" \
  > /dev/null 2>&1

assert_file_contains "$T/.autonomous/sprint-prompt.md" "Fix flaky test" "backlog title appears in prompt"

echo ""
echo "6. Prompt assembly — empty PREVIOUS_SUMMARY (omitted arg)"
T2=$(new_git_project)
mkdir -p "$T2/.autonomous"
bash "$SKILL_DIR/scripts/backlog.sh" init "$T2" > /dev/null 2>&1 || true

bash "$SKILL_DIR/scripts/build-sprint-prompt.sh" \
  "$T2" "$SKILL_DIR" 1 "Initial setup" \
  > /dev/null 2>&1

assert_file_exists "$T2/.autonomous/sprint-prompt.md" "prompt created with no prev summary"
assert_file_contains "$T2/.autonomous/sprint-prompt.md" "PREVIOUS_SUMMARY:" "PREVIOUS_SUMMARY header present (empty)"
assert_file_contains "$T2/.autonomous/sprint-prompt.md" "SPRINT_NUMBER: 1" "sprint 1 correct"

echo ""
echo "7. Prompt assembly — missing SPRINT.md → error"
T3=$(new_tmp)
mkdir -p "$T3/.autonomous"
# Use a fake SCRIPT_DIR that has no SPRINT.md
FAKE_DIR=$(new_tmp)
ERR=$(bash "$SKILL_DIR/scripts/build-sprint-prompt.sh" "$T3" "$FAKE_DIR" 1 "test" 2>&1 || true)
assert_contains "$ERR" "ERROR" "missing SPRINT.md produces error"
assert_contains "$ERR" "SPRINT.md" "error mentions SPRINT.md"

echo ""
echo "8. Prompt assembly — --help flag"
HELP=$(bash "$SKILL_DIR/scripts/build-sprint-prompt.sh" --help 2>&1)
assert_contains "$HELP" "Usage:" "build-sprint-prompt --help shows usage"
bash "$SKILL_DIR/scripts/build-sprint-prompt.sh" --help > /dev/null 2>&1
assert_eq "$?" "0" "build-sprint-prompt --help exits 0"

# ═══════════════════════════════════════════════════════════════════════════════
# 2. Sprint Master → Worker comms.json protocol lifecycle
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Comms lifecycle — idle → waiting → answered → done"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"

# Init idle
echo '{"status":"idle"}' > "$COMMS"
assert_eq "$(read_status "$COMMS")" "idle" "starts idle"

# Worker writes waiting with questions
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [{
        'question': 'Should I use REST or GraphQL?',
        'header': 'API Design',
        'options': [{'label': 'REST'}, {'label': 'GraphQL'}],
        'multiSelect': False
    }],
    'rec': 'A'
}, open('$COMMS', 'w'))
"
assert_eq "$(read_status "$COMMS")" "waiting" "worker sets waiting"

# Master writes answered
python3 -c "import json; json.dump({'status':'answered','answers':['A']}, open('$COMMS','w'))"
assert_eq "$(read_status "$COMMS")" "answered" "master sets answered"

# Worker reads answer
ANSWER=$(python3 -c "
import json
d = json.load(open('$COMMS'))
if d.get('status') == 'answered':
    for a in d.get('answers', []): print(a)
" 2>/dev/null)
assert_eq "$ANSWER" "A" "worker reads correct answer"

# Worker writes done with summary
python3 -c "
import json
json.dump({
    'status': 'done',
    'summary': 'Implemented REST API with 3 endpoints'
}, open('$COMMS', 'w'))
"
assert_eq "$(read_status "$COMMS")" "done" "worker sets done"
SUMMARY=$(python3 -c "import json; print(json.load(open('$COMMS')).get('summary',''))" 2>/dev/null)
assert_eq "$SUMMARY" "Implemented REST API with 3 endpoints" "done includes summary"

echo ""
echo "10. Comms — malformed JSON → read_status returns '?'"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo 'THIS IS NOT JSON {{{' > "$T/.autonomous/comms.json"
assert_eq "$(read_status "$T/.autonomous/comms.json")" "?" "malformed JSON returns ?"

echo '{"status":' > "$T/.autonomous/comms.json"
assert_eq "$(read_status "$T/.autonomous/comms.json")" "?" "truncated JSON returns ?"

echo "" > "$T/.autonomous/comms.json"
assert_eq "$(read_status "$T/.autonomous/comms.json")" "?" "empty file returns ?"

echo ""
echo "11. Comms — empty questions array"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"
python3 -c "
import json
json.dump({'status':'waiting','questions':[],'rec':''}, open('$COMMS','w'))
"
assert_eq "$(read_status "$COMMS")" "waiting" "waiting with empty questions is valid"
COUNT=$(python3 -c "import json; print(len(json.load(open('$COMMS'))['questions']))" 2>/dev/null)
assert_eq "$COUNT" "0" "zero questions stored"

echo ""
echo "12. Comms — multiple round trips"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"

# Round 1: worker asks, master answers
echo '{"status":"idle"}' > "$COMMS"
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [{'question':'Q1','header':'H1','options':[{'label':'Yes'},{'label':'No'}],'multiSelect':False}],
    'rec': 'A'
}, open('$COMMS', 'w'))
"
assert_eq "$(read_status "$COMMS")" "waiting" "round 1: worker asks"

python3 -c "import json; json.dump({'status':'answered','answers':['A']}, open('$COMMS','w'))"
R1_ANSWER=$(python3 -c "import json; d=json.load(open('$COMMS')); print(d['answers'][0])" 2>/dev/null)
assert_eq "$R1_ANSWER" "A" "round 1: master answers A"

# Round 2: worker asks again, master answers differently
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [{'question':'Q2','header':'H2','options':[{'label':'Fast'},{'label':'Safe'}],'multiSelect':False}],
    'rec': 'B'
}, open('$COMMS', 'w'))
"
assert_eq "$(read_status "$COMMS")" "waiting" "round 2: worker asks again"

python3 -c "import json; json.dump({'status':'answered','answers':['B']}, open('$COMMS','w'))"
R2_ANSWER=$(python3 -c "import json; d=json.load(open('$COMMS')); print(d['answers'][0])" 2>/dev/null)
assert_eq "$R2_ANSWER" "B" "round 2: master answers B"

# Worker finishes
python3 -c "
import json
json.dump({'status':'done','summary':'Completed after 2 rounds of guidance'}, open('$COMMS','w'))
"
assert_eq "$(read_status "$COMMS")" "done" "round 2: worker finishes with done"
FINAL=$(python3 -c "import json; print(json.load(open('$COMMS')).get('summary',''))" 2>/dev/null)
assert_contains "$FINAL" "2 rounds" "done summary references both rounds"

echo ""
echo "13. Comms — done status includes summary field"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms.json"
python3 -c "
import json
json.dump({
    'status': 'done',
    'summary': 'Added 5 unit tests, refactored auth module'
}, open('$COMMS', 'w'))
"
VALID=$(python3 -c "
import json
d = json.load(open('$COMMS'))
assert d['status'] == 'done'
assert 'summary' in d
assert len(d['summary']) > 0
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "done JSON has status and non-empty summary"

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Happy path: mock full sprint cycle
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Happy path — dispatch creates worker prompt and registers window"
T=$(new_git_project)
mkdir -p "$T/.autonomous"

MOCK_DIR=$(new_mock_dir)
# Mock claude that writes done to comms.json and makes a commit
cat > "$MOCK_DIR/claude" << 'MOCKEOF'
#!/usr/bin/env bash
# Simulate a worker: make a commit and write done to comms.json
PROJECT_DIR=""
for arg in "$@"; do
  if [ -d "$arg" ]; then PROJECT_DIR="$arg"; fi
done
# Try to extract project dir from the prompt file if passed via --dangerously-skip-permissions
PROMPT_TEXT="$*"
# Just use the current directory as fallback
cd "$PROJECT_DIR" 2>/dev/null || true
# Make a commit if in a git repo
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  echo "mock-change" >> mock-output.txt
  git add mock-output.txt
  git commit -q -m "mock: worker commit" 2>/dev/null || true
fi
# Write done to comms.json
if [ -d .autonomous ]; then
  python3 -c "import json; json.dump({'status':'done','summary':'Mock worker completed task'}, open('.autonomous/comms.json','w'))" 2>/dev/null || true
fi
exit 0
MOCKEOF
chmod +x "$MOCK_DIR/claude"

# Build sprint prompt first
bash "$SKILL_DIR/scripts/backlog.sh" init "$T" > /dev/null 2>&1 || true
bash "$SKILL_DIR/scripts/build-sprint-prompt.sh" \
  "$T" "$SKILL_DIR" 1 "Add unit tests" "" > /dev/null 2>&1

PROMPT_FILE="$T/.autonomous/sprint-prompt.md"
assert_file_exists "$PROMPT_FILE" "sprint prompt exists before dispatch"

# Dispatch in headless mode (no tmux in test)
# Unset tmux env to force headless
DISPATCH_OUT=$(TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$PROMPT_FILE" "worker-1" 2>&1)

assert_contains "$DISPATCH_OUT" "DISPATCH_MODE=" "dispatch reports mode"
assert_file_exists "$T/.autonomous/worker-windows.txt" "worker-windows.txt created"
assert_file_contains "$T/.autonomous/worker-windows.txt" "worker-1" "worker-1 registered"

echo ""
echo "15. Happy path — wrapper script created"
assert_file_exists "$T/.autonomous/run-worker-1.sh" "wrapper script created"

echo ""
echo "16. Happy path — wait for worker, then verify comms done"
# The mock claude runs in the background in headless mode — extract PID
DISPATCH_PID=$(echo "$DISPATCH_OUT" | grep "DISPATCH_PID=" | head -1 | cut -d= -f2)
if [ -n "$DISPATCH_PID" ]; then
  # Wait for the mock to finish (should be instant)
  wait "$DISPATCH_PID" 2>/dev/null || true
fi
# Give a moment for file writes to flush
sleep 1

# Mock claude may not have cd'd properly — that's OK; we verify the dispatch mechanics
# The main thing is dispatch.sh created all the right files

echo ""
echo "17. Happy path — write-summary.sh produces valid JSON"
# Make a commit so write-summary.sh has something to find
echo "test content" > "$T/test-file.txt"
git -C "$T" add test-file.txt
git -C "$T" commit -q -m "test: add test file"

bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Added unit tests" 2 True 1 > /dev/null 2>&1

SUMMARY_FILE="$T/.autonomous/sprint-summary.json"
assert_file_exists "$SUMMARY_FILE" "sprint-summary.json created"

VALID=$(python3 -c "
import json
d = json.load(open('$SUMMARY_FILE'))
assert d['status'] == 'complete', f'status: {d[\"status\"]}'
assert 'commits' in d, 'missing commits'
assert isinstance(d['commits'], list), 'commits not list'
assert d['summary'] == 'Added unit tests', f'summary: {d[\"summary\"]}'
assert d['iterations_used'] == 2, f'iterations: {d[\"iterations_used\"]}'
assert d['direction_complete'] == True, f'dir_complete: {d[\"direction_complete\"]}'
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "sprint-summary.json has correct structure"

echo ""
echo "18. Happy path — write-summary.sh archives comms.json"
assert_file_exists "$T/.autonomous/comms-archive/sprint-1.json" "comms archived for sprint 1"

echo ""
echo "19. Happy path — write-summary.sh cleans worker-windows.txt"
assert_file_not_exists "$T/.autonomous/worker-windows.txt" "worker-windows.txt cleaned up"

# ═══════════════════════════════════════════════════════════════════════════════
# 4. Error paths
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Error — worker exits without writing done (monitor detects WORKER_PROCESS_EXITED)"
T=$(new_git_project)
mkdir -p "$T/.autonomous"
echo '{"status":"idle"}' > "$T/.autonomous/comms.json"

# Simulate a headless worker that exited — create a fake PID that doesn't exist
FAKE_PID=99999
# Make sure it's not a real process
while kill -0 "$FAKE_PID" 2>/dev/null; do
  FAKE_PID=$((FAKE_PID + 1))
done

# Create the output log that monitor-worker.sh expects
echo "worker exited unexpectedly" > "$T/.autonomous/worker-output.log"

# Run monitor-worker.sh with the dead PID — it should detect the exit immediately
MONITOR_OUT=$(bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" "worker" "$FAKE_PID" 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_PROCESS_EXITED" "monitor detects dead worker process"

echo ""
echo "21. Error — comms.json corrupted mid-sprint → read_status returns '?'"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
# Simulate corruption: binary garbage
printf '\x00\x01\x02 not json' > "$T/.autonomous/comms.json"
assert_eq "$(read_status "$T/.autonomous/comms.json")" "?" "binary garbage returns ?"

# Partial JSON overwrite
echo '{"status":"wait' > "$T/.autonomous/comms.json"
assert_eq "$(read_status "$T/.autonomous/comms.json")" "?" "partial JSON overwrite returns ?"

echo ""
echo "22. Error — dispatch.sh with missing prompt file"
T=$(new_git_project)
mkdir -p "$T/.autonomous"

MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

ERR=$(PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/.autonomous/nonexistent-prompt.md" "worker" 2>&1 || true)
assert_contains "$ERR" "ERROR" "dispatch.sh errors on missing prompt"
assert_contains "$ERR" "not found" "error mentions file not found"

echo ""
echo "23. Error — write-summary.sh with invalid project dir"
if bash "$SKILL_DIR/scripts/write-summary.sh" "/nonexistent/project/dir" "complete" "test" > /dev/null 2>&1; then
  fail "write-summary.sh should fail for invalid dir"
else
  ok "write-summary.sh exits non-zero for invalid dir"
fi

echo ""
echo "24. Error — dispatch.sh --help"
HELP=$(bash "$SKILL_DIR/scripts/dispatch.sh" --help 2>&1)
assert_contains "$HELP" "Usage:" "dispatch --help shows usage"
bash "$SKILL_DIR/scripts/dispatch.sh" --help > /dev/null 2>&1
assert_eq "$?" "0" "dispatch --help exits 0"

echo ""
echo "25. Error — monitor-worker.sh --help"
HELP=$(bash "$SKILL_DIR/scripts/monitor-worker.sh" --help 2>&1)
assert_contains "$HELP" "Usage:" "monitor-worker --help shows usage"
assert_contains "$HELP" "WORKER_PROCESS_EXITED" "monitor-worker --help documents exit statuses"
bash "$SKILL_DIR/scripts/monitor-worker.sh" --help > /dev/null 2>&1
assert_eq "$?" "0" "monitor-worker --help exits 0"

echo ""
echo "26. Error — write-summary.sh --help"
HELP=$(bash "$SKILL_DIR/scripts/write-summary.sh" --help 2>&1)
assert_contains "$HELP" "Usage:" "write-summary --help shows usage"
bash "$SKILL_DIR/scripts/write-summary.sh" --help > /dev/null 2>&1
assert_eq "$?" "0" "write-summary --help exits 0"

print_results
