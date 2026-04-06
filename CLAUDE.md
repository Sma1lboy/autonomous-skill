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
- `OWNER.md.template` — Template for manual persona configuration
- `tests/test_helpers.sh` — Shared test framework (assertions, temp dirs, result summary)

#### Conductor layer scripts (used by SKILL.md)

- `scripts/conductor-state.sh` — State management (atomic writes, PID lock, phase transitions)
- `scripts/session-init.sh` — Create session branch, init conductor state + backlog
- `scripts/parse-args.sh` — Parse skill args into MAX_SPRINTS and DIRECTION
- `scripts/build-sprint-prompt.sh` — Build sprint-prompt.md by inlining SPRINT.md + params
- `scripts/evaluate-sprint.sh` — Read sprint summary, update conductor state, close tmux
- `scripts/merge-sprint.sh` — Merge or discard a sprint branch
- `scripts/explore-scan.sh` — Project scanner: scores 8 exploration dimensions via bash heuristics
- `scripts/loop.sh` — Standalone launcher (outside CC's skill system)
- `scripts/monitor-sprint.sh` — Poll for sprint completion via summary file + tmux liveness
- `scripts/retry-strategy.sh` — Analyze sprint failures, suggest retry directions (3-strike rule)

#### Sprint master layer scripts (used by SPRINT.md)

- `scripts/dispatch.sh` — Launch a claude -p session in tmux or headless background
- `scripts/monitor-worker.sh` — Poll for worker completion via comms.json + tmux/process liveness
- `scripts/write-summary.sh` — Write sprint-summary.json from git state

#### Shared infrastructure scripts (used by multiple layers)

- `scripts/startup.sh` — Resolve SCRIPT_DIR, display project context
- `scripts/preflight.sh` — Dependency checker: validates runtime environment before conductor starts
- `scripts/persona.sh` — Two-tier OWNER.md: global owner (`~/.autonomous/owner.md` or `AUTONOMOUS_OWNER`) + per-project generation from git history + project docs
- `scripts/session-report.sh` — Session-end report generator: table, detail, and JSON output from sprint summaries
- `scripts/backlog.sh` — Cross-session persistent backlog (progressive disclosure, mkdir locking, max 50 items)
- `scripts/show-comms.sh` — Display archived comms logs from past sprints
- `scripts/master-poll.sh` — Manual master polling for comms.json
- `scripts/master-watch.sh` — Dual-channel monitor (comms + session JSONL)
- `scripts/skill-registry.sh` — Skill registry: register, list, get, prompt-block, scan, unregister skills in `.autonomous/skill-registry/`
- `scripts/detect-framework.sh` — Auto-detect project framework/stack from marker files (package.json, Cargo.toml, go.mod, etc.)
- `scripts/build-worker-hints.sh` — Build worker hints block from detection + optional `.autonomous/skill-config.json` overrides
- `scripts/cleanup-workers.sh` — Kill registered tmux worker windows (shared by write-summary + evaluate-sprint)
- `scripts/quality-gate.sh` — Automated build/test verification after sprint merge (uses detect-framework.sh, supports skill-config.json override, shellcheck integration)
- `scripts/session-resume.sh` — Detect and resume halted autonomous sessions (reads conductor-state.json, validates branch)
- `scripts/cost-tracker.sh` — Track costs per sprint and session total (record, check budget, parse output, report)
- `scripts/shutdown.sh` — Graceful shutdown propagation: C-c to tmux workers, wait, force-kill survivors, write shutdown-reason.json
- `scripts/session-diff.sh` — Session diff summary: compare auto/ branch against base, with commit categorization and PR description

#### Skills

- `.claude/skills/test-worker/SKILL.md` — Test skill: spawns worker + auto-answering master
- `.claude/skills/clean-sandbox/SKILL.md` — Reset test sandbox
- `.claude/skills/clean-gstack/SKILL.md` — Delete gstack design doc archives
- `.claude/skills/capture-worker/SKILL.md` — Capture worker JSONL for inspection
- `.claude/skills/diff-sessions/SKILL.md` — Compare two worker sessions side-by-side

## How it works

1. User invokes `/autonomous-skill` in a git repo (e.g., `/autonomous-skill 5 build REST API`)
2. persona.sh generates OWNER.md if missing (from global owner + git log + CLAUDE.md + README.md)
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
- Per-worker isolation: `comms-{worker-id}.json` for concurrent multi-worker dispatch
- Validated: 20+ rounds per session, cross-attention quality preserved

## Conductor State

The conductor tracks multi-sprint progress in `.autonomous/conductor-state.json`:
- Phase: "directed" (executing user's mission) or "exploring" (autonomous improvement)
- Sprint history: direction, status, commits, summary per sprint
- Phase transition decision tree (see SKILL.md)
- Exploration dimensions with audit status and scores
- Atomic writes (tmp+mv), PID lock for concurrency safety
- Per-sprint `retry_count` tracking (0 by default, incremented via `retry-mark`)
- `get-sprint` command to retrieve individual sprint data as JSON

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
bash tests/test_session_report.sh     # 37 tests: table/detail/JSON output, ratings, truncation, edge cases, CLI help
bash tests/test_preflight.sh          # 48 tests: dependency checks, install hints, --setup, version detection, tmux status
bash tests/test_conductor.sh          # 94 tests: state management, phase transitions, exploration, stale cleanup, input validation, CLI help
bash tests/test_comms.sh              # 50 tests: comms.json protocol, master-watch/master-poll CLI help
bash tests/test_multi_worker.sh       # 98 tests: per-worker comms isolation, --all mode, archiving, backward compat
bash tests/test_persona.sh            # 29 tests: OWNER.md generation, CLI help
bash tests/test_explore_scan.sh       # 45 tests: 8-dimension scoring heuristics, edge cases, CLI help
bash tests/test_loop.sh               # 20 tests: standalone launcher args, env vars, persona, error handling, CLI help
bash tests/test_backlog.sh            # 76 tests: CRUD, progressive disclosure, pick, prune, overflow, concurrency, validation
bash tests/test_detect_framework.sh   # 71 tests: framework detection for node/react/next/vue/angular/rust/go/python/ruby/java/bash
bash tests/test_worker_hints.sh       # 48 tests: hints block generation, config overrides, partial merges, edge cases
bash tests/test_skill_registry.sh     # 91 tests: register, list, get, prompt-block, scan, unregister, edge cases, CLI help
bash tests/test_parse_args.sh         # 37 tests: argument parsing, sprint count, direction extraction
bash tests/test_build_sprint_prompt.sh # 22 tests: prompt inlining, parameter substitution
bash tests/test_session_init.sh       # 19 tests: branch creation, state initialization
bash tests/test_merge_sprint.sh       # 25 tests: merge/discard logic, branch cleanup
bash tests/test_evaluate_sprint.sh    # 24 tests: summary reading, state updates
bash tests/test_conversations.sh      # 56 tests: comms round-trip, cross-attention quality
bash tests/test_error_handling.sh     # 33 tests: corrupt JSON, atomic writes, monitor timeouts
bash tests/test_quality_gate.sh      # 76 tests: quality gate verification, framework detection, config override, shellcheck integration
bash tests/test_session_resume.sh    # 42 tests: resume detection, branch validation, --resume/--fresh flags, edge cases
bash tests/test_cost_tracker.sh      # 60 tests: record, check budget, parse-output, report, accumulation, integration
bash tests/test_shutdown.sh          # 63 tests: graceful shutdown, signal propagation, monitor integration, JSON output
bash tests/test_session_diff.sh      # 79 tests: diff summary, commit categorization, test detection, JSON/markdown output, session-report integration
bash tests/test_retry_strategy.sh    # 60 tests: retry analysis, 3-strike rule, adjusted direction, retry-mark, get-sprint, count, edge cases
bash tests/test_dispatch_timeout.sh  # 28 tests: worker timeout enforcement, env/config override, timeout exit handling, monitor detection
shellcheck scripts/*.sh               # lint all shell scripts
```

Test harness uses `tests/claude` (mock CC binary) controlled by env vars:
- `MOCK_CLAUDE_COST` — reported cost per invocation
- `MOCK_CLAUDE_COMMIT=1` — make a git commit during the mock run
- `MOCK_CLAUDE_DELAY` — sleep N seconds (for timeout tests)
- `MOCK_CLAUDE_EXIT` — exit code to return
