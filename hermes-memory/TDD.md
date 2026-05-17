# TDD: Hermes Local Long-Duration Memory System

**Document:** `TDD.md`  
**Product Name:** Hermes Local Memory Pack  
**Owner:** David McCarty  
**Version:** 0.1  
**Date:** 2026-05-17  
**Status:** Draft technical design

---

## 1. Technical Summary

Hermes Local Memory Pack is a local-first memory subsystem that gives Hermes durable long-duration memory, lossless historical chat recall, semantic and keyword search, project/daily memory files, and recursive “dreaming” consolidation.

The core principle is:

> Raw history is the immutable source of truth. All summaries, facts, vector chunks, graph nodes, and memory files are derived views.

The architecture intentionally separates:

1. **Capture** — append-only storage of every event.
2. **Storage** — raw JSONL/QMD, SQLite, Qdrant, optional Mem0 OSS.
3. **Indexing** — keyword and vector indexing.
4. **Consolidation** — local dreaming process.
5. **Serving** — tool/MCP/API access for Hermes.
6. **Curation** — human-editable memory files.

---

## 2. Architecture Goals

1. Local-first, no recurring memory provider cost.
2. Complete historical preservation.
3. Fast retrieval across months/years of conversations.
4. Dual retrieval modes:
   - semantic vector search
   - exact keyword search
5. Durable memory facts with source traceability.
6. Clear separation between raw and derived memory.
7. Hermes-compatible tool interface.
8. Extensible to OpenClaw, Agent Zero, meeting transcripts, and document ingestion.
9. Optional Mem0 OSS without lock-in.
10. Optional graph memory after MVP.

---

## 3. High-Level Component Diagram

```text
+----------------------+
|      Hermes Agent    |
|  MEMORY.md / USER.md |
+----------+-----------+
           |
           | Tool/MCP/HTTP calls
           v
+------------------------------+
| Local Memory Gateway          |
| - search_semantic             |
| - search_keyword              |
| - search_hybrid               |
| - add_fact                    |
| - add_decision                |
| - dream_now                   |
| - get_session                 |
+---------------+--------------+
                |
                v
+------------------------------+
| Memory Service API            |
| - capture manager             |
| - retrieval orchestrator      |
| - write manager               |
| - source reference resolver   |
| - redaction guard             |
+-------+-----------+----------+
        |           |
        |           |
        v           v
+---------------+  +----------------+
| SQLite DB     |  | Qdrant         |
| - sessions    |  | - vectors      |
| - turns       |  | - payloads     |
| - chunks      |  | - filters      |
| - facts       |  | - collections  |
| - decisions   |  +----------------+
| - FTS5        |
+-------+-------+
        |
        v
+------------------------------+
| Filesystem Memory             |
| /raw JSONL                    |
| /qmd session exports          |
| /daily memory                 |
| /projects memory              |
| /facts / decisions            |
| /dream reports                |
+---------------+--------------+
                |
                v
+------------------------------+
| Dreamer / Consolidator         |
| - summarization                |
| - fact extraction              |
| - decision extraction          |
| - contradiction detection      |
| - project memory update        |
| - index refresh                |
+------------------------------+
```

### 3.1 Centralized Access Rule

All backend stores shown in the diagram are private implementation details behind the Local Memory Gateway. Hermes does not directly connect to Qdrant, SQLite, raw JSONL, QMD files, daily files, project files, Mem0, or graph memory.

Hermes sees one programmatic interface:

```text
memory_query()
memory_write()
memory_get_source()
memory_recent_context()
memory_dream()
memory_reindex()
memory_update()
```

This prevents memory silos and ensures every answer can be merged, ranked, and source-traced centrally.

---

## 4. Runtime Flow Overview

### 4.1 Conversation Capture Flow

```text
Hermes turn occurs
    |
    v
Memory Gateway receives event
    |
    v
Redaction guard scans content
    |
    v
Append event to raw JSONL
    |
    v
Write normalized turn to SQLite
    |
    v
Export/update QMD session file
    |
    v
Mark turn as pending chunk/index/dream
```

### 4.2 Indexing Flow

```text
New raw turns
    |
    v
Chunker groups turns into retrieval units
    |
    +--> SQLite chunks table
    |
    +--> SQLite FTS5 keyword index
    |
    +--> local embedding model
             |
             v
          Qdrant upsert
          with payload metadata
```

