# TDD: Hermes Local Memory Pack

**Document:** `TDD.md`
**Project:** `hermes-memory`
**Owner:** David McCarty
**Version:** 0.2 (rewrite — see `docs/archive/v0.1-original/` for v0.1)
**Date:** 2026-05-17
**Status:** Draft technical design

---

## 1. Technical Summary

The system splits into three deployment artifacts but **one shared library**:

| Artifact | Where it runs | What it owns |
|---|---|---|
| `plugins/memory/hermes-local/` | In-process inside Hermes (`AIAgent` process) | Capture path, tool dispatch, narrative thread, prefetch |
| `hermes_memory_core/` (library) | Imported by both plugin and gateway | SQLite, Qdrant, embeddings, hybrid scorer, redaction, source resolver |
| `hermes-memory-gateway` (FastAPI) | Standalone systemd service on `localhost:8787` | HTTP endpoints; runs dreamer; future cross-agent access |

The plugin **never speaks to Qdrant/SQLite directly itself** — it always goes through `hermes_memory_core`. The gateway is a thin HTTP shell over the same library. This means:

- Tests target one library.
- Schema/index logic exists exactly once.
- Plugin works even if the gateway is down (it calls the library directly).
- Gateway can run the dreamer (cron) without needing the agent process alive.

**Core principle:** raw history is immutable. Summaries, facts, chunks, vectors, daily/project files are derived views that can be rebuilt from raw at any time.

---

## 2. Architecture Goals

1. Local-first, no recurring memory provider cost.
2. Complete historical preservation.
3. Fast retrieval across years of conversation.
4. Dual indexing: semantic + keyword + structural.
5. Source-traceability on every derived item.
6. Clear separation: raw vs. derived.
7. Single tool surface in Hermes.
8. Plugin functional even if gateway is down.
9. Schema independence from Hermes core.
10. Graceful degradation when any backend is unavailable.
11. Idempotent capture / indexing / dreaming.
12. Rebuildable: nuke any derived store and rebuild from raw.

---

## 3. Component Diagram

```text
+---------------------------------------------------------------------------+
|                          Hermes Agent (in-process)                        |
|                                                                           |
|  AIAgent + MemoryManager                                                  |
|  |                                                                        |
|  | Hermes loads exactly ONE active MemoryProvider via config              |
|  v                                                                        |
|  +-----------------------------------------------------------------+     |
|  | plugins/memory/hermes-local/   (this plugin)                    |     |
|  |   __init__.py    -> HermesLocalProvider(MemoryProvider)         |     |
|  |   plugin.yaml    -> name, hooks                                 |     |
|  |   narrative.py   -> session thread (fixed /new injection)       |     |
|  |   tools.py       -> 6 tool schemas + dispatch                   |     |
|  |   prefetch.py    -> background hybrid prefetch                  |     |
|  +-----------------------+---------------------------+-------------+     |
|                          |                           |                    |
|       in-process import  |                           |  HTTP (heavy ops)  |
|                          v                           v                    |
|  +---------------------------------+      +-------------------------+     |
|  | hermes_memory_core/  (library)  |      | hermes-memory-gateway   |     |
|  |                                 |      | (FastAPI :8787)         |     |
|  | store/                          |      |                         |     |
|  |   sqlite.py    SQLite + FTS5    |      | /memory/query           |     |
|  |   qdrant.py    Vector store     |      | /memory/write           |     |
|  |   fs.py        JSONL + QMD      |      | /memory/source/{ref}    |     |
|  | search/                         |      | /memory/dream           |     |
|  |   hybrid.py    Scorer + merge   |      | /memory/reindex         |     |
|  |   hrr.py       Forked HRR       |      | /memory/recent_context  |     |
|  | write/                          |      | /health/*               |     |
|  |   pipeline.py  Canonical write  |      |                         |     |
|  |   redaction.py Secret scanner   |      | (Same library inside)   |     |
|  | source.py      Resolver         |      +-------------+-----------+     |
|  | embed.py       LMS client       |                    |                  |
|  | chunk.py       Chunker          |                    | (cron starts    |
|  | dream/                          |                    |  dream worker)  |
|  |   worker.py    Orchestrator     |                    v                  |
|  |   prompts/*    Templates        |      +-------------------------+     |
|  |   contradict.py Heuristic       |      | dreamer cron (3am)      |     |
|  +-----+--------------+------------+      | /etc/cron.d/hermes-     |     |
|        |              |                   | memory-dream            |     |
|        v              v                   +-------------------------+     |
|   ~/.hermes/memory/   Qdrant :6333                                        |
|     memory.sqlite     hermes_memory_*                                     |
|     raw/  qmd/        (versioned)                                         |
|     daily/  projects/                                                     |
|     dreams/                                                               |
|     SESSION-THREAD/{session_id}.md                                        |
+---------------------------------------------------------------------------+
```

### 3.1 Centralized Access Rule

Hermes interacts with memory exclusively through the registered plugin tools. The plugin owns the contract; backends are private. No code outside `hermes_memory_core` SQLs `memory.sqlite` directly.

---

## 4. Runtime Flows

### 4.1 Capture (per turn)

```text
Hermes turn completes
    -> AIAgent calls MemoryManager.sync_turn(user, asst, session_id)
        -> HermesLocalProvider.sync_turn()
            -> hermes_memory_core.write.pipeline.capture_event(event)
                -> redaction.scan(content) -> redacted_content
                -> append JSONL to memory/raw/YYYY/YYYY-MM-DD/{session_id}.jsonl
                -> insert rows into sessions + turns (SQLite WAL)
                -> queue (chunk + embed + Qdrant upsert) on worker thread
                -> mark turns.index_status = 'pending'
                -> append/update QMD export
            -> narrative.update_thread(user, asst)   # rolling 5-window
```

**Synchronous portion**: redaction + JSONL + SQLite insert (fast, < 50 ms).
**Async portion**: chunking + embedding + Qdrant upsert. Status tracked in SQLite so retries are idempotent.

### 4.2 Indexing (async worker)

