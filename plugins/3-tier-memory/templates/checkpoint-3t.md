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
- <defecto> _verificado: <test, corrida o consulta que lo comprobo en esta sesion>_
- <defecto que NO quedo cerrado y verificado> _pendiente: <id de Step 3b; lo pones en Step 3d>_
<or "Ninguno">

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

## Recomendaciones de research sin resolver
<filled in Step 8d — borra esta seccion si print-research-recomendaciones.py no imprimio nada>

## Related
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
- [[_plans-index]] (if plan work this session)
- [[_research-index]] (if research this session)
```

**`## Bugs fixed` — cada defecto declara como se cerro (2.34.0).** Cada linea de primer nivel
lleva UNO de dos campos, y lo decides al escribirla:
- `_verificado: <evidencia>_` — el arreglo se comprobo en esta sesion: el test que lo cubre, la
  corrida que lo mostro, la consulta que lo confirmo. Reescribir una regla o un parrafo NO es
  evidencia: un arreglo solo en prosa no esta verificado.
- `_pendiente: p-…_` — el defecto no quedo cerrado y verificado (Step 3b punto 9). En Step 2 aun no
  hay id: deja el campo con el texto del pendiente y pon el id en Step 3d.

Una linea de primer nivel por defecto. El campo va en el texto propio de esa linea, no en un
sub-bullet: un hijo con `_verificado:` no cierra a su padre. Cuenta todo defecto hallado en la
sesion, tambien los que el usuario senalo en vivo.
`checkpoint-audit.py` marca `SALTADO` en `bugs.cierre` una linea sin ninguno de los dos campos, o
con un `_pendiente:` que no existe en la memoria. Tambien marca `snippet.ninguno_defecto` si el
snippet dice `ninguno` y un `_pendiente:` de aqui sigue abierto e inmediato. El hook de cierre
anade una senal mas: el ultimo veredicto del adversario de goalspec en la sesion es `break` y
ningun `_pendiente:` abierto de esta seccion lo registra. Limite honesto: el script solo mide el
campo. No puede saber si un `_verificado:` es verdad, ni ver un defecto que nunca escribiste aqui
(misma regla 216 que `_bloqueado:`). Caso real: sesion 5790b9f2, un defecto senalado por el usuario
y "reescrito como pregunta" tenia la misma forma que los verificados, y `ninguno` pasaba.

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
python3 "$JBIN/normalize-pendientes.py" "$MEMORY_DIR" --apply --quiet    # the three priority headers exist; idempotent
python3 "$JBIN/enrich-memory.py" "$MEMORY_DIR" --apply --only creado,id   # legacy lines get `_creado` (if missing) and `_id: p-…_`; idempotent
python3 "$JBIN/repair-dualwrite.py" "$MEMORY_DIR" --apply --fix-pipes    # adopts orphan lines; Tier 2 lines with no Tier 3 row; rows a `|` made unclosable; idempotent
python3 "$JBIN/repair-plans-index.py" "$MEMORY_DIR" --apply    # migrates legacy 4-col plan rows to the canonical 6-col shape, re-headers if needed; idempotent
python3 "$JBIN/repair-research-index.py" "$MEMORY_DIR" --apply    # migrates by COLUMN NAME any '## Active Research'/'## Completed Research' table whose header isn't EXACTLY canonical yet (name AND order, not just the last column); idempotent
python3 "$JBIN/check-active-plans.py" "$MEMORY_DIR"    # read-only; lists active/draft/testing plans, if any
python3 "$JBIN/check-active-research.py" "$MEMORY_DIR"    # read-only; lists research with unresolved '## Recomendaciones', if any
```

`repair-plans-index.py` prints `legacy_rows_migrated=N header_rewritten=si|no unrepairable_rows=N possible_duplicates=N no_plans_table=0|1 header_unrecognized=0|1`. It runs BEFORE `check-active-plans.py` on purpose: a `_plans-index.md` still carrying the pre-journal 4-column shape (`Fecha|Plan|Status|Resumen`) under a legacy or mixed header reads its Plan/Status columns in the wrong order, so fixing the shape first is what makes the plan list `check-active-plans.py` prints trustworthy. `unrepairable_rows>0` or `possible_duplicates>0` means a row could not be migrated safely (ambiguous width, or a title collision with an existing canonical row) — read it and fix by hand; this script never guesses.

`repair-research-index.py` is the same idea one level over, for `_research-index.md` (p-cd33654290): since 2.31.5 `research.upsert` (journal-compact.py) treats any anchored `## Active Research`/`## Completed Research` table whose LAST column isn't named Archivo or File as READ-ONLY (`research_table_is_canonical`) — a new research on that table goes to quarantine instead of writing. That last-column-only check is lenient on purpose (it's what `apply_research_upsert` itself uses to decide whether to write by position), but it is NOT sufficient to call a table safely canonical: a header like `Topic|Started|Sesion|File` passes it while still writing to the wrong cells on every update. This script uses a STRICTER check (name AND order must match `TABLE_COLUMNS[header]` exactly) to decide what's already fine, and migrates everything else — closing that gap instead of inheriting it (found by an adversary sweeping the user's own real installations, 2.31.6). Measured across real installs: the legacy shapes vary by column NAME, not by a single fixed width (`Topic|Result|File|Fecha`, `Slug|Topic|Fecha|Sesion`, `Topic|File|Resultado`, …), so this script recognizes a header by mapping each column name to a role (Tema/Archivo/Resultado/Next step/Origen/fecha) instead of by position — a name outside that map, or a header without exactly one Tema and one Archivo column, is reported `header_unrecognized` and left untouched, never guessed. A column with no canonical slot (Fecha, Sesion, Started…) is anexed as text AFTER the wikilink, in Archivo — the one cell `apply_research_upsert` never rewrites by position — never into Next step/Origen/Resultado, which a normal future event replaces wholesale. It prints `active_header_rewritten=si|no active_rows_migrated=N active_unrepairable=N active_possible_duplicates=N completed_header_rewritten=si|no completed_rows_migrated=N completed_unrepairable=N completed_possible_duplicates=N no_active_table=0|1 no_completed_table=0|1 active_header_unrecognized=0|1 completed_header_unrecognized=0|1`. This is the mechanism that reaches every installation that upgrades the plugin without anyone running a one-off migration by hand: any `## Active Research`/`## Completed Research` table left in a pre-2.31.5 shape gets migrated the next time that project runs `/checkpoint-3t`, the same way `repair-plans-index.py` already does for `_plans-index.md` — idempotent, and safe to run every time because a checkpoint always ends in a git commit.

`repair-dualwrite` prints `adopted=N rows_added=N pipes_broken=N pipes_fixed=N unaligned_rows=N unrepairable=N odd_values=N header_issues=N ids_invented=N missing_data=N`.

**`check-active-plans.py` is not a repair — it is a reminder, and it exists because reading Step 5
carefully was not enough once (measured 2026-09-15, this same repo): a pendiente born while
auditing a plan's phase got closed standalone, never connected to the plan, even though the plan
itself said "if a new finding shows up, add it here as a new phase instead of leaving it loose"
and the agent had that exact instruction in front of it. If it prints any plans, read them NOW,
before Step 3a — Step 5 will ask you to act on this, but by then the pendientes are already
reconciled and it is easy to answer "## Plans: Ninguno" out of habit. It does not try to detect
the connection for you (that needs following `_origen` → "Continuacion de" → plan chains across
session files, and a wrong guess there is worse than no guess) — it only makes sure you cannot
say you never saw the list.

**`check-active-research.py` is the same reminder, one level over: a research that produced
several candidate recommendations, of which this session (or a past one) only acted on some.**
Without it, the recommendations you did NOT act on live only as prose inside a research already
marked `completed` — nothing lists them again, ever, unless someone happens to reopen that exact
file. If it prints any research with unresolved `## Recomendaciones` items, read them NOW, before
Step 5 — Step 8d will build the "retomar" prompt for whatever is still unchecked, but only if you
either resolved them (checked off, with a pointer to the plan/pendiente that tracks it, or a
`declinado: <motivo>` note) or left them alone on purpose.

**Read `adopted` and `rows_added` before you call anything broken — on the FIRST checkpoint of a
memory that predates 2.12.0 they are both expected and non-zero, and nothing is wrong.** Such a
`_pendientes.md` organizes its items under its own headers (`## Abiertos`, `P0 — …`, by week or by
topic), which the journal cannot anchor to, so those lines never had a Tier 3 row: `adopted=N`
means N of them were moved under `## Alta/Media/Baja prioridad` (each move printed with its reason)
and `rows_added` counts the rows that were missing. That is a one-time migration of state older
than the mechanism, not a bypass — say exactly that in Step 7, not "the dual write was broken".

`rows_added` or `ids_invented` above 0 **with `adopted=0`** is the other case: someone wrote Tier 2
outside the journal since the last checkpoint, and the dual write was bypassed. Without this repair
those pendientes lose their resolution date and closing session when they are eventually closed.
Report the counts in Step 7; if `missing_data>0`, the listed lines lack `_creado` and need a look by
hand (a missing priority header is no longer one of the causes: adoption resolves it).
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

**Alcance acotado — y el resto se CUENTA, no se calla.** Hasta 2.27.0 este paso pedia clasificar
*cada* pendiente abierto. Medido en 14 sesiones reales de un usuario del plugin (2026-09-13..19):
con ~200 abiertos, ese barrido no se hizo **ni una sola vez** — las 8 sesiones que llegaron aqui lo
difirieron a `/triage-3t`, y ninguna lo dijo en su cierre. Un paso que se salta el 100% de las
veces no es un agente flojo, es una especificacion mal escrita: pide un barrido de backlog dentro
de un guardado de sesion. Asi que el alcance obligatorio de 3a es cerrado:

1. **Los pendientes que esta sesion toco** — resueltos, creados, superseded o simplemente leidos
   mientras trabajabas.
2. **Los que traen `_revisar: <fecha>_` vencida o de hoy**, sean de la sesion que sean. Son los que
   alguien programo para HOY y los que mas veces salieron sin mencionar (3 de las sesiones medidas).

