#!/bin/bash
# dispatch.sh — Launch a claude -p session in tmux or headless background
#
# Usage: bash dispatch.sh <project_dir> <prompt_file> <window_name>
#
# Creates a wrapper script, then dispatches in tmux (if available) or
# falls back to headless background execution.
#
# Output: Prints launch status. Sets DISPATCH_PID for headless mode.

set -euo pipefail

show_help() {
  echo "Usage: bash dispatch.sh <project_dir> <prompt_file> <window_name>"
  echo ""
  echo "Launch a claude -p session from a prompt file."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory to cd into"
  echo "  prompt_file   Path to the prompt markdown file"
  echo "  window_name   tmux window name (e.g., 'worker', 'sprint-1')"
  echo ""
  echo "Examples:"
  echo "  bash dispatch.sh /path/to/project .autonomous/worker-prompt.md worker"
  echo "  bash dispatch.sh /path/to/project .autonomous/sprint-prompt.md sprint-1"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

PROJECT_DIR="${1:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name>}"
PROMPT_FILE="${2:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name>}"
WINDOW_NAME="${3:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name>}"

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# Create wrapper script — tmux cannot use claude -p or stdin redirect reliably
WRAPPER="$PROJECT_DIR/.autonomous/run-${WINDOW_NAME}.sh"
cat > "$WRAPPER" << RUNEOF
#!/bin/bash
cd "$PROJECT_DIR"
PROMPT=\$(cat "$PROMPT_FILE")
exec claude --dangerously-skip-permissions "\$PROMPT"
RUNEOF
chmod +x "$WRAPPER"

# Dispatch in tmux (visible to user) or headless background
if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
  tmux new-window -n "$WINDOW_NAME" "bash $WRAPPER"
  echo "$WINDOW_NAME" >> "$PROJECT_DIR/.autonomous/worker-windows.txt"
  echo "DISPATCH_MODE=tmux"
  echo "Launched in tmux window '$WINDOW_NAME'"
else
  bash "$WRAPPER" > "$PROJECT_DIR/.autonomous/${WINDOW_NAME}-output.log" 2>&1 &
  DISPATCH_PID=$!
  echo "$WINDOW_NAME" >> "$PROJECT_DIR/.autonomous/worker-windows.txt"
  echo "DISPATCH_MODE=headless"
  echo "DISPATCH_PID=$DISPATCH_PID"
  echo "PID: $DISPATCH_PID"
fi
