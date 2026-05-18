# Project Introspection: Hermes Local Memory Pack

**Document:** `project-introspection.md`  
**Date:** 2026-05-17  
**Author:** Hermes Agent (internal review)  
**Status:** Issues and open questions identified

---

## 1. Executive Summary

The Hermes Local Memory Pack spec (Plan.md, prd.md, TDD.md) is well-structured and clearly authored with strong architectural discipline. The phased delivery strategy and centralized control plane principle are sound. However, there are gaps, complications, and open questions that need resolution before or during implementation. This document catalogs those issues.

---

## 2. Hermes Architecture Mapping

### 2.1 Current Memory Architecture

Hermes has an existing layered memory system:

| Component | Location | Role |
|---|---|---|
| `MEMORY.md` / `USER.md` | `~/.hermes/` | Curated durable context, human-editable |
| `hermes_state.py` (SessionDB) | Hermes core | SQLite session storage with FTS5 |
| `fact_store` | Tool | Structured entity memory (holographic) |
| `session_search` | Tool | FTS5 full-text session search |
| `memory` tool | Tool | Simple key-value memory reads |
| `MemoryProvider` plugin interface | `agent/memory_provider.py` | Pluggable external memory backend |
| `MemoryManager` | `agent/memory_manager.py` | Single-provider orchestration |
| Built-in narrative thread | `plugins/hermes-memory/` | Per-session rolling working memory |

**Key constraint:** Only ONE external MemoryProvider at a time. This is enforced to prevent tool schema bloat and conflicting backends.

### 2.2 How the Spec Maps to Current Architecture

| Spec Concept | Hermes Current State | Fit |
|---|---|---|
| Raw JSONL capture | Not implemented in Hermes core | Gap — need new capture layer |
| QMD export | Not implemented | Gap |
| SQLite sessions/turns | `hermes_state.py` has sessions + turns tables | Partial — schema differs |
| SQLite FTS5 | `hermes_state.py` uses FTS5 | Already exists |
| Qdrant semantic search | Not implemented | Gap |
| Dreamer/consolidation | Narrative thread plugin attempts this | Partial — different approach |
| Central memory gateway | No equivalent | Gap — spec requires new service |
| `memory_query` / `memory_write` | No equivalent tool interface | Gap |
| Source tracing | Not implemented | Gap |
| Fact/decisions/questions stores | `fact_store` tool exists separately | Partial — not unified |
| Memory files (`MEMORY.md`, `USER.md`) | Already exists at `~/.hermes/` | Already exists |
| MCP/Gateway integration | MCP not wired to memory system | Gap |
| `memory_get_source` | Not implemented | Gap |

### 2.3 Critical Overlap: hermes_state.py

`hermes_state.py` is Hermes's current session store. It already has:
- SQLite with FTS5 for session search
- Sessions and turns tables
- Session ID and turn indexing

**The spec proposes a completely separate SQLite schema** at `memory/index/memory.sqlite`. This creates a second SQLite database that stores overlapping data (sessions/turns). This is a significant complication:

1. **Dual storage** — session events land in both `hermes_state.db` and `memory/index/memory.sqlite`
2. **Two FTS indexes** — both track session content
3. **Two write paths** — Hermes writes to `hermes_state`, the memory gateway writes to its own DB
4. **Migration question** — does the memory system own the canonical session store, or mirror from Hermes?

**This is the most critical architectural conflict in the spec.**

---

## 3. Issues and Complications

### Issue 1: Dual SQLite Session Stores

**Severity:** High  
**Category:** Architecture conflict

The spec places session/turn storage at `memory/index/memory.sqlite` with its own schema. Hermes currently stores sessions/turns in `hermes_state.db` via `hermes_state.py`. Both would hold sessions and turns.

**Questions raised:**
- Does the memory gateway become the canonical store and Hermes reads from it?
- Does Hermes continue writing to `hermes_state.db` and the memory gateway mirrors from there?
- Does the memory gateway share the same SQLite file as `hermes_state.db`?
- What happens to existing session history in `hermes_state.db` during migration?

**Recommendation:** The memory gateway should read from Hermes's existing session store rather than duplicating it. A shared SQLite file or read-only mirror avoids dual-write complexity.