### 4.3 Hybrid Search Flow

```text
Hermes asks memory_search_hybrid(query, filters)
    |
    v
Retrieval orchestrator
    |
    +--> Keyword search in SQLite FTS5
    |
    +--> Semantic search in Qdrant
    |
    v
Merge results
    |
    v
Apply filters / ranking / dedupe
    |
    v
Return excerpts + source references
```

### 4.4 Dreaming Flow

```text
Scheduled or manual dream trigger
    |
    v
Load unprocessed sessions/turns
    |
    v
Group by project/topic/day/entity
    |
    v
Local LLM creates:
  - session summary
  - daily summary
  - facts
  - decisions
  - open questions
  - contradictions
    |
    v
Validation + dedupe + source linking
    |
    v
Write derived memory:
  - SQLite facts/decisions/questions
  - Markdown/QMD memory files
  - dream report
    |
    v
Refresh indexes
    |
    v
Update checkpoints
```

### 4.5 Memory Read in Hermes

```text
User asks question
    |
    v
Hermes calls local memory tools
    |
    v
Memory Gateway returns top contextual memories
    |
    v
Hermes composes answer with source references
```

---

## 4A. Central Memory Control Plane

The central architectural requirement is that Hermes shall not interact with each memory backend separately. Hermes shall interact with one central memory interface, and that interface shall orchestrate all backend memory stores.

```text
Hermes
  |
  | one provider/tool/MCP surface
  v
Local Memory Gateway
  |
  v
Memory Orchestrator
  |
  +-- Raw JSONL archive
  +-- QMD/Markdown session files
  +-- SQLite canonical ledger
  +-- SQLite FTS5 keyword search
  +-- Qdrant semantic search
  +-- Daily memory files
  +-- Project memory files
  +-- Optional Mem0 OSS mirror
  +-- Optional graph memory
```

### 4A.1 Memory Gateway Responsibilities

The Local Memory Gateway is responsible for:

- exposing one programmatic memory interface
- routing reads to the right backends
- routing writes through the canonical write path
- merging and reranking retrieval results
- deduplicating by source reference and content hash
- resolving original sources
- enforcing redaction and write safety
- updating derived indexes
- hiding backend implementation from Hermes
- supporting future agents such as OpenClaw and Agent Zero

### 4A.2 Memory Orchestrator Responsibilities

The Memory Orchestrator is the internal runtime component inside the gateway.

Responsibilities:

```text
Query orchestration:
  - classify query intent
  - select search mode
  - select backends
  - run searches
  - merge results
  - rerank results
  - dedupe results
  - normalize result shape

Write orchestration:
  - validate write
  - require source reference
  - check duplicates
  - check contradictions
  - write canonical SQLite record
  - update Markdown/QMD files
  - update FTS
  - update Qdrant
  - optionally mirror to Mem0
  - optionally update graph

Source orchestration:
  - parse source_ref
  - retrieve raw source
  - return source excerpts
  - support expansion from excerpt to full session
```

### 4A.3 Central Interface Contract

The gateway shall expose these primary functions:

```text
memory_query
memory_write
memory_get_source
memory_recent_context
memory_dream
memory_reindex
memory_update
```

Secondary functions may exist internally, but Hermes should primarily use these.

### 4A.4 Central Query Modes

`memory_query` shall support:

```text
hybrid
semantic
keyword
facts
decisions
open_questions
sessions
daily
project
source
recent
graph
```

The default mode shall be `hybrid`.

### 4A.5 Central Result Normalization

All backends must return results converted into this common result object:

```json
{
  "memory_id": "string",
  "type": "fact | decision | open_question | session | turn_chunk | daily | project_memory | graph",
  "project": "string",
  "text": "string",
  "score": 0.0,
  "confidence": 0.0,
  "source_ref": "string",
  "backend_hits": ["fts", "qdrant"],
  "created_at": "timestamp",
  "updated_at": "timestamp",
  "metadata": {}
}
```

### 4A.6 Central Write Path

Durable memory writes shall flow through the gateway.

