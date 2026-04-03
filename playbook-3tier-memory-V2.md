---
type: playbook
created: 2026-03-09
updated: 2026-03-23
status: active
---
# Playbook: Sistema 3-Tier de Memoria para Agentes Claude Code

## Context

Cada proyecto operado por Claude Code necesita memoria persistente para no repetir errores, retomar trabajo pendiente, y mantener contexto entre sesiones. Sin estructura formal, los agentes acumulan archivos monolíticos que hacen triple función (log + learnings + pendientes), pierden pendientes enterrados en prosa, y repiten errores ya resueltos.

Este playbook documenta el proceso completo para implementar el sistema 3-tier de memoria en cualquier proyecto Claude Code — ya sea migración de un proyecto existente o setup inicial de uno nuevo. Soporta dos modelos: **Model A** (todo en auto-memory) y **Model B** (project-local con bridge — recomendado para proyectos con directorio propio).

**Output**: Un plan de implementación completo (como el que se generó para N8n) que el agente ejecutor pueda seguir paso a paso.

---

## Cuándo usar este playbook

- Proyecto Claude Code con 3+ sesiones sin memoria formal
- Proyecto nuevo que se espera tenga múltiples sesiones
- Agente que repite errores, pierde pendientes, o no retoma contexto

---

## Fase 1: Auditoría — Entender el estado actual

### 1.1 Localizar los paths del proyecto

Identificar 3 rutas críticas:

```
AUTO_MEMORY_DIR = ~/.claude/projects/<encoded-project-path>/memory/
PROJECT_DIR     = <ruta del proyecto>/
HOOKS_DIR       = <ruta del proyecto>/.claude/hooks/
```

> **Nota**: `<encoded-project-path>` es el path del proyecto con `/` reemplazados por `-`. Ejemplo: `/home/victor/proyectos/N8n/` → `-home-victor-proyectos-N8n`.

**Decision tree — Model A vs Model B**:

```
¿El proyecto tiene su propio directorio (fuera de home)?
├── SÍ → Model B (RECOMENDADO)
│   MEMORY_DIR = PROJECT_DIR/memory/          (visible, git, Obsidian)
│   AUTO_MEMORY_DIR/MEMORY.md = bridge only   (auto-loaded, apunta a MEMORY_DIR)
└── NO (es home/raíz)
    MEMORY_DIR = AUTO_MEMORY_DIR              (todo en auto-memory)
```

| | Model A: Todo en auto-memory | Model B: Híbrido (DEFAULT) |
|---|---|---|
| **Cuándo** | Proyecto ES la carpeta home/raíz | Proyecto con directorio propio |
| **Auto-memory MEMORY.md** | Contiene todo | Solo bridge a PROJECT_DIR |
| **Archivos reales** | `~/.claude/.../memory/` | `PROJECT_DIR/memory/` |
| **Git versionable** | No | Sí |
| **Visible al humano** | No (carpeta oculta) | Sí |
| **Obsidian graph** | No (a menos que symlink) | Sí (wikilinks nativos) |
| **Hooks** | Path hardcoded | `$CLAUDE_PROJECT_DIR/memory/` (portable) |

### 1.2 Auditoría del auto-memory existente

**CRÍTICO**: Verificar el estado del auto-memory MEMORY.md ANTES de cualquier otra operación.

```bash
AUTO_MEMORY_FILE="$AUTO_MEMORY_DIR/MEMORY.md"
ls -la "$AUTO_MEMORY_FILE" 2>/dev/null
wc -l "$AUTO_MEMORY_FILE" 2>/dev/null
```

Clasificar el auto-memory en una de estas categorías:

| Estado | Descripción | Acción requerida |
|---|---|---|
| **No existe** | Directorio vacío o sin MEMORY.md | Crear bridge (Model B) o full MEMORY.md (Model A) |
| **Bridge válido** | Solo contiene redirección a PROJECT_DIR/memory/ | OK — no tocar |
| **Contenido inline** | Tiene session protocol, pendientes, status, etc. DENTRO del auto-memory | **MUST migrate**: extraer contenido → PROJECT_DIR/memory/, reemplazar con bridge |
| **Híbrido corrupto** | Mezcla de bridge y contenido inline | **MUST fix**: backup, extraer contenido útil, reemplazar con bridge limpio |

> **Red flag Model B**: Si el auto-memory tiene más de 20 líneas de contenido real (no bridge), el sistema de memoria NO está funcionando como Model B. Todo lo que el agente escriba irá al auto-memory en vez del proyecto. **Esto se debe corregir antes de continuar.**

### 1.3 Inventariar archivos existentes

Listar todo lo que hay en MEMORY_DIR (y en AUTO_MEMORY_DIR si es diferente):

```bash
ls -laR $MEMORY_DIR
ls -laR $AUTO_MEMORY_DIR  # Solo si Model B, para detectar contenido fuera de lugar
```

Clasificar cada archivo en una de estas categorías:

| Categoría | Descripción | Ejemplo |
|---|---|---|
| **Index** | Archivo que principalmente apunta a otros | MEMORY.md con links |
| **Monolito** | Archivo grande haciendo múltiples funciones | debug-log.md con logs + learnings + pendientes |
| **Learnings** | Reglas/patrones aprendidos de errores | learnings.md, patterns.md |
| **Reference** | IDs, credenciales, config | ids.md, config.md |
| **Vacío/Stub** | Creado pero sin contenido útil | — |

### 1.4 Inventariar historial de sesiones (JSONL — lectura completa obligatoria)

**OBLIGATORIO**: Leer el 100% de TODOS los archivos JSONL de transcripts. No muestrear, no leer solo headers, no saltar archivos grandes. Cada JSONL es una sesión potencial para backfill.

```bash
# Contar y listar TODOS los JSONL
ls -la ~/.claude/projects/<encoded-path>/*.jsonl
```

**Para CADA archivo JSONL encontrado**:
1. Leer el archivo COMPLETO (sin límite de líneas, sin sampling)
2. Extraer: fecha, temas trabajados, bugs encontrados/resueltos, decisiones tomadas
3. Buscar patrones: `ExitPlanMode` (planes completados), `TODO`, `FIXME`, pendientes mencionados
4. Buscar learnings implícitos: errores cometidos y corregidos, patrones descubiertos
5. Registrar como sesión candidata para backfill

**NO es aceptable**:
- Leer solo los primeros N mensajes de cada JSONL
- Decidir que un JSONL "es muy largo" y saltar su contenido
- Resumir un JSONL sin haberlo leído completo
- Inferir el contenido de un JSONL por su nombre o tamaño

Buscar también evidencia fuera de JSONLs:
- **Logs dentro de archivos**: Buscar patrones como "Session X", "## Fix #N", fechas
- **CLAUDE.md del proyecto**: Leer para entender contexto del negocio

Determinar:
- ¿Cuántas sesiones ha tenido el proyecto?
- ¿Hay información recuperable para backfill?
- ¿Qué tan detallada es la información? (bugs numerados, fechas, descripciones)

### 1.5 Inventariar planes y research existentes

Buscar evidencia de planificación e investigación:

**Planes formales** (plan mode de Claude Code):
- JSONL transcripts: buscar `ExitPlanMode` → cada ocurrencia es un plan completado
- Archivos de plan: `ls ~/.claude/plans/*.md` → plans guardados durante sesiones
- Sessions que mencionan "plan", "architecture", "diseño", "implementación"

