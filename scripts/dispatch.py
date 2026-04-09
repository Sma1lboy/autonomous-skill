#!/usr/bin/env python3
"""Launch claude sessions via tmux or headless background."""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


def tmux_available() -> bool:
    return (
        shutil.which("tmux") is not None
        and subprocess.run(
            ["tmux", "info"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
        == 0
    )


def create_wrapper(project_dir: Path, prompt_file: Path, window: str) -> Path:
    wrapper = project_dir / ".autonomous" / f"run-{window}.sh"
    wrapper.parent.mkdir(exist_ok=True)
    content = (
        "#!/bin/bash\n"
        f"cd \"{project_dir}\"\n"
        f"PROMPT=$(cat \"{prompt_file}\")\n"
        "exec claude --dangerously-skip-permissions \"$PROMPT\"\n"
    )
    wrapper.write_text(content)
    wrapper.chmod(0o755)
    return wrapper


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Dispatch claude session")
    parser.add_argument("project_dir")
    parser.add_argument("prompt_file")
    parser.add_argument("window_name")
    args = parser.parse_args(argv[1:])

    project = Path(args.project_dir).resolve()
    prompt = Path(args.prompt_file).resolve()
    if not prompt.exists():
        print(f"ERROR: Prompt file not found: {prompt}", file=sys.stderr)
        return 1

    wrapper = create_wrapper(project, prompt, args.window_name)

    env_mode = os.environ.get("DISPATCH_MODE", "").lower()

    if env_mode == "blocking":
        print("DISPATCH_MODE=blocking")
        print(f"Running '{args.window_name}' (blocking)...")
        result = subprocess.run(["bash", str(wrapper)], check=False)
        print(f"Finished with exit code {result.returncode}")
    elif tmux_available() and env_mode != "headless":
        subprocess.run(
            ["tmux", "new-window", "-n", args.window_name, f"bash {wrapper}"],
            check=False,
        )
        print("DISPATCH_MODE=tmux")
        print(f"Launched in tmux window '{args.window_name}'")
    else:
        log_file = project / ".autonomous" / f"{args.window_name}-output.log"
        log_file.parent.mkdir(exist_ok=True)
        with open(log_file, "w") as log:
            proc = subprocess.Popen(["bash", str(wrapper)], stdout=log, stderr=log)
        print("DISPATCH_MODE=headless")
        print(f"DISPATCH_PID={proc.pid}")
        print(f"PID: {proc.pid}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
