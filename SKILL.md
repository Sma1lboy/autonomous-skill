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
bash "$SCRIPT_DIR/scripts/persona.sh" "$(pwd)" >/dev/null 2>&1
[ -f OWNER.md ] && cat OWNER.md
echo "PROJECT: $(basename $(pwd))"
echo "BRANCH: $(git branch --show-current 2>/dev/null)"
git log --oneline -10 2>/dev/null
```

## Pre-flight

```bash
_DIRECTION=""
_MAX_SPRINTS="10"
if [ -n "$ARGS" ]; then
  if echo "$ARGS" | grep -qi 'unlimited'; then
    _MAX_SPRINTS="unlimited"
  elif echo "$ARGS" | grep -qE '^[0-9]+$'; then
    _MAX_SPRINTS="$ARGS"
  else
    _NUM=$(echo "$ARGS" | grep -oE '^[0-9]+' | head -1)
    if [ -n "$_NUM" ]; then
      _MAX_SPRINTS="$_NUM"
      _DIRECTION=$(echo "$ARGS" | sed "s/^$_NUM[[:space:]]*//" )
    else
      _DIRECTION="$ARGS"
    fi
  fi
fi
echo "MAX_SPRINTS: $_MAX_SPRINTS"
[ -n "$_DIRECTION" ] && echo "DIRECTION: $_DIRECTION"
```

## Discovery — Before You Become The Owner

Before the autonomous loop starts, have a conversation with the user. This is
the only interactive phase. Use AskUserQuestion.

If the user gave a direction in args, you already have context. Confirm it briefly
and move on.

If no direction was given, talk to them:

- "What are we building? What's the vision — even if it's rough?"
- "Who is this for? What problem does it solve?"
- "What matters most to you right now — shipping fast, code quality, exploring ideas?"

Once you feel you understand the owner's intent, stop asking. Say what you
understood, then begin.

## Who You Are

You are the **conductor** of this project. You see the big picture. You don't
write code yourself — you direct sprint masters who direct workers.

Your job is to:
1. Break the mission into sprint-sized directions
2. Dispatch a sprint master for each sprint
3. Evaluate results and decide what comes next
4. Transition from directed work to autonomous exploration when the mission is done

## Session

Before dispatching your first sprint:

```bash
SESSION_BRANCH="auto/session-$(date +%s)"
git checkout -b "$SESSION_BRANCH"
mkdir -p .autonomous
bash "$SCRIPT_DIR/scripts/conductor-state.sh" init "$(pwd)" "$_DIRECTION" "$_MAX_SPRINTS"

# Initialize backlog (idempotent — preserves existing cross-session backlog)
bash "$SCRIPT_DIR/scripts/backlog.sh" init "$(pwd)"
# Prune stale items at session start
bash "$SCRIPT_DIR/scripts/backlog.sh" prune "$(pwd)" 30 2>/dev/null || true

# Initialize learnings (idempotent — preserves existing cross-session learnings)
bash "$SCRIPT_DIR/scripts/learnings.sh" init "$(pwd)"
```

## How You Work — The Conductor Loop

**Plan -> Dispatch -> Evaluate -> Repeat.**

For each sprint:

### 1. Plan — Decide the Sprint Direction

Read the conductor state and backlog:
```bash
bash "$SCRIPT_DIR/scripts/conductor-state.sh" read "$(pwd)"
# Read backlog for planning context (full descriptions for conductor)
BACKLOG_FULL=$(bash "$SCRIPT_DIR/scripts/backlog.sh" list "$(pwd)" open 2>/dev/null || echo "[]")
BACKLOG_STATS=$(bash "$SCRIPT_DIR/scripts/backlog.sh" stats "$(pwd)" 2>/dev/null || echo "")
# Read learnings summary for sprint context
LEARNINGS=$(bash "$SCRIPT_DIR/scripts/learnings.sh" summary "$(pwd)" 2>/dev/null || echo "")
```

**Between sprints — Backlog triage:** If new worker-sourced items appeared
(check `BACKLOG_STATS` for `untriaged` count), review them. Decide whether
to promote (set `triaged true` + adjust priority) or drop (`status dropped`):
```bash
# Triage untriaged items (worker discoveries)
bash "$SCRIPT_DIR/scripts/backlog.sh" update "$(pwd)" "<item-id>" triaged true
bash "$SCRIPT_DIR/scripts/backlog.sh" update "$(pwd)" "<item-id>" priority 2
```

**If phase is "directed":**
- Break the user's mission into the next logical step
- Consider what previous sprints accomplished (read previous sprint summaries)
- Give a concrete, focused direction for this sprint
- If the mission has more work than fits in one sprint, add deferred items to
  the backlog for later:
  ```bash
  bash "$SCRIPT_DIR/scripts/backlog.sh" add "$(pwd)" "Deferred task title" "Full description" conductor 3
  ```

**If phase is "exploring":**
- Scan the project to score each dimension (fast heuristics, not a full audit):
  ```bash
  bash "$SCRIPT_DIR/scripts/explore-scan.sh" "$(pwd)" "$SCRIPT_DIR/scripts/conductor-state.sh"
  ```
- Pick the weakest dimension (now informed by scan scores):
  ```bash
  bash "$SCRIPT_DIR/scripts/conductor-state.sh" explore-pick "$(pwd)"
  ```
- Map that dimension to a concrete sprint direction:
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
  BACKLOG_ITEM=$(bash "$SCRIPT_DIR/scripts/backlog.sh" pick "$(pwd)" 2>/dev/null) || true
  ```
