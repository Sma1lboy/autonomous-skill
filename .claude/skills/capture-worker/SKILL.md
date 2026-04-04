---
name: capture-worker
description: Capture a worker's execution JSONL into claude-code-viewer's auto-debug project for inspection
user-invocable: true
---

# Capture Worker

Copy a worker subagent's full execution log (JSONL) into the claude-code-viewer
auto-debug project, so you can inspect every tool call, thinking block, and
decision in the viewer UI.

The viewer groups sessions by the `cwd` field in the JSONL. We rewrite `cwd`
to `/auto-debug` so these sessions appear as a separate project in the viewer,
not mixed into the original project.

## Run

```bash
VIEWER_DATA="/Volumes/ssd/i/claude-code-viewer/history-data/projects"
PROJECT_DIR="$VIEWER_DATA/auto-debug"
mkdir -p "$PROJECT_DIR"

# Find recent worker sessions
echo "RECENT_WORKERS:"
find ~/.claude/projects/ -name "agent-*.jsonl" -mmin -180 2>/dev/null | while read f; do
  LINES=$(wc -l < "$f" | tr -d ' ')
  SIZE_KB=$(( $(wc -c < "$f" | tr -d ' ') / 1024 ))
  MOD=$(stat -f '%Sm' -t '%H:%M' "$f" 2>/dev/null || date -r "$f" '+%H:%M')
  echo "  [$MOD] ${LINES}L ${SIZE_KB}KB  $f"
done

# Show existing captures
echo "EXISTING_CAPTURES:"
for jsonl in "$PROJECT_DIR"/*.jsonl; do
  [ -f "$jsonl" ] || continue
  SID=$(basename "$jsonl" .jsonl)
  SLABEL=""
  [ -f "$PROJECT_DIR/$SID.label" ] && SLABEL="$(cat "$PROJECT_DIR/$SID.label")"
  SLINES=$(wc -l < "$jsonl" | tr -d ' ')
  echo "  ${SLINES}L  ${SLABEL:-$SID}"
done

echo "ARGS_VALUE=$ARGS"
```

## Behavior

**If ARGS is empty:** Show the list of recent workers and ask the user via
AskUserQuestion which one to capture. Present them as a numbered list.

**If ARGS is "all":** Capture all recent workers at once with auto-generated labels.

**If ARGS is provided:** Parse ARGS as `<path-or-number> [label]`.
- If it's a number, map to the Nth recent worker from the list.
- If it's a path, use it directly.
- If a label is provided after the path, use it. Otherwise generate one
  from the timestamp.

**Capture process:**

1. Generate a UUID for the session:
```bash
SESSION_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
```

2. Rewrite the JSONL for viewer compatibility:
   - `cwd` → `/auto-debug` (separate project in viewer)
   - `sessionId` → match the new filename UUID
   - `isSidechain` → `false` (viewer skips sidechain messages)
```bash
python3 -c "
import json, sys
new_sid = sys.argv[2]
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if 'cwd' in obj:
            obj['cwd'] = '/auto-debug'
        if 'sessionId' in obj:
            obj['sessionId'] = new_sid
        if 'isSidechain' in obj:
            obj['isSidechain'] = False
        print(json.dumps(obj))
    except:
        print(line)
" "$AGENT_JSONL" "$SESSION_ID" > "$PROJECT_DIR/$SESSION_ID.jsonl"
```

3. Copy sibling subagent files (also rewrite cwd):
```bash
PARENT_DIR=$(dirname "$AGENT_JSONL")
if ls "$PARENT_DIR"/agent-*.jsonl 1>/dev/null 2>&1; then
  mkdir -p "$PROJECT_DIR/$SESSION_ID"
  for sub in "$PARENT_DIR"/agent-*.jsonl; do
    SUB_NAME=$(basename "$sub")
    python3 -c "
import json, sys
new_sid = sys.argv[2]
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if 'cwd' in obj:
            obj['cwd'] = '/auto-debug'
        if 'sessionId' in obj:
            obj['sessionId'] = new_sid
        if 'isSidechain' in obj:
            obj['isSidechain'] = False
        print(json.dumps(obj))
    except:
        print(line)
" "$sub" "$SESSION_ID" > "$PROJECT_DIR/$SESSION_ID/$SUB_NAME"
  done
  cp "$PARENT_DIR"/agent-*.meta.json "$PROJECT_DIR/$SESSION_ID/" 2>/dev/null || true
fi
```

4. Save the label:
```bash
echo "$LABEL" > "$PROJECT_DIR/$SESSION_ID.label"
```

5. Report: session ID, line count, size, subagent count, and how to view it.

6. After capture, remind the user: "Restart the viewer (`pkill -f 'main.js.*3400'`
   then relaunch) to see the new sessions. The viewer only discovers new projects
   on startup."
