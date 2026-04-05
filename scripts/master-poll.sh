#!/usr/bin/env bash
# Master polling loop — runs in a separate terminal
# Usage: bash scripts/master-poll.sh /path/to/project
#
# Continuously polls .autonomous/comms.json for worker questions.
# When a question arrives, displays it and waits for master's answer.

set -euo pipefail

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

PROJECT="${1:-.}"
COMMS="$PROJECT/.autonomous/comms.json"

if [ ! -f "$COMMS" ]; then
  echo "ERROR: $COMMS not found" >&2
  exit 1
fi

trap 'echo ""; echo "  Stopped."; exit 0' INT TERM

echo "═══════════════════════════════════════"
echo " Master Poll — watching $COMMS"
echo " Ctrl+C to stop"
echo "═══════════════════════════════════════"
echo ""

while true; do
  # Wait for a question
  while true; do
    STATUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status','?'))" "$COMMS" 2>/dev/null)
    if [ "$STATUS" = "waiting" ]; then
      break
    fi
    sleep 2
  done

  # Display the question
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  python3 - "$COMMS" << 'DISPLAY'
import json, sys
d = json.load(open(sys.argv[1]))
for q in d.get('questions', []):
    print(f"  [{q.get('header','')}]")
    print(f"  {q['question'][:500]}")
    print()
    for i, o in enumerate(q.get('options', [])):
        label = o['label'] if isinstance(o, dict) else o
        print(f"    {chr(65+i)}) {label}")
print(f"\n  rec: {d.get('rec','—')}")
DISPLAY
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Get master's answer
  echo ""
  read -p "  Answer (letter + optional note): " ANSWER

  # Write answer (use sys.argv to avoid injection via quotes in ANSWER)
  python3 -c "
import json, sys
json.dump({'status':'answered','answers':[sys.argv[1]]}, open(sys.argv[2],'w'))
print('  → Answered. Polling...')
" "$ANSWER" "$COMMS"
done
