#!/usr/bin/env bash
# skill-registry.sh — Manage a registry of AI-readable skill metadata.
# Skills are stored as individual JSON files in .autonomous/skill-registry/.
# Supports registration, listing, querying, prompt generation, and scanning.

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: skill-registry.sh <command> <project-dir> [args...]

Manage a registry of AI-readable skill metadata for autonomous workers.
Skills are stored as individual JSON files in .autonomous/skill-registry/.

Commands:
  register <project-dir> <skill-dir> [--summary "text"]
      Register a skill from a directory containing SKILL.md.
      Extracts name from directory name or first heading.
      If --summary is omitted and claude -p is available, generates a summary.
      If claude -p fails, uses a generic fallback summary.

  list <project-dir>
      List all registered skills: "name — summary" format, one per line.

  get <project-dir> <skill-name>
      Output full JSON for the named skill.

  prompt-block <project-dir>
      Generate a "## Available Skills" text block for injecting into prompts.
      Empty output (exit 0) if no skills registered.

  scan <project-dir> <search-dir>
      Find SKILL.md files recursively in <search-dir>.
      Register any not already in the registry (auto-generates summary).

  unregister <project-dir> <skill-name>
      Remove a skill from the registry.

Examples:
  bash scripts/skill-registry.sh register ./my-project ./skills/deploy --summary "Deploy to prod"
  bash scripts/skill-registry.sh list ./my-project
  bash scripts/skill-registry.sh get ./my-project deploy
  bash scripts/skill-registry.sh prompt-block ./my-project
  bash scripts/skill-registry.sh scan ./my-project ./skills
  bash scripts/skill-registry.sh unregister ./my-project deploy
EOF
  exit 0
}

# Handle --help / -h before anything else
case "${1:-}" in
  -h|--help|help) usage ;;
esac

command -v python3 &>/dev/null || { echo "ERROR: python3 required but not found" >&2; exit 1; }

CMD="${1:-}"
PROJECT="${2:-.}"
REGISTRY_DIR="$PROJECT/.autonomous/skill-registry"

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_registry() {
  mkdir -p "$REGISTRY_DIR"
}

# Extract skill name from directory name (basename), sanitized
skill_name_from_dir() {
  local dir="$1"
  # Remove trailing slashes, get basename, lowercase, replace non-alnum with dash
  local name
  name=$(basename "$dir" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')
  echo "$name"
}

# Extract skill name from SKILL.md first heading, or fall back to directory name
extract_skill_name() {
  local skill_dir="$1"
  local skill_file="$skill_dir/SKILL.md"

  if [ -f "$skill_file" ]; then
    # Try first heading (# Title)
    local heading
    heading=$(python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r'^#+\s+(.+)', line.strip())
        if m:
            name = re.sub(r'[^a-zA-Z0-9_-]', '-', m.group(1).strip().lower())
            name = re.sub(r'-+', '-', name).strip('-')
            print(name)
            sys.exit(0)
print('')
" "$skill_file" 2>/dev/null || echo "")

    if [ -n "$heading" ]; then
      echo "$heading"
      return
    fi
  fi

  skill_name_from_dir "$skill_dir"
}

# Extract capabilities from SKILL.md headings
extract_capabilities() {
  local skill_file="$1"
  python3 -c "
import sys, re, json

caps = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            m = re.match(r'^#{2,}\s+(.+)', line.strip())
            if m:
                cap = m.group(1).strip()
                if cap and len(cap) < 100:
                    caps.append(cap)
except FileNotFoundError:
    pass

print(json.dumps(caps[:20]))
" "$skill_file" 2>/dev/null || echo "[]"
}

# Generate summary from first few lines of SKILL.md
auto_summary_from_content() {
  local skill_file="$1"
  python3 -c "
import sys, re

lines = []
try:
    with open(sys.argv[1]) as f:
        for line in f:
            stripped = line.strip()
            # Skip headings and empty lines at the start
            if not stripped or re.match(r'^#+\s', stripped):
                if lines:
                    break
                continue
            lines.append(stripped)
            if len(lines) >= 3:
                break
except FileNotFoundError:
    pass

if lines:
    summary = ' '.join(lines)[:200]
    print(summary)
else:
    print('')
" "$skill_file" 2>/dev/null || echo ""
}

# Generate summary using claude -p, with fallback
generate_summary() {
  local skill_dir="$1"
  local skill_file="$skill_dir/SKILL.md"

  # Try claude -p if available
  if command -v claude &>/dev/null; then
    local content
    content=$(head -50 "$skill_file" 2>/dev/null || echo "")
    if [ -n "$content" ]; then
      local ai_summary
      ai_summary=$(echo "$content" | claude -p "Summarize this skill in 2-3 sentences. Output ONLY the summary, nothing else." 2>/dev/null || echo "")
      if [ -n "$ai_summary" ]; then
        echo "$ai_summary"
        return
      fi
    fi
  fi

  # Fallback: extract from content
  local content_summary
  content_summary=$(auto_summary_from_content "$skill_file")
  if [ -n "$content_summary" ]; then
    echo "$content_summary"
    return
  fi

  # Last resort: generic
  echo "Skill from $skill_dir"
}

# ── Commands ─────────────────────────────────────────────────────────────

cmd_register() {
  local skill_dir="${3:-}"
  [ -z "$skill_dir" ] && die "Usage: skill-registry.sh register <project-dir> <skill-dir> [--summary \"text\"]"

  local skill_file="$skill_dir/SKILL.md"
  [ -f "$skill_file" ] || die "SKILL.md not found in: $skill_dir"

  # Parse --summary flag from remaining args
  local summary=""
  local has_summary_flag=false
  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --summary)
        has_summary_flag=true
        summary="${2:-}"
        [ -z "$summary" ] && die "--summary requires a value"
        shift 2
        ;;
      *)
        die "Unknown flag: $1"
        ;;
    esac
  done

  # Generate summary if not provided
  if [ "$has_summary_flag" = false ]; then
    summary=$(generate_summary "$skill_dir")
  fi

  local name
  name=$(extract_skill_name "$skill_dir")
  [ -z "$name" ] && die "Could not determine skill name from: $skill_dir"

  local capabilities
  capabilities=$(extract_capabilities "$skill_file")

  local abs_path
  abs_path=$(cd "$skill_dir" && pwd)

  ensure_registry

  python3 -c "
