# ADR 001: Narrative Thread `/new` Injection Mechanism

**Status:** **Accepted** ✅
**Date:** 2026-05-17
**Author:** hm-architect (draft) — David approved 2026-05-17
**Critique ref:** `docs/v0.2-critique.md` Issue 1
**Spec ref:** `TDD.md` §9.2, §15.1; `Plan.md` Phase 5 Epic 5.1

---

## Context

The hermes-memory project includes a "narrative thread" — a per-session `SESSION-THREAD/{session_id}.md` file with the rolling 5-exchange working memory. On `/new`, `/resume`, `/branch`, or post-context-compression, the prior session's thread content should be injected into the new session so the agent can pick up where it left off ("…last session you were debugging T-007 redaction; want to continue?").

The current holographic plugin attempts this via `system_prompt_block()`. **It doesn't work on `/new`.** Root cause is documented in TDD §9.2:

- `AIAgent._cached_system_prompt` is built once at agent init
- It is only invalidated during context compression (`run_agent.py:10305`)
- `/new` rotates `session_id` and fires `on_session_switch(reset=False)`, which correctly populates the plugin's `_nt_prev_content`
- But the cached system prompt is **not** rebuilt — so `system_prompt_block()` is never called again
- Result: prior context is loaded into the plugin but never reaches the model

Recent fix attempt (`commit 84881393d` 2026-05-16) changed `/new` to pass `reset=False`. The fix was correct but insufficient — the cache invalidation gap remained.

The hermes-memory plugin needs a working injection path before Phase 5 of the build can land. This ADR decides how.

## Decision (proposed)

**Adopt Option A: User-message injection.**

On `on_session_switch(reset=False, parent_session_id, new_session_id)`, the plugin:

1. Reads `~/.hermes/SESSION-THREAD/{parent_session_id}.md`
2. Constructs an injection message with the prior content + a short directive ("Briefly note what you found above from the last session and ask if there's anything to continue")
3. Prepends it as a `{"role": "user", ...}` entry to `AIAgent.conversation_history` via a stored agent reference

This bypasses the cached-system-prompt limitation entirely. The injection looks to the model like a natural turn-1 user message ("here's our context, what now?"). The agent's response is naturally conversational.

## Options Considered

### Option A: User-message injection — **Recommended**

**How it works:** Inject the prior thread content as a `{"role": "user", ...}` message at index 0 of `conversation_history` during `on_session_switch`.

**How the plugin gets `agent_ref`:**

- Sub-option A1 (preferred): on `MemoryProvider.initialize(session_id, **kwargs)`, look for `kwargs.get('agent_ref')` or `kwargs.get('agent_instance')`. If present, store it. Submit a tiny upstream Hermes PR to add `agent_ref=self` to the kwargs passed to providers. Backwards-compatible (extra kwarg). Risk: PR merge time.
- Sub-option A2 (fallback if A1 unavailable): read `inspect.currentframe().f_back` from within `on_session_switch` to walk up to the calling `MemoryManager`, which holds `self._agent`. Fragile but works without core changes.
- Sub-option A3 (last resort): if `agent_ref` can't be obtained, call `agent._invalidate_system_prompt()` reflectively + use the existing `system_prompt_block()` path. Fragile but Hermes-only.

