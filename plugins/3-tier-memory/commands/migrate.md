---
description: Migrate an existing 3-tier memory system (created from the playbook) to the plugin. Installs local commands, hooks, and bridge without touching your data.
---

# Migrate Existing Memory to Plugin

For projects that already have a `memory/` directory set up from the playbook. This command installs the plugin's local commands and verifies the setup WITHOUT modifying your existing memory data.

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

Install these 3 command files. If any already exist, overwrite them with the latest version:

### 2a. /checkpoint
Create `.claude/commands/checkpoint.md` with the checkpoint command content (session log, dual-write for sessions/pendientes/learnings, git commit). Use the same content as the setup-memory command's Step 6a.

### 2b. /status
Create `.claude/commands/status.md` with the status command content (read all indexes, count items, report compact summary).

### 2c. /audit
Create `.claude/commands/audit.md` with the audit command content (5 verification checklists: structure, content, bridge, wikilinks, CLAUDE.md).

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

## Step 5: Verify bridge

Determine auto-memory path: `~/.claude/projects/<encoded-project-path>/memory/MEMORY.md`

Check the bridge:
- If it doesn't exist → create it with the bridge template (redirect to memory/)
- If it exists and is a valid bridge (<40 lines, references memory/) → leave it alone
- If it exists with inline content (>40 lines or has indexes/data) → back up to .bak, replace with bridge template

## Step 6: Update CLAUDE.md

Check if CLAUDE.md has the bridge protection rule. If not, append:

```markdown
## CRITICAL: Auto-memory MEMORY.md is a BRIDGE ONLY

The file at `~/.claude/projects/<encoded-path>/memory/MEMORY.md` is a bridge that redirects to `memory/` in this project. NEVER write content, indexes, session data, learnings, or any operational data into that file. It must ONLY contain the redirect template. All memory operations go to `memory/` in the project directory. If auto-memory MEMORY.md has more than 30 lines, something is wrong — rewrite it as a bridge immediately.
```

Check if CLAUDE.md has a Memory System section. If not, append one listing the operational indexes, learnings, and /checkpoint usage.

## Step 7: Run audit

Execute the audit checklists (same as /audit):
1. Structure: 5 dirs + 6 indexes
2. Content: each index has minimum valid structure
3. Bridge: compact, redirect-only
4. Wikilinks: Related sections present
5. CLAUDE.md: has Memory System + bridge rule

## Step 8: Report

```
MIGRATION COMPLETE
==================
Commands installed: /checkpoint, /status, /audit
Directories: N created, M already existed
Indexes: N created, M already existed (not overwritten)
Bridge: created | verified | fixed (was inline, backed up)
CLAUDE.md: updated | already had all sections

AUDIT RESULTS:
<audit output from Step 7>

Next: use /checkpoint to save progress, /status for overview, /audit to verify.
```
