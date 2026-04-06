#!/usr/bin/env bash
# Tests for error handling hardening across shell scripts.
# Covers: corrupted JSON, missing CLI, atomic write safety, monitor timeouts,
#         mkdir-based locking, evaluate-sprint fallback.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
CONDUCTOR="$SCRIPTS/conductor-state.sh"
MONITOR_WORKER="$SCRIPTS/monitor-worker.sh"
MONITOR_SPRINT="$SCRIPTS/monitor-sprint.sh"
DISPATCH="$SCRIPTS/dispatch.sh"
EVALUATE="$SCRIPTS/evaluate-sprint.sh"
WRITE_SUMMARY="$SCRIPTS/write-summary.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_error_handling.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Corrupted JSON — monitor-worker.sh doesn't hang (single-worker mode)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. Corrupted JSON — monitor-worker.sh (single-worker mode)"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q

# Write truncated/corrupt JSON
echo '{"status":"wai' > "$T/.autonomous/comms.json"

# Run with MAX_POLLS=3 so it doesn't loop forever; no tmux, no PID
OUT=$(MONITOR_MAX_POLLS=3 bash "$MONITOR_WORKER" "$T" "nowindow" "" "" 2>&1)
assert_contains "$OUT" "WORKER" "monitor-worker exits on corrupt JSON (not infinite loop)"
# The warning goes to stderr but we captured both above
COMBINED=$(MONITOR_MAX_POLLS=3 bash "$MONITOR_WORKER" "$T" "nowindow" "" "" 2>&1)
assert_contains "$COMBINED" "CORRUPT\|TIMEOUT\|WORKER" "monitor-worker handles corrupt comms"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Corrupted JSON — monitor-worker.sh (--all mode)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Corrupted JSON — monitor-worker.sh (--all mode)"

T=$(new_tmp)
mkdir -p "$T/.autonomous"

echo '{"bad json' > "$T/.autonomous/comms-worker-w1.json"

OUT=$(MONITOR_MAX_POLLS=3 bash "$MONITOR_WORKER" "$T" "--all" 2>&1)
assert_contains "$OUT" "WORKER" "--all mode exits on corrupt JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Corrupted JSON — monitor-sprint.sh doesn't hang
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Corrupted JSON — monitor-sprint.sh"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q

# Write corrupt comms.json with a recent mtime (so _comms_changed_since_start triggers)
echo '{"broken' > "$T/.autonomous/comms.json"

# Need to make comms.json appear "changed" — sleep briefly so mtime differs
OUT=$(MONITOR_MAX_POLLS=3 bash "$MONITOR_SPRINT" "$T" "99" 2>&1)
assert_contains "$OUT" "SPRINT 99" "monitor-sprint exits on timeout/corrupt"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Monitor poll timeout — monitor-worker.sh
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Monitor poll timeout — monitor-worker.sh"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q

# Write idle comms — monitor should timeout after MAX_POLLS
echo '{"status":"idle"}' > "$T/.autonomous/comms.json"

OUT=$(MONITOR_MAX_POLLS=2 bash "$MONITOR_WORKER" "$T" "nowindow" "" "" 2>&1)
assert_contains "$OUT" "TIMEOUT" "monitor-worker times out after MAX_POLLS"
assert_contains "$OUT" "WORKER_DONE" "monitor-worker emits WORKER_DONE on timeout"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Monitor poll timeout — monitor-sprint.sh
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Monitor poll timeout — monitor-sprint.sh"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q

OUT=$(MONITOR_MAX_POLLS=2 bash "$MONITOR_SPRINT" "$T" "99" 2>&1)
assert_contains "$OUT" "TIMEOUT" "monitor-sprint times out after MAX_POLLS"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Missing claude CLI — dispatch.sh exits with error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Missing claude CLI — dispatch.sh"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "test prompt" > "$T/.autonomous/test-prompt.md"

# Hide claude from PATH
OUT=$(PATH="/usr/bin:/bin" bash "$DISPATCH" "$T" "$T/.autonomous/test-prompt.md" "testworker" 2>&1 || true)
assert_contains "$OUT" "claude CLI not found" "dispatch.sh errors when claude missing"

# Verify it exits non-zero
if PATH="/usr/bin:/bin" bash "$DISPATCH" "$T" "$T/.autonomous/test-prompt.md" "testworker" 2>/dev/null; then
  fail "dispatch.sh should exit non-zero when claude missing"
else
  ok "dispatch.sh exits non-zero when claude missing"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 7. Atomic write failure — conductor-state.sh
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Atomic write failure — conductor-state.sh"

T=$(new_tmp)
mkdir -p "$T/.autonomous" && chmod 700 "$T/.autonomous"

# Test that atomic_write detects empty write
# We can't easily simulate disk full, but we can test the function directly
# by sourcing the script's helper. Instead, test via the init command with
# a non-writable directory (python3 write_state will fail)
T2=$(new_tmp)
mkdir -p "$T2/.autonomous" && chmod 700 "$T2/.autonomous"
# Init should work normally
SESSION=$(bash "$CONDUCTOR" init "$T2" "test mission" 3 2>/dev/null)
assert_contains "$SESSION" "conductor-" "init works with writable dir"

