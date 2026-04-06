#!/usr/bin/env bash
# worktree-manager.sh — Manage git worktrees for sprint isolation.
#
# Each worker gets its own worktree under .autonomous/worktrees/<sanitized-branch>/
# so multiple workers can run on different branches without checkout conflicts.
#
# Usage: bash worktree-manager.sh <command> [args...]
#
# Commands:
#   create  <project_dir> <branch>                 Create worktree for branch
#   destroy <project_dir> <branch>                 Remove worktree + clean up
#   list    <project_dir>                          List active worktrees (JSON)
#   merge   <project_dir> <branch> <target>        Merge worktree branch into target, destroy
#   cleanup <project_dir>                          Remove all stale/orphaned worktrees
#   path    <project_dir> <branch>                 Print worktree path for a branch
#
# Layer: shared

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: bash worktree-manager.sh <command> [args...]

Manage git worktrees for sprint worker isolation.

Commands:
  create  <project_dir> <branch>                 Create worktree at .autonomous/worktrees/<sanitized-branch>/
  destroy <project_dir> <branch>                 Remove worktree + clean up
  list    <project_dir>                          List active worktrees (JSON array)
  merge   <project_dir> <branch> <target>        Merge worktree branch into target, then destroy
  cleanup <project_dir>                          Remove all stale/orphaned worktrees
  path    <project_dir> <branch>                 Print the worktree path for a branch

Examples:
  bash worktree-manager.sh create /path/to/project auto/sprint-1
  bash worktree-manager.sh list /path/to/project
  bash worktree-manager.sh merge /path/to/project auto/sprint-1 auto/session-123
  bash worktree-manager.sh cleanup /path/to/project
EOF
  exit 0
}

# ── Helpers ───────────────────────────────────────────────────────────────────

# Sanitize branch name: replace / with --, strip non-alphanumeric except - and _
sanitize_branch() {
  local branch="$1"
  printf '%s' "$branch" | sed 's|/|--|g' | tr -cd 'a-zA-Z0-9_-'
}

