---
name: autonomous-skill
description: Self-driving project agent. Runs in a loop, autonomously finding and fixing issues.
user-invocable: true
---

# Autonomous Skill — Self-Driving Project Agent

An autonomous agent that explores your project, finds issues, fixes them, and
creates git commits on a session branch. Runs until interrupted or budget exhausted.

## Usage

Invoke with `/autonomous-skill` in any git repository.

## Startup

```bash
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
# Resolve the skill directory
if [ ! -d "$SCRIPT_DIR/scripts" ]; then
  # Try common install locations
  for dir in ~/.claude/skills/autonomous-skill /Volumes/ssd/i/autonomous-skill; do
    if [ -d "$dir/scripts" ]; then
      SCRIPT_DIR="$dir"
      break
    fi
  done
fi
echo "SCRIPT_DIR: $SCRIPT_DIR"
ls "$SCRIPT_DIR/scripts/" 2>/dev/null || echo "ERROR: scripts directory not found at $SCRIPT_DIR/scripts/"
```

## Workflow

Run the autonomous loop on the current project directory:

```bash
bash "$SCRIPT_DIR/scripts/loop.sh" "$(pwd)"
```

The loop will:
1. Generate or load OWNER.md (your persona/preferences)
2. Discover tasks from TODOS.md, TODO comments, and GitHub issues
3. Create a session branch `auto/session-TIMESTAMP`
4. Iterate: pick task → invoke CC → verify → commit or rollback
5. Log progress and cost to `~/.autonomous-skill/projects/SLUG/autonomous-log.jsonl`

## Configuration

Environment variables:
- `MAX_ITERATIONS` — max iterations per session (default: 50)
- `CC_TIMEOUT` — timeout per CC invocation in seconds (default: 900)
- `REFRESH_INTERVAL` — re-discover tasks every N iterations (default: 5)

## Stopping

- Press Ctrl+C — finishes current task, then exits gracefully
- Create sentinel file: `touch ~/.autonomous-skill/projects/SLUG/.stop-autonomous`
- The loop exits automatically when all tasks are done or max iterations reached

## Output

After the session, review the work:
```bash
git log main..auto/session-TIMESTAMP --oneline
```

Merge if satisfied:
```bash
git checkout main && git merge auto/session-TIMESTAMP
```
