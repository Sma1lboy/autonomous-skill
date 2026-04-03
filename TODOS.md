# TODOS

## Completed (v0.1)
- [x] Fix operator precedence bug in `detect_test_command`
- [x] Fix MAIN_BRANCH detection — detect via show-ref, not current HEAD
- [x] Fix `verify_result` to detect untracked files
- [x] Register cleanup trap for SIGTERM/ERR temp files
- [x] Add startup dependency checks (jq, claude, git)
- [x] Fix jq injection in `mark_task` — use `--arg`
- [x] Add JSON validation of discover.sh output
- [x] Log discarded files before resetting on test failure
- [x] Handle session branch name collision
- [x] Guard discover.sh against control chars and UTF-8 truncation

## Completed (v0.2)
- [x] Implement TRACE.md — auto-maintained session history
- [x] Implement KANBAN.md — project todo/doing/done board
- [x] Add KANBAN.md as task source in discover.sh
- [x] Fix sed regex portability (\\s → POSIX [[:space:]]) in discover.sh

## Open
- [ ] Add `--dry-run` flag to loop.sh — show plan without spawning CC
- [ ] Add session cost budget (`MAX_COST_USD` env var) to loop.sh
- [ ] Implement `scripts/report.sh` — parse autonomous-log.jsonl into summary
- [x] Competitive analysis — COMPETITIVE.md comparing SWE-agent, Devin, OpenHands
- [ ] Improve README.md — architecture diagram, usage examples, quickstart
- [ ] Add test harness — mock CC responses for loop.sh integration tests
