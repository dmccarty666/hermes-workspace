# Kanban Operations — Hermes Local Memory

> Operational playbook for running the hermes-memory project through Hermes Kanban.
> Authored: 2026-05-17 (v0.2 design).
> Companion to: `PROJECT.md`, `Plan.md`, `souls/hm-*.md`.

---

## TL;DR

We run the hermes-memory build through Hermes Kanban with 5 specialist profiles. The dispatcher (gateway-embedded) auto-spawns workers per task. You drive sprints with one `/goal` per phase, review high-risk work via `kanban_block(reason='review-required: ...')`, and walk away the rest of the time.

```
PROJECTS/hermes-memory/   ← project state (PRD, TDD, Plan, TASKLIST)
                          ← decisions live as ADRs in docs/adr/
                          ← SOULs source-controlled here in souls/

~/.hermes/profiles/hm-*/  ← runtime profile homes (SOULs installed here)
~/.hermes/kanban.db       ← board state (survives crashes)
~/.hermes/kanban/         ← per-task workspaces
~/.hermes/hermes-agent/   ← code under construction
```

---

## 1. Roles & Profiles

| Profile | Role | Model | Endpoint | What they do |
|---|---|---|---|---|
| `hm-orchestrator` | **Loop driver, state machine, escalator** | `unsloth/Qwen3.6-27B-NVFP4` | Local Spark2 (`192.168.2.105:1234`) | Cron heartbeat every 30 min; reads goal+state, drives phase progression, escalates to David |
| `hm-planner` | Decomposer | `openrouter/minimax/minimax-m2.7` | OpenRouter (paid) | Read Plan.md, create cards with parents/AC/DoD |
| `hm-architect` | Designer | `unsloth/Qwen3.6-27B-NVFP4` | Local Spark2 (`192.168.2.105:1234`) | Write tech specs, ADRs, schema diffs |
| `hm-developer` | Implementer | `openrouter/minimax/minimax-m2.7` | OpenRouter (paid) | Write code + tests, TDD-style |
| `hm-qa` | Verifier | `unsloth/Qwen3.6-27B-NVFP4` | Local Spark2 (`192.168.2.105:1234`) | Run tests, check AC, approve/reject |
| `hm-docs` | Historian | `unsloth/Qwen3.6-27B-NVFP4` | Local Spark2 (`192.168.2.105:1234`) | Update TASKLIST/EPICS/CHANGELOG after qa approval |

**Initial test-bed configuration:** MiniMax for planner + developer (the two roles where reasoning quality drives downstream throughput the most), Qwen3.6-35B local for the other three (anchor design/verification/docs work on free local inference).

This is an experiment — if planning/dev quality is great on MiniMax but the cost adds up, or if Qwen3.6 handles QA/architect work as well as MiniMax, we'll consolidate toward local. Models are swappable mid-project via `hermes -p <profile> model <name>` — no SOUL changes needed.

**Each profile lives at `~/.hermes/profiles/hm-<role>/`** with its own `SOUL.md`, `config.yaml`, `.env`, `memories/`, etc.

---

## 2. One-Time Setup (Sprint 0)

### 2.1 Create the profiles

```bash
# From hermes-agent checkout
cd ~/.hermes/hermes-agent

# Create all 6 profiles (including the orchestrator). We clone configuration
# from `default` so each profile inherits the gateway/Qdrant/LMS endpoints;
# we then install custom SOULs.
hermes profile create hm-orchestrator --clone
hermes profile create hm-planner      --clone
hermes profile create hm-architect    --clone
hermes profile create hm-developer    --clone
hermes profile create hm-qa           --clone
hermes profile create hm-docs         --clone
```

### 2.2 Install the SOULs

The SOULs are source-controlled in `~/.hermes/PROJECTS/hermes-memory/souls/`. Install them into each profile's home:

```bash
cd ~/.hermes/PROJECTS/hermes-memory
scripts/install-souls.sh
```

After installation:

```bash
ls -l ~/.hermes/profiles/hm-developer/SOUL.md
# -rw-r--r-- 1 dmccarty dmccarty 17433 May 17 ... SOUL.md
```

Re-run the install script any time a SOUL is updated in `PROJECTS/hermes-memory/souls/` — it overwrites the per-profile copies.

### 2.3 Configure per-profile models

Each profile inherits the default model. Override per role per the test-bed plan (§1):

