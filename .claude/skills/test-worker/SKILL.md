---
name: test-worker
description: Test the autonomous worker pipeline end-to-end. Spawns a worker, acts as master, auto-answers via comms protocol.
user-invocable: true
---

# Test Worker Pipeline

Automated master that spawns a worker and drives the full skill pipeline
(office-hours → eng-review → design-review → build) using the comms protocol.

## Setup

```bash
# Clean previous test artifacts
SANDBOX="/Volumes/ssd/i/auto-tool-workspace/disk-clean"
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"
git init
echo "# DiskClean" > README.md
mkdir -p .autonomous tests
echo "STATUS: IDLE" > .autonomous/comms.md
git add . && git commit -m "init"

# Clean gstack cache for this project
rm -f ~/.gstack/projects/disk-clean/*.md ~/.gstack/projects/disk-clean/*.jsonl 2>/dev/null
echo "Sandbox ready: $SANDBOX"
```

## Owner Context

You are the master/owner. This is your product vision — use it to answer
every question the worker asks via comms.md:

**Product:** DiskClean — intelligent disk space manager for macOS.
**Tech:** React + TypeScript + Electron.

**The pain:** I have a 256GB Mac Mini and constantly run into storage pressure.
Every few weeks I have to manually hunt through folders deciding what to delete,
what to move to external storage, and what to keep. Existing tools like DaisyDisk
show me disk usage but don't help me decide what's safe to clean. CleanMyMac
deletes caches but doesn't touch my actual files intelligently. I want something
that understands my files and says "these 8GB of old downloads are safe to remove,
these project files haven't been opened in 6 months — archive them?"

**Hypothesis:** Competitive gap analysis + third-party research (Smallpdf survey:
4.5hrs/week lost to file searching). Existing paid tools like Hazel ($42) and
Sparkle ($5/mo) validated willingness to pay, but user reviews reveal a clear
unmet need: content-aware file organization without manual rule setup. No
one-time-purchase tool fills this gap.

**Key decisions (pre-decided):**
- Mode: Building a startup
- Demand: Own pain, firsthand experience, not yet validated with others
- Target user: "Saturday afternoon Jason" — indie dev/CS student, 24-32, base-model Mac, hits disk full mid-side-project
- Competitive landscape: DaisyDisk (visualization only), CleanMyMac (caches only), Hazel (rules required), Sparkle (subscription)
- Pricing: $29 one-time, launch at $14.99 (50% discount)
- Core insight: Decision support, not visualization. "Here's what's safe and why."
- Trust is the product: Conversational reasons, cleanup history, Trash-as-undo
- Approach: Ship in 2 days. Electron V1 (Swift V2 if it works). No ML, no menubar, no background process.
- Design: iOS-style, Apple HIG. Restraint. No confetti. No tab bar — utility app pattern.
- Tests: In tests/ with structured observability. Comprehensive QA, not just happy path.

## Dispatch Worker

Spawn the worker via the Agent tool with this prompt. Run it in the background.

---BEGIN WORKER PROMPT---

WORKER CONTEXT: You are an engineer executing a direction from the project owner.
You are running as a subagent in autonomous mode.

PROJECT DIRECTORY: /Volumes/ssd/i/auto-tool-workspace/disk-clean
TECH STACK: React + TypeScript + Electron

TOOL CONSTRAINTS:
- You have: Bash, Read, Edit, Write, Grep, Glob, Skill, ToolSearch
- You may have: MCP tools (claude-peers) — use if available for status updates
- You do NOT have: AskUserQuestion, WebSearch, WebFetch, Agent
- If a skill needs browser/web tools, skip that step and use Bash + curl

COMMS PROTOCOL (replaces AskUserQuestion):
Every time a skill says "ask via AskUserQuestion" or presents options,
you MUST use this file-based protocol.

1. Write to /Volumes/ssd/i/auto-tool-workspace/disk-clean/.autonomous/comms.md:
   ```
   STATUS: WAITING
   ## Question
   [exact question from the skill, word for word]
   ## Options
   [exact options from the skill]
   ## Worker Recommendation
   [your recommendation with reasoning, or "None"]
   ## Context
   [which skill, which phase, which step]
   ```

2. Poll until the master answers:
   ```bash
   while true; do
     if grep -q '^STATUS: ANSWERED' /Volumes/ssd/i/auto-tool-workspace/disk-clean/.autonomous/comms.md; then break; fi
     sleep 3
   done
   ```

3. Read the ## Answer section and continue the skill with the owner's EXACT answer.

RULES:
- Do this for EVERY AskUserQuestion. No exceptions.
- Do NOT answer questions yourself.
- Do NOT skip or batch questions.
- Do NOT self-approve deliverables.
- During build phase: proceed without comms if owner says so.

OWNER'S DIRECTION:
Build DiskClean — an intelligent disk space manager for macOS. iOS-style design,
comprehensive tests in tests/ with observability, production-quality code.

YOUR PIPELINE:
1. /office-hours — product thinking, every question through comms
2. /plan-eng-review — architecture review, every decision through comms
3. /plan-design-review — UI/UX review, iOS aesthetic
4. Build — implement the MVP, commit when done

Start Phase 1 now. Invoke /office-hours via the Skill tool.

---END WORKER PROMPT---

## Master Loop

After dispatching the worker, run the master polling loop. For EVERY question
that appears in comms.md with STATUS: WAITING:

1. Read the question, options, and worker recommendation
2. Answer as the owner using the Owner Context above
3. Apply your product judgment — don't rubber-stamp recommendations
4. Write the answer to comms.md with STATUS: ANSWERED
5. Restart the poll

**Decision principles (when the skill asks and you must choose):**
- When asked about mode/goal → "Building a startup"
- When asked about demand → Own pain, firsthand, 256GB Mac Mini, recurring every 2-3 weeks
- When asked about target user → "Saturday afternoon Jason" persona (see Owner Context)
- When asked about competitive landscape → DaisyDisk/CleanMyMac/Hazel/Sparkle gaps
- When asked about premises → Agree with most, but insist on $29 pricing, expand target beyond just devs
- When asked about approach → Hybrid A+B: ship fast + trust core
- When asked about design → iOS-style, no tab bar, no confetti, restraint
- When asked to approve → Approve if it reflects Owner Context decisions. Override if not.
- When build phase starts → Tell worker "no more questions until done or stuck"

**How to answer:**
Write answers that are specific, opinionated, and grounded in the Owner Context.
Don't be generic. Reference specific numbers ($29, 256GB, 30-60 minutes), specific
competitors (DaisyDisk, CleanMyMac), and specific user moments ("Saturday afternoon,
npm install fails, ENOSPC"). The quality of the worker's output depends on the
quality of your answers.

**Polling template:**
```bash
while true; do
  if grep -q '^STATUS: WAITING' /Volumes/ssd/i/auto-tool-workspace/disk-clean/.autonomous/comms.md; then
    cat /Volumes/ssd/i/auto-tool-workspace/disk-clean/.autonomous/comms.md
    break
  fi
  sleep 3
done
```

After reading, write your answer:
```bash
cat > /Volumes/ssd/i/auto-tool-workspace/disk-clean/.autonomous/comms.md << 'EOF'
STATUS: ANSWERED

## Question
[echo the question back]

## Answer
[your answer]
EOF
```

Then restart the poll for the next question. Continue until the worker completes.

## Completion

When the worker agent finishes:
1. Run `cd /Volumes/ssd/i/auto-tool-workspace/disk-clean && npm test` to verify
2. Count files: `find src tests -type f | wc -l`
3. Report: how many comms rounds, how many overrides, test results, file count
4. Save the comms log for analysis
