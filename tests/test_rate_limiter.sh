#!/usr/bin/env bash
# Tests for scripts/rate-limiter.sh — rate limit detection and backoff.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RATE_LIMITER="$SCRIPT_DIR/../scripts/rate-limiter.sh"
CONDUCTOR_STATE="$SCRIPT_DIR/../scripts/conductor-state.sh"
SESSION_REPORT="$SCRIPT_DIR/../scripts/session-report.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_rate_limiter.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. check — detect rate limit patterns
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. check — positive patterns"

bash "$RATE_LIMITER" check "HTTP 429 Too Many Requests" 2>/dev/null
assert_eq "$?" "0" "check detects 429"

bash "$RATE_LIMITER" check "rate_limit exceeded" 2>/dev/null
assert_eq "$?" "0" "check detects rate_limit"

bash "$RATE_LIMITER" check "server overloaded, retry later" 2>/dev/null
assert_eq "$?" "0" "check detects overloaded"

bash "$RATE_LIMITER" check "Rate limit reached" 2>/dev/null
assert_eq "$?" "0" "check detects Rate limit"

bash "$RATE_LIMITER" check "Too many requests, slow down" 2>/dev/null
assert_eq "$?" "0" "check detects Too many requests"

bash "$RATE_LIMITER" check "at capacity, please wait" 2>/dev/null
assert_eq "$?" "0" "check detects capacity"

echo ""
echo "2. check — negative patterns"

bash "$RATE_LIMITER" check "success" 2>/dev/null && FAIL_EXIT=0 || FAIL_EXIT=$?
assert_eq "$FAIL_EXIT" "1" "check rejects 'success'"

bash "$RATE_LIMITER" check "normal error message" 2>/dev/null && FAIL_EXIT=0 || FAIL_EXIT=$?
assert_eq "$FAIL_EXIT" "1" "check rejects normal error"

bash "$RATE_LIMITER" check "connection timeout" 2>/dev/null && FAIL_EXIT=0 || FAIL_EXIT=$?
assert_eq "$FAIL_EXIT" "1" "check rejects connection timeout"

bash "$RATE_LIMITER" check "file not found" 2>/dev/null && FAIL_EXIT=0 || FAIL_EXIT=$?
assert_eq "$FAIL_EXIT" "1" "check rejects file not found"

echo ""
echo "3. check — mixed content"

bash "$RATE_LIMITER" check "Error on line 12: 429 response" 2>/dev/null
assert_eq "$?" "0" "check finds 429 in mixed content"

bash "$RATE_LIMITER" check "WARNING: service at capacity, retrying" 2>/dev/null
assert_eq "$?" "0" "check finds capacity in mixed content"

# ═══════════════════════════════════════════════════════════════════════════
# 4. wait — backoff calculation (DRY_RUN to avoid sleeping)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. wait — backoff calculation"

TMP=$(new_tmp)
mkdir -p "$TMP/.autonomous"

OUT=$(DRY_RUN=1 bash "$RATE_LIMITER" wait "$TMP" 1 2>/dev/null)
assert_eq "$OUT" "30" "wait attempt 1 → 30s"

OUT=$(DRY_RUN=1 bash "$RATE_LIMITER" wait "$TMP" 2 2>/dev/null)
assert_eq "$OUT" "60" "wait attempt 2 → 60s"

OUT=$(DRY_RUN=1 bash "$RATE_LIMITER" wait "$TMP" 3 2>/dev/null)
assert_eq "$OUT" "120" "wait attempt 3 → 120s"

OUT=$(DRY_RUN=1 bash "$RATE_LIMITER" wait "$TMP" 4 2>/dev/null)
assert_eq "$OUT" "240" "wait attempt 4 → 240s"

OUT=$(DRY_RUN=1 bash "$RATE_LIMITER" wait "$TMP" 5 2>/dev/null)
assert_eq "$OUT" "300" "wait attempt 5 → 300s (capped)"

echo ""
echo "5. wait — max retries exceeded"

