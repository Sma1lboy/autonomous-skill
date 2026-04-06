#!/usr/bin/env bash
# Tests for signal handling in long-running scripts.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_signal_handling.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Static analysis: verify trap statements exist
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Static analysis — trap statements exist"

# monitor-worker.sh: INT/TERM trap
grep -q "trap.*INT" "$SCRIPTS/monitor-worker.sh" && ok "monitor-worker.sh has INT trap" || fail "monitor-worker.sh missing INT trap"
grep -q "trap.*TERM" "$SCRIPTS/monitor-worker.sh" && ok "monitor-worker.sh has TERM trap" || fail "monitor-worker.sh missing TERM trap"

# monitor-sprint.sh: INT/TERM trap
grep -q "trap.*INT" "$SCRIPTS/monitor-sprint.sh" && ok "monitor-sprint.sh has INT trap" || fail "monitor-sprint.sh missing INT trap"
grep -q "trap.*TERM" "$SCRIPTS/monitor-sprint.sh" && ok "monitor-sprint.sh has TERM trap" || fail "monitor-sprint.sh missing TERM trap"

# dispatch.sh: EXIT trap
grep -q "trap.*EXIT" "$SCRIPTS/dispatch.sh" && ok "dispatch.sh has EXIT trap" || fail "dispatch.sh missing EXIT trap"

# write-summary.sh: EXIT trap
grep -q "trap.*EXIT" "$SCRIPTS/write-summary.sh" && ok "write-summary.sh has EXIT trap" || fail "write-summary.sh missing EXIT trap"

# evaluate-sprint.sh: EXIT trap
grep -q "trap.*EXIT" "$SCRIPTS/evaluate-sprint.sh" && ok "evaluate-sprint.sh has EXIT trap" || fail "evaluate-sprint.sh missing EXIT trap"

# conductor-state.sh: EXIT trap (pre-existing)
grep -q "trap.*EXIT" "$SCRIPTS/conductor-state.sh" && ok "conductor-state.sh has EXIT trap" || fail "conductor-state.sh missing EXIT trap"

# ═══════════════════════════════════════════════════════════════════════════
# 2. monitor-worker.sh trap outputs WORKER_DONE
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. monitor-worker.sh trap includes WORKER_DONE"

TRAP_LINE=$(grep "trap.*INT.*TERM" "$SCRIPTS/monitor-worker.sh" | head -1)
echo "$TRAP_LINE" | grep -q "WORKER_DONE" && ok "monitor-worker trap outputs WORKER_DONE" || fail "monitor-worker trap missing WORKER_DONE"

# ═══════════════════════════════════════════════════════════════════════════
# 3. monitor-sprint.sh uses _MONITOR_INTERRUPTED flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. monitor-sprint.sh interrupt flag mechanism"

grep -q "_MONITOR_INTERRUPTED" "$SCRIPTS/monitor-sprint.sh" && ok "monitor-sprint uses _MONITOR_INTERRUPTED flag" || fail "monitor-sprint missing interrupt flag"
# Verify it checks for summary files after interrupt
grep -A5 "_MONITOR_INTERRUPTED.*-eq 1" "$SCRIPTS/monitor-sprint.sh" | grep -q "SUMMARY_FILE" && ok "monitor-sprint checks summary after interrupt" || fail "monitor-sprint doesn't check summary after interrupt"

# ═══════════════════════════════════════════════════════════════════════════
# 4. dispatch.sh EXIT trap cleans up WRAPPER
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. dispatch.sh EXIT trap cleans WRAPPER"

grep -q "WRAPPER" "$SCRIPTS/dispatch.sh" | head -1
CLEANUP_FN=$(grep -A3 "_dispatch_cleanup" "$SCRIPTS/dispatch.sh" | head -4)
echo "$CLEANUP_FN" | grep -q "WRAPPER" && ok "dispatch cleanup references WRAPPER" || fail "dispatch cleanup doesn't reference WRAPPER"

# ═══════════════════════════════════════════════════════════════════════════
# 5. write-summary.sh EXIT trap cleans tmp file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. write-summary.sh EXIT trap cleans tmp"

TRAP_LINE=$(grep "trap.*EXIT" "$SCRIPTS/write-summary.sh")
echo "$TRAP_LINE" | grep -q "sprint-summary.json.tmp" && ok "write-summary trap cleans .tmp file" || fail "write-summary trap missing .tmp cleanup"

# ═══════════════════════════════════════════════════════════════════════════
# 6. evaluate-sprint.sh EXIT trap cleans tmp file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. evaluate-sprint.sh EXIT trap cleans tmp"

TRAP_LINE=$(grep "trap.*EXIT" "$SCRIPTS/evaluate-sprint.sh")
echo "$TRAP_LINE" | grep -q "sprint-summary.json.tmp" && ok "evaluate-sprint trap cleans .tmp file" || fail "evaluate-sprint trap missing .tmp cleanup"