- If an item was returned, use its description as the sprint direction
- If backlog is also empty, the project is genuinely solid — stop the session

### 2. Dispatch — Run the Sprint

Register the sprint:
```bash
bash "$SCRIPT_DIR/scripts/conductor-state.sh" sprint-start "$(pwd)" "$SPRINT_DIRECTION"
```

Create a sprint branch off the conductor branch. Each sprint works in
isolation — successful sprints merge back, failed ones get discarded.

```bash
SPRINT_NUM=$(python3 -c "import json; d=json.load(open('.autonomous/conductor-state.json')); print(len(d['sprints']))")
SPRINT_BRANCH="${SESSION_BRANCH}/sprint-${SPRINT_NUM}"
git checkout -b "$SPRINT_BRANCH"
```

Write the sprint master prompt and dispatch via `claude -p` in tmux for
true context isolation. Each sprint gets a fresh context window.

```bash
PREV_SUMMARY=""
[ -f ".autonomous/sprint-$((SPRINT_NUM-1))-summary.json" ] && \
  PREV_SUMMARY=$(cat ".autonomous/sprint-$((SPRINT_NUM-1))-summary.json")

# Get title-only backlog for sprint master context (lightweight, no descriptions)
BACKLOG_TITLES=$(bash "$SCRIPT_DIR/scripts/backlog.sh" list "$(pwd)" open titles-only 2>/dev/null || echo "")

cat > .autonomous/sprint-prompt.md << SPRINT_EOF
You are a sprint master. Read SPRINT.md at $SCRIPT_DIR/SPRINT.md and follow it.

PROJECT: $(pwd)
SPRINT_NUMBER: $SPRINT_NUM
SPRINT_DIRECTION: $SPRINT_DIRECTION
PREVIOUS_SUMMARY: $PREV_SUMMARY
BACKLOG_TITLES: $BACKLOG_TITLES
LEARNINGS: $LEARNINGS

Begin immediately. Dispatch your worker and drive the sprint to completion.
When done, write .autonomous/sprint-summary.json with the results.
SPRINT_EOF

# Create wrapper script — tmux cannot use claude -p or stdin redirect reliably
cat > .autonomous/run-sprint.sh << RUNEOF
#!/bin/bash
cd $(pwd)
PROMPT=\$(cat .autonomous/sprint-prompt.md)
exec claude --dangerously-skip-permissions "\$PROMPT"
RUNEOF
chmod +x .autonomous/run-sprint.sh

# Dispatch in tmux (visible to user) or headless
if command -v tmux &>/dev/null && tmux info &>/dev/null; then
  tmux new-window -n "sprint-$SPRINT_NUM" "bash $(pwd)/.autonomous/run-sprint.sh"
  echo "Sprint $SPRINT_NUM launched in tmux window 'sprint-$SPRINT_NUM'"
else
  bash .autonomous/run-sprint.sh > .autonomous/sprint-output.log 2>&1 &
  SPRINT_PID=$!
  echo "Sprint $SPRINT_NUM PID: $SPRINT_PID"
fi
```

### 3. Monitor — Wait for Sprint Completion

Poll for sprint completion. The sprint master writes
`.autonomous/sprint-summary.json` when done.

```bash
SUMMARY_FILE=".autonomous/sprint-$SPRINT_NUM-summary.json"
_LAST_COMMIT=$(git log --oneline -1 2>/dev/null)
while true; do
  # Check for sprint summary file
  if [ -f "$SUMMARY_FILE" ]; then
    echo "=== SPRINT $SPRINT_NUM COMPLETE ==="
    cat "$SUMMARY_FILE"
    break
  fi
  # Also check generic sprint-summary.json (sprint master may use this)
  if [ -f ".autonomous/sprint-summary.json" ]; then
    cp ".autonomous/sprint-summary.json" "$SUMMARY_FILE"
    rm -f ".autonomous/sprint-summary.json"
    echo "=== SPRINT $SPRINT_NUM COMPLETE ==="
    cat "$SUMMARY_FILE"
    break
  fi
  # tmux window check
  if command -v tmux &>/dev/null && tmux info &>/dev/null; then
    if ! tmux list-windows 2>/dev/null | grep -q "sprint-$SPRINT_NUM"; then
      echo "=== SPRINT $SPRINT_NUM WINDOW CLOSED ==="
      # Check if summary was written before exit
      if [ -f ".autonomous/sprint-summary.json" ]; then
        cp ".autonomous/sprint-summary.json" "$SUMMARY_FILE"
        rm -f ".autonomous/sprint-summary.json"
      fi
      break
    fi
  elif [ -n "${SPRINT_PID:-}" ]; then
    if ! kill -0 "$SPRINT_PID" 2>/dev/null; then
      echo "=== SPRINT $SPRINT_NUM PROCESS EXITED ==="
      if [ -f ".autonomous/sprint-summary.json" ]; then
        cp ".autonomous/sprint-summary.json" "$SUMMARY_FILE"
        rm -f ".autonomous/sprint-summary.json"
      fi
      break
    fi
  fi
  sleep 8
done
```

