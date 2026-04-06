#!/usr/bin/env bash
# learnings.sh — Cross-session persistent sprint learnings for the autonomous-skill conductor.
# Manages .autonomous/learnings.json with atomic writes and mkdir-based locking.
#
# Invariant: This script NEVER touches conductor-state.json or backlog.json.

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: learnings.sh <command> <project-dir> [args...]

Cross-session persistent sprint learnings for the autonomous-skill conductor.
Manages .autonomous/learnings.json with atomic writes and mkdir-based locking.

Commands:
  init <project-dir>
      Create learnings.json if missing (idempotent).

  add <project-dir> <type> <content> [confidence] [tags] [source] [sprint]
      Add a learning item. Returns the item ID.
      type: success|failure|quirk|pattern (required)
      content: the learning text (required)
      confidence: 1-10 (default: 5)
      tags: comma-separated tags (default: "")
      source: conductor|worker|sprint-master (default: worker)
      sprint: sprint number reference (default: "")
      Max 100 items; overflow prunes lowest confidence items.

  list <project-dir> [type] [format]
      List learnings filtered by type (default: all).
      type: success|failure|quirk|pattern|all
      format: full|compact (default: full)
      full: JSON array. compact: one-liner per item.

  search <project-dir> <query>
      Search learnings by content and tags (case-insensitive substring match).
      Returns matching items in compact format.

  summary <project-dir>
      Compact one-liner format for sprint prompt injection.
      Top 20 by confidence. Symbols: success=✓, failure=✗, quirk=?, pattern=⟳

  update <project-dir> <id> <field> <value>
      Update a learning field. Fields: confidence, tags, type, archived.

  stats <project-dir>
      Summary counts by type, average confidence, total count.

  prune <project-dir> [min-confidence]
      Archive learnings below confidence threshold (default: 3).
      Only prunes non-archived items.

Examples:
  bash scripts/learnings.sh init ./my-project
  bash scripts/learnings.sh add ./my-project success "Tests catch regressions early" 8 "testing,workflow" worker 3
  bash scripts/learnings.sh list ./my-project failure compact
  bash scripts/learnings.sh search ./my-project "testing"
  bash scripts/learnings.sh summary ./my-project
  bash scripts/learnings.sh update ./my-project ln-1234-1 confidence 9
  bash scripts/learnings.sh prune ./my-project 4
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
STATE_DIR="$PROJECT/.autonomous"
LEARNINGS_FILE="$STATE_DIR/learnings.json"
LOCK_DIR="$STATE_DIR/learnings.lock"
MAX_ITEMS=100

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Locking (mkdir-based, POSIX atomic) ──────────────────────────────────

learnings_lock() {
  local deadline=$(($(date +%s) + 2))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # Stale lock — check if holder is alive
      local lock_pid=""
      [ -f "$LOCK_DIR/pid" ] && lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
      if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        die "Learnings locked by PID $lock_pid"
      fi
      # Stale lock, break it
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      mkdir "$LOCK_DIR" 2>/dev/null || die "Cannot acquire learnings lock"
      break
    fi
    sleep 0.1
  done
  echo $$ > "$LOCK_DIR/pid"
}

learnings_unlock() {
  if [ -d "$LOCK_DIR" ] 2>/dev/null; then
    local lock_pid=""
    [ -f "$LOCK_DIR/pid" ] && lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ "$lock_pid" = "$$" ] || [ -z "$lock_pid" ]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}

# ── Cleanup ──────────────────────────────────────────────────────────────

cleanup() {
  rm -f "$LEARNINGS_FILE.tmp.$$" 2>/dev/null || true
  learnings_unlock
}
trap cleanup EXIT

# ── JSON I/O ─────────────────────────────────────────────────────────────

read_learnings() {
  if [ ! -f "$LEARNINGS_FILE" ]; then
    echo '{"version":1,"items":[]}'
    return 0
  fi
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    json.dump(d, sys.stdout)
except (json.JSONDecodeError, FileNotFoundError):
    print('{\"version\":1,\"items\":[]}')
" "$LEARNINGS_FILE" 2>/dev/null || echo '{"version":1,"items":[]}'
}

