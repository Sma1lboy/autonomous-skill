#!/usr/bin/env bash
# Tests for scripts/config-validator.sh — skill-config.json validation.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../scripts/config-validator.sh"
DETECT="$SCRIPT_DIR/../scripts/detect-framework.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_config_validator.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Helper: create project with config
setup_project() {
  local d
  d=$(new_tmp)
  mkdir -p "$d/.autonomous"
  echo "$d"
}

write_config() {
  local project="$1"
  local json="$2"
  echo "$json" > "$project/.autonomous/skill-config.json"
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help output"

OUT=$(bash "$VALIDATOR" --help 2>&1) || true
assert_contains "$OUT" "Usage" "--help shows usage"
assert_contains "$OUT" "config-validator" "--help mentions script name"
assert_contains "$OUT" "validate" "--help documents validate command"
assert_contains "$OUT" "init" "--help documents init command"
assert_contains "$OUT" "migrate" "--help documents migrate command"
echo "$OUT" | grep -qF -- "--fix" && ok "--help documents --fix flag" || fail "--help documents --fix flag"
echo "$OUT" | grep -qF -- "--json" && ok "--help documents --json flag" || fail "--help documents --json flag"

OUT=$(bash "$VALIDATOR" -h 2>&1) || true
assert_contains "$OUT" "Usage" "-h also shows usage"

OUT=$(bash "$VALIDATOR" help 2>&1) || true
assert_contains "$OUT" "Usage" "help also shows usage"

# ═══════════════════════════════════════════════════════════════════════════
# 2. validate — valid config
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. validate — valid config"

PROJECT=$(setup_project)
write_config "$PROJECT" '{
  "framework": "nextjs",
  "test_command": "npm test",
  "lint_command": "npm run lint",
  "build_command": "npm run build",
  "worker_hints": ["always type-check"],
  "dispatch_isolation": "branch",
  "worker_timeout": 600
}'

OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1)
RC=$?
assert_eq "$RC" "0" "valid config exits 0"
assert_contains "$OUT" "VALID" "valid config prints VALID"

# ═══════════════════════════════════════════════════════════════════════════
# 3. validate — valid config JSON mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. validate — JSON output"

OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1)
VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['valid'])" 2>/dev/null)
assert_eq "$VALID" "True" "JSON output shows valid=True"

ERRORS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['errors']))" 2>/dev/null)
assert_eq "$ERRORS" "0" "JSON output has no errors"

# ═══════════════════════════════════════════════════════════════════════════
# 4. validate — invalid JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. validate — invalid JSON"

PROJECT=$(setup_project)
echo '{bad json' > "$PROJECT/.autonomous/skill-config.json"

OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1) || true
assert_contains "$OUT" "INVALID" "invalid JSON detected"
assert_contains "$OUT" "invalid JSON" "error message mentions invalid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 5. validate — wrong types
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. validate — wrong types"

PROJECT=$(setup_project)
write_config "$PROJECT" '{
  "framework": 123,
  "test_command": true,
  "worker_hints": "not-an-array",
  "dispatch_isolation": "invalid",
  "worker_timeout": -5
}'

OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1) || true
ERRORS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['errors']))" 2>/dev/null)
assert_ge "$ERRORS" "4" "multiple type errors detected"

VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['valid'])" 2>/dev/null)
assert_eq "$VALID" "False" "invalid config shows valid=False"

# ═══════════════════════════════════════════════════════════════════════════
# 6. validate — unknown fields (warning)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. validate — unknown fields"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"framework":"rust","extra_field":"value","another":"x"}'

OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1)
RC=$?
assert_eq "$RC" "0" "unknown fields are warnings, not errors"

WARNINGS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['warnings']))" 2>/dev/null)
assert_ge "$WARNINGS" "2" "two unknown field warnings"

# ═══════════════════════════════════════════════════════════════════════════
# 7. validate — --fix coerces types
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. validate — --fix type coercion"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"framework": 123, "worker_timeout": 300.5}'

OUT=$(bash "$VALIDATOR" validate "$PROJECT" --fix --json 2>&1)
RC=$?
assert_eq "$RC" "0" "--fix fixes type errors, exits 0"

FIXES=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['fixes']))" 2>/dev/null)
assert_ge "$FIXES" "2" "at least 2 fixes applied"