---

### Issue 2: Capture Path Is Unclear

**Severity:** High  
**Category:** Integration gap

The spec defines the capture flow as:
```
Hermes turn occurs → Memory Gateway receives event
```

But Hermes has no mechanism to push events to an external gateway. The current `MemoryProvider` interface has `sync_turn(user, asst)` which is called by the agent after each turn, but this is designed for external cloud providers (Honcho-style), not a local HTTP gateway.

**Questions raised:**
- How does Hermes send events to the local memory gateway? Polling? Webhook? Direct function call?
- Is the gateway called as a `MemoryProvider` implementation?
- Does the gateway run as a sidecar or embedded in the same process?
- Does the capture use HTTP (network, latency, failure modes) or IPC (faster, more complex)?

**Recommendation:** Define the transport explicitly. An MCP server for the memory gateway is the cleanest fit since Hermes already uses MCP tools and the spec calls out MCP as the preferred integration. A local HTTP API is slower and adds failure modes for sync operations.

---

### Issue 3: Memory Provider Constraint Conflict

**Severity:** Medium  
**Category:** Design tension

Hermes enforces **one external MemoryProvider at a time** to prevent tool schema bloat. The spec proposes multiple backends (Qdrant, SQLite, files, Mem0, graph) behind a single gateway — but the gateway itself would be a MemoryProvider.

If a user wants Honcho cloud memory AND the local memory pack simultaneously, they can't have both. The spec's "optional Mem0 mirror" and "optional graph memory" are fine as internal backends, but if the local memory gateway replaces Honcho, the user loses Honcho's features.

**Questions raised:**
- Does the local memory gateway replace the Honcho MemoryProvider entirely?
- Can users who want cloud memory + local memory have both?
- Is the "one provider" rule a hard constraint worth preserving?

**Recommendation:** The local memory gateway should implement `MemoryProvider` and replace Honcho as the preferred local-first option. Honcho becomes the optional cloud fallback.

---

### Issue 4: Embedding Model Not Determined

**Severity:** Medium  
**Category:** Missing spec detail

The spec mentions local embeddings via Ollama or LM Studio but does not specify which embedding model to use. Different embedding models have different dimensions, which determines the Qdrant collection vector size. Changing the embedding model later requires re-embedding all chunks.

**Questions raised:**
- Which local embedding model for MVP?
- What dimension for Qdrant collections?
- Is there a preference between Ollama (`nomic-embed-text`) vs LM Studio embedding endpoint vs sentence-transformers?
- Does the embedding model need GPU support?

**Recommendation:** Choose `nomic-embed-text` (768d, fast, CPU-capable) for MVP to avoid GPU dependency. Document dimension clearly and version the collection by embedding model.

---

### Issue 5: Narrative Thread vs Dreamer Scope Overlap

**Severity:** Medium  
**Category:** Feature overlap

Hermes has a narrative thread plugin (`plugins/hermes-memory/`) that attempts rolling session summarization and context retention across session rotations. The spec's "dreamer" does session/day summaries, fact extraction, and project memory updates.

Both:
- Generate session summaries
- Update rolling memory context
- Run on session boundaries
- Extract key facts/decisions

The spec does not address the relationship between the narrative thread and the dreamer.

**Questions raised:**
- Does the dreamer replace the narrative thread?
- Do they run as separate processes?
- Does the narrative thread become a client of the memory gateway?
- Should narrative thread stories be migrated to dreamer jobs?

**Recommendation:** The dreamer should subsume narrative thread functionality. The narrative thread's current approach (lightweight per-session) complements the dreamer's deeper analysis (periodic deep consolidation), but they should not duplicate writes to the same memory files.

---

### Issue 6: Redaction Guard Placement

**Severity:** Medium  
**Category:** Security / Data handling

The spec lists "redaction guard" in the capture flow before JSONL append. This is the right place. However:
- The spec does not define what constitutes a secret (beyond "API keys, tokens")
- There's no mention of PII handling
- The review queue (Phase 9) comes after all other phases — secrets could be stored for months before review discovers them

