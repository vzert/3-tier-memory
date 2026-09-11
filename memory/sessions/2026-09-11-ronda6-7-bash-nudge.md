---
type: session
date: 2026-09-11
status: completed-with-pendientes
importance: 9
---
# Las escrituras que se saltan el journal, el aviso en Bash, y dos rondas mas de adversario

## Contexto
Tercer tramo del dia. Victor reporto un patron que veia constantemente: los agentes se saltan
`journal_strict`, escriben un indice a mano y luego deshacen su cambio para rehacerlo por el
journal. De ahi salieron cinco versiones (2.13.2 a 2.14.2), dos rondas adversariales mas, y el
primer uso del adversario LOCAL en vez del externo.

## Cambios realizados
- **Deteccion de escrituras fuera del journal, por bytes.** El compactador guarda el `sha256` de
  cada indice al escribirlo (`.journal/fingerprints.json`); si no coincide en la pasada siguiente,
  alguien escribio fuera. Aviso en `SessionStart`, rastro en `.journal/out-of-band.log`,
  re-sellado para que salga una vez. Nuevo `--check-drift` con entrada propia, y check 15 en
  `/audit-3t`. **No consulta `.memory-config`**: 64 de 65 proyectos no tienen config.
- **Aviso en Bash, que no bloquea** — `bin/bash-journal-nudge.sh`, en `PreToolUse` (texto del
  comando, aproximado, llega antes) y `PostToolUse` (bytes, exacto, un turno tarde). ~10 ms por
  llamada cuando no hay nada que decir, tras meter una criba en shell; eran 40.
- **`journal-compact.py --reseal`** — el unico camino sancionado para una edicion manual.
- **`journal_strict=1` por defecto** en `setup-memory` (Step 3b) y `migrate`, sin pisar una config
  existente.
- **Aviso de origen colgante** en `journal-emit.py`, en los tres sitios que nombran una sesion.
- **`bin/check-index-writers.py`** — cada script de `bin/` declara `# sella-huellas: si|no (razon)`.
- **Dos rondas adversariales**: la 6 (externo, codex/GPT-5) `break ungrounded=2 unfalsified=1
  incomplete=4 autonomy-violations=1`, y la 7 (LOCAL, subagente Sonnet 5) `break ungrounded=1
  unfalsified=0 incomplete=2 autonomy-violations=0`.
- Publicadas **2.13.2, 2.13.3, 2.13.4, 2.13.5, 2.14.0, 2.14.1 y 2.14.2**. Suite
  `test-bash-nudge.sh` nueva, de 23 a 49 aserciones.

## Bugs fixed
- **`scan-secrets.py` escribia indices y era invisible al detector.** Recorre todo `memory/` con
  `os.walk` filtrando por extension, asi que reescribe `_pendientes.md` si contiene un secreto —
  es el gate del Step 6. No sellaba: el detector acusaba a una herramienta del propio plugin y le
  decia "usa journal-emit.py", imposible para una redaccion. Y `check-index-writers.py` no lo
  escaneaba porque nunca nombra un indice como literal.
- **La ventana del sellado, tres veces.** No era el lock: una escritura por Bash nunca pide
  `.journal/.lock`. Estaba entre las DOS LECTURAS DE BYTES. Se arreglo reusando una sola lectura.
- **`enrich-memory.py` no re-sellaba**, y es el que `/triage-3t` manda correr antes del barrido.
- **La huella no veia un indice BORRADO ni un mensual creado a mano.**
- **Borrar `_pendientes.md` cegaba al plugin**: es el centinela con el que 10 scripts localizan
  `memory/`. Arreglado en las 2 entradas que toque.
- **La compuerta de mtime perdia escrituras del mismo segundo** (`find -newer` exige `>`).
- **Enlaces de Tier 2 colgando**: emiti 5 pendientes con DOS slugs de sesion inventados y nunca
  escribi el session file. Lo encontro otro agente leyendo el indice.
- **Un test mutaba `enrich-memory.py` en su sitio** y al abortar `set -e` lo dejo roto en el arbol
  versionado.
- **`plan.upsert --title` se aceptaba y se ignoraba** al actualizar (commit de otra sesion).

## Plans
- Ninguno nuevo. El plan padre `plan-pendientes-diferidos-v2.13.0` lo cerro la sesion paralela.

## Research
- Ninguno formal. Las mediciones viven en `.goalspec/` y en la transcripcion.

## Learnings generados
- [[learnings/3tier-memory-system]] — reglas 114, 115, 116 y las de esta sesion