# Verify file was actually fixed
FIXED=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print(type(d['framework']).__name__)
print(type(d['worker_timeout']).__name__)
")
FW_TYPE=$(echo "$FIXED" | head -1)
WT_TYPE=$(echo "$FIXED" | tail -1)
assert_eq "$FW_TYPE" "str" "framework coerced to string"
assert_eq "$WT_TYPE" "int" "worker_timeout coerced to int"

# ═══════════════════════════════════════════════════════════════════════════
# 8. validate — --fix removes unknown fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. validate — --fix removes unknown fields"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"framework":"go","unknown_field":"val"}'

bash "$VALIDATOR" validate "$PROJECT" --fix >/dev/null 2>&1 || true
HAS_UNKNOWN=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print('unknown_field' in d)
")
assert_eq "$HAS_UNKNOWN" "False" "unknown field removed by --fix"

# ═══════════════════════════════════════════════════════════════════════════
# 9. validate — --fix wraps worker_hints string
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. validate — --fix wraps worker_hints"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"worker_hints":"run tests first"}'

bash "$VALIDATOR" validate "$PROJECT" --fix >/dev/null 2>&1 || true
HINTS=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print(type(d['worker_hints']).__name__)
print(len(d['worker_hints']))
")
HINTS_TYPE=$(echo "$HINTS" | head -1)
HINTS_LEN=$(echo "$HINTS" | tail -1)
assert_eq "$HINTS_TYPE" "list" "worker_hints wrapped in array"
assert_eq "$HINTS_LEN" "1" "wrapped array has 1 element"

# ═══════════════════════════════════════════════════════════════════════════
# 10. validate — dispatch_isolation values
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. validate — dispatch_isolation"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"dispatch_isolation":"branch"}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1)
assert_eq "$?" "0" "branch is valid"

write_config "$PROJECT" '{"dispatch_isolation":"worktree"}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1)
assert_eq "$?" "0" "worktree is valid"

write_config "$PROJECT" '{"dispatch_isolation":"container"}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1) || true
assert_contains "$OUT" "INVALID" "container is invalid"

# ═══════════════════════════════════════════════════════════════════════════
# 11. validate — --fix lowercases dispatch_isolation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. validate — --fix dispatch_isolation case"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"dispatch_isolation":"Branch"}'

bash "$VALIDATOR" validate "$PROJECT" --fix >/dev/null 2>&1 || true
VAL=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print(d['dispatch_isolation'])
")
assert_eq "$VAL" "branch" "dispatch_isolation lowercased by --fix"

# ═══════════════════════════════════════════════════════════════════════════
# 12. validate — worker_timeout edge cases
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. validate — worker_timeout edges"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"worker_timeout": 0}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1) || true
assert_contains "$OUT" "positive" "zero timeout is invalid"

write_config "$PROJECT" '{"worker_timeout": true}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1) || true
assert_contains "$OUT" "positive integer" "boolean timeout is invalid"

write_config "$PROJECT" '{"worker_timeout": "300"}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1) || true
ERRORS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['errors']))" 2>/dev/null)
assert_ge "$ERRORS" "1" "string timeout is error"

# ═══════════════════════════════════════════════════════════════════════════
# 13. validate — --fix string worker_timeout
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. validate — --fix string timeout"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"worker_timeout": "450"}'

bash "$VALIDATOR" validate "$PROJECT" --fix >/dev/null 2>&1 || true
VAL=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print(d['worker_timeout'])
print(type(d['worker_timeout']).__name__)
")
TIMEOUT_VAL=$(echo "$VAL" | head -1)
TIMEOUT_TYPE=$(echo "$VAL" | tail -1)
assert_eq "$TIMEOUT_VAL" "450" "string timeout coerced to 450"
assert_eq "$TIMEOUT_TYPE" "int" "timeout is now int type"

# ═══════════════════════════════════════════════════════════════════════════
# 14. validate — empty config is valid
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. validate — empty object"

PROJECT=$(setup_project)
write_config "$PROJECT" '{}'

OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1)
assert_eq "$?" "0" "empty object is valid"
assert_contains "$OUT" "VALID" "empty object shows VALID"

# ═══════════════════════════════════════════════════════════════════════════
# 15. validate — not an object
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. validate — non-object"

PROJECT=$(setup_project)
write_config "$PROJECT" '[]'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1) || true
assert_contains "$OUT" "INVALID" "array root is invalid"

write_config "$PROJECT" '"just a string"'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1) || true
assert_contains "$OUT" "INVALID" "string root is invalid"

# ═══════════════════════════════════════════════════════════════════════════
# 16. validate — missing config file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. validate — missing file"

