#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/hooks/careful.sh"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.py"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_careful_hook.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: run hook with a tool_input.command payload, return exit code + stderr
run_hook() {
  local cmd="$1"
  local input
  input=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]}}))" "$cmd")
  printf '%s' "$input" | bash "$HOOK" 2> /tmp/careful-test-stderr || echo "EXIT:$?"
}

# Returns "ALLOW" or "BLOCK" for the given command
hook_decision() {
  local cmd="$1"
  local input output
  input=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]}}))" "$cmd")
  if printf '%s' "$input" | bash "$HOOK" >/dev/null 2> /tmp/careful-test-stderr; then
    echo "ALLOW"
  else
    echo "BLOCK"
  fi
}

# ── 1. Safe commands allowed ──────────────────────────────────────────────

echo ""
echo "1. Safe commands allowed"

assert_eq "$(hook_decision 'ls -la')" "ALLOW" "ls -la allowed"
assert_eq "$(hook_decision 'git status')" "ALLOW" "git status allowed"
assert_eq "$(hook_decision 'npm install')" "ALLOW" "npm install allowed"
assert_eq "$(hook_decision 'pytest tests/')" "ALLOW" "pytest allowed"
assert_eq "$(hook_decision 'rm foo.txt')" "ALLOW" "rm of single file allowed"
assert_eq "$(hook_decision 'rm -f foo.txt')" "ALLOW" "rm -f of single file allowed"
assert_eq "$(hook_decision 'mkdir -p build/output')" "ALLOW" "mkdir allowed"
assert_eq "$(hook_decision 'echo rm -rf /')" "ALLOW" "quoted-looking dangerous command as echo content allowed"

# ── 2. Catastrophic rm blocked ────────────────────────────────────────────

echo ""
echo "2. Catastrophic rm blocked"

assert_eq "$(hook_decision 'rm -rf /')" "BLOCK" "rm -rf / blocked"
assert_eq "$(hook_decision 'rm -rf /*')" "BLOCK" "rm -rf /* blocked"
assert_eq "$(hook_decision 'rm -rf /Users')" "BLOCK" "rm -rf /Users blocked"
assert_eq "$(hook_decision 'rm -rf /home')" "BLOCK" "rm -rf /home blocked"
assert_eq "$(hook_decision 'rm -rf $HOME')" "BLOCK" "rm -rf \$HOME blocked"
assert_eq "$(hook_decision 'rm -rf ~')" "BLOCK" "rm -rf ~ blocked"
assert_eq "$(hook_decision 'rm -rf ~/')" "BLOCK" "rm -rf ~/ blocked"

# ── 3. Build artifact cleanup allowed ─────────────────────────────────────

echo ""
echo "3. Build artifact cleanup allowed"

assert_eq "$(hook_decision 'rm -rf node_modules')" "ALLOW" "rm -rf node_modules allowed"
assert_eq "$(hook_decision 'rm -rf ./node_modules')" "ALLOW" "rm -rf ./node_modules allowed"
assert_eq "$(hook_decision 'rm -rf dist')" "ALLOW" "rm -rf dist allowed"
assert_eq "$(hook_decision 'rm -rf .next')" "ALLOW" "rm -rf .next allowed"
assert_eq "$(hook_decision 'rm -rf __pycache__')" "ALLOW" "rm -rf __pycache__ allowed"
assert_eq "$(hook_decision 'rm -rf build target coverage')" "ALLOW" "multi-target build-artifact allowed"
assert_eq "$(hook_decision 'rm -rf packages/core/dist')" "ALLOW" "nested dist allowed"

# Mixed safe + unsafe → block (fallthrough treats catastrophic patterns only,
# but the safe-only check fails, so it falls through — which is actually OK
# because non-catastrophic rm is allowed by the fallback. Verify:
assert_eq "$(hook_decision 'rm -rf node_modules some-random-path')" "ALLOW" "mixed safe+ordinary allowed (not catastrophic)"

# Arbitrary path rm is allowed (not catastrophic, not safe-listed — falls through)
assert_eq "$(hook_decision 'rm -rf some/path')" "ALLOW" "ordinary rm -rf allowed (neither catastrophic nor safe-listed)"

