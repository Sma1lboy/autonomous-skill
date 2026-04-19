<div align="center">

![logo](assets/logo.svg)

# autonomous-skill

> *"You sleep. It ships."*

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Skill-blueviolet)](https://claude.ai/code)
[![AgentSkills](https://img.shields.io/badge/AgentSkills-Standard-green)](https://agentskills.io)
[![Python](https://img.shields.io/badge/Python-3.11-3776AB?logo=python&logoColor=white)](scripts/)

<br>

You close your laptop at midnight. 47 TODOs in your backlog.<br>
You open it at 8am. 38 of them are done, tested, committed, on a clean branch.<br>
Total cost: $4.20. No meetings required.<br>

**That's autonomous-skill.**

A self-driving project agent for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
Drop it into any git repo, run `/autonomous`, go to sleep.

[Quickstart](#quickstart) · [Skills](#skills) · [Architecture](#architecture) · [How It Works](#how-it-works) · [Configuration](#configuration) · [Safety](#safety) · [Testing](#testing)

</div>

---

## Install — 10 seconds

Requirements: [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Git, Python 3.9+

Optional: [tmux](https://github.com/tmux/tmux) (visible worker windows), [jq](https://jqlang.github.io/jq/) (persona generation)

Paste this into Claude Code:

```
Install autonomous-skill: git clone https://github.com/Sma1lboy/autonomous-skill.git ~/.claude/skills/autonomous-skill && cd ~/.claude/skills/autonomous-skill && ./setup
```

That's it. Open any git repo and run `/autonomous` or `/quickdo`.

---

## Skills

This package ships two public skills:

### `/autonomous` — Full multi-sprint orchestration

The complete pipeline: Conductor → Sprint Master → Worker. Runs multiple sprints,
transitions between directed work and autonomous exploration, manages sprint branches,
evaluates results between sprints.

```bash
# Default: 10 sprints
/autonomous

# Quick: 3 sprints
/autonomous 3

# With direction: focus on a specific area
/autonomous 5 build REST API

# Direction only (default 10 sprints)
/autonomous fix all auth bugs
```

### `/quickdo` — Fast single-sprint execution

Lightweight mode. Skips the conductor, runs one sprint master directly via blocking
`claude -p`. No tmux, no multi-sprint state, no monitor polling. One direction, one
sprint, done.

```bash
# Single task
/quickdo add login page with GitHub OAuth

# Quick fix
/quickdo fix the broken unit tests
```

Best for tasks that fit in a single sprint — a full page, a complete feature stage,
a test suite, a refactor.

### Standalone (outside Claude Code)

```bash
# Direct CLI invocation via loop.py
AUTONOMOUS_DIRECTION="fix auth bugs" python3 scripts/loop.py /path/to/project
```

---

## Architecture

Three-layer hierarchy with full context isolation between layers:

```
Conductor (autonomous/SKILL.md — runs in user's Claude Code session)
  │
  ├── Plans sprint directions (directed phase or exploration phase)
  ├── Dispatches sprint masters via claude -p
  ├── Evaluates sprint results, manages phase transitions
  │
  └── Sprint Master (SPRINT.md — separate claude -p session)
        │
        ├── Sense → Direct → Respond → Summarize loop
        ├── Dispatches workers via claude -p
        ├── Answers worker questions via comms.json protocol
        │
        └── Worker (full Claude session with all tools)
              │
              └── Executes the actual work: reads code, edits files,
                  runs tests, commits changes
```

Each layer runs in its own Claude session — fresh context per sprint, no bleed between layers.

`/quickdo` flattens this to two layers: it skips the conductor and runs the sprint master directly.

**Backlog** — A persistent work queue (`.autonomous/backlog.json`) that survives across sessions. Workers log out-of-scope discoveries, the conductor decomposes large missions into deferred items. When exploration runs dry, idle sprints pick from the backlog. Progressive disclosure: sprint masters only see one-line titles, the conductor sees full descriptions.

### Templates

Worker-task suggestions and boundary blacklists are driven by swappable templates at `templates/<name>/template.md`. Ships with two: `gstack` (default — uses `/office-hours`, `/qa`, `/investigate`, blocks `/ship` etc.) and `default` (generic, no toolchain commands).

Select a template per project by writing `.autonomous/skill-config.json` in your project root:

```json
{ "template": "default" }
```

The project-level override beats the skill-root default at `~/.claude/skills/autonomous-skill/skill-config.json`. Unknown template names fall through to `default`. To add a new template, create `templates/<name>/template.md` with `## Allow` and `## Block` sections and point the config at it.

---

## How It Works

1. **Persona** — `persona.py` reads your git history + project docs to understand your coding style. Writes `OWNER.md`.
2. **Discovery** — The conductor talks to you to understand the mission. If you passed a direction in args, it confirms and moves on.
3. **Session** — Creates an `auto/session-TIMESTAMP` branch and initializes `conductor-state.json`.
4. **Conductor loop** — Plan → Dispatch → Monitor → Evaluate → Repeat:
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

Dimensions are scored via fast Python heuristics (`explore-scan.py`), and the weakest is selected for each exploration sprint.

### Comms Protocol

Workers can't use `AskUserQuestion` in subagent context. Instead, they write questions to `.autonomous/comms.json`:

```json
{"status": "waiting", "questions": [{"question": "...", "options": [...]}], "rec": "A"}
```

The sprint master polls, decides using product intuition (or OWNER.md guidance), and writes back:

```json
{"status": "answered", "answers": ["A"]}
```

Valid statuses: `idle`, `waiting`, `answered`, `done`.

### Worker safety hook (opt-in)

Set `AUTONOMOUS_WORKER_CAREFUL=1` to install a PreToolUse hook on every dispatched worker that blocks catastrophic Bash commands:

```bash
AUTONOMOUS_WORKER_CAREFUL=1 /autonomous 5 build REST API
```

Blocks: `rm -rf /`, `rm -rf $HOME`, `rm -rf /Users|/home`, `mkfs`, `dd of=/dev/sd*`, fork bombs, device redirects, `shutdown`/`reboot`, `git push --force` to `main`/`master`/`trunk`/`release`, `DROP TABLE/DATABASE/SCHEMA`, `TRUNCATE TABLE`.

Search/view tools (`grep DROP foo.sql`, `echo rm -rf /`) are recognized by first-word whitelist and allowed. Ordinary `rm -rf node_modules` and similar build-artifact cleanup pass through.

Configured per-sprint via `claude --settings <file>` — no global settings change. Blocks are exit-2 with a stderr message; the worker reads "BLOCKED: ..." and adapts.


## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_SPRINTS` (via args) | `10` | Max conductor sprints |
| `MAX_ITERATIONS` | `50` | Max iterations for loop.py standalone mode |
| `CC_TIMEOUT` | `900` | Timeout per CC invocation (seconds) |
| `AUTONOMOUS_DIRECTION` | _(none)_ | Session focus (e.g., "fix auth bugs") |
| `MAX_COST_USD` | _(none)_ | Stop when total cost exceeds this |
| `DISPATCH_MODE` | _(auto)_ | `blocking` (no tmux), `headless` (background), or auto (tmux if available) |

---

## Project Structure

```
autonomous-skill/
├── autonomous/SKILL.md               # /autonomous — multi-sprint conductor
├── quickdo/SKILL.md                  # /quickdo — fast single-sprint mode
├── SPRINT.md                         # Sprint master: per-sprint execution (inlined into prompt)
├── CLAUDE.md                         # Project instructions for Claude
├── OWNER.md.template                 # Persona template for manual config
├── skill-config.json                 # Default template selector (per-project override at .autonomous/)
├── templates/
│   ├── gstack/template.md            # Allow/Block sections for gstack toolchain
│   └── default/template.md           # Generic fallback, no toolchain assumptions
├── scripts/
│   ├── startup.py                    # SCRIPT_DIR resolution + project context (shared)
│   ├── parse-args.py                 # Parse ARGS → _MAX_SPRINTS + _DIRECTION
│   ├── session-init.py               # Create session branch, init state + backlog
│   ├── build-sprint-prompt.py        # Inline SPRINT.md + params → sprint-prompt.md
│   ├── dispatch.py                   # Blocking / tmux / headless session dispatch
│   ├── monitor-sprint.py             # Poll for sprint-summary.json
│   ├── monitor-worker.py             # Poll comms.json + tmux/process liveness
│   ├── evaluate-sprint.py            # Read summary JSON, update conductor state
│   ├── merge-sprint.py               # Merge or discard sprint branch
│   ├── write-summary.py              # Generate sprint-summary.json
│   ├── conductor-state.py            # State management (atomic writes, PID lock)
│   ├── explore-scan.py               # 8-dimension project scanner
│   ├── backlog.py                    # Cross-session persistent backlog
│   ├── persona.py                    # OWNER.md auto-generation
│   ├── loop.py                       # Standalone launcher (outside CC)
│   ├── master-poll.py                # Manual master polling for comms.json
│   └── master-watch.py               # Dual-channel monitor (comms + JSONL)
├── tests/
│   ├── test_helpers.sh               # Shared test framework
│   ├── test_conductor.sh             # 99 tests: state, phase transitions, exploration
│   ├── test_comms.sh                 # 34 tests: comms.json protocol
│   ├── test_persona.sh               # 20 tests: OWNER.md generation
│   ├── test_explore_scan.sh          # 45 tests: dimension scoring heuristics
│   ├── test_loop.sh                  # 20 tests: standalone launcher
│   ├── test_backlog.sh               # 76 tests: CRUD, progressive disclosure
│   ├── test_build_sprint_prompt.sh   # 25 tests: template resolution, allow/block injection
│   ├── test_eval_output.sh           # 35 tests: eval safety, tmux cleanup
│   └── claude                        # Mock CC binary for testing
├── .claude/skills/                   # Internal dev/test skills
│   ├── smoke-test/SKILL.md           # E2E pipeline smoke test
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
- `.autonomous/comms.json` — worker↔master IPC
- `.autonomous/sprint-summary.json` — per-sprint results

---

## Safety

| Guard | How |
|-------|-----|
| **Branch isolation** | All work on `auto/session-*` or `auto/quickdo-*` branches. Never touches main. |
| **Per-sprint branches** | Each sprint works on its own branch; merged on success, discarded on failure. |
| **Timeout** | Each CC invocation capped at 15 min (configurable via `CC_TIMEOUT`). |
| **Cost budget** | `MAX_COST_USD` env var stops the session when exceeded. |
| **Excluded workflows** | Configured per template (see `templates/<name>/template.md` `## Block` section). |
| **Graceful shutdown** | SIGINT + sentinel file for clean exit across all layers. |
| **3-strike rule** | Same approach fails 3 times → stop and report. |
| **Atomic state** | Conductor state uses tmp+mv writes, PID lock for concurrency safety. |

---

## Testing

329 tests across 7 suites, all pure bash:

```bash
bash tests/test_conductor.sh    # 99 tests
bash tests/test_comms.sh        # 34 tests
bash tests/test_persona.sh      # 20 tests
bash tests/test_explore_scan.sh # 45 tests
bash tests/test_loop.sh         # 20 tests
bash tests/test_backlog.sh      # 76 tests
bash tests/test_eval_output.sh  # 35 tests
python3 -m compileall scripts   # quick syntax check for Python helpers
```

The test harness uses `tests/claude` (a mock CC binary) controlled by env vars:

| Variable | Effect |
|----------|--------|
| `MOCK_CLAUDE_COST` | Reported cost per invocation |
| `MOCK_CLAUDE_COMMIT=1` | Make a git commit during the mock run |
| `MOCK_CLAUDE_DELAY` | Sleep N seconds (for timeout tests) |
| `MOCK_CLAUDE_EXIT` | Exit code to return |

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
```

---

## License

MIT
