---
description: Consolidate learnings — dedup, resolve contradictions (supersedes), and reflect sessions into higher-level rules
---

# Memory Consolidation

Periodic memory hygiene for the 3-tier system: merge duplicate learnings, surface
contradictions WITHOUT silently overwriting, and reflect recent sessions into a few
higher-level semantic rules. Inspired by Generative-Agents "reflection" and the
"don't silently overwrite — supersede" principle from temporal knowledge graphs (Zep).

Run this occasionally (e.g. when /audit-3t reports learnings needing review, or every
~10-15 sessions). It is conservative: it PROPOSES changes and asks before rewriting.

CORE RULES:
- Never delete a learning silently. Merges and supersessions are shown to the user first.
- Contradictions are resolved by `supersedes`, keeping both entries — not by overwrite.
- This command reads the whole conversation only for the reflection step; the rest is file-driven.

Throughout, **skip archived content**: ignore `memory/archive/`, and any file named
`*.bak` / `*.bak-*` / `*.zip` / `*.archived.md` / `*-archived-*.md`. Archived files are
out of scope for dedup, supersede, and reflection.

## Step 0: Locate memory directory, apply pending journal events

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).

Since v2.12.0 other agents write rules through the journal (`bin/journal-emit.py` +
`bin/journal-compact.py`). Compact FIRST, so you dedup and mark against the real state and not
against a copy that is missing rules still sitting in `memory/.journal/pending/`:

```bash
MEMORY_DIR="memory"   # the directory located above (Model B); use the Model A path otherwise
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/journal-emit.py" ]; then
  JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
elif [ -f "plugins/3-tier-memory/bin/journal-emit.py" ]; then
  JBIN="$PWD/plugins/3-tier-memory/bin"     # the plugin's own repo: dogfood the working tree, not the cache
else
  # Ruta del plugin INSTALADO: la version mas alta de `installed_plugins.json`
  # (si el plugin llega por varios marketplaces, cual esta activo no se sabe).
  # `find ... | head -1` devolvia una version ARBITRARIA del
  # cache (medido 2026-09-11: 2.13.2 con 2.17.1 instalada), y un checkpoint escribia
  # los indices con scripts cuatro versiones viejos, en silencio.
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  JEMIT=${_B:+$_B/journal-emit.py}
  JBIN=${JEMIT:+$(dirname "$JEMIT")}   # empty when find found nothing (dirname "" would give ".")
fi
[ -n "$JBIN" ] && [ -f "$JBIN/journal-compact.py" ] && echo "JBIN=$JBIN" || echo "JBIN=NONE"
```