**Research / investigación**:
- Archivos existentes tipo análisis: `*analisis*`, `*analysis*`, `*comparison*`, `*evaluation*`
- Sessions con investigación: buscar "investigar", "evaluar", "comparar", "opciones", "alternativas"
- Ideas o evaluaciones pendientes en pendientes o MEMORY.md

**Para cada plan/research encontrado, registrar**:
1. Título descriptivo
2. Fecha
3. Status (completed, active, abandoned)
4. Si generó pendientes, learnings, o más planes
5. Fuente (JSONL, archivo, session)

**Decision tree para clasificar**:
```
¿El item es una investigación/evaluación sin implementación directa?
├── SÍ → research (puede o no tener archivo en research/)
└── NO → ¿Se definieron pasos de implementación?
    ├── SÍ → plan
    └── NO → registrar en session como actividad
```

### 1.6 Evaluar CLAUDE.md del proyecto

Leer `PROJECT_DIR/CLAUDE.md` completo. Identificar:
- Contexto del negocio y dominio
- Convenciones de archivos existentes
- ¿Ya tiene sección de Memory System? → Si sí, evaluar si es funcional o solo declarativa
- ¿Tiene `.gitignore` con `.claude/`?

### 1.7 Producir diagnóstico

Resumir hallazgos en formato estructurado:

```
DIAGNÓSTICO:
- Archivos existentes: [lista con categoría]
- Monolitos a dividir: [archivo → funciones que cumple]
- Pendientes enterrados: [cantidad, ubicación]
- Learnings recuperables: [cantidad, calidad]
- Sesiones reconstruibles: [cantidad, fuente de datos]
- Auto-memory estado: [no existe | bridge válido | contenido inline | corrupto]
- Ausencias: [qué falta vs. estructura 3-tier completa]
```

---

## Fase 2: Diseño — Decidir qué crear

### 2.1 Determinar el scope: Migración vs. Greenfield

```
¿El proyecto tiene historial (3+ sesiones, learnings, pendientes)?
├── SÍ → MIGRACIÓN: backfill sessions, migrar learnings, extraer pendientes
└── NO → GREENFIELD: crear estructura vacía con templates, sin backfill
```

### 2.2 Estructura objetivo (universal)

Todo proyecto debe terminar con TODAS las carpetas e índices. No hay carpetas opcionales — se crean todas siempre.

**Model A** (todo en auto-memory — solo para proyectos sin directorio propio):

```
~/.claude/projects/<encoded>/memory/    ← MEMORY_DIR
├── MEMORY.md                    # Tier 1: Lean index + checkpoint protocol
├── _pendientes.md               # Tier 2: Central aggregator
├── _session-index.md            # Tier 2: Session registry
├── _learnings.md                # Tier 2: Learnings topic index
├── _plans-index.md              # Tier 2: Plan registry
├── _research-index.md           # Tier 2: Research tracker
├── learnings/                   # Tier 3: Topic files
│   └── <topic>.md
├── sessions/                    # Tier 3: Session logs
│   └── YYYY-MM-DD-slug.md
├── pendientes/                  # Tier 3: Monthly archives
│   └── YYYY-MM.md
├── plans/                       # Tier 3: Plan files
│   └── plan-<slug>.md
└── research/                    # Tier 3: Research files
    └── <slug>.md
```

**Model B** (DEFAULT — project-local, con bridge en auto-memory):

```
PROJECT_DIR/
├── CLAUDE.md                    # Domain context + memory references
├── memory/                      ← MEMORY_DIR (visible, git, Obsidian)
│   ├── MEMORY.md                # Tier 1: Lean index (fuente de verdad)
│   ├── _pendientes.md, _session-index.md, _learnings.md
│   ├── _plans-index.md, _research-index.md
│   ├── learnings/, sessions/, pendientes/, plans/, research/
│   └── [reference files: ids.md, debug-log.md, etc.]
├── .claude/
│   ├── hooks/session-start.sh, check-index-registration.sh
│   ├── skills/checkpoint.md
│   └── settings.local.json

~/.claude/projects/<encoded>/memory/
└── MEMORY.md                    # Bridge: auto-loaded, apunta a PROJECT_DIR/memory/
```

Ambos modelos comparten hooks y skills en `PROJECT_DIR/.claude/`:

```
PROJECT_DIR/
├── .gitignore                   # Incluir .claude/
└── .claude/
    ├── hooks/
    │   ├── session-start.sh     # Inyecta pendientes + protocol reminder
    │   └── check-index-registration.sh  # Detecta archivos sin registrar
    ├── skills/
    │   └── checkpoint.md        # /checkpoint: actualiza memoria + commit
    └── settings.local.json      # Hook configuration
```

### 2.3 Diseñar migración de archivos existentes

Para cada archivo existente del diagnóstico (Fase 1), decidir acción:

| Archivo existente | Condición | Acción |
|---|---|---|
| Monolito con learnings | Tiene patrones/reglas valiosas | **Move** a `learnings/<topic>.md` + frontmatter |
| Monolito con logs | Tiene historial de bugs/fixes | **Keep** como archivo histórico + agregar header de archivo |
| Monolito con pendientes | Tiene TODOs/items abiertos | **Extract** pendientes a `_pendientes.md` + `pendientes/YYYY-MM.md` |
| Archivo de referencia | IDs, config, credenciales | **Keep** in place, solo agregar link desde MEMORY.md |
| MEMORY.md existente | Tiene contenido inline | **Rewrite** como lean index + checkpoint protocol |
| Archivo sin uso | No referenciado, contenido obsoleto | **Archive** o delete |
| Auto-memory con contenido (Model B) | Tiene más que bridge | **Backup** → extraer contenido útil → **Rewrite** como bridge |

**Regla de oro**: Nunca eliminar contenido valioso. Migrar, reorganizar, indexar — pero preservar.

### 2.4 Diseñar topics de learnings

Analizar el contenido de learnings/patterns existentes y agrupar por dominio:

```
¿Cuántos dominios de conocimiento distintos hay?
├── 1 dominio → 1 archivo: learnings/<domain>.md
├── 2-5 dominios → 1 archivo por dominio
└── Greenfield → Crear 1 archivo genérico: learnings/<project-name>.md
```

Para cada topic, definir:
- **Nombre del archivo**: `learnings/<topic-slug>.md`
- **Cuándo consultar**: "Before [acción específica del dominio]"
- **Quick reference rules**: Las 3-6 reglas más críticas (para `_learnings.md`)

### 2.5 Diseñar backfill de sesiones (solo migración)

**OBLIGATORIO**: El backfill se basa en la lectura completa de TODOS los JSONL (realizada en §1.4). No se puede hacer backfill parcial.

Para cada sesión reconstruible:
1. **Fecha**: Extraer del JSONL o inferir del contenido
2. **Slug**: Descripción corta de lo que se hizo (lowercase, hyphens)
3. **Status**: `completed` o `completed-with-pendientes`
4. **Contenido mínimo**: Contexto + cambios realizados + bugs fixed + pendientes

**Fuentes de datos para backfill** (en orden de preferencia):
1. Transcripts JSONL — TODOS leídos al 100% en §1.4 (fuente más rica)
2. Debug logs / changelogs (ya estructurados)
3. Git history del proyecto
4. CLAUDE.md / README con historial

### 2.6 Diseñar backfill de planes (solo migración)

