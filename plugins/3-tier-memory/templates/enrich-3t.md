---
description: One-time enrichment of existing memory — backfill importance + _creado so v2.8.0 recall/decay work on legacy corpora
---

# Memory Enrichment (one-time migration)

v2.8.0 added two signals that only get written to NEWLY created files:
- `importance: 0-10` on learnings/sessions → drives recall **salience**.
- `_creado: YYYY-MM-DD` on pendientes → drives Fase C **staleness/decay**.

On a corpus created before v2.8.0 these fields are absent, so recall runs degraded
(every unit defaults to importance 5) and staleness never fires (no `_creado` → no age).
This command backfills those fields into existing files — **deterministically, idempotently,
and only after you approve a dry-run preview**. Run it once per project (re-running is a no-op).

CORE RULES:
- It MUTATES the live memory tree. It is DRY-RUN by default and writes only after you confirm.
- Idempotent: only files/lines LACKING the field are touched. Safe to re-run.
- It never reorders or edits rule/pendiente TEXT — only appends/inserts a field.
- Files without frontmatter are FLAGGED, never auto-rewritten (handle them manually).
- Archived content is skipped (`memory/archive/`, `*.bak`, `*.zip`, `*.archived.md`, `*-archived-*.md`).

## Step 0: Locate memory directory + script

If `memory/` exists in the project root, use it (Model B); else use the auto-memory path (Model A).
```bash
MEMORY_DIR="memory"   # or the Model A path if that's what you found
BIN="${CLAUDE_PLUGIN_ROOT}/bin"
if [ ! -f "$BIN/enrich-memory.py" ]; then
  # Ruta del plugin INSTALADO: la version mas alta de `installed_plugins.json`
  # (si el plugin llega por varios marketplaces, cual esta activo no se sabe).
  # `find ... | head -1` devolvia una version ARBITRARIA del
  # cache (medido 2026-09-11: 2.13.2 con 2.17.1 instalada), y un checkpoint escribia
  # los indices con scripts cuatro versiones viejos, en silencio.
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "enrich-memory.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  BIN=$_B
fi
ENRICH="$BIN/enrich-memory.py"
SEAL="$BIN/ensure-frontmatter.py"
```
If `enrich-memory.py` is not found, report: "Could not find enrich-memory.py — ensure the 3-tier-memory plugin is installed." and **stop**.

## Step 1: Dry-run preview (no writes)

Preview BOTH passes — the frontmatter seal runs FIRST (it adds missing `---` blocks), then
enrich adds `_creado:`/`importance:`. Sealing first means files that had no frontmatter at all
get a block now and then get scored by the importance pass, instead of being skipped.

```bash
python3 "$SEAL" "$MEMORY_DIR"      # frontmatter seal — files missing a block
python3 "$ENRICH" "$MEMORY_DIR"    # _creado + importance
```
Show the user both previews verbatim. The seal reports how many typed files are missing a
frontmatter block (these get a minimal `type`/`date`/`status` block). Enrich reports how many
pendientes will get `_creado:` (and how many fall back to file mtime), how many learnings/sessions
will get `importance:` (and how many substantive sessions are left neutral).

**How the values are chosen** (so you can explain it):
- `_creado:` — derived in priority order: (1) the date in the `_origen` wikilink slug, (2) the `date:` frontmatter of the file `_origen` links to, (3) `_pendientes.md` file mtime (coarse last resort; never a future date).
- `importance:` learnings — 8 if multiple strong markers (crítico/nunca/siempre/blocking…), 7 if one, else 5.
- `importance:` sessions — trivial sessions demoted (backfilled→3, no durable artifact→4); substantive sessions left NEUTRAL (no field; recall uses its default 5), because a uniform high score across substantive sessions wouldn't change ranking.

## Step 2: Approve, then apply

Ask the user to confirm. On approval, run the seal FIRST, then enrich (so newly-sealed files get scored):
```bash
python3 "$SEAL" "$MEMORY_DIR" --apply     # prepend missing frontmatter blocks
python3 "$ENRICH" "$MEMORY_DIR" --apply   # _creado + importance (now scores the sealed files too)
```
Optionally scope a single enrich job with `--only creado` or `--only importance`.

## Step 3: Rebuild the recall index

The enriched fields only take effect once the derived index is rebuilt:
```bash
# raiz-del-proyecto: RAIZ es la carpeta donde se lanzo la sesion, el primer "cwd" no de subagente
# de su JSONL, si el shell esta dentro de ella. CLAUDE_PROJECT_DIR llega vacia al Bash del agente
# y PWD cambia si el agente hizo cd. Sin id, sin JSONL, sin python3 o fuera de esa carpeta: PWD.
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
RAIZ=$(python3 -c 'import glob, json, os, sys
d, s, w = sys.argv[1:4]
def dentro(c):
    try:
        c, x = os.path.realpath(c), os.path.realpath(w)
        return os.path.commonpath([c, x]) == c
    except ValueError:
        return False
def primer_cwd(f):
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for l in fh:
                try:
                    o = json.loads(l)
                except ValueError:
                    continue
                if isinstance(o, dict) and o.get("cwd") and not o.get("isSidechain"):
                    return o["cwd"]
    except OSError:
        pass
    return None
if d == w and s:
    base = glob.escape(os.path.expanduser("~/.claude/projects"))
    hits = [(os.path.getmtime(f), primer_cwd(f)) for f in glob.glob(os.path.join(base, "*", glob.escape(s) + ".jsonl"))]
    hits = sorted(h for h in hits if h[1] and dentro(h[1]))
    if hits:
        d = hits[-1][1]
print(d)' "$PROJECT_DIR" "${CLAUDE_CODE_SESSION_ID:-}" "$PWD" 2>/dev/null) || RAIZ="$PROJECT_DIR"
[ -n "$RAIZ" ] || RAIZ="$PROJECT_DIR"
ENCODED=$(echo "$RAIZ" | sed 's/[^A-Za-z0-9]/-/g')
INDEX="$HOME/.claude/projects/$ENCODED/.recall-index.jsonl"
python3 "$(dirname "$ENRICH")/build-recall-index.py" "$MEMORY_DIR" "$INDEX" >/dev/null 2>&1
```
(It also rebuilds lazily on the next user prompt, but doing it now makes the effect immediate.)

## Step 4: Report

Tell the user: F files got a frontmatter block sealed, N pendientes got `_creado:` (M via mtime
fallback), K files got `importance:`, L substantive sessions left neutral. Note that the sealed
files only cover top-level typed files (recall units) — nested .md attachments in subfolders are
intentionally left alone. Fase C staleness will now start flagging the legacy pendientes as they
age past 30 days.
