# Plan: Hermes Local Long-Duration Memory System

**Document:** `Plan.md`  
**Product Name:** Hermes Local Memory Pack  
**Owner:** David McCarty  
**Version:** 0.1  
**Date:** 2026-05-17  
**Status:** Draft phased implementation plan

---

## 1. Delivery Strategy

Build the system in phases so that each phase delivers useful memory capability without waiting for the full architecture.

The recommended approach:

```text
Phase 0: Foundation and repository
Phase 0A: Central memory control plane
Phase 1: Lossless capture and files
Phase 2: SQLite and keyword search
Phase 3: Qdrant semantic search
Phase 4: Hybrid retrieval and source tracing
Phase 5: Dreaming v1
Phase 6: Hermes tool integration
Phase 7: Mem0 OSS optional mirror
Phase 8: Graph memory optional expansion
Phase 9: Hardening, backup, and operations
```

The MVP is achieved by completing Phases 0, 0A, and 1 through 6.

---

## 2. Global Definition of Done

A story is done when:

1. Code/config is committed to the project repo.
2. Feature is runnable locally.
3. Unit tests pass where applicable.
4. Integration test or manual verification exists.
5. Documentation is updated.
6. Logs/errors are visible.
7. No secrets are committed.
8. Source references are preserved for memory-derived data.
9. User-facing commands or tools have examples.
10. The feature does not break existing memory capture/search flows.

---

## 3. Phase 0: Foundation

### Epic 0.1: Project Bootstrap

#### Story 0.1.1: Create repository structure

**As a** builder,  
**I want** a clean project structure,  
**so that** the memory system can be developed incrementally.

**Tasks**

- Create repo root.
- Add `README.md`.
- Add `prd.md`, `TDD.md`, and `Plan.md`.
- Add directories:
  - `memory-gateway/`
  - `memory-core/`
  - `memory-cli/`
  - `docker/`
  - `config/`
  - `tests/`
  - `docs/`
  - `scripts/`

**Acceptance Criteria**

- Repo has documented folder structure.
- Docs are placed at root or `/docs`.
- Project can be opened and understood without additional explanation.

**Definition of Done**

- Structure exists.
- README describes purpose and quick start placeholder.
- No secrets or machine-specific paths committed.

---

#### Story 0.1.2: Define initial configuration file

**As a** builder,  
**I want** a local config file,  
**so that** paths, models, and services can be changed without code edits.

**Tasks**

- Create `config/memory.yaml`.
- Include base paths, Qdrant URL, SQLite path, model endpoints, redaction settings, dreamer settings.
- Add config loader module.

**Acceptance Criteria**

- Config file loads successfully.
- Missing required config returns a clear error.
- Defaults exist for local single-machine deployment.

**Definition of Done**

- Config loader tested.
- Example config committed.
- README includes config location.

---

### Epic 0.2: Local Service Skeleton

#### Story 0.2.1: Create FastAPI memory gateway skeleton

**As Hermes,**  
**I want** a local memory API,  
**so that** I can call memory tools without knowing the storage implementation.

**Tasks**

- Create FastAPI app.
- Add `/health`.
- Add placeholder endpoints for capture, search, and dream.
- Add logging.

**Acceptance Criteria**

- Server starts locally.
- `/health` returns status OK.
- Placeholder endpoints return structured JSON.

**Definition of Done**

- Server can run with one command.
- Basic test verifies `/health`.

---

#### Story 0.2.2: Create CLI skeleton

**As a** builder,  
**I want** a command-line interface,  
**so that** I can test memory functions outside Hermes.

**Tasks**

- Create CLI entrypoint.
- Add commands:
  - `memory health`
  - `memory init`
  - `memory capture-test`
  - `memory search`
  - `memory dream`

**Acceptance Criteria**

- CLI runs locally.
- Help output is clear.
- Commands fail gracefully when dependencies are missing.

**Definition of Done**

- CLI documented.
- CLI smoke test exists.

---

## 3A. Phase 0A: Central Memory Control Plane

This phase makes the central gateway and orchestrator explicit before individual storage/index backends become silos.

### Epic 0A.1: Central Memory API Contract

#### Story 0A.1.1: Define central memory interface

**As Hermes,**  
**I want** one memory interface,  
**so that** I do not need to search Qdrant, SQLite, raw files, daily files, project files, Mem0, or graph memory separately.

**Tasks**

- Define API/tool schemas for:
  - `memory_query`
  - `memory_write`
  - `memory_get_source`
  - `memory_recent_context`
  - `memory_dream`
  - `memory_reindex`
  - `memory_update`
- Define common request/response envelope.
- Define normalized memory result object.
- Define error response object.
- Document supported query modes.

**Acceptance Criteria**

- One API contract exists for all memory access.
- Each function has JSON schema examples.
- Each result includes type, score, text, source_ref, and backend_hits.
- The contract explicitly states Hermes shall not directly access backend stores.

