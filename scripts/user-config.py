#!/usr/bin/env python3
"""User config + mode selection for autonomous-skill.

Two scopes, precedence high → low:
1. Environment variables (temporary override — debugging)
2. Project config at `<project>/.autonomous/config.json`
3. Global config at `~/.claude/autonomous/config.json`
4. Built-in defaults

Why two scopes:
- Global = "my normal preferences across every repo" (most users)
- Project = "this one repo needs different settings" (escape hatch)

Why a separate `~/.claude/autonomous/` dir (not inside the skill dir):
- The skill is git-managed (`~/.claude/skills/autonomous-skill/`), so putting
  user data inside it creates conflicts on `git pull` updates.

Commands:
  check <project>           — print one of: configured | needs-setup
                              SKILL.md reads this at startup to decide whether
                              to run the first-time AskUserQuestion flow.
  get <key> [project]       — print the effective value (with env overrides).
                              Example keys: mode.worktrees, mode.careful_hook,
                              mode.template, persona.scope
  set <key> <value> [--scope global|project] [--project <dir>]
                            — persist a value at the chosen scope.
  setup [--scope global|project] [--project <dir>]
        [--worktrees on|off] [--careful on|off] [--template <name>]
                            — write a full initial config in one shot.
                              Used by SKILL.md after the AskUserQuestion flow.
  show [--scope global|project|effective] [--project <dir>]
                            — dump the config as JSON.
  paths [--project <dir>]   — print resolved global/project paths (for debugging).

Values:
  mode.worktrees, mode.careful_hook  → bool (true|false)
  mode.template                      → string (gstack|default|<custom>)
  persona.scope                      → string (global|project)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any, NoReturn

VERSION = 1

# Path to the JSON Schema shipped with the skill. Written into config files
# as "$schema" so VS Code / JSON validators pick it up for autocomplete.
SCHEMA_URL = (
    "https://raw.githubusercontent.com/Sma1lboy/autonomous-skill/main/"
    "schemas/autonomous-config.schema.json"
)

# Keys that are user-toggleable. Env-var names where applicable.
ENV_OVERRIDES: dict[str, str] = {
    "mode.worktrees": "AUTONOMOUS_SPRINT_WORKTREES",
    "mode.careful_hook": "AUTONOMOUS_WORKER_CAREFUL",
}

BOOL_KEYS = {
    "mode.worktrees",
    "mode.careful_hook",
    "experimental.vira_worktree",
    "experimental.parallel_sprints",
}
STRING_KEYS = {"mode.template", "persona.scope"}
VALID_TEMPLATES = {"gstack", "default"}
VALID_PERSONA_SCOPES = {"global", "project"}

# Experimental keys surface a stderr warning on every `check` so the user
# never forgets they're running unstable code. Extend this set when adding
# new experimental toggles. Also update the JSON Schema.
EXPERIMENTAL_KEYS = {
    "experimental.vira_worktree",
    "experimental.parallel_sprints",
}

DEFAULTS: dict[str, Any] = {
    "mode": {
        "worktrees": False,
        "careful_hook": False,
        "template": "gstack",
    },
    "persona": {
        "scope": "global",
        "last_generated": None,
    },
    "experimental": {
        "vira_worktree": False,
        "parallel_sprints": False,
    },
}


def die(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def global_dir() -> Path:
    return Path.home() / ".claude" / "autonomous"


def global_config_path() -> Path:
    return global_dir() / "config.json"


def global_owner_path() -> Path:
    return global_dir() / "OWNER.md"


def project_config_path(project: Path) -> Path:
    return project / ".autonomous" / "config.json"


def project_owner_path(project: Path) -> Path:
    return project / ".autonomous" / "OWNER.md"


def legacy_skill_config_path(project: Path) -> Path:
    """Old per-project template selector (pre-user-config)."""
    return project / ".autonomous" / "skill-config.json"


def _load_json(path: Path) -> dict[str, Any]:
    """Return a dict or {} — never raises, never returns non-dict."""
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    tmp.replace(path)


def _deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    """Overlay wins on leaf conflicts; nested dicts merge recursively."""
    result = dict(base)
    for key, value in overlay.items():
        if (
            key in result
            and isinstance(result[key], dict)
            and isinstance(value, dict)
        ):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def _parse_bool_env(raw: str) -> bool | None:
    if raw.lower() in {"1", "true", "yes", "on"}:
        return True
    if raw.lower() in {"0", "false", "no", "off"}:
        return False
    return None


def _get_nested(data: dict[str, Any], dotted: str) -> Any:
    cur: Any = data
    for part in dotted.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


def _set_nested(data: dict[str, Any], dotted: str, value: Any) -> None:
    parts = dotted.split(".")
    cur: Any = data
    for part in parts[:-1]:
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    cur[parts[-1]] = value


def load_effective(project: Path | None) -> dict[str, Any]:
    """Merged view: defaults ← global ← project. No env overrides applied here."""
    merged = json.loads(json.dumps(DEFAULTS))  # deep copy
    merged = _deep_merge(merged, _load_json(global_config_path()))
    if project is not None:
        # Backward compat: pull template out of legacy skill-config.json if the
        # new config.json doesn't exist in the project.
        project_cfg_path = project_config_path(project)
        if not project_cfg_path.exists():
            legacy = _load_json(legacy_skill_config_path(project))
            if legacy.get("template"):
                merged["mode"]["template"] = legacy["template"]
        else:
            merged = _deep_merge(merged, _load_json(project_cfg_path))
    return merged


def is_configured() -> bool:
    """Global config exists? That's our 'has the user ever set this up' test."""
    return global_config_path().exists()


