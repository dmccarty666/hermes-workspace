# TASKLIST — Hermes Local Memory

**Doc Version:** 0.3
**Last Updated:** 2026-05-17 (Sprint 1 autonomous build live)

---

## Current State

**Phase:** Phase 1 — AUDIT_PENDING (substance complete, gate closing in progress)
**Phase gate:** t_a2b7d19d — T-PHASE1-GATE (ready, awaiting AUDIT-GATE pass + orchestrator transition)
**hm-auditor:** Active — audit/PHASE_1_GATE_AUDIT.md written, 18-point audit complete (15/18 pass, 3 require action)

**Audit status:** 15/18 criteria pass. 3 require action before gate can close:
- Criterion 3: Fresh gate card created (t_a2b7d19d)
- Criterion 16: STATE.md updated (was stale — manually corrected)
- Criterion 18: Awaiting re-audit after gate card creation

**Tests:** 231/231 pass (Phase 1 scenarios A+B verified)
**Code:** All Phase 1 files committed — pipeline.py(358L), redaction.py(203L), sqlite.py(499L)

**Recent decisions locked (from `answers.txt` + design discussion):**
- Build as **new** Hermes `MemoryProvider` plugin (`plugins/memory/hermes-local/`), alongside holographic — not extend in place.
- Own SQLite file (`~/.hermes/memory/memory.sqlite`) — never touch `memory_store.db` or `hermes_state.db` schemas directly.
- Plugin = in-process write path; FastAPI gateway = out-of-process query/dream/source path. Both share a common `memory_core/` library.
- Dreamer LLM: Qwen3.6-35B on `.105` for everything (labeling + deep dream). Nightly 3am cron.
- Single tool surface (`memory_query`, `memory_write`, `memory_update`, `memory_get_source`, `memory_dream_now`) — `fact_store` simply doesn't load because holographic isn't registered.
- Narrative thread: lift design from holographic, **fix `/new` injection via user-message injection** (cached system prompt issue is real and documented).
- Redaction moves from Phase 9 → Phase 1.
- Mem0 / graph / cross-agent / dashboard all post-MVP.

---

## Outstanding Work (immediate)

| Order | Item | Owner | Status |
|---|---|---|---|
| 1 | Rewrite docs (PROJECT/PRD/TDD/Plan/EPICS/meta) — v0.2 reflecting locked decisions | Agent | ✅ Done |
| 2 | Critique + edge-case scrub of v0.2 docs | Agent + User | ✅ Done |
| 3 | Sign-off on v0.2 docs | User | ✅ Done |
| 4 | Sprint 0: 6 profiles + SOULs + models + 3 ADRs | Agent + User | ✅ Done |
| 5 | Sprint 1 Phase 1 task decomposition into kanban cards | hm-planner | ✅ Done (T-001..T-009 + T-007-qa + T-PHASE1-GATE) |
| 6 | Sprint 1 Phase 1 implementation | hm-developer (parallel) | 🟡 **In progress** |
| 7 | T-PHASE1-GATE acceptance (Scenarios A+B passing) | hm-qa | Pending |
| 8 | Phases 2 → 6 (kicked off automatically by orchestrator state machine) | All workers | Pending |

## System/Process Fixes (Direct — No Tickets)

> Boundary: fixing HOW agents work = direct work, documented here. Fixing WHAT they produce = kanban tickets.

| # | Item | Status |
|---|---|---|
| SYS-1 | T-010 fixture: `ghp_` + 36x 'a' → `ghp_` + 36x alphanumeric in `test_capture_tool_results.py` | Open — ticket to hm-developer |
| SYS-2 | hm-planner SOUL: add idempotency check (skip if card with same name exists non-archived) | Open — our work |
| SYS-3 | Kanban dispatcher: auto-complete of rc=0 workers without kanban_complete → mark needs_attention | Open — our work |
| SYS-4 | hm-qa: spawn fresh T-007-qa card with parent = t_cc90cccf (canonical done) | Open — ticket to hm-qa |
| SYS-5 | T-PHASE1-GATE: consolidate to single canonical card | Open — ticket to hm-qa |
| SYS-6 | T-009 2nd attempt (t_fc420847): hm-developer completes + calls kanban_complete | Open — ticket to hm-developer |

---

## Open Questions