# Make state dir read-only — write_state should fail
chmod 444 "$T2/.autonomous"
OUT=$(bash "$CONDUCTOR" sprint-start "$T2" "test" 2>&1 || true)
assert_contains "$OUT" "ERROR\|Permission denied\|Read-only" "conductor errors on non-writable dir"
chmod 700 "$T2/.autonomous"  # restore for cleanup

# ═══════════════════════════════════════════════════════════════════════════
# 8. Conductor lock is directory-based
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Conductor lock — directory-based"

# Note: lock/unlock commands run in subshells, so the EXIT trap cleans
# up the lock dir automatically. We verify the mechanism via stale lock
# behavior (test 9) and by checking that the code uses mkdir, not file.

T=$(new_tmp)
mkdir -p "$T/.autonomous" && chmod 700 "$T/.autonomous"

# Lock command should succeed
OUT=$(bash "$CONDUCTOR" lock "$T" 2>&1)
assert_contains "$OUT" "locked" "lock command succeeds"

# After subprocess exits, the cleanup trap removes the lock dir — expected
# Verify lock dir was cleaned up (EXIT trap ran correctly)
assert_file_not_exists "$T/.autonomous/conductor.lock/pid" "lock dir cleaned by EXIT trap"

# Verify the code uses mkdir-based locking by creating a directory lock
# and seeing if the lock command handles it (breaks stale dir lock)
mkdir -p "$T/.autonomous/conductor.lock"
echo "99999" > "$T/.autonomous/conductor.lock/pid"
# This should break the stale directory lock and re-acquire
OUT=$(bash "$CONDUCTOR" lock "$T" 2>&1)
assert_contains "$OUT" "locked" "handles existing directory lock (mkdir-based)"

# Verify that a FILE named conductor.lock causes lock to still work
# (init should handle both gracefully)
rm -rf "$T/.autonomous/conductor.lock"
touch "$T/.autonomous/conductor.lock"
# mkdir should fail on a file, but our code should handle it via stale cleanup
OUT=$(bash "$CONDUCTOR" lock "$T" 2>&1 || true)
# Either succeeds or reports a clear error — should not hang
assert_contains "$OUT" "locked\|ERROR" "handles file at lock path gracefully"
rm -f "$T/.autonomous/conductor.lock"

# Unlock when no lock exists should succeed silently
OUT=$(bash "$CONDUCTOR" unlock "$T" 2>&1)
assert_contains "$OUT" "unlocked" "unlock command succeeds even when no lock"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Lock contention — stale lock cleanup
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Lock contention — stale lock cleanup"

T=$(new_tmp)
mkdir -p "$T/.autonomous" && chmod 700 "$T/.autonomous"

# Create a stale lock with a dead PID
mkdir -p "$T/.autonomous/conductor.lock"
echo "99999" > "$T/.autonomous/conductor.lock/pid"

# Should succeed by breaking the stale lock
OUT=$(bash "$CONDUCTOR" lock "$T" 2>&1)
assert_contains "$OUT" "locked" "stale lock broken and re-acquired"

# Clean up
bash "$CONDUCTOR" unlock "$T" > /dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════════
# 10. evaluate-sprint.sh with corrupted summary JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. evaluate-sprint.sh — corrupted summary JSON"

T=$(new_tmp)
mkdir -p "$T/.autonomous" && chmod 700 "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q

# Init conductor state
bash "$CONDUCTOR" init "$T" "test" 3 > /dev/null 2>&1
bash "$CONDUCTOR" sprint-start "$T" "test direction" > /dev/null 2>&1

# Write corrupt summary
echo '{"status":"compl' > "$T/.autonomous/sprint-1-summary.json"

# evaluate-sprint should fall back gracefully
OUT=$(bash "$EVALUATE" "$T" "$SCRIPT_DIR/.." "1" "" 2>&1 || true)
assert_contains "$OUT" "STATUS=" "evaluate-sprint outputs STATUS on corrupt JSON"
assert_contains "$OUT" "PHASE=" "evaluate-sprint outputs PHASE on corrupt JSON"
# Should not contain raw python error
assert_not_contains "$OUT" "Traceback" "no python traceback on corrupt JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 11. evaluate-sprint.sh with valid summary JSON (baseline)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. evaluate-sprint.sh — valid summary JSON"

T=$(new_tmp)
mkdir -p "$T/.autonomous" && chmod 700 "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q

bash "$CONDUCTOR" init "$T" "test" 3 > /dev/null 2>&1
bash "$CONDUCTOR" sprint-start "$T" "test direction" > /dev/null 2>&1

# Write valid summary
python3 -c "
import json
json.dump({'status':'complete','summary':'Did stuff','commits':['abc123'],'direction_complete':True}, open('$T/.autonomous/sprint-1-summary.json','w'))
"