write_learnings() {
  local json_str="$1"
  python3 -c "
import json, sys, os
try:
    d = json.loads(sys.argv[1])
    lf = sys.argv[2]
    tmp = lf + '.tmp.' + str(os.getpid())
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=2)
    os.rename(tmp, lf)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" "$json_str" "$LEARNINGS_FILE"
}

# ── Commands ─────────────────────────────────────────────────────────────

cmd_init() {
  mkdir -p "$STATE_DIR"
  if [ ! -f "$LEARNINGS_FILE" ]; then
    write_learnings '{"version":1,"items":[]}'
    echo "initialized"
  else
    echo "exists"
  fi
}

cmd_add() {
  local type="${3:-}"
  local content="${4:-}"
  local confidence="${5:-5}"
  local tags="${6:-}"
  local source="${7:-worker}"
  local sprint="${8:-}"

  [ -z "$type" ] && die "Usage: learnings.sh add <project-dir> <type> <content> [confidence] [tags] [source] [sprint]"
  [ -z "$content" ] && die "Usage: learnings.sh add <project-dir> <type> <content> [confidence] [tags] [source] [sprint]"

  # Validate type
  case "$type" in
    success|failure|quirk|pattern) ;;
    *) die "Invalid type: $type (valid: success, failure, quirk, pattern)" ;;
  esac

  # Validate confidence
  case "$confidence" in
    1|2|3|4|5|6|7|8|9|10) ;;
    *) die "Invalid confidence: $confidence (valid: 1-10)" ;;
  esac

  # Validate source
  case "$source" in
    conductor|worker|sprint-master) ;;
    *) die "Invalid source: $source (valid: conductor, worker, sprint-master)" ;;
  esac

  mkdir -p "$STATE_DIR"
  learnings_lock

  local state
  state=$(read_learnings)

  local updated
  updated=$(python3 -c "
import json, sys, time

d = json.loads(sys.argv[1])
item_type = sys.argv[2]
content = sys.argv[3]
confidence = int(sys.argv[4])
tags_str = sys.argv[5]
source = sys.argv[6]
sprint = sys.argv[7]
max_items = int(sys.argv[8])

tags = [t.strip() for t in tags_str.split(',') if t.strip()] if tags_str else []

items = d.get('items', [])
ts = int(time.time())
seq = len(items) + 1
item_id = f'ln-{ts}-{seq}'
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

# Check non-archived count and prune if needed
active_items = [i for i in items if not i.get('archived', False)]
while len(active_items) >= max_items:
    # Find lowest confidence, then oldest
    candidates = sorted(active_items, key=lambda x: (x.get('confidence', 5), x.get('created_at', '')))
    victim = candidates[0]
    victim['archived'] = True
    victim['updated_at'] = now
    print(f'WARNING: archived {victim[\"id\"]} (confidence {victim.get(\"confidence\",5)}) to stay under {max_items} cap', file=sys.stderr)
    active_items = [i for i in items if not i.get('archived', False)]

new_item = {
    'id': item_id,
    'type': item_type,
    'content': content,
    'confidence': confidence,
    'tags': tags,
    'source': source,
    'sprint_ref': sprint,
    'archived': False,
    'created_at': now,
    'updated_at': now
}

items.append(new_item)
d['items'] = items
print(json.dumps(d))
" "$state" "$type" "$content" "$confidence" "$tags" "$source" "$sprint" "$MAX_ITEMS")

  # Extract the item ID from the updated state
  local item_id
  item_id=$(python3 -c "import json,sys; items=json.loads(sys.argv[1])['items']; print(items[-1]['id'])" "$updated")

  write_learnings "$updated"
  echo "$item_id"
}

