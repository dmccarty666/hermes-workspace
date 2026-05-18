# ADR 002: SQLite Writer Strategy (Plugin + Gateway Concurrency)

**Status:** **Accepted** ✅
**Date:** 2026-05-17
**Author:** hm-architect (draft) — David approved 2026-05-17
**Critique ref:** `docs/v0.2-critique.md` Issue 2
**Spec ref:** `TDD.md` §6.4, §14.1

---

## Context

The hermes-memory project has two distinct processes that need to write to `~/.hermes/memory/index/memory.sqlite`:

1. **The plugin (`hermes-local`)** — runs in-process inside `hermes` agent sessions. Triggered by every conversation turn. Writes via `sync_turn` capture path: inserts to `sessions`, `turns`, `raw_events`, and the QMD/JSONL files.

2. **The gateway service (`hermes-memory-gateway` FastAPI)** — runs as a long-lived systemd service. Hosts the dreamer (cron-triggered nightly), the migration script, and any future cross-agent / batch operations. Writes via `memory_write` / dreamer batch: inserts/updates `facts`, `decisions`, `open_questions`, `chunks`, `dream_runs`.

Both processes are concurrent. SQLite WAL mode allows concurrent reads but **only one writer at a time across processes**. The v0.2 TDD §6.4 said "they coordinate via in-DB advisory locks" — but the critique correctly noted SQLite has no native advisory locks and the design was hand-waved.

This ADR picks an explicit strategy. Getting it wrong = sporadic `SQLITE_BUSY` errors during nightly dreamer runs colliding with user CLI sessions; data loss is not at risk (SQLite is robust), but UX is (CLI stalls for 30s if the dreamer holds the writer).

## Decision (proposed)

**Adopt Option A: Process-pinned table ownership.**

Each table has one owning process. The other process may only read it. Cross-table reference integrity is preserved by stable IDs (UUIDs) and the JSON `source_refs_json` columns — no real foreign keys block writes.

**Plugin owns (writes):**
- `sessions`
- `turns`
- `raw_events`
- `audit_log` (plugin appends redaction events; gateway appends migration events — natural row-level isolation by `actor` column)

**Gateway owns (writes):**
- `chunks` (created by the async indexer; gateway hosts it)
- `chunks_fts` (synced by triggers when `chunks` updates)
- `facts`
- `entities`
- `fact_entities`
- `decisions`
- `open_questions`
- `dream_runs`
- `memory_banks`

**Both can read everything.** WAL mode allows it without contention.

**FTS5 shadow tables (`turns_fts`, `facts_fts`, `decisions_fts`) are owned by their parent table's owner**, synced via triggers (same connection, same transaction, no cross-process issue).

Connection settings (both processes):
- `journal_mode=WAL` (with fallback per `hermes_state.apply_wal_with_fallback`)
- `busy_timeout=30000` (30s — generous, catches genuine contention without UX-breaking stalls)
- `synchronous=NORMAL` (default for WAL; faster than FULL, safe on power loss because WAL is journaled)

## Options Considered

### Option A: Process-pinned table ownership — **Recommended**

**How it works:** Each process exclusively writes its own tables. Both can read all tables (WAL allows this concurrent-reads-with-one-writer model). Communication between processes is through *reading* the other process's tables — no shared write path.

**Pros:**
- ✅ Zero write contention by design — they don't touch the same tables
- ✅ Each process can use its own connection without thinking about coordination
- ✅ Natural mapping to the project's already-decided architecture: plugin = capture; gateway = derive
- ✅ Schema independence preserved (`audit_log` row-level separation by `actor` column)
- ✅ Easy to test: each process's tests use only its own tables
- ✅ Easy to reason about during postmortems: "did the plugin write this? then it owns this table."

**Cons:**
- ❌ FTS5 triggers fire on the table owner's INSERT/UPDATE/DELETE, so e.g. `chunks_fts` is only mutated when the gateway writes `chunks` — but the plugin needs `chunks_fts` for keyword search at read time. **Mitigation:** plugin reads `chunks_fts` (WAL allows it), it just doesn't write.
- ❌ If we later add a feature where the plugin needs to update a fact (e.g. `fact_feedback` tool with helpful/unhelpful), the plugin would need to call into the gateway via HTTP. **Mitigation:** `fact_feedback` is already designed to go through the gateway (TDD §5.2).

**Implementation effort:** Trivial. It's a discipline rule, not a code feature. Enforced by:
- Plugin code's `memory_core.store.sqlite` module never exposes write methods for gateway-owned tables to plugin callers
- Code review check during Phase 1 / Phase 4 / Phase 5

### Option B: Single-writer queue via Unix socket

