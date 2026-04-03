#!/usr/bin/env bash
# report.sh — Parse autonomous-log.jsonl into a human-readable summary.
# Usage: report.sh [project-dir] [--json]
set -euo pipefail

PROJECT_DIR="."
OUTPUT_JSON=0
USE_COLOR="auto"

for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT_JSON=1 ;;
    --color) USE_COLOR="always" ;;
    --no-color) USE_COLOR="never" ;;
    *) [ -d "$arg" ] && PROJECT_DIR="$arg" ;;
  esac
done

# ─── Color setup ─────────────────────────────────────────────────
if [ "$USE_COLOR" = "always" ] || { [ "$USE_COLOR" = "auto" ] && [ -t 1 ]; }; then
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_RESET=$'\033[0m'
else
  C_BOLD="" C_DIM="" C_GREEN="" C_RED="" C_YELLOW="" C_CYAN="" C_RESET=""
fi

SLUG=$(basename "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")")
DATA_DIR="${AUTONOMOUS_SKILL_HOME:-$HOME/.autonomous-skill}/projects/$SLUG"
LOG_FILE="$DATA_DIR/autonomous-log.jsonl"

if [ ! -f "$LOG_FILE" ]; then
  echo "[report] No log file found at $LOG_FILE" >&2
  exit 1
fi

# ─── Dependency check ─────────────────────────────────────────────
for dep in jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "[report] ERROR: $dep not found" >&2; exit 1; }
done

# ─── Parse log ────────────────────────────────────────────────────
# Normalize: old logs use "details", new logs use "detail"
ENTRIES=$(jq -c 'if .detail then . elif .details then .detail = .details | del(.details) else . end' "$LOG_FILE")

