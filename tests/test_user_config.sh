#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UC="$SCRIPT_DIR/../scripts/user-config.py"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_user_config.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Every test uses a sandboxed HOME so the real user config isn't touched.
sandbox_home() {
  local h
  h=$(new_tmp)
  echo "$h"
}

make_project() {
  local p
  p=$(new_tmp)
  (cd "$p" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init) >/dev/null
  echo "$p"
}

# ── 1. Help + unknown command ────────────────────────────────────────────

echo ""
echo "1. Help + CLI surface"

HELP=$(python3 "$UC" --help 2>&1)
assert_contains "$HELP" "check" "--help documents check"
assert_contains "$HELP" "get" "--help documents get"
assert_contains "$HELP" "set" "--help documents set"
assert_contains "$HELP" "setup" "--help documents setup"
assert_contains "$HELP" "show" "--help documents show"

if python3 "$UC" bogus 2>/dev/null; then
  fail "unknown subcommand should fail"
else
  ok "unknown subcommand rejected"
fi

# ── 2. check: needs-setup vs configured ──────────────────────────────────

echo ""
echo "2. check subcommand"

H=$(sandbox_home)
T=$(make_project)
OUT=$(HOME="$H" python3 "$UC" check "$T")
assert_eq "$OUT" "needs-setup" "fresh HOME → needs-setup"

HOME="$H" python3 "$UC" setup --scope global --worktrees on --careful off > /dev/null
OUT=$(HOME="$H" python3 "$UC" check "$T")
assert_eq "$OUT" "configured" "after setup → configured"

# ── 3. setup writes complete config ──────────────────────────────────────

echo ""
echo "3. setup writes full config"

H=$(sandbox_home)
HOME="$H" python3 "$UC" setup --scope global --worktrees on --careful on --template gstack --persona-scope global > /dev/null
CONFIG="$H/.claude/autonomous/config.json"
assert_file_exists "$CONFIG" "global config written"
assert_file_contains "$CONFIG" '"worktrees": true' "worktrees on persisted"
assert_file_contains "$CONFIG" '"careful_hook": true' "careful on persisted"
assert_file_contains "$CONFIG" '"template": "gstack"' "template persisted"
assert_file_contains "$CONFIG" '"scope": "global"' "persona scope persisted"
assert_file_contains "$CONFIG" '"version": 1' "version field present"
assert_file_contains "$CONFIG" '"created_at"' "created_at present"

# ── 4. get: reads value from global ──────────────────────────────────────

echo ""
echo "4. get from global"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" setup --scope global --worktrees on > /dev/null
WT=$(HOME="$H" python3 "$UC" get mode.worktrees "$T")
assert_eq "$WT" "true" "global worktrees=on read as true"
CH=$(HOME="$H" python3 "$UC" get mode.careful_hook "$T")
assert_eq "$CH" "false" "global careful unset → default false"
TMPL=$(HOME="$H" python3 "$UC" get mode.template "$T")
assert_eq "$TMPL" "gstack" "template default=gstack"

# ── 5. project overrides global ─────────────────────────────────────────

echo ""
echo "5. project overrides global"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" setup --scope global --worktrees on --careful on > /dev/null
HOME="$H" python3 "$UC" set mode.worktrees false --scope project --project "$T" > /dev/null
WT=$(HOME="$H" python3 "$UC" get mode.worktrees "$T")
assert_eq "$WT" "false" "project worktrees=false beats global=true"
# careful is unset at project → inherits global
CH=$(HOME="$H" python3 "$UC" get mode.careful_hook "$T")
assert_eq "$CH" "true" "careful inherits from global (not set at project)"

# ── 6. env var beats everything ──────────────────────────────────────────

echo ""
echo "6. env var overrides project+global"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" setup --scope global --worktrees on > /dev/null
WT=$(HOME="$H" AUTONOMOUS_SPRINT_WORKTREES=0 python3 "$UC" get mode.worktrees "$T")
assert_eq "$WT" "false" "env=0 overrides global=true"
WT=$(HOME="$H" AUTONOMOUS_SPRINT_WORKTREES=yes python3 "$UC" get mode.worktrees "$T")
assert_eq "$WT" "true" "env=yes overrides"
CH=$(HOME="$H" AUTONOMOUS_WORKER_CAREFUL=true python3 "$UC" get mode.careful_hook "$T")
assert_eq "$CH" "true" "careful env override works"

