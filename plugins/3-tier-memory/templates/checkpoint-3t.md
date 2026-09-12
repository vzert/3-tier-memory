---
description: Save memory checkpoint — session log, action items, learnings, indexes, git commit
---

# Memory Checkpoint

Save the current session state to the 3-tier memory system. Execute ALL steps in order.

CORE RULES:
- Dual-write ALWAYS for sessions, action items, and learnings (Tier 2 index + Tier 3 file)
- Plans and research: SCAN for signals below — register if ANY signal found

## Step 0: Locate memory directory and the journal scripts

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).
Read `memory/MEMORY.md` to confirm the system is initialized.

Since v2.12.0 you do NOT edit the shared indexes (`_pendientes.md`, `pendientes/YYYY-MM.md`,
`_session-index.md`, `_learnings.md`, `_plans-index.md`, `_research-index.md`) or the rule
numbering of `learnings/<topic>.md` by hand. Several agents may be checkpointing on this machine
at the same time, and a hand edit silently drops their lines (Claude Code only warns; it does not
block). Every change is an EVENT emitted with `journal-emit.py`; a single compactor
(`journal-compact.py`) applies the events under a lock, as anchored deltas. Tier-3 files that
belong to this session alone (`sessions/DATE-SLUG.md`, `plans/plan-<slug>.md`,
`research/<slug>.md`) are still written directly: one writer per file. Optional strict guard: with
`journal_strict=1` in `memory/.memory-config` the plugin's PreToolUse hook denies direct `Edit`/`Write`
on those index files (off by default; the "Fallback (no JBIN)" branches below are then unavailable —
set it to `0` for a deliberate hand edit). Locate the scripts once:

```bash
MEMORY_DIR="memory"   # the directory located above (Model B); use the Model A path otherwise
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/journal-emit.py" ]; then
  JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
elif [ -f "plugins/3-tier-memory/bin/journal-emit.py" ]; then
  JBIN="$PWD/plugins/3-tier-memory/bin"     # the plugin's own repo: dogfood the working tree, not the cache
else
  # Ruta del plugin INSTALADO: la version mas alta de `installed_plugins.json`
  # (si el plugin llega por varios marketplaces, cual esta activo no se sabe).
  # `find ... | head -1` devolvia una version ARBITRARIA del
  # cache (medido 2026-09-11: 2.13.2 con 2.17.1 instalada), y un checkpoint escribia
  # los indices con scripts cuatro versiones viejos, en silencio.
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  JEMIT=${_B:+$_B/journal-emit.py}
  JBIN=${JEMIT:+$(dirname "$JEMIT")}   # empty when find found nothing (dirname "" would give ".")
fi
[ -n "$JBIN" ] && [ -f "$JBIN/journal-compact.py" ] && echo "JBIN=$JBIN" || echo "JBIN=NONE"
```

If it prints `JBIN=NONE` (plugin older than 2.12.0), use the manual edits marked **Fallback**
in each step and say so in the Step 7 report.

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

## Callejones sin salida
- <what was tried> → <why it failed> → <what to do instead>
<or "Ninguno">

## Pendientes
<filled in Step 3d — leave this placeholder for now>

## Commits
<filled in Step 6>

## Como retomar
<filled in Step 8>

## Recordatorios de calendario
<filled in Step 8c-2 — borra esta seccion si no hubo pendientes con fecha futura>

## Related
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
- [[_plans-index]] (if plan work this session)
- [[_research-index]] (if research this session)
```

**`## Callejones sin salida` — la seccion que la sesion siguiente no puede reconstruir sola.**
Todo lo demas del session file registra lo que SI salio; esto registra lo que se intento y no
funciono, que es la informacion mas cara de la sesion y la unica que nadie puede recuperar leyendo
el resultado. Escribe una linea por callejon, con las tres partes: **que se intento**, **por que
fallo** (con la evidencia, no con una impresion), y **que hacer en su lugar**. Cuenta como callejon:
un enfoque que se abandono a mitad, una medicion que resulto mal calibrada, una herramienta o
libreria que no servia para el caso, un diseno que un revisor rompio, una hipotesis que los datos
refutaron. NO cuenta un bug que arreglaste (eso va en `## Bugs fixed`) ni trabajo que quedo a medias
(eso es un pendiente). Si de verdad no hubo ninguno, escribe "Ninguno" — pero revisa primero: una
sesion sustancial sin ningun callejon suele significar que no se exploro nada, o que se te olvido.
Step 8 lee esta seccion para llenar la linea `No repitas:` del snippet de continuidad.

