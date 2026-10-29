---
description: Move the long text already written in the Tier 2 indexes to Tier 3 — dry-run table first, your yes, then apply with a backup
---

# Tier 2 long-text migration

<!-- worktree-memoria (2.52.0) -->
**Git worktrees.** Si esta sesion corre dentro de un worktree enlazado de git, la memoria es la del
worktree PRINCIPAL del repo, no un `memory/` junto a ti (con `memory/` ignorada ni siquiera existe; con
`memory/` versionada es una copia que nadie mas lee). Corre este bloque una vez y, en TODO este
archivo, lee cada `memory/...` como `<MEMORY_DIR impreso>/...`: lecturas, Write/Edit y argumentos de
scripts. Fuera de un worktree imprime `MEMORY_DIR=memory` y nada cambia.

```bash
MEMORY_DIR="memory"
_MH=""; for _c in "${CLAUDE_PLUGIN_ROOT:-}/bin/memory-home.sh" "$PWD/plugins/3-tier-memory/bin/memory-home.sh" "$(find "$HOME/.claude/plugins" -name memory-home.sh -path '*/3-tier-memory/*' 2>/dev/null | sort -V | tail -1)"; do [ -f "$_c" ] && { _MH="$_c"; break; }; done; [ -n "$_MH" ] && _M=$(bash "$_MH" --memory-dir "$PWD") && [ "$_M" != "$PWD/memory" ] && [ -d "$_M" ] && MEMORY_DIR="$_M"   # worktree de git: la memoria del principal (2.52.0)
echo "MEMORY_DIR=$MEMORY_DIR"
```

Since 2.63.47 the plugin no longer writes long lines into `_pendientes.md`, `_learnings.md` or
`_research-index.md`, but the lines written before stay there, and the agent reads all of that
text whenever it consults the index (measured 2026-10-28: 1001 movable lines, ~1.1 MB, across 40 projects of one
machine). `migrar-tier2.py` moves each line of more than 800 characters to Tier 3 — the monthly row
of the pendiente, or the topic/research file the line already points to — and leaves a short title
in Tier 2. Ids do not change. The session start says, in one line (`MIGRAR-TIER2: ...`), when there is
something to move.

CORE RULES:
- Nothing is written before the user says yes to the dry-run table (Step 2): Steps 0-1 only read.
  Even the journal compaction (which applies pending events and refreshes `.journal/fingerprints.json`)
  waits for Step 3.
- The script writes Tier 3 first, checks it, and only then shortens Tier 2; it copies every file it
  may touch to `.journal/migrar-tier2/<date-time>/` before the first write. Do not edit the indexes
  by hand around it.
- A `no-migrable` line is reported, never forced. Its reason says what would unlock it.

## Step 0: Locate memory directory and scripts

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).

```bash
MEMORY_DIR="memory"   # the directory located above (Model B); use the Model A path otherwise
_MH=""; for _c in "${CLAUDE_PLUGIN_ROOT:-}/bin/memory-home.sh" "$PWD/plugins/3-tier-memory/bin/memory-home.sh" "$(find "$HOME/.claude/plugins" -name memory-home.sh -path '*/3-tier-memory/*' 2>/dev/null | sort -V | tail -1)"; do [ -f "$_c" ] && { _MH="$_c"; break; }; done; [ -n "$_MH" ] && _M=$(bash "$_MH" --memory-dir "$PWD") && [ "$_M" != "$PWD/memory" ] && [ -d "$_M" ] && MEMORY_DIR="$_M"   # worktree de git: la memoria del principal (2.52.0)
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/migrar-tier2.py" ]; then
  JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
elif [ -f "plugins/3-tier-memory/bin/migrar-tier2.py" ]; then
  JBIN="$PWD/plugins/3-tier-memory/bin"     # the plugin's own repo: dogfood the working tree, not the cache
else
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "migrar-tier2.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  JBIN=${_B}
fi
{ [ -n "$JBIN" ] && [ -f "$JBIN/migrar-tier2.py" ] && [ -f "$JBIN/journal-compact.py" ]; } || JBIN=NONE
echo "JBIN=$JBIN"
ls "$MEMORY_DIR/.journal/pending" 2>/dev/null | grep -c '\.json$'
```