# ── 7. legacy skill-config.json migration path ──────────────────────────

echo ""
echo "7. legacy skill-config.json → template"

H=$(sandbox_home)
T=$(make_project)
mkdir -p "$T/.autonomous"
# Pre-existing legacy file (old users have this)
echo '{"template":"default"}' > "$T/.autonomous/skill-config.json"
TMPL=$(HOME="$H" python3 "$UC" get mode.template "$T")
assert_eq "$TMPL" "default" "legacy skill-config.json read as template"

# New config.json should win over legacy
HOME="$H" python3 "$UC" set mode.template custom-tpl --scope project --project "$T" > /dev/null
TMPL=$(HOME="$H" python3 "$UC" get mode.template "$T")
assert_eq "$TMPL" "custom-tpl" "new config.json beats legacy skill-config.json"

# ── 8. set: validation ──────────────────────────────────────────────────

echo ""
echo "8. set validation"

H=$(sandbox_home)
if HOME="$H" python3 "$UC" set mode.worktrees notabool --scope global 2>/dev/null; then
  fail "invalid bool should be rejected"
else
  ok "invalid bool rejected"
fi
if HOME="$H" python3 "$UC" set mode.template "../path" --scope global 2>/dev/null; then
  fail "path-traversal template should be rejected"
else
  ok "path-traversal template rejected"
fi
if HOME="$H" python3 "$UC" set mode.template ".hidden" --scope global 2>/dev/null; then
  fail "dot-prefix template should be rejected"
else
  ok "dot-prefix template rejected"
fi
if HOME="$H" python3 "$UC" set persona.scope elsewhere --scope global 2>/dev/null; then
  fail "invalid persona scope should be rejected"
else
  ok "invalid persona scope rejected"
fi
if HOME="$H" python3 "$UC" set mode.worktrees true --scope project 2>/dev/null; then
  fail "project scope without --project should fail"
else
  ok "project scope requires --project"
fi

# ── 9. show: effective vs scoped ────────────────────────────────────────

echo ""
echo "9. show subcommand"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" setup --scope global --worktrees on --template gstack > /dev/null
HOME="$H" python3 "$UC" set mode.worktrees false --scope project --project "$T" > /dev/null

EFFECTIVE=$(HOME="$H" python3 "$UC" show --project "$T")
assert_contains "$EFFECTIVE" '"worktrees": false' "effective shows project override"
assert_contains "$EFFECTIVE" '"template": "gstack"' "effective includes global template"

GLOBAL_ONLY=$(HOME="$H" python3 "$UC" show --scope global)
assert_contains "$GLOBAL_ONLY" '"worktrees": true' "global scope shows true"

PROJECT_ONLY=$(HOME="$H" python3 "$UC" show --scope project --project "$T")
assert_contains "$PROJECT_ONLY" '"worktrees": false' "project scope shows false"

# ── 10. paths ────────────────────────────────────────────────────────────

echo ""
echo "10. paths subcommand"

H=$(sandbox_home)
T=$(make_project)
OUT=$(HOME="$H" python3 "$UC" paths --project "$T")
assert_contains "$OUT" "$H/.claude/autonomous/config.json" "global config path shown"
assert_contains "$OUT" "$T/.autonomous/config.json" "project config path shown"
assert_contains "$OUT" "OWNER.md" "owner path shown"

# ── 11. malformed config resilience ─────────────────────────────────────

echo ""
echo "11. malformed config doesn't crash"

H=$(sandbox_home)
T=$(make_project)
mkdir -p "$H/.claude/autonomous" "$T/.autonomous"
echo "not valid json" > "$H/.claude/autonomous/config.json"
echo '["list","not","dict"]' > "$T/.autonomous/config.json"
OUT=$(HOME="$H" python3 "$UC" get mode.worktrees "$T" 2>&1)
assert_eq "$OUT" "false" "malformed configs fall through to default"

