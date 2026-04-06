#!/usr/bin/env bash
# selective-merge.sh — Cherry-pick specific sprints from an auto/ session branch.
#
# Usage: selective-merge.sh <project-dir> <session-branch> [options]
#
# Modes:
#   --list                  List all sprints with merge recommendation (default)
#   --merge N,N,N           Cherry-pick merge commits for specified sprint numbers
#   --squash N,N,N          Squash-merge selected sprints into one commit
#   --dry-run               Show what would be merged without doing it
#   --interactive FILE      Write interactive choices to FILE
#   --apply                 Apply choices from interactive file (use with --interactive)
#   --target BRANCH         Target branch (default: current branch)
#   -h, --help              Show help
#
# Layer: conductor

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  cat << 'EOF'
Usage: selective-merge.sh <project-dir> <session-branch> [options]

Cherry-pick specific sprints from an auto/ session branch onto a target branch.

Arguments:
  project-dir       Project directory (must be a git repo)
  session-branch    Session branch name (e.g., auto/session-12345)

Modes:
  --list                  List all sprints with merge recommendation (default)
  --merge N,N,N           Cherry-pick merge commits for specified sprint numbers
  --squash N,N,N          Squash-merge selected sprints into one commit
  --dry-run               Show what would be merged without doing it
  --interactive FILE      Write interactive choices to FILE
  --apply                 Apply choices from interactive file (use with --interactive)
  --target BRANCH         Target branch (default: current branch)
  -h, --help              Show help

Examples:
  bash scripts/selective-merge.sh ./my-project auto/session-12345
  bash scripts/selective-merge.sh ./my-project auto/session-12345 --merge 1,3,5
  bash scripts/selective-merge.sh ./my-project auto/session-12345 --squash 1,2,3
  bash scripts/selective-merge.sh ./my-project auto/session-12345 --merge 1,2 --dry-run
  bash scripts/selective-merge.sh ./my-project auto/session-12345 --interactive plan.json
  bash scripts/selective-merge.sh ./my-project auto/session-12345 --interactive plan.json --apply
EOF
  exit 0
}

# Handle --help before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

# ── Parse arguments ──────────────────────────────────────────────────────

PROJECT_DIR=""
SESSION_BRANCH=""
MODE="list"
SPRINT_NUMS=""
DRY_RUN=false
INTERACTIVE_FILE=""
APPLY_MODE=false
TARGET_BRANCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage ;;
    --list)
      MODE="list"
      shift
      ;;
    --merge)
      [ -z "${2:-}" ] && die "--merge requires sprint numbers (e.g., --merge 1,2,3)"
      MODE="merge"
      SPRINT_NUMS="$2"
      shift 2
      ;;
    --squash)
      [ -z "${2:-}" ] && die "--squash requires sprint numbers (e.g., --squash 1,2,3)"
      MODE="squash"
      SPRINT_NUMS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --interactive)
      [ -z "${2:-}" ] && die "--interactive requires a file path"
      MODE="interactive"
      INTERACTIVE_FILE="$2"
      shift 2
      ;;
    --apply)
      APPLY_MODE=true
      shift
      ;;
    --target)
      [ -z "${2:-}" ] && die "--target requires a branch name"
      TARGET_BRANCH="$2"
      shift 2
      ;;
    *)
      if [ -z "$PROJECT_DIR" ]; then
        PROJECT_DIR="$1"
      elif [ -z "$SESSION_BRANCH" ]; then
        SESSION_BRANCH="$1"
      else
        die "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[ -z "$PROJECT_DIR" ] && die "project-dir is required"
