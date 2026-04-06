#!/usr/bin/env bash
# Tests for per-worker comms isolation (multi-worker concurrent dispatch).
# Covers dispatch.sh worker-id, monitor-worker.sh worker-id + --all mode,
# write-summary.sh per-worker archiving, master-poll.sh and master-watch.sh
# worker-id support, show-comms.sh per-worker display, and backward compat.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Helper: write comms.json to a dir
write_comms() {
  mkdir -p "$1/.autonomous"
  echo "$2" > "$1/.autonomous/comms.json"
}

# Helper: write per-worker comms file
write_worker_comms() {
  # $1 = dir, $2 = worker-id, $3 = JSON string
  mkdir -p "$1/.autonomous"
  echo "$3" > "$1/.autonomous/comms-${2}.json"
}

# Helper: read status from any comms file
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

# Create a mock dir with mock timeout
new_mock_dir() {
  local d; d=$(new_tmp)
  cat > "$d/timeout" << 'TEOF'
#!/usr/bin/env bash
shift; exec "$@"
TEOF
  chmod +x "$d/timeout"
  echo "$d"
}

write_mock_claude() {
  local dir="$1"
  {
    echo '#!/usr/bin/env bash'
    echo 'cat > /dev/null 2>&1 || true; exit 0'
  } > "$dir/claude"
  chmod +x "$dir/claude"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_multi_worker.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════════
# 1. dispatch.sh — worker-id creates per-worker comms file
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "1. dispatch.sh — worker-id creates per-worker comms file"
T=$(new_git_project)
mkdir -p "$T/.autonomous"

MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

# Create a prompt file
echo "test prompt" > "$T/.autonomous/worker-prompt.md"

# Dispatch WITH worker-id
DISPATCH_OUT=$(TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/.autonomous/worker-prompt.md" "w1" "worker-1" 2>&1)
assert_file_exists "$T/.autonomous/comms-worker-1.json" "comms-worker-1.json created"
WSTATUS=$(read_status "$T/.autonomous/comms-worker-1.json")
assert_eq "$WSTATUS" "idle" "per-worker comms starts idle"
assert_contains "$DISPATCH_OUT" "DISPATCH_MODE=" "dispatch reports mode with worker-id"

echo ""
echo "2. dispatch.sh — no worker-id does NOT create per-worker comms"
T=$(new_git_project)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/worker-prompt.md"

MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/.autonomous/worker-prompt.md" "worker" 2>&1 > /dev/null
# Should NOT create any comms-*.json files
COMMS_COUNT=$(find "$T/.autonomous" -name "comms-*.json" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$COMMS_COUNT" "0" "no per-worker comms when worker-id omitted"

echo ""
echo "3. dispatch.sh — multiple workers get separate comms files"
T=$(new_git_project)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/worker-prompt.md"

MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/.autonomous/worker-prompt.md" "w1" "worker-1" 2>&1 > /dev/null
TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/.autonomous/worker-prompt.md" "w2" "worker-2" 2>&1 > /dev/null

assert_file_exists "$T/.autonomous/comms-worker-1.json" "worker-1 comms created"
assert_file_exists "$T/.autonomous/comms-worker-2.json" "worker-2 comms created"
assert_eq "$(read_status "$T/.autonomous/comms-worker-1.json")" "idle" "worker-1 idle"
assert_eq "$(read_status "$T/.autonomous/comms-worker-2.json")" "idle" "worker-2 idle"

echo ""
echo "4. dispatch.sh — worker-id registers window name"
assert_file_contains "$T/.autonomous/worker-windows.txt" "w1" "w1 in worker-windows"
assert_file_contains "$T/.autonomous/worker-windows.txt" "w2" "w2 in worker-windows"

echo ""
echo "5. dispatch.sh — --help shows worker-id"
HELP=$(bash "$SKILL_DIR/scripts/dispatch.sh" --help 2>&1)
assert_contains "$HELP" "worker-id" "dispatch --help mentions worker-id"

# ═══════════════════════════════════════════════════════════════════════════════
# 2. monitor-worker.sh — worker-id monitors per-worker file
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "6. monitor-worker.sh — worker-id monitors per-worker comms file (done)"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
git -C "$T" init -q 2>/dev/null
git -C "$T" config user.email "test@test.com"
git -C "$T" config user.name "Test"
echo "init" > "$T/f.txt" && git -C "$T" add f.txt && git -C "$T" commit -q -m "init"

write_worker_comms "$T" "worker-1" '{"status":"done","summary":"Task completed"}'

# Use a dead PID so monitor exits via comms check, not process liveness
FAKE_PID=99998
while kill -0 "$FAKE_PID" 2>/dev/null; do FAKE_PID=$((FAKE_PID + 1)); done

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" "worker" "$FAKE_PID" "worker-1" 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_DONE" "monitor detects done on per-worker file"

echo ""
echo "7. monitor-worker.sh — worker-id monitors per-worker comms file (waiting)"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
git -C "$T" init -q 2>/dev/null
git -C "$T" config user.email "test@test.com"
git -C "$T" config user.name "Test"
echo "init" > "$T/f.txt" && git -C "$T" add f.txt && git -C "$T" commit -q -m "init"

write_worker_comms "$T" "worker-2" '{"status":"waiting","questions":[{"question":"Which?","header":"H","options":[{"label":"A"}],"multiSelect":false}],"rec":"A"}'

FAKE_PID=99998
while kill -0 "$FAKE_PID" 2>/dev/null; do FAKE_PID=$((FAKE_PID + 1)); done

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" "worker" "$FAKE_PID" "worker-2" 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_ASKING" "monitor detects asking on per-worker file"

echo ""
echo "8. monitor-worker.sh — no worker-id uses comms.json (backward compat)"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
git -C "$T" init -q 2>/dev/null
git -C "$T" config user.email "test@test.com"
git -C "$T" config user.name "Test"
echo "init" > "$T/f.txt" && git -C "$T" add f.txt && git -C "$T" commit -q -m "init"

write_comms "$T" '{"status":"done","summary":"Done via default comms"}'

FAKE_PID=99998
while kill -0 "$FAKE_PID" 2>/dev/null; do FAKE_PID=$((FAKE_PID + 1)); done

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" "worker" "$FAKE_PID" 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_DONE" "monitor uses comms.json when no worker-id"

echo ""
echo "9. monitor-worker.sh — --help shows worker-id and --all"
HELP=$(bash "$SKILL_DIR/scripts/monitor-worker.sh" --help 2>&1)
assert_contains "$HELP" "worker-id" "monitor --help mentions worker-id"
# Use grep -F for literal match since --all is a grep flag
echo "$HELP" | grep -qF -- "--all" && ok "monitor --help mentions --all" || fail "monitor --help mentions --all — '--all' not in output"
bash "$SKILL_DIR/scripts/monitor-worker.sh" --help > /dev/null 2>&1
assert_eq "$?" "0" "monitor --help exits 0"

# ═══════════════════════════════════════════════════════════════════════════════
# 3. monitor-worker.sh --all mode
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "10. monitor --all — detects done worker"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
write_worker_comms "$T" "worker-1" '{"status":"idle"}'
write_worker_comms "$T" "worker-2" '{"status":"done","summary":"W2 done"}'

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" --all 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_DONE" "--all detects done worker"
assert_contains "$MONITOR_OUT" "WORKER_ID=" "--all outputs WORKER_ID"

echo ""
echo "11. monitor --all — detects waiting worker"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
write_worker_comms "$T" "worker-1" '{"status":"idle"}'
write_worker_comms "$T" "worker-2" '{"status":"waiting","questions":[{"question":"Q","header":"H","options":[],"multiSelect":false}],"rec":"A"}'

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" --all 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_ASKING" "--all detects asking worker"
assert_contains "$MONITOR_OUT" "WORKER_ID=worker-2" "--all reports correct worker-id"

echo ""
echo "12. monitor --all — first active worker wins"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
write_worker_comms "$T" "worker-1" '{"status":"done","summary":"W1 done"}'
write_worker_comms "$T" "worker-2" '{"status":"done","summary":"W2 done"}'

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" --all 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_DONE" "--all with two done workers exits immediately"
assert_contains "$MONITOR_OUT" "WORKER_ID=" "--all reports a worker-id"

echo ""
echo "13. monitor --all — ignores non-worker comms files"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
# comms.json (not a worker file) has done — should be ignored by --all
write_comms "$T" '{"status":"done","summary":"Sprint done"}'
write_worker_comms "$T" "worker-1" '{"status":"done","summary":"W1 done"}'

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" --all 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_ID=worker-1" "--all only scans comms-worker-* files"

echo ""
echo "14. monitor --all — extracts worker-id from filename"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
write_worker_comms "$T" "worker-abc-123" '{"status":"done","summary":"done"}'

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" --all 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_ID=worker-abc-123" "--all extracts complex worker-id"

# ═══════════════════════════════════════════════════════════════════════════════
# 4. write-summary.sh — per-worker comms archiving
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "15. write-summary.sh — archives per-worker comms files"
T=$(new_git_project)
write_comms "$T" '{"status":"done","summary":"Sprint master done"}'
write_worker_comms "$T" "worker-1" '{"status":"done","summary":"W1 done"}'
write_worker_comms "$T" "worker-2" '{"status":"done","summary":"W2 done"}'

bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Test summary" 1 True 5 > /dev/null

assert_file_exists "$T/.autonomous/comms-archive/sprint-5.json" "sprint-level archive created"
assert_file_exists "$T/.autonomous/comms-archive/sprint-5-worker-1.json" "worker-1 archive created"
assert_file_exists "$T/.autonomous/comms-archive/sprint-5-worker-2.json" "worker-2 archive created"

# Verify content
W1_STATUS=$(python3 -c "import json; print(json.load(open('$T/.autonomous/comms-archive/sprint-5-worker-1.json')).get('summary',''))" 2>/dev/null)
assert_eq "$W1_STATUS" "W1 done" "worker-1 archive has correct content"
W2_STATUS=$(python3 -c "import json; print(json.load(open('$T/.autonomous/comms-archive/sprint-5-worker-2.json')).get('summary',''))" 2>/dev/null)
assert_eq "$W2_STATUS" "W2 done" "worker-2 archive has correct content"

echo ""
echo "16. write-summary.sh — no worker comms → only sprint-level archive"
T=$(new_git_project)
write_comms "$T" '{"status":"done","summary":"Just sprint master"}'

bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Test" 1 True 3 > /dev/null

assert_file_exists "$T/.autonomous/comms-archive/sprint-3.json" "sprint-level archive created"
WORKER_ARCHIVES=$(find "$T/.autonomous/comms-archive" -name "sprint-3-worker-*.json" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$WORKER_ARCHIVES" "0" "no worker archives when no worker comms"

echo ""
echo "17. write-summary.sh — no sprint_num skips all archiving"
T=$(new_git_project)
write_comms "$T" '{"status":"done"}'
write_worker_comms "$T" "worker-1" '{"status":"done"}'

bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Test" 1 True > /dev/null

assert_file_not_exists "$T/.autonomous/comms-archive" "no archive dir without sprint_num"

echo ""
echo "18. write-summary.sh — --help mentions per-worker"
HELP=$(bash "$SKILL_DIR/scripts/write-summary.sh" --help 2>&1)
assert_contains "$HELP" "per-worker" "write-summary --help mentions per-worker"

# ═══════════════════════════════════════════════════════════════════════════════
# 5. show-comms.sh — per-worker archives
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "19. show-comms.sh --list — shows per-worker archives"
T=$(new_tmp)
mkdir -p "$T/.autonomous/comms-archive"
echo '{"status":"done"}' > "$T/.autonomous/comms-archive/sprint-1.json"
echo '{"status":"done"}' > "$T/.autonomous/comms-archive/sprint-1-worker-1.json"
echo '{"status":"done"}' > "$T/.autonomous/comms-archive/sprint-1-worker-2.json"

LIST_OUTPUT=$(bash "$SKILL_DIR/scripts/show-comms.sh" "$T" --list)
assert_contains "$LIST_OUTPUT" "Sprint 1" "--list shows sprint 1"
assert_contains "$LIST_OUTPUT" "worker-1" "--list shows worker-1"
assert_contains "$LIST_OUTPUT" "worker-2" "--list shows worker-2"

echo ""
echo "20. show-comms.sh — reads sprint-level archive (backward compat)"
OUTPUT=$(bash "$SKILL_DIR/scripts/show-comms.sh" "$T" 1)
assert_contains "$OUTPUT" "done" "show-comms reads sprint-level archive"

echo ""
echo "21. show-comms.sh — --help mentions per-worker"
HELP=$(bash "$SKILL_DIR/scripts/show-comms.sh" --help 2>&1)
assert_contains "$HELP" "per-worker" "show-comms --help mentions per-worker"

# ═══════════════════════════════════════════════════════════════════════════════
# 6. master-poll.sh — worker-id support
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "22. master-poll.sh — --help shows worker-id"
HELP=$(bash "$SKILL_DIR/scripts/master-poll.sh" --help 2>&1)
assert_contains "$HELP" "worker-id" "master-poll --help mentions worker-id"
bash "$SKILL_DIR/scripts/master-poll.sh" --help > /dev/null 2>&1
assert_eq "$?" "0" "master-poll --help exits 0"

echo ""
echo "23. master-poll.sh — errors on missing per-worker comms file"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
ERR=$(bash "$SKILL_DIR/scripts/master-poll.sh" "$T" "worker-999" 2>&1 || true)
assert_contains "$ERR" "ERROR" "master-poll errors on missing worker comms"
assert_contains "$ERR" "comms-worker-999.json" "error mentions specific worker file"

echo ""
echo "24. master-poll.sh — errors on missing default comms file"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
ERR=$(bash "$SKILL_DIR/scripts/master-poll.sh" "$T" 2>&1 || true)
assert_contains "$ERR" "ERROR" "master-poll errors on missing comms.json"

echo ""
echo "25. master-poll.sh — finds per-worker comms when present"
T=$(new_tmp)
write_worker_comms "$T" "worker-1" '{"status":"idle"}'
# Just test that it doesn't error on startup (would loop forever without a question)
# We can't easily test the full loop, but we can verify the file is found
ERR=$(timeout 1 bash "$SKILL_DIR/scripts/master-poll.sh" "$T" "worker-1" 2>&1 || true)
assert_not_contains "$ERR" "ERROR" "master-poll finds per-worker comms file"

# ═══════════════════════════════════════════════════════════════════════════════
# 7. master-watch.sh — worker-id support
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "26. master-watch.sh — --help shows worker-id"
HELP=$(bash "$SKILL_DIR/scripts/master-watch.sh" --help 2>&1)
assert_contains "$HELP" "worker-id" "master-watch --help mentions worker-id"
bash "$SKILL_DIR/scripts/master-watch.sh" --help > /dev/null 2>&1
assert_eq "$?" "0" "master-watch --help exits 0"

echo ""
echo "27. master-watch.sh — errors on missing per-worker comms file"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
ERR=$(bash "$SKILL_DIR/scripts/master-watch.sh" "$T" "" "worker-999" 2>&1 || true)
assert_contains "$ERR" "ERROR" "master-watch errors on missing worker comms"

echo ""
echo "28. master-watch.sh — finds per-worker comms when present"
T=$(new_tmp)
write_worker_comms "$T" "worker-1" '{"status":"idle"}'
ERR=$(timeout 1 bash "$SKILL_DIR/scripts/master-watch.sh" "$T" "" "worker-1" 2>&1 || true)
assert_not_contains "$ERR" "ERROR" "master-watch finds per-worker comms file"
assert_contains "$ERR" "Master Watch" "master-watch starts watching"

# ═══════════════════════════════════════════════════════════════════════════════
# 8. Per-worker comms protocol — full round trip
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Per-worker comms — full round trip (idle → waiting → answered → done)"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms-worker-1.json"

# Init idle
echo '{"status":"idle"}' > "$COMMS"
assert_eq "$(read_status "$COMMS")" "idle" "per-worker starts idle"

# Worker asks
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [{'question': 'REST or GraphQL?','header': 'API','options': [{'label': 'REST'},{'label': 'GraphQL'}],'multiSelect': False}],
    'rec': 'A'
}, open('$COMMS', 'w'))
"
assert_eq "$(read_status "$COMMS")" "waiting" "per-worker waiting"

# Master answers
python3 -c "import json; json.dump({'status':'answered','answers':['A']}, open('$COMMS','w'))"
assert_eq "$(read_status "$COMMS")" "answered" "per-worker answered"

# Worker reads
ANSWER=$(python3 -c "import json; d=json.load(open('$COMMS')); print(d['answers'][0])" 2>/dev/null)
assert_eq "$ANSWER" "A" "per-worker answer read correctly"

# Worker done
python3 -c "import json; json.dump({'status':'done','summary':'Built REST API'}, open('$COMMS','w'))"
assert_eq "$(read_status "$COMMS")" "done" "per-worker done"

echo ""
echo "30. Per-worker comms — two workers independent state"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
COMMS1="$T/.autonomous/comms-worker-1.json"
COMMS2="$T/.autonomous/comms-worker-2.json"

echo '{"status":"idle"}' > "$COMMS1"
echo '{"status":"idle"}' > "$COMMS2"

# Worker 1 asks, worker 2 stays idle
python3 -c "
import json
json.dump({'status':'waiting','questions':[{'question':'Q1','header':'H','options':[],'multiSelect':False}],'rec':'A'}, open('$COMMS1','w'))
"
assert_eq "$(read_status "$COMMS1")" "waiting" "worker-1 is waiting"
assert_eq "$(read_status "$COMMS2")" "idle" "worker-2 still idle"

# Answer worker 1, worker 2 asks
python3 -c "import json; json.dump({'status':'answered','answers':['A']}, open('$COMMS1','w'))"
python3 -c "
import json
json.dump({'status':'waiting','questions':[{'question':'Q2','header':'H','options':[],'multiSelect':False}],'rec':'B'}, open('$COMMS2','w'))
"
assert_eq "$(read_status "$COMMS1")" "answered" "worker-1 answered"
assert_eq "$(read_status "$COMMS2")" "waiting" "worker-2 waiting independently"

echo ""
echo "31. Per-worker comms — comms.json unaffected by worker files"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"status":"idle"}' > "$T/.autonomous/comms.json"
write_worker_comms "$T" "worker-1" '{"status":"done","summary":"w1 done"}'

assert_eq "$(read_status "$T/.autonomous/comms.json")" "idle" "comms.json stays idle"
assert_eq "$(read_status "$T/.autonomous/comms-worker-1.json")" "done" "worker-1 is done"

# ═══════════════════════════════════════════════════════════════════════════════
# 9. Backward compatibility — old behaviors unchanged
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "32. Backward compat — dispatch.sh 3-arg form still works"
T=$(new_git_project)
mkdir -p "$T/.autonomous"
echo "prompt" > "$T/.autonomous/p.md"

MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

DISPATCH_OUT=$(TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/.autonomous/p.md" "worker" 2>&1)
assert_contains "$DISPATCH_OUT" "DISPATCH_MODE=" "3-arg dispatch still works"
assert_file_exists "$T/.autonomous/run-worker.sh" "wrapper still created"
assert_file_exists "$T/.autonomous/worker-windows.txt" "windows still registered"

echo ""
echo "33. Backward compat — monitor-worker.sh 2-arg form still works"
T=$(new_git_project)
write_comms "$T" '{"status":"done","summary":"Done"}'

FAKE_PID=99998
while kill -0 "$FAKE_PID" 2>/dev/null; do FAKE_PID=$((FAKE_PID + 1)); done

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" "worker" "$FAKE_PID" 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_DONE" "2-arg monitor still works"

echo ""
echo "34. Backward compat — write-summary.sh archives comms.json as before"
T=$(new_git_project)
write_comms "$T" '{"status":"done","summary":"Classic sprint done"}'

bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Test" 1 True 7 > /dev/null

assert_file_exists "$T/.autonomous/comms-archive/sprint-7.json" "classic comms.json archived"
ARCHIVED=$(python3 -c "import json; print(json.load(open('$T/.autonomous/comms-archive/sprint-7.json')).get('summary',''))" 2>/dev/null)
assert_eq "$ARCHIVED" "Classic sprint done" "classic archive content correct"

echo ""
echo "35. Backward compat — show-comms.sh still reads sprint-level archives"
OUTPUT=$(bash "$SKILL_DIR/scripts/show-comms.sh" "$T" 7)
assert_contains "$OUTPUT" "Classic sprint done" "show-comms reads classic archive"

# ═══════════════════════════════════════════════════════════════════════════════
# 10. Edge cases
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "36. Edge — worker-id with special chars (dashes, numbers)"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
write_worker_comms "$T" "worker-abc-123" '{"status":"idle"}'
assert_file_exists "$T/.autonomous/comms-worker-abc-123.json" "complex worker-id filename"
assert_eq "$(read_status "$T/.autonomous/comms-worker-abc-123.json")" "idle" "complex worker-id readable"

echo ""
echo "37. Edge — monitor --all with no worker comms files"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
# Only comms.json, no worker files. --all should loop (we timeout to test)
MONITOR_OUT=$(timeout 2 bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" --all 2>&1 || true)
# Should have timed out (exit 124) because no worker files have done/waiting
assert_not_contains "$MONITOR_OUT" "WORKER_DONE" "--all with no worker files doesn't falsely trigger"
assert_not_contains "$MONITOR_OUT" "WORKER_ASKING" "--all with no worker files doesn't falsely ask"

echo ""
echo "38. Edge — monitor --all with malformed worker comms"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"status":' > "$T/.autonomous/comms-worker-bad.json"
write_worker_comms "$T" "worker-good" '{"status":"done","summary":"ok"}'

MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" --all 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_DONE" "--all handles malformed + good worker files"
assert_contains "$MONITOR_OUT" "WORKER_ID=worker-good" "--all picks good worker despite bad one"

echo ""
echo "39. Edge — write-summary.sh handles mixed comms files"
T=$(new_git_project)
write_comms "$T" '{"status":"done","summary":"Master"}'
write_worker_comms "$T" "worker-1" '{"status":"done","summary":"W1"}'
# Also have a non-worker comms file that should not be archived as worker
echo '{"status":"idle"}' > "$T/.autonomous/comms-sprint.json"

bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Mixed" 1 True 9 > /dev/null

assert_file_exists "$T/.autonomous/comms-archive/sprint-9.json" "sprint-level archive"
assert_file_exists "$T/.autonomous/comms-archive/sprint-9-worker-1.json" "worker-1 archive"
# comms-sprint.json should NOT be archived (not comms-worker-* pattern)
assert_file_not_exists "$T/.autonomous/comms-archive/sprint-9-sprint.json" "non-worker comms not archived"

echo ""
echo "40. Edge — dispatch.sh creates .autonomous dir if needed for worker-id"
T=$(new_git_project)
# Don't create .autonomous — dispatch should handle it
echo "prompt" > "$T/p.md"

MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/p.md" "w1" "worker-1" 2>&1 > /dev/null

assert_file_exists "$T/.autonomous/comms-worker-1.json" "dispatch creates .autonomous for worker-id"

echo ""
echo "41. Edge — per-worker comms protocol with multiple questions"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
COMMS="$T/.autonomous/comms-worker-1.json"
python3 -c "
import json
json.dump({
    'status': 'waiting',
    'questions': [
        {'question':'Q1','header':'H1','options':[{'label':'Yes'}],'multiSelect':False},
        {'question':'Q2','header':'H2','options':[{'label':'No'}],'multiSelect':False}
    ],
    'rec':'A'
}, open('$COMMS','w'))
"
COUNT=$(python3 -c "import json; print(len(json.load(open('$COMMS'))['questions']))" 2>/dev/null)
assert_eq "$COUNT" "2" "per-worker multiple questions stored"

echo ""
echo "42. Edge — worker-id with just numbers"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
write_worker_comms "$T" "worker-42" '{"status":"done","summary":"numeric worker done"}'
assert_eq "$(read_status "$T/.autonomous/comms-worker-42.json")" "done" "numeric worker-id works"

echo ""
echo "43. Edge — archiving with multiple sprints"
T=$(new_git_project)
write_worker_comms "$T" "worker-1" '{"status":"done","summary":"S1W1"}'
bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Sprint 1" 1 True 1 > /dev/null

# New sprint, new worker comms
write_worker_comms "$T" "worker-1" '{"status":"done","summary":"S2W1"}'
write_worker_comms "$T" "worker-2" '{"status":"done","summary":"S2W2"}'
bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Sprint 2" 1 True 2 > /dev/null

assert_file_exists "$T/.autonomous/comms-archive/sprint-1-worker-1.json" "sprint 1 worker-1 archived"
assert_file_exists "$T/.autonomous/comms-archive/sprint-2-worker-1.json" "sprint 2 worker-1 archived"
assert_file_exists "$T/.autonomous/comms-archive/sprint-2-worker-2.json" "sprint 2 worker-2 archived"

S1W1=$(python3 -c "import json; print(json.load(open('$T/.autonomous/comms-archive/sprint-1-worker-1.json')).get('summary',''))" 2>/dev/null)
assert_eq "$S1W1" "S1W1" "sprint 1 worker-1 content correct"
S2W2=$(python3 -c "import json; print(json.load(open('$T/.autonomous/comms-archive/sprint-2-worker-2.json')).get('summary',''))" 2>/dev/null)
assert_eq "$S2W2" "S2W2" "sprint 2 worker-2 content correct"

# ═══════════════════════════════════════════════════════════════════════════════
# 11. SPRINT.md prompt template
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "44. SPRINT.md — mentions comms_file placeholder"
assert_file_contains "$SKILL_DIR/SPRINT.md" "{comms_file}" "SPRINT.md has comms_file placeholder"

echo ""
echo "45. SPRINT.md — mentions multi-worker dispatch"
assert_file_contains "$SKILL_DIR/SPRINT.md" "Multi-worker dispatch" "SPRINT.md documents multi-worker"

echo ""
echo "46. SPRINT.md — mentions worker-id in dispatch example"
assert_file_contains "$SKILL_DIR/SPRINT.md" "worker-1" "SPRINT.md shows worker-id example"

echo ""
echo "47. SPRINT.md — mentions --all in monitor example"
assert_file_contains "$SKILL_DIR/SPRINT.md" "\-\-all" "SPRINT.md shows --all example"

echo ""
echo "48. SPRINT.md — backward compat default path documented"
assert_file_contains "$SKILL_DIR/SPRINT.md" ".autonomous/comms.json" "SPRINT.md still shows default comms path"

# ═══════════════════════════════════════════════════════════════════════════════
# 12. Integration — dispatch + monitor + write-summary full cycle
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "49. Integration — full multi-worker cycle"
T=$(new_git_project)
mkdir -p "$T/.autonomous"
echo "worker prompt 1" > "$T/.autonomous/wp1.md"
echo "worker prompt 2" > "$T/.autonomous/wp2.md"

MOCK_DIR=$(new_mock_dir)
write_mock_claude "$MOCK_DIR"

# Dispatch two workers with IDs
TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/.autonomous/wp1.md" "w1" "worker-1" 2>&1 > /dev/null
TMUX="" PATH="$MOCK_DIR:$PATH" bash "$SKILL_DIR/scripts/dispatch.sh" \
  "$T" "$T/.autonomous/wp2.md" "w2" "worker-2" 2>&1 > /dev/null

# Verify both comms files initialized
assert_eq "$(read_status "$T/.autonomous/comms-worker-1.json")" "idle" "integration: w1 idle"
assert_eq "$(read_status "$T/.autonomous/comms-worker-2.json")" "idle" "integration: w2 idle"

# Simulate workers finishing
python3 -c "import json; json.dump({'status':'done','summary':'W1 built API'}, open('$T/.autonomous/comms-worker-1.json','w'))"
python3 -c "import json; json.dump({'status':'done','summary':'W2 added tests'}, open('$T/.autonomous/comms-worker-2.json','w'))"

# Monitor --all should detect a done worker
MONITOR_OUT=$(TMUX="" bash "$SKILL_DIR/scripts/monitor-worker.sh" "$T" --all 2>&1)
assert_contains "$MONITOR_OUT" "WORKER_DONE" "integration: monitor detects done"

# Write summary with sprint num archives everything
write_comms "$T" '{"status":"done","summary":"Sprint master done"}'
bash "$SKILL_DIR/scripts/write-summary.sh" "$T" "complete" "Full cycle test" 1 True 10 > /dev/null

assert_file_exists "$T/.autonomous/comms-archive/sprint-10.json" "integration: sprint archive"
assert_file_exists "$T/.autonomous/comms-archive/sprint-10-worker-1.json" "integration: w1 archive"
assert_file_exists "$T/.autonomous/comms-archive/sprint-10-worker-2.json" "integration: w2 archive"

# show-comms --list shows everything
LIST=$(bash "$SKILL_DIR/scripts/show-comms.sh" "$T" --list)
assert_contains "$LIST" "Sprint 10" "integration: --list shows sprint 10"
assert_contains "$LIST" "worker-1" "integration: --list shows worker-1"
assert_contains "$LIST" "worker-2" "integration: --list shows worker-2"

print_results
