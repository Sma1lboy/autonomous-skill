#!/usr/bin/env bash
# config-validator.sh — Validate .autonomous/skill-config.json schema.
# Supports validate, init (from detect-framework.sh), migrate, and --fix.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: config-validator.sh <command> <project-dir> [options]

Validate and manage .autonomous/skill-config.json files.

Commands:
  validate <project-dir> [--fix]
      Check skill-config.json against the expected schema.
      Fields: framework (string), test_command (string), lint_command (string),
              build_command (string), worker_hints (string[]),
              dispatch_isolation ("branch"|"worktree"), worker_timeout (positive int).
      --fix: auto-fix common issues (type coercion, remove unknown fields)

  init <project-dir>
      Create skill-config.json with defaults from detect-framework.sh.
      Will not overwrite an existing config.

  migrate <project-dir> [--fix]
      Detect old/incompatible formats and upgrade to current schema.
      --fix: apply migrations automatically (otherwise dry-run report)

Options:
  --json              Machine-readable JSON output
  --fix               Auto-fix common issues (validate, migrate)
  -h, --help          Show this help message

Schema:
  {
    "framework": "string",           // e.g., "nextjs", "rust", "python"
    "test_command": "string",        // e.g., "npm test"
    "lint_command": "string",        // e.g., "npm run lint"
    "build_command": "string",       // e.g., "npm run build"
    "worker_hints": ["string"],      // additional worker hints
    "dispatch_isolation": "string",  // "branch" or "worktree"
    "worker_timeout": integer        // positive integer (seconds)
  }

Exit codes:
  0  Valid / success
  1  Invalid / errors found

Examples:
  bash scripts/config-validator.sh validate ./my-project
  bash scripts/config-validator.sh validate ./my-project --fix --json
  bash scripts/config-validator.sh init ./my-project
  bash scripts/config-validator.sh migrate ./my-project --fix
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || die "python3 required but not found"

# ── Parse arguments ──────────────────────────────────────────────────────

CMD="${1:-}"
[ -z "$CMD" ] && die "command is required. Use: validate|init|migrate"
shift

PROJECT_DIR=""
JSON_MODE=false
FIX_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --fix)
      FIX_MODE=true
      shift
      ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Validate command ────────────────────────────────────────────────────

