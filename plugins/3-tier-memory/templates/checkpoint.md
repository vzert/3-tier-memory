---
description: Save memory checkpoint — session log, action items, learnings, indexes, git commit
---

# Memory Checkpoint

Save the current session state to the 3-tier memory system. Execute ALL steps in order.

CORE RULES:
- Dual-write ALWAYS for sessions, action items, and learnings (Tier 2 index + Tier 3 file)
- Plans and research: SCAN for signals below — register if ANY signal found

## Step 0: Locate memory directory

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).
Read `memory/MEMORY.md` to confirm the system is initialized.

## Step 1: Session slug

If the user provided arguments after /checkpoint, use that as the slug.
Otherwise generate one from the session's main work (lowercase, hyphens, max 40 chars).

Set: DATE = today (YYYY-MM-DD), SESSION_FILE = memory/sessions/DATE-SLUG.md

## Step 2: Session — DUAL WRITE (always)

**Tier 3**: Write SESSION_FILE with this structure:

```markdown
---
type: session
date: DATE
status: completed | completed-with-pendientes
---
# Session Title

## Contexto
<1-2 lines>

## Cambios realizados
- <bullets>

## Bugs fixed
- <list or "Ninguno">

## Plans
- <plans used/created this session with wikilinks, or "Ninguno">

## Research
- <research/investigations done this session with wikilinks, or "Ninguno">

## Learnings generados
- <links to learnings/ files, or "Ninguno">

## Pendientes
- [ ] <items> — ver [[_pendientes]]
<or "Ninguno">

## Commits
<filled in Step 6>

## Related
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
- [[_plans-index]] (if plan work this session)
- [[_research-index]] (if research this session)
```

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

## Step 5: Plans & Research — DUAL WRITE (scan for signals)

Do NOT skip this step. Actively scan the conversation for these signals:

### Plan signals — if ANY found, register the plan:
- Plan mode was used (ExitPlanMode, "plan mode", plan file created/edited)
- A plan file exists in `~/.claude/plans/` from this session
- Implementation steps were discussed or executed
- User said "plan", "diseño", "arquitectura", "implementacion"

**If plan signals found:**
- Tier 2: add/update row in memory/_plans-index.md (title, status, date, session link)
- Tier 3: create/update memory/plans/plan-<slug>.md with context, decisions, steps, outcome
- Add wikilink in session log ## Plans section and ## Related

### Research signals — if ANY found, register the research:
- Web searches or web fetches were performed
- Documentation was consulted (library docs, API references)
- Options/alternatives were compared or evaluated
- User said "investiga", "busca", "compara", "evalua", "analiza"

**If research signals found:**
- Tier 2: add/update row in memory/_research-index.md (topic, result, file link)
- Tier 3: create/update memory/research/<slug>.md with context, findings, conclusion
- Add wikilink in session log ## Research section and ## Related

### If NO signals found for either:
Write "Ninguno" in the session log sections and skip the index updates.

## Step 5b: Prune indexes

Keep Tier 2 indexes lean. Tier 3 detail files are NEVER deleted — only index rows are removed.

### _pendientes.md
Remove any `- [x]` items. Completed pendientes should already be gone (Step 3), but clean up stragglers.

### _session-index.md
If the Sessions table has more than 10 rows, keep only the 10 most recent (by date). Remove older rows.

### _plans-index.md
Keep all rows with status active, draft, or testing. For completed/abandoned, keep only the 5 most recent. Remove older rows.

### _research-index.md
Keep the entire Active Research table. In Completed Research, keep only the 5 most recent rows. Remove older rows.

### _learnings.md
No pruning — bounded by design.

Note pruned row count for Step 7 report.

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

Tell the user: session path, N pendientes extracted, M resolved, N learnings added, plans registered (Y/N), research registered (Y/N), indexes updated, N rows pruned from indexes (if any), commit hash.