## Callejones sin salida
- **Atacar la ventana del sellado por el lado del lock** — dos intentos (tomarlo; fundir dos en
  uno) y ninguno era el problema: una escritura por Bash nunca pide `.journal/.lock`, asi que el
  lock no la bloquea → la ventana estaba entre las dos LECTURAS DE BYTES; se arregla reusando una
  sola lectura, no sincronizando mejor.
- **Detectar por analisis de texto quien escribe un indice** — cuatro intentos, cuatro cortos; el
  ultimo no veia `normalize-pendientes` (`(jc.replace_with_retry if ... else os.replace)(tmp, p)`)
  ni `scan-secrets` (construye la ruta con `os.walk`) → dejar de adivinar: que cada script lo
  DECLARE, y exigir la declaracion a todos.
- **Encender `journal_strict` para que no editen los indices a mano** — el unico proyecto que lo
  tiene (`claude-vzert`) es el que mas ids escritos a mano acumula, 25 de 43, porque el hook no
  cubre Bash → lo que llega a todos sin `migrate` es la deteccion por huella, que no lee la config.
- **Una instruccion de AskUserQuestion en `~/.claude/CLAUDE.md`** — se escribio y se quito el mismo
  dia: n=1, sin prueba que la falsee, y en un fichero que nadie poda (el patron "cementerio" que
  este proyecto ataca) → la regla vive aqui: *antes de mandar un modal, por cada opcion que
  descartaste al redactarlo comprueba si su version mas DEBIL esta en el menu* (bloquear→avisar,
  borrar→archivar, fallar→reportar). Descartar una opcion por lo que cuesta equivocarse suele
  descartar el eje entero, y la opcion buena vive en el medio. **Caso que la origino**: ofreci
  huella / bloquear-en-Bash / ambas / documentar; rechace bloquear porque un falso positivo cuesta
  trabajo perdido, y tire el eje entero sin ver que AVISAR cuesta una linea de texto. Victor tuvo
  que pedirlo el, y el adversario de la ronda 6 lo confirmo como violacion de autonomia.
- **Probar la discriminacion con `git stash` sobre un fichero limpio** — no crea stash y la prueba
  pasa sin probar nada → mutar una copia, o comprobar que el stash existio.
- **`grep` sobre `_pendientes.md` bajo el proxy `rtk`** — truncaba la salida e inyectaba lineas
  propias ("tches in 1 files:"), asi que los ids salian como `SIN-ID` → leer el fichero con python
  cuando la salida tiene que ser exacta. Mismo patron que la regla ya escrita sobre `find -iname`.

## Pendientes
- [x] Decidir si journal_strict cubre Bash — `p-988cf235c6` (resuelto)
- [ ] ver [[_pendientes]] — los nuevos de esta sesion y 42 previos

## Commits
- `c797a9f` — checkpoint. En el repo solo entran el codigo del plugin y
  `memory/learnings/3tier-memory-system.md`: el resto de `memory/` esta en el .gitignore.
- Las 7 versiones de la sesion: `ea96c19` 2.13.2, `f873d18` 2.13.3, `bd7ecec` 2.13.4,
  `906f085` 2.13.5, `77dbbe1` 2.14.0, `f57a031` 2.14.1, `8b09d14` 2.14.2.

## Como retomar

```
Retomamos: las escrituras que se saltan el journal — medidas (96 por Bash, 43 ids sin evento), detectadas por huella y avisadas en Bash sin bloquear; 2.13.2 a 2.14.2 publicadas.
Lee memory/sessions/2026-09-11-ronda6-7-bash-nudge.md para el contexto completo.
Proximo paso: arreglar `bin/resolve-project-dir.sh`, que usa CLAUDE_PLUGIN_ROOT sin proteger y aborta cualquier hook con `set -u` _id: p-a4fcd4212a_. En el mismo fichero sigue abierto el bloqueo sin stdin _id: p-0e978674af_; miralos juntos.
No repitas: atacar la ventana del sellado por el lado del lock — una escritura por Bash nunca pide `.journal/.lock`, asi que sincronizar mejor no cierra nada; ni detectar por analisis de texto quien escribe un indice — cuatro intentos cortos, la unica forma que no pierde nada es que TODOS declaren.
Terminas cuando: los dos defectos de resolve-project-dir esten arreglados con una prueba que falle contra el codigo anterior, y las siete suites verdes. Nada mas del backlog en esa sesion.
Antes de actuar, dime en 3 lineas donde quedamos.
```

## Related
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
- [[sessions/2026-09-11-ronda4-5-eol-cursor]]