**Definition of Done**

- API contract documented.
- Sample requests/responses included.
- Schemas validated with tests.

---

#### Story 0A.1.2: Define normalized memory result model

**As a** memory orchestrator,  
**I want** all backend results normalized,  
**so that** search results can be merged and ranked centrally.

**Tasks**

- Define fields:
  - `memory_id`
  - `type`
  - `project`
  - `text`
  - `score`
  - `confidence`
  - `source_ref`
  - `backend_hits`
  - `created_at`
  - `updated_at`
  - `metadata`
- Map FTS results to normalized result.
- Map Qdrant results to normalized result.
- Map facts/decisions/questions to normalized result.
- Map daily/project/session file results to normalized result.

**Acceptance Criteria**

- All backends can return the same result shape.
- Normalized result includes source traceability.
- Result model supports deduplication and reranking.

**Definition of Done**

- Result model implemented.
- Unit tests cover sample result conversion from each backend type.

---

### Epic 0A.2: Memory Orchestrator

#### Story 0A.2.1: Implement orchestrator skeleton

**As the** Local Memory Gateway,  
**I want** a Memory Orchestrator component,  
**so that** I can route searches and writes through one central control plane.

**Tasks**

- Create orchestrator module.
- Add backend adapter interface.
- Add registry for enabled backends.
- Add placeholder adapters:
  - structured store
  - FTS
  - Qdrant
  - file memory
  - optional Mem0
  - optional graph
- Add query planner stub.

**Acceptance Criteria**

- Orchestrator can register backends.
- Orchestrator can route a mock query to multiple mock backends.
- Orchestrator returns one normalized result list.

**Definition of Done**

- Orchestrator skeleton implemented.
- Mock backend tests pass.

---

#### Story 0A.2.2: Implement central query fan-out and merge

**As Hermes,**  
**I want** `memory_query` to search all relevant memory stores,  
**so that** I receive one complete memory answer context.

**Tasks**

- Parse query mode.
- Select backends based on mode and filters.
- Run backend searches.
- Merge results.
- Deduplicate by source_ref, memory_id, and content hash.
- Rerank results.
- Return normalized response.

**Acceptance Criteria**

- A single `memory_query` call can return results from multiple backends.
- Duplicates are collapsed.
- Results include backend_hits showing which backends matched.
- Query modes influence ranking.

**Definition of Done**

- Integration test uses mock FTS, mock Qdrant, mock facts, and mock project memory.
- Response contains one merged ranked list.

---

#### Story 0A.2.3: Implement central write coordinator

**As a** memory system,  
**I want** all durable memory writes to go through one canonical write path,  
**so that** memory does not fragment across files and indexes.

**Tasks**

- Implement `memory_write`.
- Validate required fields.
- Require source refs unless manually pinned.
- Run redaction checks.
- Check duplicates.
- Check contradiction candidates.
- Write canonical SQLite record.
- Fan out index/file updates.
- Return canonical memory_id.

**Acceptance Criteria**

- Facts/decisions/questions cannot be written only to one backend.
- Write returns canonical memory_id and source_ref.
- Failed secondary index update is logged and retryable.
- Duplicate writes do not create duplicate durable memories.

**Definition of Done**

- Central write tests pass.
- Failure handling documented.

---

#### Story 0A.2.4: Implement central source resolver

**As Hermes,**  
**I want** `memory_get_source`,  
**so that** I can trace any memory result back to the original raw source.

**Tasks**

- Parse source_ref formats.
- Resolve raw session turn refs.
- Resolve QMD/session refs.
- Resolve daily/project refs.
- Resolve fact/decision/question refs.
- Return excerpt and optional expanded source.

**Acceptance Criteria**

- Every normalized result source_ref can be resolved.
- Invalid source refs return clear errors.
- Multi-turn source refs return the right turn range.

**Definition of Done**

- Source resolver tests pass.
- Source format documented.

---

#### Story 0A.2.5: Implement central recent context

**As Hermes,**  
**I want** compact recent/project memory context,  
**so that** I can begin a session with the right working set.

**Tasks**

- Implement `memory_recent_context`.
- Include pinned user facts.
- Include active project facts.
- Include recent decisions.
- Include open questions.
- Include recent session/dream summaries.
- Enforce max token/character budget.

**Acceptance Criteria**

- Recent context is compact.
- Context can be filtered by project.
- Context includes source refs.
- Response is suitable for prompt injection into Hermes.

**Definition of Done**

- Endpoint implemented.
- Test verifies token/character budget behavior.

---

### Epic 0A.3: Central Gateway Integration Tests

#### Story 0A.3.1: Prove no-silo retrieval

**As a** user,  
**I want** one query to retrieve memory from all stores,  
**so that** the memory system behaves as one brain rather than separate silos.

**Tasks**