**Pros:**
- ✅ Bypasses the cached-system-prompt problem entirely
- ✅ Reads as a natural conversation start to the model — no awkward "system context update"
- ✅ Survives context compaction naturally (the injected message gets summarized with the rest)
- ✅ Prompt cache stays warm (we don't invalidate the cached system prompt)
- ✅ Pattern is portable to other clients (TUI, Telegram) without per-client special casing
- ✅ Integration-testable end-to-end (Plan.md §9 Scenario J)

**Cons:**
- ❌ Needs access to `conversation_history`. The current `MemoryProvider` ABC doesn't pass `agent_ref`. Three sub-options for this (above), of which A1 is best.
- ❌ Sub-option A2 (reflection fallback) is fragile to Hermes internal restructuring
- ❌ One injected user message counts toward the conversation budget (typically ~500 tokens — negligible)

**Implementation effort:** ~half a day, all in the plugin. The injection logic itself is ~30 lines.

### Option B: System-prompt invalidation

**How it works:** In `on_session_switch(reset=False)`, call `agent._invalidate_system_prompt()` reflectively. Hermes rebuilds the prompt on the next turn, including the freshly-populated `system_prompt_block()`.

**Pros:**
- Uses the existing `system_prompt_block()` plumbing
- No new ABC changes needed
- Smaller diff than Option A

**Cons:**
- ❌ Relies on `_invalidate_system_prompt()` being a stable API (it's an underscore method — by convention, private)
- ❌ Forces full system-prompt rebuild on every `/new` — breaks upstream prompt caching (significant cost on long projects)
- ❌ The injected content lives in the system prompt, which is a less natural place for "let me tell you what we were doing last time"
- ❌ Doesn't solve the post-compaction case as cleanly (compaction has its own invalidation already; double-invalidating is wasteful)
- ❌ Reflection-on-private-method is exactly the kind of thing that breaks silently on Hermes upgrade

### Option C: Upstream Hermes change — add `agent_ref` to `MemoryProvider.initialize` kwargs

**How it works:** PR to Hermes that adds `agent_ref=self` to the kwargs in `MemoryManager._init_provider()`. Documented as part of the public ABC. Then plugin uses it cleanly (Option A1).

**Pros:**
- ✅ Cleanest possible long-term solution
- ✅ No reflection, no private-method access
- ✅ Makes future plugin authors' lives easier
- ✅ Tiny PR (additive kwarg, no behavioral change)

**Cons:**
- ❌ Calendar dependency — PR review/merge time (could be days to weeks)
- ❌ Blocks our Phase 5 if PR doesn't merge before we get there

**Verdict:** worth filing AT THE START OF PHASE 1 (not Phase 5) so it has time to merge. Combine with Option A2 fallback in the meantime.

### Option D: Don't fix; document narrative thread as "broken on /new"

**Verdict:** rejected. The narrative thread is a stated MVP goal (G7 in PROJECT.md). Shipping with this broken would be a hidden regression versus the holographic provider's current (broken-but-known) behavior.

## Consequences

### Positive

- Phase 5 of the build can land with confidence
- Acceptance test Plan.md §9 Scenario J (`/new` references prior session) becomes pass-able
- Future plugin authors get a clear pattern for injection-needing providers
- Hermes upstream may benefit if the PR (Option C) is merged

### Negative

- We carry a small risk that the `agent_ref` access path stays on the fragile A2 fallback
- The plugin has a dependency on internal Hermes APIs (`agent.conversation_history`) — must be tested against Hermes' major version pins

### Commitments

- Plugin code must include all three sub-option fallbacks (A1 → A2 → A3) with clear logging when each tier is used
- Integration test (Plan.md §9 Scenario J) **must** pass before Phase 5 closes
- File the upstream PR (Option C) by end of Phase 1
- If C merges: simplify the plugin's injection logic and drop the A2/A3 fallbacks in a Phase 6 hardening story

## Implementation pointer

Lands as part of Plan.md Phase 5 Epic 5.1 ("Narrative Thread Port + /new Injection Fix"). Specific stories:

- T-PHASE5-narrative-thread-port (port file format + rolling window from holographic)
- T-PHASE5-narrative-thread-inject (the fix per this ADR — Option A with three sub-option fallbacks)
- T-PHASE5-narrative-thread-test (Plan.md §9 Scenario J integration test)

A separate, parallel story files the upstream Hermes PR.

## Open questions (post-decision)

- **What's the budget for the injected user message?** Recommendation: cap at 4000 chars (the same default as `memory_recent_context`). Adjust if early Phase 5 testing shows it's not enough or too much.
- **Should the injection include the prior session's commits / kanban activity?** Out of scope for MVP. Just the SESSION-THREAD content.

---

## David's approval

Sign here once you approve this decision:

```
Approved by: David McCarty
Date:        2026-05-17
Comments:    Accepted as drafted.
```
