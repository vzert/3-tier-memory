---
description: Run verification checklists on the 3-tier memory system — structure, content, bridge, wikilinks, CLAUDE.md
---

# Memory Audit

Run ALL verification checklists below. Report results per category with pass/fail counts.

## 0. Detect mode

Check if `memory/.memory-config` exists and contains `multi-dev: true`. This determines whether multi-dev checks run in section 6.

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
- [ ] Mentions `/checkpoint`
- [ ] Has bridge protection rule ("BRIDGE ONLY" or "NEVER write")
- [ ] .gitignore includes `.claude/`

## 6. Multi-dev audit (only if `.memory-config` has `multi-dev: true`)

Skip this section entirely if multi-dev is not active.

### 6a. Config check
- [ ] `memory/.memory-config` exists and is readable
- [ ] Contains `multi-dev: true`

### 6b. Session index format
- [ ] `_session-index.md` header row has `Dev` column (6 columns: Fecha | Dev | Sesion | Status | Commit | Resumen)
- [ ] At least the 5 most recent session rows have a non-empty Dev value

### 6c. Session file frontmatter
- [ ] At least the 3 most recent session files in sessions/ have `dev:` in their frontmatter

### 6d. Pendientes attribution
- [ ] At least 3 of the open `- [ ]` items in `_pendientes.md` have `_dev:` tags
  (Note: legacy items without `_dev:` are acceptable — only check recent ones)

### 6e. Plans index format
- [ ] `_plans-index.md` header row has `Dev` column (7 columns: Plan | Status | Dev | Fecha | Sesion | Pendientes | Learnings)

### 6f. MEMORY.md attribution section
- [ ] MEMORY.md contains "Developer Attribution" or "dev:" documentation

## 7. Report

Present results:

```
MEMORY AUDIT
============
Structure:   X/X passed
Content:     X/X passed
Bridge:      X/X passed (or N/A if Model A)
Wikilinks:   X/X passed
CLAUDE.md:   X/X passed
Multi-dev:   X/X passed (or N/A if single-dev)

ISSUES:
- <list each failed check with what to fix>

STATUS: ALL PASSED | N issues found
```

If any check fails, explain what's wrong and how to fix it.
