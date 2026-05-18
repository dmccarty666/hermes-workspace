# Plan: Hermes Local Memory Pack

**Document:** `Plan.md`
**Project:** `hermes-memory`
**Owner:** David McCarty
**Version:** 0.2 (rewrite — see `docs/archive/v0.1-original/` for v0.1)
**Date:** 2026-05-17
**Status:** Draft phased delivery plan

---

## 1. Delivery Strategy

Six tight phases, each ending in a working, verifiable slice. MVP = Phases 1–6.

```text
Phase 1: Foundation + Lossless Capture + Redaction
Phase 2: Keyword Search + Plugin Activation
Phase 3: Semantic Search (Qdrant + LMS embeddings)
Phase 4: Hybrid Retrieval + Recent Context
Phase 5: Narrative Thread (with fixed /new) + Dreamer v1
Phase 6: Migration + Hardening + Operations
```

Each phase has 1 sprint of focused work — total estimate **2–3 weeks** of focused build time.

---

## 2. Global Definition of Done

A story is done when:

1. Code committed to `hermes-agent` repo on a feature branch.
2. Runs locally end-to-end (smoke test passes).
3. Unit tests pass (`scripts/run_tests.sh tests/<module>/`).
4. Integration test exists where applicable.
5. Docs updated in `~/.hermes/PROJECTS/hermes-memory/` (PROJECT/TDD/TASKLIST as relevant).
6. Logs visible at `~/.hermes/logs/memory-*.log`.
7. No secrets in commit.
8. Source refs preserved for any derived memory writes.
9. Feature visible from CLI or tool call (user can exercise it).
10. Does not break existing capture/search flows (regression suite).

---

## 3. Phase 1: Foundation + Lossless Capture + Redaction

**Sprint goal:** Capture every Hermes turn losslessly to disk and SQLite, with redaction running before any write.

### Epic 1.1: Project Scaffold

**Story 1.1.1 — Create plugin + core scaffolding**

- Create `plugins/memory/hermes-local/{__init__.py, plugin.yaml, narrative.py, tools.py, prefetch.py, README.md}`
- Create `hermes_memory_core/{__init__.py, store/{sqlite.py,qdrant.py,fs.py}, search/{hybrid.py,hrr.py}, write/{pipeline.py,redaction.py}, source.py, embed.py, chunk.py, dream/{worker.py,prompts/}}` inside the hermes-agent tree (per user direction: code lives in natural Hermes locations)
- Add config loader reading `plugins.hermes-local-memory` block from `~/.hermes/config.yaml`
- `register(ctx)` entry point — registers plugin; **does NOT activate** until `memory.provider: hermes-local` is set in config
- Document folder structure in TDD §6.1
- **Acceptance:** Plugin imports cleanly. Setting `memory.provider: hermes-local` activates it (verified via `hermes config get memory.provider`). `is_available()` returns True. Tool list is currently empty (no tools yet).

**Story 1.1.2 — `memory init` CLI command**

- Add `memory` CLI subcommand to Hermes CLI (`hermes_cli/commands.py`)
- `memory init` creates `~/.hermes/memory/{raw,qmd,daily,projects,entities,dreams,prompts,exports,backups,index,config}`
- Idempotent — running twice is safe.
- Creates starter project folders: `hermes`, `hermes-memory`, `openclaw`, `local-ai-lab`, `personal-ai` with `memory.md`/`facts.md`/`decisions.md`/`open_questions.md`/`timeline.md`/`sources.md` stubs
- **Acceptance:** `hermes memory init` creates the tree, re-running is no-op. README documents structure.

### Epic 1.2: SQLite Schema + Migrations

**Story 1.2.1 — Schema + migration system**

- Implement `hermes_memory_core.store.sqlite.MemoryDB` with WAL fallback (reuse `hermes_state.apply_wal_with_fallback`)
- Apply v1 schema from TDD §6.2 (sessions, turns, raw_events, chunks, facts, entities, fact_entities, decisions, open_questions, dream_runs, memory_banks, schema_version, audit_log) + FTS5 virtuals + triggers
- Migration table tracks applied versions; reapply is safe
- **Acceptance:** `hermes memory db init` creates fresh DB; all tables present; schema_version row exists; second run is no-op.

