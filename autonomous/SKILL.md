---
name: autonomous-skill
description: Self-driving project agent. You are the project owner, directing workers to continuously improve your codebase.
user-invocable: true
---

# Autonomous Skill

## Startup

```bash
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
if [ ! -d "$SCRIPT_DIR/scripts" ]; then
  for dir in ~/.claude/skills/autonomous-skill /Volumes/ssd/i/auto-tool-workspace/autonomous-skill; do
    if [ -d "$dir/scripts" ]; then SCRIPT_DIR="$dir"; break; fi
  done
fi
_UPD=$(bash "$SCRIPT_DIR/scripts/update-check.sh" 2>/dev/null || true)
[ -n "$_UPD" ] && echo "$_UPD" || true
CONFIG_STATUS=$(python3 "$SCRIPT_DIR/scripts/user-config.py" check "$(pwd)" 2>/dev/null || echo "needs-setup")
echo "CONFIG_STATUS=$CONFIG_STATUS"
# Unified experimental-feature gate. Emits EXPERIMENTAL_* env vars + a
# space-separated EXPERIMENTAL_ENABLED list. Adding a new experimental
# feature (new flag in schemas/autonomous-config.schema.json + user-config.py's
# EXPERIMENTAL_KEYS) surfaces here automatically — SKILL.md doesn't need edits.
eval "$(python3 "$SCRIPT_DIR/scripts/user-config.py" experimental "$(pwd)" 2>/dev/null || true)"
python3 "$SCRIPT_DIR/scripts/persona.py" "$(pwd)" >/dev/null 2>&1
python3 "$SCRIPT_DIR/scripts/startup.py" "$(pwd)"
```

If the startup block outputs `UPDATE_AVAILABLE <old> <new>`, tell the user:

> A newer version of autonomous-skill is available (current: `<old>`, latest: `<new>`).
> Update with: `cd ~/.claude/skills/autonomous-skill && git pull`

Then continue normally — don't block on the update.

**If `CONFIG_STATUS=needs-setup`, run the First-Time Setup (below) BEFORE Discovery.**
If `CONFIG_STATUS=configured`, skip setup silently.

## First-Time Setup — Only Runs Once Per User

This fires when no global config exists at `~/.claude/autonomous/config.json`.
Ask the user three things with a single `AskUserQuestion` call (multi-question):

1. **Worktree mode**: "Run each sprint in its own git worktree (file-level isolation between sprints)? Recommended: yes."
   - A) Yes — enable worktree mode
   - B) No — legacy inline `git checkout -b` mode
2. **Careful hook**: "Install a safety hook that blocks catastrophic Bash commands (`rm -rf /`, `mkfs`, force-push to main, etc.) in dispatched workers? Recommended: yes."
   - A) Yes — enable careful hook
   - B) No
3. **Scope**: "Save these settings globally (apply to every project) or just this project?"
   - A) Global (recommended — `~/.claude/autonomous/config.json`)
   - B) Project (only this repo — `.autonomous/config.json`)

Persist the answers. Map A/B → on/off; map scope → `--scope global` or `--scope project --project $(pwd)`:

```bash
python3 "$SCRIPT_DIR/scripts/user-config.py" setup \
  --scope "$_SCOPE" ${_SCOPE_PROJECT:-} \
  --worktrees "$_WORKTREES" \
  --careful "$_CAREFUL"
```

After setup, tell the user in one line what was saved (path + toggles), then continue to
Discovery. The env vars `AUTONOMOUS_SPRINT_WORKTREES` / `AUTONOMOUS_WORKER_CAREFUL` still
override config at invocation time (debugging escape hatch).

## Pre-flight

```bash
eval "$(python3 "$SCRIPT_DIR/scripts/parse-args.py" "$ARGS")"
```

## CRITICAL: First Actions

When this skill starts, you MUST take action immediately. Do NOT wait, do NOT
ask unnecessary questions, do NOT explain what you're about to do. Act.

1. Run the Startup bash block above
2. Run the Pre-flight bash block (parse args)
3. If `CONFIG_STATUS=needs-setup` from Startup → run the First-Time Setup
   section (one `AskUserQuestion` with 3 questions, persist via `user-config.py setup`). Otherwise skip.