[ -z "$SESSION_BRANCH" ] && die "session-branch is required"
[ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────

# Read conductor-state.json from the session branch via git show
read_conductor_state() {
  git -C "$PROJECT_DIR" show "$SESSION_BRANCH:.autonomous/conductor-state.json" 2>/dev/null || echo '{}'
}

# Find the merge commit hash for a specific sprint number on the session branch
find_sprint_commit() {
  local sprint_num="$1"
  # Match "sprint N:" at the start of the message
  git -C "$PROJECT_DIR" log --oneline "$SESSION_BRANCH" --grep="^sprint ${sprint_num}:" --format="%H %s" 2>/dev/null | head -1
}

# Parse comma-separated sprint numbers into a newline-separated list
parse_sprint_nums() {
  echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^[0-9]+$' || true
}

# ── List mode ────────────────────────────────────────────────────────────

do_list() {
  local state
  state=$(read_conductor_state)

  python3 -c "
import json, sys

state = json.loads(sys.argv[1])
session = sys.argv[2]
sprints = state.get('sprints', [])

if not sprints:
    print('No sprints found in conductor state.')
    sys.exit(0)

print(f'Session: {session}')
print()
print(f'{\"Sprint\":<7} | {\"Direction\":<40} | {\"Status\":<10} | {\"Commits\":<7} | {\"QG\":<4} | Rating')
print(f'{\"-\"*7}+{\"-\"*42}+{\"-\"*12}+{\"-\"*9}+{\"-\"*6}+{\"-\"*15}')

for s in sprints:
    num = s.get('number', 0)
    direction = s.get('direction', 'unknown')
    if len(direction) > 38:
        direction = direction[:35] + '...'
    status = s.get('status', 'unknown')
    commits = s.get('commits', [])
    commit_count = len(commits)
    qg = s.get('quality_gate_passed')
    if qg is True:
        qg_str = 'pass'
    elif qg is False:
        qg_str = 'fail'
    else:
        qg_str = chr(0x2014)

    if status in ('complete', 'merged') and commit_count > 0:
        rating = 'recommended'
    else:
        rating = 'skippable'

    print(f'{num:<7} | {direction:<40} | {status:<10} | {commit_count:<7} | {qg_str:<4} | {rating}')

rec = [s.get('number', 0) for s in sprints
       if s.get('status') in ('complete', 'merged') and len(s.get('commits', [])) > 0]
if rec:
    nums = ','.join(str(n) for n in rec)
    print()
    print(f'Recommended: --merge {nums}')
" "$state" "$SESSION_BRANCH"
}

# ── Merge mode ───────────────────────────────────────────────────────────

do_merge() {
  local nums_input="$1"
  local dry_run="$2"
  local target="$3"

  local nums
  nums=$(parse_sprint_nums "$nums_input")

  if [ -z "$nums" ]; then
    die "no valid sprint numbers provided"
  fi

  # Switch to target branch if specified
  if [ -n "$target" ]; then
    if [ "$dry_run" = "false" ]; then
      git -C "$PROJECT_DIR" checkout "$target" 2>/dev/null || die "cannot checkout target branch: $target"
    fi
  fi

  local merged=0 skipped=0 conflicted=0 failed_nums=""

  while IFS= read -r num; do
    local commit_info
    commit_info=$(find_sprint_commit "$num")

    if [ -z "$commit_info" ]; then
      echo "Sprint $num: no merge commit found — skipped"
      skipped=$((skipped + 1))
      continue
    fi

    local commit_hash
    commit_hash=$(echo "$commit_info" | awk '{print $1}')
    local commit_msg
    commit_msg=$(echo "$commit_info" | cut -d' ' -f2-)

    if [ "$dry_run" = "true" ]; then
      echo "Sprint $num: would cherry-pick $commit_hash ($commit_msg)"
      merged=$((merged + 1))
      continue
    fi

    echo "Sprint $num: cherry-picking $commit_hash..."
    # Merge commits (from --no-ff) require -m 1 to specify mainline parent
    if git -C "$PROJECT_DIR" cherry-pick -m 1 "$commit_hash" --allow-empty 2>/dev/null; then
      echo "Sprint $num: merged ($commit_msg)"
      merged=$((merged + 1))
    else
      git -C "$PROJECT_DIR" cherry-pick --abort 2>/dev/null || true
      echo "Sprint $num: CONFLICT — skipped"
      conflicted=$((conflicted + 1))
      failed_nums="${failed_nums:+$failed_nums,}$num"
    fi
  done <<< "$nums"

  echo ""
  if [ "$dry_run" = "true" ]; then
    echo "Dry run: $merged would be merged, $skipped skipped"
  else
    echo "Result: $merged merged, $skipped skipped, $conflicted conflicted"
    if [ -n "$failed_nums" ]; then
      echo "Conflicted sprints: $failed_nums"
    fi
  fi
}

# ── Squash mode ──────────────────────────────────────────────────────────

do_squash() {
  local nums_input="$1"
  local dry_run="$2"
  local target="$3"

  local nums
  nums=$(parse_sprint_nums "$nums_input")

  if [ -z "$nums" ]; then
    die "no valid sprint numbers provided"
  fi

  # Collect commit info first
  local commit_hashes=()
  local commit_msgs=()
  local sprint_numbers=()

  while IFS= read -r num; do
    local commit_info
    commit_info=$(find_sprint_commit "$num")

    if [ -z "$commit_info" ]; then
      echo "Sprint $num: no merge commit found — skipped"
      continue
    fi

    local commit_hash
    commit_hash=$(echo "$commit_info" | awk '{print $1}')
    local commit_msg
    commit_msg=$(echo "$commit_info" | cut -d' ' -f2-)

    commit_hashes+=("$commit_hash")
    commit_msgs+=("$commit_msg")
    sprint_numbers+=("$num")
  done <<< "$nums"

  if [ ${#commit_hashes[@]} -eq 0 ]; then
    echo "No merge commits found for any of the specified sprints."
    echo ""
    echo "Result: 0 merged, 0 skipped, 0 conflicted"
    return
  fi

  if [ "$dry_run" = "true" ]; then
    echo "Squash: would combine ${#commit_hashes[@]} sprints into one commit:"
    for i in "${!sprint_numbers[@]}"; do
      echo "  Sprint ${sprint_numbers[$i]}: ${commit_hashes[$i]} (${commit_msgs[$i]})"
    done
    echo ""
    echo "Dry run: ${#commit_hashes[@]} would be merged, 0 skipped"
    return
  fi

  # Determine current branch for return
  local original_branch
  original_branch=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "HEAD")
  local target_branch="${target:-$original_branch}"

  # Switch to target if specified
  if [ -n "$target" ]; then
    git -C "$PROJECT_DIR" checkout "$target" 2>/dev/null || die "cannot checkout target branch: $target"
  fi

  # Create temp branch from current position
  local tmp_branch="tmp/squash-$$"
  git -C "$PROJECT_DIR" checkout -b "$tmp_branch" 2>/dev/null || die "cannot create temp branch"

  local cherry_picked=0
  local conflicted=0

  for i in "${!commit_hashes[@]}"; do
    # Merge commits (from --no-ff) require -m 1 to specify mainline parent
    if git -C "$PROJECT_DIR" cherry-pick -m 1 "${commit_hashes[$i]}" --allow-empty 2>/dev/null; then
      cherry_picked=$((cherry_picked + 1))
    else
      git -C "$PROJECT_DIR" cherry-pick --abort 2>/dev/null || true
      echo "Sprint ${sprint_numbers[$i]}: CONFLICT during squash — skipped"
      conflicted=$((conflicted + 1))
    fi
  done

  if [ "$cherry_picked" -eq 0 ]; then
    git -C "$PROJECT_DIR" checkout "$target_branch" 2>/dev/null
    git -C "$PROJECT_DIR" branch -D "$tmp_branch" 2>/dev/null || true
    echo "No sprints could be cherry-picked."
    echo ""
    echo "Result: 0 merged, 0 skipped, $conflicted conflicted"
    return
  fi

  # Switch back to target and squash merge
  git -C "$PROJECT_DIR" checkout "$target_branch" 2>/dev/null

  # Build combined summary
  local sprint_list
  sprint_list=$(printf "%s," "${sprint_numbers[@]}" | sed 's/,$//')
  local combined_msg="squash sprints $sprint_list"

  git -C "$PROJECT_DIR" merge --squash "$tmp_branch" 2>/dev/null || {
    git -C "$PROJECT_DIR" merge --abort 2>/dev/null || true
    git -C "$PROJECT_DIR" branch -D "$tmp_branch" 2>/dev/null || true
    die "squash merge failed"
  }

  git -C "$PROJECT_DIR" commit -m "$combined_msg" 2>/dev/null || {
    git -C "$PROJECT_DIR" branch -D "$tmp_branch" 2>/dev/null || true
    die "squash commit failed"
  }

  # Clean up temp branch
  git -C "$PROJECT_DIR" branch -D "$tmp_branch" 2>/dev/null || true

  echo ""
  echo "Result: $cherry_picked merged (squashed), 0 skipped, $conflicted conflicted"
}

# ── Interactive mode ─────────────────────────────────────────────────────

do_interactive() {
  local file="$1"
  local apply="$2"
  local dry_run="$3"
  local target="$4"

  if [ "$apply" = "true" ]; then
    # Read the file and merge sprints marked "yes"
    [ -f "$file" ] || die "interactive file not found: $file"

    local yes_sprints
    yes_sprints=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
nums = [str(item['sprint']) for item in data if item.get('action') == 'yes']
print(','.join(nums))
" "$file" 2>/dev/null) || die "failed to parse interactive file"

    if [ -z "$yes_sprints" ]; then
      echo "No sprints marked 'yes' in $file"
      return
    fi

    echo "Applying sprints: $yes_sprints"
    do_merge "$yes_sprints" "$dry_run" "$target"
    return
  fi

  # Generate the interactive choices file
  local state
  state=$(read_conductor_state)

  python3 -c "
import json, sys

state = json.loads(sys.argv[1])
outfile = sys.argv[2]
sprints = state.get('sprints', [])

choices = []
for s in sprints:
    num = s.get('number', 0)
    direction = s.get('direction', 'unknown')
    status = s.get('status', 'unknown')
    commits = s.get('commits', [])
    commit_count = len(commits)

    if status in ('complete', 'merged') and commit_count > 0:
        rating = 'recommended'
    else:
        rating = 'skippable'

    choices.append({
        'sprint': num,
        'direction': direction,
        'status': status,
        'commits': commit_count,
        'rating': rating,
        'action': 'pending'
    })

with open(outfile, 'w') as f:
    json.dump(choices, f, indent=2)

print(f'Wrote {len(choices)} sprint choices to {outfile}')
print('Edit the file to set action to \"yes\", \"no\", or \"skip\" for each sprint.')
print(f'Then run: selective-merge.sh <project-dir> <session-branch> --interactive {outfile} --apply')
" "$state" "$file"
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "$MODE" in
  list)
    do_list
    ;;
  merge)
    do_merge "$SPRINT_NUMS" "$DRY_RUN" "$TARGET_BRANCH"
    ;;
  squash)
    do_squash "$SPRINT_NUMS" "$DRY_RUN" "$TARGET_BRANCH"
    ;;
  interactive)
    do_interactive "$INTERACTIVE_FILE" "$APPLY_MODE" "$DRY_RUN" "$TARGET_BRANCH"
    ;;
esac