Para cada plan encontrado en la auditoría (§1.5):
1. **¿Tiene suficiente detalle para archivo propio?** (>20 líneas, decisiones documentadas) → `plans/plan-{slug}.md`
2. **¿Es simple?** → solo fila en `_plans-index.md` con "(inline)"
3. **Fuentes de datos para contenido**:
   - Plan files guardados (`~/.claude/plans/*.md`) — copiar, agregar frontmatter + Related
   - JSONL transcripts — buscar contenido del plan entre `EnterPlanMode` y `ExitPlanMode`
   - Sessions que describen la planificación

### 2.7 Diseñar backfill de research (solo migración)

Para cada research encontrado en la auditoría (§1.5):
1. **¿Es una investigación profunda con hallazgos documentados?** → `research/{slug}.md`
2. **¿Es una idea o evaluación simple?** → solo fila en `_research-index.md`
3. **¿Maduró en plan?** → registrar en ambos: research como "completed → plan" y plan como origen
4. **¿Generó pendientes sin plan?** → registrar pendientes con `_origen: [[research/{slug}]]`

### 2.8 Diseñar hooks y skills

**Hook 1: SessionStart** — Inyecta pendientes + reminder
- Lee `_pendientes.md`, extrae líneas `- [ ]`
- Imprime pendientes abiertos + recordatorio de protocolo
- El recordatorio debe ser específico al dominio del proyecto

**Hook 2: PostToolUse/Write** — Detecta archivos sin registrar
- Al escribir archivo en `memory/sessions/`, verificar en `_session-index.md`
- Al escribir archivo en `memory/learnings/`, verificar en `_learnings.md`
- Al escribir archivo en `memory/pendientes/`, verificar en `_pendientes.md`

**Skill: /checkpoint** — Guarda estado de memoria + commit
- Crea/actualiza session log
- Extrae pendientes de la sesión
- Actualiza todos los índices
- Hace git commit de los archivos de memoria
- Registra hash del commit en el session log

### 2.9 Producir tabla de archivos

Generar tabla completa de archivos a crear/modificar:

```markdown
### Parte A: Estructura de memoria (MEMORY_DIR/)

| # | Archivo | Acción | Descripción |
|---|---|---|---|
| 1 | MEMORY.md | Rewrite | Lean index + checkpoint protocol |
| 2 | _pendientes.md | Create | Aggregator con items extraídos |
| ... | ... | ... | ... |

### Parte B: Hooks, skills e instrucciones (PROJECT_DIR/)

| # | Archivo | Acción | Descripción |
|---|---|---|---|
| N | .claude/hooks/session-start.sh | Create | Inyecta pendientes |
| N+1 | .claude/skills/checkpoint.md | Create | /checkpoint skill |
| ... | ... | ... | ... |
```

---

## Fase 3: Escribir contenido de cada archivo

### 3.1 MEMORY.md — Template

**Model A** (MEMORY.md vive en auto-memory y contiene todo):

```markdown
# <Project Name> — Memory Index

## Checkpoint Protocol — MANDATORY

### At session start
1. Read `_pendientes.md` — check for pending fixes, tests, or blockers

### During execution
- **New learning/gotcha** → add to `learnings/<topic>.md`, update `_learnings.md` if critical
- **New pendiente** → add to `_pendientes.md` with `_origen:` link
- **Executing a plan** → register/update row in `_plans-index.md` (🔄 while active, ✅ when done)
- **New research/investigation** → `research/{slug}.md` or row in `_research-index.md`
- **Research matures into plan** → create plan, move research to Completed in `_research-index.md`

### Checkpoint (user says "/checkpoint", "checkpoint", "guardemos", "save progress")
Run the /checkpoint skill which will:
1. Create/update `sessions/YYYY-MM-DD-slug.md` → add row to `_session-index.md`
2. Extract pendientes from session:
   - Unfixed bugs discovered
   - Tests not yet run
   - Deferred work ("después hay que...", "en próxima sesión")
   - <DOMAIN-SPECIFIC items, e.g., "Nodes/connections that need verification">
3. Each pendiente → `_pendientes.md` with `_origen:` link + `pendientes/YYYY-MM.md`
4. Update `_plans-index.md` — any plans started, progressed, or completed this session
5. Update `_research-index.md` — any research started or concluded this session
6. Git commit all memory changes → record commit hash in session log

## Topic Files
<Links to reference files that existed before migration, e.g., ids.md, config files>
<Links to archived monoliths, e.g., debug-log.md marked as historical>

## Operational Indexes
- [[_pendientes]] — Open action items. **Check at session start.**
- [[_session-index]] — Session history
- [[_learnings]] — When to consult which learnings file
- [[_plans-index]] — Plans ejecutados y en progreso
- [[_research-index]] — Investigaciones y evaluaciones

## Current Status
<2-4 bullets describing current project state>
<"See _pendientes.md for open items">

## Memory Rules
- Este archivo es un **índice**. No poner contenido detallado aquí.
- Crear archivos nuevos por tema en la carpeta correspondiente
- Actualizar o eliminar entradas obsoletas
- Usar frontmatter: `type`, `created`, `updated`, `status`
```

**Model B** (MEMORY.md vive en `PROJECT_DIR/memory/` — es idéntico al template de arriba). El MEMORY.md del auto-memory es un bridge (ver §3.15).

**Reglas de adaptación**:
- `Checkpoint Protocol > Checkpoint > Extract pendientes` debe incluir items específicos al dominio del proyecto
- `Topic Files` lista solo archivos que NO son indexes ni sessions/learnings/pendientes
- `Current Status` es snapshot breve — el detalle va en `_pendientes.md`

### 3.2 _pendientes.md — Template

```markdown
---
type: index
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active
---
# Pendientes

Open action items. Check at session start. Monthly archive: [[pendientes/YYYY-MM|<Mes> <Año>]].

## Alta prioridad

<Extraídos de auditoría: items bloqueantes o con fecha límite>

## Media prioridad

<Extraídos de auditoría: mejoran calidad pero no bloquean>

## Baja prioridad

<Extraídos de auditoría: nice-to-have>

## Cómo usar

### Agregar pendientes
1. Agregar aquí bajo la prioridad correcta con `_origen:` link (wikilink a session o plan)
2. Agregar fila a `pendientes/YYYY-MM.md`

### Completar pendientes
1. Remover de aquí
2. En `pendientes/YYYY-MM.md`: llenar Resuelto + Sesión (wikilink)

## Related
- [[_session-index]]
- [[_learnings]]
- [[pendientes/YYYY-MM|<Mes> <Año>]]
```

**Si es greenfield** (sin historial): Dejar secciones de prioridad vacías con comentario `<!-- Sin pendientes aún -->`.

### 3.3 _session-index.md — Template

```markdown
---
type: index
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active
---
# Session Index

**Status:** ✅ completada | ⚠️ con pendientes

## Sessions

| Fecha | Sesión | Status | Resumen | Commit |
|---|---|---|---|---|
<Filas de backfill si es migración>
<Vacío si es greenfield>

## Convención
- **Archivo por sesión**: `sessions/YYYY-MM-DD-slug.md`
- **Checkpoint (`/checkpoint`)**: crear archivo, agregar fila aquí, extraer pendientes, commit
- **Columna Commit**: hash corto del commit generado por /checkpoint

## Related
- [[_pendientes]]
- [[_learnings]]
```

### 3.4 _learnings.md — Template

