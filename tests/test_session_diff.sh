#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFF_SCRIPT="$SCRIPT_DIR/../scripts/session-diff.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_session_diff.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Helper: create a git repo with main branch and auto/ branch ────────

setup_project() {
  local dir="$1"
  mkdir -p "$dir"
  cd "$dir"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > init.txt
  git add init.txt
  git commit -q -m "initial commit"
  # Create main branch explicitly (some git versions default to 'master')
  git branch -M main
  cd - > /dev/null
}

create_auto_branch() {
  local dir="$1" branch_name="${2:-auto/session-test}"
  cd "$dir"
  git checkout -q -b "$branch_name"
  cd - > /dev/null
}

make_commits() {
  local dir="$1"
  shift
  cd "$dir"
  for msg in "$@"; do
    local fname
    fname="file-$(date +%s%N)-$RANDOM.txt"
    echo "$msg" > "$fname"
    git add "$fname"
    git commit -q -m "$msg"
  done
  cd - > /dev/null
}

make_test_file_commit() {
  local dir="$1" test_fname="$2" msg="$3"
  cd "$dir"
  echo "test content" > "$test_fname"
  git add "$test_fname"
  git commit -q -m "$msg"
  cd - > /dev/null
}

# ── 1. Help flags ──────────────────────────────────────────────────────

echo ""
echo "1. Help flags"

RESULT=$(bash "$DIFF_SCRIPT" --help 2>&1)
assert_contains "$RESULT" "Usage:" "--help shows usage"
assert_contains "$RESULT" "session-diff" "--help mentions script name"
echo "$RESULT" | grep -qF -- "--base" && ok "--help mentions --base" || fail "--help mentions --base"
echo "$RESULT" | grep -qF -- "--json" && ok "--help mentions --json" || fail "--help mentions --json"
echo "$RESULT" | grep -qF -- "--markdown" && ok "--help mentions --markdown" || fail "--help mentions --markdown"

RESULT2=$(bash "$DIFF_SCRIPT" -h 2>&1)
assert_contains "$RESULT2" "Usage:" "-h shows usage"

RESULT3=$(bash "$DIFF_SCRIPT" help 2>&1)
assert_contains "$RESULT3" "Usage:" "help shows usage"

# ── 2. Error: missing project-dir ──────────────────────────────────────

echo ""
echo "2. Error handling"

RESULT=$(bash "$DIFF_SCRIPT" 2>&1) || true
assert_contains "$RESULT" "ERROR" "missing project-dir shows error"

# Non-existent directory
RESULT=$(bash "$DIFF_SCRIPT" /nonexistent/path 2>&1) || true
assert_contains "$RESULT" "ERROR" "nonexistent dir shows error"

# Directory that's not a git repo
T=$(new_tmp)
RESULT=$(bash "$DIFF_SCRIPT" "$T" 2>&1) || true
assert_contains "$RESULT" "ERROR" "non-git dir shows error"
assert_contains "$RESULT" "not a git repository" "mentions not a git repo"

# ── 3. Error: no main/master branch ───────────────────────────────────

echo ""
echo "3. No base branch detected"

T=$(new_tmp)
mkdir -p "$T"
cd "$T"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "initial"
# Rename branch to something else entirely
git branch -M feature-only
cd - > /dev/null

RESULT=$(bash "$DIFF_SCRIPT" "$T" 2>&1) || true
assert_contains "$RESULT" "ERROR" "no main/master shows error"
assert_contains "$RESULT" "no main or master" "mentions missing main/master"

# ── 4. Error: invalid --base branch ───────────────────────────────────

echo ""
echo "4. Invalid --base branch"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --base nonexistent 2>&1) || true
assert_contains "$RESULT" "ERROR" "invalid --base shows error"
assert_contains "$RESULT" "base branch not found" "mentions branch not found"

# ── 5. Basic diff: default text output ────────────────────────────────

echo ""
echo "5. Basic text output"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: add login page" "fix: correct typo in header"

