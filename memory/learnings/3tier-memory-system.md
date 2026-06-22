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
60. **Encoding de ruta de proyecto = `[^A-Za-z0-9]→-`, NUNCA solo `/→-`.** Claude Code nombra la carpeta en `~/.claude/projects/` reemplazando **todo carácter no alfanumérico** por `-` (barras, espacios, puntos, guiones bajos; cada char individual → `/.paperclip` da `--paperclip` doble guión). El plugin usaba `sed 's|/|-|g'` (solo barras) inlineado en 19 sitios (`bin/`, `templates/`, `commands/`), así que cualquier proyecto con espacio/punto en la ruta (`…/Vecino Seguro/Panel PHP`) calculaba una carpeta inexistente y el índice de backfill/recall caía mal. Fix: `sed 's/[^A-Za-z0-9]/-/g'` en todos. Validado contra carpetas reales (`-Users-will-Projects-3-tier-memory`, `-Users-will--paperclip-…`). Rutas "limpias" (sin espacio/punto/`_`) dan el mismo resultado → no necesitan migración; comandos idempotentes → re-correr basta. Reportado por usuario en v2.9.3. Refuerza #26 (bump al cambiar). v2.9.4.

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

## Pendientes Lifecycle

43. **Inyecta contenido, no contadores** — SessionStart debe meter los pendientes abiertos *inline* en el contexto del agente, no solo un conteo. Sin el texto visible, el agente nunca cruza la peticion del usuario contra items abiertos y los resuelve sin marcarlos. Cap a 10 items, ordenados por prioridad luego por edad (mas viejos primero porque son los mas sospechosos de estar ya resueltos). Framing imperativo: "Antes de responder, verifica si la peticion se relaciona con...". v2.7.0.
44. **Reconciliacion antes de extraccion** — Checkpoint Step 3 debe enumerar y clasificar CADA pendiente existente (resolved/still-open/superseded/abandoned) ANTES de buscar nuevos. Con extraccion primero el agente entra en modo "nuevo trabajo" y la reconciliacion se vuelve un afterthought. El paso debe imprimir tabla de reconciliacion al usuario para comprometer la decision. v2.7.0.
45. **`_creado: YYYY-MM-DD` inline en cada pendiente** — Formato canonico: `- [ ] <texto> — _origen: [[sessions/...]]_ — _creado: YYYY-MM-DD_`. Habilita ordenamiento por edad en SessionStart y senales de staleness futuras. Parser de session-start.sh debe tolerar items legacy sin `_creado:` (van al final del bucket). Backfill usa la fecha de la sesion origen (`dateFirst`), no hoy. v2.7.0.

## Relevance Recall & Decay (v2.8.0)

46. **Recall por relevancia = hook UserPromptSubmit, no SessionStart.** La brecha #1 vs el nativo era que la memoria nunca se cruzaba contra el prompt. Solución: hook `UserPromptSubmit` (`bin/recall.sh`) que puntúa cada unidad de memoria contra el prompt e inyecta top 3-4. SessionStart sigue inyectando pendientes+conteo de reglas; recall añade la capa por-turno. Silencio si nada supera umbral — el ruido degrada más que la ausencia.
47. **Motor léxico puro (BM25-lite + IDF), cero dependencias.** `score = relevancia × recencia × importancia`. Relevancia = suma de IDF de términos del prompt que matchean keywords de la unidad (términos raros pesan más). Decisión deliberada de NO usar embeddings: mantiene el ethos portable/git-versioned/sin-deps. Límite conocido: cross-language (prompt ES vs learning EN no matchea) — aceptado.
48. **Índice de recall es cache DERIVADO, va fuera de memory/.** Vive en `~/.claude/projects/<encoded>/.recall-index.jsonl` junto a `.backfill-progress.json` (per-máquina, nunca commiteado). Se reconstruye cuando cualquier `.md` de memory/ es más nuevo que el índice (`find -newer`). ~70ms/turno. NUNCA tratar el índice como fuente de verdad: regenerable siempre desde los .md.
49. **Tokenización idéntica en builder y scorer.** `build-recall-index.py` y el python embebido de `recall.sh` deben tokenizar igual (mismas stopwords ES/EN, mismo regex). Tokens ≥3 chars OR longitud-2 con dígito (captura identificadores como `3t`, `v2`). Si divergen, el matching se rompe silenciosamente.
50. **importance/last_verified son OPCIONALES y retrocompatibles.** `importance: 0-10` (salience Generative-Agents) en frontmatter de sessions/learnings alimenta el ranking; ausencia → default 5. `last_verified: YYYY-MM-DD` en learnings habilita el flag de staleness de /audit-3t. Archivos legacy sin estos campos funcionan sin cambios — patrón de reglas #41/#45.
51. **Decay por tipo, no global.** Half-life en el scorer: sessions 30d, pendientes 60d, plans/research 180d, learnings 3650d (casi infinito — el conocimiento no caduca como una sesión). Pendientes >30d se marcan `⚠ posible stale` en SessionStart y se empujan a reconciliación (Step 3a).
52. **Consolidación = supersede, no overwrite.** `/consolidate-3t` resuelve contradicciones marcando la regla vieja con `⊘ SUPERSEDED by [[...]]` y conservándola (preserva el "por qué" histórico, patrón Zep/knowledge-graph temporal). Dedup y reflexión (sesiones→reglas de mayor nivel) también proponen antes de tocar. Nunca borra learnings en silencio.

## Scale (v2.9.0)

