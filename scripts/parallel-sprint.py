#!/usr/bin/env python3
"""V2 parallel sprint orchestrator.

Gated by `experimental.parallel_sprints=true` + `mode.worktrees=true`. Runs
K sprints concurrently in isolated worktrees, then merges them serially
into the session branch.

Flow:
  1. Input: session_branch + JSON array of K sprint directions
  2. For each sprint i in 1..K:
       - Create worktree at .worktrees/sprint-{i} (via worktree.py)
       - Build sprint prompt (via build-sprint-prompt.py)
       - Dispatch headless claude -p (via dispatch.py, DISPATCH_MODE=headless)
  3. Wait until all K sprint-{i}-summary.json files exist (or timeout)
  4. Merge in order 1..K, serially:
       - Successful merge: remove worktree, delete branch
       - Failed merge (conflicts): abort wave, preserve remaining worktrees
         + branches for inspection
  5. Emit a summary JSON with per-sprint status

Design notes / known limits (V2 — experimental):
- Relies on the conductor (an LLM) to plan DISJOINT directions. No
  automated file-overlap check yet — that's a follow-up.
- Merge is strictly in-order: the first conflict blocks all later sprints
  in the wave. This keeps blame attribution simple ("sprint 3 is stuck"
  rather than "sprint 1, 3, and 5 each blocked something else").
- Worker failure != merge failure. A worker can time out / crash (no
  sprint-summary.json) and we still try to merge whatever commits it left
  on its branch before declaring it incomplete.
- Cap via `experimental.max_parallel_sprints` (default 3). Honored strictly.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, NoReturn

# Environment / config fallbacks
DEFAULT_MAX_PARALLEL = 3
DEFAULT_WAIT_TIMEOUT_S = 60 * 30  # 30 minutes per wave
POLL_INTERVAL_S = 5


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def log(message: str) -> None:
    """All logs go to stderr so stdout stays reserved for the final JSON."""
    print(f"[parallel-sprint] {message}", file=sys.stderr, flush=True)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run(cmd: list[str], *, cwd: Path | None = None, check: bool = False,
        capture: bool = False, timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=check,
        capture_output=capture,
        text=True,
        timeout=timeout,
    )


def script_dir() -> Path:
    return Path(__file__).resolve().parent


def load_user_config(project: Path, key: str) -> str:
    """Read a single config key via user-config.py. Returns the trimmed
    stdout or empty string on any failure — never raises."""
    try:
        result = run(
            [sys.executable, str(script_dir() / "user-config.py"),
             "get", key, str(project)],
            capture=True,
            timeout=10,
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, OSError):
        return ""


def _max_parallel(project: Path, cli_override: int | None) -> int:
    if cli_override is not None:
        return max(1, cli_override)
    env_raw = os.environ.get("AUTONOMOUS_MAX_PARALLEL_SPRINTS", "")
    if env_raw.isdigit():
        return max(1, int(env_raw))
    cfg = load_user_config(project, "experimental.max_parallel_sprints")
    if cfg.isdigit():
        return max(1, int(cfg))
    return DEFAULT_MAX_PARALLEL


def _gated(project: Path) -> tuple[bool, str]:
    """Return (ok, reason). The orchestrator refuses to run unless both
    the parallel flag AND worktree mode are on — parallel only makes
    sense with file isolation."""
    parallel = load_user_config(project, "experimental.parallel_sprints")
    if parallel != "true":
        return False, (
            "experimental.parallel_sprints is not enabled (set via "
            "`user-config.py set experimental.parallel_sprints true --scope global`)"
        )
    worktrees = load_user_config(project, "mode.worktrees")
    if worktrees != "true":
        return False, (
            "mode.worktrees is required for parallel sprints (set via "
            "`user-config.py set mode.worktrees true --scope global`). "
            "Without worktrees every sprint would fight for the same working tree."
        )
    return True, "ok"


def create_worktree(project: Path, sprint_num: int, branch: str) -> Path:
    result = run(
        [sys.executable, str(script_dir() / "worktree.py"),
         "create", str(project), str(sprint_num), branch],
        capture=True,
        timeout=30,
    )
    if result.returncode != 0:
        die(f"worktree create failed for sprint {sprint_num}: "
            f"{result.stderr.strip() or result.stdout.strip()}")
    return Path(result.stdout.strip())


def build_prompt(project: Path, script_root: Path, sprint_num: int,
                 direction: str, prev_summary: str) -> None:
    result = run(
        [sys.executable, str(script_root / "scripts" / "build-sprint-prompt.py"),
         str(project), str(script_root), str(sprint_num), direction, prev_summary],
        capture=True,
        timeout=30,
    )
    if result.returncode != 0:
        die(f"build-sprint-prompt failed for sprint {sprint_num}: "
            f"{result.stderr.strip() or result.stdout.strip()}")


def dispatch_headless(worktree: Path, prompt_path: Path, window: str) -> int:
    """Dispatch claude -p in headless (background) mode. Returns the PID
    of the wrapper script process for optional aliveness checks."""
    env = os.environ.copy()
    env["DISPATCH_MODE"] = "headless"
    result = subprocess.run(
        [sys.executable, str(script_dir() / "dispatch.py"),
         str(worktree), str(prompt_path), window],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )
    if result.returncode != 0:
        die(f"dispatch failed for {window}: "
            f"{result.stderr.strip() or result.stdout.strip()}")
    # dispatch.py prints "DISPATCH_PID=<n>" — parse it out.
    for line in result.stdout.splitlines():
        if line.startswith("DISPATCH_PID="):
            try:
                return int(line.split("=", 1)[1].strip())
            except ValueError:
                pass
    return 0  # PID unknown; we'll still see the summary file when worker finishes


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def wait_for_all(project: Path, sprint_nums: list[int], pids: dict[int, int],
                 timeout_s: int) -> dict[int, str]:
    """Poll for sprint-{n}-summary.json for every n in sprint_nums.
    Returns a dict mapping sprint_num → status string:
      "complete"  — summary JSON written, status=complete|partial
      "crashed"   — no summary AND no alive PID
      "timeout"   — neither summary nor crash detection by deadline
    """
    deadline = time.time() + timeout_s
    pending = set(sprint_nums)
    status: dict[int, str] = {}

    autonomous = project / ".autonomous"

    while pending and time.time() < deadline:
        for n in list(pending):
            summary_path = autonomous / f"sprint-{n}-summary.json"
            if summary_path.exists():
                status[n] = "complete"
                pending.discard(n)
                log(f"sprint {n}: summary detected")
                continue
            pid = pids.get(n, 0)
            if pid and not pid_alive(pid):
                # Process gone but no summary — worker crashed or exited early.
                status[n] = "crashed"
                pending.discard(n)
                log(f"sprint {n}: PID {pid} gone without summary")
        if pending:
            time.sleep(POLL_INTERVAL_S)

    for n in pending:
        status[n] = "timeout"
        log(f"sprint {n}: timed out after {timeout_s}s")
    return status


def read_summary(project: Path, sprint_num: int) -> dict[str, Any]:
    path = project / ".autonomous" / f"sprint-{sprint_num}-summary.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def merge_in_order(project: Path, session_branch: str,
                   sprints: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Serially merge each sprint. First merge-conflict aborts the wave
    so the remaining worktrees/branches stay intact for inspection.

    Returns a list of result dicts in the input order.
    """
    results: list[dict[str, Any]] = []
    aborted = False

    for sprint in sprints:
        n = sprint["number"]
        branch = sprint["branch"]
        status = sprint["status"]
        if aborted:
            results.append({**sprint, "merged": False, "reason": "wave-aborted"})
            continue

        summary = read_summary(project, n)
        worker_status = summary.get("status", status or "unknown")
        worker_summary = summary.get("summary", "")
        commits = summary.get("commits", [])
        commits_json = json.dumps(commits if isinstance(commits, list) else [])

        merge_result = run(
            [sys.executable, str(script_dir() / "merge-sprint.py"),
             "--keep-branch", session_branch, branch, str(n),
             worker_status, worker_summary, "--project-dir", str(project)],
            timeout=120,
        )

        if merge_result.returncode != 0:
            log(f"sprint {n}: merge FAILED — preserving worktree + branch")
            results.append({**sprint, "merged": False, "reason": "merge-conflict"})
            aborted = True
            continue

        # Merge succeeded → tear down worktree + branch for this sprint.
        run(
            [sys.executable, str(script_dir() / "worktree.py"),
             "remove", str(project), str(n)],
            timeout=30,
        )
        run(
            ["git", "branch", "-D", branch],
            cwd=project,
            timeout=10,
        )
        log(f"sprint {n}: merged + cleaned up")
        # Keep commit_count etc. for the final summary
        _ = commits_json
        results.append({
            **sprint,
            "merged": True,
            "commit_count": len(commits) if isinstance(commits, list) else 0,
        })

    return results


