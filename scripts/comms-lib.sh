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
  result=$(python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('status',sys.argv[2]))
except (json.JSONDecodeError, ValueError, KeyError):
    print('CORRUPT')
" "$file" "$default" 2>/dev/null) || { echo "CORRUPT"; return 0; }
  echo "$result"
}
