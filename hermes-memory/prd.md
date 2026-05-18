# PRD: Hermes Local Memory Pack

**Document:** `prd.md`
**Project:** `hermes-memory`
**Owner:** David McCarty
**Version:** 0.2 (rewrite — see `docs/archive/v0.1-original/` for v0.1 + introspection)
**Date:** 2026-05-17
**Status:** Draft for design lock-in

---

## 1. Executive Summary

Hermes Local Memory Pack is a **local-first, no-additional-cost long-duration memory subsystem** for the Hermes Agent. It captures every conversation turn losslessly, indexes them for both exact-keyword and semantic search, extracts durable facts through a nightly local "dreamer" process, and exposes a single, unified memory tool surface so the agent never has to know which storage backend produced a given result.

The system ships as a **new Hermes `MemoryProvider` plugin** (`plugins/memory/hermes-local/`), activated by a single config flip (`memory.provider: hermes-local`). For heavy queries, source resolution, and the dreamer process, the plugin delegates to a local **FastAPI gateway service**. Both share one SQLite database, one Qdrant collection set, and one filesystem layout under `~/.hermes/memory/`.

This PRD replaces v0.1 and incorporates the v0.1 introspection critique, deep-scrub findings on the existing holographic plugin, the diagnosed root-cause of the `/new` narrative-thread injection bug, and the user's locked design decisions.

---

## 2. Problem Statement

Hermes' built-in memory is useful for compact durable context but is not sufficient for the user's desired long-duration memory:

- The existing `holographic` plugin stores facts in `memory_store.db` but does not preserve raw chat history, has no semantic retrieval, and produces no daily/project memory artifacts.
- Cloud providers (Honcho, Mem0 Cloud) cost per token and conflict with the local-first preference.
- The OpenClaw `lossless-claw` + `enhanced-memory` pattern has proven the model locally but has never been ported to Hermes.

What the user needs:

1. Lossless preservation of every chat turn.
2. Both exact-string search (config keys, error strings, command snippets) and semantic search (concepts, "what did we decide about X").
3. Durable, source-traceable facts and decisions.
4. Recursive consolidation ("dreaming") that updates daily / project memory files automatically.
5. Per-session "narrative thread" that survives `/new`, `/resume`, and context compaction.
6. Zero recurring SaaS / token-metered cost.
7. One tool surface inside Hermes — no risk that the agent drifts back to a default tool.

---

## 3. Goals

### 3.1 Product Goals

1. **Lossless capture** — every user / assistant / system / tool turn lands in append-only JSONL.
2. **Dual indexing** — SQLite FTS5 for keywords; Qdrant for semantic.
3. **Hybrid retrieval** — one query merges FTS + Qdrant + Jaccard + HRR + trust + recency, with graceful degradation if any backend is down.
4. **Source traceability** — every returned result carries a `source_ref` that resolves back to raw content.
5. **Local dreaming** — nightly cron extracts facts, decisions, open questions, contradictions, daily summaries, project memory updates.
6. **Single tool surface** — `memory_query`, `memory_write`, `memory_update`, `memory_get_source`, `memory_recent_context`, `memory_dream_now`.
7. **Provider swap** — activating this provider unregisters holographic/`fact_store` automatically (Hermes core enforces single external provider).
8. **Schema independence** — we own our SQLite file end-to-end; we only touch Hermes core via documented public APIs.
9. **Narrative thread that actually works on `/new`** — prior session content is injected on the next turn (via user message, bypassing the cached-system-prompt limitation).
10. **Idempotent operations** — capture, indexing, and dreaming all safe to re-run.

### 3.2 User Experience Goals

The user can ask Hermes any of the following and get a useful, source-cited answer:

- "What did we decide about Hermes memory last week?"
- "Find the exact OpenClaw error I pasted about `agents.list.0.tools`."
- "What hardware do I currently have in the AI lab?"
- "Summarize everything we discussed about Qdrant and meeting transcripts."
- "Show me all open questions about using Mem0 OSS."
- "Update the project memory for Hermes with this new decision."
- "Dream on today's sessions and update daily/project memory."

After `/new`, the assistant's first response should briefly reference the prior session's focus and ask whether to continue from there.

---

## 4. Non-Goals (MVP)

