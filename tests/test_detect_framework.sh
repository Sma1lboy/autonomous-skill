#!/usr/bin/env bash
# Tests for scripts/detect-framework.sh — framework/stack auto-detection.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/../scripts/detect-framework.sh"

# Helper: get a field from detection JSON
get_field() {
  local json="$1" field="$2"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2],''))" "$json" "$field"
}

# Helper: check if a tool is in detected_tools array
has_tool() {
  local json="$1" tool="$2"
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('yes' if sys.argv[2] in d.get('detected_tools',[]) else 'no')" "$json" "$tool"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_detect_framework.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help flag"
OUT=$(bash "$DETECT" --help 2>&1)
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "detect-framework" "--help mentions script name"
assert_contains "$OUT" "package.json" "--help lists package.json marker"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Missing directory error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Missing directory error"
ERR=$(bash "$DETECT" "/nonexistent/path" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails on missing dir"

# ═══════════════════════════════════════════════════════════════════════════
# 3. No arguments error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. No arguments error"
ERR=$(bash "$DETECT" 2>&1 || true)
assert_contains "$ERR" "ERROR" "fails with no args"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Unknown framework (empty dir)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. Unknown framework (empty dir)"
T=$(new_tmp)
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "unknown" "empty dir → unknown framework"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Plain Node.js (package.json, no framework deps)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Plain Node.js"
T=$(new_tmp)
echo '{"name":"myapp","scripts":{"test":"jest","build":"tsc"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
BUILD=$(get_field "$OUT" "build_command")
assert_eq "$FW" "node" "plain package.json → node"
assert_eq "$TEST" "npm test" "node with test script → npm test"
assert_eq "$BUILD" "npm run build" "node with build script → npm run build"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Next.js detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. Next.js detection"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0","react":"18.0.0"},"scripts":{"test":"jest","lint":"next lint","build":"next build"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
LINT=$(get_field "$OUT" "lint_command")
BUILD=$(get_field "$OUT" "build_command")
assert_eq "$FW" "nextjs" "next dep → nextjs"
assert_eq "$TEST" "npm test" "nextjs with test script → npm test"
assert_eq "$LINT" "npm run lint" "nextjs with lint script → npm run lint"
assert_eq "$BUILD" "npm run build" "nextjs with build script → npm run build"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Next.js without scripts (fallback commands)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Next.js without scripts"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
LINT=$(get_field "$OUT" "lint_command")
assert_eq "$FW" "nextjs" "next dep without scripts → nextjs"
assert_eq "$TEST" "npx jest" "nextjs no test script → npx jest"
assert_eq "$LINT" "npx next lint" "nextjs no lint script → npx next lint"

# ═══════════════════════════════════════════════════════════════════════════
# 8. React detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. React detection"
T=$(new_tmp)
echo '{"dependencies":{"react":"18.0.0","react-dom":"18.0.0"},"scripts":{"test":"jest"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "react" "react dep → react"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Vue detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. Vue detection"
T=$(new_tmp)
echo '{"dependencies":{"vue":"3.0.0"},"scripts":{"test":"vitest","lint":"eslint .","build":"vite build"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
LINT=$(get_field "$OUT" "lint_command")
assert_eq "$FW" "vue" "vue dep → vue"
assert_eq "$LINT" "npm run lint" "vue with lint script → npm run lint"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Angular detection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Angular detection"
T=$(new_tmp)
echo '{"dependencies":{"@angular/core":"17.0.0"},"scripts":{"test":"ng test","lint":"ng lint","build":"ng build"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "angular" "@angular/core dep → angular"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Rust (Cargo.toml)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Rust detection"
T=$(new_tmp)
echo '[package]
name = "myapp"
version = "0.1.0"' > "$T/Cargo.toml"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
LINT=$(get_field "$OUT" "lint_command")
BUILD=$(get_field "$OUT" "build_command")
assert_eq "$FW" "rust" "Cargo.toml → rust"
assert_eq "$TEST" "cargo test" "rust test command"
assert_eq "$LINT" "cargo clippy" "rust lint command"
assert_eq "$BUILD" "cargo build" "rust build command"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Go (go.mod)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Go detection"
T=$(new_tmp)
echo 'module example.com/myapp
go 1.21' > "$T/go.mod"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
assert_eq "$FW" "go" "go.mod → go"
assert_eq "$TEST" "go test ./..." "go test command"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Python (requirements.txt)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Python via requirements.txt"
T=$(new_tmp)
echo 'flask==2.0.0' > "$T/requirements.txt"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
LINT=$(get_field "$OUT" "lint_command")
assert_eq "$FW" "python" "requirements.txt → python"
assert_eq "$TEST" "pytest" "python test command"
assert_eq "$LINT" "ruff check ." "python lint command"

# ═══════════════════════════════════════════════════════════════════════════
# 14. Python (pyproject.toml)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. Python via pyproject.toml"
T=$(new_tmp)
echo '[project]
name = "myapp"' > "$T/pyproject.toml"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "python" "pyproject.toml → python"

# ═══════════════════════════════════════════════════════════════════════════
# 15. Ruby (Gemfile)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. Ruby detection"
T=$(new_tmp)
echo 'source "https://rubygems.org"
gem "rails"' > "$T/Gemfile"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
LINT=$(get_field "$OUT" "lint_command")
assert_eq "$FW" "ruby" "Gemfile → ruby"
assert_eq "$TEST" "bundle exec rspec" "ruby test command"
assert_eq "$LINT" "rubocop" "ruby lint command"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Java Maven (pom.xml)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Java Maven detection"
T=$(new_tmp)
echo '<project><modelVersion>4.0.0</modelVersion></project>' > "$T/pom.xml"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
BUILD=$(get_field "$OUT" "build_command")
assert_eq "$FW" "java-maven" "pom.xml → java-maven"
assert_eq "$TEST" "mvn test" "maven test command"
assert_eq "$BUILD" "mvn package" "maven build command"

# ═══════════════════════════════════════════════════════════════════════════
# 17. Java Gradle (build.gradle)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. Java Gradle detection"
T=$(new_tmp)
echo 'plugins { id "java" }' > "$T/build.gradle"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
BUILD=$(get_field "$OUT" "build_command")
assert_eq "$FW" "java-gradle" "build.gradle → java-gradle"
assert_eq "$TEST" "gradle test" "gradle test command"
assert_eq "$BUILD" "gradle build" "gradle build command"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Java Gradle Kotlin DSL (build.gradle.kts)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Java Gradle Kotlin DSL"
T=$(new_tmp)
echo 'plugins { java }' > "$T/build.gradle.kts"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "java-gradle" "build.gradle.kts → java-gradle"

# ═══════════════════════════════════════════════════════════════════════════
# 19. Bash detection (*.sh + tests/)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. Bash detection"
T=$(new_tmp)
mkdir -p "$T/scripts" "$T/tests"
echo '#!/bin/bash' > "$T/scripts/run.sh"
echo '#!/bin/bash' > "$T/tests/test_foo.sh"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
LINT=$(get_field "$OUT" "lint_command")
assert_eq "$FW" "bash" "sh files + tests/ → bash"
assert_eq "$TEST" "bash tests/test_*.sh" "bash test command"
assert_eq "$LINT" "shellcheck scripts/*.sh" "bash lint command"

# ═══════════════════════════════════════════════════════════════════════════
# 20. Bash detection — root-level .sh files, no scripts/ dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. Bash detection — root .sh files"
T=$(new_tmp)
echo '#!/bin/bash' > "$T/run.sh"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
LINT=$(get_field "$OUT" "lint_command")
assert_eq "$FW" "bash" "root .sh file → bash"
assert_eq "$LINT" "shellcheck *.sh" "root sh → shellcheck *.sh"

# ═══════════════════════════════════════════════════════════════════════════
# 21. package.json priority over other markers
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. package.json takes priority"
T=$(new_tmp)
echo '{"dependencies":{"react":"18.0.0"}}' > "$T/package.json"
echo 'flask==2.0.0' > "$T/requirements.txt"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "react" "package.json wins over requirements.txt"

# ═══════════════════════════════════════════════════════════════════════════
# 22. Tool detection in devDependencies
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. Tool detection"
T=$(new_tmp)
echo '{"devDependencies":{"typescript":"5.0.0","eslint":"8.0.0","prettier":"3.0.0","jest":"29.0.0"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
TS=$(has_tool "$OUT" "typescript")
ESLINT=$(has_tool "$OUT" "eslint")
PRETTIER=$(has_tool "$OUT" "prettier")
JEST=$(has_tool "$OUT" "jest")
assert_eq "$TS" "yes" "detects typescript"
assert_eq "$ESLINT" "yes" "detects eslint"
assert_eq "$PRETTIER" "yes" "detects prettier"
assert_eq "$JEST" "yes" "detects jest"

# ═══════════════════════════════════════════════════════════════════════════
# 23. Output is valid JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. Output is valid JSON"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
VALID=$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('yes')" "$OUT" 2>/dev/null || echo "no")
assert_eq "$VALID" "yes" "output is valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 24. Unknown output is valid JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. Unknown framework JSON"
T=$(new_tmp)
OUT=$(bash "$DETECT" "$T")
VALID=$(python3 -c "import json,sys; json.loads(sys.argv[1]); print('yes')" "$OUT" 2>/dev/null || echo "no")
assert_eq "$VALID" "yes" "unknown output is valid JSON"
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "unknown" "unknown framework value"

# ═══════════════════════════════════════════════════════════════════════════
# 25. Node.js without any scripts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. Node.js without scripts"
T=$(new_tmp)
echo '{"name":"myapp"}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
TEST=$(get_field "$OUT" "test_command")
assert_eq "$FW" "node" "minimal package.json → node"
assert_eq "$TEST" "" "node without test script → no test command"

# ═══════════════════════════════════════════════════════════════════════════
# 26. React without react-dom
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. React via react-dom only"
T=$(new_tmp)
echo '{"dependencies":{"react-dom":"18.0.0"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "react" "react-dom dep → react"

# ═══════════════════════════════════════════════════════════════════════════
# 27. Null fields omitted from output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. Null fields omitted"
T=$(new_tmp)
echo '{"name":"myapp"}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
HAS_BUILD=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('yes' if 'build_command' in d else 'no')" "$OUT")
assert_eq "$HAS_BUILD" "no" "null build_command omitted from JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 28. Maven has no lint command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. Maven lint omitted"
T=$(new_tmp)
echo '<project/>' > "$T/pom.xml"
OUT=$(bash "$DETECT" "$T")
HAS_LINT=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('yes' if 'lint_command' in d else 'no')" "$OUT")
assert_eq "$HAS_LINT" "no" "maven has no lint command"

# ═══════════════════════════════════════════════════════════════════════════
# 29. Python has no build command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. Python build omitted"
T=$(new_tmp)
echo 'flask' > "$T/requirements.txt"
OUT=$(bash "$DETECT" "$T")
HAS_BUILD=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('yes' if 'build_command' in d else 'no')" "$OUT")
assert_eq "$HAS_BUILD" "no" "python has no build command"

# ═══════════════════════════════════════════════════════════════════════════
# 30. Bash detection without tests dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. Bash without tests dir"
T=$(new_tmp)
mkdir -p "$T/scripts"
echo '#!/bin/bash' > "$T/scripts/run.sh"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
HAS_TEST=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('yes' if 'test_command' in d else 'no')" "$OUT")
assert_eq "$FW" "bash" "sh without tests/ → bash"
assert_eq "$HAS_TEST" "no" "bash no tests/ → no test command"

# ═══════════════════════════════════════════════════════════════════════════
# 31. Angular without scripts (fallback commands)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. Angular fallback commands"
T=$(new_tmp)
echo '{"dependencies":{"@angular/core":"17.0.0"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
TEST=$(get_field "$OUT" "test_command")
LINT=$(get_field "$OUT" "lint_command")
BUILD=$(get_field "$OUT" "build_command")
assert_eq "$TEST" "npx ng test" "angular fallback test"
assert_eq "$LINT" "npx ng lint" "angular fallback lint"
assert_eq "$BUILD" "npx ng build" "angular fallback build"

# ═══════════════════════════════════════════════════════════════════════════
# 32. Vue without scripts (fallback commands)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "32. Vue fallback commands"
T=$(new_tmp)
echo '{"dependencies":{"vue":"3.0.0"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
TEST=$(get_field "$OUT" "test_command")
LINT=$(get_field "$OUT" "lint_command")
BUILD=$(get_field "$OUT" "build_command")
assert_eq "$TEST" "npx vitest" "vue fallback test"
assert_eq "$LINT" "npx eslint ." "vue fallback lint"
assert_eq "$BUILD" "npx vite build" "vue fallback build"

# ═══════════════════════════════════════════════════════════════════════════
# 33. Next.js wins over React when both present
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "33. Next.js wins over React"
T=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0","react":"18.0.0","react-dom":"18.0.0"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
FW=$(get_field "$OUT" "framework")
assert_eq "$FW" "nextjs" "next + react → nextjs wins"

# ═══════════════════════════════════════════════════════════════════════════
# 34. Exit code 0 for all detections
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "34. Exit codes"
T=$(new_tmp)
bash "$DETECT" "$T" > /dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "unknown framework → exit 0"

T2=$(new_tmp)
echo '{"dependencies":{"next":"14.0.0"}}' > "$T2/package.json"
bash "$DETECT" "$T2" > /dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "known framework → exit 0"

# ═══════════════════════════════════════════════════════════════════════════
# 35. Tool detection from dependencies (not just devDependencies)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "35. Tool detection from dependencies"
T=$(new_tmp)
echo '{"dependencies":{"tailwindcss":"3.0.0"}}' > "$T/package.json"
OUT=$(bash "$DETECT" "$T")
TW=$(has_tool "$OUT" "tailwindcss")
assert_eq "$TW" "yes" "detects tailwindcss from dependencies"

# ═══════════════════════════════════════════════════════════════════════════
print_results