- Seed one fact in SQLite.
- Seed one decision in SQLite.
- Seed one exact keyword in FTS.
- Seed one semantic chunk in Qdrant/mock Qdrant.
- Seed one daily memory file.
- Seed one project memory file.
- Run one `memory_query`.

**Acceptance Criteria**

- One query returns all relevant memory types.
- Each result has type, score, source_ref, and backend_hits.
- Hermes does not directly query individual stores.
- Duplicates are merged.

**Definition of Done**

- No-silo integration test passes.
- Test is included in MVP acceptance suite.


---

## 4. Phase 1: Lossless Capture and File Store

### Epic 1.1: Filesystem Memory Layout

#### Story 1.1.1: Create memory directory initializer

**As a** builder,  
**I want** the memory folder structure created automatically,  
**so that** the system has a predictable source-of-truth layout.

**Tasks**

- Implement `memory init`.
- Create directories:
  - raw
  - qmd
  - daily
  - projects
  - entities
  - dreams
  - index
  - logs
  - backups
  - prompts
- Create starter project folders for:
  - hermes
  - openclaw
  - local-ai-lab

**Acceptance Criteria**

- `memory init` creates all directories.
- Running it twice is safe.
- Existing files are not overwritten unless explicitly requested.

**Definition of Done**

- Unit test confirms idempotency.
- README shows directory layout.

---

#### Story 1.1.2: Create starter memory files

**As Hermes,**  
**I want** curated memory files,  
**so that** I can read compact durable context.

**Tasks**

- Create:
  - `MEMORY.md`
  - `USER.md`
  - project `memory.md`
  - project `facts.md`
  - project `decisions.md`
  - project `open_questions.md`
  - project `timeline.md`

**Acceptance Criteria**

- Files exist after initialization.
- Files contain headings and instructions.
- Files are human-readable and agent-readable.

**Definition of Done**

- Starter templates committed.
- Init command writes from templates.

---

### Epic 1.2: Raw Event Capture

#### Story 1.2.1: Define event schema

**As a** memory system,  
**I want** a stable event schema,  
**so that** raw history can be preserved and reprocessed later.

**Tasks**

- Define JSON schema for captured events.
- Include event ID, session ID, role, content, timestamp, metadata, hash, tags, source, tool calls.
- Add validation.

**Acceptance Criteria**

- Valid event passes.
- Invalid event returns clear validation errors.
- Event schema is versioned.

**Definition of Done**

- Schema file committed.
- Tests cover required fields.

---

#### Story 1.2.2: Append events to JSONL

**As a** user,  
**I want** every chat event saved append-only,  
**so that** no historical detail is lost.

**Tasks**

- Implement append function.
- Use date/session-based file paths.
- Write one JSON object per line.
- Include content hash.

**Acceptance Criteria**

- Events append to correct JSONL file.
- Multiple events maintain order.
- Duplicate event handling is deterministic.

**Definition of Done**

- Unit test writes and reads sample JSONL.
- Failure modes are logged.

---

#### Story 1.2.3: Export sessions to QMD/Markdown

**As a** user,  
**I want** human-readable chat session files,  
**so that** I can inspect or edit memory outside the database.

**Tasks**

- Generate QMD/Markdown from raw JSONL.
- Include frontmatter.
- Render user/assistant/tool turns.
- Add source refs.

**Acceptance Criteria**

- QMD file generated for sample session.
- QMD preserves all turn content.
- QMD includes metadata and source refs.

**Definition of Done**

- Export test passes.
- Example QMD added to docs.

---

## 5. Phase 2: SQLite and Keyword Search

### Epic 2.1: SQLite Persistence

#### Story 2.1.1: Create SQLite schema

**As a** memory system,  
**I want** structured tables for sessions, turns, chunks, facts, decisions, questions, and dreams,  
**so that** memory can be queried and managed locally.

**Tasks**

- Create migration system.
- Create tables from TDD.
- Add indexes.
- Add DB initialization command.

**Acceptance Criteria**

- `memory db init` creates SQLite DB.
- Schema version is tracked.
- Migrations are idempotent.

**Definition of Done**

- Migration tests pass.
- Schema documented.

---

#### Story 2.1.2: Write captured events to SQLite

**As a** memory system,  
**I want** raw events normalized into SQLite,  
**so that** sessions and turns can be queried efficiently.

**Tasks**

- Map raw event to `sessions` and `turns`.
- Handle session creation/update.
- Store JSON metadata.
- Track index and dream statuses.

**Acceptance Criteria**

- Sample events create one session and multiple turns.
- Reprocessing the same JSONL does not duplicate records.
- Content hashes are stored.

**Definition of Done**

- Integration test passes: JSONL → SQLite.

---

### Epic 2.2: Keyword Search

#### Story 2.2.1: Create FTS5 tables

**As a** user,  
**I want** exact keyword search,  
**so that** I can find errors, commands, config keys, and model names.

**Tasks**

- Create FTS5 tables for turns and chunks.
- Populate FTS from existing turns.
- Keep FTS updated on new capture.