1. Replace `hermes_state.py` / Hermes' session DB.
2. Replace OpenClaw memory.
3. Build a hosted SaaS.
4. Store secrets, API keys, passwords, tokens.
5. Guarantee perfect fact extraction without human review.
6. Solve enterprise multi-user governance.
7. Implement full graph reasoning in MVP.
8. Ingest arbitrary external data sources (files, NAS, transcripts).
9. Depend on any cloud LLM API.
10. Rewrite raw history during consolidation (raw is immutable).
11. Provide a web dashboard (post-MVP).
12. Cross-agent memory bus for OpenClaw / Agent Zero (post-MVP).

---

## 5. Architecture Overview

```text
                +-----------------------------+
                | Hermes Agent (in-process)   |
                |                             |
                |  AIAgent + MemoryManager    |
                +--------------+--------------+
                               |
                               | activates exactly one MemoryProvider
                               v
                +-----------------------------+
                | hermes-local plugin         |  <-- this project
                |  (MemoryProvider impl)      |
                |                             |
                | * sync_turn() write path    |
                | * on_session_switch()       |
                | * tool schemas + dispatch   |
                | * narrative thread          |
                +-------+-------------+-------+
                        |             |
        in-process call |             | HTTP (heavy queries, dream, source)
                        v             v
                +-----------------------------+
                | memory_core library         |  <-- shared
                |                             |
                | * SQLite (sessions, turns,  |
                |   chunks, facts, decisions, |
                |   open_questions, dream_    |
                |   runs, raw_events) + FTS5  |
                | * Qdrant client             |
                | * LMS embeddings client     |
                | * Hybrid scorer             |
                | * Redaction guard           |
                | * Source resolver           |
                +---------------+-------------+
                                |
                +---------------+---------------+
                |               |               |
                v               v               v
        SQLite file       Qdrant @ :6333   ~/.hermes/memory/
   memory.sqlite          collections      raw/, qmd/, daily/,
   (WAL + FTS5)           (nomic v1.5)     projects/, dreams/

                +-----------------------------+
                | hermes-memory-gateway        |  (FastAPI, optional service)
                |                             |
                | * /memory/query             |
                | * /memory/write             |
                | * /memory/source/{ref}      |
                | * /memory/dream             |
                | * /memory/reindex           |
                | * /health                   |
                +---------------+-------------+
                                |
                                v
                        same memory_core lib

                +-----------------------------+
                | Dreamer cron (3am nightly)  |
                |                             |
                | Calls Qwen3.6-35B @ .105    |
                | Reads new turns, writes via |
                | memory_write through        |
                | memory_core                 |
                +-----------------------------+
```

### 5.1 Centralized Access Rule (carried from v0.1)

Hermes interacts with memory through **one** programmatic interface — the plugin's registered tools. Every backend (SQLite, Qdrant, files, dreamer outputs) is a private implementation detail behind that interface.

Why this matters for v0.2: we have explicit leverage. Hermes' `MemoryProvider` contract enforces single-provider — when `hermes-local` is active, `fact_store` and other provider tools are not registered. The agent literally cannot call them. No skill-wrapping, no soul.md nudging, no hoping the agent picks the right tool.

---

## 6. Personas

### 6.1 Primary: Local AI Power User (David)

- Builds self-hosted AI lab; uses Hermes daily across CLI + Telegram + TUI.
- Local-first; rejects per-token cloud memory cost.
- Wants high-recall, source-cited answers across months of conversation history.
- Edits memory files by hand when needed.

### 6.2 Secondary: Hermes Agent (in-process consumer)

- Needs: fast prefetch, structured query results, write tools, source-traced facts.
- Hard constraint: no surprise schema breaks, no missing tool surfaces.

### 6.3 Secondary: Dreamer (automated process)

- Runs from cron at 3am.
- Needs: access to unprocessed turns, idempotent batches, checkpointing, contradiction detection, ability to update derived memory + indexes.

---

## 7. Scope

### 7.1 MVP Scope (Phases 1–6 in `Plan.md`)

