#!/usr/bin/env bash
# session-diff.sh — Session diff summary: compare an auto/ branch against its base.
# Produces consolidated diff stats, commit categorization, and PR-style descriptions.
# Layer: shared

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: session-diff.sh <project-dir> [--base BRANCH] [--json] [--markdown]

Compare the current auto/ session branch against a base branch and produce
a consolidated diff summary with stats and commit categorization.

Arguments:
  project-dir    Project directory (must be a git repo on an auto/ branch)

Options:
  --base BRANCH  Base branch to diff against (default: auto-detect main/master)
  --json         Output machine-readable JSON
  --markdown     Output GitHub PR body markdown
  -h, --help     Show this help message

Output includes:
  - Total files changed, lines added/removed
  - New test files/functions added
  - Commit categorization (feat/fix/refactor/test/docs/chore/perf/trace/other)
  - PR-style description

Examples:
  bash scripts/session-diff.sh ./my-project
  bash scripts/session-diff.sh ./my-project --base main --json
  bash scripts/session-diff.sh ./my-project --markdown
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v git &>/dev/null || die "git required but not found"
command -v python3 &>/dev/null || die "python3 required but not found"

# ── Parse arguments ──────────────────────────────────────────────────────

PROJECT_DIR=""
BASE_BRANCH=""
JSON_MODE=false
MARKDOWN_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --base)
      [ -z "${2:-}" ] && die "--base requires a branch name"
      BASE_BRANCH="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --markdown)
      MARKDOWN_MODE=true
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

[ -z "$PROJECT_DIR" ] && die "project-dir is required"
[ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"
[ -d "$PROJECT_DIR/.git" ] || die "not a git repository: $PROJECT_DIR"

# ── Detect base branch ──────────────────────────────────────────────────

if [ -z "$BASE_BRANCH" ]; then
  if git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    BASE_BRANCH="main"
  elif git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    BASE_BRANCH="master"
  else
    die "no main or master branch found; use --base to specify"
  fi
fi

# Verify base branch exists
git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$BASE_BRANCH" 2>/dev/null \
  || die "base branch not found: $BASE_BRANCH"

# Get current branch
CURRENT_BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) \
  || die "could not determine current branch"

# Find merge base
MERGE_BASE=$(git -C "$PROJECT_DIR" merge-base "$BASE_BRANCH" HEAD 2>/dev/null) \
  || die "could not find merge base between $BASE_BRANCH and HEAD"

# ── Gather diff data via python3 ────────────────────────────────────────

python3 -c "
import subprocess, json, sys, re, os

project_dir = sys.argv[1]
base_branch = sys.argv[2]
current_branch = sys.argv[3]
merge_base = sys.argv[4]
json_mode = sys.argv[5] == 'true'
markdown_mode = sys.argv[6] == 'true'

def run_git(*args):
    r = subprocess.run(
        ['git'] + list(args),
        capture_output=True, text=True, cwd=project_dir
    )
    return r.stdout.strip()

# ── Diff stats ──────────────────────────────────────────────────────────

diffstat = run_git('diff', '--stat', merge_base + '..HEAD')
numstat = run_git('diff', '--numstat', merge_base + '..HEAD')

files_changed = 0
lines_added = 0
lines_removed = 0
changed_files = []

for line in numstat.split('\n'):
    line = line.strip()
    if not line:
        continue
    parts = line.split('\t')
    if len(parts) < 3:
        continue
    added, removed, fname = parts[0], parts[1], parts[2]
    # Binary files show '-' for added/removed
    a = int(added) if added != '-' else 0
    r = int(removed) if removed != '-' else 0
    lines_added += a
    lines_removed += r
    files_changed += 1
    changed_files.append(fname)

# ── New tests detection ─────────────────────────────────────────────────

diff_content = run_git('diff', merge_base + '..HEAD')

new_test_files = []
new_test_functions = 0

for f in changed_files:
    # Check if it's a new file that looks like a test
    is_test = False
    if re.search(r'test[_\-]|_test\.|\.test\.|spec[_\-]|_spec\.|\.spec\.', f, re.IGNORECASE):
        is_test = True
    if is_test:
        # Check if the file is newly added (not just modified)
        status = run_git('diff', '--name-status', merge_base + '..HEAD', '--', f)
        if status.startswith('A'):
            new_test_files.append(f)

# Count new test functions/assertions in the diff
# Look for added lines that define test functions
for line in diff_content.split('\n'):
    if not line.startswith('+'):
        continue
    if line.startswith('+++'):
        continue
    # Common test function patterns
    if re.search(r'^\+\s*(def test_|it\(|describe\(|test\(|#\s*test|assert_|fn test_)', line):
        new_test_functions += 1