# ── 12. Experimental flags ──────────────────────────────────────────────

echo ""
echo "12. Experimental flags"

H=$(sandbox_home)
T=$(make_project)
# Defaults: both experimental flags off
HOME="$H" python3 "$UC" setup --scope global --worktrees on > /dev/null
VIRA=$(HOME="$H" python3 "$UC" get experimental.vira_worktree "$T")
PARA=$(HOME="$H" python3 "$UC" get experimental.parallel_sprints "$T")
assert_eq "$VIRA" "false" "vira_worktree defaults to false"
assert_eq "$PARA" "false" "parallel_sprints defaults to false"

# Can be set
HOME="$H" python3 "$UC" set experimental.vira_worktree true --scope global > /dev/null
VIRA=$(HOME="$H" python3 "$UC" get experimental.vira_worktree "$T")
assert_eq "$VIRA" "true" "experimental flag set persists"

# Validation: must be bool
if HOME="$H" python3 "$UC" set experimental.vira_worktree maybe --scope global 2>/dev/null; then
  fail "non-bool experimental value should be rejected"
else
  ok "non-bool experimental value rejected"
fi

# check emits warning to stderr when any experimental is on
STDERR=$(HOME="$H" python3 "$UC" check "$T" 2>&1 >/dev/null)
assert_contains "$STDERR" "experimental flags enabled" "check warns on experimental"
assert_contains "$STDERR" "vira_worktree" "warning names the enabled flag"

# stdout stays clean (machine-readable)
STDOUT=$(HOME="$H" python3 "$UC" check "$T" 2>/dev/null)
assert_eq "$STDOUT" "configured" "stdout unchanged by experimental warning"

# No warning when all experimental flags are off
HOME="$H" python3 "$UC" set experimental.vira_worktree false --scope global > /dev/null
STDERR=$(HOME="$H" python3 "$UC" check "$T" 2>&1 >/dev/null)
assert_not_contains "$STDERR" "experimental" "no warning when no experimental flags on"

# ── 13. $schema reference in written configs ────────────────────────────

echo ""
echo "13. \$schema reference"

H=$(sandbox_home)
HOME="$H" python3 "$UC" setup --scope global --worktrees on > /dev/null
CONFIG="$H/.claude/autonomous/config.json"
assert_file_contains "$CONFIG" "autonomous-config.schema.json" "setup writes \$schema field"

# set also writes $schema if file didn't exist
H=$(sandbox_home)
HOME="$H" python3 "$UC" set mode.worktrees true --scope global > /dev/null
assert_file_contains "$H/.claude/autonomous/config.json" "autonomous-config.schema.json" "set writes \$schema on fresh file"

# ── 14. init command ────────────────────────────────────────────────────

echo ""
echo "14. init command (sample config)"

H=$(sandbox_home)
OUT=$(HOME="$H" python3 "$UC" init --scope global)
assert_contains "$OUT" "wrote sample config" "init prints path"

CONFIG="$H/.claude/autonomous/config.json"
assert_file_exists "$CONFIG" "init wrote a config"
# All top-level sections present
assert_file_contains "$CONFIG" '"mode"' "init seeds mode section"
assert_file_contains "$CONFIG" '"persona"' "init seeds persona section"
assert_file_contains "$CONFIG" '"experimental"' "init seeds experimental section"
assert_file_contains "$CONFIG" '"vira_worktree"' "init lists vira_worktree"
assert_file_contains "$CONFIG" '"parallel_sprints"' "init lists parallel_sprints"
assert_file_contains "$CONFIG" "autonomous-config.schema.json" "init includes \$schema"

# init refuses to overwrite
if HOME="$H" python3 "$UC" init --scope global 2>/dev/null; then
  fail "init should refuse when config exists"
else
  ok "init refuses to clobber existing config"
fi

# init --scope project requires --project
H=$(sandbox_home)
if HOME="$H" python3 "$UC" init --scope project 2>/dev/null; then
  fail "init --scope project without --project should fail"
else
  ok "init --scope project requires --project"
fi

# init --scope project + --project works
T=$(make_project)
HOME="$H" python3 "$UC" init --scope project --project "$T" > /dev/null
assert_file_exists "$T/.autonomous/config.json" "init writes project config"

