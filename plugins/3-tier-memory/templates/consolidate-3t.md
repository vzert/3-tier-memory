---
description: Consolidate learnings — dedup, resolve contradictions (supersedes), and reflect sessions into higher-level rules
---

# Memory Consolidation

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
_MH=""; for _c in "${CLAUDE_PLUGIN_ROOT:-}/bin/memory-home.sh" "$PWD/plugins/3-tier-memory/bin/memory-home.sh" "$(find "$HOME/.claude/plugins" -name memory-home.sh -path '*/3-tier-memory/*' 2>/dev/null | sort -V | tail -1)"; do [ -f "$_c" ] && { _MH="$_c"; break; }; done; [ -n "$_MH" ] && _M=$(bash "$_MH" --memory-dir "$PWD") && [ "$_M" != "$PWD/memory" ] && [ -d "$_M" ] && MEMORY_DIR="$_M"   # worktree de git: la memoria del principal (2.52.0)
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
{ [ -n "$JBIN" ] && [ -f "$JBIN/journal-compact.py" ]; } || JBIN=NONE   # dirname "" da "." sin plugin: la variable, no solo el eco
echo "JBIN=$JBIN"
```

**`JBIN=NONE`: stop here** and tell the user the plugin scripts were not found. Since 2.50.0 this
command has no hand-edit path: every change it makes is a journal event, so the result is
reproducible from `.journal/applied/`.

```bash
[ "$JBIN" != NONE ] && python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

Then read `memory/_learnings.md` and list the topic files in `memory/learnings/`.

Since 2.50.0 **every** edit below goes through the journal; none is a direct edit of
`learnings/<topic>.md` or `_learnings.md`:
- new rules (Step 3 reflections) → `learning.add`;
- the supersede marker (Steps 1, 2 and 2b) → `learning.retire`: the compactor writes the marker on
  the rule's own line, keeps its number and, with `--quickref-prefix`, removes its Quick Reference
  line;
- folding B's detail into A (Step 1) and the corrected text of an original (Step 2b) →
  `learning.update --match-prefix "<A today>" --text "<A merged>"`, which keeps A's number;
- a Quick Reference line → `learning.update --quickref-prefix "<line today>" --quickref "<new>"`;
- `last_verified` (Step 4) → `learning.update --last-verified DATE`.

So the result of a run is reproducible from `memory/.journal/applied/`, and `journal_strict=1`
never has to be switched off. Without JBIN there is no fallback: the command stops in Step 0.

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
_MH=""; for _c in "${CLAUDE_PLUGIN_ROOT:-}/bin/memory-home.sh" "$PWD/plugins/3-tier-memory/bin/memory-home.sh" "$(find "$HOME/.claude/plugins" -name memory-home.sh -path '*/3-tier-memory/*' 2>/dev/null | sort -V | tail -1)"; do [ -f "$_c" ] && { _MH="$_c"; break; }; done; [ -n "$_MH" ] && _M=$(bash "$_MH" --memory-dir "$PWD") && [ "$_M" != "$PWD/memory" ] && [ -d "$_M" ] && MEMORY_DIR="$_M"   # worktree de git: la memoria del principal (2.52.0)
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
5. Since 2.50.0, also the per-topic pairs and the corrections-by-adding (F3/F6). Jaccard over the
   keyword sets misses a duplicate written with other words; the measure of `journal-emit.py
   learning.add` (Dice weighted by IDF inside the topic, `bin/learning_vecinos.py`) catches more of
   them, and the same script lists the live rules whose TITLE says they correct another one
   ("Corrige regla N: …", "Correccion de la regla N: …", "CORREGIDO el …"):
```bash
[ "$JBIN" != NONE ] && [ -f "$JBIN/consolidate-aviso.py" ] && python3 "$JBIN/consolidate-aviso.py" --memory-dir "$MEMORY_DIR" --json
```
   `pares` (same topic, parecido ≥ 0.5, the threshold at which `learning.add` refuses without a
   `--decision`) are candidates for Step 1, like `candidates`. `h11` goes to Step 2b.
   `crecimiento` is what the session-start notice reported.

