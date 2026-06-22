---
description: Run verification checklists on the 3-tier memory system — structure, content, bridge, wikilinks, CLAUDE.md
---

# Memory Audit

Run ALL verification checklists using parallel Haiku subagents, then compile results into a single report.

## Step 0: Determine paths

- `MEMORY_DIR`: `$CLAUDE_PROJECT_DIR/memory` (Model B) or auto-memory path (Model A)
- `ENCODED_PATH`: `echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g'`
- `AUTO_MEMORY`: `$HOME/.claude/projects/$ENCODED_PATH/memory/MEMORY.md`

## Step 1: Launch parallel verification agents

Launch ALL 3 agents in a **single message** for parallel execution:

### Agent A: Structure + Content

```
Agent(subagent_type: "Explore", model: "haiku", description: "Audit structure + content")
```

Prompt:
```
Verify the 3-tier memory system structure and content at: <MEMORY_DIR>

STRUCTURE CHECKS — verify each exists:
Directories: sessions/, pendientes/, learnings/, plans/, research/
Index files: MEMORY.md, _pendientes.md, _session-index.md, _learnings.md, _plans-index.md, _research-index.md
At least 1 file in: learnings/*.md, pendientes/*.md

CONTENT CHECKS — read each index and verify it contains required markers:
| File | Required content |
|---|---|
| MEMORY.md | "Checkpoint" AND "session start" |
| _pendientes.md | "Alta prioridad" AND "Media prioridad" AND "Baja prioridad" |
| _session-index.md | "| Fecha |" |
| _learnings.md | "| Topic |" |
| _plans-index.md | "| Plan |" |
| _research-index.md | "Active Research" AND "Completed Research" |

STALENESS CHECKS (warning-only — these never fail the audit, they surface decay):
1. In _pendientes.md, count open `- [ ]` items whose `_creado: YYYY-MM-DD` is more than 30 days before today. These are stale candidates for reconciliation (/checkpoint-3t Step 3a).
2. In each learnings/*.md, read frontmatter `last_verified:` (if present). Flag any file whose last_verified is more than 180 days before today (or has no last_verified at all) as "needs review". Suggest running /consolidate-3t.
3. Recall index: check whether `$HOME/.claude/projects/<ENCODED_PATH>/.recall-index.jsonl` exists. If absent, note it will build lazily on the next prompt (not an error).

SCALE CHECKS (warning-only — Tier 2 should COORDINATE, not STORE; design budget is "<60 lines"):
4. For each index file (MEMORY.md and the _*.md indexes), measure size with: `wc -l <file>` and `wc -c <file>`. Compute avg chars/line = bytes ÷ lines. Flag an index as OVER BUDGET if it exceeds ANY of: 60 data lines, 120 avg chars/line, or 40000 bytes. An over-budget index is storing content instead of coordinating — recommend sharding it into family sub-indexes (e.g. `_learnings/<family>.md`) and trimming rows to one-line pointers.
5. Pendientes backlog: count ALL open `- [ ]` items in _pendientes.md. If more than 50, flag a backlog warning — resolution isn't keeping pace; recommend a reconciliation pass (/checkpoint-3t Step 3a) and/or archiving resolved-but-unmarked items.
6. Frontmatter integrity: count top-level typed Tier-3 files (sessions/, learnings/, plans/, research/, reference/) missing a leading `---` frontmatter block. Locate and run `ensure-frontmatter.py` in count mode if available (`if [ -n "$CLAUDE_PLUGIN_ROOT" ]...` else `find "$HOME/.claude/plugins" -name ensure-frontmatter.py -path "*/3-tier-memory/*"`), e.g. `python3 <script> <MEMORY_DIR> --count`. If N>0, flag it — those files run degraded (recall default 5, no type/date). Recommend /enrich-3t (which repairs them) or a /checkpoint-3t (Step 5c seals them).

Skip archived content everywhere: ignore `memory/archive/`, `*.bak`, `*.zip`, `*.archived.md`, `*-archived-*.md`.

Return a JSON object with results:
{
  "structure": [
    {"check": "sessions/ directory", "passed": true/false},
    ...
  ],
  "content": [
    {"check": "MEMORY.md has checkpoint protocol", "passed": true/false},
    ...
  ],
  "staleness": [
    {"check": "Stale pendientes (>30d)", "count": N, "details": "list of stale item texts"},
    {"check": "Learnings needing review (>180d or no last_verified)", "count": N, "details": "list of file names"},
    {"check": "Recall index present", "passed": true/false}
  ],
  "scale": [
    {"check": "Index budget (<60 lines / <120 chars-per-line / <40KB)", "over_budget": ["_learnings.md (536 lines, 443 chars/line)", ...]},
    {"check": "Pendientes backlog (>50 open)", "count": N, "over": true/false},
    {"check": "Files missing frontmatter", "count": N}
  ]
}
```

### Agent B: Bridge + CLAUDE.md

```
Agent(subagent_type: "Explore", model: "haiku", description: "Audit bridge + CLAUDE.md")
```

