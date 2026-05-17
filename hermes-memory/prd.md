# PRD: Hermes Local Long-Duration Memory System

**Document:** `prd.md`  
**Product Name:** Hermes Local Memory Pack  
**Owner:** David McCarty  
**Version:** 0.1  
**Date:** 2026-05-17  
**Status:** Draft for build planning

---

## 1. Executive Summary

Hermes Local Memory Pack is a local-first, no-additional-cost memory system for Hermes Agent that provides long-duration recall, lossless historical chat preservation, searchable working memory, durable user/project facts, and recursive “dreaming” consolidation.

The system is intended to approximate the strongest capabilities of cloud memory systems such as Honcho while avoiding token-metered SaaS dependency. It will preserve every conversation turn and tool event in a lossless archive, generate daily and project-level memory files, index all history with both semantic vector search and exact keyword search, expose agent tools for recall/write/update operations, and run a scheduled local consolidation process that extracts durable facts, decisions, contradictions, unresolved questions, and project memory updates.

This PRD assumes Hermes built-in memory files remain active and are enhanced by a local memory bridge. Hermes documentation describes external memory providers as additive to built-in `MEMORY.md` / `USER.md`, with provider context injected, relevant memories prefetched, turns synced, and provider tools added. The local system should follow the same conceptual pattern while using local services and files.

---

## 2. Problem Statement

Hermes built-in memory is useful for concise durable context, but it is not sufficient by itself for the user’s desired long-duration memory system.

The user wants a system similar to OpenClaw’s “lossless claw” and QMD-style memory approach, including:

- Complete historical chat turns
- Durable user and project facts
- Exact keyword lookup
- Semantic vector search
- Daily memory files
- Project memory files
- Session memory files
- Recursive review/dreaming
- Local-first storage
- No recurring token-metered memory provider cost
- Agent-accessible recall and write tools

Cloud systems such as Honcho offer attractive user modeling and recursive memory features, but the user prefers a local solution with no incremental per-token charges.

---

## 3. Goals

### 3.1 Product Goals

1. Preserve every Hermes chat turn and tool interaction in a lossless local archive.
2. Provide searchable long-term memory across all historical chats.
3. Maintain concise durable memory files for Hermes built-in context.
4. Maintain daily, session, project, entity, fact, decision, and open-question memory files.
5. Provide hybrid retrieval:
   - Vector semantic search
   - Exact keyword search
   - Metadata filtering
   - Date/session/project filtering
6. Provide a local “dreaming” process that recursively reviews new history and updates summaries/facts.
7. Expose memory functions to Hermes through tools or MCP.
8. Keep all private data local by default.
9. Avoid recurring SaaS/token-metered memory costs.
10. Preserve portability by keeping human-readable Markdown/QMD and JSONL as the source of truth.

### 3.2 User Experience Goals

The user should be able to ask Hermes questions such as:

- “What did we decide about Hermes memory last week?”
- “Find the exact OpenClaw error I pasted about `agents.list.0.tools`.”
- “What hardware do I currently have in the AI lab?”
- “Summarize everything we discussed about Qdrant and meeting transcripts.”
- “What changed in my local AI architecture over time?”
- “Show me all open questions about using Mem0 OSS.”
- “Update the project memory for Hermes with this new decision.”
- “Dream on today’s sessions and update daily/project memory.”

Hermes should answer with relevant citations or references back to source sessions/files whenever possible.

---

## 4. Non-Goals

The first release will not attempt to:

1. Replace Hermes as the primary agent runtime.
2. Replace OpenClaw memory.
3. Build a paid hosted memory SaaS.
4. Store secrets, API keys, passwords, tokens, or sensitive credentials.
5. Guarantee perfect fact extraction without human review.
6. Solve enterprise-scale multi-user governance in v1.
7. Implement full graph reasoning in the MVP unless it is low effort after the core stack is stable.
8. Ingest every external data source immediately.
9. Depend on cloud LLM APIs for core memory operations.
10. Rewrite raw history during consolidation.

---

---

## 4A. Central Memory Control Plane Requirement

The system shall not behave as a loose collection of disconnected memory stores. Hermes, OpenClaw, Agent Zero, or any other agent runtime shall interact with memory through one central programmable memory interface.

The central interface is the **Local Memory Gateway**.

