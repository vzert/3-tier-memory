# 3-Tier Memory System for Claude Code

Structured persistent memory across sessions. Never lose context, learnings, or pendientes again.

## Quick start

```
1. Install plugin     →  /plugin marketplace add vzert/3-tier-memory
                         /plugin install 3-tier-memory@3-tier-memory-marketplace
                         /reload-plugins

2. Setup (once)       →  /3-tier-memory:setup-memory

3. Day-to-day         →  /checkpoint
                         /checkpoint fix-auth-bug
```

After setup, you only need `/checkpoint`. The setup command installs it locally in your project — no plugin namespace required.

## What it does

- **Session logs** — automatic session tracking with git commits
- **Pendientes tracking** — dual-write system (active + monthly archive)
- **Learnings** — topic-based knowledge from past mistakes, injected at session start
- **Plans & Research** — lifecycle tracking from idea to execution (when applicable)
- **Hooks** — auto-inject open pendientes + learnings at session start, detect unregistered files

## The 3-Tier Architecture

```
Tier 1: MEMORY.md (auto-loaded, <200 lines)
   links to
Tier 2: _index files (lean aggregators, 30-60 lines each)
   links to
Tier 3: detail files in typed folders (full content)
```

Dual-write rule: sessions, pendientes, and learnings ALWAYS go to both Tier 2 (index) and Tier 3 (detail file). Plans and research only when applicable.

## Install

### Option A: Marketplace (recommended)

Run these commands inside Claude Code:

```
/plugin marketplace add vzert/3-tier-memory
/plugin install 3-tier-memory@3-tier-memory-marketplace
/reload-plugins
```

### Option B: Team setup (auto-prompt when teammates trust the repo)

Add to your project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "3-tier-memory-marketplace": {
      "source": {
        "source": "github",
        "repo": "vzert/3-tier-memory"
      }
    }
  }
}
```

Then each team member runs:
```
/plugin install 3-tier-memory@3-tier-memory-marketplace
/reload-plugins
```

### Option C: Local / testing

```bash
git clone https://github.com/vzert/3-tier-memory.git
claude --plugin-dir ./3-tier-memory/plugins/3-tier-memory
```

## Usage

### 1. Initialize memory (once per project)

```
/3-tier-memory:setup-memory
```

This is the only time you use the long namespaced command. It:
- Creates the full `memory/` directory structure with all indexes
- Creates a starter learnings file and monthly pendientes archive
- Sets up the auto-memory bridge
- Updates CLAUDE.md with memory system references
- **Installs `/checkpoint` as a local command** in `.claude/commands/`

### 2. Save checkpoints (day-to-day)

```
/checkpoint
/checkpoint fix-auth-bug
```

This is your daily command. It:
- Creates/updates the session log (`sessions/YYYY-MM-DD-slug.md`)
- Extracts pendientes from the conversation (dual-write to index + archive)
- Captures learnings (dual-write to index + topic file)
- Updates plans/research indexes if applicable
- Git commits all memory changes and records the hash

### Directory structure after setup

```
your-project/
├── .claude/
│   └── commands/
│       └── checkpoint.md      ← local /checkpoint command
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