Set `importance` to a salience score 0-10 (Generative-Agents style): how reusable/critical is this session for future recall? Routine work ≈ 3-4, normal feature work ≈ 5-6, an architectural decision or hard-won fix ≈ 8-10. This score feeds the relevance-recall ranking (UserPromptSubmit hook). If unsure, omit it — the recall engine defaults to 5.

**Tier 2**: emit one `session.add` event (the compactor writes the row in Step 5a):

```bash
python3 "$JBIN/journal-emit.py" --type session.add --slug "DATE-SLUG" --date DATE \
  --status "completada|con pendientes" --summary "<one-line summary, no newlines>"
```

The compactor inserts `| DATE | [[sessions/DATE-SLUG\|SLUG]] | <status> | <summary> | |` at the
top of the `## Sessions` table of `memory/_session-index.md` and prunes that table to the 10
most recent rows by date. The Commit cell is filled in Step 6c with a second `session.add`
(same slug, `--commit`). Do NOT edit the index by hand.

**Fallback (no JBIN)**: add the row by hand, commit hash "filled in Step 6".

**Do NOT write pendiente ids in this file yet.** A pendiente's id is
`sha1(text + creado + origen)[:10]` — the journal computes it in Step 3 and prints it. Writing
the `## Pendientes` section now means inventing ids that no event will ever match, and once an
invented id is referenced here, re-emitting the pendiente correctly would produce a *different*
id, so the natural next move is to hand-write Tier 2 as well — which is exactly what breaks the
dual write. Measured 2026-09-10 in one project: 31 of 118 ids in `_pendientes.md` did not match
the hash of their own line, and 49 pendientes had no Tier 3 row at all. Leave the placeholder;
Step 3d fills it.

This is an instruction, not a gate, and you should know where the gate stops: `journal_strict=1`
denies the `Edit`/`Write`/`MultiEdit` tools on the shared indexes, but it is a PreToolUse hook and
does **not** see a shell redirect, so `sed -i` or a heredoc through `Bash` still writes them. What
catches a bypass is Step 3-pre's `repair-dualwrite.py`, after the fact: `rows_added>0` or
`ids_invented>0` means someone wrote Tier 2 outside the journal, whichever tool they used.

## Step 3: Pendientes — DUAL WRITE via journal (always)

Pendientes go through the journal too (`JBIN` and `MEMORY_DIR` from Step 0): `pendiente.add` /
`pendiente.resolve` events, applied as anchored deltas (insert under the priority header, delete
by id, fill a cell by id).

This step runs in FOUR sub-phases, in order: 3-pre, 3a, 3b, 3c. Do not merge them.

### Step 3-pre — Fresh state + ids

```bash
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"       # apply whatever other agents left pending
python3 "$JBIN/enrich-memory.py" "$MEMORY_DIR" --apply --only creado,id   # legacy lines get `_creado` (if missing) and `_id: p-…_`; idempotent
python3 "$JBIN/repair-dualwrite.py" "$MEMORY_DIR" --apply --fix-pipes    # Tier 2 lines with no Tier 3 row; rows a `|` made unclosable; idempotent
```

`repair-dualwrite` prints `rows_added=N pipes_broken=N pipes_fixed=N unaligned_rows=N unrepairable=N odd_values=N header_issues=N ids_invented=N missing_data=N`.
**A non-zero `rows_added` or `ids_invented` means someone wrote Tier 2 outside the journal since the
last checkpoint** — the dual write was bypassed. Without this repair those pendientes lose their
resolution date and closing session when they are eventually closed. Report the counts in Step 7;
if `missing_data>0`, the listed lines lack `_creado` or a priority header and need a look by hand.
**`unaligned_rows` or `unrepairable` above 0 is the serious one**: a Tier 3 row that cannot be
mapped onto the canonical columns at all, or that the repair refuses to touch because fixing it
automatically would move data between columns. Neither is repaired for you — report the file and
line in Step 7 and check it against its Tier 2 line before rewriting anything. Read the GRAVE line
itself: it prints what was MEASURED (cells, raw `|`, escaped `\|`) and lists the candidate causes.
It no longer claims the data is lost, because that was only one of them — a hand-written row
missing middle columns produces the same signal with nothing lost.
`odd_values>0` and `header_issues>0` are warnings, not damage: the first is a row that is aligned
fine but whose `Prioridad` is not Alta/Media/Baja (fix the value, not the row); the second is a
monthly whose header is shorter than the canonical 7 columns, so a close has nowhere to record the
session that closed it. Neither is fixed automatically — rewriting a header is a migration.

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
  --prioridad Alta|Media|Baja --origen "[[sessions/DATE-SLUG]]" [--revisar YYYY-MM-DD]