```markdown
---
type: index
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active
---
# Learnings Index

Consult BEFORE making changes. Each file contains verified rules from past mistakes.

## Topic Files

| Topic | File | When to consult |
|---|---|---|
| <Topic 1> | [[learnings/<slug-1>]] | <Cuándo consultar — ser específico> |
| <Topic 2> | [[learnings/<slug-2>]] | <Cuándo consultar — ser específico> |

## Quick Reference — Most Critical Rules

<3-6 reglas one-liner extraídas de los topic files>
<Formato: N. **Keyword**: regla concisa>

## Related
- [[_pendientes]]
- [[_session-index]]
```

**Si es greenfield**: 1 topic genérico con el nombre del proyecto. Quick Reference vacío con nota "Se llenará conforme se descubran patrones".

### 3.5 learnings/topic.md — Template

```markdown
---
type: learnings
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active
---
# <Topic Title>

<Contenido migrado del archivo original, o vacío si greenfield>

## Related
- [[_learnings|Learnings Index]]
- [[<other-topic>|<Display Name>]]
- <Links a archivos relacionados del proyecto>
```

**Para migración**: Copiar contenido existente, agregar frontmatter, agregar Related.
**Para greenfield**: Crear con contenido mínimo (título + "Rules will be added as patterns are discovered").

### 3.6 sessions/YYYY-MM-DD-slug.md — Template

```markdown
---
type: session
date: YYYY-MM-DD
status: completed | completed-with-pendientes
---
# <Session Title>

## Contexto
<1-2 líneas de contexto>

## Cambios realizados
- <Bullet list de lo que se hizo>

## Bugs fixed
- <Lista referenciando archivos históricos si aplica>

## Learnings generados
- <Links a learnings/ files actualizados>

## Pendientes
- [ ] <Item> — ver [[_pendientes]]

## Commits
- `<short-hash>` — <commit message> (<fecha>)

## Related
- [[_session-index]]
- [[_pendientes]] (si generó pendientes)
- [[_learnings]] (si generó o consultó learnings)
- [[<related-sessions>]]
- [[<historical-files>]] (e.g., debug-log)
```

**Regla de wikilinks para sessions**: Cada session DEBE linkar a:
1. `[[_session-index]]` siempre
2. `[[_pendientes]]` si generó pendientes
3. `[[_learnings]]` si generó o consultó learnings
4. Otras sessions relacionadas
5. Archivos históricos relevantes (debug-log, etc.)

### 3.7 pendientes/YYYY-MM.md — Template

```markdown
---
type: archive
period: YYYY-MM
---
# Pendientes — <Mes> <Año>

| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesión resolución |
|---|---|---|---|---|---|---|
<Filas de pendientes extraídos>

## Related
- [[_pendientes|Pendientes (aggregator)]]
- [[_session-index]]
```

### 3.8 _plans-index.md — Template

```markdown
---
type: index
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active
---
# Plans Index

Registro de planes ejecutados y en progreso.

## Plans

| Plan | Status | Fecha | Sesión | Pendientes | Learnings |
|---|---|---|---|---|---|
<Filas de backfill si es migración>

## Lifecycle

idea → research → plan (draft) → ejecución (active) → reporte (completed) → pendientes → next plan

## Cómo agregar

1. Sustancial (>20 líneas) → `plans/plan-{slug}.md` + fila aquí
2. Simple → solo fila aquí con "(inline)"
3. Status: ⏳ draft | 🔄 active | ⚠️ testing | ✅ completed | ❌ abandoned

## Related
- [[_pendientes]]
- [[_session-index]]
- [[_learnings]]
- [[_research-index]]
```

### 3.9 plans/plan-slug.md — Template

```markdown
---
type: plan
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: draft | active | completed | testing | abandoned
---
# Plan: <Title>

## Context
<Por qué se necesita — problema, trigger, objetivo>

## Decisiones
<Opciones evaluadas y decisión tomada>

## Implementación
<Pasos ejecutados o a ejecutar>

## Resultado
<Output, estado final>

## Pendientes
- [ ] <items abiertos> — ver [[_pendientes]]

## Related
- [[_plans-index]]
- [[<session>]] (sesión de ejecución)
```

### 3.10 _research-index.md — Template

```markdown
---
type: index
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active
---
# Research Index

Investigaciones, evaluaciones técnicas, y exploraciones. Cuando un research madura → plan.

## Active Research

| Tema | Next step | Origen | Archivo |
|---|---|---|---|
<Filas de backfill o vacío>

## Completed Research

| Tema | Resultado | Archivo |
|---|---|---|
<Filas de backfill o vacío>

## Cómo agregar

1. Idea simple (1 línea) → fila en Active Research
2. Investigación profunda → `research/{slug}.md` + link en tabla
3. Cuando madura → crear plan en [[_plans-index]], mover research a Completed
4. Si genera pendientes sin plan → extraer a [[_pendientes]] con `_origen: [[research/{slug}]]`

## Related
- [[_plans-index]]
- [[_pendientes]]
```

### 3.11 research/slug.md — Template

```markdown
---
type: research
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active | completed | abandoned
---
# <Research Title>

## Contexto
<Qué se está investigando y por qué>

## Hallazgos
<Descubrimientos, comparaciones, evaluaciones>

## Conclusión
<Decisión tomada o next steps>

## Related
- [[_research-index]]
- [[_plans-index]] (si generó plan)
- [[_pendientes]] (si generó pendientes)
```

### 3.12 Hooks — Templates

> **Portabilidad**: Usar `$CLAUDE_PROJECT_DIR/memory/` en hooks (Model B) en lugar de paths hardcoded. Claude Code expone `$CLAUDE_PROJECT_DIR` automáticamente. Para Model A, usar el path absoluto de `AUTO_MEMORY_DIR`.

**session-start.sh**:
```bash
#!/bin/bash
# Inyecta pendientes abiertos y recordatorio de protocolo
# Model B: usa $CLAUDE_PROJECT_DIR (portable)
# Model A: reemplazar con path absoluto de AUTO_MEMORY_DIR
MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"

PENDIENTES=$(grep -E '^\- \[ \]' "$MEMORY_DIR/_pendientes.md" 2>/dev/null)

if [ -n "$PENDIENTES" ]; then
  echo "📋 PENDIENTES ABIERTOS:"
  echo "$PENDIENTES"
  echo ""
fi

echo "⚠️ PROTOCOLO: Registrar planes en _plans-index.md, sessions en _session-index.md, y pendientes en _pendientes.md DURANTE ejecución. No batching."
echo "💾 Usar /checkpoint para guardar progreso (actualiza memoria + git commit)."
echo "📖 ANTES de <DOMAIN-SPECIFIC-ACTION>: leer memory/_learnings.md → consultar el topic file relevante."
```

