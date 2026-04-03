---
description: Initialize the 3-tier memory system in the current project. Creates all directories, indexes, hooks, and bridge. Run once per project.
---

# Setup 3-Tier Memory System

Initialize a complete 3-tier memory system for this project. Follow ALL steps in order.

## Step 1: Detect environment

Determine paths:
```
PROJECT_DIR = $CLAUDE_PROJECT_DIR (current project root)
MEMORY_DIR = PROJECT_DIR/memory/
```

Check if `MEMORY_DIR/MEMORY.md` already exists. If yes, tell the user: "Memory system already exists. Use `/3-tier-memory:migrate` to install the plugin's local commands (/checkpoint, /status, /audit) without touching your data." and stop.

## Step 2: Create directory structure

Create ALL directories (none are optional):

```bash
mkdir -p "$PROJECT_DIR/memory/"{learnings,sessions,pendientes,plans,research}
```

## Step 3: Create Tier 2 indexes

Create ALL of these files in `MEMORY_DIR/`. Use today's date for `created` and `updated` fields.

**MEMORY.md** (Tier 1 — lean index):
- Checkpoint Protocol section (at session start, during execution, checkpoint trigger)
- Topic Files section (empty, to be populated)
- Operational Indexes section linking to all _index files
- Current Status section (brief project state)
- Memory Rules section

**_pendientes.md** — Aggregator with Alta/Media/Baja prioridad sections, "Como usar" instructions, Related links.

**_session-index.md** — Table with columns: Fecha, Sesion, Status, Resumen, Commit. Empty rows. Convention section.

**_learnings.md** — Table with columns: Topic, File, When to consult. One initial topic file entry. Quick Reference section (empty initially).

**_plans-index.md** — Table with columns: Plan, Status, Fecha, Sesion, Pendientes, Learnings. Lifecycle description. Como agregar section.

**_research-index.md** — Active Research table and Completed Research table. Como agregar section.

All index files must have:
- Frontmatter: type, created, updated, status
- Related section with wikilinks to other indexes

## Step 4: Create Tier 3 starter files

**learnings/<project-slug>.md** — One starter learnings file named after the project. Frontmatter + "Rules will be added as patterns are discovered."

**pendientes/YYYY-MM.md** — Monthly archive for current month. Table with columns: #, Pendiente, Prioridad, Creado, Origen, Resuelto, Sesion resolucion.

## Step 5: Create auto-memory bridge

Determine the auto-memory path:
```
AUTO_MEMORY_DIR = ~/.claude/projects/<encoded-project-path>/memory/
```
Where `<encoded-project-path>` is PROJECT_DIR with `/` replaced by `-` and leading `-`.

If AUTO_MEMORY_DIR/MEMORY.md exists with content (not just a bridge):
1. Back it up to MEMORY.md.bak
2. Extract any valuable content not already in MEMORY_DIR

Create/overwrite AUTO_MEMORY_DIR/MEMORY.md with the bridge template:
```markdown
# <Project Name> — Memory Bridge

This project uses project-local memory. Files live in `memory/` within the project directory.

## At session start
1. Read `memory/_pendientes.md` — open action items
2. Read `memory/_learnings.md` — consult before making changes

## During execution
- New learning → `memory/learnings/<topic>.md`, update `memory/_learnings.md` if critical
- New pendiente → `memory/_pendientes.md` with `_origen:` link + `memory/pendientes/YYYY-MM.md`
- Executing a plan → register/update row in `memory/_plans-index.md`
- New research → `memory/research/{slug}.md` + row in `memory/_research-index.md`

## Checkpoint
Use /checkpoint to save progress. It will update session log, extract pendientes, update indexes, and git commit.

## Index
- `memory/MEMORY.md` — lean index
- `memory/_pendientes.md` — open action items
- `memory/_learnings.md` — learnings by topic
- `memory/_session-index.md` — session history
- `memory/_plans-index.md` — plans registry
- `memory/_research-index.md` — research tracker
```

## Step 6: Install local commands

Create `PROJECT_DIR/.claude/commands/` directory if it doesn't exist, then create these 3 command files. All are auto-updated by the plugin's SessionStart hook when a new version ships — the user never needs to re-run setup for command improvements.

### 6a. /checkpoint — save memory state
Create `PROJECT_DIR/.claude/commands/checkpoint.md`:

Note: this file will be auto-updated by the plugin's SessionStart hook whenever a new plugin version ships an updated template. The user doesn't need to re-run setup to get checkpoint improvements.

The content of this file should match `templates/checkpoint.md` from the plugin. It will be auto-updated by the SessionStart hook on future plugin updates.

Write the full content of the latest checkpoint template (see templates/checkpoint.md in the plugin source for the canonical version).

Also create the directory if needed: `mkdir -p PROJECT_DIR/.claude/commands`

### 6b. /status — memory health overview
Create `PROJECT_DIR/.claude/commands/status.md` with this content:

```markdown
---
description: Quick memory health overview — action items, sessions, learnings, plans, research
---

# Memory Status

Read and report the current state of the 3-tier memory system.

1. Read memory/_pendientes.md — count open items by priority (Alta, Media, Baja)
2. Read memory/_session-index.md — total sessions, most recent date and slug
3. Read memory/_learnings.md — count topic files and Quick Reference rules
4. Read memory/_plans-index.md — count by status (active, completed, draft)
5. Read memory/_research-index.md — count active and completed
6. Verify 5 dirs + 6 indexes exist

Report:
MEMORY STATUS: N pendientes (X alta, Y media, Z baja) | N sessions (last: DATE) | N learnings topics | N plans active | N research active | Structure: X/11
```

### 6c. /audit — verification checklists
Create `PROJECT_DIR/.claude/commands/audit.md` with this content:

```markdown
---
description: Run verification checklists on the 3-tier memory system — structure, content, bridge, wikilinks, CLAUDE.md
---

# Memory Audit

Run ALL checks, report pass/fail per category:

1. STRUCTURE: 5 dirs + 6 indexes + at least 1 learnings file + at least 1 pendientes archive
2. CONTENT: MEMORY.md has checkpoint protocol, _pendientes.md has priority sections, all indexes have tables
3. BRIDGE: auto-memory MEMORY.md is compact (<40 lines), references memory/, no inline content
4. WIKILINKS: Related sections in session files, pendientes, learnings, plans, research with correct links
5. CLAUDE.md: has Memory System section, mentions /checkpoint, has bridge protection rule, .gitignore has .claude/

Report: X/X per category. List any failures with fix instructions.
```

## Step 7: Update CLAUDE.md

If PROJECT_DIR/CLAUDE.md exists, append the sections below. If not, create it with project context + these sections.

Add this CRITICAL rule section:

```markdown
## CRITICAL: Auto-memory MEMORY.md is a BRIDGE ONLY

The file at `~/.claude/projects/<encoded-path>/memory/MEMORY.md` is a bridge that redirects to `memory/` in this project. NEVER write content, indexes, session data, learnings, or any operational data into that file. It must ONLY contain the redirect template. All memory operations go to `memory/` in the project directory. If auto-memory MEMORY.md has more than 30 lines, something is wrong — rewrite it as a bridge immediately.
```

Add the Memory System section listing:
- Operational indexes with paths
- When to consult learnings
- How to use `/checkpoint` to save progress
- Reference files

## Step 8: Verify

Run the structure audit:
- All 5 directories exist in memory/
- All 6 index files exist (MEMORY.md + 5 _indexes)
- At least 1 learnings file exists
- At least 1 pendientes monthly archive exists
- Bridge exists in auto-memory
- Bridge is compact (<40 lines) and references memory/

Report results to the user.
