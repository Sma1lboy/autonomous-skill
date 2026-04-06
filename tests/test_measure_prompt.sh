#!/usr/bin/env bash
# Tests for scripts/measure-prompt.sh — prompt size measurement.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEASURE="$SCRIPT_DIR/../scripts/measure-prompt.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " test_measure_prompt.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# 1. --help flag
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "1. --help flag"

HELP=$(bash "$MEASURE" --help 2>&1)
assert_contains "$HELP" "Usage:" "--help shows Usage"
assert_contains "$HELP" "prompt_file" "--help mentions prompt_file"
assert_contains "$HELP" "json" "--help mentions --json"

bash "$MEASURE" --help >/dev/null 2>&1
assert_eq "$?" "0" "--help exits 0"

HELP_SHORT=$(bash "$MEASURE" -h 2>&1)
assert_contains "$HELP_SHORT" "Usage:" "-h shows Usage"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Basic invocation
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "2. Basic invocation"

T=$(new_tmp)
printf 'line one\nline two\nline three\n' > "$T/prompt.md"

OUT=$(bash "$MEASURE" "$T/prompt.md" 2>&1)
assert_contains "$OUT" "Total lines: 3" "reports 3 lines"
assert_contains "$OUT" "Total words:" "reports word count"
assert_contains "$OUT" "Total chars:" "reports char count"
assert_contains "$OUT" "Prompt Metrics" "has metrics header"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Section breakdown
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "3. Section breakdown"

T=$(new_tmp)
cat > "$T/prompt.md" << 'EOF'
# Header
Some intro text

## Input
Line A
Line B

## Startup
Run this command

## Worker Prompt
Write the prompt
And dispatch
EOF

OUT=$(bash "$MEASURE" "$T/prompt.md" 2>&1)
assert_contains "$OUT" "Sections" "shows sections header"
assert_contains "$OUT" "Input" "lists Input section"
assert_contains "$OUT" "Startup" "lists Startup section"
assert_contains "$OUT" "Worker Prompt" "lists Worker Prompt section"

# ═══════════════════════════════════════════════════════════════════════════
# 4. --json output
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "4. --json output"

T=$(new_tmp)
cat > "$T/prompt.md" << 'EOF'
## Alpha
hello world

## Beta
one two three
four five
EOF

OUT=$(bash "$MEASURE" --json "$T/prompt.md" 2>&1)
assert_contains "$OUT" '"total_lines"' "JSON has total_lines"
assert_contains "$OUT" '"total_chars"' "JSON has total_chars"
assert_contains "$OUT" '"total_words"' "JSON has total_words"
assert_contains "$OUT" '"sections"' "JSON has sections array"
assert_contains "$OUT" '"Alpha"' "JSON has Alpha section"
assert_contains "$OUT" '"Beta"' "JSON has Beta section"

# Validate JSON is parseable
python3 -c "import json,sys; json.loads(sys.stdin.read())" < <(echo "$OUT") 2>/dev/null
assert_eq "$?" "0" "JSON output is valid JSON"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Empty file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "5. Empty file"

T=$(new_tmp)
touch "$T/empty.md"

OUT=$(bash "$MEASURE" "$T/empty.md" 2>&1)
assert_contains "$OUT" "Total lines: 0" "empty file has 0 lines"
assert_contains "$OUT" "Total words: 0" "empty file has 0 words"

# ═══════════════════════════════════════════════════════════════════════════
# 6. File with no sections
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "6. File with no sections"

T=$(new_tmp)
printf 'just some text\nno section headers here\n' > "$T/nosect.md"

OUT=$(bash "$MEASURE" "$T/nosect.md" 2>&1)
assert_contains "$OUT" "Total lines: 2" "no-section file has 2 lines"
assert_not_contains "$OUT" "Sections" "no sections header when none found"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Missing file → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "7. Missing file → error"

RC=0
ERR=$(bash "$MEASURE" "/nonexistent/file.md" 2>&1) || RC=$?
assert_eq "$RC" "1" "missing file exits 1"
assert_contains "$ERR" "file not found" "error mentions file not found"

# ═══════════════════════════════════════════════════════════════════════════
# 8. No arguments → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "8. No arguments → error"

RC=0
bash "$MEASURE" 2>/dev/null || RC=$?
assert_ge "$RC" "1" "no args exits non-zero"

# ═══════════════════════════════════════════════════════════════════════════
# 9. JSON with no sections
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "9. JSON with no sections"

T=$(new_tmp)
printf 'no sections here\n' > "$T/plain.md"