```

**`--revisar` cuando el pendiente nombra una fecha futura** (`revisar el 2026-09-22`, `target
2026-10-01`, `T+7` resuelto a fecha). Escribe la fecha **como campo**, no solo en prosa: el
compactador anade `— _revisar: YYYY-MM-DD_` a la linea de Tier 2. Sin el campo la fecha no la lee
nadie — medido 2026-09-11: **395 de 996 pendientes abiertos llevan una fecha ya vencida escrita en
prosa y ningun codigo la miro nunca**. Con el campo tiene dos consumidores: `expire-pendientes.py`
(no toca un item cuya ventana no ha vencido; caduca el que si) y el Step 8c, que imprime el
recordatorio de calendario. `--revisar` no cambia el `_id`: la ventana no es parte de la identidad.

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
runs now so the reconciliation report is fresh; Steps 2, 4 and 5 emit more events, and Step 5a
compacts everything again before the commit.

### Step 3d — Rellenar `## Pendientes` del session log

Only now do the ids exist. Replace the placeholder left in Step 2 with the pendientes this
session touched, each with the id the journal actually assigned:

```markdown
## Pendientes
- [ ] <texto corto> — `p-xxxxxxxxxx`
- [x] <texto corto> — `p-yyyyyyyyyy` (resuelto)
<or "Ninguno">
```

Take every id from the `journal-emit.py` stdout of Steps 3a/3b, or from the line the compactor
wrote in `_pendientes.md` — **never type one from memory and never make one up**. If an id you
wrote here does not appear in `memory/_pendientes.md` or in `memory/pendientes/YYYY-MM.md`, it is
invented: drop it and re-read the file.

## Step 4: Learnings — DUAL WRITE (always)

Review session for new patterns, gotchas, rules, or mistakes discovered.

For EACH learning, emit one `learning.add` event; the compactor writes both tiers in Step 5a:

```bash
python3 "$JBIN/journal-emit.py" --type learning.add --topic <topic-slug> \
  --text "**<Rule name>** — <one-line explanation, no newlines>" \
  [--section "<## header to append under, existing or new>"] \
  [--quickref "**<Rule name>** — <short form for the Quick Reference>"] \
  [--title "<Topic Title>" --when "<when to consult>" --importance <0-10>]
```

**Tier 3**: the compactor appends the rule to `memory/learnings/<topic>.md` with the next number
(`max + 1`, assigned under the lock — two agents never get the same number), at the end of
`--section` (created before `## Related` if it does not exist) or of the last block before
`## Related`. A topic file that only uses bullets gets a bullet. If the topic file does not exist
it is created with frontmatter (`importance` from `--importance`, `last_verified: DATE`; recall
defaults importance to 5 — critical, broadly-applicable rules ≈ 8-10, niche ≈ 3-5).
**Tier 2**: a row `| <title> | [[learnings/<topic>]] | <when> |` is added to the Topic Files table
of `memory/_learnings.md` if missing; `--quickref` adds the short form to `## Quick Reference`
with the next number. Identity = topic + text: the same rule emitted twice is written once.

**Fallback (no JBIN)**: append the rule with the next number by hand, create the topic file with
`importance` and `last_verified` in its frontmatter, and update `_learnings.md` yourself.

If no learnings this session, skip.

## Step 5: Plans & Research — DUAL WRITE (scan for signals)

Do NOT skip this step. Actively scan the conversation for these signals:

### Plan signals — if ANY found, register the plan:
- Plan mode was used (ExitPlanMode, "plan mode", plan file created/edited)
- A plan file exists in `~/.claude/plans/` from this session
- Implementation steps were discussed or executed
- User said "plan", "diseño", "arquitectura", "implementacion"

