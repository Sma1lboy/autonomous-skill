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

[Quickstart](#-quickstart) · [How It Works](#-how-it-works) · [Configuration](#-configuration) · [Safety](#-safety) · [Competitive Analysis](COMPETITIVE.md)

</div>

---

## Quickstart

```bash
# 1. Clone
git clone https://github.com/sma1lboy/autonomous-skill.git

# 2. Symlink into Claude Code skills
ln -s "$(pwd)/autonomous-skill" ~/.claude/skills/autonomous-skill

# 3. In any git repo, open Claude Code and run:
/autonomous-skill
```

That's it. It creates an `auto/session-*` branch and starts working.

---

## How It Works

```
┌─────────────────────────────────────────────────┐
│           /autonomous-skill                     │
│                                                 │
│  ┌──────────┐   ┌──────────┐   ┌────────────┐  │
│  │ persona  │──▶│ discover │──▶│  loop.sh   │  │
│  │  .sh     │   │  .sh     │   │            │  │
│  └──────────┘   └──────────┘   │ for each   │  │
│   OWNER.md       task list     │  iteration: │  │
│   (who you are)  (what to do)  │  ┌───────┐  │  │
│                                │  │claude │  │  │
│                                │  │  -p   │  │  │
│                                │  └───┬───┘  │  │
│                                │      │      │  │
│                                │  HEAD moved? │  │
│                                │  ✓ = success │  │
│                                │  ✗ = retry   │  │
│                                └────────────┘  │
│                                                 │
│  Output: auto/ branch + TRACE.md + log.jsonl   │
└─────────────────────────────────────────────────┘
```

| Step | What happens |
|------|-------------|
| **Persona** | `persona.sh` reads your git history + CLAUDE.md to understand your coding style and priorities. Writes `OWNER.md`. |
| **Discover** | `discover.sh` scans TODOS.md, code `TODO:` comments, KANBAN.md, and GitHub issues. Outputs a priority-sorted task list. |
| **Loop** | `loop.sh` creates a session branch, then for each iteration: spawns `claude -p` with your persona + task, watches tool calls in real-time, checks if HEAD moved (= commit = success). |
| **End** | Prints metrics (duration, commits, cost), appends to TRACE.md, returns to main. |

Each `claude -p` invocation is a **fresh conversation** with full permissions. CC decides what to do: read code, edit files, run tests, commit. loop.sh just checks the result.

---

## Usage

```bash
# Default: 50 iterations
/autonomous-skill

# Quick test: 3 iterations
/autonomous-skill 3

# Unlimited: runs until Ctrl+C or no tasks left
/autonomous-skill unlimited

# With direction: focus the agent on a specific area
/autonomous-skill fix all auth bugs

# Parallel: run N tasks simultaneously via worktrees
MAX_ITERATIONS=20 bash scripts/loop.sh --parallel 3 .
```

---

## Configuration

| Variable / Flag | Default | Description |
|----------------|---------|-------------|
| `MAX_ITERATIONS` / `--max-iterations` | `50` | Max loop iterations (0 = unlimited) |
| `CC_TIMEOUT` / `--timeout` | `900` | Timeout per CC invocation (seconds) |
| `AUTONOMOUS_DIRECTION` / `--direction` | _(none)_ | Session focus (e.g. "fix auth bugs") |
| `MAX_COST_USD` / `--max-cost` | _(none)_ | Stop when total cost exceeds this |
| `--dry-run` | off | Preview tasks without running CC |
| `--resume` | off | Continue on existing session branch |
| `--parallel N` | off | Run N tasks in parallel via worktrees |
| `--stop` | — | Signal a running session to stop |

Or use `.autonomous-skill.yml` in your project root:

```yaml
max_iterations: 100
timeout: 600
direction: "improve test coverage"
```

---

## Stopping

| Method | Behavior |
|--------|----------|
| **Ctrl+C** | Finishes current iteration, then exits |
| **`--stop`** | Signals running session via sentinel file |
| **Rate limit** | Auto-detects API limit, stops immediately |
| **Auto** | Exits when all tasks done or budget hit |

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

## Project Structure

```
autonomous-skill/
├── SKILL.md              # Claude Code skill entry point
├── CLAUDE.md             # Project instructions for Claude
├── OWNER.md.template     # Persona template
├── scripts/
│   ├── loop.sh           # Main autonomous loop
│   ├── discover.sh       # Task discovery (4 sources)
│   ├── persona.sh        # OWNER.md auto-generation
│   ├── parallel.sh       # Worktree parallel execution
│   ├── report.sh         # Session report generator
│   └── status.sh         # Session status dashboard
├── tests/
│   └── test_loop.sh      # Integration tests
└── README.md
```

**Generated at runtime** (gitignored):
- `OWNER.md` — your persona, auto-generated from git + docs
- `TRACE.md` — session history (commits, cost, duration)
- `KANBAN.md` — todo/doing/done board
- `TODOS.md` — task list with completion tracking

---

## Safety

| Guard | How |
|-------|-----|
| **Branch isolation** | All work on `auto/session-*` branches. Never touches main. |
| **Excluded commands** | `/ship`, `/land-and-deploy`, `/careful`, `/guard` are forbidden. |
| **Timeout** | Each CC invocation capped at 15 min (configurable). |
| **Rate limit detection** | Auto-stops when API quota is exhausted. |
| **Graceful shutdown** | Ctrl+C and sentinel files for clean exit. |

---

## Session Metrics

Every session ends with a dashboard:

```
═══════════════════════════════════════════════════
  SESSION METRICS
═══════════════════════════════════════════════════
  Duration:      47m 12s
  Iterations:    20
  Commits:       18
  Files changed: 13 files
  Total cost:    $3.42
  Avg cost/iter: $0.1710
───────────────────────────────────────────────────
```

Session history tracked in `TRACE.md`. Run `scripts/report.sh` for analytics.

---

## License

MIT
