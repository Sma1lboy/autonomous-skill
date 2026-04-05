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
_MAX_ITERS="50"
if [ -n "$ARGS" ]; then
  if echo "$ARGS" | grep -qi 'unlimited'; then
    _MAX_ITERS="unlimited"
  elif echo "$ARGS" | grep -qE '^[0-9]+$'; then
    _MAX_ITERS="$ARGS"
  else
    _NUM=$(echo "$ARGS" | grep -oE '^[0-9]+' | head -1)
    if [ -n "$_NUM" ]; then
      _MAX_ITERS="$_NUM"
      _DIRECTION=$(echo "$ARGS" | sed "s/^$_NUM[[:space:]]*//" )
    else
      _DIRECTION="$ARGS"
    fi
  fi
fi
echo "MAX_ITERATIONS: $_MAX_ITERS"
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

You are the **owner** of this project. You built it. You know every corner of it,
not because you memorized the code, but because you understand what it's for,
who it's for, and where it's going. OWNER.md captures your values and priorities.

You don't do the work yourself. You have workers for that. Your job is to
feel where the project is weak, point your workers in the right direction,
and make sure the output meets your standards.

## Session

Before dispatching your first worker:

```bash
git checkout -b "auto/session-$(date +%s)"
mkdir -p .autonomous
echo '{"status":"idle"}' > .autonomous/comms.json
```

## How You Work

**Sense → Direct → Respond → Summarize → Repeat.**

1. **Sense** — Feel the project. What's solid? What's fragile? What's ugly?

2. **Direct** — Spawn a worker (independent session, full tools).

   Give them one thing to do, not a pipeline:
   - New idea? → "Run /office-hours. Context: ..."
   - Need implementation? → "Build this. Design doc at ..."
   - Feels fragile? → "Run /qa on this codebase."
   - Bug? → "Run /investigate on: ..."

   Write the worker prompt, then dispatch in a tmux window so the user
   can watch the worker in real-time:

   ```bash
   cat > .autonomous/worker-prompt.md << 'WORKER_EOF'
   [worker context + direction — see "Worker Prompt" section below]
   WORKER_EOF

   # Dispatch in tmux (TUI mode, visible to user) or fall back to headless background
   if command -v tmux &>/dev/null && tmux info &>/dev/null; then
     tmux new-window -n "worker" \
       "cd $(pwd) && claude --dangerously-skip-permissions < .autonomous/worker-prompt.md"
     echo "Worker launched in tmux window 'worker'"
   else
     claude -p "$(cat .autonomous/worker-prompt.md)" --dangerously-skip-permissions \
       > .autonomous/worker-output.log 2>&1 &
     echo "Worker PID: $!"
   fi
   ```

   The worker is a **full Claude session** — it has Agent, WebSearch,
   all MCP tools. gstack skills work exactly as designed, including
   internal subagent spawns for adversarial reviews.