1. Hermes plugin: `plugins/memory/hermes-local/` (capture + tools).
2. FastAPI gateway: `hermes-memory-gateway` (queries, source, dream).
3. Shared `memory_core/` library (used by both).
4. JSONL append-only archive.
5. QMD/Markdown session export.
6. Own SQLite database (`~/.hermes/memory/memory.sqlite`) with full schema.
7. SQLite FTS5 for keyword search.
8. Qdrant integration with `nomic-embed-text-v1.5@f16` (768d, LMS `:1235`).
9. Hybrid scorer with graceful degradation.
10. Forked HRR lib for `probe` / `related` / `reason` compositional queries.
11. Redaction guard in Phase 1.
12. Source resolver.
13. Dreamer v1 with Qwen3.6-35B at `192.168.2.105`.
14. Daily memory files (`~/.hermes/memories/YYYY-MM-DD.md`).
15. Per-project memory files.
16. Narrative thread with fixed `/new` injection.
17. Memory CLI (`memory init`, `db init`, `search`, `dream`, `backup`, `rebuild-indexes`).
18. One-shot migration from holographic `memory_store.db`.
19. Backup + index rebuild from raw JSONL.

### 7.2 Post-MVP (deferred)

- Mem0 OSS as optional adaptive mirror
- Graph memory (Kùzu / Neo4j)
- Web dashboard
- Cross-agent memory bus (OpenClaw, Agent Zero)
- Document / transcript ingestion
- Local re-ranker
- LLM-based contradiction detection
- Memory review queue
- Per-project confidence thresholds

---

## 8. Functional Requirements

### FR-001: Lossless Chat Capture

Every Hermes turn shall append a record to `memory/raw/YYYY/YYYY-MM-DD/{session_id}.jsonl` with:
`event_id`, `session_id`, `turn_id`, `sequence`, `timestamp`, `role`, `content`, `agent`, `project`, `source`, `tags`, `tool_calls`, `attachments`, `metadata`, `hash`, `parent_turn_id`, `embedding_status`, `index_status`, `dream_status`.

Acceptance: no content loss under normal operation; duplicate events (matching hash) are deduplicated, not lost.

### FR-002: Human-Readable Session Export

The system shall export each session to QMD/Markdown under `memory/qmd/YYYY/YYYY-MM-DD/` with frontmatter, chronological turns, tool call summaries, source refs, tags.

### FR-003: Daily Memory Files

The system shall maintain one daily file per date at `~/.hermes/memories/YYYY-MM-DD.md` containing sessions processed, major topics, durable facts discovered, decisions made, unresolved questions, follow-up actions, changed project memories, source references.

### FR-004: Project Memory Files

The system shall maintain per-project memory folders at `~/.hermes/memory/projects/<project>/` with `memory.md`, `facts.md`, `decisions.md`, `open_questions.md`, `timeline.md`, `sources.md`. Seeded projects: `hermes`, `hermes-memory`, `openclaw`, `local-ai-lab`, `personal-ai`. Auto-create on first reference.

### FR-005: Fact Store

Durable facts shall be stored in SQLite with: text, confidence, scope, project, entity, source refs (array), first/last seen, status (`active`/`superseded`/`disputed`/`archived`), supersedes / superseded_by, tags, retrieval/helpful counters, HRR vector (BLOB).

### FR-006: Decision Store

Decisions stored with: text, rationale, project, date, source refs, owner, status, implications, related fact IDs.

### FR-007: Open Questions

Open questions stored with: text, project, priority, status, source refs, created date, next action.

### FR-008: Semantic Search

Qdrant collections versioned by embedding model (e.g. `hermes_memory_chunks_nomic_v15`). Payload indexes on `project`, `date`, `memory_type`, `session_id`, `tags`, `status`. Filterable on all of these.

### FR-009: Keyword Search

SQLite FTS5 over turns, chunks, facts, decisions, open questions. Must handle exact strings: config keys, error messages, model names, hardware names, filenames, commands, URLs, code snippets.

### FR-010: Hybrid Search

Default `memory_query` mode. Combines FTS + Qdrant + Jaccard + HRR + trust + freshness with mode-driven weight adjustment. Returns results in normalized result shape (see §10). **Must auto-redistribute weights and remain functional if Qdrant, LMS embeddings, or HRR (numpy) is down.**

### FR-011: Local Dreamer

Nightly 3am cron + manual trigger (`memory_dream_now`) + optional session-end. Loads new turns since last checkpoint, generates session/daily summaries via Qwen3.6-35B at `192.168.2.105`, extracts candidate facts/decisions/questions, detects contradictions via entity+project bucket comparison (heuristic v1), writes derived memory through the canonical write path, refreshes indexes, writes a dream report to `memory/dreams/YYYY-MM-DD-HHMM.md`. Never overwrites raw.