OUT=$(bash "$MEASURE" --json "$T/plain.md" 2>&1)
assert_contains "$OUT" '"sections":\[\]' "JSON has empty sections array"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Section line counts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "10. Section line counts"

T=$(new_tmp)
cat > "$T/prompt.md" << 'EOF'
## First
a
b
## Second
c
EOF

OUT=$(bash "$MEASURE" --json "$T/prompt.md" 2>&1)
# First section: ## First, a, b = 3 lines; Second section: ## Second, c = 2 lines
FIRST_LINES=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['sections'][0]['lines'])" <<< "$OUT")
SECOND_LINES=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['sections'][1]['lines'])" <<< "$OUT")
assert_eq "$FIRST_LINES" "3" "First section has 3 lines"
assert_eq "$SECOND_LINES" "2" "Second section has 2 lines"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Single section
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "11. Single section"

T=$(new_tmp)
printf '## Only\njust one section\n' > "$T/one.md"

OUT=$(bash "$MEASURE" --json "$T/one.md" 2>&1)
SECT_COUNT=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d['sections']))" <<< "$OUT")
assert_eq "$SECT_COUNT" "1" "single section counted"

SECT_NAME=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['sections'][0]['name'])" <<< "$OUT")
assert_eq "$SECT_NAME" "Only" "section name is 'Only'"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Real SPRINT.md measurement
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "12. Real SPRINT.md measurement"

SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT=$(bash "$MEASURE" "$SKILL_DIR/SPRINT.md" 2>&1)
assert_contains "$OUT" "Total lines:" "measures real SPRINT.md lines"
assert_contains "$OUT" "Sections" "real SPRINT.md has sections"

# ═══════════════════════════════════════════════════════════════════════════
# 13. Unknown option → error
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "13. Unknown option → error"

RC=0
ERR=$(bash "$MEASURE" --bad-flag 2>&1) || RC=$?
assert_eq "$RC" "1" "unknown flag exits 1"
assert_contains "$ERR" "Unknown option" "error mentions unknown option"

# ═══════════════════════════════════════════════════════════════════════════
# 14. JSON total_words matches wc
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "14. JSON total_words matches wc"

T=$(new_tmp)
printf 'one two three\nfour five\n' > "$T/words.md"

OUT=$(bash "$MEASURE" --json "$T/words.md" 2>&1)
JSON_WORDS=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['total_words'])" <<< "$OUT")
WC_WORDS=$(wc -w < "$T/words.md" | tr -d ' ')
assert_eq "$JSON_WORDS" "$WC_WORDS" "JSON word count matches wc"

# ═══════════════════════════════════════════════════════════════════════════
# 15. JSON empty file
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "15. JSON empty file"

T=$(new_tmp)
touch "$T/empty.md"

OUT=$(bash "$MEASURE" --json "$T/empty.md" 2>&1)
JSON_LINES=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['total_lines'])" <<< "$OUT")
assert_eq "$JSON_LINES" "0" "JSON empty file has 0 lines"

# ═══════════════════════════════════════════════════════════════════════════
# 16. Content before first section excluded from sections
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "16. Content before first section excluded from sections"

T=$(new_tmp)
cat > "$T/prompt.md" << 'EOF'
preamble line 1
preamble line 2

## First
body
EOF

OUT=$(bash "$MEASURE" --json "$T/prompt.md" 2>&1)
SECT_COUNT=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(len(d['sections']))" <<< "$OUT")
assert_eq "$SECT_COUNT" "1" "preamble not counted as section"

FIRST_LINES=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['sections'][0]['lines'])" <<< "$OUT")
assert_eq "$FIRST_LINES" "2" "First section has 2 lines (header + body)"

# ═══════════════════════════════════════════════════════════════════════════
# 17. help flag exits 0
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "17. help word flag"

HELP_WORD=$(bash "$MEASURE" help 2>&1)
assert_contains "$HELP_WORD" "Usage:" "help word shows Usage"

# ═══════════════════════════════════════════════════════════════════════════
# 18. Human-readable section char counts
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "18. Human-readable section char counts"

T=$(new_tmp)
cat > "$T/prompt.md" << 'EOF'
## Tiny
hi
EOF

OUT=$(bash "$MEASURE" "$T/prompt.md" 2>&1)
assert_contains "$OUT" "Tiny" "human output shows section name"
assert_contains "$OUT" "lines" "human output shows lines label"
assert_contains "$OUT" "chars" "human output shows chars label"

print_results