```bash
# Orchestrator runs constantly — use local Qwen3.6 to avoid burning tokens on heartbeats
hermes -p hm-orchestrator model unsloth/Qwen3.6-27B-NVFP4 --provider lms_spark2

# MiniMax (paid OpenRouter) for the two reasoning-heaviest roles
hermes -p hm-planner   model openrouter/minimax/minimax-m2.7
hermes -p hm-developer model openrouter/minimax/minimax-m2.7

# Qwen3.6-35B (local Spark2 @ .105:1234) for the rest — free per token
hermes -p hm-architect model unsloth/Qwen3.6-27B-NVFP4 --provider lms_spark2
hermes -p hm-qa        model unsloth/Qwen3.6-27B-NVFP4 --provider lms_spark2
hermes -p hm-docs      model unsloth/Qwen3.6-27B-NVFP4 --provider lms_spark2
```

(Provider flags assume `lms_spark2` is already configured as a provider in `~/.hermes/config.yaml` for `192.168.2.105:1234`. If it's not yet, set `base_url` per the existing `lms_spark` pattern in your config.)

Per-profile model overrides are inheritable: re-running `hermes -p <profile> model <name>` later swaps the model without touching the SOUL.

### 2.4 Verify

```bash
hermes profile list

# Expected:
# Profile          Model                        Gateway      Alias
# ────────────     ───────────────────────────  ─────────    ────────
# default          nvidia-nemotron-3-super-12   running      —
# hm-planner       minimax-m2.7                 -            —
# hm-architect     minimax-m2.7                 -            —
# hm-developer     Nemotron-3-Super-120B        -            —
# hm-qa            qwen3.6-35b                  -            —
# hm-docs          minimax-m2.7                 -            —

# Confirm SOUL.md auto-loads:
hermes -p hm-developer chat -q "Who are you, in 1 line?"
# Expected: response self-identifies as hm-developer
```

### 2.5 Ensure dispatcher is running

```bash
hermes config get kanban.dispatch_in_gateway
# Expected: true (default)

hermes gateway status
# Expected: running

hermes kanban
# Expected: empty board or whatever's there
```

### 2.6 Resolve the three critique high-severity items (ADRs)

Before the first sprint, write three ADRs in `docs/adr/` (the critique calls these out as resolve-before-Sprint-1):

- `docs/adr/001-narrative-thread-injection.md` — how the plugin obtains conversation_history access
- `docs/adr/002-sqlite-writer-strategy.md` — process-pinned writes vs single-writer queue
- `docs/adr/003-indexer-process-model.md` — plugin worker thread + gateway fallback, catch-up on init

These are short (~1 page each). The user (David) authors them; hm-planner refers to them when creating Phase 1 cards.

---

## 3. Daily / Per-Sprint Operating Model

### 3.1 Kick off a sprint (= one Plan.md phase)

From an interactive CLI session as a hm-planner:

```bash
hermes -p hm-planner chat
```

In the CLI:

```
/goal land hermes-memory Phase 1 (capture + redaction) per Plan.md §3
```

Walk away. The session runs the planner profile, which:

1. Reads PROJECT.md / Plan.md / EPICS.md / docs/v0.2-critique.md / docs/adr/
2. Decomposes Phase 1 into the cards Plan.md prescribes (T-001..T-010)
3. Creates each card via `kanban_create()` with the right `parents=[...]`
4. Posts a decomposition report
5. (Optional) Creates a phase-gate card

The `/goal` judge cycle keeps the planner working until the decomposition is done or the turn budget is exhausted (default ~25 turns — usually enough for a phase's planning).

### 3.2 Workers pick up cards automatically

The gateway-embedded dispatcher polls `kanban.db` and spawns workers:

```
T-001 (hm-developer)  →  hermes -p hm-developer chat -q "work kanban task t_<id>"
T-006 (hm-developer)  →  spawned in parallel (no parent)
T-007 (hm-developer)  →  blocked, waiting on T-006 (parent gate)
```

You see this happen via:

```bash
hermes kanban           # board overview
hermes kanban tail <id> # follow a specific task's worker log
```

### 3.3 Review-required interrupts

When a hm-developer hits a risky-work block (schema, redaction, narrative thread, migration — per SOUL.md §7), they end with:

```
kanban_block(reason="review-required: <one-line>")
```

You see these in the board. When you have time:

```bash
hermes kanban show <task_id>     # full diff + summary + commits
hermes kanban tail <task_id>     # last worker output
git -C ~/.hermes/hermes-agent log --oneline -10 | head
git -C ~/.hermes/hermes-agent diff HEAD~3..HEAD
```

Decide:

- **Approve + resume:**
  ```bash
  hermes kanban comment <task_id> "looks good — approving"
  hermes kanban update <task_id> --status ready
  # dispatcher respawns worker; it continues to kanban_complete
  ```

- **Request changes:**
  ```bash
  hermes kanban comment <task_id> "needs: change X to Y because Z"
  hermes kanban update <task_id> --status ready
  # dispatcher respawns; worker re-reads comments via kanban_show, addresses them
  ```

- **Reject + abandon:**
  ```bash
  hermes kanban comment <task_id> "wrong approach — abandoning, will respec"
  hermes kanban update <task_id> --status blocked
  # Then create a follow-up planning task to revisit
  ```

### 3.4 QA approvals close stories

When hm-qa approves a story, the qa task hits `done`, which auto-promotes the next dependent card (e.g. a hm-docs card with `parents=[qa_task_id]`) to `ready`. hm-docs picks it up, updates TASKLIST.md / EPICS.md / CHANGELOG.md.

### 3.5 Phase gate closes the sprint

When the phase-gate card (assigned to hm-qa) hits `done`, the phase is officially closed. The next sprint can begin.

---

## 4. Daily Touchpoints (for the human — David)

| Frequency | Action |
|---|---|
| Once or twice a day | `hermes kanban` — see what's running/blocked |
| When a `review-required` block appears | Inspect diff, approve or request changes |
| When an escalation block appears | Read reason, decide course of action (unblock with context, or pause work pending decision) |
| End of week | Read `TASKLIST.md` Done section to see what landed |
| After a phase gate closes | Skim the phase's commits + CHANGELOG.md entry |

If you go a day without touching anything, the worst case is that one review-required task sits idle. Everything else keeps running.

---

## 5. Operating Rules of Thumb

### When to use Kanban vs `/goal` vs direct chat

| Situation | Use |
|---|---|
| Whole sprint / phase | `/goal` in a planner CLI session → Kanban runs |
| Single complex card I want to drive to done now | `/goal` in a developer CLI session on the specific task |
| Quick question, no execution | Direct chat — don't manufacture a card |
| Code review | Just open the diff, no card needed |
| Investigating a stuck worker | Direct chat / `hermes kanban tail` |

### When to spawn a sub-card vs do it inline

Inside a hm-developer or hm-architect task, if you discover new work:

- **Sub-card** (`kanban_create(parents=[your_task_id])`) — when the new work has its OWN AC, must be done before yours, and is meaningfully separate
- **kanban_comment(content='followup: ...')** — when it's a future improvement, not blocking yours
- **Inline (in scope)** — never. Stay in scope. If it touches your task's AC, it was always yours; if it doesn't, it's a follow-up.

### When to override a SOUL

You shouldn't, normally. SOULs are source-controlled in `PROJECTS/hermes-memory/souls/`. If a SOUL is wrong:

1. Edit it in `PROJECTS/hermes-memory/souls/`
2. Re-run `scripts/install-souls.sh`
3. Future workers spawn with the updated SOUL

Don't edit `~/.hermes/profiles/hm-*/SOUL.md` directly — those are installed copies.

---

## 6. Common Operational Tasks

### Reset / restart a stuck task

```bash
# See current state
hermes kanban show <task_id>

# Force-reclaim (kills worker, resets task to ready)
hermes kanban reclaim <task_id>
```

### Reassign to a different profile

```bash
# E.g. a planner task accidentally created with assignee=default
hermes kanban reassign <task_id> hm-planner --reclaim
```

### Inspect what a worker actually did

```bash
# Live tail
hermes kanban tail <task_id>

# Past runs
hermes kanban runs <task_id>

# Logs (per-worker)
ls ~/.hermes/kanban/logs/
```

### Skip a card / move it directly

```bash
# Mark done manually (only if work was done out-of-band)
hermes kanban update <task_id> --status done
hermes kanban comment <task_id> "manually completed: <reason>"
```

### Pause all work (e.g., before a Hermes upgrade)

```bash
# Stop the gateway (dispatcher dies with it)
hermes gateway stop

# Or pause individual cards
hermes kanban update <task_id> --status blocked
hermes kanban comment <task_id> "paused: <reason>"
```

When you bring the gateway back up, ready cards resume.

### See the entire dependency graph

```bash
hermes kanban graph  # if available; else:
sqlite3 ~/.hermes/kanban.db \
  "SELECT t.task_id, t.title, t.status, t.assignee,
          GROUP_CONCAT(d.parent_task_id) AS parents
   FROM tasks t
   LEFT JOIN task_deps d ON d.child_task_id = t.task_id
   GROUP BY t.task_id;"
```

---

## 7. Failure Modes & Recovery

### Worker hallucinated `created_cards=[...]`

The dispatcher's validator blocks the completion; the task is flagged with a ⚠ badge in the dashboard.

- Read `hermes kanban audit <task_id>` for the event trail
- Reclaim, fix the prompt (or worker model), respawn

### Worker keeps blocking on the same thing

3+ rejections from hm-qa on the same task = process problem, not a worker problem.

- Read the qa comments carefully
- Either: (a) the AC is wrong → escalate to hm-planner to fix Plan.md; (b) the worker model is the wrong fit → switch model via `hermes -p hm-developer model <other>`; (c) the SOUL guardrail is too loose → tighten SOUL.md and re-install

### `force_no_redact` snuck into code

QA SOUL rejects on sight. If it landed anyway:

- Pull the commit, revert it
- Add a regression test that fails if `force_no_redact` appears in any source file
- Hardenthe SOUL further if the worker had a plausible-sounding reason

### SQLite locked errors during 3am cron

Cron dreamer competing with plugin writes (see critique Issue 2):

- Confirm ADR-002 (process-pinned writes) is implemented
- If still racing: set `busy_timeout=30000` in `memory_core.store.sqlite` connection setup
- If still racing: shorten dream batches (`dreamer.max_turns_per_batch` from 500 → 100)

### Plan.md drifted from reality

hm-docs flagged drift via `kanban_comment(content='doc-drift: ...')`. The user (David) updates Plan.md, then a fresh hm-planner task can re-decompose anything affected.

---

## 8. What This Buys You (the self-sufficiency promise)

Once Sprint 0 is done:

- **Walk-away-able:** kick off `/goal "land Phase 1"` in a planner CLI session, close the terminal, come back tomorrow. Gateway dispatcher kept running, cards got processed, review-required blocks waiting for you.
- **Crash-survivable:** Hermes restarts, machine reboots, the queue is intact in SQLite.
- **Audit trail forever:** every spawned worker, every comment, every run attempt persists in `kanban.db`. Six months from now, you can answer "why did we choose Option A for narrative thread injection" by reading the comment thread on the planning card or the ADR.
- **Parallel where it can be:** independent cards fan out across two workers simultaneously (Plan.md story dependencies enforced by `parents=[...]`).
- **One-message rescue:** a comment on a stuck card unblocks it. You don't have to remember context — the SOUL + Plan.md + parent handoff is everything the worker needs.
- **SOUL discipline:** workers literally cannot push to remote, mock internal modules, or skip redaction tests. The guardrails are baked in.

---

## 10. The Orchestrator (Ralph loop) — autonomous build driver

The `hm-orchestrator` profile is what turns this from "manually kick off each phase" into "set a goal, walk away for weeks." It runs every 30 min via cron, reads the project state, and drives the build forward one tiny action at a time.

**Critical safety property:** the orchestrator never does work itself, never writes code, never auto-approves human gates. It coordinates and escalates. Workers do the work. You make the decisions.

### 10.1 What it does (in one paragraph)

Every 30 minutes, a fresh `hermes -p hm-orchestrator` process spawns from cron. It loads its SOUL (the state machine), reads `orchestrator/GOAL.md` and `orchestrator/STATE.md`, looks at the kanban board, and takes **at most one primary action**: bootstrap the first planner task, advance to the next phase when a gate hits done, reclaim a stuck worker (once), or notify David via telegram for anything that requires human input. It updates `STATE.md` and `HISTORY.md`, removes its lock file, and exits. Most ticks do nothing — that's the healthy outcome.

### 10.2 State machine (summary)

See `souls/hm-orchestrator.md` §3 for the full state machine. High level:

```
IDLE → BOOTSTRAP → PHASE_1_PLANNING → PHASE_1_RUNNING → PHASE_1_DONE
                                                              ↓
                                                       PHASE_2_PLANNING
                                                              ↓
                                                            ...
                                                              ↓
                                                       PHASE_6_DONE → GOAL_ACHIEVED
                                                                          ↓
                                                                      cron self-disables
```

Side states (active in parallel): `BLOCKED_ON_REVIEW`, `BLOCKED_ON_DECISION`, `STUCK_WORKER`, `HALLUCINATION_FLAG`, `DRIFT_DETECTED`.

### 10.3 Files the orchestrator owns

```
~/.hermes/PROJECTS/hermes-memory/orchestrator/
├── GOAL.md         ← you (David) edit; orchestrator READ ONLY
├── STATE.md        ← orchestrator reads + writes every tick
├── HISTORY.md      ← append-only audit log
├── heartbeat.log   ← raw cron output (auto-managed by script)
└── .lock           ← single-tick mutex (auto-managed by script)
```

`GOAL.md` is the contract. Edit it to pause/resume/end the build. `STATE.md` is the current state machine snapshot. `HISTORY.md` is the audit trail.

### 10.4 Enabling the orchestrator (Sprint 0 step)

After running Steps 2.1–2.4 of this runbook (profiles created, SOULs installed, models set), you enable the orchestrator:

```bash
# 1. Make sure all 7 readiness items in orchestrator/STATE.md are checked off:
#    - all 6 profiles created
#    - SOULs installed
#    - models set
#    - gateway running
#    - 3 ADRs authored (docs/adr/001-*.md, 002-*.md, 003-*.md)
#    - GOAL.md status: Active (it already is, by default)

# 2. Smoke-test one heartbeat manually:
cd ~/.hermes/PROJECTS/hermes-memory
./scripts/orchestrator-heartbeat.sh --dry-run
# Expected: "Would run: hermes -p hm-orchestrator chat -q '<prompt>' (timeout=900s)"

# 3. Run a real tick (manual, will not bootstrap if GOAL.md isn't set to Active
#    and Sprint 0 checklist isn't complete):
./scripts/orchestrator-heartbeat.sh --verbose
# Watch heartbeat.log for the tick's output.

# 4. After the manual tick succeeds cleanly, register the cron job. Use Hermes' own
#    cronjob() tool for managed lifecycle:
hermes -p default chat -q '
Create a cronjob:
  name: hermes-memory-orchestrator
  schedule: */30 * * * *
  script: ~/.hermes/PROJECTS/hermes-memory/scripts/orchestrator-heartbeat.sh
  no_agent: true
  deliver: local
'

# OR — if you prefer system cron over hermes cronjob:
crontab -e
# Add line:
*/30 * * * * /home/dmccarty/.hermes/PROJECTS/hermes-memory/scripts/orchestrator-heartbeat.sh
```

### 10.5 Watching it run

```bash
# Tail the heartbeat log
tail -f ~/.hermes/PROJECTS/hermes-memory/orchestrator/heartbeat.log

# See what the orchestrator thinks the state is
cat ~/.hermes/PROJECTS/hermes-memory/orchestrator/STATE.md

# See every action it's ever taken
tail -100 ~/.hermes/PROJECTS/hermes-memory/orchestrator/HISTORY.md

# See cronjob status
hermes -p default chat -q "List my cron jobs"
```

### 10.6 Pausing / stopping the orchestrator

Three ways to stop it, from least to most permanent:

**Pause via GOAL.md** (orchestrator-aware):
Edit `orchestrator/GOAL.md`, set the front matter `Status: Paused`. Next tick will see this and heartbeat without acting. Resume by changing back to `Status: Active`.

**Pause the cron** (orchestrator-blind):
```bash
hermes -p default chat -q "Pause cronjob hermes-memory-orchestrator"
```
The script never runs. State files remain. Resume with `cronjob action='resume'`.

**Remove the cron** (clean shutdown):
```bash
hermes -p default chat -q "Remove cronjob hermes-memory-orchestrator"
```
Used at GOAL_ACHIEVED automatically. You can also do it manually.

### 10.7 The telegram escalation contract

When the orchestrator pings you on telegram, the message has this shape:

```
[hm-orchestrator] <urgency>: <one-line summary>

Project: hermes-memory
State: <current state>
Issue: <specific issue>

Card: <task_id> (<title>)
Last action by worker: <last comment summary>
Last heartbeat: <when>
Worker: <profile name>

Suggested next step:
  hermes kanban tail <id>

Auto-action taken: <none / reclaimed / archived / etc>
```

Urgency tags govern your response time:

| Urgency | Meaning | Your response time |
|---|---|---|
| `routine` | review-required >24h, gentle nudge | when convenient |
| `attention` | stuck worker reclaimed, ADR needed, plan revision requested | within a day |
| `urgent` | hallucination warning, drift, repeated worker failure | within hours |
| `critical` | schema-independence violation, secrets in stored data, kanban DB corruption | immediately |

### 10.8 Common operator interactions

**Approve a `review-required` block the orchestrator pinged you about:**
```bash
# Inspect first
hermes kanban show <task_id>
git -C ~/.hermes/hermes-agent diff HEAD~3..HEAD

# Then approve
hermes kanban comment <task_id> "Approved by David — looks good."
hermes kanban unblock <task_id>
```

**Reject + request changes on a `review-required` block:**
```bash
hermes kanban comment <task_id> "Requested changes: <what>"
hermes kanban unblock <task_id>   # worker respawns, reads comment, addresses
```

**Author an ADR the orchestrator says is needed:**
```bash
# The ADR file goes at docs/adr/00X-<topic>.md
$EDITOR ~/.hermes/PROJECTS/hermes-memory/docs/adr/004-<topic>.md

# Then unblock the blocked planning/architect task
hermes kanban comment <task_id> "ADR-004 authored. Proceed."
hermes kanban unblock <task_id>
```

**Stop everything (emergency):**
```bash
# Pause cron
hermes -p default chat -q "Pause cronjob hermes-memory-orchestrator"

# Block in-flight cards
hermes kanban ls --status running --status ready | awk '{print $1}' | xargs -I{} hermes kanban block {} "Emergency pause by David"

# Stop the gateway dispatcher (kills any active workers)
hermes gateway stop
```

### 10.9 Failure modes — what to watch for

| Symptom | Likely cause | What to do |
|---|---|---|
| `heartbeat.log` shows ticks but `HISTORY.md` unchanged | Orchestrator can't write the file, or model is returning empty responses | Check file perms, run a manual `--verbose` tick |
| Same review-required ping fires every 24h, never approved | You forgot — by design | Approve or escalate to "this is stuck, change the approach" |
| STATE.md says PHASE_2_RUNNING but no Phase 2 cards on board | DRIFT_DETECTED — orchestrator should be escalating | Read HISTORY.md to see what happened |
| Cron not running at all | Cron service down, or cronjob was paused | `hermes cronjob list` or check `crontab -l` |
| Two ticks colliding (rare) | Lock file mechanism caught it; logs will say "skipped (lock held)" | Should not require action |
| Orchestrator looping or thrashing | Model degraded, prompt drift, or model timing out | Pause via GOAL.md Status=Paused; inspect heartbeat.log + HISTORY |

### 10.10 The "always escalate, never decide" rule

The single most important property of `hm-orchestrator` is its self-restraint. The SOUL is explicit:

- It **never** auto-approves a `review-required` block — that's a human decision
- It **never** auto-approves a phase gate — that requires qa to have signed off, which the orchestrator only observes
- It **never** writes an ADR — that's a human decision
- It **never** modifies Plan.md / PRD.md / TDD.md / GOAL.md — those are contracts
- When in doubt: escalate, don't act

This is by design. The orchestrator is the watchdog, not the architect.

---

## 11. Cross-References

- Profile SOULs: `~/.hermes/PROJECTS/hermes-memory/souls/hm-*.md`
- Profile config sample: `~/.hermes/PROJECTS/hermes-memory/config/profiles.sample.yaml`
- Install script: `~/.hermes/PROJECTS/hermes-memory/scripts/install-souls.sh`
- Project plan: `~/.hermes/PROJECTS/hermes-memory/Plan.md`
- Critique items requiring ADRs: `~/.hermes/PROJECTS/hermes-memory/docs/v0.2-critique.md` §2
- Hermes Kanban orchestrator playbook: `skill_view('kanban-orchestrator')`
- Hermes Kanban worker pitfalls: `skill_view('kanban-worker')`
- Existing OpenClaw SOULs (reference): `~/.openclaw/workspace/PROJECTS/mission-control/souls/`