cmd_list() {
  local type_filter="${3:-all}"
  local format="${4:-full}"

  # Validate type filter
  case "$type_filter" in
    success|failure|quirk|pattern|all) ;;
    full|compact)
      # User passed format as the type arg
      format="$type_filter"
      type_filter="all"
      ;;
    *) die "Invalid type filter: $type_filter (valid: success, failure, quirk, pattern, all)" ;;
  esac

  # Validate format
  case "$format" in
    full|compact) ;;
    *) die "Invalid format: $format (valid: full, compact)" ;;
  esac

  local state
  state=$(read_learnings)

  if [ "$format" = "compact" ]; then
    python3 -c "
import json, sys

d = json.loads(sys.argv[1])
type_filter = sys.argv[2]
items = d.get('items', [])

# Exclude archived
items = [i for i in items if not i.get('archived', False)]

if type_filter != 'all':
    items = [i for i in items if i.get('type') == type_filter]

# Sort by confidence descending
items.sort(key=lambda x: -x.get('confidence', 5))

symbols = {'success': '✓', 'failure': '✗', 'quirk': '?', 'pattern': '⟳'}

for item in items:
    sym = symbols.get(item.get('type', ''), '?')
    content = item.get('content', '')
    conf = item.get('confidence', 5)
    tags = item.get('tags', [])
    tag_str = ', tags:' + ','.join(tags) if tags else ''
    print(f'{sym} {content} (confidence:{conf}{tag_str})')
" "$state" "$type_filter"
  else
    python3 -c "
import json, sys

d = json.loads(sys.argv[1])
type_filter = sys.argv[2]
items = d.get('items', [])

# Exclude archived
items = [i for i in items if not i.get('archived', False)]

if type_filter != 'all':
    items = [i for i in items if i.get('type') == type_filter]

items.sort(key=lambda x: -x.get('confidence', 5))
print(json.dumps(items, indent=2))
" "$state" "$type_filter"
  fi
}

cmd_search() {
  local query="${3:-}"
  [ -z "$query" ] && die "Usage: learnings.sh search <project-dir> <query>"

  local state
  state=$(read_learnings)

  python3 -c "
import json, sys

d = json.loads(sys.argv[1])
query = sys.argv[2].lower()
items = d.get('items', [])

# Exclude archived
items = [i for i in items if not i.get('archived', False)]

symbols = {'success': '✓', 'failure': '✗', 'quirk': '?', 'pattern': '⟳'}
matches = []
for item in items:
    content = item.get('content', '').lower()
    tags = [t.lower() for t in item.get('tags', [])]
    if query in content or any(query in t for t in tags):
        matches.append(item)

matches.sort(key=lambda x: -x.get('confidence', 5))
for item in matches:
    sym = symbols.get(item.get('type', ''), '?')
    content = item.get('content', '')
    conf = item.get('confidence', 5)
    tags = item.get('tags', [])
    tag_str = ', tags:' + ','.join(tags) if tags else ''
    print(f'{sym} {content} (confidence:{conf}{tag_str})')
" "$state" "$query"
}

cmd_summary() {
  local state
  state=$(read_learnings)

  python3 -c "
import json, sys

d = json.loads(sys.argv[1])
items = d.get('items', [])

# Exclude archived
items = [i for i in items if not i.get('archived', False)]

# Sort by confidence descending, take top 20
items.sort(key=lambda x: -x.get('confidence', 5))
items = items[:20]

symbols = {'success': '✓', 'failure': '✗', 'quirk': '?', 'pattern': '⟳'}

print(f'[LEARNINGS: {len(items)} items]')
for item in items:
    sym = symbols.get(item.get('type', ''), '?')
    content = item.get('content', '')
    conf = item.get('confidence', 5)
    tags = item.get('tags', [])
    tag_str = ', tags:' + ','.join(tags) if tags else ''
    print(f'{sym} {content} (confidence:{conf}{tag_str})')
" "$state"
}