**If plan signals found:**
- Tier 3: create/update memory/plans/plan-<slug>.md with context, decisions, steps, outcome (direct write: one writer per file)
- Tier 2: emit one `plan.upsert` event (the compactor writes the row in Step 5a):
  ```bash
  python3 "$JBIN/journal-emit.py" --type plan.upsert --slug <slug> --title "<Plan title>" \
    --status draft|active|testing|completed|abandoned --date DATE --sesion "[[sessions/DATE-SLUG]]" \
    [--pendientes N] [--learnings "N rules"] [--inline]
  ```
  New plan → row `| [[plans/plan-<slug>\|<title>]] | <status> | DATE | <sesion> | ... |` at the top of
  `## Plans` (`--inline` writes `<title> (inline)` instead of the link). Existing plan (matched by
  `plans/plan-<slug>` or by title) → only the cells you pass are updated; Fecha never changes. The
  compactor prunes completed/abandoned rows to the 5 most recent by date.
- Add wikilink in session log ## Plans section and ## Related

**Fallback (no JBIN)**: add/update the row in memory/_plans-index.md by hand.

### Research signals — if ANY found, register the research:
- Web searches or web fetches were performed
- Documentation was consulted (library docs, API references)
- Options/alternatives were compared or evaluated
- User said "investiga", "busca", "compara", "evalua", "analiza"

**If research signals found:**
- Tier 3: create/update memory/research/<slug>.md with context, findings, conclusion (direct write: one writer per file)
- Tier 2: emit one `research.upsert` event (the compactor writes the row in Step 5a):
  ```bash
  python3 "$JBIN/journal-emit.py" --type research.upsert --slug <slug> --tema "<Topic>" \
    --status active|completed [--next-step "<next step>"] [--origen "[[sessions/DATE-SLUG]]"] \
    [--resultado "<one-line conclusion>"] [--inline]
  ```
  `active` → row in `## Active Research` (Tema, Next step, Origen, Archivo); `completed` → row in
  `## Completed Research` (Tema, Resultado, Archivo), removing it from Active if it was there. A
  completed research never moves back to Active (reopen by hand). Archivo is `[[research/<slug>]]`
  or `(inline)`, followed by `_completado: DATE_` on completed rows (DATE = `--date`, today by
  default): the compactor prunes Completed Research to the 5 most recent by that date; rows without
  it (hand-written, or older than 2.12.0) are never pruned.
- Add wikilink in session log ## Research section and ## Related

**Fallback (no JBIN)**: add/update the row in memory/_research-index.md by hand.

### If NO signals found for either:
Write "Ninguno" in the session log sections and skip the index updates.

## Step 5a: Compactar (all events from Steps 2-5)

```bash
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

It must print `JOURNAL applied=N quarantined=0 pending_left=0`. Same handling as Step 3c for
`quarantined>0` (read each `.reason`, apply by hand, delete the pair, report) and for `JOURNAL busy`
(retry after a few seconds). This MUST run before Step 5d and Step 6: the secrets scan and the
commit have to see the applied rows. Skip if `JBIN=NONE`.

## Step 5b: Prune indexes

Keep Tier 2 indexes lean. Tier 3 detail files are NEVER deleted — only index rows are removed.

Since v2.12.0 the compactor prunes on every event it applies, always by date and never by
position: `_session-index.md` to the 10 most recent sessions (Fecha column), `_plans-index.md` to
active/draft/testing + the 5 most recent completed/abandoned (Fecha column), `_research-index.md`
Completed Research to the 5 most recent by the `_completado: DATE_` mark in the Archivo cell. Rows
without a valid date (hand-written, or older than 2.12.0) are never pruned by the compactor. Do NOT
prune those three tables by hand (it is the same race the journal removes); if legacy undated rows
pile up in Completed Research, add `_completado: DATE_` to them once and the compactor takes over.

### _pendientes.md
Remove any `- [x]` items. Completed pendientes should already be gone (Step 3), but clean up stragglers.

### _learnings.md
No pruning — bounded by design.

**Fallback (no JBIN)**: prune sessions and plans by hand with the limits above too. Note pruned row count for Step 7 report.

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
  # Ruta del plugin INSTALADO: la version mas alta de `installed_plugins.json`
  # (si el plugin llega por varios marketplaces, cual esta activo no se sabe).
  # `find ... | head -1` devolvia una version ARBITRARIA del
  # cache (medido 2026-09-11: 2.13.2 con 2.17.1 instalada), y un checkpoint escribia
  # los indices con scripts cuatro versiones viejos, en silencio.
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "ensure-frontmatter.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  SEAL=${_B:+$_B/ensure-frontmatter.py}
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
  # Ruta del plugin INSTALADO: la version mas alta de `installed_plugins.json`
  # (si el plugin llega por varios marketplaces, cual esta activo no se sabe).
  # `find ... | head -1` devolvia una version ARBITRARIA del
  # cache (medido 2026-09-11: 2.13.2 con 2.17.1 instalada), y un checkpoint escribia
  # los indices con scripts cuatro versiones viejos, en silencio.
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "scan-secrets.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  SCAN=${_B:+$_B/scan-secrets.py}
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

If the commit succeeds: get the short hash, record it in the session log `## Commits` section, and fill the `_session-index.md` Commit column through the journal:

```bash
python3 "$JBIN/journal-emit.py" --type session.add --slug "DATE-SLUG" --date DATE --commit '`<short-hash>`'
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

(**Fallback (no JBIN)**: write the hash into the Commit cell by hand.) Do NOT amend to embed the hash into that same commit — a commit cannot contain its own hash: writing the hash changes the tree, which produces a new hash, and amending to "fix" the mismatch loops forever. Leave the hash annotation as an uncommitted forward reference; it rolls into the next checkpoint's commit, exactly like the `## Como retomar` snippet already does in Step 8.

If the commit fails (e.g., user.name/user.email not configured) → set GIT_SKIP = the error message.

**6d. If GIT_SKIP is set:**

- Write in session log `## Commits`: "Git commit skipped: [GIT_SKIP reason]"
- Set commit hash to "N/A" in `_session-index.md`
- Do NOT stop — continue to Step 7

## Step 7: Report

Tell the user: session path, N pendientes extracted, M resolved, journal result (`applied=N` for Steps 3c, 5a and 6c together, any quarantined event with its reason, and whether any **Fallback** path was used), N learnings added, plans registered (Y/N), research registered (Y/N), indexes updated, N rows pruned by hand (if any), frontmatter sealed (if N>0), **secrets redacted (if N>0, with file:line list + rotate-your-keys warning)**, git result (commit hash OR reason skipped).

## Step 8: Como retomar — snippet de continuidad

Genera un prompt breve y autosuficiente que el usuario pueda copiar y pegar al iniciar la proxima sesion (despues de `/exit` o `/clear`) para retomar contexto sin pensar.

**Plantilla de 6 lineas: 4 obligatorias y 2 condicionales**:

```
Retomamos: <contexto-1-linea>.
Lee memory/sessions/DATE-SLUG.md para el contexto completo.
Proximo paso: <next-step>.
Sigue abierto: <pendientes de esta sesion>.               <- omitir si no quedo ninguno mas
No repitas: <callejones sin salida>.                      <- omitir si no hubo
Terminas cuando: <done-bar>.                              <- omitir si no aplica
Antes de actuar, dime en 3 lineas donde quedamos.
```

Reglas para llenar los slots:

- `<contexto-1-linea>`: una frase que describa el trabajo principal de la sesion (max 90 chars). Toma como base la primera linea de ## Contexto del session file.
- `<next-step>`: la accion mas inmediata pendiente, en orden de preferencia:
  1. El pendiente nuevo de mayor prioridad creado en Step 3b de esta sesion.
  2. Si no hay nuevo, el pendiente existente de mayor prioridad relacionado con el trabajo de la sesion.
  3. Si tampoco aplica, escribir literalmente `revisar _pendientes.md y proponer siguiente prioridad`.
  Incluye aqui los umbrales o criterios que ya se acordaron en esta sesion (un numero, un limite,
  una condicion de exito), si los hay. Sin ellos la sesion siguiente los vuelve a negociar contigo.
- `<pendientes de esta sesion>`: **los pendientes que esta sesion dejo abiertos, ademas del que
  ya va en `Proximo paso`** — los que emitiste en Step 3b mas los que en Step 3a quedaron
  `still-open` y tocan este trabajo. Nombra cada uno en media linea, con su `_id: p-…_`, separados
  por ` · `. **Maximo 3**; si hay mas, cierra con `+N mas en _pendientes.md`. **Omite la linea
  entera si el unico pendiente de la sesion es el que ya esta en `Proximo paso`** — repetirlo no
  anade nada.

  **Por que existe esta linea.** Medido sobre **491 pendientes de 176 sesiones** (2026-09-11,
  salidas congeladas en `.goalspec/snippet-rows-empate-*.json`): los que el snippet mencionaba
  cerraron el **35%**; los que solo quedaron en la lista, el **19%**. Son **16 puntos**, con umbral
  fijado antes en 15. El emparejador de cierre es un proxy por solape de palabras, y su empate iba
  a "cerrado": invertido da **31% vs 14% = 17 puntos**, asi que el sesgo no creaba el efecto. La medicion no puede separar el efecto del snippet del hecho de que el agente elige para
  `Proximo paso` lo que ya juzgaba mas accionable — asi que acota el techo, no lo demuestra. Aun
  asi, nombrarlos cuesta una linea y no nombrarlos es como se pierden.

