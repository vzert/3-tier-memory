---
description: Save a learning/rule to memory (lightweight, for Paperclip agents)
---

# Save Learning

Guarda un learning o regla crítica en el sistema de memoria, sin hacer checkpoint completo.

**Uso**: Cuando descubras un patrón nuevo, regla de negocio, gotcha técnico, o corrección a un learning existente.

**NO** escribe sesiones, pendientes, plans, ni research. Eso es para CLI con `/checkpoint-3t`.

## Step 1: Locate memory directory and the journal scripts

If `memory/` exists in the project root, use it (Model B). Otherwise check auto-memory (Model A).
Read `memory/MEMORY.md` to confirm the system is initialized.

Since v2.12.0 rules are NOT appended to `memory/learnings/<topic>.md` or `memory/_learnings.md` by
hand: several agents (Paperclip workers included) may save a learning at the same time, and two
hand edits give two rules the same number or drop one of them. Each rule is an EVENT applied by a
single compactor under a lock, which assigns the number (`max + 1`). Locate the scripts once:

```bash
MEMORY_DIR="memory"   # the directory located above (Model B); use the Model A path otherwise
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/journal-emit.py" ]; then
  JBIN="${CLAUDE_PLUGIN_ROOT}/bin"
elif [ -f "plugins/3-tier-memory/bin/journal-emit.py" ]; then
  JBIN="$PWD/plugins/3-tier-memory/bin"     # the plugin's own repo: dogfood the working tree, not the cache
else
  JEMIT=$(find "$HOME/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
  JBIN=${JEMIT:+$(dirname "$JEMIT")}   # empty when find found nothing (dirname "" would give ".")
fi
[ -n "$JBIN" ] && [ -f "$JBIN/journal-compact.py" ] && echo "JBIN=$JBIN" || echo "JBIN=NONE"
```

If it prints `JBIN=NONE` (plugin older than 2.12.0), use the **Fallback** in Step 3 and say so in Step 5.

## Step 2: Review for learnings

Scan the current conversation for:
- New patterns discovered in data or behavior
- Business rules or constraints
- Technical gotchas or bugs
- Corrections to existing learnings
- Best practices or anti-patterns

If no learnings found, exit with "No new learnings to save."

## Step 3: Learnings — DUAL WRITE via journal

Read `memory/_learnings.md` to pick the topic (existing slug, or a new one). For each learning,
emit one event:

```bash
python3 "$JBIN/journal-emit.py" --type learning.add --topic <topic-slug> \
  --text "**<Rule name>** — <one-line description, no newlines>" \
  [--quickref "**<Rule name>** — <short form>"]   # only if critical (correctness/safety)
  [--title "<Topic Title>" --when "<when to consult>" --importance <0-10>]   # when the topic is new
```

Then compact:

```bash
python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
```

It must print `JOURNAL applied=N quarantined=0 pending_left=0`. If `quarantined>0`, read
`memory/.journal/quarantine/*.reason`, apply that change by hand, delete the `.json`/`.reason` pair
and report it in Step 5. If it prints `JOURNAL busy`, retry after a few seconds.

What the compactor writes — **Tier 3**: the rule appended to `memory/learnings/<topic>.md` with the
next number (or as a bullet if the file only uses bullets); a new topic file gets frontmatter
(`type`, `topic`, `created`, `updated`, `status`, `importance`, `last_verified`), `# <Topic Title>`,
`## Rules`, `## Related`. **Tier 2**: a row in the Topic Files table of `memory/_learnings.md` if the
topic is new, and the `--quickref` text numbered in `## Quick Reference`. The same rule emitted twice
is written once.

**Fallback (no JBIN)**: append the rule to the `## Rules` section of `memory/learnings/<topic>.md`
with the next number (create the file with the frontmatter above if missing), add the topic row and
the Quick Reference entry to `memory/_learnings.md` by hand.

## Step 3b: Seal frontmatter (deterministic guarantee)

Don't trust the write above to have a frontmatter block — enforce it. Run the seal script:
it prepends a minimal `---` block to any learning file missing one (no-op if you wrote it
right). Idempotent, atomic, never touches the body.

```bash
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py" ]; then
  SEAL="${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py"
else
  SEAL=$(find "$HOME/.claude/plugins" -name "ensure-frontmatter.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
fi
[ -n "$SEAL" ] && python3 "$SEAL" "$MEMORY_DIR" --apply
```

## Step 3c: Redact secrets (deterministic gate — before commit)

Step 4 commits memory/. Redact any plaintext key/token captured in the learning before it
gets committed. Idempotent and a no-op when clean (skips `$VAR`/`<REDACTED>`/placeholders).

```bash
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/scan-secrets.py" ]; then
  SCAN="${CLAUDE_PLUGIN_ROOT}/bin/scan-secrets.py"
else
  SCAN=$(find "$HOME/.claude/plugins" -name "scan-secrets.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)
fi
[ -n "$SCAN" ] && python3 "$SCAN" "$MEMORY_DIR" --apply
```
If it reports `secrets_redacted=N` with N>0, warn the user to rotate any key that was pushed earlier.

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
- File: memory/learnings/<topic>.md (rule #N)
- Journal: applied=N quarantined=0 (or "Fallback: hand edit, plugin < 2.12.0")
- Commit: <hash> (or "no git commit")
```

## Example

User discovers that PostHog has a bug with UTM parameters:

1. Read `memory/_learnings.md` to see existing topics
2. Determine this is a new learning for topic "posthog-utm-bug"
3. Emit the event and compact:
   ```bash
   python3 "$JBIN/journal-emit.py" --type learning.add --topic posthog-utm-bug \
     --title "PostHog UTM Bug" --when "Before attributing conversions in PostHog" --importance 7 \
     --text "**UTMs are session-level** — PostHog stores UTMs at session level (\$session_entry_utm_source), not event level. Event-level properties (utm_source, \$utm_source) are no longer populated as of 2026-01-30." \
     --quickref "**UTMs are session-level** — use \$session_entry_utm_source for attribution, not event properties"
   python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"
   ```
   The compactor creates `memory/learnings/posthog-utm-bug.md` (frontmatter + `## Rules` + `1. **UTMs are session-level** — ...`),
   adds `| PostHog UTM Bug | [[learnings/posthog-utm-bug]] | Before attributing conversions in PostHog |` to the Topic Files
   table and the Quick Reference entry with the next number.
4. Git commit: `learning: PostHog UTM session-level storage`
5. Report: "Learning saved: posthog-utm-bug"
