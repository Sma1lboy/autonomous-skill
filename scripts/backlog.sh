#!/usr/bin/env bash
# backlog.sh — Cross-session persistent backlog for the autonomous-skill conductor.
# Manages .autonomous/backlog.json with atomic writes and mkdir-based locking.
#
# Invariant: This script NEVER touches conductor-state.json.
# conductor-state.sh NEVER touches backlog.json. No cross-lock acquisition.
# Layer: shared

set -euo pipefail

usage() {
  cat << 'EOF'
Usage: backlog.sh <command> <project-dir> [args...]

Cross-session persistent backlog for the autonomous-skill conductor.
Manages .autonomous/backlog.json with atomic writes and mkdir-based locking.

Commands:
  init <project-dir>
      Create backlog.json if missing (idempotent).

  add <project-dir> <title> [description] [source] [priority] [dimension]
      Add a backlog item. Returns the item ID.
      source: conductor|worker|explore|user (default: user)
      priority: 1-5 (default: 3, or 4 if source=worker)
      dimension: one of the 8 exploration dimensions (optional)
      Max 50 open items; overflow force-prunes lowest priority.

  list <project-dir> [status] [titles-only]
      List items filtered by status (default: open).
      Pass "titles-only" as last arg for sprint master format.

  read <project-dir> <id>
      Read a single item with full detail (JSON).

  pick <project-dir>
      Pick the highest-priority open+triaged item, mark it in_progress.
      Exits 1 if no eligible items.

  update <project-dir> <id> <field> <value>
      Update an item field. Fields: status, priority, sprint, triaged.

  stats <project-dir>
      Summary counts by status.

  prune <project-dir> [max-age-days]
      Drop stale open items (priority >= 4, triaged=true, older than N days).
      Default: 30 days. Untriaged items are never auto-pruned.

Examples:
  bash scripts/backlog.sh init ./my-project
  bash scripts/backlog.sh add ./my-project "Fix auth bug" "Token refresh fails" worker 4 security
  bash scripts/backlog.sh list ./my-project open titles-only
  bash scripts/backlog.sh pick ./my-project
  bash scripts/backlog.sh update ./my-project bl-1234-1 status done
  bash scripts/backlog.sh prune ./my-project 14
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
BACKLOG_FILE="$STATE_DIR/backlog.json"
LOCK_DIR="$STATE_DIR/backlog.lock"
MAX_OPEN=50

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Locking (mkdir-based, POSIX atomic) ──────────────────────────────────

backlog_lock() {
  local deadline=$(($(date +%s) + 2))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # Stale lock — check if holder is alive
      local lock_pid=""
      [ -f "$LOCK_DIR/pid" ] && lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
      if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        die "Backlog locked by PID $lock_pid"
      fi
      # Stale lock, break it
      rm -rf "$LOCK_DIR" 2>/dev/null || true
      mkdir "$LOCK_DIR" 2>/dev/null || die "Cannot acquire backlog lock"
      break
    fi
    sleep 0.1
  done
  echo $$ > "$LOCK_DIR/pid"
}

backlog_unlock() {
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
  rm -f "$BACKLOG_FILE.tmp.$$" 2>/dev/null || true
  backlog_unlock
}
trap cleanup EXIT

# ── JSON I/O ─────────────────────────────────────────────────────────────

read_backlog() {
  if [ ! -f "$BACKLOG_FILE" ]; then
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
" "$BACKLOG_FILE" 2>/dev/null || echo '{"version":1,"items":[]}'
}

write_backlog() {
  local json_str="$1"
  python3 -c "
import json, sys, os
try:
    d = json.loads(sys.argv[1])
    bf = sys.argv[2]
    tmp = bf + '.tmp.' + str(os.getpid())
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=2)
    os.rename(tmp, bf)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" "$json_str" "$BACKLOG_FILE"
}

# ── Commands ─────────────────────────────────────────────────────────────

