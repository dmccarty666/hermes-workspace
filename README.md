# PROJECTS — Standards & Conventions

This directory contains all persistent project work. These standards ensure consistent structure across every project, making it easy for any agent (or human) to understand the current state of any project at a glance.

---

## Project Structure

Every project lives at `PROJECTS/<project-key>/` and follows this standard layout:

```
PROJECTS/<project-key>/
├── PROJECT.md           # Project charter and goals (required)
├── EPICS.md            # List of epics and their status
├── TASKLIST.md         # Current state, progress, outstanding work (required)
├── meta.json           # Machine-readable project metadata
├── tasks/              # Per-run task files (created by agents or scripts)
│   └── *.md            # Individual task files
├── docs/               # Design docs, specs, ADRs, research notes
│   └── *.md
├── designs/            # UI/UX mockups, diagrams, screenshots
├── scripts/            # Standalone utility scripts (Python, Shell, TypeScript)
│   └── *.py / *.sh / *.ts / *.js
├── config/             # Project-specific configuration files (YAML, JSON, etc.)
│   └── *.yaml / *.yml / *.json / *.toml
├── skills/             # Agent skill definitions (skill.yaml, SOUL.md, etc.)
│   └── <skill-name>/
│       ├── skill.yaml
│       └── SOUL.md (optional)
├── tests/              # Test files and test data (not generated output)
│   └── *.py / *.ts / *.sh
├── output/             # Generated output (HTML, images, reports) — NOT in Git
├── data/               # Project data files — NOT in Git
├── storage/            # Local data stores (SQLite, Qdrant, etc.) — NOT in Git
└── logs/               # Log files — NOT in Git
```

### Required per project
- `PROJECT.md` — what the project is and why
- `TASKLIST.md` — current narrative state

### Optional based on project needs
- `scripts/` — add if the project has executable scripts
- `config/` — add if the project has custom configs
- `skills/` — add if the project defines agent skills
- `docs/` — add if the project has design docs or research
- `tests/` — add if the project has tests
- `tasks/` — auto-created when runs are spawned

### Always excluded from Git (handled by file backup layer)
- `output/` — generated artifacts (HTML reports, images, exports)
- `data/` — input/output data files
- `storage/` — database files, vector stores, caches
- `logs/` — log files
- `archive/` — old epics only (NOT the whole project)

Sub-projects with their own internal structure (e.g., `backend/`, `frontend/`, `node_modules/`) are allowed and should follow their own conventions internally.

---

## What Goes Where — Code, Config, or Data?

| Type | Location in project | In Git? |
|------|---------------------|---------|
| Agent source code (TS/JS) | `src/` or at project root | ✅ Yes |
| Standalone scripts | `scripts/` | ✅ Yes |
| Agent skill definitions | `skills/<name>/skill.yaml` | ✅ Yes |
| Project configs (YAML, JSON, TOML) | `config/` or project root | ✅ Yes |
| Design docs, ADRs, research | `docs/` | ✅ Yes |
| Test files | `tests/` | ✅ Yes |
| Task files | `tasks/*.md` | ✅ Yes |
| Generated reports, HTML output | `output/` | ❌ No |
| Log files | `logs/` | ❌ No |
| Database files, vector stores | `storage/` | ❌ No |
| Project data (CSVs, JSON exports) | `data/` | ❌ No |
| Archived epics | `archive/` | ✅ Yes |
| Archived whole-project | `PROJECTS/_Archive/<key>/` | ❌ No (file backup only) |

**Rule of thumb:** If it changes during active development and you want diffs + intra-day snapshots → Git. If it's generated, cached, or backed up as a file → file backup layer only.

---

## TASKLIST.md — Purpose & Maintenance

**What it is:** A living document that captures the current state of a project — what was done, what's happening now, what's next, and what's blocking progress.

**What it isn't:** A replacement for Mission Control. MC tracks executable work items with acceptance criteria. TASKLIST.md tracks narrative state and context for projects that live outside or above MC.

**When to update TASKLIST.md:**
- When a significant milestone is reached (feature shipped, major bug fixed)
- When work shifts direction or scope changes
- When a new blocker appears or an existing blocker is resolved
- During weekly review (every Sunday evening)
- When spawning a subagent on a project for the first time in a while

**Format:**

```markdown
# <project-name> — Task List

**Status:** Active | On Hold | Complete | Archived
**Owner:** <owner>
**Last Updated:** YYYY-MM-DD
**MC Board:** <MC board name or N/A>

## ✅ Completed
- (YYYY-MM-DD) Milestone: Brief description

## 🔄 In Progress
- (YYYY-MM-DD) What: Brief description — ETA: YYYY-MM-DD | Blocked by: X

## 📋 Todo
- (YYYY-MM-DD) [P1] Brief high-priority description
- (YYYY-MM-DD) [P2] Brief medium-priority description
- (YYYY-MM-DD) [P3] Brief low-priority description

## 🚧 Blockers
- Blocker description — Impact: what this blocks

## 📝 Notes
- Context, decisions, or things worth remembering
```

**Status values:**
| Status | Meaning |
|--------|---------|
| Active | Work is ongoing |
| On Hold | Blocked or paused indefinitely |
| Complete | All goals achieved, maintenance mode only |
| Archived | No longer relevant, preserved for historical reference |

---

## Creating a New Project

When a new body of work is identified:

1. Create the directory: `mkdir -p PROJECTS/<project-key>/`
2. Create `PROJECT.md` — project name, goals, why it exists, who it's for
3. Create `TASKLIST.md` — initial status set to "Active", owner, today's date
4. Create `meta.json` — `{ "key": "...", "name": "...", "created": "YYYY-MM-DD", "status": "active" }`
5. Optionally create `EPICS.md`, `tasks/`, `docs/` as needed
6. Document the new project in MEMORY.md under Projects

**Project key naming:** lowercase, hyphenated, no spaces. E.g., `auto-router`, `mission-control`, `morning-updates`.

---

## Project Lifecycle

1. **Created** — Directory and TASKLIST.md exist, work is being planned
2. **Active** — Work is ongoing, TASKLIST.md is maintained
3. **On Hold** — Work paused (blocker or deferral)
4. **Complete** — All goals achieved
5. **Archived** — Project no longer active; moved to `archive/` subfolder

### Archiving a Project (Whole-Project Archive)

**Whole projects** go to `PROJECTS/_Archive/<project-key>/` — not a subfolder within the project.

```bash
mv PROJECTS/<project-key> PROJECTS/_Archive/<project-key>/
```

Whole-project archives are excluded from Git (handled by file backup: NAS1 + B2).

**Within a project**, only individual **epics or milestone docs** go into `archive/`:
```bash
mv PROJECTS/<project-key>/docs/old-epic-v1.md PROJECTS/<project-key>/archive/
```

### Archiving a Project

To archive a project:
1. Move the project directory into `PROJECTS/_Archive/<project-key>/`
2. Update `TASKLIST.md` status to "Archived"
3. Update `MEMORY.md` — remove from active projects list, note archived location

---


---

*These standards apply as of 2026-03-28. Update this file when conventions change.*
