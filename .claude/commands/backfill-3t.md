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
1. Lee `memory/.backfill-progress.json` (si existe)
2. Renombra el array `skipped` -> `previously_skipped` (preserva auditoría)
3. Deja `skipped` como array vacío
4. Escribe el progress file actualizado y procede al Step 1

`processed[]` nunca se reconsidera automáticamente — esas sesiones ya tienen entrada en `memory/sessions/`. Para reconstruir una entrada específica: borrar el archivo en `memory/sessions/` y eliminar el UUID de `processed[]` manualmente.

## Step 0b: Prerequisites

1. Verify `memory/MEMORY.md` exists in `$CLAUDE_PROJECT_DIR`. If not: tell the user "No memory system found. Run `/setup-memory` first." and **stop**.

2. Determine the JSONL directory:
```bash
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
JSONL_DIR="$HOME/.claude/projects/$ENCODED"
```

3. Verify `$JSONL_DIR` exists and contains `.jsonl` files. If not: tell the user "No JSONL session files found for this project." and **stop**.

4. Check for `.backfill-progress.json` in `$JSONL_DIR`. If it exists, load it — it tracks previously processed sessions for resume/idempotency.

5. Locate the extraction script:
```bash
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/extract-session-digest.py" ]; then
  EXTRACT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/bin/extract-session-digest.py"
else
  EXTRACT_SCRIPT=$(find "$HOME/.claude/plugins" -name "extract-session-digest.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
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
  JEMIT=$(find "$HOME/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
  JBIN=${JEMIT:+$(dirname "$JEMIT")}   # empty when find found nothing (dirname "" would give ".")
fi
[ -n "$JBIN" ] && [ -f "$JBIN/journal-compact.py" ] && echo "JBIN=$JBIN" || echo "JBIN=NONE"
```
If it prints `JBIN=NONE` (plugin older than 2.12.0), use the **Fallback** noted in each Step 3 sub-step
and say so in the final report.

## Step 1: Inventory

Run the extraction script in metadata-only mode for every JSONL file:

```bash
for f in "$JSONL_DIR"/*.jsonl; do
  python3 "$EXTRACT_SCRIPT" --metadata-only "$f"
done
```

Parse each output and build an inventory. For each JSONL file, collect:
- `filename` (just the UUID.jsonl basename)
- `sessionId`
- `customTitle`
- `dateFirst`
- `lineCount`
- `userMessageCount`
- `trivial` (boolean)
- `signals`

Now classify each file:

- **Already processed**: `filename` appears in `.backfill-progress.json` `processed` or `skipped` arrays -> skip
- **Trivial**: `trivial == true` (tiny size AND no signal: no tools used, no plan mode, no signals.*) -> will be skipped (mark in progress file)
- **Already in memory**: A file exists in `memory/sessions/` whose name starts with the same `dateFirst` AND whose title/slug approximately matches `customTitle` -> skip
- **Current session**: The JSONL file being actively written (check: most recent `tsLast` within last 5 minutes, or matches known current session) -> skip
- **To process**: Everything else

Sort the "to process" list chronologically by `dateFirst`.

Report the inventory:
```
BACKFILL INVENTORY
==================
JSONL files found: N
Already in memory:  M (matched by date+title)
Already processed:  P (from previous backfill run)
Trivial (skipped):  K (sin señal y <10 líneas y <2 user msgs)
Current session:    1
To process:         J sessions

Processing J sessions...
```

If J == 0, report "Nothing to backfill. All sessions are already in memory." and **stop**.

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

## Pendientes
- [ ] <item> — ver [[_pendientes]] (only if pendientes extracted)
- OR "Ninguno"

## Commits
- Backfilled from JSONL — no commit hash available

## Related
- [[_session-index]]
- [[_pendientes]] (if pendientes extracted)
- [[_learnings]] (if learnings extracted)
- [[_plans-index]] (if plans registered)
- [[_research-index]] (if research registered)
```

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

After each session is fully written, update `.backfill-progress.json`:
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
   It must print `JOURNAL applied=N quarantined=0 pending_left=0`. If `quarantined>0`, read each
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