### Epic 1.3: Event Schema + JSONL Capture

**Story 1.3.1 — Define event schema**

- JSON schema for events: `event_id, session_id, turn_id, sequence, timestamp, role, content, agent, project, source, tags, tool_calls, attachments, metadata, hash, parent_turn_id, embedding_status, index_status, dream_status`
- Validator with clear error messages on missing fields
- **Acceptance:** Sample valid + invalid events handled correctly. Schema versioned.

**Story 1.3.2 — JSONL append**

- Implement `hermes_memory_core.store.fs.append_event(event)` → writes to `~/.hermes/memory/raw/YYYY/YYYY-MM-DD/{session_id}.jsonl`
- Content hashing for dedup
- File-handle pool / lazy open per session
- **Acceptance:** Unit test writes 100 events to JSONL, reads them back in order, checks hashes.

**Story 1.3.3 — Capture pipeline (`sync_turn` plumbing)**

- Implement `HermesLocalProvider.sync_turn(user, asst, session_id)`
- Wire into `hermes_memory_core.write.pipeline.capture_event(event)`:
  - Run redaction (story 1.4.1) → return redacted content + types
  - Append JSONL
  - Insert into SQLite `sessions` (upsert on session_id), `turns`, `raw_events`
  - Update `audit_log` if redaction fired
  - Mark turn status `pending` for index + dream
- **Acceptance:** Send a fake Hermes turn → confirm JSONL row, 1 sessions row, 1 turns row, raw_events row.

### Epic 1.4: Redaction Guard (Phase 1, not Phase 9!)

**Story 1.4.1 — Implement redaction scanner**

- `hermes_memory_core.write.redaction.scan(content) -> (redacted, types_redacted)`
- Patterns per TDD §7.1: AWS, GitHub, OpenAI/Anthropic, private keys, Luhn cards, SSN, high-entropy strings
- `[REDACTED:<type>]` inline replacement
- Audit-log row never includes raw value
- `force_no_redact=true` override on `memory_write` skips scan but writes `audit_log` row `redaction_override`
- **Acceptance:** Fixture content with each secret type → all caught. Negative test: ordinary content not touched.

**Story 1.4.2 — Wire redaction into capture path**

- Capture pipeline calls `redaction.scan` BEFORE any write
- Tool result content also scanned (catch secrets in tool outputs)
- Attachments scanned by filename pattern only (binary content not scanned in MVP)
- **Acceptance:** Send a turn containing `sk-abc123...` → JSONL + SQLite both contain `[REDACTED:openai_key]`. Original value never appears on disk.

### Epic 1.5: QMD Exporter

**Story 1.5.1 — QMD/Markdown session exporter**

- `hermes_memory_core.store.fs.export_qmd(session_id)` writes `~/.hermes/memory/qmd/YYYY/YYYY-MM-DD/{session_id}.qmd`
- Frontmatter: session_id, project, started_at, ended_at, tags, source_refs
- Body: chronological turns, tool-call summaries
- Triggered: on session_end and on manual export
- **Acceptance:** Sample session → readable QMD with all turns + frontmatter.

### Epic 1.6: Memory CLI v1

**Story 1.6.1 — CLI smoke commands**

- `hermes memory health` — shows DB path, FTS available, redaction enabled, etc.
- `hermes memory init`
- `hermes memory db init`
- `hermes memory capture-test` — injects a fake turn end-to-end
- `hermes memory ls-sessions` — lists captured sessions
- **Acceptance:** All commands documented in help, all run, exit codes correct.

### Phase 1 Acceptance Gate

A real Hermes CLI session captures losslessly:
- JSONL exists for session
- SQLite has session + N turns
- Fixture API key inserted in a turn → redacted in both JSONL and SQLite
- QMD exported, readable
- Re-running capture on same session is idempotent (no dup rows)

---

## 4. Phase 2: Keyword Search + Plugin Activation

**Sprint goal:** `memory_query` tool returns FTS5 keyword matches; activating the provider drops `fact_store` from the tool list.

### Epic 2.1: FTS5 Search

**Story 2.1.1 — FTS5 query function**

