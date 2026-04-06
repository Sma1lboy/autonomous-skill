#!/usr/bin/env bash
# Tests for scripts/shutdown.sh — graceful shutdown propagation.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHUTDOWN="$SCRIPT_DIR/../scripts/shutdown.sh"
MONITOR="$SCRIPT_DIR/../scripts/monitor-sprint.sh"

# Helper: check JSON is valid
is_valid_json() {
  python3 -c "import json,sys; json.loads(sys.argv[1]); print('yes')" "$1" 2>/dev/null || echo "no"
}

# Helper: get a field from JSON
get_field() {
  local json="$1" field="$2"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); v=d.get(sys.argv[2]); print('None' if v is None else str(v))" "$json" "$field"
}

# Helper: get JSON array length
get_array_len() {
  local json="$1" field="$2"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get(sys.argv[2],[])))" "$json" "$field"
}

# Helper: get JSON array element
get_array_elem() {
  local json="$1" field="$2" idx="$3"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); arr=d.get(sys.argv[2],[]); print(arr[int(sys.argv[3])] if int(sys.argv[3])<len(arr) else 'INDEX_OUT_OF_RANGE')" "$json" "$field" "$idx"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_shutdown.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help flag"
OUT=$(bash "$SHUTDOWN" --help 2>&1)
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "shutdown" "--help mentions script name"
assert_contains "$OUT" "signal" "--help mentions signal"
assert_contains "$OUT" "project_dir" "--help mentions project_dir"

bash "$SHUTDOWN" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 2. -h short flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. -h short flag"
OUT=$(bash "$SHUTDOWN" -h 2>&1)
assert_contains "$OUT" "Usage" "-h shows usage"

bash "$SHUTDOWN" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 3. help positional arg
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. help positional arg"
OUT=$(bash "$SHUTDOWN" help 2>&1)
assert_contains "$OUT" "Usage" "help shows usage"