PROJECT=$(setup_project)
rm -f "$PROJECT/.autonomous/skill-config.json"
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1) || true
assert_contains "$OUT" "ERROR" "missing config file shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 17. validate — empty string warnings
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. validate — empty strings"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"framework":"","test_command":""}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1)
WARNINGS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['warnings']))" 2>/dev/null)
assert_ge "$WARNINGS" "2" "empty strings produce warnings"

# ═══════════════════════════════════════════════════════════════════════════
# 18. init — creates config from detect-framework
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. init — basic"

PROJECT=$(setup_project)
rm -f "$PROJECT/.autonomous/skill-config.json"
# Create a bash project for detection
mkdir -p "$PROJECT/tests" "$PROJECT/scripts"
touch "$PROJECT/scripts/foo.sh"

OUT=$(bash "$VALIDATOR" init "$PROJECT" 2>&1)
assert_contains "$OUT" "Created" "init prints confirmation"
assert_file_exists "$PROJECT/.autonomous/skill-config.json" "config file created"

# Verify content
FW=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print(d.get('framework',''))
")
[ -n "$FW" ] && ok "framework field populated" || fail "framework field empty"

# ═══════════════════════════════════════════════════════════════════════════
# 19. init — won't overwrite existing
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "19. init — no overwrite"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"framework":"custom"}'
OUT=$(bash "$VALIDATOR" init "$PROJECT" 2>&1)
assert_contains "$OUT" "already exists" "init won't overwrite"

FW=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    print(json.load(f)['framework'])
")
assert_eq "$FW" "custom" "original config preserved"

# ═══════════════════════════════════════════════════════════════════════════
# 20. init — JSON mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "20. init — JSON output"

PROJECT=$(setup_project)
rm -f "$PROJECT/.autonomous/skill-config.json"
OUT=$(bash "$VALIDATOR" init "$PROJECT" --json 2>&1)
CREATED=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['created'])" 2>/dev/null)
assert_eq "$CREATED" "True" "JSON init shows created=True"

# already exists case
OUT=$(bash "$VALIDATOR" init "$PROJECT" --json 2>&1)
CREATED=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['created'])" 2>/dev/null)
assert_eq "$CREATED" "False" "JSON init shows created=False when exists"

# ═══════════════════════════════════════════════════════════════════════════
# 21. migrate — camelCase fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "21. migrate — camelCase"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"testCommand":"npm test","lintCommand":"npm run lint"}'

OUT=$(bash "$VALIDATOR" migrate "$PROJECT" 2>&1)
assert_contains "$OUT" "migration" "migrate detects old fields"
assert_contains "$OUT" "testCommand" "migrate mentions old field name"

# dry-run: file should not change
HAS_OLD=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print('testCommand' in d)
")
assert_eq "$HAS_OLD" "True" "dry-run does not modify file"

# ═══════════════════════════════════════════════════════════════════════════
# 22. migrate — --fix applies changes
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "22. migrate — --fix"

OUT=$(bash "$VALIDATOR" migrate "$PROJECT" --fix 2>&1)
assert_contains "$OUT" "Applied" "migrate --fix shows applied"

RESULT=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print('testCommand' in d)
print('test_command' in d)
print(d['test_command'])
")
HAS_OLD=$(echo "$RESULT" | sed -n '1p')
HAS_NEW=$(echo "$RESULT" | sed -n '2p')
NEW_VAL=$(echo "$RESULT" | sed -n '3p')
assert_eq "$HAS_OLD" "False" "old camelCase field removed"
assert_eq "$HAS_NEW" "True" "new snake_case field added"
assert_eq "$NEW_VAL" "npm test" "value preserved during migration"

# ═══════════════════════════════════════════════════════════════════════════
# 23. migrate — kebab-case fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "23. migrate — kebab-case"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"test-command":"pytest","worker-timeout":"300"}'

OUT=$(bash "$VALIDATOR" migrate "$PROJECT" --fix --json 2>&1)
MIGRATED=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['migrated'])" 2>/dev/null)
assert_eq "$MIGRATED" "True" "kebab-case fields migrated"

# ═══════════════════════════════════════════════════════════════════════════
# 24. migrate — no changes needed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "24. migrate — nothing to do"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"framework":"rust","test_command":"cargo test"}'

OUT=$(bash "$VALIDATOR" migrate "$PROJECT" 2>&1)
assert_contains "$OUT" "No migrations" "no migrations when up-to-date"