DRY_RUN=1 bash "$RATE_LIMITER" wait "$TMP" 6 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "wait attempt 6 exits 1 (max retries exceeded)"

DRY_RUN=1 bash "$RATE_LIMITER" wait "$TMP" 10 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "wait attempt 10 exits 1"

echo ""
echo "6. wait — default attempt"

OUT=$(DRY_RUN=1 bash "$RATE_LIMITER" wait "$TMP" 2>/dev/null)
assert_eq "$OUT" "30" "wait with no attempt_num defaults to 30s"

# ═══════════════════════════════════════════════════════════════════════════
# 7. record — creates rate_limits array
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. record — creates rate_limits array"

TMP2=$(new_tmp)
mkdir -p "$TMP2/.autonomous"
echo '{"phase":"directed","sprints":[]}' > "$TMP2/.autonomous/conductor-state.json"

OUT=$(bash "$RATE_LIMITER" record "$TMP2" "sprint-1 dispatch" 2>/dev/null)
assert_eq "$OUT" "recorded" "record returns 'recorded'"

assert_file_exists "$TMP2/.autonomous/conductor-state.json" "state file exists after record"

# Verify rate_limits array exists
CONTENTS=$(python3 -c "import json; d=json.load(open('$TMP2/.autonomous/conductor-state.json')); print(len(d.get('rate_limits',[])))")
assert_eq "$CONTENTS" "1" "rate_limits has 1 entry"

echo ""
echo "8. record — appends to existing"

bash "$RATE_LIMITER" record "$TMP2" "sprint-2 dispatch" 2>/dev/null
CONTENTS=$(python3 -c "import json; d=json.load(open('$TMP2/.autonomous/conductor-state.json')); print(len(d.get('rate_limits',[])))")
assert_eq "$CONTENTS" "2" "rate_limits has 2 entries after second record"

# Verify structure
HAS_TS=$(python3 -c "import json; d=json.load(open('$TMP2/.autonomous/conductor-state.json')); print('timestamp' in d['rate_limits'][0])")
assert_eq "$HAS_TS" "True" "rate_limit entry has timestamp"

HAS_CTX=$(python3 -c "import json; d=json.load(open('$TMP2/.autonomous/conductor-state.json')); print(d['rate_limits'][0]['context'])")
assert_eq "$HAS_CTX" "sprint-1 dispatch" "rate_limit entry has correct context"

HAS_ATT=$(python3 -c "import json; d=json.load(open('$TMP2/.autonomous/conductor-state.json')); print(d['rate_limits'][0]['attempt'])")
assert_eq "$HAS_ATT" "1" "first event attempt is 1"

echo ""
echo "9. record — attempt counter per context"

bash "$RATE_LIMITER" record "$TMP2" "sprint-1 dispatch" 2>/dev/null
ATT=$(python3 -c "import json; d=json.load(open('$TMP2/.autonomous/conductor-state.json')); print(d['rate_limits'][-1]['attempt'])")
assert_eq "$ATT" "2" "second event for same context has attempt=2"

echo ""
echo "10. record — preserves existing state"

PHASE=$(python3 -c "import json; d=json.load(open('$TMP2/.autonomous/conductor-state.json')); print(d.get('phase','missing'))")
assert_eq "$PHASE" "directed" "record preserves existing phase"

echo ""
echo "11. record — creates state file if missing"

TMP3=$(new_tmp)
bash "$RATE_LIMITER" record "$TMP3" "dispatch" 2>/dev/null
assert_file_exists "$TMP3/.autonomous/conductor-state.json" "record creates state file if missing"

CONTENTS=$(python3 -c "import json; d=json.load(open('$TMP3/.autonomous/conductor-state.json')); print(len(d.get('rate_limits',[])))")
assert_eq "$CONTENTS" "1" "new state file has rate_limits with 1 entry"

echo ""
echo "12. record — corrupt JSON recovery"

TMP4=$(new_tmp)
mkdir -p "$TMP4/.autonomous"
echo "not json at all" > "$TMP4/.autonomous/conductor-state.json"