**Acceptance Criteria**

- Search finds exact config key strings.
- Search returns source refs.
- Search can filter by project and date.

**Definition of Done**

- Tests cover exact string lookup.
- CLI supports `memory search --keyword`.

---

#### Story 2.2.2: Implement keyword search endpoint

**As Hermes,**  
**I want** a keyword search tool,  
**so that** I can retrieve exact historical matches.

**Tasks**

- Add `/search/keyword`.
- Return ranked matches.
- Include excerpts and source refs.
- Support filters.

**Acceptance Criteria**

- API returns results for sample exact string.
- API returns empty list for no match.
- API handles malformed queries gracefully.

**Definition of Done**

- Endpoint integration test passes.
- Tool schema documented.

---

## 6. Phase 3: Qdrant Semantic Search

### Epic 3.1: Qdrant Setup

#### Story 3.1.1: Add Docker Compose Qdrant service

**As a** builder,  
**I want** a local Qdrant service,  
**so that** semantic search can run without SaaS.

**Tasks**

- Add Qdrant to Docker Compose.
- Add persistent volume.
- Add health check.
- Add config setting for Qdrant URL.

**Acceptance Criteria**

- Qdrant starts locally.
- Qdrant data persists across restarts.
- Health check verifies connectivity.

**Definition of Done**

- Compose file committed.
- README includes startup instructions.

---

#### Story 3.1.2: Create Qdrant collections

**As a** memory system,  
**I want** vector collections with payload indexes,  
**so that** semantic search can be filtered by project/date/type.

**Tasks**

- Create collections:
  - `memory_turn_chunks`
  - `memory_summaries`
  - `memory_facts`
  - `memory_decisions`
  - `memory_project_files`
- Add payload indexes for project/date/type/session/status.

**Acceptance Criteria**

- Collections are created.
- Re-running collection setup is safe.
- Payload indexes exist.

**Definition of Done**

- Setup command tested.
- Collection definitions documented.

---

### Epic 3.2: Embedding Pipeline

#### Story 3.2.1: Implement local embedding client

**As a** memory system,  
**I want** local embeddings,  
**so that** semantic search does not require cloud APIs.

**Tasks**

- Support Ollama or OpenAI-compatible local endpoint.
- Add embedding model config.
- Add retry/error handling.
- Store embedding model metadata.

**Acceptance Criteria**

- Sample text returns embedding vector.
- Errors are clear if model endpoint is down.
- Embedding dimensions match Qdrant collection.

**Definition of Done**

- Unit/integration test with mocked embedding.
- Manual test instructions added.

---

#### Story 3.2.2: Chunk turns for semantic indexing

**As a** memory system,  
**I want** retrieval-friendly chunks,  
**so that** semantic search returns useful context.

**Tasks**

- Implement chunking strategy.
- Support turn windows and topic chunks.
- Store chunks in SQLite.
- Assign source refs.

**Acceptance Criteria**

- Sample session is chunked.
- Chunks preserve source turn ranges.
- Chunks are neither too tiny nor too broad.

**Definition of Done**

- Chunking tests pass.
- Chunking settings configurable.

---

#### Story 3.2.3: Upsert chunks to Qdrant

**As a** memory system,  
**I want** chunks embedded and stored in Qdrant,  
**so that** semantic recall works.

**Tasks**

- Generate embeddings for chunks.
- Upsert point to Qdrant.
- Store Qdrant point ID in SQLite.
- Mark index status complete.

**Acceptance Criteria**

- Sample chunks appear in Qdrant.
- Payload contains project/date/type/source refs.
- Re-indexing does not duplicate points.

**Definition of Done**

- Integration test passes: chunk → embedding → Qdrant.

---

### Epic 3.3: Semantic Search API

#### Story 3.3.1: Implement semantic search endpoint

**As Hermes,**  
**I want** semantic memory search,  
**so that** I can recall conceptually related prior discussions.

**Tasks**

- Add `/search/semantic`.
- Embed query locally.
- Search Qdrant.
- Apply payload filters.
- Return excerpts/source refs.

**Acceptance Criteria**

- Conceptual query returns relevant chunk.
- Project filter narrows result.
- Date filter works.

**Definition of Done**

- Endpoint test passes.
- CLI supports semantic search.

---

## 7. Phase 4: Hybrid Retrieval and Source Tracing

### Epic 4.1: Hybrid Search

#### Story 4.1.1: Implement hybrid result merger

**As Hermes,**  
**I want** hybrid search,  
**so that** I get both exact and conceptual memory recall.

**Tasks**

- Query FTS and Qdrant.
- Normalize scores.
- Deduplicate by source ref/chunk ID.
- Apply ranking weights.
- Add modes: balanced, keyword_heavy, semantic_heavy, facts_only, decisions_only.

**Acceptance Criteria**

- Hybrid search returns both exact and semantic results.
- Duplicate results are collapsed.
- Exact error strings rank highly in keyword-heavy mode.

