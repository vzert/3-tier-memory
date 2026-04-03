---
type: index
created: 2026-04-02
updated: 2026-04-02
status: active
---
# Learnings Index

Consult BEFORE making changes. Each file contains verified rules from past mistakes.

## Topic Files

| Topic | File | When to consult |
|---|---|---|
| 3-Tier Memory System | [[learnings/3tier-memory-system]] | Before modifying plugin structure, skill logic, or hook behavior |

## Quick Reference — Most Critical Rules

1. **Tier 1 never lists growing items** — only links to Tier 2 indexes
2. **Dual-write pendientes** — always write to both _pendientes.md AND pendientes/YYYY-MM.md
3. **Bridge is redirect-only** — auto-memory MEMORY.md must contain ONLY the bridge, no inline content
4. **All folders are mandatory** — sessions/, pendientes/, learnings/, plans/, research/ always exist
5. **DURING execution, not batching** — register learnings, sessions, pendientes as they happen

## Related
- [[_pendientes]]
- [[_session-index]]
