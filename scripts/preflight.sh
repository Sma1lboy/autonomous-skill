#!/usr/bin/env bash
# preflight.sh — Dependency checker for the autonomous-skill system.
# Verifies required tools are present before the conductor starts.
# Exit 0 if all good (or only optional deps missing).
# Exit 1 only if `claude` CLI is missing (the one critical dependency).

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat << 'EOF'
Usage: preflight.sh [options]

Check runtime dependencies for the autonomous-skill system.

Options:
  --setup     Attempt to auto-install missing optional dependencies
  -h, --help  Show this help message

Dependencies checked:
  claude      (critical — exit 1 if missing)
  tmux        (optional — needed for worker dispatch)
  python3     (optional — needed for comms protocol)
  jq          (optional — needed for JSON processing)
  shellcheck  (optional — needed for shell script linting)

Examples:
  bash scripts/preflight.sh
  bash scripts/preflight.sh --setup
EOF
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────

SETUP=false
case "${1:-}" in
  -h|--help|help) usage ;;
  --setup) SETUP=true ;;
esac

# ── Platform detection ────────────────────────────────────────────────────

detect_platform() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*)  echo "linux" ;;
    *)       echo "unknown" ;;
  esac
}

PLATFORM=$(detect_platform)

# ── Install instructions ─────────────────────────────────────────────────

install_hint() {
  local dep="$1"
  case "$dep" in
    claude)
      echo "  Install: https://docs.anthropic.com/en/docs/claude-code"
      ;;
    *)
      case "$PLATFORM" in
        macos) echo "  Install: brew install $dep" ;;
        linux) echo "  Install: sudo apt install $dep" ;;
        *)     echo "  Install: see your package manager for '$dep'" ;;
      esac
      ;;
  esac
}

# ── Dependency check ─────────────────────────────────────────────────────

MISSING_OPTIONAL=()
CLAUDE_MISSING=false

check_dep() {
  local dep="$1"
  local critical="${2:-false}"

  if command -v "$dep" &>/dev/null; then
    echo "  ✓ $dep"
    return 0
  else
    if [ "$critical" = "true" ]; then
      echo "  ✗ $dep (REQUIRED)"
      CLAUDE_MISSING=true
    else
      echo "  ✗ $dep (optional)"
      MISSING_OPTIONAL+=("$dep")
    fi
    install_hint "$dep"
    return 1
  fi
}

echo "═══════════════════════════════════════════════════"
echo "  Preflight Check"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Dependencies:"

check_dep claude true || true
check_dep tmux false || true
check_dep python3 false || true
check_dep jq false || true
check_dep shellcheck false || true

# ── Claude version detection ─────────────────────────────────────────────

if ! $CLAUDE_MISSING && command -v claude &>/dev/null; then
  echo ""
  CC_VERSION=$(claude --version 2>/dev/null || echo "unknown")
  echo "Claude CLI version: $CC_VERSION"
fi

# ── tmux server status ───────────────────────────────────────────────────

if command -v tmux &>/dev/null; then
  if tmux list-sessions &>/dev/null; then
    echo "tmux server: running"
  else
    echo "tmux server: not running (will be started on first dispatch)"
  fi
fi

# ── Auto-install (--setup) ───────────────────────────────────────────────

if $SETUP && [ ${#MISSING_OPTIONAL[@]} -gt 0 ]; then
  echo ""
  echo "Attempting to install missing optional dependencies..."
  for dep in "${MISSING_OPTIONAL[@]}"; do
    case "$PLATFORM" in
      macos)
        echo "  brew install $dep"
        brew install "$dep" 2>/dev/null || echo "  Failed to install $dep via brew"
        ;;
      linux)
        echo "  sudo apt install -y $dep"
        sudo apt install -y "$dep" 2>/dev/null || echo "  Failed to install $dep via apt"
        ;;
      *)
        echo "  Skipping $dep — unknown platform"
        ;;
    esac
  done
elif $SETUP && [ ${#MISSING_OPTIONAL[@]} -eq 0 ]; then
  echo ""
  echo "All optional dependencies already installed."
fi

if $SETUP && $CLAUDE_MISSING; then
  echo ""
  echo "Note: claude CLI must be installed manually."
  install_hint claude
fi

# ── Result ────────────────────────────────────────────────────────────────

echo ""
if $CLAUDE_MISSING; then
  echo "FAIL: claude CLI is required but not found."
  exit 1
fi

if [ ${#MISSING_OPTIONAL[@]} -gt 0 ]; then
  echo "OK (${#MISSING_OPTIONAL[@]} optional dep(s) missing — see above)"
else
  echo "OK — all dependencies present."
fi
exit 0
