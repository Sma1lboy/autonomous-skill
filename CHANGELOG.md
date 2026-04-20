# Changelog

All notable changes to autonomous-skill are documented here.

## [Unreleased]

### Added (experimental flags + schema)
- `schemas/autonomous-config.schema.json` — JSON Schema (draft-07) documenting every field in `~/.claude/autonomous/config.json` with per-key descriptions. IDEs pick it up via `$schema` for autocomplete.
- `user-config.py init` — write a fully-populated sample config (all sections, defaults, `$schema` reference) at global or project scope. Refuses to overwrite existing configs.
- `experimental` section in config schema with two flags — `vira_worktree` and `parallel_sprints`. Both default to false; setting either on emits a WARNING to stderr on every `check` call. Implementation of these features is tracked for a future PR; the flags themselves are no-ops until then but are documented and persist across restarts.
- `user-config.py check` now emits `WARNING: experimental flags enabled: ...` to stderr when any experimental flag is on. Stdout stays machine-readable (`configured`/`needs-setup`) for bash callers.
- All written configs include `"$schema": "..."` reference so editors can validate + autocomplete.


### Added
- `scripts/user-config.py` — global + project config, replaces scattered env vars as the source of truth for mode toggles. Commands: `check`, `get`, `set`, `setup`, `show`, `paths`. Precedence: env > `<project>/.autonomous/config.json` > `~/.claude/autonomous/config.json` > defaults. Reads legacy `.autonomous/skill-config.json` for back-compat.
- First-time setup in `autonomous/SKILL.md` — when no global config exists, asks once via `AskUserQuestion` for `worktrees`, `careful_hook`, and `scope` (global/project), persists, never asks again.
- `tests/test_user_config.sh` — 38 tests covering precedence, env overrides, legacy migration, validation, malformed-config resilience.
- `scripts/worktree.py` — per-sprint git worktree manager (opt-in via `mode.worktrees`). Creates `.worktrees/sprint-N/` on a dedicated sprint branch, symlinks `.autonomous/` back to the main tree so coordination files stay single-sourced. Commands: `create`, `remove`, `list`, `ensure-gitignore`, `prune`, `path`. Refuses symlinked `.worktrees/` or `.autonomous/` to prevent repo escape; validates branch names via `git check-ref-format`; requires `is_git_repo` before remove.
- `tests/test_worktree.sh` — 65 tests covering CRUD, validation, symlink escape refusal, unregistered-directory remove guard, branch name validation, `.autonomous` symlink write-through, and multi-sprint coexistence.

### Changed
- `scripts/persona.py` — OWNER.md now lives at `~/.claude/autonomous/OWNER.md` (global) by default. Legacy `~/.claude/skills/autonomous-skill/OWNER.md` is migrated on first run. When `persona.scope=project` is set in config, OWNER.md goes to `<project>/.autonomous/OWNER.md` instead.
- `scripts/dispatch.py` — careful-hook toggle now sourced from user-config (`mode.careful_hook`). `AUTONOMOUS_WORKER_CAREFUL` env var still overrides for debugging.
- `scripts/build-sprint-prompt.py` — template resolution chain: project `config.json` → project `skill-config.json` (legacy) → global `config.json` → skill-root `skill-config.json` → default.
- `autonomous/SKILL.md` Dispatch phase — when `mode.worktrees=true` (or `AUTONOMOUS_SPRINT_WORKTREES=1`), each sprint runs in its own worktree instead of flipping the main tree onto the sprint branch. Merge runs first (with `--keep-branch`), then worktree removal, then branch delete — if merge conflicts, worktree and branch are preserved for forensics.
- `scripts/merge-sprint.py` — adds `--keep-branch` flag (skip final `git branch -D`, worktree mode deletes the branch separately after worktree removal). Merge failures now return 1 with the merge aborted cleanly instead of raising.

## [0.6.0] — 2026-04-09