bash "$RATE_LIMITER" record "$TMP4" "recovery test" 2>/dev/null
CONTENTS=$(python3 -c "import json; d=json.load(open('$TMP4/.autonomous/conductor-state.json')); print(len(d.get('rate_limits',[])))")
assert_eq "$CONTENTS" "1" "record recovers from corrupt JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 13. report — empty report
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. report — empty report"

TMP5=$(new_tmp)
mkdir -p "$TMP5/.autonomous"
echo '{"phase":"directed"}' > "$TMP5/.autonomous/conductor-state.json"

OUT=$(bash "$RATE_LIMITER" report "$TMP5" 2>/dev/null)
assert_contains "$OUT" "No rate limit events" "report with no events says so"

echo ""
echo "14. report — missing state file"

TMP6=$(new_tmp)
OUT=$(bash "$RATE_LIMITER" report "$TMP6" 2>/dev/null)
assert_contains "$OUT" "No rate limit events" "report with missing file says no events"

echo ""
echo "15. report — populated report"

OUT=$(bash "$RATE_LIMITER" report "$TMP2" 2>/dev/null)
assert_contains "$OUT" "Rate limits:" "populated report shows header"
assert_contains "$OUT" "events" "populated report shows event count"
assert_contains "$OUT" "First:" "populated report shows first timestamp"
assert_contains "$OUT" "Last:" "populated report shows last timestamp"
assert_contains "$OUT" "sprint-1 dispatch" "populated report shows context"

# ═══════════════════════════════════════════════════════════════════════════
# 16. conductor-state.sh rate-limit command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. conductor-state.sh rate-limit command"

TMP7=$(new_tmp)
bash "$CONDUCTOR_STATE" init "$TMP7" "test mission" 3 >/dev/null 2>&1

OUT=$(bash "$CONDUCTOR_STATE" rate-limit "$TMP7" "sprint-1" 2>/dev/null)
assert_eq "$OUT" "recorded" "conductor-state rate-limit returns recorded"

RL_COUNT=$(python3 -c "import json; d=json.load(open('$TMP7/.autonomous/conductor-state.json')); print(len(d.get('rate_limits',[])))")
assert_eq "$RL_COUNT" "1" "conductor-state rate-limit creates rate_limits"

bash "$CONDUCTOR_STATE" rate-limit "$TMP7" "sprint-2" 2>/dev/null
RL_COUNT=$(python3 -c "import json; d=json.load(open('$TMP7/.autonomous/conductor-state.json')); print(len(d.get('rate_limits',[])))")
assert_eq "$RL_COUNT" "2" "conductor-state rate-limit appends"

# ═══════════════════════════════════════════════════════════════════════════
# 17. session-report.sh integration — table mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. session-report.sh — rate limits in table mode"

TMP8=$(new_tmp)
mkdir -p "$TMP8/.autonomous"

# Initialize conductor state with rate limits
bash "$CONDUCTOR_STATE" init "$TMP8" "test rate limits" 3 >/dev/null 2>&1
bash "$CONDUCTOR_STATE" sprint-start "$TMP8" "do something" >/dev/null 2>&1
bash "$CONDUCTOR_STATE" sprint-end "$TMP8" "complete" "did something" '["abc123 test commit"]' "false" "" >/dev/null 2>&1
bash "$CONDUCTOR_STATE" rate-limit "$TMP8" "test-context" 2>/dev/null

# Create sprint summary file
python3 -c "
import json
d = {'status': 'complete', 'commits': ['abc123 test commit'], 'summary': 'did something'}
with open('$TMP8/.autonomous/sprint-1-summary.json', 'w') as f:
    json.dump(d, f)
"

OUT=$(bash "$SESSION_REPORT" "$TMP8" 2>/dev/null)
assert_contains "$OUT" "Rate limits:" "table mode shows rate limits line"
assert_contains "$OUT" "1 events" "table mode shows event count"

