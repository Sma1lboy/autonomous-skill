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

- `autonomous/SKILL.md` — Conductor: multi-sprint orchestrator, phase management, exploration strategy
- `SPRINT.md` — Sprint master: per-sprint execution (Sense->Direct->Respond->Summarize)
- `scripts/update-check.sh` — Version check: compares local VERSION against GitHub, 60-min cache
- `scripts/startup.py` — SCRIPT_DIR resolution + project context (shared by all layers)
- `scripts/parse-args.py` — Parse ARGS → _MAX_SPRINTS + _DIRECTION
- `scripts/session-init.py` — Create session branch, init conductor state + backlog
- `scripts/build-sprint-prompt.py` — Inline SPRINT.md + params → sprint-prompt.md
- `scripts/dispatch.py` — tmux/headless session dispatch; optionally deploys careful hook when `AUTONOMOUS_WORKER_CAREFUL=1`
- `scripts/hooks/careful.sh` — PreToolUse Bash hook; blocks catastrophic patterns (rm -rf /, mkfs, force-push to main, DROP TABLE, fork bombs)
- `scripts/monitor-sprint.py` — Poll for sprint-summary.json
- `scripts/monitor-worker.py` — Poll comms.json + tmux/process liveness
- `scripts/evaluate-sprint.py` — Read summary JSON, update conductor state
- `scripts/merge-sprint.py` — Merge or discard sprint branch
- `scripts/worktree.py` — Per-sprint git worktree manager (opt-in via `AUTONOMOUS_SPRINT_WORKTREES=1`): creates `.worktrees/sprint-N/` with symlinked `.autonomous/`, removes on success
- `scripts/write-summary.py` — Generate sprint-summary.json
- `scripts/conductor-state.py` — Conductor state management (atomic writes, PID lock, phase transitions; emits timeline events)
- `scripts/timeline.py` — Append-only JSONL session event log at `.autonomous/timeline.jsonl` (session-start, sprint-start, sprint-end, phase-transition, session-end)
- `scripts/explore-scan.py` — Project scanner: scores 8 exploration dimensions via heuristics
- `scripts/backlog.py` — Cross-session persistent backlog (progressive disclosure, mkdir locking, max 50 items)
- `scripts/user-config.py` — Global + project config (mode toggles, template, persona scope). Precedence: env > project > global > defaults. Drives first-time AskUserQuestion setup; persists to `~/.claude/autonomous/config.json` or `<project>/.autonomous/config.json`.
- `scripts/checkpoint.py` — Human-readable markdown snapshots of session state at `.autonomous/checkpoints/<ts>-<slug>.md` (save/list/latest/show)
- `scripts/persona.py` — OWNER.md auto-generation from git history + project docs
- `scripts/loop.py` — Standalone launcher (outside CC's skill system)
- `scripts/master-poll.py` — Manual master polling for comms.json
- `scripts/master-watch.py` — Dual-channel monitor (comms + session JSONL)
- `.claude/skills/test-worker/SKILL.md` — Test skill: spawns worker + auto-answering master
- `.claude/skills/clean-sandbox/SKILL.md` — Reset test sandbox
- `.claude/skills/clean-gstack/SKILL.md` — Delete gstack design doc archives
- `.claude/skills/capture-worker/SKILL.md` — Capture worker JSONL for inspection
- `.claude/skills/diff-sessions/SKILL.md` — Compare two worker sessions side-by-side
- `.claude/skills/smoke-test/SKILL.md` — Quick e2e pipeline smoke test (Conductor→Master→Worker→done)
- `quickdo/SKILL.md` — Fast single-sprint mode: skip conductor, blocking claude -p
- `OWNER.md.template` — Template for manual persona configuration
- `tests/test_helpers.sh` — Shared test framework (assertions, temp dirs, result summary)
- `.claude/skills/diff-sessions/SKILL.md` — Compare two worker sessions side-by-side
- `skill-config.json` — Default template selector (overridden per-project at `.autonomous/skill-config.json`)
- `templates/gstack/template.md` — Worker slash-command set for the gstack toolchain
- `templates/default/template.md` — Generic worker guidance with no toolchain assumptions
- `scripts/build-sprint-prompt.py` — Inlines SPRINT.md + template allow/block sections into the sprint master prompt
- `explore-ralph-loop/SKILL.md` — Explore Ralph Loop: detects toolchain, captures execute-verify-fix patterns as reusable skills
- `scripts/register-ralph-loops.sh` — Dynamic scanner: symlinks ralph-loop-skills/ to ~/.claude/skills/
- `ralph-loop-skills/` — Generated loop skills (gitignored, per-user)

## How it works

1. User invokes `/autonomous-skill` in a git repo (e.g., `/autonomous-skill 5 build REST API`)
2. persona.py generates OWNER.md if missing (from git log + CLAUDE.md + README.md)
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
6. **Session wrap-up**: conductor classifies all commits into Feature 1/2/3 groups
   using sprint directions, writes `.autonomous/session-summary.md` with a PR description
7. Session ends when all sprints used up, project feels solid, and backlog is empty

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
- Management: `scripts/backlog.py` (init, add, list, read, pick, update, stats, prune)

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
template. `scripts/build-sprint-prompt.py` resolves the template, extracts the
Allow/Block sections with Python, and substitutes them into the
`<!-- AUTO:TEMPLATE_ALLOW -->` / `<!-- AUTO:TEMPLATE_BLOCK -->` markers in
SPRINT.md as it writes `.autonomous/sprint-prompt.md`.

To add a new template: create `templates/<name>/template.md` with both sections,
then set `{"template":"<name>"}` in `skill-config.json` (or the project override).

## Safety

- All changes on `auto/session-*` branches (never main)
- Per-sprint branches: each sprint works on its own branch; merged on success, discarded on failure
- Workers run with `--dangerously-skip-permissions` but excluded from dangerous workflows
- Excluded workflows: /ship, /land-and-deploy, /careful, /guard
- 15-minute timeout per CC invocation (configurable via `CC_TIMEOUT`)
- All changes on `auto/` branches (never main)
- --permission-mode auto (blocks dangerous operations)
- Excluded workflows: configured per template (see `templates/<name>/template.md` `## Block` section)
- 15-minute timeout per CC invocation
- Session cost budget (`MAX_COST_USD` env var or `--max-cost` flag)
- SIGINT + sentinel file for graceful shutdown
- 3-strike rule prevents infinite retry loops
- Atomic state writes (tmp+mv), PID lock for concurrency safety

## Testing

688 tests across 13 suites, all pure bash:

```bash
bash tests/test_conductor.sh    # 99 tests: state management, phase transitions, exploration, stale cleanup, input validation, CLI help
bash tests/test_comms.sh        # 34 tests: comms.json protocol, master-watch/master-poll CLI help
bash tests/test_persona.sh      # 20 tests: OWNER.md generation, CLI help
bash tests/test_explore_scan.sh # 45 tests: 8-dimension scoring heuristics, edge cases, CLI help
bash tests/test_loop.sh         # 20 tests: standalone launcher args, env vars, persona, error handling, CLI help
bash tests/test_backlog.sh      # 76 tests: CRUD, progressive disclosure, pick, prune, overflow, concurrency, validation
bash tests/test_build_sprint_prompt.sh  # 25 tests: template resolution, allow/block injection, fallback, path-traversal guard
bash tests/test_eval_output.sh  # 35 tests: eval-safe output, shell quoting, tmux cleanup
bash tests/test_timeline.sh     # 63 tests: append-only JSONL log, filters, conductor integration, phase-transition emission, non-raising emit, bounded tail
bash tests/test_careful_hook.sh # 97 tests: PreToolUse hook pattern matching, adversarial bypasses, dispatch integration, window_name validation
bash tests/test_checkpoint.sh   # 70 tests: save/list/latest/show, path-traversal rejection, YAML injection resistance, type-unsafe JSON, non-UTF8
bash tests/test_worktree.sh     # 65 tests: per-sprint worktree CRUD, symlink escape refusal, branch validation, registered-worktree guard, merge-sprint --keep-branch
bash tests/test_user_config.sh  # 38 tests: config precedence (env > project > global > defaults), legacy migration, path validation, malformed config resilience
python3 -m compileall scripts   # quick syntax check
```

Test harness uses `tests/claude` (mock CC binary) controlled by env vars:
- `MOCK_CLAUDE_COST` — reported cost per invocation
- `MOCK_CLAUDE_COMMIT=1` — make a git commit during the mock run
- `MOCK_CLAUDE_DELAY` — sleep N seconds (for timeout tests)
- `MOCK_CLAUDE_EXIT` — exit code to return

## Development workflow

When contributing to this project, follow these rules:

### Branching & PRs
- Feature work goes on a branch (`feat/`, `fix/`, `refactor/`, `docs/`), then a PR
- Direct pushes to main only for trivial doc fixes (typos, comments)
- Rebase onto latest main before opening a PR

### Changelog
- Update `CHANGELOG.md` with every PR that changes user-facing behavior
- Follow [Keep a Changelog](https://keepachangelog.com) format: Added, Fixed, Changed, Removed
- Group under the current unreleased version at the top
- Bump `VERSION` file when cutting a release

### Testing
- New scripts must have tests. New behavior in existing scripts must have test coverage.
- Run `python3 -m compileall scripts` before committing Python changes
- Run affected test suites before pushing

### Sandbox verification (end-to-end, per PR)
After unit tests pass, every PR that touches user-facing behavior gets an
end-to-end sandbox run that exercises the full flow (fresh HOME, fresh git
project, real subprocess invocations — not just stubs).

**Delegate to a subagent, don't run sandbox scripts in the main session.**
Rationale:
- Sandbox output (raw command dumps, file listings, multi-step logs) pollutes
  the main context window fast. A subagent isolates that noise.
- Subagents can run a scenario matrix in parallel and report pass/fail only.
- If the sandbox flags something, the main session still sees the summary + failure
  details without drowning in everything that passed.

Prompt shape (brief the subagent like a colleague — include branch, feature
summary, precise scenarios, and what "pass" means per scenario):

```
You are a sandbox test runner for autonomous-skill at <path>. Branch <name>.
Feature under test: <one paragraph>.

Ensure you're on the branch, then run these scenarios:
1. ...
2. ...
10. ...

For each: print [PASS] or [FAIL] on one line with scenario number + brief reason.
If FAIL, include the command output so we can diagnose.

Safety:
- Sandbox HOME (mktemp -d), sandbox git project (mktemp -d + git init) per scenario
- Never write to the real ~/.claude/<anything>
- Kill any stray claude processes you spawned

Final line: SUMMARY: N/M passed.
```

Scope rule: any PR touching `scripts/`, `autonomous/SKILL.md`, `quickdo/SKILL.md`,
or worker dispatch should add a sandbox run to its test plan. Pure doc/test
changes can skip this.

### Commit messages
- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `perf:`
- Lowercase, imperative, concise
- No AI attribution (`Co-Authored-By`, `Generated with`)

### CLAUDE.md maintenance
- Update Key Files section when adding/removing/renaming files
- Update test counts when adding tests
- Keep Architecture diagram current

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
