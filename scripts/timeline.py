#!/usr/bin/env python3
"""Append-only session event log for autonomous-skill.

Writes JSONL events to .autonomous/timeline.jsonl across sessions. Used for
post-hoc inspection ("what happened in session X?"), future analytics, and
debugging phase transitions or sprint failures.

Append-only; never truncates. Writes use O_APPEND; individual writes smaller
than the OS page size are generally seen as atomic by concurrent readers on
local filesystems (no guarantee on NFS). This is best-effort logging — if
interleaved or partially-written lines appear, `iter_events()` skips the
malformed entries. The API is deliberately non-raising: `emit()` always
returns a bool, never raises `SystemExit` or propagates errors, so conductor
integrations cannot be killed by a bad event name or a full disk.
"""
from __future__ import annotations

import json
import os
import sys
import time
from collections import deque
from pathlib import Path
from typing import Any, NoReturn

VALID_EVENTS = {
    "session-start",
    "session-end",
    "sprint-start",
    "sprint-end",
    "phase-transition",
    "intercept",  # reserved for future use
    "note",       # free-form annotation
}


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_session_id(project_dir: Path) -> str | None:
    state_file = project_dir / ".autonomous" / "conductor-state.json"
    if not state_file.exists():
        return None
    try:
        data = json.loads(state_file.read_text())
        sid = data.get("session_id")
        return sid if isinstance(sid, str) and sid else None
    except (json.JSONDecodeError, OSError):
        return None


def timeline_path(project_dir: Path) -> Path:
    return project_dir / ".autonomous" / "timeline.jsonl"


def emit(
    project_dir: Path,
    event: str,
    session_id: str | None = None,
    **fields: Any,
) -> bool:
    """Append a single event line. Returns True on success, False on any
    error (unknown event, OS error, encoding failure, etc.). Never raises.

    The conductor relies on this contract: an unknown event name is a bug we
    want to notice in tests, not a crash that kills an in-flight sprint.
    The CLI path (`cmd_emit`) still validates loudly via `die()`.
    """
    if event not in VALID_EVENTS:
        return False

    try:
        state_dir = project_dir / ".autonomous"
        state_dir.mkdir(parents=True, exist_ok=True)

        record: dict[str, Any] = {
            "ts": now_iso(),
            "session_id": session_id if session_id is not None else read_session_id(project_dir),
            "event": event,
        }
        record.update(fields)

        line = json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n"
        path = timeline_path(project_dir)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line)
        return True
    except (OSError, TypeError, ValueError):
        return False


def parse_kv_args(args: list[str]) -> dict[str, Any]:
    """Parse `key=value` CLI args. Values are JSON-decoded when possible
    (so `count=3` is int 3, `ok=true` is bool, `note="hello"` is str)."""
    result: dict[str, Any] = {}
    for item in args:
        if "=" not in item:
            die(f"expected key=value, got: {item}")
        key, _, raw = item.partition("=")
        if not key:
            die(f"empty key in: {item}")
        try:
            result[key] = json.loads(raw)
        except (json.JSONDecodeError, ValueError):
            result[key] = raw
    return result


def cmd_emit(project: Path, args: list[str]) -> None:
    if not args:
        die("Usage: timeline.py emit <project-dir> <event> [key=value ...]")
    event = args[0]
    if event not in VALID_EVENTS:
        die(f"Unknown event: {event} (valid: {', '.join(sorted(VALID_EVENTS))})")
    extras = parse_kv_args(args[1:])
    ok = emit(project, event, **extras)
    print("ok" if ok else "silent-fail")


def iter_events(project: Path):
    path = timeline_path(project)
    if not path.exists():
        return
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for raw in handle:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    yield json.loads(raw)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return


def cmd_tail(project: Path, args: list[str]) -> None:
    n_raw = args[0] if args else "20"
    try:
        n = int(n_raw)
    except ValueError:
        die(f"N must be integer, got: {n_raw}")
    if n <= 0:
        die(f"N must be positive, got: {n}")

    # Bounded memory: keep only the last N events, not the whole log.
    last_n: deque[dict[str, Any]] = deque(maxlen=n)
    for record in iter_events(project):
        last_n.append(record)
    for record in last_n:
        print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))


def cmd_list(project: Path, args: list[str]) -> None:
    """Optional filters: --session <id>, --event <name>."""
    session_filter: str | None = None
    event_filter: str | None = None
    i = 0
    while i < len(args):
        flag = args[i]
        if flag == "--session":
            if i + 1 >= len(args):
                die("--session requires a value")
            session_filter = args[i + 1]
            i += 2
        elif flag == "--event":
            if i + 1 >= len(args):
                die("--event requires a value")
            event_filter = args[i + 1]
            i += 2
        else:
            die(f"Unknown flag: {flag} (valid: --session, --event)")

    for record in iter_events(project):
        if session_filter is not None and record.get("session_id") != session_filter:
            continue
        if event_filter is not None and record.get("event") != event_filter:
            continue
        print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))


def cmd_sessions(project: Path) -> None:
    """Print a distinct list of session_ids seen in the timeline, oldest first."""
    seen: list[str] = []
    found: set[str] = set()
    for record in iter_events(project):
        sid = record.get("session_id")
        if sid and sid not in found:
            found.add(sid)
            seen.append(sid)
    for sid in seen:
        print(sid)


def usage() -> None:
    print(
        """Usage: timeline.py <command> <project-dir> [args...]

Commands:
  emit <project> <event> [k=v ...]   Append an event (auto-fills ts, session_id)
  tail <project> [N]                 Show last N events (default 20)
  list <project> [--session ID] [--event NAME]
                                     Filter + dump events
  sessions <project>                 List distinct session IDs seen

Events: session-start, session-end, sprint-start, sprint-end,
        phase-transition, intercept, note

Examples:
  python3 timeline.py emit . sprint-start sprint=3 direction='"add auth"'
  python3 timeline.py tail . 50
  python3 timeline.py list . --event sprint-end
""",
        file=sys.stderr,
    )


def main(argv: list[str]) -> int:
    if len(argv) <= 1 or argv[1] in {"-h", "--help", "help"}:
        usage()
        return 0

    cmd = argv[1]
    project = Path(argv[2]) if len(argv) > 2 else Path(".")
    args = argv[3:]

    if cmd == "emit":
        cmd_emit(project, args)
    elif cmd == "tail":
        cmd_tail(project, args)
    elif cmd == "list":
        cmd_list(project, args)
    elif cmd == "sessions":
        cmd_sessions(project)
    else:
        die(f"Unknown command: {cmd}. Use: emit|tail|list|sessions")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
