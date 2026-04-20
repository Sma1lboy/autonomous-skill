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

Safety invariants (enforced, see codex review on PR #55):
- `.worktrees/` and `.autonomous/` in the project root must be real
  directories, not symlinks. A symlink would let `git worktree add` and
  the symlink target resolution escape the project.
- `remove` always validates the target is a real git worktree under the
  project's `.worktrees/`. Never delegates to `rmtree` against arbitrary paths.
- Branch name must pass `git check-ref-format --branch`.
- Sprint number must be a positive integer (not 0, not negative).
"""
from __future__ import annotations

import os
import re
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


def _assert_real_dir(path: Path, label: str) -> None:
    """Refuse to proceed if `path` exists and is a symlink (not a real dir).
    Prevents an attacker or accident from making `.worktrees/` or
    `.autonomous/` point outside the repo so subsequent file ops escape."""
    if path.exists() and path.is_symlink():
        die(f"{label} is a symlink — refusing to operate ({path} -> {os.readlink(path)})")


def _validate_sprint_num(raw: str) -> int:
    """Parse and validate sprint number. Must be a positive integer so
    path composition (`sprint-{n}`) can't produce oddities like `sprint--1`
    or `sprint-0` that collide with manual work."""
    try:
        n = int(raw)
    except ValueError:
        die(f"sprint-num must be integer, got: {raw}")
    if n < 1:
        die(f"sprint-num must be >= 1, got: {n}")
    return n


def _validate_branch_name(name: str, project_root: Path) -> None:
    """Ensure branch name is safe for git. Uses git's own validator to
    reject control chars, leading `-`, whitespace, reserved sequences, etc."""
    if not name.strip():
        die("branch-name is required")
    result = subprocess.run(
        ["git", "check-ref-format", "--branch", name],
        cwd=project_root,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        die(f"invalid branch name '{name}': {result.stderr.strip() or 'rejected by git check-ref-format'}")


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
    sprint_num = _validate_sprint_num(args[0])
    branch_name = args[1]

    if not is_git_repo(project_root):
        die(f"not a git repo: {project_root}")
    _validate_branch_name(branch_name, project_root)

    # Refuse to operate if .worktrees/ or .autonomous/ are pre-existing
    # symlinks — they'd escape the repo via git's followed-path writes.
    worktrees_dir = worktree_root(project_root)
    _assert_real_dir(worktrees_dir, ".worktrees")
    _assert_real_dir(project_root / ".autonomous", ".autonomous")

    wt_path = sprint_worktree_path(project_root, sprint_num)
    worktrees_dir.mkdir(exist_ok=True)

    # Prune stale entries before creating a new one. Harmless if nothing is stale.
    git(["worktree", "prune"], cwd=project_root, check=False)

    if wt_path.exists() or wt_path.is_symlink():
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
    # Target is the literal project_root/.autonomous (NOT resolved) so
    # redirection via a malicious .autonomous → /elsewhere is not silently
    # propagated into every worktree.
    main_autonomous = project_root / ".autonomous"
    _assert_real_dir(main_autonomous, ".autonomous (re-check post-mkdir)")
    try:
        main_autonomous.mkdir(exist_ok=True)
    except FileExistsError:
        pass

    worktree_autonomous = wt_path / ".autonomous"
    # A fresh worktree shouldn't have .autonomous (gitignored), but git may
    # carry it through if a previous tree left a symlink. Remove defensively.
    if worktree_autonomous.is_symlink() or worktree_autonomous.exists():
        if worktree_autonomous.is_symlink() or worktree_autonomous.is_file():
            worktree_autonomous.unlink()
        else:
            import shutil
            shutil.rmtree(worktree_autonomous)
    worktree_autonomous.symlink_to(main_autonomous, target_is_directory=True)

    print(str(wt_path.resolve()))


def cmd_remove(project_root: Path, args: list[str]) -> None:
    """remove <sprint-num>"""
    if not args:
        die("Usage: worktree.py remove <project-root> <sprint-num>")
    sprint_num = _validate_sprint_num(args[0])

    if not is_git_repo(project_root):
        die(f"not a git repo: {project_root}")

    wt_path = sprint_worktree_path(project_root, sprint_num)

    if not wt_path.exists():
        # Idempotent: nothing to remove.
        git(["worktree", "prune"], cwd=project_root, check=False)
        print(f"worktree sprint-{sprint_num} not present (nothing to remove)")
        return

    # Confirm this path is actually a git worktree known to the repo. Refuse
    # to delete arbitrary directories even if they happen to live at
    # .worktrees/sprint-N. This prevents the remove fallback from rmtree'ing
    # user data that ended up at that path by accident.
    list_result = git(["worktree", "list", "--porcelain"], cwd=project_root, check=False)
    known_paths: set[str] = set()
    for raw in list_result.stdout.splitlines():
        if raw.startswith("worktree "):
            known_paths.add(raw[len("worktree "):].strip())
    if str(wt_path.resolve()) not in known_paths and str(wt_path) not in known_paths:
        die(
            f"refusing to remove: {wt_path} is not a registered git worktree. "
            "If this is stale state, delete it manually."
        )

    # Unlink the .autonomous symlink so git worktree remove doesn't follow
    # it into the main tree. Only unlink if it really is a symlink (never a
    # real directory — that would mean state split already happened).
    wt_autonomous = wt_path / ".autonomous"
    autonomous_unlinked = False
    if wt_autonomous.is_symlink():
        wt_autonomous.unlink()
        autonomous_unlinked = True

    # --force removes even if the worktree has uncommitted changes. By the
    # time conductor calls remove(), evaluate-sprint has already read the
    # summary, so any dirty state in the worktree is disposable.
    result = git(
        ["worktree", "remove", "--force", str(wt_path)],
        cwd=project_root,
        check=False,
    )
    success = result.returncode == 0
    if not success:
        # Git refused to remove. Try pruning and cleaning up the directory,
        # but ONLY if it's still under .worktrees/ (sanity re-check — the
        # earlier registered-worktree check already validated this).
        git(["worktree", "prune"], cwd=project_root, check=False)
        if wt_path.exists():
            resolved = wt_path.resolve()
            expected_parent = worktree_root(project_root).resolve()
            try:
                resolved.relative_to(expected_parent)
            except ValueError:
                die(f"refusing to rmtree: {resolved} is not under {expected_parent}")
            import shutil
            shutil.rmtree(wt_path, ignore_errors=True)
            success = not wt_path.exists()

    # Restore the .autonomous symlink if we unlinked it but removal failed;
    # otherwise the worktree is in a state-split condition (present without
    # the symlink, so any .autonomous created locally is divergent data).
    if not success and autonomous_unlinked and wt_path.exists():
        try:
            wt_autonomous.symlink_to(project_root / ".autonomous", target_is_directory=True)
        except OSError:
            pass
        die(f"worktree remove failed: {result.stderr.strip() or result.stdout.strip()}")

    if success:
        print(f"worktree sprint-{sprint_num} removed")
    else:
        die(f"worktree remove failed: {result.stderr.strip() or result.stdout.strip()}")


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