**Definition of Done**

- Ranking tests pass.
- Examples documented.

---

#### Story 4.1.2: Add source resolver

**As a** user,  
**I want** every memory answer to trace back to original turns,  
**so that** memory is auditable.

**Tasks**

- Implement `source_ref` parser.
- Resolve session/turn/daily/project/fact/decision references.
- Return raw context.
- Support source expansion.

**Acceptance Criteria**

- Given a source ref, system returns correct raw text.
- Invalid refs return clear errors.
- Multi-turn refs resolve correctly.

**Definition of Done**

- Source resolver tests pass.
- API endpoint documented.

---

### Epic 4.2: Retrieval CLI and Diagnostics

#### Story 4.2.1: Add memory search CLI

**As a** builder,  
**I want** CLI search,  
**so that** I can debug memory without Hermes.

**Tasks**

- Add:
  - `memory search --keyword`
  - `memory search --semantic`
  - `memory search --hybrid`
  - `memory source get`
- Pretty print results.

**Acceptance Criteria**

- CLI returns readable results.
- Source refs can be expanded.
- Filters work from CLI.

**Definition of Done**

- CLI examples added to README.

---

## 8. Phase 5: Dreaming v1

### Epic 5.1: Prompt Templates

#### Story 5.1.1: Create dreamer prompt templates

**As a** dreamer process,  
**I want** standard prompts,  
**so that** summaries and facts are extracted consistently.

**Tasks**

- Create prompts for:
  - session summary
  - daily summary
  - fact extraction
  - decision extraction
  - open question extraction
  - contradiction detection
  - project memory update
- Add JSON output requirements.

**Acceptance Criteria**

- Prompts exist and are versioned.
- Prompts require source references.
- Prompts forbid inventing unsupported facts.

**Definition of Done**

- Prompt templates committed.
- Prompt docs explain purpose.

---

### Epic 5.2: Session and Daily Summaries

#### Story 5.2.1: Generate session summaries

**As a** user,  
**I want** session summaries,  
**so that** long chats can be understood quickly.

**Tasks**

- Load session turns.
- Call local LLM summarizer.
- Save summary to SQLite and QMD.
- Index summary.

**Acceptance Criteria**

- Session summary generated for sample session.
- Summary includes key topics and decisions.
- Summary references source turns.

**Definition of Done**

- Integration test with mocked LLM.
- Manual local LLM test documented.

---

#### Story 5.2.2: Generate daily memory file

**As a** user,  
**I want** daily memory files,  
**so that** each day’s AI work is summarized.

**Tasks**

- Group sessions by date.
- Summarize topics, facts, decisions, questions.
- Write `/daily/YYYY-MM-DD.md`.
- Index daily file.

**Acceptance Criteria**

- Daily file includes all sessions for date.
- Daily file has source refs.
- Re-running updates safely.

**Definition of Done**

- Daily generation test passes.
- Example daily file added.

---

### Epic 5.3: Facts, Decisions, and Questions

#### Story 5.3.1: Extract candidate facts

**As a** memory system,  
**I want** durable facts extracted from raw chats,  
**so that** Hermes can remember stable context.

**Tasks**

- Use local LLM to extract candidate facts.
- Require source refs and confidence.
- Deduplicate against existing facts.
- Save to SQLite and project facts file.

**Acceptance Criteria**

- Candidate facts include source refs.
- Duplicate facts are not recreated.
- Facts below threshold are marked candidate/review.

**Definition of Done**

- Fact extraction test with fixture session passes.

---

#### Story 5.3.2: Extract decisions

**As a** memory system,  
**I want** decisions recorded,  
**so that** architecture choices are not lost.

**Tasks**

- Extract decisions from sessions.
- Include rationale and implications.
- Save to SQLite and project decisions file.
- Index decisions.

**Acceptance Criteria**

- Decisions are captured with date and source refs.
- Decision rationale is stored when present.
- Duplicate decisions are deduped.

**Definition of Done**

- Decision extraction test passes.

---

#### Story 5.3.3: Extract open questions

**As a** memory system,  
**I want** unresolved questions tracked,  
**so that** future work can continue without losing context.

**Tasks**

- Extract open questions.
- Assign project and priority.
- Save to SQLite and project open questions file.
- Mark status open.

**Acceptance Criteria**

- Questions include source refs.
- Resolved questions can be updated later.
- Open questions appear in project memory.

**Definition of Done**

- Open-question extraction test passes.

---

### Epic 5.4: Contradiction and Supersession Handling

#### Story 5.4.1: Detect conflicting facts

**As a** memory system,  
**I want** contradictions surfaced,  
**so that** memory does not silently become wrong.

**Tasks**

- Compare new facts with existing facts in same scope/entity/project.
- Use local LLM or heuristics.
- Mark conflicts as disputed or superseded.
- Write contradiction report.

