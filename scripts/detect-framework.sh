#!/usr/bin/env bash
# detect-framework.sh — Auto-detect project framework/stack from marker files.
# Outputs JSON with framework, test/lint/build commands, and detected tools.
# Used by build-worker-hints.sh to generate worker hints.
# Layer: shared

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: detect-framework.sh <project-dir>

Auto-detect the project's framework and tooling from root-level marker files.
Outputs JSON to stdout with detected framework, commands, and tools.

Detection order (first match wins for compiled/interpreted):
  package.json       → node/react/nextjs/vue/angular (inspects dependencies)
  Cargo.toml         → rust
  go.mod             → go
  requirements.txt   → python
  pyproject.toml     → python
  Gemfile            → ruby
  pom.xml            → java-maven
  build.gradle(.kts) → java-gradle
  *.sh + tests/      → bash (fallback)

Output format (JSON):
  {"framework":"nextjs","test_command":"npm test","lint_command":"npx next lint",
   "build_command":"npm run build","detected_tools":["typescript","eslint"]}

If no framework detected: {"framework":"unknown"}

Arguments:
  project-dir   Path to the project root to scan

Requires: python3
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

# ── Detection logic (delegated to python3 for JSON handling) ──────────────
python3 - "$PROJECT" << 'PYEOF'
import json, os, sys

project = sys.argv[1]

def file_exists(name):
    return os.path.isfile(os.path.join(project, name))

def glob_exists(pattern):
    """Check if any file matching a simple *.ext pattern exists in project root."""
    import glob
    return len(glob.glob(os.path.join(project, pattern))) > 0

def read_json(name):
    try:
        with open(os.path.join(project, name)) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None

def detect_package_json():
    """Detect Node.js ecosystem framework from package.json."""
    pkg = read_json("package.json")
    if pkg is None:
        return None

    deps = {}
    deps.update(pkg.get("dependencies", {}))
    deps.update(pkg.get("devDependencies", {}))

    # Detect tools from devDependencies
    tool_names = ["typescript", "eslint", "prettier", "jest", "mocha",
                  "vitest", "webpack", "vite", "rollup", "esbuild",
                  "tailwindcss", "sass", "less", "storybook"]
    detected_tools = [t for t in tool_names if t in deps]

    # Detect scripts
    scripts = pkg.get("scripts", {})
    has_test = "test" in scripts
    has_lint = "lint" in scripts
    has_build = "build" in scripts

    # Framework detection (order matters — most specific first)
    if "next" in deps:
        return {
            "framework": "nextjs",
            "test_command": "npm test" if has_test else "npx jest",
            "lint_command": "npm run lint" if has_lint else "npx next lint",
            "build_command": "npm run build" if has_build else "npx next build",
            "detected_tools": detected_tools,
        }
    elif "vue" in deps:
        return {
            "framework": "vue",
            "test_command": "npm test" if has_test else "npx vitest",
            "lint_command": "npm run lint" if has_lint else "npx eslint .",
            "build_command": "npm run build" if has_build else "npx vite build",
            "detected_tools": detected_tools,
        }
    elif "@angular/core" in deps:
        return {
            "framework": "angular",
            "test_command": "npm test" if has_test else "npx ng test",
            "lint_command": "npm run lint" if has_lint else "npx ng lint",
            "build_command": "npm run build" if has_build else "npx ng build",
            "detected_tools": detected_tools,
        }
    elif "react" in deps or "react-dom" in deps:
        return {
            "framework": "react",
            "test_command": "npm test" if has_test else "npx jest",
            "lint_command": "npm run lint" if has_lint else "npx eslint .",
            "build_command": "npm run build" if has_build else None,
            "detected_tools": detected_tools,
        }
    else:
        return {
            "framework": "node",
            "test_command": "npm test" if has_test else None,
            "lint_command": "npm run lint" if has_lint else "npx eslint .",
            "build_command": "npm run build" if has_build else None,
            "detected_tools": detected_tools,
        }

def detect_cargo():
    if not file_exists("Cargo.toml"):
        return None
    return {
        "framework": "rust",
        "test_command": "cargo test",
        "lint_command": "cargo clippy",
        "build_command": "cargo build",
        "detected_tools": [],
    }

def detect_go():
    if not file_exists("go.mod"):
        return None
    return {
        "framework": "go",
        "test_command": "go test ./...",
        "lint_command": "golangci-lint run",
        "build_command": "go build ./...",
        "detected_tools": [],
    }

def detect_python():
    if not file_exists("requirements.txt") and not file_exists("pyproject.toml"):
        return None
    return {
        "framework": "python",
        "test_command": "pytest",
        "lint_command": "ruff check .",
        "build_command": None,
        "detected_tools": [],
    }

def detect_ruby():
    if not file_exists("Gemfile"):
        return None
    return {
        "framework": "ruby",
        "test_command": "bundle exec rspec",
        "lint_command": "rubocop",
        "build_command": None,
        "detected_tools": [],
    }

def detect_java_maven():
    if not file_exists("pom.xml"):
        return None
    return {
        "framework": "java-maven",
        "test_command": "mvn test",
        "lint_command": None,
        "build_command": "mvn package",
        "detected_tools": [],
    }

def detect_java_gradle():
    if not file_exists("build.gradle") and not file_exists("build.gradle.kts"):
        return None
    return {
        "framework": "java-gradle",
        "test_command": "gradle test",
        "lint_command": None,
        "build_command": "gradle build",
        "detected_tools": [],
    }

def detect_bash():
    """Fallback: detect bash projects (*.sh files + tests/ dir)."""
    has_sh = glob_exists("*.sh") or glob_exists("scripts/*.sh")
    has_tests = os.path.isdir(os.path.join(project, "tests"))
    if not has_sh:
        return None
    return {
        "framework": "bash",
        "test_command": "bash tests/test_*.sh" if has_tests else None,
        "lint_command": "shellcheck scripts/*.sh" if glob_exists("scripts/*.sh") else "shellcheck *.sh",
        "build_command": None,
        "detected_tools": [],
    }

# Run detectors in priority order
detectors = [
    detect_package_json,
    detect_cargo,
    detect_go,
    detect_python,
    detect_ruby,
    detect_java_maven,
    detect_java_gradle,
    detect_bash,
]

result = None
for detect in detectors:
    result = detect()
    if result is not None:
        break

if result is None:
    result = {"framework": "unknown"}

# Clean up null values — omit fields with None
output = {k: v for k, v in result.items() if v is not None}

print(json.dumps(output, separators=(",", ":")))
PYEOF