**Questions raised:**
- What patterns trigger redaction? Entropy? Regex? Allowlist?
- Are API keys caught before storage or only during review?
- Does redaction apply to tool results, attachments, and reasoning content?
- Can the user override redaction for specific content?

**Recommendation:** Redaction should be tested in Phase 1 (not Phase 9) with fixture API keys and password patterns. Phase 9 placement means the MVP could store secrets that aren't caught until much later.

---

### Issue 7: Source Ref Resolution for Tool Calls

**Severity:** Medium  
**Category:** Implementation complexity

The spec's source refs include `session:{session_id}#turns={start}-{end}` format. Tool calls are stored separately in the event schema but are part of the turn. When a tool result is the source of a fact or decision, the source ref needs to point to the tool result specifically, not just the turn.

**Questions raised:**
- Do tool calls get their own turn IDs or share the parent turn's ID?
- Can you source-resolve a specific tool call within a turn?
- What about multi-turn tool sequences (user asks → assistant calls tool → tool result → assistant responds)?
- Do attachments get source refs?

**Recommendation:** Define tool call source refs explicitly in the event schema. A `tool_call` inside a turn should be addressable as `session:{id}#turn={n}#tool={tool_call_id}`.

---

### Issue 8: FastAPI Gateway vs MCP Server Ambiguity

**Severity:** Low-Medium  
**Category:** Integration pattern

The spec says the gateway should run as: local HTTP API, CLI, MCP server, Hermes custom memory provider adapter. That's four deployment options. The MCP server is listed as "preferred first integration."

But Hermes has a specific `MemoryProvider` plugin interface. If the gateway is an MCP server, it's a separate process with its own transport. If it's a MemoryProvider adapter, it runs in-process.

**Questions raised:**
- Is the gateway an out-of-process HTTP/MCP service, or an in-process library?
- If out-of-process, does Hermes call it via HTTP or via MCP?
- If MCP, does it register as an MCP server that Hermes connects to?
- Does the gateway run as a cron job or a persistent service?

**Recommendation:** Decide on out-of-process HTTP + MCP for the MVP. Hermes calls the gateway via HTTP (simpler to implement and debug), with MCP as a secondary interface for future agent interoperability (OpenClaw, Agent Zero).

---

### Issue 9: Chunking Strategy Under-Specified

**Severity:** Low-Medium  
**Category:** Missing detail

The spec says "implement chunking strategy" and "support turn windows and topic chunks" but doesn't define the actual chunking algorithm. Chunk size directly affects retrieval quality and Qdrant storage.

**Questions raised:**
- Fixed token count chunks or semantic boundary chunks?
- Overlap between chunks? How much?
- Who decides chunk boundaries — the chunker or the embedding model?
- Are multi-turn tool sequences chunked together or split?

**Recommendation:** Start with fixed-size chunks (512 tokens, 128 token overlap) for MVP simplicity. Semantic boundary chunking is a Phase 3+ enhancement.

---

### Issue 10: Fact Confidence and Review Queue

**Severity:** Low-Medium  
**Category:** UX / Quality

The spec requires confidence scores on facts and a review queue for low-confidence facts. But:
- Who decides the confidence threshold for auto-promotion vs review?
- Is there a user notification when facts hit the review queue?
- Is the review queue a file, CLI, or dashboard?

**Questions raised:**
- What's the default confidence threshold (0.7? 0.9?)?
- Does the user get notified in Hermes when a fact needs review?
- Can the user set per-project confidence thresholds?

**Recommendation:** Default threshold of 0.8 for auto-promotion. Review queue as CLI command first, dashboard post-MVP.

---

### Issue 11: Qdrant Collection Versioning

**Severity:** Low  
**Category:** Operational

The spec notes embedding model changes require re-embedding. But Qdrant collections with different vector dimensions are incompatible. If the embedding model changes (e.g., from 768d to 1536d), the collection must be recreated and re-indexed.

**Questions raised:**
- Does the collection name encode the embedding model version?
- Is there a migration path for existing vectors when the model changes?
- Does the gateway support multiple collection versions simultaneously?

**Recommendation:** Collection naming includes embedding model version (e.g., `memory_turn_chunks_v1`). Re-indexing job rebuilds from source when model changes.