| ID | Question | Status |
|---|---|---|
| Q1 | Final plugin name — `hermes-local` vs `hermes-local-memory` vs `hermes-memory-pack`? | Open — needs user pick |
| Q2 | Gateway: always-on systemd/cron service vs lazy-start by plugin? | Open — recommend always-on for cron access |
| Q3 | When the plugin is loaded but the gateway is down, do we degrade to direct SQLite/Qdrant calls (plugin owns memory_core), or hard-fail? | Open — recommend degrade silently |
| Q4 | Dreamer triggers: nightly cron only, or also session-end and `/dream now` command? | Recommend all three; cron is the workhorse |
| Q5 | Narrative thread retention — how many days of per-session thread files do we keep? | Open — recommend 30 days then dreamer-rolls them up |

---

## Risks Being Tracked

See `PROJECT.md §8` for the full register. Top three to watch in Sprint 1:

- **R3** — Narrative thread injection bug. We have a diagnosed root cause (cached system prompt) and a proposed fix (user-message injection). Integration test must cover `/new` explicitly.
- **R6** — Secrets leak before redaction. Phase 1 redaction tests use fixture API keys, GitHub tokens, AWS keys.
- **R1** — Hermes upstream changes. We pin only to `agent.memory_provider.MemoryProvider` public ABC; everything else is touched via public helpers (`get_hermes_home`, `apply_wal_with_fallback`).

---

## Done

| Date | Item |
|---|---|
| 2026-05-17 | v0.1 PRD/TDD/Plan drafted (1 AI agent) |
| 2026-05-17 | v0.1 critiqued via `project-introspection.md` (2nd AI agent) |
| 2026-05-17 | Fresh-take review by Hermes; clarifying questions issued |
| 2026-05-17 | User answered clarifying Qs in `answers.txt` |
| 2026-05-17 | Deep code-scrub of `holographic` / `honcho` / `MemoryProvider` ABC |
| 2026-05-17 | Narrative-thread `/new` injection bug root-caused (cached system prompt) |
| 2026-05-17 | v0.1 docs archived to `docs/archive/v0.1-original/` |
| 2026-05-17 | v0.2 PROJECT.md / meta.json / EPICS.md / TASKLIST.md written |
| 2026-05-17 | v0.2 PRD / TDD / Plan / critique written |
| 2026-05-17 | Five specialist SOULs authored: hm-planner, hm-architect, hm-developer, hm-qa, hm-docs (under `souls/`) |
| 2026-05-17 | `docs/KANBAN_OPERATIONS.md` runbook written |
| 2026-05-17 | `scripts/install-souls.sh` + `config/profiles.sample.yaml` added (Sprint 0 setup tooling) |
| 2026-05-17 | Test-bed model assignments locked: MiniMax M2.7 → hm-planner + hm-developer; Qwen3.6-35B (local Spark2) → hm-architect + hm-qa + hm-docs |
| 2026-05-17 | Board cleared (4 financial-agent triage stories archived) — clean slate for hermes-memory Sprint 0 |
| 2026-05-17 | hm-orchestrator profile added: Ralph-loop autonomous build driver. SOUL + state machine + heartbeat script + GOAL/STATE/HISTORY files written. Cron-driven, 30-min ticks, single-action-per-tick, hard guardrails against auto-approvals. |
| 2026-05-17 | **Sprint 0-A complete:** 6 profiles created (hm-orchestrator, hm-planner, hm-architect, hm-developer, hm-qa, hm-docs). All 6 SOULs installed via install-souls.sh. Per-profile models set: MiniMax M2.7 → planner+developer; Qwen3.6-35B-a3b @ lms_spark2 → orchestrator+architect+qa+docs. Verified via `hermes -p <profile> chat -q ...` — SOULs loading correctly, both OpenRouter + local Spark2 endpoints functional. |
| 2026-05-17 | **Sprint 0-B drafted:** Three ADRs authored — ADR-001 narrative-thread injection (Option A: user-message inject), ADR-002 SQLite writer strategy (Option A: process-pinned ownership), ADR-003 indexer process model (Option A: gateway-primary + plugin fallback + catch-up). All marked **Proposed** — awaiting David's approval signatures in each ADR. |
| 2026-05-17 | **ADRs 001, 002, 003 approved by David.** Status flipped Proposed → Accepted in all three. Sprint 0 readiness checklist now complete (all 13 items checked). System ready for first orchestrator heartbeat. |
| 2026-05-17 | **Orchestrator cron job registered** — `job_id=d1594aa9a5d8`, schedule `*/30 * * * *`, wrapper at `~/.hermes/scripts/hm-orchestrator-heartbeat.sh` (delegates to project script). Workdir pinned to `~/.hermes/PROJECTS/hermes-memory/`. |
| 2026-05-17 | **First orchestrator tick executed end-to-end.** IDLE → PHASE_1_PLANNING. Created T-PLAN-PHASE-1 (t_8e5dab74). STATE.md / HISTORY.md correctly updated. Lock acquired and released cleanly. |
| 2026-05-17 | **hm-planner decomposed Phase 1.** 11 cards on board: T-001 (plugin scaffold), T-002 (memory init CLI), T-003 (SQLite schema + migrations), T-004 (event schema), T-005 (JSONL append), T-006 (redaction scanner — Phase 1 security gate), T-007 (capture pipeline / sync_turn wiring), T-008 (QMD/Markdown exporter), T-009 (memory CLI smoke), T-007-qa (capture e2e verify), T-PHASE1-GATE (Scenarios A+B acceptance). All cards cross-ref Plan.md / TDD.md and carry the `software-development/test-driven-development` skill tag. |
| 2026-05-17 | **First foundation code landed on disk** by hm-developer agents: `plugins/memory/hermes-local/__init__.py` (HermesLocalProvider, 4.6KB, production-grade) + `plugins/memory/hermes-local/plugin.yaml`. `hermes_memory_core/` scaffolded with all 7 subpackages (`chunk/`, `dream/`, `embed/`, `search/`, `source/`, `store/`, `write/`) matching TDD.md module layout. |
| 2026-05-17 | **Autonomous build mode live.** 4 hm-developer instances running in parallel (T-001, T-003, T-004, T-006). Dispatcher routing tasks by skill. Orchestrator cron next-run 23:00. Telegram escalation wired for stuck/blocked/HUMAN-DECISION cards. David hands-off until phase gate or escalation. |

