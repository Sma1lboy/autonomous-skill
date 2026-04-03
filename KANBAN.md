# KANBAN

Project board for autonomous-skill. Updated by the autonomous agent and maintainers.

## Todo

- [ ] Improve README.md — architecture diagram, usage examples, quickstart
- [ ] Add `--dry-run` flag to loop.sh — show what would happen without spawning CC
- [ ] Add session cost budget (`MAX_COST_USD` env var) to loop.sh
- [ ] Implement `scripts/report.sh` — parse autonomous-log.jsonl into human-readable summary

## Doing

_(nothing in progress)_

## Done

- [x] Implement TRACE.md — auto-maintained session history
- [x] Rewrite loop.sh as thin harness (608→239 lines)
- [x] Fix all 12 bugs from initial TODOS.md
- [x] Add SIGINT + sentinel file graceful shutdown
- [x] Add startup dependency checks (jq, claude, git)
- [x] Live progress output — show tool calls in real-time
- [x] Session metrics dashboard at session end
- [x] OWNER.md persona auto-generation via persona.sh
- [x] Task discovery from TODOS.md, code TODOs, GitHub issues
- [x] Support KANBAN.md as a task source in discover.sh
- [x] Competitive analysis — COMPETITIVE.md (SWE-agent, Devin, OpenHands, Open SWE)
