#!/usr/bin/env python3
"""Merge or discard sprint branches.

By default, the sprint branch is deleted after merge/discard. In worktree
mode (--keep-branch), the conductor is expected to delete the branch
*after* the worktree is removed, since `git branch -D` refuses to delete
a branch that's checked out in any worktree.

Exit codes:
  0 — merged, discarded (no commits), or successfully bailed without changes
  1 — merge conflict or other git failure. In worktree mode, the worktree
      should be preserved for inspection.
"""
from __future__ import annotations

import argparse
import subprocess
import sys


def run(cmd: list[str], *, cwd: str | None = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, check=check, text=True, capture_output=False)


def git_output(cmd: list[str], *, cwd: str | None = None) -> str:
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    return result.stdout.strip()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Merge sprint branch")
    parser.add_argument("session_branch")
    parser.add_argument("sprint_branch")
    parser.add_argument("sprint_num")
    parser.add_argument("status")
    parser.add_argument("summary", nargs="?", default="")
    parser.add_argument("--project-dir", default=None, help="Project directory (defaults to CWD)")
    parser.add_argument(
        "--keep-branch",
        action="store_true",
        help="Skip `git branch -D` at the end. Use in worktree mode where "
        "the worktree must be removed first before git will let us delete the branch.",
    )
    args = parser.parse_args(argv[1:])

    cwd = args.project_dir

    run(["git", "checkout", args.session_branch], cwd=cwd)

    if args.status in {"complete", "partial"}:
        commits = git_output(
            [
                "git",
                "log",
                f"{args.session_branch}..{args.sprint_branch}",
                "--oneline",
            ],
            cwd=cwd,
        )
        if commits:
            message = args.summary or f"Sprint {args.sprint_num}"
            # Use check=False here so merge conflicts don't raise — we return
            # 1 so the conductor can preserve the worktree for inspection.
            result = subprocess.run(
                [
                    "git",
                    "merge",
                    "--no-ff",
                    args.sprint_branch,
                    "-m",
                    f"sprint {args.sprint_num}: {message}",
                ],
                cwd=cwd,
                check=False,
            )
            if result.returncode != 0:
                print(
                    f"ERROR: merge of sprint {args.sprint_num} into "
                    f"{args.session_branch} failed (conflicts or git error). "
                    f"Sprint branch preserved.",
                    file=sys.stderr,
                )
                # Abort the in-progress merge so main tree is left clean.
                subprocess.run(["git", "merge", "--abort"], cwd=cwd, check=False)
                return 1
            print(f"Sprint {args.sprint_num} merged into {args.session_branch}")
        else:
            print(f"Sprint {args.sprint_num} had no commits, skipping merge")
    else:
        print(f"Sprint {args.sprint_num} discarded ({args.status})")

    if not args.keep_branch:
        subprocess.run(["git", "branch", "-D", args.sprint_branch], cwd=cwd, check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
