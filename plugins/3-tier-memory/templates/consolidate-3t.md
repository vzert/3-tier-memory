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

## Step 0: Locate memory directory

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).
Read `memory/_learnings.md` and list the topic files in `memory/learnings/`.

## Step 1: Dedup — find near-duplicate learnings

Read every rule across `memory/learnings/*.md` (numbered rules) plus the Quick Reference
bullets in `memory/_learnings.md`. Identify clusters of rules that say substantially the
same thing (same mechanism, same gotcha, same constraint), even if worded differently or
living in different topic files.

For each duplicate cluster, **print a proposal** before changing anything:

```
DEDUP:
- Cluster 1: learnings/<topic>.md #N + #M say the same thing about <X>
  → propose: keep #N (clearer), fold #M's extra detail into it, remove #M
```

Apply only the merges the user approves (or all, if the user said "consolida todo").
When merging:
- Keep the clearest phrasing; preserve any unique detail from the other(s).
- Tier 3: edit the canonical rule in `learnings/<topic>.md`; remove the merged-away rule(s) and renumber if needed.
- Tier 2: update the Quick Reference in `_learnings.md` if a merged rule was listed there.

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

For approved reflections, dual-write like a normal learning:
- Tier 3: add to the relevant `learnings/<topic>.md` with `derived_from:` noted inline on the rule.
- Tier 2: add to `_learnings.md` Quick Reference if broadly critical.
- Set/refresh the topic file's `last_verified: DATE` frontmatter.

## Step 4: Refresh last_verified

For every `learnings/<topic>.md` you reviewed and confirmed still accurate this run, set its
frontmatter `last_verified: DATE` (today). Add the field if missing. This clears the staleness
flag surfaced by /audit-3t and /status-3t. Leave `importance:` untouched unless the user changes it.

## Step 5: Git commit (best-effort)

Same best-effort pattern as /checkpoint-3t Step 6:
- `command -v git && git rev-parse --is-inside-work-tree` — if it fails, skip gracefully.
- `git add memory/` then `git commit -m "consolidate: dedup + supersede + reflect — DATE"`.
- If git is unavailable or nothing staged, report the skip reason and continue. The file edits
  are the valuable part; the commit is a convenience.

The recall index rebuilds automatically on the next prompt (memory files are now newer).

## Step 6: Report

Tell the user: N duplicate clusters merged, M contradictions superseded, K reflections added,
L topic files re-verified, git result (hash or skip reason).
