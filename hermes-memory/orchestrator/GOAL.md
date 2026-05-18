# GOAL — hermes-memory build

**Set by:** David McCarty
**Date set:** 2026-05-17
**Project:** hermes-memory
**Status:** Active (or change to: Paused / Achieved / Cancelled)

---

## Headline

Land the hermes-memory MVP — Plan.md Phases 1 through 6 — with the MVP acceptance test suite green.

## Definition of done

The goal is achieved when ALL of these hold:

- [ ] Plan.md §3 (Phase 1: Foundation + Capture + Redaction) gate card is `done`
- [ ] Plan.md §4 (Phase 2: Keyword Search + Plugin Activation) gate card is `done`
- [ ] Plan.md §5 (Phase 3: Semantic Search via Qdrant) gate card is `done`
- [ ] Plan.md §6 (Phase 4: Hybrid Retrieval + Recent Context) gate card is `done`
- [ ] Plan.md §7 (Phase 5: Narrative Thread + Dreamer v1) gate card is `done`
- [ ] Plan.md §8 (Phase 6: Migration + Hardening + Operations) gate card is `done`
- [ ] Plan.md §9 MVP Acceptance Test Suite (Scenarios A through L) — all passing
- [ ] TASKLIST.md "Done" section reflects every phase completion with date stamp
- [ ] `memory.provider: hermes-local` is the active provider in config; `fact_store`
      (holographic) no longer registered as a tool

## Phase-by-phase exit criteria

For each phase, the orchestrator considers it closed when:

| Phase | Gate Condition |
|---|---|
| 1 | T-PHASE1-GATE = done; Plan.md §9 Scenarios A and B passing |
| 2 | T-PHASE2-GATE = done; Plan.md §9 Scenario C passing; provider swap verified |
| 3 | T-PHASE3-GATE = done; Plan.md §9 Scenario D passing |
| 4 | T-PHASE4-GATE = done; Plan.md §9 Scenarios E and F passing |
| 5 | T-PHASE5-GATE = done; Plan.md §9 Scenarios G, H, J passing |
| 6 | T-PHASE6-GATE = done; Plan.md §9 Scenarios I, K, L passing |

## Out of scope

These are explicitly NOT part of this goal:

- Mem0 OSS integration (post-MVP per PROJECT.md §3.2)
- Graph memory (post-MVP)
- Web dashboard (post-MVP)
- Cross-agent memory bus for OpenClaw / Agent Zero (post-MVP)
- Document / transcript ingestion (post-MVP)
- LLM-based contradiction detection (heuristic v1 is the MVP target)
- Memory review queue UI (post-MVP)
- Hermes core changes beyond what ADR-001 authorizes

If a worker proposes any of the above, the orchestrator should escalate, not auto-approve.

## Hard constraints

- **Schema independence:** zero direct queries into `hermes_state.db` or `memory_store.db` schemas
- **No remote push:** all commits stay local on the hermes-agent feature branches
- **Real services in tests:** no internal-module mocking; real Qdrant @ :6333, LMS @ :1235, SQLite tmp_path
- **Redaction is Phase 1:** all secrets blocked at write time, fixture-tested before any other Phase 1 code lands
- **`force_no_redact` removed:** the argument must not appear anywhere in code

If any of these are violated by a worker, the orchestrator escalates with urgency=`critical`.

## Escalation expectations

David expects to be notified (via telegram) when:

- A review-required block has sat >24h
- An ADR is needed (a worker raised an unresolvable design question)
- A worker has been reclaimed once and is stuck again
- A hallucination warning fires on any card
- The orchestrator's state machine detects drift (state ≠ board reality)
- A phase gate fails (a worker rejected something critical)
- Goal achievement: when all phase gates are done

David does NOT need to be notified about:

- Workers running normally
- Cards moving through their lifecycle on schedule
- Routine state machine transitions (BOOTSTRAP → PHASE_1_PLANNING, etc.)
- Heartbeats with no actions

## Notes / context

- The orchestrator runs every 30 minutes via cron (see `~/.hermes/PROJECTS/hermes-memory/scripts/orchestrator-heartbeat.sh`)
- Profile model assignments: see `~/.hermes/PROJECTS/hermes-memory/docs/KANBAN_OPERATIONS.md` §1
- Specialist SOULs are under `~/.hermes/PROJECTS/hermes-memory/souls/`; updates flow into profile homes via `scripts/install-souls.sh`
- The three pre-Sprint-1 ADRs (narrative-thread injection, SQLite writer strategy, indexer process model) MUST be authored by David before BOOTSTRAP can succeed. If `docs/adr/` is missing these, the orchestrator escalates urgency=`attention` and stays in BOOTSTRAP.

---

## Changing this goal

If David needs to pause, change, or end the goal:

- **Pause:** add `Status: Paused` to the front matter; orchestrator will heartbeat without taking actions
- **Cancel:** add `Status: Cancelled`; orchestrator will note in HISTORY and disable cron
- **Modify scope:** edit the "Definition of done" and "Out of scope" sections; orchestrator reads them on the next tick

The orchestrator will never edit this file.
