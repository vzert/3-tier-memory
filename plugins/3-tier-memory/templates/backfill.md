---
description: Backfill memory from past JSONL conversation history. Reconstructs sessions, pendientes, learnings, plans, and research from Claude Code conversation logs.
---

# Backfill Memory from JSONL History

Reconstruct the full memory system from past Claude Code conversation logs. This command reads JSONL session files, extracts meaningful content, and creates all memory artifacts following the dual-write protocol.

## Step 0: Prerequisites

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
EXTRACT_SCRIPT="${CLAUDE_PLUGIN_ROOT}/bin/extract-session-digest.py"
```
If `$CLAUDE_PLUGIN_ROOT` is not set or the script doesn't exist, try: `$(dirname $(dirname $(readlink -f "$0")))/bin/extract-session-digest.py` or search in the plugin installation directory. If still not found, report error and stop.

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

- **Already processed**: `filename` appears in `.backfill-progress.json` `processed` or `skipped` arrays → skip
- **Trivial**: `trivial == true` → will be skipped (mark in progress file)
- **Already in memory**: A file exists in `memory/sessions/` whose name starts with the same `dateFirst` AND whose title/slug approximately matches `customTitle` → skip
- **Current session**: The JSONL file being actively written (check: most recent `tsLast` within last 5 minutes, or matches known current session) → skip
- **To process**: Everything else

Sort the "to process" list chronologically by `dateFirst`.

Report the inventory:
```
BACKFILL INVENTORY
==================
JSONL files found: N
Already in memory:  M (matched by date+title)
Already processed:  P (from previous backfill run)
Trivial (skipped):  K (< 3 user messages)
Current session:    1
To process:         J sessions

Processing J sessions chronologically...
```

If J == 0, report "Nothing to backfill. All sessions are already in memory." and **stop**.

## Step 2: Full extraction + synthesis loop

Process ALL sessions continuously. For each JSONL file to process (in chronological order):

### 2a. Extract full digest

```bash
python3 "$EXTRACT_SCRIPT" "$JSONL_DIR/<filename>"
```

Read the JSON output. This contains `userTexts`, `assistantTexts`, `toolsUsed`, `filesTouched`, and `signals`.

### 2b. Generate session slug

- If `customTitle` exists: clean it to slug format (lowercase, replace spaces/special chars with hyphens, max 40 chars)
- Otherwise: synthesize from the first 2-3 user messages (pick the main topic)
- Check for collision: if `memory/sessions/DATE-SLUG.md` already exists, append `-2`, `-3` etc.

### 2c. Create session file (Tier 3)

Write `memory/sessions/YYYY-MM-DD-slug.md` with this exact format:

```markdown
---
type: session
date: YYYY-MM-DD
status: backfilled
---
# Session Title

## Contexto
<1-2 sentence summary synthesized from the conversation — what was the user trying to accomplish?>

## Cambios realizados
- <bullet points of what was done, extracted from assistant text and tool usage>
- <focus on outcomes, not process>

## Bugs fixed
- <any bugs mentioned> OR "Ninguno"

## Plans
- [[plans/plan-slug|Plan title]] — status (only if signals.plans is true and plan work was done)
- OR "Ninguno"

## Research
- [[research/slug|Research title]] (only if signals.research is true)
- OR "Ninguno"

## Learnings generados
- [[learnings/topic]] — description (only if signals.learnings is true)
- OR "Ninguno"

## Pendientes
- [ ] <action item> — ver [[_pendientes]] (only if signals.pendientes is true)
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

### 2d. Update session index (Tier 2)

Add a row to `memory/_session-index.md` in the Sessions table:

```
| YYYY-MM-DD | [[sessions/YYYY-MM-DD-slug\|slug]] | backfilled | <one-line summary> | backfill |
```

### 2e. Extract pendientes (conditional)

**Only extract pendientes from the 5 most recent sessions** (by dateFirst). Older pendientes are likely already resolved.

If `signals.pendientes` is true AND this session is within the 5 most recent:
1. Scan `userTexts` and `assistantTexts` for pendiente patterns:
   - Lines containing: TODO, FIXME, "hay que", "falta", "pendiente", "verificar", "próxima sesión"
   - Deferred work: "después", "luego", "mañana"