def cmd_run(args: argparse.Namespace) -> int:
    project = Path(args.project).resolve()
    script_root = Path(args.script_root).resolve()

    ok, reason = _gated(project)
    if not ok:
        die(reason)

    # Parse directions: --directions is a JSON array of strings
    try:
        directions = json.loads(args.directions)
    except json.JSONDecodeError as e:
        die(f"--directions must be a JSON array of strings: {e}")
    if not isinstance(directions, list) or not directions:
        die("--directions must be a non-empty JSON array")
    if not all(isinstance(d, str) and d.strip() for d in directions):
        die("all directions must be non-empty strings")

    max_parallel = _max_parallel(project, args.max_parallel)
    if len(directions) > max_parallel:
        die(
            f"requested {len(directions)} parallel sprints but max is "
            f"{max_parallel} (configure via "
            f"`experimental.max_parallel_sprints` or --max-parallel)"
        )

    session_branch = args.session_branch
    start_num = args.start_sprint_num
    timeout_s = args.timeout or DEFAULT_WAIT_TIMEOUT_S

    # ── Plan: assign sprint numbers + branch names ──────────────────────
    sprints: list[dict[str, Any]] = []
    for i, direction in enumerate(directions):
        n = start_num + i
        sprints.append({
            "number": n,
            "direction": direction,
            "branch": f"{session_branch}-sprint-{n}",
            "worktree": None,
            "pid": 0,
        })

    log(f"planning wave: {len(sprints)} sprints ({start_num}..{start_num + len(sprints) - 1})")

    # ── Create + dispatch ──────────────────────────────────────────────
    pids: dict[int, int] = {}
    for s in sprints:
        n = s["number"]
        wt = create_worktree(project, n, s["branch"])
        s["worktree"] = str(wt)
        # Build prompt against main tree's .autonomous (sprint-prompt.md is
        # overwritten each build; in parallel mode we need a per-sprint
        # prompt file, otherwise sprints race on the same file).
        build_prompt(project, script_root, n, s["direction"], "")
        # Copy the just-built prompt to a per-sprint filename so the next
        # build doesn't clobber it before dispatch reads it.
        per_sprint_prompt = project / ".autonomous" / f"sprint-{n}-prompt.md"
        shared = project / ".autonomous" / "sprint-prompt.md"
        if shared.exists():
            per_sprint_prompt.write_text(shared.read_text(), encoding="utf-8")

        pid = dispatch_headless(wt, per_sprint_prompt, f"sprint-{n}")
        pids[n] = pid
        s["pid"] = pid
        log(f"sprint {n}: dispatched (pid={pid}, worktree={wt})")

    # ── Monitor ────────────────────────────────────────────────────────
    log(f"waiting for {len(sprints)} sprints (timeout={timeout_s}s)...")
    worker_status = wait_for_all(project, [s["number"] for s in sprints], pids, timeout_s)
    for s in sprints:
        s["status"] = worker_status.get(s["number"], "unknown")

    # ── Merge serially ─────────────────────────────────────────────────
    log("all workers settled; merging in order")
    results = merge_in_order(project, session_branch, sprints)

    # ── Emit summary (stdout, machine-readable) ───────────────────────
    report = {
        "wave_start_sprint": start_num,
        "wave_end_sprint": start_num + len(sprints) - 1,
        "sprints": results,
        "merged": [r["number"] for r in results if r.get("merged")],
        "blocked": [r["number"] for r in results if not r.get("merged")],
        "finished_at": now_iso(),
    }
    print(json.dumps(report, indent=2))
    # Non-zero if anything got blocked so the conductor can notice via $?
    return 0 if not report["blocked"] else 2


