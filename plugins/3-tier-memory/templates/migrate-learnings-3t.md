---
description: Migrate an existing learnings corpus — link each Quick Reference line to its rule and add triggers (disparadores), with your approval
---

# Learnings migration (F7 of the learnings lifecycle)

Since 2.45-2.50 the plugin can retire rules, dedup on write, attach trigger phrases
(`<!-- disparadores: ... -->`) and warn when it is time to consolidate. A corpus written before
that has none of it: Quick Reference lines are short versions of rules with different words (in
the plugin's own corpus only 11 of 162 shared the title of their rule), and no rule carries
trigger phrases. This command brings an existing corpus to the state the plugin reached by hand
in its own repo:

1. no rule that "corrects" another one still live (H11) and no strong duplicate pair undecided —
   that is `/consolidate-3t`'s job, this command checks it first;
2. every Quick Reference line linked to its rule with `<!-- regla: <topic>#<N> -->` (written once;
   new lines get it automatically from `learning.add --quickref` since 2.51.0);
3. at least 90 % of the linked rules with trigger phrases.

CORE RULES:
- Every change goes through the journal (`journal-emit.py` + `journal-compact.py`). No hand edit of
  `learnings/<topic>.md` or `_learnings.md`.
- A link is applied only when two independent signals agree (the lexical candidate 1 and a judge
  agent) or **the user** decided it. A retirement or merge is never decided here.
- Trigger phrases change no rule's meaning, so they are applied without per-rule approval — but
  only for the Quick Reference rules by default. More levels only if the user asks (Step 4).
- **What this command cannot measure.** Adding trigger phrases can push one rule out of the top 4
  of the recall for a prompt where it used to appear (measured in the plugin's repo: enriching
  every rule lost 2 of 14 recall cases and gained 2 others). The plugin's recall bench lives in the plugin repo, not in your
  install, so this command cannot detect that here. Say so in the report.

## Step 0: Locate memory directory and scripts, compact

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).

```bash
MEMORY_DIR="memory"   # the directory located above (Model B); use the Model A path otherwise
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/learnings-migracion.py" ]; then
  JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
elif [ -f "plugins/3-tier-memory/bin/learnings-migracion.py" ]; then
  JBIN="$PWD/plugins/3-tier-memory/bin"     # the plugin's own repo: dogfood the working tree, not the cache
else
  _R=$(find "$HOME/.claude/plugins" -name resolve-plugin-bin.sh -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
  _B=$([ -n "$_R" ] && bash "$_R" 2>/dev/null)
  [ -n "$_B" ] || _B=$(dirname "$(find "$HOME/.claude/plugins" -name "learnings-migracion.py" -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)")
  JBIN=${_B}
fi
{ [ -n "$JBIN" ] && [ -f "$JBIN/learnings-migracion.py" ] && [ -f "$JBIN/journal-compact.py" ]; } || JBIN=NONE
echo "JBIN=$JBIN"
[ "$JBIN" != NONE ] && python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

**`JBIN=NONE`: stop** and tell the user the plugin scripts (2.51.0 or later) were not found.

Work files go in a scratch directory outside `memory/` (never commit them):
```bash
W=$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/migrate-learnings-$$"); mkdir -p "$W"; echo "W=$W"
```
Each bash block below defines what it uses: the shell does not keep variables between calls, so
repeat `MEMORY_DIR`, `JBIN` and `W` with the values printed here.

## Step 1: Where the corpus stands

```bash
python3 "$JBIN/learnings-migracion.py" --memory-dir "$MEMORY_DIR" --estado > "$W/estado-antes.json"
python3 -c "import json,sys;e=json.load(open(sys.argv[1]));print(json.dumps({k:(len(v) if isinstance(v,list) else v) for k,v in e.items() if k!='c3'},ensure_ascii=False));print(json.dumps(e['c3'],ensure_ascii=False)[:600])" "$W/estado-antes.json"
```

Show the user, in plain words: how many Quick Reference lines, how many already linked, how many
the journal **cannot** link (`sin_enlace_bloqueadas`: a code block or HTML comment earlier in
`_learnings.md`, or a multi-line item — the journal only rewrites a line when markdown allows no
other reading; fixing that layout is a manual edit the user decides), `numeros_repetidos` (rules
whose number appears twice in a topic: they can only be linked to the topic, not to `topic#N`),
and the three criteria.

## Step 2: H11 and strong pairs come first

If `c1_h11` or `c2_pares` is not empty, tell the user and **stop**: run `/consolidate-3t` first
(Steps 1 and 2b there decide merges and corrections with the user's approval, and note it on each
retirement). Then run this command again. If `/consolidate-3t` already ran and the user **decided
to keep** the remaining pairs, ask once with `AskUserQuestion` — "These N pairs are above the
duplicate threshold. Were they reviewed and kept on purpose?" — and continue only on yes. Do not
judge pairs here.

## Step 3: Link each Quick Reference line to its rule

```bash
python3 "$JBIN/learnings-migracion.py" --memory-dir "$MEMORY_DIR" --candidatos > "$W/candidatos.jsonl"
wc -l < "$W/candidatos.jsonl"
```

Each row is one unlinked line: `qr`, `linea`, `prefijo` (its anchor) and `candidatas` — the 6 live
rules of ALL topics that look most like it (`regla` is `<topic>#<N>`, or `<topic>` for a topic
of bullets or a repeated number). Measured: the right rule was candidate 1 in 156 of 161 lines in
one corpus and 18 of 21 in another; it was among the 6 in 160/161 and 21/21. So candidate 1 alone
is not enough, and sometimes the right rule is not in the list.

