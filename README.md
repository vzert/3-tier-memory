# 3-Tier Memory System for Claude Code

Structured persistent memory across sessions. Never lose context, learnings, or pendientes again.

## Quick start

There are 3 steps. The first two you only do once. After that you just use `/checkpoint`.

### Step 1: Install the plugin

Run these 3 commands **inside Claude Code** (not in a regular terminal):

```
/plugin marketplace add vzert/3-tier-memory
```

Wait for it to finish, then:

```
/plugin install 3-tier-memory@3-tier-memory-marketplace
```

Then:

```
/reload-plugins
```

> **Troubleshooting**: If `/plugin install` says "not found", make sure the `/plugin marketplace add` finished successfully first. You may need to restart Claude Code after adding the marketplace.

### Step 2: Initialize memory in your project (once per project)

```
/3-tier-memory:setup-memory
```

This is the only time you use the long namespaced command. It creates:
- The full `memory/` directory structure with all indexes
- A starter learnings file and monthly pendientes archive
- The auto-memory bridge (so Claude loads your memory automatically)
- A **local `/checkpoint` command** in `.claude/commands/` so you never need the long name again

### Step 3: Day-to-day usage

```
/checkpoint
/checkpoint fix-auth-bug
```

That's it. `/checkpoint` saves your session, extracts pendientes, captures learnings, updates all indexes, and git commits everything.

---

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

## Alternative install methods

### Team setup (auto-prompt when teammates trust the repo)

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

> **Important**: `extraKnownMarketplaces` only makes the marketplace *known* — each team member still needs to run the install and reload commands from Step 1. It just skips the `marketplace add` step.

### Local / testing

```bash
git clone https://github.com/vzert/3-tier-memory.git
claude --plugin-dir ./3-tier-memory/plugins/3-tier-memory
```

This loads the plugin for that session only. Good for testing changes before pushing.

## Directory structure after setup

```
your-project/
├── .claude/
│   └── commands/
│       └── checkpoint.md      ← your local /checkpoint command
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

## Troubleshooting

### "Plugin not found" or install fails with validation error

If `/plugin install` fails or shows an old cached version, remove the marketplace and re-add it fresh:

```
/plugin marketplace remove 3-tier-memory-marketplace
/plugin marketplace add vzert/3-tier-memory
/plugin install 3-tier-memory@3-tier-memory-marketplace
/reload-plugins
```

### /checkpoint not recognized after setup

Make sure `/3-tier-memory:setup-memory` ran successfully — it creates `.claude/commands/checkpoint.md` in your project. If the file exists but the command isn't recognized, run `/reload-plugins`.

### Hooks not firing

The plugin's hooks (pendientes + learnings injection at session start) activate after install + reload. If they don't fire, check `/doctor` for plugin errors.

## Playbook

See [playbook-3tier-memory-V2.md](./playbook-3tier-memory-V2.md) for the complete 5-phase implementation guide with templates, migration strategies, and audit checklists.

## License

MIT
