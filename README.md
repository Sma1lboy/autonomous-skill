<div align="center">

![logo](assets/logo.svg)

# autonomous-skill

> *"You sleep. It ships."*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Skill-blueviolet)](https://claude.ai/code)
[![AgentSkills](https://img.shields.io/badge/AgentSkills-Standard-green)](https://agentskills.io)
[![Bash](https://img.shields.io/badge/Bash-Script-4EAA25?logo=gnu-bash&logoColor=white)](scripts/)

<br>

You close your laptop at midnight. 47 TODOs in your backlog.<br>
You open it at 8am. 38 of them are done, tested, committed, on a clean branch.<br>
Total cost: $4.20. No meetings required.<br>

**That's autonomous-skill.**

A self-driving project agent for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
Drop it into any git repo, run `/autonomous-skill`, go to sleep.

[Quick Start](#quick-start) · [Features](#features) · [Architecture](#architecture) · [Script Reference](#script-reference) · [Configuration](#configuration) · [Testing](#testing) · [Session Management](#session-management) · [Safety](#safety)

</div>

---

## Quick Start

### Install — 30 seconds

Requirements: [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Git

Open Claude Code and paste this. Claude does the rest.

```
Install autonomous-skill: run git clone --single-branch --depth 1 https://github.com/Sma1lboy/autonomous-skill.git ~/.claude/skills/autonomous-skill then add an "autonomous-skill" section to CLAUDE.md that says this is a self-driving project agent — run /autonomous-skill to start an autonomous session that creates an auto/ branch and continuously finds and fixes issues. Usage: /autonomous-skill [sprint_count] [direction]. Examples: /autonomous-skill (explore mode, 10 sprints), /autonomous-skill 5 build REST API, /autonomous-skill unlimited. List the helper skills: /test-worker, /clean-sandbox, /capture-worker, /diff-sessions. Mention that all changes happen on auto/ branches (never main), with --dangerously-skip-permissions and 15-minute timeout per sprint. Then ask the user if they want to try it now on the current project.
```

Or install manually:

```bash
# 1. Clone
git clone --single-branch --depth 1 https://github.com/Sma1lboy/autonomous-skill.git ~/.claude/skills/autonomous-skill

# 2. In any git repo, open Claude Code and run:
/autonomous-skill
```

### Usage

```bash
# Default: 10 sprints, explore mode
/autonomous-skill

# Quick: 3 sprints
/autonomous-skill 3

# With direction: focus on a specific area
/autonomous-skill 5 build REST API

# Unlimited sprints
/autonomous-skill unlimited

# Direction only (default 10 sprints)
/autonomous-skill fix all auth bugs

# Use a saved template
/autonomous-skill --template security-audit
```

### Standalone mode (outside Claude Code)

```bash
# Direct bash invocation via loop.sh
AUTONOMOUS_DIRECTION="fix auth bugs" bash scripts/loop.sh /path/to/project
```

---

## Features

| Feature | Description |
|---------|-------------|
| **Framework detection** | Auto-detects project stack (Node/React/Next/Vue/Angular/Rust/Go/Python/Ruby/Java/Bash) from marker files |
| **Worker hints** | Generates framework-specific hints for workers from detection + optional config overrides |
| **Skill registry** | Register, list, query, and scan AI-readable skill metadata in `.autonomous/skill-registry/` |
| **Multi-worker dispatch** | Concurrent workers with per-worker comms isolation (`comms-{worker-id}.json`) |
| **Parallel dispatch** | Dispatch N sprints simultaneously in separate worktrees, merge results sequentially |
| **Preflight checks** | Validates runtime environment (claude CLI, tmux, git) before conductor starts, with `--setup` mode |
| **Cross-session backlog** | Persistent work queue with progressive disclosure, priority, and auto-pruning (max 50 items) |
| **Session reports** | Table, detail, and JSON output from sprint summaries with quality ratings |
| **Session resume** | Detect and resume halted autonomous sessions from conductor-state.json |
| **Sprint history** | List all `auto/` branches with session metadata, detail, compare, and JSON output |
| **Cross-session metrics** | Collect, show, and trend metrics per project with JSON output |
| **Cost tracking** | Track costs per sprint and session total, with budget enforcement (`MAX_COST_USD`) |
| **Rate limit detection** | Detect API rate limits and apply exponential backoff for dispatch retries |
| **Retry strategy** | Analyze sprint failures, suggest adjusted directions, enforce 3-strike rule |
| **Quality gates** | Automated build/test verification after sprint merge (uses framework detection, shellcheck) |
| **Selective merge** | Cherry-pick specific sprints from a session branch (list, merge, squash, dry-run, interactive) |
| **Session diff** | Compare `auto/` branch against base with commit categorization and PR description |
| **Worktree isolation** | Git worktree lifecycle for sprint isolation (create, destroy, list, merge, cleanup) |
| **Sprint templates** | Save and replay sprint direction patterns across projects (`~/.autonomous/templates/`) |
| **Flaky test detection** | Run tests N times, identify inconsistent pass/fail, static analysis for flakiness patterns |
| **Prompt measurement** | Measure prompt file size and section breakdown (lines, chars, words, JSON output) |
| **Config validation** | Validate `.autonomous/skill-config.json` schema with init, migrate, and `--fix` modes |
| **Cross-session learnings** | Record sprint outcomes, query history, suggest directions, prune old entries (max 200 FIFO) |
| **Graceful shutdown** | SIGINT + sentinel file propagation: C-c to tmux workers, wait, force-kill survivors |
| **Progress reporting** | Real-time progress from conductor state for external consumers |

---

## Architecture

Three-layer hierarchy with full context isolation between layers:

```
Conductor (SKILL.md — runs in user's Claude Code session)
  |
  |-- Plans sprint directions (directed phase or exploration phase)
  |-- Dispatches sprint masters via claude -p in tmux
  |-- Evaluates sprint results, manages phase transitions
  |
  └── Sprint Master (SPRINT.md — separate claude -p session)
        |
        |-- Sense -> Direct -> Respond -> Summarize loop
        |-- Dispatches workers via tmux / headless claude -p
        |-- Answers worker questions via comms.json protocol
        |
        └── Worker (full Claude session with all tools)
              |
              └── Executes the actual work: reads code, edits files,
                  runs tests, commits changes
```

Each layer runs in its own Claude session — fresh context per sprint, no bleed between layers.

### How It Works

1. **Persona** — `persona.sh` reads your git history + project docs to understand your coding style. Writes `OWNER.md`.
2. **Discovery** — The conductor talks to you to understand the mission. If you passed a direction in args, it confirms and moves on.
3. **Session** — Creates an `auto/session-TIMESTAMP` branch and initializes `conductor-state.json`.
4. **Conductor loop** — Plan -> Dispatch -> Monitor -> Evaluate -> Repeat:
   - **Directed phase**: breaks your mission into sprint-sized tasks, dispatches one sprint master per task
   - **Phase transition**: when direction is complete (2 consecutive signals + commits, max sprints reached, or 2 zero-commit sprints)
   - **Exploration phase**: scans the project across 8 dimensions, picks the weakest, generates improvement sprints
5. **Sprint execution** — Each sprint master gets a fresh `claude -p` session, dispatches a worker, answers questions via `comms.json`, and writes `sprint-summary.json` when done.
6. **Merge/discard** — Successful sprints merge back to the session branch. Failed sprints are discarded.
7. **Backlog pickup** — When exploration dimensions are all solid, the conductor checks the backlog for deferred work items before stopping.
8. **Session ends** when all sprints are used up, the project feels solid, and the backlog is empty.

### Exploration Dimensions

When the directed mission is complete, the conductor autonomously explores 8 dimensions:

| Dimension | What it audits |
|-----------|---------------|
| `test_coverage` | Untested code paths, missing edge cases |
| `error_handling` | Missing error messages, unhandled failures |
| `security` | Hardcoded secrets, injection vulnerabilities, input validation |
| `code_quality` | Dead code, duplication, overly complex functions |
| `documentation` | README accuracy, missing docstrings, stale docs |
| `architecture` | Module boundaries, dependency directions, separation of concerns |
| `performance` | N+1 queries, blocking I/O, missing caching |
| `dx` | CLI help text, error messages, setup instructions |

Dimensions are scored via fast bash heuristics (`explore-scan.sh`), and the weakest is selected for each exploration sprint.

### Comms Protocol

Workers can't use `AskUserQuestion` in subagent context. Instead, they write questions to `.autonomous/comms.json`:

```json
{"status": "waiting", "questions": [{"question": "...", "options": [...]}], "rec": "A"}
```

The sprint master polls, decides using product intuition (or OWNER.md guidance), and writes back:

```json
{"status": "answered", "answers": ["A"]}
```

Valid statuses: `idle`, `waiting`, `answered`, `done`. Per-worker isolation via `comms-{worker-id}.json`.

---

## Script Reference

### Conductor layer (used by SKILL.md)

| Script | Description |
|--------|-------------|
| `conductor-state.sh` | State management: atomic writes, PID lock, phase transitions |
| `session-init.sh` | Create session branch, init conductor state + backlog |
| `parse-args.sh` | Parse skill args into MAX_SPRINTS and DIRECTION |
| `build-sprint-prompt.sh` | Build sprint-prompt.md by inlining SPRINT.md + params |
| `evaluate-sprint.sh` | Read sprint summary, update conductor state, close tmux |
| `merge-sprint.sh` | Merge or discard a sprint branch |
| `explore-scan.sh` | Project scanner: scores 8 exploration dimensions via bash heuristics |
| `loop.sh` | Standalone launcher (outside CC's skill system) |
| `monitor-sprint.sh` | Poll for sprint completion via summary file + tmux liveness |
| `retry-strategy.sh` | Analyze sprint failures, suggest retry directions (3-strike rule) |
| `rate-limiter.sh` | Rate limit detection and exponential backoff for dispatch retries |
| `parallel-dispatch.sh` | Dispatch N sprints simultaneously in separate worktrees |
| `parallel-monitor.sh` | Monitor N worktree directories for sprint completion |

### Sprint Master layer (used by SPRINT.md)

| Script | Description |
|--------|-------------|
| `dispatch.sh` | Launch a claude -p session in tmux or headless background |
| `monitor-worker.sh` | Poll for worker completion via comms.json + tmux/process liveness |
| `write-summary.sh` | Write sprint-summary.json from git state |
| `cleanup-workers.sh` | Kill registered tmux worker windows |

### Shared infrastructure (used across layers)

| Script | Description |
|--------|-------------|
| `startup.sh` | Resolve SCRIPT_DIR, display project context |
| `common.sh` | Shared utility functions (die, etc.) |
| `comms-lib.sh` | Shared comms.json helpers for monitor scripts |
| `preflight.sh` | Dependency checker: validates runtime environment, `--setup` mode |
| `persona.sh` | Two-tier OWNER.md: global owner + per-project generation from git + docs |
| `session-report.sh` | Session-end report generator: table, detail, and JSON output |
| `backlog.sh` | Cross-session persistent backlog: CRUD, progressive disclosure, max 50 items |
| `show-comms.sh` | Display archived comms logs from past sprints |
| `master-poll.sh` | Manual master polling for comms.json |
| `master-watch.sh` | Dual-channel monitor (comms + session JSONL) |
| `skill-registry.sh` | Register, list, get, prompt-block, scan, unregister skills |
| `detect-framework.sh` | Auto-detect project framework/stack from marker files |
| `build-worker-hints.sh` | Build worker hints from detection + optional config overrides |
| `quality-gate.sh` | Automated build/test verification after sprint merge |
| `session-resume.sh` | Detect and resume halted autonomous sessions |
| `cost-tracker.sh` | Track costs per sprint and session total (record, check budget, report) |
| `measure-prompt.sh` | Measure prompt file size and section breakdown |
| `comms-protocol.txt` | Standalone comms protocol reference for worker prompts |
| `shutdown.sh` | Graceful shutdown propagation: C-c to workers, wait, force-kill |
| `session-diff.sh` | Session diff summary: compare auto/ branch against base |
| `history.sh` | Sprint history viewer: list auto/ branches with metadata |
| `test-stability.sh` | Flaky test detection: run tests N times, identify inconsistent results |
| `worktree-manager.sh` | Git worktree lifecycle: create, destroy, list, merge, cleanup |
| `metrics.sh` | Cross-session metrics dashboard: collect, show, trend |
| `config-validator.sh` | Validate .autonomous/skill-config.json: validate, init, migrate, `--fix` |
| `learnings.sh` | Cross-session learning system: record, query, suggest, prune (max 200 FIFO) |
| `selective-merge.sh` | Cherry-pick specific sprints: list, merge, squash, dry-run, interactive |
| `templates.sh` | Session template system for reusable sprint patterns |
| `run-all-tests.sh` | Parallel test runner with summary |
| `progress-reporter.sh` | Progress reporting for autonomous sessions |
| `autonomous-status.sh` | Quick status check for autonomous sessions |

---

## Configuration

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_SPRINTS` (via args) | `10` | Max conductor sprints |
| `MAX_ITERATIONS` | `50` | Max iterations for loop.sh standalone mode |
| `CC_TIMEOUT` | `900` | Timeout per CC invocation (seconds) |
| `AUTONOMOUS_DIRECTION` | _(none)_ | Session focus (e.g., "fix auth bugs") |
| `MAX_COST_USD` | _(none)_ | Stop when total cost exceeds this |
| `AUTONOMOUS_OWNER` | _(none)_ | Path to global owner persona file |
| `AUTONOMOUS_SKILL_DIR` | _(none)_ | Override skill directory location |
| `AUTONOMOUS_TEMPLATES_DIR` | `~/.autonomous/templates` | Template storage directory |
| `AUTONOMOUS_LEARNINGS_DIR` | `~/.autonomous` | Learnings storage directory |
| `AUTONOMOUS_DEEP_TIMEOUT` | `30` | Timeout for deep explore-scan checks (seconds) |
| `DISPATCH_ISOLATION` | `branch` | Worker isolation mode: `branch` or `worktree` |
| `MONITOR_MAX_POLLS` | `225` | Max poll iterations before monitor timeout |
| `MONITOR_INTERVAL` | `8` | Seconds between monitor polls |

### Project config

**`.autonomous/skill-config.json`** — Per-project configuration overrides. Managed by `config-validator.sh`:

```bash
bash scripts/config-validator.sh init /path/to/project     # Create default config
bash scripts/config-validator.sh validate /path/to/project  # Check schema
bash scripts/config-validator.sh migrate /path/to/project   # Upgrade old config
bash scripts/config-validator.sh validate /path/to/project --fix  # Auto-fix issues
```

### Persona

**Global owner**: `~/.autonomous/owner.md` or set `AUTONOMOUS_OWNER` env var to a custom path.

**Per-project**: `persona.sh` auto-generates `OWNER.md` from global owner + git history + project docs. Use `OWNER.md.template` for manual persona configuration.

---

## Testing

~2,500+ tests across 45 suites, all pure bash.

### Running tests

```bash
# Run everything (parallel by default)
bash scripts/run-all-tests.sh

# Run a single suite
bash tests/test_conductor.sh

# Filter by pattern
bash scripts/run-all-tests.sh --filter "backlog"

# Run sequentially
bash scripts/run-all-tests.sh --sequential

# Lint all scripts
shellcheck scripts/*.sh
```

### Test suites

| Suite | Tests | Description |
|-------|------:|-------------|
| `test_conductor.sh` | 94 | State management, phase transitions, exploration, stale cleanup, input validation |
| `test_comms.sh` | 50 | comms.json protocol, master-watch/master-poll CLI help |
| `test_multi_worker.sh` | 98 | Per-worker comms isolation, --all mode, archiving, backward compat |
| `test_persona.sh` | 29 | OWNER.md generation, CLI help |
| `test_explore_scan.sh` | 45 | 8-dimension scoring heuristics, edge cases, CLI help |
| `test_explore_deep.sh` | 45 | Deep explore-scan: test execution, shellcheck integration, caching |
| `test_loop.sh` | 20 | Standalone launcher args, env vars, persona, error handling |
| `test_backlog.sh` | 76 | CRUD, progressive disclosure, pick, prune, overflow, concurrency |
| `test_preflight.sh` | 48 | Dependency checks, install hints, --setup, version detection, tmux status |
| `test_session_report.sh` | 37 | Table/detail/JSON output, ratings, truncation, edge cases |
| `test_detect_framework.sh` | 71 | Framework detection for node/react/next/vue/angular/rust/go/python/ruby/java/bash |
| `test_worker_hints.sh` | 48 | Hints block generation, config overrides, partial merges, edge cases |
| `test_skill_registry.sh` | 91 | Register, list, get, prompt-block, scan, unregister, edge cases |
| `test_parse_args.sh` | 37 | Argument parsing, sprint count, direction extraction |
| `test_parse_args_template.sh` | 42 | --template flag: basic, with sprint count, with direction |
| `test_build_sprint_prompt.sh` | 35 | Prompt inlining, parameter substitution, --compact flag |
| `test_session_init.sh` | 19 | Branch creation, state initialization |
| `test_merge_sprint.sh` | 25 | Merge/discard logic, branch cleanup |
| `test_evaluate_sprint.sh` | 24 | Summary reading, state updates |
| `test_conversations.sh` | 56 | Comms round-trip, cross-attention quality |
| `test_error_handling.sh` | 33 | Corrupt JSON, atomic writes, monitor timeouts |
| `test_quality_gate.sh` | 76 | Quality gate verification, framework detection, config override, shellcheck |
| `test_session_resume.sh` | 42 | Resume detection, branch validation, --resume/--fresh flags |
| `test_cost_tracker.sh` | 60 | Record, check budget, parse-output, report, accumulation |
| `test_shutdown.sh` | 63 | Graceful shutdown, signal propagation, monitor integration, JSON output |
| `test_session_diff.sh` | 79 | Diff summary, commit categorization, test detection, JSON/markdown output |
| `test_retry_strategy.sh` | 60 | Retry analysis, 3-strike rule, adjusted direction, retry-mark |
| `test_dispatch_timeout.sh` | 28 | Worker timeout enforcement, env/config override, timeout exit handling |
| `test_history.sh` | 113 | History viewer listing, detail, compare, JSON, graceful handling |
| `test_rate_limiter.sh` | 62 | Rate limit detection, backoff calculation, recording, reporting |
| `test_stability.sh` | 53 | Flaky test detection, JSON output, fix mode pattern analysis |
| `test_measure_prompt.sh` | 44 | Prompt size measurement, section breakdown, JSON output |
| `test_selective_merge.sh` | 158 | Selective merge/cherry-pick, squash, dry-run, interactive, conflict handling |
| `test_worktree_manager.sh` | 32 | Worktree lifecycle: create, destroy, list, merge, cleanup, sanitization |
| `test_dispatch_worktree.sh` | 18 | Dispatch worktree isolation: env/config override, branch file, backward compat |
| `test_metrics.sh` | 57 | Collect, show, trend, per-project filtering, JSON output |
| `test_config_validator.sh` | 85 | Validate, init, migrate, --fix, schema checking, edge cases |
| `test_learnings.sh` | 102 | Record, query, suggest, prune, FIFO overflow, filters, JSON output |
| `test_templates.sh` | 200 | Session template CRUD, save, apply, list, cross-project reuse |
| `test_run_all_tests.sh` | 36 | Parallel test runner: discovery, filtering, summary |
| `test_progress_reporter.sh` | 81 | Progress reporting, autonomous-status, conductor progress command |
| `test_parallel_conductor.sh` | 38 | Conductor mark-parallel and get-parallel commands |
| `test_parallel_dispatch.sh` | 52 | Parallel sprint dispatch and merge |
| `test_parallel_monitor.sh` | 53 | Parallel worktree monitoring |
| `test_integration.sh` | — | Integration tests (gated by `INTEGRATION_TEST=1`, requires real claude CLI) |

### Flaky test detection

```bash
# Run a suite 5 times, identify inconsistent tests
bash scripts/test-stability.sh tests/test_conductor.sh 5

# JSON output
bash scripts/test-stability.sh tests/test_conductor.sh 5 --json
```

### Mock binary

The test harness uses `tests/claude` (a mock CC binary) controlled by env vars:

| Variable | Effect |
|----------|--------|
| `MOCK_CLAUDE_COST` | Reported cost per invocation |
| `MOCK_CLAUDE_COMMIT=1` | Make a git commit during the mock run |
| `MOCK_CLAUDE_DELAY` | Sleep N seconds (for timeout tests) |
| `MOCK_CLAUDE_EXIT` | Exit code to return |

---

## Session Management

### Resume halted sessions

```bash
# Detect resumable sessions
bash scripts/session-resume.sh /path/to/project

# Resume with --resume flag
bash scripts/session-resume.sh /path/to/project --resume

# Force fresh session
bash scripts/session-resume.sh /path/to/project --fresh
```

### Sprint history

```bash
# List all auto/ branches with metadata
bash scripts/history.sh /path/to/project

# Detail for a specific session
bash scripts/history.sh /path/to/project detail auto/session-1234

# Compare two sessions
bash scripts/history.sh /path/to/project compare auto/session-1234 auto/session-5678

# JSON output
bash scripts/history.sh /path/to/project --json
```

### Cross-session metrics

```bash
# Collect metrics from current session
bash scripts/metrics.sh collect /path/to/project

# Show dashboard
bash scripts/metrics.sh show /path/to/project

# Show trends
bash scripts/metrics.sh trend /path/to/project

# JSON output
bash scripts/metrics.sh show /path/to/project --json
```

### Selective merge

```bash
# List sprints in a session branch
bash scripts/selective-merge.sh list /path/to/project auto/session-1234

# Merge specific sprints
bash scripts/selective-merge.sh merge /path/to/project auto/session-1234 1 3 5

# Squash merge
bash scripts/selective-merge.sh squash /path/to/project auto/session-1234 1 3

# Dry run
bash scripts/selective-merge.sh merge /path/to/project auto/session-1234 1 3 --dry-run
```

### Session diff

```bash
# Compare session branch against base
bash scripts/session-diff.sh /path/to/project auto/session-1234

# JSON output
bash scripts/session-diff.sh /path/to/project auto/session-1234 --json

# Markdown PR description
bash scripts/session-diff.sh /path/to/project auto/session-1234 --markdown
```

### Session reports

```bash
# Table summary
bash scripts/session-report.sh /path/to/project

# Detailed per-sprint output
bash scripts/session-report.sh /path/to/project --detail

# JSON output
bash scripts/session-report.sh /path/to/project --json
```

---

## Project Structure

```
autonomous-skill/
├── SKILL.md                          # Conductor: multi-sprint orchestrator
├── SPRINT.md                         # Sprint master: per-sprint execution
├── CLAUDE.md                         # Project instructions for Claude
├── OWNER.md.template                 # Persona template for manual config
├── scripts/
│   ├── startup.sh                    # SCRIPT_DIR resolution + project context
│   ├── common.sh                     # Shared utility functions (die, etc.)
│   ├── comms-lib.sh                  # Shared comms.json helpers for monitors
│   ├── preflight.sh                  # Dependency checker: validates runtime env
│   ├── parse-args.sh                 # Parse ARGS -> _MAX_SPRINTS + _DIRECTION
│   ├── session-init.sh               # Create session branch, init state + backlog
│   ├── build-sprint-prompt.sh        # Inline SPRINT.md + params -> sprint-prompt.md
│   ├── conductor-state.sh            # State management (atomic writes, PID lock)
│   ├── dispatch.sh                   # tmux/headless session dispatch
│   ├── monitor-sprint.sh             # Poll for sprint-summary.json
│   ├── monitor-worker.sh             # Poll comms.json + tmux/process liveness
│   ├── evaluate-sprint.sh            # Read summary JSON, update conductor state
│   ├── merge-sprint.sh               # Merge or discard sprint branch
│   ├── write-summary.sh              # Generate sprint-summary.json
│   ├── cleanup-workers.sh            # Kill registered tmux worker windows
│   ├── explore-scan.sh               # 8-dimension project scanner
│   ├── detect-framework.sh           # Auto-detect project framework/stack
│   ├── build-worker-hints.sh         # Build worker hints from detection + config
│   ├── skill-registry.sh             # Register, list, get, scan skills
│   ├── backlog.sh                    # Cross-session persistent backlog
│   ├── persona.sh                    # OWNER.md auto-generation
│   ├── session-report.sh             # Session-end report generator
│   ├── show-comms.sh                 # Display archived comms logs
│   ├── loop.sh                       # Standalone launcher (outside CC)
│   ├── master-poll.sh                # Manual master polling for comms.json
│   ├── master-watch.sh               # Dual-channel monitor (comms + JSONL)
│   ├── quality-gate.sh               # Automated build/test verification
│   ├── session-resume.sh             # Detect + resume halted sessions
│   ├── cost-tracker.sh               # Track costs per sprint + session total
│   ├── measure-prompt.sh             # Measure prompt size + section breakdown
│   ├── comms-protocol.txt            # Comms protocol reference for workers
│   ├── shutdown.sh                   # Graceful shutdown propagation
│   ├── session-diff.sh               # Session diff + commit categorization
│   ├── retry-strategy.sh             # Analyze failures, suggest retry directions
│   ├── rate-limiter.sh               # Rate limit detection + exponential backoff
│   ├── history.sh                    # Sprint history viewer
│   ├── test-stability.sh             # Flaky test detection
│   ├── selective-merge.sh            # Cherry-pick specific sprints
│   ├── worktree-manager.sh           # Git worktree lifecycle management
│   ├── config-validator.sh           # Validate skill-config.json
│   ├── metrics.sh                    # Cross-session metrics dashboard
│   ├── learnings.sh                  # Cross-session learning system
│   ├── templates.sh                  # Session template system
│   ├── run-all-tests.sh              # Parallel test runner with summary
│   ├── progress-reporter.sh          # Progress reporting for sessions
│   ├── autonomous-status.sh          # Quick session status check
│   ├── parallel-dispatch.sh          # Parallel sprint dispatch in worktrees
│   └── parallel-monitor.sh           # Parallel worktree completion monitor
├── tests/
│   ├── test_helpers.sh               # Shared test framework (assertions, temp dirs)
│   ├── test_*.sh                     # 45 test suites (~2,500+ tests)
│   ├── claude                        # Mock CC binary for testing
│   └── timeout                       # Timeout helper binary for tests
├── .claude/skills/
│   ├── test-worker/SKILL.md          # Spawns worker + auto-answering master
│   ├── capture-worker/SKILL.md       # Capture worker JSONL for inspection
│   ├── diff-sessions/SKILL.md        # Compare two sessions side-by-side
│   ├── clean-sandbox/SKILL.md        # Reset test sandbox
│   └── clean-gstack/SKILL.md         # Delete gstack design doc archives
└── README.md
```

**Generated at runtime** (gitignored):
- `OWNER.md` — your persona, auto-generated from git + docs
- `.autonomous/conductor-state.json` — multi-sprint state machine
- `.autonomous/comms.json` — worker<->master IPC
- `.autonomous/sprint-summary.json` — per-sprint results
- `.autonomous/backlog.json` — persistent work queue
- `.autonomous/progress.json` — session progress for external consumers
- `.autonomous/parallel-tracking.json` — parallel dispatch tracking
- `.autonomous/parallel-results.json` — parallel sprint results

---

## Safety

| Guard | How |
|-------|-----|
| **Branch isolation** | All work on `auto/session-*` branches. Never touches main. |
| **Per-sprint branches** | Each sprint works on its own branch; merged on success, discarded on failure. |
| **Permission mode** | Workers run with `--dangerously-skip-permissions` but excluded from dangerous workflows. |
| **Excluded workflows** | `/ship`, `/land-and-deploy`, `/careful`, `/guard` are forbidden. |
| **Timeout** | Each CC invocation capped at 15 min (configurable via `CC_TIMEOUT`). |
| **Cost budget** | `MAX_COST_USD` env var stops the session when exceeded. |
| **Graceful shutdown** | SIGINT + sentinel file for clean exit across all layers. |
| **3-strike rule** | Same approach fails 3 times -> stop and report. |
| **Atomic state** | Conductor state uses tmp+mv writes, PID lock for concurrency safety. |

---

## Reviewing & Merging

```bash
# See what the agent did
git log main..auto/session-TIMESTAMP --oneline

# Detailed diff
git diff main..auto/session-TIMESTAMP --stat

# Merge if satisfied
git checkout main && git merge auto/session-TIMESTAMP

# Or cherry-pick specific commits
git cherry-pick COMMIT_HASH

# Or use selective-merge for fine-grained control
bash scripts/selective-merge.sh list /path/to/project auto/session-TIMESTAMP
bash scripts/selective-merge.sh merge /path/to/project auto/session-TIMESTAMP 1 3 5
```

---

## License

MIT