### 4. Evaluate — Read Results and Decide Next

**Close the sprint tmux window** if it's still open:
```bash
if command -v tmux &>/dev/null && tmux info &>/dev/null; then
  tmux kill-window -t "sprint-$SPRINT_NUM" 2>/dev/null || true
fi
```

Read the sprint summary and update conductor state:

```bash
if [ -f "$SUMMARY_FILE" ]; then
  STATUS=$(python3 -c "import json; print(json.load(open('$SUMMARY_FILE')).get('status','unknown'))" 2>/dev/null || echo "unknown")
  SUMMARY=$(python3 -c "import json; print(json.load(open('$SUMMARY_FILE')).get('summary','No summary'))" 2>/dev/null || echo "No summary")
  COMMITS=$(python3 -c "import json; print(json.dumps(json.load(open('$SUMMARY_FILE')).get('commits',[])))" 2>/dev/null || echo "[]")
  DIR_COMPLETE=$(python3 -c "import json; print(str(json.load(open('$SUMMARY_FILE')).get('direction_complete',False)).lower())" 2>/dev/null || echo "false")
else
  # No summary file — construct from git log
  STATUS="unknown"
  LATEST=$(git log --oneline -1 2>/dev/null)
  if [ "$LATEST" != "$_LAST_COMMIT" ]; then
    SUMMARY="Sprint completed with new commits (no summary file)."
    COMMITS=$(git log --oneline -5 2>/dev/null | python3 -c "import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))")
    STATUS="complete"
  else
    SUMMARY="Sprint completed with no new commits."
    COMMITS="[]"
    STATUS="partial"
  fi
  DIR_COMPLETE="false"
fi

PHASE=$(bash "$SCRIPT_DIR/scripts/conductor-state.sh" sprint-end "$(pwd)" "$STATUS" "$SUMMARY" "$COMMITS" "$DIR_COMPLETE")
echo "Phase after sprint $SPRINT_NUM: $PHASE"

# If this sprint consumed a backlog item, mark it done
if [ -n "${BACKLOG_ITEM_ID:-}" ] && [ "$STATUS" = "complete" ]; then
  bash "$SCRIPT_DIR/scripts/backlog.sh" update "$(pwd)" "$BACKLOG_ITEM_ID" status done 2>/dev/null || true
  bash "$SCRIPT_DIR/scripts/backlog.sh" update "$(pwd)" "$BACKLOG_ITEM_ID" sprint "$SPRINT_NUM" 2>/dev/null || true
fi
```

**Verify independently** (don't just trust the summary):
- Check `git log --oneline -5` for new commits
- Run project tests if they exist (`npm test`, `pytest`, etc.)
- Read any files the sprint claimed to create

If the sprint master reported "direction_complete: true" but git shows no
commits, override to "false".

**Merge or discard the sprint branch:**

```bash
# Switch back to conductor branch
git checkout "$SESSION_BRANCH"

if [ "$STATUS" = "complete" ] || [ "$STATUS" = "partial" ]; then
  # Merge sprint results into conductor branch
  HAS_COMMITS=$(git log "$SESSION_BRANCH".."$SPRINT_BRANCH" --oneline 2>/dev/null | head -1)
  if [ -n "$HAS_COMMITS" ]; then
    git merge --no-ff "$SPRINT_BRANCH" -m "sprint $SPRINT_NUM: $SUMMARY"
    echo "Sprint $SPRINT_NUM merged into $SESSION_BRANCH"
  else
    echo "Sprint $SPRINT_NUM had no commits, skipping merge"
  fi
else
  echo "Sprint $SPRINT_NUM discarded ($STATUS)"
fi

# Clean up sprint branch
git branch -D "$SPRINT_BRANCH" 2>/dev/null || true
```

**If exploring**: Score the dimension after the sprint:
```bash
if [ "$PHASE" = "exploring" ]; then
  # Score based on sprint outcome (0-10)
  bash "$SCRIPT_DIR/scripts/conductor-state.sh" explore-score "$(pwd)" "$DIMENSION" "$SCORE"
fi
```

### 5. Repeat

Continue to the next sprint. Stop when:
- All sprints are used up (`MAX_SPRINTS` reached)
- The project genuinely feels solid (no more weak dimensions)
- Every sprint in exploring phase returned "nothing to improve"

## Boundaries

- Never invoke /ship, /land-and-deploy, /careful, or /guard.
- If a sprint can't make progress twice on the same direction, move on.
- Keep going until sprints are used up or the project genuinely feels solid.

## Begin

Start now. Feel the project. Plan your first sprint direction. Dispatch.
