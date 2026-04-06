# 3-Tier Memory Plugin

Claude Code plugin that provides a structured 3-tier memory system for persistent knowledge across sessions.

## Project Structure

This project is BOTH a Claude Code plugin AND uses the memory system itself:
- **Plugin files**: `.claude-plugin/`, `plugins/3-tier-memory/` (commands, hooks, bin, templates)
- **Local memory**: `memory/` (Model B — project-local)

## CRITICAL: Auto-memory MEMORY.md is a BRIDGE ONLY

The file at `~/.claude/projects/<encoded-path>/memory/MEMORY.md` is a **bridge** that redirects to `memory/` in this project. **NEVER** write content, indexes, session data, learnings, or any operational data into that file. It must ONLY contain the redirect template. All memory operations go to `memory/` in the project directory. If auto-memory MEMORY.md has more than 30 lines, something is wrong — rewrite it as a bridge immediately.

## Memory System

This project uses project-local memory. All files live in `memory/` within the project directory.

### Operational Indexes
- `memory/_pendientes.md` — open action items (**check at session start**)
- `memory/_session-index.md` — session history
- `memory/_learnings.md` — topic-based rules (**consult before modifying plugin structure**)
- `memory/_plans-index.md` — plans registry
- `memory/_research-index.md` — research tracker

### Before modifying plugin structure, skill logic, or hook behavior
Read `memory/_learnings.md` → open the relevant topic file:
- `memory/learnings/3tier-memory-system` — architecture rules, pendientes patterns, bridge rules, distribution patterns

### Checkpoint
Use `/checkpoint-3t` to save progress. Updates session log, extracts pendientes, updates indexes, and creates a git commit.
