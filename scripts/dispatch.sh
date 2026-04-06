#!/usr/bin/env bash
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
# Layer: sprint-master

set -euo pipefail

usage() {
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
  usage
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

# Clean up wrapper script if dispatch fails before launch
_dispatch_launched=0
_dispatch_cleanup() {
  if [ "$_dispatch_launched" -eq 0 ]; then
    [ -n "${WRAPPER:-}" ] && [ -f "${WRAPPER:-}" ] && rm -f "$WRAPPER" 2>/dev/null || true
  fi
}
trap _dispatch_cleanup EXIT

command -v claude &>/dev/null || { echo "ERROR: claude CLI not found. Install from https://docs.anthropic.com/en/docs/claude-code" >&2; exit 1; }

PROJECT_DIR="${1:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name> [worker-id]}"
PROMPT_FILE="${2:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name> [worker-id]}"
WINDOW_NAME="${3:?Usage: dispatch.sh <project_dir> <prompt_file> <window_name> [worker-id]}"
WORKER_ID="${4:-}"

log_init "$PROJECT_DIR"

if [ ! -f "$PROMPT_FILE" ]; then
  log_error "Prompt file not found: $PROMPT_FILE"
  echo "ERROR: Prompt file not found: $PROMPT_FILE. Check the path or ensure the sprint master wrote this file" >&2
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

# ── Determine dispatch isolation mode ────────────────────────────────────
# Priority: skill-config.json > DISPATCH_ISOLATION env var > default "branch"
DISPATCH_ISOLATION="${DISPATCH_ISOLATION:-branch}"
CONFIG_FILE="$PROJECT_DIR/.autonomous/skill-config.json"
if [ -f "$CONFIG_FILE" ] && command -v python3 &>/dev/null; then
  CFG_ISOLATION=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get('dispatch_isolation')
    if v in ('branch', 'worktree'):
        print(v)
except Exception:
    pass
" "$CONFIG_FILE" 2>/dev/null || true)
  [ -n "$CFG_ISOLATION" ] && DISPATCH_ISOLATION="$CFG_ISOLATION"
fi

# Validate isolation mode
if [[ "$DISPATCH_ISOLATION" != "branch" && "$DISPATCH_ISOLATION" != "worktree" ]]; then
  echo "WARNING: invalid DISPATCH_ISOLATION '$DISPATCH_ISOLATION' — valid values are 'branch' or 'worktree'. Using default 'branch'" >&2
  DISPATCH_ISOLATION="branch"
fi

# ── Worktree setup (if isolation=worktree) ───────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_PATH=""
WORKER_CD_DIR="$PROJECT_DIR"

if [ "$DISPATCH_ISOLATION" = "worktree" ]; then
  WORKTREE_BRANCH="auto/worker-${SAFE_WINDOW_NAME}"
  WT_OUT=$(bash "$SCRIPT_DIR/worktree-manager.sh" create "$PROJECT_DIR" "$WORKTREE_BRANCH" 2>&1) || {
    echo "ERROR: worktree creation failed. worktree-manager.sh said: $WT_OUT" >&2
    exit 1
  }
  WORKTREE_PATH=$(echo "$WT_OUT" | grep '^WORKTREE_PATH=' | head -1 | cut -d= -f2-)
  WORKER_CD_DIR="$WORKTREE_PATH"
  # Record worktree branch for later cleanup/merge
  echo "$WORKTREE_BRANCH" > "$PROJECT_DIR/.autonomous/worker-worktree-${SAFE_WINDOW_NAME}.txt"
  echo "DISPATCH_ISOLATION=worktree"
  echo "WORKTREE_BRANCH=$WORKTREE_BRANCH"
  echo "WORKTREE_PATH=$WORKTREE_PATH"
fi

# ── Determine worker timeout ─────────────────────────────────────────────
# Priority: skill-config.json > WORKER_TIMEOUT env var > default 600s
WORKER_TIMEOUT_SECS="${WORKER_TIMEOUT:-600}"
CONFIG_FILE="$PROJECT_DIR/.autonomous/skill-config.json"
if [ -f "$CONFIG_FILE" ] && command -v python3 &>/dev/null; then
  CFG_TIMEOUT=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get('worker_timeout')
    if v is not None and isinstance(v, int) and v > 0:
        print(v)
except Exception:
    pass
" "$CONFIG_FILE" 2>/dev/null || true)
  [ -n "$CFG_TIMEOUT" ] && WORKER_TIMEOUT_SECS="$CFG_TIMEOUT"
fi

# Validate timeout is a positive integer
if ! [[ "$WORKER_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]]; then
  echo "WARNING: invalid WORKER_TIMEOUT '$WORKER_TIMEOUT_SECS' — expected a positive integer (seconds). Using default 600" >&2
  WORKER_TIMEOUT_SECS=600
fi

# Determine comms file path for timeout handler
if [ -n "$WORKER_ID" ]; then
  COMMS_PATH="$PROJECT_DIR/.autonomous/comms-${WORKER_ID}.json"
else
  COMMS_PATH="$PROJECT_DIR/.autonomous/comms.json"
fi

# Create wrapper script — tmux cannot use claude -p or stdin redirect reliably
# Use printf %q for safe shell-escaping of paths
WRAPPER="$PROJECT_DIR/.autonomous/run-${SAFE_WINDOW_NAME}.sh"
{
  echo '#!/bin/bash'
  printf 'cd %q\n' "$WORKER_CD_DIR"
  # shellcheck disable=SC2016
  printf 'PROMPT=$(cat %q)\n' "$PROMPT_FILE"
  # Timeout-wrapped execution with gtimeout fallback for macOS
  # shellcheck disable=SC2016
  printf 'TIMEOUT_CMD=""\n'
  # shellcheck disable=SC2016
  printf 'if command -v timeout &>/dev/null; then TIMEOUT_CMD="timeout"; fi\n'
  # shellcheck disable=SC2016
  printf 'if [ -z "$TIMEOUT_CMD" ] && command -v gtimeout &>/dev/null; then TIMEOUT_CMD="gtimeout"; fi\n'
  # shellcheck disable=SC2016
  printf 'if [ -n "$TIMEOUT_CMD" ]; then\n'
  # shellcheck disable=SC2016
  printf '  $TIMEOUT_CMD %s claude --dangerously-skip-permissions "$PROMPT"\n' "$WORKER_TIMEOUT_SECS"
  # shellcheck disable=SC2016
  printf '  EXIT_CODE=$?\n'
  # shellcheck disable=SC2016
  printf '  if [ "$EXIT_CODE" -eq 124 ]; then\n'
  printf '    printf '"'"'{"status":"done","summary":"WORKER_TIMEOUT: exceeded %ss limit"}'"'"' > %q\n' "$WORKER_TIMEOUT_SECS" "$COMMS_PATH"
  printf '  fi\n'
  # shellcheck disable=SC2016
  printf '  exit $EXIT_CODE\n'
  printf 'else\n'
  # shellcheck disable=SC2016
  printf '  exec claude --dangerously-skip-permissions "$PROMPT"\n'
  printf 'fi\n'
} > "$WRAPPER"
chmod +x "$WRAPPER"

# Dispatch in tmux (visible to user) or headless background
log_info "Dispatching worker '$SAFE_WINDOW_NAME' isolation=$DISPATCH_ISOLATION timeout=${WORKER_TIMEOUT_SECS}s"

_dispatch_launched=1

if command -v tmux &>/dev/null && tmux info &>/dev/null 2>&1; then
  tmux new-window -n "$SAFE_WINDOW_NAME" "bash $WRAPPER"
  echo "$SAFE_WINDOW_NAME" >> "$PROJECT_DIR/.autonomous/worker-windows.txt"
  echo "DISPATCH_MODE=tmux"
  echo "Launched in tmux window '$SAFE_WINDOW_NAME'"
  log_info "Dispatched in tmux mode window='$SAFE_WINDOW_NAME'"
else
  bash "$WRAPPER" > "$PROJECT_DIR/.autonomous/${SAFE_WINDOW_NAME}-output.log" 2>&1 &
  DISPATCH_PID=$!
  echo "$SAFE_WINDOW_NAME" >> "$PROJECT_DIR/.autonomous/worker-windows.txt"
  echo "DISPATCH_MODE=headless"
  echo "DISPATCH_PID=$DISPATCH_PID"
  echo "PID: $DISPATCH_PID"
  log_info "Dispatched in headless mode pid=$DISPATCH_PID"
fi