**EARLY-EXIT:** if `candidates`, `borderline`, `pares` AND `h11` are all empty, print:
> Corpus limpio: 0 pares duplicados sobre el umbral y 0 reglas que corrigen a otra (N unidades evaluadas). No se requiere consolidación de dedup.

…and **skip Steps 1 and 2b entirely** — do NOT spawn any judging agent. Still run Step 4c: a
clean corpus counts as reviewed, and without it the session-start notice never goes quiet. Proceed to Step 2/3 only if the user asked for contradictions/reflection. This is the whole point: when there is nothing to merge, consolidation costs milliseconds, not a multi-agent fan-out.

## Step 1: Dedup — judge ONLY the candidate pairs

For each pair in `candidates` and `pares` (and optionally `borderline`), the two sides give you
`path` + `texto` for each rule (a `pares` entry gives `topic#N` for each side). **Map back to
the live rule by `path` + matching its text — never by the `id`** (the index `id` is a
positional counter, unstable across rebuilds). Re-read the rule in its `path`, read its neighbor, and judge: a high lexical
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
- If N has detail M lacks, fold it into M through the journal (M keeps its number):
  ```bash
  python3 "$JBIN/journal-emit.py" --type learning.update --topic <topic> \
    --match-prefix "<first words of M today>" --text "**<M title>** — <M body + N's unique detail>"
  ```
- **Never delete or renumber the merged-away rule(s)**: rules are cited by number ("regla 142")
  in session files, code and other rules, so its line stays with its number. Retire it:
  ```bash
  python3 "$JBIN/journal-emit.py" --type learning.retire --topic <topic> \
    --match-prefix "<first words of N>" --motivo duplicada --por M --nota "merged into #M" \
    [--quickref-prefix "<its Quick Reference line>"]
  ```
  The compactor appends `— ⊘ RETIRADA (YYYY-MM-DD, duplicada por #M): merged into #M` to N's line.
