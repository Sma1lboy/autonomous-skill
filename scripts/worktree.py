#!/usr/bin/env python3
"""Per-sprint git worktree manager for autonomous-skill.

Each sprint gets its own working directory at `<project>/.worktrees/sprint-N/`,
bound to a dedicated branch. The main project tree stays on the session
branch throughout — only worktrees switch between sprint branches. This
isolates file changes between sprints and lets us avoid `git checkout -b`
churn on the main tree.

The worktree's `.autonomous/` is symlinked back to the main tree so coordination
files (comms.json, conductor-state.json, sprint-N-summary.json, backlog.json)
all go through a single source of truth. Workers and sprint masters read/write
via `$(pwd)/.autonomous/` as before — the symlink is transparent.

V1 scope: serial sprints, worktree per sprint, isolation only. Parallel
dispatch + file-overlap guards are deferred to V2.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import NoReturn


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def worktree_root(project_root: Path) -> Path:
    return project_root / ".worktrees"


def sprint_worktree_path(project_root: Path, sprint_num: int) -> Path:
    return worktree_root(project_root) / f"sprint-{sprint_num}"


def git(args: list[str], *, cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=check,
    )


def is_git_repo(path: Path) -> bool:
    if not path.exists():
        return False
    result = subprocess.run(
        ["git", "rev-parse", "--git-dir"],
        cwd=path,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0


def cmd_create(project_root: Path, args: list[str]) -> None:
    """create <sprint-num> <branch-name>"""
    if len(args) < 2:
        die("Usage: worktree.py create <project-root> <sprint-num> <branch-name>")
    try:
        sprint_num = int(args[0])
    except ValueError:
        die(f"sprint-num must be integer, got: {args[0]}")
    branch_name = args[1]
    if not branch_name.strip():
        die("branch-name is required")

    if not is_git_repo(project_root):
        die(f"not a git repo: {project_root}")

    wt_path = sprint_worktree_path(project_root, sprint_num)
    worktree_root(project_root).mkdir(exist_ok=True)

    # Prune stale entries before creating a new one. Harmless if nothing is stale.
    git(["worktree", "prune"], cwd=project_root, check=False)

    if wt_path.exists():
        die(f"worktree path already exists: {wt_path}. Run `worktree.py remove {sprint_num}` first.")

    # Create worktree on new branch off current HEAD (session branch).
    result = git(
        ["worktree", "add", str(wt_path), "-b", branch_name],
        cwd=project_root,
        check=False,
    )
    if result.returncode != 0:
        die(f"git worktree add failed: {result.stderr.strip() or result.stdout.strip()}")

    # Symlink .autonomous so coordination files stay in the main tree.
    main_autonomous = project_root / ".autonomous"
    main_autonomous.mkdir(exist_ok=True)
    worktree_autonomous = wt_path / ".autonomous"
    if worktree_autonomous.exists() or worktree_autonomous.is_symlink():
        # Remove whatever's there — a fresh checkout shouldn't have .autonomous
        # (it's gitignored) but belt-and-suspenders.
        if worktree_autonomous.is_symlink() or worktree_autonomous.is_file():
            worktree_autonomous.unlink()
        else:
            import shutil
            shutil.rmtree(worktree_autonomous)
    worktree_autonomous.symlink_to(main_autonomous.resolve(), target_is_directory=True)

    print(str(wt_path.resolve()))


def cmd_remove(project_root: Path, args: list[str]) -> None:
    """remove <sprint-num>"""
    if not args:
        die("Usage: worktree.py remove <project-root> <sprint-num>")
    try:
        sprint_num = int(args[0])
    except ValueError:
        die(f"sprint-num must be integer, got: {args[0]}")

    wt_path = sprint_worktree_path(project_root, sprint_num)

    if not wt_path.exists():
        # Idempotent: nothing to remove.
        git(["worktree", "prune"], cwd=project_root, check=False)
        print(f"worktree sprint-{sprint_num} not present (nothing to remove)")
        return

    # Unlink the .autonomous symlink first so git worktree remove doesn't
    # complain about unknown content or follow it into the main tree.
    wt_autonomous = wt_path / ".autonomous"
    if wt_autonomous.is_symlink():
        wt_autonomous.unlink()

    # --force removes even if the worktree has uncommitted changes. By the
    # time conductor calls remove(), evaluate-sprint has already read the
    # summary, so any dirty state in the worktree is disposable.
    result = git(
        ["worktree", "remove", "--force", str(wt_path)],
        cwd=project_root,
        check=False,
    )
    if result.returncode != 0:
        # Fall back to prune + rmdir if git is confused about the worktree.
        git(["worktree", "prune"], cwd=project_root, check=False)
        if wt_path.exists():
            import shutil
            shutil.rmtree(wt_path, ignore_errors=True)
    print(f"worktree sprint-{sprint_num} removed")


def cmd_list(project_root: Path, args: list[str]) -> None:
    """list — list all git worktrees (including the main tree)"""
    if not is_git_repo(project_root):
        die(f"not a git repo: {project_root}")
    result = git(["worktree", "list"], cwd=project_root, check=False)
    sys.stdout.write(result.stdout)


def cmd_ensure_gitignore(project_root: Path, args: list[str]) -> None:
    """ensure-gitignore — append .worktrees/ to .gitignore if missing"""
    gitignore = project_root / ".gitignore"
    entry = ".worktrees/"

    existing = ""
    if gitignore.exists():
        try:
            existing = gitignore.read_text()
        except OSError:
            existing = ""

    # Already present? Match exact line or .worktrees with/without trailing slash.
    for line in existing.splitlines():
        stripped = line.strip()
        if stripped in {".worktrees", ".worktrees/", ".worktrees/*"}:
            print("already present")
            return

    # Append with a leading newline if the file doesn't end with one.
    to_write = existing
    if to_write and not to_write.endswith("\n"):
        to_write += "\n"
    # Add a comment marker so future readers know why this is here.
    to_write += "\n# autonomous-skill per-sprint worktrees\n"
    to_write += entry + "\n"

    try:
        gitignore.write_text(to_write)
    except OSError as exc:
        die(f"failed to update .gitignore: {exc}")
    print("added")


def cmd_prune(project_root: Path, args: list[str]) -> None:
    """prune — `git worktree prune` (remove stale admin entries)"""
    if not is_git_repo(project_root):
        die(f"not a git repo: {project_root}")
    result = git(["worktree", "prune", "-v"], cwd=project_root, check=False)
    sys.stdout.write(result.stdout)


def cmd_path(project_root: Path, args: list[str]) -> None:
    """path <sprint-num> — print the absolute path for a sprint's worktree"""
    if not args:
        die("Usage: worktree.py path <project-root> <sprint-num>")
    try:
        sprint_num = int(args[0])
    except ValueError:
        die(f"sprint-num must be integer, got: {args[0]}")
    print(str(sprint_worktree_path(project_root, sprint_num).resolve()))