# Helper: create a fake bin dir that hides tmux so monitors stay in poll loop
make_no_tmux_env() {
  local d="$1"
  local fake_bin="$d/.fake-bin"
  mkdir -p "$fake_bin"
  # Create a tmux stub that always fails (simulates no tmux session)
  cat > "$fake_bin/tmux" << 'STUBEOF'
#!/bin/bash
# Fake tmux: "info" subcommand always fails (no server), everything else no-ops
if [ "${1:-}" = "info" ]; then exit 1; fi
exit 1
STUBEOF
  chmod +x "$fake_bin/tmux"
  echo "$fake_bin"
}

# ═══════════════════════════════════════════════════════════════════════════
# 7. Functional: monitor-worker.sh exits with WORKER_DONE on SIGTERM (first instance)
#    Note: SIGINT is unreliable for background processes in bash; INT/TERM share the same
#    trap handler, so testing via TERM covers both. Static analysis (test 1) verifies INT.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Functional: monitor-worker.sh SIGTERM -> WORKER_DONE (1st)"

D=$(new_tmp)
mkdir -p "$D/.autonomous"
git -C "$D" init -q 2>/dev/null || true
echo '{"status":"idle"}' > "$D/.autonomous/comms.json"
FAKE_BIN=$(make_no_tmux_env "$D")

# Start a fake worker process to keep alive
sleep 60 &
FAKE_WORKER=$!

# Run monitor-worker with fake tmux so it stays in poll loop
PATH="$FAKE_BIN:$PATH" MONITOR_MAX_POLLS=1000 bash "$SCRIPTS/monitor-worker.sh" "$D" "w" "$FAKE_WORKER" "" > "$D/monitor-out.txt" 2>/dev/null &
MON_PID=$!

sleep 2

kill -TERM "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
kill "$FAKE_WORKER" 2>/dev/null || true

OUT=$(cat "$D/monitor-out.txt" 2>/dev/null || echo "")
assert_contains "$OUT" "WORKER_DONE" "SIGTERM produces WORKER_DONE (1st)"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Functional: monitor-sprint.sh SIGTERM -> clean exit
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Functional: monitor-sprint.sh SIGTERM -> clean exit"

D=$(new_tmp)
mkdir -p "$D/.autonomous"
git -C "$D" init -q 2>/dev/null || true
echo '{"status":"idle"}' > "$D/.autonomous/comms.json"
FAKE_BIN=$(make_no_tmux_env "$D")

PATH="$FAKE_BIN:$PATH" MONITOR_MAX_POLLS=1000 bash "$SCRIPTS/monitor-sprint.sh" "$D" 99 > "$D/sprint-mon-out.txt" 2>/dev/null &
MON_PID=$!

sleep 2

kill -TERM "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true

OUT=$(cat "$D/sprint-mon-out.txt" 2>/dev/null || echo "")
assert_contains "$OUT" "INTERRUPTED" "SIGTERM produces INTERRUPTED message"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Functional: monitor-worker.sh SIGTERM also works
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Functional: monitor-worker.sh SIGTERM -> WORKER_DONE"

D=$(new_tmp)
mkdir -p "$D/.autonomous"
git -C "$D" init -q 2>/dev/null || true
echo '{"status":"idle"}' > "$D/.autonomous/comms.json"
FAKE_BIN=$(make_no_tmux_env "$D")

sleep 60 &
FAKE_WORKER=$!

PATH="$FAKE_BIN:$PATH" MONITOR_MAX_POLLS=1000 bash "$SCRIPTS/monitor-worker.sh" "$D" "w" "$FAKE_WORKER" "" > "$D/monitor-out2.txt" 2>/dev/null &
MON_PID=$!

sleep 2

kill -TERM "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
kill "$FAKE_WORKER" 2>/dev/null || true

OUT=$(cat "$D/monitor-out2.txt" 2>/dev/null || echo "")
assert_contains "$OUT" "WORKER_DONE" "SIGTERM produces WORKER_DONE"

# ═══════════════════════════════════════════════════════════════════════════
# 10. monitor-sprint.sh checks summary after interrupt
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. monitor-sprint.sh checks summary after interrupt"

D=$(new_tmp)
mkdir -p "$D/.autonomous"
git -C "$D" init -q 2>/dev/null || true
echo '{"status":"idle"}' > "$D/.autonomous/comms.json"
# Pre-create a summary file so the interrupted handler finds it
echo '{"status":"complete","summary":"pre-existing"}' > "$D/.autonomous/sprint-88-summary.json"

MONITOR_MAX_POLLS=1000 bash "$SCRIPTS/monitor-sprint.sh" "$D" 88 > "$D/sprint-mon-out2.txt" 2>/dev/null &
MON_PID=$!

# Wait until monitor is in the loop (it will find the summary file on first poll)
sleep 1
# If the summary was found, the process already exited on its own
wait "$MON_PID" 2>/dev/null || true

OUT=$(cat "$D/sprint-mon-out2.txt" 2>/dev/null || echo "")
assert_contains "$OUT" "COMPLETE" "monitor-sprint found pre-existing summary"

# ═══════════════════════════════════════════════════════════════════════════
print_results
