#!/usr/bin/env python3
"""Create session branch, init conductor state + backlog."""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


def run(cmd: list[str], cwd: Path, *, check: bool = True, quiet: bool = False) -> None:
    kwargs: dict[str, Any] = {"cwd": cwd, "check": check}
    if quiet:
        kwargs["stdout"] = subprocess.DEVNULL
    subprocess.run(cmd, **kwargs)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Create session branch and initialize conductor state/backlog."
    )
    parser.add_argument("project_dir", help="Path to the project directory")
    parser.add_argument("script_dir", help="Path to the skill directory")
    parser.add_argument("direction", nargs="?", default="", help="Initial mission")
    parser.add_argument(
        "max_sprints",
        nargs="?",
        default="10",
        help="Maximum number of sprints for this session",
    )
    args = parser.parse_args(argv[1:])

    project_dir = Path(args.project_dir).resolve()
    script_dir = Path(args.script_dir).resolve()

    session_branch = f"auto/session-{int(time.time())}"
    run(["git", "checkout", "-b", session_branch], cwd=project_dir)
    (project_dir / ".autonomous").mkdir(exist_ok=True)

    conductor = script_dir / "scripts" / "conductor-state.py"
    backlog = script_dir / "scripts" / "backlog.py"

    run(
        [
            sys.executable,
            str(conductor),
            "init",
            str(project_dir),
            args.direction,
            str(args.max_sprints),
        ],
        cwd=project_dir,
        quiet=True,
    )

    run([sys.executable, str(backlog), "init", str(project_dir)], cwd=project_dir, quiet=True)
    run(
        [sys.executable, str(backlog), "prune", str(project_dir), "30"],
        cwd=project_dir,
        check=False,
        quiet=True,
    )

    print(f"SESSION_BRANCH={session_branch}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
