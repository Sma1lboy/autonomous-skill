#!/usr/bin/env bash
# explore-scan.sh — Scan a project and score all 8 exploration dimensions.
# Called by the Conductor (SKILL.md) before explore-pick to replace blind
# priority-order selection with data-driven scoring.
# Layer: conductor

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: explore-scan.sh <project-dir> [conductor-state-script]

Scan a project and score all 8 exploration dimensions (0-10, higher = better).
Scores are written to conductor-state.json via conductor-state.sh explore-score.

Dimensions scored:
  test_coverage    Ratio of test files to source files
  error_handling   Files with error-handling patterns (try/catch/rescue)
  security         Hardcoded secrets, TODO-security markers, .env files
  code_quality     TODO/FIXME/HACK/XXX markers
  documentation    README existence, freshness, docs/ directory
  architecture     Files over 300 lines (fewer = better)
  performance      Sleep/N+1 antipatterns
  dx               CLI scripts with --help/usage patterns

Arguments:
  project-dir            Path to the project to scan (default: current directory)
  conductor-state-script Path to conductor-state.sh (default: auto-detected)

Requires: an initialized conductor state (.autonomous/conductor-state.json)
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

PROJECT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDUCTOR="${2:-$SCRIPT_DIR/conductor-state.sh}"

[ -d "$PROJECT" ] || { echo "ERROR: project dir not found: $PROJECT" >&2; exit 1; }
[ -f "$CONDUCTOR" ] || { echo "ERROR: conductor-state.sh not found: $CONDUCTOR" >&2; exit 1; }

# ── Common exclusion patterns for find/grep ───────────────────────────────
# Directories to exclude from all scanning (noise dirs that inflate counts).
EXCLUDE_PATHS=(
  -not -path '*/node_modules/*'
  -not -path '*/.git/*'
  -not -path '*/.autonomous/*'
  -not -path '*/vendor/*'
  -not -path '*/dist/*'
  -not -path '*/build/*'
)

# Grep --exclude-dir flags — prevents grep from descending into noise
# directories at all, rather than scanning them then filtering with sed.
# On large repos (e.g. node_modules with 100k+ files) this is 10-100x faster.
GREP_EXCLUDE_DIRS=(
  --exclude-dir=node_modules
  --exclude-dir=.git
  --exclude-dir=.autonomous
  --exclude-dir=vendor
  --exclude-dir=dist
  --exclude-dir=build
)

# ── Helpers ────────────────────────────────────────────────────────────────

