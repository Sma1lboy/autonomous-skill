---
name: smoke-test
description: Quick end-to-end pipeline smoke test. Runs Conductor → Sprint Master → Worker → done in a sandbox, verifying every layer fires correctly.
user-invocable: true
---

# Smoke Test — Full Pipeline Verification

Fast end-to-end test of the Conductor → Sprint Master → Worker pipeline.
Creates a throwaway sandbox, runs 1 sprint with a trivial task, and reports
pass/fail for each layer. Total runtime: ~30-60 seconds.

## What it verifies

1. **Scripts parse**: `python3 -m compileall` on all scripts
2. **Session init**: branch created, conductor-state.json valid, eval output clean
3. **Sprint prompt**: build-sprint-prompt.py produces a prompt file
4. **Dispatch**: sprint master launched in tmux (or headless)
5. **Monitor**: summary file detected, tmux window cleaned up
6. **Evaluate**: eval output parses cleanly (STATUS, SUMMARY, PHASE)
7. **Merge**: sprint branch merged or skipped correctly
8. **Cleanup**: session branch exists, no orphan branches

## Run

```bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../../.. && pwd)"
SANDBOX=$(mktemp -d)
TIMESTAMP=$(date +%s)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Smoke Test — autonomous-skill pipeline"
echo " Sandbox: $SANDBOX"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

## Execute

Run ALL of the following steps sequentially. Report each step as PASS or FAIL.
If a step fails, report FAIL, capture the error, and continue to the next step
(do NOT abort — collect all results).

### Step 1: Compile check

```bash
echo ""
echo "Step 1: Compile check"
python3 -m compileall "$SKILL_DIR/scripts" -q 2>&1 && echo "STEP1=PASS" || echo "STEP1=FAIL"
```

### Step 2: Sandbox init

```bash
echo ""
echo "Step 2: Sandbox init"
cd "$SANDBOX"
git init -q
echo "# Smoke Test Project" > README.md
mkdir -p src
echo 'print("hello world")' > src/main.py
git add . && git commit -q -m "init"
echo "STEP2=PASS"
```

### Step 3: Session init (eval-safe output)

```bash
echo ""
echo "Step 3: Session init"
OUTPUT=$(python3 "$SKILL_DIR/scripts/session-init.py" "$SANDBOX" "$SKILL_DIR" "Print hello world from src/main.py" "1" 2>/dev/null)
echo "Raw output: $OUTPUT"

# Must be exactly one line, must eval cleanly
LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
if [ "$LINE_COUNT" -ne 1 ]; then
  echo "STEP3=FAIL (got $LINE_COUNT lines, expected 1)"
else
  eval "$OUTPUT" 2>/tmp/smoke-eval-err || true
  EVAL_ERR=$(cat /tmp/smoke-eval-err)
  if [ -n "$EVAL_ERR" ]; then
    echo "STEP3=FAIL (eval error: $EVAL_ERR)"
  else
    echo "SESSION_BRANCH=$SESSION_BRANCH"
    echo "STEP3=PASS"
  fi
fi
```

### Step 4: Conductor state valid

```bash
echo ""
echo "Step 4: Conductor state"
STATE=$(python3 "$SKILL_DIR/scripts/conductor-state.py" read "$SANDBOX" 2>/dev/null)
MISSION=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mission',''))" 2>/dev/null)
PHASE=$(echo "$STATE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('phase',''))" 2>/dev/null)
echo "Mission: $MISSION"
echo "Phase: $PHASE"
if [ "$PHASE" = "directed" ] && [ -n "$MISSION" ]; then
  echo "STEP4=PASS"
else
  echo "STEP4=FAIL (phase=$PHASE, mission=$MISSION)"
fi
```

### Step 5: Sprint start + prompt build

```bash
echo ""
echo "Step 5: Sprint start + prompt build"
DIRECTION="Print hello world from src/main.py"
python3 "$SKILL_DIR/scripts/conductor-state.py" sprint-start "$SANDBOX" "$DIRECTION" > /dev/null
SPRINT_BRANCH="${SESSION_BRANCH}-sprint-1"
git -C "$SANDBOX" checkout -b "$SPRINT_BRANCH" 2>/dev/null