```text
Indexing queue tick
    -> select * from turns where index_status = 'pending' limit BATCH
    -> chunk(turns) -> chunks[]
    -> insert chunks into chunks + chunks_fts
    -> embed.batch(chunk.text) -> vectors[]
    -> qdrant.upsert(chunks_collection, vectors, payloads)
    -> update chunks.qdrant_point_id, turns.index_status = 'indexed'
```

If embedding endpoint is down: leave `index_status='pending'`, retry next tick. **Reads still work** because hybrid scorer redistributes weights.

### 4.3 Hybrid Search

```text
memory_query(query, mode='hybrid', filters)
    -> hybrid.search(query, filters)
        -> parallel:
            * sqlite.fts5_search(query, filters)        -> fts_hits
            * embed(query); qdrant.search(vec, filters) -> qd_hits
            * jaccard(query_tokens, candidate_tokens)
            * hrr.encode + hrr.similarity (if numpy)
        -> normalize_scores(per backend)
        -> score = w_fts*fts + w_qd*qd + w_jac*jac + w_hrr*hrr
                   * trust * freshness_decay
        -> dedupe by (memory_id, source_ref, content_hash)
        -> sort desc, take top-K
    -> normalize_results() (see §10)
```

### 4.4 Source Resolution

```text
memory_get_source(source_ref)
    -> parse_ref(source_ref) -> (kind, args)
    -> dispatch:
        session#turn       -> read JSONL, locate turn_id, return content + turn metadata
        session#turns=a-b  -> stream a..b range
        session#turn#tool  -> turn + tool_call extraction
        fact:{id}          -> SQLite facts row + linked source refs
        decision:{id}      -> SQLite decisions row + linked source refs
        daily:{date}       -> read ~/.hermes/memories/{date}.md
        project:{p}/...    -> read project file, navigate to heading
        dream:{run_id}     -> read memory/dreams/...
    -> return { kind, path, content, excerpt, expandable: bool }
```

### 4.5 Dreaming (nightly cron)

```text
3am cron -> systemctl start hermes-memory-dream.service
    -> hermes_memory_core.dream.worker.run(scope='since_last')
        -> select sessions where dream_status='pending' (or new turns since checkpoint)
        -> group by (session, day, project)
        -> for each group:
            * call Qwen3.6-35B via LMS with prompts/{summarize_session.md}
            * extract candidate facts, decisions, open_questions (JSON output)
            * for each candidate:
                - run redaction (defense in depth — already done at capture)
                - call contradict.find_conflicts(candidate)
                - call pipeline.write_memory(...) (canonical write path)
        * update daily memory file (~/.hermes/memories/YYYY-MM-DD.md)
        * update project memory files
        * write dream report (memory/dreams/YYYY-MM-DD-HHMM.md)
        * update checkpoints (last_dream_run_at, processed_turn_ids)
        * mark dream_status='dreamed' on processed turns
```

Idempotency: dream runs by `(session_id, dream_run_id)` are stamped; reruns of the same scope are a no-op.

### 4.6 Memory Read in Hermes (the agent-facing loop)

```text
User asks question
    -> Hermes prefetch hook fires: provider.prefetch(query, session_id)
        -> returns cached top-3 from background queue_prefetch
    -> System prompt block: provider.system_prompt_block()
        -> pinned user facts + tiny "active project" block
    -> Hermes constructs context, calls model
    -> Model calls memory_query (or directly answers)
    -> tool dispatched -> handle_tool_call() -> core.search.hybrid.search()
    -> returns normalized results with source refs
    -> Model composes answer with citations
```

---

## 4A. Central Control Plane (carried from v0.1)

The plugin is the only memory surface in Hermes. The core library is the only memory engine. The gateway exposes the same engine over HTTP for processes that aren't the agent (cron dreamer, future cross-agent).

```text
Hermes  --plugin tools-->  hermes_memory_core
   (in-process)             |
                            +--> SQLite + FTS5
                            +--> Qdrant
                            +--> filesystem (raw, qmd, daily, projects, dreams)
                            +--> embeddings (LMS @ .105:1235)
                            +--> dreamer LLM (Qwen3.6 @ .105:1234)

Cron / future clients --HTTP--> hermes-memory-gateway --> hermes_memory_core
                                  (FastAPI :8787)
```

---

## 5. Plugin Surface

### 5.1 `plugin.yaml`

```yaml
name: hermes-local
version: 0.2.0
description: "Hermes Local Memory — lossless capture, hybrid retrieval, dreaming, narrative thread (local-first, zero per-token cost)."
hooks:
  - on_session_end
  - on_session_switch
  - on_pre_compress
  - on_memory_write
  - on_delegation
```

### 5.2 Tool Schemas (registered in `get_tool_schemas`)

#### `memory_query`

```json
{
  "name": "memory_query",
  "description": "Search the local memory. Default mode 'hybrid' combines semantic + keyword + structural. Modes also include 'semantic', 'keyword', 'facts', 'decisions', 'open_questions', 'sessions', 'daily', 'project', 'recent', 'probe', 'related', 'reason'.",
  "parameters": {
    "type": "object",
    "properties": {
      "query":   {"type": "string"},
      "mode":    {"type": "string", "default": "hybrid"},
      "project": {"type": "string"},
      "entity":  {"type": "string"},
      "entities":{"type": "array",  "items": {"type": "string"}},
      "filters": {"type": "object"},
      "limit":   {"type": "integer","default": 10}
    },
    "required": ["query"]
  }
}
```

#### `memory_write`

```json
{
  "name": "memory_write",
  "description": "Write a durable memory: fact / decision / open_question. Source reference required (or force_no_redact=true with explicit override).",
  "parameters": {
    "type": "object",
    "properties": {
      "type":       {"type": "string", "enum": ["fact","decision","open_question"]},
      "text":       {"type": "string"},
      "project":    {"type": "string"},
      "scope":      {"type": "string", "enum": ["user","project","general"]},
      "source_ref": {"type": "string"},
      "confidence": {"type": "number"},
      "tags":       {"type": "string"},
      "rationale":  {"type": "string"},
      "owner":      {"type": "string"},
      "priority":   {"type": "string"},
      "force_no_redact": {"type": "boolean", "default": false}
    },
    "required": ["type","text"]
  }
}
```

