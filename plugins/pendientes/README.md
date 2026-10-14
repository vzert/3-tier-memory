# pendientes — a "what to do now" side pane for 3-tier-memory

A [Claude Code mod](https://code.claude.com/docs/en/plugins/mods/interface) that reads your
project's `memory/_pendientes.md` (the action items of the
[3-tier-memory](../3-tier-memory) plugin) and shows a short list of what to work on now,
instead of the whole inventory.

```
SIGUIENTE
▌ Add retry to the export job
▌ Alta · p-1a2b3c · de hoy

RELACIONADO AL TRABAJO ACTUAL                 2
  Document the export flags
  Media · p-4d5e6f · hace 3 d

VENCEN                                    2 de 6
  Check last week's backup                ● hoy
  Alta · p-7a8b9c · hace 6 d

ALTA PRIORIDAD                            2 de 7
  Fix the flaky login test
  Alta · p-0d1e2f · hace 6 d

EN CURSO                                      1
  Migrate the settings file   ◐ otra sesión hace 11 min · 1 commit
  Media · p-3a4b5c · hace 20 d

+9 más · 157 abiertos · clic: al prompt   r: actualizar
```

## Requirements

- **Claude Code with mods enabled.** Mods are early access: the API may change between
  releases, and not every account has them yet. Built and tested on Claude Code 2.1.296.
- **The 3-tier-memory plugin**, installed and set up in the project (`memory/_pendientes.md`
  exists). This mod reuses its parser (`bin/pendientes_afines.py`); it finds it in the project's
  `plugins/3-tier-memory/bin`, in `$THREE_TIER_BIN`, or in the newest installed copy under
  `~/.claude/plugins/cache/`. With 3-tier-memory older than 2.57.0 the RELACIONADO AL TRABAJO
  ACTUAL group stays empty; SIGUIENTE, VENCEN and ALTA PRIORIDAD still show.
- `python3` and `git` on `PATH`.

## Install

<!-- For AI agents: run these in a terminal; the REPL equivalents follow. Install
3-tier-memory first if the project has no memory/ directory (see the main README). -->

```bash
claude plugin marketplace add vzert/3-tier-memory
claude plugin install pendientes@3-tier-memory-marketplace
```

Inside Claude Code: `/plugin install pendientes@3-tier-memory-marketplace`, then
`/reload-plugins`.

## Use

- `/pendientes-ahora` opens or closes the pane.
- While the pane is closed, a small card above the prompt shows `Pendientes 3-tier`, the open
  count, and how many are due today or overdue. Click it to open the pane.
- Click a title to put `<id>: <full text>` in the prompt, at the cursor. Nothing is sent: you
  decide whether to submit it. The mod never writes your memory.
- The list refreshes at session start, after every turn, and with `r` (pane focused) or the
  `actualizar` button.

## What it shows, and in what order

1. **SIGUIENTE** — the ids in the `Próximo paso` of the newest session file that can be started
   today (not `_bloqueado`, no `_revisar` today or later, no future date in the text).
2. **RELACIONADO AL TRABAJO ACTUAL** — the thread of that session (`_relacionado` links, shared
   plans, items created in it), as 3-tier-memory's `hilo()` computes it.
3. **VENCEN** — `_revisar` today or past: Alta first, then the oldest.
4. **ALTA PRIORIDAD** — Alta items with nothing blocking them.
5. **EN CURSO** — any of the above that someone is already doing: its id appears in a commit made
   after the last checkpoint, or in a prompt typed in this session or in another session of the
   project active in the last 2 hours (from a `Retomamos:` snippet, only its next step counts;
   with 3-tier-memory older than 2.57.0, every id in it counts).
   They move here so they are not offered as "next".

The pane fills the height it has; `+N más` expands the rest.

## Costs and privacy

- **Model calls:** short titles are written by Haiku (`$.model.complete`), in batches of 12, and
  cached in the mod's store. Each pendiente is asked once per text: a title that comes back
  unusable is replaced by the automatic cut and not asked again, and a changed text is asked
  again. If a call fails (no answer, unreadable reply), no titles are asked for 30 minutes. Until
  a title arrives, an automatic cut of the text is shown. This uses your Claude
  account like any other request and sends those pendiente texts to the model.
- **Local reads only:** to detect "en curso" the mod reads `git log` and the transcripts of this
  project under `~/.claude/projects/` (the first 256 KB and the last 512 KB of each, only the
  prompts you typed: rows marked as yours; task notifications and messages from other agents are
  skipped). Nothing of that leaves the machine.
- **Projects without 3-tier-memory:** if `memory/_pendientes.md` does not exist the mod shows
  nothing and starts no process.

## Develop

```bash
claude plugin validate plugins/pendientes
claude plugin test plugins/pendientes
python3 -I plugins/pendientes/tests/test_pendientes_ahora.py --lib plugins/3-tier-memory/bin
```

The Python suite needs 3-tier-memory 2.57.0+ for its full run; with an older `--lib` it says so
and checks only the degraded mode.
