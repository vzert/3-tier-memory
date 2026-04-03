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

Check if `MEMORY_DIR/MEMORY.md` already exists. If yes, tell the user "Memory system already initialized at MEMORY_DIR" and stop.

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

## Step 6: Install local /checkpoint command

Create `PROJECT_DIR/.claude/commands/checkpoint.md` so the user can type just `/checkpoint` (no plugin namespace):

```markdown
---
description: Save memory checkpoint — session log, pendientes, learnings, indexes, git commit
---

# Memory Checkpoint

Save the current session state to the 3-tier memory system. Execute ALL steps in order.

CORE RULE: Dual-write ALWAYS for sessions, pendientes, and learnings (Tier 2 index + Tier 3 file). Plans and research only if applicable.

## Step 0: Locate memory directory

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).
Read `memory/MEMORY.md` to confirm the system is initialized.

## Step 1: Session slug

If the user provided arguments after /checkpoint, use that as the slug.
Otherwise generate one from the session's main work (lowercase, hyphens, max 40 chars).

Set: DATE = today (YYYY-MM-DD), SESSION_FILE = memory/sessions/DATE-SLUG.md

## Step 2: Session — DUAL WRITE (always)

**Tier 3**: Write SESSION_FILE with frontmatter (type: session, date, status), sections: Contexto, Cambios realizados, Bugs fixed, Learnings generados, Pendientes, Commits (filled in Step 6), Related (wikilinks to _session-index, _pendientes, _learnings).

**Tier 2**: Add/update row in memory/_session-index.md with date, session link, status emoji, summary, commit hash (filled in Step 6).

## Step 3: Pendientes — DUAL WRITE (always)

Scan the ENTIRE conversation for:
1. Verification items ("confirmar", "verificar", "monitorear")
2. Deferred work ("despues hay que", "proxima sesion", TODO, FIXME)
3. Conditional checks ("si no mejora", "si vuelve a pasar")
4. Incomplete plan steps not yet executed
5. User deferrals ("luego lo veo", "manana checo")
6. Unfixed bugs discovered this session
7. Tests not run
8. Documentation gaps

For EACH pendiente:
**Tier 2**: Add to memory/_pendientes.md under correct priority with `_origen: [[sessions/DATE-SLUG]]`
**Tier 3**: Add row to memory/pendientes/YYYY-MM.md

Also check if existing pendientes were RESOLVED this session — mark done in BOTH files.

## Step 4: Learnings — DUAL WRITE (always)

Review session for new patterns, gotchas, rules, or mistakes discovered.

**Tier 3**: Add each learning to the relevant memory/learnings/<topic>.md. Create new topic file if needed.
**Tier 2**: Update memory/_learnings.md — add topic row if new file, add critical rules to Quick Reference.

If no learnings this session, skip.

## Step 5: Plans & Research — DUAL WRITE (only if applicable)

**Plans** — if any plan started, progressed, or completed:
- Tier 2: update row in memory/_plans-index.md
- Tier 3: create/update memory/plans/plan-<slug>.md if substantial

**Research** — if any research started or concluded:
- Tier 2: update row in memory/_research-index.md
- Tier 3: create/update memory/research/<slug>.md if substantial

## Step 6: Git commit

```
git add memory/
git commit -m "checkpoint: DATE-SLUG — summary"
```

Record the short hash in the session log and _session-index.md, then amend:
```
git add memory/
git commit --amend --no-edit
```

## Step 7: Report

Tell the user: session path, N pendientes extracted, M resolved, N learnings added, plans/research updated or not, indexes updated, commit hash.
```

Also create the directory if needed: `mkdir -p PROJECT_DIR/.claude/commands`

## Step 7: Update CLAUDE.md

If PROJECT_DIR/CLAUDE.md exists, append the Memory System section. If not, create it with project context + Memory System section.

The Memory System section should list:
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
