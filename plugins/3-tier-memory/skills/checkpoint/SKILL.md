---
name: checkpoint
description: Save a memory checkpoint — creates/updates session log, extracts pendientes, updates all indexes, and commits to git. Use when the user says "checkpoint", "save progress", "guardemos", or at natural stopping points.
---

# Memory Checkpoint

Save the current session state to the 3-tier memory system. Execute ALL steps below in order.

## Step 0: Locate memory directory

```
If memory/ exists in $CLAUDE_PROJECT_DIR → MEMORY_DIR = $CLAUDE_PROJECT_DIR/memory (Model B)
Else → MEMORY_DIR = auto-memory directory (Model A)
```

Read `MEMORY_DIR/MEMORY.md` to confirm the memory system is initialized. If not found, tell the user to run `/3-tier-memory:setup-memory` (or `/setup-memory` if installed locally) first and stop.

## Step 1: Determine session slug

If `$ARGUMENTS` is provided, use it as the slug. Otherwise, generate a slug from the main work done this session (lowercase, hyphens, max 40 chars). Examples: `fix-auth-middleware`, `setup-ci-pipeline`, `migrate-database`.

Set: `DATE = YYYY-MM-DD` (today), `SLUG = <determined slug>`, `SESSION_FILE = MEMORY_DIR/sessions/DATE-SLUG.md`

## Step 2: Create/update session log

Write `SESSION_FILE` with this exact structure:

```markdown
---
type: session
date: <DATE>
status: completed | completed-with-pendientes
---
# <Descriptive Session Title>

## Contexto
<1-2 lines: what was the goal of this session>

## Cambios realizados
- <bullet list of concrete changes made>

## Bugs fixed
- <list bugs fixed, or "Ninguno">

## Learnings generados
- <links to learnings/ files updated, or "Ninguno">

## Pendientes
- [ ] <each pending item> — ver [[_pendientes]]
<or "Ninguno" if no pendientes>

## Commits
<will be filled in Step 5>

## Related
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
```

Set status to `completed-with-pendientes` if Step 3 finds any pendientes, otherwise `completed`.

## Step 3: Extract pendientes

Scan the ENTIRE current conversation for ALL of these categories:

1. **Verification items**: "confirmar que X funciona", "verificar", "monitorear"
2. **Deferred work**: "después hay que...", "en próxima sesión", "TODO", "FIXME"
3. **Conditional checks**: "si no mejora...", "si vuelve a pasar..."
4. **Incomplete plan steps**: steps from any active plan not yet executed
5. **User deferrals**: "luego lo veo", "mañana checo", "eso después"
6. **Unfixed bugs**: bugs discovered but not fixed this session
7. **Tests not run**: tests mentioned but not executed
8. **Documentation gaps**: docs that need updating after code changes

For EACH pendiente found:

**A)** Add to `MEMORY_DIR/_pendientes.md` under the correct priority section:
```
- [ ] <description> — _origen: [[sessions/DATE-SLUG]]_
```

**B)** Add a row to `MEMORY_DIR/pendientes/YYYY-MM.md`:
```
| N | <description> | alta/media/baja | DATE | [[sessions/DATE-SLUG]] | | |
```

Also check: were any EXISTING pendientes in `_pendientes.md` resolved this session? If so:
- Remove or mark `[x]` in `_pendientes.md`
- Fill `Resuelto` date and `Sesion resolucion` in the monthly archive

## Step 4: Update all indexes

**A) `_session-index.md`** — Add or update row:
```
| DATE | [[sessions/DATE-SLUG\|SLUG]] | STATUS_EMOJI | <1-line summary> | <commit hash — filled in Step 5> |
```

**B) `_plans-index.md`** — If any plan was started, progressed, or completed this session, update its row. Status emojis: draft, active, testing, completed, abandoned.

**C) `_research-index.md`** — If any research was started or concluded, update the relevant table.

**D) `_learnings.md`** — If any new learnings were added to topic files, ensure they appear in the Quick Reference section if critical.

## Step 5: Git commit

Run:
```bash
cd $CLAUDE_PROJECT_DIR
git add memory/
git commit -m "checkpoint: DATE-SLUG — <1-line summary of session work>"
```

Capture the commit short hash (first 7 chars). Then:

**A)** Add to the session log `## Commits` section:
```
- `<hash>` — checkpoint: <summary> (DATE)
```

**B)** Update the Commit column in `_session-index.md` for this session's row.

**C)** Stage and amend to include the hash references:
```bash
git add memory/
git commit --amend --no-edit
```

## Step 6: Report

Tell the user:
```
Checkpoint saved:
- Session: sessions/DATE-SLUG.md
- Pendientes: N extracted, M resolved
- Indexes updated: <list which ones>
- Commit: <hash> — checkpoint: <summary>
```