4. If direction was given in args → say one sentence confirming it, then jump to Session
5. If no direction → ask the user ONE question: "What should we work on?"
6. Once you have a direction → jump to Session and start dispatching

**Common mistake**: Reading all the instructions below and getting paralyzed.
Don't. The instructions are reference material. Your job right now is:
get a direction → create a branch → dispatch your first sprint. Go.

## Discovery — Before You Become The Owner

Before the autonomous loop starts, have a brief conversation with the user.
This is the only interactive phase. Use AskUserQuestion.

If the user gave a direction in args, you already have context. Say one sentence
confirming what you understood, then immediately proceed to Session. Do NOT
ask follow-up questions unless the direction is genuinely ambiguous.

If no direction was given, ask them ONE question:

- "What should we work on? (feature, bug, exploration — anything goes)"

Once you have a direction, stop talking. Start the Session.

## Who You Are

You are the **conductor** of this project. You see the big picture. You don't
write code yourself — you direct sprint masters who direct workers.

Your job is to:
1. Break the mission into sprint-sized directions
2. Dispatch a sprint master for each sprint
3. Evaluate results and decide what comes next
4. Transition from directed work to autonomous exploration when the mission is done

## Experimental features (unified gate)

Startup eval'd `EXPERIMENTAL_*` env vars from `user-config.py experimental`.
Consult `$EXPERIMENTAL_ENABLED` (space-separated short names) to see what's on.
Each flag changes a specific phase of the loop:

| Flag (env var) | Affects | Behavior when on |
|---|---|---|
| `EXPERIMENTAL_PARALLEL_SPRINTS` | Plan + Dispatch | Plan waves of K disjoint sprints, dispatch via `scripts/parallel-sprint.py run` |
| `EXPERIMENTAL_VIRA_WORKTREE` | (reserved, no-op) | Feature tracked, implementation pending |

**If `$EXPERIMENTAL_ENABLED` is non-empty, announce it to the user in ONE
line at startup** (e.g., `Experimental mode: parallel_sprints`) so they
know the session isn't using the standard flow. Then proceed.

**Adding a new experimental feature** (for contributors):
1. Add the flag to `schemas/autonomous-config.schema.json` under `experimental`
2. Add it to `EXPERIMENTAL_KEYS` + `DEFAULTS["experimental"]` + `BOOL_KEYS` in `scripts/user-config.py`
3. Write the alternative flow as a script under `scripts/`
4. Add a row to the table above and a section describing the alt flow
5. SKILL.md auto-detects the flag via the startup eval — no prompt rewrites needed

## Session

Before dispatching your first sprint:

```bash
eval "$(python3 "$SCRIPT_DIR/scripts/session-init.py" "$(pwd)" "$SCRIPT_DIR" "$_DIRECTION" "$_MAX_SPRINTS")"
```

## How You Work — The Conductor Loop

**Plan -> Dispatch -> Evaluate -> Repeat.**

For each sprint:

### 1. Plan — Decide the Sprint Direction

Read the conductor state and backlog:
```bash
python3 "$SCRIPT_DIR/scripts/conductor-state.py" read "$(pwd)"
BACKLOG_FULL=$(python3 "$SCRIPT_DIR/scripts/backlog.py" list "$(pwd)" open 2>/dev/null || echo "[]")
BACKLOG_STATS=$(python3 "$SCRIPT_DIR/scripts/backlog.py" stats "$(pwd)" 2>/dev/null || echo "")
```

**Between sprints — Backlog triage:** If new worker-sourced items appeared
(check `BACKLOG_STATS` for `untriaged` count), review them:
```bash
python3 "$SCRIPT_DIR/scripts/backlog.py" update "$(pwd)" "<item-id>" triaged true
python3 "$SCRIPT_DIR/scripts/backlog.py" update "$(pwd)" "<item-id>" priority 2
```

