---
name: clean-gstack
description: Delete gstack design doc archives for a project (design docs, eng reviews, timelines)
user-invocable: true
---

# Clean Gstack Archives

Delete all gstack project archives (design docs, eng reviews, design reviews,
timelines) for a given project slug. Used between autonomous-skill test runs
to prevent workers from finding stale prior work and skipping skill phases.

## Run

```bash
SLUG="${ARGS:-}"
if [ -z "$SLUG" ]; then
  echo "AVAILABLE_PROJECTS:"
  ls ~/.gstack/projects/ 2>/dev/null || echo "(none)"
  echo "NEED_SLUG=true"
else
  GSTACK_DIR="$HOME/.gstack/projects/$SLUG"
  if [ -d "$GSTACK_DIR" ]; then
    echo "FILES_FOUND:"
    ls -la "$GSTACK_DIR/"
    FILE_COUNT=$(find "$GSTACK_DIR" -type f | wc -l | tr -d ' ')
    echo "FILE_COUNT=$FILE_COUNT"
  else
    echo "NO_DATA=true"
    echo "SLUG=$SLUG"
  fi
fi
```

## Behavior

If no ARGS provided, list available project slugs and ask the user which one
to clean using AskUserQuestion.

If ARGS is a slug:
1. Show the files that will be deleted
2. Ask the user to confirm with AskUserQuestion: "Delete N files from ~/.gstack/projects/SLUG?"
3. On confirm, delete all .md, .jsonl, .json files in that directory:

```bash
rm -f "$HOME/.gstack/projects/$SLUG"/*.md "$HOME/.gstack/projects/$SLUG"/*.jsonl "$HOME/.gstack/projects/$SLUG"/*.json
rmdir "$HOME/.gstack/projects/$SLUG" 2>/dev/null || true
```

4. Report what was deleted.

If NO_DATA=true, tell the user there's nothing to clean for that slug.