def usage() -> None:
    print(
        """Usage: worktree.py <command> <project-root> [args...]

Commands:
  create <project> <sprint-num> <branch>   Create worktree at .worktrees/sprint-N
                                           on a new branch, symlink .autonomous,
                                           print absolute path
  remove <project> <sprint-num>            Remove worktree (force); idempotent
  list <project>                           `git worktree list`
  ensure-gitignore <project>               Append .worktrees/ to .gitignore if missing
  prune <project>                          `git worktree prune -v`
  path <project> <sprint-num>              Print worktree absolute path (no side effects)

Typical flow — conductor invokes these between Plan and Dispatch:
  WT=$(python3 worktree.py create /path sprint-3 auto/session-X-sprint-3)
  python3 dispatch.py "$WT" prompt.md sprint-3
  # ... monitor + evaluate ...
  python3 worktree.py remove /path 3
""",
        file=sys.stderr,
    )


def main(argv: list[str]) -> int:
    if len(argv) <= 1 or argv[1] in {"-h", "--help", "help"}:
        usage()
        return 0

    cmd = argv[1]
    project = Path(argv[2]).resolve() if len(argv) > 2 else Path.cwd()
    args = argv[3:]

    if cmd == "create":
        cmd_create(project, args)
    elif cmd == "remove":
        cmd_remove(project, args)
    elif cmd == "list":
        cmd_list(project, args)
    elif cmd == "ensure-gitignore":
        cmd_ensure_gitignore(project, args)
    elif cmd == "prune":
        cmd_prune(project, args)
    elif cmd == "path":
        cmd_path(project, args)
    else:
        die(f"Unknown command: {cmd}. Use: create|remove|list|ensure-gitignore|prune|path")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
