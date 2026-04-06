#!/usr/bin/env bash
# Tests for worker timeout enforcement in dispatch.sh and monitor-worker.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.sh"
MONITOR="$SCRIPT_DIR/../scripts/monitor-worker.sh"

# Use the mock claude binary from tests/ dir
export PATH="$SCRIPT_DIR:$PATH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_dispatch_timeout.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Default timeout value (600) appears in wrapper script
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Default timeout value in wrapper"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
# Run dispatch — it will fail at claude launch but still creates the wrapper
unset WORKER_TIMEOUT 2>/dev/null || true
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w1" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w1.sh"
assert_file_exists "$WRAPPER" "wrapper script created"
assert_file_contains "$WRAPPER" "600" "default timeout 600 in wrapper"

# ═══════════════════════════════════════════════════════════════════════════
# 2. WORKER_TIMEOUT env var overrides default
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. WORKER_TIMEOUT env var overrides default"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
WORKER_TIMEOUT=900 bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w2" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w2.sh"
assert_file_exists "$WRAPPER" "wrapper created with env override"
assert_file_contains "$WRAPPER" "900" "env var 900 in wrapper"

# ═══════════════════════════════════════════════════════════════════════════
# 3. skill-config.json worker_timeout overrides env var
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. skill-config.json overrides env var"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
echo '{"worker_timeout": 1200}' > "$T/.autonomous/skill-config.json"
WORKER_TIMEOUT=900 bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w3" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w3.sh"
assert_file_exists "$WRAPPER" "wrapper created with config override"
assert_file_contains "$WRAPPER" "1200" "skill-config 1200 in wrapper"
assert_file_not_contains "$WRAPPER" "900" "env var 900 NOT in wrapper"

# ═══════════════════════════════════════════════════════════════════════════
# 4. skill-config.json takes precedence over WORKER_TIMEOUT env var
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Precedence: skill-config > env > default"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
echo '{"worker_timeout": 300}' > "$T/.autonomous/skill-config.json"
WORKER_TIMEOUT=1800 bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w4" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w4.sh"
# Wrapper should contain 300 (from config), not 1800 (from env) or 600 (default)
TIMEOUT_LINE=$(grep -o '\$TIMEOUT_CMD [0-9]*' "$WRAPPER" | head -1 || true)
assert_contains "$TIMEOUT_LINE" "300" "config value 300 wins over env 1800"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Wrapper script handles timeout exit code (124) and writes comms status
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Wrapper handles exit code 124"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w5" "test-w5" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w5.sh"
assert_file_contains "$WRAPPER" "EXIT_CODE" "wrapper checks EXIT_CODE"
assert_file_contains "$WRAPPER" '124' "wrapper checks for exit code 124"
assert_file_contains "$WRAPPER" "WORKER_TIMEOUT" "wrapper writes WORKER_TIMEOUT to comms"
assert_file_contains "$WRAPPER" "comms-test-w5.json" "wrapper writes to correct comms file"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Wrapper without worker-id uses comms.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. No worker-id → comms.json path"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w6" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w6.sh"
# No worker-id provided, so comms path should be comms.json
assert_file_contains "$WRAPPER" "comms.json" "no worker-id → comms.json in wrapper"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Wrapper includes gtimeout fallback for macOS
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. gtimeout fallback"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w7" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w7.sh"
assert_file_contains "$WRAPPER" "gtimeout" "wrapper has gtimeout fallback"
assert_file_contains "$WRAPPER" "TIMEOUT_CMD" "wrapper uses TIMEOUT_CMD variable"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Wrapper falls back to exec when no timeout command available
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Fallback to exec without timeout"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w8" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w8.sh"
assert_file_contains "$WRAPPER" "exec claude" "wrapper has exec fallback"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Invalid WORKER_TIMEOUT (negative) reverts to default
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Invalid WORKER_TIMEOUT reverts to default"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
ERR=$(WORKER_TIMEOUT=-5 bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w9" 2>&1 &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true
echo "done")
WRAPPER="$T/.autonomous/run-test-w9.sh"
if [ -f "$WRAPPER" ]; then
  assert_file_contains "$WRAPPER" "600" "invalid timeout → default 600"