- Tier 2: if the canonical rule M is in the Quick Reference and its line changes, use
  `learning.update --topic <topic> --quickref-prefix "<M's line today>" --quickref "<new line>"`
  (the retired rule's line goes away with `--quickref-prefix` on the retire). No direct edit of
  `_learnings.md`, so `journal_strict=1` stays on.

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

## Step 2b: Corrections by adding — fold the correction into the original (H11)

A rule like `218. **Corrige regla 217: …**` corrects another one by ADDING a rule: both stay live,
and the recall serves the wrong one and its correction side by side. For each entry of `h11`
(Step 0.5, item 5), read the corrector C and the original O it names, and **print a proposal**:

```
CORRECTION:
- learnings/<topic>.md #C corrects #O
  → O's text becomes: "**<O title>** — <O body as it should read now, with C's correction in>"
  → C retired: superada por #O
```

Apply only what the user approves. Two events, in this order, then compact once:
```bash
python3 "$JBIN/journal-emit.py" --type learning.update --topic <topic> \
  --match-prefix "<first words of O today>" --text "<O's corrected text>"
python3 "$JBIN/journal-emit.py" --type learning.retire --topic <topic> \
  --match-prefix "<first words of C>" --motivo superada --por O \
  --nota "correccion incorporada a #O" [--quickref-prefix "<C's Quick Reference line>"]
```
O keeps its number, so every citation of O now reads the corrected rule; C keeps its number and
its text (why the old belief existed) behind the marker. If O no longer applies at all, do not
fold: retire O as `obsoleta` instead and leave C. If the title only LOOKS like a correction (it
names a rule but does not correct it), say so and skip it — the notice reads titles, not meaning.

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
  [--disparadores "frases=<3-6 frases separadas por |>; cmd=<prefijos>; path=<globs>; tool=<herramientas>"] \
  [--quickref "**<insight>** — <short form>"]   # only if broadly critical
```

Opcional desde 2.48.0: `--disparadores "frases=a | b | c; cmd=...; path=...; tool=..."`, frases de
como describiria el momento quien NO conoce la regla. El recall las indexa, pero en la F4 no
subieron el recall de prompt al criterio: no las exijas. Detalle: Step 4 de /checkpoint-3t.

Desde 2.47.0 el emisor imprime por stderr las 8 reglas del topic mas parecidas, y se niega (sale 1,
sin escribir) si una se parece mucho y no pasas `--decision nueva` o `--decision reemplaza:N`, o
si el texto no tiene la forma `**Titulo** — cuerpo`. Lee la lista: si una regla ya dice lo mismo,
no emitas; si quedo incompleta, `learning.update`. `--solo-vecinos` muestra la lista sin escribir.

The topic file's `last_verified: DATE` is refreshed in Step 4 (a `learning.update` event).

## Step 4: Refresh last_verified

For every `learnings/<topic>.md` you reviewed and confirmed still accurate this run, refresh its
frontmatter `last_verified` through the journal (the compactor adds the field if missing, and
never moves it back to an earlier date):
```bash
python3 "$JBIN/journal-emit.py" --type learning.update --topic <topic> --last-verified "$(date +%F)"
```
This clears the staleness flag surfaced by /audit-3t and /status-3t. Leave `importance:` untouched
unless the user changes it.

## Step 4b: Compactar

```bash
[ "$JBIN" != NONE ] && python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

Applies the events of Steps 1-4 and anything other agents emitted while you were working. It must
print `quarantined=0 pending_left=0`. If an event was quarantined (an anchor moved: for example
you anchored on M's old text after updating M), read `memory/.journal/quarantine/*.reason`, emit
the event again with the anchor of today, compact, and only then delete the quarantined
`.json`/`.reason` pair. Do not apply it by hand: a hand edit is the one thing the replay from
`.journal/applied/` cannot reproduce. Report it in Step 6.

## Step 4c: Record the consolidation

Once Step 4b printed `quarantined=0`, record where each topic stands, so the session-start
notice ("CONSOLIDAR: learnings/<topic>.md crecio N reglas …") counts from here:
```bash
[ "$JBIN" != NONE ] && [ -f "$JBIN/consolidate-aviso.py" ] && python3 "$JBIN/consolidate-aviso.py" --memory-dir "$MEMORY_DIR" --guardar-estado
```
It writes `memory/.consolidate-state.json` (the highest rule number of each topic; growth is
counted by number, so retiring rules never hides it). Run it once Steps 0.5, 1 and 2b ran
(every candidate pair and every `h11` entry was judged, or Step 0.5 took the EARLY-EXIT), even if
the user declined every proposal. Do not run it if you skipped them: the notice would go quiet over a corpus nobody looked
at.

## Step 5: Git commit (best-effort)

Same best-effort pattern as /checkpoint-3t Step 6:
- `command -v git && git rev-parse --is-inside-work-tree` — if it fails, skip gracefully.
- `python3 "$JBIN/checkpoint-commit.py" --memory-dir "$MEMORY_DIR" --solo-compartidos --mensaje "consolidate: dedup + supersede + reflect — DATE"`
  (2.52.0: commitea solo lo compartido — indices, `learnings/`, `pendientes/` — con `git commit --only`;
  nunca `git add memory/`, que barre fichas y planes a medias de otras sesiones del mismo checkout).
- If git is unavailable or nothing staged, report the skip reason and continue. The file edits
  are the valuable part; the commit is a convenience.

The recall index rebuilds automatically on the next prompt (memory files are now newer).

## Step 6: Report

Tell the user: N duplicate clusters merged, M contradictions superseded, H corrections folded
into their original (Step 2b), K reflections added
(journal `applied=K`), L topic files re-verified, quarantined events
if any, whether Step 4c recorded the state, git result (hash or skip reason).
