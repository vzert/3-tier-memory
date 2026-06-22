---
description: Save a learning/rule to memory (lightweight, for Paperclip agents)
---

# Save Learning

Guarda un learning o regla crítica en el sistema de memoria, sin hacer checkpoint completo.

**Uso**: Cuando descubras un patrón nuevo, regla de negocio, gotcha técnico, o corrección a un learning existente.

**NO** escribe sesiones, pendientes, plans, ni research. Eso es para CLI con `/checkpoint-3t`.

## Step 1: Locate memory directory

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).
Read `memory/MEMORY.md` to confirm the system is initialized.

## Step 2: Review for learnings

Scan the current conversation for:
- New patterns discovered in data or behavior
- Business rules or constraints
- Technical gotchas or bugs
- Corrections to existing learnings
- Best practices or anti-patterns

If no learnings found, exit with "No new learnings to save."

## Step 3: Learnings — DUAL WRITE

For each learning:

**Tier 3**: Add to the relevant `memory/learnings/<topic>.md` file.
- If the topic file doesn't exist, create it with frontmatter:
  ```markdown
  ---
  type: learning
  topic: <topic-name>
  ---
  # <Topic Title>
  
  ## Rules
  
  - **<Rule name>**: <description>
  ```
- If the file exists, append the new rule to the ## Rules section

**Tier 2**: Update `memory/_learnings.md`:
- If new topic file created, add a row to the Topics table
- If the learning is critical (affects correctness/safety), add it to the ## Quick Reference section

## Step 3b: Seal frontmatter (deterministic guarantee)

Don't trust the write above to have a frontmatter block — enforce it. Run the seal script:
it prepends a minimal `---` block to any learning file missing one (no-op if you wrote it
right). Idempotent, atomic, never touches the body.

```bash
MEMORY_DIR="memory"   # or the Model A path from Step 1
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py" ]; then
  SEAL="${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py"
else
  SEAL=$(find "$HOME/.claude/plugins" -name "ensure-frontmatter.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
fi
[ -n "$SEAL" ] && python3 "$SEAL" "$MEMORY_DIR" --apply
```

## Step 4: Git commit (best-effort)

If git is available and there are changes:
```bash
git add memory/learnings/ memory/_learnings.md
git commit -m "learning: <brief-description>"
```

If git fails or is not available, continue anyway.

## Step 5: Report

Output a brief summary:
```
Learning saved: <topic>
- <brief description of what was learned>
- File: memory/learnings/<topic>.md
- Commit: <hash> (or "no git commit")
```

## Example

User discovers that PostHog has a bug with UTM parameters:

1. Read `memory/_learnings.md` to see existing topics
2. Determine this is a new learning for topic "posthog-utm-bug"
3. Create `memory/learnings/posthog-utm-bug.md`:
   ```markdown
   ---
   type: learning
   topic: posthog-utm-bug
   ---
   # PostHog UTM Bug
   
   ## Rules
   
   - **UTMs are session-level**: PostHog stores UTMs at session level (`$session_entry_utm_source`), not event level. Event-level properties (`utm_source`, `$utm_source`) are no longer populated as of 2026-01-30.
   ```
4. Update `memory/_learnings.md`:
   - Add row to Topics table: `| posthog-utm-bug | PostHog UTM parameter handling | [[learnings/posthog-utm-bug]] |`
   - Add to Quick Reference: `- **UTMs are session-level**: Use `$session_entry_utm_source` for attribution, not event properties.`
5. Git commit: `learning: PostHog UTM session-level storage`
6. Report: "Learning saved: posthog-utm-bug"
