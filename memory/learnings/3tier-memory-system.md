---
type: learnings
created: 2026-04-02
updated: 2026-04-18
status: active
---
# 3-Tier Memory System — Learnings

## Architecture Rules

1. **Tier 1 (MEMORY.md) is an index only** — never put growing content here, only links to Tier 2. Must stay under 200 lines.
2. **Tier 2 (_index files) coordinate, don't store** — they reference Tier 3 files. Keep each under 60 lines.
3. **Tier 3 is source of truth** — full content with frontmatter in typed folders.
4. **All 5 folders are mandatory** — sessions/, pendientes/, learnings/, plans/, research/ — even if empty.

## Dual-Write Rules

5. **Sessions, pendientes, and learnings ALWAYS dual-write** — Tier 2 index + Tier 3 detail file. No exceptions.
6. **Plans and research: SCAN for signals, don't skip** — detect plan mode (ExitPlanMode, plan files), web searches, comparisons, investigation keywords. Any signal → dual-write. The old "only if applicable" wording caused agents to always skip.
7. **On pendiente resolve**: remove from _pendientes.md, fill Resuelto + Sesion in monthly archive.
8. **_origen wikilink required** — every pendiente must link to its source session or plan.

## Bridge Rules (Model B)

9. **Bridge is redirect-only** — auto-memory MEMORY.md contains ONLY the bridge template. Zero inline content.
10. **Bridge uses relative paths** — `memory/...` not absolute paths. Portable across machines.
11. **Red flag**: auto-memory MEMORY.md with >20 lines of real content = broken bridge.

## Session Rules

12. **Register DURING execution, not at end** — batching = forgetting items.
13. **Checkpoints, not session close** — multiple checkpoints per session are fine. Each includes git commit.

## Plugin Distribution — CRITICAL LESSONS

14. **Marketplace = repo with .claude-plugin/marketplace.json** — plugin lives inside plugins/<name>/ subdirectory with its own .claude-plugin/plugin.json.
15. **plugin.json schema is strict** — `repository` must be string (NOT object), use `keywords` (NOT `tags`). Always validate with `claude plugin validate`.
16. **${CLAUDE_PLUGIN_ROOT}** — correct variable for hook commands in plugins. NOT $CLAUDE_PLUGIN_DIR.
17. **Local command names must use `-3t` suffix** — Generic names (checkpoint, status, audit) collide with global skills (e.g., gstack). All local commands use `-3t` suffix: /checkpoint-3t, /status-3t, /audit-3t, /backfill-3t. session-start.sh auto-migrates old names on first run after update.
18. **Marketplace cache is sticky** — `/plugin marketplace update` does NOT always pull latest. If stale, must do `cd ~/.claude/plugins/marketplaces/<name> && git pull` manually, or remove + re-add.
19. **`/plugin marketplace remove` + `add` may reuse stale clone** — doesn't guarantee a fresh clone. Manual git pull in the marketplace directory is the reliable fix.
20. **extraKnownMarketplaces only makes it known** — users still need to run `/plugin install` + `/reload-plugins`. It does NOT auto-install.
21. **Version bump forces cache refresh** — always bump version in plugin.json when pushing fixes, otherwise cached versions persist.
22. **README must not assume plugin knowledge** — step-by-step with one command per block, wait points between steps, troubleshooting for every known failure mode.
23. **Don't mix languages in user-facing text** — keep README and plugin description in one language. Spanish terms only in internal filenames (_pendientes.md).
24. **Index pruning is automatic** — checkpoint Step 5b trims session/plan/research indexes. Tier 3 detail files are NEVER deleted. Only index rows are removed after exceeding retention limits (10 sessions, 5 completed plans, 5 completed research).
25. **Git commit is best-effort in checkpoint** — Step 6 detects git issues (not installed, no repo, user not configured, .gitignore) and skips gracefully. Memory file writes (Steps 1-5) are the valuable part; git commit is a convenience, never a blocker.
26. **Version bump is mandatory on every push** — Claude Code uses plugin.json version as cache key. Same version across two commits = skip update. ALWAYS bump version in plugin.json before pushing changes to the repo.
27. **Auto-update must be enabled automatically** — Third-party marketplaces don't auto-update by default (only official Anthropic marketplaces do). session-start.sh, setup-memory, and migrate all auto-enable `autoUpdate: true` in `known_marketplaces.json`. Never depend on user manual action for updates.
28. **`claude plugin` works as terminal CLI** — Not just REPL `/plugin`. Commands like `claude plugin marketplace add`, `claude plugin install`, `claude plugin list` all work from a regular shell. Terminal form is preferred in docs because AI agents universally understand shell commands but may not recognize REPL slash commands.
29. **README must be agent-readable** — AI agents guide most installations. Use HTML comments for agent-only instructions (invisible on GitHub), prefer terminal commands over REPL slash commands, always provide a manual fallback (git clone + settings.json).