**Acceptance Criteria**

- Fixture contradictory facts are detected.
- Existing facts are not overwritten silently.
- Report includes both source refs.

**Definition of Done**

- Contradiction test passes.
- Dream report shows conflict section.

---

## 9. Phase 6: Hermes Tool Integration

### Epic 6.1: Hermes Tool Bridge

#### Story 6.1.1: Define Hermes memory tool schemas

**As Hermes,**  
**I want** stable memory tool schemas,  
**so that** I can call local memory reliably.

**Tasks**

- Define JSON schemas for all memory tools.
- Add examples.
- Include error response schema.

**Acceptance Criteria**

- Schemas cover search, get, add, update, dream.
- Schemas are documented.
- Schemas are versioned.

**Definition of Done**

- Schema files committed.
- Tests validate sample payloads.

---

#### Story 6.1.2: Implement Hermes callable tools

**As Hermes,**  
**I want** callable memory tools,  
**so that** I can recall and update long-term memory during conversations.

**Tasks**

- Implement tools:
  - semantic search
  - keyword search
  - hybrid search
  - get session
  - get daily
  - get project
  - add fact
  - add decision
  - add open question
  - dream now
- Return compact result structures.

**Acceptance Criteria**

- Hermes can call each tool locally.
- Tools return source refs.
- Tool errors are readable.

**Definition of Done**

- Manual Hermes integration test passes.
- Tool docs added.

---

### Epic 6.2: Context Injection Support

#### Story 6.2.1: Add recent context endpoint

**As Hermes,**  
**I want** compact recent/project context,  
**so that** I can load useful memory before answering.

**Tasks**

- Create `/memory/recent_context`.
- Include pinned facts, recent decisions, open questions, recent sessions.
- Allow project filter.
- Keep response token-budget friendly.

**Acceptance Criteria**

- Endpoint returns compact context.
- Project filter works.
- Response excludes raw long history unless requested.

**Definition of Done**

- Endpoint test passes.
- Hermes usage example documented.

---

## 10. Phase 7: Optional Mem0 OSS Mirror

### Epic 7.1: Mem0 Local Setup

#### Story 7.1.1: Add optional Mem0 OSS service

**As a** builder,  
**I want** Mem0 OSS available locally,  
**so that** I can experiment with adaptive memory without cloud fees.

**Tasks**

- Add Mem0 OSS to optional compose profile.
- Configure local vector/LLM settings where possible.
- Document setup.
- Keep disabled by default.

**Acceptance Criteria**

- Mem0 starts locally when profile enabled.
- Core memory works if Mem0 is disabled.
- No cloud Mem0 endpoint is required.

**Definition of Done**

- Optional setup docs added.
- Health check exists.

---

#### Story 7.1.2: Mirror selected facts to Mem0

**As a** memory system,  
**I want** selected durable memories mirrored to Mem0,  
**so that** I can test its recall without losing source-of-truth control.

**Tasks**

- Add Mem0 client abstraction.
- Mirror facts/decisions above confidence threshold.
- Log Mem0 writes.
- Store Mem0 IDs in SQLite.

**Acceptance Criteria**

- Selected facts mirror to Mem0.
- Failed mirror does not break core memory.
- Mirrored records remain traceable.

**Definition of Done**

- Integration test with mocked Mem0 client.
- Docs explain source-of-truth rule.

---

## 11. Phase 8: Optional Graph Memory

### Epic 8.1: Graph Store Evaluation

#### Story 8.1.1: Evaluate graph database choice

**As a** builder,  
**I want** to choose a graph backend,  
**so that** relationship/time-evolution memory can be added cleanly.

**Tasks**

- Compare Kùzu, Neo4j, and Graphiti-style approach.
- Decide MVP graph backend.
- Document tradeoffs.

**Acceptance Criteria**

- Recommendation documented.
- Deployment implications listed.
- No graph dependency is added to MVP unless approved.

**Definition of Done**

- Decision recorded in project decisions file.

---

### Epic 8.2: Entity and Relationship Extraction

#### Story 8.2.1: Extract entities and relationships

**As a** memory system,  
**I want** entities and relationships extracted from conversations,  
**so that** Hermes can answer relationship questions.

**Tasks**

- Define entity types.
- Define relationship types.
- Extract from dreamer output.
- Store in graph DB.

**Acceptance Criteria**

- Entities for hardware/tools/projects are extracted.
- Relationships include source refs.
- Time validity is recorded.

**Definition of Done**

- Fixture graph extraction test passes.

---

## 12. Phase 9: Hardening and Operations

### Epic 9.1: Backup and Restore

#### Story 9.1.1: Create backup command

**As a** user,  
**I want** memory backups,  
**so that** I can recover the entire memory system.

**Tasks**

- Backup raw files, QMD files, daily/project memory, SQLite DB, config, prompts.
- Trigger Qdrant snapshot/export where possible.
- Compress backup.
- Write manifest.