import json, sys, time, os

name = sys.argv[1]
path = sys.argv[2]
summary = sys.argv[3]
capabilities = json.loads(sys.argv[4])
registry_dir = sys.argv[5]
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

skill = {
    'name': name,
    'path': path,
    'summary': summary,
    'capabilities': capabilities,
    'last_updated': now
}

out_file = os.path.join(registry_dir, name + '.json')
tmp_file = out_file + '.tmp.' + str(os.getpid())
with open(tmp_file, 'w') as f:
    json.dump(skill, f, indent=2)
os.rename(tmp_file, out_file)

print(name)
" "$name" "$abs_path" "$summary" "$capabilities" "$REGISTRY_DIR"
}

cmd_list() {
  ensure_registry

  python3 -c "
import json, sys, os, glob

registry_dir = sys.argv[1]
pattern = os.path.join(registry_dir, '*.json')
files = sorted(glob.glob(pattern))

if not files:
    sys.exit(0)

for f in files:
    try:
        with open(f) as fh:
            d = json.load(fh)
        name = d.get('name', os.path.basename(f).replace('.json', ''))
        summary = d.get('summary', '')
        print(f'{name} — {summary}')
    except (json.JSONDecodeError, KeyError):
        pass
" "$REGISTRY_DIR"
}

cmd_get() {
  local skill_name="${3:-}"
  [ -z "$skill_name" ] && die "Usage: skill-registry.sh get <project-dir> <skill-name>"

  local skill_file="$REGISTRY_DIR/$skill_name.json"
  [ -f "$skill_file" ] || die "Skill not found: $skill_name"

  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(json.dumps(d, indent=2))
" "$skill_file"
}

cmd_prompt_block() {
  ensure_registry

  python3 -c "
import json, sys, os, glob

registry_dir = sys.argv[1]
pattern = os.path.join(registry_dir, '*.json')
files = sorted(glob.glob(pattern))

if not files:
    sys.exit(0)

print('## Available Skills')
for f in files:
    try:
        with open(f) as fh:
            d = json.load(fh)
        name = d.get('name', os.path.basename(f).replace('.json', ''))
        summary = d.get('summary', '')
        print(f'- **{name}**: {summary}')
    except (json.JSONDecodeError, KeyError):
        pass
" "$REGISTRY_DIR"
}

cmd_scan() {
  local search_dir="${3:-}"
  [ -z "$search_dir" ] && die "Usage: skill-registry.sh scan <project-dir> <search-dir>"
  [ -d "$search_dir" ] || die "Search directory not found: $search_dir"

  ensure_registry

  local count=0
  local skipped=0

  # Find all SKILL.md files recursively
  while IFS= read -r skill_file; do
    local skill_dir
    skill_dir=$(dirname "$skill_file")

    local name
    name=$(extract_skill_name "$skill_dir")

    # Skip if already registered
    if [ -f "$REGISTRY_DIR/$name.json" ]; then
      ((skipped++)) || true
      continue
    fi

    # Generate a summary from the file content
    local summary
    summary=$(auto_summary_from_content "$skill_file")
    if [ -z "$summary" ]; then
      summary="Skill from $skill_dir"
    fi

    # Register with --summary to avoid claude -p call
    bash "$0" register "$PROJECT" "$skill_dir" --summary "$summary" > /dev/null
    ((count++)) || true
  done < <(find "$search_dir" -name "SKILL.md" -type f 2>/dev/null | sort)

  echo "scanned: $count new, $skipped existing"
}

cmd_unregister() {
  local skill_name="${3:-}"
  [ -z "$skill_name" ] && die "Usage: skill-registry.sh unregister <project-dir> <skill-name>"

  local skill_file="$REGISTRY_DIR/$skill_name.json"
  [ -f "$skill_file" ] || die "Skill not found: $skill_name"

  rm -f "$skill_file"
  echo "unregistered: $skill_name"
}

# ── Dispatch ─────────────────────────────────────────────────────────────

[ -z "$CMD" ] && die "No command specified. Use: register|list|get|prompt-block|scan|unregister"

case "$CMD" in
  register)      cmd_register "$@" ;;
  list)          cmd_list ;;
  get)           cmd_get "$@" ;;
  prompt-block)  cmd_prompt_block ;;
  scan)          cmd_scan "$@" ;;
  unregister)    cmd_unregister "$@" ;;
  *)             die "Unknown command: $CMD. Use: register|list|get|prompt-block|scan|unregister" ;;
esac