**check-index-registration.sh**:
```bash
#!/bin/bash
# Verifica que archivos en subcarpetas estén registrados en su índice
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path')
# Model B: usa $CLAUDE_PROJECT_DIR (portable)
# Model A: reemplazar con path absoluto de AUTO_MEMORY_DIR
MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"

# Solo actuar si el archivo está dentro de memory/
[[ "$FILE_PATH" != *"/memory/"* ]] && exit 0

BASENAME=$(basename "$FILE_PATH" .md)
SUBDIR=""
INDEX_FILE=""

if [[ "$FILE_PATH" == *"memory/plans/"* ]]; then
  SUBDIR="plans/"
  INDEX_FILE="$MEMORY_DIR/_plans-index.md"
elif [[ "$FILE_PATH" == *"memory/research/"* ]]; then
  SUBDIR="research/"
  INDEX_FILE="$MEMORY_DIR/_research-index.md"
elif [[ "$FILE_PATH" == *"memory/sessions/"* ]]; then
  SUBDIR="sessions/"
  INDEX_FILE="$MEMORY_DIR/_session-index.md"
elif [[ "$FILE_PATH" == *"memory/learnings/"* ]]; then
  SUBDIR="learnings/"
  INDEX_FILE="$MEMORY_DIR/_learnings.md"
elif [[ "$FILE_PATH" == *"memory/pendientes/"* ]]; then
  SUBDIR="pendientes/"
  INDEX_FILE="$MEMORY_DIR/_pendientes.md"
fi

if [ -n "$INDEX_FILE" ] && [ -n "$BASENAME" ]; then
  if ! grep -q "$BASENAME" "$INDEX_FILE" 2>/dev/null; then
    echo "⚠️ Archivo '$BASENAME' creado en ${SUBDIR} pero NO registrado en $(basename "$INDEX_FILE"). Registrarlo ahora."
  fi
fi

exit 0
```

### 3.13 /checkpoint Skill — Template

Crear en `.claude/skills/checkpoint.md`:

```markdown
---
name: checkpoint
description: Save memory checkpoint — update session log, extract pendientes, update indexes, git commit, record commit hash
user_invocable: true
---

# /checkpoint — Memory Checkpoint

Execute ALL of the following steps in order. Do not skip any step.

## 1. Session Log

- Determine a descriptive slug for this session's work
- Create or update `memory/sessions/YYYY-MM-DD-slug.md` using the session template:
  - Frontmatter with type, date, status
  - Contexto, Cambios realizados, Bugs fixed, Learnings generados, Pendientes
  - Related section with wikilinks
- Add or update the row in `memory/_session-index.md`

## 2. Extract Pendientes

Scan the ENTIRE current session for ALL of these categories:
- Verification/monitoring items ("confirmar que X funciona", "monitorear")
- Deferred steps ("después hay que...", "en próxima sesión")
- Conditions needing future checking ("si no mejora...", "si vuelve a pasar...")
- Incomplete plan steps not executed
- User deferrals ("luego lo veo", "mañana checo")
- Unfixed bugs discovered during the session
- Tests not yet run

Each extracted pendiente:
1. Add to `memory/_pendientes.md` under the correct priority with `_origen:` wikilink
2. Add row to `memory/pendientes/YYYY-MM.md`

Also check: were any existing pendientes resolved this session? If so:
1. Mark as `[x]` or remove from `memory/_pendientes.md`
2. Fill Resuelto date and Sesión wikilink in `memory/pendientes/YYYY-MM.md`

## 3. Update Indexes

- `memory/_plans-index.md` — any plans started, progressed, or completed this session
- `memory/_research-index.md` — any research started or concluded this session
- `memory/_learnings.md` — any new learnings added to topic files

## 4. Git Commit

```bash
git add memory/
git commit -m "checkpoint: YYYY-MM-DD-slug — <1-line summary of session work>"
```

Record the commit short hash (first 7 chars) in the session log file under `## Commits`:
```
- `abc1234` — checkpoint: <summary> (YYYY-MM-DD)
```

Also add the commit hash to the session's row in `_session-index.md` under the Commit column.

## 5. Confirm

Report to the user:
- Session log: created/updated (with path)
- Pendientes: N extracted, M resolved
- Indexes: which ones were updated
- Commit: hash and message
```

### 3.14 CLAUDE.md — Sección a agregar

Agregar al final del CLAUDE.md existente del proyecto:

**Model A** (archivos en auto-memory):

```markdown
## Memory System

This project uses a structured memory system for persistent knowledge across sessions. All memory files live in the auto-memory directory and use wikilinks for Obsidian graph traceability.

### Auto-loaded at session start
- MEMORY.md (auto-memory) — lean index + checkpoint protocol
- SessionStart hook injects open pendientes + protocol reminder

### Operational Indexes
- [[_pendientes]] — open action items (**check at session start**)
- [[_session-index]] — session history with links to each session
- [[_learnings]] — topic-based rules from past mistakes (**consult before <DOMAIN-ACTION>**)
- [[_plans-index]] — planes ejecutados y en progreso
- [[_research-index]] — investigaciones y evaluaciones

### Before <DOMAIN-SPECIFIC-ACTION>
Read [[_learnings]] → open the relevant topic file:
- [[learnings/<topic-1>]] — <description>
- [[learnings/<topic-2>]] — <description>

### Checkpoint
Use `/checkpoint` to save progress at any time. It will:
1. Create/update session log in `sessions/`
2. Extract pendientes → `_pendientes.md` + `pendientes/YYYY-MM.md`
3. Update all indexes
4. Git commit memory changes + record hash in session log

### Reference
- <Links to reference files: ids, config, etc.>
- <Links to archived historical files>
```

**Model B** (archivos en `PROJECT_DIR/memory/` — no duplicar checkpoint protocol, el bridge lo maneja):

```markdown
## Memory System

This project uses project-local memory. All files live in `memory/` within the project directory — visible, git-versionable, and Obsidian-ready with wikilinks.

### Operational Indexes
- `memory/_pendientes.md` — open action items (**check at session start**)
- `memory/_session-index.md` — session history
- `memory/_learnings.md` — topic-based rules (**consult before <DOMAIN-ACTION>**)
- `memory/_plans-index.md` — planes ejecutados y en progreso
- `memory/_research-index.md` — investigaciones y evaluaciones

### Before <DOMAIN-SPECIFIC-ACTION>
Read `memory/_learnings.md` → open the relevant topic file:
- `memory/learnings/<topic-1>` — <description>
- `memory/learnings/<topic-2>` — <description>

### Checkpoint
Use `/checkpoint` to save progress. Updates session log, extracts pendientes, updates indexes, and creates a git commit.

### Reference
- `memory/<reference-file>` — <description>
```

> **Nota Model B**: El checkpoint protocol completo vive en el bridge MEMORY.md (auto-loaded) y en `PROJECT_DIR/memory/MEMORY.md`. No duplicar en CLAUDE.md.

### 3.15 .gitignore

Agregar `.claude/` al `.gitignore` del proyecto si no está ya.

### 3.16 Auto-memory bridge (Model B only)

Cuando se usa Model B, el MEMORY.md en `~/.claude/projects/<encoded>/memory/` es un **bridge**: auto-loaded por Claude Code, solo redirige al proyecto.

**IMPORTANTE — Procedimiento de creación/reemplazo del bridge**:

1. **Si el auto-memory MEMORY.md ya existe con contenido inline** (detectado en §1.2):
   - Backup: copiar a `MEMORY.md.bak` en el mismo directorio
   - Extraer cualquier contenido valioso que no esté ya en PROJECT_DIR/memory/
   - **Borrar completamente el contenido existente** y reemplazar con el bridge template
   - **NO hacer append** — el bridge debe ser el ÚNICO contenido del archivo
2. **Si no existe**: crear directamente con el bridge template
3. **Verificar después de crear** (ver Fase 5: Auto-auditoría)

**Bridge template**:

```markdown
# <Project> — Memory Bridge

Este proyecto usa memoria project-local. Los archivos viven en `memory/` del proyecto.

## At session start
1. Read `memory/_pendientes.md` — pendientes abiertos
2. Read `memory/_learnings.md` — consultar antes de <DOMAIN-ACTION>

