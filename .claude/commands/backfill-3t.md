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
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g')
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

### 3c. Update session index (Tier 2)

Add a row to `memory/_session-index.md`:

```
| YYYY-MM-DD | [[sessions/YYYY-MM-DD-slug\|slug]] | backfilled | <one-line summary> | backfill |
```

### 3d. Extract pendientes (conditional)

**Only extract pendientes from the 5 most recent sessions** (by dateFirst). Older pendientes are likely already resolved.

If the draft has pendientes AND this session is within the 5 most recent:
1. Before adding, check if an equivalent pendiente already exists in `_pendientes.md` (fuzzy match on key phrases). Skip duplicates.
2. For each new pendiente:
   - **Tier 2**: Add to `memory/_pendientes.md` under Media prioridad with `_origen: [[sessions/YYYY-MM-DD-slug]] (backfill)_`
   - **Tier 3**: Add row to `memory/pendientes/YYYY-MM.md` (create the file if needed)

### 3e. Extract learnings (conditional)

If the draft has learnings:
1. For each learning, determine the topic
2. Check if a learnings file already exists for that topic in `memory/learnings/`
   - If yes: append new rules (check for duplicates first)
   - If no: create new topic file with frontmatter
3. If a new critical rule was found, add it to the Quick Reference in `memory/_learnings.md`
4. If a new topic file was created, add a row to the Topic Files table in `memory/_learnings.md`

### 3f. Register plans (conditional)

If `signals.plans` is true and `plan_summary` is not null:
1. Determine status: if plan was executed -> `completed`; if only designed -> `draft`
2. For substantive plans: create `memory/plans/plan-slug.md` + row in `memory/_plans-index.md`
3. For simple plans: row in `memory/_plans-index.md` with "(inline)"

### 3g. Register research (conditional)

If `signals.research` is true and `research_summary` is not null:
1. Determine status: if conclusions drawn -> `completed`; if ongoing -> `active`
2. For substantive research: create `memory/research/slug.md` + row in `memory/_research-index.md`
3. For brief lookups: row in `memory/_research-index.md` Completed table with "(inline)"

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

1. **Sort session index**: Read `memory/_session-index.md`, sort the table rows by date (oldest first)
2. **Apply pruning rules** (same as checkpoint):
   - `_session-index.md`: keep only 10 most recent rows
   - `_plans-index.md`: keep active/draft/testing + 5 most recent completed
   - `_research-index.md`: keep all Active + 5 most recent Completed
   - `_pendientes.md`: no pruning (manual management)
   - `_learnings.md`: no pruning
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
