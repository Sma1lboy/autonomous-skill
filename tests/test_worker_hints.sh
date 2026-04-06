#!/usr/bin/env bash
# Tests for scripts/build-worker-hints.sh — worker hints block generation.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HINTS="$SCRIPT_DIR/../scripts/build-worker-hints.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_worker_hints.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help flag"
OUT=$(bash "$HINTS" --help 2>&1)
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "build-worker-hints" "--help mentions script name"
assert_contains "$OUT" "skill-config.json" "--help mentions config file"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Missing directory error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Missing directory error"
ERR=$(bash "$HINTS" "/nonexistent/path" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails on missing dir"

# ═══════════════════════════════════════════════════════════════════════════
# 3. No arguments error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. No arguments error"
ERR=$(bash "$HINTS" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails with no args"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Empty output for unknown framework
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Unknown framework → empty output"
T=$(new_tmp)
OUT=$(bash "$HINTS" "$T")
assert_eq "$OUT" "" "unknown framework → empty output"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Exit 0 for unknown framework
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Unknown framework → exit 0"
T=$(new_tmp)
bash "$HINTS" "$T" > /dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "unknown framework → exit 0"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Detected framework produces hints block
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Detected framework → hints block"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"},"scripts":{"test":"jest","lint":"next lint","build":"next build"}}' > "$T/package.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "## Project Stack" "has header"
assert_contains "$OUT" "Framework: nextjs" "has framework"
assert_contains "$OUT" "Test: npm test" "has test command"
assert_contains "$OUT" "Lint: npm run lint" "has lint command"
assert_contains "$OUT" "Build: npm run build" "has build command"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Rust detection produces hints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Rust hints"
T=$(new_tmp)
echo '[package]
name = "myapp"' > "$T/Cargo.toml"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: rust" "rust framework in hints"
assert_contains "$OUT" "Test: cargo test" "rust test in hints"
assert_contains "$OUT" "Lint: cargo clippy" "rust lint in hints"
assert_contains "$OUT" "Build: cargo build" "rust build in hints"

# ═══════════════════════════════════════════════════════════════════════════
# 8. Config overrides detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. Config overrides detection"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T/package.json"
mkdir -p "$T/.autonomous"
echo '{"framework":"custom-next","test_command":"pnpm test","lint_command":"pnpm lint"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: custom-next" "config overrides framework"
assert_contains "$OUT" "Test: pnpm test" "config overrides test command"
assert_contains "$OUT" "Lint: pnpm lint" "config overrides lint command"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Partial config override (only some fields)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Partial config override"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"},"scripts":{"test":"jest","lint":"next lint","build":"next build"}}' > "$T/package.json"
mkdir -p "$T/.autonomous"
echo '{"test_command":"yarn test"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: nextjs" "detection framework preserved"
assert_contains "$OUT" "Test: yarn test" "config overrides test only"
assert_contains "$OUT" "Lint: npm run lint" "detection lint preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Worker hints array
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Worker hints array"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T/package.json"
mkdir -p "$T/.autonomous"
echo '{"worker_hints":["always run type-check before committing","use pnpm not npm"]}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Hints:" "has hints header"
assert_contains "$OUT" "always run type-check before committing" "has first hint"
assert_contains "$OUT" "use pnpm not npm" "has second hint"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Config with unknown framework but with commands
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Config-only project (no detection markers)"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"framework":"custom","test_command":"make test","lint_command":"make lint"}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: custom" "config-only framework"
assert_contains "$OUT" "Test: make test" "config-only test"
assert_contains "$OUT" "Lint: make lint" "config-only lint"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Config with only worker_hints (no framework)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Config with only hints"
T=$(new_tmp)
mkdir -p "$T/.autonomous"
echo '{"worker_hints":["check logs after deploy"]}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "## Project Stack" "has header even with hints only"
assert_contains "$OUT" "Framework: unknown" "unknown framework shown"
assert_contains "$OUT" "check logs after deploy" "hint present"

# ═══════════════════════════════════════════════════════════════════════════
# 13. No hints section when no worker_hints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. No hints section when empty"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T/package.json"
OUT=$(bash "$HINTS" "$T")
assert_not_contains "$OUT" "Hints:" "no hints section without worker_hints"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Go detection through hints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Go project hints"
T=$(new_tmp)
echo 'module example.com/app
go 1.21' > "$T/go.mod"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: go" "go in hints"
assert_contains "$OUT" "Test: go test" "go test in hints"

# ═══════════════════════════════════════════════════════════════════════════
# 15. Python detection through hints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Python project hints"
T=$(new_tmp)
echo 'flask' > "$T/requirements.txt"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: python" "python in hints"
assert_contains "$OUT" "Test: pytest" "pytest in hints"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Multi-line output format
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Multi-line format"
T=$(new_tmp)
echo '[package]
name = "myapp"' > "$T/Cargo.toml"
OUT=$(bash "$HINTS" "$T")
LINES=$(echo "$OUT" | wc -l | tr -d ' ')
assert_ge "$LINES" "4" "at least 4 lines for framework with all commands"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Invalid config JSON is ignored
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Invalid config JSON ignored"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T/package.json"
mkdir -p "$T/.autonomous"
echo 'not valid json{{{' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: nextjs" "invalid config falls back to detection"

# ═══════════════════════════════════════════════════════════════════════════
# 18. No build line when no build command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. No build line when absent"
T=$(new_tmp)
echo 'flask' > "$T/requirements.txt"
OUT=$(bash "$HINTS" "$T")
assert_not_contains "$OUT" "Build:" "no build line for python"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Empty config file (no overrides)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Empty config object"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"},"scripts":{"test":"jest"}}' > "$T/package.json"
mkdir -p "$T/.autonomous"
echo '{}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: nextjs" "empty config → detection preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Bash project hints
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Bash project hints"
T=$(new_tmp)
mkdir -p "$T/scripts" "$T/tests"
echo '#!/bin/bash' > "$T/scripts/run.sh"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: bash" "bash in hints"
assert_contains "$OUT" "Lint: shellcheck" "shellcheck in hints"

# ═══════════════════════════════════════════════════════════════════════════
# 21. Config with empty worker_hints array
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. Empty worker_hints array"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T/package.json"
mkdir -p "$T/.autonomous"
echo '{"worker_hints":[]}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_not_contains "$OUT" "Hints:" "empty hints array → no hints section"

# ═══════════════════════════════════════════════════════════════════════════
# 22. Config overrides build to null-like empty string produces no Build line
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. Full config override for Ruby"
T=$(new_tmp)
echo 'source "https://rubygems.org"' > "$T/Gemfile"
mkdir -p "$T/.autonomous"
echo '{"test_command":"bundle exec rake test","worker_hints":["use rbenv"]}' > "$T/.autonomous/skill-config.json"
OUT=$(bash "$HINTS" "$T")
assert_contains "$OUT" "Framework: ruby" "ruby framework"
assert_contains "$OUT" "Test: bundle exec rake test" "config overrides ruby test"
assert_contains "$OUT" "Lint: rubocop" "detection lint preserved"
assert_contains "$OUT" "use rbenv" "hint present"

# ═══════════════════════════════════════════════════════════════════════════
# 23. Exit code 0 for detected framework
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. Exit code 0"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T/package.json"
bash "$HINTS" "$T" > /dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "detected framework → exit 0"

# ═══════════════════════════════════════════════════════════════════════════
print_results