#### `memory_update`

```json
{
  "name": "memory_update",
  "description": "Update an existing memory's content / trust / tags / status / category.",
  "parameters": {
    "type": "object",
    "properties": {
      "memory_id":   {"type": "string"},
      "text":        {"type": "string"},
      "trust_delta": {"type": "number"},
      "tags":        {"type": "string"},
      "status":      {"type": "string", "enum": ["active","superseded","disputed","archived"]},
      "category":    {"type": "string"}
    },
    "required": ["memory_id"]
  }
}
```

#### `memory_get_source`

```json
{
  "name": "memory_get_source",
  "description": "Resolve a source_ref back to original content + excerpt.",
  "parameters": {
    "type": "object",
    "properties": {
      "source_ref": {"type": "string"},
      "expand":     {"type": "boolean", "default": false}
    },
    "required": ["source_ref"]
  }
}
```

#### `memory_recent_context`

```json
{
  "name": "memory_recent_context",
  "description": "Compact working set for session start: pinned facts + active project facts + recent decisions + open questions, token-budget aware.",
  "parameters": {
    "type": "object",
    "properties": {
      "project":   {"type": "string"},
      "max_chars": {"type": "integer", "default": 4000}
    }
  }
}
```

#### `memory_dream_now`

```json
{
  "name": "memory_dream_now",
  "description": "Trigger an immediate dream run. Default scope 'since_last' processes turns since last checkpoint.",
  "parameters": {
    "type": "object",
    "properties": {
      "scope":   {"type": "string", "default": "since_last", "enum": ["since_last","today","date","project","weekly"]},
      "date":    {"type": "string"},
      "project": {"type": "string"},
      "deep":    {"type": "boolean", "default": false}
    }
  }
}
```

#### `fact_feedback` (preserved from holographic)

```json
{
  "name": "fact_feedback",
  "description": "Rate a memory after using it. helpful=+0.05 trust, unhelpful=-0.10 trust.",
  "parameters": {
    "type": "object",
    "properties": {
      "memory_id": {"type": "string"},
      "action":    {"type": "string", "enum": ["helpful","unhelpful"]}
    },
    "required": ["memory_id","action"]
  }
}
```

### 5.3 Gateway HTTP Endpoints

```text
POST /memory/query              body: memory_query schema
POST /memory/write              body: memory_write schema
POST /memory/update             body: memory_update schema
GET  /memory/source/{ref}       (URL-encoded source_ref)
POST /memory/recent_context     body: memory_recent_context schema
POST /memory/dream              body: memory_dream_now schema
POST /memory/reindex            body: { scope, ranges }
GET  /health                    overall
GET  /health/sqlite             SQLite + FTS5 reachable
GET  /health/qdrant             Qdrant ping + collection count
GET  /health/llm                Dreamer LLM reachable (HEAD on LMS)
GET  /health/embedding          LMS embedding reachable + correct dim
```

---

## 6. Data Layer

### 6.1 Filesystem Layout

```text
# ── Plugin (shipped inside hermes-agent) ──────────────────────────────────
hermes-agent/
  plugins/memory/hermes-local/
    __init__.py     — HermesLocalProvider (MemoryProvider ABC); register() gates on memory.provider=hermes-local
    plugin.yaml     — name: hermes-local, version: 0.2.0, hooks: [on_session_end, on_session_switch, on_pre_compress, on_memory_write, on_delegation]
    narrative.py    — Placeholder for narrative thread (Phase 5)
    tools.py        — Placeholder for 7 tool schemas (Phase 2)
    prefetch.py     — Placeholder for hybrid prefetch (Phase 4)
    README.md       — Architecture overview and activation config

  hermes_memory_core/       (shared library — imported by plugin AND gateway)
    __init__.py     — HermesMemoryCore class; submodules importable independently
    store/
      __init__.py
      sqlite.py     — SQLite + FTS5 persistence
      qdrant.py     — Qdrant vector store client
      fs.py         — JSONL / QMD filesystem
    search/
      __init__.py
      hybrid.py     — Hybrid retrieval scorer
      hrr.py        — HRR compositional retrieval
    write/
      __init__.py
      pipeline.py   — Canonical write pipeline
      redaction.py  — Secret scanner (AWS, GitHub, OpenAI, Anthropic, card, SSN, high-entropy)
    source.py       — Source reference resolver
    embed.py        — LMS embedding client
    chunk.py        — Text chunker
    dream/
      __init__.py
      worker.py     — Dreamer orchestrator
      prompts/      — Dreamer prompt templates

# ── Runtime data (created on first use) ───────────────────────────────────
~/.hermes/memory/                         (owned by this project)
  config/
    memory.yaml                           (plugin reads from here OR ~/.hermes/config.yaml)
  raw/
    2026/2026-05-17/{session_id}.jsonl
  qmd/
    2026/2026-05-17/{session_id}.qmd
  projects/
    hermes/
      memory.md  facts.md  decisions.md  open_questions.md  timeline.md  sources.md
    hermes-memory/...
    openclaw/...
    local-ai-lab/...
  entities/
    hardware.md  models.md  tools.md  vendors.md  people.md
  dreams/
    2026/2026-05-17-0300.md
  prompts/
    summarize_session.md
    summarize_day.md
    extract_facts.md
    extract_decisions.md
    extract_open_questions.md
    detect_contradictions.md
    update_project_memory.md
  exports/
  backups/
  index/
    memory.sqlite                         (canonical SQLite DB)
    qdrant_snapshots/                     (created by `memory backup`)

~/.hermes/memories/                       (carry-forward from existing)
  2026-05-17.md

~/.hermes/SESSION-THREAD/                 (carry-forward pattern from holographic)
  {session_id}.md
```

### 6.2 SQLite Schema (`memory.sqlite`)

