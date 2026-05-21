# Project Development Automation Framework — Status & Tasklist

> **Living document.** Single source of truth for what we're building, why,
> what's done, what's next, and how to pick this work back up after Phase 6
> of hermes-memory closes.

**Last updated:** 2026-05-21 (during hermes-memory Phase 6 execution)
**Status:** ON HOLD by design — work resumes after hermes-memory Phase 6 gate closes.
**Owner:** David McCarty
**Workspace:** `~/.hermes/PROJECTS/.framework/`
**Git workspace:** `~/.hermes/PROJECTS/` (hermes-workspace repo)
**Companion skills:** `kanban-orchestrator`, `kanban-worker`, `kanban-project-bootstrap`

---

## 1. Why this exists

The **hermes-memory** project proved that a Ralph-loop orchestrator plus a
small crew of specialist worker agents (planner, architect, developer, qa,
docs, auditor) can drive a real multi-week, multi-phase build to completion
with human sign-off at phase gates and escalation when stuck.

**The pain:** ~80% of that machinery is generic, but the first version baked
project-specific names and domain knowledge directly into SOUL files,
hardcoded `hm-*` profile names, and a single cron job. That works for one
project but **doesn't scale to a second one without copy-paste-rename hell.**

**The fix:** extract the generic parts into templates + a single
`project.yaml`, so any new project can be bootstrapped in minutes:

```bash
mkdir -p ~/.hermes/PROJECTS/financial-app
cd ~/.hermes/PROJECTS/financial-app
# 1. Author PROJECT.md, prd.md, TDD.md, Plan.md, EPICS.md (the inputs)
# 2. Write project.yaml (the framework config)
~/.hermes/PROJECTS/.framework/scripts/bootstrap.sh ./project.yaml
# 7 profiles created, SOULs installed, cron registered, orchestrator IDLE → ready
```

The **regression test** for the framework is byte-equivalence: running
`bootstrap.sh` against `examples/hermes-memory.yaml` must produce SOULs
that match the hand-written `hermes-memory/souls/hm-*.md` files (modulo
whitespace).

---

## 2. Architecture — three layers

```
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 1 — FRAMEWORK  (~/.hermes/PROJECTS/.framework/)            │
│   • souls-template/<role>.md.tmpl   Jinja-style SOUL templates   │
│   • scripts/render-soul.py          Template renderer            │
│   • scripts/bootstrap.sh            One-shot project setup       │
│   • scripts/heartbeat.sh            Generic cron driver          │
│   • schema/project.schema.yaml      project.yaml JSON Schema     │
│   • examples/<slug>.yaml            Reference project YAMLs      │
└────────────────────────────────┬─────────────────────────────────┘
                                 │ rendered + installed into
                                 ▼
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 2 — PROJECT SCAFFOLD  (~/.hermes/PROJECTS/<slug>/)         │
│   • project.yaml                       (human-edited config)     │
│   • PROJECT.md, prd.md, TDD.md, Plan.md, EPICS.md  (inputs)      │
│   • orchestrator/{GOAL,STATE,HISTORY}.md  (rendered + live)      │
│   • souls/<slug>-<role>.md  (rendered from template + yaml)      │
│   • scripts/heartbeat.sh   (thin shim → framework heartbeat.sh)  │
│   • scripts/install-souls.sh                                     │
└────────────────────────────────┬─────────────────────────────────┘
                                 │ installed by install-souls.sh into
                                 ▼
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 3 — RUNTIME  (~/.hermes/profiles/<slug>-<role>/)           │
│   ~/.hermes/profiles/<slug>-orchestrator/SOUL.md                 │
│   ~/.hermes/profiles/<slug>-planner/SOUL.md                      │
│   ~/.hermes/profiles/<slug>-architect/SOUL.md                    │
│   ~/.hermes/profiles/<slug>-developer/SOUL.md                    │
│   ~/.hermes/profiles/<slug>-qa/SOUL.md                           │
│   ~/.hermes/profiles/<slug>-docs/SOUL.md                         │
│   ~/.hermes/profiles/<slug>-auditor/SOUL.md                      │
└──────────────────────────────────────────────────────────────────┘
```