# Compute worktree path for a branch
worktree_path() {
  local project_dir="$1"
  local branch="$2"
  local safe
  safe=$(sanitize_branch "$branch")
  echo "$project_dir/.autonomous/worktrees/$safe"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_create() {
  local project_dir="${1:?ERROR: project_dir required}"
  local branch="${2:?ERROR: branch name required}"

  local wt_path
  wt_path=$(worktree_path "$project_dir" "$branch")

  if [ -d "$wt_path" ]; then
    echo "ERROR: worktree already exists at $wt_path" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$wt_path")"

  # Check if branch already exists
  if git -C "$project_dir" rev-parse --verify "$branch" &>/dev/null; then
    git -C "$project_dir" worktree add "$wt_path" "$branch" 2>&1
  else
    git -C "$project_dir" worktree add "$wt_path" -b "$branch" 2>&1
  fi

  echo "WORKTREE_PATH=$wt_path"
}

cmd_destroy() {
  local project_dir="${1:?ERROR: project_dir required}"
  local branch="${2:?ERROR: branch name required}"

  local wt_path
  wt_path=$(worktree_path "$project_dir" "$branch")

  if [ ! -d "$wt_path" ]; then
    echo "Worktree not found at $wt_path, nothing to destroy"
    return 0
  fi

  git -C "$project_dir" worktree remove "$wt_path" --force 2>/dev/null || {
    # Fallback: manually remove if git worktree remove fails
    rm -rf "$wt_path"
    git -C "$project_dir" worktree prune 2>/dev/null || true
  }

  echo "Destroyed worktree for branch '$branch'"
}

cmd_list() {
  local project_dir="${1:?ERROR: project_dir required}"
  local wt_dir="$project_dir/.autonomous/worktrees"

  # Use git worktree list --porcelain and filter to our managed worktrees
  local porcelain
  porcelain=$(git -C "$project_dir" worktree list --porcelain 2>/dev/null || true)

  python3 -c "
import sys, os, json

porcelain = sys.stdin.read()
wt_dir = os.path.realpath(sys.argv[1]) if os.path.exists(sys.argv[1]) else sys.argv[1]
result = []
current = {}

for line in porcelain.split('\n'):
    if line.startswith('worktree '):
        if current:
            # Check if this worktree is under our managed dir
            wt_path = current.get('path', '')
            if '/.autonomous/worktrees/' in wt_path:
                result.append(current)
        current = {'path': line[len('worktree '):]}
    elif line.startswith('HEAD '):
        current['head'] = line[len('HEAD '):]
    elif line.startswith('branch '):
        current['branch'] = line[len('branch refs/heads/'):]
    elif line == '' and current:
        wt_path = current.get('path', '')
        if '/.autonomous/worktrees/' in wt_path:
            result.append(current)
        current = {}

# Handle last entry
if current:
    wt_path = current.get('path', '')
    if '/.autonomous/worktrees/' in wt_path:
        result.append(current)

print(json.dumps(result))
" "$wt_dir" <<< "$porcelain"
}

cmd_merge() {
  local project_dir="${1:?ERROR: project_dir required}"
  local branch="${2:?ERROR: source branch required}"
  local target="${3:?ERROR: target branch required}"

  # Verify the branch exists
  if ! git -C "$project_dir" rev-parse --verify "$branch" &>/dev/null; then
    echo "ERROR: branch '$branch' does not exist" >&2
    exit 1
  fi

  # Save current branch to restore after merge
  local current_branch
  current_branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD)

  # Checkout target branch in main repo
  git -C "$project_dir" checkout "$target" 2>/dev/null || {
    echo "ERROR: cannot checkout target branch '$target'" >&2
    exit 1
  }

  # Merge the worktree branch
  git -C "$project_dir" merge --no-ff "$branch" -m "Merge worktree branch '$branch' into '$target'" 2>&1 || {
    local merge_exit=$?
    # Restore original branch on merge failure
    git -C "$project_dir" checkout "$current_branch" 2>/dev/null || true
    echo "ERROR: merge failed" >&2
    exit "$merge_exit"
  }

  # Destroy the worktree
  cmd_destroy "$project_dir" "$branch"

  echo "Merged '$branch' into '$target'"
}

cmd_cleanup() {
  local project_dir="${1:?ERROR: project_dir required}"
  local wt_dir="$project_dir/.autonomous/worktrees"

  # Prune stale worktree bookkeeping
  git -C "$project_dir" worktree prune 2>/dev/null || true

  if [ ! -d "$wt_dir" ]; then
    echo "No worktrees directory found, nothing to clean"
    return 0
  fi

  local count=0
  for entry in "$wt_dir"/*/; do
    [ -d "$entry" ] || continue
    # Check if this directory is still a valid worktree
    if ! git -C "$project_dir" worktree list --porcelain 2>/dev/null | grep -q "$entry"; then
      rm -rf "$entry"
      ((count++)) || true
    fi
  done

  # Remove worktrees dir if empty
  if [ -d "$wt_dir" ] && [ -z "$(ls -A "$wt_dir" 2>/dev/null)" ]; then
    rmdir "$wt_dir" 2>/dev/null || true
  fi

  echo "Cleaned up $count stale worktree(s)"
}

cmd_path() {
  local project_dir="${1:?ERROR: project_dir required}"
  local branch="${2:?ERROR: branch name required}"

  worktree_path "$project_dir" "$branch"
}

# ── Main dispatch ─────────────────────────────────────────────────────────────

case "${1:-}" in
  -h|--help|help) usage ;;
  create)   shift; cmd_create "$@" ;;
  destroy)  shift; cmd_destroy "$@" ;;
  list)     shift; cmd_list "$@" ;;
  merge)    shift; cmd_merge "$@" ;;
  cleanup)  shift; cmd_cleanup "$@" ;;
  path)     shift; cmd_path "$@" ;;
  "")
    echo "ERROR: command required. Run with --help for usage." >&2
    exit 1
    ;;
  *)
    echo "ERROR: unknown command '$1'" >&2
    echo "Run with --help for usage." >&2
    exit 1
    ;;
esac
