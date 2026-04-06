#!/usr/bin/env bash
# build-worker-hints.sh — Build a worker hints block from framework detection
# and optional .autonomous/skill-config.json overrides.
# Output: multi-line text block suitable for injection into worker prompts.
# If framework is "unknown" and no config exists, outputs nothing (empty stdout).
# Layer: shared

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: build-worker-hints.sh <project-dir>

Detect the project framework (via detect-framework.sh), merge with optional
.autonomous/skill-config.json overrides, and output a worker hints block.

Config file (.autonomous/skill-config.json) schema:
  {"framework":"nextjs","test_command":"npm test","lint_command":"npm run lint",
   "build_command":"npm run build","worker_hints":["always run type-check"]}

Config fields override auto-detection. worker_hints are appended as bullet points.

Output format (multi-line text):
  ## Project Stack
  Framework: nextjs
  Test: npm test
  Lint: npm run lint
  Build: npm run build
  Hints:
  - always run type-check before committing

If framework is "unknown" and no config exists: no output, exit 0.

Arguments:
  project-dir   Path to the project root

Requires: python3, detect-framework.sh (same directory)
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

PROJECT="${1:?ERROR: project-dir required. Run with --help for usage.}"

[ -d "$PROJECT" ] || { echo "ERROR: project dir not found: $PROJECT" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/detect-framework.sh"

[ -f "$DETECT" ] || { echo "ERROR: detect-framework.sh not found: $DETECT" >&2; exit 1; }

# ── Run detection ─────────────────────────────────────────────────────────
DETECTION_JSON=$(bash "$DETECT" "$PROJECT")

# ── Merge detection + config, produce output ──────────────────────────────
CONFIG_FILE="$PROJECT/.autonomous/skill-config.json"

python3 - "$DETECTION_JSON" "$CONFIG_FILE" << 'PYEOF'
import json, os, sys

detection = json.loads(sys.argv[1])
config_path = sys.argv[2]

# Load config if it exists
config = {}
if os.path.isfile(config_path):
    try:
        with open(config_path) as f:
            config = json.load(f)
    except (json.JSONDecodeError, IOError):
        pass

# Merge: config overrides detection for known fields
framework = config.get("framework", detection.get("framework", "unknown"))
test_cmd = config.get("test_command", detection.get("test_command"))
lint_cmd = config.get("lint_command", detection.get("lint_command"))
build_cmd = config.get("build_command", detection.get("build_command"))
hints = config.get("worker_hints", [])

# If framework is unknown and no config provided anything useful, output nothing
if framework == "unknown" and not test_cmd and not lint_cmd and not build_cmd and not hints:
    sys.exit(0)

# Build output block
lines = ["## Project Stack"]
lines.append(f"Framework: {framework}")
if test_cmd:
    lines.append(f"Test: {test_cmd}")
if lint_cmd:
    lines.append(f"Lint: {lint_cmd}")
if build_cmd:
    lines.append(f"Build: {build_cmd}")
if hints:
    lines.append("Hints:")
    for h in hints:
        lines.append(f"- {h}")

print("\n".join(lines))
PYEOF
