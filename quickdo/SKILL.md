---
name: quickdo
description: Fast single-sprint execution. Skips the conductor, runs one sprint master directly via blocking claude -p. For quick tasks that don't need multi-sprint orchestration.
user-invocable: true
---

# Quick Do

Lightweight execution mode for the autonomous-skill pipeline.
Skips the conductor entirely — runs one sprint master as a blocking `claude -p`
call. The sprint master senses the project, dispatches a worker, handles comms,
and summarizes. One direction, one sprint, done.

## Startup

```bash
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
if [ ! -d "$SCRIPT_DIR/scripts" ]; then
  for dir in ~/.claude/skills/autonomous-skill /Volumes/ssd/i/auto-tool-workspace/autonomous-skill; do
    if [ -d "$dir/scripts" ]; then SCRIPT_DIR="$dir"; break; fi
  done
fi
python3 "$SCRIPT_DIR/scripts/persona.py" "$(pwd)" >/dev/null 2>&1
python3 "$SCRIPT_DIR/scripts/startup.py" "$(pwd)"
```

## Pre-flight

```bash
eval "$(python3 "$SCRIPT_DIR/scripts/parse-args.py" "$ARGS")"
```

## First Actions

When this skill starts, act immediately. No explanations, no summaries.

1. Run the Startup bash block
2. Run the Pre-flight bash block
3. If `_DIRECTION` is non-empty → confirm in one sentence, proceed to Execute
4. If `_DIRECTION` is empty → ask the user ONE question: "What should we work on?"
5. Once you have a direction → Execute

## Execute

Once you have a direction, run this sequence without stopping:

```bash
# 1. Create working branch
QUICKDO_BRANCH="auto/quickdo-$(date +%s)"
git checkout -b "$QUICKDO_BRANCH"

# 2. Force all dispatch calls to blocking mode (no tmux)
export DISPATCH_MODE=blocking

# 3. Build sprint prompt (reuses SPRINT.md template)
mkdir -p .autonomous
python3 "$SCRIPT_DIR/scripts/build-sprint-prompt.py" "$(pwd)" "$SCRIPT_DIR" "1" "$_DIRECTION" ""

# 4. Run sprint master — blocking, no tmux
TIMEOUT="${CC_TIMEOUT:-1800}"
timeout "$TIMEOUT" claude -p --dangerously-skip-permissions "$(cat .autonomous/sprint-prompt.md)" 2>&1 || true
```

Wait for the `claude -p` call to finish. It will block until the sprint master
completes (senses project, dispatches worker, monitors, summarizes).

## Report

After the sprint master finishes:

```bash
echo "=== QUICKDO RESULTS ==="
echo "Branch: $QUICKDO_BRANCH"
echo ""
echo "=== COMMITS ==="
git log main.."$QUICKDO_BRANCH" --oneline --no-merges 2>/dev/null || git log --oneline -10
echo ""
if [ -f .autonomous/sprint-summary.json ]; then
  echo "=== SUMMARY ==="
  cat .autonomous/sprint-summary.json
fi
```

Show the user:
- What branch their work is on
- The commits made
- The sprint summary (if generated)
- How to merge: `git checkout main && git merge <branch>`

If zero commits were made, say so — the task may not have required code changes.

## Boundaries

- Never invoke shipping or deployment workflows.
- Single sprint only — no retry loops, no phase transitions.
- If the sprint master times out (default 30 min), report what happened and stop.
