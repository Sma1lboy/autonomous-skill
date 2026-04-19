# Autonomous Skill — GitHub Copilot Edition

A single-agent variant of [`autonomous-skill`](../README.md), built specifically
for GitHub Copilot users. Copilot has no subagent dispatch, so this version
runs the whole scan → score → fix → verify loop in one agent session.

This directory is **Copilot-only**. Claude Code does not discover anything here
(it loads the conductor at the repo root). The two paths are independent.

## What's inside

```
copilot/
└── skills/
    └── autonomous-copilot/
        └── SKILL.md      # The whole skill — single file, self-contained
```

## Install (pick one)

### Option 1 — User-global (all your projects)

```bash
mkdir -p ~/.copilot/skills
cp -r copilot/skills/autonomous-copilot ~/.copilot/skills/
```

Copilot auto-discovers it across every workspace. Nothing to commit.

### Option 2 — Project-local (commit + share with team)

From your project root:

```bash
mkdir -p .github/skills
cp -r /path/to/autonomous-skill/copilot/skills/autonomous-copilot .github/skills/
```

Commit the `.github/skills/autonomous-copilot/` folder. Anyone on the team who
opens the project in VS Code with Copilot Chat gets the skill automatically.

### Option 3 — Custom location

Add to your VS Code `settings.json`:

```json
"chat.skillsLocations": {
  "/absolute/path/to/this/repo/copilot/skills": true
}
```

Useful if you want to dogfood without copying.

## How it triggers

Copilot auto-invokes the skill when your chat prompt matches the `description`
field in `SKILL.md` — e.g. "improve this codebase", "audit the project",
"make this solid", "find and fix issues". No slash command, no manual pick.

## How it differs from the Claude version

| Aspect              | Claude (`../SKILL.md`)                      | Copilot (`./skills/autonomous-copilot/SKILL.md`) |
|---------------------|---------------------------------------------|--------------------------------------------------|
| Architecture        | Conductor → sprint master → worker          | Single agent does everything                     |
| Concurrency         | Sequential sprints, each in a subagent      | Sequential dimensions, all in one session        |
| State               | `.autonomous/conductor-state.json` + scripts| Copilot `memory` tool                            |
| Scoring             | Bash heuristics in `explore-scan.sh`        | Inline grep/file_search inside the agent         |
| Branching           | One branch per sprint, merged on success    | Whatever the user already has — no branch logic  |
| Dispatch tooling    | tmux + `claude -p` headless                 | None — no subagents on Copilot                   |