cmd_init() {
  mkdir -p "$STATE_DIR"
  if [ ! -f "$BACKLOG_FILE" ]; then
    write_backlog '{"version":1,"items":[]}'
    echo "initialized"
  else
    echo "exists"
  fi
}

cmd_add() {
  local title="${3:-}"
  local description="${4:-}"
  local source="${5:-user}"
  local priority="${6:-}"
  local dimension="${7:-}"

  [ -z "$title" ] && die "Usage: backlog.sh add <project-dir> <title> [description] [source] [priority] [dimension]"

  # Validate source
  case "$source" in
    conductor|worker|explore|user) ;;
    *) die "Invalid source: $source (valid: conductor, worker, explore, user)" ;;
  esac

  # Default priority: 4 for worker, 3 for others
  if [ -z "$priority" ]; then
    if [ "$source" = "worker" ]; then
      priority=4
    else
      priority=3
    fi
  fi

  # Validate priority
  case "$priority" in
    1|2|3|4|5) ;;
    *) die "Invalid priority: $priority (valid: 1-5)" ;;
  esac

  # Validate dimension if provided
  if [ -n "$dimension" ]; then
    local valid_dims="test_coverage error_handling security code_quality documentation architecture performance dx"
    echo "$valid_dims" | grep -qw "$dimension" || die "Invalid dimension: $dimension"
  fi

  mkdir -p "$STATE_DIR"
  backlog_lock

  local state
  state=$(read_backlog)

  local triaged="false"
  if [ "$source" != "worker" ]; then
    triaged="true"
  fi

  local updated
  updated=$(python3 -c "
import json, sys, time, re

d = json.loads(sys.argv[1])
title = sys.argv[2]
description = sys.argv[3]
source = sys.argv[4]
priority = int(sys.argv[5])
dimension = sys.argv[6] if sys.argv[6] else None
triaged = sys.argv[7] == 'true'

# Sanitize title: strip control chars and newlines, truncate to 120
title = re.sub(r'[\x00-\x1f\x7f]', '', title)[:120]

items = d.get('items', [])
ts = int(time.time())
seq = len(items) + 1
item_id = f'bl-{ts}-{seq}'
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

# Check open count and force-prune if needed
open_items = [i for i in items if i.get('status') == 'open']
pruned_ids = []
max_open = int(sys.argv[8])
while len(open_items) >= max_open:
    # Find lowest priority (highest number), then oldest
    candidates = sorted(open_items, key=lambda x: (-x.get('priority', 3), x.get('created_at', '')))
    victim = candidates[0]
    victim['status'] = 'dropped'
    victim['updated_at'] = now
    pruned_ids.append(victim['id'])
    open_items = [i for i in items if i.get('status') == 'open']

new_item = {
    'id': item_id,
    'type': 'task',
    'title': title,
    'description': description,
    'status': 'open',
    'priority': priority,
    'source': source,
    'source_detail': '',
    'dimension': dimension,
    'triaged': triaged,
    'created_at': now,
    'updated_at': now,
    'sprint_consumed': None
}

items.append(new_item)
d['items'] = items

# Output: first line is the item ID, pruned IDs go to stderr
import os
if pruned_ids:
    for pid in pruned_ids:
        print(f'WARNING: pruned {pid} to stay under {max_open} cap', file=sys.stderr)
print(json.dumps(d))
" "$state" "$title" "$description" "$source" "$priority" "${dimension:-}" "$triaged" "$MAX_OPEN")

  # Extract the item ID from the updated state
  local item_id
  item_id=$(python3 -c "import json,sys; items=json.loads(sys.argv[1])['items']; print(items[-1]['id'])" "$updated")

  write_backlog "$updated"
  echo "$item_id"
}