def _enabled_experimental(project: Path | None) -> list[str]:
    """Return the list of experimental.* keys currently set to true in the
    effective config (after project/global merge). Used to warn on startup."""
    cfg = load_effective(project)
    enabled: list[str] = []
    for key in EXPERIMENTAL_KEYS:
        value = _get_nested(cfg, key)
        if value is True:
            enabled.append(key)
    return enabled


def cmd_check(args: argparse.Namespace) -> None:
    """Print 'configured' or 'needs-setup' to stdout. If any experimental
    flag is on, also print a single-line WARNING to stderr — stdout stays
    machine-parseable for bash callers, the warning is a human cue."""
    print("configured" if is_configured() else "needs-setup")
    project = Path(args.project).resolve() if args.project else None
    enabled = _enabled_experimental(project)
    if enabled:
        print(
            "WARNING: experimental flags enabled (subject to breaking changes): "
            + ", ".join(sorted(enabled)),
            file=sys.stderr,
        )


def _coerce_value(key: str, raw: str) -> Any:
    if key in BOOL_KEYS:
        parsed = _parse_bool_env(raw)
        if parsed is None:
            die(f"invalid bool for {key}: {raw} (use true|false|on|off)")
        return parsed
    if key == "mode.template":
        cleaned = raw.strip()
        if not cleaned:
            die("template name is required")
        # Safety: reject path traversal / dot-prefix like build-sprint-prompt.py
        if cleaned.startswith(".") or "/" in cleaned or "\\" in cleaned:
            die(f"invalid template name: {cleaned}")
        return cleaned
    if key == "persona.scope":
        if raw not in VALID_PERSONA_SCOPES:
            die(f"invalid scope: {raw} (use global|project)")
        return raw
    if key in STRING_KEYS:
        return raw
    die(f"unknown key: {key}")


def cmd_get(args: argparse.Namespace) -> None:
    project = Path(args.project).resolve() if args.project else None
    cfg = load_effective(project)

    # Env override wins
    env_name = ENV_OVERRIDES.get(args.key)
    if env_name and env_name in os.environ and os.environ[env_name]:
        parsed = _parse_bool_env(os.environ[env_name])
        if parsed is not None:
            print("true" if parsed else "false")
            return

    value = _get_nested(cfg, args.key)
    if isinstance(value, bool):
        print("true" if value else "false")
    elif value is None:
        print("")
    else:
        print(value)


def _write_at_scope(
    scope: str,
    project: Path | None,
    mutation: "callable",
) -> Path:
    if scope == "global":
        path = global_config_path()
    elif scope == "project":
        if project is None:
            die("--project is required when --scope=project")
        path = project_config_path(project)
    else:
        die(f"invalid scope: {scope} (use global|project)")
    existing = _load_json(path)
    if not existing:
        # Minimal skeleton only. Do NOT seed defaults here: that would cause
        # a project-scope write to shadow keys the user set globally (e.g.,
        # setting mode.worktrees=false at project would also write
        # mode.careful_hook=false and erase the inherited global value).
        existing = {
            "$schema": SCHEMA_URL,
            "version": VERSION,
            "created_at": now_iso(),
        }
    mutation(existing)
    existing["updated_at"] = now_iso()
    existing.setdefault("version", VERSION)
    existing.setdefault("$schema", SCHEMA_URL)
    _atomic_write_json(path, existing)
    return path