```bash
[ "$JBIN" != NONE ] && python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

Then read `memory/_learnings.md` and list the topic files in `memory/learnings/`.

Which edits below go through the journal and which do not: **new rules** (Step 3 reflections)
are emitted as `learning.add` events, and since 2.45.0 **supersede markers** (Steps 1 and 2) are
`learning.retire` events: the compactor writes the marker on the rule's own line, keeps its number
and removes its Quick Reference line. **Folding B's detail into A and `last_verified`** (Steps 1,
4) are still direct edits, on purpose: they rewrite existing rules after the user approves each
one. The window is bounded because you compacted just now and compact again in Step 4b; keep the
direct edits short (one topic file at a time, read right before you write).

## Step 0.5: Generate duplicate candidates from the recall index (pre-filter)

Do NOT scan the whole corpus by hand — that cost is proportional to corpus SIZE, not to
the number of real duplicates (on a 300+ learning corpus it means an O(n²) blind read).
Instead, let the derived recall index surface the few high-overlap PAIRS worth judging.

1. Resolve paths (same scheme as recall.sh). `MEMORY_DIR` is the directory located in Step 0 (`memory/` for Model B):
```bash
# raiz-del-proyecto: RAIZ es la carpeta donde se lanzo la sesion: el "cwd" del JSONL de la sesion
# cuya codificacion es el nombre de la carpeta donde vive ese JSONL, si el shell esta dentro de ella.
# CLAUDE_PROJECT_DIR llega vacia al Bash del agente, PWD cambia si el agente hizo cd, y una
# variable PROJECT_DIR puede venir del perfil del usuario: no se usa. Sin id, sin JSONL, sin
# python3 o fuera de esa carpeta: PWD.
RAIZ=$(python3 -c 'import glob, json, os, re, sys
d, s, w = sys.argv[1:4]
def dentro(c):
    try:
        c, x = os.path.realpath(c), os.path.realpath(w)
        return os.path.commonpath([c, x]) == c
    except ValueError:
        return False
def cwd_del_proyecto(f):
    enc = os.path.basename(os.path.dirname(f))
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for l in fh:
                try:
                    o = json.loads(l)
                except ValueError:
                    continue
                c = o.get("cwd") if isinstance(o, dict) and not o.get("isSidechain") else None
                if isinstance(c, str) and re.sub("[^A-Za-z0-9]", "-", c) == enc and dentro(c):
                    return c
    except OSError:
        pass
    return None
if d == w and s:
    base = glob.escape(os.path.expanduser("~/.claude/projects"))
    hits = [(os.path.getmtime(f), cwd_del_proyecto(f)) for f in glob.glob(os.path.join(base, "*", glob.escape(s) + ".jsonl"))]
    hits = sorted(h for h in hits if h[1])
    if hits:
        d = hits[-1][1]
print(d)' "${CLAUDE_PROJECT_DIR:-$PWD}" "${CLAUDE_CODE_SESSION_ID:-}" "$PWD" 2>/dev/null) || RAIZ="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -n "$RAIZ" ] || RAIZ="${CLAUDE_PROJECT_DIR:-$PWD}"
MEMORY_DIR="memory"   # Model B; use the auto-memory path if Step 0 found Model A
ENCODED=$(printf '%s\n' "$RAIZ" | sed 's/[^A-Za-z0-9]/-/g')
INDEX="$HOME/.claude/projects/$ENCODED/.recall-index.jsonl"
```
2. Locate the plugin scripts (mirror /backfill-3t Step 5):
```bash
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/find-dup-candidates.py" ]; then
  BIN="${CLAUDE_PLUGIN_ROOT}/bin"
else
  # Ruta del plugin INSTALADO: la version mas alta de `installed_plugins.json`
  # (si el plugin llega por varios marketplaces, cual esta activo no se sabe).
  # `find ... | head -1` devolvia una version ARBITRARIA del
  # cache (medido 2026-09-11: 2.13.2 con 2.17.1 instalada), y un checkpoint escribia
  # los indices con scripts cuatro versiones viejos, en silencio.
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "find-dup-candidates.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  BIN=$_B
fi
```
If `find-dup-candidates.py` is not found, fall back to the legacy manual scan in Step 1 (and tell the user the pre-filter was unavailable).
3. **Rebuild the index first** (it is ~70ms and prevents dedup against a stale view):
```bash
python3 "$BIN/build-recall-index.py" "$MEMORY_DIR" "$INDEX" >/dev/null 2>&1
```
4. Run the candidate generator (tune with `DUP_JACCARD_THRESHOLD`, default 0.5 — raise to 0.6–0.7 if too noisy, lower to 0.4 if it misses known dups):
```bash
python3 "$BIN/find-dup-candidates.py" "$INDEX"
```
It prints JSON: `candidates` (strong pairs ≥ threshold) and `borderline` (top-5 just below).

**EARLY-EXIT:** if `candidates` AND `borderline` are both empty, print:
> Corpus limpio: 0 pares duplicados sobre el umbral (N unidades evaluadas). No se requiere consolidación de dedup.

…and **skip Step 1 entirely** — do NOT spawn any judging agent. Proceed to Step 2/3 only if the user asked for contradictions/reflection. This is the whole point: when there is nothing to merge, consolidation costs milliseconds, not a multi-agent fan-out.

## Step 1: Dedup — judge ONLY the candidate pairs

For each pair in `candidates` (and optionally `borderline`), the two sides give you
`path` + `texto` for each rule. **Map back to the live rule by `path` + matching its
text — never by the `id`** (the index `id` is a positional counter, unstable across
rebuilds). Re-read the rule in its `path`, read its neighbor, and judge: a high lexical
overlap is a *candidate*, not a verdict — many will be complementary rules about the same
topic, not true duplicates. Confirm true semantic duplication before proposing a merge.

When the pair is large, fan out: hand each judging agent a slice of the candidate pairs
(each pair carries both `path`s and `texto`s — enough to locate and judge without reading
the whole corpus).

For each pair you confirm is a true duplicate, **print a proposal** before changing anything:

```
DEDUP:
- learnings/<topic>.md "<texto A>" duplicates learnings/<topic>.md "<texto B>"  (jaccard 0.78)
  → propose: keep the clearer one, fold the other's unique detail in, mark the other as merged
```

Apply only the merges the user approves (or all, if the user said "consolida todo").
When merging:
- Keep the clearest phrasing; preserve any unique detail from the other(s).
- Tier 3: edit the canonical rule M in `learnings/<topic>.md`. **Never delete or renumber the
  merged-away rule(s)**: rules are cited by number ("regla 142") in session files, code and other
  rules, so its line stays with its number. Retire it through the journal:
  `journal-emit.py --type learning.retire --topic <topic> --match-prefix "<first words of N>"
  --motivo duplicada --por M --nota "merged into #M" [--quickref-prefix "<its Quick Reference line>"]`.
  The compactor appends `— ⊘ RETIRADA (YYYY-MM-DD, duplicada por #M): merged into #M` to N's line.
- Tier 2: update the Quick Reference in `_learnings.md` if the canonical rule M is listed there
  (the retired rule's line goes away with `--quickref-prefix`).
- If `memory/.memory-config` contains `journal_strict=1`, the plugin's PreToolUse guard denies
  direct edits to `_learnings.md`. A hand edit of the Quick Reference is the one legitimate case
  left: set `journal_strict=0`, do it, set it back to `1` (the guard reads the file on every call;
  nothing to restart) — or use `learning.update --quickref-prefix/--quickref` on M.

## Step 2: Contradictions — supersede, don't overwrite

Scan learnings for rules that conflict (a newer decision reverses an older one, two rules
give opposing guidance). For each conflict, **print it** and resolve by supersession:

```
CONTRADICTION:
- learnings/<topic>.md #N (older) conflicts with #M (newer) about <X>
  → keep both; mark #N as superseded by #M
```

To mark a superseded rule, retire the OLDER rule through the journal (do not delete it):
```bash
python3 "$JBIN/journal-emit.py" --type learning.retire --topic <topic> \
  --match-prefix "<first words of N>" --motivo superada --por M --nota "<one-line reason>" \
  [--quickref-prefix "<prefix of N's Quick Reference line>"]
```
The compactor appends `— ⊘ RETIRADA (YYYY-MM-DD, superada por #M): <reason>` to N's line, keeps
its number, and with `--quickref-prefix` removes N from the Quick Reference (which should reflect
only current truth). The recall index skips retired rules. The newer rule stays as-is. This
preserves history (why the old belief existed) while making the current truth unambiguous. Older
markers written by hand (`— ⊘ SUPERSEDED by [[…]]`, `— ⊘ SUPERSEDED (FECHA, …)`) count as
retired too.

## Step 3: Reflection — sessions → higher-level rules

Read the 5 most recent rows of `memory/_session-index.md` and skim those session files'
`## Cambios realizados` and `## Learnings generados`. Ask: **what higher-level pattern do
these sessions reveal that isn't yet captured as a learning?** (Generative-Agents reflection.)

Propose AT MOST 2-3 new synthesized learnings. For each, print:
```
REFLECTION:
- New rule: "<higher-level insight>"
  derived_from: [[sessions/...]], [[sessions/...]]
```

For approved reflections, emit one `learning.add` event each (the compactor numbers it under the
lock and writes both tiers):

```bash
python3 "$JBIN/journal-emit.py" --type learning.add --topic <topic-slug> \
  --text "**<higher-level insight>** — <explanation> (derived_from: [[sessions/...]], [[sessions/...]])" \
  [--quickref "**<insight>** — <short form>"]   # only if broadly critical
```

Desde 2.46.0 el emisor imprime por stderr las 8 reglas del topic mas parecidas, y se niega (sale 1,
sin escribir) si una se parece mucho y no pasas `--decision nueva` o `--decision reemplaza:N`, o
si el texto no tiene la forma `**Titulo** — cuerpo`. Lee la lista: si una regla ya dice lo mismo,
no emitas; si quedo incompleta, `learning.update`. `--solo-vecinos` muestra la lista sin escribir.

The topic file's `last_verified: DATE` is refreshed in Step 4 (direct edit).

**Fallback (no JBIN)**: append the rule with the next number to `learnings/<topic>.md` and the Quick
Reference entry to `_learnings.md` by hand (denied while `journal_strict=1`: the guard requires JBIN).

## Step 4: Refresh last_verified

For every `learnings/<topic>.md` you reviewed and confirmed still accurate this run, set its
frontmatter `last_verified: DATE` (today). Add the field if missing. This clears the staleness
flag surfaced by /audit-3t and /status-3t. Leave `importance:` untouched unless the user changes it.

## Step 4b: Compactar

```bash
[ "$JBIN" != NONE ] && python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

Applies the Step 3 reflections and anything other agents emitted while you were editing. It must
print `quarantined=0 pending_left=0`; if an event was quarantined (its anchor moved because of a
merge you just made), read `memory/.journal/quarantine/*.reason`, apply it by hand, delete the
`.json`/`.reason` pair, and report it in Step 6.

## Step 5: Git commit (best-effort)

Same best-effort pattern as /checkpoint-3t Step 6:
- `command -v git && git rev-parse --is-inside-work-tree` — if it fails, skip gracefully.
- `git add memory/` then `git commit -m "consolidate: dedup + supersede + reflect — DATE"`.
- If git is unavailable or nothing staged, report the skip reason and continue. The file edits
  are the valuable part; the commit is a convenience.

The recall index rebuilds automatically on the next prompt (memory files are now newer).

## Step 6: Report

Tell the user: N duplicate clusters merged, M contradictions superseded, K reflections added
(journal `applied=K`, or "Fallback: hand edit"), L topic files re-verified, quarantined events
if any, git result (hash or skip reason).