**Judge.** Split `candidatos.jsonl` in files of 25 rows and spawn one subagent per file, in
parallel, with this brief (fill the paths):

> Read-only except your output file. For each row of `<file>`: the `linea` is a short version of
> ONE rule of `<MEMORY_DIR>/learnings/*.md`. Pick the rule that carries the same lesson — judge
> by meaning, titles often differ. Start with `candidatas`; if none fits, search the topic files
> yourself. Never pick a line marked `⊘ RETIRADA` or `⊘ SUPERSEDED`. Write `<out>` as JSONL, one
> row per input row: `{"qr": .., "prefijo": "<copied>", "regla": "<topic>#<N>" | "<topic>" |
> "ninguna", "confianza": "alta|media|baja", "motivo": "<short>"}`. Use `<topic>` only when the
> rule is a bullet (no number) or its number is repeated in its topic. Reply with the output path
> and how many rows you wrote.

**Decide.** Join the judges' outputs. A row is **agreed** when the judge's `regla` equals
candidate 1 and `confianza` is `alta`. Every other row (the judge picked another candidate, a
rule outside the list, `ninguna`, or low confidence) goes to the user: show them as a table
(line, judge's pick with its rule title, candidate 1, reason) and ask with `AskUserQuestion`:
approve the judge's picks for all of them (recommended), or review them one by one (then ask in
batches of up to 4). `ninguna` is a real answer: the line stays, linked to nothing, and stops
being reported.

Write the decided rows (agreed + user-approved) as JSONL `{"prefijo": .., "regla": ..}` to
`$W/enlaces.jsonl` and apply them:
```bash
python3 "$JBIN/learnings-migracion.py" --memory-dir "$MEMORY_DIR" --aplicar-enlaces "$W/enlaces.jsonl"
```
It emits one `learning.update --quickref-regla` per row and compacts. Exit 1 lists the rejected
rows with the emitter's reason: show them, never retry them silently.

## Step 4: Trigger phrases

```bash
python3 "$JBIN/learnings-migracion.py" --memory-dir "$MEMORY_DIR" --lote --nivel 1 --tam 0 > "$W/lote.jsonl"
wc -l < "$W/lote.jsonl"
```

Level 1 = rules linked from the Quick Reference, without trigger phrases, that the journal can
rewrite. That is the default and what the 90 % criterion counts. Levels 2-4 (rules cited as
`topic#N` in session files of the last 30 days; rules naming a command or a path; the rest) only
if the user asks for them — explain the cost first (one writer per 25 rules) and the limit above
(no bench here). With more than 1000 rules in the batch, ask before spending the tokens.

Find the writer's guide and split the batch:
```bash
GUIA="$JBIN/../templates/guia-disparadores.md"
[ -f "$GUIA" ] || GUIA=$(find "$HOME/.claude/plugins" -name guia-disparadores.md -path "*/3-tier-memory/*" 2>/dev/null | sort -V | tail -1)
echo "GUIA=$GUIA"
split -l 25 "$W/lote.jsonl" "$W/lote-"; ls "$W"/lote-*
```

Spawn one writer subagent per `lote-*` file, in parallel: "Read `<GUIA>` and follow it. Your batch
is `<lote file>`; write your output to `<lote file>.out.jsonl`." Then:
```bash
cat "$W"/lote-*.out.jsonl > "$W/escritor.jsonl"
python3 "$JBIN/learnings-migracion.py" --memory-dir "$MEMORY_DIR" --aplicar-disparadores "$W/escritor.jsonl"
```
It validates every row, says which rules the journal cannot rewrite (and why) without emitting
them, applies the rest in batches of 25 and compacts before and after each batch. Exit 1 lists
rejected rows: if a row has a format problem (`--`, `<`, `>`, wrong number of phrases), ask that
writer to fix only those rows and apply them again.

## Step 5: Report and leftovers

```bash
python3 "$JBIN/learnings-migracion.py" --memory-dir "$MEMORY_DIR" --estado > "$W/estado-despues.json"
python3 -c "import json,sys;e=json.load(open(sys.argv[1]));print(e['criterios']);print(json.dumps(e['c3'],ensure_ascii=False))" "$W/estado-despues.json"
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR" --check-drift; echo "drift rc=$?"
```

If linked rules are still without trigger phrases and the journal could rewrite them, ask the user
(`AskUserQuestion`) whether to leave them so on purpose. Only on yes:
```bash
python3 "$JBIN/learnings-migracion.py" --memory-dir "$MEMORY_DIR" --decidir <topic#N> [<topic#N> ...]
```
That writes `memory/.migracion-learnings.json`; the session-start notice stops counting them.

## Step 6: Git commit (best-effort)

Same best-effort pattern as /checkpoint-3t Step 6: if `git` works here, `git add memory/` and
`git commit -m "migrate-learnings: links + disparadores — DATE"`; otherwise report the skip
reason. The recall index rebuilds itself on the next prompt.

Tell the user: lines linked (agreed by judge and candidate / decided by the user / `ninguna`),
lines the journal cannot link and why, rules enriched, rules rejected and why, the three criteria
before and after, `drift rc`, and the limit: this install has no recall bench, so a recall
regression caused by the new phrases cannot be measured here.
