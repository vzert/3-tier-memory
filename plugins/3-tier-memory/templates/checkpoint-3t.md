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

If the user provided arguments after /checkpoint-3t, use that as the slug.
Otherwise generate one from the session's main work (lowercase, hyphens, max 40 chars).

Set: DATE = today (YYYY-MM-DD), SESSION_FILE = memory/sessions/DATE-SLUG.md

## Step 2: Session — DUAL WRITE (always)

**Tier 3**: Write SESSION_FILE with this structure:

```markdown
---
type: session
date: DATE
status: completed | completed-with-pendientes
importance: <0-10>
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

## Como retomar
<filled in Step 8>

## Related
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
- [[_plans-index]] (if plan work this session)
- [[_research-index]] (if research this session)
```

Set `importance` to a salience score 0-10 (Generative-Agents style): how reusable/critical is this session for future recall? Routine work ≈ 3-4, normal feature work ≈ 5-6, an architectural decision or hard-won fix ≈ 8-10. This score feeds the relevance-recall ranking (UserPromptSubmit hook). If unsure, omit it — the recall engine defaults to 5.

**Tier 2**: Add/update row in memory/_session-index.md with date, session link, status emoji, summary, commit hash (filled in Step 6).

## Step 3: Pendientes — DUAL WRITE via journal (always)

Since v2.12.0 you do NOT edit `memory/_pendientes.md` or `memory/pendientes/YYYY-MM.md` by hand.
Several agents may be checkpointing on this machine at the same time, and a hand edit silently
drops their lines (Claude Code only warns; it does not block). Every change is an EVENT emitted
with `journal-emit.py`; a single compactor (`journal-compact.py`) applies the events under a lock,
as anchored deltas (insert under the priority header, delete by id, fill a cell by id). Locate
the scripts once:

```bash
MEMORY_DIR="memory"   # the directory located in Step 0 (Model B); use the Model A path otherwise
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/journal-emit.py" ]; then
  JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
elif [ -f "plugins/3-tier-memory/bin/journal-emit.py" ]; then
  JBIN="$PWD/plugins/3-tier-memory/bin"     # the plugin's own repo: dogfood the working tree, not the cache
else
  JEMIT=$(find "$HOME/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
  JBIN=${JEMIT:+$(dirname "$JEMIT")}   # empty when find found nothing (dirname "" would give ".")
fi
[ -n "$JBIN" ] && [ -f "$JBIN/journal-compact.py" ] && echo "JBIN=$JBIN" || echo "JBIN=NONE"
```

If it prints `JBIN=NONE` (plugin older than 2.12.0), fall back to the manual edits marked
**Fallback** below and say so in the Step 7 report.

This step runs in FOUR sub-phases, in order: 3-pre, 3a, 3b, 3c. Do not merge them.

### Step 3-pre — Fresh state + ids

```bash
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"       # apply whatever other agents left pending
python3 "$JBIN/enrich-memory.py" "$MEMORY_DIR" --apply --only creado,id   # legacy lines get `_creado` (if missing) and `_id: p-…_`; idempotent
```

THEN read `memory/_pendientes.md`. Every open line now ends with `_id: p-xxxxxxxxxx_`. That id is
how you resolve it in 3a; never match a line by its text.

### Step 3a — Reconciliacion de pendientes existentes (RECONCILIATION FIRST)

Enumerate EVERY open item (`- [ ]`) you just read. For each, classify into exactly one of:

- **resolved** — the work described was completed in this session, directly or indirectly (e.g., the user asked for X and X happens to satisfy the pendiente).
- **still-open** — the work is still pending and was not touched this session.
- **superseded** — the item was absorbed by another pendiente or a scope change (reference the new owner/scope).
- **abandoned** — the item no longer applies (architecture changed, feature dropped, etc.).

**Print a reconciliation table** to the user before continuing, so the decision is explicit:
```
RECONCILIACION:
- #1 <pendiente text> → still-open
- #2 <pendiente text> → resolved (this session)
- #3 <pendiente text> → superseded by <new pendiente or scope ref>
- #4 <pendiente text> → abandoned — <reason>
...
```

For EACH item classified `resolved`, `superseded`, or `abandoned`, emit one event:

```bash
python3 "$JBIN/journal-emit.py" --type pendiente.resolve --id p-xxxxxxxxxx \
  --estado resolved|superseded|abandoned --sesion "[[sessions/DATE-SLUG]]" --nota "<reason or new ref>"
```

The compactor (Step 3c) removes the line from `_pendientes.md` (**Tier 2**) and fills `Resuelto`
with today's date and `Sesion resolucion` with `<sesion> — <estado> — <nota>` in the monthly row
that carries the same id (**Tier 3**). Legacy items (created before 2.12.0) have no id in their
monthly row: the compactor logs a WARN for them and you fill that one monthly row by hand, as
before (`Resuelto` = today, `Sesion resolucion` = `[[sessions/DATE-SLUG]]` plus `SUPERSEDED — <ref>`
or `ABANDONED — <reason>` when applicable).

