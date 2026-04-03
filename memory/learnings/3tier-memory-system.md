---
type: learnings
created: 2026-04-02
updated: 2026-04-02
status: active
---
# 3-Tier Memory System — Learnings

## Architecture Rules

1. **Tier 1 (MEMORY.md) is an index only** — never put growing content here, only links to Tier 2. Must stay under 200 lines.
2. **Tier 2 (_index files) coordinate, don't store** — they reference Tier 3 files. Keep each under 60 lines.
3. **Tier 3 is source of truth** — full content with frontmatter in typed folders.
4. **All 5 folders are mandatory** — sessions/, pendientes/, learnings/, plans/, research/ — even if empty. A project without plans today may have one tomorrow.

## Pendientes Rules

5. **Dual-write always** — every pendiente goes to BOTH _pendientes.md (operational) AND pendientes/YYYY-MM.md (archive). No exceptions.
6. **On resolve**: remove from _pendientes.md, fill Resuelto + Sesion in monthly archive.
7. **_origen wikilink required** — every pendiente must link to its source session or plan.

## Bridge Rules (Model B)

8. **Bridge is redirect-only** — auto-memory MEMORY.md contains ONLY the bridge template. Zero inline content.
9. **Bridge uses relative paths** — `memory/...` not absolute paths. Portable across machines.
10. **Red flag**: auto-memory MEMORY.md with >20 lines of real content = broken bridge. Fix immediately.

## Session Rules

11. **Register DURING execution, not at end** — batching = forgetting items.
12. **Checkpoints, not session close** — multiple checkpoints per session are fine. Each includes git commit.
13. **Every session file must have Related section** with wikilinks to _session-index, _pendientes, _learnings.

## Plugin Distribution

14. **Plugin format is the canonical distribution** — .claude-plugin/plugin.json + skills/ + hooks/ + commands/ + bin/
15. **Skills use SKILL.md in folders** — skills/checkpoint/SKILL.md, not skills/checkpoint.md
16. **Hooks use hooks.json** — hooks/hooks.json (plugin format), not settings.local.json
17. **$CLAUDE_PLUGIN_DIR** — use this in hook commands for plugin-relative paths

## Related
- [[_learnings|Learnings Index]]