OUT=$(bash "$EVALUATE" "$T" "$SCRIPT_DIR/.." "1" "" 2>&1 || true)
assert_contains "$OUT" "STATUS=complete" "evaluate-sprint parses valid JSON correctly"
assert_contains "$OUT" "SUMMARY=Did stuff" "evaluate-sprint extracts summary"
assert_contains "$OUT" "DIR_COMPLETE=true" "evaluate-sprint extracts direction_complete"

# ═══════════════════════════════════════════════════════════════════════════
# 12. write-summary.sh fallback on python3 failure
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. write-summary.sh — fallback on python3 failure"

T=$(new_tmp)
mkdir -p "$T/.autonomous" && chmod 700 "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q

# Simulate python3 failure by using a bad ITERATIONS value that int() can't parse
OUT=$(bash "$WRITE_SUMMARY" "$T" "complete" "test summary" "not_a_number" "true" 2>&1 || true)
# Fallback summary should exist
assert_file_exists "$T/.autonomous/sprint-summary.json" "fallback summary written on python3 failure"
FALLBACK_STATUS=$(python3 -c "import json; print(json.load(open('$T/.autonomous/sprint-summary.json'))['status'])" 2>/dev/null || echo "")
assert_eq "$FALLBACK_STATUS" "blocked" "fallback summary has status=blocked"

# ═══════════════════════════════════════════════════════════════════════════
# 13. monitor-worker.sh _read_comms_status helper — valid JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. _read_comms_status helper — various inputs"

T=$(new_tmp)
mkdir -p "$T/.autonomous"

# Valid idle
echo '{"status":"idle"}' > "$T/.autonomous/test-comms.json"
# We test the helper indirectly via monitor behavior. For direct test,
# use a tiny wrapper.
STATUS=$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('status','idle'))
except (json.JSONDecodeError, ValueError, KeyError):
    print('CORRUPT')
" "$T/.autonomous/test-comms.json")
assert_eq "$STATUS" "idle" "helper reads idle correctly"

# Valid waiting
echo '{"status":"waiting","questions":[]}' > "$T/.autonomous/test-comms.json"
STATUS=$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('status','idle'))
except (json.JSONDecodeError, ValueError, KeyError):
    print('CORRUPT')
" "$T/.autonomous/test-comms.json")
assert_eq "$STATUS" "waiting" "helper reads waiting correctly"

# Truncated JSON
echo '{"status":"wai' > "$T/.autonomous/test-comms.json"
STATUS=$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('status','idle'))
except (json.JSONDecodeError, ValueError, KeyError):
    print('CORRUPT')
" "$T/.autonomous/test-comms.json")
assert_eq "$STATUS" "CORRUPT" "helper detects truncated JSON"

# Empty file
true > "$T/.autonomous/test-comms.json"
STATUS=$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('status','idle'))
except (json.JSONDecodeError, ValueError, KeyError):
    print('CORRUPT')
" "$T/.autonomous/test-comms.json")
assert_eq "$STATUS" "CORRUPT" "helper detects empty file"

# Binary garbage
printf '\x00\x01\x02' > "$T/.autonomous/test-comms.json"
STATUS=$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('status','idle'))
except (json.JSONDecodeError, ValueError, KeyError):
    print('CORRUPT')
" "$T/.autonomous/test-comms.json")
assert_eq "$STATUS" "CORRUPT" "helper detects binary garbage"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Corrupt JSON with 3-strike escalation (monitor-worker single mode)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Corrupt JSON 3-strike escalation"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q

echo '{"broken' > "$T/.autonomous/comms.json"

# With MAX_POLLS high enough, the 3-strike corruption should trigger WORKER_ASKING
OUT=$(MONITOR_MAX_POLLS=10 bash "$MONITOR_WORKER" "$T" "nowindow" "" "" 2>&1)
assert_contains "$OUT" "CORRUPT JSON (3 consecutive)" "3-strike corruption detected"
assert_contains "$OUT" "WORKER_ASKING" "emits WORKER_ASKING on corruption escalation"

# ═══════════════════════════════════════════════════════════════════════════
# 15. dispatch.sh --help still works
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. dispatch.sh --help"

OUT=$(bash "$DISPATCH" --help 2>&1)
assert_contains "$OUT" "Usage:" "dispatch --help shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# 16. MONITOR_MAX_POLLS env var override
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. MONITOR_MAX_POLLS env var override"

T=$(new_tmp)
mkdir -p "$T/.autonomous"
cd "$T" && git init -q && git commit --allow-empty -m "init" -q
echo '{"status":"idle"}' > "$T/.autonomous/comms.json"

# MAX_POLLS=1 should timeout after 1 poll
OUT=$(MONITOR_MAX_POLLS=1 bash "$MONITOR_WORKER" "$T" "nowindow" "" "" 2>&1)
assert_contains "$OUT" "TIMEOUT" "MONITOR_MAX_POLLS=1 causes immediate timeout"

# ═══════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════

print_results