### FR-012: Hermes Tool Interface

The plugin shall expose ONLY these tools to Hermes:

- `memory_query(query, mode?, project?, filters?, limit?)` — default hybrid; modes: `hybrid`, `semantic`, `keyword`, `facts`, `decisions`, `open_questions`, `sessions`, `daily`, `project`, `recent`, `probe`, `related`, `reason`.
- `memory_write(type, text, source_ref, project?, ...)` — types: `fact`, `decision`, `open_question`. Returns `memory_id`.
- `memory_update(memory_id, ...)` — partial updates incl. `status`, `trust_delta`.
- `memory_get_source(source_ref)` — returns raw content + excerpt + optional expansion.
- `memory_recent_context(project?, max_chars?)` — compact working set for session start.
- `memory_dream_now(scope?, project?, deep?)` — manual dreamer trigger.

`fact_feedback` (helpful / unhelpful) is preserved from holographic as a sibling tool — small, cheap, real trust-training value.

### FR-013: Built-in Hermes Memory Sync

`MEMORY.md` and `USER.md` continue to be maintained by Hermes built-ins. The plugin's `on_memory_write` hook mirrors those writes as facts (category `user_pref` or `general`). The plugin does NOT take ownership of these files.

### FR-014: Local-Only Default

No external API calls by default. All memory content stays local.

### FR-015: Redaction Guard (Phase 1, not Phase 9)

Before any disk write, content passes through a regex + entropy scan for: AWS keys, GitHub tokens, OpenAI/Anthropic API keys (`sk-...`), generic high-entropy `[A-Z0-9]{32,}` patterns, private keys (`-----BEGIN`), credit-card-like strings (Luhn check), SSN patterns. Detected matches are replaced inline with `[REDACTED:<type>]`. Redaction events are logged with `event_id` and pattern type but never the raw value. User can override per-fact via `force_no_redact: true` flag on `memory_write` (logged separately for audit).

### FR-016: Backup and Portability

`memory backup` creates a timestamped archive of raw JSONL + QMD files + SQLite DB + project files + dream reports + config. Qdrant snapshot fired via Qdrant API.

### FR-017: Source Resolver

`memory_get_source(source_ref)` resolves these ref formats:

- `session:{session_id}#turn={turn_id}`
- `session:{session_id}#turns={start}-{end}`
- `session:{session_id}#turn={turn_id}#tool={tool_call_id}`  *(new — was missing in v0.1)*
- `daily:{YYYY-MM-DD}`
- `project:{project}/memory.md#section={heading}`
- `fact:{fact_id}`
- `decision:{decision_id}`
- `question:{question_id}`
- `dream:{dream_run_id}`

### FR-018: Recent Context

`memory_recent_context` returns pinned user facts + active project facts + recent decisions + open questions + recent session/dream summaries, ALL within a configurable `max_chars` budget (default 4000), all source-traced.

### FR-019: Narrative Thread (with `/new` fix)

Per-session `~/.hermes/SESSION-THREAD/{session_id}.md` with rolling 5-exchange window, focus line, tools-used list.

**Critical change from v0.1 / holographic:** on `/new`, `/resume`, `/branch`, and post-context-compression, prior session content is injected as a **`{"role": "user", ...}` message** prepended to `conversation_history` — NOT as a `system_prompt_block()` addition. This bypasses the cached-system-prompt limitation in Hermes core (`_cached_system_prompt` is set once at agent init and only invalidated during compression). A short prompt directive ("Briefly note what you found above from the last session and ask if there's anything to continue") is included in the injected user message.

### FR-020: Provider Swap & Migration

- Activated via `memory.provider: hermes-local` in `~/.hermes/config.yaml`.
- Hermes' single-provider rule guarantees the previous provider's tools (e.g., `fact_store`) are no longer registered.
- A one-shot migration script reads holographic facts from `~/.hermes/memory_store.db` and writes them through `memory_write` into the new store. Run via `memory migrate-from-holographic`. Idempotent — safe to re-run; uses content-hash dedup.
- Holographic data is never modified or deleted.

---

## 9. Non-Functional Requirements

