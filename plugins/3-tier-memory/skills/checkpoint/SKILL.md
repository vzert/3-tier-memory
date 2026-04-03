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

Read `MEMORY_DIR/MEMORY.md` to confirm the memory system is initialized. If not found, tell the user to run setup-memory first and stop.

## Step 1: Determine session slug

If `$ARGUMENTS` is provided, use it as the slug. Otherwise, generate a slug from the main work done this session (lowercase, hyphens, max 40 chars). Examples: `fix-auth-middleware`, `setup-ci-pipeline`, `migrate-database`.

Set: `DATE = YYYY-MM-DD` (today), `SLUG = <determined slug>`, `SESSION_FILE = MEMORY_DIR/sessions/DATE-SLUG.md`

## Step 2: Session — DUAL WRITE (always)

**A) Tier 3** — Write `SESSION_FILE`:

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
<will be filled in Step 6>

## Related
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
```

**B) Tier 2** — Add or update row in `_session-index.md`:
```
| DATE | [[sessions/DATE-SLUG|SLUG]] | STATUS_EMOJI | <1-line summary> | <commit hash — filled in Step 6> |
```

Set status to `completed-with-pendientes` if Step 3 finds any pendientes, otherwise `completed`.

## Step 3: Pendientes — DUAL WRITE (always)

Scan the ENTIRE current conversation for ALL of these categories:

1. **Verification items**: "confirmar que X funciona", "verificar", "monitorear"
2. **Deferred work**: "despues hay que...", "en proxima sesion", "TODO", "FIXME"
3. **Conditional checks**: "si no mejora...", "si vuelve a pasar..."
4. **Incomplete plan steps**: steps from any active plan not yet executed
5. **User deferrals**: "luego lo veo", "manana checo", "eso despues"
6. **Unfixed bugs**: bugs discovered but not fixed this session
7. **Tests not run**: tests mentioned but not executed
8. **Documentation gaps**: docs that need updating after code changes

For EACH pendiente found:

**A) Tier 2** — Add to `_pendientes.md` under the correct priority section:
```
- [ ] <description> — _origen: [[sessions/DATE-SLUG]]_
```

**B) Tier 3** — Add row to `pendientes/YYYY-MM.md`:
```
| N | <description> | alta/media/baja | DATE | [[sessions/DATE-SLUG]] | | |
```

Also check: were any EXISTING pendientes resolved this session? If so:
- Remove or mark `[x]` in `_pendientes.md`
- Fill Resuelto date and Sesion resolucion in `pendientes/YYYY-MM.md`

## Step 4: Learnings — DUAL WRITE (always)

Review the session for new patterns, gotchas, rules, or mistakes discovered.

**A) Tier 3** — For each learning, add to the relevant `learnings/<topic>.md` file. If no topic file fits, create a new one with frontmatter.

**B) Tier 2** — Update `_learnings.md`:
- If a new topic file was created, add a row to the Topic Files table
- If a critical rule was added, add it to the Quick Reference section

If no learnings were generated this session, skip this step.

## Step 5: Plans & Research — DUAL WRITE (only if applicable)

**Plans** — If any plan was started, progressed, or completed this session:
- **Tier 2**: Update row in `_plans-index.md` (status, session link)
- **Tier 3**: Create or update `plans/plan-<slug>.md` if substantial (>20 lines)

**Research** — If any research was started or concluded this session:
- **Tier 2**: Update row in `_research-index.md`
- **Tier 3**: Create or update `research/<slug>.md` if substantial

## Step 6: Git commit

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

## Step 7: Report

Tell the user:
```
Checkpoint saved:
- Session: sessions/DATE-SLUG.md
- Pendientes: N extracted, M resolved
- Learnings: N added to <topic files>
- Plans/Research: <updated or "no changes">
- Indexes updated: <list which ones>
- Commit: <hash> — checkpoint: <summary>
```