echo ""
echo "18. session-report.sh — no rate limits line when empty"

TMP9=$(new_tmp)
mkdir -p "$TMP9/.autonomous"
bash "$CONDUCTOR_STATE" init "$TMP9" "test no rate limits" 2 >/dev/null 2>&1
bash "$CONDUCTOR_STATE" sprint-start "$TMP9" "test" >/dev/null 2>&1
bash "$CONDUCTOR_STATE" sprint-end "$TMP9" "complete" "done" '["def456 commit"]' "false" "" >/dev/null 2>&1

python3 -c "
import json
d = {'status': 'complete', 'commits': ['def456 commit'], 'summary': 'done'}
with open('$TMP9/.autonomous/sprint-1-summary.json', 'w') as f:
    json.dump(d, f)
"

OUT=$(bash "$SESSION_REPORT" "$TMP9" 2>/dev/null)
assert_not_contains "$OUT" "Rate limits:" "table mode omits rate limits when none"

echo ""
echo "19. session-report.sh — JSON mode includes rate_limits"

OUT=$(bash "$SESSION_REPORT" "$TMP8" --json 2>/dev/null)
assert_contains "$OUT" "rate_limits" "JSON mode includes rate_limits key"

HAS_RL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('rate_limits',[])))" "$OUT")
assert_eq "$HAS_RL" "1" "JSON mode has 1 rate limit entry"

echo ""
echo "20. session-report.sh — JSON mode rate_limits empty array"

OUT=$(bash "$SESSION_REPORT" "$TMP9" --json 2>/dev/null)
HAS_RL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('rate_limits',[])))" "$OUT")
assert_eq "$HAS_RL" "0" "JSON mode has empty rate_limits when none"

# ═══════════════════════════════════════════════════════════════════════════
# 21. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. --help flag"

HELP=$(bash "$RATE_LIMITER" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
assert_contains "$HELP" "check" "--help mentions check"
assert_contains "$HELP" "wait" "--help mentions wait"
assert_contains "$HELP" "record" "--help mentions record"
assert_contains "$HELP" "report" "--help mentions report"

bash "$RATE_LIMITER" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

echo ""
echo "22. -h short flag"

bash "$RATE_LIMITER" -h >/dev/null 2>&1
assert_eq "$?" "0" "-h exits 0"

echo ""
echo "23. missing args"

bash "$RATE_LIMITER" 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "no command exits 1"

bash "$RATE_LIMITER" check 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "check with no text exits 1"

bash "$RATE_LIMITER" record "$TMP" 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "record with no context exits 1"

bash "$RATE_LIMITER" report 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "report with no dir exits 1"

echo ""
echo "24. unknown command"

bash "$RATE_LIMITER" foobar 2>/dev/null && EXIT=0 || EXIT=$?
assert_eq "$EXIT" "1" "unknown command exits 1"

# ═══════════════════════════════════════════════════════════════════════════
# 25. concurrent writes safety
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. concurrent writes"

TMP10=$(new_tmp)
mkdir -p "$TMP10/.autonomous"
echo '{"phase":"directed"}' > "$TMP10/.autonomous/conductor-state.json"

# Fire 3 records in parallel
bash "$RATE_LIMITER" record "$TMP10" "concurrent-1" 2>/dev/null &
bash "$RATE_LIMITER" record "$TMP10" "concurrent-2" 2>/dev/null &
bash "$RATE_LIMITER" record "$TMP10" "concurrent-3" 2>/dev/null &
wait

# At least the file should be valid JSON
python3 -c "import json; json.load(open('$TMP10/.autonomous/conductor-state.json'))" 2>/dev/null
assert_eq "$?" "0" "state file is valid JSON after concurrent writes"

# Should have at least 1 entry (race conditions may lose some)
COUNT=$(python3 -c "import json; d=json.load(open('$TMP10/.autonomous/conductor-state.json')); print(len(d.get('rate_limits',[])))")
assert_ge "$COUNT" "1" "at least 1 rate_limit recorded under concurrency"

print_results