- `<callejones sin salida>`: **copia condensada de la seccion `## Callejones sin salida`** del
  session file, solo los que afectan al proximo paso. **Si el session file no tiene esa seccion**
  (lo escribio una version anterior a 2.12.2, o un /backfill-3t anterior a 2.15.1), no la
  crees ni migres nada: omite la linea `No repitas:` y sigue. El resto del snippet no depende
  de ella. Una linea, con el "que hacer en su lugar"
  incluido: `X no funciona porque Y — usa Z`. **Omite la linea entera si esa seccion dice "Ninguno"**
  o si ningun callejon toca el proximo paso; no la rellenes con ruido. Esta es la linea que evita
  que la sesion siguiente repita, a tu costa, el camino que ya se descarto.
- `<done-bar>`: cuando se considera terminado el proximo paso — el entregable concreto y su limite
  de alcance (`un veredicto con numero, sin implementar el resto del plan`). Sacalo del plan si hay
  uno, del criterio de aceptacion si existe, o de lo que el usuario pidio. **Omite la linea si el
  proximo paso es exploratorio** y su final no se puede nombrar de antemano: un done-bar inventado
  es peor que ninguno, porque la sesion siguiente lo trata como acordado contigo.

La ultima linea `Antes de actuar, dime en 3 lineas donde quedamos.` es INVARIABLE — fuerza al agente
de la siguiente sesion a leer el session file y confirmar contexto antes de tocar nada. Va siempre al
final, sola, aunque se omitan las condicionales.

**Por que estas dos lineas.** Las tres originales transmitian solo lo que salio bien. Un snippet que
dice donde quedamos pero no que ya se descarto hace que la sesion siguiente vuelva a intentar el
enfoque muerto — y uno sin done-bar la deja expandirse hasta que el usuario la corta a mano. Son
condicionales, no opcionales: si la informacion existe, la linea va.

**8a. Persistir en el session file**:

Reemplaza el placeholder `<filled in Step 8>` de la seccion `## Como retomar` con el snippet dentro de un bloque de codigo (aqui con las dos condicionales presentes; omite la linea entera cuando no apliquen):

````markdown
## Como retomar

```
Retomamos: <contexto-1-linea>.
Lee memory/sessions/DATE-SLUG.md para el contexto completo.
Proximo paso: <next-step>.
Sigue abierto: <pendientes de esta sesion>.
No repitas: <callejones sin salida>.
Terminas cuando: <done-bar>.
Antes de actuar, dime en 3 lineas donde quedamos.
```
````

Ejemplo real, con las 6 lineas:

````markdown
```
Retomamos: plan v2.13.0 ratificado para que los pendientes dejen de ser un cementerio.
Lee memory/sessions/2026-09-09-pendientes-cementerio-plan.md para el contexto completo.
Proximo paso: medir en seco la precision del cierre por silencio sobre los 98 vencidos (umbrales ya acordados: >=90% de aciertos, cero cierres de items que pedian consultar un dato).
Sigue abierto: mover measure-pendientes-v2.13.0.py a bin/ si el plan se implementa _id: p-ea5dab51be_ · falsificar los dos claims negativos de §3 _id: p-77c1a0b3e2_.
No repitas: clasificar los pendientes con un regex sobre su texto — fallo tres veces y un revisor rompio las tres; leelos y clasifica con criterio declarado.
Terminas cuando: haya un veredicto con numero (entra / no entra) y, si entra, el diseno de las tres senales de deteccion. Nada mas del plan en esa sesion.
Antes de actuar, dime en 3 lineas donde quedamos.
```
````

**8b. Imprimir al terminal**:

Despues del reporte de Step 7, imprime el bloque al usuario con separadores visuales para que sea facil de identificar y copiar:

```
─── ¿Como retomar en la siguiente sesion? ───
Copia y pega esto al iniciar una nueva sesion de Claude Code:

Retomamos: <contexto-1-linea>.
Lee memory/sessions/DATE-SLUG.md para el contexto completo.
Proximo paso: <next-step>.
Sigue abierto: <pendientes de esta sesion>.
No repitas: <callejones sin salida>.
Terminas cuando: <done-bar>.
Antes de actuar, dime en 3 lineas donde quedamos.
─────────────────────────────────────────────
```