# Clamp a value to 0-10 integer. Returns 0 on empty/non-numeric input.
# Uses AST-based safe eval — only allows numeric constants and arithmetic operators.
clamp() {
  local expr="${1:-0}"
  python3 -c "
import sys, ast, operator
def safe_eval(expr):
    ops = {ast.Add: operator.add, ast.Sub: operator.sub,
           ast.Mult: operator.mul, ast.Div: operator.truediv,
           ast.FloorDiv: operator.floordiv, ast.USub: operator.neg}
    def _eval(node):
        if isinstance(node, ast.Expression): return _eval(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.BinOp) and type(node.op) in ops:
            return ops[type(node.op)](_eval(node.left), _eval(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in ops:
            return ops[type(node.op)](_eval(node.operand))
        raise ValueError('unsafe expression')
    return _eval(ast.parse(expr, mode='eval'))
try:
    print(max(0, min(10, int(safe_eval(sys.argv[1])))))
except Exception:
    print(0)
" "$expr"
}

# Count files matching a find pattern (uses shared EXCLUDE_PATHS)
count_files() {
  find "$PROJECT" -type f "$@" "${EXCLUDE_PATHS[@]}" \
    2>/dev/null | wc -l | tr -d ' '
}

# Count files containing a grep pattern (uses shared GREP_EXCLUDE_DIRS).
# The || true prevents exit-code-1-on-no-match from failing under pipefail.
count_grep() {
  local pattern="$1"; shift
  { grep -rl "$pattern" "$PROJECT" "${GREP_EXCLUDE_DIRS[@]}" "$@" 2>/dev/null || true; } \
    | wc -l | tr -d ' '
}

# Score a dimension
score() {
  local dim="$1" val="$2"
  bash "$CONDUCTOR" explore-score "$PROJECT" "$dim" "$val" >/dev/null
  echo "  $dim: $val"
}

# ── Source file extensions (used by multiple heuristics) ───────────────────

SRC_EXTS=(-name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.tsx' \
          -o -name '*.rb' -o -name '*.go' -o -name '*.rs' -o -name '*.sh' \
          -o -name '*.java')

# ── Scoring ────────────────────────────────────────────────────────────────

echo "Scanning project: $PROJECT"

# 1. test_coverage: ratio of test files to non-test source files
_tests=$(count_files \( -name '*test*' -o -name '*spec*' -o -name '*_test.*' \))
_srcs=$(find "$PROJECT" -type f \( "${SRC_EXTS[@]}" \) \
  "${EXCLUDE_PATHS[@]}" -not -name '*test*' -not -name '*spec*' \
  2>/dev/null | wc -l | tr -d ' ')
_s=${_srcs:-0}
[ "$_s" -eq 0 ] && _s=1
score "test_coverage" "$(clamp "$_tests * 10 / $_s")"

# 2. error_handling: files with error-handling patterns per source file
_errs=$(count_grep 'try\|catch\|rescue\|except\|raise\|throw' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' \
  --include='*.go' --include='*.rs' --include='*.sh')
score "error_handling" "$(clamp "$_errs * 10 / $_s")"

# 3. security: fewer issues = higher score (inverted)
_sec_issues=$(count_grep 'TODO.*secur\|FIXME.*secur' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' --include='*.sh')
_secrets=$(count_grep 'password\s*=\s*["'"'"']\|api_key\s*=\s*["'"'"']\|secret\s*=\s*["'"'"']' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' --include='*.sh')
_envf=$(find "$PROJECT" -maxdepth 3 -name '.env' "${EXCLUDE_PATHS[@]}" 2>/dev/null | wc -l | tr -d ' ')
score "security" "$(clamp "10 - ($_sec_issues + $_secrets + $_envf) * 2")"

# 4. code_quality: fewer TODO/FIXME/HACK = higher score (inverted)
_todos=$(count_grep 'TODO\|FIXME\|HACK\|XXX' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb' \
  --include='*.sh' --include='*.go' --include='*.rs')
score "code_quality" "$(clamp "10 - $_todos")"

# 5. documentation: README existence + freshness + docs/ directory
_ds=0
[ -f "$PROJECT/README.md" ] && _ds=$((_ds + 4))
[ -d "$PROJECT/docs" ] && _ds=$((_ds + 3))
if [ -f "$PROJECT/README.md" ] && command -v git &>/dev/null; then
  _rf=$(python3 -c "
import subprocess, datetime, sys
r = subprocess.run(['git','log','-1','--format=%ct','--','README.md'],
                   capture_output=True, text=True, cwd=sys.argv[1])
ts = int(r.stdout.strip()) if r.stdout.strip() else 0
days = (datetime.datetime.now().timestamp() - ts) / 86400 if ts else 999
print(min(3, round(3 * max(0, 1 - days / 180))))
" "$PROJECT" 2>/dev/null || echo "0")
  _ds=$((_ds + _rf))
fi
score "documentation" "$(clamp "$_ds")"

# 6. architecture: fewer files > 300 lines = better
# Uses -exec wc -l {} + to batch all files into one wc invocation,
# instead of forking one awk per file (avoids thousands of forks on large repos).
_big=$(find "$PROJECT" -type f \( "${SRC_EXTS[@]}" \) \
  "${EXCLUDE_PATHS[@]}" \
  -exec wc -l {} + 2>/dev/null \
  | awk '$1 > 300 && !/total$/' \
  | wc -l | tr -d ' ')
score "architecture" "$(clamp "10 - $_big * 2")"

# 7. performance: fewer sleep/N+1 antipatterns = better
_perf=$(count_grep 'sleep\|\.each.*\.save\|\.each.*\.update\|N+1\|n+1' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb')
score "performance" "$(clamp "10 - $_perf * 2")"

# 8. dx: CLI scripts with --help/usage patterns
_help=$(count_grep '\-\-help\|usage()\|Usage:\|usage:' \
  --include='*.sh' --include='*.py' --include='*.js')
_cli=$(find "$PROJECT" -type f -name '*.sh' "${EXCLUDE_PATHS[@]}" \
  2>/dev/null | wc -l | tr -d ' ')
_c=${_cli:-0}
[ "$_c" -eq 0 ] && _c=1
score "dx" "$(clamp "$_help * 10 / $_c")"

echo "Exploration scan complete."