cmd_update() {
  local item_id="${3:-}"
  local field="${4:-}"
  local value="${5:-}"

  [ -z "$item_id" ] || [ -z "$field" ] && die "Usage: learnings.sh update <project-dir> <id> <field> <value>"

  # Validate field
  case "$field" in
    confidence)
      case "$value" in
        1|2|3|4|5|6|7|8|9|10) ;;
        *) die "Invalid confidence: $value (valid: 1-10)" ;;
      esac
      ;;
    tags)
      # Any string is valid for tags
      ;;
    type)
      case "$value" in
        success|failure|quirk|pattern) ;;
        *) die "Invalid type: $value (valid: success, failure, quirk, pattern)" ;;
      esac
      ;;
    archived)
      case "$value" in
        true|false) ;;
        *) die "Invalid archived value: $value (valid: true, false)" ;;
      esac
      ;;
    *) die "Invalid field: $field (valid: confidence, tags, type, archived)" ;;
  esac

  learnings_lock

  local state
  state=$(read_learnings)

  local updated
  updated=$(python3 -c "
import json, sys, time

d = json.loads(sys.argv[1])
target_id = sys.argv[2]
field = sys.argv[3]
value = sys.argv[4]
items = d.get('items', [])
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

found = False
for item in items:
    if item.get('id') == target_id:
        found = True
        if field == 'confidence':
            item['confidence'] = int(value)
        elif field == 'tags':
            item['tags'] = [t.strip() for t in value.split(',') if t.strip()] if value else []
        elif field == 'type':
            item['type'] = value
        elif field == 'archived':
            item['archived'] = value == 'true'
        item['updated_at'] = now
        break

if not found:
    print(f'ERROR: item not found: {target_id}', file=sys.stderr)
    sys.exit(1)

d['items'] = items
print(json.dumps(d))
" "$state" "$item_id" "$field" "$value")

  write_learnings "$updated"
  echo "ok"
}

cmd_stats() {
  local state
  state=$(read_learnings)

  python3 -c "
import json, sys

d = json.loads(sys.argv[1])
items = d.get('items', [])

# Exclude archived for active stats
active = [i for i in items if not i.get('archived', False)]
archived_count = sum(1 for i in items if i.get('archived', False))

type_counts = {}
confidences = []
for item in active:
    t = item.get('type', 'unknown')
    type_counts[t] = type_counts.get(t, 0) + 1
    confidences.append(item.get('confidence', 5))

total = len(active)
avg_conf = sum(confidences) / len(confidences) if confidences else 0

print(f'total: {total}')
for t in ['success', 'failure', 'quirk', 'pattern']:
    c = type_counts.get(t, 0)
    if c > 0:
        print(f'{t}: {c}')
print(f'avg_confidence: {avg_conf:.1f}')
if archived_count > 0:
    print(f'archived: {archived_count}')
" "$state"
}

cmd_prune() {
  local min_confidence="${3:-3}"

  # Validate min_confidence
  case "$min_confidence" in
    1|2|3|4|5|6|7|8|9|10) ;;
    *) die "Invalid min-confidence: $min_confidence (valid: 1-10)" ;;
  esac

  learnings_lock

  local state
  state=$(read_learnings)

  local updated
  updated=$(python3 -c "
import json, sys, time

d = json.loads(sys.argv[1])
min_conf = int(sys.argv[2])
items = d.get('items', [])
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

pruned = 0
for item in items:
    if not item.get('archived', False) and item.get('confidence', 5) < min_conf:
        item['archived'] = True
        item['updated_at'] = now
        pruned += 1

d['items'] = items
print(json.dumps(d))
print(f'pruned: {pruned}', file=sys.stderr)
" "$state" "$min_confidence" 2>/dev/null)

  write_learnings "$updated"

  local active_count archived_count
  active_count=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(sum(1 for i in d['items'] if not i.get('archived',False)))" "$updated")
  archived_count=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(sum(1 for i in d['items'] if i.get('archived',False)))" "$updated")
  echo "pruned: checked (active: $active_count, archived: $archived_count)"
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "$CMD" in
  init)    cmd_init ;;
  add)     cmd_add "$@" ;;
  list)    cmd_list "$@" ;;
  search)  cmd_search "$@" ;;
  summary) cmd_summary ;;
  update)  cmd_update "$@" ;;
  stats)   cmd_stats ;;
  prune)   cmd_prune "$@" ;;
  *)       die "Unknown command: $CMD. Use: init|add|list|search|summary|update|stats|prune" ;;
esac