```text
memory_write request
  |
  v
validate + redact + source-check
  |
  v
dedupe + contradiction check
  |
  v
write canonical record to SQLite
  |
  +--> update project/daily Markdown files
  +--> update SQLite FTS
  +--> embed and upsert to Qdrant
  +--> optional Mem0 mirror
  +--> optional graph write
  |
  v
return memory_id + source_ref
```

No durable fact, decision, or open question should be written only to Markdown, only to Qdrant, or only to Mem0.

### 4A.7 Central Read Path

```text
memory_query request
  |
  v
parse query + filters
  |
  v
select backends
  |
  +--> SQLite facts/decisions/questions
  +--> SQLite FTS
  +--> Qdrant
  +--> raw/session/daily/project file indexes
  +--> optional Mem0
  +--> optional graph
  |
  v
merge + dedupe + rerank
  |
  v
resolve source refs as needed
  |
  v
return normalized source-backed results
```

### 4A.8 Central Source Resolver

`memory_get_source` shall support source refs such as:

```text
session:{session_id}#turn={turn_id}
session:{session_id}#turns={start}-{end}
daily:{YYYY-MM-DD}
project:{project}/memory.md#section={heading}
fact:{fact_id}
decision:{decision_id}
question:{question_id}
dream:{dream_run_id}
```

### 4A.9 Gateway as MCP Server

The gateway should be packaged so it can run as:

1. local HTTP API
2. CLI
3. MCP server
4. future Hermes custom memory provider adapter

The MCP/tool bridge is the preferred first integration because it can later be reused by Hermes, OpenClaw, Agent Zero, or other local agents.


---

## 5. Technical Components

## 5.1 Local Memory Gateway

The Local Memory Gateway is the agent-facing access layer.

Recommended implementation:

- FastAPI service
- Optional MCP server wrapper
- CLI wrapper for debugging
- Python package for internal calls

Responsibilities:

- Expose memory tools
- Validate requests
- Apply redaction rules
- Route reads/writes
- Normalize results
- Return source references
- Keep Hermes decoupled from implementation details

Primary central endpoints/tools:

```text
POST /memory/query
POST /memory/write
GET  /memory/source/{source_ref}
POST /memory/recent_context
POST /memory/dream
POST /memory/reindex
POST /memory/update

# Lower-level/internal endpoints may include:
POST /capture/event
POST /search/semantic
POST /search/keyword
POST /search/hybrid
GET  /sessions/{session_id}
GET  /daily/{date}
GET  /projects/{project}/memory
POST /facts
POST /decisions
POST /questions
POST /dream/run
GET  /sources/{source_ref}
```

---

## 5.2 Capture Manager

Responsibilities:

- Accept conversation events
- Assign IDs
- Hash content
- Append to JSONL
- Write normalized records to SQLite
- Update QMD export
- Mark records for indexing and dreaming

Event example:

```json
{
  "event_id": "evt_20260517_000042",
  "session_id": "sess_20260517_hermes_001",
  "turn_id": 42,
  "timestamp": "2026-05-17T12:20:00-05:00",
  "agent": "hermes",
  "role": "user",
  "project": "hermes-memory",
  "content": "I prefer a local solution that does not cost additional...",
  "tags": ["memory", "local-first", "requirements"],
  "source": "chat",
  "tool_calls": [],
  "attachments": [],
  "metadata": {
    "client": "hermes",
    "model": null
  },
  "hash": "sha256:..."
}
```

---

## 5.3 Filesystem Memory Store

Recommended base path:

```text
~/ai-memory/hermes-local-memory/
```

Directory layout:

```text
memory/
  raw/
    2026/
      2026-05-17/
        sess_20260517_hermes_001.jsonl

  qmd/
    2026/
      2026-05-17/
        sess_20260517_hermes_001.qmd

  daily/
    2026/
      2026-05-17.md

  projects/
    hermes/
      memory.md
      facts.md
      decisions.md
      open_questions.md
      timeline.md
      sources.md

    openclaw/
      memory.md
      facts.md
      decisions.md
      open_questions.md
      timeline.md
      sources.md

    local-ai-lab/
      memory.md
      facts.md
      decisions.md
      open_questions.md
      timeline.md
      sources.md

  entities/
    hardware.md
    models.md
    tools.md
    vendors.md
    people.md

  dreams/
    2026/
      2026-05-17-2300.md

  exports/
  backups/
  config/
```

