# Changelog

## [2.1.0] - 2026-04-05
### Added
- Optional multi-dev support via `memory/.memory-config` file. When `multi-dev: true` is set:
  - Session frontmatter includes `dev:` field (identified via `whoami`)
  - Session index uses 6-column format with `Dev` column
  - Pendientes include `_dev: <username>_` tag alongside `_origen:`
  - Plans index uses 7-column format with `Dev` column
  - Git commits use `checkpoint(<dev>): slug — summary` format
  - SessionStart hook injects developer identity
- `detect-multidev.sh` — shared detection script sourced by all hooks
- Configurable pruning thresholds in `.memory-config` (`prune-sessions`, `prune-plans-completed`)
- `/audit` Section 6: multi-dev consistency checks (Dev columns, dev: frontmatter, _dev: tags)
- `/status` Dev Breakdown section showing per-developer session and pendiente counts

### Changed
- `/checkpoint` now reads `.memory-config` at Step 0 to determine single-dev or multi-dev mode. All subsequent steps adapt formats conditionally.
- `/checkpoint` Step 5b pruning thresholds are now configurable (defaults: 10/5 single-dev, 50/20 multi-dev)
- `/migrate` detects existing index column formats and warns on mismatches without reformatting data
- `setup-memory` creates indexes with correct column counts when multi-dev is configured
- `setup-memory` adds "Developer Attribution — OBLIGATORIO" section to MEMORY.md when multi-dev

### Fixed
- Projects with existing multi-dev conventions can now use the plugin without losing their customizations

## [2.0.0] - 2026-04-05
### Added
- Checkpoint Step 6 git resilience — detect-and-skip if git unavailable or not in a repo
- Agent-proof README with HTML comment header, terminal-first commands, manual install method
- Auto-enable marketplace auto-update in SessionStart hook
- Git status check in setup-memory verify step
- Marketplace auto-update step in setup-memory and migrate commands

### Changed
- Step 6 is now best-effort: checks git availability, handles .gitignore, reports skip reason
- README rewritten with Prerequisites, troubleshooting for AI agents, `claude plugin` terminal commands

## [1.7.0] - 2026-04-03
### Changed
- /checkpoint Step 5 now actively SCANS for plan/research signals instead of passively waiting. Detects plan mode usage, ExitPlanMode, web searches, comparisons, and investigation keywords.
- Session log template now includes ## Plans and ## Research sections with wikilinks to _plans-index and _research-index
- CORE RULE updated: plans/research are "scan for signals" not "only if applicable"

### Fixed
- Plans created in plan mode were not being registered in memory
- Research (web searches, doc lookups, comparisons) was silently dropped at checkpoint

## [1.6.0] - 2026-04-03
### Added
- `/3-tier-memory:migrate` command — for projects that already have memory/ from the playbook. Installs local commands, verifies bridge, creates missing indexes, runs audit. Does NOT overwrite existing data.

### Changed
- `setup-memory` now detects existing memory and redirects to `migrate` instead of stopping

## [1.5.0] - 2026-04-03
### Added
- SessionEnd hook — reminds to /checkpoint if no checkpoint was saved this session
- `/status` local command — quick memory health overview (pendientes, sessions, learnings, plans, research)
- `/audit` local command — runs Fase 5 verification checklists on demand
- CHANGELOG.md and LICENSE file

### Changed
- setup-memory now installs 3 local commands: /checkpoint, /status, /audit
- SessionStart hook auto-updates all 3 local commands when plugin updates

## [1.4.0] - 2026-04-03
### Added
- PreCompact hook — checkpoint reminder before context compaction
- Auto-update for local /checkpoint on plugin version change
- Canonical templates/ directory for local commands

## [1.3.0] - 2026-04-02
### Changed
- Removed checkpoint skill from plugin (was duplicate of local command)
- Plugin.json cleaned to official schema (repository=string, keywords not tags)

## [1.2.0] - 2026-04-02
### Changed
- Restructured as marketplace with plugin in plugins/3-tier-memory/
- Hooks use ${CLAUDE_PLUGIN_ROOT} for plugin-relative paths

## [1.1.0] - 2026-04-02
### Added
- Setup-memory installs local /checkpoint command
- Dual-write enforcement for sessions, pendientes, and learnings
- SessionStart hook injects learnings Quick Reference
### Fixed
- Bridge protection rule in CLAUDE.md

## [1.0.0] - 2026-04-02
### Added
- Initial plugin: setup-memory command, checkpoint skill, hooks
- 3-tier memory structure: MEMORY.md, 5 indexes, 5 folders
- SessionStart and PostToolUse hooks
- README with install/usage/troubleshooting
