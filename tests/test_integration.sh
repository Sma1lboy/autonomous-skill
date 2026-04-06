#!/usr/bin/env bash
# Integration tests for the autonomous-skill pipeline.
# Requires real claude CLI — gated by INTEGRATION_TEST=1.

set -euo pipefail

# ── Gate: skip unless explicitly enabled ──────────────────────────────────────
if [ "${INTEGRATION_TEST:-}" != "1" ]; then
  echo "SKIP: set INTEGRATION_TEST=1 to run integration tests"
  exit 0
fi

# Require real claude CLI (not the mock)
if ! command -v claude &>/dev/null; then
  echo "SKIP: real claude CLI not found in PATH"
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.sh"
MONITOR="$SCRIPT_DIR/../scripts/monitor-worker.sh"
WRITE_SUMMARY="$SCRIPT_DIR/../scripts/write-summary.sh"

# Determine timeout command (macOS uses gtimeout from coreutils)
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then TIMEOUT_CMD="timeout"; fi
if [ -z "$TIMEOUT_CMD" ] && command -v gtimeout &>/dev/null; then TIMEOUT_CMD="gtimeout"; fi

# Helper: run command with 60s timeout
run_with_timeout() {
  if [ -n "$TIMEOUT_CMD" ]; then
    $TIMEOUT_CMD 60 "$@"
  else
    "$@"
  fi
}

# Create a git-initialized temp project dir
new_git_project() {
  local d; d=$(new_tmp)
  (cd "$d" && git init -q && git commit -q --allow-empty -m "init")
  echo "$d"
}

# Cleanup: kill any integration test tmux windows on exit
_integ_cleanup() {
  if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
    for w in $(tmux list-windows -F '#{window_name}' 2>/dev/null | grep '^integ-' || true); do
      tmux kill-window -t "$w" 2>/dev/null || true
    done
  fi
}
trap '_integ_cleanup; cleanup' EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_integration.sh (real claude)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# A. Full dispatch -> monitor -> summary pipeline
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "A. Full dispatch -> monitor -> summary pipeline"

T=$(new_git_project)
mkdir -p "$T/.autonomous" && chmod 700 "$T/.autonomous"
echo '{"status":"idle"}' > "$T/.autonomous/comms.json"

# Write worker prompt
PROMPT_FILE="$T/.autonomous/worker-prompt.md"
cat > "$PROMPT_FILE" << 'PROMPT_EOF'
You are a worker. Execute these bash commands exactly:

1. Run: echo hello > test.txt
2. Run: git add test.txt
3. Run: git commit -m "test commit"
4. Run: python3 -c "import json; json.dump({'status':'done','summary':'created test.txt'}, open('.autonomous/comms.json','w'))"

Do not ask questions. Do not explain. Just run those 4 commands.
PROMPT_EOF

# Dispatch
run_with_timeout bash "$DISPATCH" "$T" "$PROMPT_FILE" "integ-pipeline" 2>&1 || true

# Monitor for completion
MONITOR_MAX_POLLS=30 run_with_timeout bash "$MONITOR" "$T" "integ-pipeline" 2>&1 || true

# Verify: test.txt exists
if [ -f "$T/test.txt" ]; then
  ok "A: test.txt created by worker"
else
  fail "A: test.txt created by worker"
fi

# Verify: git log shows the commit
COMMITS=$(cd "$T" && git log --oneline 2>/dev/null || echo "")
if echo "$COMMITS" | grep -q "test commit"; then
  ok "A: git log contains 'test commit'"
else
  fail "A: git log contains 'test commit' — got: $COMMITS"
fi

# Write summary
run_with_timeout bash "$WRITE_SUMMARY" "$T" "complete" "integration test" 2>&1 || true

# Verify: sprint-summary.json exists and is valid JSON
if [ -f "$T/.autonomous/sprint-summary.json" ]; then
  ok "A: sprint-summary.json exists"
else
  fail "A: sprint-summary.json exists"
fi

VALID_JSON=$(python3 -c "
import json
d = json.load(open('$T/.autonomous/sprint-summary.json'))
assert 'status' in d
assert 'commits' in d
assert 'summary' in d
print('ok')
" 2>/dev/null || echo "fail")
assert_eq "$VALID_JSON" "ok" "A: sprint-summary.json has status, commits, summary fields"

# ═══════════════════════════════════════════════════════════════════════════
# B. Comms protocol end-to-end
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "B. Comms protocol end-to-end"

T2=$(new_git_project)
mkdir -p "$T2/.autonomous" && chmod 700 "$T2/.autonomous"
echo '{"status":"idle"}' > "$T2/.autonomous/comms.json"

# Write worker prompt that asks a question, waits for answer, uses it
PROMPT2="$T2/.autonomous/worker-prompt.md"
cat > "$PROMPT2" << 'PROMPT_EOF'
You are a worker. Execute these steps exactly:

Step 1: Write a question to comms.json by running:
python3 -c "import json; json.dump({'status':'waiting','questions':[{'question':'What color?','options':[{'label':'red'},{'label':'blue'}]}]}, open('.autonomous/comms.json','w'))"

Step 2: Poll for the answer by running this python3 script:
python3 -c "
import json, time
for i in range(30):
    d = json.load(open('.autonomous/comms.json'))
    if d.get('status') == 'answered':
        answer = d['answers'][0]
        with open('answer.txt', 'w') as f:
            f.write(answer)
        break
    time.sleep(2)
"

Step 3: Write done to comms.json by running:
python3 -c "import json; json.dump({'status':'done','summary':'answered question'}, open('.autonomous/comms.json','w'))"

Do not ask questions via any other mechanism. Do not explain. Just run those 3 steps.
PROMPT_EOF

# Dispatch
run_with_timeout bash "$DISPATCH" "$T2" "$PROMPT2" "integ-comms" 2>&1 || true

# Monitor — should see WORKER_ASKING
MON_OUT=$(MONITOR_MAX_POLLS=30 run_with_timeout bash "$MONITOR" "$T2" "integ-comms" 2>&1 || true)
if echo "$MON_OUT" | grep -q "WORKER_ASKING"; then
  ok "B: monitor detected WORKER_ASKING"
else
  fail "B: monitor detected WORKER_ASKING — got: $(echo "$MON_OUT" | tail -3)"
fi

# Write answer
python3 -c "import json; json.dump({'status':'answered','answers':['blue']}, open('$T2/.autonomous/comms.json','w'))"

# Re-monitor — worker should complete
MON_OUT2=$(MONITOR_MAX_POLLS=30 run_with_timeout bash "$MONITOR" "$T2" "integ-comms" 2>&1 || true)
if echo "$MON_OUT2" | grep -q "WORKER_DONE"; then
  ok "B: monitor detected WORKER_DONE after answer"
else
  fail "B: monitor detected WORKER_DONE after answer — got: $(echo "$MON_OUT2" | tail -3)"
fi

# Verify answer.txt
if [ -f "$T2/answer.txt" ] && grep -q "blue" "$T2/answer.txt"; then
  ok "B: answer.txt contains 'blue'"
else
  fail "B: answer.txt contains 'blue' — file exists: $([ -f "$T2/answer.txt" ] && cat "$T2/answer.txt" || echo 'NO')"
fi

print_results
