#!/usr/bin/env bash
# log.sh — Structured logging library for autonomous-skill scripts.
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
# Layer: shared
#
# Functions: log_init, log_info, log_warn, log_error
# Format: [TIMESTAMP] [LEVEL] [SCRIPT] message
# WARN/ERROR also echo to stderr for console visibility.

# Default log file path (overridable via LOG_FILE env var or log_init)
_LOG_FILE="${LOG_FILE:-}"

# Initialize logging with a project directory or explicit path.
# Usage: log_init <project_dir_or_path>
# If the argument contains a slash and ends in .log, it's treated as a file path.
# Otherwise, it's treated as a project dir and logs go to <dir>/.autonomous/session.log.
log_init() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    return 0
  fi
  if [[ "$target" == *.log ]]; then
    _LOG_FILE="$target"
  else
    _LOG_FILE="$target/.autonomous/session.log"
  fi
}

# Internal: write a log line.
# Usage: _log_write <level> <message>
_log_write() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local script_name
  # Use BASH_SOURCE[2] to get the caller's caller (skip _log_write -> log_xxx -> actual caller)
  script_name=$(basename "${BASH_SOURCE[2]:-unknown}")
  local line="[$timestamp] [$level] [$script_name] $message"

  # Determine log file
  local log_file="${_LOG_FILE:-${LOG_FILE:-}}"

  if [ -n "$log_file" ]; then
    # Ensure parent directory exists
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    echo "$line" >> "$log_file"
  fi

  # WARN and ERROR also go to stderr
  if [ "$level" = "WARN" ] || [ "$level" = "ERROR" ]; then
    echo "$line" >&2
  fi
}

log_info() {
  _log_write "INFO" "$@"
}

log_warn() {
  _log_write "WARN" "$@"
}

log_error() {
  _log_write "ERROR" "$@"
}