---

## 5.4 SQLite Database

SQLite is used for local structured storage and keyword search.

Database path:

```text
memory/index/memory.sqlite
```

SQLite is a small, self-contained, reliable embedded database. SQLite FTS5 supports efficient full-text search.

### 5.4.1 Core Tables

#### sessions

```sql
CREATE TABLE sessions (
  session_id TEXT PRIMARY KEY,
  agent TEXT NOT NULL,
  title TEXT,
  project TEXT,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  summary TEXT,
  qmd_path TEXT,
  raw_path TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

#### turns

```sql
CREATE TABLE turns (
  turn_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  timestamp TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  project TEXT,
  tags_json TEXT,
  tool_calls_json TEXT,
  attachments_json TEXT,
  metadata_json TEXT,
  index_status TEXT DEFAULT 'pending',
  dream_status TEXT DEFAULT 'pending',
  FOREIGN KEY(session_id) REFERENCES sessions(session_id)
);
```

#### chunks

```sql
CREATE TABLE chunks (
  chunk_id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  start_turn_id TEXT,
  end_turn_id TEXT,
  chunk_type TEXT NOT NULL,
  project TEXT,
  text TEXT NOT NULL,
  summary TEXT,
  source_ref TEXT NOT NULL,
  qdrant_point_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

#### facts

```sql
CREATE TABLE facts (
  fact_id TEXT PRIMARY KEY,
  fact_text TEXT NOT NULL,
  scope TEXT NOT NULL,
  project TEXT,
  entity TEXT,
  confidence REAL,
  status TEXT DEFAULT 'active',
  first_seen_at TEXT,
  last_confirmed_at TEXT,
  source_refs_json TEXT NOT NULL,
  supersedes_fact_id TEXT,
  superseded_by_fact_id TEXT,
  tags_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

#### decisions

```sql
CREATE TABLE decisions (
  decision_id TEXT PRIMARY KEY,
  decision_text TEXT NOT NULL,
  rationale TEXT,
  project TEXT,
  status TEXT DEFAULT 'active',
  decision_date TEXT,
  owner TEXT,
  source_refs_json TEXT NOT NULL,
  related_fact_ids_json TEXT,
  implications TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

#### open_questions

```sql
CREATE TABLE open_questions (
  question_id TEXT PRIMARY KEY,
  question_text TEXT NOT NULL,
  project TEXT,
  priority TEXT,
  status TEXT DEFAULT 'open',
  source_refs_json TEXT NOT NULL,
  next_action TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

#### dream_runs

```sql
CREATE TABLE dream_runs (
  dream_run_id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  status TEXT NOT NULL,
  input_scope_json TEXT,
  output_path TEXT,
  facts_created INTEGER DEFAULT 0,
  facts_updated INTEGER DEFAULT 0,
  decisions_created INTEGER DEFAULT 0,
  questions_created INTEGER DEFAULT 0,
  errors_json TEXT
);
```

### 5.4.2 Full-Text Search Tables

```sql
CREATE VIRTUAL TABLE turns_fts USING fts5(
  content,
  session_id UNINDEXED,
  turn_id UNINDEXED,
  project UNINDEXED,
  timestamp UNINDEXED
);

CREATE VIRTUAL TABLE chunks_fts USING fts5(
  text,
  chunk_id UNINDEXED,
  session_id UNINDEXED,
  project UNINDEXED,
  source_ref UNINDEXED
);
```

---

## 5.5 Qdrant Vector Store

Qdrant is used for semantic search. Qdrant collections are named sets of vector points with payload metadata. Payload fields can be indexed and filtered.

Recommended collections:

```text
memory_turn_chunks
memory_summaries
memory_facts
memory_decisions
memory_project_files
```

### 5.5.1 Point Payload

Example Qdrant payload:

```json
{
  "chunk_id": "chk_20260517_000123",
  "session_id": "sess_20260517_hermes_001",
  "project": "hermes-memory",
  "source_ref": "session:sess_20260517_hermes_001#turns=12-18",
  "memory_type": "turn_chunk",
  "role_mix": ["user", "assistant"],
  "date": "2026-05-17",
  "tags": ["memory", "local-first"],
  "status": "active",
  "text_preview": "The user prefers a local solution..."
}
```

### 5.5.2 Payload Indexes

Create payload indexes for:

- `project`
- `date`
- `memory_type`
- `session_id`
- `tags`
- `status`

---

## 5.6 Local Embedding Service

Options:

- Ollama embeddings
- LM Studio embedding endpoint
- sentence-transformers local model
- llama.cpp embedding server

Recommended MVP:

- Use a local embedding model that is fast and small.
- Store embedding model name and dimensions in config.
- Use one embedding model consistently per collection unless collections are versioned.

Config:

```yaml
embedding:
  provider: "local"
  endpoint: "http://127.0.0.1:11434"
  model: "nomic-embed-text"
  dimension: 768
```

---

## 5.7 Local LLM Summarizer / Dreamer Model

Use local model endpoint through LM Studio, Ollama, or another OpenAI-compatible local server.

Recommended model roles:

```text
fast_model:
  - chunk labeling
  - tag extraction
  - simple summaries

strong_model:
  - daily dream
  - fact extraction
  - contradiction detection
  - project memory rewrite
```

Example config:

```yaml
llm:
  provider: "openai-compatible"
  base_url: "http://127.0.0.1:1234/v1"
  dream_model: "local-strong-model"
  fast_model: "local-small-model"
  temperature: 0.1
```

---

## 5.8 Dreamer / Consolidator

The Dreamer is a scheduled or manually triggered process.

Implementation:

- Python worker
- CLI command
- optional cron/systemd timer
- optional Docker service

Commands:

```bash
memory dream --date 2026-05-17
memory dream --since-last
memory dream --project hermes
memory dream --deep --project hermes
```

### 5.8.1 Dreamer Stages

```text
Stage 1: Load unprocessed source turns
Stage 2: Group by session/day/project/topic
Stage 3: Generate session summary
Stage 4: Extract candidate facts
Stage 5: Extract candidate decisions
Stage 6: Extract open questions
Stage 7: Compare candidates to existing memory
Stage 8: Detect contradictions/supersessions
Stage 9: Write structured DB records
Stage 10: Update Markdown/QMD memory files
Stage 11: Reindex derived memory
Stage 12: Write dream report
```

### 5.8.2 Dreamer Prompts

Prompt templates should be stored locally:

```text
memory/prompts/
  summarize_session.md
  summarize_day.md
  extract_facts.md
  extract_decisions.md
  extract_open_questions.md
  detect_contradictions.md
  update_project_memory.md
```

### 5.8.3 Contradiction Detection

The Dreamer should compare candidate facts against existing facts in the same project/entity scope.

Outcomes:

- create new fact
- confirm existing fact
- update last confirmed date
- mark existing fact superseded
- mark conflict as disputed
- request user review

---

## 5.9 Mem0 OSS Optional Layer

Mem0 OSS can be added as a local memory API layer, but it must not become the only source of truth.

Use cases:

- adaptive memory API
- cross-application memory access
- optional dashboard
- memory add/search/update abstraction

Mem0 OSS can run locally as a library or self-hosted server with dashboard, API keys, and audit logging.

Recommended integration pattern:

```text
Hermes
  |
  v
Local Memory Gateway
  |
  +--> native files/SQLite/Qdrant source of truth
  |
  +--> optional Mem0 OSS mirror
```

Rules:

1. Raw JSONL/QMD remains source of truth.
2. Facts/decisions remain in local DB and Markdown.
3. Mem0 stores a mirrored/adaptive memory view.
4. If Mem0 is unavailable, core memory still works.
5. Mem0 write operations are logged and traceable.

---

## 5.10 Optional Graph Memory

Post-MVP graph memory can be added for relationship and time-evolution queries.

Options:

- Kùzu
- Neo4j
- Graphiti-style temporal graph

Graph concepts:

```text
Nodes:
  User
  Project
  Agent
  Tool
  Model
  Hardware
  Vendor
  Decision
  Fact
  Session
  Document

Edges:
  USER_PREFERS
  PROJECT_USES
  DECISION_AFFECTS
  FACT_SUPERSEDES
  SESSION_DISCUSSes
  TOOL_INTEGRATES_WITH
  HARDWARE_RUNS_MODEL
```

Graph flow:

```text
Dreamer extracts entities/relations
    |
    v
Graph writer upserts nodes/edges
    |
    v
Graph search tool answers relationship/time queries
```

---

## 6. Tool Interface Design

### 6.1 `memory_search_semantic`

Input:

```json
{
  "query": "what did we decide about Hermes memory?",
  "project": "hermes",
  "date_from": null,
  "date_to": null,
  "limit": 8
}
```

Output:

```json
{
  "results": [
    {
      "source_ref": "session:sess_20260517_hermes_001#turns=4-9",
      "score": 0.87,
      "memory_type": "turn_chunk",
      "project": "hermes",
      "excerpt": "The user prefers a local solution..."
    }
  ]
}
```

---

### 6.2 `memory_search_keyword`

Input:

```json
{
  "query": "agents.list.0.tools",
  "project": "openclaw",
  "limit": 10
}
```

Output includes exact matches and source references.

---

### 6.3 `memory_search_hybrid`

Input:

```json
{
  "query": "local memory system like lossless claw",
  "project": "hermes",
  "mode": "balanced",
  "limit": 10
}
```

Modes:

```text
keyword_heavy
semantic_heavy
balanced
recent
facts_only
decisions_only
```

---

### 6.4 `memory_add_fact`

Input:

```json
{
  "fact_text": "User prefers local/no-additional-cost memory solutions over token-metered cloud memory.",
  "scope": "user",
  "project": "hermes",
  "source_ref": "session:sess_20260517_hermes_001#turn=7",
  "confidence": 0.95,
  "tags": ["preference", "local-first", "cost"]
}
```

---

### 6.5 `memory_dream_now`

Input:

```json
{
  "scope": "since_last",
  "project": null,
  "deep": false
}
```

Output:

```json
{
  "dream_run_id": "dream_20260517_230000",
  "status": "completed",
  "report_path": "memory/dreams/2026/2026-05-17-2300.md",
  "facts_created": 4,
  "decisions_created": 2,
  "questions_created": 3
}
```

---

## 7. Source Reference Format

Use stable source refs:

```text
session:{session_id}#turn={turn_id}
session:{session_id}#turns={start}-{end}
daily:{YYYY-MM-DD}
project:{project}/memory.md#section={heading}
fact:{fact_id}
decision:{decision_id}
question:{question_id}
```

Examples:

```text
session:sess_20260517_hermes_001#turns=6-9
project:hermes/memory.md#section=Architecture Decisions
fact:fact_20260517_000003
```

---

## 8. Configuration

Main config file:

```text
memory/config/memory.yaml
```

Example:

```yaml
paths:
  base: "~/ai-memory/hermes-local-memory"
  raw: "memory/raw"
  qmd: "memory/qmd"
  daily: "memory/daily"
  projects: "memory/projects"
  dreams: "memory/dreams"
  sqlite: "memory/index/memory.sqlite"

services:
  gateway:
    host: "127.0.0.1"
    port: 8787

  qdrant:
    url: "http://127.0.0.1:6333"

embedding:
  provider: "ollama"
  endpoint: "http://127.0.0.1:11434"
  model: "nomic-embed-text"

llm:
  provider: "openai-compatible"
  base_url: "http://127.0.0.1:1234/v1"
  fast_model: "local-small"
  dream_model: "local-strong"
  temperature: 0.1

memory:
  default_project: "general"
  redact_secrets: true
  write_qmd: true
  write_daily: true
  write_project_memory: true

dreamer:
  schedule: "nightly"
  max_turns_per_batch: 500
  require_source_refs: true
  contradiction_detection: true
  auto_promote_confidence_threshold: 0.85

mem0:
  enabled: false
  mode: "self-hosted"
  endpoint: "http://127.0.0.1:8888"
```

---

## 9. Deployment Architecture

### 9.1 MVP Local Deployment

```text
Host machine or AI lab node
  |
  +-- memory-gateway container
  +-- qdrant container
  +-- optional mem0-oss container
  +-- sqlite file volume
  +-- memory file volume
  +-- local model server
```

### 9.2 Docker Compose Sketch

```yaml
services:
  qdrant:
    image: qdrant/qdrant:latest
    ports:
      - "6333:6333"
    volumes:
      - ./data/qdrant:/qdrant/storage

  memory-gateway:
    build: ./memory-gateway
    ports:
      - "8787:8787"
    volumes:
      - ./memory:/app/memory
    environment:
      - MEMORY_CONFIG=/app/memory/config/memory.yaml
    depends_on:
      - qdrant
```

Mem0 OSS can be added later.

---

## 10. Security and Privacy Design

### 10.1 Local-First Rule

No external API calls by default.

### 10.2 Secret Redaction

Redaction guard should detect:

- API keys
- tokens
- passwords
- private keys
- OAuth secrets
- credit card-like strings
- SSNs
- bank account-like strings

### 10.3 Memory Write Guard

High-risk memory writes require review:

- credentials
- precise personal addresses
- medical facts
- financial account details
- legal claims
- highly sensitive personal attributes

### 10.4 Audit Trail

Every memory mutation logs:

- actor
- timestamp
- previous value
- new value
- source refs
- reason
- confidence

---

## 11. Reliability Design

### 11.1 Idempotent Capture

Events are hashed. Duplicate events are ignored or linked.

### 11.2 Idempotent Indexing

Chunk IDs are deterministic from session/turn ranges and content hash.

### 11.3 Dream Checkpoints

Each dream run records:

- input sessions
- input turn ranges
- status
- output paths
- error log

### 11.4 Recovery

Recovery steps:

1. Rebuild SQLite from raw JSONL.
2. Rebuild QMD from SQLite/raw.
3. Rebuild Qdrant from chunks.
4. Rerun dreams from checkpoint or full source.

---

## 12. Observability

### 12.1 Logs

Log files:

```text
logs/memory-gateway.log
logs/indexer.log
logs/dreamer.log
logs/errors.log
```

### 12.2 Health Checks

Endpoints:

```text
GET /health
GET /health/sqlite
GET /health/qdrant
GET /health/embedding
GET /health/llm
```

### 12.3 Metrics

Track:

- captured turns
- indexed chunks
- failed indexing records
- dream run duration
- facts created
- contradictions detected
- search latency
- Qdrant collection sizes
- SQLite DB size

---

## 13. Build Sequencing

Recommended build order:

1. Filesystem layout and config.
2. SQLite schema.
3. Capture manager.
4. QMD exporter.
5. Keyword search.
6. Qdrant integration.
7. Semantic search.
8. Hybrid search.
9. Dreamer v1.
10. Hermes tool bridge.
11. Memory file updater.
12. Optional Mem0 OSS mirror.
13. Optional graph memory.

---

## 14. Testing Strategy

### 14.1 Unit Tests

- ID generation
- JSONL append
- SQLite inserts
- FTS indexing
- chunking
- source ref creation
- redaction
- fact dedupe

### 14.2 Integration Tests

- capture → SQLite → QMD
- capture → chunk → FTS
- capture → chunk → embedding → Qdrant
- search hybrid returns source refs
- dreamer updates files
- Hermes tool call returns valid JSON

### 14.3 Regression Tests

Use a fixture session containing:

- exact error string
- conceptual memory discussion
- decision
- contradictory fact
- open question
- sensitive secret-like value

### 14.4 Acceptance Tests

User queries:

1. “Find the exact error about `agents.list.0.tools`.”
2. “What did we decide about Honcho?”
3. “What is my local memory architecture?”
4. “Show open questions for Hermes memory.”
5. “Dream today’s conversations and update project memory.”

---

## 15. Future Enhancements

1. Web dashboard.
2. Graph memory.
3. Meeting transcript ingestion.
4. Document ingestion from NAS.
5. OpenClaw bridge.
6. Agent Zero bridge.
7. Local reranker.
8. User review queue.
9. Memory diff viewer.
10. Export/import pack format.

---

## 16. References

- Hermes Agent memory providers: https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/memory-providers.md
- Hermes Honcho memory overview: https://hermes-agent.nousresearch.com/docs/user-guide/features/honcho
- Mem0 OSS overview: https://docs.mem0.ai/open-source/overview
- Mem0 self-hosted setup: https://docs.mem0.ai/open-source/setup
- Qdrant collections: https://qdrant.tech/documentation/manage-data/collections/
- Qdrant payload filtering: https://qdrant.tech/documentation/search/filtering/
- Qdrant payload indexing: https://qdrant.tech/documentation/manage-data/payload/
- SQLite: https://sqlite.org/