- `hermes_memory_core.search.fts5_search(query, filters, limit)` returns ranked rows + excerpts
- Snippet generation via SQLite `snippet()` function
- Supports filters: `project`, `session_id`, `date_from`, `date_to`, `role`
- **Acceptance:** Insert turn with `agents.list.0.tools` → query finds it → returns excerpt + source_ref.

### Epic 2.2: Tool Surface (subset)

**Story 2.2.1 — Register `memory_query` (keyword mode only)**

- Implement `get_tool_schemas()` returning ONE schema: `memory_query`
- Implement `handle_tool_call()` dispatching `memory_query(mode='keyword'|'sessions'|'recent')` only (others raise `not_implemented_yet`)
- Wire normalized result shape per TDD §5.2 / PRD §10
- **Acceptance:** Set `memory.provider: hermes-local`, restart CLI, run `memory_query(query='agents.list', mode='keyword')` → returns sources.

**Story 2.2.2 — Source resolver**

- Implement `hermes_memory_core.source.resolve(source_ref)` for session-related refs
- Register `memory_get_source` tool
- **Acceptance:** Tool returns raw turn content for a given source_ref. Invalid refs return clean error.

### Epic 2.3: Provider Swap Verification

**Story 2.3.1 — Confirm holographic tools unloaded**

- With `memory.provider: hermes-local`, run `hermes --tools` (or equivalent inspection): assert `fact_store` and `fact_feedback` (the holographic one) are NOT in the tool list
- Add integration test
- **Acceptance:** Provider swap is documented + verified.

### Phase 2 Acceptance Gate

- `memory.provider: hermes-local` activates the plugin.
- `fact_store` and other holographic tools are not registered.
- `memory_query(query='X', mode='keyword')` returns results with source refs.
- `memory_get_source` resolves and returns raw content.

---

## 5. Phase 3: Semantic Search

**Sprint goal:** `memory_query(mode='semantic')` returns Qdrant vector matches with payload filters.

### Epic 3.1: Qdrant + Embeddings Setup

**Story 3.1.1 — Qdrant collections (versioned)**

- Create `hermes_memory_chunks_nomic_v15`, `hermes_memory_summaries_nomic_v15`, `hermes_memory_facts_nomic_v15`, `hermes_memory_decisions_nomic_v15`
- Vector dim 768, cosine distance
- Payload indexes for `project`, `date`, `memory_type`, `session_id`, `tags`, `status`
- Idempotent setup script
- **Acceptance:** `hermes memory qdrant-init` creates collections; re-running is no-op.

**Story 3.1.2 — LMS embedding client**

- `hermes_memory_core.embed.LMSEmbedder` calls `http://192.168.2.105:1235/v1/embeddings`
- Model: `text-embedding-nomic-embed-text-v1.5`
- Retry on transient errors; clear error if endpoint is down
- Health check: returns dim and model
- **Acceptance:** Embed sample text → 768d vector. Endpoint down → useful error.

### Epic 3.2: Chunking + Indexing

**Story 3.2.1 — Chunker**

- `hermes_memory_core.chunk.chunk_turns(turns, size=512, overlap=128, prefer_boundaries=True)`
- Multi-turn tool sequences treated as one chunk when ≤ 1024 tokens
- Tokenization: tiktoken `cl100k_base`
- Each chunk: stable ID from `(session_id, start_turn, end_turn, text_hash, embed_model)`
- **Acceptance:** Sample 10-turn session → expected chunk count + boundaries.

**Story 3.2.2 — Async indexer**

- Background worker thread (or systemd-style) that polls `turns where index_status='pending'`
- Chunks → embeds → upserts to Qdrant → updates `chunks.qdrant_point_id` + `turns.index_status='indexed'`
- Failure → `index_status='failed'` + retry policy
- **Acceptance:** Capture a session → wait → confirm chunks + Qdrant points exist. Restart agent → no duplicate chunks.

### Epic 3.3: Semantic Search

**Story 3.3.1 — `memory_query(mode='semantic')`**

- Embed query → Qdrant search with payload filters
- Returns normalized results
- **Acceptance:** Conceptual fixture session → semantic query returns relevant chunk with source_ref.

### Phase 3 Acceptance Gate

- Conceptual fixture query returns relevant Qdrant hit.
- Re-indexing is idempotent.
- Embedding endpoint down → indexer queues, reads still work via keyword.

