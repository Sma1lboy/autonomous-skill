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
    if echo "$line" | grep -qE '^\s*-\s*\[\s*\]'; then
      task=$(echo "$line" | sed 's/^\s*-\s*\[\s*\]\s*//')
      if [ -n "$task" ]; then
        add_task "$task" "TODOS.md" 3
      fi
    fi
  done < "$PROJECT_DIR/TODOS.md"
fi

# Source 2: TODO/FIXME/HACK comments in code
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  # Use git grep to find TODOs (respects .gitignore)
  while IFS= read -r match; do
    if [ -n "$match" ]; then
      file=$(echo "$match" | cut -d: -f1)
      comment=$(echo "$match" | cut -d: -f2- | sed 's/.*\(TODO\|FIXME\|HACK\)[: ]*//' | sed 's/\s*$//' | head -c 200)
      if [ -n "$comment" ] && [ ${#comment} -gt 3 ]; then
        add_task "$comment (in $file)" "code-comment" 5
      fi
    fi
  done < <(git -C "$PROJECT_DIR" grep -n -i '\(TODO\|FIXME\|HACK\)[: ]' -- '*.ts' '*.js' '*.py' '*.rs' '*.go' '*.rb' '*.java' '*.sh' 2>/dev/null | head -30 || true)
fi

# Source 3: GitHub issues (if gh is available and we're in a repo)
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
  add_task "Explore project and identify improvement opportunities (code quality, test coverage, documentation)" "auto-discover" 5
fi

# Sort by priority (lower number = higher priority)
TASKS=$(echo "$TASKS" | jq 'sort_by(.priority)')

echo "$TASKS"
