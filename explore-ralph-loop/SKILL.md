---
name: explore-ralph-loop
description: Analyzes your conversation history with Claude to detect Ralph Loop patterns (execute→verify→fix→done cycles), then captures them as reusable skills that auto-run via /quickdo.
user-invocable: true
---

# Explore Ralph Loop

Analyzes your current conversation with Claude to detect Ralph Loop patterns —
repetitive execute→verify→fix→verify→done cycles you've been doing manually.
When it finds one, it captures the pattern as a reusable skill so next time the
loop runs automatically via `/quickdo`.

This is NOT a project scanner. It reads YOUR conversation to find loops YOU
already triggered — the commands you ran, the errors you hit, how you fixed them,
what you verified, and when you considered it done.

## Startup

```bash
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")"
if [ ! -d "$SCRIPT_DIR/scripts" ]; then
  for dir in ~/.claude/skills/autonomous-skill /Volumes/ssd/i/auto-tool-workspace/autonomous-skill; do
    if [ -d "$dir/scripts" ]; then SCRIPT_DIR="$dir"; break; fi
  done
fi
RALPH_DIR="$SCRIPT_DIR/ralph-loop-skills"
mkdir -p "$RALPH_DIR"
echo "SCRIPT_DIR=$SCRIPT_DIR"
echo "RALPH_DIR=$RALPH_DIR"
# List existing loops
if ls "$RALPH_DIR"/*/SKILL.md >/dev/null 2>&1; then
  echo "=== EXISTING RALPH LOOPS ==="
  for f in "$RALPH_DIR"/*/SKILL.md; do
    name=$(basename "$(dirname "$f")")
    desc=$(grep "^description:" "$f" | head -1 | sed 's/^description: //')
    echo "  /$name — $desc"
  done
else
  echo "No Ralph Loop skills recorded yet."
fi
```

## First Actions

Run the Startup block. Then decide based on ARGS:

1. If ARGS is "list" → show existing loops (already printed by Startup) and stop
2. If ARGS is "delete <name>" → delete that loop's directory under `$RALPH_DIR` and
   re-register (`bash "$SCRIPT_DIR/scripts/register-ralph-loops.sh"`), then stop
3. If ARGS contains a description → the user is telling you what loop they want
   captured. Use it as context, proceed to Detect
4. If ARGS is empty → proceed to Detect

## Detect

Review the **current conversation history** to identify Ralph Loop patterns.
You have full access to the conversation context — look backwards through it.

### What to look for

A Ralph Loop is any sequence where the user (or you, acting for the user) did:

1. **Execute** — ran a command, wrote code, performed an action
2. **Verify** — checked if it worked (ran tests, built, checked output, opened browser)
3. **Fix** — something failed, so you fixed the source/config/etc.
4. **Verify again** — re-ran the verification
5. **Repeat** steps 2-4 until everything passed
6. **Done** — moved on to the next thing

### Concrete patterns to detect

- Build-fix cycles: `cargo build` → fix errors → `cargo build` → pass
- Test-fix cycles: `npm test` → fix failures → `npm test` → pass
- Lint-fix cycles: `ruff check .` → fix warnings → `ruff check .` → clean
- Type-check cycles: `tsc --noEmit` → fix type errors → `tsc --noEmit` → pass
- Multi-phase chains: build → test → lint (each with its own fix cycle)
- Custom loops: migration → verify schema → seed → verify data → done
- Deploy loops: deploy → health check → fix config → redeploy → health check → pass
- Any other repetitive execute→verify→fix pattern specific to this project

### How to extract the pattern

For each loop detected, extract:

| Field | Source |
|-------|--------|
| **Commands** | The actual shell commands used in the conversation |
| **Order** | The sequence they were run in |
| **Failure signals** | What the error output looked like (compiler errors, test failures, etc.) |
| **Fix strategy** | What kind of fixes were applied (edit source, update config, add imports, etc.) |
| **Done condition** | What "success" looked like (exit code 0, all tests pass, clean output) |

### Present findings

Tell the user what loop pattern you detected. Be specific — show the actual
commands and sequence from the conversation. Example:

