#!/usr/bin/env bash
# careful.sh — PreToolUse hook for autonomous workers.
#
# Reads Claude Code hook JSON from stdin, inspects the Bash command for
# patterns that have no legitimate use in an autonomous worker context, and
# blocks them by exiting 2 with a stderr message Claude can read.
#
# Deployed by dispatch.py when AUTONOMOUS_WORKER_CAREFUL=1 is set.
#
# Exit codes:
#   0  — allow
#   2  — block (stderr message goes back to Claude as tool error)
set -euo pipefail

# Read the hook input JSON from stdin
INPUT=$(cat)

# Extract tool_input.command. Try jq if available, fall back to Python.
CMD=""
if command -v jq >/dev/null 2>&1; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
fi
if [ -z "$CMD" ]; then
  CMD=$(printf '%s' "$INPUT" | python3 -c \
    'import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get("tool_input",{}).get("command",""))
except Exception:
    pass
' 2>/dev/null || true)
fi

# Non-Bash tool or empty command → allow
if [ -z "$CMD" ]; then
  exit 0
fi

# Commands whose first word is a read-only / display tool cannot do damage
# even if their arguments mention dangerous strings. Allow unconditionally.
FIRST_WORD=$(printf '%s' "$CMD" | awk '{print $1}' | sed 's|.*/||')
case "$FIRST_WORD" in
  echo|printf|grep|egrep|fgrep|rg|ag|find|sed|awk|cat|head|tail|less|more|bat|\
  vi|vim|nano|emacs|code|view|file|stat|ls|ll|tree|wc|sort|uniq|diff|cmp|cksum|\
  md5|md5sum|shasum|sha256sum|base64|hexdump|xxd|od|strings|type|which|whereis|\
  pwd|env|printenv|date|git|node|python|python3|ruby|perl|go|cargo|npm|pnpm|yarn|\
  make|pytest|jest|bundle|pip|pip3|uv|poetry|rustc|tsc|deno|bun)
    # Still check these below for their own specific destructive patterns,
    # but skip generic rm/dd/mkfs/shutdown/SQL checks by marking as "safe-first".
    SAFE_FIRST=1
    ;;
  *)
    SAFE_FIRST=0
    ;;
esac

CMD_LOWER=$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')

block() {
  echo "BLOCKED by autonomous-skill careful hook: $1" >&2
  echo "Command: $CMD" >&2
  echo "If this is a false positive, rephrase the command or narrow its scope." >&2
  exit 2
}

# Flexible flag regex fragment: matches "-rf", "-Rf", "-fr", etc., plus "--recursive"
RM_RECURSIVE_FLAG='(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)'

# ── Checks that run regardless of first word (shell-level hazards) ─────

# Redirect to raw block device — shell redirect, applies even for `cat`, `echo`
if printf '%s' "$CMD_LOWER" | grep -qE '>\s*/dev/(sd[a-z]|nvme|disk[0-9]|hd[a-z]|rdisk)'; then
  block "redirect to raw disk device"
fi

# git force-push to protected branches — applies even when first word is git
if printf '%s' "$CMD" | grep -qE 'git\s+push\s+.*\b(main|master|trunk|release)\b'; then
  if printf '%s' "$CMD" | grep -qE 'git\s+push\s+.*(-f\b|--force\b|--force-with-lease\b)'; then
    block "git force-push to main/master/trunk/release branch"
  fi
fi

# For search/view tools, skip all other destructive checks
if [ "$SAFE_FIRST" = "1" ] && [ "$FIRST_WORD" != "git" ]; then
  exit 0
fi

# ── Catastrophic: system-wipe patterns ──────────────────────────────────

# rm -rf / or rm -rf /* or rm -rf /--no-preserve-root
if printf '%s' "$CMD" | grep -qE "rm\s+${RM_RECURSIVE_FLAG}(\s+-[a-zA-Z]+)*\s+(/\s*$|/\s|/\*|/--no-preserve-root)"; then
  block "rm -rf against / (filesystem root)"
fi

# rm -rf $HOME or rm -rf ~
if printf '%s' "$CMD" | grep -iqE "rm\s+${RM_RECURSIVE_FLAG}(\s+-[a-zA-Z]+)*\s+(\\\$home\b|~\/?(\s|$))"; then
  block "rm -rf against \$HOME"
fi

# rm -rf /Users or /home (user directories)
if printf '%s' "$CMD" | grep -iqE "rm\s+${RM_RECURSIVE_FLAG}(\s+-[a-zA-Z]+)*\s+(/users|/home)(/|\s|$)"; then
  block "rm -rf against system user directories"
fi

# dd writing to raw device
if printf '%s' "$CMD_LOWER" | grep -qE 'dd\s+.*of=/dev/(sd[a-z]|nvme|disk|hd[a-z]|rdisk)'; then
  block "dd to raw disk device"
fi

# mkfs — filesystem format
if printf '%s' "$CMD_LOWER" | grep -qE '\bmkfs(\.[a-z0-9]+)?\b'; then
  block "mkfs filesystem format"
fi

# Fork bomb
if printf '%s' "$CMD" | grep -qE ':\(\)\s*\{\s*:\s*\|\s*:&?\s*\}\s*;?\s*:'; then
  block "fork bomb pattern"
fi

# Shutdown / reboot / halt
if printf '%s' "$CMD_LOWER" | grep -qE '^\s*(sudo\s+)?(shutdown|reboot|halt|poweroff)(\s|$)'; then
  block "system shutdown command"
fi

# ── Destructive SQL ─────────────────────────────────────────────────────

if printf '%s' "$CMD_LOWER" | grep -qE '\bdrop\s+(table|database|schema)\b'; then
  block "SQL DROP TABLE/DATABASE/SCHEMA"
fi

if printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\s+table\b'; then
  block "SQL TRUNCATE TABLE"
fi

# ── Safe exceptions: rm -rf of known build artifacts is allowed ─────────

# If the command is rm -rf and all targets are in the safe list, allow it.
# (This is for clarity in logs; non-safe targets fall through to the default
# allow since we only block catastrophic paths above.)
exit 0
