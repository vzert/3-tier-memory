# 3-Tier Memory System for Claude Code

Structured persistent memory across sessions. Never lose context, learnings, or pendientes again.

## What it does

- **Session logs** — automatic session tracking with git commits
- **Pendientes tracking** — dual-write system (active + monthly archive)
- **Learnings** — topic-based knowledge from past mistakes
- **Plans & Research** — lifecycle tracking from idea to execution
- **Checkpoint skill** — one command to save everything: `/3-tier-memory:checkpoint`
- **Setup command** — initialize in any project: `/3-tier-memory:setup-memory`
- **Hooks** — auto-inject pendientes at session start, detect unregistered files

## The 3-Tier Architecture

```
Tier 1: MEMORY.md (auto-loaded, <200 lines)
   links to
Tier 2: _index files (lean aggregators, 30-60 lines each)
   links to
Tier 3: detail files in typed folders (full content)
```

- Tier 1 never lists items that grow — only links to Tier 2
- Tier 2 coordinates, doesn't store — references Tier 3
- Tier 3 is the source of truth — full content with frontmatter

## Install

### As a Claude Code Plugin (recommended)

```bash
# From a marketplace that includes this plugin
/plugin install 3-tier-memory

# Or load directly from local clone
git clone https://github.com/willhack/3-tier-memory.git
claude --plugin-dir ./3-tier-memory
```

### Manual setup

Copy the `skills/`, `hooks/`, and `bin/` directories to your project's `.claude/` directory.

## Usage

### Initialize memory in your project

```
/3-tier-memory:setup-memory
```

This creates the full directory structure, all indexes, a starter learnings file, and the auto-memory bridge.

### Save a checkpoint

```
/3-tier-memory:checkpoint
/3-tier-memory:checkpoint fix-auth-bug
```

This creates/updates the session log, extracts pendientes, updates all indexes, and commits to git.

### Directory structure after setup

```
your-project/
└── memory/
    ├── MEMORY.md              # Tier 1: lean index + checkpoint protocol
    ├── _pendientes.md         # Tier 2: open action items
    ├── _session-index.md      # Tier 2: session history
    ├── _learnings.md          # Tier 2: learnings topic index
    ├── _plans-index.md        # Tier 2: plan registry
    ├── _research-index.md     # Tier 2: research tracker
    ├── learnings/             # Tier 3: topic files
    ├── sessions/              # Tier 3: session logs
    ├── pendientes/            # Tier 3: monthly archives
    ├── plans/                 # Tier 3: plan files
    └── research/              # Tier 3: research files
```

## Playbook

See [playbook-3tier-memory-V2.md](./playbook-3tier-memory-V2.md) for the complete 5-phase implementation guide with templates, migration strategies, and audit checklists.

## License

MIT
