#!/usr/bin/env bash
# comms-lib.sh — Shared comms.json helpers for monitor scripts.
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/comms-lib.sh"
# Layer: shared

# Read comms JSON status safely.
# Usage: _read_comms_status <file> [default_status]
# Outputs one of: idle, waiting, done, answered, CORRUPT, or default_status/""
_read_comms_status() {
  local file="$1"
  local default="${2:-}"
  [ -f "$file" ] || { echo "$default"; return 0; }
  local result
  # Apple jq exits 0 on parse errors — detect corrupt via empty output
  # Use sentinel to distinguish "valid JSON, no status" from "corrupt JSON"
  result=$(jq -r 'if type == "object" then (.status // "__NOSTATUS__") else "__CORRUPT__" end' "$file" 2>/dev/null)
  if [ -z "$result" ]; then
    echo "CORRUPT"
    return 0
  fi
  case "$result" in
    __NOSTATUS__) echo "$default" ;;
    __CORRUPT__) echo "CORRUPT" ;;
    *) echo "$result" ;;
  esac
}