---

## 6. Phase 4: Hybrid Retrieval + Recent Context

**Sprint goal:** Default hybrid mode merges all backends with graceful degradation. `memory_recent_context` returns a compact working set.

### Epic 4.1: Hybrid Scorer

**Story 4.1.1 — Hybrid merge + scoring**

- `hermes_memory_core.search.hybrid.search(query, mode, filters, limit)` per TDD §8
- Implements per-backend score normalization, weighted combine, trust + freshness, dedup by `(memory_id, source_ref, content_hash)`
- Backend weights per mode (default + `keyword`/`semantic`/`facts_only`)
- **Acceptance:** Single hybrid query returns merged sorted results with `backend_hits` showing which backends matched.

**Story 4.1.2 — Graceful degradation**

- Auto-redistribute weights when a backend reports unavailable
- Return `degraded_modes` array in response when degradation occurred
- **Acceptance:** Kill Qdrant → hybrid still returns results (FTS + Jaccard); response includes `degraded_modes: ['qdrant']`.

### Epic 4.2: HRR Fork

**Story 4.2.1 — Fork HRR library**

- Copy `plugins/memory/holographic/holographic.py` → `hermes_memory_core/search/hrr.py`
- Add license/attribution comment to original
- Identical surface: `encode_atom`, `encode_text`, `encode_fact`, `bind`, `unbind`, `bundle`, `similarity`, `phases_to_bytes`, `bytes_to_phases`, `snr_estimate`
- **Acceptance:** Tests from holographic copied + pass against our fork.

**Story 4.2.2 — HRR-backed `probe`/`related`/`reason` modes**

- Wire modes into hybrid scorer (per-fact HRR vector lookup)
- Falls back to keyword search if numpy missing (same pattern as holographic)
- **Acceptance:** `memory_query(query=..., mode='probe', entity='Hermes')` returns entity-bound facts.

### Epic 4.3: Recent Context

**Story 4.3.1 — `memory_recent_context`**

- Pinned user facts (scope='user' + status='active', top by trust)
- Active project facts (top N by trust where project=current)
- Recent decisions (last 14 days)
- Open questions (status='open')
- Recent dream summaries (last 7 days)
- Token budget: default 4000 chars, configurable
- **Acceptance:** Tool returns compact context fitting budget; source refs included.

### Epic 4.4: Write Tools

**Story 4.4.1 — `memory_write` for facts/decisions/open_questions**

- Implement canonical write path per TDD §4 / PRD §10
- Redaction always runs unless `force_no_redact=true` (logged)
- Contradiction stub: just check for content_hash dup (LLM-based contradiction is Phase 5)
- HRR vector computed for facts
- FTS5 + Qdrant updated post-write
- **Acceptance:** Write a fact → reappears in `memory_query(mode='facts_only')`; source_ref required; hash-dup blocked.

**Story 4.4.2 — `memory_update` + `fact_feedback`**

- `memory_update` supports content/trust/tags/status/category
- `fact_feedback` ports holographic semantics (+0.05 / -0.10)
- **Acceptance:** Update + feedback round-trip working; trust clamped [0,1].

### Phase 4 Acceptance Gate

- Hybrid is the default mode; merges + dedupes + ranks.
- Killing Qdrant doesn't break reads (graceful degrade).
- `memory_recent_context` produces a compact + source-traced budget-fit response.
- Writes work + are auditable.

---

## 7. Phase 5: Narrative Thread + Dreamer v1

**Sprint goal:** `/new` correctly injects prior session context. Nightly cron extracts facts/decisions and writes daily/project memory.

### Epic 5.1: Narrative Thread Port

**Story 5.1.1 — Port narrative thread file format**

- Implement `narrative.py` in plugin:
  - Per-session SESSION-THREAD/{session_id}.md (lifted from holographic)
  - Rolling 5-exchange window
  - Tools-used tracking
  - `_write_thread` + `_read_thread_file`
- **Acceptance:** Send 3 turns → thread file written + readable.

**Story 5.1.2 — `/new` user-message injection (the bug fix)**

- In `on_session_switch(new_id, parent_session_id, reset=False)`:
  - Read parent thread file
  - Construct injection user-message per TDD §9.2
  - Insert into `agent.conversation_history` (via stored agent_ref from `initialize` kwargs)
  - Mark `_nt_first_turn_done = True`
