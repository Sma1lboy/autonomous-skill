# autonomous-skill

Self-driving project agent for Claude Code. Runs in a continuous loop, autonomously
finding and fixing issues in any codebase.

## Architecture

- `SKILL.md` — Main autonomous skill entry point (master/owner role)
- `.claude/skills/test-worker/SKILL.md` — Test skill: spawns worker + auto-answering master for DiskClean pipeline
- `.claude/skills/clean-sandbox/SKILL.md` — Reset test sandbox
- `.claude/skills/clean-gstack/SKILL.md` — Delete gstack design doc archives
- `.claude/skills/capture-worker/SKILL.md` — Capture worker JSONL for inspection
- `scripts/loop.sh` — Main autonomous loop (bash while-loop, spawns fresh CC per iteration)
- `scripts/discover.sh` — Task discovery from TODOS.md, KANBAN.md, TODO comments, GitHub issues
- `scripts/report.sh` — Parse autonomous-log.jsonl into human-readable summary (or `--json`)
- `scripts/status.sh` — Quick session status dashboard (branch stats, cost, sentinel state; `--json`)
- `scripts/parallel.sh` — Worktree-based parallel execution (N workers per iteration)
- `scripts/persona.sh` — OWNER.md auto-generation from git history + project docs
- `OWNER.md.template` — Template for manual persona configuration
- `TRACE.md` — Auto-maintained session history (commits, cost, duration per session)
- `KANBAN.md` — Project board (Todo/Doing/Done), also used as task source by discover.sh

## How it works

1. User invokes `/autonomous-skill` in a git repo
2. persona.sh generates OWNER.md if missing (from git log + CLAUDE.md + README.md)
3. discover.sh finds tasks (TODOS.md, code TODOs, GitHub issues)
4. loop.sh creates `auto/session-TIMESTAMP` branch and iterates:
   - **Serial mode** (default): picks one task, spawns `claude -p`
   - **Parallel mode** (`--parallel N`): picks N tasks, creates N git worktrees,
     spawns N `claude -p` concurrently, cherry-picks results back to session branch
   - Verifies result (runs tests if available)
   - Commits on success, rolls back on failure
   - 3-strike rule: skip task after 3 failures
5. Logs cost and progress to ~/.autonomous-skill/projects/SLUG/autonomous-log.jsonl
6. At session end, appends entry to TRACE.md with commits, cost, and duration

## Comms Protocol

Workers use `{project}/.autonomous/comms.md` for interactive skill questions:
- Worker writes `STATUS: WAITING` + question → polls for answer
- Master writes `STATUS: ANSWERED` + answer → worker continues
- Replaces AskUserQuestion which is unavailable in subagent context
- Validated: 20+ rounds per session, cross-attention quality preserved

## Safety

- All changes on `auto/` branches (never main)
- --permission-mode auto (blocks dangerous operations)
- Excluded workflows: /ship, /land-and-deploy, /careful, /guard
- 15-minute timeout per CC invocation
- Session cost budget (`MAX_COST_USD` env var or `--max-cost` flag)
- SIGINT + sentinel file for graceful shutdown
- 3-strike rule prevents infinite retry loops

## Testing

```bash
bash tests/test_loop.sh     # 100+ integration tests (mock CC, no API calls)
shellcheck scripts/*.sh     # lint all shell scripts
```

Test harness uses `tests/claude` (mock CC binary) controlled by env vars:
- `MOCK_CLAUDE_COST` — reported cost per invocation
- `MOCK_CLAUDE_COMMIT=1` — make a git commit during the mock run
- `MOCK_CLAUDE_DELAY` — sleep N seconds (for timeout tests)
- `MOCK_CLAUDE_EXIT` — exit code to return
