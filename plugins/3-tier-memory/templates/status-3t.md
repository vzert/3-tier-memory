---
description: Quick memory health overview — action items, sessions, learnings, plans, research
---

# Memory Status

Read and report the current state of the 3-tier memory system. Execute ALL steps, then present a compact summary.

## Step 1: Locate memory directory

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).
If no memory system found, tell the user to run setup-memory first and stop.

## Step 2: Gather metrics

Read each file and collect:

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
J="memory/.journal"   # Model A: "<auto-memory path>/.journal"
P=$(ls "$J/pending" 2>/dev/null | grep -c '\.json$')
Q=$(ls "$J/quarantine" 2>/dev/null | grep -c '\.json$')
A=$(ls -R "$J/applied" 2>/dev/null | grep -c '\.json$')
L="none"; if [ -d "$J/.lock" ]; then AGE=$(( $(date +%s) - $(cat "$J/.lock/acquired_at" 2>/dev/null || echo 0) )); [ "$AGE" -gt 60 ] && L="orphaned ${AGE}s" || L="held ${AGE}s"; fi
S="off"; grep -Eq '^[[:space:]]*journal_strict[[:space:]]*=[[:space:]]*1' memory/.memory-config 2>/dev/null && S="on"
echo "pending=$P quarantine=$Q applied=$A lock=$L strict=$S"
```

- `pending` > 0 means events were emitted and no compactor has run since. Normally the SessionStart and
  UserPromptSubmit hooks apply them; if the number persists, run `python3 "$JBIN/journal-compact.py" --memory-dir memory`
  (locate `JBIN` as in /checkpoint-3t Step 0).
- `quarantine` > 0 means the compactor refused events (anchor deleted by hand, id collision, malformed JSON).
  Each `.json` has a `.reason` file next to it. They are never deleted automatically: read the reason,
  apply the change by hand if it still applies, delete the pair.
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
Structure:   X/11 checks passed
```

If any structure checks failed, list what's missing. If `pending` or `quarantine` is not 0, or the
lock is orphaned, add one line under the table saying what to do (Step 2, Journal).