cmd_list() {
  local status_filter="${3:-open}"
  local titles_only="${4:-}"

  # Validate status filter
  case "$status_filter" in
    open|in_progress|done|dropped|all) ;;
    titles-only)
      # User passed titles-only as the status arg
      titles_only="titles-only"
      status_filter="open"
      ;;
    *) die "Invalid status filter: $status_filter (valid: open, in_progress, done, dropped, all)" ;;
  esac

  local state
  state=$(read_backlog)

  if [ "$titles_only" = "titles-only" ]; then
    python3 -c "
import json, sys

d = json.loads(sys.argv[1])
status_filter = sys.argv[2]
items = d.get('items', [])

if status_filter != 'all':
    items = [i for i in items if i.get('status') == status_filter]

# Sort by priority ascending (P1 first), then by created_at ascending (older first)
items.sort(key=lambda x: (x.get('priority', 3), x.get('created_at', '')))

print(f'[{len(items)} {status_filter} items]')
for item in items:
    p = item.get('priority', 3)
    title = item.get('title', '')
    print(f'- [P{p}] {title}')
" "$state" "$status_filter"
  else
    python3 -c "
import json, sys

d = json.loads(sys.argv[1])
status_filter = sys.argv[2]
items = d.get('items', [])

if status_filter != 'all':
    items = [i for i in items if i.get('status') == status_filter]

items.sort(key=lambda x: (x.get('priority', 3), x.get('created_at', '')))
print(json.dumps(items, indent=2))
" "$state" "$status_filter"
  fi
}

cmd_read() {
  local item_id="${3:-}"
  [ -z "$item_id" ] && die "Usage: backlog.sh read <project-dir> <id>"

  local state
  state=$(read_backlog)

  python3 -c "
import json, sys

d = json.loads(sys.argv[1])
target_id = sys.argv[2]
items = d.get('items', [])

for item in items:
    if item.get('id') == target_id:
        print(json.dumps(item, indent=2))
        sys.exit(0)

print(f'ERROR: item not found: {target_id}', file=sys.stderr)
sys.exit(1)
" "$state" "$item_id"
}

cmd_pick() {
  backlog_lock

  local state
  state=$(read_backlog)

  local result
  result=$(python3 -c "
import json, sys, time

d = json.loads(sys.argv[1])
items = d.get('items', [])
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())

# Find eligible items: open and triaged
eligible = [i for i in items if i.get('status') == 'open' and i.get('triaged', False)]

if not eligible:
    # Fallback: any open item
    eligible = [i for i in items if i.get('status') == 'open']

if not eligible:
    print('NO_ITEMS', file=sys.stderr)
    sys.exit(1)

# Sort by priority ascending (P1 first), then older first
eligible.sort(key=lambda x: (x.get('priority', 3), x.get('created_at', '')))
picked = eligible[0]

# Mark in_progress
for item in items:
    if item.get('id') == picked['id']:
        item['status'] = 'in_progress'
        item['updated_at'] = now
        break

d['items'] = items

# Output: JSON of the state on first line, picked item on second
print(json.dumps(d))
print('---PICKED---')
print(json.dumps(picked, indent=2))
" "$state" 2>/dev/null) || {
    echo "ERROR: no open items in backlog" >&2
    return 1
  }

  # Split output: state update vs picked item
  local updated_state picked_item
  updated_state=$(echo "$result" | sed -n '1p')
  picked_item=$(echo "$result" | sed -n '/^---PICKED---$/,$ p' | tail -n +2)

  write_backlog "$updated_state"
  echo "$picked_item"
}

