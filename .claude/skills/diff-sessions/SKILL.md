---
name: diff-sessions
description: Compare two worker sessions side-by-side in a local HTML diff page. Shows comms rounds, decisions, overrides, and quality metrics.
user-invocable: true
---

# Diff Sessions

Compare two worker session JSONLs side-by-side. Generates a local HTML page
showing structured diffs across every dimension that matters: skill invocations,
comms rounds, decisions, overrides, tool usage, and output metrics.

## Run

```bash
VIEWER_DATA="/Volumes/ssd/i/claude-code-viewer/history-data/projects"
PROJECT_DIR="$VIEWER_DATA/auto-debug"

echo "AVAILABLE_SESSIONS:"
for jsonl in "$PROJECT_DIR"/*.jsonl; do
  [ -f "$jsonl" ] || continue
  SID=$(basename "$jsonl" .jsonl)
  SLABEL=""
  [ -f "$PROJECT_DIR/$SID.label" ] && SLABEL="$(cat "$PROJECT_DIR/$SID.label")"
  SLINES=$(wc -l < "$jsonl" | tr -d ' ')
  SSIZE=$(( $(wc -c < "$jsonl" | tr -d ' ') / 1024 ))
  echo "  ${SLINES}L ${SSIZE}KB  ${SLABEL:-$SID}  [$SID]"
done

# Also find recent raw agent JSONLs
echo "RECENT_WORKERS:"
find ~/.claude/projects/ -name "agent-*.jsonl" -mmin -360 2>/dev/null | while read f; do
  LINES=$(wc -l < "$f" | tr -d ' ')
  SIZE_KB=$(( $(wc -c < "$f" | tr -d ' ') / 1024 ))
  MOD=$(stat -f '%Sm' -t '%H:%M' "$f" 2>/dev/null || date -r "$f" '+%H:%M')
  echo "  [$MOD] ${LINES}L ${SIZE_KB}KB  $f"
done

echo "ARGS_VALUE=$ARGS"
```

## Behavior

**If ARGS is empty:** Show available sessions and ask user to pick two.

**If ARGS has two paths/IDs:** Use them as session A (left) and session B (right).
Format: `<pathA> <pathB>` or `<labelA> <labelB>`.

## Parse Sessions

For each session JSONL, extract:

```python
# Parse one session into structured data
import json

def parse_session(jsonl_path):
    session = {
        "skills": [],          # skill invocations
        "tools": {},           # tool name -> count
        "comms_rounds": [],    # {question, options, recommendation, answer, context}
        "decisions": [],       # owner decisions from answers
        "overrides": [],       # where owner disagreed with worker recommendation
        "total_lines": 0,
        "total_tokens": 0,
        "duration_ms": 0,
        "texts": [],           # assistant text blocks (reasoning)
    }

    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                obj = json.loads(line)
                # ... extract data
            except:
                pass

    return session
```

Key extraction logic:

1. **Skills**: Find `tool_use` blocks with `name == "Skill"`, extract `input.skill`
2. **Tools**: Count all `tool_use` blocks by name
3. **Comms rounds**: Find `Write` calls targeting `comms.md` — parse the content
   for WAITING blocks (questions) and ANSWERED blocks (answers)
4. **Overrides**: Compare `## Worker Recommendation` with `## Answer` — if they
   differ, it's an override
5. **Texts**: Extract assistant text blocks for reasoning quality comparison
6. **Metrics**: Last line often has token/duration stats

## Generate HTML

Write a self-contained HTML file to `/tmp/session-diff.html`. Design:

- **Two-column layout**, session A on left, session B on right
- **Header**: session labels, file sizes, dates
- **Metrics bar**: side-by-side stats (skills called, tool uses, comms rounds,
  overrides, tokens, duration)
- **Timeline**: chronological list of events (skill invocations, comms rounds,
  tool calls) aligned by phase. Color-code:
  - Green: comms round completed (question asked + answered)
  - Yellow: question skipped (no comms, worker self-answered)  
  - Red: override (owner disagreed with worker)
  - Gray: tool calls
- **Comms diff**: For each comms round, show question + answer side by side.
  Highlight rounds that exist in one session but not the other.
- **Decision table**: All decisions with who made them (worker vs owner)
- **Quality signals**: Reasoning text length, push-back presence, cross-references
  to prior answers

**Style:**
- Dark theme, monospace font
- Sticky header with session labels
- Collapsible sections for each phase
- Diff highlighting (additions in green bg, removals in red bg)

## Open

```bash
open /tmp/session-diff.html
```

Report: "Diff generated. Opening in browser. Showing X comms rounds in A vs Y in B,
Z overrides in B. See /tmp/session-diff.html."
