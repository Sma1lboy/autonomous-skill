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

[Quickstart](#quickstart) · [Architecture](#architecture) · [How It Works](#how-it-works) · [Configuration](#configuration) · [Safety](#safety) · [Testing](#testing)

</div>

---

## Install — 30 seconds

Requirements: [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Git, Bash 4+

Optional but recommended: [gstack](https://github.com/garrytan/gstack) (for better performance), [tmux](https://github.com/tmux/tmux) (visible worker windows), [jq](https://jqlang.github.io/jq/) (persona generation)

Open Claude Code and paste this. Claude does the rest:

```
Install autonomous-skill: run git clone --single-branch --depth 1 https://github.com/Sma1lboy/autonomous-skill.git ~/.claude/skills/autonomous-skill.
```

Or install manually:

```bash
git clone --single-branch --depth 1 https://github.com/Sma1lboy/autonomous-skill.git ~/.claude/skills/autonomous-skill
```

Then in any git repo, open Claude Code and run `/autonomous-skill`. It creates an `auto/session-*` branch and starts working.

---

## Usage

### Fully Unattended Mode

By default, Claude Code will still prompt you for permissions on certain operations (file writes, bash commands, etc.) during the conductor session. If you want a **truly hands-off** experience — close your laptop and come back to finished work — start Claude Code with:

```bash
claude --dangerously-skip-permissions
```

Then run `/autonomous-skill` as usual. The conductor, sprint masters, and workers will all run without permission prompts.

> **Note**: This flag skips all permission checks. The built-in [safety guards](#safety) (branch isolation, excluded workflows, timeouts, cost budgets) still apply, but you should review the changes on the `auto/session-*` branch before merging to main.

```bash
# Default: 10 sprints
/autonomous-skill

# Quick: 3 sprints
/autonomous-skill 3

# With direction: focus on a specific area
/autonomous-skill 5 build REST API

# Unlimited sprints
/autonomous-skill unlimited

# Direction only (default 10 sprints)
/autonomous-skill fix all auth bugs
```

### Standalone (outside Claude Code)

```bash
# Direct bash invocation via loop.sh
AUTONOMOUS_DIRECTION="fix auth bugs" bash scripts/loop.sh /path/to/project
```

---

## Architecture

Three-layer hierarchy with full context isolation between layers:

```
Conductor (SKILL.md — runs in user's Claude Code session)
  │
  ├── Plans sprint directions (directed phase or exploration phase)
  ├── Dispatches sprint masters via claude -p in tmux
  ├── Evaluates sprint results, manages phase transitions
  │
  └── Sprint Master (SPRINT.md — separate claude -p session)
        │
        ├── Sense → Direct → Respond → Summarize loop
        ├── Dispatches workers via tmux / headless claude -p
        ├── Answers worker questions via comms.json protocol
        │
        └── Worker (full Claude session with all tools)
              │
              └── Executes the actual work: reads code, edits files,
                  runs tests, commits changes
```

Each layer runs in its own Claude session — fresh context per sprint, no bleed between layers.

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

1. **Persona** — `persona.sh` reads your git history + project docs to understand your coding style. Writes `OWNER.md`.
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

Valid statuses: `idle`, `waiting`, `answered`, `done`.


## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_SPRINTS` (via args) | `10` | Max conductor sprints |
| `MAX_ITERATIONS` | `50` | Max iterations for loop.sh standalone mode |
| `CC_TIMEOUT` | `900` | Timeout per CC invocation (seconds) |
| `AUTONOMOUS_DIRECTION` | _(none)_ | Session focus (e.g., "fix auth bugs") |
| `MAX_COST_USD` | _(none)_ | Stop when total cost exceeds this |

---

## Project Structure

```
autonomous-skill/
├── SKILL.md                          # Conductor: multi-sprint orchestrator
├── SPRINT.md                         # Sprint master: per-sprint execution (inlined into prompt)
├── CLAUDE.md                         # Project instructions for Claude
├── OWNER.md.template                 # Persona template for manual config
├── skill-config.json                 # Default template selector (per-project override at .autonomous/)
├── templates/
│   ├── gstack/template.md            # Allow/Block sections for gstack toolchain
│   └── default/template.md           # Generic fallback, no toolchain assumptions
├── scripts/
│   ├── startup.sh                    # SCRIPT_DIR resolution + project context (shared)
│   ├── parse-args.sh                 # Parse ARGS → _MAX_SPRINTS + _DIRECTION
│   ├── session-init.sh               # Create session branch, init state + backlog
│   ├── build-sprint-prompt.sh        # Inline SPRINT.md + params → sprint-prompt.md
│   ├── dispatch.sh                   # tmux/headless session dispatch
│   ├── monitor-sprint.sh             # Poll for sprint-summary.json
│   ├── monitor-worker.sh             # Poll comms.json + tmux/process liveness
│   ├── evaluate-sprint.sh            # Read summary JSON, update conductor state
│   ├── merge-sprint.sh               # Merge or discard sprint branch
│   ├── write-summary.sh              # Generate sprint-summary.json
│   ├── conductor-state.sh            # State management (atomic writes, PID lock)
│   ├── explore-scan.sh               # 8-dimension project scanner
│   ├── backlog.sh                    # Cross-session persistent backlog
│   ├── persona.sh                    # OWNER.md auto-generation
│   ├── loop.sh                       # Standalone launcher (outside CC)
│   ├── master-poll.sh                # Manual master polling for comms.json
│   └── master-watch.sh               # Dual-channel monitor (comms + JSONL)
├── tests/
│   ├── test_helpers.sh               # Shared test framework
│   ├── test_conductor.sh             # 99 tests: state, phase transitions, exploration
│   ├── test_comms.sh                 # 34 tests: comms.json protocol
│   ├── test_persona.sh               # 20 tests: OWNER.md generation
│   ├── test_explore_scan.sh          # 45 tests: dimension scoring heuristics
│   ├── test_loop.sh                  # 20 tests: standalone launcher
│   ├── test_backlog.sh               # 76 tests: CRUD, progressive disclosure
│   ├── test_build_sprint_prompt.sh   # 25 tests: template resolution, allow/block injection
│   └── claude                        # Mock CC binary for testing
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
- `.autonomous/comms.json` — worker↔master IPC
- `.autonomous/sprint-summary.json` — per-sprint results

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
| **3-strike rule** | Same approach fails 3 times → stop and report. |
| **Atomic state** | Conductor state uses tmp+mv writes, PID lock for concurrency safety. |

---

## Testing

294 tests across 6 suites, all pure bash:

```bash
bash tests/test_conductor.sh    # 99 tests
bash tests/test_comms.sh        # 34 tests
bash tests/test_persona.sh      # 20 tests
bash tests/test_explore_scan.sh # 45 tests
bash tests/test_loop.sh         # 20 tests
bash tests/test_backlog.sh      # 76 tests
shellcheck scripts/*.sh         # lint all shell scripts
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
