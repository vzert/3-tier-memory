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

Return a JSON object with results:
{
  "structure": [
    {"check": "sessions/ directory", "passed": true/false},
    ...
  ],
  "content": [
    {"check": "MEMORY.md has checkpoint protocol", "passed": true/false},
    ...
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

CHECKS:
1. Read each file in sessions/ — verify Related section contains [[_session-index]]
2. Read _pendientes.md — verify Related contains [[_session-index]] and [[_learnings]]
3. Read _learnings.md — verify Related contains [[_pendientes]] and [[_session-index]]
4. Read each file in learnings/ — verify Related contains [[_learnings]]
5. Read _plans-index.md — verify Related contains [[_pendientes]] and [[_research-index]]
6. Read _research-index.md — verify Related contains [[_plans-index]] and [[_pendientes]]

Return a JSON object:
{
  "wikilinks": [
    {"check": "Session files have [[_session-index]] in Related", "passed": true/false, "details": "N/M files OK"},
    {"check": "_pendientes.md Related links", "passed": true/false},
    ...
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
Wikilinks:   X/X passed
CLAUDE.md:   X/X passed
Hooks:       X/X passed (warning-only: orphaned entries in settings*.json)

ISSUES:
- <list each failed check with what to fix>

STATUS: ALL PASSED | N issues found
```

If any check fails, explain what's wrong and how to fix it.
