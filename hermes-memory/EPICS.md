# EPICS — Hermes Local Memory

**Doc Version:** 0.2
**Date:** 2026-05-17

Phase numbers map 1:1 to `Plan.md`. Each epic lands a working, verifiable slice — no epic depends on the next being completed to be useful.

---

## Phase 1: Foundation + Lossless Capture + Redaction

| ID | Epic | Status |
|---|---|---|
| E1.1 | Project scaffold + memory core skeleton (`plugins/memory/hermes-local/`, shared `memory_core/` lib) | Pending |
| E1.2 | SQLite schema + migrations (sessions, turns, chunks, facts, decisions, open_questions, dream_runs, raw_events) | Pending |
| E1.3 | Capture path — `sync_turn` → JSONL append + SQLite insert + content hashing | Pending |
| E1.4 | **Redaction guard** — regex + entropy scan before any disk write (API keys, tokens, cards, SSNs) | Pending |
| E1.5 | QMD/Markdown session exporter | Pending |
| E1.6 | Memory CLI v1 (`memory init`, `memory db init`, `memory capture-test`) | Pending |

**Phase 1 done when:** A test Hermes session captures losslessly to JSONL + SQLite, a fixture API key is redacted before write, and the QMD export is human-readable.

---

## Phase 2: Keyword Search + Plugin Registration

| ID | Epic | Status |
|---|---|---|
| E2.1 | SQLite FTS5 virtual tables + triggers (`turns_fts`, `chunks_fts`, `facts_fts`, `decisions_fts`) | Pending |
| E2.2 | `hermes-local-memory` plugin registration — `plugin.yaml`, `register(ctx)`, config wiring | Pending |
| E2.3 | First tool — `memory_query(mode='keyword')` exposed via `get_tool_schemas` | Pending |
| E2.4 | Source resolver — `memory_get_source` for raw session refs (`session:{id}#turn={n}`) | Pending |

**Phase 2 done when:** `memory.provider: hermes-local` in config swaps the active provider, holographic's `fact_store` is no longer in the tool list, and `memory_query` returns exact keyword matches with source refs.

---

## Phase 3: Semantic Search via Qdrant + Embedding Pipeline

| ID | Epic | Status |
|---|---|---|
| E3.1 | Qdrant collection setup (versioned by embedding model — `hermes_memory_chunks_nomic_v15`) | Pending |
| E3.2 | LMS embedding client (LM Studio `:1235`, `text-embedding-nomic-embed-text-v1.5@f16`, 768d) | Pending |
| E3.3 | Chunker — fixed-size (512 tokens / 128 overlap) + role-mix aware | Pending |
| E3.4 | Async indexer — chunks → embed → Qdrant upsert, status tracked in SQLite | Pending |
| E3.5 | `memory_query(mode='semantic')` — vector search with payload filters (project, date, role) | Pending |

**Phase 3 done when:** Conceptual queries return relevant chunks from Qdrant, payload filters work, re-indexing is idempotent.

---

## Phase 4: Hybrid Retrieval + Recent Context

| ID | Epic | Status |
|---|---|---|
| E4.1 | Hybrid scorer — FTS + Qdrant + Jaccard + HRR + trust + freshness (lifted from holographic) | Pending |
| E4.2 | Graceful degradation — auto-redistribute weights when a backend is down | Pending |
| E4.3 | `memory_query(mode='hybrid')` (default) + result normalization | Pending |
| E4.4 | `memory_recent_context` — pinned facts + recent decisions + open questions, token-budget aware | Pending |
| E4.5 | HRR vector storage + `probe`/`related`/`reason` modes (forked HRR lib) | Pending |

**Phase 4 done when:** Hybrid query returns ranked, deduplicated, source-traced results merging all backends; `recent_context` produces a compact session-start working set.

---

## Phase 5: Narrative Thread + Dreamer v1

| ID | Epic | Status |
|---|---|---|
| E5.1 | Narrative thread file format + per-session SESSION-THREAD/{session_id}.md (port from holographic) | Pending |
| E5.2 | **/new injection fix** — user-message injection on session switch (Option C, not system prompt) | Pending |
| E5.3 | Dreamer prompts (session summary, fact extraction, decision extraction, contradiction detection) | Pending |
| E5.4 | Dreamer worker — load new turns, call Qwen3.6-35B, write through `memory_write` | Pending |
| E5.5 | Daily memory file generator (`~/.hermes/memories/YYYY-MM-DD.md`) | Pending |
| E5.6 | Project memory file generator + entity-bucket contradiction heuristic | Pending |
| E5.7 | Nightly 3am cron job + dream report writer (`memory/dreams/YYYY-MM-DD-HHMM.md`) | Pending |

**Phase 5 done when:** A `/new` correctly references prior-session content; nightly cron processes the day's turns and produces daily summary + facts/decisions, all source-traced.

---

## Phase 6: Migration + Hardening + Operations

| ID | Epic | Status |
|---|---|---|
| E6.1 | One-shot migration script — holographic `memory_store.db` → new memory store via `memory_write` | Pending |
| E6.2 | `memory backup` — archive raw JSONL + SQLite + Qdrant snapshot + project files | Pending |
| E6.3 | `memory rebuild-indexes` — recreate SQLite tables + Qdrant collections from raw JSONL | Pending |
| E6.4 | Health endpoints + observability (`/health`, `/health/qdrant`, `/health/llm`, `/health/sqlite`) | Pending |
| E6.5 | MVP acceptance test suite (capture / keyword / semantic / hybrid / dream / /new / migration) | Pending |

**Phase 6 done when:** Migration runs without data loss, indexes rebuild from raw, full acceptance suite passes.

---

## Post-MVP (Deferred — track in TASKLIST.md "Backlog")

- Mem0 OSS mirror integration
- Graph memory (Kùzu / Neo4j)
- Local re-ranker (e.g. mxbai-rerank)
- Memory review queue (CLI + dashboard)
- Cross-agent gateway hardening (OpenClaw / Agent Zero)
- Document/transcript ingestion
- Web dashboard
- LLM-based contradiction detection (replaces heuristic)
- Compression of raw JSONL after age threshold