**How it works:** A dedicated writer process owns the SQLite connection. Plugin and gateway both POST writes to a Unix socket; the writer serializes them. Reads stay direct.

**Pros:**
- Centralized write path → easier to add cross-table consistency checks
- No table-ownership rules to remember
- Could batch writes for throughput

**Cons:**
- ❌ Significant new component: a third long-lived process, lifecycle management, restart-on-crash, etc.
- ❌ Plugin (in-process) suddenly has a transport hop for every `sync_turn` — adds latency
- ❌ Plugin must handle "writer socket down" gracefully → adds reconnect logic + buffering
- ❌ Over-engineered for our 1-writer-per-table needs

**Verdict:** Right pattern for a larger / multi-machine system. Massive overkill for one-box, two-process MVP.

### Option C: Accept the contention; rely on `busy_timeout`

**How it works:** Both processes write to all tables freely. Set `busy_timeout=30000`. When SQLite returns SQLITE_BUSY, the calling process waits up to 30s. With WAL, contention is rare anyway.

**Pros:**
- Simplest possible. Zero coordination.
- WAL makes the actual collision window tiny (<1ms for a row insert)

**Cons:**
- ❌ During a multi-minute dreamer run, the user's CLI could stall up to 30s if the dreamer holds the writer
- ❌ Failure mode is hard to reproduce in tests (timing-dependent)
- ❌ Doesn't surface the architectural intent — feels like we're "tolerating bugs"
- ❌ User-facing latency surprises are exactly the kind of paper cut that erodes trust in the system

**Verdict:** good for one-process scenarios. Bad for our specifically-two-processes design.

### Option D: SQLite-side per-table BEGIN IMMEDIATE locks

**How it works:** Every write wraps in `BEGIN IMMEDIATE; ... ; COMMIT;` which acquires the writer lock immediately rather than waiting for the first INSERT. This forces serialization without changing the schema.

**Pros:**
- Pure SQLite mechanics; no new infrastructure
- Honest about contention (fails fast)

**Cons:**
- ❌ Equivalent to Option C with a different stall pattern (fails immediately vs waits)
- ❌ Doesn't solve the architectural question of "who owns what"
- ❌ Still leaves the dreamer holding the lock for the whole batch

**Verdict:** mechanic, not a strategy. Combine with A or B if anything.

## Consequences

### Positive

- Plugin and gateway have zero write-contention scenarios in the MVP design
- Both processes can use simple `sqlite3.connect()` without coordination layers
- Architecture matches mental model: capture-side vs. derive-side, with reads being unrestricted
- Tests stay isolated: each module tests its own tables
- Onboarding new contributors: "you only write the tables your process owns" is a one-sentence rule

### Negative

- Discipline-based, not code-enforced. A careless commit could break the invariant (mitigated by code review).
- The `fact_feedback` tool, even when called from the plugin's tool dispatch, must call the gateway's HTTP API to write — a small extra hop.
- If we ever add a feature where the plugin needs to write a gateway-owned table directly, we need to revisit (likely → add an in-process call path through `memory_core`).

### Commitments

- All `memory_core.store.sqlite` write methods are organized into two namespaces: `capture.*` (plugin-callable) and `derive.*` (gateway-callable). Plugin imports only `capture`; gateway can import both.
- Code review checklist for any SQL write: "does the calling process own this table per ADR-002?"
- Integration test (Phase 6): start dreamer batch, kick off plugin `sync_turn` in parallel — assert no `SQLITE_BUSY` errors for either.
- Connection settings (WAL, busy_timeout=30000) applied consistently in `memory_core.store.sqlite.connect()`.
- If we ever add a write path that crosses the ownership boundary, we file a new ADR.

## Implementation pointer

Phase 1 Story T-003 (SQLite schema + migrations) — connection settings + table comments.
Phase 1 Story T-007 (capture pipeline) — plugin writes only `capture.*` namespace.
Phase 5 Story for dreamer worker — gateway writes only `derive.*` namespace.

## Open questions (post-decision)

- **What about manual `sqlite3` CLI usage by humans?** Out of band. Humans can write anything; just don't run a manual migration during a dreamer run.
- **What if both processes need to update `audit_log` concurrently?** Each appends with its `actor` column (plugin / gateway / migration / cron). Concurrent appends to an append-only table is fine in WAL mode. No collision possible.
- **What about the migration script (from-holographic)?** Runs once, with `actor='migration'`. Gateway-style writer, but explicit one-shot — no contention because it's a single-process foreground operation.

---

## David's approval

```
Approved by: David McCarty
Date:        2026-05-17
Comments:    Accepted as drafted.
```