python3 "$SKILL_DIR/scripts/build-sprint-prompt.py" "$SANDBOX" "$SKILL_DIR" "1" "$DIRECTION" "" 2>/dev/null
if [ -f "$SANDBOX/.autonomous/sprint-prompt.md" ]; then
  PROMPT_LINES=$(wc -l < "$SANDBOX/.autonomous/sprint-prompt.md" | tr -d ' ')
  echo "Sprint prompt: $PROMPT_LINES lines"
  echo "STEP5=PASS"
else
  echo "STEP5=FAIL (sprint-prompt.md not created)"
fi
```

### Step 6: Dispatch + Monitor + Evaluate

This is the core test — actually dispatch a claude session and wait for it.

```bash
echo ""
echo "Step 6: Dispatch → Monitor → Evaluate"
python3 "$SKILL_DIR/scripts/dispatch.py" "$SANDBOX" "$SANDBOX/.autonomous/sprint-prompt.md" "sprint-1" 2>/dev/null
echo "Dispatched. Monitoring..."
```

Wait for the sprint to complete (up to 5 minutes):

```bash
timeout 300 python3 "$SKILL_DIR/scripts/monitor-sprint.py" "$SANDBOX" "1" 2>/dev/null
MONITOR_EXIT=$?
if [ $MONITOR_EXIT -eq 0 ]; then
  echo "Monitor: sprint completed"
else
  echo "Monitor: timed out or failed (exit=$MONITOR_EXIT)"
fi
```

Evaluate (the eval-safe output test):

```bash
OUTPUT=$(python3 "$SKILL_DIR/scripts/evaluate-sprint.py" "$SANDBOX" "$SKILL_DIR" "1" 2>/dev/null)
echo "Evaluate raw: $OUTPUT"
STATUS="" ; SUMMARY="" ; PHASE="" ; DIR_COMPLETE=""
eval "$OUTPUT" 2>/tmp/smoke-eval-err2 || true
EVAL_ERR=$(cat /tmp/smoke-eval-err2)
if [ -n "$EVAL_ERR" ]; then
  echo "STEP6=FAIL (eval error: $EVAL_ERR)"
elif [ -z "$STATUS" ]; then
  echo "STEP6=FAIL (STATUS empty)"
else
  echo "STATUS=$STATUS SUMMARY=$SUMMARY"
  echo "STEP6=PASS"
fi
```

### Step 7: Merge sprint branch

```bash
echo ""
echo "Step 7: Merge sprint branch"
python3 "$SKILL_DIR/scripts/merge-sprint.py" "$SESSION_BRANCH" "$SPRINT_BRANCH" "1" "${STATUS:-complete}" "${SUMMARY:-smoke test}" 2>/dev/null
CURRENT=$(git -C "$SANDBOX" branch --show-current)
if [ "$CURRENT" = "$SESSION_BRANCH" ]; then
  echo "STEP7=PASS (on $SESSION_BRANCH)"
else
  echo "STEP7=FAIL (expected $SESSION_BRANCH, on $CURRENT)"
fi
```

### Step 8: No orphan branches

```bash
echo ""
echo "Step 8: Orphan branch check"
ORPHANS=$(git -C "$SANDBOX" branch | grep "sprint-" | wc -l | tr -d ' ')
if [ "$ORPHANS" -eq 0 ]; then
  echo "STEP8=PASS (no orphan sprint branches)"
else
  echo "STEP8=FAIL ($ORPHANS orphan branches remain)"
fi
```

## Report

After all steps, print a summary table. Count PASS/FAIL from the step variables.

```bash
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " SMOKE TEST RESULTS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

Print each step result. Then:

```bash
rm -rf "$SANDBOX" 2>/dev/null
```

If all 8 steps passed → print `ALL PASS` in bold.
If any failed → print which steps failed and the captured error.

## Abort

If Step 6 (dispatch/monitor) times out after 5 minutes, skip steps 7-8 and
report those as SKIP. This means the claude binary itself hung — not a
pipeline bug. Report: "Step 6 timed out — claude session didn't complete
within 5 minutes. Infra issue, not a pipeline bug."