cmd_validate() {
  [ -z "$PROJECT_DIR" ] && die "validate requires project-dir"
  [ -d "$PROJECT_DIR" ] || die "project dir not found: $PROJECT_DIR"

  local config_file="$PROJECT_DIR/.autonomous/skill-config.json"
  [ -f "$config_file" ] || die "skill-config.json not found: $config_file"

  python3 - "$config_file" "$JSON_MODE" "$FIX_MODE" << 'PYEOF'
import json, sys, os

config_file = sys.argv[1]
json_mode = sys.argv[2] == "true"
fix_mode = sys.argv[3] == "true"

errors = []
warnings = []
fixes = []

# Try to load JSON
try:
    with open(config_file) as f:
        config = json.load(f)
except json.JSONDecodeError as e:
    if json_mode:
        print(json.dumps({"valid": False, "errors": [f"invalid JSON: {e}"], "warnings": [], "fixes": []}))
    else:
        print(f"INVALID: {config_file}")
        print(f"  Error: invalid JSON: {e}")
    sys.exit(1)

if not isinstance(config, dict):
    if json_mode:
        print(json.dumps({"valid": False, "errors": ["config must be a JSON object"], "warnings": [], "fixes": []}))
    else:
        print(f"INVALID: {config_file}")
        print("  Error: config must be a JSON object")
    sys.exit(1)

KNOWN_FIELDS = {
    "framework", "test_command", "lint_command", "build_command",
    "worker_hints", "dispatch_isolation", "worker_timeout"
}

STRING_FIELDS = ["framework", "test_command", "lint_command", "build_command"]

modified = False

# Check for unknown fields
unknown = set(config.keys()) - KNOWN_FIELDS
for field in unknown:
    warnings.append(f"unknown field: '{field}'")
    if fix_mode:
        del config[field]
        fixes.append(f"removed unknown field: '{field}'")
        modified = True

# Validate string fields
for field in STRING_FIELDS:
    if field in config:
        val = config[field]
        if not isinstance(val, str):
            errors.append(f"'{field}' must be a string, got {type(val).__name__}")
            if fix_mode and val is not None:
                config[field] = str(val)
                fixes.append(f"coerced '{field}' to string")
                errors.pop()
                modified = True
        elif val == "":
            warnings.append(f"'{field}' is empty")

# Validate worker_hints
if "worker_hints" in config:
    val = config["worker_hints"]
    if not isinstance(val, list):
        errors.append("'worker_hints' must be an array of strings")
        if fix_mode and isinstance(val, str):
            config["worker_hints"] = [val]
            fixes.append("wrapped 'worker_hints' string in array")
            errors.pop()
            modified = True
    else:
        for i, item in enumerate(val):
            if not isinstance(item, str):
                errors.append(f"'worker_hints[{i}]' must be a string, got {type(item).__name__}")
                if fix_mode:
                    config["worker_hints"][i] = str(item)
                    fixes.append(f"coerced 'worker_hints[{i}]' to string")
                    errors.pop()
                    modified = True

# Validate dispatch_isolation
if "dispatch_isolation" in config:
    val = config["dispatch_isolation"]
    if not isinstance(val, str):
        errors.append("'dispatch_isolation' must be a string")
    elif val not in ("branch", "worktree"):
        errors.append(f"'dispatch_isolation' must be 'branch' or 'worktree', got '{val}'")
        if fix_mode and val.lower() in ("branch", "worktree"):
            config["dispatch_isolation"] = val.lower()
            fixes.append(f"lowercased 'dispatch_isolation' to '{val.lower()}'")
            errors.pop()
            modified = True

# Validate worker_timeout
if "worker_timeout" in config:
    val = config["worker_timeout"]
    if isinstance(val, bool):
        errors.append("'worker_timeout' must be a positive integer")
    elif isinstance(val, int) and not isinstance(val, bool):
        if val <= 0:
            errors.append(f"'worker_timeout' must be positive, got {val}")
    elif isinstance(val, float):
        errors.append("'worker_timeout' must be an integer, got float")
        if fix_mode and val > 0:
            config["worker_timeout"] = int(val)
            fixes.append(f"coerced 'worker_timeout' from float to int")
            errors.pop()
            modified = True
    elif isinstance(val, str):
        errors.append(f"'worker_timeout' must be an integer, got string")
        if fix_mode:
            try:
                int_val = int(val)
                if int_val > 0:
                    config["worker_timeout"] = int_val
                    fixes.append(f"coerced 'worker_timeout' from string to int")
                    errors.pop()
                    modified = True
            except ValueError:
                pass
    else:
        errors.append(f"'worker_timeout' must be a positive integer")

# Write fixes if any
if fix_mode and modified:
    tmp = config_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.replace(tmp, config_file)

valid = len(errors) == 0

if json_mode:
    result = {
        "valid": valid,
        "errors": errors,
        "warnings": warnings,
        "fixes": fixes
    }
    print(json.dumps(result, indent=2))
else:
    if valid:
        print(f"VALID: {config_file}")
    else:
        print(f"INVALID: {config_file}")
    for e in errors:
        print(f"  Error: {e}")
    for w in warnings:
        print(f"  Warning: {w}")
    for fix in fixes:
        print(f"  Fixed: {fix}")

sys.exit(0 if valid else 1)
PYEOF
}

# ── Init command ─────────────────────────────────────────────────────────

cmd_init() {
  [ -z "$PROJECT_DIR" ] && die "init requires project-dir"
  [ -d "$PROJECT_DIR" ] || die "project dir not found: $PROJECT_DIR"

  local config_file="$PROJECT_DIR/.autonomous/skill-config.json"
  if [ -f "$config_file" ]; then
    if [ "$JSON_MODE" = true ]; then
      echo '{"created":false,"reason":"config already exists"}'
    else
      echo "Config already exists: $config_file"
      echo "Use 'validate' to check it, or delete and re-run 'init'."
    fi
    return 0
  fi

  local detect="$SCRIPT_DIR/detect-framework.sh"
  [ -f "$detect" ] || die "detect-framework.sh not found: $detect"

  mkdir -p "$PROJECT_DIR/.autonomous"

  local detection_json
  detection_json=$(bash "$detect" "$PROJECT_DIR" 2>/dev/null) || detection_json='{"framework":"unknown"}'

  python3 - "$config_file" "$detection_json" "$JSON_MODE" << 'PYEOF'
import json, sys, os

config_file = sys.argv[1]
detection_json = sys.argv[2]
json_mode = sys.argv[3] == "true"

detection = json.loads(detection_json)

config = {}
config["framework"] = detection.get("framework", "unknown")

if detection.get("test_command"):
    config["test_command"] = detection["test_command"]
if detection.get("lint_command"):
    config["lint_command"] = detection["lint_command"]
if detection.get("build_command"):
    config["build_command"] = detection["build_command"]

config["worker_hints"] = []
config["dispatch_isolation"] = "branch"
config["worker_timeout"] = 600

tmp = config_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
os.replace(tmp, config_file)

if json_mode:
    print(json.dumps({"created": True, "config": config}, indent=2))
else:
    print(f"Created: {config_file}")
    print(f"  Framework: {config['framework']}")
    for k, v in config.items():
        if k != "framework":
            print(f"  {k}: {v}")
PYEOF
}

