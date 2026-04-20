#!/usr/bin/env python3
"""Session checkpoint snapshots for autonomous-skill.

Dumps the current conductor state, sprint history, backlog summary, and git
state into a human-readable markdown file at
`.autonomous/checkpoints/<timestamp>-<slug>.md`. Useful for:

- Context switching — come back next day, read the latest checkpoint
- Sharing — send to a teammate who asks "what's the autonomous session doing?"
- Review — before resuming, confirm sprints 1-3 match what you expected

Does NOT auto-resume a session. This is a human-readable snapshot only.
Each save is a separate file; history is retained. Delete manually if needed.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, NoReturn


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def slugify(text: str, max_len: int = 40) -> str:
    text = re.sub(r"[^a-zA-Z0-9\s-]", "", text).strip().lower()
    text = re.sub(r"\s+", "-", text)
    return text[:max_len] or "checkpoint"


def read_json(path: Path) -> dict[str, Any]:
    """Load a JSON file as a dict. Returns {} on any failure — missing file,
    malformed JSON, wrong top-level type, encoding errors. Callers assume
    dict shape and use .get() extensively, so non-dict payloads must be
    filtered out here rather than crash downstream."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, FileNotFoundError, UnicodeDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def git(project: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=project,
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except (subprocess.TimeoutExpired, OSError):
        return ""


def gather_git_state(project: Path) -> dict[str, Any]:
    if not (project / ".git").exists():
        return {"is_git": False}
    current_branch = git(project, "rev-parse", "--abbrev-ref", "HEAD")
    last_commit = git(project, "log", "-1", "--oneline", "--no-decorate")
    status_porcelain = git(project, "status", "--porcelain")
    modified_count = len([line for line in status_porcelain.splitlines() if line.strip()])
    return {
        "is_git": True,
        "current_branch": current_branch,
        "last_commit": last_commit,
        "modified_count": modified_count,
    }


def format_sprint(sprint: dict[str, Any]) -> str:
    num = sprint.get("number", "?")
    direction = sprint.get("direction", "(no direction)")
    status = sprint.get("status", "unknown")
    commits = sprint.get("commits", [])
    commit_count = len(commits) if isinstance(commits, list) else 0
    summary = sprint.get("summary", "").strip()

    lines = [f"{num}. **{direction}** — {status} ({commit_count} commit{'s' if commit_count != 1 else ''})"]
    if summary:
        # Indent-quote the summary so markdown renders it nicely
        for summary_line in summary.splitlines():
            lines.append(f"   > {summary_line}")
    return "\n".join(lines)


def _yaml_scalar(value: Any) -> str:
    """Serialize any value as a YAML-safe scalar. JSON is a YAML subset so
    `json.dumps` produces a valid YAML string literal for any input, and
    handles newlines, colons, `#`, leading `[`/`{`, unicode escapes. Used
    instead of raw f-string interpolation to prevent frontmatter injection
    if conductor-state fields contain YAML-hostile characters."""
    return json.dumps(value if value is not None else "", ensure_ascii=False)


def _safe_shape(state: dict[str, Any]) -> dict[str, Any]:
    """Coerce nested state fields to the shape the renderer expects. Covers
    the case where conductor-state.json is valid JSON but has wrong types
    (sprints as dict, exploration as list, etc.) after a refactor or
    corruption."""
    sprints = state.get("sprints")
    if not isinstance(sprints, list):
        sprints = []
    exploration = state.get("exploration")
    if not isinstance(exploration, dict):
        exploration = {}
    return {
        "session_id": state.get("session_id") or "(no session)",
        "mission": state.get("mission") or "(no mission)",
        "phase": state.get("phase") or "unknown",
        "sprints": [s for s in sprints if isinstance(s, dict)],
        "max_sprints": state.get("max_sprints", "?"),
        "exploration": {k: v for k, v in exploration.items() if isinstance(v, dict)},
    }