cmd_update() {
  local item_id="${3:-}"
  local field="${4:-}"
  local value="${5:-}"

  [ -z "$item_id" ] || [ -z "$field" ] && die "Usage: backlog.sh update <project-dir> <id> <field> <value>"

  # Validate field
  case "$field" in
    status)
      case "$value" in
        open|in_progress|done|dropped) ;;
        *) die "Invalid status: $value (valid: open, in_progress, done, dropped)" ;;
      esac
      ;;
    priority)
      case "$value" in
        1|2|3|4|5) ;;
        *) die "Invalid priority: $value (valid: 1-5)" ;;
      esac
      ;;
    sprint)
      python3 -c "int('$value')" 2>/dev/null || die "sprint must be numeric, got: $value"
      ;;
    triaged)
      case "$value" in
        true|false) ;;
        *) die "Invalid triaged value: $value (valid: true, false)" ;;
      esac
      ;;
    *) die "Invalid field: $field (valid: status, priority, sprint, triaged)" ;;
  esac

  backlog_lock

  local state
  state=$(read_backlog)

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
        if field == 'status':
            item['status'] = value
        elif field == 'priority':
            item['priority'] = int(value)
        elif field == 'sprint':
            item['sprint_consumed'] = int(value)
        elif field == 'triaged':
            item['triaged'] = value == 'true'
        item['updated_at'] = now
        break

if not found:
    print(f'ERROR: item not found: {target_id}', file=sys.stderr)
    sys.exit(1)

d['items'] = items
print(json.dumps(d))
" "$state" "$item_id" "$field" "$value")

  write_backlog "$updated"
  echo "ok"
}

cmd_stats() {
  local state
  state=$(read_backlog)

  python3 -c "
import json, sys

d = json.loads(sys.argv[1])
items = d.get('items', [])

counts = {}
for item in items:
    s = item.get('status', 'unknown')
    counts[s] = counts.get(s, 0) + 1

total = len(items)
print(f'total: {total}')
for status in ['open', 'in_progress', 'done', 'dropped']:
    c = counts.get(status, 0)
    if c > 0:
        print(f'{status}: {c}')

# Untriaged count
untriaged = sum(1 for i in items if not i.get('triaged', True) and i.get('status') == 'open')
if untriaged > 0:
    print(f'untriaged: {untriaged}')
" "$state"
}

cmd_prune() {
  local max_age_days="${3:-30}"

  # Validate max_age_days
  python3 -c "
v = int('$max_age_days')
if v < 0:
    raise ValueError('negative')
" 2>/dev/null || die "max-age-days must be a non-negative integer, got: $max_age_days"

  backlog_lock

  local state
  state=$(read_backlog)

  local updated
  updated=$(python3 -c "
import json, sys, time
from datetime import datetime, timedelta, timezone

d = json.loads(sys.argv[1])
max_age_days = int(sys.argv[2])
items = d.get('items', [])
now = datetime.now(timezone.utc)
cutoff = now - timedelta(days=max_age_days)

pruned = []
kept = []
for item in items:
    # Only prune: open, priority >= 4, triaged=true, old enough
    if (item.get('status') == 'open'
        and item.get('priority', 3) >= 4
        and item.get('triaged', False)
        and item.get('created_at', '')):
        try:
            created = datetime.fromisoformat(item['created_at'].replace('Z', '+00:00'))
            if created < cutoff:
                item['status'] = 'dropped'
                item['updated_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
                pruned.append(item['id'])
        except (ValueError, KeyError):
            pass
    kept.append(item)

d['items'] = kept
for pid in pruned:
    print(f'pruned: {pid}', file=sys.stderr)
print(json.dumps(d))
" "$state" "$max_age_days")

  write_backlog "$updated"

  local pruned_count
  pruned_count=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(sum(1 for i in d['items'] if i.get('status') == 'dropped'))
" "$updated")
  echo "pruned: checked (dropped items: $pruned_count)"
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "$CMD" in
  init)    cmd_init ;;
  add)     cmd_add "$@" ;;
  list)    cmd_list "$@" ;;
  read)    cmd_read "$@" ;;
  pick)    cmd_pick ;;
  update)  cmd_update "$@" ;;
  stats)   cmd_stats ;;
  prune)   cmd_prune "$@" ;;
  *)       die "Unknown command: $CMD. Use: init|add|list|read|pick|update|stats|prune" ;;
esac