---

### Issue 12: Open Questions in the Spec

The following open questions from the spec were not resolved and need user input:

1. **Base path:** Spec suggests `~/ai-memory/hermes-local-memory/` but existing Hermes state is at `~/.hermes/`. Should memory pack live at `~/.hermes/memory/` to keep everything together, or at `~/.hermes-memory/` as a sibling to `.hermes`?

2. **Dreamer LLM model:** The spec says "use local model endpoint through LM Studio or Ollama" but doesn't specify which model for fact extraction vs summarization. Should we use Spark (already running on `.249`) for the dreamer?

3. **Backup target:** Where should backups be stored? Same NAS/backup target as other AI lab data? The spec says backup excludes secrets but doesn't specify the backup destination.

4. **Mem0 OSS integration priority:** The spec deprioritizes Mem0 to post-MVP, but Mem0 might solve some of the adapter complexity. Is Mem0 OSS integration desired in MVP or truly post-MVP?

5. **Cross-agent memory:** The spec says the gateway should support Hermes, OpenClaw, and Agent Zero. How should cross-agent memory sharing work? Should OpenClaw also write to the same memory gateway?

6. **Git sync:** The OpenClaw workspace has a git repo. Should the memory pack's project memory files (facts.md, decisions.md, etc.) be git-tracked separately, or should they sync into the OpenClaw workspace git automatically?

---

## 4. Positive Observations

These are things the spec gets right:

- **Central control plane principle** — routing all memory through one gateway is the correct architectural decision and avoids the silo problem.
- **Raw JSONL as immutable source of truth** — derived views can be rebuilt from raw, not the other way around. This is the right approach.
- **Dual indexing (FTS + Qdrant)** — necessary for the "exact error string" vs "conceptual" distinction.
- **Phased delivery with sprint exits** — practical and reduces risk.
- **Idempotency requirement** — re-running indexing/dreaming shouldn't create duplicates. Critical for operational reliability.
- **Source tracing on every result** — builds trust in memory-derived context.
- **Contradiction detection** — surfacing conflicts rather than silently overwriting is the right behavior.
- **Redaction before storage** — catching secrets at write time rather than after is the right architecture.
- **Mem0 kept optional and not source of truth** — avoids vendor lock-in and preserves the local-first principle.

---

## 5. Recommended Next Steps

### Before Sprint 1:

1. **Resolve Issue 1** — Decide how `hermes_state.py` and `memory/index/memory.sqlite` relate. Options: share the same DB file, mirror reads, or have the gateway read from Hermes's session store directly.

2. **Resolve Issue 2** — Define the capture transport (HTTP push from Hermes? MCP? MemoryProvider interface?).

3. **Resolve Issue 8** — Decide: out-of-process HTTP service for MVP, MCP as secondary.

4. **Resolve open question 1** — Choose memory pack base path (`~/.hermes/memory/` vs `~/.hermes-memory/`).

5. **Resolve open question 2** — Choose dreamer LLM (Spark via LM Studio is a strong candidate since it's already running).

### During Sprint 1:

6. **Address Issue 6** — Move redaction testing to Phase 1, not Phase 9.

7. **Address Issue 9** — Define chunking strategy explicitly before implementing Phase 3.

8. **Address Issue 12** — Define tool call source ref format before implementing capture.

---

## 6. Summary Assessment

| Dimension | Score | Notes |
|---|---|---|
| Architectural soundness | 8/10 | Central gateway principle is correct. Dual DB is the main issue. |
| Hermes fit | 6/10 | Significant gaps in capture path and Hermes integration |
| Spec completeness | 7/10 | Good detail in TDD, PRD, and Plan. Missing transport definition. |
| Operational clarity | 6/10 | Idempotency and rebuild covered well. Backup scope unclear. |
| Security/remediation | 5/10 | Redaction in Phase 9 is too late. PII not addressed. |
| Implementation risk | Medium | Phase 0A and Phase 1 integration points with Hermes are underspecified |

The spec is a strong foundation. The main gaps are in the Hermes integration layer (how Hermes talks to the gateway) and the dual database question. Resolving those two items before Sprint 1 will prevent significant rework.