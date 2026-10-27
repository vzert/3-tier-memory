---
description: Quick memory health overview — action items, sessions, learnings, plans, research
---

# Memory Status

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

Read and report the current state of the 3-tier memory system. Execute ALL steps, then present a compact summary.

## Step 1: Locate memory directory

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).
If no memory system found, tell the user to run setup-memory first and stop.

## Step 2: Gather metrics

Do NOT read the Tier 2 indexes whole (p-206fd62e68: they reach 200-460 KB). Count with `grep -c`
(e.g. `grep -c '^- \[ \]' memory/_pendientes.md`, `grep -c '_creado: ' ...`) and read only the first lines
of each file (`head`). Collect:

```bash
python3 "$JBIN/print-tier2-tamano.py" "$MEMORY_DIR"
```

It prints `<index> bytes=N lineas=L largas=K[ GRANDE]` per index. A `GRANDE` index goes in the report
(Step 4, line `Tier 2`) with the advice to trim it (`/triage-3t`; short title in Tier 2, detail in Tier 3).
If `largas` is not 0 in `_pendientes.md`, `_learnings.md` or `_research-index.md`, the advice also names
`python3 "$JBIN/migrar-tier2.py" "$MEMORY_DIR"`: a dry-run that lists each long line and where its text
would go in Tier 3. `--apply` moves it, and only runs when the user approves it. This command does not run
either one.
Locate `JBIN` as in /checkpoint-3t Step 0.

**Pendientes** (`memory/_pendientes.md`):
- Count items with `- [ ]` (open) grouped by priority section (Alta, Media, Baja)
- Count items with `- [x]` (resolved, if any still listed)
- Count open items whose `_creado: YYYY-MM-DD` is more than 30 days before today (stale candidates)
- Backlog flag: if total open exceeds 50, note it — resolution isn't keeping pace (recommend a reconciliation pass)

**Sessions** (`memory/_session-index.md`):
- Total number of sessions
- Most recent session: date, slug, status
- Date of oldest session

**Learnings** (`memory/_learnings.md`):
- Number of topic files listed
- Number of rules in Quick Reference

**Plans** (`memory/_plans-index.md`):
- Count by status: active, completed, draft, abandoned

**Research** (`memory/_research-index.md`):
- Count active research items
- Count completed research items

**Journal** (`memory/.journal/`, v2.12.0 — the event log the shared indexes are written through).
Run this exactly (do not `find`: under some shell proxies it fails silently) and report the numbers:

```bash
MEMORY_DIR="memory"
_MH=""; for _c in "${CLAUDE_PLUGIN_ROOT:-}/bin/memory-home.sh" "$PWD/plugins/3-tier-memory/bin/memory-home.sh" "$(find "$HOME/.claude/plugins" -name memory-home.sh -path '*/3-tier-memory/*' 2>/dev/null | sort -V | tail -1)"; do [ -f "$_c" ] && { _MH="$_c"; break; }; done; [ -n "$_MH" ] && _M=$(bash "$_MH" --memory-dir "$PWD") && [ "$_M" != "$PWD/memory" ] && [ -d "$_M" ] && MEMORY_DIR="$_M"   # worktree de git: la memoria del principal (2.52.0)
J="$MEMORY_DIR/.journal"   # Model A: "<auto-memory path>/.journal"
P=$(ls "$J/pending" 2>/dev/null | grep -c '\.json$')
Q=$(ls "$J/quarantine" 2>/dev/null | grep -c '\.json$')
A=$(ls -R "$J/applied" 2>/dev/null | grep -c '\.json$')
L="none"; if [ -d "$J/.lock" ]; then AT=$(cat "$J/.lock/acquired_at" 2>/dev/null); [ -n "$AT" ] || AT=$(python3 -c 'import os,sys;print(int(os.stat(sys.argv[1]).st_mtime))' "$J/.lock" 2>/dev/null || date +%s); AGE=$(( $(date +%s) - AT )); [ "$AGE" -gt 60 ] && L="orphaned ${AGE}s" || L="held ${AGE}s"; fi
S="off"; grep -Eq '^[[:space:]]*journal_strict[[:space:]]*=[[:space:]]*1' "$J/../.memory-config" 2>/dev/null && S="on"
echo "pending=$P quarantine=$Q applied=$A lock=$L strict=$S"
```

- `pending` > 0 means events were emitted and no compactor has run since. Normally the SessionStart and
  UserPromptSubmit hooks apply them; if the number persists, run `python3 "$JBIN/journal-compact.py" --memory-dir memory`
  (locate `JBIN` as in /checkpoint-3t Step 0).
- `lock`: a lock without an `acquired_at` marker is not orphaned by itself — the compactor ages it by the directory's
  mtime (the marker can be missing for an instant right after `mkdir`, or if writing it failed), which is what the snippet does.
- `quarantine` > 0 means the compactor refused events (anchor deleted by hand, id collision, malformed JSON,
  impossible date, or `error-interno:` — an event the compactor failed to apply, since 2.63.17). Each `.json` has a `.reason` file next to it. They are never deleted automatically: read the
  reason, apply the change by hand if it still applies, delete the pair. A missing priority header stopped being
  one of these causes in 2.22.0 (the compactor creates it), so whatever is here does need a person.
- `lock` orphaned (older than 60 s) means a compactor died; the next one steals it. Report it, do not delete it by hand.
- `strict` on means the PreToolUse guard denies direct `Edit`/`Write` on `_*.md` and `pendientes/YYYY-MM.md`.

## Step 3: Structure check

Verify existence (not content, just existence):
- 5 directories: sessions/, pendientes/, learnings/, plans/, research/
- 6 index files: MEMORY.md, _pendientes.md, _session-index.md, _learnings.md, _plans-index.md, _research-index.md

## Step 4: Report

Present in this format:

```
MEMORY STATUS
=============
Pendientes:  N open (X alta, Y media, Z baja) — S stale (>30d)[ ⚠ backlog if >50]
Sessions:    N total | last: YYYY-MM-DD (slug)
Learnings:   N topics, M critical rules
Plans:       N active, M completed
Research:    N active, M completed
Journal:     P pending, Q quarantine, A applied | lock: none | strict: off
Tier 2:      <index> NNN KB GRANDE (only the ones flagged; omit the line if none)
Structure:   X/11 checks passed
```

If any structure checks failed, list what's missing. If `pending` or `quarantine` is not 0, or the
lock is orphaned, add one line under the table saying what to do (Step 2, Journal).