Slug-prefixed profile names matter: the framework requires every project to
choose a unique short slug (2–16 chars). All profile names, the kanban
tenant, cron jobs, and rendered SOULs derive from it.

| Project | Slug | Profile names |
|---|---|---|
| Hermes Memory | `hm` | `hm-orchestrator`, `hm-developer`, … |
| Financial App | `fin` | `fin-orchestrator`, `fin-developer`, … |
| OpenClaw v2 | `ocw` | `ocw-orchestrator`, `ocw-developer`, … |

---

## 3. Current state — what's actually on disk

```
.framework/
├── README.md                         202 lines  ✅
├── STATUS.md                         (this file) ✅
├── schema/
│   └── project.schema.yaml           303 lines  ✅ done
├── souls-template/
│   ├── PROGRESS.md                    76 lines  ✅ tracker
│   ├── orchestrator.md.tmpl          343 lines  ✅ DONE
│   ├── auditor.md.tmpl                68 lines  ✅ DONE
│   ├── planner.md.tmpl                       —  ⏳ TODO  (~361 source lines)
│   ├── architect.md.tmpl                     —  ⏳ TODO  (~334 source lines)
│   ├── developer.md.tmpl                     —  ⏳ TODO  (~386 source lines)
│   ├── qa.md.tmpl                            —  ⏳ TODO  (~482 source lines)
│   └── docs.md.tmpl                          —  ⏳ TODO  (~317 source lines)
├── scripts/
│   ├── bootstrap.sh                  333 lines  ✅ drafted, untested
│   ├── heartbeat.sh                  219 lines  ✅ drafted, untested
│   └── render-soul.py                218 lines  ✅ drafted, untested
├── examples/
│   ├── hermes-memory.yaml            159 lines  ✅ canonical reference
│   └── financial-app.yaml            146 lines  ✅ starter for next project
└── docs/                                     —  ⏳ NOT CREATED YET
    ├── ARCHITECTURE.md                       (planned)
    ├── ROLES.md                              (planned)
    └── MIGRATION.md                          (planned)
```

**Git commit:** `5b051b8 .framework: scaffold pluggable kanban-orchestrator framework`
(local-only on PROJECTS workspace, not pushed)

**Hand-written source SOULs (the byte-equivalence target):**
```
~/.hermes/PROJECTS/hermes-memory/souls/hm-orchestrator.md    20,696 bytes
~/.hermes/PROJECTS/hermes-memory/souls/hm-developer.md       18,854 bytes
~/.hermes/PROJECTS/hermes-memory/souls/hm-qa.md              16,473 bytes
~/.hermes/PROJECTS/hermes-memory/souls/hm-planner.md         13,919 bytes
~/.hermes/PROJECTS/hermes-memory/souls/hm-docs.md            11,512 bytes
~/.hermes/PROJECTS/hermes-memory/souls/hm-architect.md        9,883 bytes
~/.hermes/PROJECTS/hermes-memory/souls/hm-auditor.md          1,290 bytes
```

---

## 4. Why this is on hold

The framework README says it explicitly:

> **DO NOT run against hermes-memory while Phase 6 is in flight.**

Reason: bootstrap.sh would install `hm-*` profiles, register a cron job, and
push SOULs into profile homes — all overlapping with the running
hermes-memory orchestrator. We'd corrupt our working system trying to test
the abstraction of it.

**Restart conditions:** hermes-memory Phase 6 gate (`T-PHASE6-GATE`,
card `t_085fa48b`) is approved. After that, hermes-memory becomes the
**first dogfooding test** for the framework.

---

## 5. Open tasklist — work to do when we resume

Numbered in the order they should be tackled. Each carries a rough effort
estimate, dependencies, and acceptance criteria so we can drop right back in.

### F-001 — Extract remaining 5 SOUL templates  [BLOCKER for everything else]

Five hand-written SOULs in `hermes-memory/souls/` must be turned into
templates under `souls-template/`. The extraction recipe is documented in
`souls-template/PROGRESS.md` step-by-step (identity / path / domain /
test-command / phase-count / escalation sweeps).

