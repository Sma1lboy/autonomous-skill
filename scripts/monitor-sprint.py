#!/usr/bin/env python3
"""Poll for sprint completion."""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path


def tmux_has_window(name: str) -> bool:
    if shutil.which("tmux") is None:
        return False
    result = subprocess.run(
        ["tmux", "list-windows"], capture_output=True, text=True, check=False
    )
    return result.returncode == 0 and name in result.stdout


def tmux_kill(name: str) -> None:
    if shutil.which("tmux") is None:
        return
    subprocess.run(
        ["tmux", "kill-window", "-t", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def tmux_available() -> bool:
    return shutil.which("tmux") is not None and subprocess.run(
        ["tmux", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
    ).returncode == 0


def print_summary(path: Path) -> None:
    print(f"=== SPRINT {path.stem.split('-')[1]} COMPLETE ===")
    print(path.read_text())


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Monitor sprint completion")
    parser.add_argument("project_dir")
    parser.add_argument("sprint_num")
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    summary_file = project / ".autonomous" / f"sprint-{args.sprint_num}-summary.json"
    generic = project / ".autonomous" / "sprint-summary.json"

    window_name = f"sprint-{args.sprint_num}"
    while True:
        if summary_file.exists():
            tmux_kill(window_name)
            print(f"=== SPRINT {args.sprint_num} COMPLETE ===")
            print(summary_file.read_text())
            break
        if generic.exists():
            summary_file.write_text(generic.read_text())
            generic.unlink(missing_ok=True)
            tmux_kill(window_name)
            print(f"=== SPRINT {args.sprint_num} COMPLETE ===")
            print(summary_file.read_text())
            break
        if tmux_available():
            if not tmux_has_window(window_name):
                print(f"=== SPRINT {args.sprint_num} WINDOW CLOSED ===")
                if generic.exists():
                    summary_file.write_text(generic.read_text())
                    generic.unlink(missing_ok=True)
                break
        time.sleep(8)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