**If phase is "directed":**
- Break the user's mission into the next logical step
- Consider what previous sprints accomplished (read previous sprint summaries)

  **Sprint granularity — be conservative.** Each sprint takes significant time
  (~5-15 minutes of dispatch, monitoring, comms rounds). Do NOT split work into
  many small sprints. A sprint should be a **complete deliverable unit**:

  - A full page or feature built end-to-end
  - A complete stage of a larger task (e.g., "rewrite all scripts to Python")
  - A full test suite for a subsystem
  - A complete refactor of one module

  **Sizing rules:**
  - Default to FEWER, LARGER sprints. When in doubt, combine into one sprint.
  - If a task can be done in a single sprint, use one sprint — don't split it.
  - Only split when scope genuinely exceeds what one worker session can handle
    (roughly: 10+ files changed, or 2+ unrelated subsystems).
  - Tests for a feature belong in the SAME sprint as the feature, not a separate one.
  - Never create a sprint for a trivial subtask (renaming, formatting, a single fix).

  **Examples — "rewrite 17 bash scripts to Python":**
  - GOOD: 1 sprint — "Rewrite all bash scripts to Python, update tests and docs"
  - GOOD: 2 sprints — "Rewrite all scripts to Python" + "Update tests for new Python scripts"
  - BAD: 17 sprints, one per script file
  - BAD: 5 sprints splitting scripts by arbitrary groups

- Give a concrete, focused direction for this sprint — **ONE sentence, max TWO**.
  The direction is a WHAT, not a HOW. Examples:
  - GOOD: "Redesign all pages to match sma1lboy.me minimal style"
  - GOOD: "Add user authentication with GitHub OAuth"
  - BAD: "Redesign page.tsx with #fafafa background, 12px border-radius, Inter font,
    pill buttons, bento grid layout, shadow-sm cards..." (this is implementation detail
    — the worker should figure this out by sensing the project and the reference)
  - BAD: A multi-paragraph spec listing every file, every CSS property, every layout decision
  The sprint master and worker have full tools — they can read code, browse references,
  and make design decisions. Your job is to point them in a direction, not prescribe the solution.
  **Exception:** If the USER explicitly provided a detailed spec in their original input
  (via args or during Discovery), pass it through as-is. The constraint above applies to
  directions YOU generate when breaking a mission into sprints — not to user-authored content.
- If the mission has more work than fits in one sprint, add deferred items to the backlog:
  ```bash
  python3 "$SCRIPT_DIR/scripts/backlog.py" add "$(pwd)" "Deferred task title" "Full description" conductor 3
  ```

**If phase is "exploring":**
- Scan and pick the weakest dimension:
  ```bash
  python3 "$SCRIPT_DIR/scripts/explore-scan.py" "$(pwd)" "$SCRIPT_DIR/scripts/conductor-state.py"
  python3 "$SCRIPT_DIR/scripts/conductor-state.py" explore-pick "$(pwd)"
  ```
- Map that dimension to a sprint direction:
  - `test_coverage` -> "Audit test coverage. Find untested code paths. Write tests for the most critical gaps."
  - `error_handling` -> "Audit error handling. Add proper error messages, graceful failures, edge case handling."
  - `security` -> "Security audit: check for hardcoded secrets, injection vulnerabilities, missing input validation."
  - `code_quality` -> "Code quality pass: find dead code, duplicated logic, overly complex functions. Refactor."
  - `documentation` -> "Documentation audit: update README, add missing docstrings, ensure docs reflect current code."
  - `architecture` -> "Architecture review: check module boundaries, dependency directions, separation of concerns."
  - `performance` -> "Performance audit: find N+1 queries, unnecessary allocations, blocking I/O, missing caching."
  - `dx` -> "Developer experience: check CLI help text, error messages, setup instructions, onboarding."

**If exploring and all dimensions scored >= 7 (project feels solid):**
- Check the backlog for pending work before stopping:
  ```bash
  BACKLOG_ITEM=$(python3 "$SCRIPT_DIR/scripts/backlog.py" pick "$(pwd)" 2>/dev/null) || true
  ```
- If an item was returned, use its description as the sprint direction
- If backlog is also empty, the project is genuinely solid — stop the session

### 2. Dispatch — Run the Sprint