| Sub-task | Source lines | Est. effort |
|---|---|---|
| F-001a `planner.md.tmpl` | 361 | ~2h |
| F-001b `architect.md.tmpl` | 334 | ~2h |
| F-001c `developer.md.tmpl` | 386 | ~2.5h |
| F-001d `qa.md.tmpl` | 482 | ~3h |
| F-001e `docs.md.tmpl` | 317 | ~2h |

**AC:**
- Each template renders cleanly via `render-soul.py --soul <role> examples/hermes-memory.yaml`
- Rendered output diffs against the hand-written SOUL with only project-
  specific cosmetic differences (whitespace, ordering)
- `souls-template/PROGRESS.md` updated as each lands

### F-002 — End-to-end dry-run of `bootstrap.sh` against `financial-app.yaml`

The bootstrap script is 333 lines but untested. We need a throwaway target
to validate it without risking hermes-memory.

**AC:**
- `bootstrap.sh examples/financial-app.yaml --dry-run` prints the plan with
  zero errors
- Live run on a throwaway dir (`/tmp/test-project/`) creates: souls/
  rendered files, orchestrator/ goal+state+history, scripts/ shims, 7
  profiles via `hermes profile create`, 1 cron job
- Tear-down command (or `--partial` flag confirmation) actually works

### F-003 — Byte-equivalence regression check against hermes-memory

The whole point of the framework is that templates + project.yaml reproduce
what we hand-wrote. Build a checking harness.

**AC:**
- New script `scripts/check-equivalence.sh <project.yaml> <souls-dir>` exists
- Running it against `examples/hermes-memory.yaml` and
  `~/.hermes/PROJECTS/hermes-memory/souls/` reports either:
  - ✅ all 7 SOULs match (modulo whitespace)
  - ❌ specific diffs requiring template OR source SOUL update
- Diffs surface in CI-friendly format (one section per SOUL)

### F-004 — Author missing `docs/` set

The planned `.framework/docs/` directory doesn't exist yet. Three documents:

| File | Purpose |
|---|---|
| `docs/ARCHITECTURE.md` | Deeper design discussion than README — why three layers, what each script does, how render-soul.py renders, schema validation flow |
| `docs/ROLES.md` | What each of 7 roles does, when each fires, escalation rules, how they handoff via kanban states |
| `docs/MIGRATION.md` | Step-by-step retrofit guide for an existing project (the hermes-memory migration plan, generalized) |

**AC:**
- Each file ≥150 lines of substantive content with examples
- Cross-linked from README.md

### F-005 — Migrate hermes-memory onto the framework (THE BIG TEST)

Once Phase 6 of hermes-memory closes, retrofit hermes-memory itself onto
the framework. This is the **definitive proof of the framework**.

Steps:

1. Author `hermes-memory/project.yaml` (already exists at
   `.framework/examples/hermes-memory.yaml` — copy it in)
2. Run `bootstrap.sh hermes-memory/project.yaml --check` → diff rendered
   SOULs vs hand-written ones
3. Reconcile diffs — either update templates (if hand-written is correct
   pattern) or update SOULs (if template caught drift)
4. Switch cron job to invoke framework `heartbeat.sh`
5. Decommission `hermes-memory/scripts/orchestrator-heartbeat.sh` →
   replace with shim

**AC:**
- hermes-memory continues to run its (post-Phase-6) maintenance / dream /
  contradiction loop entirely via framework heartbeat
- `~/.hermes/PROJECTS/hermes-memory/scripts/` contains only thin shims
- Cron registered with name `hm-orchestrator` calling framework heartbeat
- No regressions in observable orchestrator behavior over 48h

### F-006 — Bootstrap the second project (financial-app or other)

The real win is when project #2 lights up in minutes.

**AC:**
- Pick a real next project (financial-app, openclaw-v2, kanban-llm-router,
  etc.) — decision deferred to David
- Author its `project.yaml`, `PROJECT.md`, `prd.md`, `TDD.md`, `Plan.md`,
  `EPICS.md`
