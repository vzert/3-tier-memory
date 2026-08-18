# Changelog

## [2.11.2] - 2026-08-18
### Fixed
- **`/checkpoint-3t` Step 6c pedía `git commit --amend` para embeber el hash del propio commit dentro de ese commit — un punto fijo que no existe.** Grabar el hash `H1` en un archivo trackeado y luego amendear cambia el arbol, lo que produce un hash nuevo `H2 ≠ H1`; el hash recien grabado queda obsoleto de inmediato. En sesiones reales esto producia loops de re-amend, abandono silencioso, o un falso "listo" — en los tres casos el hash grabado terminaba apuntando a un commit huerfano, peor que no grabarlo. Fix: se elimina el amend. El hash se graba como forward-reference sin comitear y se resuelve solo en el commit del proximo checkpoint — exactamente el mismo patron que el template ya usaba para el snippet `## Como retomar` de Step 8. Reportado en [#8](https://github.com/vzert/3-tier-memory/issues/8). Nota: el fix del template solo alcanza instalaciones nuevas o que reciban auto-update; copias ya congeladas en `.claude/commands/checkpoint-3t.md` de proyectos existentes mantienen el bug hasta que se re-corra `/setup-memory` o se apliquen manualmente.

## [2.11.1] - 2026-08-18
### Fixed
- **Nunca se instalan los comandos `-3t` en el ambito USER.** Si la sesion se abre desde `$HOME`, `"$CLAUDE_PROJECT_DIR/.claude/commands"` **es** `~/.claude/commands` — el ambito global, no el del proyecto. El hook (y `/setup-memory` y `/migrate`, que escriben ahi directamente) dejaban una copia global de cada comando, y a partir de ese momento el usuario ve `/checkpoint-3t` DUPLICADO (user + project) en todos sus proyectos, de forma permanente y sin ninguna pista de su origen — ademas la copia global se queda vieja, porque el auto-update solo toca las locales. Condiciones para caer en esto: que exista memoria para `$HOME` (Model B en `~/memory/`, o auto-memory en `~/.claude/projects/-Users-<user>/memory/`) y abrir una sesion desde `~`; es exactamente lo que hace quien prueba el plugin por primera vez sin entrar a un proyecto. Ahora el hook detecta el caso, se salta la escritura de comandos (la inyeccion de memoria sigue normal) y explica por que; `/setup-memory` y `/migrate` llevan la misma guarda documentada. Reportado por un usuario que encontro dos `/checkpoint-3t`, uno "user" y uno "project".

### Added
- **`bin/test-parser.sh` cubre la guarda de ambito** (25 casos): que no instala comandos cuando `$CLAUDE_PROJECT_DIR` es `$HOME` —probado con un `HOME` falso, sin tocar el real— y el control de que si los instala en un proyecto normal.

## [2.11.0] - 2026-08-17
### Fixed
- **El parser de `_pendientes.md` descartaba en silencio toda seccion fuera de `## Alta/Media/Baja` (`bin/session-start.sh`).** Un `## <header>` no reconocido ponia `current = None`, asi que sus items nunca entraban a un bucket — y como `total` se calculaba DESPUES del descarte, el encabezado del bloque imprimia un numero plausible pero falso. El fallo era invisible: se ve igual que "no hay pendientes". Medido en 12 proyectos reales: `unifi-expert` inyectaba **0 de 15** pendientes (su archivo usa `## Abiertos`, nunca tuvo secciones de prioridad); `Vecinex` 1 de 11; `Will-Ops` 86 de 109; `paperclip` 540 de 546. Las secciones desconocidas ahora caen en un bucket `otros` que se muestra al final; las secciones cerradas (`Como usar`, `Related`, `Completados`, `Scope`) se siguen saltando a proposito.
- **Items fuera de toda seccion tampoco se descartan.** Un pendiente escrito en el preambulo del archivo (antes del primer `## `) se perdia igual que los de seccion desconocida — real en `sms-masivos/landings`. El parser arranca en el bucket `otros` y salta el frontmatter YAML explicitamente.
- **Items bajo secciones cerradas se reportan en vez de desaparecer.** `## Completados`/`## Scope`/`## Related`/`## Como usar` se siguen excluyendo de la inyeccion (es correcto), pero ahora el bloque dice cuantos y de que seccion — 16 en `paperclip`, 7 en `sms-masivos/google_ads`, 2 en `landings`. La regla es que nada se cae en silencio, ni siquiera lo que se excluye a proposito.
- **El match de secciones cerradas esta anclado, no es por prefijo.** Comparar con `low.startswith(...)` tragaba secciones VIVAS enteras: `## Notas pendientes` empieza con `## notas`, `## Scope expansion tasks` con `## scope` — y sus items se restaban del auto-chequeo, o sea desaparicion silenciosa con el tripwire callado, el mismo fallo por otra puerta. Ahora se compara con un regex anclado al final que admite solo un sufijo acotado (`## Completados (2026-03-23)`, `## Cómo usar este archivo`), nunca texto libre.
- **La deteccion de frontmatter ya no se traga el archivo.** El toggle disparaba con cualquier `---`, asi que una regla horizontal a media pagina activaba el salto **para el resto del archivo** — una regresion peor que el bug original, capaz de suprimir un proyecto completo. Ahora solo cuenta como frontmatter si el `---` es la primera linea no vacia.
- **El auto-chequeo corre ANTES del corto por `total == 0`.** La supresion total es precisamente el caso que este release vino a arreglar (`unifi-expert` inyectaba 0 de 15), y el chequeo estaba despues del `sys.exit(0)`: un archivo cuyos items caian todos en secciones cerradas salia mudo. Ahora imprime la linea `ESTRUCTURA` aunque no haya nada que inyectar.
- **`bin/test-parser.sh`** — 23 regresiones del parser y del detector, cada una un fallo que ya ocurrio en produccion o que la verificacion adversarial encontro antes de publicar. Sin dependencias. Contra el parser de 2.10.0 falla 4 de 7 de los casos del parser, y con el detector saboteado fallan sus 15 casos — o sea que el arnes no acepta no-evidencia: stderr va aparte, se exige salida limpia y el marcador exacto, porque una version anterior de estas mismas pruebas daba `ok` ante un traceback.
- **El auto-chequeo normaliza igual que la clasificacion.** Clasificaba con `strip()` pero contaba con un regex anclado a columna cero, asi que un `  - [ ]` indentado producia un desajuste falso permanente.
- **Los avisos de estructura se recortan a 3 secciones + contador.** `sms-masivos/seo` organiza el archivo por fecha/tarea y tiene 7 secciones no canonicas: listarlas todas metia una linea de 300+ chars en cada sesion — el ruido que este release vino a quitar.
- **ALTA ya no se oculta por el cap.** El cap plano de 10 items cortaba por prioridad: un proyecto con 13 ALTA solo veia 10. Ahora ALTA se muestra completa (techo duro de 25) y el cap aplica al resto; si el techo recorta ALTA, el bloque lo declara (`OJO: solo 25 de 482 ALTA caben aqui`) en vez de omitirlo en silencio.

### Changed
- **El cuerpo de cada pendiente se trunca a 120 chars en el bloque SessionStart.** Un pendiente puede pasar de 900 chars; inyectarlo entero en CADA sesion ahoga el prompt real del usuario. Se corta en frontera de palabra, cierra cualquier `**` abierto y marca con `…`. El detalle completo sigue en `_pendientes.md`, que el agente abre si el item resulta relevante.

  Efecto neto por proyecto (bytes del bloque de pendientes, parser viejo vs nuevo, medido ejecutando ambos contra los mismos archivos): **el bloque encoge donde estaba inflado y crece donde estaba roto** — la correccion de conteo manda sobre el ahorro, no al reves.

  | proyecto | viejo | nuevo | |
  |---|---|---|---|
  | cloudflare-expert | 15407 | 4341 | −72% |
  | goal-spec-skill | 7590 | 2091 | −73% |
  | scalar-api-docs | 8715 | 2604 | −71% |
  | Will-Ops | 4210 | 2294 | −46% |
  | claude-vzert | 4346 | 2486 | −43% |
  | time-tracker | 1500 | 1317 | −13% |
  | paperclip | 3131 | 5310 | **+69%** — 482 ALTA: ahora muestra 25 en vez de 10 |
  | Vecinex | 385 | 1797 | **+366%** — recupera 10 items que estaban ocultos |
  | unifi-expert | 0 | 1960 | inyectaba **nada**; ahora sus 15 items |

### Added
- **Auto-verificacion de estructura en el hook SessionStart.** La leccion del bug anterior no es "faltaba un header" sino que **el hook fallaba en silencio y nadie comparaba su output contra el archivo**. Ahora el hook audita su propio parseo y emite una linea `ESTRUCTURA de _pendientes.md:` cuando detecta (a) secciones fuera del esquema de prioridad, (b) encabezados duplicados (`## Media prioridad` dos veces, real en 2 proyectos), (c) items `- [ ]` bajo secciones cerradas que por eso no se inyectan (real en paperclip: 16 sin cerrar bajo `## Completados`/`## Scope`), o (d) un desajuste entre las lineas `- [ ]` clasificables del archivo y las clasificadas. En proyectos con estructura sana no imprime nada.
- **El hook SessionStart detecta por si mismo un hook local duplicado.** Hasta ahora la deteccion vivia solo en `/migrate` y `/audit-3t` — dos comandos opt-in que se corren una vez al adoptar el plugin y nunca mas, asi que una instalacion podia pagar el corpus dos veces (una cruda, una curada) durante meses sin que nada lo dijera. El hook ya corre en cada sesion de cada instalacion: ahora lee `settings.json`/`settings.local.json` del proyecto, busca una entrada `SessionStart`/`UserPromptSubmit`/`PreCompact` cuyo script exista, lea `_pendientes.md` y lo haga `echo`, mide cuanto vuelca y emite UNA linea apuntando a `/migrate`. Ignora su propio registro (`${CLAUDE_PLUGIN_ROOT}`) y las entradas huerfanas (script inexistente — eso lo reporta `/migrate`). Validado contra el estado pre-limpieza de 8 instalaciones reales: las detecta todas, con cero falsos positivos en 17 proyectos ya limpios.

- **`/migrate` ahora resuelve el hook legacy que duplica al plugin.** El comando detectaba estas entradas pero se abstenia explicitamente cuando el script existia en disco ("not removing, verify this is intentional") — justo el unico caso que de verdad duplica contexto. Dos instalaciones anteriores al plugin (marzo 2026) llevaban meses inyectando los pendientes crudos ADEMAS del bloque curado: 31.5 KB extra por sesion en una de ellas. Ahora `/migrate` clasifica cada linea del script (emision duplicada / protocolo duplicado / genuinamente custom, tratando placeholders sin sustituir como texto muerto), mide los bytes que inyecta, y ofrece recortarlo conservando solo lo propio — o borrarlo junto con su registro si no queda nada custom.

## [2.10.0] - 2026-06-22
### Added
- **Redacción determinista de secrets en `memory/` (`bin/scan-secrets.py`).** `/checkpoint-3t` corre `git add memory/` + commit, así que en cualquier proyecto donde `memory/` NO esté en `.gitignore`, un secret capturado verbatim en un digest (sessions/plans/research) se commitea y, al hacer push, se filtra. Una *regla* de "acuérdate de redactar" es frágil (el agente la olvida); la garantía es un escáner determinista, mismo patrón que el frontmatter-seal (#24). Detecta shapes de alta confianza (AWS `AKIA…`, GitHub `ghp_…`/`github_pat_…`, OpenAI/Anthropic `sk-…`, Google `AIza…`, Slack `xox…`, Stripe `sk_live_…`, JWT, bloques `BEGIN … PRIVATE KEY`) + una regla genérica `key = valor` con gate de entropía (solo dispara en valores alfanuméricos mixtos, no en prosa). Reemplaza solo el VALOR por `<REDACTED>`; salta `$VAR`/`<REDACTED>`/placeholders → idempotente, atómico, nunca toca el resto del archivo, nunca imprime el secret (output enmascarado).
- **Enforcement en 3 capas** (prevención + detección): `/checkpoint-3t` Step 5d y `/save-learning` Step 3c redactan en `--apply` ANTES del commit (la capa que previene la fuga); `/audit-3t` y el hook SessionStart escanean en `--count` y avisan (warning-only).

### Fixed
- **`UnicodeEncodeError` en Windows con consola cp1252 (`enrich-memory.py`, `ensure-frontmatter.py`, `scan-secrets.py`).** Los tres scripts imprimen caracteres como `→`/`—`/`…` en su output; en Windows la codificación de `stdout` depende del codepage de la consola (o del locale, cuando se invoca vía `python3 script.py` bajo command substitution como hace `session-start.sh`), no de UTF-8. Con cp1252 (default en muchas instalaciones de Windows en español/inglés) el `print()` truena. Cada script ahora fuerza `sys.stdout.reconfigure(encoding="utf-8")` al arrancar, independiente del locale del shell que lo invoque.

### Notes
- **Si corriste `/migrate` antes de esta version y tenias un hook local propio, el comando te lo dejo pasar.** Hasta 2.10.0, al encontrar una entrada de hook cuyo script SI existia en disco, `/migrate` respondia "Found existing custom hook — not removing. Verify this is intentional" y seguia de largo — justo el unico caso que de verdad duplica contexto. Vuelve a correr `/migrate`: ahora clasifica el script, mide lo que inyecta y ofrece recortarlo conservando lo tuyo. De donde vienen: **de una receta que este repo publico**. El documento `playbook-3tier-memory-V2.md`, incluido en el primer commit (`3a59a09`, 2026-04-02) y borrado al dia siguiente (`6801bcb`, "chore: remove outdated playbook"), instruye textualmente crear `.claude/hooks/session-start.sh` y registrarlo en `settings.json` — la forma exacta de todos los ejemplares encontrados. Nunca estuvo dentro de `plugins/`, asi que el marketplace no lo distribuyo y no esta en ningun clone instalado; el codigo del plugin nunca escribio esos hooks y el README nunca lo indico. Pero la receta existio, y los proyectos armados con ella arrastran el hook al copiarse el scaffold de uno a otro. Por eso la deteccion se movio al hook SessionStart en vez de dejarla en un comando opt-in.

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