- Fallback when `agent_ref` unavailable: call `agent._invalidate_system_prompt()` reflectively as last resort
- **Acceptance:** Integration test `test_narrative_thread_inject.py` (per TDD §9.4) passes for `/new`, `/resume`, `/branch`, post-compaction.

### Epic 5.2: Dreamer Prompts

**Story 5.2.1 — Author prompt templates**

- Write all 6 prompts under `~/.hermes/memory/prompts/` per TDD §10.2
- Each enforces strict JSON output; forbids hallucination; requires source_ref
- Version stamps in prompts
- **Acceptance:** Run each prompt manually against Qwen3.6-35B with sample input → JSON output validates against schema.

### Epic 5.3: Dreamer Worker

**Story 5.3.1 — Dream pipeline (stages 1–9)**

- `hermes_memory_core.dream.worker.run(scope='since_last' | 'today' | 'date' | 'project' | 'weekly', deep=False)`
- Implements stages from TDD §4.5
- LLM endpoint configurable; defaults to Qwen3.6-35B at `192.168.2.105:1234`
- JSON-mode requested where supported
- All output candidates go through `memory_core.write.pipeline.write_memory`
- Status tracking: `dream_runs.status`, `turns.dream_status`
- **Acceptance:** Manual `memory_dream_now(scope='today')` → dream report written, facts/decisions/questions extracted with source refs.

**Story 5.3.2 — Contradiction detection (heuristic v1)**

- Per TDD §10.3: bucket by `(project, entity, category)`, Jaccard threshold, conflict yields `status='disputed'` + `supersedes_fact_id` link
- Dream report flags conflicts; doesn't auto-resolve
- **Acceptance:** Fixture with two contradictory facts → second one is `disputed`, both visible, dream report flags it.

**Story 5.3.3 — Daily memory file generator**

- Update or create `~/.hermes/memories/YYYY-MM-DD.md` with: sessions processed, topics, facts, decisions, open questions, changed project memories
- Preserve manually-edited content above an `<!-- AUTO-GENERATED BELOW -->` marker
- **Acceptance:** Re-running dreamer on the same date appends/updates safely, doesn't clobber manual notes.

**Story 5.3.4 — Project memory file updater**

- For each project touched, update `memory.md`, `facts.md`, `decisions.md`, `open_questions.md`, `timeline.md`
- Use `update_project_memory.md` prompt — give existing content + new items, get updated markdown
- Same auto-generated marker
- **Acceptance:** Project memory grows over runs; never auto-deletes user content.

### Epic 5.4: Cron Schedule

**Story 5.4.1 — systemd timer + service**

- `hermes-memory-dream.service` invokes `python -m hermes_memory_core.dream --scope since_last`
- `hermes-memory-dream.timer` fires at 3:00 local time daily
- Install script: `scripts/install-cron.sh` copies units + `systemctl enable --now`
- **Acceptance:** Manually trigger timer → dream runs → log shows completion.

### Phase 5 Acceptance Gate

- After `/new`, assistant first response references prior session focus.
- Nightly cron runs at 3am → daily memory file updated, project memory files updated, dream report written.
- Contradictions surface in dream report, never silently overwrite.

---

## 8. Phase 6: Migration + Hardening + Operations

**Sprint goal:** Migrate from holographic with zero data loss. Backup + rebuild documented and tested. MVP acceptance suite passes.

### Epic 6.1: Migration

**Story 6.1.1 — Migration script (holographic → hermes-local)**

- `scripts/migrate_from_holographic.py` per TDD §16
- Reads holographic `memory_store.db` (read-only)
- Maps facts/entities/fact_entities → new schema via `memory_write`
- Rebuilds HRR banks
- Idempotent (content_hash dedup)
- Writes migration report `exports/migration-holographic-{ts}.md`
- **Acceptance:** Run on real holographic DB → all facts present in new DB, no data lost, holographic DB unchanged. Re-run is no-op.

### Epic 6.2: Backup + Rebuild

**Story 6.2.1 — `memory backup`**