## During execution
- New learning → `memory/learnings/<topic>.md`, update `memory/_learnings.md` if critical
- New pendiente → `memory/_pendientes.md` with `_origen:` link + `memory/pendientes/YYYY-MM.md`
- Executing a plan → register/update row in `memory/_plans-index.md`
- New research → `memory/research/{slug}.md` + row in `memory/_research-index.md`
- Research matures → create plan, move research to Completed

## Checkpoint (user says "/checkpoint", "checkpoint", "guardemos", "save progress")
Run the /checkpoint skill which will:
1. Create/update `memory/sessions/YYYY-MM-DD-slug.md` → add row to `memory/_session-index.md`
2. Extract pendientes from session:
   - <DOMAIN-SPECIFIC categories>
3. Each pendiente → `memory/_pendientes.md` with `_origen:` link + `memory/pendientes/YYYY-MM.md`
4. Update `memory/_plans-index.md` — plans started, progressed, or completed
5. Update `memory/_research-index.md` — research started or concluded
6. Git commit all memory changes → record commit hash in session log

## Index
- `memory/MEMORY.md` — lean index completo
- `memory/_pendientes.md` — pendientes abiertos
- `memory/_learnings.md` — learnings por topic
- `memory/_session-index.md` — historial de sesiones
- `memory/_plans-index.md` — planes ejecutados y en progreso
- `memory/_research-index.md` — investigaciones y evaluaciones
- <additional reference files>
```

> **Importante**: El bridge usa paths relativos al proyecto (`memory/...`), NO paths absolutos. Esto lo hace portable entre máquinas (VPS, Mac, etc.). El contenido del bridge es idéntico en todas las máquinas donde se abra el proyecto.

### 3.17 settings.local.json

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/check-index-registration.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

---

## Fase 4: Plan de ejecución

Ordenar los cambios para ejecución:

### Parte A: Estructura de memoria

1. **Crear TODOS los directorios**: `mkdir -p sessions pendientes learnings plans research` en MEMORY_DIR — no es opcional, todos se crean siempre
2. **Mover archivos existentes**: Learnings/patterns a `learnings/`, agregar frontmatter + Related
3. **Crear TODOS los índices**: `_pendientes.md`, `_session-index.md`, `_learnings.md`, `_plans-index.md`, `_research-index.md` — todos obligatorios
4. **Crear plan files**: para planes sustanciales (>20 líneas) en `plans/`
5. **Crear research files**: para investigaciones con hallazgos documentados en `research/`
6. **Rewrite MEMORY.md**: Lean index + checkpoint protocol
7. **Crear monthly archive**: `pendientes/YYYY-MM.md`
8. **Crear session backfills** (solo migración): N archivos en `sessions/` — basados en lectura 100% de JSONL
9. **Crear learnings files**: al menos 1 topic file (greenfield) o migrados (migración)
10. **Marcar archivos históricos**: Agregar header "Archivo histórico" a monolitos preservados

### Parte B: Hooks, skills e instrucciones

11. **Crear hooks dir**: `mkdir -p PROJECT_DIR/.claude/hooks`
12. **Crear skills dir**: `mkdir -p PROJECT_DIR/.claude/skills`
13. **Crear hook scripts**: session-start.sh + check-index-registration.sh + `chmod +x`
14. **Crear checkpoint skill**: `.claude/skills/checkpoint.md`
15. **Crear settings.local.json**: Hook configuration
16. **Update CLAUDE.md**: Agregar sección Memory System (Model A o B según §3.14)
17. **Update .gitignore**: Agregar `.claude/`

### Parte C: Bridge + auto-memory (Model B only)

18. **Backup auto-memory MEMORY.md** (si existe con contenido inline): copiar a `.bak`
19. **Crear/reemplazar auto-memory bridge**: `~/.claude/projects/<encoded>/memory/MEMORY.md` con bridge template (§3.16)
20. **Eliminar archivos residuales del auto-memory**: si la migración movió archivos de auto-memory a PROJECT_DIR/memory/, eliminar los originales del auto-memory (excepto MEMORY.md bridge)

---

## Fase 5: Auto-auditoría

**OBLIGATORIO**: Después de ejecutar todas las fases anteriores, ejecutar esta auditoría completa. No se considera terminado hasta que TODOS los checks pasen.

### 5.1 Auditoría de estructura

Verificar que TODOS los archivos y carpetas existen (no opcionales):

```bash
MEMORY_DIR="<path>"  # Ajustar

# Directorios (TODOS obligatorios)
for dir in sessions pendientes learnings plans research; do
  [ -d "$MEMORY_DIR/$dir" ] && echo "✅ $dir/" || echo "❌ FALTA: $dir/"
done

# Índices (TODOS obligatorios)
for idx in MEMORY.md _pendientes.md _session-index.md _learnings.md _plans-index.md _research-index.md; do
  [ -f "$MEMORY_DIR/$idx" ] && echo "✅ $idx" || echo "❌ FALTA: $idx"
done

# Monthly archive
ls "$MEMORY_DIR/pendientes/"*.md 2>/dev/null | head -1 && echo "✅ pendientes/YYYY-MM.md" || echo "❌ FALTA: pendientes/YYYY-MM.md"

# Al menos 1 learnings file
ls "$MEMORY_DIR/learnings/"*.md 2>/dev/null | head -1 && echo "✅ learnings/*.md" || echo "❌ FALTA: al menos 1 learnings file"
```

Si CUALQUIER check falla → crear el archivo/carpeta faltante antes de continuar.

### 5.2 Auditoría de contenido

Para cada índice, verificar que tiene contenido mínimo válido:

| Archivo | Check | Criterio |
|---|---|---|
| `MEMORY.md` | Tiene checkpoint protocol | Contiene "Checkpoint" y "session start" |
| `_pendientes.md` | Tiene estructura de prioridades | Contiene "Alta prioridad", "Media prioridad", "Baja prioridad" |
| `_session-index.md` | Tiene tabla | Contiene "\| Fecha \|" |
| `_learnings.md` | Tiene tabla de topics | Contiene "\| Topic \|" |
| `_plans-index.md` | Tiene tabla de planes | Contiene "\| Plan \|" |
| `_research-index.md` | Tiene tablas active/completed | Contiene "Active Research" y "Completed Research" |

### 5.3 Auditoría de bridge (Model B only) — CRÍTICA

Esta es la verificación más importante. Un bridge mal configurado rompe todo el sistema.

```bash
AUTO_MEMORY_DIR="~/.claude/projects/<encoded>/memory"
PROJECT_MEMORY="<PROJECT_DIR>/memory"

# 1. Bridge existe
[ -f "$AUTO_MEMORY_DIR/MEMORY.md" ] && echo "✅ Bridge existe" || echo "❌ Bridge NO existe"

# 2. Bridge es bridge, no contenido inline
LINE_COUNT=$(wc -l < "$AUTO_MEMORY_DIR/MEMORY.md")
if [ "$LINE_COUNT" -lt 40 ]; then
  echo "✅ Bridge es compacto ($LINE_COUNT líneas)"
else
  echo "⚠️ Bridge tiene $LINE_COUNT líneas — posible contenido inline residual"
fi

# 3. Bridge apunta al proyecto
if grep -q "memory/" "$AUTO_MEMORY_DIR/MEMORY.md"; then
  echo "✅ Bridge referencia memory/ del proyecto"
else
  echo "❌ Bridge NO referencia memory/ — posible contenido inline"
fi

