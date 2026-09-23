---
type: session
date: 2026-09-23
status: completed-with-pendientes
importance: 8
---
# Dos regresiones reales del snippet "Como retomar", confirmadas en el JSONL crudo de claude-vzert (2.32.0)

## Contexto
Víctor pidió (vía `/goalspec:interview`) revisar el JSONL de las sesiones recientes de
`claude-vzert` por una sospecha de regresión: el mecanismo de "próximo paso lee el plan activo"
(2.25.0/2.25.1) y el de "no repitas un id que ya tiene su propio recordatorio futuro" (2.25.7/8/9)
llevan semanas sin tocarse en el template, pero Víctor los vio fallar en vivo en la sesión "fase 7".

## Cambios realizados
- Localicé el JSONL de `claude-vzert` (`~/.claude/projects/-Users-will-Projects-claude-vzert/`,
  149-202 sesiones) y encontré el turno exacto donde Víctor corrigió al agente ("no hay un paso
  siguiente de la fase 7 en vez de que me des un prompt genérico"), grepeando mensajes de usuario
  reales, no la ficha ya compactada.
- Reconstruí el borrador ORIGINAL (pre-corrección) de `2026-09-22-verificacion-cierre-pr238.md`
  desde el `Write` tool_use del JSONL: `## Plans` decía "Ninguno — sin cambios al plan desde el
  checkpoint anterior" mientras `## Como retomar` nombraba el plan por ruta en prosa suelta —
  confirmando que el caso 1 de `<next-step>` nunca se disparó porque el plan no estaba enlazado.
- Escribí un script de barrido (`shadow_run.py`, en el scratchpad) contra las 101-102 fichas
  reales de `claude-vzert` desde 2.25.9 (2026-09-17 en adelante) para confirmar la segunda
  sospecha: encontré 2 sesiones reales (`verificar-avance-pr192-censo-grep`, `restos-213-pr220`)
  con un id duplicado entre `## Recordatorios de calendario` y `Sigue abierto:`.
- Implementé dos checks nuevos en `checkpoint-audit.py`: `plan.mencionado_no_enlazado` y
  `snippet.futuro_duplicado`, más un fix de prosa en `checkpoint-3t.md` (caso 1 de `<next-step>`
  gana su propia variante del caso 5).
- **Cinco rondas de `/goalspec:adversary`** (el backend externo configurado, `codex exec`, falló
  las tres veces que lo intenté — exit 1 sin completar ninguna ronda, tratado como `hold` no
  verificado; verificación real hecha por subagente Opus) encontraron y cerraron defectos reales:
  falso negativo por substring en vez de wikilink real, falsos positivos por no acotar las líneas
  ni exigir que el archivo del plan exista, y una contradicción de prosa entre mi variante nueva
  del caso 5 y dos reglas de colapso ya existentes en el template. Detalle completo abajo.
- `test-checkpoint-audit.sh`: 84 → 101 casos. Suite completa (`tools/run-tests.sh`) verde,
  36 suites, único skip pre-existente (`oraculo-rewrite-rule`, falta `markdown-it-py`).
- Commit `33fb17b`, aislado a mano (`git apply --cached` con un patch de solo mis hunks) del
  trabajo de otra sesión que ya estaba sin commitear en el mismo árbol
  (`journal-compact.py`, `repair-research-index.py`, `setup-memory.md`, dos tests, y otro párrafo
  de `checkpoint-3t.md`) — ninguno de esos archivos se tocó ni se commiteó.
- Versión 2.31.9 → 2.32.0, CHANGELOG.
- **Al cerrar esta misma sesión, Víctor señaló en vivo un tercer defecto, del mismo tipo que los
  dos que acababa de arreglar**: mi primer `## Como retomar` promovió a `Proximo paso` un
  pendiente (`p-a4439fa8fd`) cuyo único trabajo era "verificar... una vez OTRA instalación
  actualice el plugin" — bloqueado por una decisión ajena, no accionable de inmediato. La regla
  existente en `checkpoint-3t.md` ("no inventes 'revisar si X respondió'") no me lo impidió porque
  mi frase no usaba esas palabras literales. Reescribí esa regla como una pregunta explícita a
  hacerse ANTES de fijar cualquier `<next-step>` de los casos 2-4 ("¿esto se puede hacer de
  inmediato, sin esperar acción de algo fuera de esta sesión?"), citando este mismo incidente junto
  al de 2026-09-14. También reescribí el `## Como retomar` de esta ficha al caso 4 correcto
  (`p-a4439fa8fd` baja a `Sigue abierto`) y pegué el recordatorio de calendario literal en el chat,
  que la primera vez solo describí en prosa sin mostrarlo — segundo error señalado en el mismo
  turno. Versión 2.32.0 → 2.32.1.

## Bugs fixed
- **Producto** (`claude-vzert`, mecanismo del plugin): caso 1 de `<next-step>` no leía el `## Estado`
  del plan cuando `## Plans` decía "sin cambios" en prosa (fase 7); `Sigue abierto:` podía repetir
  un id ya cubierto por su propio recordatorio de calendario (2 sesiones reales). _verificado: test-checkpoint-audit.sh sobre las 2 sesiones reales de claude-vzert_
- **Propios de esta sesión, encontrados por el adversario antes de comitear**: el respaldo por
  substring de `plan.mencionado_no_enlazado` daba falso NEGATIVO (prosa sin wikilink real contaba
  como "enlazado") y falso POSITIVO (mención en `No repitas:` o ruta `docs/plans/…` contaba como
  "el próximo paso"); wikilinks con `.md`/`#ancla` no se reconocían; una línea `Próximo paso:` con
  tilde o `**negrita**` se saltaba; y mi primera redacción del caso 1 en `checkpoint-3t.md`
  contradecía la condición de "subir hasta la raíz" (Step 5) y la exclusión de Alta de otras
  sesiones (Step 8) para cuándo colapsa el caso 5. Los seis, corregidos y verificados antes de esta
  ficha — ninguno llegó al commit. _verificado: 4 rondas de adversario, ultima hold_
- **Propio del cierre de ESTA ficha, señalado por el usuario después de comitear 2.32.0**: mi
  `<next-step>` promovió un pendiente bloqueado por una decisión ajena ("cuando otra instalación
  actualice el plugin") como si fuera trabajo de hoy — la regla de `checkpoint-3t.md` contra
  "revisar si X respondió" no me detuvo porque la frase no coincidía literal. Reescrita como
  pregunta explícita, ver `## Cambios realizados`.

## Plans
Ninguno.

## Research
Ninguno.

## Learnings generados
- [[learnings/3tier-memory-system]] — un subagente adversario RETOMADO puede responder desde su
  propio contexto de la ronda anterior en vez de releer los archivos, aun pidiéndole
  explícitamente verificar "el código ACTUAL" — cita cifras (diff stat, número de línea) que ya no
  existen, y solo se detecta comparándolas contra una medición propia independiente.
- [[learnings/3tier-memory-system]] — un check mecánico construido para cerrar un defecto de
  "mención vs reconciliación" puede él mismo caer en el mismo defecto (substring en vez de
  wikilink real, sección completa en vez de línea exacta) — verificarlo con casos adversariales
  construidos a propósito, no solo con el corpus real donde el patrón malo ya se sabe que existe.
- [[learnings/3tier-memory-system]] — el propio agente que acaba de escribir una regla puede
  violarla en el mismo cierre: minutos después de reescribir la regla contra pasos bloqueados por
  terceros, promoví a `Proximo paso` un pendiente con exactamente esa forma. Ninguna prosa nueva
  se prueba sola contra su propio autor.
- [[learnings/3tier-memory-system]] — un defecto hallado en vivo y "arreglado" solo con prosa
  sigue abierto; si no se registra como pendiente, la escalera de `<next-step>` no lo ve y cae al
  caso 4 genérico.

## Callejones sin salida
- Primera versión de `snippet.futuro_duplicado` medía cualquier id dentro de `## Como retomar`
  completo → 2 falsos positivos reales (`remedicion-goalspec-precondicion-no-cumplida`,
  `nudge-devs-encendido`) donde `Proximo paso` citaba el id solo para explicar el caso 5, no para
  duplicarlo → acotado a la línea `Sigue abierto:` únicamente, donde el patrón es inequívoco.
- Primera versión de `plan.mencionado_no_enlazado` comparaba por substring `plans/<slug> in
  sec_plans` → aceptaba prosa sin wikilink real como "enlazado" y confundía `plan-x` con
  `plan-x-v2` por prefijo → reemplazado por un wikilink real (`WIKILINK_PLAN_LAXO`) comparado por
  slug exacto, y la búsqueda de menciones acotada a las líneas `Proximo paso:`/`Lee `.
- Primera redacción del caso 1 en `checkpoint-3t.md` decía "usa la misma variante del caso 5" sin
  decir si el bloque de 6 líneas colapsa o no → chocaba con la regla de "subir hasta la raíz" (Step
  5) y con la exclusión de Alta de otras sesiones (Step 8) → reescrito para que la variante nueva
  sea literalmente una condición MÁS de cuándo `<next-step>` ES el caso 5 (mismo mecanismo de 8a),
  con referencia cruzada explícita en ambos puntos de conflicto.
- El backend externo configurado para el adversario (`codex exec`) falló 3 veces seguidas (exit 1,
  sandbox read-only, sin completar ninguna ronda) → tratado como `hold` no verificado, no como
  bloqueo → verificación real hecha con el backend de subagente (Opus).
- Primer `## Como retomar` de ESTA ficha promovió `p-a4439fa8fd` a `Proximo paso` con el texto
  "una vez otra instalación actualice el plugin" → es exactamente el patrón que
  `checkpoint-3t.md` ya prohibía bajo la frase "revisar si X respondió", pero mi frase no la usaba
  literal y la regla no disparó → reescrita como pregunta explícita a hacerse antes de fijar
  cualquier `<next-step>` de los casos 2-4, y el `<next-step>` de esta misma ficha bajado al caso 4
  (`p-a4439fa8fd` a `Sigue abierto`).
- Segundo `## Como retomar` de ESTA ficha cayó al caso 4 genérico ("revisar _pendientes.md y
  proponer siguiente prioridad") → es el síntoma exacto de "fase 7": había trabajo inmediato
  (resolver el defecto recién visto), pero lo di por cerrado con 2.32.1 (solo prosa) y nunca lo
  registré como pendiente, así que la escalera no tenía candidato → registrado como `p-daf3051915`
  (Alta, sin fecha) y puesto como `Proximo paso`. Víctor lo señaló en vivo por segunda vez.
- Tercer y cuarto intento de entrega: pegué en la respuesta solo el recordatorio de calendario y
  dejé el snippet de trabajo inmediato dentro de un tool result, que el usuario no ve → es la
  OMISION que Step 8b ya declara como límite; "pega la salida del script" no la impide → queda
  dentro de `p-daf3051915` como defecto (4), con la opción de un hook Stop que audite la respuesta.

## Pendientes
RECONCILIACION: 3 de 109 pendientes abiertos revisados — 106 sin revisar, barrido en /triage-3t
- [ ] verificar en uso real que las dos reglas de prosa nuevas (variante del caso 5 del caso 1; pregunta explicita antes de fijar next-step de casos 2-4) se siguen de verdad — `p-e685e9c92a`
- [ ] verificar en instalacion real (claude-vzert) que los dos checks nuevos no dan falsos positivos fuera del corpus medido — `p-a4439fa8fd`

## Commits
- `33fb17b` — 2.32.0: dos checks nuevos cierran una regresion real del snippet de cierre en claude-vzert
- `59bc6e7` — 2.32.1: la regla contra pasos bloqueados por terceros ya no depende de una frase literal
- Git commit del checkpoint saltado: `memory/` está en `.gitignore` de este repo (`.gitignore:3`),
  así que Step 6 no tiene nada que comitear — la memoria de este proyecto vive solo en disco, no
  en git (mismo caso documentado en la sesión 2026-09-19).

## Como retomar

```
Retomamos: /checkpoint-3t cometio en vivo, en su propio cierre, los 4 defectos que Victor ve en otros agentes.

Lee memory/sessions/2026-09-22-snippet-cierre-regresion-claude-vzert.md para el contexto completo.

Proximo paso: ninguno — lo unico propio espera a otra instalacion.

Sigue abierto: p-a4439fa8fd verificar en instalacion real que los checks de 2.32.0 no dan falsos positivos, condicionado a que esa instalacion actualice · p-014255373e plan.upsert sin guardian de reversa · p-49996efc69 estado FINAL de 2.30.0 sin revisar por adversario · +5 mas en _pendientes.md.

No repitas: no des por resuelto un defecto con solo reescribir prosa — 2.32.1 no cubrio ninguno de los 4 y el siguiente cierre volvio a fallar. No confies en "pega la salida del script" como garantia: se omitio dos veces. No promuevas a Proximo paso algo que depende de otro proceso. Prueba cada check nuevo con casos adversariales construidos, no solo con el corpus real. Si codex exec falla dos veces seguidas, usa el subagente.

Terminas cuando: las 4 formas, reproducidas como fixtures desde el transcript 5790b9f2 (mas el borrador de pr238), ya no puedan cerrar un checkpoint sin que checkpoint-audit.py o un hook las marque — con tests en test-checkpoint-audit.sh, ronda de adversario y version nueva del plugin.

Antes de actuar, dime en 3 lineas donde quedamos.
```

## Recordatorios de calendario

### 2026-09-27 — [3-tier-memory] ¿Se siguen en la práctica las dos reglas de prosa del caso 1/Step 8?

```
─── Recordatorio para el 2026-09-27 ───
Ponlo en tu calendario:

Título: [3-tier-memory] ¿Se siguen en la práctica las dos reglas de prosa del caso 1/Step 8?

Descripción:
El 2026-09-22 se agregaron dos reglas de prosa en checkpoint-3t.md: (1) una variante del
caso 5 para cuando un plan activo está bloqueado por una fecha futura ya cubierta por el
calendario; (2) una pregunta explícita a hacerse antes de fijar cualquier <next-step> de
los casos 2-4 ("¿esto se puede hacer de inmediato, sin esperar acción de algo fuera de
esta sesión?"), reescrita después de que el propio agente de esa sesión violara la versión
anterior de esa regla en su propio cierre, minutos después de escribirla. Ninguna de las
dos es un check mecánico — el mismo tipo de regla que ya falló en silencio antes (el
hallazgo de "fase 7" que motivó toda la sesión). Ese día hay que revisar sesiones nuevas
de claude-vzert (u otro proyecto real) y confirmar si el agente siguió las dos reglas o
las volvió a violar con otras palabras.

Pega esto dentro del evento (es el prompt para el agente):
```
Proyecto: 3-tier-memory — /home/usuario/Projects/3-tier-memory
Retomamos: verificar si las dos reglas nuevas del caso 1/Step 8 se siguen en la practica _id: p-e685e9c92a_
Contexto: memory/sessions/2026-09-22-snippet-cierre-regresion-claude-vzert.md
Comprueba: busca en sesiones reales de claude-vzert (u otro proyecto con el plugin actualizado a 2.32.1+) (a) un plan activo con ## Estado bloqueado por fecha futura ya cubierta por el calendario — el snippet debe usar la media-linea "ninguno — <plan> Fase <N> esta bloqueada...", no repetir la accion completa; (b) un <next-step> de los casos 2-4 que dependa de que algo FUERA de la sesion actue o decida (un peer, otra instalacion, un PR ajeno) — no deberia estar en Proximo paso, sino en Sigue abierto o fuera del snippet. Si cualquiera de las dos se viola, decidir si vale la pena un check mecanico (aunque signifique acercarse al juicio semantico que la regla 216 prohibe) o reforzar la prosa otra vez.
Si ya no aplica, cierralo con /checkpoint-3t en vez de dejarlo abierto.
```
────────────────────────────────────
```

## Related
- [[_session-index]]
- [[_pendientes]]
- [[_learnings]]