RESULT=$(bash "$DIFF_SCRIPT" "$T" 2>&1)
assert_contains "$RESULT" "Session Diff" "text output has header"
assert_contains "$RESULT" "Files changed" "shows files changed"
assert_contains "$RESULT" "Lines added" "shows lines added"
assert_contains "$RESULT" "Lines removed" "shows lines removed"
assert_contains "$RESULT" "Total commits" "shows total commits"
assert_contains "$RESULT" "Commit breakdown" "shows commit breakdown"
assert_contains "$RESULT" "feat:" "shows feat category"
assert_contains "$RESULT" "fix:" "shows fix category"
assert_contains "$RESULT" "Summary:" "shows summary line"

# ── 6. Commit categorization: all prefixes ────────────────────────────

echo ""
echo "6. Commit categorization"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" \
  "feat: new feature" \
  "fix: bug fix" \
  "refactor: clean up code" \
  "test: add unit tests" \
  "docs: update readme" \
  "chore: bump deps" \
  "perf: optimize query" \
  "trace: add logging" \
  "random commit message"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)

CATS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
c = d['categories']
checks = []
checks.append(c.get('feat', 0) == 1)
checks.append(c.get('fix', 0) == 1)
checks.append(c.get('refactor', 0) == 1)
checks.append(c.get('test', 0) == 1)
checks.append(c.get('docs', 0) == 1)
checks.append(c.get('chore', 0) == 1)
checks.append(c.get('perf', 0) == 1)
checks.append(c.get('trace', 0) == 1)
checks.append(c.get('other', 0) == 1)
print('ok' if all(checks) else f'fail: {c}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$CATS" "ok" "all 9 commit categories counted correctly"

TOTAL=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['total_commits'])
" "$RESULT" 2>/dev/null)
assert_eq "$TOTAL" "9" "total commits is 9"

# ── 7. --json output structure ────────────────────────────────────────

echo ""
echo "7. --json output"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: add api endpoint" "fix: handle null response"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)

VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    assert 'branch' in d
    assert 'base' in d
    assert 'files_changed' in d
    assert 'lines_added' in d
    assert 'lines_removed' in d
    assert 'total_commits' in d
    assert 'new_test_files' in d
    assert 'new_test_functions' in d
    assert 'categories' in d
    assert 'category_details' in d
    assert 'changed_files' in d
    assert 'pr_summary' in d
    print('ok')
except Exception as e:
    print(f'fail: {e}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "JSON has all required fields"

# Check values
VALUES=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
checks = []
checks.append(d['files_changed'] == 2)
checks.append(d['total_commits'] == 2)
checks.append(d['base'] == 'main')
checks.append(d['lines_added'] > 0)
checks.append(d['categories']['feat'] == 1)
checks.append(d['categories']['fix'] == 1)
print('ok' if all(checks) else f'fail: {d}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALUES" "ok" "JSON values are accurate"

# ── 8. --markdown output ──────────────────────────────────────────────

echo ""
echo "8. --markdown output"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: new dashboard" "test: add dashboard tests"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --markdown 2>&1)
assert_contains "$RESULT" "## Diff Summary" "markdown has header"
echo "$RESULT" | grep -qF "**Branch:**" && ok "markdown has branch info" || fail "markdown has branch info"
assert_contains "$RESULT" "### Stats" "markdown has stats section"
assert_contains "$RESULT" "| Metric | Count |" "markdown has stats table"
assert_contains "$RESULT" "Files changed" "markdown shows files changed"
assert_contains "$RESULT" "### Commit Breakdown" "markdown has commit breakdown"
echo "$RESULT" | grep -qF "**feat**" && ok "markdown shows feat category" || fail "markdown shows feat category"
assert_contains "$RESULT" "### Summary" "markdown has summary section"

# ── 9. --base flag override ───────────────────────────────────────────

echo ""
echo "9. --base flag"

T=$(new_tmp)
setup_project "$T"
# Create a custom base branch
cd "$T"
git checkout -q -b develop
echo "develop content" > develop.txt
git add develop.txt
git commit -q -m "develop commit"
git checkout -q -b auto/test-session
cd - > /dev/null
make_commits "$T" "feat: feature on custom base"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --base develop --json 2>&1)
BASE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['base'])
" "$RESULT" 2>/dev/null)
assert_eq "$BASE" "develop" "--base flag sets correct base branch"