# ── 4. Disk/filesystem destruction blocked ────────────────────────────────

echo ""
echo "4. Disk/filesystem destruction blocked"

assert_eq "$(hook_decision 'dd if=/dev/zero of=/dev/sda bs=1M')" "BLOCK" "dd to /dev/sda blocked"
assert_eq "$(hook_decision 'dd if=foo of=/dev/nvme0n1')" "BLOCK" "dd to /dev/nvme blocked"
assert_eq "$(hook_decision 'dd if=foo of=/dev/disk2')" "BLOCK" "dd to /dev/disk blocked"
assert_eq "$(hook_decision 'dd if=/dev/zero of=./foo')" "ALLOW" "dd to regular file allowed"

assert_eq "$(hook_decision 'mkfs.ext4 /dev/sda1')" "BLOCK" "mkfs.ext4 blocked"
assert_eq "$(hook_decision 'mkfs /dev/sdb')" "BLOCK" "mkfs blocked"
assert_eq "$(hook_decision 'mkfs.fat -F32 /dev/disk2s1')" "BLOCK" "mkfs.fat blocked"

assert_eq "$(hook_decision 'cat x > /dev/sda')" "BLOCK" "redirect to /dev/sda blocked"
assert_eq "$(hook_decision 'cat x > /dev/null')" "ALLOW" "redirect to /dev/null allowed"

# ── 5. System control blocked ─────────────────────────────────────────────

echo ""
echo "5. System control blocked"

assert_eq "$(hook_decision 'shutdown -h now')" "BLOCK" "shutdown blocked"
assert_eq "$(hook_decision 'reboot')" "BLOCK" "reboot blocked"
assert_eq "$(hook_decision 'sudo reboot')" "BLOCK" "sudo reboot blocked"
assert_eq "$(hook_decision 'halt')" "BLOCK" "halt blocked"
assert_eq "$(hook_decision 'echo shutdown')" "ALLOW" "echo of dangerous word allowed"

# Fork bomb
assert_eq "$(hook_decision ':(){ :|:& };:')" "BLOCK" "fork bomb blocked"

# ── 6. Git force-push to protected branches blocked ──────────────────────

echo ""
echo "6. Git force-push protection"

assert_eq "$(hook_decision 'git push --force origin main')" "BLOCK" "force-push to main blocked"
assert_eq "$(hook_decision 'git push -f origin master')" "BLOCK" "force-push -f to master blocked"
assert_eq "$(hook_decision 'git push --force-with-lease origin main')" "BLOCK" "force-with-lease to main blocked"
assert_eq "$(hook_decision 'git push --force origin trunk')" "BLOCK" "force-push to trunk blocked"

assert_eq "$(hook_decision 'git push origin main')" "ALLOW" "ordinary push to main allowed"
assert_eq "$(hook_decision 'git push --force origin feat/foo')" "ALLOW" "force-push to feature branch allowed"
assert_eq "$(hook_decision 'git push -f origin my-work')" "ALLOW" "force-push to non-main branch allowed"

# ── 7. Destructive SQL blocked ────────────────────────────────────────────

echo ""
echo "7. SQL destruction blocked"

assert_eq "$(hook_decision 'psql -c \"DROP TABLE users\"')" "BLOCK" "DROP TABLE blocked"
assert_eq "$(hook_decision 'psql -c \"drop database prod\"')" "BLOCK" "lowercase drop database blocked"
assert_eq "$(hook_decision 'mysql -e \"TRUNCATE TABLE orders\"')" "BLOCK" "TRUNCATE TABLE blocked"
assert_eq "$(hook_decision 'psql -c \"DROP SCHEMA public CASCADE\"')" "BLOCK" "DROP SCHEMA blocked"

assert_eq "$(hook_decision 'psql -c \"SELECT * FROM users\"')" "ALLOW" "SELECT allowed"
assert_eq "$(hook_decision 'psql -c \"CREATE TABLE foo\"')" "ALLOW" "CREATE TABLE allowed"
assert_eq "$(hook_decision 'grep DROP schema.sql')" "ALLOW" "grep for DROP allowed"

