# 3-Tier Memory Plugin

Claude Code plugin that provides a structured 3-tier memory system for persistent knowledge across sessions.

## Project Structure

This project is BOTH a Claude Code plugin AND uses the memory system itself:
- **Plugin files**: `.claude-plugin/`, `skills/`, `commands/`, `hooks/`, `bin/`
- **Local memory**: `memory/` (Model B — project-local)
- **Reference docs**: `playbook-3tier-memory-V2.md`

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
Use `/3-tier-memory:checkpoint` to save progress. Updates session log, extracts pendientes, updates indexes, and creates a git commit.
