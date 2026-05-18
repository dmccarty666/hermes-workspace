# PROJECT: Hermes Local Memory

**Project Key:** `hermes-memory`
**Owner:** David McCarty
**Created:** 2026-05-17
**Doc Version:** 0.2
**Status:** Active — Design lock-in / Pre-Sprint 1

---

## 1. Charter

Build a **local-first, no-additional-cost long-duration memory system** for the Hermes Agent that:

1. Captures every conversation turn losslessly to a local archive.
2. Provides hybrid retrieval (keyword + semantic + structural) over months/years of history.
3. Maintains durable, source-traceable facts/decisions/open-questions.
4. Runs a nightly local "dreamer" that summarizes sessions, extracts durable memory, and updates project memory files.
5. Exposes one unified tool surface (`memory_query`, `memory_write`, ...) so the agent never has to know which backend produced a result.

The system replaces — by single config flip — the active `holographic` memory provider, owning its own SQLite file and Qdrant collections so future Hermes core schema changes cannot break us.

## 2. Why now

- The user has rejected per-token cloud memory providers (Honcho et al.) on cost grounds.
- The OpenClaw `lossless-claw` + `enhanced-memory` pattern works locally; the equivalent has never existed for Hermes.
- ~60% of the required infrastructure is already live on this box: Qdrant, LMS embeddings, Spark/Qwen LLMs, FTS5-backed SQLite. The remaining 40% is gluing it together correctly behind the `MemoryProvider` interface.
- Hermes' new `MemoryProvider` plugin contract makes "swap the active memory provider" a one-line config change — the cleanest possible integration.

## 3. Scope (MVP)

### In scope
- New Hermes `MemoryProvider` plugin: `plugins/memory/hermes-local/`
- Local FastAPI gateway service (`hermes-memory-gateway`) for queries, source resolution, dreaming
- Lossless JSONL capture + QMD/Markdown export
- Own SQLite database (`~/.hermes/memory/memory.sqlite`) with sessions, turns, chunks, facts, decisions, open_questions, dream_runs, raw_events
- SQLite FTS5 keyword search
- Qdrant semantic search (`nomic-embed-text-v1.5@f16` on LMS `:1235`)
- Hybrid scoring: FTS + Qdrant + Jaccard + HRR + trust + recency
- Nightly local "dreamer" (3am cron) using Qwen3.6-35B on `.105`
- Daily memory files (continuing `~/.hermes/memories/YYYY-MM-DD.md`)
- Per-project memory files (`memory.md` / `facts.md` / `decisions.md` / `open_questions.md` / `timeline.md`)
- Narrative thread (per-session SESSION-THREAD/{session_id}.md) with **the `/new` injection bug fixed**
- Redaction guard at write time (Phase 1, not Phase 9)
- Source tracing on every result (`session:{id}#turn={n}`, `fact:{id}`, etc.)
- One-shot migration tool: holographic `memory_store.db` → new memory store
- Backup/restore + index rebuild from raw JSONL

### Out of scope for MVP
- Mem0 OSS mirror (post-MVP option)
- Graph memory (post-MVP option)
- Cross-agent memory bus (OpenClaw / Agent Zero have their own)
- Web dashboard / UI
- Document / meeting-transcript ingestion
- Local reranker / LLM-based contradiction detection (use heuristic v1)
- Multi-user governance

## 4. Goals (measurable)

| # | Goal | Target |
|---|---|---|
| G1 | Lossless capture | 100% of CLI + gateway sessions land in raw JSONL |
| G2 | Keyword recall | Exact-string lookup (config keys, error messages) finds source in < 1s |
| G3 | Semantic recall | Conceptual queries return relevant chunks in < 2s |
| G4 | Hybrid recall | Top-3 results relevant + source-traced for 80% of "what did we decide about X" queries on seeded test set |
| G5 | Dreaming | Nightly cron produces daily summary + ≥1 fact per substantive session, no duplicates |
| G6 | Provider swap | Single config flip (`memory.provider: hermes-local`) — fact_store + holographic tools no longer registered |
| G7 | Narrative thread on /new | After `/new`, the next assistant turn references prior session focus and asks if to continue |
| G8 | Schema independence | Zero queries from our code into `~/.hermes/memory_store.db` schema or `hermes_state.db` schema; only public APIs |
| G9 | Reliability | Indexes can be rebuilt 100% from raw JSONL with a single command |

## 5. Non-goals (deliberate exclusions)

