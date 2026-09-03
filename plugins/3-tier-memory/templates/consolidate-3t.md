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
`bin/journal-compact.py`). Compact FIRST, so you dedup and renumber against the real state and not
against a copy that is missing rules still sitting in `memory/.journal/pending/`:

```bash
MEMORY_DIR="memory"   # the directory located above (Model B); use the Model A path otherwise
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/journal-emit.py" ]; then
  JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
elif [ -f "plugins/3-tier-memory/bin/journal-emit.py" ]; then
  JBIN="$PWD/plugins/3-tier-memory/bin"     # the plugin's own repo: dogfood the working tree, not the cache
else
  JEMIT=$(find "$HOME/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
  JBIN=${JEMIT:+$(dirname "$JEMIT")}   # empty when find found nothing (dirname "" would give ".")
fi
[ -n "$JBIN" ] && [ -f "$JBIN/journal-compact.py" ] && echo "JBIN=$JBIN" || echo "JBIN=NONE"
```

```bash
[ "$JBIN" != NONE ] && python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

Then read `memory/_learnings.md` and list the topic files in `memory/learnings/`.

Which edits below go through the journal and which do not: **new rules** (Step 3 reflections)
are emitted as `learning.add` events. **Merges, supersede markers, renumbering and
`last_verified`** (Steps 1, 2, 4) are still direct edits, on purpose: they rewrite existing
rules after the user approves each one, and no event can express "fold rule B into A". The
window is bounded because you compacted just now and compact again in Step 4b; keep the direct
edits short (one topic file at a time, read right before you write).

## Step 0.5: Generate duplicate candidates from the recall index (pre-filter)

Do NOT scan the whole corpus by hand — that cost is proportional to corpus SIZE, not to
the number of real duplicates (on a 300+ learning corpus it means an O(n²) blind read).
Instead, let the derived recall index surface the few high-overlap PAIRS worth judging.

1. Resolve paths (same scheme as recall.sh). `MEMORY_DIR` is the directory located in Step 0 (`memory/` for Model B):
```bash
MEMORY_DIR="memory"   # Model B; use the auto-memory path if Step 0 found Model A
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
INDEX="$HOME/.claude/projects/$ENCODED/.recall-index.jsonl"
```
2. Locate the plugin scripts (mirror /backfill-3t Step 5):
```bash
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/find-dup-candidates.py" ]; then
  BIN="${CLAUDE_PLUGIN_ROOT}/bin"
else
  BIN=$(dirname "$(find "$HOME/.claude/plugins" -name "find-dup-candidates.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)")
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
  → propose: keep the clearer one, fold the other's unique detail in, remove the duplicate
```

Apply only the merges the user approves (or all, if the user said "consolida todo").
When merging:
- Keep the clearest phrasing; preserve any unique detail from the other(s).
- Tier 3: edit the canonical rule in `learnings/<topic>.md`; remove the merged-away rule(s) and renumber if needed.
- Tier 2: update the Quick Reference in `_learnings.md` if a merged rule was listed there.
- If `memory/.memory-config` contains `journal_strict=1`, the plugin's PreToolUse guard denies these
  direct edits to `_learnings.md`. Merges are the one legitimate hand edit: set `journal_strict=0`,
  do the merge, set it back to `1` (the guard reads the file on every call; nothing to restart).

## Step 2: Contradictions — supersede, don't overwrite

Scan learnings for rules that conflict (a newer decision reverses an older one, two rules
give opposing guidance). For each conflict, **print it** and resolve by supersession:

```
CONTRADICTION:
- learnings/<topic>.md #N (older) conflicts with #M (newer) about <X>
  → keep both; mark #N as superseded by #M
```

To mark a superseded rule, append an inline marker to the OLDER rule (do not delete it):
```
N. **<old rule text>** — ⊘ SUPERSEDED by [[learnings/<topic>#M]] (YYYY-MM-DD): <one-line reason>
```
The newer rule stays as-is. This preserves history (why the old belief existed) while making
the current truth unambiguous. If the older rule is in the Quick Reference, remove it from there
(Quick Reference should reflect only current truth).

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