# ── Migrate command ──────────────────────────────────────────────────────

cmd_migrate() {
  [ -z "$PROJECT_DIR" ] && die "migrate requires project-dir"
  [ -d "$PROJECT_DIR" ] || die "project dir not found: $PROJECT_DIR"

  local config_file="$PROJECT_DIR/.autonomous/skill-config.json"
  if [ ! -f "$config_file" ]; then
    if [ "$JSON_MODE" = true ]; then
      echo '{"migrated":false,"reason":"no config file found"}'
    else
      echo "No config file found: $config_file"
      echo "Use 'init' to create one."
    fi
    return 0
  fi

  python3 - "$config_file" "$JSON_MODE" "$FIX_MODE" << 'PYEOF'
import json, sys, os

config_file = sys.argv[1]
json_mode = sys.argv[2] == "true"
fix_mode = sys.argv[3] == "true"

migrations = []

try:
    with open(config_file) as f:
        config = json.load(f)
except json.JSONDecodeError as e:
    if json_mode:
        print(json.dumps({"migrated": False, "errors": [f"invalid JSON: {e}"]}))
    else:
        print(f"Cannot migrate: invalid JSON in {config_file}")
    sys.exit(1)

if not isinstance(config, dict):
    if json_mode:
        print(json.dumps({"migrated": False, "errors": ["config must be a JSON object"]}))
    else:
        print("Cannot migrate: config is not a JSON object")
    sys.exit(1)

modified = False

# Migration 1: old field names
OLD_FIELDS = {
    "testCommand": "test_command",
    "lintCommand": "lint_command",
    "buildCommand": "build_command",
    "workerHints": "worker_hints",
    "dispatchIsolation": "dispatch_isolation",
    "workerTimeout": "worker_timeout",
    "test-command": "test_command",
    "lint-command": "lint_command",
    "build-command": "build_command",
    "worker-hints": "worker_hints",
    "dispatch-isolation": "dispatch_isolation",
    "worker-timeout": "worker_timeout",
}

for old, new in OLD_FIELDS.items():
    if old in config and new not in config:
        migrations.append(f"rename '{old}' -> '{new}'")
        if fix_mode:
            config[new] = config.pop(old)
            modified = True
    elif old in config and new in config:
        migrations.append(f"remove duplicate old field '{old}' ('{new}' already exists)")
        if fix_mode:
            del config[old]
            modified = True

# Migration 2: timeout as string
if "worker_timeout" in config and isinstance(config["worker_timeout"], str):
    try:
        int_val = int(config["worker_timeout"])
        migrations.append(f"convert 'worker_timeout' from string to int")
        if fix_mode:
            config["worker_timeout"] = int_val
            modified = True
    except ValueError:
        migrations.append(f"'worker_timeout' is an invalid string: '{config['worker_timeout']}'")

# Migration 3: dispatch_isolation case normalization
if "dispatch_isolation" in config and isinstance(config["dispatch_isolation"], str):
    val = config["dispatch_isolation"]
    if val not in ("branch", "worktree") and val.lower() in ("branch", "worktree"):
        migrations.append(f"lowercase 'dispatch_isolation': '{val}' -> '{val.lower()}'")
        if fix_mode:
            config["dispatch_isolation"] = val.lower()
            modified = True

# Migration 4: worker_hints as string instead of array
if "worker_hints" in config and isinstance(config["worker_hints"], str):
    migrations.append("wrap 'worker_hints' string in array")
    if fix_mode:
        config["worker_hints"] = [config["worker_hints"]]
        modified = True

if fix_mode and modified:
    tmp = config_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    os.replace(tmp, config_file)

if json_mode:
    print(json.dumps({
        "migrated": modified,
        "migrations": migrations,
        "fix_applied": fix_mode and modified
    }, indent=2))
else:
    if not migrations:
        print("No migrations needed.")
    else:
        print(f"Found {len(migrations)} migration(s):")
        for m in migrations:
            prefix = "Applied" if (fix_mode and modified) else "Needed"
            print(f"  {prefix}: {m}")
    if not fix_mode and migrations:
        print("\nRun with --fix to apply migrations.")
PYEOF
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "$CMD" in
  validate)  cmd_validate ;;
  init)      cmd_init ;;
  migrate)   cmd_migrate ;;
  *)         die "unknown command: $CMD. Use: validate|init|migrate" ;;
esac
