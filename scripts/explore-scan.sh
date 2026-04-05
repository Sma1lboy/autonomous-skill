#!/usr/bin/env bash
# explore-scan.sh — Scan a project and score all 8 exploration dimensions.
# Called by the Conductor (SKILL.md) before explore-pick to replace blind
# priority-order selection with data-driven scoring.
#
# Usage:
#   explore-scan.sh <project-dir> [conductor-state-script]
#
# Scores each dimension 0-10 (higher = better) and feeds into
# conductor-state.sh explore-score. Requires an initialized conductor state.

set -euo pipefail

PROJECT="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONDUCTOR="${2:-$SCRIPT_DIR/conductor-state.sh}"

[ -d "$PROJECT" ] || { echo "ERROR: project dir not found: $PROJECT" >&2; exit 1; }
[ -f "$CONDUCTOR" ] || { echo "ERROR: conductor-state.sh not found: $CONDUCTOR" >&2; exit 1; }

# ── Helpers ────────────────────────────────────────────────────────────────

# Clamp a value to 0-10 integer
clamp() {
  python3 -c "print(max(0, min(10, int($1))))"
}

# Count files matching a find pattern (excludes node_modules, .git, vendor, dist)
count_files() {
  find "$PROJECT" -type f "$@" \
    -not -path '*/node_modules/*' \
    -not -path '*/.git/*' \
    -not -path '*/.autonomous/*' \
    -not -path '*/vendor/*' \
    -not -path '*/dist/*' \
    -not -path '*/build/*' \
    2>/dev/null | wc -l | tr -d ' '
}

# Count files containing a grep pattern (excludes noise dirs).
# Uses sed instead of grep -v to avoid exit-code-1-on-empty under pipefail.
count_grep() {
  local pattern="$1"; shift
  { grep -rl "$pattern" "$PROJECT" "$@" 2>/dev/null || true; } \
    | sed '/node_modules/d; /\.git\//d; /\.autonomous\//d; /\/vendor\//d; /\/dist\//d' \
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
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.autonomous/*' \
  -not -path '*/vendor/*' -not -path '*/dist/*' -not -path '*/build/*' \
  -not -name '*test*' -not -name '*spec*' \
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
_envf=$(find "$PROJECT" -maxdepth 3 -name '.env' -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')
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
import subprocess, datetime
r = subprocess.run(['git','log','-1','--format=%ct','--','README.md'],
                   capture_output=True, text=True, cwd='$PROJECT')
ts = int(r.stdout.strip()) if r.stdout.strip() else 0
days = (datetime.datetime.now().timestamp() - ts) / 86400 if ts else 999
print(min(3, round(3 * max(0, 1 - days / 180))))
" 2>/dev/null || echo "0")
  _ds=$((_ds + _rf))
fi
score "documentation" "$(clamp "$_ds")"

# 6. architecture: fewer files > 300 lines = better
_big=$(find "$PROJECT" -type f \( "${SRC_EXTS[@]}" \) \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.autonomous/*' \
  -not -path '*/vendor/*' -not -path '*/dist/*' \
  2>/dev/null -exec awk 'END{if(NR>300)print FILENAME}' {} + 2>/dev/null \
  | wc -l | tr -d ' ')
score "architecture" "$(clamp "10 - $_big * 2")"

# 7. performance: fewer sleep/N+1 antipatterns = better
_perf=$(count_grep 'sleep\|\.each.*\.save\|\.each.*\.update\|N+1\|n+1' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.rb')
score "performance" "$(clamp "10 - $_perf * 2")"

# 8. dx: CLI scripts with --help/usage patterns
_help=$(count_grep '\-\-help\|usage()\|Usage:\|usage:' \
  --include='*.sh' --include='*.py' --include='*.js')
_cli=$(find "$PROJECT" -type f -name '*.sh' \
  -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.autonomous/*' \
  2>/dev/null | wc -l | tr -d ' ')
_c=${_cli:-0}
[ "$_c" -eq 0 ] && _c=1
score "dx" "$(clamp "$_help * 10 / $_c")"

echo "Exploration scan complete."
