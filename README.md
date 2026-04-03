# 3-Tier Memory System for Claude Code

Structured persistent memory across sessions. Never lose context, learnings, or action items again.

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

**New project** (no existing memory):
```
/3-tier-memory:setup-memory
```

**Existing project** (already has `memory/` from the playbook):
```
/3-tier-memory:migrate
```

`setup-memory` creates everything from scratch. `migrate` installs the plugin's local commands (/checkpoint, /status, /audit) without touching your existing data.

Both are the only time you use long namespaced commands. After that:

### Step 3: Day-to-day usage

```
/checkpoint
/checkpoint fix-auth-bug
```

That's it. `/checkpoint` saves your session, extracts action items, captures learnings, updates all indexes, and git commits everything.

---

## What it does

- **Session logs** — automatic session tracking with git commits
- **Action items tracking** — dual-write system (active aggregator + monthly archive)
- **Learnings** — topic-based knowledge from past mistakes, injected at session start
- **Plans & Research** — lifecycle tracking from idea to execution (when applicable)
- **Hooks** — auto-inject open action items + learnings at session start, detect unregistered files

## The 3-Tier Architecture

```
Tier 1: MEMORY.md (auto-loaded, <200 lines)
   links to
Tier 2: _index files (lean aggregators, 30-60 lines each)
   links to
Tier 3: detail files in typed folders (full content)
```

Dual-write rule: sessions, action items, and learnings ALWAYS go to both Tier 2 (index) and Tier 3 (detail file). Plans and research only when applicable.

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

## Update

```
/plugin update 3-tier-memory@3-tier-memory-marketplace
/reload-plugins
```

That's it. On the next session start:
- **Hooks** (session start injection, file registration check, pre-compact reminder) update immediately
- **`/checkpoint`** auto-syncs — the plugin compares your local version against the latest and copies if needed. You'll see "ACTUALIZADO" if it was updated.
- **`memory/` structure** is untouched — your data is yours

> **If update doesn't pull the latest version**, force refresh the marketplace:
> ```bash
> cd ~/.claude/plugins/marketplaces/3-tier-memory-marketplace && git pull
> ```
> Then `/reload-plugins` inside Claude Code.

## Uninstall

### Remove the plugin

```
/plugin uninstall 3-tier-memory@3-tier-memory-marketplace
/reload-plugins
```

### Remove the marketplace

```
/plugin marketplace remove 3-tier-memory-marketplace
```

### Clean up a project's memory (optional)

The plugin doesn't auto-delete project files. To fully remove from a project:

```bash
rm -rf memory/                          # memory directory
rm -f .claude/commands/checkpoint.md    # local /checkpoint command
```

The auto-memory bridge at `~/.claude/projects/<encoded-path>/memory/MEMORY.md` can also be deleted if no longer needed.

## Directory structure after setup

```
your-project/
├── .claude/
│   └── commands/
│       └── checkpoint.md      <- your local /checkpoint command
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

The plugin's hooks (action items + learnings injection at session start) activate after install + reload. If they don't fire, check `/doctor` for plugin errors.

## Playbook

See [playbook-3tier-memory-V2.md](./playbook-3tier-memory-V2.md) for the complete 5-phase implementation guide with templates, migration strategies, and audit checklists.

## License

MIT
