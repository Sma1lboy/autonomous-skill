#!/usr/bin/env bash
# persona.sh — Generate global OWNER.md if it doesn't exist
# OWNER.md lives in the skill directory (global, not per-project).
# Owner identity, preferences, and decision style don't change per repo.
set -euo pipefail

usage() {
  cat << 'EOF'
Usage: persona.sh [project-dir]

Generate OWNER.md in the autonomous-skill directory (global persona).
If OWNER.md already exists, prints its path and exits.

The generated persona captures the owner's coding style, priorities,
and conventions — used by autonomous-skill workers to make decisions
aligned with the owner's preferences.

Arguments:
  project-dir   Optional project path used as context for initial generation.
                Not where OWNER.md is stored — it always lives in the skill dir.

Falls back to a template if no project context is available or
if claude CLI is not installed.
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

PROJECT_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER_FILE="$SCRIPT_DIR/../OWNER.md"
TEMPLATE="$SCRIPT_DIR/../OWNER.md.template"

# Write the fallback template to OWNER_FILE (used when no context or claude fails)
write_fallback_template() {
  if [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" "$OWNER_FILE"
  else
    cat > "$OWNER_FILE" << 'EOF'
# Owner Persona

## Priorities (what matters most)
<!-- Fill in your priorities -->

## Style (code conventions, commit style)
<!-- Fill in your coding style -->

## Avoid (things NOT to change)
<!-- Fill in things to avoid -->

## Current focus (what I'm working on right now)
<!-- Fill in your current focus -->

## Decision Framework
1. **Choose completeness** — Ship the whole thing over shortcuts
2. **Boil lakes** — Fix everything in the blast radius if effort is small
3. **Pragmatic** — Two similar options? Pick the cleaner one
4. **DRY** — Reuse what exists. Reject duplicate implementations
5. **Explicit over clever** — Obvious 10-line fix beats 200-line abstraction
6. **Bias toward action** — Approve and move forward. Flag concerns but don't block
EOF
  fi
}

# If OWNER.md exists, just print its path and exit
if [ -f "$OWNER_FILE" ]; then
  echo "$OWNER_FILE"
  exit 0
fi

echo "No OWNER.md found. Auto-generating from project context..." >&2

# Gather context
GIT_LOG=""
if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  GIT_LOG=$(git -C "$PROJECT_DIR" log --oneline -50 2>/dev/null || true)
fi

CLAUDE_MD=""
if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
  CLAUDE_MD=$(head -100 "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true)
fi

README=""
if [ -f "$PROJECT_DIR/README.md" ]; then
  README=$(head -80 "$PROJECT_DIR/README.md" 2>/dev/null || true)
fi

# If no context available, write template and exit
if [ -z "$GIT_LOG" ] && [ -z "$CLAUDE_MD" ] && [ -z "$README" ]; then
  write_fallback_template
  echo "$OWNER_FILE"
  exit 0
fi

# Generate persona from context using claude -p
CONTEXT="Generate an OWNER.md persona file for this project based on the following context.
Output ONLY the markdown content, no explanation.

Format:
# Owner Persona
## Priorities (what matters most)
## Style (code conventions, commit style)
## Avoid (things NOT to change)
## Current focus (what I'm working on right now)"

if [ -n "$GIT_LOG" ]; then
  CONTEXT="$CONTEXT

Recent git history:
$GIT_LOG"
fi

if [ -n "$CLAUDE_MD" ]; then
  CONTEXT="$CONTEXT

CLAUDE.md:
$CLAUDE_MD"
fi

if [ -n "$README" ]; then
  CONTEXT="$CONTEXT

README.md:
$README"
fi

# Try to use CC to generate, fall back to template
RESULT=$(timeout 60 claude -p "$CONTEXT" --permission-mode auto --output-format json 2>/dev/null || true)
if [ -n "$RESULT" ]; then
  GENERATED=$(echo "$RESULT" | jq -r '.result // empty' 2>/dev/null || true)
  if [ -n "$GENERATED" ]; then
    echo "$GENERATED" > "$OWNER_FILE"
    echo "Auto-generated OWNER.md. Review and edit: $OWNER_FILE" >&2
    echo "$OWNER_FILE"
    exit 0
  fi
fi

# Fallback: write template
write_fallback_template
echo "Created OWNER.md template. Edit it with your preferences: $OWNER_FILE" >&2
echo "$OWNER_FILE"
