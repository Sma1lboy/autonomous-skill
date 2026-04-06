#!/usr/bin/env bash
# measure-prompt.sh — Measure prompt file size and section breakdown
#
# Usage: bash measure-prompt.sh [--json] <prompt_file>
#
# Reports total lines, chars, words, and per-section breakdown.
# Layer: shared

set -euo pipefail

usage() {
  echo "Usage: bash measure-prompt.sh [--json] <prompt_file>"
  echo ""
  echo "Measure a prompt file's size and section breakdown."
  echo ""
  echo "Options:"
  echo "  --json    Machine-readable JSON output"
  echo "  --help    Show this help"
}

JSON_MODE=false

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --help|-h|help) usage; exit 0 ;;
    --json) JSON_MODE=true; shift ;;
    -*) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) break ;;
  esac
done

PROMPT_FILE="${1:?ERROR: prompt file path required}"

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: file not found: $PROMPT_FILE" >&2
  exit 1
fi

# Total metrics
TOTAL_LINES=$(wc -l < "$PROMPT_FILE" | tr -d ' ')
TOTAL_CHARS=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
TOTAL_WORDS=$(wc -w < "$PROMPT_FILE" | tr -d ' ')

# Parse sections (lines starting with ## )
declare -a SECTION_NAMES=()
declare -a SECTION_LINES=()
declare -a SECTION_CHARS=()

CURRENT_SECTION=""
CURRENT_LINES=0
CURRENT_CHARS=0
HAS_SECTIONS=false

flush_section() {
  if [ -n "$CURRENT_SECTION" ]; then
    SECTION_NAMES+=("$CURRENT_SECTION")
    SECTION_LINES+=("$CURRENT_LINES")
    SECTION_CHARS+=("$CURRENT_CHARS")
  fi
}

while IFS= read -r line || [ -n "$line" ]; do
  if [[ "$line" =~ ^##\  ]]; then
    HAS_SECTIONS=true
    flush_section
    CURRENT_SECTION="${line#\#\# }"
    CURRENT_LINES=0
    CURRENT_CHARS=0
  fi
  if [ -n "$CURRENT_SECTION" ]; then
    ((CURRENT_LINES++)) || true
    CURRENT_CHARS=$((CURRENT_CHARS + ${#line} + 1))
  fi
done < "$PROMPT_FILE"
flush_section

if [ "$JSON_MODE" = true ]; then
  # JSON output
  printf '{"total_lines":%d,"total_chars":%d,"total_words":%d,"sections":[' \
    "$TOTAL_LINES" "$TOTAL_CHARS" "$TOTAL_WORDS"
  for i in "${!SECTION_NAMES[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    printf '{"name":"%s","lines":%d,"chars":%d}' \
      "${SECTION_NAMES[$i]}" "${SECTION_LINES[$i]}" "${SECTION_CHARS[$i]}"
  done
  printf ']}\n'
else
  # Human-readable output
  echo "=== Prompt Metrics ==="
  echo "Total lines: $TOTAL_LINES"
  echo "Total chars: $TOTAL_CHARS"
  echo "Total words: $TOTAL_WORDS"
  if [ "$HAS_SECTIONS" = true ]; then
    echo ""
    echo "=== Sections ==="
    for i in "${!SECTION_NAMES[@]}"; do
      printf "  %-40s %5d lines  %6d chars\n" \
        "${SECTION_NAMES[$i]}" "${SECTION_LINES[$i]}" "${SECTION_CHARS[$i]}"
    done
  fi
fi