> I detected this Ralph Loop in our conversation:
>
> 1. **Build**: `cargo build` — you ran this 3 times, fixing import errors and type mismatches
> 2. **Test**: `cargo test` — you ran this 2 times, fixing one assertion
> 3. **Lint**: `cargo clippy -- -D warnings` — ran once, clean
>
> Want me to capture this as a reusable `/<name>` skill?

If no loop pattern is found in the conversation, tell the user:

> I don't see a Ralph Loop pattern in our conversation yet. Try running
> `/explore-ralph-loop` after you've gone through an execute→verify→fix cycle,
> or describe the loop you want to capture.

Ask the user to confirm or adjust. They might rename phases, add/remove steps,
or change commands. Incorporate their feedback.

## Capture

Once confirmed, structure the loop:

| Field | Description |
|-------|-------------|
| **name** | Kebab-case identifier derived from the loop (e.g., `rust-build-test`, `next-typecheck-lint`) |
| **description** | One-line summary of what this loop automates |
| **phases** | Ordered list of execute→verify→fix phases with their commands |
| **done condition** | What signals the entire loop is complete |

## Generate

Generate the skill file. The generated skill delegates execution to `/quickdo`
with a canned direction encoding the full loop.

```bash
LOOP_NAME="<name>"
LOOP_DIR="$RALPH_DIR/$LOOP_NAME"
mkdir -p "$LOOP_DIR"
```

Write `$LOOP_DIR/SKILL.md` following this template:

````markdown
---
name: <loop-name>
description: "<one-line: what this loop does, derived from the conversation pattern>"
user-invocable: true
---

# <Loop Title>

<What workflow this automates — written from the actual conversation pattern.>

## Execute

If the user provided ARGS, use them as the task context.
Otherwise, the loop runs as a standalone verification pass.

Use the Skill tool to invoke quickdo:

```
skill: "quickdo"
args: "<canned direction that encodes all phases, commands, fix strategies,
       and done conditions extracted from the conversation. Be specific —
       include the exact commands, the order, and what 'fixed' means at
       each phase. End with: max 3 retries per phase, stop and report if
       still failing.>"
```
````

### Example: generated from a conversation where the user built+tested a Rust project

````markdown
---
name: rust-build-test-clippy
description: "Ralph Loop: cargo build → cargo test → cargo clippy, fixing errors at each phase until clean."
user-invocable: true
---

# Rust Build-Test-Clippy Loop

Runs the full Rust verification chain extracted from a prior development session.
Fixes errors iteratively at each phase before moving to the next.

## Execute

If the user provided ARGS (e.g., "add pagination to the list endpoint"),
prepend it as the task. Otherwise, run as a verification-only pass.

Use the Skill tool to invoke quickdo:

```
skill: "quickdo"
args: "<user task if any>. Then run the Ralph Loop verification chain:
Phase 1 — Build: run `cargo build`. If it fails, read the compiler errors,
fix the source code (imports, types, lifetimes), and re-run. Max 3 retries.
Phase 2 — Test: run `cargo test`. If any test fails, read the failure output,
fix the code or test expectations, and re-run. Max 3 retries.
Phase 3 — Lint: run `cargo clippy -- -D warnings`. If warnings appear, apply
the suggested fixes and re-run. Max 3 retries.
When all 3 phases pass, report what was fixed and total iterations per phase."
```
````

## Register

After generating, register the new loop skill:

```bash
bash "$SCRIPT_DIR/scripts/register-ralph-loops.sh"
```

Report to the user:
- The loop has been captured as `/<loop-name>`
- It was extracted from this conversation's pattern
- It runs via `/quickdo` — auto-branching, worker isolation, sprint summary included
- They can invoke it with `/<loop-name>` or `/<loop-name> <task description>`
- They can edit it at: `<LOOP_DIR>/SKILL.md`
- To see all loops: `/explore-ralph-loop list`
- To delete: `/explore-ralph-loop delete <name>`

## Boundaries

- Only generates skill files — never executes loops directly
- User must confirm the detected pattern before generation
- Generated skills delegate to /quickdo for execution
- Generated skills enforce max 3 retries per phase via the direction text
- Generated skills never invoke deployment, shipping, or destructive workflows
- Loop names must be kebab-case, no path traversal (no `/`, `..`, or `.` prefixes)
- If no loop is detected in the conversation, say so and stop — don't guess
