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

## Step 3: Structure check

Verify existence (not content, just existence):
- 5 directories: sessions/, pendientes/, learnings/, plans/, research/
- 6 index files: MEMORY.md, _pendientes.md, _session-index.md, _learnings.md, _plans-index.md, _research-index.md

## Step 4: Report

Present in this format:

```
MEMORY STATUS
=============
Pendientes:  N open (X alta, Y media, Z baja)
Sessions:    N total | last: YYYY-MM-DD (slug)
Learnings:   N topics, M critical rules
Plans:       N active, M completed
Research:    N active, M completed
Structure:   X/11 checks passed
```

If any structure checks failed, list what's missing.