### Added
- `/explore-ralph-loop` skill — detects Ralph Loop patterns from conversation history and captures them as reusable skills
- `scripts/register-ralph-loops.sh` — dynamic registration of generated loop skills to `~/.claude/skills/`
- `ralph-loop-skills/` directory for generated loop skills (gitignored, per-user)
- Generated loop skills delegate execution to `/quickdo` with canned directions

## [0.5.0] — 2026-04-09

### Added
- `/quickdo` skill — fast single-sprint execution mode, no tmux, blocking `claude -p` all the way down (#42, #43)
- `/smoke-test` internal skill — 8-step end-to-end pipeline verification (#39)
- `DISPATCH_MODE` env var — `blocking` (no tmux), `headless` (background), or auto (#42)
- Update check on skill startup — compares local VERSION against GitHub, 60-min cache (#44)
- Sprint granularity rules in conductor prompt — fewer, larger sprints (#40)
- `test_eval_output.sh` — 35 tests for eval safety, shell quoting, tmux cleanup (#39)
- `VERSION` file for release tracking (#44)

### Fixed
- `session-init.py` — subprocess stdout leaked into eval output (#38)
- `evaluate-sprint.py` — SUMMARY with spaces/quotes broke shell eval, fixed with `shlex.quote()` (#38)
- `monitor-sprint.py` — sprint master tmux window not killed after completion (#39)
- `monitor-worker.py` — worker tmux window not killed after completion (#41)
- `merge-sprint.py` — relied on CWD, added `--project-dir` flag (#41)

### Changed
- Skill layout: `autonomous/SKILL.md` and `quickdo/SKILL.md` at root level, internal skills stay in `.claude/skills/` (#43)
- README rewritten: removed dangerous usage instructions, documented both skills, updated project structure (#43)

## [0.4.0] — 2026-04-09

### Added
- Template system for worker-task guidance — swappable allow/block sections per project (#35)
- `build-sprint-prompt.py` — renders SPRINT.md with template injection (#35)
- Session summary with feature classification on wrap-up (#36)
- `skill-config.json` for template selection (#35)

### Changed
- All 17 bash scripts rewritten to Python (#37)
- Tests updated to call `.py` instead of `.sh` (#37)
- `shellcheck` replaced with `python3 -m compileall` (#37)

## [0.3.0] — 2026-04-07

### Added
- Cross-session persistent backlog — progressive disclosure, 76 tests (#backlog PR)
- `--help` flags on all scripts, improved error messages — 35 new tests
- Exploration scanning heuristics for 8 dimensions
- Per-sprint branch isolation with merge/discard workflow
- Multi-sprint conductor with directed → exploration phase transitions
- 6-principle decision fallback for worker questions

### Changed
- OWNER.md moved to global (not per-project)
- Dispatch/monitor extracted to standalone scripts
- Prompts reduced by ~370 lines via script extraction

## [0.2.0] — 2026-04-04

### Added
- Discovery phase — conductor talks to user before starting
- `test-worker`, `capture-worker`, `diff-sessions`, `clean-sandbox`, `clean-gstack` internal skills
- `master-watch.sh` — dual-channel monitor for comms + JSONL
- Sprint master architecture: sense → direct → respond → summarize
- Workers use skill workflows, comms.json protocol

### Changed
- Architecture refactored to 3-layer: Conductor → Sprint Master → Worker
- SKILL.md rewritten as project owner identity, not instruction manual

## [0.1.0] — 2026-04-01

### Added
- Initial release: `loop.sh` autonomous loop with discover → plan → execute
- Session branches (`auto/session-*`), cost budgets, timeout guards
- Live progress output, session metrics dashboard
- `--dry-run`, `--resume`, `--stop`, `--parallel` flags
- `report.sh` session reports, `status.sh` dashboard
- 179 tests across multiple suites
- Rate limit detection, graceful shutdown (SIGINT/SIGTERM)