```sql
-- session-level
CREATE TABLE sessions (
  session_id   TEXT PRIMARY KEY,
  agent        TEXT NOT NULL,
  title        TEXT,
  project      TEXT,
  started_at   TEXT NOT NULL,
  ended_at     TEXT,
  summary      TEXT,
  qmd_path     TEXT,
  raw_path     TEXT,
  source       TEXT,                      -- 'cli','telegram','tui','gateway','cron'
  platform     TEXT,
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);

-- turn-level (lossless)
CREATE TABLE turns (
  turn_id          TEXT PRIMARY KEY,
  session_id       TEXT NOT NULL,
  sequence         INTEGER NOT NULL,
  timestamp        TEXT NOT NULL,
  role             TEXT NOT NULL,         -- 'user','assistant','system','tool'
  content          TEXT NOT NULL,         -- post-redaction
  raw_content_hash TEXT NOT NULL,         -- hash of original (pre-redaction)
  content_hash     TEXT NOT NULL,         -- hash of stored content
  project          TEXT,
  tags_json        TEXT,
  tool_calls_json  TEXT,
  attachments_json TEXT,
  metadata_json    TEXT,
  parent_turn_id   TEXT,
  index_status     TEXT DEFAULT 'pending',-- 'pending','indexed','failed'
  dream_status     TEXT DEFAULT 'pending',-- 'pending','dreamed'
  redaction_applied INTEGER DEFAULT 0,
  redaction_types_json TEXT,
  FOREIGN KEY(session_id) REFERENCES sessions(session_id)
);
CREATE INDEX idx_turns_session ON turns(session_id, sequence);
CREATE INDEX idx_turns_index_status ON turns(index_status);
CREATE INDEX idx_turns_dream_status ON turns(dream_status);

-- raw events (defense in depth — JSONL is canonical, this is a duplicate index for fast diagnostics)
CREATE TABLE raw_events (
  event_id    TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL,
  turn_id     TEXT,
  timestamp   TEXT NOT NULL,
  jsonl_path  TEXT NOT NULL,
  byte_offset INTEGER NOT NULL,
  content_hash TEXT NOT NULL
);

-- retrieval chunks (multiple per turn possible)
CREATE TABLE chunks (
  chunk_id        TEXT PRIMARY KEY,
  session_id      TEXT NOT NULL,
  start_turn_id   TEXT,
  end_turn_id     TEXT,
  chunk_type      TEXT NOT NULL,         -- 'turn_window','tool_sequence','summary'
  project         TEXT,
  text            TEXT NOT NULL,
  text_hash       TEXT NOT NULL,
  summary         TEXT,
  source_ref      TEXT NOT NULL,
  qdrant_point_id TEXT,
  embed_model     TEXT,                  -- which embedding model produced the vector
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL,
  UNIQUE(text_hash, embed_model)
);

-- durable facts
CREATE TABLE facts (
  fact_id           TEXT PRIMARY KEY,
  fact_text         TEXT NOT NULL,
  content_hash      TEXT NOT NULL UNIQUE,
  scope             TEXT NOT NULL,        -- 'user','project','general'
  category          TEXT DEFAULT 'general',
  project           TEXT,
  entity            TEXT,
  confidence        REAL,
  trust_score       REAL DEFAULT 0.5,
  status            TEXT DEFAULT 'active', -- 'active','superseded','disputed','archived'
  first_seen_at     TEXT,
  last_confirmed_at TEXT,
  source_refs_json  TEXT NOT NULL,
  supersedes_fact_id     TEXT,
  superseded_by_fact_id  TEXT,
  tags_json         TEXT,
  retrieval_count   INTEGER DEFAULT 0,
  helpful_count     INTEGER DEFAULT 0,
  hrr_vector        BLOB,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL
);
CREATE INDEX idx_facts_trust    ON facts(trust_score DESC);
CREATE INDEX idx_facts_project  ON facts(project);
CREATE INDEX idx_facts_status   ON facts(status);
CREATE INDEX idx_facts_entity   ON facts(entity);

-- entities (lifted from holographic; entity resolution)
CREATE TABLE entities (
  entity_id   INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL,
  entity_type TEXT DEFAULT 'unknown',
  aliases     TEXT DEFAULT '',
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_entities_name ON entities(name);

CREATE TABLE fact_entities (
  fact_id   TEXT REFERENCES facts(fact_id),
  entity_id INTEGER REFERENCES entities(entity_id),
  PRIMARY KEY (fact_id, entity_id)
);

-- decisions
CREATE TABLE decisions (
  decision_id      TEXT PRIMARY KEY,
  decision_text    TEXT NOT NULL,
  rationale        TEXT,
  project          TEXT,
  status           TEXT DEFAULT 'active',
  decision_date    TEXT,
  owner            TEXT,
  source_refs_json TEXT NOT NULL,
  related_fact_ids_json TEXT,
  implications     TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);
CREATE INDEX idx_decisions_project ON decisions(project);

-- open questions
CREATE TABLE open_questions (
  question_id      TEXT PRIMARY KEY,
  question_text    TEXT NOT NULL,
  project          TEXT,
  priority         TEXT,
  status           TEXT DEFAULT 'open',
  source_refs_json TEXT NOT NULL,
  next_action      TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);
CREATE INDEX idx_questions_project ON open_questions(project);
CREATE INDEX idx_questions_status  ON open_questions(status);

-- dream runs
CREATE TABLE dream_runs (
  dream_run_id     TEXT PRIMARY KEY,
  started_at       TEXT NOT NULL,
  ended_at         TEXT,
  status           TEXT NOT NULL,         -- 'running','completed','failed'
  input_scope_json TEXT,
  output_path      TEXT,
  facts_created    INTEGER DEFAULT 0,
  facts_updated    INTEGER DEFAULT 0,
  decisions_created INTEGER DEFAULT 0,
  questions_created INTEGER DEFAULT 0,
  contradictions_detected INTEGER DEFAULT 0,
  errors_json      TEXT,
  llm_model        TEXT,                  -- 'qwen3.6-35b@spark2'
  llm_endpoint     TEXT
);

-- memory banks for HRR (lifted from holographic)
CREATE TABLE memory_banks (
  bank_id    INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_name  TEXT NOT NULL UNIQUE,
  vector     BLOB NOT NULL,
  dim        INTEGER NOT NULL,
  fact_count INTEGER DEFAULT 0,
  updated_at TEXT NOT NULL
);

-- schema versioning (we own this; never share with Hermes core)
CREATE TABLE schema_version (
  applied_at TEXT NOT NULL,
  version    INTEGER NOT NULL PRIMARY KEY,
  notes      TEXT
);
INSERT INTO schema_version VALUES (datetime('now'), 1, 'initial v0.2 schema');

-- audit log (redaction events, force_no_redact overrides, write failures)
CREATE TABLE audit_log (
  audit_id     INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp    TEXT NOT NULL,
  actor        TEXT NOT NULL,            -- 'plugin','gateway','dreamer','migration','cli'
  action       TEXT NOT NULL,
  target_kind  TEXT,
  target_id    TEXT,
  detail_json  TEXT,
  source_ref   TEXT
);
CREATE INDEX idx_audit_timestamp ON audit_log(timestamp);

-- FTS5 virtual tables (all auto-synced via triggers)
CREATE VIRTUAL TABLE turns_fts USING fts5(
  content, session_id UNINDEXED, turn_id UNINDEXED, project UNINDEXED, timestamp UNINDEXED,
  content=turns, content_rowid=ROWID
);

CREATE VIRTUAL TABLE chunks_fts USING fts5(
  text, chunk_id UNINDEXED, session_id UNINDEXED, project UNINDEXED, source_ref UNINDEXED,
  content=chunks, content_rowid=ROWID
);

CREATE VIRTUAL TABLE facts_fts USING fts5(
  fact_text, tags, fact_id UNINDEXED, project UNINDEXED, scope UNINDEXED,
  content=facts, content_rowid=ROWID
);

CREATE VIRTUAL TABLE decisions_fts USING fts5(
  decision_text, rationale, decision_id UNINDEXED, project UNINDEXED,
  content=decisions, content_rowid=ROWID
);
```