# ── 14.5. experimental subcommand (unified SKILL.md gate) ──────────────

echo ""
echo "14.5. experimental subcommand"

H=$(sandbox_home)
T=$(make_project)
HOME="$H" python3 "$UC" setup --scope global --worktrees on > /dev/null

OUT=$(HOME="$H" python3 "$UC" experimental "$T")
assert_contains "$OUT" "EXPERIMENTAL_PARALLEL_SPRINTS=false" "parallel flag false by default"
assert_contains "$OUT" "EXPERIMENTAL_VIRA_WORKTREE=false" "vira flag false by default"
assert_contains "$OUT" 'EXPERIMENTAL_ENABLED=""' "nothing enabled by default"

HOME="$H" python3 "$UC" set experimental.parallel_sprints true --scope global > /dev/null
OUT=$(HOME="$H" python3 "$UC" experimental "$T")
assert_contains "$OUT" "EXPERIMENTAL_PARALLEL_SPRINTS=true" "parallel flag true after set"
assert_contains "$OUT" 'EXPERIMENTAL_ENABLED="parallel_sprints"' "enabled list includes parallel_sprints"

HOME="$H" python3 "$UC" set experimental.vira_worktree true --scope global > /dev/null
OUT=$(HOME="$H" python3 "$UC" experimental "$T")
assert_contains "$OUT" "EXPERIMENTAL_VIRA_WORKTREE=true" "vira now true"

eval "$(HOME="$H" python3 "$UC" experimental "$T")"
assert_eq "$EXPERIMENTAL_PARALLEL_SPRINTS" "true" "eval sets EXPERIMENTAL_PARALLEL_SPRINTS"
assert_eq "$EXPERIMENTAL_VIRA_WORKTREE" "true" "eval sets EXPERIMENTAL_VIRA_WORKTREE"

OUT=$(HOME="$H" EXPERIMENTAL_PARALLEL_SPRINTS=0 python3 "$UC" experimental "$T")
assert_contains "$OUT" "EXPERIMENTAL_PARALLEL_SPRINTS=false" "env var overrides config to false"

T2=$(make_project)
HOME="$H" python3 "$UC" set experimental.parallel_sprints false --scope project --project "$T2" > /dev/null
OUT=$(HOME="$H" python3 "$UC" experimental "$T2")
assert_contains "$OUT" "EXPERIMENTAL_PARALLEL_SPRINTS=false" "project false overrides global true"

# ── 15. Schema file exists and is valid ─────────────────────────────────

echo ""
echo "15. Schema file integrity"

SCHEMA_FILE="$SCRIPT_DIR/../schemas/autonomous-config.schema.json"
assert_file_exists "$SCHEMA_FILE" "schema file present"

# Valid JSON
VALID=$(python3 -c "
import json, sys
try:
    d = json.load(open('$SCHEMA_FILE'))
    assert d.get('title') == 'autonomous-skill config'
    assert 'mode' in d.get('properties', {})
    assert 'experimental' in d.get('properties', {})
    assert 'vira_worktree' in d['properties']['experimental'].get('properties', {})
    assert 'parallel_sprints' in d['properties']['experimental'].get('properties', {})
    print('ok')
except Exception as e:
    print(f'fail: {e}', file=sys.stderr)
    sys.exit(1)
")
assert_eq "$VALID" "ok" "schema documents mode + experimental sections"

# Schema matches what user-config.py writes
H=$(sandbox_home)
HOME="$H" python3 "$UC" init --scope global > /dev/null
python3 -c "
import json
schema = json.load(open('$SCHEMA_FILE'))
config = json.load(open('$H/.claude/autonomous/config.json'))
# Every top-level property in the written config should be in schema.properties
schema_props = set(schema.get('properties', {}).keys())
config_keys = set(config.keys())
missing = config_keys - schema_props
assert not missing, f'config has keys not in schema: {missing}'
print('ok')
" > /tmp/schema-check.out
assert_eq "$(cat /tmp/schema-check.out)" "ok" "every config key is documented in schema"
rm -f /tmp/schema-check.out

print_results