Prompt:
```
Verify the auto-memory bridge and CLAUDE.md configuration.

BRIDGE CHECKS:
1. Read: <AUTO_MEMORY path>
2. Check: file exists
3. Check: compact (< 40 lines)
4. Check: references "memory/" paths
5. Check: does NOT contain inline indexes (no "## Alta prioridad", no "## Sessions" without "memory/" prefix)
6. Check: no other .md files exist in the auto-memory directory besides MEMORY.md

CLAUDE.MD CHECKS:
1. Read: <$CLAUDE_PROJECT_DIR>/CLAUDE.md
2. Check: file exists
3. Check: has "Memory System" section
4. Check: mentions "/checkpoint-3t"
5. Check: has bridge protection rule ("BRIDGE ONLY" or "NEVER write")
6. Read: <$CLAUDE_PROJECT_DIR>/.gitignore — check it includes ".claude/"

HOOK HYGIENE CHECKS (warning-only):
For each of <$CLAUDE_PROJECT_DIR>/.claude/settings.json and <$CLAUDE_PROJECT_DIR>/.claude/settings.local.json that exists:
1. Parse as JSON. If invalid or no `hooks` key, skip.
2. For every nested hook `command` under hooks.SessionStart|PostToolUse|PreCompact|SessionEnd|UserPromptSubmit, flag it as a potential orphan if it:
   - References one of: session-start.sh, session-end.sh, pre-compact.sh, post-tool-use.sh, check-index-registration.sh
   - AND uses "$CLAUDE_PROJECT_DIR/.claude/hooks/" or contains "plugins/3-tier-memory/" without "${CLAUDE_PLUGIN_ROOT}"
3. For each flagged command, expand $CLAUDE_PROJECT_DIR and check if the target script exists on disk.
4. Report result (do NOT auto-fix — /audit-3t is read-only): "No orphaned hook entries" OR list each flagged entry with file/path/event and whether the target exists. Suggest running /migrate to clean up.

Return a JSON object:
{
  "bridge": [
    {"check": "Bridge file exists", "passed": true/false},
    ...
  ],
  "claude_md": [
    {"check": "CLAUDE.md exists", "passed": true/false},
    ...
  ],
  "hooks": [
    {"check": "No orphaned hook entries in settings*.json", "passed": true/false, "details": "list of flagged entries with file+event+target+exists flag"}
  ]
}
```

### Agent C: Wikilinks

```
Agent(subagent_type: "Explore", model: "haiku", description: "Audit wikilinks")
```

Prompt:
```
Verify wikilink cross-references in the memory system at: <MEMORY_DIR>

PART 1 — BROKEN LINKS (run the deterministic checker; do NOT read links by hand):
Locate and run check-wikilinks.py — it extracts every [[target]] and reports those whose
target file doesn't exist (scales to hundreds of links; archived files are skipped):
  if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/check-wikilinks.py" ]; then
    CHK="${CLAUDE_PLUGIN_ROOT}/bin/check-wikilinks.py"
  else
    CHK=$(find "$HOME/.claude/plugins" -name "check-wikilinks.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
  fi
  python3 "$CHK" "<MEMORY_DIR>"
Report the SUMMARY line (broken_links=N) and up to ~15 sample BROKEN lines. This is
warning-only — broken links surface link rot for the user to fix, they don't fail the audit.

PART 2 — PRESENCE (structural Related links still expected):
1. Spot-check a few files in sessions/ — Related section contains [[_session-index]]
2. _pendientes.md — Related contains [[_session-index]] and [[_learnings]]
3. _learnings.md — Related contains [[_pendientes]] and [[_session-index]]
4. _plans-index.md and _research-index.md cross-link each other and [[_pendientes]]

Return a JSON object:
{
  "wikilinks": [
    {"check": "Broken wikilinks", "count": N, "samples": ["source -> [[target]]", ...]},
    {"check": "Structural Related links present", "passed": true/false, "details": "..."}
  ]
}
```

## Step 2: Compile report

Receive results from all 3 agents. Count passes and failures per category. Present:

```
MEMORY AUDIT
============
Structure:   X/X passed
Content:     X/X passed
Bridge:      X/X passed (or N/A if Model A)
Wikilinks:   structural X/X passed — N broken links (warning)
CLAUDE.md:   X/X passed
Hooks:       X/X passed (warning-only: orphaned entries in settings*.json)
Staleness:   N stale pendientes (>30d), M learnings need review — recall index: present/lazy
Scale:       N indexes over budget, P open pendientes (backlog if >50), F files missing frontmatter

ISSUES:
- <list each failed check with what to fix>

WARNINGS (do not change STATUS):
- <over-budget indexes → recommend sharding into family sub-indexes>
- <broken wikilinks → sample + suggest fixing/removing dead refs>
- <pendientes backlog → recommend reconciliation pass>

STATUS: ALL PASSED | N issues found
```

Staleness, scale, and broken-link items are warnings, not failures — they never change STATUS. Surface them so the user can run /checkpoint-3t (pendientes), /consolidate-3t (learnings), or /enrich-3t (backfill importance/_creado on a legacy corpus).

If any check fails, explain what's wrong and how to fix it.