FTS5 INSERT/DELETE/UPDATE triggers follow the holographic pattern (auto-sync content tables to FTS shadow tables).

### 6.3 Qdrant Collections (versioned by embed model)

```text
hermes_memory_chunks_nomic_v15      (turn-window chunks)
hermes_memory_summaries_nomic_v15   (session + daily summaries)
hermes_memory_facts_nomic_v15       (fact text)
hermes_memory_decisions_nomic_v15   (decision text)
```

Vector: 768d, distance: cosine. Payload indexes: `project`, `date`, `memory_type`, `session_id`, `tags`, `status`, `source_ref`.

Example payload:

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

### 6.4 SQLite Concurrency Model

- WAL mode (with fallback per `hermes_state.apply_wal_with_fallback`).
- Plugin is the only writer for capture (per Hermes process).
- Gateway is the only writer for dreamer / migration / reindex.
- Both can read concurrently (WAL allows it).
- Where the gateway and plugin might race (e.g. plugin writes a fact while dreamer is reindexing): the dreamer takes an advisory write lock in `audit_log` (row-level marker) at batch start; the plugin checks before bulk-writing.

---

## 7. Capture Path Details

### 7.1 Redaction Guard (Phase 1)

`hermes_memory_core.write.redaction`:

```python
PATTERNS = {
  "aws_access_key":   r"AKIA[0-9A-Z]{16}",
  "aws_secret":       r"(?<![A-Za-z0-9])[A-Za-z0-9+/]{40}(?![A-Za-z0-9/+])",  # heuristic
  "github_token":     r"gh[pousr]_[A-Za-z0-9_]{36,}",
  "openai_key":       r"sk-[A-Za-z0-9-_]{20,}",
  "anthropic_key":    r"sk-ant-[A-Za-z0-9-_]{20,}",
  "private_key":      r"-----BEGIN [A-Z ]+PRIVATE KEY-----",
  "high_entropy":     r"(?<![A-Za-z0-9])[A-Za-z0-9]{40,}(?![A-Za-z0-9])",  # secondary
  "luhn_card":        custom_luhn_match(),
  "ssn":              r"\b\d{3}-\d{2}-\d{4}\b",
}

def scan(content: str) -> tuple[str, list[str]]:
    """Returns (redacted_content, types_redacted)."""
```

On match: substring replaced with `[REDACTED:<type>]`; original is **never persisted**. Audit-log row records `target_id` (event_id) + types redacted + length, never the value. `force_no_redact=true` on `memory_write` skips the scan but logs an `audit_log` row of type `redaction_override` with `actor` and full context for review.

### 7.2 Chunking (Phase 3)

