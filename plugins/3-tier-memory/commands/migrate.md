---
description: Migrate an existing 3-tier memory system to the plugin. Installs local commands, absorbs auto-memory content into project memory, and establishes bridge.
---

# Migrate Existing Memory to Plugin

For projects that already have a `memory/` directory set up from the playbook. This command installs the plugin's local commands, absorbs any auto-memory files into the correct project memory folders, establishes the bridge, and verifies the setup.

## Step 1: Verify existing memory

Check that `memory/MEMORY.md` exists in the project root. If it does NOT exist, tell the user: "No memory system found. Use `/3-tier-memory:setup-memory` instead for a fresh setup." and stop.

Verify the basic structure exists:
- `memory/MEMORY.md`
- `memory/_pendientes.md`
- `memory/_session-index.md`
- `memory/_learnings.md`

Report what was found and what's missing. Continue even if some indexes are missing — we'll flag them in the audit at the end.

## Step 2: Install local commands

Create `PROJECT_DIR/.claude/commands/` directory if it doesn't exist.

Install these 4 command files. All use `-3t` suffix to avoid name collisions with global skills. If any already exist, overwrite them with the latest version:

### 2a. /checkpoint-3t
Create `.claude/commands/checkpoint-3t.md` with the checkpoint command content (session log, dual-write for sessions/pendientes/learnings, git commit). Use the same content as the setup-memory command's Step 6a.

### 2b. /status-3t
Create `.claude/commands/status-3t.md` with the status command content (read all indexes, count items, report compact summary).

### 2c. /audit-3t
Create `.claude/commands/audit-3t.md` with the audit command content (5 verification checklists: structure, content, bridge, wikilinks, CLAUDE.md).

### 2d. /backfill-3t
Create `.claude/commands/backfill-3t.md` with the backfill command content (reconstruct memory from JSONL history — sessions, pendientes, learnings, plans, research). Use the content from `templates/backfill-3t.md` in the plugin source.

Also create `.claude/commands/consolidate-3t.md` from `templates/consolidate-3t.md` (dedup learnings, supersede contradictions, reflect sessions into higher-level rules). The SessionStart hook auto-installs any command that is missing, so this is also covered automatically.

> **Antes de escribir aqui: si `PROJECT_DIR` es el directorio HOME del usuario, DETENTE.**
> `~/.claude/commands/` no es el ambito del proyecto: es el ambito **USER**, global. Instalar
> ahi hace que `/checkpoint-3t` y compañia aparezcan DUPLICADOS (user + project) en todos los
> demas proyectos, de forma permanente y sin rastro de su origen — y la copia global se queda
> vieja, porque el hook solo actualiza las locales. Si detectas ese caso, no escribas los
> comandos: dile al usuario que abra la sesion desde el directorio del proyecto y explica por que.

### 2e. Detect orphaned hook entries in project settings

The plugin registers its own hooks via `hooks.json` (using `${CLAUDE_PLUGIN_ROOT}`). Any 3-tier-memory hooks registered in `.claude/settings.json` or `.claude/settings.local.json` of the project are redundant, and if they use `$CLAUDE_PROJECT_DIR/.claude/hooks/...` (legacy per-project pattern) they often reference files that don't exist, causing `SessionStart:startup hook error`.

For each file that exists — `.claude/settings.json` and `.claude/settings.local.json`:

1. Read the file. If it's not valid JSON or has no `hooks` key, skip it.
2. For every nested hook `command` under `hooks.SessionStart|PostToolUse|PreCompact|SessionEnd|UserPromptSubmit`, flag the entry as suspicious if ANY of these match:
   - Command references one of the plugin's hook script filenames: `session-start.sh`, `session-end.sh`, `pre-compact.sh`, `check-index-registration.sh`, `post-tool-use.sh`
   - Command contains `.claude/hooks/` (per-project legacy path — the plugin never installs files there)
   - Command contains `plugins/3-tier-memory/` but does NOT use `${CLAUDE_PLUGIN_ROOT}` (plugin path referenced as project-local)
