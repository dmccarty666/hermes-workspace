# ADR 003: Indexer Process Model

**Status:** **Accepted** ✅
**Date:** 2026-05-17
**Author:** hm-architect (draft) — David approved 2026-05-17
**Critique ref:** `docs/v0.2-critique.md` Issue 3
**Spec ref:** `TDD.md` §4.2; `Plan.md` Phase 3 Epic 3.2 (Async indexer)

---

## Context

The hermes-memory system has an asynchronous **indexer** that does the heavy work of turning a captured turn into a queryable artifact:

1. Take turns marked `index_status='pending'` in SQLite
2. Chunk them (per `memory_core.chunk`)
3. Embed each chunk via LMS (`http://192.168.2.105:1235`)
4. Upsert into Qdrant with payload metadata
5. Update `chunks.qdrant_point_id` and `turns.index_status='indexed'`

This is NOT in the synchronous `sync_turn` capture path — that path stays fast (<50ms): JSONL append + SQLite insert + redaction. The indexing is deferred to an async worker because embedding can take seconds and Qdrant upserts can fail transiently.

The v0.2 TDD §4.2 described the indexer ambiguously as "a background worker thread (or systemd-style)" — three very different architectures. The critique correctly flagged this as a gap. This ADR picks one.

**Failure modes that drive the decision:**
- User runs a 200-turn CLI session, then quits → un-indexed turns leak if indexer was in-process
- LMS endpoint is down for 2 hours → indexer must queue and retry, not lose work
- Gateway service crashes mid-batch → in-flight chunk must not get half-indexed (orphan Qdrant points)
- Indexer becomes a third writer to SQLite → must respect ADR-002 ownership (gateway owns `chunks`)

## Decision (proposed)

**Adopt Option A: Gateway-hosted indexer + plugin in-process fallback + catch-up on startup.**

The indexer is primarily a gateway responsibility (matches ADR-002 ownership of the `chunks` table). The plugin contains a **fallback** in-process worker that runs only when the gateway is unreachable, so the system still indexes when the gateway is down or not deployed.

**Both paths perform "catch-up on init":** when either the gateway boots or the plugin's `initialize()` runs, they scan for `turns where index_status='pending'` and resume work from where the previous run left off.

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Plugin sync_turn (in-process, every turn)                    │
│  1. Redact + JSONL + SQLite + QMD                            │
│  2. Mark turns.index_status='pending'                        │
│  3. (NO embedding/Qdrant here — keep capture path fast)      │
└───────────────────────┬──────────────────────────────────────┘
                        │
                        ▼ pending turns visible
        ┌───────────────────────────────────┐
        │ Indexer (chooses one of two paths │
        │ per the boot-time check)          │
        └────────┬──────────────────┬───────┘
                 │                  │
   Gateway up?   │                  │   Gateway down?
                 ▼                  ▼
  ┌─────────────────────┐   ┌─────────────────────────────┐
  │ Gateway-hosted      │   │ Plugin in-process worker    │
  │ asyncio worker      │   │ thread (fallback)           │
  │                     │   │                             │
  │ - Owns chunks table │   │ - Same algorithm            │
  │ - Polls every 5s    │   │ - Same retry logic          │
  │ - Batches up to 50  │   │ - Batches up to 20 (smaller │
  │ - Long-lived        │   │   to free agent process     │
  │                     │   │   memory faster)            │
  └─────────────────────┘   └─────────────────────────────┘
```

### Choice logic on plugin init

```python
def _start_indexer(self):
    if gateway_reachable(timeout=2s):
        # Trust the gateway. Plugin's role: just mark pending; gateway picks up.
        self.indexer_mode = "gateway"
        return  # no in-process worker
    else:
        # No gateway available. Spin up in-process worker.
        self.indexer_mode = "plugin"
        self._worker_thread = threading.Thread(target=self._index_loop, daemon=True)
        self._worker_thread.start()
```

The gateway is the **preferred** path. The plugin worker is the **fallback**. Importantly, **never both at once** — duplicate work + write contention. The mode is decided at init and stays until shutdown.

### Catch-up on startup

Both paths execute the same first step:

```python
def catchup():
    pending = sqlite.read("SELECT * FROM turns WHERE index_status='pending'")
    if pending:
        log.info(f"Indexer catch-up: {len(pending)} pending turns from prior runs")
        for batch in batches_of(pending, BATCH_SIZE):
            process_batch(batch)