def cmd_set(args: argparse.Namespace) -> None:
    key, value = args.key, args.value
    coerced = _coerce_value(key, value)
    project = Path(args.project).resolve() if args.project else None

    def mutate(cfg: dict[str, Any]) -> None:
        _set_nested(cfg, key, coerced)

    path = _write_at_scope(args.scope, project, mutate)
    print(f"{key}={coerced} saved to {path}")


def cmd_setup(args: argparse.Namespace) -> None:
    """Write a complete fresh config — the target of the first-time flow."""
    project = Path(args.project).resolve() if args.project else None
    worktrees = _parse_bool_env(args.worktrees) if args.worktrees else None
    careful = _parse_bool_env(args.careful) if args.careful else None
    if args.worktrees and worktrees is None:
        die(f"invalid --worktrees: {args.worktrees}")
    if args.careful and careful is None:
        die(f"invalid --careful: {args.careful}")
    if args.template and args.template not in VALID_TEMPLATES and (
        args.template.startswith(".") or "/" in args.template
    ):
        die(f"invalid --template: {args.template}")

    def mutate(cfg: dict[str, Any]) -> None:
        if worktrees is not None:
            _set_nested(cfg, "mode.worktrees", worktrees)
        if careful is not None:
            _set_nested(cfg, "mode.careful_hook", careful)
        if args.template:
            _set_nested(cfg, "mode.template", args.template)
        if args.persona_scope:
            if args.persona_scope not in VALID_PERSONA_SCOPES:
                die(f"invalid --persona-scope: {args.persona_scope}")
            _set_nested(cfg, "persona.scope", args.persona_scope)

    path = _write_at_scope(args.scope, project, mutate)
    print(f"config saved to {path}")


def cmd_show(args: argparse.Namespace) -> None:
    project = Path(args.project).resolve() if args.project else None
    scope = args.scope
    if scope == "global":
        data = _load_json(global_config_path())
    elif scope == "project":
        if project is None:
            die("--project is required when --scope=project")
        data = _load_json(project_config_path(project))
    else:  # effective (default)
        data = load_effective(project)
    print(json.dumps(data, indent=2))


def cmd_init(args: argparse.Namespace) -> None:
    """Write a fully-populated sample config at the chosen scope.

    Unlike `setup` (which only writes the keys the user answered), `init`
    lays down every known field at its default value with the `$schema`
    reference. Useful as a manual starting point: users can edit the file
    with full IDE autocomplete via the schema, without having to memorize
    the key names.

    Refuses to overwrite an existing config — rename the subcommand to
    `set` or delete the file if you really want to start over.
    """
    project = Path(args.project).resolve() if args.project else None
    if args.scope == "global":
        path = global_config_path()
    else:
        if project is None:
            die("--project is required when --scope=project")
        path = project_config_path(project)

    if path.exists():
        die(
            f"config already exists at {path}. Edit it directly or use "
            "`set`/`setup`; `init` refuses to overwrite."
        )

    seeded = {
        "$schema": SCHEMA_URL,
        "version": VERSION,
        "created_at": now_iso(),
        "updated_at": now_iso(),
    }
    seeded.update(json.loads(json.dumps(DEFAULTS)))  # deep copy
    _atomic_write_json(path, seeded)
    print(f"wrote sample config to {path}")