Lo demas queda **fuera del alcance de este paso** y se declara con una linea, no con silencio:

```
RECONCILIACION: <R> de <N> pendientes abiertos revisados — <N-R> sin revisar, barrido en /triage-3t
```

Esa linea es obligatoria aunque `N-R` sea 0. `checkpoint-audit.py` (Step 7a) la vuelve a medir por
su cuenta y la imprime como `PARCIAL` mientras quede uno sin revisar, asi que recortarla en
silencio ya no es posible.

Para los pendientes DENTRO del alcance, clasifica cada uno en exactamente uno de:

- **resolved** — the work described was completed in this session, directly or indirectly (e.g., the user asked for X and X happens to satisfy the pendiente).
- **still-open** — the work is still pending and was not touched this session.
  If a still-open item that touches this session's work **waits on something outside the
  session** (another install, a peer, a foreign PR) and its line has no `_bloqueado:`, mark it:
  `journal-emit.py --type pendiente.block --id p-… --bloqueado-por "<what it waits for>"`.
  Without the field, Step 8 can promote it to `Proximo paso` (see Step 3b, `--bloqueado-por`).
- **corregido** — sigue abierto, pero su TEXTO quedo falso (parte del trabajo se adelanto, el
  alcance se ajusto) o su prioridad cambio. No es un cierre: se emite `pendiente.update`, abajo.
- **superseded** — the item was absorbed by another pendiente or a scope change (reference the new owner/scope).
- **abandoned** — the item no longer applies (architecture changed, feature dropped, etc.).

`corregido` existe para que no se use `superseded` + `add` en su lugar. Ese par cambia el id (es
`sha1(texto+creado+origen)`), y deja las citas del id viejo —en fichas, recordatorios y research—
apuntando a un pendiente cerrado, con la fila mensual aparentando dos trabajos donde hay uno.

**Print the reconciliation table** to the user before continuing, so the decision is explicit. Solo
lleva los pendientes del alcance de arriba, y **cierra con la linea del conteo**:
```
RECONCILIACION: 4 de 203 pendientes abiertos revisados — 199 sin revisar, barrido en /triage-3t
- p-aaaaaaaaaa <pendiente text> → still-open
- p-bbbbbbbbbb <pendiente text> → resolved (this session)
- p-cccccccccc <pendiente text> → superseded by <new pendiente or scope ref>
- p-dddddddddd <pendiente text> → abandoned — <reason>
- p-eeeeeeeeee <pendiente text> → still-open (vence 2026-09-19, no es de esta sesion)
- p-ffffffffff <pendiente text> → corregido — <que dejo de ser cierto del texto>
```

For EACH item classified `resolved`, `superseded`, or `abandoned`, emit one event:

```bash
python3 "$JBIN/journal-emit.py" --type pendiente.resolve --id p-xxxxxxxxxx \
  --estado resolved|superseded|abandoned --sesion "[[sessions/DATE-SLUG]]" --nota "<reason or new ref>"
```

Para cada item clasificado `corregido`, un evento distinto — **no** cierra nada y **conserva el
id**, que es todo el punto:

```bash
python3 "$JBIN/journal-emit.py" --type pendiente.update --id p-xxxxxxxxxx \
  --text "<el texto corregido>" --prioridad Alta|Media|Baja
```

Cualquiera de los dos campos basta (`--text`, `--prioridad`, o los dos). El compactador reescribe
la linea de **Tier 2** conservando `_origen:`/`_creado:`/`_id:`/`_revisar:`, mueve la linea de
seccion si cambio la prioridad, actualiza las celdas Pendiente/Prioridad de la fila mensual
(**Tier 3**) por id, y deja `_actualizado: FECHA_` en la linea. Esa marca es lo que le dice a
`repair-dualwrite.py` que el `_id:` es el hash de NACIMIENTO y no uno inventado: sin ella,
`--fix-ids --apply` lo renombraria y romperia las citas igual que `superseded` + `add`.

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
9. **Every defect found during this session that is not closed AND verified** — including
   the ones the user pointed out live, and including the ones you already "fixed" by
   rewriting prose (a rule, a template paragraph). **This one is mandatory, not a heuristic.**
   A prose-only fix is not a closed defect. If it has no pendiente, the `<next-step>` ladder
   in Step 8 cannot see it. Measured in session 5790b9f2 of this repo: the closing snippet
   fell to the generic case 4 while exactly that work was open (learning 272). Since 2.33.0,
   `Proximo paso:` must cite a pendiente id, so unregistered work cannot be named there. Since
   2.34.0, its line in `## Bugs fixed` carries `_pendiente: p-…_` (Step 3d writes the id), and
   `checkpoint-audit.py` rejects a `ninguno` snippet while that pendiente is open and immediate.

For EACH new pendiente, emit one event:

```bash
python3 "$JBIN/journal-emit.py" --type pendiente.add --text "<texto del pendiente>" \
  --prioridad Alta|Media|Baja --origen "[[sessions/DATE-SLUG]]" [--revisar YYYY-MM-DD] \
  [--bloqueado-por "<que espera, fuera de esta sesion>"]
```

**`--bloqueado-por` cuando el pendiente espera a algo FUERA de esta sesion**: otra instalacion
que tiene que actualizar, un peer, un mantenedor ajeno, un PR de otro repo, una decision de otra
persona. Decidelo al CREAR el pendiente, respondiendo "¿se puede hacer de inmediato, sin esperar
a nadie?". El compactador anade `— _bloqueado: <que>_` a la linea de Tier 2. Ese campo tiene un
consumidor: `checkpoint-audit.py` rechaza (`snippet.proximo_paso`) un `Proximo paso:` que cite
ese id. El pendiente sigue en `## Pendientes` de la ficha. No cambia el id. Para un pendiente que ya
existe: `journal-emit.py --type pendiente.block --id p-… --bloqueado-por "…"` (o
`--desbloquear` cuando ya no espera). Caso real (2026-09-22, sesion 5790b9f2): `p-a4439fa8fd`
("verificar... una vez esa instalacion actualice a 2.32.0") llego a `Proximo paso` porque nada
lo marcaba. La regla en prosa de Step 8 ya lo prohibia y no bastaba.

**`--revisar` cuando el pendiente nombra una fecha futura** (`revisar el 2026-09-22`, `target
2026-10-01`, `T+7` resuelto a fecha). Escribe la fecha **como campo**, no solo en prosa: el
compactador anade `— _revisar: YYYY-MM-DD_` a la linea de Tier 2. Sin el campo la fecha no la lee
nadie — medido 2026-09-11: **395 de 996 pendientes abiertos llevan una fecha ya vencida escrita en
prosa y ningun codigo la miro nunca**. Con el campo tiene dos consumidores: `expire-pendientes.py`
(no toca un item cuya ventana no ha vencido; caduca el que si) y el Step 8c, que imprime el
recordatorio de calendario. `--revisar` no cambia el `_id`: la ventana no es parte de la identidad.