```

After catch-up, normal polling proceeds.

### Shutdown / drain

On clean shutdown signals (`on_session_end` for the plugin, SIGTERM for the gateway), the indexer drains its current queue with a 30s cap. If it doesn't finish in 30s, leaves remaining turns as `pending` — next startup picks them up.

### Status tracking

`turns.index_status` is the source of truth:
- `pending` — captured but not indexed
- `indexing` — actively being processed (set at batch start, cleared at batch end)
- `indexed` — done
- `failed` — exceeded retry count; needs operator attention

`indexing` entries older than 5 minutes are considered stuck (crashed mid-batch) and reset to `pending` on next startup.

## Options Considered

### Option A: Gateway-primary + plugin fallback + catch-up on init — **Recommended**

(Description above.)

**Pros:**
- ✅ Respects ADR-002 ownership (gateway = `chunks` writer)
- ✅ Works without the gateway running (small dev setups, plugin-only mode)
- ✅ Catch-up on init = un-indexed turns are never silently lost
- ✅ Status column on `turns` is the only state we need — no separate queue infrastructure
- ✅ Easy to reason about: "gateway up = gateway does it; gateway down = plugin does it"
- ✅ Plugin-mode batch size is smaller (20 vs 50) to free agent-process memory faster
- ✅ Naturally idempotent: re-running on a `pending` row produces the same chunk via stable IDs

**Cons:**
- ❌ Two implementations of the same logic. **Mitigation:** put the actual indexer code in `memory_core.index.batch_index()` — both gateway and plugin call it. Only the polling loop differs.
- ❌ Need to detect gateway availability at plugin init time → adds a 2s HTTP HEAD probe to plugin startup. **Mitigation:** acceptable; happens once per session start, not per turn.

**Implementation effort:** ~2 days. Most of the code is in `memory_core.index`; the gateway and plugin each have ~30 lines of polling/worker-loop scaffolding.

### Option B: Always in-process (plugin thread only, no gateway)

**How it works:** The plugin always runs the indexer as a background thread. The gateway service doesn't have an indexer at all.

**Pros:**
- Simpler — one implementation
- No coordination question

**Cons:**
- ❌ When user quits the CLI, the indexer thread dies; pending turns from that session land but never get indexed until the user starts a new CLI session
- ❌ Indexing happens in the agent process, consuming memory the agent could use
- ❌ Violates ADR-002 — plugin writes to `chunks` (which the ADR says gateway owns)
- ❌ Long-running batches block agent shutdown (have to wait for the worker thread)

**Verdict:** rejected. CLI quit losing pending work is a real failure mode.

### Option C: Always in gateway (require gateway for any indexing)

**How it works:** The gateway is the only indexer. The plugin marks turns pending and does nothing else.

**Pros:**
- Cleanest mental model
- Indexer lifecycle decoupled from agent process

**Cons:**
- ❌ Requires gateway to be running for the system to be functional. The PRD allows a "plugin-only mode" for users who don't want/can't run the gateway.
- ❌ If gateway crashes and isn't restarted, indexing silently stops indefinitely

**Verdict:** rejected. The fallback path is worth the (small) code duplication.

### Option D: Separate systemd service (third process)

**How it works:** A dedicated `hermes-memory-indexer.service` runs continuously. Plugin and gateway both just write to SQLite.

**Pros:**
- Indexer fully isolated; can restart independently
- Single owner of the indexing logic

**Cons:**
- ❌ Three processes to manage instead of two
- ❌ Yet another systemd unit to install/configure
- ❌ Doesn't solve the "what if the indexer service is down" problem — still need fallback
- ❌ Over-engineered for one box

**Verdict:** rejected. Adds operational complexity without clear benefit.

## Consequences

### Positive

- Pending turns from a quit CLI session **always** get indexed eventually (next gateway tick or next CLI session start)
- Crash recovery is automatic via `index_status` tracking + catch-up on init
- ADR-002 ownership is respected (gateway is primary writer)
- Plugin-only deployment is supported (small dev setups)
- One algorithm (`memory_core.index.batch_index`), two callers — easy to test

### Negative

- The `index_status` state machine has 4 values to maintain (and `indexing` requires the stuck-row reset on startup)
- Need a deterministic gateway-reachable probe at plugin init (HTTP HEAD with 2s timeout)
- Two code paths to test: plugin-mode and gateway-mode (mitigated because the underlying algorithm is shared)

### Commitments

- Both indexer code paths use the same `memory_core.index.batch_index(pending_turns_batch)` function
- Catch-up runs at startup unconditionally (both paths)
- Stuck-row reset (`indexing` rows older than 5 min → `pending`) runs at startup
- `index_status` column has an index for fast `WHERE index_status='pending'` scans
- Integration tests cover: (1) gateway-mode normal operation, (2) plugin-fallback when gateway down, (3) catch-up after kill -9 during a batch, (4) re-running produces no duplicate Qdrant points

## Implementation pointer

Phase 3 Epic 3.2 (Embedding + Indexing Pipeline):

- Story 3.2.1 — `memory_core.index.batch_index()` (the shared algorithm)
- Story 3.2.2 — Plugin in-process worker thread + gateway-reachability probe
- Story 3.2.3 — Gateway-hosted asyncio worker
- Story 3.2.4 — Catch-up + stuck-row reset on init
- Story 3.2.5 — Integration tests (4 scenarios above)

## Open questions (post-decision)

- **What's the LMS embedding endpoint failure policy?** Recommendation: exponential backoff retry, max 5 attempts. After 5 failures, mark `index_status='failed'` and surface via dashboard metrics. Operator action: clear + re-process.
- **What if Qdrant collection schema changes mid-flight (e.g., dimension change)?** Out of scope for MVP. Embedding model is pinned to `text-embedding-nomic-embed-text-v1.5@f16` (768d) and the collection name includes the version. If we change models, we rebuild from raw (Plan §9 Scenario L).
- **Should the indexer batch by date/session for cache locality?** Future optimization. MVP processes in `turn_id` order. Revisit if profiling shows it's a bottleneck.

---

## David's approval

```
Approved by: David McCarty
Date:        2026-05-17
Comments:    Accepted as drafted.
```