- Bootstrap completes < 5 minutes
- Orchestrator picks up on first cron tick and writes a STATE.md entry

### F-007 — Promote the framework

Three downstream considerations:

| Item | Decision needed |
|---|---|
| Move into `hermes-agent/` core? | Currently lives under `~/.hermes/PROJECTS/.framework/`. The README argues against putting it in hermes-agent (it's a project-pattern, not a Hermes feature). Re-evaluate after F-006. |
| Publish skills as part of the hermes-agent build? | `kanban-project-bootstrap` skill is the public API; could ship it as a built-in skill in the repo |
| Versioning of `project.yaml` schema | First production project pins a version. Migrations may be needed if the schema evolves. |

---

## 6. Where things live — cross-reference

| Concern | Path / artifact |
|---|---|
| Framework code | `~/.hermes/PROJECTS/.framework/` |
| Hand-written reference SOULs | `~/.hermes/PROJECTS/hermes-memory/souls/hm-*.md` |
| Live orchestrator goal/state | `~/.hermes/PROJECTS/hermes-memory/orchestrator/{GOAL,STATE,HISTORY}.md` |
| Reference project.yaml | `.framework/examples/hermes-memory.yaml` |
| Schema | `.framework/schema/project.schema.yaml` |
| Companion bootstrap skill | `~/.hermes/skills/devops/kanban-project-bootstrap/SKILL.md` |
| Companion worker skill | `~/.hermes/skills/devops/kanban-worker/SKILL.md` |
| Companion orchestrator skill | `~/.hermes/skills/devops/kanban-orchestrator/SKILL.md` |
| Git workspace (this work) | `~/.hermes/PROJECTS/` → `hermes-workspace` repo |

---

## 7. Decisions log (so we don't re-litigate)

| Date | Decision |
|---|---|
| 2026-05-21 | Framework code lives under `~/.hermes/PROJECTS/.framework/`, **not** inside `hermes-agent/`. Reason: it's a project-pattern, not a Hermes Agent feature. |
| 2026-05-21 | Slug + dir_name are separate fields. Slug (`hm`) is the agent-facing identity; dir_name (`hermes-memory`) is the filesystem location. Can differ. |
| 2026-05-21 | Each project's orchestrator runs independently. **No** cross-project meta-orchestrator — if needed, build that as a separate layer above. |
| 2026-05-21 | Regression test is byte-equivalence: framework rendering hermes-memory must reproduce hand-written SOULs. |
| 2026-05-21 | DO NOT bootstrap against hermes-memory while Phase 6 is in flight. |
| 2026-05-21 | `auditor.md.tmpl` and `orchestrator.md.tmpl` are the first two templates extracted — extraction pattern is now documented in `souls-template/PROGRESS.md`. |

---

## 8. Restart-here checklist when Phase 6 closes

When the hermes-memory Phase 6 gate is approved and you come back to this:

1. Read this STATUS.md top to bottom
2. Skim `~/.hermes/PROJECTS/.framework/README.md` and
   `souls-template/PROGRESS.md`
3. Pick up at **F-001** (extract remaining 5 templates) — that's the
   blocker for everything else
4. Re-run `git log --oneline ~/.hermes/PROJECTS/.framework/` to see if
   anything moved while we were heads-down on Phase 6
5. Update this file's "Last updated" line and append a Decisions log entry
   for whatever new context appears

---

## 9. Out of scope (already considered, deliberately excluded)

| Idea | Why excluded |
|---|---|
| Replace Hermes Kanban backend | Framework rides on top; the kanban DB is fine |
| Automate PRD/TDD/Plan authorship | Human-authored inputs are a feature, not a bug |
| Cross-project work coordination | Each project independent; meta-orchestrator is a separate layer |
| Build a UI for project.yaml | YAML + schema validation is sufficient; UI is post-MVP |
| LLM-based template extraction | Manual extraction via the documented recipe is faster + safer than a tool we'd debug for weeks |

---

**Maintain this doc.** Whenever you make a structural change, update §3 (state on disk) and §5 (tasklist). Whenever you make an irreversible decision, append to §7.