3. For each flagged command, expand `$CLAUDE_PROJECT_DIR` to the current project directory and check if the target script exists on disk.

Present findings to the user in a compact block, e.g.:

```
ORPHANED HOOK ENTRIES DETECTED
File: .claude/settings.local.json
  [MISSING] SessionStart → bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh
  [MISSING] PostToolUse  → bash $CLAUDE_PROJECT_DIR/.claude/hooks/post-tool-use.sh

These entries duplicate what the plugin provides via hooks.json and
reference files that don't exist. Remove them? (y/n)
```

Behavior rules:
- **If the user confirms removal**: edit the settings file and remove ONLY the flagged hook entries. If removing an entry leaves a matcher block with an empty `hooks` array, remove that matcher too. If an event (e.g. `SessionStart`) ends up with an empty array, remove that event key. Preserve every other setting untouched.
- **If the flagged hook's target file DOES exist**: read it and decide whether it duplicates the plugin, instead of skipping. This is the case that actually costs context — a working legacy hook that dumps the same memory the plugin already injects, silently, every session. Historically it went unnoticed for months (one project shipped ~31 KB of raw pendientes per session on top of the plugin's curated block).

  Classify each line of the existing script:
  - **Duplicated emission** — reads `_pendientes.md` and echoes its contents (typically `grep -E '^- \[ \]' .../_pendientes.md` piped to `echo`). This is the ONLY memory content the plugin's `session-start.sh` re-emits, curated by priority and truncated. Scope this narrowly: for `_learnings.md` the plugin emits a **count** (`REGLAS CRITICAS: N`) and never its contents, and it emits no other index at all — so a script that echoes learnings, plans, research, or any other index is providing something the plugin does NOT, and counts as custom. Getting this wrong deletes context the user never gets back.
  - **Duplicated protocol** — an `echo` whose text restates the plugin's own PROTOCOLO/dual-write reminder.
  - **Genuinely custom** — anything project-specific the plugin does not emit (e.g. a domain rule like "read learnings before SSH ops"). Note that scaffolding placeholders left unsubstituted (`<DOMAIN-SPECIFIC-ACTION>` and similar) are NOT custom — they are dead template text.

  Measure the duplicated emission before asking, so the user sees the real cost:

  ```bash
  grep -E '^- \[ \]' memory/_pendientes.md | wc -c   # bytes injected per session by the legacy hook
  ```

  Then report and offer the specific action:

  ```
  DUPLICATE HOOK DETECTED
  File: .claude/hooks/session-start.sh (exists, runs every session)
    [DUPLICATE] dumps 109 raw pendientes = 31.5 KB — the plugin already injects this, curated
    [DUPLICATE] PROTOCOLO reminder — the plugin emits an equivalent line
    [CUSTOM]    "ANTES de SSH/remote ops: leer memory/_learnings.md"

  Trim to the custom line only? (y/n)
  ```

  - If custom lines remain, rewrite the script keeping ONLY those, and leave its registration in settings intact.
  - If NOTHING custom remains, say so and offer to delete the script and its settings entry together.
  - If the script contains logic you cannot classify with confidence, do not rewrite it — fall back to warning the user with the byte measurement, so the decision is at least informed.
- **If no orphaned entries are found**: report `Hook entries: clean`.

Never touch hooks for other plugins or commands — only entries matching the heuristics above.

## Step 3: Create missing directories

