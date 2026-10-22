# pendientes — a "what to do now" side pane for 3-tier-memory

A [Claude Code mod](https://code.claude.com/docs/en/plugins/mods/interface) that reads your
project's `memory/_pendientes.md` (the action items of the
[3-tier-memory](../3-tier-memory) plugin) and shows a short list of what to work on now,
instead of the whole inventory.

```
PLANES ACTIVOS                                2
↻ Add the dry-run flag to the importer   ◉ abierta
  2026-10-21 · 1 pendiente · importer-flags
↻ Measure the cache after a week        ○ cerrada 3 d
  2026-10-19 · 2 pendientes · cache-ttl

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

<!-- For AI agents: see "For AI agents installing this for a user" below. -->

```bash
claude plugin marketplace add vzert/3-tier-memory
claude plugin install pendientes@3-tier-memory-marketplace
```

Inside Claude Code: `/plugin install pendientes@3-tier-memory-marketplace`, then
`/reload-plugins`.

## For AI agents installing this for a user

If a user asks you to install this mod, follow these steps:

1. **Check the requirements.** `memory/_pendientes.md` must exist in the project. If it does not,
   install and set up 3-tier-memory first (see the main README). `python3` and `git` must be on
   `PATH`.
2. **Get the latest catalog.** If the marketplace is already added, refresh it:
   `claude plugin marketplace update 3-tier-memory-marketplace`. If it is not added, add it:
   `claude plugin marketplace add vzert/3-tier-memory`. An old catalog installs an old version.
3. **Install:** `claude plugin install pendientes@3-tier-memory-marketplace`. Then run
   `claude plugin list` and confirm that `pendientes` is listed with the version from
   `.claude-plugin/plugin.json`.
4. **Check the data, not the pane.** You cannot see the pane or the band above the prompt.
   Mods are early access, and the user's account may not have them yet. What you can check is
   that the script has data. From the project root, run:
   `python3 ~/.claude/plugins/cache/3-tier-memory-marketplace/pendientes/<version>/bin/pendientes-ahora.py --memory-dir memory`.
   The JSON must start with `"ok": true`. If it says `"ok": false`, its `error` field tells
   you what is missing.
5. **Hand over to the user.** Do not tell the user that the pane works, because you did not see
   it. Tell them that it is installed, and then give them these steps:
   - Run `/reload-plugins`, or start a new session.
   - Type `/pendientes-ahora` to open or close the pane. While it is closed, a card above the
     prompt shows the open count. Click the card to open the pane.
   - Click a pendiente to put it in the prompt with what to read. Nothing is sent until you
     submit it.
   - Press `r` (pane focused) to refresh.
   - If neither the pane nor the card appears, the account does not have mods yet.
   - Short titles use Haiku through the user's own Claude account (see Costs and privacy).

## Use

- `/pendientes-ahora` opens or closes the pane.
- While the pane is closed, a small card above the prompt shows `Pendientes 3-tier`, the open
  count, how many are due today or overdue, and how many active plans there are (`↻ N planes`).
  Click it to open the pane.
- Click a title to put `<id>: <full text>` in the prompt, at the cursor, followed by what to read
  to pick it up, like the `Retomamos` snippet of a session note:
  `Lee memory/sessions/<note>.md para el contexto.` for each file its `_origen` names that exists
  (a session note, a plan, a research file), or `Origen: <text>` when it names none, and
  `Relacionado: <ids, plans>` from its `_relacionado`. Lines without data are left out. Nothing
  is sent: you decide whether to submit it. The mod never writes your memory.
- Click an active plan (see PLANES ACTIVOS below) to paste the whole `Retomamos` snippet of its
  session note, ready to resume. An item in VENCEN that also carries `_retomar` pastes it too.
- The list refreshes at session start, after every turn, and with `r` (pane focused) or the
  `actualizar` button.

## What it shows, and in what order

0. **PLANES ACTIVOS** — one row per session note whose `Retomamos` snippet is still open: the notes
   named by `_retomar` (3-tier-memory 2.62.8+), which `/checkpoint-3t` writes on the item its
   `Próximo paso` cites, from that date until the item is closed or a later checkpoint moves the
   mark. Newest first, all of them, above everything else and outside the 7-item cap, so you can
   close a parked window and still find the plan. Each row shows the next step and, on the right,
   whether a window is still working on it: `◉ abierta` (the session that wrote the note is a live
   Claude Code process, from `~/.claude/sessions/`), `◉ retomada` (another live window of the
   project or of one of its worktrees got its next step, pasted by you or handed over by a
   supervisor in its system prompt), `◉ aquí` (this session), or `○ cerrada N d` (days since its
   last activity). Without that registry only the transcript is known, and the row
   says so: `◐ activa` (activity in the last 2 hours) or `○ sin actividad N d`. These items do not
   appear in the list below, except in VENCEN when they also have a `_revisar` today or past.
1. **SIGUIENTE** — the ids in the `Próximo paso` of the newest session file that can be started
   today (not `_bloqueado`, no `_revisar` today or later, no future date in the text).
2. **RELACIONADO AL TRABAJO ACTUAL** — the thread of that session (`_relacionado` links, shared
   plans, items created in it), as 3-tier-memory's `hilo()` computes it.
3. **VENCEN** — `_revisar` today or past: Alta first, then the oldest. Only real dates: until
   0.3.0 the `_retomar` marks showed here too, and a parked plan read like a due item. An item
   with a future `_revisar` waits.
4. **ALTA PRIORIDAD** — Alta items with nothing blocking them.
5. **EN CURSO** — any of the above that someone is already doing: its id appears in a commit made
   after the last checkpoint, or in a prompt typed in this session or in another session of the
   project active in the last 2 hours (from a `Retomamos:` snippet, only its next step counts;
   with 3-tier-memory older than 2.57.0, every id in it counts).
   They move here so they are not offered as "next".

The pane fills the height it has; `+N más` expands the rest.

**Items without `_id` do not show.** The mod picks items by id, so an open `- [ ]` line without
`_id: p-…_` cannot appear in any group, and the open count leaves it out. The pane says how many
there are (`● N sin id: /enrich-3t (no salen aquí)`), and so does the card (`● N sin id`). The
card shows even when nothing else would, so a project where no item has an id still gets it.
`/enrich-3t` in 3-tier-memory gives them an id (an indented sub-bullet may keep none). (Measured
2026-10-18: 1395 of 2987 open items in 39 local projects had no id, and in 18 projects the pane
showed `0 abiertos` with nothing else.)

## Costs and privacy

- **Model calls:** short titles are written by Haiku (`$.model.complete`), in batches of 12, and
  cached in the mod's store. Each pendiente is asked once per text: a title that comes back
  unusable is replaced by the automatic cut and not asked again, and a changed text is asked
  again. If a call fails (no answer, unreadable reply, or rejected: model blocked, invalid request), no titles are asked for 30 minutes. Until
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