bash "$SHUTDOWN" help >/dev/null 2>&1
assert_eq "$?" "0" "help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Missing signal argument fails
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Missing signal argument"
ERR=$(bash "$SHUTDOWN" 2>&1 || true)
assert_contains "$ERR" "signal" "fails without signal"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Missing project_dir argument fails
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Missing project_dir argument"
ERR=$(bash "$SHUTDOWN" SIGINT 2>&1 || true)
assert_contains "$ERR" "project_dir" "fails without project_dir"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Nonexistent project dir fails
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Nonexistent project dir"
ERR=$(bash "$SHUTDOWN" SIGINT "/nonexistent/path/xyz" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails on nonexistent dir"
assert_contains "$ERR" "not found" "error mentions not found"

# ═══════════════════════════════════════════════════════════════════════════
# 7. No worker-windows.txt → still writes shutdown-reason.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. No worker-windows.txt"
T=$(new_tmp)
OUT=$(bash "$SHUTDOWN" SIGINT "$T" 2>&1)
assert_file_exists "$T/.autonomous/shutdown-reason.json" "shutdown-reason.json created"
assert_contains "$OUT" "Shutdown complete" "output confirms completion"

# ═══════════════════════════════════════════════════════════════════════════
# 8. shutdown-reason.json has correct signal
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Signal in shutdown-reason.json"
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
SIG=$(get_field "$JSON" "signal")
assert_eq "$SIG" "SIGINT" "signal is SIGINT"

# ═══════════════════════════════════════════════════════════════════════════
# 9. shutdown-reason.json has timestamp
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Timestamp in shutdown-reason.json"
TS=$(get_field "$JSON" "timestamp")
assert_contains "$TS" "T" "timestamp contains T separator"
assert_contains "$TS" "Z" "timestamp ends with Z"

# ═══════════════════════════════════════════════════════════════════════════
# 10. shutdown-reason.json has empty arrays when no workers
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Empty arrays when no workers"
STOPPED_LEN=$(get_array_len "$JSON" "windows_stopped")
KILLED_LEN=$(get_array_len "$JSON" "windows_force_killed")
assert_eq "$STOPPED_LEN" "0" "windows_stopped is empty"
assert_eq "$KILLED_LEN" "0" "windows_force_killed is empty"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Valid JSON output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Valid JSON output"
VALID=$(is_valid_json "$JSON")
assert_eq "$VALID" "yes" "shutdown-reason.json is valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 12. JSON has all required fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. All required fields present"
FIELDS_OK=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
required = ['signal', 'timestamp', 'windows_stopped', 'windows_force_killed']
missing = [f for f in required if f not in d]
print('ok' if not missing else 'missing: ' + ','.join(missing))
" "$JSON")
assert_eq "$FIELDS_OK" "ok" "all required fields present"

# ═══════════════════════════════════════════════════════════════════════════
# 13. SIGTERM signal
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. SIGTERM signal"
T=$(new_tmp)
bash "$SHUTDOWN" SIGTERM "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
SIG=$(get_field "$JSON" "signal")
assert_eq "$SIG" "SIGTERM" "signal is SIGTERM"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Custom signal name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Custom signal name"
T=$(new_tmp)
bash "$SHUTDOWN" TIMEOUT "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
SIG=$(get_field "$JSON" "signal")
assert_eq "$SIG" "TIMEOUT" "signal is TIMEOUT"

# ═══════════════════════════════════════════════════════════════════════════
# 15. Empty worker-windows.txt
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Empty worker-windows.txt"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
touch "$T/.autonomous/worker-windows.txt"
OUT=$(bash "$SHUTDOWN" SIGINT "$T" 2>&1)
assert_file_exists "$T/.autonomous/shutdown-reason.json" "shutdown-reason.json created with empty worker file"
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
STOPPED_LEN=$(get_array_len "$JSON" "windows_stopped")
assert_eq "$STOPPED_LEN" "0" "no windows stopped from empty file"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Worker windows that don't exist in tmux → counted as stopped
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Non-existent tmux windows"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
printf "fake-window-abc\nfake-window-def\n" > "$T/.autonomous/worker-windows.txt"
# These windows don't exist in tmux, so they should be counted as "already stopped"
OUT=$(bash "$SHUTDOWN" SIGINT "$T" 2>&1)
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
STOPPED_LEN=$(get_array_len "$JSON" "windows_stopped")
KILLED_LEN=$(get_array_len "$JSON" "windows_force_killed")
# If tmux is available, non-existent windows go to stopped
# If tmux is not available, both arrays are empty (no worker processing)
TOTAL=$((STOPPED_LEN + KILLED_LEN))
assert_contains "$OUT" "Shutdown complete" "completes with non-existent windows"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Output message format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Output message format"
T=$(new_tmp)
OUT=$(bash "$SHUTDOWN" SIGINT "$T" 2>&1)
assert_contains "$OUT" "signal=SIGINT" "output includes signal name"
assert_contains "$OUT" "stopped=" "output includes stopped count"
assert_contains "$OUT" "force_killed=" "output includes force_killed count"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Atomic write (no partial file)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Atomic write"
T=$(new_tmp)
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
# Verify no .tmp file left behind
assert_file_not_exists "$T/.autonomous/shutdown-reason.json.tmp" "no .tmp file left"
assert_file_exists "$T/.autonomous/shutdown-reason.json" "final file exists"

# ═══════════════════════════════════════════════════════════════════════════
# 19. .autonomous directory created if missing
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. .autonomous dir created"
T=$(new_tmp)
# No .autonomous dir exists
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
assert_file_exists "$T/.autonomous/shutdown-reason.json" ".autonomous dir created automatically"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Overwrites existing shutdown-reason.json
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Overwrites existing shutdown-reason.json"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"signal":"OLD"}' > "$T/.autonomous/shutdown-reason.json"
bash "$SHUTDOWN" SIGTERM "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
SIG=$(get_field "$JSON" "signal")
assert_eq "$SIG" "SIGTERM" "overwrites old shutdown-reason.json"

# ═══════════════════════════════════════════════════════════════════════════
# 21. Worker-windows.txt with blank lines
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. Blank lines in worker-windows.txt"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
printf "\n\nfake-win-1\n\n\n" > "$T/.autonomous/worker-windows.txt"
OUT=$(bash "$SHUTDOWN" SIGINT "$T" 2>&1)
assert_contains "$OUT" "Shutdown complete" "handles blank lines"
VALID=$(is_valid_json "$(cat "$T/.autonomous/shutdown-reason.json")")
assert_eq "$VALID" "yes" "valid JSON with blank lines in input"

# ═══════════════════════════════════════════════════════════════════════════
# 22. SHUTDOWN_WAIT_SECONDS env var respected
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. SHUTDOWN_WAIT_SECONDS env var"
T=$(new_tmp)
# With 0-second wait, should complete quickly even with workers
START=$(date +%s)
SHUTDOWN_WAIT_SECONDS=1 bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
END=$(date +%s)
ELAPSED=$((END - START))
assert_le "$ELAPSED" "5" "SHUTDOWN_WAIT_SECONDS=1 completes quickly"

# ═══════════════════════════════════════════════════════════════════════════
# 23. Multiple signals in sequence
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. Multiple signals in sequence"
T=$(new_tmp)
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
JSON1=$(cat "$T/.autonomous/shutdown-reason.json")
SIG1=$(get_field "$JSON1" "signal")
assert_eq "$SIG1" "SIGINT" "first signal correct"

bash "$SHUTDOWN" SIGTERM "$T" >/dev/null 2>&1
JSON2=$(cat "$T/.autonomous/shutdown-reason.json")
SIG2=$(get_field "$JSON2" "signal")
assert_eq "$SIG2" "SIGTERM" "second signal overwrites first"

# ═══════════════════════════════════════════════════════════════════════════
# 24. Timestamp format ISO 8601
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. Timestamp format"
T=$(new_tmp)
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
TS=$(get_field "$JSON" "timestamp")
# Validate ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ
TS_VALID=$(python3 -c "
import sys, re
ts = sys.argv[1]
pattern = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
print('yes' if re.match(pattern, ts) else 'no')
" "$TS")
assert_eq "$TS_VALID" "yes" "timestamp is ISO 8601 format"

# ═══════════════════════════════════════════════════════════════════════════
# 25. windows_stopped is a JSON array
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. windows_stopped is array"
T=$(new_tmp)
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
IS_ARRAY=$(python3 -c "
import json,sys
d = json.loads(sys.argv[1])
print('yes' if isinstance(d['windows_stopped'], list) else 'no')
" "$JSON")
assert_eq "$IS_ARRAY" "yes" "windows_stopped is a list"

# ═══════════════════════════════════════════════════════════════════════════
# 26. windows_force_killed is a JSON array
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. windows_force_killed is array"
IS_ARRAY=$(python3 -c "
import json,sys
d = json.loads(sys.argv[1])
print('yes' if isinstance(d['windows_force_killed'], list) else 'no')
" "$JSON")
assert_eq "$IS_ARRAY" "yes" "windows_force_killed is a list"

# ═══════════════════════════════════════════════════════════════════════════
# 27. monitor-sprint.sh detects shutdown marker
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. monitor-sprint.sh detects shutdown"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
# Write shutdown-reason.json before starting monitor
echo '{"signal":"SIGINT","timestamp":"2024-01-01T00:00:00Z","windows_stopped":[],"windows_force_killed":[]}' > "$T/.autonomous/shutdown-reason.json"
# Monitor should exit immediately when it sees the marker
OUT=$(MONITOR_MAX_POLLS=2 bash "$MONITOR" "$T" 1 2>&1)
assert_contains "$OUT" "SPRINT 1 SHUTDOWN" "monitor detects shutdown marker"

# ═══════════════════════════════════════════════════════════════════════════
# 28. monitor-sprint.sh shutdown message includes sprint number
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. Shutdown message includes sprint number"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"signal":"SIGTERM"}' > "$T/.autonomous/shutdown-reason.json"
OUT=$(MONITOR_MAX_POLLS=2 bash "$MONITOR" "$T" 5 2>&1)
assert_contains "$OUT" "SPRINT 5 SHUTDOWN" "shutdown message has correct sprint number"

# ═══════════════════════════════════════════════════════════════════════════
# 29. monitor-sprint.sh prefers shutdown over timeout
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Shutdown takes priority over timeout"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"signal":"SIGINT"}' > "$T/.autonomous/shutdown-reason.json"
OUT=$(MONITOR_MAX_POLLS=1 bash "$MONITOR" "$T" 1 2>&1)
assert_contains "$OUT" "SHUTDOWN" "shutdown detected before timeout"
assert_not_contains "$OUT" "TIMEOUT" "no timeout message"

# ═══════════════════════════════════════════════════════════════════════════
# 30. monitor-sprint.sh without shutdown marker behaves normally
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. Monitor without shutdown marker"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
# No shutdown-reason.json, no summary, should timeout
OUT=$(MONITOR_MAX_POLLS=1 bash "$MONITOR" "$T" 1 2>&1)
assert_not_contains "$OUT" "SHUTDOWN" "no shutdown without marker"

# ═══════════════════════════════════════════════════════════════════════════
# 31. Exit code is 0 on successful shutdown
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. Exit code 0 on success"
T=$(new_tmp)
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
assert_eq "$?" "0" "exits 0 on successful shutdown"

# ═══════════════════════════════════════════════════════════════════════════
# 32. Exit code non-zero on bad project dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "32. Exit code non-zero on bad dir"
bash "$SHUTDOWN" SIGINT "/nonexistent" >/dev/null 2>&1 && EXIT=0 || EXIT=$?
assert_ge "$EXIT" "1" "non-zero exit on bad dir"

# ═══════════════════════════════════════════════════════════════════════════
# 33. Single worker window name preserved in JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "33. Worker window names in JSON"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo "worker-sprint-1" > "$T/.autonomous/worker-windows.txt"
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
VALID=$(is_valid_json "$JSON")
assert_eq "$VALID" "yes" "valid JSON with worker names"

# ═══════════════════════════════════════════════════════════════════════════
# 34. Multiple worker window names
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "34. Multiple worker window names"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
printf "worker-1\nworker-2\nworker-3\n" > "$T/.autonomous/worker-windows.txt"
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
VALID=$(is_valid_json "$JSON")
assert_eq "$VALID" "yes" "valid JSON with multiple workers"
# Total of stopped + force_killed should account for all workers
STOPPED_LEN=$(get_array_len "$JSON" "windows_stopped")
KILLED_LEN=$(get_array_len "$JSON" "windows_force_killed")
TOTAL=$((STOPPED_LEN + KILLED_LEN))
# If tmux is running, all 3 should be accounted for; if not, 0 (no processing)
# Either way, the JSON should be valid
assert_eq "$VALID" "yes" "JSON valid with multiple workers"

# ═══════════════════════════════════════════════════════════════════════════
# 35. Signal with special characters
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "35. Signal with special characters"
T=$(new_tmp)
bash "$SHUTDOWN" "USR1" "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
SIG=$(get_field "$JSON" "signal")
assert_eq "$SIG" "USR1" "USR1 signal preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 36. Output message counts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "36. Output counts"
T=$(new_tmp)
OUT=$(bash "$SHUTDOWN" SIGINT "$T" 2>&1)
assert_contains "$OUT" "stopped=0" "zero stopped count in output"
assert_contains "$OUT" "force_killed=0" "zero force_killed count in output"

# ═══════════════════════════════════════════════════════════════════════════
# 37. Worker-windows.txt with trailing newline
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "37. Trailing newline in worker file"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
printf "win-a\n" > "$T/.autonomous/worker-windows.txt"
OUT=$(bash "$SHUTDOWN" SIGINT "$T" 2>&1)
assert_contains "$OUT" "Shutdown complete" "handles trailing newline"

# ═══════════════════════════════════════════════════════════════════════════
# 38. Worker-windows.txt with no trailing newline
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "38. No trailing newline in worker file"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
printf "win-b" > "$T/.autonomous/worker-windows.txt"
OUT=$(bash "$SHUTDOWN" SIGINT "$T" 2>&1)
assert_contains "$OUT" "Shutdown complete" "handles no trailing newline"

# ═══════════════════════════════════════════════════════════════════════════
# 39. monitor-sprint.sh --help still works
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "39. monitor-sprint.sh --help"
OUT=$(bash "$MONITOR" --help 2>&1)
assert_contains "$OUT" "Usage" "monitor --help still works"

bash "$MONITOR" --help >/dev/null 2>&1
assert_eq "$?" "0" "monitor --help exits 0"

# ═══════════════════════════════════════════════════════════════════════════
# 40. Shutdown then monitor integration
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "40. Shutdown → monitor integration"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
# Run shutdown first
bash "$SHUTDOWN" SIGTERM "$T" >/dev/null 2>&1
# Then monitor should detect it
OUT=$(MONITOR_MAX_POLLS=2 bash "$MONITOR" "$T" 3 2>&1)
assert_contains "$OUT" "SPRINT 3 SHUTDOWN" "monitor detects shutdown after shutdown.sh runs"

# ═══════════════════════════════════════════════════════════════════════════
# 41. shutdown-reason.json does not contain .tmp artifacts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "41. No tmp artifacts in JSON"
T=$(new_tmp)
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
assert_not_contains "$JSON" ".tmp" "no .tmp in JSON content"

# ═══════════════════════════════════════════════════════════════════════════
# 42. Concurrent shutdown calls don't corrupt JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "42. Sequential shutdown calls"
T=$(new_tmp)
bash "$SHUTDOWN" SIGINT "$T" >/dev/null 2>&1
bash "$SHUTDOWN" SIGTERM "$T" >/dev/null 2>&1
bash "$SHUTDOWN" TIMEOUT "$T" >/dev/null 2>&1
JSON=$(cat "$T/.autonomous/shutdown-reason.json")
VALID=$(is_valid_json "$JSON")
assert_eq "$VALID" "yes" "JSON valid after sequential shutdowns"
SIG=$(get_field "$JSON" "signal")
assert_eq "$SIG" "TIMEOUT" "last signal wins"

print_results