# 4. Bridge NO tiene indexes inline
for pattern in "_pendientes.md" "_session-index.md" "## Alta prioridad" "## Sessions"; do
  if grep -q "$pattern" "$AUTO_MEMORY_DIR/MEMORY.md" && ! grep -q "memory/$pattern" "$AUTO_MEMORY_DIR/MEMORY.md"; then
    echo "❌ Bridge tiene contenido inline: encontrado '$pattern' sin prefijo 'memory/'"
  fi
done

# 5. Project-local MEMORY.md existe y es la fuente de verdad
[ -f "$PROJECT_MEMORY/MEMORY.md" ] && echo "✅ Project MEMORY.md existe" || echo "❌ Project MEMORY.md NO existe"

# 6. No hay archivos residuales en auto-memory (excepto MEMORY.md)
RESIDUAL=$(find "$AUTO_MEMORY_DIR" -name "*.md" ! -name "MEMORY.md" 2>/dev/null | wc -l)
if [ "$RESIDUAL" -eq 0 ]; then
  echo "✅ No hay archivos residuales en auto-memory"
else
  echo "⚠️ $RESIDUAL archivos residuales en auto-memory — deberían estar en $PROJECT_MEMORY"
fi
```

**Si cualquier check falla**:
- ❌ Bridge no existe → crear con template §3.16
- ⚠️ Bridge tiene contenido inline → backup `.bak`, reemplazar con bridge template
- ❌ Bridge no referencia memory/ → reescribir completamente
- ❌ Project MEMORY.md no existe → copiar contenido del auto-memory, luego reemplazar auto-memory con bridge
- ⚠️ Archivos residuales → mover a PROJECT_DIR/memory/, eliminar del auto-memory

### 5.4 Auditoría de hooks y skills

```bash
PROJECT_DIR="<path>"

# Hooks
[ -x "$PROJECT_DIR/.claude/hooks/session-start.sh" ] && echo "✅ session-start.sh ejecutable" || echo "❌ session-start.sh"
[ -x "$PROJECT_DIR/.claude/hooks/check-index-registration.sh" ] && echo "✅ check-index-registration.sh ejecutable" || echo "❌ check-index-registration.sh"

# Skill
[ -f "$PROJECT_DIR/.claude/skills/checkpoint.md" ] && echo "✅ checkpoint.md skill" || echo "❌ checkpoint.md skill FALTA"

# Settings
[ -f "$PROJECT_DIR/.claude/settings.local.json" ] && echo "✅ settings.local.json" || echo "❌ settings.local.json"

# Verify hooks reference in settings
if grep -q "session-start.sh" "$PROJECT_DIR/.claude/settings.local.json"; then
  echo "✅ SessionStart hook configurado"
else
  echo "❌ SessionStart hook NO configurado en settings.local.json"
fi

# Test funcional del hook
echo "--- Test session-start.sh ---"
CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$PROJECT_DIR/.claude/hooks/session-start.sh"
```

### 5.5 Auditoría de graph traceability (wikilinks)

- [ ] Cada session file tiene `## Related` con `[[_session-index]]`
- [ ] `_pendientes.md` tiene Related con links a `[[_session-index]]`, `[[_learnings]]`, `[[pendientes/YYYY-MM]]`
- [ ] `_learnings.md` tiene Related con links a `[[_pendientes]]`, `[[_session-index]]`
- [ ] Cada learnings file tiene Related con links a `[[_learnings]]` y otros topics
- [ ] `pendientes/YYYY-MM.md` tiene Related con links a `[[_pendientes]]`, `[[_session-index]]`
- [ ] `_plans-index.md` tiene Related con links a `[[_pendientes]]`, `[[_session-index]]`, `[[_research-index]]`
- [ ] `_research-index.md` tiene Related con links a `[[_plans-index]]`, `[[_pendientes]]`
- [ ] Orígenes en pendientes usan wikilinks: `[[debug-log]]`, `[[sessions/slug]]`

### 5.6 Auditoría de CLAUDE.md

- [ ] CLAUDE.md tiene sección "Memory System"
- [ ] Sección lista los operational indexes correctos
- [ ] Sección menciona `/checkpoint`
- [ ] Si Model B: NO duplica checkpoint protocol (está en el bridge)
- [ ] `.gitignore` incluye `.claude/`

### 5.7 Resumen de auditoría

Al finalizar, producir reporte:

```
AUDITORÍA COMPLETADA:
- Estructura: X/X checks passed
- Contenido: X/X checks passed
- Bridge: X/X checks passed (o N/A si Model A)
- Hooks/Skills: X/X checks passed
- Wikilinks: X/X checks passed
- CLAUDE.md: X/X checks passed

ISSUES ENCONTRADOS Y CORREGIDOS:
- <lista de lo que se tuvo que arreglar>

ESTADO FINAL: ✅ Sistema 3-tier operacional | ❌ Requiere intervención manual en: <items>
```

---

## Principios críticos

### El patrón 3-tier

```
Tier 1: MEMORY.md (auto-loaded, <200 líneas)
   ↓ links to
Tier 2: _index files (lean aggregators, 30-60 líneas)
   ↓ links to
Tier 3: detail files in typed folders (contenido completo)
```

- **Tier 1 nunca lista items que crecen** — solo links a Tier 2
- **Tier 2 es referencia, no CRUD** — coordina, no almacena
- **Tier 3 es la fuente de verdad** — contenido completo con frontmatter

### Todo es obligatorio

Todas las carpetas (`sessions/`, `pendientes/`, `learnings/`, `plans/`, `research/`) y todos los índices (`_pendientes.md`, `_session-index.md`, `_learnings.md`, `_plans-index.md`, `_research-index.md`) se crean SIEMPRE. No hay carpetas opcionales. Un proyecto sin planes hoy puede tener uno mañana — la estructura debe estar lista.

### Backfill completo de JSONL

Cuando un proyecto tiene transcripts JSONL, se leen TODOS al 100%. No se muestrean headers, no se saltan archivos grandes, no se decide que "no hay suficiente información". Cada JSONL contiene una sesión completa de trabajo — es la fuente más rica de datos para reconstruir el historial.

### Dual-write para pendientes

Cada pendiente se escribe en DOS lugares simultáneamente:
1. `_pendientes.md` — operacional, se lee al inicio de sesión
2. `pendientes/YYYY-MM.md` — archivo histórico con lifecycle completo

Al resolver: remover de `_pendientes.md`, llenar Resuelto + Sesión en `pendientes/YYYY-MM.md`.

### Checkpoints, no "cierre de sesión"

El concepto de "cerrar sesión" se reemplaza por **checkpoint**: un snapshot del estado de la memoria que incluye un git commit. Los checkpoints:
- Se pueden hacer múltiples veces por sesión
- Siempre incluyen git commit con hash registrado
- No implican que el trabajo terminó — son puntos de guardado
- Se invocan con `/checkpoint` o cuando el usuario pide guardar progreso

### DURANTE ejecución, no batching

Registrar learnings, sessions, y pendientes DURANTE la ejecución de la sesión, NO al final en batch. Batching = olvidar items.

### Preservar contenido valioso

Nunca eliminar archivos con contenido útil. Migrar → reorganizar → indexar. Si un monolito tiene 300 líneas de bugs resueltos, moverlo es mejor que reescribirlo.

### Wikilinks everywhere

Usar `[[slug|Display]]` en lugar de `[Display](slug.md)`. Habilita:
- Obsidian graph visualization
- Backlink discovery (detectar huérfanos)
- Cross-vault references

### Frontmatter en todo

```yaml
---
type: index | session | plan | research | learnings | archive | playbook
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: active | completed | archived | superseded
---
```

