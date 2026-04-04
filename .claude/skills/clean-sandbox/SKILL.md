---
name: clean-sandbox
description: Reset the test sandbox — wipe project, gstack cache, and re-init a fresh git repo for autonomous-skill testing
user-invocable: true
---

# Clean Sandbox

Nuke and re-initialize the test sandbox project used for autonomous-skill
testing. Clears the project directory, its gstack archives, and creates a
fresh git repo with comms.md ready to go.

Sandbox lives at: `/Volumes/ssd/i/auto-tool-workspace/sandbox/`

## Run

```bash
PROJECT="${ARGS:-disk-clean-manager}"
SANDBOX_DIR="/Volumes/ssd/i/auto-tool-workspace/sandbox"
PROJECT_DIR="$SANDBOX_DIR/$PROJECT"
GSTACK_DIR="$HOME/.gstack/projects/$PROJECT"

echo "PROJECT=$PROJECT"
echo "PROJECT_DIR=$PROJECT_DIR"

# Check what exists
if [ -d "$PROJECT_DIR" ]; then
  FILE_COUNT=$(find "$PROJECT_DIR" -type f -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')
  echo "PROJECT_EXISTS=true"
  echo "PROJECT_FILE_COUNT=$FILE_COUNT"
else
  echo "PROJECT_EXISTS=false"
fi

if [ -d "$GSTACK_DIR" ]; then
  GSTACK_COUNT=$(find "$GSTACK_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo "GSTACK_EXISTS=true"
  echo "GSTACK_FILE_COUNT=$GSTACK_COUNT"
else
  echo "GSTACK_EXISTS=false"
fi
```

## Behavior

1. Show what will be cleaned (project dir file count + gstack archive count).
2. Ask the user to confirm via AskUserQuestion: "Reset sandbox/$PROJECT? This deletes X project files and Y gstack archives."
3. On confirm, execute the cleanup:

```bash
PROJECT="${ARGS:-disk-clean-manager}"
SANDBOX_DIR="/Volumes/ssd/i/auto-tool-workspace/sandbox"
PROJECT_DIR="$SANDBOX_DIR/$PROJECT"
GSTACK_DIR="$HOME/.gstack/projects/$PROJECT"

# Step 1: Clean gstack
rm -rf "$GSTACK_DIR" 2>/dev/null

# Step 2: Remove project
rm -rf "$PROJECT_DIR"

# Step 3: Re-init
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
git init -q
echo "# $PROJECT" > README.md
mkdir -p .autonomous tests
echo "STATUS: IDLE" > .autonomous/comms.md
git add .
git commit -q -m "init"
echo "DONE=true"
echo "BRANCH=$(git branch --show-current)"
```

4. Report: "Sandbox reset. Fresh repo at sandbox/$PROJECT with comms.md ready."