def cmd_experimental(args: argparse.Namespace) -> None:
    """Emit shell-eval-able env vars for every experimental flag, plus a
    short note listing which are enabled. This is the unified interface
    SKILL.md consumes at the start of each Plan phase — adding a new
    experimental feature means editing this script's EXPERIMENTAL_KEYS
    and DEFAULTS, nothing else; the conductor picks it up automatically.

    Output format (stdout, safe to `eval`):
        EXPERIMENTAL_PARALLEL_SPRINTS=true
        EXPERIMENTAL_VIRA_WORKTREE=false
        EXPERIMENTAL_ENABLED="parallel_sprints"   # space-separated short names

    The `EXPERIMENTAL_ENABLED` var is a convenience for scripts that want
    to quickly check "is anything experimental on?" without listing every flag.
    """
    project = Path(args.project).resolve() if args.project else None
    cfg = load_effective(project)

    enabled_short: list[str] = []
    for key in sorted(EXPERIMENTAL_KEYS):
        # Env var name: uppercase, strip "experimental." prefix
        short = key.split(".", 1)[1] if "." in key else key
        env_name = "EXPERIMENTAL_" + short.upper()

        # Honor env-override precedence used everywhere else in this module
        env_override = os.environ.get(env_name)
        if env_override is not None:
            parsed = _parse_bool_env(env_override)
            value = parsed if parsed is not None else False
        else:
            raw = _get_nested(cfg, key)
            value = bool(raw) if raw is not None else False

        print(f"{env_name}={'true' if value else 'false'}")
        if value:
            enabled_short.append(short)

    # Shell-safe join (short names are alphanumeric + underscore, no quoting needed)
    print(f'EXPERIMENTAL_ENABLED="{" ".join(enabled_short)}"')


def cmd_paths(args: argparse.Namespace) -> None:
    project = Path(args.project).resolve() if args.project else None
    print(f"global_dir:      {global_dir()}")
    print(f"global_config:   {global_config_path()}")
    print(f"global_owner:    {global_owner_path()}")
    if project:
        print(f"project_dir:     {project}")
        print(f"project_config:  {project_config_path(project)}")
        print(f"project_owner:   {project_owner_path(project)}")
        print(f"legacy_config:   {legacy_skill_config_path(project)}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="user-config.py",
        description=__doc__.splitlines()[0] if __doc__ else "",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check", help="print 'configured' or 'needs-setup'")
    p_check.add_argument("project", nargs="?", default=None)
    p_check.set_defaults(func=cmd_check)

    p_get = sub.add_parser("get", help="get a config value (env overrides apply)")
    p_get.add_argument("key")
    p_get.add_argument("project", nargs="?", default=None)
    p_get.set_defaults(func=cmd_get)

    p_set = sub.add_parser("set", help="persist a config value")
    p_set.add_argument("key")
    p_set.add_argument("value")
    p_set.add_argument("--scope", choices=["global", "project"], default="global")
    p_set.add_argument("--project", default=None)
    p_set.set_defaults(func=cmd_set)

    p_setup = sub.add_parser(
        "setup",
        help="write a full fresh config (used by SKILL.md after first-time AskUserQuestion)",
    )
    p_setup.add_argument("--scope", choices=["global", "project"], default="global")
    p_setup.add_argument("--project", default=None)
    p_setup.add_argument("--worktrees", default=None, help="on|off")
    p_setup.add_argument("--careful", default=None, help="on|off")
    p_setup.add_argument("--template", default=None)
    p_setup.add_argument(
        "--persona-scope",
        default=None,
        choices=list(VALID_PERSONA_SCOPES),
        help="where OWNER.md lives (default global)",
    )
    p_setup.set_defaults(func=cmd_setup)

    p_show = sub.add_parser("show", help="print config JSON")
    p_show.add_argument(
        "--scope",
        choices=["global", "project", "effective"],
        default="effective",
    )
    p_show.add_argument("--project", default=None)
    p_show.set_defaults(func=cmd_show)

    p_init = sub.add_parser(
        "init",
        help="write a fully-populated sample config (all fields, defaults, $schema)",
    )
    p_init.add_argument("--scope", choices=["global", "project"], default="global")
    p_init.add_argument("--project", default=None)
    p_init.set_defaults(func=cmd_init)

    p_exp = sub.add_parser(
        "experimental",
        help="emit eval-able EXPERIMENTAL_* env vars + EXPERIMENTAL_ENABLED list "
        "(unified interface for SKILL.md to gate experimental flows)",
    )
    p_exp.add_argument("project", nargs="?", default=None)
    p_exp.set_defaults(func=cmd_experimental)

    p_paths = sub.add_parser("paths", help="print resolved paths (debug)")
    p_paths.add_argument("--project", default=None)
    p_paths.set_defaults(func=cmd_paths)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv[1:])
    args.func(args)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main(sys.argv))