**Si el pendiente es del tipo "esperar y luego revisar"** (depende de que pase tiempo o actividad
acumulada, no de una condicion o decision) **el texto debe nombrar un intervalo concreto ANTES de
emitir el evento** — nunca lo dejes en prosa abierta como "revisar periodicamente" o "monitorear
que no falle". Dos reglas fijas, sin criterio intermedio (para que dos agentes lleguen siempre a la
misma fecha), y una sola salida sin fecha — la fecha ya vencida o de hoy, dentro de la regla 1:
1. **Si el propio usuario o la sesion ya dijeron UN SOLO numero POSITIVO (mayor que cero) de
   horas, dias naturales o semanas, o UNA SOLA fecha futura inequivoca, sin condicion** ("T+7",
   "en 2 semanas" → dias × 7, "en 48 horas" → dias = horas ÷ 24 redondeado HACIA ARRIBA (48h → 2
   dias; 30h → 2 dias, nunca hacia abajo — `_revisar` es una fecha sin hora, y redondear hacia
   abajo revisaria antes de que termine de pasar el tiempo pedido), "el 2026-09-30") — conviertelo
   a fecha, igual que ya haces con "T+7". Solo cuentan horas/dias naturales (calendario): "dias
   habiles" u otra unidad que dependa de un calendario que este proyecto no define (feriados, fin
   de semana) NO cuenta como "un numero ya dicho" — cae en la regla 2. Una fecha relativa a un dia
   de la semana ("el viernes") cae aqui solo si el texto ya dice a cual viernes se refiere (p.ej.
   "el viernes que viene"); si no lo dice, cae en la regla 2.
   Una fecha YA VENCIDA (pasada o de hoy) no va en `--revisar`, pero **tampoco cae en la regla
   2**: la espera ya termino, asi que el pendiente es accionable HOY. Emitelo **sin** `--revisar`
   — igual que un `_revisar` vencido "vuelve a ser un pendiente normal" en Step 8. Mandarlo a 5
   dias (o a manana) lo sacaria de `<next-step>` justo cuando el usuario pidio mirarlo ya
   (hallazgo de Codex, 2026-09-21: "revisalo hoy" terminaba con `_revisar` a 5 dias). **Cualquier otra forma — mas
   de un numero mencionado ("3 o 7 dias segun X"), una condicion ("si sigue igual, en una
   semana"), o un rango— tampoco cuenta como "un numero ya dicho": cae en la regla 2.**
2. **En cualquier otro caso, usa literalmente 5 dias** — mismo numero que ya uso el usuario en el
   caso real de abajo. No hay un tercer criterio ("razona el intervalo del mecanismo"): ese
   tercer criterio es el que dejaba a dos agentes eligiendo fechas distintas (hallazgo de
   `/goalspec:adversary`, 2026-09-16).

Convierte el resultado a `--revisar YYYY-MM-DD`, la misma disciplina que ya aplicas para "T+7" —
salvo la fecha ya vencida o de hoy de la regla 1, que va sin `--revisar`. Un pendiente que SI espera
tiempo y queda sin `--revisar` no cae en la exclusion de Step 8 (2.25.7) — se
queda flotando indefinidamente como candidato de `<next-step>` por pura prioridad,
sin importar que tan pronto sea razonable revisarlo. Caso real (2026-09-16, proyecto
`claude-vzert`): `p-fd5c8cccb7` ("revisar el log del cron por PUSH FAILED", prioridad Alta, sin
`--revisar`) gano `<next-step>` el mismo dia que se implemento el cron que monitorea — sin
actividad de push acumulada todavia el chequeo no tenia con que fallar de verdad — y siguio
reapareciendo dateless en `Sigue abierto` de una sesion posterior
(`2026-09-16-verificar-backfill-tier3-no-aplicado`) sin que nada lo corrigiera; el usuario eligio 5
dias (`_revisar: 2026-09-21`) al fecharlo a mano. Si el pendiente de verdad no depende del tiempo
sino de una condicion o decision, no le pongas `--revisar` — esta regla es solo para el que su
unico bloqueo real es "que pase tiempo o actividad", nunca para el que espera una decision ajena
(ver la advertencia contra "revisar si X respondio" en Step 8, mas abajo).

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

It must print `JOURNAL applied=N quarantined=0 pending_left=0`. A `rescued=N` in that line is good
news, not a problem: N events that an older version of the plugin quarantined for a missing anchor
were returned to `pending/` and applied in this same pass. If `quarantined>0`, open each
`memory/.journal/quarantine/*.reason` (a hand-edited anchor, an id collision, a broken JSON, an
impossible date), apply that change by hand, delete the `.json`/`.reason` pair, and report it in
Step 7. Since 2.22.0 a **missing priority header is not one of those cases** — the compactor creates
the header and applies the event — so a quarantined event really does need a person: do not report it
as "something the new version does the first time". If it prints `JOURNAL busy`, another agent holds
the lock right now: run it again after a few seconds. This
runs now so the reconciliation report is fresh; Steps 2, 4 and 5 emit more events, and Step 5a
compacts everything again before the commit.

### Step 3d — Rellenar `## Pendientes` del session log

Only now do the ids exist. Replace the placeholder left in Step 2 with the pendientes this
session touched, each with the id the journal actually assigned:

```markdown
## Pendientes
RECONCILIACION: <R> de <N> pendientes abiertos revisados — <N-R> sin revisar, barrido en /triage-3t
- [ ] <texto corto> — `p-xxxxxxxxxx`
- [x] <texto corto> — `p-yyyyyyyyyy` (resuelto)
<or "Ninguno">
```

**La linea `RECONCILIACION:` va tambien AQUI, no solo impresa en pantalla.** Impresa se la lleva el
scroll; en la ficha queda, y `checkpoint-audit.py` (Step 7a) la comprueba. Es la misma linea de
Step 3a, con los mismos numeros.

**Pon tambien el id en `## Bugs fixed`.** Cada linea que Step 2 dejo con `_pendiente: <texto>_`
pasa a `_pendiente: p-xxxxxxxxxx_`, con el id que el journal asigno al pendiente de ese defecto
(Step 3b punto 9).

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

### Corregir una regla YA escrita — `learning.update`, nunca un `learning.add` de correccion

Si lo que hiciste fue descubrir que una regla EXISTENTE quedo falsa (cambio la ruta que cita, el
mecanismo que describe ya no es ese, la fila de resumen contradice a su propio fichero), **no
emitas un `learning.add` diciendo "la regla N esta vencida"**. Eso deja el indice mal Y anotado:
la regla falsa sigue ahi, con otra al lado diciendo que no le hagas caso, y el recall devuelve las
dos. Es el workaround que se uso dos veces en la semana del 2026-09-19 y el motivo de que exista
este evento.

```bash
python3 "$JBIN/journal-emit.py" --type learning.update --topic <topic-slug> \
  [--match-prefix "<prefijo del texto ACTUAL de la regla>" --text "**<Regla>** — <texto nuevo>"] \
  [--quickref-prefix "<prefijo de la regla ACTUAL del Quick Reference>" \
   --quickref "**<Regla>** — <version corta nueva>"] \
  [--title "<Titulo del tema>"] [--when "<cuando consultarlo>"]
```

Las tres superficies son independientes: corregir el cuerpo no obliga a tocar el Quick Reference,
que suele llevar una version mas corta de la misma regla. Pasa las que de verdad cambiaron.

**El numero de la regla se conserva.** Es su identidad publica: las reglas se citan por numero
("learning 106", "regla 142") en fichas de sesion, en comentarios del codigo y en los propios
learnings. Renumerar rompe esas citas igual que renombrar el `_id:` de un pendiente.

**El ancla es un prefijo, porque un learning no tiene id en su linea.** El prefijo se compara sin
enfasis y sin distinguir mayusculas, asi que no hace falta citar los asteriscos. Si no casa
ninguna regla, o casan dos, el compactador cuarentena el evento y nombra las candidatas: no
reescribe a ciegas. Si sale `ambiguous`, alarga el prefijo.

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
- **A pendiente you resolved in Step 3a traces back (via its `_origen`, or a "Continuacion de"
  chain across session files) to one of the plans `check-active-plans.py` printed in Step 3-pre.**
  This is a signal even if THIS session did no planning of its own — the work still belongs to an
  existing plan's lineage, and per that plan's own convention a new finding gets added as a new
  phase, not left standalone (see the note under Step 3-pre for the incident that made this
  explicit).

**If plan signals found:**
- Tier 3: create/update memory/plans/plan-<slug>.md with context, decisions, steps, outcome (direct write: one writer per file)
- Tier 2: emit one `plan.upsert` event (the compactor writes the row in Step 5a):
  ```bash
  python3 "$JBIN/journal-emit.py" --type plan.upsert --slug <slug> --title "<Plan title>" \
    --status draft|active|testing|completed|abandoned --date DATE --sesion "[[sessions/DATE-SLUG]]" \
    [--pendientes N] [--learnings "N rules"] [--inline] [--parent <parent-slug>]
  ```
  New plan → row `| [[plans/plan-<slug>\|<title>]] | <status> | DATE | <sesion> | ... |` at the top of
  `## Plans` (`--inline` writes `<title> (inline)` instead of the link). Existing plan (matched by
  `plans/plan-<slug>` or by title) → only the cells you pass are updated; Fecha never changes. The
  compactor prunes completed/abandoned rows to the 5 most recent by date.
  **Reopening a closed plan** (completed/abandoned/superseded → active) is NOT a `plan.upsert`: since
  2.37.0 an upsert that moves the status backwards is dropped with a WARN (that is what stops a
  replayed old event from un-closing a plan). Emit
  `python3 "$JBIN/journal-emit.py" --type plan.reopen --slug <slug>` (add `--title "<Plan title>"`
  for an `--inline` plan), then update the plan file's frontmatter yourself.
- Add wikilink in session log ## Plans section and ## Related

**Fallback (no JBIN)**: add/update the row in memory/_plans-index.md by hand.

### Plan multi-sesión — bloque `## Estado` (Step 8 lo lee)

**Cuándo aplica.** Solo si el plan de esta sesión va a cruzar varias sesiones (tiene fases, o ya
es un plan `active` que otra sesión va a retomar). Un plan de una sola sesión (`completed` al
cerrar, o un `(inline)` de una línea) no lo necesita — no le des la ceremonia a algo que no la
usa.

**Por qué existe.** Medido 2026-09-14 sobre las sesiones reales del port 3-tier al VPS: aun cuando
el snippet de Step 8 ya nombraba el archivo del plan activo, `Proximo paso` seguía sin leer ningún
estado — caía a `revisar _pendientes.md y proponer siguiente prioridad`, que es la misma prosa
genérica de una sesión sin plan. El plan sí tenía el big picture (fases, fechas, orden); lo que
faltaba era que Step 8 lo leyera. Por eso este bloque no es narrativa nueva — es la MISMA
información que ya escribes en el plan, movida a una forma que un agente pueda leer sin
re-derivarla de 300 líneas de prosa.

**Qué escribir.** Justo debajo del título del plan, ANTES de la narrativa, cuatro campos fijos:

```markdown
## Estado

Fase actual: <N> — <nombre corto de la fase>
Próxima acción: <lo más concreto posible — qué, con qué criterio o fecha si ya se acordó>
Bloqueado por: <qué lo detiene, o "nada">
Actualizado: <DATE>
```

Actualízalo en CADA checkpoint que toque este plan — es el único campo de todo el plan que se
reescribe en vez de acumularse; el historial de cómo llegó ahí ya vive en la narrativa de abajo,
que sigue creciendo como siempre. Si `Próxima acción` no cambia respecto al último checkpoint,
escribe la misma línea — no la omitas ni la vacíes; un `## Estado` ausente y uno que no cambió se
leen distinto para quien lo consulta después.

**La prueba de que sirve.** Tapa el resto del plan y lee solo `Fase actual` + `Próxima acción`. Si
con eso no sabes qué hacer la próxima sesión sin abrir la narrativa, no está lo bastante concreto
— es el mismo criterio que la línea `<next-step>` de Step 8 ya exige, aplicado un nivel arriba.

### Plan padre/hijo — cuando un esfuerzo se fragmenta en varios planes

**Cuándo aplica.** Un esfuerzo grande a veces nace como un plan y luego se parte en sub-planes por
bloque o por fase (medido: el port 3-tier al VPS terminó con 5 filas en `_plans-index.md` para el
mismo esfuerzo, sin relación visible entre ellas — dos con el mismo alcance, una activa y otra ya
completed el mismo día). Si vas a crear un plan que es una fase o un bloque de un plan más grande
que YA existe, decláralo como hijo en vez de dejarlo suelto.

- Al emitir su `plan.upsert`, pasa `--parent <slug-del-plan-padre>`. El compactor anota la celda
  `Status` del hijo como `<status> (fase de plan-<parent>)` — sin ampliar la tabla ni migrar filas
  viejas: es la misma celda de siempre, con la fase visible en el texto. El compactor rechaza
  (`Quarantine`) un `--parent` que cerraría un ciclo — que `X` sea padre de `Y` cuando `Y` ya es
  ancestro de `X`, directa o transitivamente — leyendo las anotaciones `(fase de plan-…)` ya
  escritas en el índice; si lo ves rechazado con `parent-cycle:`, revisa la cadena antes de
  reintentar, no vuelvas a emitir el mismo evento. También rechaza `--parent` cuando el destino no
  tiene fila propia identificable, cuando el plan que estás escribiendo tiene más de una fila en el
  índice, o cuando el índice trae alguna fila con anotación de padre sin wikilink reconocible — las
  tres son la misma familia de problema (una fila que el guardián no puede verificar) y la salida
  es siempre la misma: arreglar el índice a mano antes de reintentar. **En un índice con tablas
  legacy (columnas en otro orden, el caso real de un `_plans-index.md` sin migrar) `--parent`
  puede rechazar operaciones sobre planes que sí existen** — es deliberado: el guardián solo
  reconoce una fila por su wikilink en la primera celda (el formato que escribe el propio
  compactor), y adivinar la identidad de una fila con las columnas en otro orden es exactamente el
  riesgo que este mecanismo existe para no correr. Mismo criterio que el pendiente ya abierto sobre
  unificar ese índice: la jerarquía de planes no se puede usar de forma confiable ahí hasta que se
  unifique, y el compactor ahora lo hace cumplir en vez de dejarlo en prosa.
- En el plan PADRE, mantén una sección `## Sub-planes` (tabla de 3 columnas: Sub-plan, Estado,
  Fase actual) con una fila por hijo, **en el orden en que se deben atacar** (la fila de más
  arriba es la que sigue cuando haya que elegir entre varios hijos abiertos — Step 8 lo usa como
  criterio de desempate). Actualizada a mano en cada checkpoint que toque alguno — Tier 3,
  escritura directa, igual que el resto del cuerpo del plan.
- Un plan que reemplaza a otro (no es hijo, lo sustituye entero) no lleva `--parent`: cierra el
  viejo con `--status "superseded — reemplazado por plan-<nuevo>"` y dilo también en la narrativa
  del nuevo. `superseded` cuenta como cerrado para la poda (mismo criterio que `completed`).

**Anidamiento — un hijo puede tener sus propios hijos, sin límite de profundidad.** `--parent`
apunta a CUALQUIER plan, y ese plan puede a su vez tener su propio `--parent`: la cadena es
recursiva por construcción, no hace falta un campo ni un esquema nuevo por nivel. Un plan que es
hijo de uno y padre de otros lleva las dos piezas a la vez: su propio `## Estado` (Step 5, arriba)
Y su propia `## Sub-planes` con SUS hijos. No trates "hijo" y "padre" como roles excluyentes.

**Subir en el árbol al cerrar un hijo — el paso que falta si solo emites el evento y sigues.**
Sin esto, `--parent` resuelve un nivel (un plan con varios hijos sueltos) pero no el caso real que
lo motivó: una sombrilla de varios niveles (el port al VPS: plan → Bloque A/B/D → lo que cada uno
abrió dentro) donde cerrar UNA rama no dice nada sobre las demás, y la persona termina preguntando
"¿qué sigue?" sesión tras sesión porque nadie sube a mirar el padre. Regla, en el mismo `plan.upsert`
que cierra un hijo (`--status completed|abandoned|superseded`):

1. Si ese hijo tiene `--parent`, abre el plan PADRE y revisa su `## Sub-planes`.
2. **Antes de confiar en esa tabla, crúzala contra `_plans-index.md`.** `## Sub-planes` es Tier 3
   a mano — solo se actualiza "en cada checkpoint que toque alguno", así que un hijo creado en una
   sesión que nunca tocó al padre la deja incompleta. El índice no tiene ese problema: cada fila
   con `(fase de plan-<padre>)` en su Status es un hijo suyo, y esa anotación sobrevive mientras
   el hijo siga abierto (se preserva automáticamente al cerrar otros campos — ver la nota del
   compactor más abajo). `grep '(fase de plan-<slug-del-padre>)' _plans-index.md` te da los hijos
   reales; si difiere de `## Sub-planes`, el índice manda y actualizas la tabla para que coincida.
3. **Si queda otro hijo `active` o `draft`** (por el índice, no solo por la tabla), la fila MÁS
   ARRIBA de esos en `## Sub-planes` es el candidato a `<next-step>` de la sombrilla entera —
   aunque esta sesión no lo haya tocado (si el padre no ordenó las filas a propósito, dilo en el
   `## Estado` en vez de elegir en silencio). Actualiza el `## Estado` del padre para que su
   `Próxima acción` lo nombre (Step 8 lo lee de ahí, no hace falta que tú lo repitas en el snippet
   de hoy).
4. **Si no queda ninguno abierto**, el padre pasa a evaluarse para cerrar él mismo — no se cierra
   solo porque sus hijos cerraron (puede tener trabajo propio, fuera de los hijos: mide contra su
   propio `## Estado` y su narrativa). Si en efecto ya no queda nada, ciérralo con el mismo
   `plan.upsert --status completed|abandoned|superseded`, y si ESE padre tiene a su vez un padre,
   repite el paso 1 un nivel más arriba. La subida termina cuando encuentras un padre con otro hijo
   abierto, o cuando llegas a la raíz (un plan sin `--parent`) y esa también queda cerrada.

**El compactor preserva `(fase de plan-<padre>)` aunque el evento que cierra al hijo no traiga
`--parent`.** No hace falta reafirmarlo al cerrar (`--status completed` sola basta) — el
compactor mira la celda existente antes de sobreescribirla y conserva la anotación si la había.
Sin esto, cerrar un hijo borraba en silencio el único registro legible por máquina de su lugar en
el árbol, y con él la entrada de `build_parent_map`/`would_cycle` (el guardián de ciclos de abajo)
quedaba ciega para ese eslabón — hallazgo adversarial (2026-09-14), con repro de tres niveles.

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
  it (hand-written, or older than 2.12.0) are never pruned. **Known limit**: Next step/Origen have
  no column in Completed and are dropped on maturation, on purpose (a finished research has no next
  step to track) — if either mattered, fold it into `--resultado` before the `completed` event
  fires. Anything already appended to Archivo past the bare link (decoration, or text folded there
  by `repair-research-index.py`) DOES carry forward since 2.31.7 — before that it was rebuilt from
  scratch and lost too, on every maturation (`p-115356214b`).
- Add wikilink in session log ## Research section and ## Related

**Fallback (no JBIN)**: add/update the row in memory/_research-index.md by hand.

### Research con varias recomendaciones candidatas — sección `## Recomendaciones`

**Cuándo aplica.** Solo si el research de esta sesión (o uno que revisaste, aunque no lo hayas
escrito hoy) produjo **más de una** recomendación/opción a considerar, y esta sesión solo actuó
sobre alguna(s) de ellas — típico de un audit comparativo ("de estas N ideas, implementamos 1").
Un research con una sola conclusión (`--resultado` de una línea, sin ramas) no lo necesita.

**Por qué existe.** `research.upsert --status completed` cierra el research entero como una sola
unidad, con un solo `--resultado`. Las recomendaciones que NO se ejecutaron quedan como prosa
suelta dentro de un archivo ya marcado `completed` — nada vuelve a mostrarlas jamás, a menos que
alguien reabra ese archivo por su cuenta. Medido en este mismo repo, 2026-09-17:
`research/openwolf-vs-3tier.md` generó 4 recomendaciones priorizadas, se implementó 1, y las
otras 3 no tenían ningún rastro mecánico — ni en el índice, ni en "Como retomar" — hasta que el
usuario lo señaló explícitamente. El precedente de planes (`--parent` + `## Sub-planes`) resuelve
el problema análogo para fases de un plan, pero es demasiado — nunca se usó en un plan real de
este repo (cero filas `(fase de plan-…)`, cero secciones `## Sub-planes`, verificado). Lo que sí
sobrevivió al uso real (v2.13.0) fue el mecanismo más simple: un puntero directo, sin tabla
recíproca ni detección de ciclos. Este es ese mismo espíritu, aplicado a research.

**Qué escribir**, directo en el cuerpo del research (Tier 3, sin evento nuevo — no toca
`research.upsert` ni el índice):

```markdown
## Recomendaciones

- [ ] <recomendación aún sin decidir>
- [x] <recomendación ya resuelta> — implementada en [[plans/plan-<slug>]]
- [x] <recomendación descartada> — declinado: <motivo corto>
```

Marca `[x]` solo cuando la recomendación tiene un destino real: un plan/pendiente que la
implementa, o una nota explícita de por qué se descarta. Dejarla `[ ]` es la señal correcta
mientras nadie ha decidido nada — no la marques solo para "limpiar" la lista.

`check-active-research.py` (Step 3-pre) avisa en cada checkpoint mientras queden `[ ]` sin
marcar en cualquier research — no solo en el de hoy. `print-research-recomendaciones.py` (Step
8d) arma el prompt de retomar a partir de esta misma sección, para los research que ESTA sesión
enlazó en su `## Research` — una sola fuente de verdad, nunca una segunda redacción.

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

### 5c-bis: Sellar `session_id` en SESSION_FILE (la llave del dedup)

Escribe en el frontmatter de la ficha de esta sesion el UUID de su propia transcripcion. Es lo
que permite que `/backfill-3t` sepa, sin heuristica ninguna, que esta sesion YA tiene ficha:

```bash
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/stamp-session-id.py" ]; then
  STAMP="${CLAUDE_PLUGIN_ROOT}/bin/stamp-session-id.py"
elif [ -f "plugins/3-tier-memory/bin/stamp-session-id.py" ]; then
  STAMP="$PWD/plugins/3-tier-memory/bin/stamp-session-id.py"   # el repo del propio plugin
else
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "stamp-session-id.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  STAMP=${_B:+$_B/stamp-session-id.py}
fi
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
JSONL_DIR="$HOME/.claude/projects/$ENCODED"
if [ -n "$STAMP" ] && [ -f "$STAMP" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  python3 "$STAMP" "$SESSION_FILE" "$CLAUDE_CODE_SESSION_ID" --jsonl-dir "$JSONL_DIR"
else
  echo "stamped=0 reason=sin-STAMP-o-sin-CLAUDE_CODE_SESSION_ID"
fi
```

`CLAUDE_CODE_SESSION_ID` **no esta documentada**. Se midio en esta instalacion (2026-09-12: su
valor coincide con el nombre del `.jsonl` en curso) y no se ha comprobado en otras versiones, en
modo SDK ni sin terminal. Por eso el sello nunca se da por bueno: `stamp-session-id.py` exige que
ese id tenga `.jsonl` en `$JSONL_DIR` **y** que la fecha de la ficha caiga dentro del rango de esa
transcripcion, y si algo no cuadra no sella.

**Sin sello no pasa nada malo**: `match-session-file.py` tiene una segunda capa que reconstruye
la union observando que ficha escribio cada transcripcion, asi que una instalacion donde
`CLAUDE_CODE_SESSION_ID` no exista sigue deduplicando. Lo que no se hace nunca es inventarse el
UUID: el script se niega si ese id no tiene `.jsonl` en `$JSONL_DIR`, porque en el matcher el
sello GANA a la evidencia de escritura y un sello equivocado no da un duplicado visible — da el
fallo invisible, una sesion marcada como importada que no lo esta.

Si imprime `stamped=0` con una razon distinta de `ya-sellada-con-el-mismo-id`, anotalo para el
informe del Step 7.

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

## Step 7a: Auditoria del propio checkpoint (deterministica — NO es opcional)

```bash
python3 "$JBIN/checkpoint-audit.py" "$MEMORY_DIR" --session-file "$SESSION_FILE" --repo-root .
```

**Por que existe.** Step 7 solo pide reportar lo que SI se hizo. Medido en 14 sesiones reales de un
usuario del plugin (2026-09-13..19): en las 14 el usuario pregunto *"falto algo de tu checkpoint?"*
y en las 14 el agente enumero omisiones reales que su propio cierre no mencionaba — la tabla de 3a,
el plan sin `## Estado`, un `header_issues=1` repetido tres veces y nunca reportado, pendientes que
vencian ese dia, el snippet sin los pendientes recien creados. La informacion existia dentro de la
sesion; nunca llegaba sola al usuario. Un usuario normal no pregunta: lee el cierre y lo da por
completo. Esto es la regla de las garantias mecanicas aplicada al cierre — no se delega al agente
recordar que se salto, se mide.

El script **no repara y no escribe**: lee `memory/` y el estado de git, y da cuatro estados:

| Estado | Que significa | Que haces |
|---|---|---|
| `HECHO` | el paso se cumplio, medido | nada |
| `PARCIAL` | se hizo dentro de un alcance acotado (Step 3a) | dejar el conteo a la vista |
| `SALTADO` | el paso falta y no hay diseno que lo permita | **arreglar o declarar** (abajo) |
| `POR-DISEÑO` | el skill lo ordena asi (no hay push, el hash es referencia adelantada) | reportarlo como lo que es, nunca como falla |

`POR-DISEÑO` es un estado de primera clase por una razon medida: al preguntarle, el agente tambien
confesaba como fallas cosas que este mismo archivo ORDENA (no hacer `git push`, dejar el hash del
commit sin commitear — Step 6c). Sin una referencia fija de que cuenta como omision, la confesion
libre produce un muro de falsos positivos y el usuario se queda tan ciego como con el silencio.

**Que hacer con cada `SALTADO` o `PARCIAL`:**

1. **Si el script imprime una linea `corrige:`, ejecutala ahora.** Son arreglos baratos y
   deterministas (emitir el `plan.upsert` que falto, compactar el journal, correr Step 8d). Vuelve
   a correr el audit y marca ese punto como `CORREGIDO` en el reporte. No le devuelvas al usuario
   un trabajo de un comando.
2. **Si no hay `corrige:` o el arreglo pide criterio**, se queda `SALTADO` y entra literal en el
   reporte de Step 7 con su motivo en una linea. Ejemplos legitimos: el barrido completo de 3a
   (es `/triage-3t`), una cabecera mensual incompleta (es una migracion), un pendiente vencido de
   otra sesion que no te toca resolver.
3. **Nunca marques como `POR-DISEÑO` algo que el script no clasifico asi.** Ese estado lo decide el
   script leyendo este archivo, no tu comodidad.

**La salida del script se pega LITERAL en el reporte de Step 7**, con sus cuatro estados y su linea
`resumen:`. No la parafrasees ni la resumas: la salida entera cabe en pantalla y su valor esta en
que el usuario vea los `SALTADO` sin tener que preguntar.

## Step 7b: Los tres huecos que ningun script puede ver

El audit mide artefactos. Estas tres preguntas son sobre lo que **dijiste**, y no hay fichero que
las conteste. Respondelas las tres, siempre, aunque la respuesta sea "ninguno" — una seccion
condicional que se omite entera se lee como que no se miro:

```
HUECOS NO MECANIZABLES:
1. Afirmaciones sin dueno: <ninguna | que afirmaste que pasaria o se comprobaria despues, y que
   pendiente con fecha lo cubre ahora>
2. Avisos que vi y no reporte: <ninguno | que imprimio un script o un hook durante la sesion y no
   llego al reporte>
3. Pasos que recorte: <ninguno | que paso hiciste a medias por tamano o tiempo, y por que>
```

La 1 es la mas cara y la que menos se ve: si esta sesion afirmo *"manana a las 03:00 esto sale del
codigo actual"* y nadie quedo de comprobarlo, falta un pendiente con `--revisar`. Salio exactamente
asi en el corpus medido y el cierre no lo menciono.

## Step 7: Report

Empieza pegando **literal** la salida de Step 7a y el bloque de Step 7b. Despues, el reporte de
siempre: session path, N pendientes extracted, M resolved, journal result (`applied=N` for Steps 3c, 5a and 6c together, any quarantined event with its reason, and whether any **Fallback** path was used), N learnings added, plans registered (Y/N), research registered (Y/N), indexes updated, N rows pruned by hand (if any), frontmatter sealed (if N>0), **secrets redacted (if N>0, with file:line list + rotate-your-keys warning)**, git result (commit hash OR reason skipped).

**Say what a number MEANS, not just the number.** A count the user cannot interpret reads as a
failure: an `adopted=12 rows_added=12` on a memory older than 2.12.0 is a one-time migration and
the sentence for it is "your 12 pendientes predate the journal; they were moved under the priority
headers and now have their history row" — never "12 pendientes were not in the journal". If a
number really is a problem (a quarantined event, `unaligned_rows`, a bypassed dual write), say what
it blocks and what you did about it. Nothing here is for the user to fix by hand unless this file
says so explicitly.

## Step 8: Como retomar — snippet de continuidad

Genera un prompt breve y autosuficiente que el usuario pueda copiar y pegar al iniciar la proxima sesion (despues de `/exit` o `/clear`) para retomar contexto sin pensar.

**Si el caso 5 de `<next-step>` aplica (mas abajo), NO generes el bloque completo — mismo
principio que Step 8c con los recordatorios de calendario: una seccion condicional que no aplica
se omite entera, no se rellena con placeholders.** 2026-09-14, el propio usuario lo senalo sobre
un caso real: un bloque con `Retomamos: ninguno` / `Proximo paso: ninguno` / `Antes de actuar...`
para una sesion que no dejo nada que retomar es la misma ceremonia vacia que el bloque de
calendario existe para evitar — mas ruido que senal. Ver la instruccion alternativa en 8a y 8b.

**Un pendiente Alta del backlog general (sin relacion con el trabajo de esta sesion) NO es motivo
para generar el bloque completo cuando el caso 5 aplica.** Caso real (2026-09-17, proyecto
`claude-vzert`, via `/goalspec:interview`): con 89 pendientes abiertos y 5 en Alta, siempre hay
alguno suelto que calificaria para la antigua linea `Sigue abierto` — la excepcion anterior ("si hay un Alta que
agregar, bloque completo") volvia inalcanzable el colapso a una linea en la practica, justo cuando
la sesion no dejo nada accionable hoy (los unicos pendientes de esa sesion tenian `_revisar`
futuro y ya su propio recordatorio de calendario). Ese backlog Alta ya lo reporta otro canal (el
hook de inicio de sesion cuenta los pendientes Alta abiertos) — no hace falta repetirlo en un
bloque pensado para "copia y pega esto en una sesion nueva, ahora mismo". El caso 5 colapsa a una
linea sin excepcion (ver 8a).

**Plantilla de 6 lineas: 4 obligatorias y 2 condicionales**:

```
Retomamos: <contexto-1-linea>.

Lee memory/sessions/DATE-SLUG.md para el contexto completo.

Proximo paso: <next-step>.

No repitas: <callejones sin salida>.                      <- omitir si no hubo

Terminas cuando: <done-bar>.                              <- omitir si no aplica

Antes de actuar, dime en 3 lineas donde quedamos.
```

**Linea en blanco entre cada campo, siempre** (2026-09-14, hallazgo del propio usuario sobre un
snippet real): 5-7 lineas pegadas sin separacion se leen como un parrafo cortado por el fence, no
como instrucciones distintas — cuesta el doble de alto pero se escanea de un vistazo, y un LLM lee
igual de bien instrucciones separadas por blanco. Aplica a los TRES bloques de este step (8a, el
ejemplo, y 8b) por la misma regla de "identicos" de mas abajo.

Reglas para llenar los slots:

- `<contexto-1-linea>`: una frase que describa el trabajo principal de la sesion (max 90 chars).
  Toma como base la primera linea de ## Contexto del session file. **Si aplica el caso 1 de
  `<next-step>`** (plan activo con `## Estado`), la frase nombra el PLAN y la fase en vez de la
  sesion de hoy: `<titulo del plan> — Fase <N> (<nombre de la fase>)`. Es la primera linea que se
  lee, y en una tarea de fases es la que responde "que estabamos haciendo" y "es parte de un plan
  mayor" de un vistazo — sin esto, un humano que solo lee `Retomamos:` (no el resto del snippet)
  ve el recorte de HOY, no el trabajo completo del que es parte. Mismo principio que el `Titulo:`
  de los recordatorios de calendario (Step 8c): legible sin abrir nada mas.

  **Si ADEMAS ese plan tiene `--parent`** (es hijo de otro, sin importar cuantos niveles subiste
  para llegar a el — ver el caso 1 de `<next-step>`, mas abajo), la frase suma el padre inmediato:
  `<titulo del plan> — Fase <N> (<nombre>) — hijo de <titulo del plan padre>`. Una sola linea seguia
  siendo una sola linea — esto NO agrega una linea nueva al snippet de 6, extiende la misma
  `Retomamos:` que ya existia. Si sumar el padre rompe el limite de ~90 caracteres, el que se
  acorta es el nombre del padre (o se omite entero), nunca el nombre del plan propio ni la fase:
  esos son los que el lector necesita para actuar hoy.
- `<next-step>`: la accion mas inmediata pendiente, en orden de preferencia:
  1. **Si esta sesion toco un plan `active` que tiene bloque `## Estado`** (ver Step 5), el
     `<next-step>` es `Fase actual: <N> — <nombre>. <Proxima accion del bloque>`, ya actualizado
     con lo que esta sesion resolvio — NO el pendiente suelto de mayor prioridad, aunque exista
     uno. Por que va primero: medido 2026-09-14, un pendiente suelto relacionado con un plan de
     fases es casi siempre UN PASO de la fase, no la fase completa — anteponerlo pierde el orden
     que el plan ya tiene. Si el plan no tiene `## Estado` todavia (uno viejo, sin retro-adaptar),
     cae al caso 2 como cualquier sesion sin plan.

     **Si la `Proxima accion` del `## Estado` es integramente esperar a una fecha que Step 8c ya
     reservo para su propio recordatorio de calendario** (el plan no tiene nada que hacer HOY,
     solo una revision futura), NO la repitas verbatim como `<next-step>`: el texto del slot pasa
     a `ninguno — <plan> Fase <N> esta bloqueada hasta <fecha>, ver Recordatorios de calendario`
     (mismo formato de media linea que ya usa la variante de casos 2-3 mas abajo). La regla de mas
     abajo ("la escalera descarta candidatos con `_revisar` futuro") se escribio pensando en casos
     2-3 y nunca se extendio a este caso 1 — medido en `claude-vzert` (2026-09-18 y 2026-09-21, dos
     sesiones reales): el caso 1 imprimio integro el texto de una `Proxima accion` fechada a futuro
     (el script exacto a correr, la fecha, el criterio), y el snippet pensado para "copia y arranca
     AHORA" termino siendo una copia del recordatorio que Step 8c ya iba a mandar por separado.

     **Esto es una variante MAS del caso 5, no un mecanismo nuevo de colapso** — mismo principio
     que la variante ya documentada para casos 2-3 mas abajo ("Tambien aplica cuando..."): si,
     ADEMAS de que la `Proxima accion` es puro futuro, no queda ningun pendiente PROPIO de esta
     sesion que se pueda hacer ya (sin `_bloqueado:` y sin `_revisar` futuro), entonces `<next-step>` en su conjunto ES el caso 5, y
     8a colapsa el bloque a una linea con la media-linea de arriba como motivo — el MISMO mecanismo
     de 8a, sin condicion nueva que agregarle ahi. **Un pendiente Alta de OTRA sesion, sin relacion
     con esta, no cuenta para esta cuenta** — mismo criterio que ya rige el colapso general (ver
     mas arriba, "Un pendiente Alta del backlog general... NO es motivo para generar el bloque
     completo"): ese backlog ya lo reporta el hook de inicio de sesion, y exigirlo aqui volveria el
     colapso inalcanzable en la practica, el mismo defecto que 2.25.9 ya cerro para casos 2-3. Si en
     cambio queda un pendiente propio que se puede hacer ya, el caso 5 no aplica (sigue siendo el
     caso 1, no colapsa): el bloque completo de 6 lineas se genera igual, con la media-linea de
     arriba en `Proximo paso` y el resto normal.

     **"Toco" incluye el plan padre que actualizaste por la regla de subir de Step 5, no solo el
     plan que era el tema explicito de la sesion.** Hallazgo adversarial (2026-09-14): si el
     trabajo de hoy fue CERRAR un hijo, ese hijo mismo ya no esta `active` — leer el caso 1 en
     sentido literal ("el plan que la sesion toco") sobre el hijo cerrado hace que el caso NO
     aplique justo cuando mas hace falta. El plan correcto a leer es el PADRE: dejo de estar
     `active` con `## Estado` viejo para estarlo con `## Estado` actualizado por el paso 2 de la
     regla de subir — ese conteo como "el plan que esta sesion toco" para este caso, tan valido
     como si hubieras trabajado en el directamente.

     **Si el plan que da el `<next-step>` quedo sin trabajo propio Y tiene `--parent`** (subiste
     al padre en Step 5 y no encontraste otro hijo abierto ahi tampoco todavia), sube otra vez y
     usa el `## Estado` de ESE padre. Repite mientras haga falta — es la misma regla de Step 5,
     aplicada al armar el snippet en vez de al cerrar el evento. Por esta via de escalar
     padre/hijo, el caso 5 (`ninguno`) solo aplica si subiste hasta la raiz y la raiz tambien esta
     sin trabajo abierto, nunca porque el hijo de hoy ya cerro — esto no excluye la OTRA variante
     de caso 5 de este mismo caso 1 (plan bloqueado por fecha futura, unas lineas arriba): las dos
     son condiciones independientes que, si se cumplen, hacen que `<next-step>` sea el caso 5.

     **Si al subir encuentras un padre SIN bloque `## Estado`** (uno viejo, sin retro-adaptar —
     el caso real de varios planes del port al VPS), NO sigas subiendo asumiendo que esta bien:
     no hay forma de leer su estado con confianza. Detente ahi y cae al caso 2 de esta misma
     escalera (pendiente suelto), igual que si nunca hubiera habido plan. Seguir subiendo mas alla
     de un eslabon sin `## Estado` es la misma apuesta que inventar un `<next-step>` — mejor admitir
     el limite que fingir que se leyo algo que no estaba.

     **Si el padre (o cualquier nivel al que subiste) tiene mas de un hijo `active`/`draft`**, no
     elijas en silencio cual sigue — el orden es el de las FILAS de `## Sub-planes`, de arriba
     hacia abajo (esa tabla ya declara prioridad al escribirse: la fila mas arriba es la que sigue,
     como en `plan-hallazgos-piloto-2.25.0`). Si el padre no ordeno sus filas a proposito, dilo tal
     cual en el `<next-step>` (`hay N hijos abiertos sin orden declarado — decide cual primero`) en
     vez de escoger uno sin decirlo: una eleccion no determinista silenciosa es peor que admitir que
     falta el criterio. (El breadcrumb "hijo de <padre>" para este mismo plan ya se resuelve en la
     regla de `<contexto-1-linea>`, arriba — no se repite aqui.)
  2. El pendiente nuevo de mayor prioridad creado en Step 3b de esta sesion.
  3. Si no hay nuevo, el pendiente existente de mayor prioridad relacionado con el trabajo de la sesion.

  **Ningun candidato de los casos 2 o 3 es valido si su unico dato accionable es una fecha futura**
  — trae `_revisar: YYYY-MM-DD` posterior a hoy en `_pendientes.md`, el mismo campo que Step 8c ya
  lee para generar su propio recordatorio de calendario. Un pendiente asi no es accionable hoy sea
  cual sea su prioridad: tratalo como si el caso no aplicara y sigue cayendo por la escalera (al
  otro candidato del mismo caso si hay mas de uno, o al siguiente caso). Caso real (2026-09-15,
  proyecto `cloudflare-expert`): el `<next-step>` elegido fue `confirmar el 2026-09-16 que...`
  sobre `p-b106ce03d9` (`_revisar: 2026-09-16`) — identico al recordatorio de calendario que el
  mismo Step 8c genero para esa fecha en la MISMA sesion. Sin esta regla, `Como retomar` es una
  replica del bloque de calendario: no le dice a la sesion siguiente nada que el calendario no
  fuera a decir ya, y un usuario despistado copia el snippet y arranca una sesion sin nada que
  hacer hoy. No excluye un `_revisar` YA VENCIDO (fecha igual o anterior a hoy) — eso ya paso su
  ventana y vuelve a ser un pendiente normal para el caso 3.

  **Este paso NO intenta detectar ni corregir, por su cuenta, un pendiente viejo "esperar y luego
  revisar" que se creo sin `_revisar` antes de que existiera la regla de Step 3b de abajo.**
  Hacerlo aqui exigiria juzgar por el texto si el pendiente "es de ese tipo" — exactamente la
  clasificacion por prosa que la regla 216 de `learnings/3tier-memory-system.md` ya prohibe para
  este mismo Step (verificado por adversario, 2026-09-16: un primer intento de "red de seguridad"
  aqui, gateada por `_creado != hoy`, seguia dependiendo del mismo juicio semantico y violaba esa
  regla). Un pendiente asi se trata como cualquier otro sin `_revisar` (compite por prioridad,
  casos 2-3) hasta que `/triage-3t` u otra revision manual del backlog le asigne fecha — no es
  responsabilidad de este Step arreglar datos que otro paso dejo mal formados.
  4. **(Quitado en 2.33.0.)** Era `revisar _pendientes.md y proponer siguiente prioridad`, una
     salida generica sin guardia. En la sesion 5790b9f2 de este repo el agente la tomo teniendo
     trabajo propio sin cerrar: el defecto que el usuario acababa de senalar en vivo, "arreglado"
     solo con prosa y nunca registrado como pendiente, asi que la escalera no lo veia. Ahora no
     hay caso 4. O hay un candidato real de los casos 1-3, o es el caso 5. Si el trabajo existe
     pero no tiene pendiente, **registralo en Step 3b** y sera el caso 2. `checkpoint-audit.py`
     marca `SALTADO` en `snippet.proximo_paso` si la linea empieza por ese texto.
  5. **Si la sesion genuinamente no dejo trabajo que retomar** (una sesion de reporte, de
     verificacion puntual, o que se cerro sola) — no hay pendiente nuevo, no hay uno relacionado,
     y "revisar _pendientes.md" seria un placeholder vacio, no una pista real — dilo tal cual:
     `ninguno — <en media linea, por que esta sesion se cierra sola>`. Antes de declararlo,
     preguntate si esta sesion encontro algun defecto o trabajo que no quedo cerrado y
     verificado. Si lo hay y no tiene pendiente, este caso no aplica: vuelve a Step 3b.
     `checkpoint-audit.py` marca `SALTADO` en `snippet.ninguno_defecto` un `ninguno` con un
     `_pendiente:` de `## Bugs fixed` abierto e inmediato (2.34.0).

     **Tambien aplica cuando el UNICO candidato que encontraste en 2 o 3 quedo excluido por la
     regla de `_revisar` futuro de arriba, y no hay otro sin fecha que lo reemplace** — no es lo
     mismo que "no hay nada", pero el efecto para HOY es identico: nada que la sesion siguiente
     pueda avanzar antes de esa fecha. La media-linea de motivo lo dice tal cual, señalando el
     bloque de calendario: `ninguno — lo unico abierto de este hilo tiene fecha futura, ver
     Recordatorios de calendario`. Ejemplo: si la sesion del 2026-09-08 no hubiera dejado el
     pendiente suelto sin fecha `p-9445bed4b6`, el texto habria sido `ninguno — el snapshot semanal
     de SQL-LIVE y la confirmacion de N8n-Crons ya tienen su propio recordatorio (09-16, 09-20)`.

     **Tambien aplica, por la misma razon, cuando el candidato es el caso 1** (plan activo con
     `## Estado`) y su `Proxima accion` es integramente esperar una fecha ya cubierta por el
     calendario, sin ningun otro pendiente propio de esta sesion que se pueda hacer ya — ver el
     parrafo de esa variante en el caso 1, arriba, para el detalle y el ejemplo real.

     **Antes de declarar este caso, relee la seccion `## Pendientes` que este mismo Step ya
     escribio (3a/3b) de ESTE archivo.** Si queda algun `- [ ]` sin marcar ahi **y su id, buscado en
     `_pendientes.md`, trae `_revisar` vencido o ningun `_revisar`**, este caso no aplica — es el 2
     o el 3. El `_revisar` se mira en `_pendientes.md` porque la linea de `## Pendientes` de la ficha
     solo guarda texto e id (plantilla de Step 3d): ahi el campo nunca aparece, y leerlo ahi haria
     pasar por "sin `_revisar`" a todos. Caso real (2026-09-15):
     una sesion declaro `ninguno` con un pendiente Alta recien creado a la vista en su propia
     seccion `## Pendientes` — el atajo salto directo a este caso sin pasar por el 2, y el
     pendiente se perdio del snippet hasta que se audito el jsonl a mano en una sesion posterior.
     **No es excusa para NO declarar este caso** un pendiente Alta que no sea de esta sesion ni
     este relacionado con ella — ese puede salir en el prompt opcional de Step 8e, no cambia el
     veredicto de `<next-step>`. **Si TODOS los `- [ ]` sin marcar traen `_revisar` futuro** (en `_pendientes.md`), la relectura no
     bloquea el caso 5 — es exactamente la variante de arriba ("Tambien aplica cuando..."), no una
     excepcion a esta regla.

  **Cuando aplica el caso 1**, la linea `Lee memory/sessions/DATE-SLUG.md para el contexto
  completo.` de la plantilla (mas abajo) se extiende con la ruta del plan:
  `Lee memory/sessions/DATE-SLUG.md para el contexto completo, y memory/plans/plan-<slug>.md
  para el resto de las fases.` — el snippet ya probo (sesion 2026-09-14-bloque-b, medida en la
  entrevista que origino este cambio) que nombrar el archivo del plan sin que `<next-step>`
  leyera su estado no bastaba; ahora que si lo lee, la referencia al archivo completo sigue
  haciendo falta para el resto de las fases que no caben en una linea. Fuera del caso 1, la
  linea queda como siempre, sin la segunda clausula.

  **En los casos 2 y 3, la linea `Proximo paso:` cita el `_id: p-…_` del pendiente** (desde
  2.33.0). Fuera del caso 1 (`Fase actual: …` con el plan enlazado en `## Plans`) y del caso 5
  (`ninguno — …`), un paso sin id es trabajo que nunca se registro. `checkpoint-audit.py` lo
  marca `SALTADO` en `snippet.proximo_paso`, igual que un id que no esta abierto en
  `_pendientes.md`, uno con `_revisar` futuro y uno con `_bloqueado:`. Tambien marca `ninguno`
  cuando la ficha deja un pendiente propio abierto, sin `_bloqueado` ni `_revisar` futuro.

  **Antes de fijar cualquier candidato de los casos 2 o 3 como `<next-step>`, hazte la
  pregunta explicita: "¿esto se puede hacer de inmediato, en la sesion siguiente, sin esperar una
  decision o accion de alguien o algo FUERA de esta sesion?"** Si la respuesta es no, ese
  candidato no es un `<next-step>` — es un pendiente futuro (con `--revisar` si depende de que
  pase tiempo, o con `_bloqueado:` y fuera de `Proximo paso` si depende de una decision, accion
  o condicion ajena), y el siguiente candidato de la escalera (o el caso 5, `ninguno`) es el que
  corresponde. **Desde 2.33.0 esta pregunta tiene respaldo mecanico, pero solo si el pendiente
  lleva el campo**: nace con `--bloqueado-por "<que espera>"` (Step 3b) o se lo pone
  `pendiente.block` (Step 3a), y entonces el audit rechaza citarlo en `Proximo paso`. El juicio de
  "esto espera a un tercero" se hace al CREAR el pendiente, no al leer su texto aqui (regla 216:
  nunca clasificar por prosa).
  Esta pregunta no es un ejercicio retorico: se salto DOS veces, en dos formas de superficie
  distintas, y la segunda ocurrio en la propia sesion que escribio esta regla mas amplia — la
  variante estrecha de abajo no bastaba porque el patron con otras palabras no la disparaba.

  **Sintoma mas comun, para reconocerlo aunque no use estas palabras exactas: "revisar si X
  respondio/actuo"**, cuando X es un agente, persona o proceso FUERA de esta sesion (un peer, un
  mantenedor ajeno, un PR de otro repo, OTRA instalacion que tiene que actualizar algo). Escribirlo
  como si fuera un paso accionable le hace perder tiempo a quien lo lea despues. Dos casos reales:
  2026-09-14, "revisar si goal-spec-skill-7d respondio" en vez del caso 5, `ninguno`; 2026-09-22,
  esta misma sesion (`2026-09-22-snippet-cierre-regresion-claude-vzert`) promovio a `Proximo paso`
  un pendiente formulado como "verificar... una vez OTRA instalacion actualice el plugin" — mismo
  defecto, palabras distintas, sin la frase literal "revisar si X respondio" que la version
  anterior de esta regla buscaba. El usuario lo senalo en vivo, en el propio cierre del cambio que
  arreglaba justo esta clase de fallo en otro proyecto. Si de verdad hace falta un seguimiento
  programado mas adelante, eso es un recordatorio (`routine-followup` u otro mecanismo de
  seguimiento), no una linea de este snippet.

  Incluye aqui los umbrales o criterios que ya se acordaron en esta sesion (un numero, un limite,
  una condicion de exito), si los hay. Sin ellos la sesion siguiente los vuelve a negociar contigo.
- **(Quitado en 2.35.0) la linea `Sigue abierto:`.** Listaba ids de los pendientes de la sesion
  y de los Alta de otras sesiones. Victor (2026-09-23) la senalo como inutil en los dos extremos:
  el agente que recibe el snippet solo actua sobre `Proximo paso`, y al humano una lista de ids no
  le da nada que hacer. Los pendientes propios siguen en `## Pendientes` de la ficha, que la linea
  `Lee …` manda leer. Lo que se podia hacer ya con esa lista lo cubre ahora el prompt opcional de
  **Step 8e**: un prompt completo para otra sesion, sobre un pendiente que vence hoy o un Alta.
  La medicion que la sostenia (2026-09-11: los pendientes mencionados en el snippet cerraban el 35%
  frente al 19%) no separaba el efecto de la linea del hecho de que el agente elige para el snippet
  lo que ya ve mas accionable; `p-cd965754ec` se redefinio para medir el prompt opcional.
  Las fichas escritas antes del 2026-09-23 conservan su linea y el audit las mide como antes.

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

**Si el caso 5 aplica** (la sesion no dejo trabajo que retomar, en ningun lado), reemplaza el
placeholder `<filled in Step 8>` con UNA linea, sin bloque de codigo — sin excepcion por
pendientes Alta del backlog general (esos no entran aqui: los reporta el hook de inicio de sesion,
y uno de ellos puede salir en el prompt opcional de Step 8e):

```markdown
## Como retomar

Ninguno — <la misma media-linea del caso 5: por que esta sesion se cierra sola>.
```

**En cualquier otro caso**, reemplaza el placeholder `<filled in Step 8>` de la seccion `## Como retomar` con el snippet dentro de un bloque de codigo (aqui con las dos condicionales presentes; omite la linea entera cuando no apliquen):

````markdown
## Como retomar

```
Retomamos: <contexto-1-linea>.

Lee memory/sessions/DATE-SLUG.md para el contexto completo.

Proximo paso: <next-step>.

No repitas: <callejones sin salida>.

Terminas cuando: <done-bar>.

Antes de actuar, dime en 3 lineas donde quedamos.
```
````

Ejemplo real, con las 6 lineas (sin `Sigue abierto:`, quitada en 2.35.0):

````markdown
```
Retomamos: plan v2.13.0 ratificado para que los pendientes dejen de ser un cementerio.

Lee memory/sessions/2026-09-09-pendientes-cementerio-plan.md para el contexto completo.

Proximo paso: medir en seco la precision del cierre por silencio sobre los 98 vencidos (umbrales ya acordados: >=90% de aciertos, cero cierres de items que pedian consultar un dato).

No repitas: clasificar los pendientes con un regex sobre su texto — fallo tres veces y un revisor rompio las tres; leelos y clasifica con criterio declarado.

Terminas cuando: haya un veredicto con numero (entra / no entra) y, si entra, el diseno de las tres senales de deteccion. Nada mas del plan en esa sesion.

Antes de actuar, dime en 3 lineas donde quedamos.
```
````

**8b. Imprimir al terminal — corre el script, no redactes el bloque otra vez**:

```bash
python3 "$JBIN/print-como-retomar.py" "$SESSION_FILE"
```

**Pega su salida tal cual, sin resumirla ni reformularla**, como el ultimo bloque de tu respuesta
(despues del reporte de Step 7). El script ya decide el formato correcto por ti — linea unica sin
separadores si el caso 5 aplica, bloque completo con separadores en cualquier otro caso — leyendo el MISMO `## Como retomar` que acabas de escribir en 8a. No existe una segunda
redaccion que pueda divergir de la primera, porque no hay una segunda redaccion: hay una lectura.

**Por que un script y no "redacta lo mismo otra vez".** Medido en vivo (2026-09-15, este mismo
repo): el agente que acababa de escribir el bloque en 8a, en el turno siguiente, no lo repitio —
escribio su propio resumen en prosa en su lugar, con la instruccion de 8b (idéntica a esta,
antes de este cambio) presente y leida segundos antes. La instruccion en prosa "imprime lo mismo
que en 8a" no impidio que el agente sustituyera el bloque exigido por su propia sintesis, bajo la
idea de que un resumen mas legible era mas util. Comparar 8a contra 8b despues del hecho tampoco
sirve — un comparador a mano es un proxy, no el instrumento (ya diverge en este mismo repo el
contador de backfill, justo donde importaba). La unica version que no se puede saltar por
sustitucion es la que no le da al agente nada que redactar: correr el script y pegar su stdout.

Si el script sale con codigo 1 (`Step 8a todavia no lleno esta seccion`), 8a no corrio — vuelve
ahi antes de continuar, no improvises el bloque a mano.

**La OMISION la vigila un hook Stop desde 2.33.0 (`checkpoint-close-guard.sh`).** El script de
arriba elimina la SUSTITUCION: no hay nada que redactar. No eliminaba la OMISION: en la sesion
5790b9f2 el snippet salio solo en la salida del script (un tool result, que el usuario no ve), y
en otro cierre el recordatorio de calendario quedo "persistido en la ficha" sin pegarse. Al
terminar un turno que corrio /checkpoint-3t o `print-como-retomar.py`, que edito `## Como
retomar` de una ficha, o que cerro, caduco o bloqueo un pendiente citado en el `## Como retomar`
de una ficha de esta sesion (con `journal-emit.py` o con `expire-pendientes.py --apply`), el hook
exige varias cosas en el TEXTO de tu respuesta, nunca en un tool
result:
- cada linea que imprime `print-como-retomar.py`;
- los dos primeros recordatorios de `## Recordatorios de calendario`, completos (y `+N con fecha
  futura` si hay mas);
- que `checkpoint-audit.py --solo-snippet` no marque `SALTADO` sobre la ficha final. Step 7a corre
  antes que Step 8 y no ve el snippet.

Si falta algo, bloquea el cierre una vez y te dice que pegar o corregir. Limite: en el segundo
intento seguido ya no bloquea, para no entrar en bucle. Solo avisa al usuario.

**El snippet no se congela al terminar el checkpoint (2.33.1).** Si DESPUES, en la misma sesion,
cierras, caducas o bloqueas un pendiente que el `## Como retomar` cita, el snippet que el usuario
ya tiene quedo viejo. Rehaz la linea afectada en la ficha, vuelve a correr `print-como-retomar.py`
y pega el snippet nuevo en esa misma respuesta. Caso real: tras el checkpoint de 2.33.0 se resolvio
`p-477bb60303` (el push) y la respuesta no aviso; el snippet seguia listandolo en `Sigue abierto`
(linea quitada en 2.35.0). Lo vigila el hook: dispara tambien en un turno que emite
`pendiente.resolve`, `pendiente.expire` o `pendiente.block` sobre un id citado en la ficha de esta
sesion, y en ese turno vuelve a exigir el snippet y el prompt opcional de Step 8e, que se genera en
vivo. En fichas anteriores al 2026-09-23 `checkpoint-audit.py` sigue marcando `SALTADO` en
`snippet.ids_vivos` si `Sigue abierto:` nombra un id que ya no esta abierto. Registrar un pendiente NUEVO tambien puede cambiar el snippet (un Alta nuevo gana
`Proximo paso`); eso no lo detecta ningun script: revisa la escalera y rehaz el snippet.

**Fallback (no JBIN)**: si `print-como-retomar.py` no existe (instalacion mas vieja que esta
version, o el sync de comandos aun no llego), redacta el bloque a mano copiando literalmente lo
que ya escribiste en 8a — el riesgo de divergencia por sustitucion de mas arriba aplica en ese
caso, asi que revisalo dos veces contra el session file antes de imprimirlo.

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

**8d. Recomendaciones de research sin resolver — bloque aparte, igual que el de calendario**:

Si algún research que el `## Research` de este session log enlaza (de esta sesión, o uno viejo
que solo revisaste) tiene una sección `## Recomendaciones` con ítems `- [ ]` sin marcar, corre:

```bash
python3 "$JBIN/print-research-recomendaciones.py" "$SESSION_FILE"
```

**Pega su salida tal cual, sin resumirla**, después del bloque de "Como retomar" (y después de
los recordatorios de calendario si los hay) — mismo motivo que 8b: una segunda redacción es una
segunda oportunidad de divergir o de sustituir el formato exigido por un resumen propio. Si no
imprime nada, no hay nada que pegar — el silencio en stdout es el caso normal (la mayoría de los
research no tienen recomendaciones múltiples, y los que las tienen normalmente ya se resolvieron).
**Si el script avisa por stderr que un wikilink de `## Research` no se pudo leer, no lo ignores**
— puede ser un research legítimamente `(inline)` (sin archivo propio), o puede ser un enlace roto
que esconde recomendaciones sin resolver que el script no pudo revisar. Repáralo o confírmalo
antes de asumir que ese research no tiene nada pendiente.

**Va fuera del bloque `## Como retomar`, no dentro — misma regla que el recordatorio de
calendario (8c).** No depende de qué caso de `<next-step>` haya aplicado: si el caso 5 colapsó
"Como retomar" a una línea porque esta sesión no dejó nada del TRABAJO DE HOY que retomar, un
research con recomendaciones sin resolver de una sesión anterior sigue sin resolverse igual, y
el colapso de una no tiene por qué implicar el otro. Confundir los dos fue exactamente lo que
pasó el 2026-09-17 en este mismo repo: una sesión implementó 1 de 4 recomendaciones de un
research, cerró con "Como retomar: ninguno" (caso 5, correcto para el trabajo de hoy), y las
otras 3 recomendaciones no aparecieron en ningún lado del cierre — el usuario tuvo que señalarlo
él mismo, en la sesión siguiente, porque nada se lo recordó.

**Persistir en el session file**: agrega la misma salida (o "Ninguna" si no imprimió nada) en una
sección `## Recomendaciones de research sin resolver`, entre `## Recordatorios de calendario` (o
`## Como retomar` si no hubo recordatorios) y `## Related`. Igual que 8c-2: los bloques
persistidos son idénticos a los impresos.

**8e. Prompt opcional para cerrar un pendiente en otra sesion (2.35.0)**:

```bash
python3 "$JBIN/print-pendiente-opcional.py" "$SESSION_FILE"
```

**Pega su salida tal cual** como el ultimo bloque de tu respuesta, despues de los de 8b, 8c y 8d.
Si no imprime nada, no hay nada que pegar. Es para el humano: un prompt completo (proyecto,
pendiente con su id, ficha de origen, motivo, clausula de cierre) que puede abrir en otra sesion,
ahora o cuando tenga tiempo. Reemplaza la linea `Sigue abierto:` que el snippet llevaba hasta
2.34.0, que el agente no usaba y el humano no podia accionar.

El script elige por campos de `_pendientes.md`, nunca por el texto (regla 216):
1. los que vencen hoy o ya vencieron (`_revisar` <= hoy), el mas viejo primero — hasta 2;
2. si no hay ninguno, el Alta con `_creado` mas reciente (a igual fecha, la fila mas arriba).

Nunca propone un pendiente con `_bloqueado:`, uno con `_revisar` futuro (ya tiene su recordatorio
de calendario) ni el que cita `Proximo paso:`. Sale haya o no recordatorios de calendario: un
recordatorio es para otra fecha y no compite con lo que se puede hacer hoy. Cuando `Proximo paso`
es `ninguno`, este es el unico prompt accionable del cierre.

**No se guarda en la ficha.** Se genera en vivo desde `_pendientes.md`, y el hook de cierre
(`checkpoint-close-guard.sh`) lo vuelve a correr y exige cada linea en tu respuesta. Si en la misma
sesion cambias el estado de un pendiente citado en la ficha, el hook lo pide otra vez con el estado
nuevo. Limite: cerrar DESPUES el pendiente que este prompt propone, sin tocar ninguno de la ficha,
no vuelve a disparar el hook; el propio prompt dice "si ya no aplica, cierralo".

No agregues git commit aqui — el cambio al session file ya quedo dentro del flujo de Step 6, pero como Step 8 corre DESPUES, ni `## Como retomar` ni `## Recordatorios de calendario` ni `## Recomendaciones de research sin resolver` estaran en el commit. Es aceptable: el snippet vive en disco y el commit es best-effort. Si el usuario quiere comitearlo, puede `git add memory/sessions/DATE-SLUG.md && git commit --amend --no-edit` manualmente o esperar al proximo checkpoint.