# ── 8. Non-Bash tool input → pass through ─────────────────────────────────

echo ""
echo "8. Non-Bash tool input"

NON_BASH=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/rm -rf /"}}' | bash "$HOOK" 2>&1; echo "exit=$?")
assert_contains "$NON_BASH" "exit=0" "non-Bash tool passes through"

EMPTY_INPUT=$(echo '{}' | bash "$HOOK" 2>&1; echo "exit=$?")
assert_contains "$EMPTY_INPUT" "exit=0" "empty input passes through"

MALFORMED=$(echo 'not json' | bash "$HOOK" 2>&1; echo "exit=$?")
assert_contains "$MALFORMED" "exit=0" "malformed input passes through (allow by default)"

# ── 9. Block output format ────────────────────────────────────────────────

echo ""
echo "9. Block message format"

set +e
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | bash "$HOOK" 2>&1)
CODE=$?
set -e
assert_eq "$CODE" "2" "block returns exit code 2"
assert_contains "$OUTPUT" "BLOCKED" "block output mentions BLOCKED"
assert_contains "$OUTPUT" "Command:" "block output includes the rejected command"
assert_contains "$OUTPUT" "false positive" "block output hints at false-positive handling"

# ── 10. dispatch.py integration ──────────────────────────────────────────

echo ""
echo "10. Dispatch integration"

T=$(new_tmp)
echo "test prompt" > "$T/prompt.txt"

# Without env var: no settings file created, wrapper has no --settings
AUTONOMOUS_WORKER_CAREFUL="" DISPATCH_MODE=headless python3 "$DISPATCH" "$T" "$T/prompt.txt" testwin > /dev/null 2>&1 || true
WRAPPER="$T/.autonomous/run-testwin.sh"
assert_file_exists "$WRAPPER" "wrapper created"
# NB: grep pattern can't start with '--' (would be parsed as flag), so match on the filename
assert_file_not_contains "$WRAPPER" "settings-testwin.json" "wrapper does not reference a settings file without env var"
assert_file_not_exists "$T/.autonomous/settings-testwin.json" "no settings json without env var"
# Kill the dispatched process
pkill -f "run-testwin.sh" 2>/dev/null || true

# With env var: settings file created, wrapper uses --settings
T2=$(new_tmp)
echo "test prompt" > "$T2/prompt.txt"
AUTONOMOUS_WORKER_CAREFUL=1 DISPATCH_MODE=headless python3 "$DISPATCH" "$T2" "$T2/prompt.txt" testwin2 > /dev/null 2>&1 || true
WRAPPER2="$T2/.autonomous/run-testwin2.sh"
SETTINGS="$T2/.autonomous/settings-testwin2.json"
assert_file_exists "$SETTINGS" "settings json created when env var set"
assert_file_contains "$SETTINGS" "PreToolUse" "settings has PreToolUse hook"
assert_file_contains "$SETTINGS" "careful.sh" "settings references careful.sh"
assert_file_contains "$SETTINGS" '"matcher": "Bash"' "settings matches Bash tool"
assert_file_contains "$WRAPPER2" "settings-testwin2.json" "wrapper references settings file when env var set"
pkill -f "run-testwin2.sh" 2>/dev/null || true

# Env var variants: AUTONOMOUS_WORKER_CAREFUL=true / yes also enables
T3=$(new_tmp)
echo "test prompt" > "$T3/prompt.txt"
AUTONOMOUS_WORKER_CAREFUL=true DISPATCH_MODE=headless python3 "$DISPATCH" "$T3" "$T3/prompt.txt" testwin3 > /dev/null 2>&1 || true
assert_file_exists "$T3/.autonomous/settings-testwin3.json" "AUTONOMOUS_WORKER_CAREFUL=true enables hook"
pkill -f "run-testwin3.sh" 2>/dev/null || true

# Wait for pkill'd processes to actually die before cleanup
sleep 0.5 2>/dev/null || true

rm -f /tmp/careful-test-stderr

print_results
