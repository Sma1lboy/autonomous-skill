#!/usr/bin/env bash
# discover.sh — Discover tasks from project sources (TODOS.md, TODO comments, CLAUDE.md)
# Outputs JSON array of tasks to stdout
set -euo pipefail

PROJECT_DIR="${1:-.}"
TASKS="[]"

add_task() {
  local description="$1"
  local source="$2"
  local priority="${3:-5}"
  # Sanitize: strip control characters (NUL, tabs, newlines, etc.) that break JSON
  description=$(printf '%s' "$description" | LC_ALL=C tr -d '[:cntrl:]')
  # Generate ID from description hash
  local id
  id=$(echo -n "$description" | shasum -a 256 | cut -c1-12)
  TASKS=$(echo "$TASKS" | jq --arg id "$id" --arg desc "$description" --arg src "$source" --argjson pri "$priority" \
    '. + [{"id": $id, "description": $desc, "source": $src, "priority": $pri, "status": "pending", "strikes": 0, "last_error": null}]')
}

# Source 1: TODOS.md
if [ -f "$PROJECT_DIR/TODOS.md" ]; then
  while IFS= read -r line; do
    # Match lines starting with - [ ] (unchecked todos)
    if echo "$line" | grep -qE '^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]'; then
      task=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]*//')
      if [ -n "$task" ]; then
        add_task "$task" "TODOS.md" 3
      fi
    fi
  done < "$PROJECT_DIR/TODOS.md"
fi

# Source 2: KANBAN.md (Todo section only)
if [ -f "$PROJECT_DIR/KANBAN.md" ]; then
  in_todo=0
  while IFS= read -r line; do
    # Detect section headers
    if echo "$line" | grep -qE '^## Todo'; then
      in_todo=1; continue
    elif echo "$line" | grep -qE '^## '; then
      in_todo=0; continue
    fi
    # Only pick up unchecked items from the Todo section
    if [ "$in_todo" -eq 1 ] && echo "$line" | grep -qE '^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]'; then
      task=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]*//')
      if [ -n "$task" ]; then
        add_task "$task" "KANBAN.md" 4
      fi
    fi
  done < "$PROJECT_DIR/KANBAN.md"
fi

# Source 3: code comments containing TODO/FIXME/HACK keywords
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r match; do
    if [ -n "$match" ]; then
      # git grep -n output: file:linenum:content
      file=$(echo "$match" | cut -d: -f1)
      content=$(echo "$match" | cut -d: -f3-)
      # Extract the actual TODO/FIXME/HACK message after the keyword
      # Extract comment, strip whitespace, then truncate by characters (not bytes)
      # to avoid splitting multi-byte UTF-8 characters
      comment=$(echo "$content" | sed -E 's/.*\b(TODO|FIXME|HACK)[: ]+//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
      comment="${comment:0:200}"
      if [ -n "$comment" ] && [ ${#comment} -gt 3 ]; then
        add_task "$comment (in $file)" "code-comment" 5
      fi
    fi
  done < <(git -C "$PROJECT_DIR" grep -n -i '\bTODO[: ]\|FIXME[: ]\|HACK[: ]' -- '*.ts' '*.js' '*.py' '*.rs' '*.go' '*.rb' '*.java' '*.sh' ':!scripts/discover.sh' 2>/dev/null | head -30 || true)
fi

# Source 4: GitHub issues (if gh is available and we're in a repo)
if command -v gh >/dev/null 2>&1 && git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS=$'\t' read -r number title; do
    if [ -n "$title" ]; then
      add_task "GitHub #$number: $title" "github-issue" 2
    fi
  done < <(gh issue list --limit 10 --state open --json number,title --jq '.[] | [.number, .title] | @tsv' 2>/dev/null || true)
fi

# If no tasks found, add a meta-task to explore
TASK_COUNT=$(echo "$TASKS" | jq 'length')
if [ "$TASK_COUNT" -eq 0 ]; then
  add_task "Read README.md and CLAUDE.md, then create a TODOS.md file with 5 concrete, actionable tasks for improving this project. Each task should be one clear sentence. Focus on: missing tests, error handling gaps, documentation holes, or code quality issues." "auto-discover" 5
fi

# Sort by priority (lower number = higher priority)
TASKS=$(echo "$TASKS" | jq 'sort_by(.priority)')

echo "$TASKS"