def render_markdown(
    project: Path,
    state: dict[str, Any],
    backlog: dict[str, Any],
    git_state: dict[str, Any],
    title: str,
    saved_at: str,
) -> str:
    safe = _safe_shape(state)
    session_id = safe["session_id"]
    mission = safe["mission"]
    phase = safe["phase"]
    sprints = safe["sprints"]
    max_sprints = safe["max_sprints"]
    exploration = safe["exploration"]

    total_commits = sum(
        len(s.get("commits", [])) for s in sprints if isinstance(s.get("commits"), list)
    )

    backlog_items = backlog.get("items")
    if not isinstance(backlog_items, list):
        backlog_items = []
    open_items = [
        item for item in backlog_items
        if isinstance(item, dict) and item.get("status") == "open"
    ]
    untriaged = sum(1 for item in open_items if not item.get("triaged", True))
    next_item = None
    if open_items:
        open_items_sorted = sorted(
            open_items,
            key=lambda it: (it.get("priority", 3), it.get("created_at", "")),
        )
        next_item = open_items_sorted[0]

    lines: list[str] = []

    # YAML frontmatter — every scalar goes through _yaml_scalar to prevent
    # injection if a field contains `:`, newlines, `#`, leading `[`/`{`,
    # or other YAML-hostile characters. JSON is a YAML subset so quoted JSON
    # strings are valid YAML strings.
    lines.append("---")
    lines.append(f"saved_at: {_yaml_scalar(saved_at)}")
    lines.append(f"session_id: {_yaml_scalar(session_id)}")
    lines.append(f"session_branch: {_yaml_scalar(git_state.get('current_branch', ''))}")
    lines.append(f"phase: {_yaml_scalar(phase)}")
    lines.append(f"sprint_count: {len(sprints)}")
    lines.append(f"max_sprints: {max_sprints if isinstance(max_sprints, (int, str)) else '?'}")
    lines.append(f"commit_count: {total_commits}")
    lines.append(f"backlog_open: {len(open_items)}")
    lines.append(f"title: {_yaml_scalar(title)}")
    lines.append("---")
    lines.append("")

    # Header
    lines.append(f"# Checkpoint: {title}")
    lines.append("")
    lines.append(f"_Saved at {saved_at}_")
    lines.append("")

    # Session section
    lines.append("## Session")
    lines.append(f"- **Mission**: {mission}")
    lines.append(f"- **Phase**: {phase}")
    lines.append(f"- **Sprints**: {len(sprints)} / {max_sprints}")
    lines.append(f"- **Commits**: {total_commits}")
    lines.append(f"- **Session branch**: `{git_state.get('current_branch', 'unknown')}`")
    lines.append("")

    # Sprint history
    lines.append("## Sprint history")
    if not sprints:
        lines.append("_No sprints yet._")
    else:
        for sprint in sprints:
            lines.append(format_sprint(sprint))
            lines.append("")

    # Exploration dimensions (only if in exploring phase or any audited)
    audited = [
        (dim, info) for dim, info in exploration.items() if info.get("audited")
    ]
    unaudited = [
        dim for dim, info in exploration.items() if not info.get("audited")
    ]
    if audited or phase == "exploring":
        lines.append("## Exploration dimensions")
        for dim, info in audited:
            score = info.get("score", "?")
            lines.append(f"- `{dim}`: {score}/10")
        for dim in unaudited:
            lines.append(f"- `{dim}`: not audited")
        lines.append("")

    # Backlog
    lines.append("## Backlog")
    lines.append(f"- **Open**: {len(open_items)} ({untriaged} untriaged)")
    if next_item:
        title_line = next_item.get("title", "")
        priority = next_item.get("priority", 3)
        lines.append(f"- **Next up**: {title_line} (P{priority})")
    lines.append("")

    # Git state
    lines.append("## Git state")
    if git_state.get("is_git"):
        lines.append(f"- **Current branch**: `{git_state.get('current_branch', '?')}`")
        last_commit = git_state.get("last_commit", "")
        if last_commit:
            lines.append(f"- **Last commit**: `{last_commit}`")
        modified = git_state.get("modified_count", 0)
        if modified > 0:
            lines.append(f"- **Uncommitted changes**: {modified} file{'s' if modified != 1 else ''}")
        else:
            lines.append("- **Working tree**: clean")
    else:
        lines.append("_Not a git repo._")
    lines.append("")

    # Resume guidance
    lines.append("## Resume guidance")
    if sprints:
        lines.append("To resume this session manually:")
        lines.append("")
        branch = git_state.get("current_branch", "")
        # Find the session branch (auto/session-*) if we're on a sprint branch
        session_branch = branch
        if "-sprint-" in branch:
            session_branch = branch.split("-sprint-")[0]
        if session_branch.startswith("auto/session"):
            lines.append(f"1. `git checkout {session_branch}`")
        else:
            lines.append(f"1. Ensure you're on the session branch")
        lines.append("2. Inspect `.autonomous/conductor-state.json` to confirm phase and sprint count")
        remaining = state.get("max_sprints", 0)
        if isinstance(remaining, int):
            remaining = max(0, remaining - len(sprints))
        if remaining:
            lines.append(f"3. Re-invoke `/autonomous {remaining}` to continue with remaining sprints")
        else:
            lines.append("3. Max sprints reached — start a fresh session if more work is needed")
    else:
        lines.append("No sprints completed yet. Re-invoke `/autonomous <direction>` to start.")
    lines.append("")

    return "\n".join(lines)


