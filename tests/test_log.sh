#!/usr/bin/env bash
# Tests for scripts/log.sh — structured logging library.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_LIB="$SCRIPT_DIR/../scripts/log.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_log.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: source log.sh in a subshell with a temp log file
run_log_cmd() {
  local log_file="$1"
  shift
  (
    source "$LOG_LIB"
    _LOG_FILE="$log_file"
    "$@"
  )
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. Basic log_info writes to file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. log_info writes to file"

D=$(new_tmp)
LOG="$D/test.log"
run_log_cmd "$LOG" log_info "hello world"
assert_file_exists "$LOG" "log file created"
assert_file_contains "$LOG" "hello world" "message in log"
assert_file_contains "$LOG" "INFO" "INFO level in log"

# ═══════════════════════════════════════════════════════════════════════════
# 2. log_warn writes to file and stderr
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. log_warn writes to file and stderr"

D=$(new_tmp)
LOG="$D/test.log"
STDERR_OUT=$(run_log_cmd "$LOG" log_warn "watch out" 2>&1 1>/dev/null)
assert_file_contains "$LOG" "WARN" "WARN level in log file"
assert_file_contains "$LOG" "watch out" "warn message in log file"
assert_contains "$STDERR_OUT" "WARN" "WARN echoed to stderr"
assert_contains "$STDERR_OUT" "watch out" "warn message echoed to stderr"

# ═══════════════════════════════════════════════════════════════════════════
# 3. log_error writes to file and stderr
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. log_error writes to file and stderr"

D=$(new_tmp)
LOG="$D/test.log"
STDERR_OUT=$(run_log_cmd "$LOG" log_error "something broke" 2>&1 1>/dev/null)
assert_file_contains "$LOG" "ERROR" "ERROR level in log file"
assert_file_contains "$LOG" "something broke" "error message in log file"
assert_contains "$STDERR_OUT" "ERROR" "ERROR echoed to stderr"
assert_contains "$STDERR_OUT" "something broke" "error message echoed to stderr"

# ═══════════════════════════════════════════════════════════════════════════
# 4. log_info does NOT write to stderr
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. log_info does not write to stderr"

D=$(new_tmp)
LOG="$D/test.log"
STDERR_OUT=$(run_log_cmd "$LOG" log_info "quiet info" 2>&1 1>/dev/null)
assert_eq "$STDERR_OUT" "" "log_info produces no stderr"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Timestamp format is ISO-8601
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Timestamp format"

D=$(new_tmp)
LOG="$D/test.log"
run_log_cmd "$LOG" log_info "timestamp test"
LINE=$(cat "$LOG")
# Match [YYYY-MM-DDTHH:MM:SSZ]
echo "$LINE" | grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' && ok "ISO-8601 timestamp format" || fail "ISO-8601 timestamp format — got: $LINE"

# ═══════════════════════════════════════════════════════════════════════════
# 6. LEVEL field is correct for each function
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. LEVEL field correctness"

D=$(new_tmp)
LOG="$D/test.log"
run_log_cmd "$LOG" log_info "i" 2>/dev/null
run_log_cmd "$LOG" log_warn "w" 2>/dev/null
run_log_cmd "$LOG" log_error "e" 2>/dev/null
assert_eq "$(sed -n '1p' "$LOG" | grep -o '\[INFO\]')" "[INFO]" "line 1 is INFO"
assert_eq "$(sed -n '2p' "$LOG" | grep -o '\[WARN\]')" "[WARN]" "line 2 is WARN"
assert_eq "$(sed -n '3p' "$LOG" | grep -o '\[ERROR\]')" "[ERROR]" "line 3 is ERROR"

# ═══════════════════════════════════════════════════════════════════════════
# 7. SCRIPT field shows caller name
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. SCRIPT field"

D=$(new_tmp)
LOG="$D/test.log"
# Create a script that sources log.sh and calls log_info
cat > "$D/my_script.sh" << 'SCRIPT_EOF'
#!/usr/bin/env bash
source "$1"
_LOG_FILE="$2"
log_info "from my script"
SCRIPT_EOF
bash "$D/my_script.sh" "$LOG_LIB" "$LOG"
assert_file_contains "$LOG" "[my_script.sh]" "SCRIPT field shows caller basename"

# ═══════════════════════════════════════════════════════════════════════════
# 8. log_init sets custom path via project dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. log_init with project dir"

D=$(new_tmp)
mkdir -p "$D/myproject/.autonomous"
(
  source "$LOG_LIB"
  log_init "$D/myproject"
  log_info "init test"
)
assert_file_exists "$D/myproject/.autonomous/session.log" "log_init creates session.log"
assert_file_contains "$D/myproject/.autonomous/session.log" "init test" "message logged via log_init path"

# ═══════════════════════════════════════════════════════════════════════════
# 9. log_init sets explicit .log file path
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. log_init with explicit .log path"

D=$(new_tmp)
(
  source "$LOG_LIB"
  log_init "$D/custom.log"
  log_info "custom path"
)
assert_file_exists "$D/custom.log" "explicit .log path created"
assert_file_contains "$D/custom.log" "custom path" "message in custom log"

# ═══════════════════════════════════════════════════════════════════════════
# 10. LOG_FILE env var override
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. LOG_FILE env var override"

D=$(new_tmp)
(
  export LOG_FILE="$D/env-override.log"
  source "$LOG_LIB"
  log_info "env var test"
)
assert_file_exists "$D/env-override.log" "LOG_FILE env var creates file"
assert_file_contains "$D/env-override.log" "env var test" "message in env var log"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Log file is created if parent dir doesn't exist
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. mkdir -p for parent dir"

D=$(new_tmp)
LOG="$D/deep/nested/dir/app.log"
run_log_cmd "$LOG" log_info "nested dir test"
assert_file_exists "$LOG" "nested parent dirs created"
assert_file_contains "$LOG" "nested dir test" "message in nested log"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Multiple log calls append (don't overwrite)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Append mode"

D=$(new_tmp)
LOG="$D/test.log"
run_log_cmd "$LOG" log_info "line one"
run_log_cmd "$LOG" log_info "line two"
run_log_cmd "$LOG" log_warn "line three" 2>/dev/null
LINE_COUNT=$(wc -l < "$LOG" | tr -d ' ')
assert_eq "$LINE_COUNT" "3" "three lines appended"
assert_file_contains "$LOG" "line one" "first line preserved"
assert_file_contains "$LOG" "line two" "second line preserved"
assert_file_contains "$LOG" "line three" "third line preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 13. No log file path — no crash
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. No log file — graceful no-op"

(
  source "$LOG_LIB"
  unset LOG_FILE
  _LOG_FILE=""
  log_info "should not crash" 2>/dev/null
) && ok "no crash with empty log path" || fail "crashed with empty log path"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Full format verification
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Full format: [TIMESTAMP] [LEVEL] [SCRIPT] message"

D=$(new_tmp)
LOG="$D/test.log"
run_log_cmd "$LOG" log_info "format check"
LINE=$(cat "$LOG")
# [YYYY-MM-DDTHH:MM:SSZ] [INFO] [something.sh] format check
echo "$LINE" | grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] \[INFO\] \[.+\] format check$' \
  && ok "full format matches pattern" || fail "full format mismatch — got: $LINE"

# ═══════════════════════════════════════════════════════════════════════════
# 15. log_init with empty arg is no-op
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. log_init empty arg"

D=$(new_tmp)
(
  source "$LOG_LIB"
  _LOG_FILE="$D/before.log"
  log_init ""
  # _LOG_FILE should still be the old value
  log_info "still works"
) 2>/dev/null
assert_file_exists "$D/before.log" "log_init '' preserves existing path"

# ═══════════════════════════════════════════════════════════════════════════
print_results