# ═══════════════════════════════════════════════════════════════════════════
# 25. migrate — missing config
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "25. migrate — no config file"

PROJECT=$(setup_project)
rm -f "$PROJECT/.autonomous/skill-config.json"
OUT=$(bash "$VALIDATOR" migrate "$PROJECT" 2>&1)
assert_contains "$OUT" "No config" "migrate handles missing config"

# ═══════════════════════════════════════════════════════════════════════════
# 26. migrate — JSON output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "26. migrate — JSON no config"

PROJECT=$(setup_project)
rm -f "$PROJECT/.autonomous/skill-config.json"
OUT=$(bash "$VALIDATOR" migrate "$PROJECT" --json 2>&1)
MIGRATED=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['migrated'])" 2>/dev/null)
assert_eq "$MIGRATED" "False" "JSON migrate false when no file"

# ═══════════════════════════════════════════════════════════════════════════
# 27. migrate — worker_hints string wrap
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "27. migrate — worker_hints string"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"worker_hints":"run tests"}'

OUT=$(bash "$VALIDATOR" migrate "$PROJECT" --fix 2>&1)
HINTS_TYPE=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print(type(d['worker_hints']).__name__)
")
assert_eq "$HINTS_TYPE" "list" "string worker_hints wrapped by migrate"

# ═══════════════════════════════════════════════════════════════════════════
# 28. migrate — invalid JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "28. migrate — invalid JSON"

PROJECT=$(setup_project)
echo 'not json' > "$PROJECT/.autonomous/skill-config.json"
OUT=$(bash "$VALIDATOR" migrate "$PROJECT" 2>&1) || true
assert_contains "$OUT" "invalid JSON" "migrate handles corrupt file"

# ═══════════════════════════════════════════════════════════════════════════
# 29. error handling — missing command
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "29. error handling"

OUT=$(bash "$VALIDATOR" 2>&1) || true
assert_contains "$OUT" "ERROR" "no command shows error"

OUT=$(bash "$VALIDATOR" badcmd 2>&1) || true
assert_contains "$OUT" "ERROR" "unknown command shows error"

# ═══════════════════════════════════════════════════════════════════════════
# 30. validate — worker_hints array with non-string elements
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "30. validate — worker_hints bad elements"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"worker_hints":["good",123,true]}'

OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1) || true
ERRORS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['errors']))" 2>/dev/null)
assert_ge "$ERRORS" "2" "non-string array elements caught"

# ═══════════════════════════════════════════════════════════════════════════
# 31. validate — --fix coerces array elements
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "31. validate — --fix array elements"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"worker_hints":["good",123]}'

bash "$VALIDATOR" validate "$PROJECT" --fix >/dev/null 2>&1 || true
RESULT=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print(d['worker_hints'][1])
print(type(d['worker_hints'][1]).__name__)
")
VAL=$(echo "$RESULT" | head -1)
TYPE=$(echo "$RESULT" | tail -1)
assert_eq "$VAL" "123" "element coerced to string '123'"
assert_eq "$TYPE" "str" "element type is now str"

# ═══════════════════════════════════════════════════════════════════════════
# 32. validate — missing project dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "32. validate — bad project"

OUT=$(bash "$VALIDATOR" validate 2>&1) || true
assert_contains "$OUT" "ERROR" "validate without dir errors"

OUT=$(bash "$VALIDATOR" validate /nonexistent 2>&1) || true
assert_contains "$OUT" "ERROR" "validate with bad dir errors"

# ═══════════════════════════════════════════════════════════════════════════
# 33. init — missing project dir
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "33. init — bad project"

OUT=$(bash "$VALIDATOR" init 2>&1) || true
assert_contains "$OUT" "ERROR" "init without dir errors"

OUT=$(bash "$VALIDATOR" init /nonexistent 2>&1) || true
assert_contains "$OUT" "ERROR" "init with bad dir errors"

# ═══════════════════════════════════════════════════════════════════════════
# 34. migrate — duplicate old+new fields
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "34. migrate — duplicate old+new"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"testCommand":"old","test_command":"new"}'

OUT=$(bash "$VALIDATOR" migrate "$PROJECT" --fix --json 2>&1)
RESULT=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print('testCommand' in d)
print(d['test_command'])
")
HAS_OLD=$(echo "$RESULT" | head -1)
NEW_VAL=$(echo "$RESULT" | tail -1)
assert_eq "$HAS_OLD" "False" "old duplicate removed"
assert_eq "$NEW_VAL" "new" "new field preserved over old"