Imprime exactamente las mismas lineas que escribiste en 8a — si ahi omitiste una condicional, aqui
tambien. El usuario copia de la terminal; un snippet que no coincide con el del session file crea
dos versiones de la verdad.

**8c. Recordatorio de calendario para los pendientes con fecha futura**:

Si algun pendiente de esta sesion (nuevo o reconciliado) **nombra una fecha posterior a hoy** —
`revisar el 2026-09-22`, `target 2026-10-01`, `T+7`, `en 2 semanas` resuelto a fecha — imprime
**un bloque aparte por cada uno, despues del snippet**. Imprime maximo 2; si hay mas, di
`+N con fecha futura en _pendientes.md`. El tope es para no llenar la terminal: en el session
file (8c-2) van **todos**, sin tope.

**Va fuera del snippet, no dentro.** El snippet se pega al agente de la sesion siguiente; una
instruccion de calendario pegada ahi es ruido para el agente y se pierde para ti. Este bloque se
dirige a ti, y lo que lleva dentro del fence es un prompt para que TU lo guardes en el evento.

**La regla de division.** Una sola, y resuelve cualquier duda de donde va cada cosa:

- **Dentro del fence** va todo lo que el AGENTE necesita para actuar: el `Proyecto:`, el `_id: p-…`,
  la ruta del session file, las cifras y el criterio, y la clausula `Si ya no aplica, cierralo con
  /checkpoint-3t`.
- **Fuera del fence** va solo lo que TU necesitas para decidir si vale la pena abrir el portatil:
  Titulo —con el proyecto delante— y Descripcion.

Nunca subas el id al Titulo, nunca saques la clausula de cierre del fence.

**El proyecto es el unico dato que va en los dos lados, y no es redundancia.** Responde dos
preguntas distintas en dos momentos distintos: fuera del fence contesta *cual de mis recordatorios
es este* cuando miras el mes con recordatorios de varios proyectos encima; dentro contesta *desde
donde se corre esto* cuando pegas el prompt. Sin la linea de dentro, `Contexto:` es una ruta
relativa que no resuelve contra nada.

````
─── Recordatorio para el <FECHA> ───
Ponlo en tu calendario:

Título: [<proyecto>] <la pregunta que se responde ese dia, en una linea>

Descripción:
<2-4 lineas de prosa: que se construyo o decidio, por que, que se
decide ese dia, y que pasa segun el resultado>

Pega esto dentro del evento (es el prompt para el agente):
```
Proyecto: <proyecto> — <ruta absoluta del proyecto>
Retomamos: <pendiente en una linea> _id: p-…_
Contexto: memory/sessions/DATE-SLUG.md
Comprueba: <que hay que mirar ese dia, con las cifras y el criterio si se acordo uno>
Si ya no aplica, cierralo con /checkpoint-3t en vez de dejarlo abierto.
```
────────────────────────────────────
````

- `Título`: abre con `[<proyecto>]` y sigue con la pregunta. Tiene que ser legible en la vista de
  mes de un calendario, donde solo se ve esa linea. Nombra **la cosa y la pregunta**, no el item:
  `[3-tier-memory] ¿La linea "Sigue abierto:" cierra mas pendientes?`, no `Medir p-cd965754ec`.
  Sin ids `p-…`, sin rutas de fichero, **~70 caracteres contando el prefijo** — el que se acorta es
  el texto de la pregunta, nunca el prefijo. El calendario corta por la derecha en vista de mes, asi
  que lo unico que sobrevive siempre es lo que va primero, y con recordatorios de varios proyectos
  encima el proyecto es justo el dato que los distingue.
- `[<proyecto>]`: el **basename del directorio raiz del proyecto**, tal cual, entre corchetes —
  `[3-tier-memory]`, `[tienda-web]`. No inventes un nombre "bonito" ni uses el del repo remoto si
  difiere: el basename es lo que veras en la ruta y en el prompt, y dos nombres para el mismo
  proyecto son dos versiones de la verdad.
- `Proyecto:` (primera linea del fence): `<basename> — <ruta absoluta>`, con la ruta **tal cual**,
  sin `~` y sin variables. `Proyecto: tienda-web — /Users/ana/Projects/tienda-web`. El
  agente que recibe este prompt puede estar arrancado en cualquier sitio; `~` depende de que el
  shell lo expanda y en Git Bash/Windows no siempre apunta a lo mismo.
