# TRACE — Session History

Automatically maintained by `loop.sh`. Each entry records one autonomous session.

## Session 1775195395
- **Branch**: `auto/session-1775195395`
- **Date**: 2026-04-02
- **Iterations**: ~10
- **Cost**: _(not tracked)_
- **Duration**: ~1h
- **Direction**: _(initial development)_
- **Commits**:
  - `a3183e5` init: autonomous-skill — self-driving project agent
  - `74b31b9` fix: discover.sh self-match, loop.sh unbound var, add DIRECTION support, add README
  - `b012ff4` fix: add DIRECTION support, unlimited iterations, display fixes
  - `a63e662` fix: make fallback explore task specific and bounded
  - `ca80c0e` feat: live progress output — show tool calls and timing in real-time
  - `d54828c` fix: init LAST_TOOL before progress loop
  - `cb2a237` fix: mktemp suffix compat for macOS
  - `9ad9532` fix: use acceptEdits permission mode, add cost sanitization
  - `4d4d2f7` fix: use --permission-mode auto, fix jq injection in mark_task
  - `acf9aca` fix: use --dangerously-skip-permissions for non-interactive writes
  - `aaba8d5` fix: correct operator precedence in detect_test_command pytest check
  - `d6d4454` feat: session metrics dashboard + fix add_cost float truncation

## Session 1775202019
- **Branch**: `auto/session-1775202019`
- **Date**: 2026-04-02 → 2026-04-03
- **Iterations**: ~12
- **Cost**: _(not tracked)_
- **Duration**: ~2h
- **Direction**: Bug fixes and loop.sh refactor
- **Commits**:
  - `c65352a` fix: detect main/master branch via show-ref instead of current HEAD
  - `1fb0bcd` fix: harden MAIN_BRANCH fallback and base session branch off main
  - `8c85670` fix: detect untracked files in verify_result
  - `b4b292b` fix: add EXIT cleanup trap for CC_STREAM_FILE temp files
  - `5b8a120` feat: add startup dependency checks for jq, claude, git, timeout
  - `ceda3ee` fix: validate discover.sh JSON output before passing to init_state
  - `24a0ee7` fix: log discarded files before resetting on test failure
  - `13818a4` fix: handle session branch name collision with random suffix retry
  - `32aac1f` fix: guard discover.sh against control chars and UTF-8 truncation
  - `9876207` fix: detect untracked files in cleanup section of loop.sh
  - `8f52a2d` fix: add SIGTERM trap in loop.sh to clean up temp stream files
  - `27b67ad` fix: strengthen cleanup traps for SIGTERM/ERR in loop.sh
  - `f598923` fix: remove ERR from cleanup trap to prevent premature stream file deletion
  - `e393358` fix: three core issues — HEAD tracking, CC commit detection, cost parsing
  - `f03cbeb` refactor: rewrite loop.sh as thin harness (608→239 lines)