The Local Memory Gateway is the authoritative memory control plane. It exposes a small set of tools/functions and internally fans out to the underlying memory stores, indexes, and derived files.

### 4A.1 Control Plane Principle

```text
Hermes shall not directly query Qdrant, SQLite, JSONL, QMD, daily files, project files, Mem0, or graph memory independently.

Hermes shall call one central memory layer.

The Local Memory Gateway shall route, merge, deduplicate, rank, source-trace, and return normalized memory results.
```

### 4A.2 Canonical Memory Interface

The core interface shall include:

```text
memory_query()
memory_write()
memory_get_source()
memory_recent_context()
memory_dream()
memory_reindex()
memory_update()
```

These tools shall be available through one or more of:

- local HTTP API
- CLI
- MCP server
- Hermes custom memory provider adapter

### 4A.3 Backend Stores Are Not Independent Memories

The system shall treat each backend as a storage/index/view layer:

| Backend | Role |
|---|---|
| Raw JSONL | Immutable lossless source of truth |
| QMD/Markdown sessions | Human-readable source view |
| SQLite | Canonical structured ledger for sessions, turns, facts, decisions, questions, and dream runs |
| SQLite FTS5 | Exact keyword / BM25-style retrieval |
| Qdrant | Semantic vector retrieval |
| Daily files | Derived day-level memory |
| Project memory files | Derived project-level memory |
| Mem0 OSS | Optional adaptive memory mirror |
| Graph store | Optional relationship/time-evolution view |

Hermes shall not need to know which backend produced a result. The Local Memory Gateway shall return a normalized result set.

### 4A.4 Central Query Behavior

When Hermes calls `memory_query`, the gateway shall:

1. Parse intent, scope, project, memory types, filters, and search mode.
2. Query applicable backends in parallel or sequence.
3. Search structured facts, decisions, and open questions.
4. Search SQLite FTS5 for exact keyword matches.
5. Search Qdrant for semantic matches.
6. Search project/daily/session memory files when applicable.
7. Optionally query Mem0 OSS or graph memory if enabled.
8. Merge and deduplicate results by `source_ref`, `memory_id`, and content hash.
9. Rerank results based on mode, relevance, source type, recency, project match, and confidence.
10. Return one normalized, source-backed result set.

### 4A.5 Central Write Behavior

When Hermes or the dreamer calls `memory_write`, the gateway shall:

1. Validate the memory write request.
2. Require source references unless explicitly marked as user-pinned manual memory.
3. Run redaction and safety checks.
4. Check for duplicates, contradictions, and superseded facts.
5. Write the canonical record to SQLite.
6. Append/update human-readable memory files.
7. Update SQLite FTS indexes.
8. Generate embeddings and update Qdrant.
9. Optionally mirror to Mem0 OSS.
10. Optionally update graph memory.
11. Return a canonical `memory_id` and `source_ref`.

### 4A.6 Required Normalized Result Shape

All memory read tools shall return results using a normalized shape:

```json
{
  "query": "what did we decide about local memory?",
  "mode": "hybrid",
  "results": [
    {
      "memory_id": "decision_20260517_000001",
      "type": "decision",
      "project": "hermes",
      "text": "Use a local central memory gateway as the single memory interface.",
      "score": 0.94,
      "confidence": 0.97,
      "source_ref": "session:sess_20260517_hermes_001#turns=4-9",
      "backend_hits": ["sqlite_decisions", "qdrant", "fts"],
      "created_at": "2026-05-17T12:00:00-05:00",
      "updated_at": "2026-05-17T12:30:00-05:00"
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

### 4A.7 Central Gateway Acceptance Requirement

The system is not considered MVP-complete unless Hermes can retrieve facts, decisions, raw turns, daily memory, project memory, semantic results, and exact keyword results through the same central `memory_query` function.


## 5. Personas

### 5.1 Primary Persona: Local AI Power User / Builder

The primary user is building a self-hosted AI lab and wants advanced agentic workflows across Hermes, OpenClaw, Agent Zero, local models, NAS storage, meeting transcripts, documents, coding workflows, and presentations.

Needs:

- Local-first control
- High recall quality
- Durable long-term context
- Practical technical implementation
- Auditable source-of-truth files
- Flexible integration with agents and tools

### 5.2 Secondary Persona: Agent Runtime

Hermes is a consumer of the memory system.

Needs:

- Fast recall APIs
- Structured query results
- Concise context injection
- Write/update tools
- Fact and decision lookup
- Session/project filtering
- Safe memory mutation rules

### 5.3 Secondary Persona: Maintenance/Dreaming Job

The dreamer is an automated local process.

Needs:

- Access to raw unprocessed turns
- Idempotent processing
- Checkpointing
- Conflict detection
- Ability to write summaries and facts
- Ability to update indexes
- Ability to generate a dream report

---

## 6. Scope

### 6.1 MVP Scope

The MVP includes:

1. Local directory structure for lossless memory.
2. JSONL append-only session archive.
3. QMD/Markdown session export.
4. SQLite database with:
   - sessions
   - turns
   - chunks
   - facts
   - decisions
   - open questions
   - dream runs
   - source references
5. SQLite FTS5 index for keyword search.
6. Qdrant collection for semantic search.
7. Local embedding pipeline.
8. Local summarization/dreaming pipeline.
9. Memory CLI.
10. Hermes-facing memory tools:
   - semantic search
   - keyword search
   - hybrid search
   - get session
   - get daily memory
   - get project memory
   - add fact
   - add decision
   - dream now
11. Human-readable memory files:
   - `MEMORY.md`
   - `USER.md`
   - daily files
   - project memory files
   - facts
   - decisions
   - open questions
12. Docker Compose for local services.

### 6.2 Post-MVP Scope

1. Mem0 OSS integration as optional local memory API.
2. Graph memory with Neo4j, Kùzu, or Graphiti-style extraction.
3. UI dashboard.
4. Cross-agent memory bus for Hermes, OpenClaw, and Agent Zero.
5. Document/file ingestion beyond chat turns.
6. Meeting transcript ingestion.
7. Relationship/time-evolution queries.
8. Memory governance workflows.
9. Local re-ranker.
10. Redaction pipeline.

---

## 7. Functional Requirements

### FR-001: Lossless Chat Capture

The system shall capture every user, assistant, system, and tool turn from Hermes sessions into append-only JSONL files.

Each captured event shall include:

- `session_id`
- `turn_id`
- `timestamp`
- `role`
- `content`
- `agent`
- `project`
- `source`
- `tags`
- `tool_calls`
- `attachments`
- `metadata`
- `hash`
- `parent_turn_id`
- `embedding_status`
- `index_status`
- `dream_status`

Acceptance baseline: no conversation content is lost during normal operation.

---

### FR-002: Human-Readable Session Export

The system shall export each session to QMD or Markdown.

The export shall include:

- session metadata
- chronological turns
- tool call summaries
- source links
- tags
- extracted headings
- optional generated session summary

---

### FR-003: Daily Memory Files

The system shall maintain one daily memory file per date.

Daily files shall include:

- sessions processed
- major topics
- durable facts discovered
- decisions made
- unresolved questions
- follow-up actions
- changed project memories
- source references

---

### FR-004: Project Memory Files

The system shall maintain project-specific memory folders.

Example:

```text
/memory/projects/hermes/
  memory.md
  facts.md
  decisions.md
  open_questions.md
  timeline.md
  sources.md