| ID | Requirement |
|---|---|
| NFR-001 | All memory content stays local by default. |
| NFR-002 | Every derived item traces to raw source via `source_ref`. |
| NFR-003 | Raw is append-only; failed dream/index jobs are retryable. |
| NFR-004 | Latency: keyword < 1s, semantic < 2s, hybrid < 4s. Dreamer batch-oriented. |
| NFR-005 | Idempotency: capture / indexing / dreaming safe to re-run. |
| NFR-006 | Extensible: future agents, transcripts, graphs without re-architecting. |
| NFR-007 | Local LLM compat: works with LM Studio / Ollama / llama.cpp OpenAI-compat. |
| NFR-008 | All memory files human-readable and human-editable. |
| NFR-009 | Secrets blocked by Phase 1 redaction; override is auditable. |
| NFR-010 | Answers cite source refs. |
| NFR-011 | **Schema independence** — zero direct queries into `hermes_state.db` or `memory_store.db` schemas. |
| NFR-012 | **Graceful degradation** — system functions if Qdrant, LMS embeddings, or dreamer LLM are down (hybrid weights redistribute; reads still work; writes queue for later index). |
| NFR-013 | **Concurrent safety** — plugin (in-process writes) and gateway (out-of-process reads / cron writes) coordinate via SQLite WAL + write-queue. |

---

## 10. Normalized Result Shape

Every read tool returns:

```json
{
  "query": "what did we decide about local memory?",
  "mode": "hybrid",
  "results": [
    {
      "memory_id": "decision_20260517_000001",
      "type": "decision",
      "project": "hermes-memory",
      "text": "Build as new MemoryProvider plugin alongside holographic.",
      "score": 0.94,
      "confidence": 0.95,
      "source_ref": "session:sess_20260517_hermes_001#turns=4-9",
      "backend_hits": ["sqlite_decisions", "qdrant", "fts"],
      "created_at": "2026-05-17T12:00:00-05:00",
      "updated_at": "2026-05-17T12:30:00-05:00",
      "metadata": {}
    }
  ],
  "sources": [
    {
      "source_ref": "session:sess_20260517_hermes_001#turns=4-9",
      "kind": "raw_session",
      "path": "memory/raw/2026/2026-05-17/sess_20260517_hermes_001.jsonl"
    }
  ]
}
```

---

## 11. Search Behavior

### 11.1 Keyword-first cases
Exact error strings, config keys, code, filenames, command snippets, product/model names, dates, URLs.

### 11.2 Semantic-first cases
Conceptual questions, "what did we decide about...", "summarize what we discussed about...", "find chats related to...".

### 11.3 Hybrid ranking factors
Semantic score, keyword score, Jaccard token overlap, HRR similarity, recency, project match, source type, fact/decision priority, user-pinned status, contradiction/supersession status.

### 11.4 Degradation
- Qdrant down → semantic weight → 0, redistributed to FTS+Jaccard.
- LMS embeddings down → same.
- numpy missing → HRR weight → 0, redistributed.
- All four backends down → return error with `degraded_modes: [...]`.

---

## 12. Dreaming Behavior

### 12.1 Cadence
- Nightly cron at 3am (workhorse)
- Manual: `memory_dream_now`
- Session-end (optional flag)
- Weekly deep dream (cross-week consolidation)

### 12.2 Output
- One file per run: `memory/dreams/YYYY-MM-DD-HHMM.md`
- Updated daily / project memory files
- New rows in `facts`, `decisions`, `open_questions`, `dream_runs`

### 12.3 Contradiction Handling (heuristic v1)
- Group candidate facts by `(project, entity, category)`.
- If a candidate matches an existing fact's bucket but contradicts on key tokens, do NOT overwrite — write the new fact with `status='disputed'` and `supersedes_fact_id` populated; emit a dream-report warning.
- LLM-based semantic contradiction detection deferred to post-MVP.

### 12.4 Promotion Levels
1. raw → 2. indexed → 3. summarized → 4. candidate fact → 5. durable fact → 6. pinned memory.

Default auto-promote threshold: 0.8 confidence. Below threshold: candidate, requires manual review (CLI in MVP, dashboard post-MVP).

---

## 13. Integration

### 13.1 Hermes Plugin
- Registered via `plugins/memory/hermes-local/plugin.yaml` + `register(ctx)`.
- Activated by `memory.provider: hermes-local` in config.
- Plugin config block under `plugins.hermes-local-memory:` in `config.yaml`.

### 13.2 FastAPI Gateway
- Default port: `8787`.
- Started by systemd unit or `memory serve` CLI.
- All endpoints documented in TDD §5.

