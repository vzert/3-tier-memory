---
description: Backfill memory from past JSONL conversation history. Reconstructs sessions, pendientes, learnings, plans, and research from Claude Code conversation logs.
---

# Backfill Memory from JSONL History

Reconstruct the full memory system from past Claude Code conversation logs. Uses parallel Haiku subagents for extraction (cheaper, faster) and the main session for synthesis and writing.

## Step 0: Overrides y reconsider mode

`extract-session-digest.py` soporta estas env vars:

- `BACKFILL_FORCE_ALL=1` — desactiva el gate trivial, procesa TODO (incluso sesiones cortas sin señal)
- `BACKFILL_TRIVIAL_LINE_THRESHOLD=N` — ajusta umbral de líneas (default 10)
- `BACKFILL_TRIVIAL_USER_MSG_THRESHOLD=N` — ajusta umbral de user msgs (default 2)

Si `BACKFILL_FORCE_ALL=1` está presente en el env al inicio de la sesión:
1. Lee `$JSONL_DIR/.backfill-progress.json` (si existe). **No esta en `memory/`**: vive
   junto a los `.jsonl`, que es donde lo escribe Step 3h y donde lo lee el aviso de
   arranque (`bin/session-start.sh`). Step 0 decia `memory/.backfill-progress.json` y ahi
   no hay nada, asi que un run con `BACKFILL_FORCE_ALL=1` no reconsideraba nada: leia un
   fichero inexistente, no fallaba, y seguia como si `skipped[]` estuviera vacio.
2. Renombra el array `skipped` -> `previously_skipped` (preserva auditoría)
3. Deja `skipped` como array vacío
4. Escribe el progress file actualizado y procede al Step 1

`processed[]` nunca se reconsidera automáticamente — esas sesiones ya tienen entrada en `memory/sessions/`. Para reconstruir una entrada específica: borrar el archivo en `memory/sessions/` y eliminar el UUID de `processed[]` manualmente.

## Step 0b: Prerequisites