- `Descripción`: prosa, 2-4 lineas, **sin cifras**. Baselines, umbrales y listas por proyecto van
  solo en `Comprueba:`, dentro del fence — la descripcion la lees en el movil para decidir si vale
  la pena abrir el portatil; las cifras son trabajo del agente. Tiene que contestar tres cosas:
  **que era el pendiente**, **que se decide ese dia**, y **que pasa segun el resultado**.
  **Si el pendiente no trae una decision detras** —se construyo algo y nunca se midio, sin criterio
  acordado— dilo tal cual en vez de inventar uno: `Se construyo X en <mes> y nunca se probo contra
  Y. No hay criterio acordado: ese dia hay que decidir uno antes de mirar nada.` Una descripcion
  seca y honesta sirve; una inventada te hace llegar a la fecha creyendo que hubo un acuerdo que
  nunca existio.

**La prueba de que la descripcion sirve**: tapa el fence y lee solo Titulo + Descripcion. Si con
eso no puedes decir de que iba el pendiente ni que vas a hacer ese dia, reescribela. Ese es
exactamente el fallo que este bloque existe para evitar. **Y la prueba del Titulo, mas dura
todavia**: tapa tambien la Descripcion. Si con esa sola linea no sabes **en que proyecto** cae el
recordatorio, el prefijo esta mal puesto o se perdio.

**Ademas, el pendiente nace con la fecha como campo**, no solo en prosa:
`journal-emit.py --type pendiente.add … --revisar YYYY-MM-DD`. El compactador escribe
`— _revisar: YYYY-MM-DD_` en la linea de Tier 2. Ese campo tiene dos consumidores reales:
`expire-pendientes.py` (no caduca un item cuya ventana aun no vence) y el propio barrido manual.

**8c-2. Persistir los recordatorios en el session file**:

Escribe los mismos bloques en el session file, en la seccion `## Recordatorios de calendario`,
entre `## Como retomar` y `## Related`. Uno por pendiente con fecha futura, **todos, sin el tope
de 2** que aplica a la terminal. Encabeza cada uno con `### <FECHA> — <Titulo>` y debajo el bloque
completo. Si no hubo ninguno, borra la seccion entera en vez de dejarla vacia.

`<Titulo>` del encabezado es **el mismo texto que la linea `Título:` del bloque, caracter por
caracter** — con su prefijo `[<proyecto>]` y con sus tildes. El resto de este fichero va sin tildes
por convencion, y esa costumbre se cuela justo aqui: en 2.15.0 el encabezado quedo con `linea/mas`
y el `Título:` con `línea/más`, dos versiones del mismo titulo en el mismo bloque. Lo encontro un
verificador externo, no la vista.

Los bloques persistidos son **identicos** a los impresos — misma regla que en 8a/8b: el usuario
copia de la terminal o del fichero indistintamente, y dos versiones del mismo recordatorio son dos
versiones de la verdad. Si en la terminal dijiste `+N con fecha futura en _pendientes.md`, en el
fichero estan los N.

**Por que este bloque.** Medido 2026-09-11: **11% de los pendientes nuevos traen una fecha
posterior a su creacion** (28 en 30 dias sobre 5 instalaciones, ~1 al dia) y **395 de 996
abiertos llevan una fecha ya vencida escrita en prosa que ningun codigo leyo nunca**. El
calendario del usuario es el unico disparador que si dispara sin cron, sin servicio externo y sin
depender de que alguien abra el proyecto ese dia. Titulo y Descripcion existen porque un evento
que solo lleva el prompt llega a su fecha sin decirle al humano de que iba: el prompt esta escrito
para el agente, y el que abre el calendario eres tu. **El proyecto se anadio por lo mismo, un nivel
mas arriba** (2.16.0): quien corre el plugin en varios proyectos acumula recordatorios de todos en
un mismo calendario, y tres campos que no dicen *donde* dejan un prompt que no se sabe desde donde
correr. El snippet de 8a/8b no tiene este problema porque se pega en el acto, sabiendo donde estas;
este se pega dentro de un mes.

No agregues git commit aqui — el cambio al session file ya quedo dentro del flujo de Step 6, pero como Step 8 corre DESPUES, ni `## Como retomar` ni `## Recordatorios de calendario` estaran en el commit. Es aceptable: el snippet vive en disco y el commit es best-effort. Si el usuario quiere comitearlo, puede `git add memory/sessions/DATE-SLUG.md && git commit --amend --no-edit` manualmente o esperar al proximo checkpoint.