**`JBIN=NONE`: stop** and tell the user the plugin scripts (2.68.0 or later) were not found.
The last number is how many journal events wait to be compacted. With more than 0, the dry-run below
does not show them yet (they are new, short lines since 2.63.47); Step 3 compacts them first, because
the script refuses to apply with events still pending.

## Step 1: Dry-run

```bash
python3 "$JBIN/migrar-tier2.py" "$MEMORY_DIR" > "${TMPDIR:-/tmp}/migrar-tier2-dry.txt"; echo "rc=$?"
tail -1 "${TMPDIR:-/tmp}/migrar-tier2-dry.txt"
grep -c ' mueve' "${TMPDIR:-/tmp}/migrar-tier2-dry.txt"
grep -c ' acorta' "${TMPDIR:-/tmp}/migrar-tier2-dry.txt"
grep ' no-migrable:' "${TMPDIR:-/tmp}/migrar-tier2-dry.txt" | sed 's/^[^ ]* no-migrable: //; s/ ->.*//' | sort | uniq -c | sort -rn
```

Each line reads `<index>:<line> <state> -> <destination> | <proposed title>`. The last line is
`candidatos=N migrables=M no_migrables=K`. With `migrables=0`, tell the user there is nothing to move
(and why the remaining lines are not movable) and stop.

## Step 2: Table and the user's yes

Show the user one table, per index: lines that move to Tier 3 (`mueve`), lines whose text Tier 3
already has (`acorta`), and `no-migrable` lines grouped by reason, plus 3 sample rows with their
proposed title so they see what Tier 2 keeps. Then ask once with `AskUserQuestion`:

- **Apply (Recommended)** — move the M lines; backup in `.journal/migrar-tier2/`.
- **Not now** — write nothing.

Only on Apply go on. On "Not now", stop: the session-start line will keep reminding them.

## Step 3: Apply

```bash
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
python3 "$JBIN/migrar-tier2.py" "$MEMORY_DIR" --apply; echo "rc=$?"
python3 "$JBIN/migrar-tier2.py" "$MEMORY_DIR" | tail -1
python3 "$JBIN/migrar-tier2.py" "$MEMORY_DIR" --aviso
```

The apply's last line is `candidatos=N migrables=M no_migrables=K aplicados=A errores=E respaldo=<dir>`.
`rc=1` and no summary line: read stderr (lock busy or events still pending: compact again and retry).
`rc=1` with errors: each failed line was left as it was (stderr says why); report them. The second
dry-run must say `migrables=0`; if not, report what is left. The `--aviso` line is what the next
session start will show: empty means the reminder is gone.

**To undo**: the backup folder holds every touched file as `<name>.pre-migrar`, with its path under
`memory/`. Copy them back over the originals, then run
`python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR" --reseal`.

## Step 4: Git commit (best-effort)

Same best-effort pattern as /checkpoint-3t Step 6 (solo lo compartido, nunca `git add memory/`):
`python3 "$JBIN/checkpoint-commit.py" --memory-dir "$MEMORY_DIR" --solo-compartidos --mensaje "migrar-tier2: texto largo de Tier 2 a Tier 3 — DATE"`.
Its last line says `COMMIT hash=...` or `COMMIT skip=<reason>`; report the skip reason.

Tell the user: lines moved, lines only shortened, errors, what is left and why (each `no-migrable`
reason: `sin _id` → `journal-emit.py --type pendiente.adopt`; `no tiene tabla` →
`repair-dualwrite.py`; no target file → the line points to no topic or research file), and where the
backup is.