```

The system shall support projects such as:

- `hermes`
- `openclaw`
- `agent-zero`
- `local-ai-lab`
- `meeting-intelligence`
- `diveratings`
- `work-aem`
- `personal-ai`

---

### FR-005: Fact Store

The system shall extract durable facts into a structured local database and Markdown files.

Each fact shall include:

- fact text
- confidence
- scope
- project
- source session
- source turn IDs
- first seen date
- last confirmed date
- status: active, superseded, disputed, archived
- supersedes/superseded_by relationship
- tags

---

### FR-006: Decision Store

The system shall extract decisions into a structured store.

Each decision shall include:

- decision text
- rationale
- project
- date
- source references
- owner
- status
- downstream implications
- related facts

---

### FR-007: Open Questions Store

The system shall extract unresolved questions.

Each open question shall include:

- question
- project
- priority
- source references
- created date
- status
- next action

---

### FR-008: Semantic Search

The system shall support semantic search over:

- raw turns
- chunks
- session summaries
- daily summaries
- project memory files
- facts
- decisions
- open questions

The semantic search engine shall support metadata filtering by:

- project
- date range
- session
- role
- source
- tag
- memory type

Qdrant is the preferred vector store. Qdrant collections contain points with vectors and JSON payloads, and Qdrant supports payload-based filtering for precise retrieval.

---

### FR-009: Keyword Search

The system shall support exact keyword search over all captured text.

SQLite FTS5 or Postgres full-text search shall be used.

Keyword search must handle exact strings such as:

- config keys
- error messages
- model names
- hardware names
- filenames
- commands
- URLs
- code snippets

---

### FR-010: Hybrid Search

The system shall provide a hybrid search API that combines:

- vector semantic results
- keyword/FTS results
- metadata filters
- recency boost
- source-type boost
- optional reranking

Hybrid results shall include source references and enough excerpt context to allow Hermes to answer accurately.

---

### FR-011: Dreaming / Recursive Consolidation

The system shall include a local scheduled dreamer.

The dreamer shall:

1. Read new raw turns since the last dream checkpoint.
2. Group content by session, day, project, topic, and entity.
3. Generate session summaries.
4. Generate or update daily summaries.
5. Extract durable facts.
6. Extract decisions.
7. Extract unresolved questions.
8. Detect contradictions or superseded facts.
9. Update project memory files.
10. Update semantic and keyword indexes.
11. Produce a dream report.

The dreamer shall never overwrite raw history.

---

### FR-012: Hermes Tool Interface

The system shall expose tools for Hermes:

- `memory_search_semantic`
- `memory_search_keyword`
- `memory_search_hybrid`
- `memory_get_session`
- `memory_get_daily`
- `memory_get_project`
- `memory_add_fact`
- `memory_add_decision`
- `memory_add_open_question`
- `memory_update_fact`
- `memory_dream_now`
- `memory_recent_context`
- `memory_trace_sources`

Tools shall return concise, source-referenced results.

---

### FR-013: Built-in Hermes Memory Sync

The system shall maintain Hermes built-in memory files as curated top-level summaries.

Files:

- `MEMORY.md`
- `USER.md`

These files shall be small enough to remain useful in agent context.

---

### FR-014: Local-Only Default

The system shall run locally by default.

No captured memory content shall be sent to external services unless explicitly configured.

---

### FR-015: Backup and Portability

The system shall support backup by copying the memory directory and database files.

The source-of-truth archive shall remain portable because it uses:

- JSONL
- Markdown/QMD
- SQLite
- Qdrant export/snapshot

---

---

### FR-016: Central Memory Gateway

The system shall expose a single Local Memory Gateway as the only supported programmatic memory interface for Hermes and other agents.

Hermes shall not directly query backend memory stores. All read/write/search/update/dream/reindex operations shall route through the Local Memory Gateway.

The gateway shall support:

- `memory_query`
- `memory_write`
- `memory_get_source`
- `memory_recent_context`
- `memory_dream`
- `memory_reindex`
- `memory_update`

Acceptance baseline: one call to `memory_query` can retrieve and merge results from structured facts, decisions, raw historical turns, QMD session files, daily files, project files, FTS keyword search, Qdrant semantic search, and any enabled optional memory backends.

---

### FR-017: Memory Orchestrator

The system shall include a Memory Orchestrator inside the Local Memory Gateway.

The orchestrator shall:

- route queries to relevant backends
- merge results
- deduplicate results
- normalize result shape
- rank results
- enforce source traceability
- enforce redaction and write rules
- update all derived indexes after canonical writes
- hide backend complexity from Hermes

Acceptance baseline: Hermes receives one normalized result set regardless of which backend produced the underlying memory hits.

---

### FR-018: Canonical Write Path

The system shall enforce a single canonical write path for durable memory writes.

All facts, decisions, open questions, project memory updates, daily memory updates, and dream outputs shall be written through `memory_write` or an internal gateway-equivalent write service.

The write path shall update:

- SQLite canonical structured ledger
- Markdown/QMD memory files where applicable
- SQLite FTS indexes
- Qdrant semantic indexes
- optional Mem0 OSS mirror
- optional graph memory

Acceptance baseline: no component writes durable memory to only one backend without updating the canonical ledger and indexes.

---

### FR-019: Source Resolver

The system shall provide `memory_get_source` as a central source resolver.

The source resolver shall retrieve original raw source content from:

- raw JSONL sessions
- QMD/Markdown session files
- daily files
- project files
- facts
- decisions
- open questions
- dream reports

Acceptance baseline: every returned memory result can be traced to an original source or explicitly marked as manually pinned memory.

---

### FR-020: Central Recent Context

The system shall provide `memory_recent_context`.

This tool shall return compact, token-budget-aware context for Hermes at session start or project switch.

The context may include:

- pinned user facts
- active project facts
- recent decisions
- unresolved open questions
- recent relevant sessions
- recent dream summaries
- high-priority contradictions or review items

Acceptance baseline: Hermes can obtain a compact working set without directly reading individual memory files.


## 8. Non-Functional Requirements

### NFR-001: Privacy

All memory content shall remain local by default.

### NFR-002: Auditability

Every derived memory item shall trace back to raw source turns.

### NFR-003: Recoverability

Raw history shall be append-only. Failed dream/index jobs shall be retryable.

### NFR-004: Performance

Target local response times:

- keyword search: under 1 second for normal use
- semantic search: under 2 seconds for normal use
- hybrid search: under 4 seconds for normal use
- dream run: batch-oriented, no strict interactive SLA

### NFR-005: Idempotency

Running indexing or dreaming repeatedly shall not create duplicate facts, duplicate chunks, or duplicate vector points.

### NFR-006: Extensibility

The system shall allow additional agents, tools, documents, transcripts, and graph memory later.

### NFR-007: Local Model Compatibility

The system shall support local LLMs and local embedding models served through LM Studio, Ollama, or equivalent local endpoints.

### NFR-008: Human Editability

Memory files shall be human-readable and manually editable.

### NFR-009: Security

The system shall exclude secrets from memory by default and support redaction rules.

### NFR-010: Explainability

Answers using memory shall include source references when possible.

---

## 9. Data Types

### 9.1 Raw Turn

A raw turn is an immutable source event.

### 9.2 Chunk

A chunk is a retrieval unit derived from one or more turns.

### 9.3 Summary

A summary is a derived compression of a session, day, or project.

### 9.4 Fact

A fact is a durable statement believed to be useful across future sessions.

### 9.5 Decision

A decision is a committed choice, plan, architecture preference, or constraint.

### 9.6 Open Question

An open question is an unresolved item requiring future attention.

### 9.7 Memory File

A memory file is a Markdown/QMD artifact that can be read directly by humans or agents.

---

## 10. Memory Taxonomy

### 10.1 User Memory

Long-lived facts about the user’s goals, preferences, environment, and constraints.

Examples:

- local-first preference
- no recurring token-metered memory provider
- AI lab hardware
- OpenClaw/Hermes/Agent Zero project focus

### 10.2 Project Memory

Durable facts and decisions specific to a project.

Examples:

- Hermes memory architecture
- OpenClaw configuration decisions
- meeting transcript RAG pipeline
- Diveratings site planning

### 10.3 Session Memory

Summary and important items from a conversation session.

### 10.4 Daily Memory

Cross-session summary of a day.

### 10.5 Entity Memory

Facts about entities such as systems, tools, vendors, models, hardware, or people.

### 10.6 Operational Memory

Commands, errors, configs, file paths, architecture decisions, and troubleshooting context.

---

## 11. Search Behavior Requirements

### 11.1 Keyword First Cases

Keyword search shall be preferred or blended heavily for:

- exact error strings
- config keys
- code
- filenames
- command-line snippets
- product/model names
- dates
- URLs

### 11.2 Semantic First Cases

Semantic search shall be preferred or blended heavily for:

- conceptual questions
- “what did we decide about...”
- “summarize what we discussed about...”
- “what was the rationale for...”
- “find chats related to...”

### 11.3 Hybrid Ranking

Hybrid ranking shall consider:

- semantic score
- keyword score
- recency
- project match
- source type
- fact/decision priority
- user-pinned memory
- contradiction/supersession status

---

## 12. Dreaming Behavior Requirements

### 12.1 Dream Cadence

Supported modes:

- manual `dream now`
- nightly scheduled job
- session-end dream
- weekly deep dream

### 12.2 Dream Outputs

Each dream run shall produce:

```text
/memory/dreams/YYYY-MM-DD-HHMM.md
```

With:

- input sessions
- extracted facts
- decisions
- open questions
- contradictions
- project updates
- index status
- errors/warnings

### 12.3 Contradiction Handling

If a new fact conflicts with an existing fact:

- do not silently overwrite
- mark as disputed or superseded
- include source references
- optionally ask user for confirmation if high impact

### 12.4 Memory Promotion

Raw turns become durable memory only after extraction and scoring.

Promotion levels:

1. raw
2. indexed
3. summarized
4. candidate fact
5. durable fact
6. pinned memory

---

## 13. Integration Requirements

### 13.1 Hermes Integration

The system shall provide an HTTP, CLI, or MCP interface callable by Hermes.

### 13.2 Mem0 OSS Integration

Mem0 OSS may be integrated as an optional local memory API, not the sole source of truth.

Mem0 OSS supports self-hosted use and can run as a library or server with dashboard/API keys/audit logging.

### 13.3 Qdrant Integration

Qdrant shall store vector embeddings and payload metadata for retrieval.

### 13.4 SQLite/Postgres Integration

SQLite is preferred for MVP simplicity. Postgres may be used later if multi-user or higher-concurrency requirements grow.

SQLite is small, self-contained, reliable, and broadly embedded; SQLite FTS5 supports efficient keyword search across large text collections.

### 13.5 Local Model Integration

The system shall support:

- local embeddings
- local summarization
- local fact extraction
- local contradiction detection

Model serving options:

- LM Studio
- Ollama
- llama.cpp server
- vLLM, if appropriate later

---

## 14. Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---:|---|
| Fact extraction stores incorrect facts | High | Store confidence, source references, and allow review |
| Vector search misses exact terms | Medium | Maintain keyword FTS index |
| Keyword search misses conceptual matches | Medium | Maintain Qdrant semantic index |
| Dreamer overwrites good memory | High | Raw history append-only; derived memory versioned |
| Large memory grows slow | Medium | Chunking, indexes, snapshots, archival policies |
| Secrets accidentally stored | High | Redaction filters and secret scanning |
| Local model quality insufficient | Medium | Use stronger local model for dreamer; allow manual review |
| Integration with Hermes changes | Medium | Keep adapter layer isolated |
| Mem0 OSS changes API | Low/Medium | Keep source-of-truth outside Mem0 |

---

## 15. Success Metrics

### 15.1 MVP Metrics

- 100% of new Hermes sessions captured to JSONL.
- 100% of captured sessions exported to QMD/Markdown.
- Keyword search finds exact strings from prior sessions.
- Semantic search finds conceptually related sessions.
- Dreamer produces daily and project summaries.
- Durable facts include source references.
- Hermes can query memory through local tools.

### 15.2 Quality Metrics

- Recall precision for project questions is acceptable to user.
- False durable memory writes are visible and correctable.
- Fact contradictions are surfaced, not hidden.
- User can trace answers back to source sessions.
- System can be backed up/restored from local files.

---

## 16. MVP Release Criteria

The MVP is releasable when:

1. Hermes conversation turns are captured losslessly.
2. Raw JSONL and QMD files are generated.
3. SQLite schema is created and populated.
4. FTS search works.
5. Qdrant search works.
6. Hybrid search works.
7. Dreamer generates daily/project memory files.
8. Hermes can call memory tools.
9. All derived memory items trace to source turns.
10. Backup/restore instructions exist.
11. Hermes can retrieve all memory types through the central `memory_query` function.
12. Hermes does not need direct access to Qdrant, SQLite, raw JSONL, QMD, daily files, project files, or Mem0.

---

## 17. References

- Hermes Agent memory providers: https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/memory-providers.md
- Hermes Honcho memory overview: https://hermes-agent.nousresearch.com/docs/user-guide/features/honcho
- Mem0 OSS overview: https://docs.mem0.ai/open-source/overview
- Mem0 self-hosted setup: https://docs.mem0.ai/open-source/setup
- Qdrant collections: https://qdrant.tech/documentation/manage-data/collections/
- Qdrant payload filtering: https://qdrant.tech/documentation/search/filtering/
- Qdrant payload indexing: https://qdrant.tech/documentation/manage-data/payload/
- SQLite: https://sqlite.org/