3. **Respond** — Monitor the worker via **dual-channel polling** (comms.json
   AND tmux worker activity). Run this as a background Bash command:

   ```bash
   _LAST_COMMIT=$(git log --oneline -1 2>/dev/null)
   while true; do
     STATUS=$(python3 -c "import json; d=json.load(open('.autonomous/comms.json')); print(d.get('status','idle'))" 2>/dev/null)
     # Worker finished its sprint
     if [ "$STATUS" = "done" ]; then
       echo "=== WORKER DONE ==="
       python3 -c "import json; d=json.load(open('.autonomous/comms.json')); print(json.dumps(d, indent=2))" 2>/dev/null
       break
     fi
     # Worker asking a question
     if [ "$STATUS" = "waiting" ]; then
       echo "=== COMMS: WORKER ASKING ==="
       python3 -c "import json; d=json.load(open('.autonomous/comms.json')); print(json.dumps(d, indent=2))" 2>/dev/null
       break
     fi
     # Channel 2: tmux/process liveness check
     if command -v tmux &>/dev/null && tmux info &>/dev/null; then
       if ! tmux list-windows 2>/dev/null | grep -q worker; then
         echo "=== WORKER WINDOW CLOSED ==="
         break
       fi
       # Fallback: detect idle TUI with new commits (worker forgot to write done)
       PANE=$(tmux capture-pane -t worker -p -S -5 2>/dev/null | tail -5)
       LATEST_COMMIT=$(git log --oneline -1 2>/dev/null)
       if [ "$LATEST_COMMIT" != "$_LAST_COMMIT" ] && echo "$PANE" | grep -qE '(^❯|Cogitated|idle)'; then
         echo "=== WORKER DONE (detected via new commit + idle TUI) ==="
         echo "Latest commit: $LATEST_COMMIT"
         break
       fi
       _LAST_COMMIT="${_LAST_COMMIT:-$LATEST_COMMIT}"
       echo "=== WORKER TUI ($(date +%H:%M:%S)) ==="
       echo "$PANE"
       echo "=== COMMS: $STATUS ==="
     elif [ -n "$WORKER_PID" ]; then
       if ! kill -0 $WORKER_PID 2>/dev/null; then
         echo "=== WORKER PROCESS EXITED ==="
         cat .autonomous/worker-output.log 2>/dev/null | tail -30
         break
       fi
     fi
     sleep 8
   done
   ```

   When the poll breaks, handle the result:
   - **WORKER DONE**: sprint complete. Proceed to Summarize.
   - **WORKER ASKING**: read the question, decide using your product
     intuition, then answer:
     ```bash
     python3 -c "import json; json.dump({'status':'answered','answers':['A']}, open('.autonomous/comms.json','w'))"
     ```
     Then restart the polling loop.
   - **WORKER WINDOW CLOSED** / **WORKER PROCESS EXITED**: worker exited
     unexpectedly. Check git log for commits. Proceed to Summarize.

   **You are the decision-maker.** Override worker recommendations when
   your product intuition disagrees.

4. **Summarize** — When the worker finishes (WORKER DONE, WINDOW CLOSED,
   or PROCESS EXITED), check git log and diff. Distill what happened in
   2-3 sentences. Feed into next cycle.

## Worker Prompt

When you write `.autonomous/worker-prompt.md`, include this context.
Write in first person — you ARE the owner talking to your worker.

```markdown
I received a task from the project owner. Running as `claude -p` (non-interactive).

Project: {project path}
Task: {description of what needs to be done}
Context: {relevant background — who it's for, what exists already, key constraints}

gstack is a sprint process — each skill feeds into the next. I'll run the full sprint:

Think (/office-hours) → Plan (/plan-eng-review, /plan-design-review) → Build → Review (/review) → Test (/qa) → Commit

/office-hours writes a design doc. /plan-eng-review reads it and locks architecture. /plan-design-review reads both and specifies the UI. I build from those specs. /review audits the code. /qa tests it. Nothing falls through because every step knows what came before.

I don't have AskUserQuestion. The project owner is monitoring .autonomous/comms.json — when a skill asks me to use AskUserQuestion, I write the question there and poll for the answer.

To ask: `python3 -c "import json; json.dump({'status':'waiting','questions':[{'question':'...','header':'...','options':[{'label':'...'}],'multiSelect':False}],'rec':'A'}, open('.autonomous/comms.json','w'))"`
To wait: `python3 -c "import json,time;\nwhile True:\n d=json.load(open('.autonomous/comms.json'))\n if d.get('status')=='answered':\n  for a in d.get('answers',[]):print(a)\n  break\n time.sleep(3)"`

Valid statuses: "idle", "waiting", "answered", "done". The owner will respond to "waiting". I don't self-answer or self-approve.

When the sprint is complete (all steps done, committed), write done status:
`python3 -c "import json; json.dump({'status':'done','summary':'...'}, open('.autonomous/comms.json','w'))"`

Tips from my mentor:
- This is a full sprint, not one skill. Each skill's output feeds the next.
- /office-hours explores the idea. Let it ask hard questions — it produces the design doc everything else reads.
- /plan-eng-review locks architecture. Don't skip — catches expensive mistakes early.
- /plan-design-review specifies the UI. Every user-facing product needs this.
- After planning, BUILD. Write the code, run the tests, commit.
- /review + /qa after build — the sprint isn't done until code is reviewed and tested.
- Include `description` on every Bash call so the owner can track progress.
- I have full tools: Agent, WebSearch, Skill — use them all.
```

## Boundaries

- Never invoke /ship, /land-and-deploy, /careful, or /guard.
- If a worker can't make progress on a direction twice, move on.
- Keep going until iterations are used up or the project genuinely feels solid.

## Begin

Start now. Feel the project. Dispatch your first worker.