# ── Commit categorization ──────────────────────────────────────────────

log_output = run_git('log', '--oneline', merge_base + '..HEAD')

categories = {
    'feat': [], 'fix': [], 'refactor': [], 'test': [],
    'docs': [], 'chore': [], 'perf': [], 'trace': [], 'other': []
}
prefix_pattern = re.compile(r'^[0-9a-f]+\s+(feat|fix|refactor|test|docs|chore|perf|trace)[\s:(]', re.IGNORECASE)

total_commits = 0
for line in log_output.split('\n'):
    line = line.strip()
    if not line:
        continue
    total_commits += 1
    m = prefix_pattern.match(line)
    if m:
        cat = m.group(1).lower()
        categories[cat].append(line)
    else:
        categories['other'].append(line)

# ── Build PR description ────────────────────────────────────────────────

# Summarize what categories are present
active_cats = {k: v for k, v in categories.items() if v}

description_parts = []
if categories['feat']:
    description_parts.append(f'{len(categories[\"feat\"])} new feature(s)')
if categories['fix']:
    description_parts.append(f'{len(categories[\"fix\"])} bug fix(es)')
if categories['refactor']:
    description_parts.append(f'{len(categories[\"refactor\"])} refactor(s)')
if categories['test']:
    description_parts.append(f'{len(categories[\"test\"])} test update(s)')
if categories['docs']:
    description_parts.append(f'{len(categories[\"docs\"])} doc update(s)')
if categories['chore']:
    description_parts.append(f'{len(categories[\"chore\"])} chore(s)')
if categories['perf']:
    description_parts.append(f'{len(categories[\"perf\"])} perf improvement(s)')
if categories['trace']:
    description_parts.append(f'{len(categories[\"trace\"])} trace update(s)')

pr_summary = ', '.join(description_parts) if description_parts else 'miscellaneous changes'

# ── Output ──────────────────────────────────────────────────────────────

result = {
    'branch': current_branch,
    'base': base_branch,
    'files_changed': files_changed,
    'lines_added': lines_added,
    'lines_removed': lines_removed,
    'total_commits': total_commits,
    'new_test_files': new_test_files,
    'new_test_functions': new_test_functions,
    'categories': {k: len(v) for k, v in categories.items()},
    'category_details': {k: v for k, v in categories.items() if v},
    'changed_files': changed_files,
    'pr_summary': pr_summary
}

if json_mode:
    print(json.dumps(result, indent=2))
elif markdown_mode:
    print(f'## Diff Summary')
    print()
    print(f'**Branch:** \`{current_branch}\` -> \`{base_branch}\`')
    print()
    print(f'### Stats')
    print()
    print(f'| Metric | Count |')
    print(f'|--------|-------|')
    print(f'| Files changed | {files_changed} |')
    print(f'| Lines added | +{lines_added} |')
    print(f'| Lines removed | -{lines_removed} |')
    print(f'| Total commits | {total_commits} |')
    if new_test_files:
        print(f'| New test files | {len(new_test_files)} |')
    if new_test_functions:
        print(f'| New test assertions | {new_test_functions} |')
    print()
    print(f'### Commit Breakdown')
    print()
    for cat, commits in sorted(categories.items()):
        if not commits:
            continue
        print(f'**{cat}** ({len(commits)}):')
        for c in commits:
            print(f'- \`{c}\`')
        print()
    print(f'### Summary')
    print()
    print(f'This session includes {pr_summary}.')
    print(f'{files_changed} files were modified with +{lines_added}/-{lines_removed} line changes.')
else:
    # Default: human-readable text
    sep = '─' * 50
    print(f'Session Diff: {current_branch} vs {base_branch}')
    print(sep)
    print(f'  Files changed:     {files_changed}')
    print(f'  Lines added:       +{lines_added}')
    print(f'  Lines removed:     -{lines_removed}')
    print(f'  Total commits:     {total_commits}')
    if new_test_files:
        print(f'  New test files:    {len(new_test_files)}')
    if new_test_functions:
        print(f'  New test functions: {new_test_functions}')
    print()
    print('Commit breakdown:')
    for cat, commits in sorted(categories.items()):
        if not commits:
            continue
        print(f'  {cat}: {len(commits)}')
        for c in commits:
            print(f'    - {c}')
    print()
    print(f'Summary: {pr_summary}')
" "$PROJECT_DIR" "$BASE_BRANCH" "$CURRENT_BRANCH" "$MERGE_BASE" "$JSON_MODE" "$MARKDOWN_MODE"