1. Verify `memory/MEMORY.md` exists in `${CLAUDE_PROJECT_DIR:-$PWD}` (the variable arrives EMPTY in the agent's Bash calls). If not: tell the user "No memory system found. Run `/setup-memory` first." and **stop**.

2. Determine the JSONL directory:
```bash
ENCODED=$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[^A-Za-z0-9]/-/g')   # CLAUDE_PROJECT_DIR llega vacia al Bash del agente
JSONL_DIR="$HOME/.claude/projects/$ENCODED"
```

3. Verify `$JSONL_DIR` exists and contains `.jsonl` files. If not: tell the user "No JSONL session files found for this project." and **stop**.

4. Check for `.backfill-progress.json` in `$JSONL_DIR`. If it exists, load it — it tracks previously processed sessions for resume/idempotency.

5. Locate the extraction script:
```bash
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/extract-session-digest.py" ]; then
  EXTRACT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/bin/extract-session-digest.py"
else
  # Ruta del plugin INSTALADO: la version mas alta de `installed_plugins.json`
  # (si el plugin llega por varios marketplaces, cual esta activo no se sabe).
  # `find ... | head -1` devolvia una version ARBITRARIA del
  # cache (medido 2026-09-11: 2.13.2 con 2.17.1 instalada), y un checkpoint escribia
  # los indices con scripts cuatro versiones viejos, en silencio.
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "extract-session-digest.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  EXTRACT_SCRIPT=${_B:+$_B/extract-session-digest.py}
fi
```
If `$EXTRACT_SCRIPT` is empty or the file doesn't exist, report error: "Could not find extract-session-digest.py. Ensure the 3-tier-memory plugin is installed (`claude plugin install 3-tier-memory@3-tier-memory-marketplace`)." and **stop**.

6. Locate the journal scripts (v2.12.0). Every index row, rule and pendiente this command produces
is emitted as an event and written by the compactor in Step 4 — never by editing the indexes by hand:
```bash
MEMORY_DIR="memory"   # Model B; use the auto-memory path for Model A
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
If it prints `JBIN=NONE` (plugin older than 2.12.0), use the **Fallback** noted in each Step 3 sub-step
and say so in the final report.

7. Locate the dedup scripts (v2.20.0). `MATCHER` clasifica en Step 1; `STAMP` sella la ficha en
   Step 3b. Misma resolucion de tres niveles que arriba — incluida la rama que usa el arbol de
   trabajo cuando se corre dentro del propio repo del plugin:
```bash
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/match-session-file.py" ]; then
  DBIN="${CLAUDE_PLUGIN_ROOT}/bin"
elif [ -f "plugins/3-tier-memory/bin/match-session-file.py" ]; then
  DBIN="$PWD/plugins/3-tier-memory/bin"     # the plugin's own repo: dogfood the working tree
else
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "match-session-file.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  DBIN=${_B:+$_B}
fi
MATCHER=${DBIN:+$DBIN/match-session-file.py}
STAMP=${DBIN:+$DBIN/stamp-session-id.py}
[ -n "$MATCHER" ] && [ -f "$MATCHER" ] && echo "MATCHER=$MATCHER" || echo "MATCHER=NONE"
```
   Si imprime `MATCHER=NONE` (plugin anterior a 2.20.0), **para**: sin el matcher la
   clasificacion de Step 1 volveria a apoyarse en `customTitle`, que viene vacio en los JSONL
   medidos, y una pasada duplicaria cada sesion que ya tiene ficha. Di al usuario que actualice el
   plugin.

## Step 1: Inventory

### 1a. Guarda: identificar la sesion en curso

```bash
echo "CURRENT=${CLAUDE_CODE_SESSION_ID:-NONE}"
```

Si imprime `CURRENT=NONE`, **para** y dile al usuario: *"No puedo identificar la sesion en curso,
y sin eso el backfill escribiria una ficha de esta misma conversacion que `/checkpoint-3t`
volveria a escribir al cerrar: duplicado seguro. Cierra y reabre la sesion, o dime el UUID del
`.jsonl` en curso."*

**No lo adivines por fecha de modificacion.** Esa heuristica ya se descarto en 2.15.2 para el
contador: no es prueba de identidad, y aqui el precio es peor — descartar el `.jsonl` equivocado
silencia una sesion pendiente de verdad.

### 1b. Clasificacion determinista

```bash
OUT="${TMPDIR:-/tmp}/backfill-inventario.json"
python3 "$MATCHER" "$MEMORY_DIR" "$JSONL_DIR" --current "$CLAUDE_CODE_SESSION_ID" > "$OUT"
python3 -c "
import json
d = json.load(open('$OUT'))
print(d['counts'])
for r in d['results']:
    if r['verdict'] != 'match':
        print(r['verdict'], r['jsonl'], '|', r['reason'])
"
```

`match-session-file.py` une cada `.jsonl` con su ficha por dos caminos, sin heuristica de
parecido: el **sello** `session_id` del frontmatter (lo escriben Step 3b y `/checkpoint-3t`,
y `stamp-session-id.py` lo rechaza si no cuadra con la transcripcion),
y la **escritura observada** en la propia transcripcion (para las fichas anteriores al sello).
Devuelve cuatro veredictos: `match`, `review`, `process`, `current`.

> **Por que no se compara `customTitle`.** La version anterior de este paso clasificaba
> *"Already in memory"* casando `dateFirst` + `customTitle` contra el nombre de la ficha. Ese campo
> viene `null` en los 22 JSONL de este proyecto (medido 2026-09-12: 0 de 22; no comprobado en otras
> versiones, modos ni instalaciones), asi que ahi la regla no casaba nunca y lo unico que impedia el
> duplicado era el criterio del agente leyendo. Una ejecucion literal habria reimportado toda sesion
> con ficha. Las dos capas de `match-session-file.py` no dependen de ese campo, este o no relleno.

Ahora cruza el resultado con el resto de senales:

- **`current`** -> skip (la sesion en curso).
- **Ya procesada**: el nombre aparece en `processed` o `skipped` de
  `$JSONL_DIR/.backfill-progress.json` -> skip.
- **`match`** -> skip, y anotalo en `skipped` con `skippedReason` `already-in-memory`.
  **No toques la ficha existente**: la escribio `/checkpoint-3t` en vivo, viendo mas contexto del
  que puede reconstruir un digest del JSONL.
- **`review`** -> **no decide el comando**: va al bloque de abajo.
- **`process`** + `trivial == true` (de `--metadata-only`: pocas lineas, pocos mensajes y sin
  senal) -> skip, anotado como `trivial`.
- **`process`** + no trivial -> **a procesar**.

Ordena la lista "a procesar" cronologicamente por `dateFirst`.

### 1c. Bloque REVISAR — lo resuelve una persona, no el comando

Un `review` significa que hay ficha de esa fecha pero la identidad no esta probada (por ejemplo:
la sesion reescribio una ficha que creo otra, tipico de `/enrich-3t`). Decidirlo por parecido
tiene un fallo que no se ve nunca —marcar como ya-importada una sesion que no lo esta, y perderla—
asi que **antes de que Step 2 escriba nada**, pregunta al usuario con `AskUserQuestion`, una
pregunta por caso (maximo 4 por modal, en tandas si hay mas), con estas opciones:

- **Saltar (ya esta en memoria)** — anotar en `skipped` con razon `already-in-memory-confirmado`.
- **Procesar (no tiene ficha)** — entra en la lista a procesar.

Si el usuario no puede responder (headless), **no adivines**: deja esos `.jsonl` sin tocar, fuera
de `processed` y de `skipped`, y dilo en el informe final. Quedan pendientes para la proxima
pasada, que es el fallo visible y reversible.

### 1d. Informe del inventario

```
BACKFILL INVENTORY
==================
JSONL files found:  N
Already in memory:  M (sello session_id / escritura observada)
Already processed:  P (de un run anterior)
Trivial (skipped):  K (sin senal y <10 lineas y <2 user msgs)
Current session:    1
Needs review:       R (resueltos arriba: R1 saltar, R2 procesar)
To process:         J sessions

Processing J sessions...
```

Si J == 0, di *"Nothing to backfill. All sessions are already in memory."* y **para**.

## Step 2: Parallel Extraction via Haiku Subagents

Delegate the heavy extraction work to parallel Haiku subagents. This keeps raw JSONL content out of the main context window and processes files at Haiku rates.

### 2a. Determine batch size

```
files_to_process = J
if J <= 3:    process inline (skip to Step 2c — no agents needed)
if J <= 9:    3 agents (batches of ceil(J/3))
if J <= 16:   4 agents (batches of ceil(J/4))
if J > 16:    5 agents (batches of ceil(J/5))
```

### 2b. Launch extraction agents

Launch ALL agents in a **single message** (this enables parallel execution). Use:

```
Agent(
  subagent_type: "Explore",
  model: "haiku",
  description: "Extract JSONL batch N",
  prompt: <see template below>
)
```

**Agent prompt template** (adapt per batch):

```
Extract session digests from JSONL files and synthesize draft session entries.

EXTRACTION SCRIPT: <$EXTRACT_SCRIPT path>

FILES TO PROCESS:
1. <full path to file1.jsonl>
2. <full path to file2.jsonl>
3. <full path to file3.jsonl>

For EACH file, execute these steps:

STEP 1: Run the extraction script:
  python3 <EXTRACT_SCRIPT> <file_path>

STEP 2: Parse the JSON output from stdout.

STEP 3: From the parsed data, synthesize a draft entry:
  - slug: clean customTitle to slug format (lowercase, hyphens, max 40 chars). If no customTitle, derive from first 2-3 userTexts
  - title: human-readable session title
  - summary: 1-2 sentence summary of what the user was accomplishing
  - cambios: bullet list of key outcomes (from assistantTexts + toolsUsed patterns)
  - pendientes: extract items matching TODO/FIXME/"hay que"/"falta"/"pendiente"/"verificar"/"proxima sesion" from userTexts and assistantTexts. Return empty array if none.
  - learnings: extract gotchas/rules/warnings matching "cuidado"/"siempre"/"nunca"/"regla:"/"gotcha"/"ojo:" patterns. For each, identify the topic and the rule text. Return empty array if none.
  - plan_summary: if signals.plans is true, write a 2-3 line description of the plan work. Otherwise null.
  - research_summary: if signals.research is true, write topic + key findings in 2-3 lines. Otherwise null.

STEP 4: Return your results as a JSON array with one object per file. Return ONLY the JSON, no commentary.

Output format per session:
{
  "filename": "uuid.jsonl",
  "date": "YYYY-MM-DD",
  "slug": "suggested-slug",
  "title": "Session Title",
  "summary": "1-2 sentence summary",
  "cambios": ["outcome 1", "outcome 2"],
  "pendientes": ["action item 1", "action item 2"],
  "learnings": [{"topic": "topic-name", "rule": "the rule text"}],
  "signals": {"plans": true/false, "research": true/false},
  "plan_summary": "..." or null,
  "research_summary": "..." or null
}
```

### 2c. Inline processing (for J <= 3)

If only 1-3 files, skip agents and process directly in the main session:
- Run `python3 "$EXTRACT_SCRIPT" <file>` for each
- Parse JSON output
- Synthesize the same draft fields as described in the agent prompt above
- Continue to Step 3

## Step 3: Review + Write

Receive structured summaries from all agents (or inline processing). For each session draft:

### 3a. Validate and deduplicate

- Check slug doesn't collide with existing `memory/sessions/DATE-SLUG.md` — append `-2`, `-3` if needed
- Verify date is valid

### 3b. Create session file (Tier 3)

Write `memory/sessions/YYYY-MM-DD-slug.md`:

```markdown
---
type: session
date: YYYY-MM-DD
status: backfilled
---
# Session Title

## Contexto
<summary from draft>

## Cambios realizados
- <cambios from draft>

## Bugs fixed
- Ninguno

## Plans
- [[plans/plan-slug|Plan title]] — status (only if signals.plans is true)
- OR "Ninguno"

## Research
- [[research/slug|Research title]] (only if signals.research is true)
- OR "Ninguno"

## Learnings generados
- [[learnings/topic]] — description (only if learnings extracted)
- OR "Ninguno"

## Callejones sin salida
- <enfoque abandonado> no funciona porque <razon> — usa <alternativa>
- OR "Ninguno"

## Pendientes
- [ ] <item> — ver [[_pendientes]] (only if pendientes extracted)
- OR "Ninguno"

## Commits
- Backfilled from JSONL — no commit hash available

## Recordatorios de calendario
### YYYY-MM-DD — <Titulo>
<bloque completo, formato de /checkpoint-3t Step 8c>
(only if a pendiente names a date STILL in the future at backfill time; omit the
 whole section otherwise)

## Related
- [[_session-index]]
- [[_pendientes]] (if pendientes extracted)
- [[_learnings]] (if learnings extracted)
- [[_plans-index]] (if plans registered)
- [[_research-index]] (if research registered)
```

**Las tres secciones que NO se rellenan igual que en un checkpoint en vivo:**

- **`## Callejones sin salida`** (desde 2.15.1): solo lo que el transcript DICE que se abandono —
  un enfoque que se probo y se dejo, con la razon escrita en la conversacion. **Nunca lo infieras.**
  Si el transcript no lo dice, `Ninguno`. Un callejon inventado es peor que ninguno: la linea
  `No repitas:` del snippet lo transmite a la sesion siguiente como si fuera un acuerdo tuyo, y
  cierra un camino que nadie descarto.
- **`## Como retomar` no se escribe, a proposito.** El snippet dice donde quedamos y cual es el
  proximo paso; en una sesion reconstruida meses despues eso ya es falso por construccion. Un
  snippet obsoleto es peor que ninguno porque se pega tal cual. Esta es la UNICA seccion en la que
  el esqueleto del backfill diverge del de `/checkpoint-3t` a proposito. `/checkpoint-3t` lo
  contempla: si el fichero no trae `## Callejones sin salida`, omite la linea `No repitas:` en vez
  de crearla.
- **`## Recordatorios de calendario`**: solo para fechas que **siguen siendo futuras en el momento
  de correr el backfill**. Una fecha ya pasada no genera recordatorio — el evento de calendario
  llegaria vencido. Mismo formato que Step 8c de `/checkpoint-3t`: `Titulo` abierto por
  `[<proyecto>]` (~70 caracteres contando el prefijo), `Descripcion`, y el fence encabezado por
  `Proyecto: <basename> — <ruta absoluta>`. El proyecto es el del backfill que estas corriendo, no
  el de la sesion reconstruida — son el mismo. Si ninguna fecha sigue viva, borra la seccion
  entera.

Y sella la ficha con el UUID del `.jsonl` de origen, en cuanto exista el fichero:

```bash
python3 "$STAMP" "memory/sessions/YYYY-MM-DD-slug.md" "<uuid-del-jsonl>" --jsonl-dir "$JSONL_DIR"
```

Esto es lo que hace que el run SIGUIENTE la reconozca aunque se pierda `.backfill-progress.json`:
el dedup deja de depender de un fichero de estado y pasa a estar escrito en la propia ficha.
`stamp-session-id.py` se niega si el UUID no tiene `.jsonl` en `$JSONL_DIR` y nunca pisa un sello
distinto que ya estuviera puesto — un sello equivocado no produce un duplicado visible, produce
el fallo invisible.

### 3c. Update session index (Tier 2) — via journal

Emit one `session.add` event per session (the compactor writes the row in Step 4):

```bash
python3 "$JBIN/journal-emit.py" --type session.add --slug "YYYY-MM-DD-slug" --date YYYY-MM-DD \
  --status backfilled --summary "<one-line summary>" --commit backfill
```

It becomes `| YYYY-MM-DD | [[sessions/YYYY-MM-DD-slug\|slug]] | backfilled | <summary> | backfill |`
at the top of the `## Sessions` table; the compactor keeps the 10 most recent rows by date, so an old
backfilled session may be pruned from the index right away (its Tier 3 file stays).

**Fallback (no JBIN)**: add the row to `memory/_session-index.md` by hand.

### 3d. Extract pendientes (conditional)

**Only extract pendientes from the 5 most recent sessions** (by dateFirst). Older pendientes are likely already resolved.

If the draft has pendientes AND this session is within the 5 most recent:
1. Before adding, check if an equivalent pendiente already exists in `_pendientes.md` (fuzzy match on key phrases). Skip duplicates.
2. For each new pendiente, emit one event (the compactor writes both tiers in Step 4):
   ```bash
   python3 "$JBIN/journal-emit.py" --type pendiente.add --text "<texto>" --prioridad Media \
     --origen "[[sessions/YYYY-MM-DD-slug]] (backfill)" --creado YYYY-MM-DD   # dateFirst, NOT today
   ```
   **Si el pendiente nombra una fecha posterior a HOY** (no a `--creado`), anade
   `--revisar YYYY-MM-DD` con esa fecha. **Una expresion relativa se resuelve contra la fecha de la
   SESION, no contra hoy**: `en 2 semanas` dicho el 2026-09-10 es el 2026-09-24, porque eso es lo
   que significaba cuando se escribio. Resuelve primero, y solo entonces compara el resultado con
   hoy para decidir si sigue viva. Formas que cuentan, las mismas que enumera `/checkpoint-3t`
   Step 8c: `revisar el 2026-09-22`, `target 2026-10-01`, `T+7`, `en 2 semanas`. **Si la expresion
   es demasiado vaga para dar una fecha** (`mas adelante`, `cuando se pueda`), no inventes una: no
   emitas `--revisar`. Una ventana inventada es peor que ninguna, porque `expire-pendientes.py`
   la trata como un compromiso declarado por ti. Es el mismo campo que emite `/checkpoint-3t`, y tiene dos
   consumidores reales: `expire-pendientes.py` (no caduca un item cuya ventana aun no vence) y el
   barrido manual de `/triage-3t`. Sin el, un pendiente reconstruido con ventana declarada queda
   indistinguible de uno sin ventana. **Compara contra hoy, no contra `--creado`**: lo que decide
   es si la fecha sigue viva ahora, no si era futura cuando se escribio.
   **Tier 2**: `- [ ] <texto> — _origen: [[sessions/YYYY-MM-DD-slug]] (backfill)_ — _creado: YYYY-MM-DD_ — _id: p-…_`
   under Media prioridad of `memory/_pendientes.md`. **Tier 3**: a row in `memory/pendientes/YYYY-MM.md`
   (the month of `--creado`; the file is created if needed).

   **Fallback (no JBIN)**: write the Tier 2 line (without `_id`) and the Tier 3 row by hand.

### 3e. Extract learnings (conditional)

If the draft has learnings:
1. For each learning, determine the topic (existing slug in `memory/learnings/`, or a new one)
2. Check the topic file for an equivalent rule (fuzzy match); skip duplicates
3. Emit one `learning.add` event per rule (the compactor numbers it, creates the topic file with
   frontmatter and its Topic Files row if new, and adds the `--quickref` text to the Quick Reference):
   ```bash
   python3 "$JBIN/journal-emit.py" --type learning.add --topic <topic-slug> \
     --text "**<Rule name>** — <explanation> (backfill: [[sessions/YYYY-MM-DD-slug]])" \
     [--quickref "**<Rule name>** — <short form>"] [--title "<Topic Title>" --when "<when to consult>" --importance <0-10>]
   ```

   **Fallback (no JBIN)**: append the rule with the next number, create the topic file, and update
   `memory/_learnings.md` by hand.

### 3f. Register plans (conditional)

If `signals.plans` is true and `plan_summary` is not null:
1. Determine status: if plan was executed -> `completed`; if only designed -> `draft`
2. For substantive plans: create `memory/plans/plan-slug.md` (direct write) and emit
   `plan.upsert`; for simple plans emit it with `--inline` (no plan file):
   ```bash
   python3 "$JBIN/journal-emit.py" --type plan.upsert --slug <slug> --title "<Plan title>" \
     --status completed|draft --date YYYY-MM-DD --sesion "[[sessions/YYYY-MM-DD-slug]]" [--inline]
   ```
   The compactor keeps active/draft/testing rows and the 5 most recent completed/abandoned by date.

   **Fallback (no JBIN)**: add the row to `memory/_plans-index.md` by hand ("(inline)" for simple plans).

### 3g. Register research (conditional)

If `signals.research` is true and `research_summary` is not null:
1. Determine status: if conclusions drawn -> `completed`; if ongoing -> `active`
2. For substantive research: create `memory/research/slug.md` (direct write) and emit
   `research.upsert`; for brief lookups emit it with `--inline` (no research file):
   ```bash
   python3 "$JBIN/journal-emit.py" --type research.upsert --slug <slug> --tema "<Topic>" \
     --status completed|active --date YYYY-MM-DD [--resultado "<conclusion>"] [--next-step "<next step>"] \
     --origen "[[sessions/YYYY-MM-DD-slug]]" [--inline]     # --date = the session's dateFirst, NOT today
   ```
   `completed` rows go to Completed Research with `_completado: DATE_` in the Archivo cell taken from
   `--date` (without it the emitter stamps today, which would misdate a historical research and let it
   evict a genuinely newer row); `active` rows go to Active Research. The compactor keeps the 5 most
   recent Completed rows by that date.

   **Fallback (no JBIN)**: add the row to `memory/_research-index.md` by hand ("(inline)" for brief lookups).

### 3h. Update progress

After each session is fully written, update **`$JSONL_DIR/.backfill-progress.json`**
(junto a los `.jsonl`, no en `memory/` — es el fichero que lee el aviso de arranque):
```json
{
  "processed": ["uuid1.jsonl", "uuid2.jsonl"],
  "skipped": ["uuid3.jsonl"],
  "lastRun": "2026-04-06T18:00:00Z",
  "totalFound": 8,
  "batchesCompleted": 1
}
```

## Step 4: Index reconciliation

After all sessions are processed:

1. **Compact the journal** — this is what writes every index row and pendiente emitted in Step 3:
   ```bash
   python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
   ```
   It must print `JOURNAL applied=N quarantined=0 pending_left=0` (a `rescued=N` there is fine: events an older version quarantined for a missing anchor, applied now). If `quarantined>0`, read each
   `memory/.journal/quarantine/*.reason`, apply that change by hand, delete the `.json`/`.reason` pair,
   and report it in Step 6. Compacting once at the end (instead of per session) is fine: events are
   applied in emission order.
2. **Pruning** of sessions and plans is done by the compactor on every event it applies (same limits
   as checkpoint): `_session-index.md` 10 most recent by date; `_plans-index.md` active/draft/testing +
   5 most recent completed. Rows are inserted newest-first; the session table is no longer re-sorted
   by hand. `_research-index.md` Completed Research is pruned to the 5 most recent by the
   `_completado: DATE_` mark (rows without it are never pruned). `_pendientes.md` and `_learnings.md`
   are never pruned.

   **Fallback (no JBIN)**: sort `_session-index.md` by date and apply the limits above by hand.
3. **Deduplicate pendientes**: If the same pendiente text appears multiple times in `_pendientes.md`, keep only the first occurrence (earliest origin)

## Step 5: Git commit (best-effort)

Follow the same pattern as checkpoint Step 6:

### 5a. Check git availability
```bash
command -v git 2>/dev/null
```
If missing -> skip git, report "Git: not found. Memory files saved but no commit."

### 5b. Check if inside a repo
```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```
If not -> skip git, report "Git: not in a repo."

### 5c. Stage and commit
```bash
git add memory/
git commit -m "memory: backfill N sessions from JSONL history

Sessions: DATE_FIRST to DATE_LAST
Created: N session files, M pendientes, K learnings, P plans, R research

Co-Authored-By: Claude <noreply@anthropic.com>"
```

If commit fails -> report the error but do NOT fail the backfill. Memory files are already written.

### 5d. Record result
Save the commit hash (or "skipped") for the final report.

## Step 6: Report

```
BACKFILL COMPLETE
=================
Sessions created:     N (YYYY-MM-DD to YYYY-MM-DD)
Pendientes extracted: N (X alta, Y media, Z baja)
Learnings added:      N rules to M topic files
Plans registered:     N (K with detail files)
Research registered:  N (K with detail files)
Skipped:              N trivial, M already existed, P already processed
Extraction:           N agents (Haiku) | inline
Git:                  committed as <hash> | skipped (<reason>)

Sessions created:
  - YYYY-MM-DD-slug — one-line summary
  - YYYY-MM-DD-slug — one-line summary
  ...
```

## Important Notes

- **Backfilled sessions use `status: backfilled`** to distinguish from live-captured sessions
- **Pendientes are only extracted from the 5 most recent sessions** — older ones are likely resolved
- **Progress is saved after each session** — safe to interrupt with Ctrl+C at any time
- **Running backfill again is safe** — already-processed sessions are skipped via `.backfill-progress.json`
- **The extraction script must exist** at `$CLAUDE_PLUGIN_ROOT/bin/extract-session-digest.py` or anywhere under `~/.claude/plugins/` within a `3-tier-memory` directory
- **Follow dual-write protocol** for ALL artifacts: Tier 2 index row + Tier 3 detail file
- **Use wikilinks** in all cross-references: `[[sessions/DATE-slug]]`, `[[learnings/topic]]`, etc.
- **Backfill pendientes are marked** with `(backfill)` in their `_origen:` to distinguish from live-extracted ones
- **Subagent extraction**: For 4+ files, Haiku subagents run in parallel for faster, cheaper extraction. Raw JSONL content stays in Haiku sessions — only structured summaries enter the main context.