# ── 10. master fallback ──────────────────────────────────────────────

echo ""
echo "10. master branch fallback"

T=$(new_tmp)
mkdir -p "$T"
cd "$T"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "initial"
git branch -M master
git checkout -q -b auto/test-session
cd - > /dev/null
make_commits "$T" "feat: master fallback test"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
BASE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['base'])
" "$RESULT" 2>/dev/null)
assert_eq "$BASE" "master" "falls back to master when no main"

# ── 11. Lines added/removed accuracy ─────────────────────────────────

echo ""
echo "11. Line stats accuracy"

T=$(new_tmp)
setup_project "$T"
# Add a file with known content on main
cd "$T"
git checkout -q main
printf "line1\nline2\nline3\n" > tracked.txt
git add tracked.txt
git commit -q -m "add tracked file"
git checkout -q -b auto/test-lines
# Modify: remove 1 line, add 2 lines
printf "line1\nline3\nnewA\nnewB\n" > tracked.txt
git add tracked.txt
git commit -q -m "feat: modify tracked"
cd - > /dev/null

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
LINES=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
# removed line2, added newA and newB => +2 -1
checks = []
checks.append(d['lines_added'] == 2)
checks.append(d['lines_removed'] == 1)
print('ok' if all(checks) else f'fail: added={d[\"lines_added\"]} removed={d[\"lines_removed\"]}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$LINES" "ok" "lines added/removed are accurate"

# ── 12. New test files detection ──────────────────────────────────────

echo ""
echo "12. New test files detection"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_test_file_commit "$T" "test_auth.py" "test: add auth tests"
make_test_file_commit "$T" "spec_helper.rb" "test: add spec helper"
make_commits "$T" "feat: add regular file"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
TEST_FILES=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
tf = d['new_test_files']
checks = []
checks.append(len(tf) == 2)
checks.append('test_auth.py' in tf)
checks.append('spec_helper.rb' in tf)
print('ok' if all(checks) else f'fail: {tf}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$TEST_FILES" "ok" "detects new test files correctly"

# ── 13. No commits (empty diff) ──────────────────────────────────────

echo ""
echo "13. Empty diff (no commits on branch)"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
# No commits on auto branch

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
EMPTY=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
checks = []
checks.append(d['files_changed'] == 0)
checks.append(d['lines_added'] == 0)
checks.append(d['lines_removed'] == 0)
checks.append(d['total_commits'] == 0)
print('ok' if all(checks) else f'fail: {d}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$EMPTY" "ok" "empty diff shows all zeros"

# ── 14. Empty diff text output ────────────────────────────────────────

echo ""
echo "14. Empty diff text output"

# Reuse T from test 13
RESULT=$(bash "$DIFF_SCRIPT" "$T" 2>&1)
assert_contains "$RESULT" "Files changed:     0" "text shows 0 files"
assert_contains "$RESULT" "Total commits:     0" "text shows 0 commits"

# ── 15. PR summary generation ────────────────────────────────────────

echo ""
echo "15. PR summary generation"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: one" "feat: two" "fix: three"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
SUMMARY=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
s = d['pr_summary']
checks = []
checks.append('2 new feature' in s)
checks.append('1 bug fix' in s)
print('ok' if all(checks) else f'fail: {s}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$SUMMARY" "ok" "PR summary includes category counts"

# ── 16. PR summary with only other commits ────────────────────────────

echo ""
echo "16. PR summary with only uncategorized commits"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "random stuff" "another change"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
SUMMARY=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['pr_summary'])
" "$RESULT" 2>/dev/null)
assert_eq "$SUMMARY" "miscellaneous changes" "uncategorized commits show miscellaneous"

# ── 17. Changed files list ────────────────────────────────────────────

echo ""
echo "17. Changed files in JSON"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
cd "$T"
echo "content" > specific-file.txt
git add specific-file.txt
git commit -q -m "feat: add specific file"
cd - > /dev/null

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
HAS_FILE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print('ok' if 'specific-file.txt' in d['changed_files'] else 'fail')
" "$RESULT" 2>/dev/null)
assert_eq "$HAS_FILE" "ok" "changed_files includes the specific file"

# ── 18. Category details in JSON ─────────────────────────────────────

echo ""
echo "18. Category details"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: alpha" "feat: beta"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
DETAILS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
cd = d['category_details']
checks = []
checks.append('feat' in cd)
checks.append(len(cd['feat']) == 2)
# other categories should not appear in details
checks.append('fix' not in cd)
checks.append('other' not in cd)
print('ok' if all(checks) else f'fail: {cd}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$DETAILS" "ok" "category_details only has active categories"

# ── 19. Markdown summary section ─────────────────────────────────────

echo ""
echo "19. Markdown summary content"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: dashboard" "fix: header bug"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --markdown 2>&1)
assert_contains "$RESULT" "This session includes" "markdown summary describes session"
assert_contains "$RESULT" "files were modified" "markdown summary mentions file count"
assert_contains "$RESULT" "line changes" "markdown summary mentions line changes"

# ── 20. Unexpected argument error ─────────────────────────────────────

echo ""
echo "20. Unexpected argument error"

T=$(new_tmp)
setup_project "$T"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --bad-flag 2>&1) || true
assert_contains "$RESULT" "ERROR" "unexpected flag shows error"

# ── 21. --base without value ──────────────────────────────────────────

echo ""
echo "21. --base without value"

T=$(new_tmp)
setup_project "$T"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --base 2>&1) || true
assert_contains "$RESULT" "ERROR" "--base without value shows error"
assert_contains "$RESULT" "requires" "mentions requirement"

# ── 22. Multiple file changes in single commit ───────────────────────

echo ""
echo "22. Multiple files in one commit"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
cd "$T"
echo "a" > fileA.txt
echo "b" > fileB.txt
echo "c" > fileC.txt
git add fileA.txt fileB.txt fileC.txt
git commit -q -m "feat: add three files at once"
cd - > /dev/null

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
FILES=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['files_changed'])
" "$RESULT" 2>/dev/null)
assert_eq "$FILES" "3" "counts all 3 files changed in single commit"

# ── 23. Case-insensitive prefix matching ──────────────────────────────

echo ""
echo "23. Case-insensitive prefix matching"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "Feat: uppercase prefix" "FIX: all caps prefix"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
CASE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
c = d['categories']
checks = []
checks.append(c.get('feat', 0) == 1)
checks.append(c.get('fix', 0) == 1)
print('ok' if all(checks) else f'fail: {c}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$CASE" "ok" "case-insensitive prefix matching works"

# ── 24. Branch name in output ─────────────────────────────────────────

echo ""
echo "24. Branch name in output"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T" "auto/session-12345"
make_commits "$T" "feat: test branch name"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
BRANCH=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d['branch'])
" "$RESULT" 2>/dev/null)
assert_eq "$BRANCH" "auto/session-12345" "JSON contains correct branch name"

RESULT_TEXT=$(bash "$DIFF_SCRIPT" "$T" 2>&1)
assert_contains "$RESULT_TEXT" "auto/session-12345" "text output contains branch name"

# ── 25. Colon-style and paren-style prefixes ─────────────────────────

echo ""
echo "25. Prefix styles"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: colon style" "fix(auth): paren style"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
STYLES=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
c = d['categories']
checks = []
checks.append(c.get('feat', 0) == 1)
checks.append(c.get('fix', 0) == 1)
print('ok' if all(checks) else f'fail: {c}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$STYLES" "ok" "both colon and paren prefix styles detected"

# ── 26. Test file patterns ────────────────────────────────────────────

echo ""
echo "26. Various test file patterns"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_test_file_commit "$T" "test_foo.sh" "test: bash test"
make_test_file_commit "$T" "foo.test.js" "test: js test"
make_test_file_commit "$T" "foo_spec.rb" "test: ruby spec"
make_test_file_commit "$T" "spec-helper.ts" "test: ts spec helper"
make_commits "$T" "feat: not a test file"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
TEST_COUNT=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(len(d['new_test_files']))
" "$RESULT" 2>/dev/null)
assert_ge "$TEST_COUNT" "4" "detects 4+ test file patterns"

# ── 27. Markdown table correctness ────────────────────────────────────

echo ""
echo "27. Markdown table format"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: table test"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --markdown 2>&1)
assert_contains "$RESULT" "|--------|-------|" "markdown table has separator"
assert_contains "$RESULT" "| Lines added |" "markdown table has lines added row"
assert_contains "$RESULT" "| Lines removed |" "markdown table has lines removed row"
assert_contains "$RESULT" "| Total commits |" "markdown table has commits row"

# ── 28. Large number of commits ───────────────────────────────────────

echo ""
echo "28. Many commits"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" \
  "feat: a1" "feat: a2" "feat: a3" "feat: a4" "feat: a5" \
  "fix: b1" "fix: b2" "fix: b3" \
  "docs: c1" "docs: c2"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
MANY=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
c = d['categories']
checks = []
checks.append(d['total_commits'] == 10)
checks.append(c['feat'] == 5)
checks.append(c['fix'] == 3)
checks.append(c['docs'] == 2)
print('ok' if all(checks) else f'fail: total={d[\"total_commits\"]} cats={c}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$MANY" "ok" "handles 10 commits with correct categorization"

# ── 29. File modification (not just addition) ────────────────────────

echo ""
echo "29. Modified files counted"

T=$(new_tmp)
setup_project "$T"
cd "$T"
git checkout -q main
echo "original" > existing.txt
git add existing.txt
git commit -q -m "add existing file"
git checkout -q -b auto/test-modify
echo "modified" > existing.txt
git add existing.txt
git commit -q -m "feat: modify existing"
cd - > /dev/null

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
MOD=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
checks = []
checks.append(d['files_changed'] == 1)
checks.append('existing.txt' in d['changed_files'])
print('ok' if all(checks) else f'fail: {d}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$MOD" "ok" "modified file is counted correctly"

# ── 30. Deleted file in diff ─────────────────────────────────────────

echo ""
echo "30. Deleted file in diff"

T=$(new_tmp)
setup_project "$T"
cd "$T"
git checkout -q main
echo "to delete" > removeme.txt
git add removeme.txt
git commit -q -m "add file to remove"
git checkout -q -b auto/test-delete
git rm -q removeme.txt
git commit -q -m "chore: remove unused file"
cd - > /dev/null

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
DEL=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
checks = []
checks.append(d['files_changed'] == 1)
checks.append('removeme.txt' in d['changed_files'])
checks.append(d['lines_removed'] > 0)
print('ok' if all(checks) else f'fail: {d}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$DEL" "ok" "deleted file shows in diff"

# ── 31. JSON + markdown mutual exclusion (last wins) ──────────────────

echo ""
echo "31. Multiple output flags"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: multi flag test"

# --json last
RESULT=$(bash "$DIFF_SCRIPT" "$T" --markdown --json 2>&1)
VALID=$(python3 -c "
import json, sys
try:
    json.loads(sys.argv[1])
    print('json')
except:
    if '## Diff Summary' in sys.argv[1]:
        print('markdown')
    else:
        print('text')
" "$RESULT" 2>/dev/null)
# Both flags set to true, python checks json first so json_mode wins
assert_eq "$VALID" "json" "json mode takes precedence when both set"

# ── 32. Text output formatting ────────────────────────────────────────

echo ""
echo "32. Text output structure"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: alpha" "fix: beta"

RESULT=$(bash "$DIFF_SCRIPT" "$T" 2>&1)
assert_contains "$RESULT" "─" "text output has separator line"
assert_contains "$RESULT" "vs main" "text output shows vs base"

# ── 33. Commit with scope in parens ──────────────────────────────────

echo ""
echo "33. Scoped commits"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat(ui): add button" "fix(api): null check" "refactor(db): simplify query"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
SCOPED=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
c = d['categories']
checks = []
checks.append(c.get('feat', 0) == 1)
checks.append(c.get('fix', 0) == 1)
checks.append(c.get('refactor', 0) == 1)
checks.append(c.get('other', 0) == 0)
print('ok' if all(checks) else f'fail: {c}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$SCOPED" "ok" "scoped commits categorized correctly"

# ── 34. Markdown code formatting in commits ──────────────────────────

echo ""
echo "34. Markdown commit formatting"

T=$(new_tmp)
setup_project "$T"
create_auto_branch "$T"
make_commits "$T" "feat: add new endpoint"

RESULT=$(bash "$DIFF_SCRIPT" "$T" --markdown 2>&1)
# Commits should be wrapped in backticks
assert_contains "$RESULT" "\`" "markdown wraps commits in backticks"

# ── 35. New test files NOT counted when file is modified (not new) ────

echo ""
echo "35. Modified test files not counted as new"

T=$(new_tmp)
setup_project "$T"
cd "$T"
git checkout -q main
echo "existing test" > test_existing.py
git add test_existing.py
git commit -q -m "add existing test"
git checkout -q -b auto/test-modified-test
echo "modified test" > test_existing.py
git add test_existing.py
git commit -q -m "test: update existing test"
cd - > /dev/null

RESULT=$(bash "$DIFF_SCRIPT" "$T" --json 2>&1)
NEW_TESTS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(len(d['new_test_files']))
" "$RESULT" 2>/dev/null)
assert_eq "$NEW_TESTS" "0" "modified test file not counted as new"

# ── 36. Session-report integration --diff flag ────────────────────────

echo ""
echo "36. session-report.sh --diff integration"

REPORT="$SCRIPT_DIR/../scripts/session-report.sh"

T=$(new_tmp)
cd "$T"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "initial commit"
git branch -M main
git checkout -q -b auto/test-integration
mkdir -p .autonomous
cd - > /dev/null

make_commits "$T" "feat: integration test commit"

# Create sprint summary
python3 -c "
import json, sys, subprocess
# Get commit hash
r = subprocess.run(['git', 'log', '--oneline', '-1'], capture_output=True, text=True, cwd=sys.argv[1])
commit_line = r.stdout.strip()
d = {'status': 'complete', 'summary': 'Integration test', 'commits': [commit_line], 'direction_complete': True}
with open(sys.argv[1] + '/.autonomous/sprint-1-summary.json', 'w') as f:
    json.dump(d, f)
" "$T"

RESULT=$(bash "$REPORT" "$T" --diff 2>&1)
assert_contains "$RESULT" "Sprint" "report with --diff still shows sprint table"
assert_contains "$RESULT" "Total:" "report with --diff still shows totals"
assert_contains "$RESULT" "Session Diff" "report with --diff appends diff summary"
assert_contains "$RESULT" "Files changed" "report with --diff shows diff stats"

# ── 37. Session-report --diff --json ──────────────────────────────────

echo ""
echo "37. session-report.sh --diff --json"

RESULT=$(bash "$REPORT" "$T" --diff --json 2>&1)
VALID=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    checks = []
    checks.append('sprints' in d)
    checks.append('totals' in d)
    checks.append('diff' in d)
    checks.append('files_changed' in d['diff'])
    checks.append('categories' in d['diff'])
    print('ok' if all(checks) else f'fail: {list(d.keys())}')
except Exception as e:
    print(f'fail: {e}')
" "$RESULT" 2>/dev/null || echo "fail")
assert_eq "$VALID" "ok" "report --diff --json includes diff section"

# ── 38. Session-report --diff without git changes ────────────────────

echo ""
echo "38. session-report.sh --diff with no branch changes"

T=$(new_tmp)
cd "$T"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "initial commit"
git branch -M main
git checkout -q -b auto/empty-session
mkdir -p .autonomous
cd - > /dev/null

# Create sprint summary with no commits
python3 -c "
import json
d = {'status': 'complete', 'summary': 'Empty sprint', 'commits': [], 'direction_complete': True}
with open('$T/.autonomous/sprint-1-summary.json', 'w') as f:
    json.dump(d, f)
"

RESULT=$(bash "$REPORT" "$T" --diff 2>&1)
assert_contains "$RESULT" "Session Diff" "diff section present even with no changes"
assert_contains "$RESULT" "Files changed:     0" "shows 0 files changed"

# ── Print results ────────────────────────────────────────────────────

print_results