- We do not replace `hermes_state.py` or its session store.
- We do not own or migrate other Hermes built-ins (todo, kanban, achievements).
- We do not need to support remote/cloud deployment.
- We do not aim for distributed multi-machine memory (yet).
- We do not block on perfect fact extraction — human review queue is post-MVP.

## 6. Architecture (one paragraph)

A `MemoryProvider` plugin lives in-process with Hermes and handles **writes** (sync_turn, on_session_end, on_pre_compress, on_memory_write) and the **hot-path** tool calls (`memory_query`, `memory_write`, `memory_recent_context`). For deep queries, source resolution, the dreamer process, and any future cross-agent access, the plugin can delegate to an out-of-process **FastAPI gateway** that wraps the same memory core library. Both share one SQLite database (`memory.sqlite`), one Qdrant collection set (`hermes_memory_*`), and one filesystem layout (`~/.hermes/memory/`). The dreamer runs as a cron job that calls into the same memory core, processes new turns through Qwen3.6-35B, writes structured outputs through `memory_write`, and updates indexes idempotently. The narrative thread is preserved by injecting prior-session content as a **user message** on session switch — bypassing the cached system-prompt limitation that blocks the current holographic implementation.

## 7. Stakeholders

- **Owner / decision-maker:** David McCarty
- **Primary consumer:** Hermes Agent (CLI, gateway/Telegram, TUI)
- **Secondary consumers:** future cron jobs / sub-agents calling the gateway
- **Not consumers (MVP):** OpenClaw, Agent Zero (have their own memory)

## 8. Risks

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | Hermes upstream changes break our plugin contract | High | Pin to documented `MemoryProvider` ABC; track upstream commits via Hermes release notes |
| R2 | Qdrant/LMS embedding model swap requires re-embed | Medium | Version Qdrant collections by embedding-model (`hermes_memory_chunks_nomic_v15`); rebuild from raw on swap |
| R3 | Narrative thread injection still doesn't fire on /new after our fix | Medium | Use user-message injection (Option C) instead of system-prompt block; integration test covers /new specifically |
| R4 | Dreamer LLM hallucinates facts | High | Source refs required on every fact; confidence threshold for auto-promote; review queue for low-confidence items (post-MVP) |
| R5 | SQLite contention with concurrent gateway+plugin writes | Low/Medium | WAL mode (with NFS fallback already in Hermes); single writer per process; queue async writes |
| R6 | Secrets leak into memory before redaction matures | High | Redaction guard in Phase 1, before any storage. Test with fixture API keys. |
| R7 | Migration from holographic loses HRR vectors | Low | Recompute HRR vectors during migration via `rebuild_all_vectors()` — re-running is idempotent |
| R8 | Disk growth unbounded over years | Medium | Phase 6 archive policy; JSONL compression; chunk-level vector pruning for superseded facts |

## 9. Document map

| Doc | Purpose | Status |
|---|---|---|
| `PROJECT.md` (this file) | Charter, scope, goals | ✅ v0.2 |
| `TASKLIST.md` | Current state, sprint progress, blockers | ✅ v0.2 |
| `EPICS.md` | Epic list w/ phase mapping | ✅ v0.2 |
| `meta.json` | Machine-readable metadata | ✅ v0.2 |
| `prd.md` | Product requirements | ✅ v0.2 |
| `TDD.md` | Technical design | ✅ v0.2 |
| `Plan.md` | Phased delivery plan w/ stories | ✅ v0.2 |
| `Memory_References.md` | External reference links | Carry-forward from v0.1 |
| `docs/archive/v0.1-original/` | Original drafts (PRD, TDD, Plan, introspection) | Archived |

## 10. Glossary

- **Plugin** — In-process Hermes memory provider (`MemoryProvider` ABC implementation).
- **Gateway** — Out-of-process FastAPI service that exposes `/memory/*` HTTP endpoints.
- **Memory core** — Shared Python library both plugin and gateway depend on (capture, search, write, dream).
- **Dreamer** — Scheduled cron job that consolidates raw turns into facts/decisions/summaries.
- **Source ref** — Stable pointer to original content (`session:{id}#turn={n}`, `fact:{id}`, etc.).
- **Narrative thread** — Per-session SESSION-THREAD/{session_id}.md rolling working memory injected on `/new` / `/resume` / `/branch`.
- **Holographic** — Existing Hermes plugin (`plugins/memory/holographic/`) we use as a code reference and as the migration source.