def cmd_save(project: Path, args: list[str]) -> None:
    """save [--title <text>]"""
    title = ""
    i = 0
    while i < len(args):
        if args[i] == "--title":
            if i + 1 >= len(args):
                die("--title requires a value")
            title = args[i + 1]
            i += 2
        else:
            die(f"Unknown flag: {args[i]} (only --title is supported)")

    state = read_json(project / ".autonomous" / "conductor-state.json")
    backlog = read_json(project / ".autonomous" / "backlog.json")
    git_state = gather_git_state(project)

    # Auto-generate title if none provided. Use _safe_shape so a malformed
    # sprints field (dict, scalar, missing) can't crash title generation.
    if not title:
        safe = _safe_shape(state)
        sprints_safe = safe["sprints"]
        if sprints_safe:
            last = sprints_safe[-1]
            title = f"sprint {last.get('number', len(sprints_safe))} — {last.get('status', 'unknown')}"
        else:
            title = "session-start"

    saved_at = now_iso()
    ts_filename = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    slug = slugify(title)

    ckpt_dir = project / ".autonomous" / "checkpoints"
    ckpt_dir.mkdir(parents=True, exist_ok=True)

    # Same-second same-slug saves previously silently overwrote. Add a
    # numeric suffix (-1, -2, ...) if the target already exists.
    base = f"{ts_filename}-{slug}"
    target = ckpt_dir / f"{base}.md"
    seq = 1
    while target.exists():
        target = ckpt_dir / f"{base}-{seq}.md"
        seq += 1

    content = render_markdown(project, state, backlog, git_state, title, saved_at)
    target.write_text(content, encoding="utf-8")
    print(str(target))


def cmd_list(project: Path, args: list[str]) -> None:
    """list — list checkpoints oldest→newest"""
    ckpt_dir = project / ".autonomous" / "checkpoints"
    if not ckpt_dir.exists():
        return
    files = sorted(ckpt_dir.glob("*.md"))
    for f in files:
        # Print: filename\ttitle (if parseable from frontmatter)
        try:
            head = f.read_text(encoding="utf-8", errors="replace").splitlines()[:20]
        except OSError:
            head = []
        title_val = ""
        for line in head:
            if line.startswith("title: "):
                raw = line[len("title: "):].strip()
                # Titles are written as JSON strings (_yaml_scalar). Decode
                # JSON to get the human-readable title back; fall back to the
                # raw string if parsing fails (older checkpoints, manual edits).
                try:
                    parsed = json.loads(raw)
                    if isinstance(parsed, str):
                        title_val = parsed
                    else:
                        title_val = raw
                except (json.JSONDecodeError, ValueError):
                    title_val = raw.strip('"')
                break
        # Collapse any newlines in the title — tab-delimited output would
        # otherwise break downstream parsers.
        title_val = title_val.replace("\n", " ").replace("\r", " ")
        if title_val:
            print(f"{f.name}\t{title_val}")
        else:
            print(f.name)


