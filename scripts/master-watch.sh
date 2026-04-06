#!/usr/bin/env bash
# Master watch — monitors both comms.json AND worker activity

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: master-watch.sh [project-dir] [worker-pid] [worker-id]

Dual-channel monitor for autonomous-skill workers. Watches both:
  1. comms.json — questions from the worker needing answers
  2. Worker session JSONL — tool calls, progress, errors

If worker-id is provided, monitors .autonomous/comms-{worker-id}.json
instead of comms.json for per-worker comms isolation.

Arguments:
  project-dir   Path to the project (default: current directory)
  worker-pid    PID of the worker process (optional, for liveness checks)
  worker-id     Worker identifier (optional; monitors per-worker comms file)

Requires: comms file must exist (worker must be running).
Press Ctrl+C to stop.
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

PROJECT="${1:-.}"
WORKER_PID="${2:-}"
WORKER_ID="${3:-}"

# Determine which comms file to watch
if [ -n "$WORKER_ID" ]; then
  COMMS="$PROJECT/.autonomous/comms-${WORKER_ID}.json"
else
  COMMS="$PROJECT/.autonomous/comms.json"
fi

if [ ! -f "$COMMS" ]; then
  echo "ERROR: $COMMS not found. Is the worker running?" >&2
  exit 1
fi

trap 'echo ""; echo "  Stopped."; exit 0' INT TERM

# Find worker session JSONL
find_session() {
  local slug
  slug=$(basename "$PROJECT")
  find ~/.claude/projects/ -path "*${slug}*" -name "*.jsonl" -not -name "agent-*" -mmin -60 2>/dev/null | sort -t/ -k1 | tail -1
}

LAST_LINES=0
LAST_STATUS="idle"
_CACHED_SESSION=""
_CACHE_TIME=0

echo "══════════════════════════════════════"
echo " Master Watch — $PROJECT"
[ -n "$WORKER_PID" ] && echo " Worker PID: $WORKER_PID"
[ -n "$WORKER_ID" ] && echo " Worker ID: $WORKER_ID"
echo " Ctrl+C to stop"
echo "══════════════════════════════════════"

while true; do
  # --- Channel 1: comms.json ---
  STATUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status','?'))" "$COMMS" 2>/dev/null || echo "?")

  if [ "$STATUS" = "waiting" ] && [ "$LAST_STATUS" != "waiting" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📩 QUESTION at $(date +%H:%M:%S)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    python3 - "$COMMS" << 'DISPLAY'
import json, sys
d = json.load(open(sys.argv[1]))
for q in d.get('questions', []):
    print(f"  [{q.get('header','')}]")
    print(f"  {q['question'][:400]}")
    for i, o in enumerate(q.get('options', [])):
        label = o['label'] if isinstance(o, dict) else o
        print(f"    {chr(65+i)}) {label}")
print(f"\n  rec: {d.get('rec','—')}")
DISPLAY
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  fi
  LAST_STATUS="$STATUS"

  # --- Channel 2: Worker session activity ---
  # Cache session path for 30s to avoid running find every 3s
  NOW=$(date +%s)
  if [ -z "$_CACHED_SESSION" ] || [ ! -f "$_CACHED_SESSION" ] || [ $((NOW - _CACHE_TIME)) -ge 30 ]; then
    _CACHED_SESSION=$(find_session)
    _CACHE_TIME=$NOW
  fi
  SESSION="$_CACHED_SESSION"
  if [ -n "$SESSION" ]; then
    LINES=$(wc -l < "$SESSION" | tr -d ' ')
    if [ "$LINES" -gt "$LAST_LINES" ]; then
      NEW=$((LINES - LAST_LINES))
      # Show latest tool calls
      python3 -c "
import json, sys
session_file = sys.argv[1]
tail_n = int(sys.argv[2])
with open(session_file) as f:
    lines = [l.strip() for l in f if l.strip()]
for line in lines[-tail_n:]:
    try:
        obj = json.loads(line)
        if obj.get('type') == 'assistant':
            for b in obj.get('message',{}).get('content',[]):
                if isinstance(b, dict) and b.get('type') == 'tool_use':
                    name = b.get('name','')
                    desc = b.get('input',{}).get('description','')
                    if name == 'Write':
                        fp = b.get('input',{}).get('file_path','')
                        print(f'  Write {fp.split(\"/\")[-1]}')
                    elif name == 'Bash':
                        print(f'  > {desc or b.get(\"input\",{}).get(\"command\",\"\")[:60]}')
                    elif name == 'Skill':
                        print(f'  /{b.get(\"input\",{}).get(\"skill\",\"?\")}')
                    elif name == 'Agent':
                        print(f'  Agent: {b.get(\"input\",{}).get(\"description\",\"\")}')
                    elif name in ('Read','Edit','Grep','Glob'):
                        pass  # too noisy
                    else:
                        print(f'  {name}')
    except Exception:
        pass
" "$SESSION" "$NEW" 2>/dev/null
      LAST_LINES=$LINES
    fi
  fi

  # --- Worker alive check ---
  if [ -n "$WORKER_PID" ]; then
    if ! ps -p "$WORKER_PID" > /dev/null 2>&1; then
      echo ""
      echo "  ⏹  Worker exited at $(date +%H:%M:%S)"
      break
    fi
  fi

  sleep 3
done