**Acceptance Criteria**

- Backup command creates restorable archive.
- Manifest lists included files.
- Backup excludes secrets where configured.

**Definition of Done**

- Backup tested on sample memory store.
- Restore instructions documented.

---

#### Story 9.1.2: Create rebuild command

**As a** user,  
**I want** to rebuild indexes from raw files,  
**so that** the system can recover from database/index loss.

**Tasks**

- Rebuild SQLite from JSONL.
- Rebuild QMD.
- Rebuild FTS.
- Rebuild Qdrant from chunks.
- Optionally rerun dreams.

**Acceptance Criteria**

- Deleting SQLite and rebuilding restores sessions/turns.
- Deleting Qdrant and rebuilding restores semantic search.
- Rebuild does not alter raw JSONL.

**Definition of Done**

- Rebuild test passes.

---

### Epic 9.2: Security and Redaction

#### Story 9.2.1: Add secret scanning

**As a** user,  
**I want** secrets detected before memory storage,  
**so that** keys and tokens are not accidentally persisted.

**Tasks**

- Add regex/entropy scanning for common secrets.
- Redact or quarantine high-risk values.
- Log redaction events.
- Allow user override if necessary.

**Acceptance Criteria**

- API key-like fixture is redacted.
- Redaction event is logged.
- Non-secret text is not over-redacted.

**Definition of Done**

- Redaction tests pass.

---

#### Story 9.2.2: Add memory review queue

**As a** user,  
**I want** questionable memory writes reviewed,  
**so that** sensitive or uncertain facts are not promoted automatically.

**Tasks**

- Add candidate memory status.
- Add review file or CLI.
- Support approve/reject/edit.
- Update fact status after review.

**Acceptance Criteria**

- Low-confidence facts go to review.
- User can approve/reject/edit.
- Approved facts become active.

**Definition of Done**

- CLI review flow works.

---

## 13. MVP Acceptance Test Suite

The MVP is accepted when the following test scenario passes.

### Scenario A: Capture

1. Start memory gateway.
2. Submit a sample Hermes session with 10 turns.
3. Verify raw JSONL exists.
4. Verify QMD exists.
5. Verify SQLite contains session and turns.

**Done when:** all artifacts exist and turn counts match.

---

### Scenario B: Keyword Search

1. Submit a turn containing `agents.list.0.tools`.
2. Run keyword search for `agents.list.0.tools`.
3. Verify result returns exact source ref.

**Done when:** exact string is found.

---

### Scenario C: Semantic Search

1. Submit a conversation about avoiding Honcho Cloud costs.
2. Search for “free local memory instead of paid provider.”
3. Verify relevant result is returned.

**Done when:** semantic result links back to correct session.

---

### Scenario D: Hybrid Search

1. Search for “local memory like lossless claw with QMD.”
2. Verify hybrid results include semantic and keyword matches.
3. Verify duplicate sources are collapsed.

**Done when:** top results are relevant and source-linked.

---

### Scenario E: Dreaming

1. Run dreamer on the sample session.
2. Verify daily memory file is created.
3. Verify project memory is updated.
4. Verify facts/decisions/open questions are extracted.
5. Verify source refs exist.

**Done when:** derived memory is useful, traceable, and indexed.

---

### Scenario F: Hermes Tool Use

1. Configure Hermes to call local memory tool.
2. Ask Hermes, “What did we decide about Honcho?”
3. Hermes calls memory search.
4. Hermes answers with source-backed context.

**Done when:** Hermes uses local memory rather than relying only on current context.

---

### Scenario G: Central No-Silo Retrieval

1. Seed one result in facts.
2. Seed one result in decisions.
3. Seed one result in FTS keyword search.
4. Seed one result in Qdrant semantic search.
5. Seed one result in daily memory.
6. Seed one result in project memory.
7. Call `memory_query` once.
8. Verify one normalized ranked result set is returned.

**Done when:** Hermes can retrieve all memory types through the central gateway without directly accessing backend stores.

---

## 14. Suggested First Sprint

### Sprint Goal

Create the foundation for the central memory control plane, lossless capture, files, SQLite, and basic keyword search.

### Sprint Stories

1. Story 0.1.1 — Create repository structure
2. Story 0.1.2 — Define initial configuration file
3. Story 0.2.1 — Create FastAPI gateway skeleton
4. Story 0A.1.1 — Define central memory interface
5. Story 0A.1.2 — Define normalized memory result model
6. Story 0A.2.1 — Implement orchestrator skeleton
7. Story 1.1.1 — Create memory directory initializer
8. Story 1.2.1 — Define event schema
9. Story 1.2.2 — Append events to JSONL
10. Story 2.1.1 — Create SQLite schema
11. Story 2.1.2 — Write captured events to SQLite
12. Story 2.2.1 — Create FTS5 tables

### Sprint Exit Criteria