---

## Backlog (Post-MVP)

- Mem0 OSS integration as optional adaptive memory mirror
- Graph memory (Kùzu first; Neo4j if richer ops needed)
- Web dashboard (`/dashboard` page on the gateway)
- Memory review queue for low-confidence facts
- Document / file / meeting-transcript ingestion from NAS
- LLM-based contradiction detection replacing heuristic v1
- Per-project confidence thresholds
- Local re-ranker (mxbai-rerank or similar)
- Cross-agent memory access for OpenClaw / Agent Zero (formal contract)
- Memory diff viewer for project memory file history
- Export/import "memory pack" format for portability

## System/Process Fixes (direct — no kanban tickets)

| # | Item | Status | Notes |
|---|---|---|---|
| SYS-1 | T-010 fixture (`ghp_` token needs 36 alphanumeric chars, not all `a`) | pending | Assign to hm-developer via kanban |
| SYS-2 | hm-planner SOUL: idempotency check before creating cards | pending | Direct work |
| SYS-3 | Kanban dispatcher: auto-detect clean worker exit with file changes | pending | Direct work |
| SYS-A | **DONE** — kanban create: validate skills before DB write | ✅ | hermes_cli/kanban.py |
| SYS-B | **DONE** — kanban dispatcher: validate skills before spawn, fail fast | ✅ | hermes_cli/kanban_db.py |

## hm-auditor Integration

| # | Item | Status | Notes |
|---|---|---|---|
| AUDIT-SETUP | hm-auditor profile + SOUL created | ✅ | ~/.hermes/profiles/hm-auditor/SOUL.md |
| AUDIT-P1-GATE | Phase 1 gate audit report written | ✅ | audit/PHASE_1_GATE_AUDIT.md |
| AUDIT-P1-GATE-RERUN | Re-run AUDIT-GATE after gate card + STATE.md fixed | pending | Orchestrator spawns hm-auditor |
| AUDIT-DISPATCH | Dispatcher integration: auditor on card completion | pending | SYS-3 subsumes this |
| AUDIT-SOUL-UPD | Orchestrator SOUL updated: gate needs auditor sign-off | ✅ | hm-orchestrator.md §2