def _safe_read(path: Path) -> str:
    """Read a checkpoint file as UTF-8 with lossy decoding on errors. Used
    so binary / non-UTF8 content never crashes `latest`/`show`."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        die(f"failed to read {path.name}: {exc}")


def cmd_latest(project: Path, args: list[str]) -> None:
    """latest — print the most recent checkpoint"""
    ckpt_dir = project / ".autonomous" / "checkpoints"
    if not ckpt_dir.exists():
        die("No checkpoints directory yet")
    files = sorted(ckpt_dir.glob("*.md"))
    if not files:
        die("No checkpoints yet — run `checkpoint.py save` first")
    print(_safe_read(files[-1]), end="")


def _resolve_checkpoint(ckpt_dir: Path, query: str) -> Path:
    """Resolve a user-supplied query to a single checkpoint file under
    `ckpt_dir`. Refuses path traversal — the matched file's resolved path
    must be inside the resolved ckpt_dir. The query is NOT treated as a
    glob; glob metacharacters (`*`, `?`, `[`, `/`, backslash) are rejected."""
    # Reject glob metacharacters and path separators entirely. The query is
    # meant to be a literal filename fragment, not a glob pattern.
    if not query or any(ch in query for ch in ("/", "\\", "*", "?", "[", "]", "\0")):
        die(f"invalid query (contains path or glob metacharacter): {query}")
    if ".." in query:
        die(f"invalid query (path traversal): {query}")

    resolved_dir = ckpt_dir.resolve()

    # Literal prefix match first, then substring fallback — both scoped
    # to files directly under ckpt_dir, no recursion, .md only.
    candidates = [
        p for p in ckpt_dir.iterdir()
        if p.is_file() and p.suffix == ".md" and p.name.startswith(query)
    ]
    if not candidates:
        candidates = [
            p for p in ckpt_dir.iterdir()
            if p.is_file() and p.suffix == ".md" and query in p.name
        ]
    if not candidates:
        die(f"No checkpoint matching: {query}")
    if len(candidates) > 1:
        names = "\n".join(f"  {m.name}" for m in sorted(candidates))
        die(f"Ambiguous query '{query}', matches:\n{names}")

    match = candidates[0]
    # Paranoia: verify the resolved match lives under ckpt_dir even after
    # symlink resolution. Also ensures Python's Path doesn't surprise us.
    try:
        match.resolve().relative_to(resolved_dir)
    except (ValueError, OSError):
        die(f"refusing to open path outside checkpoints directory: {match}")
    return match


def cmd_show(project: Path, args: list[str]) -> None:
    """show <filename-or-substring>"""
    if not args:
        die("Usage: checkpoint.py show <project-dir> <filename-or-substring>")
    query = args[0]
    ckpt_dir = project / ".autonomous" / "checkpoints"
    if not ckpt_dir.exists():
        die("No checkpoints directory yet")
    match = _resolve_checkpoint(ckpt_dir, query)
    print(_safe_read(match), end="")


def usage() -> None:
    print(
        """Usage: checkpoint.py <command> <project-dir> [args...]

Commands:
  save <project> [--title <text>]   Write a new checkpoint, print its path
  list <project>                    List checkpoints (filename + title)
  latest <project>                  Print the most recent checkpoint
  show <project> <filename-prefix>  Print a specific checkpoint

Checkpoint files live at `<project>/.autonomous/checkpoints/`. Each is a
self-contained markdown snapshot; history is retained.

Examples:
  python3 checkpoint.py save . --title "pre-refactor snapshot"
  python3 checkpoint.py list .
  python3 checkpoint.py latest .
  python3 checkpoint.py show . 20260419
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

    if cmd == "save":
        cmd_save(project, args)
    elif cmd == "list":
        cmd_list(project, args)
    elif cmd == "latest":
        cmd_latest(project, args)
    elif cmd == "show":
        cmd_show(project, args)
    else:
        die(f"Unknown command: {cmd}. Use: save|list|latest|show")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
