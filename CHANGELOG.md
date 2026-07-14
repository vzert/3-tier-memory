# Changelog

## [2.10.0] - 2026-06-22
### Added
- **Redacción determinista de secrets en `memory/` (`bin/scan-secrets.py`).** `/checkpoint-3t` corre `git add memory/` + commit, así que en cualquier proyecto donde `memory/` NO esté en `.gitignore`, un secret capturado verbatim en un digest (sessions/plans/research) se commitea y, al hacer push, se filtra. Una *regla* de "acuérdate de redactar" es frágil (el agente la olvida); la garantía es un escáner determinista, mismo patrón que el frontmatter-seal (#24). Detecta shapes de alta confianza (AWS `AKIA…`, GitHub `ghp_…`/`github_pat_…`, OpenAI/Anthropic `sk-…`, Google `AIza…`, Slack `xox…`, Stripe `sk_live_…`, JWT, bloques `BEGIN … PRIVATE KEY`) + una regla genérica `key = valor` con gate de entropía (solo dispara en valores alfanuméricos mixtos, no en prosa). Reemplaza solo el VALOR por `<REDACTED>`; salta `$VAR`/`<REDACTED>`/placeholders → idempotente, atómico, nunca toca el resto del archivo, nunca imprime el secret (output enmascarado).
- **Enforcement en 3 capas** (prevención + detección): `/checkpoint-3t` Step 5d y `/save-learning` Step 3c redactan en `--apply` ANTES del commit (la capa que previene la fuga); `/audit-3t` y el hook SessionStart escanean en `--count` y avisan (warning-only).

### Fixed
- **`UnicodeEncodeError` en Windows con consola cp1252 (`enrich-memory.py`, `ensure-frontmatter.py`, `scan-secrets.py`).** Los tres scripts imprimen caracteres como `→`/`—`/`…` en su output; en Windows la codificación de `stdout` depende del codepage de la consola (o del locale, cuando se invoca vía `python3 script.py` bajo command substitution como hace `session-start.sh`), no de UTF-8. Con cp1252 (default en muchas instalaciones de Windows en español/inglés) el `print()` truena. Cada script ahora fuerza `sys.stdout.reconfigure(encoding="utf-8")` al arrancar, independiente del locale del shell que lo invoque.

### Notes
- La redacción protege commits FUTUROS. Cualquier key ya pusheada está comprometida y **debe rotarse** — `git rm`/redacción no des-filtra el historial (GitHub cachea forks/PRs, los scrapers indexan en segundos). Tanto el gate como el audit lo advierten explícitamente cuando `secrets_redacted/found > 0`.
- Reportado por un usuario cuyo agente commiteó y pusheó por error una carpeta de memoria con keys reales en texto plano.
- El fix de encoding fue reportado por un usuario en Windows; lo había resuelto localmente exportando `PYTHONIOENCODING=utf-8`, pero eso no cubre invocaciones del plugin que no pasan por su shell (p. ej. el hook SessionStart). No afecta memoria ya escrita — solo el output de estos tres scripts.

## [2.9.4] - 2026-06-22
### Fixed
- **Encoding canónico de ruta de proyecto.** El encoding del directorio del proyecto usaba `sed 's|/|-|g'`, que solo reemplaza barras. Claude Code codifica la carpeta en `~/.claude/projects/` reemplazando **todo carácter no alfanumérico** por `-` (barras, espacios, puntos, guiones bajos). En proyectos con espacios o puntos en la ruta (p. ej. `…/Vecino Seguro/Panel PHP`), los hooks y comandos calculaban una carpeta equivocada — el índice de backfill/recall caía en una ruta inexistente. Ahora todos usan `sed 's/[^A-Za-z0-9]/-/g'`, idéntico a la codificación de Claude Code. Reportado por un usuario que lo encontró y parchó a mano. (19 ocurrencias en `bin/`, `templates/`, `commands/`).

### Notes
- Para rutas sin espacios/puntos/guiones bajos el resultado no cambia, así que las instalaciones existentes en rutas "limpias" no necesitan migración. Solo las rutas con esos caracteres construían carpetas equivocadas; los comandos son idempotentes, así que basta re-correrlos tras actualizar.

## [2.9.3] - 2026-06-22
### Added
- **`/audit-3t` detecta datos volátiles en MEMORY.md.** Tier 1 (MEMORY.md) debe ser orientación ESTABLE (protocolo + punteros), nunca números en vivo — nada lo refresca, así que cualquier dato computado/volátil (conteos de corpus, rangos de fecha, "latest session: X") se queda stale en silencio. El audit ahora lo marca (warning-only) y recomienda mover esos números a `/status-3t`, que los computa on-demand.

### Notes
- Diseño deliberado: NO se añade una instrucción de "mantener MEMORY.md actualizado" — eso re-introduciría la fragilidad de delegar una garantía mecánica al agente (regla #57) y duplicaría lo que `/status-3t` ya computa. El fix correcto es no almacenar datos volátiles en Tier 1, y detectar la deriva con audit.

## [2.9.2] - 2026-06-22
### Added
- **Aviso de checkpoint consciente del contexto (`bin/context-nudge.sh`, hook UserPromptSubmit).** Sugiere `/checkpoint-3t` cuando la conversación cruza una fracción configurable del window del modelo, calculada desde el **uso real de tokens del transcript** (`input + cache_read + cache_creation`). De-dupe por bucket de 10% (no molesta cada turno). Independiente del auto-compact del harness.
- **Configurable** (el harness no expone la variante `[1m]`, así que el window es un knob): `THREET_CONTEXT_WINDOW` (default 200000; pon 1000000 en modelos de 1M) y `THREET_CHECKPOINT_RATIO` (default 0.8).

### Fixed / Notes
- **Aviso prematuro de checkpoint en modelos de 1M.** El plugin NO hardcodeaba 200k — el recordatorio salía del hook PreCompact, que es puramente reactivo al auto-compact de Claude Code (que dispara ~200k y no escala a 1M; el harness solo permite on/off vía `DISABLE_AUTO_COMPACT=1`, sin setting de umbral). El nuevo aviso por uso real reemplaza esa dependencia y escala al window que configures. README documenta ambos lados (deshabilitar auto-compact + configurar el window del plugin).

## [2.9.1] - 2026-06-22
### Added
- **Sello de frontmatter determinista (`bin/ensure-frontmatter.py`).** Los archivos Tier-3 los escribe el agente siguiendo `/checkpoint-3t` y `/save-learning`, pero nada verificaba que llevaran su bloque `---`; sobre un corpus grande algunos terminaron sin frontmatter, corriendo degradados en silencio (recall default 5, sin type/date). Ahora un sello determinista lo garantiza, en 3 puntos:
  1. **Prevención (fuente)**: paso final en `/checkpoint-3t` (Step 5c) y `/save-learning` — tras escribir los archivos, el sello antepone un bloque mínimo (type/date/status) a cualquier archivo que lo necesite. Convierte "el agente olvidó el frontmatter" en un no-op autocorregido.
  2. **Detección**: `/audit-3t` cuenta archivos sin frontmatter; SessionStart emite un warning de una línea (sin mutar nada).
  3. **Reparación**: `/enrich-3t` corre el sello antes de la pasada de importance, así los archivos recién sellados se puntúan en vez de saltarse.
- Sello solo de structure (type/date/status), nunca importance — eso es trabajo de enrich (su heurística + dry-run). Idempotente, atómico, nunca toca el body. Scope = archivos top-level de carpetas tipadas (mismas unidades que indexa el recall); `.md` anidados (snapshots/attachments) se dejan intactos.

### Notes
- Origen: al correr `/enrich-3t` en paperclip aparecieron 34 learnings (+ ~36 plans/research/reference) sin frontmatter, todos creados por checkpoint a lo largo del tiempo — garantía mecánica delegada a un agente sin enforcement. Generaliza la regla #53/#55: no dependas del agente para garantías mecánicas.

## [2.9.0] - 2026-06-21
### Added
- **Consolidación dirigida por índice + early-exit (`/consolidate-3t` reescrito).** Antes el comando escaneaba a ciegas todo el corpus de learnings (O(n²) semántico) — el costo era proporcional al TAMAÑO, no al número de duplicados reales. Ahora un pre-filtro determinista (`bin/find-dup-candidates.py`) calcula solapamiento Jaccard sobre los tokens del índice de recall y surfacea solo los pares candidatos; los agentes juzgan ese set pequeño. Si nada supera el umbral, **early-exit "corpus limpio" sin gastar un solo agente**. En un corpus real de 1.349 learnings: de un fan-out multi-agente a un script <100ms que emite ~18 pares. Umbral ajustable con `DUP_JACCARD_THRESHOLD` (default 0.5).
- **`/enrich-3t` (nuevo comando) — backfill de features v2.8.0 sobre corpus legacy.** Las features de recall/decay solo se escribían en archivos NUEVOS, así que en una memoria pre-existente recall corría degradado (todo `importance` = default 5) y el staleness nunca disparaba (sin `_creado:`). `enrich-3t` rellena ambos campos en archivos existentes: deriva `_creado:` del slug `_origen` (o del `date:` del archivo enlazado, o mtime), y asigna `importance:` heurístico. DRY-RUN por defecto, idempotente, escritura atómica, nunca toca el texto. Nuevo `bin/enrich-memory.py`.
- **Checks de escala en `/audit-3t`.** Presupuesto Tier 2 (avisa cuando un índice supera 60 líneas / 120 chars-por-línea / 40KB — "almacena en vez de coordinar", recomienda sharding por familia). Backlog de pendientes (>50 abiertos). Detección de **wikilinks rotos** vía `bin/check-wikilinks.py` determinista (escala a cientos de links; antes solo verificaba presencia, no validez). Backlog también en `/status-3t`.
- **Convención de archival + exclusión de scan.** `memory/archive/`, `*.bak`, `*.zip`, `*.archived.md`, `*-archived-*.md` se excluyen del índice de recall, del rebuild lazy, y de consolidate/audit. Evita que clutter archivado contamine recall y consolidación.

### Notes
- Migración: corre `/enrich-3t` UNA vez por proyecto pre-v2.8.0 para que recall y staleness operen sobre el corpus existente. Es idempotente (re-correrlo es no-op).
- Se descartó retirar la inyección "REGLAS CRITICAS" de SessionStart (ya es solo un conteo de ~1 línea, sirve un rol distinto al recall por turno).

## [2.8.0] - 2026-06-21
### Added
- **Recall por relevancia (nuevo hook `UserPromptSubmit`).** En cada turno, el plugin cruza el prompt del usuario contra la memoria y le inyecta las 3-4 unidades más relevantes (reglas, sesiones, pendientes, planes, research). Cierra la mayor brecha frente al sistema nativo de Claude, que sí surfacea memoria relevante por turno. Motor 100% léxico (BM25-lite + IDF), cero dependencias. `score = relevancia × recencia(decay por tipo) × importancia`. Silencio cuando nada supera el umbral (no contamina contexto). Nuevos: `bin/recall.sh`, `bin/build-recall-index.py`.
- **Índice de recall derivado** en `~/.claude/projects/<encoded>/.recall-index.jsonl` (junto a `.backfill-progress.json`, per-máquina, nunca commiteado). Se reconstruye solo cuando algún archivo de `memory/` es más nuevo que el índice (~70ms por turno).
- **`importance: 0-10` (salience) opcional** en frontmatter de sessions y learnings. `/checkpoint-3t` puntúa salience al crear; alimenta el ranking del recall. Default 5. Retrocompatible.
- **Señales de staleness/decay.** SessionStart marca `⚠ posible stale` los pendientes con `_creado:` > 30 días y empuja a reconciliarlos. `last_verified: YYYY-MM-DD` opcional en learnings. `/audit-3t` y `/status-3t` reportan pendientes stale y learnings que necesitan revisión.
- **`/consolidate-3t` (nuevo comando)** — higiene periódica de memoria: dedup de learnings, resolución de contradicciones por **supersedes** (conserva ambos, no sobrescribe — patrón de knowledge graphs temporales), y reflexión de sesiones recientes en reglas de mayor nivel (estilo Generative Agents).

### Fixed
- **Conteo de learnings roto en SessionStart.** El grep contaba bullets `- ` pero el Quick Reference usa lista numerada (`1.`, `2.`), así que "REGLAS CRITICAS: N" nunca aparecía y el antipatrón `grep -c || echo 0` emitía `"0\n0"` rompiendo el `[ -gt ]`. Ahora cuenta `^([0-9]+\.|[-*] )` y sanea el valor.

## [2.7.1] - 2026-05-15
### Added
- **Step 8 "Como retomar" en checkpoint** — `/checkpoint-3t` ahora genera un snippet copiable de 3 lineas (plantilla fija: contexto + ruta-session + proximo-paso + instruccion de resumir antes de actuar) que el usuario puede pegar en una nueva sesion despues de `/exit` o `/clear` para retomar contexto sin pensar. El snippet se imprime al terminal con separadores visuales Y se persiste en una nueva seccion `## Como retomar` dentro del session file (resistente a cerrar terminal sin copiar).

## [2.7.0] - 2026-05-15
### Changed
- **SessionStart inyecta pendientes como directiva, no como contador.** El hook CLI ahora lista los pendientes abiertos inline (cap 10 items, ordenados por prioridad y edad) con framing imperativo: "Antes de responder, verifica si la peticion del usuario se relaciona con alguno de estos items...". Con los items en contexto inicial el agente puede detectar resoluciones implicitas durante el flujo natural de trabajo. Rama Paperclip preservada.
- **Checkpoint Step 3 ahora corre en dos fases.** Step 3a reconciliacion (enumera CADA pendiente existente y lo clasifica como resolved/still-open/superseded/abandoned, imprimiendo tabla al usuario antes de continuar) corre PRIMERO. Step 3b extraccion de nuevos corre despues. El orden importa: con extraccion primero, la reconciliacion se volvia un afterthought.
- **Formato de pendiente nuevo incluye `_creado: YYYY-MM-DD`.** Habilita ordenamiento por edad en SessionStart y deja camino abierto para senales de staleness futuras. Pendientes legacy sin `_creado:` siguen funcionando (ordenados al final del bucket).

### Fixed
- Pendientes que se resolvian indirectamente en sesiones posteriores quedaban como zombies en `_pendientes.md`, inyectandose en cada SessionStart sin reflejar la realidad. La causa raiz eran dos: (1) pendientes invisibles durante la sesion que los resolvia, (2) reconciliacion como parentesis al final del Step 3 de checkpoint.

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