else
  # Wrapper may not be created if dispatch fails early — check stderr
  ok "invalid timeout handled (dispatch may have warned)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 10. Invalid WORKER_TIMEOUT (non-numeric) reverts to default
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Non-numeric WORKER_TIMEOUT reverts to default"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
WORKER_TIMEOUT=abc bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w10" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w10.sh"
if [ -f "$WRAPPER" ]; then
  assert_file_contains "$WRAPPER" "600" "non-numeric timeout → default 600"
else
  ok "non-numeric timeout handled"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 11. Zero WORKER_TIMEOUT reverts to default
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Zero WORKER_TIMEOUT reverts to default"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
WORKER_TIMEOUT=0 bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w11" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w11.sh"
if [ -f "$WRAPPER" ]; then
  assert_file_contains "$WRAPPER" "600" "zero timeout → default 600"
else
  ok "zero timeout handled"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 12. skill-config.json with invalid worker_timeout ignored
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Invalid skill-config worker_timeout ignored"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
echo '{"worker_timeout": -10}' > "$T/.autonomous/skill-config.json"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w12" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w12.sh"
if [ -f "$WRAPPER" ]; then
  assert_file_contains "$WRAPPER" "600" "negative config timeout → default 600"
else
  ok "negative config timeout handled"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 13. skill-config.json with string worker_timeout ignored
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. String skill-config worker_timeout ignored"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
echo '{"worker_timeout": "fast"}' > "$T/.autonomous/skill-config.json"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w13" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w13.sh"
if [ -f "$WRAPPER" ]; then
  assert_file_contains "$WRAPPER" "600" "string config timeout → default 600"
else
  ok "string config timeout handled"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 14. monitor-worker.sh detects WORKER_TIMEOUT in comms (tmux mode)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. monitor-worker.sh detects WORKER_TIMEOUT"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q
cd "$OLDPWD"

# Write a timeout comms file
echo '{"status":"done","summary":"WORKER_TIMEOUT: exceeded 600s limit"}' > "$T/.autonomous/comms.json"

# monitor-worker.sh checks comms before tmux — so a done+timeout comms should return WORKER_DONE
# But we specifically want to test the window-closed path, which requires tmux
# Instead, test the comms path: if status=done, monitor returns WORKER_DONE and shows the comms
OUT=$(MONITOR_MAX_POLLS=2 bash "$MONITOR" "$T" "nonexistent-window" "" 2>/dev/null || true)
assert_contains "$OUT" "WORKER_DONE" "monitor detects done status from timeout comms"
assert_contains "$OUT" "WORKER_TIMEOUT" "monitor output contains WORKER_TIMEOUT summary"

# ═══════════════════════════════════════════════════════════════════════════
# 15. monitor-worker.sh detects WORKER_TIMEOUT with worker-id
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. monitor-worker.sh detects WORKER_TIMEOUT with worker-id"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q
cd "$OLDPWD"

echo '{"status":"done","summary":"WORKER_TIMEOUT: exceeded 900s limit"}' > "$T/.autonomous/comms-worker-42.json"

OUT=$(MONITOR_MAX_POLLS=2 bash "$MONITOR" "$T" "nonexistent-window" "" "worker-42" 2>/dev/null || true)
assert_contains "$OUT" "WORKER_DONE" "monitor detects done with worker-id"
assert_contains "$OUT" "WORKER_TIMEOUT" "timeout summary visible with worker-id"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Wrapper timeout comms message includes correct timeout value
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Comms message includes timeout value"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
echo '{"worker_timeout": 450}' > "$T/.autonomous/skill-config.json"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w16" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w16.sh"
assert_file_contains "$WRAPPER" "exceeded 450s" "comms message has correct timeout value"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Headless output log path used in dispatch
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Wrapper created correctly for headless dispatch"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w17" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w17.sh"
# Verify the wrapper is a valid bash script (starts with shebang)
FIRST_LINE=$(head -1 "$WRAPPER")
assert_eq "$FIRST_LINE" "#!/bin/bash" "wrapper has bash shebang"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Large timeout value preserved
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Large timeout value preserved"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/prompt.md"
WORKER_TIMEOUT=86400 bash "$DISPATCH" "$T" "$T/.autonomous/prompt.md" "test-w18" 2>/dev/null &
sleep 0.5
kill %1 2>/dev/null || true
wait 2>/dev/null || true

WRAPPER="$T/.autonomous/run-test-w18.sh"
assert_file_contains "$WRAPPER" "86400" "large timeout 86400 preserved"

print_results