### Model B como default

Para cualquier proyecto con su propio directorio, usar Model B: archivos en `PROJECT_DIR/memory/`, auto-memory MEMORY.md solo como bridge. Beneficios:
- **Git**: memoria versionable junto con el código
- **Visibilidad**: archivos visibles sin buscar en `~/.claude/`
- **Obsidian**: wikilinks nativos, aparecen en el graph
- **Multi-máquina**: Syncthing propaga archivos reales (no ocultos)

### Auto-memory bridge — el punto más frágil

En Model B, el MEMORY.md del auto-memory (`~/.claude/projects/<encoded>/memory/`) NO almacena contenido — solo redirige. El bridge:
- Es auto-loaded por Claude Code (siempre presente en contexto)
- Contiene checkpoint protocol completo con paths relativos al proyecto
- Apunta a todos los indexes y reference files
- Es idéntico en todas las máquinas donde se abra el proyecto

**Riesgo**: Si el agente escribe contenido inline en el auto-memory MEMORY.md (en vez del bridge), todo el sistema se rompe. El agente no ve los archivos project-local, no actualiza los índices correctos, y la memoria diverge. La auto-auditoría (Fase 5) verifica esto explícitamente.

### Portabilidad

- **Archivos**: paths relativos entre archivos de memory/ (`[[_pendientes]]`, `[[learnings/topic]]`)
- **Hooks**: usar `$CLAUDE_PROJECT_DIR/memory/` (env var de Claude Code, portable)
- **Bridge**: paths relativos al proyecto (`memory/_pendientes.md`)
- **Nunca** hardcodear paths absolutos en archivos ni hooks

### Plans y research como registro de decisiones

Cada plan y research se registra en su index. Dan visibilidad retroactiva: qué se investigó, qué se decidió, qué alternativas se descartaron, y cómo se llegó al estado actual. El lifecycle completo es:

idea → research (evaluar) → plan (decidir) → ejecución → reporte → pendientes → next cycle

No todo research se convierte en plan (puede descartarse o quedar como idea). No todo plan nace de research (puede ser reactivo). Pero ambos se registran para mantener trazabilidad.

### Adaptación al dominio

El checkpoint protocol, los learnings topics, y los hooks deben ser específicos al dominio del proyecto. Ejemplo:
- N8n: "Before ANY MCP operation" → consultar learnings/n8n-mcp.md
- Webflow: "Before ANY Designer API call" → consultar learnings/webflow-api.md
- OpenClaw: "Before config changes" → consultar learnings/openclaw.md

---

## Ejemplo condensado: Migración N8n (ejecutado 2026-03-09)

Este ejemplo muestra el output real de aplicar este playbook a un proyecto existente con 8 sesiones de historial. **Usa Model B** (project-local memory).

### Diagnóstico (Fase 1)

```
Archivos existentes (en auto-memory ~/.claude/.../memory/):
  - MEMORY.md        → Index (pero con status inline y pendientes mezclados)
  - debug-log.md     → Monolito (300+ líneas: session log + learnings + pendientes)
  - learnings.md     → Learnings (6 reglas genéricas, no organizado por topic)
  - n8n-patterns.md  → Learnings (40+ patrones MCP excelentes, no indexado)
  - ids.md           → Reference (IDs, credenciales — OK)
  - 7 planes en JSONL (ExitPlanMode), 1 análisis de v1 como research
  - 8 JSONL transcripts → TODOS leídos al 100% para backfill

Problema: archivos en carpeta oculta, no git, no Obsidian, no Syncthing
Auto-memory: contenido inline (NO bridge) → requiere migración + reemplazo con bridge
```

### Decisiones de diseño (Fase 2)

| Decisión | Resultado |
|---|---|
| **Modelo** | **Model B** (archivos en `N8n/memory/`, bridge en auto-memory) |
| Scope | **Migración** (8 sesiones de historial valioso, JSONL 100% leídos) |
| MEMORY.md | Rewrite como lean index en `N8n/memory/MEMORY.md` |
| Auto-memory MEMORY.md | Backup → reemplazar con bridge |
| debug-log.md | Keep como archivo histórico |
| n8n-patterns.md | Move a `memory/learnings/n8n-mcp.md` |
| learnings.md | Move a `memory/learnings/workflow-design.md` |
| ids.md | Move a `memory/ids.md` |
| Hooks | `$CLAUDE_PROJECT_DIR/memory/` (portable) |
| Skill | `/checkpoint` (session log + commit) |
| CLAUDE.md | Model B variant (no duplica checkpoint protocol) |

### Estructura final

```
N8n/
├── CLAUDE.md                              # Domain context + memory references
├── memory/                                # Visible, git, Obsidian
│   ├── MEMORY.md                          # Lean index + checkpoint protocol
│   ├── _pendientes.md, _session-index.md, _learnings.md
│   ├── _plans-index.md, _research-index.md
│   ├── learnings/n8n-mcp.md, workflow-design.md
│   ├── sessions/2026-03-0X-*.md (8 files)
│   ├── pendientes/2026-03.md
│   ├── plans/plan-followup-v2.md, plan-last-user-actions-json.md
│   ├── research/  (ideas tracked in _research-index.md)
│   ├── ids.md, debug-log.md
├── .claude/
│   ├── hooks/session-start.sh, check-index-registration.sh
│   ├── skills/checkpoint.md
│   └── settings.local.json

~/.claude/projects/-home-victor-proyectos-N8n/memory/
└── MEMORY.md                              # Bridge → N8n/memory/
```

### Test funcional del hook

```
$ CLAUDE_PROJECT_DIR=/path/to/N8n bash .claude/hooks/session-start.sh
📋 PENDIENTES ABIERTOS:
- [ ] **FIX Route Action: Skip en case 0** — _origen: [[debug-log]] session 7_
- [ ] **Test Cristhian M case** — _origen: [[sessions/2026-03-09-correction-rewrite]]_
- [ ] **Test correction paths** — _origen: [[sessions/2026-03-09-correction-rewrite]]_
- [ ] **Test Jesus C case e2e** — _origen: [[sessions/2026-03-09-correction-rewrite]]_

⚠️ PROTOCOLO: Registrar learnings, sessions, y pendientes DURANTE ejecución.
💾 Usar /checkpoint para guardar progreso (actualiza memoria + git commit).
📖 ANTES de operar con MCP: leer memory/_learnings.md → consultar topic file relevante.
```

### Auto-auditoría (Fase 5)

```
AUDITORÍA COMPLETADA:
- Estructura: 12/12 checks passed
- Contenido: 6/6 checks passed
- Bridge: 6/6 checks passed
- Hooks/Skills: 5/5 checks passed
- Wikilinks: 8/8 checks passed
- CLAUDE.md: 5/5 checks passed

ISSUES ENCONTRADOS Y CORREGIDOS:
- Auto-memory tenía contenido inline → backup creado, reemplazado con bridge

ESTADO FINAL: ✅ Sistema 3-tier operacional
```

---

## Related
- [[infrastructure/tania/subagent-playbook|Sub-Agent Playbook]] — playbook hermano para crear sub-agentes OpenClaw
- [[_plans-index]] — planes ejecutados usando este sistema
- [[_learnings]] — learnings index del proyecto principal (ejemplo vivo)
- [[_pendientes]] — pendientes del proyecto principal (ejemplo vivo)
- [[_session-index]] — session index del proyecto principal (ejemplo vivo)