- Creates timestamped archive: raw JSONL + QMD + SQLite (via `.backup` API) + project files + dream reports + config + Qdrant snapshot
- Excludes: secrets-relevant files (none if redaction works) + logs
- Manifest file in archive
- **Acceptance:** Backup completes; archive contains all artifacts; manifest accurate.

**Story 6.2.2 — `memory rebuild-indexes`**

- Per TDD §14.2
- Drops FTS shadow tables, recreates them
- Deletes + recreates Qdrant collections (versioned by current embed model)
- Re-scans raw JSONL → re-inserts turns (idempotent via hash) → re-chunks → re-embeds → re-upserts
- **Acceptance:** Drop SQLite + Qdrant entirely; run rebuild; all sessions/turns/chunks/embeddings restored from raw JSONL.

### Epic 6.3: Observability

**Story 6.3.1 — Health endpoints + metrics file**

- Gateway: `/health`, `/health/sqlite`, `/health/qdrant`, `/health/embedding`, `/health/llm`
- Plugin updates `~/.hermes/memory/metrics.json` after each capture / index / dream batch (gauges per TDD §17.2)
- **Acceptance:** `curl http://127.0.0.1:8787/health` returns rolled-up status with sub-statuses.

### Epic 6.4: Documentation + Test Suite

**Story 6.4.1 — User docs**

- README in `plugins/memory/hermes-local/README.md` covering: install, activation, migration, CLI commands, tools, troubleshooting
- Operator runbook in `~/.hermes/PROJECTS/hermes-memory/docs/RUNBOOK.md`: backup, rebuild, dreamer ops, log locations
- **Acceptance:** New reader can set up + use the system from docs only.

**Story 6.4.2 — MVP acceptance test suite**

- Implement all scenarios from §9 below as pytest tests
- Run as `scripts/run_tests.sh tests/integration/memory/`
- **Acceptance:** Full suite green.

### Phase 6 Acceptance Gate

- Migration runs without loss.
- Backup + rebuild round-trip preserves all data.
- All MVP acceptance scenarios pass.

---

## 9. MVP Acceptance Test Suite

These scenarios MUST pass before declaring MVP done. Each maps to a pytest integration test under `tests/integration/memory/`.

### Scenario A: Lossless Capture

1. Start fresh memory init.
2. Send a Hermes session with 10 turns.
3. Verify raw JSONL exists with 10 entries.
4. Verify QMD exists, human-readable.
5. Verify SQLite has 1 session row + 10 turns rows + raw_events rows.

### Scenario B: Redaction (Phase 1!)

1. Send a turn containing `sk-test12345...openai_keylike_token...`, `AKIA1234567890ABCDEF`, `ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`.
2. Verify JSONL + SQLite + QMD all contain `[REDACTED:openai_key]`, `[REDACTED:aws_access_key]`, `[REDACTED:github_token]`.
3. Verify original values nowhere on disk.
4. Verify audit_log row exists with redaction types.

### Scenario C: Keyword Search

1. Insert a turn containing `agents.list.0.tools`.
2. `memory_query(query='agents.list.0.tools', mode='keyword')`.
3. Verify exact match returned with source_ref.

### Scenario D: Semantic Search

1. Insert a session discussing "avoiding paid memory provider Honcho on cost grounds".
2. `memory_query(query='free local memory instead of paid provider', mode='semantic')`.
3. Verify relevant chunk returned, semantically matched.

### Scenario E: Hybrid Search

1. `memory_query(query='local memory like lossless claw with QMD', mode='hybrid')`.
2. Verify results include semantic and keyword matches.
3. Verify dedup collapses overlapping hits.
4. Verify `backend_hits` arrays populated.

### Scenario F: Graceful Degradation

1. Stop Qdrant.
2. `memory_query(query='X', mode='hybrid')`.
3. Verify response includes `degraded_modes: ['qdrant']` and still returns FTS results.
4. Restart Qdrant.
5. Re-query → no longer degraded.

### Scenario G: Dreaming

1. Run a session with explicit facts ("I prefer Qwen over Nemotron"), explicit decisions ("We chose nightly 3am dreamer"), explicit open questions ("Should we run weekly deep dreams?").
2. Run `memory_dream_now(scope='today')`.
3. Verify dream report exists.
4. Verify daily memory file updated.
5. Verify `facts`/`decisions`/`open_questions` rows created with source refs pointing back to actual turns.