**Fallback (no JBIN)**: remove the line from `memory/_pendientes.md` and fill the monthly row as
described above.

If reconciliation finds zero existing pendientes, say so and continue.

### Step 3b — Extraccion de pendientes nuevos

Scan the ENTIRE conversation for:
1. Verification items ("confirmar", "verificar", "monitorear")
2. Deferred work ("despues hay que", "proxima sesion", TODO, FIXME)
3. Conditional checks ("si no mejora", "si vuelve a pasar")
4. Incomplete plan steps not yet executed
5. User deferrals ("luego lo veo", "manana checo")
6. Unfixed bugs discovered this session
7. Tests not run
8. Documentation gaps

For EACH new pendiente, emit one event:

```bash
python3 "$JBIN/journal-emit.py" --type pendiente.add --text "<texto del pendiente>" \
  --prioridad Alta|Media|Baja --origen "[[sessions/DATE-SLUG]]"
```

It prints the id. Do NOT also edit the files. The compactor (Step 3c) writes both tiers:
**Tier 2** the line `- [ ] <texto> — _origen: [[sessions/DATE-SLUG]]_ — _creado: <today>_ — _id: p-…_`
right under the priority header of `memory/_pendientes.md`; **Tier 3** a row in
`memory/pendientes/YYYY-MM.md` with the standard columns (#, Pendiente, Prioridad, Creado, Origen,
Resuelto blank, Sesion resolucion blank). Identity = text + origin + day: two agents that emit the
same pendiente the same day produce the same id and the line is written once.

**Fallback (no JBIN)**: write the Tier 2 line (without `_id`) and the Tier 3 row by hand.

### Step 3c — Compactar