# ═══════════════════════════════════════════════════════════════════════════
# 35. validate — minimal valid configs
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "35. validate — minimal configs"

PROJECT=$(setup_project)

write_config "$PROJECT" '{"framework":"python"}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1)
assert_eq "$?" "0" "framework-only config valid"

write_config "$PROJECT" '{"worker_timeout":100}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1)
assert_eq "$?" "0" "timeout-only config valid"

write_config "$PROJECT" '{"worker_hints":[]}'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" 2>&1)
assert_eq "$?" "0" "empty hints array valid"

# ═══════════════════════════════════════════════════════════════════════════
# 36. init — creates .autonomous dir if needed
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "36. init — creates .autonomous dir"

PROJECT=$(new_tmp)
# Don't create .autonomous dir
OUT=$(bash "$VALIDATOR" init "$PROJECT" 2>&1)
assert_file_exists "$PROJECT/.autonomous/skill-config.json" ".autonomous dir auto-created"

# ═══════════════════════════════════════════════════════════════════════════
# 37. validate — JSON invalid JSON
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "37. validate — JSON mode invalid JSON"

PROJECT=$(setup_project)
echo '{corrupt' > "$PROJECT/.autonomous/skill-config.json"
OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1) || true
VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['valid'])" 2>/dev/null)
assert_eq "$VALID" "False" "JSON mode reports invalid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 38. validate — non-object JSON mode
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "38. validate — non-object JSON mode"

PROJECT=$(setup_project)
write_config "$PROJECT" '[1,2,3]'
OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1) || true
VALID=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['valid'])" 2>/dev/null)
assert_eq "$VALID" "False" "array root invalid in JSON mode"

# ═══════════════════════════════════════════════════════════════════════════
# 39. migrate — dispatch_isolation case
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "39. migrate — dispatch_isolation case fix"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"dispatch_isolation":"Worktree"}'

OUT=$(bash "$VALIDATOR" migrate "$PROJECT" --fix 2>&1)
VAL=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    print(json.load(f)['dispatch_isolation'])
")
assert_eq "$VAL" "worktree" "migrate fixes case"

# ═══════════════════════════════════════════════════════════════════════════
# 40. migrate — worker_timeout string conversion
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "40. migrate — timeout string"

PROJECT=$(setup_project)
write_config "$PROJECT" '{"worker_timeout":"900"}'

OUT=$(bash "$VALIDATOR" migrate "$PROJECT" --fix --json 2>&1)
MIGRATED=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['migrated'])" 2>/dev/null)
assert_eq "$MIGRATED" "True" "string timeout migrated"

TYPE=$(python3 -c "
import json
with open('$PROJECT/.autonomous/skill-config.json') as f:
    d = json.load(f)
print(type(d['worker_timeout']).__name__)
")
assert_eq "$TYPE" "int" "timeout converted to int"

# ═══════════════════════════════════════════════════════════════════════════
# 41. validate — all fields present and valid
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "41. validate — complete config"

PROJECT=$(setup_project)
write_config "$PROJECT" '{
  "framework": "python",
  "test_command": "pytest",
  "lint_command": "flake8",
  "build_command": "python setup.py build",
  "worker_hints": ["check types", "run mypy"],
  "dispatch_isolation": "worktree",
  "worker_timeout": 900
}'

OUT=$(bash "$VALIDATOR" validate "$PROJECT" --json 2>&1)
RC=$?
assert_eq "$RC" "0" "complete valid config passes"
ERRORS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['errors']))" 2>/dev/null)
WARNINGS=$(python3 -c "import json; d=json.loads('''$OUT'''); print(len(d['warnings']))" 2>/dev/null)
assert_eq "$ERRORS" "0" "no errors"
assert_eq "$WARNINGS" "0" "no warnings"

# ═══════════════════════════════════════════════════════════════════════════
# 42. init — detects node project
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "42. init — node project detection"

PROJECT=$(setup_project)
rm -f "$PROJECT/.autonomous/skill-config.json"
echo '{"name":"test","scripts":{"test":"jest"}}' > "$PROJECT/package.json"

OUT=$(bash "$VALIDATOR" init "$PROJECT" --json 2>&1)
FW=$(python3 -c "import json; d=json.loads('''$OUT'''); print(d['config']['framework'])" 2>/dev/null)
assert_eq "$FW" "node" "node framework detected"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

print_results