# ─── Aggregate by session ────────────────────────────────────────
# Build a JSON object keyed by session ID with aggregated stats
SESSIONS=$(echo "$ENTRIES" | jq -s '
  group_by(.session) | map({
    session: .[0].session,
    start_ts: (map(select(.event == "session_start")) | .[0].ts // null),
    end_ts: (map(select(.event == "session_end")) | .[0].ts // null),
    iterations: ([.[] | select(.event == "session_end") | .detail // "" |
      capture("iterations=(?<n>[0-9]+)") | .n | tonumber] | first //
      ([.[] | select(.event != "session_start" and .event != "session_end")] | length)),
    total_cost: (([.[].cost_usd] | map(select(. > 0)) | add // 0) * 10000 | round / 10000),
    commits: ([.[] | select(.event == "session_end") | .detail // "" |
      capture("commits=(?<n>[0-9]+)") | .n | tonumber] | first // 0),
    duration_s: ([.[] | select(.event == "session_end") | .detail // "" |
      capture("duration=(?<n>[0-9]+)s") | .n | tonumber] | first // null),
    successes: [.[] | select(.event == "success")] | length,
    failures: [.[] | select(.event == "failure")] | length,
    timeouts: [.[] | select(.event == "timeout")] | length,
    no_changes: [.[] | select(.event == "no_change")] | length,
    budget_hit: ([.[] | select(.event == "budget_exceeded")] | length > 0),
    events: [.[].event]
  })
')

# ─── Compute totals ──────────────────────────────────────────────
TOTALS=$(echo "$SESSIONS" | jq '{
  sessions: length,
  total_cost: ([.[].total_cost] | add // 0),
  total_commits: ([.[].commits] | add // 0),
  total_iterations: ([.[].iterations] | add // 0),
  total_successes: ([.[].successes] | add // 0),
  total_failures: ([.[].failures] | add // 0),
  total_timeouts: ([.[].timeouts] | add // 0),
  total_no_changes: ([.[].no_changes] | add // 0),
  total_duration_s: ([.[].duration_s | select(. != null)] | add // 0),
  budget_hits: ([.[] | select(.budget_hit)] | length),
  avg_cost_per_iter: (if ([.[].iterations] | add // 0) > 0
    then (([.[].total_cost] | add // 0) / ([.[].iterations] | add) * 10000 | round / 10000)
    else 0 end),
  avg_cost_per_commit: (if ([.[].commits] | add // 0) > 0
    then (([.[].total_cost] | add // 0) / ([.[].commits] | add) * 10000 | round / 10000)
    else 0 end)
}')

# ─── Top failure messages ─────────────────────────────────────────
TOP_FAILURES=$(echo "$ENTRIES" | jq -s '
  [.[] | select(.event == "failure") | .detail // "unknown"] |
  map(split(" — ") | .[0] // . | if type == "array" then join("") else . end) |
  map(gsub("^- \\[ \\] "; "")) |
  map(.[0:100]) |
  group_by(.) | map({msg: .[0], count: length}) |
  sort_by(-.count) | .[0:5]
')

# ─── JSON output ──────────────────────────────────────────────────
if [ "$OUTPUT_JSON" -eq 1 ]; then
  jq -n \
    --argjson totals "$TOTALS" \
    --argjson sessions "$SESSIONS" \
    --argjson top_failures "$TOP_FAILURES" \
    '{totals: $totals, sessions: $sessions, top_failures: $top_failures}'
  exit 0
fi

# ─── Human-readable output ────────────────────────────────────────
SESSION_COUNT=$(echo "$TOTALS" | jq '.sessions')
TOTAL_COST=$(echo "$TOTALS" | jq -r '.total_cost | . * 100 | round / 100')
TOTAL_COMMITS=$(echo "$TOTALS" | jq -r '.total_commits')
TOTAL_ITERS=$(echo "$TOTALS" | jq -r '.total_iterations')
TOTAL_SUCCESSES=$(echo "$TOTALS" | jq -r '.total_successes')
TOTAL_FAILURES=$(echo "$TOTALS" | jq -r '.total_failures')
TOTAL_TIMEOUTS=$(echo "$TOTALS" | jq -r '.total_timeouts')
BUDGET_HITS=$(echo "$TOTALS" | jq -r '.budget_hits')
TOTAL_DURATION_S=$(echo "$TOTALS" | jq -r '.total_duration_s')

# Success rate
if [ "$TOTAL_ITERS" -gt 0 ]; then
  SUCCESS_RATE=$(echo "scale=0; $TOTAL_SUCCESSES * 100 / $TOTAL_ITERS" | bc 2>/dev/null || echo "?")
else
  SUCCESS_RATE="N/A"
fi

# Cost per commit
if [ "$TOTAL_COMMITS" -gt 0 ]; then
  COST_PER_COMMIT=$(echo "scale=2; $TOTAL_COST / $TOTAL_COMMITS" | bc 2>/dev/null || echo "?")
  case "$COST_PER_COMMIT" in
    .*) COST_PER_COMMIT="0$COST_PER_COMMIT" ;;
  esac
else
  COST_PER_COMMIT="N/A"
fi

# Cost per iteration
if [ "$TOTAL_ITERS" -gt 0 ]; then
  COST_PER_ITER=$(echo "scale=2; $TOTAL_COST / $TOTAL_ITERS" | bc 2>/dev/null || echo "?")
  case "$COST_PER_ITER" in
    .*) COST_PER_ITER="0$COST_PER_ITER" ;;
  esac
else
  COST_PER_ITER="N/A"
fi

# Format total duration
if [ "$TOTAL_DURATION_S" -ge 3600 ] 2>/dev/null; then
  TOTAL_DUR_FMT="$((TOTAL_DURATION_S/3600))h $((TOTAL_DURATION_S%3600/60))m"
elif [ "$TOTAL_DURATION_S" -ge 60 ] 2>/dev/null; then
  TOTAL_DUR_FMT="$((TOTAL_DURATION_S/60))m $((TOTAL_DURATION_S%60))s"
elif [ "$TOTAL_DURATION_S" -gt 0 ] 2>/dev/null; then
  TOTAL_DUR_FMT="${TOTAL_DURATION_S}s"
else
  TOTAL_DUR_FMT="N/A"
fi

echo "${C_BOLD}═══════════════════════════════════════════════════"
echo "  AUTONOMOUS SKILL — SESSION REPORT"
echo "  Project: $SLUG"
echo "═══════════════════════════════════════════════════${C_RESET}"
echo ""
echo "  ${C_DIM}Sessions:${C_RESET}       $SESSION_COUNT"
echo "  ${C_DIM}Total cost:${C_RESET}     ${C_CYAN}\$$TOTAL_COST${C_RESET}"
echo "  ${C_DIM}Total commits:${C_RESET}  ${C_GREEN}$TOTAL_COMMITS${C_RESET}"
echo "  ${C_DIM}Total iters:${C_RESET}    $TOTAL_ITERS"
echo "  ${C_DIM}Total duration:${C_RESET} $TOTAL_DUR_FMT"
echo "  ${C_DIM}Success rate:${C_RESET}   ${C_GREEN}${SUCCESS_RATE}%${C_RESET}"
echo "  ${C_DIM}Cost/commit:${C_RESET}    ${C_CYAN}\$$COST_PER_COMMIT${C_RESET}"
echo "  ${C_DIM}Cost/iter:${C_RESET}      ${C_CYAN}\$$COST_PER_ITER${C_RESET}"
echo "  ${C_DIM}Timeouts:${C_RESET}       $TOTAL_TIMEOUTS"
echo "  ${C_DIM}Budget stops:${C_RESET}   $BUDGET_HITS"
echo ""

# ─── Per-session table ────────────────────────────────────────────
echo "${C_BOLD}─── Sessions ───────────────────────────────────────${C_RESET}"
printf "  ${C_DIM}%-12s  %-12s  %5s  %4s  %8s  %9s  %s${C_RESET}\n" "SESSION" "DATE" "ITERS" "CMTS" "DURATION" "COST" "STATUS"
printf "  ${C_DIM}%-12s  %-12s  %5s  %4s  %8s  %9s  %s${C_RESET}\n" "───────────" "──────────" "─────" "────" "────────" "─────────" "──────"

echo "$SESSIONS" | jq -r '.[] |
  .session as $s |
  (.start_ts // "?" | split("T")[0] // "?") as $date |
  (.iterations | tostring) as $iters |
  (.commits | tostring) as $cmts |
  (.duration_s // null) as $dur |
  (if $dur == null then "-"
   elif $dur >= 3600 then "\($dur / 3600 | floor)h \($dur % 3600 / 60 | floor)m"
   elif $dur >= 60 then "\($dur / 60 | floor)m \($dur % 60)s"
   else "\($dur)s" end) as $dur_fmt |
  (.total_cost | . * 100 | round / 100 | tostring | if . == "0" then "$0.00" else "$" + . end) as $cost |
  (if .budget_hit then "budget"
   elif .timeouts > 0 and .successes == 0 then "timeout"
   elif .failures > 0 and .successes == 0 then "failed"
   elif .successes > 0 then "ok"
   else "no-op" end) as $status |
  "\($s)\t\($date)\t\($iters)\t\($cmts)\t\($dur_fmt)\t\($cost)\t\($status)"
' | while IFS=$'\t' read -r session date iters cmts dur cost status; do
  case "$status" in
    ok)      status_fmt="${C_GREEN}$status${C_RESET}" ;;
    failed)  status_fmt="${C_RED}$status${C_RESET}" ;;
    timeout) status_fmt="${C_YELLOW}$status${C_RESET}" ;;
    budget)  status_fmt="${C_YELLOW}$status${C_RESET}" ;;
    *)       status_fmt="$status" ;;
  esac
  printf "  %-12s  %-12s  %5s  %4s  %8s  ${C_CYAN}%9s${C_RESET}  %s\n" "$session" "$date" "$iters" "$cmts" "$dur" "$cost" "$status_fmt"
done
echo ""

# ─── Top failures ─────────────────────────────────────────────────
FAILURE_COUNT=$(echo "$TOP_FAILURES" | jq 'length')
if [ "$FAILURE_COUNT" -gt 0 ]; then
  echo "${C_BOLD}─── Top Failures ───────────────────────────────────${C_RESET}"
  echo "$TOP_FAILURES" | jq -r '.[] | "  (\(.count)x) \(.msg)"' | while IFS= read -r line; do
    echo "  ${C_RED}$line${C_RESET}"
  done
  echo ""
fi

echo "${C_DIM}───────────────────────────────────────────────────"
echo "  Log: $LOG_FILE"
echo "  JSON: report.sh $PROJECT_DIR --json"
echo "───────────────────────────────────────────────────${C_RESET}"
