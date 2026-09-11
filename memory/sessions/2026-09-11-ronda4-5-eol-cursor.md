---
type: session
date: 2026-09-11
status: completed-with-pendientes
importance: 9
---
# Rondas 4 y 5 del adversario, el contrato de saltos de linea, y 2.13.0 publicada

## Contexto
Continuacion de `2026-09-11-caducidad-triage-adversario`. Se corrieron las dos rondas adversariales
que faltaban, acotadas al contrato de salto de linea de `atomic_write` y al delta que ninguna ronda
habia visto. Las dos cerraron en `break` con hallazgos reales. Despues se publico 2.13.0 y se
verifico el cambio de mas riesgo sobre la memoria real de Will-Ops.

## Cambios realizados
- **El salto de linea lo manda el fichero, no el sistema operativo.** Todas las escrituras usaban
  el modo texto por defecto de Python. El mismo `memory/` salia LF en macOS y CRLF en Windows.
  Habia **seis** rutas de escritura distintas en `bin/`, cada una con su copia del patron; tres
  seguian en modo texto. Ahora cada una mira el fichero en binario y conserva su salto.
- **Una prueba que ENUMERA las escrituras** del codigo y exige `newline=` en todas (`w`, `a`,
  `fdopen`, `write_text`), en vez de revisar llamantes. Es lo que impide una septima copia.
- **El id sintetico de `/triage-3t` sale del texto del item, no de su posicion.** El de la ronda 3
  se renumeraba al cerrar un item anterior y el corte estricto se saltaba ese item para siempre.
- **Cursor con digito de control** (`FECHA:ID:DIGITO`) — detecta una cadena manglada. **No** da
  procedencia, y decir que si lo hacia fue la afirmacion que rompio la ronda 5.
- **2.13.0 publicada**: merge fast-forward a main y push, `d772bc2..da4bd75`, 22 commits.

## Bugs fixed
- `atomic_write` convertia un fichero CRLF **entero** a LF. El pendiente `p-30993d16fc` lo
  describia como "un `\n` pelado", que era falso y mas benigno que la realidad.
- Segunda implementacion de `atomic_write` en `enrich-memory.py` con los cuatro defectos ya
  arreglados en la otra: sin salto final, modo texto, `path + ".tmp"` fijo (dos procesos pisandose)
  y `os.replace` sin reintento. Mas dos copias en `ensure-frontmatter.py` y `scan-secrets.py`.
- `scan-secrets.py` afirmaba "body is otherwise byte-identical", falso para un fichero CRLF.
- El log de `journal-compact.py` se escribia en modo append de texto: mezclado segun el sistema.
- Dos pruebas que decian cubrir el contrato eran **ciegas**: una comparaba en modo texto (que
  traduce el CRLF antes de comparar) y la otra miraba `tail -c 1`, igual en LF y en CRLF.
- El test del cursor estaba satisfecho por no-evidencia: solo probaba el digito deliberadamente mal.
- Una instalacion nueva veia "No queda nada por revisar tras ese cursor" sin haber dado cursor.
- El emisor aceptaba `--origen` a un session file inexistente sin decir nada — **este mismo fallo**,
  ver Callejones.

## Learnings generados
- [[learnings/3tier-memory-system]] — reglas 113 (corregida), 114 y 115

## Callejones sin salida
- **Afirmar que un digito de control da procedencia** → el adversario fabrico
  `2026-01-01:p-deadbeef00:8ae6` (id inventado, digito correcto, exit 0) → un digito derivado solo
  del id es una sha1 publica: detecta manglado, nunca procedencia. Lo que da procedencia es `_id`
  persistente.
- **Decir "dos items de texto identico son indistinguibles, no hay cuarta via"** → la habia, y ya
  estaba construida: `enrich-memory.py` (`enrich_ids`). Medido: 125 de 125 items reciben `_id` en
  una sola pasada → antes de inventar una identidad sintetica, mira si tu sistema ya persiste la real.
- **Revisar los llamantes de una funcion para probar que el contrato se cumple** → la ronda 4 miro
  los ~25 llamantes de un `atomic_write` y declaro limpio; habia seis implementaciones → la
  pregunta es cuantas implementaciones hay, y el arreglo es una prueba que las enumera.
- **Publicar razonando que "CRLF solo pasa en Windows"** → Will-Ops, en macOS, tiene diez `.md` en
  CRLF puro por Syncthing → medir el contrafactual sobre copias del corpus real, no razonar.
- **Emitir `pendiente.add` con un `--origen` a un slug que aun no existe** → cinco pendientes con
  dos slugs inventados y los enlaces de Tier 2 colgando → escribir el session file ANTES (Step 2
  antes que Step 3), y el emisor ahora avisa.
- **Listar un corpus por nombre corto sin su ruta** → el adversario lo busco donde no estaba y lo
  marco infundado → rutas absolutas en toda medicion que otro deba re-derivar.

## Pendientes
- [x] Ronda 4 adversarial acotada — `p-7d7b2b3f2b` (resuelto)
- [x] `atomic_write` y el fichero CRLF — `p-30993d16fc` (resuelto)
- [x] Publicar 2.13.0 — `p-51a9e211bc` (resuelto)
- [x] Auditar mas implementaciones de `atomic_write` — `p-921fa1b8cd` (resuelto)
- [x] Vigilar la primera instalacion con 2.13.0 — `p-f092d8c8dd` (resuelto)
- [ ] Correr `enrich-memory.py --apply` en los 6 proyectos con items sin `_id` — `p-cddd176cd7`
- [ ] Decidir si el plugin instala un `.gitattributes` — `p-d05bdba11b`
- [ ] (previo) `triage-scan.py` sin medir en el corpus de paperclip — `p-0e32d4f412`

## Verificacion
- Seis suites verdes; `test-expire-reopen.sh` paso de 45 a 68 aserciones.
- `.goalspec/`: `repro-eol.py` (contrato sobre bytes), `corpus-b2.txt` (rutas absolutas),
  `verificacion-eol-willops.txt` (el contrafactual: 981 CR → 991 con 2.13.0, → 526 con la anterior),
  y los payloads y veredictos de las rondas 4 y 5.

## Commits
- `df44aaf` … `a731fa8`. 2.13.0 en `da4bd75`.

## Related
- [[sessions/2026-09-11-caducidad-triage-adversario]]
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