Check and create any missing directories (don't touch existing ones):

```bash
mkdir -p memory/{sessions,pendientes,learnings,plans,research}
```

## Step 4: Create missing indexes

For each missing index file, create it with the standard template. Do NOT overwrite existing indexes — only create ones that don't exist:

- `memory/_pendientes.md` — if missing, create with Alta/Media/Baja prioridad sections
- `memory/_session-index.md` — if missing, create with session table
- `memory/_learnings.md` — if missing, create with topic table + Quick Reference
- `memory/_plans-index.md` — if missing, create with plans table
- `memory/_research-index.md` — if missing, create with Active/Completed Research tables

Use today's date for frontmatter. Keep the section headers and table layouts of `/setup-memory` Step 3
verbatim: since v2.12.0 they are the anchors `bin/journal-compact.py` writes under.

### 4b. Locate the journal scripts (v2.12.0)

Steps 5b and 5c below add rows and pendientes to the project indexes. They do it through journal
events, never by hand, because the project may already have agents checkpointing while you migrate:

```bash
MEMORY_DIR="memory"
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/journal-emit.py" ]; then
  JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
else
  JEMIT=$(find "$HOME/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
  JBIN=${JEMIT:+$(dirname "$JEMIT")}
fi
[ -n "$JBIN" ] && [ -f "$JBIN/journal-compact.py" ] && echo "JBIN=$JBIN" || echo "JBIN=NONE"
```

If it prints `JBIN=NONE` (plugin older than 2.12.0), use the **Fallback** in 5b/5c and say so in the report.

## Step 5: Scan and absorb auto-memory

Determine auto-memory path: `AUTO_MEMORY_DIR = ~/.claude/projects/<encoded-project-path>/memory/`
(where `<encoded-project-path>` is the project root with `/` replaced by `-` and leading `-`).

If `AUTO_MEMORY_DIR` does not exist or is empty, skip to Step 5e (create bridge).

### 5a. Scan and classify

List ALL files and directories in `AUTO_MEMORY_DIR`. Ignore `.DS_Store` and non-`.md` files. Classify the scenario:

- **Empty**: Only `MEMORY.md` (or nothing) — skip to 5e
- **Scenario A** (simple auto-memory files): Individual `.md` files with frontmatter `type:` (feedback, project, user, reference), no index files, no subdirectories
- **Scenario B** (full Model A 3-tier): Has index files (`_pendientes.md`, `_session-index.md`, etc.) AND/OR subdirectories (`sessions/`, `learnings/`, etc.)
- **Scenario C** (mixed): Valid bridge + residual `.md` files

Report the classification before proceeding:
```
Auto-memory scan:
  Path: ~/.claude/projects/<path>/memory/
  MEMORY.md: bridge | inline | missing
  Scenario: A (N files) | B (N indexes, M dirs) | C (bridge + N residual) | Empty
  Files to absorb: <list>
```

### 5b. Absorb individual auto-memory files

For each `.md` file in `AUTO_MEMORY_DIR` that is NOT `MEMORY.md`, NOT `*.bak`, NOT an index file (`_*.md`), NOT `CLAUDE.md`:

1. Read the file and extract frontmatter `type` field
2. Map to destination:
   - `type: reference` → `memory/research/{filename}` + a `research.upsert` event for the Completed Research row:
     `python3 "$JBIN/journal-emit.py" --type research.upsert --slug <filename-without-.md> --tema "<name>" --status completed --resultado "<description>" --date <file's frontmatter date or mtime, YYYY-MM-DD>` (never today: the date decides pruning)
   - `type: feedback` | `type: project` | `type: user` | no type → `memory/learnings/{filename}` + a `learning.add` event with no `--text` (registers the Topic Files row only; the copied file is not rewritten):
     `python3 "$JBIN/journal-emit.py" --type learning.add --topic <filename-without-.md> --title "<name>" --when "<derived from description>"`
3. If destination file already exists in project memory → **skip with warning**, do NOT overwrite
4. Copy file to destination, emit the index event (**Fallback (no JBIN)**: add the row by hand)
5. Delete source file from auto-memory

Special case: if `CLAUDE.md` exists in auto-memory, rename to `CLAUDE.md.bak` and warn user to review it manually for any rules to add to project CLAUDE.md.

### 5c. Merge Model A indexes (Scenario B only)

For each index file found in `AUTO_MEMORY_DIR` (`_pendientes.md`, `_session-index.md`, `_learnings.md`, `_plans-index.md`, `_research-index.md`):

The project index is never written by hand here: each row or item becomes a journal event and the
compactor merges it under its lock, so a checkpoint running in parallel loses nothing. The compactor
is idempotent by identifier (session slug, topic, plan slug/title, research slug/tema, pendiente
text+date+origin), so a row that already exists in the project index is a no-op.

1. Read the auto-memory index (the project index is read by the compactor itself)
2. For table-based indexes, emit one event per row of the auto-memory version:
   - `_session-index.md` row → `session.add --slug <slug> --date <Fecha> --status "<Status>" --summary "<Resumen>" --commit "<Commit>"`
   - `_learnings.md` Topic Files row → `learning.add --topic <slug from the wikilink> --title "<Topic>" --when "<When to consult>"` (no `--text`); Quick Reference entries → `learning.add --topic <topic that holds the rule> --quickref "<entry text>"` (no `--text`)
   - `_plans-index.md` row → `plan.upsert --slug <slug from the wikilink, or a slug from the title> --title "<Plan>" --status "<Status>" --date <Fecha> --sesion "<Sesion>" --pendientes "<Pendientes>" --learnings "<Learnings>"` (add `--inline` when the row has no plan file)
   - `_research-index.md` Active row → `research.upsert --slug <slug> --tema "<Tema>" --status active --next-step "<Next step>" --origen "<Origen>"`; Completed row → `research.upsert --slug <slug> --tema "<Tema>" --status completed --resultado "<Resultado>" --date <the _completado: date in the source row, else the source index's frontmatter `updated` date, YYYY-MM-DD>` (`--inline` when Archivo is "(inline)"; never today: the date decides pruning)
3. For `_pendientes.md`: for each open item (`- [ ]`) emit
   `pendiente.add --text "<texto without the _origen/_creado/_id suffixes>" --prioridad <section> --origen "<_origen value>" --creado <_creado value, or the file's date if missing>`
   Items with the same text, origin and creation date as one already in the project are written once.
4. Compact, then delete the auto-memory index file:
   ```bash
   python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"   # must print quarantined=0 pending_left=0
   ```
   If an event is quarantined (its anchor is missing in the project index — e.g. an index created by hand
   without the standard headers), read `memory/.journal/quarantine/*.reason`, add that row by hand, delete
   the `.json`/`.reason` pair, and report it.

   **Fallback (no JBIN)**: re-read the project index right before writing, append the missing rows/items
   by hand (match on the identifiers above), and let the next checkpoint's Step 3-pre assign `_id`s.

### 5d. Merge Model A subdirectories (Scenario B only)

For each subdirectory in `AUTO_MEMORY_DIR`:

**Standard dirs** (`sessions/`, `pendientes/`, `learnings/`, `plans/`, `research/`):
- For each `.md` file: if it already exists in project `memory/{dir}/` → skip; else copy to project
- Delete the now-empty auto-memory subdirectory

**Non-standard dirs** (e.g. `infrastructure/`, `playbooks/`):
- Create `memory/{dir-name}/` in project if it doesn't exist
- Copy all `.md` files that don't already exist in the destination
- Delete the now-empty auto-memory subdirectory

For large migrations (50+ files), summarize counts in the report rather than listing every file.

### 5e. Establish bridge

1. If `MEMORY.md` in auto-memory has inline content (>40 lines or has indexes/data), back up to `.bak` first (use `.bak2` if `.bak` already exists)
2. Create or overwrite `AUTO_MEMORY_DIR/MEMORY.md` with the standard bridge template:

```markdown
# <Project Name> — Memory Bridge

This project uses project-local memory. Files live in `memory/` within the project directory.

## At session start
1. Read `memory/_pendientes.md` — open action items
2. Read `memory/_learnings.md` — consult before making changes

## During execution
Since v2.12.0 the shared indexes are written ONLY through journal events (`bin/journal-emit.py` +
`bin/journal-compact.py`), never by editing them directly while other agents may be writing:
- New learning → `learning.add` event (`/checkpoint-3t` Step 4 or `/save-learning`): the compactor numbers the rule in `memory/learnings/<topic>.md` and updates `memory/_learnings.md`
- New pendiente → `pendiente.add` event (`/checkpoint-3t` Step 3b): the compactor writes `memory/_pendientes.md` (with `_origen:`, `_creado:`, `_id:`) and `memory/pendientes/YYYY-MM.md`
- Executing a plan → write `memory/plans/plan-<slug>.md` directly + `plan.upsert` event for the row in `memory/_plans-index.md` (`/checkpoint-3t` Step 5)
- New research → write `memory/research/{slug}.md` directly + `research.upsert` event for the row in `memory/_research-index.md` (`/checkpoint-3t` Step 5)

## Checkpoint
Use /checkpoint-3t to save progress. It will update session log, extract pendientes, update indexes, and git commit.

## Index
- `memory/MEMORY.md` — lean index
- `memory/_pendientes.md` — open action items
- `memory/_learnings.md` — learnings by topic
- `memory/_session-index.md` — session history
- `memory/_plans-index.md` — plans registry
- `memory/_research-index.md` — research tracker
```

3. Verify that `AUTO_MEMORY_DIR` contains ONLY `MEMORY.md` and optionally `.bak` files. If any other files remain, list them as warnings.

## Step 6: Update CLAUDE.md

Check if CLAUDE.md has the bridge protection rule and memory system section. If not, append:

```markdown
## CRITICAL: Auto-memory MEMORY.md is a BRIDGE ONLY

The file at `~/.claude/projects/<encoded-path>/memory/MEMORY.md` is a bridge that redirects to `memory/` in this project. NEVER write content, indexes, session data, learnings, or any operational data into that file. It must ONLY contain the redirect template. All memory operations go to `memory/` in the project directory. If auto-memory MEMORY.md has more than 30 lines, something is wrong — rewrite it as a bridge immediately.
```

Check if CLAUDE.md has a Memory System section. If not, append one listing the operational indexes, learnings, and /checkpoint-3t usage.

## Step 7: Run audit

Execute the audit checklists (same as /audit):
1. Structure: 5 dirs + 6 indexes
2. Content: each index has minimum valid structure
3. Bridge: compact, redirect-only, no residual files
4. Wikilinks: Related sections present
5. CLAUDE.md: has Memory System + bridge rule

## Step 8: Enable marketplace auto-update

Ensure the plugin receives future updates automatically. Run this bash command:

```bash
python3 -c "
import json, os
f = os.path.expanduser('~/.claude/plugins/known_marketplaces.json')
if os.path.exists(f):
    d = json.load(open(f))
    if '3-tier-memory-marketplace' in d:
        d['3-tier-memory-marketplace']['autoUpdate'] = True
        json.dump(d, open(f, 'w'), indent=2)
"
```

If the marketplace entry exists, report: "Auto-update: enabled". If the file doesn't exist or the marketplace isn't registered, report: "Auto-update: marketplace not found (plugin may not be installed via marketplace)" — this is not an error.

## Step 8b: Detect JSONL history for backfill

Check for existing JSONL conversation files:

```bash
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
JSONL_DIR="$HOME/.claude/projects/$ENCODED"
JSONL_COUNT=$(ls "$JSONL_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
```

Store `JSONL_COUNT` for inclusion in the report.

## Step 9: Report

```
MIGRATION COMPLETE
==================
Commands installed: /checkpoint-3t, /status-3t, /audit-3t, /backfill-3t, /consolidate-3t
Directories: N created, M already existed
Indexes: N created, M already existed (not overwritten)
CLAUDE.md: updated | already had all sections

AUTO-MEMORY ABSORPTION:
  Scenario: A | B | C | Empty
  Files absorbed: N → memory/learnings/, M → memory/research/
  Indexes merged: N (list which ones)
  Dirs merged: N (list which ones, file counts)
  Skipped (already existed): N
  Bridge: created | replaced (backed up) | already valid

AUDIT RESULTS:
<audit output from Step 7>

JSONL HISTORY: N files detected — run /backfill-3t to import past sessions
(If JSONL_COUNT is 0, omit this line)

Next: use /checkpoint-3t to save progress, /status-3t for overview, /audit-3t to verify.
```