### 13.3 Qdrant
- URL: `http://localhost:6333` (already running).
- Collections versioned: `hermes_memory_<type>_<embed_model>_<embed_version>`.

### 13.4 LM Studio
- Embeddings: `http://192.168.2.105:1235` → `text-embedding-nomic-embed-text-v1.5@f16` (768d).
- Dreamer LLM: `http://192.168.2.105:1234` → Qwen3.6-35B.

### 13.5 SQLite
- File: `~/.hermes/memory/memory.sqlite`.
- WAL mode with NFS/SMB/FUSE fallback (reuse `hermes_state.apply_wal_with_fallback`).
- Single writer per process; plugin and gateway coordinate via in-DB advisory locks for dreamer batch writes.

---

## 14. Risks & Mitigations

(Full register in `PROJECT.md §8`. Highlights below.)

| Risk | Severity | Mitigation |
|---|---|---|
| Hermes upstream schema changes | High | Own our SQLite file. Touch Hermes only via public ABCs/helpers. |
| Embedding model swap | Medium | Collection naming includes model version. Rebuild from raw on swap. |
| Narrative thread injection still broken | Medium | Use user-message injection (not system-prompt). Integration test covers /new. |
| Dreamer hallucination | High | Source refs required. Confidence threshold. Disputed status, not silent overwrite. |
| Secrets leak | High | Redaction in Phase 1 with fixture tests. |
| Concurrent writes | Low/Med | WAL + single-writer + advisory locks. |
| Disk growth | Medium | Backup policy + post-MVP compression. |

---

## 15. Success Metrics

### 15.1 MVP Acceptance
- 100% of new Hermes sessions captured to JSONL.
- 100% exported to QMD/Markdown.
- Keyword search finds fixture exact strings.
- Semantic search finds fixture conceptual matches.
- Hybrid search merges + deduplicates.
- Dreamer produces daily + project memory files with source refs.
- Hermes calls memory through new tools only — `fact_store` no longer in toolset.
- After `/new`, assistant references prior session focus in first reply.
- Migration from holographic completes with zero data loss.
- All indexes rebuildable from raw JSONL.

### 15.2 Quality
- User-perceived recall precision acceptable on real workflow queries.
- Memory writes are visible and correctable.
- Contradictions surfaced, not hidden.
- Every answer source-citable.

---

## 16. MVP Release Criteria

The MVP ships when:

1. Lossless capture verified.
2. Raw JSONL + QMD generated.
3. Schema in place + populated.
4. FTS5 keyword search works.
5. Qdrant semantic search works.
6. Hybrid search works.
7. Dreamer generates daily / project memory.
8. Plugin tools available; `fact_store` confirmed absent.
9. Every derived memory traces to source.
10. `/new` narrative thread injection works (acceptance test).
11. Redaction tested against fixture secrets.
12. Backup + rebuild documented and tested.
13. Migration from holographic complete + reversible (provider config flip).
14. All MVP acceptance scenarios in `Plan.md §13` pass.

---

## 17. Open Questions for Sign-Off

| ID | Question | Recommendation |
|---|---|---|
| Q1 | Final plugin name? | `hermes-local` (short config key: `memory.provider: hermes-local`). Alt: `hermes-local-memory`. |
| Q2 | Gateway lifecycle? | systemd unit + `memory serve`; auto-start with Hermes. |
| Q3 | Plugin-only mode (no gateway)? | Yes — plugin can call `memory_core` directly for all reads. Gateway is required only for cross-process access (cron dreamer, future OpenClaw). |
| Q4 | Session-end dreaming? | Off by default; enable per user preference. Cron at 3am is the workhorse. |
| Q5 | Narrative-thread retention window? | 30 days of per-session files; dreamer rolls older ones into daily/project memory. |

---

## 18. References

- `~/.hermes/PROJECTS/hermes-memory/Memory_References.md`
- Existing plugin code:
  - `~/.hermes/hermes-agent/agent/memory_provider.py` (ABC)
  - `~/.hermes/hermes-agent/plugins/memory/holographic/` (primary reference)
  - `~/.hermes/hermes-agent/plugins/memory/honcho/` (out-of-process reference)
- OpenClaw enhanced-memory: `~/.openclaw/workspace/skills/enhanced-memory/README.md`
- v0.1 docs: `docs/archive/v0.1-original/`
