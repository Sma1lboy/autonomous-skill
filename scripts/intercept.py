#!/usr/bin/env python3
"""User intercept queue for autonomous-skill.

Lets an external actor (user in another terminal, another agent, a cron job,
etc.) inject directives or pause requests into a running session. The conductor
consumes them at the start of each sprint's Plan phase.

Stored in .autonomous/intercept.json, independent of conductor-state.json to
avoid the PID lock on that file. mkdir-based atomic lock allows concurrent
writers (user + conductor).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sys
import time
from pathlib import Path
from typing import Any, NoReturn

VALID_TYPES = {"directive", "pause"}
VALID_STATUS = {"pending", "consumed", "cleared"}
MAX_DIRECTIVE_LEN = 2000


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def sanitize(text: str, limit: int = MAX_DIRECTIVE_LEN) -> str:
    cleaned = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
    return cleaned[:limit]


class InterceptLock:
    def __init__(self, lock_dir: Path) -> None:
        self.lock_dir = lock_dir
        self.pid_file = lock_dir / "pid"
        self.acquired = False

    def acquire(self) -> None:
        deadline = time.time() + 2
        while True:
            try:
                self.lock_dir.mkdir(parents=True, exist_ok=False)
                self.pid_file.write_text(str(os.getpid()))
                self.acquired = True
                return
            except FileExistsError:
                if time.time() >= deadline:
                    pid = None
                    if self.pid_file.exists():
                        try:
                            pid = int(self.pid_file.read_text().strip())
                        except ValueError:
                            pid = None
                    if pid and pid_alive(pid):
                        die(f"Intercept queue locked by PID {pid}")
                    shutil.rmtree(self.lock_dir, ignore_errors=True)
                    continue
                time.sleep(0.1)

    def release(self) -> None:
        if self.acquired:
            shutil.rmtree(self.lock_dir, ignore_errors=True)
            self.acquired = False

    def __enter__(self) -> "InterceptLock":
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.release()


class InterceptManager:
    def __init__(self, project_dir: Path) -> None:
        self.project = project_dir
        self.state_dir = self.project / ".autonomous"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.queue_file = self.state_dir / "intercept.json"
        self.conductor_state_file = self.state_dir / "conductor-state.json"
        self.lock = InterceptLock(self.state_dir / "intercept.lock")

    def load(self) -> dict[str, Any]:
        if not self.queue_file.exists():
            return {"version": 1, "items": []}
        try:
            data = json.loads(self.queue_file.read_text())
            if not isinstance(data, dict) or "items" not in data:
                return {"version": 1, "items": []}
            return data
        except (json.JSONDecodeError, OSError):
            return {"version": 1, "items": []}

    def save(self, data: dict[str, Any]) -> None:
        tmp = self.queue_file.with_suffix(
            self.queue_file.suffix + f".tmp.{os.getpid()}"
        )
        tmp.write_text(json.dumps(data, indent=2))
        tmp.replace(self.queue_file)

    def current_session_id(self) -> str | None:
        if not self.conductor_state_file.exists():
            return None
        try:
            data = json.loads(self.conductor_state_file.read_text())
            sid = data.get("session_id")
            return sid if isinstance(sid, str) and sid else None
        except (json.JSONDecodeError, OSError):
            return None


def _next_item_id(items: list[dict[str, Any]]) -> str:
    ts = int(time.time())
    return f"int-{ts}-{len(items) + 1}"


def _is_current_scope(item: dict[str, Any], session_id: str | None) -> bool:
    """An item is consumable if it matches the current session, or if it has
    no session binding (queued before any session started)."""
    item_session = item.get("session_id")
    if item_session is None:
        return True
    return item_session == session_id


def cmd_add(manager: InterceptManager, args: list[str]) -> None:
    if not args:
        die("Usage: intercept.py add <project-dir> <directive>")
    directive = sanitize(args[0])
    if not directive.strip():
        die("directive is required")

    with manager.lock:
        state = manager.load()
        items = state.setdefault("items", [])
        item_id = _next_item_id(items)
        items.append(
            {
                "id": item_id,
                "type": "directive",
                "directive": directive,
                "status": "pending",
                "session_id": manager.current_session_id(),
                "created_at": now_iso(),
                "consumed_at": None,
                "consumed_in_sprint": None,
            }
        )
        manager.save(state)
    print(item_id)


def cmd_pause(manager: InterceptManager, args: list[str]) -> None:
    note = sanitize(args[0]) if args else ""

    with manager.lock:
        state = manager.load()
        items = state.setdefault("items", [])
        item_id = _next_item_id(items)
        items.append(
            {
                "id": item_id,
                "type": "pause",
                "directive": note,
                "status": "pending",
                "session_id": manager.current_session_id(),
                "created_at": now_iso(),
                "consumed_at": None,
                "consumed_in_sprint": None,
            }
        )
        manager.save(state)
    print(item_id)


def cmd_list(manager: InterceptManager, args: list[str]) -> None:
    scope = args[0] if args else "pending"
    if scope not in {"pending", "consumed", "cleared", "all"}:
        die(f"Invalid scope: {scope} (valid: pending, consumed, cleared, all)")

    state = manager.load()
    items = state.get("items", [])
    if scope != "all":
        items = [item for item in items if item.get("status") == scope]
    print(json.dumps(items, indent=2))


def cmd_status(manager: InterceptManager) -> None:
    """One-line summary for the conductor's quick check. Counts only items
    that are pending AND belong to the current session (or unbound)."""
    state = manager.load()
    session_id = manager.current_session_id()
    pending = [
        item
        for item in state.get("items", [])
        if item.get("status") == "pending" and _is_current_scope(item, session_id)
    ]
    if not pending:
        print("none")
        return
    pause_count = sum(1 for item in pending if item.get("type") == "pause")
    directive_count = len(pending) - pause_count
    parts = []
    if directive_count:
        parts.append(f"{directive_count} directive")
    if pause_count:
        parts.append(f"{pause_count} pause")
    print(" + ".join(parts))


def cmd_consume(manager: InterceptManager, args: list[str]) -> None:
    """Atomically mark pending items in the current session as consumed and
    emit them as a JSON array. The conductor reads this to decide what to do."""
    sprint_num: int | None
    if args:
        try:
            sprint_num = int(args[0])
        except ValueError:
            die(f"sprint-num must be an integer, got: {args[0]}")
    else:
        sprint_num = None

    with manager.lock:
        state = manager.load()
        session_id = manager.current_session_id()
        now = now_iso()
        consumed: list[dict[str, Any]] = []
        for item in state.get("items", []):
            if item.get("status") != "pending":
                continue
            if not _is_current_scope(item, session_id):
                continue
            item["status"] = "consumed"
            item["consumed_at"] = now
            item["consumed_in_sprint"] = sprint_num
            consumed.append(dict(item))
        manager.save(state)

    print(json.dumps(consumed, indent=2))


def cmd_clear(manager: InterceptManager) -> None:
    with manager.lock:
        state = manager.load()
        session_id = manager.current_session_id()
        now = now_iso()
        cleared = 0
        for item in state.get("items", []):
            if item.get("status") == "pending" and _is_current_scope(item, session_id):
                item["status"] = "cleared"
                item["consumed_at"] = now
                cleared += 1
        manager.save(state)
    print(f"cleared: {cleared}")


def usage() -> None:
    print(
        """Usage: intercept.py <command> <project-dir> [args...]

Commands:
  add <project> <directive>   Queue a directive to merge into the next sprint
  pause <project> [note]      Queue a pause request (conductor will stop and ask)
  list <project> [scope]      List items (scope: pending|consumed|cleared|all, default pending)
  status <project>            One-line summary ("none" or "N directive + M pause")
  consume <project> [sprint]  Mark current-session pending items consumed, emit JSON
  clear <project>             Mark current-session pending items cleared

Typical workflow — user in another terminal interrupts a running session:
  cd /path/to/project
  python3 scripts/intercept.py add . "focus on the auth bug first"
  python3 scripts/intercept.py pause . "I need to think about the design"
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
    manager = InterceptManager(project)

    if cmd == "add":
        cmd_add(manager, args)
    elif cmd == "pause":
        cmd_pause(manager, args)
    elif cmd == "list":
        cmd_list(manager, args)
    elif cmd == "status":
        cmd_status(manager)
    elif cmd == "consume":
        cmd_consume(manager, args)
    elif cmd == "clear":
        cmd_clear(manager)
    else:
        die(f"Unknown command: {cmd}. Use: add|pause|list|status|consume|clear")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