### Scenario H: Contradiction Detection

1. Insert fact F1: "Project hermes-memory uses Qwen3.6-35B for dreaming".
2. Insert fact F2: "Project hermes-memory uses Nemotron 120B for dreaming" (contradiction).
3. Verify F2 status = `disputed`, supersedes_fact_id links to F1.
4. Verify dream report flags the conflict.

### Scenario I: Provider Swap

1. With `memory.provider: holographic`, list tools → confirm `fact_store` present.
2. Set `memory.provider: hermes-local`, restart CLI, list tools.
3. Verify `fact_store` and `fact_feedback` (holographic) are GONE.
4. Verify `memory_query`, `memory_write`, etc. PRESENT.

### Scenario J: Narrative Thread `/new` Injection

1. Start CLI session A, send 3 turns about "Project Foo authentication design".
2. `/quit`.
3. Restart CLI, send turn "What were we working on?"
4. Verify response references "Project Foo authentication".
5. `/new`.
6. Send turn "anything to continue?"
7. Verify response references the prior session focus.

### Scenario K: Migration from Holographic

1. Snapshot holographic `memory_store.db` count and content_hash list.
2. Run `scripts/migrate_from_holographic.py`.
3. Verify hermes-local SQLite has same fact_text content for all hashes.
4. Verify holographic DB unchanged (counts identical).
5. Re-run migration → 0 new rows.

### Scenario L: Rebuild from Raw

1. Capture a session normally.
2. Delete `memory.sqlite` + Qdrant collections.
3. Run `memory rebuild-indexes`.
4. Verify sessions/turns/chunks/Qdrant points all restored with same counts and content.

---

## 10. Sprint 1 Concrete Task List

These get materialized as `tasks/*.md` files when Sprint 1 starts. Drawn from Phase 1.

1. `tasks/T-001-scaffold-plugin.md` (Epic 1.1, Story 1.1.1)
2. `tasks/T-002-memory-init-cli.md` (Story 1.1.2)
3. `tasks/T-003-sqlite-schema.md` (Story 1.2.1)
4. `tasks/T-004-event-schema.md` (Story 1.3.1)
5. `tasks/T-005-jsonl-append.md` (Story 1.3.2)
6. `tasks/T-006-redaction-scanner.md` (Story 1.4.1) — **schedule before T-007**
7. `tasks/T-007-capture-pipeline.md` (Story 1.3.3 + 1.4.2)
8. `tasks/T-008-qmd-exporter.md` (Story 1.5.1)
9. `tasks/T-009-cli-smoke-commands.md` (Story 1.6.1)
10. `tasks/T-010-phase1-acceptance.md` (Phase 1 gate run)

---

## 11. Out-of-Scope (Reaffirmed)

- Mem0 OSS mirror (post-MVP option)
- Graph memory (post-MVP)
- Web dashboard (post-MVP)
- Cross-agent memory bus (post-MVP)
- Document / transcript ingestion (post-MVP)
- LLM-based contradiction detection (post-MVP)
- Memory review queue UI (post-MVP — CLI in MVP)
- Multi-user governance (not on roadmap)
- Local re-ranker (post-MVP)
- JSONL compression / archival policy (post-MVP, when growth becomes a concern)

---

## 12. Risk Watch List for Build

(Cross-ref `PROJECT.md §8` full register.)

Sprint 1 must close out:

- **R6 — Secrets leak before redaction matures.** Test fixtures with each pattern type land in Sprint 1.
- **R8 — Schema-independence accidentally violated.** Code review checks: zero `import hermes_state` SQL queries, zero `memory_store.db` paths.

Sprint 5 must close out:

- **R3 — Narrative thread injection still broken on `/new`.** Integration test mandatory; no gate without it.
- **R4 — Dreamer hallucination.** Prompt templates enforce JSON + source refs; dream report shows confidence histograms.

---

## 13. References

- `PROJECT.md` — charter, risks, glossary
- `prd.md` — requirements
- `TDD.md` — technical design
- `EPICS.md` — epic ↔ phase mapping
- `Memory_References.md` — external links
- `docs/archive/v0.1-original/` — original v0.1 docs + introspection