Default strategy:
- Window size: 512 tokens (tokenized via tiktoken `cl100k_base` for cross-model compatibility).
- Overlap: 128 tokens.
- Boundary preference: turn-aligned (don't split mid-turn unless turn > 512).
- Multi-turn tool sequences (user → assistant → tool → assistant): treat as one chunk if combined ≤ 1024 tokens, else split tool-result into its own chunk.

Configurable in `memory.yaml`:
```yaml
chunking:
  size_tokens: 512
  overlap_tokens: 128
  prefer_turn_boundaries: true
  tool_sequence_max_tokens: 1024
```

### 7.3 Tool Call Source Refs (Fix from v0.1 Critique)

Tool calls within a turn get their own resolvable source refs:

```text
session:{session_id}#turn={turn_id}#tool={tool_call_id}
```

The source resolver returns the specific `tool_calls[i]` object from the JSONL entry, including args and result.

---

## 8. Hybrid Retrieval

### 8.1 Scoring (lifted + extended from holographic `retrieval.py`)

```python
relevance = (W_FTS    * fts_normalized
           + W_QDRANT * qdrant_cosine
           + W_JACCARD* jaccard_sim
           + W_HRR    * hrr_sim)

score = relevance * trust_score * freshness_decay(updated_at)

# freshness_decay (configurable half-life)
def freshness_decay(ts, half_life_days=90):
    age_days = (now - ts).days
    return 0.5 ** (age_days / half_life_days) if half_life_days else 1.0
```

Default weights (sum to 1.0):

| Backend | Default | Notes |
|---|---|---|
| FTS | 0.30 | Exact strings |
| Qdrant | 0.40 | Semantic |
| Jaccard | 0.15 | Cheap token overlap |
| HRR | 0.15 | Structural reasoning |

Mode-driven overrides:

| Mode | FTS | Qdrant | Jaccard | HRR |
|---|---|---|---|---|
| `keyword` | 0.70 | 0.10 | 0.20 | 0.00 |
| `semantic` | 0.05 | 0.80 | 0.10 | 0.05 |
| `hybrid` (default) | 0.30 | 0.40 | 0.15 | 0.15 |
| `facts_only` | 0.40 | 0.30 | 0.15 | 0.15 (over facts table only) |

### 8.2 Graceful Degradation

```python
if not qdrant_available():
    redistribute_weight("qdrant", into=("fts","jaccard"))
if not embed_available():
    redistribute_weight("qdrant", into=("fts","jaccard"))  # can't embed query
if not numpy_available():
    redistribute_weight("hrr", into=("fts","jaccard"))
```

If all four backends are dead, return error `{degraded_modes: [...], message: ...}`.

### 8.3 Deduplication

Merge by `(memory_id, source_ref, content_hash)`. When duplicates collapse, union their `backend_hits` arrays so the caller sees that multiple backends agreed.

---

## 9. Narrative Thread (with `/new` fix)

### 9.1 File Format

Same as current holographic plugin: per-session `~/.hermes/SESSION-THREAD/{session_id}.md` with rolling 5-exchange window, focus line, tools list, last-updated timestamp.

### 9.2 `/new` Injection Bug — Root Cause + Fix

**Root cause (confirmed via Hermes source):** `_build_system_prompt` (run_agent.py §5810) caches the assembled prompt in `_cached_system_prompt` and only invalidates on context compression (`_invalidate_system_prompt()` line 10305). `/new` rotates `session_id` and fires `on_session_switch(reset=False, parent_session_id=old_id)` but the cached system prompt is **not** rebuilt — so even though the holographic plugin correctly populates `_nt_prev_content`, `system_prompt_block()` never gets called again to inject it.

**v0.2 fix — Option C (user-message injection):**

In `on_session_switch(new_id, parent_session_id, reset=False)`:

1. Read `~/.hermes/SESSION-THREAD/{parent_session_id}.md`.
2. Construct an injection message:

```python
injected = {
    "role": "user",
    "content": (
        "[NARRATIVE THREAD — prior session context]\n\n"
        + prior_thread_content
        + "\n\n[end narrative thread]\n\n"
        "Briefly note what you found above from the last session — what was the focus, "
        "what were we working on — and ask if there's anything to pick up on or continue from there."
    ),
    "_hermes_local_memory_thread_inject": True,  # marker so we don't double-inject
}
```

3. **Prepend this message** to the agent's `conversation_history` BEFORE the next user turn fires:
   - Plugin holds reference to `AIAgent` via `initialize()` kwarg `agent_ref` (we add this — see §15.1).
   - On `on_session_switch`, plugin calls `agent_ref.conversation_history.insert(0, injected)`.
4. Mark `_nt_first_turn_done = True` immediately (no risk of double-injection).
5. New session's first response naturally acknowledges prior context — no system-prompt rebuild needed, no cache invalidation needed, prompt-cache stays warm.

### 9.3 Edge Cases

- `parent_session_id` empty (rare — first-ever session, or branch without parent): no injection.
- Thread file missing: no injection, log debug.
- Context compaction mid-injection: the injected user message is part of conversation_history → gets included in compression naturally → no special handling needed.
- `/reset` (reset=True): flush all thread state, no injection.

### 9.4 Integration Test

`tests/integration/test_narrative_thread_inject.py` (we own this):

```text
1. Start CLI session, send 3 turns about "Project Foo".
2. /quit
3. Restart CLI, /resume <previous session>
4. Send turn: "hi"
5. Assert: response contains 'Project Foo' OR mentions the prior focus
6. /new
7. Send turn: "hi again"
8. Assert: response contains some reference to the prior session
9. Repeat for /branch and post-compaction scenarios
```

---

## 10. Dreaming v1

### 10.1 Stages

```text
1. Load unprocessed turns (dream_status='pending' or post-last-checkpoint).
2. Group by (session_id, day, project, entity).
3. Per group:
   3a. Generate session summary via Qwen3.6-35B (prompts/summarize_session.md).
   3b. Extract candidate facts (prompts/extract_facts.md, JSON output enforced).
   3c. Extract candidate decisions.
   3d. Extract open questions.
4. Per candidate:
   4a. Redaction (defense in depth).
   4b. Contradiction check (heuristic v1 — see §10.3).
   4c. Write via memory_core.write.pipeline.write_memory().
5. Update daily memory file.
6. Update project memory files.
7. Refresh indexes (chunks + FTS + Qdrant).
8. Write dream report.
9. Update checkpoints + mark turns dream_status='dreamed'.
```

### 10.2 Prompt Templates

All under `~/.hermes/memory/prompts/`:

- `summarize_session.md` — produces concise session summary + topic list.
- `extract_facts.md` — JSON-out: `[{text, scope, project, entity?, confidence, source_ref, tags}]`.
- `extract_decisions.md` — JSON-out: `[{text, rationale, project, source_ref, owner?}]`.
- `extract_open_questions.md` — JSON-out: `[{text, project, priority, source_ref}]`.
- `detect_contradictions.md` — gets two candidate facts + existing fact, returns `{verdict: confirms|contradicts|unrelated|supersedes, rationale}`.
- `update_project_memory.md` — given existing project memory + new facts/decisions, return updated markdown.

Each prompt MUST:
- Forbid inventing unsupported facts.
- Require source refs on every output item.
- Specify strict JSON schema (no free text).

### 10.3 Contradiction Detection (heuristic v1)

```python
def find_conflicts(candidate, existing_facts):
    bucket = (candidate.project, candidate.entity or extract_primary_entity(candidate.text), candidate.category)
    for existing in existing_facts in same bucket:
        if jaccard(candidate.text_tokens, existing.text_tokens) > 0.4 and \
           not token_alignment(candidate, existing):
            yield existing  # potential conflict
```

On conflict: new fact gets `status='disputed'`, `supersedes_fact_id=existing.fact_id` (only as a candidate link, not auto-applied), and the dream report flags it. LLM-based semantic contradiction is post-MVP.

### 10.4 Idempotency

- `dream_runs` table records `(scope, started_at, processed_turn_id_range)`.
- A re-run of the same scope: detects already-dreamed turns via `turns.dream_status='dreamed'`, skips them.
- Fact dedup: `facts.content_hash UNIQUE` constraint blocks re-insertion; matching hash bumps `last_confirmed_at` instead.

### 10.5 LLM Configuration

```yaml
llm:
  provider: "openai-compatible"
  base_url: "http://192.168.2.105:1234/v1"
  dream_model: "qwen3.6-35b-instruct"   # or whatever LMS reports
  temperature: 0.1
  max_tokens: 4096
  json_mode: true                       # strict JSON output for extraction prompts
```

---

## 11. Configuration

### 11.1 Plugin Config (in `~/.hermes/config.yaml`)

```yaml
memory:
  provider: hermes-local                   # the swap

plugins:
  hermes-local-memory:
    base_path: "$HERMES_HOME/memory"
    sqlite_path: "$HERMES_HOME/memory/index/memory.sqlite"
    gateway:
      enabled: true
      url: "http://127.0.0.1:8787"
      timeout_ms: 8000
      fallback_to_inprocess: true          # if gateway down, call core directly
    redaction:
      enabled: true
      log_overrides: true
    embedding:
      provider: "openai-compatible"
      endpoint: "http://192.168.2.105:1235/v1"
      model: "text-embedding-nomic-embed-text-v1.5"
      dimension: 768
    dreamer:
      enabled: true
      cadence: "nightly"                   # 'nightly','session_end','manual_only','all'
      cron_time: "03:00"
      llm_endpoint: "http://192.168.2.105:1234/v1"
      llm_model: "qwen3.6-35b-instruct"
      max_turns_per_batch: 500
      auto_promote_confidence: 0.8
    narrative_thread:
      enabled: true
      thread_dir: "$HERMES_HOME/SESSION-THREAD"
      retention_days: 30
    hybrid_weights:
      fts: 0.30
      qdrant: 0.40
      jaccard: 0.15
      hrr: 0.15
    freshness_half_life_days: 90
```

### 11.2 Gateway Service Config (`~/.hermes/memory/config/memory.yaml`)

Same shape; the gateway reads its own config so it can run standalone (e.g., headless on a server).

---

## 12. Deployment

### 12.1 Plugin

Ships inside `hermes-agent` via `plugins/memory/hermes-local/`. No separate install — Hermes plugin loader picks it up. Activation = one config line.

### 12.2 Gateway

Standalone systemd unit (`hermes-memory-gateway.service`) under `~/.hermes/memory/scripts/`:

```ini
[Unit]
Description=Hermes Local Memory Gateway
After=network.target

[Service]
Type=simple
User=dmccarty
WorkingDirectory=/home/dmccarty/.hermes/hermes-agent
ExecStart=/home/dmccarty/.hermes/hermes-agent/venv/bin/python -m hermes_memory_gateway
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

### 12.3 Dreamer

systemd timer (`hermes-memory-dream.timer`) fires nightly at 3am, runs `hermes-memory-dream.service`, which invokes `python -m hermes_memory_core.dream --scope since_last`.

### 12.4 Docker (optional / future)

Compose file provided for headless/server-only deployments. Out-of-scope for MVP on the main lab machine since Qdrant + LMS are already running natively.

---

## 13. Security & Privacy

- Phase 1 redaction (see §7.1).
- All memory local by default.
- Audit log on every write + every redaction override.
- High-risk content (financial/medical/legal/credentials) flagged via tag-based heuristic; high-risk writes require `force_no_redact=true` or hit redaction.
- Post-MVP: memory review queue for low-confidence + sensitive items.

---

## 14. Reliability

### 14.1 Idempotency

- Event hashing: `sha256(session_id + turn_id + raw_content)` keys dedup.
- Chunk IDs: deterministic from `(session_id, start_turn_id, end_turn_id, text_hash, embed_model)`.
- Dream runs: tagged by `(scope, started_at)`; reruns skip already-processed turns.
- Fact writes: `facts.content_hash UNIQUE` blocks dupes; matching hash bumps `last_confirmed_at`.

### 14.2 Recovery

`memory rebuild-indexes` performs:

1. Drop `chunks_fts`, `turns_fts`, `facts_fts`, `decisions_fts`.
2. Delete Qdrant collections (or recreate with current embed model version).
3. Re-scan all JSONL files in `raw/` → re-insert turns (idempotent via content_hash).
4. Re-chunk all turns → insert into chunks → re-embed → upsert Qdrant.
5. Optionally re-run dreamer to rebuild facts/decisions/questions from raw.

Raw JSONL is never touched during rebuild.

### 14.3 Checkpoints

`dream_runs` rows + `turns.dream_status` + `turns.index_status` are the durable checkpoints. A crashed dream run leaves status `running` — next dreamer detects stale `running` rows, marks them `failed`, and retries from the last completed checkpoint.

---

## 15. Hermes Integration Details

### 15.1 New `MemoryProvider` Capability We Need

To inject the narrative-thread user message (§9.2), the plugin needs a reference to the `AIAgent`'s `conversation_history`. The existing ABC doesn't pass this. Two options:

**Option A — extend `MemoryProvider.initialize` kwargs (preferred, no core change):**

The existing `initialize(session_id, **kwargs)` already passes `hermes_home`, `platform`, etc. We add a check: if `kwargs.get('agent_ref')` is available, store it. If not, fall back to a `system_prompt_block`-with-cache-invalidation hack (call `agent._invalidate_system_prompt()` via reflection — fragile).

**Option B — submit a small upstream PR to Hermes:**

Add `agent_ref` to the documented `initialize` kwargs. Tiny change, no breaking impact (extra kwarg, backwards compatible).

Recommendation: **try Option A via reflection first** (zero coupling), if it doesn't work reliably, raise Option B as a small PR.

### 15.2 Hooks We Implement

| Hook | Why |
|---|---|
| `initialize(session_id, **kwargs)` | Open DB, connect Qdrant, store agent ref, set up worker thread |
| `is_available()` | `True` (local, no creds needed) |
| `system_prompt_block()` | Pinned facts + active project context (small, not the narrative thread) |
| `prefetch(query, session_id)` | Return cached hybrid prefetch result |
| `queue_prefetch(query, session_id)` | Background thread runs hybrid search for next turn |
| `sync_turn(user, asst, session_id)` | Main capture path |
| `get_tool_schemas()` | The 7 schemas in §5.2 |
| `handle_tool_call()` | Dispatch to core |
| `on_session_end(messages)` | Optional dream trigger; flush async writes |
| **`on_session_switch(new_id, parent, reset)`** | **Narrative-thread injection (fix)** |
| `on_pre_compress(messages)` | Extract candidate facts BEFORE Hermes discards |
| `on_memory_write(action, target, content, metadata)` | Mirror built-in `memory` tool writes as facts |
| `on_delegation(task, result, child_session_id)` | Capture subagent outputs as turns |
| `get_config_schema()` | Wire into `hermes memory setup` |
| `save_config(values, hermes_home)` | Write into `config.yaml` |
| `shutdown()` | Close DB, flush queues |

---

## 16. Migration from Holographic

`scripts/migrate_from_holographic.py`:

```python
1. Read ~/.hermes/memory_store.db (via SQLite, read-only).
2. For each row in holographic.facts:
   - Map: content -> fact_text
          category -> category
          tags -> tags_json
          trust_score -> trust_score
          retrieval_count -> retrieval_count
          helpful_count -> helpful_count
          created_at/updated_at -> created_at/updated_at
   - source_ref = "migration:holographic#fact_id={old_id}"
   - confidence = trust_score (initial pin)
   - Call memory_core.write.pipeline.write_memory(fact, skip_redaction=False)
     (force_no_redact NOT set — secrets that snuck in earlier still get caught now)
3. Holographic entities + fact_entities -> new entities + fact_entities (preserve IDs).
4. Holographic memory_banks -> recomputed via rebuild_all_vectors() (fresh).
5. Write a migration report to memory/exports/migration-holographic-{ts}.md.
6. Do NOT touch holographic memory_store.db. (User can flip provider back any time.)
```

Idempotent — re-running detects existing facts by content_hash and skips them. User flips `memory.provider: hermes-local` only after running migration + verifying counts.

---

## 17. Observability

### 17.1 Logs

```text
~/.hermes/logs/memory-plugin.log     (capture path, plugin lifecycle)
~/.hermes/logs/memory-gateway.log    (gateway service)
~/.hermes/logs/memory-dream.log      (dreamer runs)
~/.hermes/memory/audit.jsonl         (write-events + redactions + overrides)
```

### 17.2 Metrics (basic — gauge files, not Prometheus for MVP)

```text
~/.hermes/memory/metrics.json   updated by plugin + gateway:
  {
    captured_turns_24h: 142,
    chunks_indexed_24h: 67,
    chunks_pending: 3,
    facts_total: 51, facts_active: 47,
    qdrant_points: 1248,
    last_dream_run_at: "2026-05-17T03:00:00",
    last_dream_status: "completed",
    redactions_24h: 2
  }
```

Wire into the existing observability stack (`/disk2/observability`) post-MVP.

### 17.3 Health Endpoints (gateway)

`GET /health` returns rolled-up status of: SQLite, Qdrant, embedding endpoint, dreamer LLM, dreamer last-run age, disk space.

---

## 18. Testing Strategy

### 18.1 Unit Tests

- Event hashing, dedup
- JSONL append + read-back
- SQLite migrations are idempotent
- FTS triggers fire on insert/update/delete
- Redaction patterns (positive + negative)
- Chunker boundaries
- Hybrid scorer weight redistribution
- Source ref parser (all formats)
- HRR encode/bundle/probe (forked from holographic)
- Fact contradiction heuristic

### 18.2 Integration Tests

- capture → SQLite → QMD → FTS visible
- capture → chunk → embed → Qdrant
- hybrid search returns merged source-refs
- dreamer produces daily + project memory + dream report
- `memory_write` round-trips via plugin and gateway
- `memory_get_source` resolves all ref formats
- **Narrative thread `/new` injection (the bug-fix test)** — covers `/resume`, `/branch`, `/new`, post-compaction
- Provider swap removes holographic tools from registered schemas
- Migration from holographic preserves all facts (count + content_hash)
- Graceful degradation: kill Qdrant; hybrid still returns FTS results
- Rebuild-indexes recreates correct row counts from raw

### 18.3 Acceptance Tests (MVP gate)

Mapped to `Plan.md §13`. Headline scenario:

> Seed a session with 10 turns including an exact error string, a conceptual discussion, a decision, a contradiction, and a fixture API key. After capture: API key is redacted, keyword search finds error string, semantic search finds conceptual discussion, dreamer extracts the decision with source ref, contradiction is flagged not silently overwritten. `/new`, then "hi" — assistant references prior session.

---

## 19. Out-of-Scope (Reaffirmed)

- Cloud sync, multi-user governance, per-user memory partitions
- Real-time graph reasoning (post-MVP)
- Document/file ingestion beyond chat turns
- Web dashboard
- Cross-agent memory bus formalization (OpenClaw / Agent Zero coexist; no shared store in MVP)

---

## 20. References

- Hermes `MemoryProvider` ABC: `~/.hermes/hermes-agent/agent/memory_provider.py`
- Holographic plugin (primary reference): `~/.hermes/hermes-agent/plugins/memory/holographic/`
- Honcho plugin (out-of-process reference): `~/.hermes/hermes-agent/plugins/memory/honcho/`
- OpenClaw enhanced-memory: `~/.openclaw/workspace/skills/enhanced-memory/README.md`
- Hermes session-state helper: `~/.hermes/hermes-agent/hermes_state.py` (`apply_wal_with_fallback`)
- Qdrant: https://qdrant.tech/documentation/
- SQLite FTS5: https://sqlite.org/fts5.html
- nomic-embed-text-v1.5: https://huggingface.co/nomic-ai/nomic-embed-text-v1.5
- v0.1 docs: `docs/archive/v0.1-original/`
