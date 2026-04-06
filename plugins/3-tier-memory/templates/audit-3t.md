---
description: Run verification checklists on the 3-tier memory system — structure, content, bridge, wikilinks, CLAUDE.md
---

# Memory Audit

Run ALL verification checklists below. Report results per category with pass/fail counts.

## 1. Structure audit

Verify ALL directories exist in memory/:

- [ ] sessions/
- [ ] pendientes/
- [ ] learnings/
- [ ] plans/
- [ ] research/

Verify ALL index files exist in memory/:

- [ ] MEMORY.md
- [ ] _pendientes.md
- [ ] _session-index.md
- [ ] _learnings.md
- [ ] _plans-index.md
- [ ] _research-index.md

Verify at least 1 file exists in:
- [ ] learnings/*.md (at least 1 topic file)
- [ ] pendientes/*.md (at least 1 monthly archive)

## 2. Content audit

For each index, verify minimum valid structure:

| File | Check | Pass if contains |
|---|---|---|
| MEMORY.md | Checkpoint protocol | "Checkpoint" AND "session start" |
| _pendientes.md | Priority sections | "Alta prioridad" AND "Media prioridad" AND "Baja prioridad" |
| _session-index.md | Table | "\| Fecha \|" |
| _learnings.md | Topic table | "\| Topic \|" |
| _plans-index.md | Plans table | "\| Plan \|" |
| _research-index.md | Both tables | "Active Research" AND "Completed Research" |

## 3. Bridge audit (Model B only)

Determine auto-memory path: `~/.claude/projects/<encoded-project-path>/memory/MEMORY.md`

- [ ] Bridge file exists
- [ ] Bridge is compact (<40 lines)
- [ ] Bridge references `memory/` paths
- [ ] Bridge does NOT contain inline indexes (no "## Alta prioridad", no "## Sessions" without "memory/" prefix)
- [ ] No residual .md files in auto-memory besides MEMORY.md

## 4. Wikilinks audit

Check Related sections exist with correct links:

- [ ] Each session file in sessions/ has `[[_session-index]]` in Related
- [ ] _pendientes.md has Related with `[[_session-index]]` and `[[_learnings]]`
- [ ] _learnings.md has Related with `[[_pendientes]]` and `[[_session-index]]`
- [ ] Each learnings file has Related with `[[_learnings]]`
- [ ] _plans-index.md has Related with `[[_pendientes]]` and `[[_research-index]]`
- [ ] _research-index.md has Related with `[[_plans-index]]` and `[[_pendientes]]`

## 5. CLAUDE.md audit

- [ ] CLAUDE.md exists in project root
- [ ] Has "Memory System" section
- [ ] Mentions `/checkpoint-3t`
- [ ] Has bridge protection rule ("BRIDGE ONLY" or "NEVER write")
- [ ] .gitignore includes `.claude/`

## 6. Report

Present results:

```
MEMORY AUDIT
============
Structure:   X/X passed
Content:     X/X passed
Bridge:      X/X passed (or N/A if Model A)
Wikilinks:   X/X passed
CLAUDE.md:   X/X passed

ISSUES:
- <list each failed check with what to fix>

STATUS: ALL PASSED | N issues found
```

If any check fails, explain what's wrong and how to fix it.