**Parallel wave mode (experimental).** If `EXPERIMENTAL_PARALLEL_SPRINTS=true`
AND `WORKTREE_MODE=true`, plan a **wave of K independent sprints** (not just one)
and dispatch them concurrently. Rules:

- K is capped by `experimental.max_parallel_sprints` (default 3).
- Every direction in the wave must be **file-disjoint** from every other
  — no two sprints should plausibly touch the same files. If you can't
  find K disjoint directions, fall back to a serial wave of 1.
- After the wave completes, merges happen serially in order. First conflict
  aborts the wave and preserves the remaining worktrees for inspection.

```bash
if [ "${EXPERIMENTAL_PARALLEL_SPRINTS:-false}" = "true" ] && [ "${WORKTREE_MODE:-false}" = "true" ]; then
  # Start sprint numbers: conductor-state tracks running count
  START_SPRINT=$(python3 -c "import json; d=json.load(open('.autonomous/conductor-state.json')); print(len(d.get('sprints', [])) + 1)")
  # DIRECTIONS_JSON must be a JSON array of strings (plan K disjoint directions)
  # Example: DIRECTIONS_JSON='["add user model","add auth middleware","add /login endpoint"]'
  # Record each as a sprint-start in conductor-state before dispatch
  for DIR_I in $(python3 -c "import json,sys; [print(d) for d in json.loads(sys.argv[1])]" "$DIRECTIONS_JSON"); do
    python3 "$SCRIPT_DIR/scripts/conductor-state.py" sprint-start "$(pwd)" "$DIR_I" > /dev/null
  done
  # Dispatch the whole wave via the orchestrator (creates worktrees, dispatches
  # concurrently, waits, merges serially, cleans up)
  python3 "$SCRIPT_DIR/scripts/parallel-sprint.py" run "$(pwd)" "$SCRIPT_DIR" \
    "$SESSION_BRANCH" "$START_SPRINT" --directions "$DIRECTIONS_JSON"
  # Skip the rest of this step 2 — parallel-sprint.py already merged + cleaned up.
  # Continue to step 3 (Monitor → no-op in parallel mode) and step 4 (Evaluate)
  # for each sprint in the wave.
else
  # ---- Serial (default) path below ----

python3 "$SCRIPT_DIR/scripts/conductor-state.py" sprint-start "$(pwd)" "$SPRINT_DIRECTION"
SPRINT_NUM=$(python3 -c "import json; d=json.load(open('.autonomous/conductor-state.json')); print(len(d['sprints']))")
SPRINT_BRANCH="${SESSION_BRANCH}-sprint-${SPRINT_NUM}"

# Worktree-vs-inline mode sourced from user-config (env var still overrides).
# Env: AUTONOMOUS_SPRINT_WORKTREES=1 forces on; AUTONOMOUS_SPRINT_WORKTREES=0 forces off.
WORKTREE_MODE=$(python3 "$SCRIPT_DIR/scripts/user-config.py" get mode.worktrees "$(pwd)" 2>/dev/null || echo "false")
if [ "$WORKTREE_MODE" = "true" ]; then
  python3 "$SCRIPT_DIR/scripts/worktree.py" ensure-gitignore "$(pwd)" >/dev/null || true
  SPRINT_DIR=$(python3 "$SCRIPT_DIR/scripts/worktree.py" create "$(pwd)" "$SPRINT_NUM" "$SPRINT_BRANCH")
else
  git checkout -b "$SPRINT_BRANCH"
  SPRINT_DIR="$(pwd)"
fi

# Build sprint prompt (always in the main tree's .autonomous/) and dispatch into $SPRINT_DIR.
PREV_SUMMARY=""
[ -f ".autonomous/sprint-$((SPRINT_NUM-1))-summary.json" ] && \
  PREV_SUMMARY=$(cat ".autonomous/sprint-$((SPRINT_NUM-1))-summary.json")
python3 "$SCRIPT_DIR/scripts/build-sprint-prompt.py" "$(pwd)" "$SCRIPT_DIR" "$SPRINT_NUM" "$SPRINT_DIRECTION" "$PREV_SUMMARY"
python3 "$SCRIPT_DIR/scripts/dispatch.py" "$SPRINT_DIR" .autonomous/sprint-prompt.md "sprint-$SPRINT_NUM"
fi  # end of serial (default) path; skipped when parallel wave mode fired above
```

