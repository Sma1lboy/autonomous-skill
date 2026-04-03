#!/usr/bin/env bash
# persona.sh — Generate OWNER.md from git history and project docs if it doesn't exist
set -euo pipefail

PROJECT_DIR="${1:-.}"
OWNER_FILE="$PROJECT_DIR/OWNER.md"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../OWNER.md.template"

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

# If no context available, copy template as-is
if [ -z "$GIT_LOG" ] && [ -z "$CLAUDE_MD" ] && [ -z "$README" ]; then
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
EOF
  fi
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

# Fallback: copy template
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
EOF
fi
echo "Created OWNER.md template. Edit it with your preferences: $OWNER_FILE" >&2
echo "$OWNER_FILE"
