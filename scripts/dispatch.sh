#!/bin/bash
# dispatch.sh — Launch a claude -p session in tmux or headless background
#
# Usage: bash dispatch.sh <project_dir> <prompt_file> <window_name> [worker-id]
#
# Creates a wrapper script, then dispatches in tmux (if available) or
# falls back to headless background execution.
#
# If worker-id is provided, creates .autonomous/comms-{worker-id}.json
# with {"status":"idle"} for per-worker comms isolation.
#
# Output: Prints launch status. Sets DISPATCH_PID for headless mode.

set -euo pipefail

show_help() {
  echo "Usage: bash dispatch.sh <project_dir> <prompt_file> <window_name> [worker-id]"
  echo ""
  echo "Launch a claude -p session from a prompt file."
  echo ""
  echo "Arguments:"
  echo "  project_dir   Project directory to cd into"
  echo "  prompt_file   Path to the prompt markdown file"
  echo "  window_name   tmux window name (e.g., 'worker', 'sprint-1')"
  echo "  worker-id     Optional worker identifier for per-worker comms isolation"
  echo "                Creates .autonomous/comms-{worker-id}.json if provided"
  echo ""
  echo "Examples:"
  echo "  bash dispatch.sh /path/to/project .autonomous/worker-prompt.md worker"
  echo "  bash dispatch.sh /path/to/project .autonomous/sprint-prompt.md sprint-1"
  echo "  bash dispatch.sh /path/to/project .autonomous/worker-prompt.md w1 worker-1"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "help" ]; then
  show_help
  exit 0
fi

command -v claude &>/dev/null || { echo "ERROR: claude CLI not found" >&2; exit 1; }

PROJECT_DIR="${1:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name> [worker-id]}"
PROMPT_FILE="${2:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name> [worker-id]}"
WINDOW_NAME="${3:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name> [worker-id]}"
WORKER_ID="${4:-}"

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# Create per-worker comms file if worker-id provided
if [ -n "$WORKER_ID" ]; then
  mkdir -p "$PROJECT_DIR/.autonomous" && chmod 700 "$PROJECT_DIR/.autonomous"
  echo '{"status":"idle"}' > "$PROJECT_DIR/.autonomous/comms-${WORKER_ID}.json"
fi

# Sanitize window name: strip anything not alphanumeric, hyphen, or underscore
SAFE_WINDOW_NAME=$(printf '%s' "$WINDOW_NAME" | tr -cd 'a-zA-Z0-9_-')
[ -z "$SAFE_WINDOW_NAME" ] && SAFE_WINDOW_NAME="worker"

# Create wrapper script — tmux cannot use claude -p or stdin redirect reliably
# Use printf %q for safe shell-escaping of paths
WRAPPER="$PROJECT_DIR/.autonomous/run-${SAFE_WINDOW_NAME}.sh"
{
  echo '#!/bin/bash'
  printf 'cd %q\n' "$PROJECT_DIR"
  # shellcheck disable=SC2016
  printf 'PROMPT=$(cat %q)\n' "$PROMPT_FILE"
  # shellcheck disable=SC2016
  echo 'exec claude --dangerously-skip-permissions "$PROMPT"'
} > "$WRAPPER"
chmod +x "$WRAPPER"

# Dispatch in tmux (visible to user) or headless background
if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
  tmux new-window -n "$SAFE_WINDOW_NAME" "bash $WRAPPER"
  echo "$SAFE_WINDOW_NAME" >> "$PROJECT_DIR/.autonomous/worker-windows.txt"
  echo "DISPATCH_MODE=tmux"
  echo "Launched in tmux window '$SAFE_WINDOW_NAME'"
else
  bash "$WRAPPER" > "$PROJECT_DIR/.autonomous/${SAFE_WINDOW_NAME}-output.log" 2>&1 &
  DISPATCH_PID=$!
  echo "$SAFE_WINDOW_NAME" >> "$PROJECT_DIR/.autonomous/worker-windows.txt"
  echo "DISPATCH_MODE=headless"
  echo "DISPATCH_PID=$DISPATCH_PID"
  echo "PID: $DISPATCH_PID"
fi