53. **El costo de gestión debe ser proporcional al HALLAZGO, no al tamaño del corpus.** Evidencia: `/consolidate-3t` v2.8.0 escaneaba a ciegas todo el corpus (O(n²) semántico) — en paperclip (284 learnings) gastó un fan-out multi-agente para encontrar ~1 dup real. Fix: pre-filtro determinista (`bin/find-dup-candidates.py`, Jaccard sobre tokens del recall index) surfacea solo los pares candidatos; los agentes juzgan ese set chico. Si nada supera el umbral → **early-exit "corpus limpio" sin gastar un agente**. 1349 units → 18 pares en <100ms. Patrón general: empuja el filtrado/selección a Python determinista, deja que los agentes juzguen un set pequeño. v2.9.0.
54. **Features nuevas necesitan un PATH DE BACKFILL para corpus pre-existentes.** `importance:` y `_creado:` solo se escribían en archivos NUEVOS → en paperclip 0/284 learnings y 0/294 sessions tenían importance, y 0 pendientes tenían `_creado:`. Resultado: recall corría degradado (todo salience=5, factor neutro en `imp/5`) y staleness era no-op total (sin `_creado` → `None` → nunca marca). Una feature opcional-hacia-adelante NO basta a escala; hace falta migración. Solución: `/enrich-3t` (`bin/enrich-memory.py`) rellena ambos campos en archivos existentes — dry-run, idempotente, atómico, nunca toca texto. v2.9.0.
55. **Heurísticas de importance deben DISCRIMINAR; un score alto uniforme es no-op.** Recall escala relevancia por `importance/5`, así que poner todas las sessions en 7 no cambia el ranking — equivale a dejarlas en 5. Lección: solo demotar lo trivial (sessions backfilled→3, sin artefacto durable→4) y dejar las sustanciales NEUTRAL (sin campo → default 5). El señal real de importance vive en learnings (half-life 3650d → es el ranking primario ahí). Y markers de scoring demasiado comunes (`gate`/`must` en un corpus de governance) aplanan el señal — usar markers fuertes/específicos. v2.9.0.
56. **Convención de archival + exclusión de scan.** `memory/archive/`, `*.bak`, `*.zip`, `*.archived.md`, `*-archived-*.md` se excluyen del índice de recall (`is_excluded()` en build-recall-index.py), del rebuild lazy (`recall.sh` `find -newer`), y de consolidate/audit (nota de skip). El clutter archivado NO debe contaminar recall ni inflar consolidación. La exclusión es path-based (segmento `archive/`) + extensión, regex compartido entre los scripts. v2.9.0.
57. **Garantías mecánicas NO se delegan al agente — se sellan deterministamente.** Los archivos Tier-3 los escribe el agente siguiendo checkpoint/save-learning; sin enforcement, a la larga algunos salen sin frontmatter (en paperclip: 34 learnings + ~36 plans/research/reference, todos creados por checkpoint) y corren degradados en silencio. Fix: `bin/ensure-frontmatter.py` antepone un bloque mínimo (type/date/status) a cualquier archivo tipado top-level que lo necesite — idempotente, atómico, nunca toca el body, solo structure (importance lo pone enrich). Enganchado en 3: prevención (paso final de checkpoint Step 5c + save-learning), detección (audit + warning SessionStart, sin mutar), reparación (enrich sella antes de puntuar). Scope = top-level (mismas unidades que indexa recall); `.md` anidados intactos. Es la regla #53/#55 aplicada al punto de escritura. v2.9.1.
58. **El aviso de checkpoint vivía solo del PreCompact del harness — rehén de su umbral.** El plugin NUNCA hardcodeó 200k; `pre-compact.sh` es un recordatorio fijo que reacciona al auto-compact de Claude Code, que dispara ~200k y NO escala a 1M (el harness solo da on/off vía `DISABLE_AUTO_COMPACT=1`, sin setting de umbral; PreCompact no recibe conteo de tokens). En 1M se sentía prematuro. Fix: `bin/context-nudge.sh` (hook UserPromptSubmit) lee el uso REAL del transcript (`usage.input_tokens + cache_read + cache_creation` del último mensaje, leyendo el tail del JSONL) y avisa a una fracción configurable de un window configurable (`THREET_CONTEXT_WINDOW` default 200k, `THREET_CHECKPOINT_RATIO` default 0.8). De-dupe por bucket de 10%. El transcript registra el modelo base SIN el sufijo `[1m]`, por eso el window es un knob, no auto-detectable. Reemplaza al PreCompact (que se pierde si desactivas auto-compact). v2.9.2.

59. **MEMORY.md (Tier 1) = orientación estable, NUNCA números en vivo.** Nada refresca MEMORY.md (checkpoint/audit solo lo leen para confirmar que el sistema existe; no lo carga session-start ni lo parsea recall — es doc de orientación human/agente). Por eso cualquier dato volátil ahí (conteos de corpus, rangos de fecha, "latest session: X") se queda stale en silencio (caso paperclip: "11 sessions 2026-04-06 to 2026-04-08" cuando había 293). El fix NO es instruir al agente a mantenerlo (re-crea la fragilidad de #57 + duplica lo que `/status-3t` computa on-demand) — es **no almacenar datos volátiles en Tier 1** y que `/audit-3t` detecte la deriva (warning-only, v2.9.3). Un status estable de una línea ("Plugin structure created") está bien; números/fechas que duplican los índices son el problema. Refuerza #1/#2 (Tier 1/2 coordinan, no almacenan). v2.9.3.

## Related
- [[_learnings|Learnings Index]]