- Can initialize local memory directory.
- Can capture sample events.
- Can store events in JSONL and SQLite.
- Can search exact keywords from captured history.
- Central memory interface and normalized result model exist.
- Orchestrator skeleton can query mock backends and return one merged result shape.

---

## 15. Suggested Second Sprint

### Sprint Goal

Add human-readable QMD exports and semantic search.

### Sprint Stories

1. Story 1.2.3 — Export sessions to QMD/Markdown
2. Story 3.1.1 — Add Docker Compose Qdrant service
3. Story 3.1.2 — Create Qdrant collections
4. Story 3.2.1 — Implement local embedding client
5. Story 3.2.2 — Chunk turns for semantic indexing
6. Story 3.2.3 — Upsert chunks to Qdrant
7. Story 3.3.1 — Implement semantic search endpoint

### Sprint Exit Criteria

- QMD files exist.
- Qdrant runs locally.
- Chunks are embedded and indexed.
- Semantic search works.

---

## 16. Suggested Third Sprint

### Sprint Goal

Add hybrid search, source resolution, central query fan-out, and Hermes-facing tools.

### Sprint Stories

1. Story 0A.2.2 — Implement central query fan-out and merge
2. Story 0A.2.3 — Implement central write coordinator
3. Story 0A.2.4 — Implement central source resolver
4. Story 0A.2.5 — Implement central recent context
5. Story 4.1.1 — Implement hybrid result merger
2. Story 4.1.2 — Add source resolver
3. Story 4.2.1 — Add memory search CLI
4. Story 6.1.1 — Define Hermes memory tool schemas
5. Story 6.1.2 — Implement Hermes callable tools
6. Story 6.2.1 — Add recent context endpoint

### Sprint Exit Criteria

- Hybrid search works.
- Source refs can be expanded.
- Hermes can call local memory tools.
- Hermes calls one central memory interface rather than individual backends.

---

## 17. Suggested Fourth Sprint

### Sprint Goal

Add dreaming v1.

### Sprint Stories

1. Story 5.1.1 — Create dreamer prompt templates
2. Story 5.2.1 — Generate session summaries
3. Story 5.2.2 — Generate daily memory file
4. Story 5.3.1 — Extract candidate facts
5. Story 5.3.2 — Extract decisions
6. Story 5.3.3 — Extract open questions
7. Story 5.4.1 — Detect conflicting facts

### Sprint Exit Criteria

- Dreamer processes sample sessions.
- Daily/project files update.
- Facts, decisions, questions are extracted.
- Contradictions are surfaced.

---

## 18. Build Priority Recommendation

Highest priority:

1. Lossless capture
2. SQLite + FTS
3. QMD export
4. Qdrant semantic search
5. Hybrid search
6. Dreamer
7. Hermes tool bridge

Lower priority:

1. Mem0 OSS mirror
2. Graph memory
3. UI dashboard
4. Advanced review queue

Reason: lossless archive and hybrid retrieval give immediate value and preserve optionality. Mem0 and graph memory should be added after the source-of-truth system is stable.

---

## 19. Risks by Phase

| Phase | Risk | Mitigation |
|---|---|---|
| 1 | Capture misses turns | Add test harness and logging |
| 2 | SQLite schema changes often | Use migrations |
| 3 | Embedding model changes dimension | Version collections by embedding model |
| 4 | Hybrid ranking poor | Add modes and tune weights |
| 5 | Dreamer stores bad facts | Require source refs and confidence |
| 6 | Hermes tool integration changes | Keep gateway stable |
| 7 | Mem0 adds complexity | Keep optional and disabled by default |
| 8 | Graph memory scope creep | Defer until core is stable |
| 9 | Backups incomplete | Add manifest and restore test |

---

## 20. Reference Implementation Milestones

### Milestone 1: Local Memory Core

- Init memory directory
- Capture JSONL
- SQLite storage
- Keyword search

### Milestone 2: Searchable Long-Term Memory

- QMD export
- Qdrant semantic search
- Hybrid retrieval
- Source refs

### Milestone 3: Agent-Integrated Memory

- Hermes tools
- Recent context
- Add fact/decision tools

### Milestone 4: Dreaming Memory

- Session summaries
- Daily summaries
- Project memory updates
- Fact/decision/question extraction

### Milestone 5: Advanced Memory

- Mem0 OSS optional mirror
- Graph memory
- Review queue
- Dashboard

---

## 21. Final MVP Definition

The MVP is complete when Hermes can:

1. Capture all new chats losslessly.
2. Search historical turns by exact keyword.
3. Search historical turns semantically.
4. Retrieve source-backed context.
5. Maintain daily and project memory files.
6. Extract durable facts, decisions, and open questions locally.
7. Run a local dreamer.
8. Use the memory system without a paid cloud memory provider.
9. Use one central `memory_query` interface for all memory retrieval.
10. Use one central `memory_write` path for durable memory mutation.
11. Resolve every returned memory item through `memory_get_source`.
