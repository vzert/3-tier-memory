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

Use today's date for frontmatter.

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
   - `type: reference` → `memory/research/{filename}` + add row to `_research-index.md` Completed Research table (Tema = `name`, Resultado = `description`, Archivo = link)
   - `type: feedback` | `type: project` | `type: user` | no type → `memory/learnings/{filename}` + add row to `_learnings.md` Topic Files table (Topic = `name`, File = wikilink, When to consult = derived from `description`)
3. If destination file already exists in project memory → **skip with warning**, do NOT overwrite
4. Copy file to destination, add index row
5. Delete source file from auto-memory

Special case: if `CLAUDE.md` exists in auto-memory, rename to `CLAUDE.md.bak` and warn user to review it manually for any rules to add to project CLAUDE.md.

### 5c. Merge Model A indexes (Scenario B only)

For each index file found in `AUTO_MEMORY_DIR` (`_pendientes.md`, `_session-index.md`, `_learnings.md`, `_plans-index.md`, `_research-index.md`):

1. Read both the auto-memory index and the project memory index
2. For table-based indexes: parse each table row from the auto-memory version. If an equivalent row does NOT already exist in the project index (match on primary identifier: session slug, topic name, plan name, research topic), append it
3. For `_pendientes.md`: parse each open item (`- [ ]`). If it does not already exist in the project `_pendientes.md` (match on text content), append it under the same priority section
4. Delete the auto-memory index file after merging

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
- New learning → `memory/learnings/<topic>.md`, update `memory/_learnings.md` if critical
- New pendiente → `memory/_pendientes.md` with `_origen:` link + `memory/pendientes/YYYY-MM.md`
- Executing a plan → register/update row in `memory/_plans-index.md`
- New research → `memory/research/{slug}.md` + row in `memory/_research-index.md`

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
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g')
JSONL_DIR="$HOME/.claude/projects/$ENCODED"
JSONL_COUNT=$(ls "$JSONL_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
```

Store `JSONL_COUNT` for inclusion in the report.

## Step 9: Report

```
MIGRATION COMPLETE
==================
Commands installed: /checkpoint-3t, /status-3t, /audit-3t, /backfill-3t
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