2. For each extracted pendiente:
   - Add to `memory/_pendientes.md` under Media prioridad (default, since we can't determine exact priority from historical context) with `_origen: [[sessions/YYYY-MM-DD-slug]] (backfill)_`
   - Add row to `memory/pendientes/YYYY-MM.md` (create the file if it doesn't exist for that month)
3. Before adding, check if an equivalent pendiente already exists in `_pendientes.md` (fuzzy match on key phrases). Skip duplicates.

### 2f. Extract learnings (conditional)

If `signals.learnings` is true:
1. Scan for learning patterns in the conversation: gotchas, rules stated, warnings, "cuidado con", "siempre hacer X", "nunca hacer Y"
2. Determine the topic: derive from the main work done in the session (e.g., if working on plugin packaging → learnings file is about plugin packaging)
3. Check if a learnings file already exists for that topic in `memory/learnings/`
   - If yes: append new rules (check for duplicates first)
   - If no: create new topic file with frontmatter
4. If a new critical rule was found, add it to the Quick Reference in `memory/_learnings.md`
5. If a new topic file was created, add a row to the Topic Files table in `memory/_learnings.md`

### 2g. Register plans (conditional)

If `signals.plans` is true (plan mode was used, or plan keywords detected):
1. Determine plan title from conversation context
2. Determine status: if the plan was executed in the same session → `completed`; if only designed → `draft`; if mentioned but not started → skip
3. For substantive plans (>20 lines of plan content in the conversation):
   - Create `memory/plans/plan-slug.md` with Context, Approach, Decisions, Outcome sections
   - Add row to `memory/_plans-index.md`
4. For simple plans:
   - Add row to `memory/_plans-index.md` with "(inline)" in the Plan column

### 2h. Register research (conditional)

If `signals.research` is true (WebSearch/WebFetch tools used):
1. Determine research topic from the search queries and context
2. Determine status: if conclusions were drawn → `completed`; if ongoing → `active`
3. For substantive research:
   - Create `memory/research/slug.md` with Context, Findings, Conclusion sections
   - Add row to `memory/_research-index.md`
4. For brief lookups:
   - Add row to `memory/_research-index.md` Completed table with "(inline)"

### 2i. Update progress

After each session is fully processed, update `.backfill-progress.json`:
```bash
# Read current progress, add this filename to processed, write back
```

The structure:
```json
{
  "processed": ["uuid1.jsonl", "uuid2.jsonl"],
  "skipped": ["uuid3.jsonl"],
  "lastRun": "2026-04-06T18:00:00Z",
  "totalFound": 8,
  "batchesCompleted": 1
}
```

### 2j. Progress reporting

Every 10 sessions, print a progress line:
```
PROGRESS: 10/40 sessions processed...
```

## Step 3: Index reconciliation

After all sessions are processed:

1. **Sort session index**: Read `memory/_session-index.md`, sort the table rows by date (oldest first)
2. **Apply pruning rules** (same as checkpoint):
   - `_session-index.md`: keep only 10 most recent rows
   - `_plans-index.md`: keep active/draft/testing + 5 most recent completed
   - `_research-index.md`: keep all Active + 5 most recent Completed
   - `_pendientes.md`: no pruning (manual management)
   - `_learnings.md`: no pruning
3. **Deduplicate pendientes**: If the same pendiente text appears multiple times in `_pendientes.md`, keep only the first occurrence (earliest origin)

## Step 4: Git commit (best-effort)

Follow the same pattern as checkpoint Step 6:

### 4a. Check git availability
```bash
command -v git 2>/dev/null
```
If missing → skip git, report "Git: not found. Memory files saved but no commit."

### 4b. Check if inside a repo
```bash
git rev-parse --is-inside-work-tree 2>/dev/null
```
If not → skip git, report "Git: not in a repo."

### 4c. Stage and commit
```bash
git add memory/
git commit -m "memory: backfill N sessions from JSONL history

Sessions: DATE_FIRST to DATE_LAST
Created: N session files, M pendientes, K learnings, P plans, R research

Co-Authored-By: Claude <noreply@anthropic.com>"
```

If commit fails → report the error but do NOT fail the backfill. Memory files are already written.

### 4d. Record result
Save the commit hash (or "skipped") for the final report.

## Step 5: Report

```
BACKFILL COMPLETE
=================
Sessions created:     N (YYYY-MM-DD to YYYY-MM-DD)
Pendientes extracted: N (X alta, Y media, Z baja)
Learnings added:      N rules to M topic files
Plans registered:     N (K with detail files)
Research registered:  N (K with detail files)
Skipped:              N trivial, M already existed, P already processed
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
- **The extraction script must exist** at `$CLAUDE_PLUGIN_ROOT/bin/extract-session-digest.py`
- **Follow dual-write protocol** for ALL artifacts: Tier 2 index row + Tier 3 detail file
- **Use wikilinks** in all cross-references: `[[sessions/DATE-slug]]`, `[[learnings/topic]]`, etc.
- **Backfill pendientes are marked** with `(backfill)` in their `_origen:` to distinguish from live-extracted ones