## Backfill Rules

30. **JSONL backfill is a separate command** — /backfill-3t is standalone, not embedded in setup or migrate. It's expensive (reads all JSONL, AI synthesis per session). Setup and migrate detect JSONL files and recommend /backfill-3t.
31. **Two-phase extraction pipeline** — Phase 1 (Python script) strips tool_results, thinking blocks, file-history-snapshots to produce a condensed digest. Phase 2 (Claude) reads the digest and synthesizes memory artifacts. This keeps token budget manageable even for 2.5MB JSONL files.
32. **Backfilled sessions use `status: backfilled`** — Distinguishes AI-reconstructed sessions from live-captured ones. Backfill pendientes are marked with `(backfill)` in _origen.
33. **Progress tracking via .backfill-progress.json** — Lives in the JSONL directory. Tracks processed/skipped UUIDs. Enables resume after interruption and idempotency on re-run.
34. **session-start.sh notifies about pending backfill** — Counts JSONL files vs processed, prints "BACKFILL PENDIENTE: N sesiones" if any remain.
35. **Global skills shadow local commands** — Claude Code resolves global skills (~/.claude/skills/) before local commands (.claude/commands/). If a global skill has the same name as a local command, the skill wins. This is why all local commands use the `-3t` suffix.
36. **session-start.sh must install missing commands, not just update** — Auto-update loop must check if template exists even when local file doesn't. Otherwise new commands added in plugin updates never get installed. Fixed in v2.2.1.
37. **Plugin skills don't appear in autocomplete** — Documented bug (anthropics/claude-code #18949, #21125, #41842). Plugin-distributed skills with namespace `plugin:skill` are invisible in `/` menu. This makes them impractical for frequently-used commands.
38. **Checkpoint needs conversation context** — checkpoint scans the entire conversation for pendientes, learnings, and session summary. Skills with `context: fork` run in isolated subagents without conversation history. Commands stay in-session — this is correct for checkpoint.
39. **Don't migrate commands to plugin skills** — Evaluated 2026-04-06. Three blockers: broken autocomplete, checkpoint needs conversation context, `-3t` suffix is more ergonomic than namespace. Re-evaluate when Anthropic fixes plugin skill autocomplete.
40. **$CLAUDE_PLUGIN_ROOT is NOT available in local commands** — Only set during hook execution (hooks.json commands). Markdown command templates in .claude/commands/ run as Claude instructions, not as hook subprocesses. Any command that references plugin binaries must use `find "$HOME/.claude/plugins" -name "script.py" -path "*/3-tier-memory/*"` as fallback. Fixed in v2.2.2.
41. **$CLAUDE_PROJECT_DIR is unreliable — always fallback to stdin `cwd`** — Despite official docs saying it's available in all command hooks, some environments don't set it. All hook scripts must source resolve-project-dir.sh which reads `cwd` from the hook's stdin JSON as fallback. Uses jq if available, python3 otherwise. Fixed in v2.2.3.
42. **Trivial = tiny AND no signal** — `extract-session-digest.py` marks a session trivial only when `line_count < 10 AND userMessageCount < 2 AND no signal`. Signals: any `signals.*`, plan permission mode, or any tool use. OR semantics were the original bug — a 163-line plan session with 2 user msgs was dropped. `BACKFILL_FORCE_ALL=1` disables the gate and moves `skipped[]` to `previously_skipped[]` for a full re-run. Thresholds overrideable via `BACKFILL_TRIVIAL_LINE_THRESHOLD` / `BACKFILL_TRIVIAL_USER_MSG_THRESHOLD`. Fixed in v2.4.0.

## Related
- [[_learnings|Learnings Index]]