def cmd_check(args: argparse.Namespace) -> int:
    """Print 'ok' if gating conditions are met, otherwise print the reason
    to stderr and exit 1. Used by SKILL.md before it tries to plan a wave."""
    project = Path(args.project).resolve()
    ok, reason = _gated(project)
    if ok:
        print("ok")
        return 0
    print(reason, file=sys.stderr)
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="parallel-sprint.py",
        description="V2 parallel sprint orchestrator (experimental).",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser(
        "check",
        help="verify parallel gating (experimental.parallel_sprints + mode.worktrees both on)",
    )
    p_check.add_argument("project")
    p_check.set_defaults(func=cmd_check)

    p_run = sub.add_parser("run", help="dispatch K sprints concurrently")
    p_run.add_argument("project")
    p_run.add_argument("script_root", help="skill root (contains scripts/, templates/)")
    p_run.add_argument("session_branch")
    p_run.add_argument("start_sprint_num", type=int)
    p_run.add_argument(
        "--directions",
        required=True,
        help="JSON array of sprint direction strings",
    )
    p_run.add_argument(
        "--max-parallel",
        type=int,
        default=None,
        help="cap concurrent sprints (default from config / env / 3)",
    )
    p_run.add_argument(
        "--timeout",
        type=int,
        default=None,
        help="max seconds to wait for all sprints (default 1800)",
    )
    p_run.set_defaults(func=cmd_run)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv[1:])
    return args.func(args) or 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
