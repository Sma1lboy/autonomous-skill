# autonomous-skill

Self-driving project agent for Claude Code. Runs in a continuous loop, autonomously
finding and fixing issues in any codebase.

## Architecture

Three-layer hierarchy: Conductor -> Sprint Master -> Worker.

```
Conductor (SKILL.md, user's CC session)
  |-- Plans sprint directions (directed phase or exploration phase)
  |-- Dispatches sprint master via claude -p in tmux (SPRINT.md inlined into prompt)
  |-- Evaluates sprint results, manages phase transitions
  |
  └── Sprint Master (SPRINT.md, separate claude -p session)
        |-- Sense -> Direct -> Respond -> Summarize loop
        |-- Dispatches workers via tmux / headless claude -p
        |-- Answers worker questions via comms.json protocol
        |
        └── Worker (full Claude session with all tools)
```

### Key Files

- `SKILL.md` — Conductor: multi-sprint orchestrator, phase management, exploration strategy
- `SPRINT.md` — Sprint master: per-sprint execution (Sense->Direct->Respond->Summarize)
- `scripts/conductor-state.sh` — Conductor state management (atomic writes, PID lock, phase transitions)
- `scripts/explore-scan.sh` — Project scanner: scores 8 exploration dimensions via bash heuristics
- `scripts/backlog.sh` — Cross-session persistent backlog (progressive disclosure, mkdir locking, max 50 items)
- `scripts/persona.sh` — OWNER.md auto-generation from git history + project docs
- `scripts/loop.sh` — Standalone launcher (outside CC's skill system)
- `scripts/master-poll.sh` — Manual master polling for comms.json
- `scripts/master-watch.sh` — Dual-channel monitor (comms + session JSONL)
- `.claude/skills/test-worker/SKILL.md` — Test skill: spawns worker + auto-answering master
- `.claude/skills/clean-sandbox/SKILL.md` — Reset test sandbox
- `.claude/skills/clean-gstack/SKILL.md` — Delete gstack design doc archives
- `.claude/skills/capture-worker/SKILL.md` — Capture worker JSONL for inspection
- `OWNER.md.template` — Template for manual persona configuration
- `tests/test_helpers.sh` — Shared test framework (assertions, temp dirs, result summary)
- `.claude/skills/diff-sessions/SKILL.md` — Compare two worker sessions side-by-side
- `skill-config.json` — Default template selector (overridden per-project at `.autonomous/skill-config.json`)
- `templates/gstack/template.md` — Worker slash-command set for the gstack toolchain
- `templates/default/template.md` — Generic worker guidance with no toolchain assumptions
- `scripts/build-sprint-prompt.sh` — Inlines SPRINT.md + template allow/block sections into the sprint master prompt

## How it works

1. User invokes `/autonomous-skill` in a git repo (e.g., `/autonomous-skill 5 build REST API`)
2. persona.sh generates OWNER.md if missing (from git log + CLAUDE.md + README.md)
3. Conductor (SKILL.md) talks to user to understand the mission (Discovery phase)
4. Conductor creates `auto/session-TIMESTAMP` branch and initializes conductor-state.json
5. **Conductor loop** (Plan -> Dispatch -> Monitor -> Evaluate -> Repeat):
   - **Directed phase**: breaks user's mission into sprint-sized tasks
   - Each sprint: `claude -p` runs SPRINT.md with a focused direction
   - Sprint master dispatches workers, answers questions via comms.json
   - Conductor reads sprint-summary.json, updates state, evaluates phase transition
   - **Phase transition**: when direction is complete (2 consecutive signals + commits,
     or max_directed_sprints reached, or 2 consecutive zero-commit sprints)
   - **Exploration phase**: picks weakest project dimension (test coverage, security,
     code quality, etc.) and generates exploration sprint directions
   - **Backlog fallback**: when exploration dimensions are all solid, conductor
     picks from the persistent backlog (`.autonomous/backlog.json`) before stopping
6. Session ends when all sprints used up, project feels solid, and backlog is empty

## Comms Protocol

Workers use `{project}/.autonomous/comms.json` for interactive skill questions:
- Worker writes `{"status":"waiting","questions":[...]}` -> polls for answer
- Master writes `{"status":"answered","answers":[...]}` -> worker continues
- Replaces AskUserQuestion which is unavailable in subagent context
- Valid statuses: "idle", "waiting", "answered", "done"
- Validated: 20+ rounds per session, cross-attention quality preserved

## Conductor State

The conductor tracks multi-sprint progress in `.autonomous/conductor-state.json`:
- Phase: "directed" (executing user's mission) or "exploring" (autonomous improvement)
- Sprint history: direction, status, commits, summary per sprint
- Phase transition decision tree (see SKILL.md)
- Exploration dimensions with audit status and scores
- Atomic writes (tmp+mv), PID lock for concurrency safety

## Backlog

Cross-session persistent work queue in `.autonomous/backlog.json`:
- Items have `title` (one-line, max 120 chars) and `description` (full detail)
- Progressive disclosure: sprint masters see titles only, conductor sees everything
- Workers write to backlog (fire-and-forget) but never read from it
- Worker items default to priority 4, `triaged: false`
- Conductor triages new items between sprints, picks from backlog when idle
- Max 50 open items; overflow force-prunes lowest priority
- `mkdir`-based atomic locking for concurrent writes (workers + conductor)
- Management: `scripts/backlog.sh` (init, add, list, read, pick, update, stats, prune)

## Templates

Sprint master worker-task suggestions and boundary blacklists are driven by
swappable templates, not hardcoded. Each template lives at
`templates/<name>/template.md` with two sections: `## Allow` (worker-task
examples) and `## Block` (commands the sprint master must never invoke).

Template selection hierarchy (first match wins):
1. `<project>/.autonomous/skill-config.json` — per-project override
2. `<skill_root>/skill-config.json` — global default (ships as `gstack`)
3. Fallback to `default` template if neither exists or requested template is missing

Config format: `{"template": "<name>"}`. Unknown names, malformed JSON, and
path-traversal attempts (`../`, dot-prefixes) all fall through to the default
template. `scripts/build-sprint-prompt.sh` resolves the template, extracts the
Allow/Block sections with python3, and substitutes them into the
`<!-- AUTO:TEMPLATE_ALLOW -->` / `<!-- AUTO:TEMPLATE_BLOCK -->` markers in
SPRINT.md as it writes `.autonomous/sprint-prompt.md`.

To add a new template: create `templates/<name>/template.md` with both sections,
then set `{"template":"<name>"}` in `skill-config.json` (or the project override).

## Safety

- All changes on `auto/` branches (never main)
- --permission-mode auto (blocks dangerous operations)
- Excluded workflows: configured per template (see `templates/<name>/template.md` `## Block` section)
- 15-minute timeout per CC invocation
- Session cost budget (`MAX_COST_USD` env var or `--max-cost` flag)
- SIGINT + sentinel file for graceful shutdown
- 3-strike rule prevents infinite retry loops

## Testing

```bash
bash tests/test_conductor.sh    # 99 tests: state management, phase transitions, exploration, stale cleanup, input validation, CLI help
bash tests/test_comms.sh        # 34 tests: comms.json protocol, master-watch/master-poll CLI help
bash tests/test_persona.sh      # 20 tests: OWNER.md generation, CLI help
bash tests/test_explore_scan.sh # 45 tests: 8-dimension scoring heuristics, edge cases, CLI help
bash tests/test_loop.sh         # 20 tests: standalone launcher args, env vars, persona, error handling, CLI help
bash tests/test_backlog.sh      # 76 tests: CRUD, progressive disclosure, pick, prune, overflow, concurrency, validation
bash tests/test_build_sprint_prompt.sh  # 25 tests: template resolution, allow/block injection, fallback, path-traversal guard
shellcheck scripts/*.sh         # lint all shell scripts
```

Test harness uses `tests/claude` (mock CC binary) controlled by env vars:
- `MOCK_CLAUDE_COST` — reported cost per invocation
- `MOCK_CLAUDE_COMMIT=1` — make a git commit during the mock run
- `MOCK_CLAUDE_DELAY` — sleep N seconds (for timeout tests)
- `MOCK_CLAUDE_EXIT` — exit code to return