```bash
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

It must print `JOURNAL applied=N quarantined=0 pending_left=0`. If `quarantined>0`, open each
`memory/.journal/quarantine/*.reason` (a hand-edited anchor, an id collision, a broken JSON), apply
that change by hand, delete the `.json`/`.reason` pair, and report it in Step 7. If it prints
`JOURNAL busy`, another agent holds the lock right now: run it again after a few seconds. This
runs BEFORE Step 5b and Step 6 so the prune and the commit see the applied state.

## Step 4: Learnings — DUAL WRITE (always)

Review session for new patterns, gotchas, rules, or mistakes discovered.

**Tier 3**: Add each learning to the relevant memory/learnings/<topic>.md. Create new topic file if needed.
When creating a NEW topic file, include `importance: <0-10>` and `last_verified: DATE` in its frontmatter (salience for recall + staleness tracking; see /audit-3t). Critical, broadly-applicable rules ≈ 8-10; niche/contextual rules ≈ 3-5. Both fields are optional — recall defaults importance to 5.
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

**Recall index:** no action needed. The derived recall index (`~/.claude/projects/<encoded>/.recall-index.jsonl`, consumed by the UserPromptSubmit hook) auto-rebuilds on the next prompt because the memory files you just wrote are newer than the index.

## Step 5c: Seal frontmatter (deterministic guarantee)

You just hand-wrote Tier-3 files. Don't trust yourself to have gotten every frontmatter
block right — enforce it deterministically. Locate and run the seal script; it PREPENDS a
minimal `---` block (type/date/status) to any typed file that's missing one, and is a no-op
if you wrote them correctly. Idempotent, atomic, never touches the body.

```bash
MEMORY_DIR="memory"   # the directory located in Step 0 (Model B); use the Model A path otherwise
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py" ]; then
  SEAL="${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py"
else
  SEAL=$(find "$HOME/.claude/plugins" -name "ensure-frontmatter.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
fi
[ -n "$SEAL" ] && python3 "$SEAL" "$MEMORY_DIR" --apply
```
If it reports `frontmatter_sealed=N` with N>0, note it for the Step 7 report — it means a
file slipped through without frontmatter and was auto-repaired (importance is left to /enrich-3t).

## Step 5d: Redact secrets (deterministic gate — runs BEFORE any commit)

Session/plan/research digests can capture real API keys, tokens, or private keys pasted
verbatim from the work. Step 6 runs `git add memory/`, so in any project where `memory/` is
NOT gitignored, an unredacted secret would be committed and (on push) leak. A "remember to
redact" rule is not enough — enforce it deterministically. Run the scanner in `--apply` mode
so it replaces each detected secret VALUE with `<REDACTED>` in place. It skips values already
in safe form (`$VAR`, `<REDACTED>`, placeholders), so it's idempotent and a no-op when clean.

```bash
MEMORY_DIR="memory"   # the directory located in Step 0 (Model B); use the Model A path otherwise
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/scan-secrets.py" ]; then
  SCAN="${CLAUDE_PLUGIN_ROOT}/bin/scan-secrets.py"
else
  SCAN=$(find "$HOME/.claude/plugins" -name "scan-secrets.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
fi
[ -n "$SCAN" ] && python3 "$SCAN" "$MEMORY_DIR" --apply
```

If it reports `secrets_redacted=N` with N>0, **tell the user explicitly in the Step 7 report**:
list the file:line of each finding (the output is already masked — never echo the secret) and
warn that **any key that was committed/pushed in a previous checkpoint is compromised and must
be rotated** — redaction here only protects future commits, it does not un-leak history.

## Step 6: Git commit (best-effort)

Memory files are already saved (Steps 1-5). The git commit is a convenience — if git is unavailable, skip it gracefully.

**6a. Check git availability:**

Run: `command -v git && git rev-parse --is-inside-work-tree 2>/dev/null`

If this fails → set GIT_SKIP = "git not available or no repository initialized" and jump to 6d.

**6b. Stage changes:**

Run: `git add memory/`
Then check: `git diff --cached --name-only -- memory/`

If nothing is staged → set GIT_SKIP = "no changes staged (memory/ may be in .gitignore or no changes to commit)" and jump to 6d.

**6c. Commit:**

Run:
```
git commit -m "checkpoint: DATE-SLUG — summary"
```

If the commit succeeds: get the short hash and record it in the session log `## Commits` section and `_session-index.md` Commit column. Do NOT amend to embed the hash into that same commit — a commit cannot contain its own hash: writing the hash changes the tree, which produces a new hash, and amending to "fix" the mismatch loops forever. Leave the hash annotation as an uncommitted forward reference; it rolls into the next checkpoint's commit, exactly like the `## Como retomar` snippet already does in Step 8.

If the commit fails (e.g., user.name/user.email not configured) → set GIT_SKIP = the error message.

**6d. If GIT_SKIP is set:**

- Write in session log `## Commits`: "Git commit skipped: [GIT_SKIP reason]"
- Set commit hash to "N/A" in `_session-index.md`
- Do NOT stop — continue to Step 7

## Step 7: Report

Tell the user: session path, N pendientes extracted, M resolved, journal result (`applied=N`, and any quarantined event with its reason), N learnings added, plans registered (Y/N), research registered (Y/N), indexes updated, N rows pruned from indexes (if any), frontmatter sealed (if N>0), **secrets redacted (if N>0, with file:line list + rotate-your-keys warning)**, git result (commit hash OR reason skipped).

## Step 8: Como retomar — snippet de continuidad

Genera un prompt breve y autosuficiente que el usuario pueda copiar y pegar al iniciar la proxima sesion (despues de `/exit` o `/clear`) para retomar contexto sin pensar.

**Plantilla fija de 3 lineas (todas obligatorias)**:

```
Retomamos: <contexto-1-linea>.
Lee memory/sessions/DATE-SLUG.md para el contexto completo.
Proximo paso: <next-step>. Antes de actuar, dime en 3 lineas donde quedamos.
```

Reglas para llenar los slots:

- `<contexto-1-linea>`: una frase que describa el trabajo principal de la sesion (max 90 chars). Toma como base la primera linea de ## Contexto del session file.
- `<next-step>`: la accion mas inmediata pendiente, en orden de preferencia:
  1. El pendiente nuevo de mayor prioridad creado en Step 3b de esta sesion.
  2. Si no hay nuevo, el pendiente existente de mayor prioridad relacionado con el trabajo de la sesion.
  3. Si tampoco aplica, escribir literalmente `revisar _pendientes.md y proponer siguiente prioridad`.

La ultima linea `Antes de actuar, dime en 3 lineas donde quedamos.` es INVARIABLE — fuerza al agente de la siguiente sesion a leer el session file y confirmar contexto antes de tocar nada.

**8a. Persistir en el session file**:

Reemplaza el placeholder `<filled in Step 8>` de la seccion `## Como retomar` con el snippet de 3 lineas dentro de un bloque de codigo:

````markdown
## Como retomar

```
Retomamos: <contexto-1-linea>.
Lee memory/sessions/DATE-SLUG.md para el contexto completo.
Proximo paso: <next-step>. Antes de actuar, dime en 3 lineas donde quedamos.
```
````

**8b. Imprimir al terminal**:

Despues del reporte de Step 7, imprime el bloque al usuario con separadores visuales para que sea facil de identificar y copiar:

```
─── ¿Como retomar en la siguiente sesion? ───
Copia y pega esto al iniciar una nueva sesion de Claude Code:

Retomamos: <contexto-1-linea>.
Lee memory/sessions/DATE-SLUG.md para el contexto completo.
Proximo paso: <next-step>. Antes de actuar, dime en 3 lineas donde quedamos.
─────────────────────────────────────────────
```

No agregues git commit aqui — el cambio al session file ya quedo dentro del flujo de Step 6, pero como Step 8 corre DESPUES, este `## Como retomar` no estara en el commit. Es aceptable: el snippet vive en disco y el commit es best-effort. Si el usuario quiere comitearlo, puede `git add memory/sessions/DATE-SLUG.md && git commit --amend --no-edit` manualmente o esperar al proximo checkpoint.