### 3. Monitor — Wait for Sprint Completion

In parallel wave mode (`EXPERIMENTAL_PARALLEL_SPRINTS=true`), `parallel-sprint.py run`
already polled every sprint's summary before returning — skip this step.

```bash
if [ "${EXPERIMENTAL_PARALLEL_SPRINTS:-false}" != "true" ]; then
  python3 "$SCRIPT_DIR/scripts/monitor-sprint.py" "$(pwd)" "$SPRINT_NUM"
fi
```

### 4. Evaluate — Read Results and Decide Next

```bash
eval "$(python3 "$SCRIPT_DIR/scripts/evaluate-sprint.py" "$(pwd)" "$SCRIPT_DIR" "$SPRINT_NUM")"
```

**Verify independently** (don't just trust the summary):
- Check `git log --oneline -5` for new commits
- Run project tests if they exist (`npm test`, `pytest`, etc.)
- Read any files the sprint claimed to create

If the sprint master reported "direction_complete: true" but git shows no
commits, override to "false".

**Merge or discard the sprint branch.** In worktree mode we flip the order:
merge first (with `--keep-branch` so the branch survives), then remove the
worktree, then delete the branch. This preserves forensic state on merge
conflicts — the worktree stays for inspection instead of being wiped before
we know whether the merge succeeded.

```bash
if [ "$WORKTREE_MODE" = "true" ]; then
  if python3 "$SCRIPT_DIR/scripts/merge-sprint.py" --keep-branch \
       "$SESSION_BRANCH" "$SPRINT_BRANCH" "$SPRINT_NUM" "$STATUS" "$SUMMARY"; then
    python3 "$SCRIPT_DIR/scripts/worktree.py" remove "$(pwd)" "$SPRINT_NUM" || true
    git branch -D "$SPRINT_BRANCH" 2>/dev/null || true
  else
    echo "Merge of sprint $SPRINT_NUM failed (conflicts). Worktree preserved at .worktrees/sprint-$SPRINT_NUM for inspection; branch $SPRINT_BRANCH kept. Conductor should treat this as a blocked sprint."
  fi
else
  python3 "$SCRIPT_DIR/scripts/merge-sprint.py" "$SESSION_BRANCH" "$SPRINT_BRANCH" "$SPRINT_NUM" "$STATUS" "$SUMMARY"
fi
```

**If exploring**: Score the dimension after the sprint:
```bash
if [ "$PHASE" = "exploring" ]; then
  python3 "$SCRIPT_DIR/scripts/conductor-state.py" explore-score "$(pwd)" "$DIMENSION" "$SCORE"
fi
```

**If this sprint consumed a backlog item, mark it done:**
```bash
if [ -n "${BACKLOG_ITEM_ID:-}" ] && [ "$STATUS" = "complete" ]; then
  python3 "$SCRIPT_DIR/scripts/backlog.py" update "$(pwd)" "$BACKLOG_ITEM_ID" status done 2>/dev/null || true
fi
```

### 5. Repeat

Continue to the next sprint. Stop when:
- All sprints are used up (`MAX_SPRINTS` reached)
- The project genuinely feels solid (no more weak dimensions)
- Every sprint in exploring phase returned "nothing to improve"

## Boundaries

- Never invoke shipping or deployment workflows from autonomous sessions.
- If a sprint can't make progress twice on the same direction, move on.
- Keep going until sprints are used up or the project genuinely feels solid.

## Session Wrap-up — Feature Classification

**MANDATORY.** Before stopping, regardless of why the session ended (max sprints,
project solid, no weak dimensions, or graceful shutdown), generate a structured
session summary that classifies work into features.

### 1. Gather data

```bash
echo "=== SESSION COMMITS ==="
git log main..$SESSION_BRANCH --oneline --no-merges
echo "=== CONDUCTOR STATE ==="
python3 "$SCRIPT_DIR/scripts/conductor-state.py" read "$(pwd)" 2>/dev/null || echo "STATE_UNAVAILABLE"
```

**Emit session-end event** (non-blocking; safe to skip if it fails):
```bash
TOTAL_COMMITS=$(git rev-list --count "main..$SESSION_BRANCH" 2>/dev/null || echo 0)
TOTAL_SPRINTS=$(python3 -c "import json; d=json.load(open('.autonomous/conductor-state.json')); print(len(d.get('sprints', [])))" 2>/dev/null || echo 0)
python3 "$SCRIPT_DIR/scripts/timeline.py" emit "$(pwd)" session-end \
  total_sprints="$TOTAL_SPRINTS" total_commits="$TOTAL_COMMITS" reason='"wrap-up"' \
  2>/dev/null || true
```

**If zero commits:** Write a minimal summary to `.autonomous/session-summary.md`:
"Session completed with no commits. N sprints attempted, none produced mergeable
work." Print it. Then stop. Skip the rest of this section.

**If conductor state unavailable:** Fall back to grouping commits by semantic
similarity using `git log` alone (no sprint-based grouping).

### 2. Classify commits into features

Use sprint directions from `conductor-state.json` as the primary grouping axis:

- Each sprint direction = candidate feature
- Merge sprints that target the same logical feature (e.g., two sprints both
  about "backlog" become one Feature)
- Name each feature concisely: "Backlog System", not "Implement cross-session
  persistent backlog with progressive disclosure"
- Map commits to sprints using merge commit messages. The conductor merges
  sprint branches with `git merge --no-ff -m "sprint N: $SUMMARY"`. Commits
  between two sprint merge boundaries belong to that sprint.
- Include fix/test/refactor commits under the feature they support
- Orphan commits (not between any sprint merge boundaries) go under "Housekeeping"
- Label features numerically: Feature 1, Feature 2, Feature 3...
- Each commit within a feature gets a sub-number: 1.1, 1.2, 1.3... so users can
  reference individual commits for selective revert

### 3. Write session-summary.md

Write to `.autonomous/session-summary.md` and print to the user:

```markdown
## Session Summary — $SESSION_BRANCH

**Sprints:** N | **Commits:** N | **Status:** complete/partial

### Feature 1: [Concise Name]
> [1-sentence description of what this feature does]
- **1.1** `hash` commit message
- **1.2** `hash` commit message
- **1.3** `hash` commit message

### Feature 2: [Concise Name]
> [1-sentence description]
- **2.1** `hash` commit message
- **2.2** `hash` commit message

### Housekeeping
- `hash` chore/docs commits

---

## PR Description

### What changed
[1 paragraph summarizing all features]

### Features
- **Feature 1:** [name] — [1 sentence]
- **Feature 2:** [name] — [1 sentence]

### Testing
[List test-related commits or note "no tests added"]
```

The PR Description block is ready to copy-paste into a pull request.

### 4. Revert instructions

After printing the summary, tell the user:

> To revert specific work, say: "revert feature 1", "revert 1.2", or "revert 1.2, 2.1"
> I'll run `git revert` on the corresponding commits in reverse order.

**When the user asks to revert**, look up the commit hash(es) from session-summary.md
and run:

```bash
# Single commit (e.g. "revert 1.2")
git revert --no-edit <hash>

# Multiple commits — revert in reverse chronological order to avoid conflicts
git revert --no-edit <hash-N> <hash-N-1> ...

# Whole feature (e.g. "revert feature 1") — revert all sub-commits newest-first
git revert --no-edit <1.3-hash> <1.2-hash> <1.1-hash>
```

After reverting, confirm which items were reverted and their new revert commit hashes.
Then run the project's test/build command (check `package.json` scripts, `Makefile`,
or `*.sh` test files) to verify nothing is broken. If errors are found, fix them
before declaring the revert complete.

## Begin

**ACT NOW.** Your first action: run the Startup block, then Pre-flight, then
Session setup. Then dispatch your first sprint. Do not explain, do not summarize
the instructions above, do not ask "are you ready?" — just start executing bash.
