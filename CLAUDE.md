# autonomous-skill

Self-driving project agent for Claude Code. Runs in a continuous loop, autonomously
finding and fixing issues in any codebase.

## Architecture

- `SKILL.md` — Claude Code skill entry point
- `scripts/loop.sh` — Main autonomous loop (bash while-loop, spawns fresh CC per iteration)
- `scripts/discover.sh` — Task discovery from TODOS.md, TODO comments, GitHub issues
- `scripts/persona.sh` — OWNER.md auto-generation from git history + project docs
- `OWNER.md.template` — Template for manual persona configuration
- `TRACE.md` — Auto-maintained session history (commits, cost, duration per session)

## How it works

1. User invokes `/autonomous-skill` in a git repo
2. persona.sh generates OWNER.md if missing (from git log + CLAUDE.md + README.md)
3. discover.sh finds tasks (TODOS.md, code TODOs, GitHub issues)
4. loop.sh creates `auto/session-TIMESTAMP` branch and iterates:
   - Picks highest-priority task
   - Spawns `claude -p` with --permission-mode auto, --output-format json
   - Verifies result (runs tests if available)
   - Commits on success, rolls back on failure
   - 3-strike rule: skip task after 3 failures
5. Logs cost and progress to ~/.autonomous-skill/projects/SLUG/autonomous-log.jsonl
6. At session end, appends entry to TRACE.md with commits, cost, and duration

## Safety

- All changes on `auto/` branches (never main)
- --permission-mode auto (blocks dangerous operations)
- Excluded workflows: /ship, /land-and-deploy, /careful, /guard
- 15-minute timeout per CC invocation
- SIGINT + sentinel file for graceful shutdown
- 3-strike rule prevents infinite retry loops

## Testing

```bash
shellcheck scripts/*.sh
```
