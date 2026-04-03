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
