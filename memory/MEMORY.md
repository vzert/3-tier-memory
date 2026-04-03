# 3-Tier Memory Plugin — Memory Index

## Checkpoint Protocol — MANDATORY

### At session start
1. Read `_pendientes.md` — check for pending fixes, tests, or blockers

### During execution
- **New learning/gotcha** → add to `learnings/<topic>.md`, update `_learnings.md` if critical
- **New pendiente** → add to `_pendientes.md` with `_origen:` link
- **Executing a plan** → register/update row in `_plans-index.md`
- **New research/investigation** → `research/{slug}.md` or row in `_research-index.md`
- **Research matures into plan** → create plan, move research to Completed in `_research-index.md`

### Checkpoint (user says "/checkpoint", "checkpoint", "guardemos", "save progress")
Run the /3-tier-memory:checkpoint skill which will:
1. Create/update `sessions/YYYY-MM-DD-slug.md` → add row to `_session-index.md`
2. Extract pendientes from session:
   - Plugin features not yet implemented
   - Tests not yet run
   - Documentation gaps
   - Community feedback to address
   - Packaging/distribution improvements deferred
3. Each pendiente → `_pendientes.md` with `_origen:` link + `pendientes/YYYY-MM.md`
4. Update `_plans-index.md` — any plans started, progressed, or completed this session
5. Update `_research-index.md` — any research started or concluded this session
6. Git commit all memory changes → record commit hash in session log

## Topic Files
- [[learnings/3tier-memory-system|3-Tier Memory System]] — rules and patterns for the memory system design

## Operational Indexes
- [[_pendientes]] — Open action items. **Check at session start.**
- [[_session-index]] — Session history
- [[_learnings]] — When to consult which learnings file
- [[_plans-index]] — Plans ejecutados y en progreso
- [[_research-index]] — Investigaciones y evaluaciones

## Current Status
- Plugin structure created with skills, hooks, commands, and bin scripts
- Playbook V2 serves as reference documentation
- Ready for testing and marketplace submission

## Memory Rules
- Este archivo es un **indice**. No poner contenido detallado aqui.
- Crear archivos nuevos por tema en la carpeta correspondiente
- Actualizar o eliminar entradas obsoletas
- Usar frontmatter: `type`, `created`, `updated`, `status`
