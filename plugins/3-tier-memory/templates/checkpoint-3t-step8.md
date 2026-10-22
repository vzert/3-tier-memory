<!-- Step 8 de /checkpoint-3t. Lo imprime el propio checkpoint (`cat` de este fichero desde
templates/, junto a checkpoint-3t.md); no es un comando: session-start.sh no lo instala en
.claude/commands/. Separado en 2.42.0. -->
## Step 8: Como retomar — snippet de continuidad

Genera un prompt breve y autosuficiente que el usuario pueda copiar y pegar al iniciar la proxima sesion (despues de `/exit` o `/clear`) para retomar contexto sin pensar.

**Si el caso 5 de `<next-step>` aplica (mas abajo), NO generes el bloque completo — mismo
principio que Step 8c con los recordatorios de calendario: una seccion condicional que no aplica
se omite entera, no se rellena con placeholders.** 2026-09-14, el propio usuario lo senalo sobre
un caso real: un bloque con `Retomamos: ninguno` / `Proximo paso: ninguno` / `Antes de actuar...`
para una sesion que no dejo nada que retomar es la misma ceremonia vacia que el bloque de
calendario existe para evitar — mas ruido que senal. Ver la instruccion alternativa en 8a y 8b.

**Un pendiente Alta del backlog general (sin relacion con el trabajo de esta sesion) NO es motivo
para generar el bloque completo cuando el caso 5 aplica.** Caso real (2026-09-17, proyecto
`claude-vzert`, via `/goalspec:interview`): con 89 pendientes abiertos y 5 en Alta, siempre hay
alguno suelto que calificaria para la antigua linea `Sigue abierto` — la excepcion anterior ("si hay un Alta que
agregar, bloque completo") volvia inalcanzable el colapso a una linea en la practica, justo cuando
la sesion no dejo nada accionable hoy (los unicos pendientes de esa sesion tenian `_revisar`
futuro y ya su propio recordatorio de calendario). Ese backlog Alta ya lo muestran otros canales (el
sidebar de pendientes a la persona, el recall por peticion al agente y `/triage-3t`; desde 2.63.0 el
hook de inicio de sesion ya no los muestra) — no hace falta repetirlo en un
bloque pensado para "copia y pega esto en una sesion nueva, ahora mismo". El caso 5 colapsa a una
linea sin excepcion (ver 8a).

**Plantilla de 6 lineas: 4 obligatorias y 2 condicionales**:

```
Retomamos: <contexto-1-linea>.

Lee memory/sessions/DATE-SLUG.md para el contexto completo.

Proximo paso: <next-step>.

No repitas: <callejones sin salida>.                      <- omitir si no hubo

Terminas cuando: <done-bar>.                              <- omitir si no aplica

Antes de actuar, dime en 3 lineas donde quedamos.
```

**Linea en blanco entre cada campo, siempre** (2026-09-14, hallazgo del propio usuario sobre un
snippet real): 5-7 lineas pegadas sin separacion se leen como un parrafo cortado por el fence, no
como instrucciones distintas — cuesta el doble de alto pero se escanea de un vistazo, y un LLM lee
igual de bien instrucciones separadas por blanco. Aplica a los TRES bloques de este step (8a, el
ejemplo, y 8b) por la misma regla de "identicos" de mas abajo.

Reglas para llenar los slots:

- `<contexto-1-linea>`: una frase que describa el trabajo principal de la sesion (max 90 chars).
  Toma como base la primera linea de ## Contexto del session file. **Si aplica el caso 1 de
  `<next-step>`** (plan activo con `## Estado`), la frase nombra el PLAN y la fase en vez de la
  sesion de hoy: `<titulo del plan> — Fase <N> (<nombre de la fase>)`. Es la primera linea que se
  lee, y en una tarea de fases es la que responde "que estabamos haciendo" y "es parte de un plan
  mayor" de un vistazo — sin esto, un humano que solo lee `Retomamos:` (no el resto del snippet)
  ve el recorte de HOY, no el trabajo completo del que es parte. Mismo principio que el `Titulo:`
  de los recordatorios de calendario (Step 8c): legible sin abrir nada mas.

  **Si ADEMAS ese plan tiene `--parent`** (es hijo de otro, sin importar cuantos niveles subiste
  para llegar a el — ver el caso 1 de `<next-step>`, mas abajo), la frase suma el padre inmediato:
  `<titulo del plan> — Fase <N> (<nombre>) — hijo de <titulo del plan padre>`. Una sola linea seguia
  siendo una sola linea — esto NO agrega una linea nueva al snippet de 6, extiende la misma
  `Retomamos:` que ya existia. Si sumar el padre rompe el limite de ~90 caracteres, el que se
  acorta es el nombre del padre (o se omite entero), nunca el nombre del plan propio ni la fase:
  esos son los que el lector necesita para actuar hoy.
- `<next-step>`: la accion mas inmediata pendiente, en orden de preferencia:
  1. **Si esta sesion toco un plan `active` que tiene bloque `## Estado`** (ver Step 5), el
     `<next-step>` es `<Proxima accion del bloque> (plan-<slug>)`, ya actualizado con lo que esta
     sesion resolvio — NO el pendiente suelto de mayor prioridad, aunque exista uno. **Empieza por
     el verbo de la accion** (`Medir…`, `Correr…`), nunca por `Fase actual: <N> — <estado>`: la fase
     ya esta en `Retomamos:` (mas arriba), y repetirla con su estado ("APLICADOS; falta medir")
     delante hacia que la primera palabra del paso fuera estado y no accion (forma comun en otro
     proyecto, medida 2026-10-13). Cita el `plan-<slug>`: es lo que `checkpoint-audit.py` usa para
     reconocer el caso 1 desde 2.56.0, si el plan esta `active` (antes, el prefijo `Fase actual`).
     Por que va primero: medido 2026-09-14, un pendiente suelto relacionado con un plan de fases es
     casi siempre UN PASO de la fase, no la fase completa — anteponerlo pierde el orden que el plan
     ya tiene. Si el plan no tiene `## Estado` todavia (uno viejo, sin retro-adaptar),
     cae al caso 2 como cualquier sesion sin plan.

     **Si la `Proxima accion` del `## Estado` no se puede empezar hoy porque espera una fecha
     futura** (nombra un dia posterior a hoy, o una hora de un dia posterior: "el 2026-10-14
     despues de las 11:51 UTC"), aunque traiga mas cosas que hacer ese dia: ese trabajo es del
     recordatorio de calendario, no del snippet. (1) Si no hay ya un pendiente con `_revisar` en
     esa fecha, registralo en Step 3b con `--revisar <fecha>` y `--relacionado plan-<slug>`, para
     que Step 8c genere su recordatorio; su `Comprueba:` lleva lo que el `<next-step>` habria
     dicho (que medir, contra que, el criterio de `Terminas cuando` y lo que `No repitas` habria
     avisado), asi el prompt del evento es el snippet completo de ese dia. (2) El slot NO repite
     esa accion: pasa a `ninguno — <plan> Fase <N> esta bloqueada hasta <fecha>, ver Recordatorios de calendario`
     (mismo formato de media linea que ya usa la variante de casos 2-3 mas abajo). La regla de mas
     abajo ("la escalera descarta candidatos con `_revisar` futuro") se escribio pensando en casos
     2-3 y nunca se extendio a este caso 1 — medido en `claude-vzert` (2026-09-18 y 2026-09-21, dos
     sesiones reales): el caso 1 imprimio integro el texto de una `Proxima accion` fechada a futuro
     (el script exacto a correr, la fecha, el criterio), y el snippet pensado para "copia y arranca
     AHORA" termino siendo una copia del recordatorio que Step 8c ya iba a mandar por separado.
     Volvio a pasar el 2026-10-13 (otro proyecto) con una accion mixta
     ("APLICADOS; falta medir. El 2026-10-14 despues de las 11:51 UTC: medir el respaldo…"): la regla
     decia "integramente esperar" y la accion no lo era. Desde 2.56.0 basta con que la accion
     espere una fecha futura, y `checkpoint-audit.py` marca `SALTADO` un `Proximo paso` que nombre
     una fecha `AAAA-MM-DD` posterior a la de la ficha (salvo `ninguno`/`nada accionable` y un
     plazo como "antes del …"). Escribe la fecha en ese formato: "manana" o "14-oct" no los ve. Y
     si escribes `ninguno …`/`nada accionable hasta <fecha>`, el audit exige que el pendiente de ese
     dia este abierto con `_revisar: <fecha>` y ligado al paso: citado en la linea, o como `_id` de
     `Retomamos:` en el bloque `### <fecha>` de esta ficha (o en su linea `ya agendado para`).

     **Esto es una variante MAS del caso 5, no un mecanismo nuevo de colapso** — mismo principio
     que la variante ya documentada para casos 2-3 mas abajo ("Tambien aplica cuando..."): si,
     ADEMAS de que la `Proxima accion` es puro futuro, no queda ningun pendiente PROPIO de esta
     sesion que se pueda hacer ya (sin `_revisar` futuro y sin `_bloqueado:`, salvo el bloqueado
     cuyo `_revisar` ya paso: ese toca mirarlo, 2.63.32), entonces `<next-step>` en su conjunto ES el caso 5, y
     8a colapsa el bloque a una linea con la media-linea de arriba como motivo — el MISMO mecanismo
     de 8a, sin condicion nueva que agregarle ahi. **Un pendiente Alta de OTRA sesion, sin relacion
     con esta, no cuenta para esta cuenta** — mismo criterio que ya rige el colapso general (ver
     mas arriba, "Un pendiente Alta del backlog general... NO es motivo para generar el bloque
     completo"): ese backlog ya lo muestran el sidebar de pendientes y el recall por peticion, y exigirlo aqui volveria el
     colapso inalcanzable en la practica, el mismo defecto que 2.25.9 ya cerro para casos 2-3. Si en
     cambio queda un pendiente propio que se puede hacer ya, el caso 5 no aplica (sigue siendo el
     caso 1, no colapsa): el bloque completo de 6 lineas se genera igual, con la media-linea de
     arriba en `Proximo paso` y el resto normal.

     **"Toco" incluye el plan padre que actualizaste por la regla de subir de Step 5, no solo el
     plan que era el tema explicito de la sesion.** Hallazgo adversarial (2026-09-14): si el
     trabajo de hoy fue CERRAR un hijo, ese hijo mismo ya no esta `active` — leer el caso 1 en
     sentido literal ("el plan que la sesion toco") sobre el hijo cerrado hace que el caso NO
     aplique justo cuando mas hace falta. El plan correcto a leer es el PADRE: dejo de estar
     `active` con `## Estado` viejo para estarlo con `## Estado` actualizado por el paso 2 de la
     regla de subir — ese conteo como "el plan que esta sesion toco" para este caso, tan valido
     como si hubieras trabajado en el directamente.

     **Si el plan que da el `<next-step>` quedo sin trabajo propio Y tiene `--parent`** (subiste
     al padre en Step 5 y no encontraste otro hijo abierto ahi tampoco todavia), sube otra vez y
     usa el `## Estado` de ESE padre. Repite mientras haga falta — es la misma regla de Step 5,
     aplicada al armar el snippet en vez de al cerrar el evento. Por esta via de escalar
     padre/hijo, el caso 5 (`ninguno`) solo aplica si subiste hasta la raiz y la raiz tambien esta
     sin trabajo abierto, nunca porque el hijo de hoy ya cerro — esto no excluye la OTRA variante
     de caso 5 de este mismo caso 1 (plan bloqueado por fecha futura, unas lineas arriba): las dos
     son condiciones independientes que, si se cumplen, hacen que `<next-step>` sea el caso 5.

     **Si al subir encuentras un padre SIN bloque `## Estado`** (uno viejo, sin retro-adaptar —
     el caso real de varios planes del port al VPS), NO sigas subiendo asumiendo que esta bien:
     no hay forma de leer su estado con confianza. Detente ahi y cae al caso 2 de esta misma
     escalera (pendiente suelto), igual que si nunca hubiera habido plan. Seguir subiendo mas alla
     de un eslabon sin `## Estado` es la misma apuesta que inventar un `<next-step>` — mejor admitir
     el limite que fingir que se leyo algo que no estaba.

     **El hermano que sigue lo da `plan-siguiente-hermano.py`** (2.55.0; ver Step 5, "Subir en el
     arbol"): con `SIGUIENTE plan-<x>`, el `<next-step>` es el `## Estado` de `plan-<x>` (o, si no
     lo tiene, `Abrir plan-<x>: <su titulo>`), y el `Proximo paso:` cita `plan-<x>` para que la
     linea de afines traiga los pendientes ligados a ese plan. `SIN-ORDEN` es el caso de abajo.

     **Si el padre (o cualquier nivel al que subiste) tiene mas de un hijo `active`/`draft`**, no
     elijas en silencio cual sigue — el orden es el de las FILAS de `## Sub-planes`, de arriba
     hacia abajo (esa tabla ya declara prioridad al escribirse: la fila mas arriba es la que sigue,
     como en `plan-hallazgos-piloto-2.25.0`). Si el padre no ordeno sus filas a proposito, dilo tal
     cual en el `<next-step>` (`hay N hijos abiertos sin orden declarado — decide cual primero`) en
     vez de escoger uno sin decirlo: una eleccion no determinista silenciosa es peor que admitir que
     falta el criterio. (El breadcrumb "hijo de <padre>" para este mismo plan ya se resuelve en la
     regla de `<contexto-1-linea>`, arriba — no se repite aqui.)
  2. **El primero del hilo** (2.57.0, p-b282a8cfc4, regla de Victor del 2026-10-13). Correlo:
     `python3 "$JBIN/pendientes_afines.py" "$SESSION_FILE" --hilo` (desde 2.61.0 marca
     `[no va de extra: <motivo>]` lo que no saldra en la linea de extras; ver abajo). El hilo es lo que la sesion
     recibio en su snippet (sello de 5c-bis), lo que nacio en ella y sus vecinos DIRECTOS por
     `_relacionado`, en cualquier direccion: un solo salto, y solo por ids abiertos (2.62.0, regla
     de Victor del 2026-10-15; reemplaza el "a cualquier distancia" de 2.57.0, que en un
     proyecto real llevo en 7 saltos a una sesion de indices al trabajo que llevaba otro
     agente). Solo lo que se puede hacer hoy. **Si el hilo sale vacio, el paso es el caso 5**
     (`ninguno — <motivo>, ver Recordatorios de calendario`): no lo llenes con trabajo de otro hilo
     o de otro agente, aunque sea Alta y este a la vista.
     Orden: prioridad; en empate el nuevo antes que el heredado, salvo un heredado que lleva 2
     sesiones seguidas sin ser el paso, que va primero. El paso recibido que no cerraste sigue ahi.
     `checkpoint-audit.py` (`snippet.hilo`) marca `SALTADO` un paso cuyo primer id sea de menor rango.
  3. **(Absorbido por el 2 en 2.57.0.)** "El existente de mayor prioridad relacionado con el trabajo"
     es ahora el hilo: si el hilo esta vacio, no hay caso 3; es el caso 5.

  **Extras del hilo (2.55.0, 2.57.0): no los escribas tu.** `<next-step>` sigue siendo UN item.
  `print-como-retomar.py` mete debajo, en vivo, `Si ese paso es corto, suma en la misma sesion: …`
  con hasta 2 del hilo fuera del paso (Alta > Media > Baja; la Baja solo si no queda Alta ni
  Media) y, si queda mas, `quedan N en el hilo: <ids>`. Esa linea la lee el sello de la sesion
  siguiente: lo que no entro vuelve por ahi, no por una lista que escribas. Asi un Media que una sesion dejo junto a un Alta vuelve en el snippet siguiente
  sin depender de que alguien se acuerde. Nunca suma uno con `_bloqueado:` cuyo `_revisar` no ha
  pasado (2.63.32: pasado, el paso es mirar si ya llego), con `_revisar` de hoy o futuro, ni (2.56.0) uno cuyo texto nombra una fecha `AAAA-MM-DD` posterior a hoy: eso no se
  puede hacer en la sesion siguiente (caso real: un pendiente Alta, "revision a 24 h desde el
  2026-10-14", sumado el 2026-10-13). **Desde 2.61.0 tampoco suma de extra** (va a `quedan N`):
  un id que tu snippet cita en `Terminas cuando:` o `No repitas:` (ya le diste un papel: "va
  aparte", "va en la siguiente supervision"), una prueba que solo pasa en uso real ("confirmar en
  vivo", "verificar en una instalacion real", "tras /reload-plugins") y uno que espera un OK o una
  decision ("falta OK de Victor", "cuando Victor decida", "pedir permiso"). Es una red de formato
  por palabras, decidida por Victor el 2026-10-15 sobre 35 extras medidos: los que se cerraron eran
  todos tareas de codigo o doc, y los de espera o en vivo no cerraron ninguno y causaron las
  preguntas. La via que cuenta sigue siendo el campo: `_bloqueado:` o `--revisar` al crearlo
  (Step 3b). Si quieres que un pendiente viejo entre, ligalo en Step
  3a con `pendiente.relate`; no lo agregues a mano al snippet. Quien retoma decide si el paso es
  corto: ningun campo lo dice, y el script no lo adivina por el texto (regla 216).

  **Como se escribe el `<next-step>` (2.60.0, marco que Victor acepto el 2026-10-13).** Elegido el
  candidato con la escalera, redactalo asi:
  1. **Una accion que se pueda empezar hoy**, con su id. La accion empieza con un verbo
     ("arreglar…", "medir…", "decidir…"). Sin `Fase actual`.
  2. **Un solo objetivo.** Lo demas del hilo va en la linea de extras que imprime el script, no
     dentro del paso ("y de paso…", "en paralelo…" son un segundo paso).
  3. **Sin ramas.** Nada de "si pasa X, haz Y; si no, Z". Si hay que decidir antes, el paso es
     "decidir X" y las opciones van en la ficha.
  4. **Sin historia.** El porque, el estado y las comprobaciones previas ("Antes: (1) leer…, (2)…")
     van a `## Estado` o `## Contexto` de la ficha; el snippet ya manda leerla. `No repitas` queda
     para callejones sin salida.
  5. **Sin esperas de Victor ni de terceros** (p-3d1c7ab131): un paso que espera a que alguien
     decida para luego actuar ("publicar si Victor lo decide") no es paso. Si lo que espera es una
     decision **del usuario**, el paso es esa decision: `decidir con el usuario <que> (p-…)`, como
     en la regla 3; nunca `_bloqueado:` (2.62.11). Si espera una decision o accion de un tercero,
     de fuera de la sesion, ponle `_bloqueado:` al pendiente y baja por la escalera (ver la pregunta
     de mas abajo).
  6. **Palabras simples:** el usuario tambien lo lee.
  7. **Unos 300 caracteres**, como guia y no como tope. Los umbrales acordados (el parrafo "Incluye
     aqui los umbrales…", mas abajo) si caben.
  Medido sobre los 163 snippets con una segunda respuesta util del usuario (de 211; research
  `hilo-pendientes-relacionados-medicion`, Anexo 2): con un paso
  limpio el usuario tuvo que aclarar o corregir en el 8 % de los casos; con una espera suya, 27 %;
  con varias tareas, 22 %; con ramas, 67 % (3 casos). El largo va junto con la complejidad, asi que
  es guia y no regla. `checkpoint-audit.py` (`snippet.marco`) avisa como `POR-DISEÑO`, nunca como
  `SALTADO`, cuatro senales de formato: una espera escrita solo en el texto ("si Victor lo decide",
  "pedir permiso", "cuando X responda", "revisar si X respondio"), 2 o mas ids (sin contar "ver
  tambien"), una lista "(1)… (2)…" y mas de 600 caracteres. `checkpoint-close-guard.sh` mete esos
  avisos en la revision del cierre: rehaz el paso o di en su ultima linea por que se queda asi. Son
  redes de formato (regla 216): un aviso puede ser falso, y su silencio no prueba que el paso
  cumpla el marco.

  **Ningun candidato de los casos 2 o 3 es valido si su unico dato accionable es una fecha futura**
  — trae `_revisar: YYYY-MM-DD` posterior a hoy en `_pendientes.md`, el mismo campo que Step 8c ya
  lee para generar su propio recordatorio de calendario. Un pendiente asi no es accionable hoy sea
  cual sea su prioridad: tratalo como si el caso no aplicara y sigue cayendo por la escalera (al
  otro candidato del mismo caso si hay mas de uno, o al siguiente caso). Caso real (2026-09-15,
  proyecto `cloudflare-expert`): el `<next-step>` elegido fue `confirmar el 2026-09-16 que...`
  sobre `p-b106ce03d9` (`_revisar: 2026-09-16`) — identico al recordatorio de calendario que el
  mismo Step 8c genero para esa fecha en la MISMA sesion. Sin esta regla, `Como retomar` es una
  replica del bloque de calendario: no le dice a la sesion siguiente nada que el calendario no
  fuera a decir ya, y un usuario despistado copia el snippet y arranca una sesion sin nada que
  hacer hoy. No excluye un `_revisar` YA VENCIDO (fecha igual o anterior a hoy) — eso ya paso su
  ventana y vuelve a ser un pendiente normal para el caso 3.

  **Este paso NO intenta detectar ni corregir, por su cuenta, un pendiente viejo "esperar y luego
  revisar" que se creo sin `_revisar` antes de que existiera la regla de Step 3b de abajo.**
  Hacerlo aqui exigiria juzgar por el texto si el pendiente "es de ese tipo" — exactamente la
  clasificacion por prosa que la regla 216 de `learnings/3tier-memory-system.md` ya prohibe para
  este mismo Step (verificado por adversario, 2026-09-16: un primer intento de "red de seguridad"
  aqui, gateada por `_creado != hoy`, seguia dependiendo del mismo juicio semantico y violaba esa
  regla). Un pendiente asi se trata como cualquier otro sin `_revisar` (compite por prioridad,
  casos 2-3) hasta que `/triage-3t` u otra revision manual del backlog le asigne fecha — no es
  responsabilidad de este Step arreglar datos que otro paso dejo mal formados.
  4. **(Quitado en 2.33.0.)** Era `revisar _pendientes.md y proponer siguiente prioridad`, una
     salida generica sin guardia. En la sesion 5790b9f2 de este repo el agente la tomo teniendo
     trabajo propio sin cerrar: el defecto que el usuario acababa de senalar en vivo, "arreglado"
     solo con prosa y nunca registrado como pendiente, asi que la escalera no lo veia. Ahora no
     hay caso 4. O hay un candidato real de los casos 1-3, o es el caso 5. Si el trabajo existe
     pero no tiene pendiente, **proponlo en Step 3b**: si el usuario lo guarda, sera el caso 2; si
     lo descarta, no es trabajo registrado y no va aqui. `checkpoint-audit.py`
     marca `SALTADO` en `snippet.proximo_paso` si la linea empieza por ese texto.
  5. **Si la sesion genuinamente no dejo trabajo que retomar** (una sesion de reporte, de
     verificacion puntual, o que se cerro sola) — no hay pendiente nuevo, no hay uno relacionado,
     y "revisar _pendientes.md" seria un placeholder vacio, no una pista real — dilo tal cual:
     `ninguno — <en media linea, por que esta sesion se cierra sola>`. Antes de declararlo,
     preguntate si esta sesion encontro algun defecto o trabajo que no quedo cerrado y
     verificado. Si lo hay y no lo propusiste en Step 3b, este caso no aplica: vuelve a Step 3b.
     Si lo propusiste y el usuario lo descarto (`_descartado:` en `## Bugs fixed`), si aplica.
     `checkpoint-audit.py` marca `SALTADO` en `snippet.ninguno_defecto` un `ninguno` con un
     `_pendiente:` de `## Bugs fixed` abierto e inmediato (2.34.0).

     **Tambien aplica cuando el UNICO candidato que encontraste en 2 o 3 quedo excluido por la
     regla de `_revisar` futuro de arriba, y no hay otro sin fecha que lo reemplace** — no es lo
     mismo que "no hay nada", pero el efecto para HOY es identico: nada que la sesion siguiente
     pueda avanzar antes de esa fecha. La media-linea de motivo lo dice tal cual, señalando el
     bloque de calendario: `ninguno — lo unico abierto de este hilo tiene fecha futura, ver
     Recordatorios de calendario`. Ejemplo: si la sesion del 2026-09-08 no hubiera dejado el
     pendiente suelto sin fecha `p-9445bed4b6`, el texto habria sido `ninguno — el snapshot semanal
     de SQL-LIVE y la confirmacion de N8n-Crons ya tienen su propio recordatorio (09-16, 09-20)`.

     **Tambien aplica, por la misma razon, cuando el candidato es el caso 1** (plan activo con
     `## Estado`) y su `Proxima accion` espera una fecha futura ya cubierta por el calendario, sin ningun otro pendiente propio de esta sesion que se pueda hacer ya — ver el
     parrafo de esa variante en el caso 1, arriba, para el detalle y el ejemplo real.

     **Antes de declarar este caso, relee la seccion `## Pendientes` que este mismo Step ya
     escribio (3a/3b) de ESTE archivo.** Si queda algun `- [ ]` sin marcar ahi **y su id, buscado en
     `_pendientes.md`, trae `_revisar` vencido o ningun `_revisar`**, este caso no aplica — es el 2
     o el 3. El `_revisar` se mira en `_pendientes.md` porque la linea de `## Pendientes` de la ficha
     solo guarda texto e id (plantilla de Step 3d): ahi el campo nunca aparece, y leerlo ahi haria
     pasar por "sin `_revisar`" a todos. Caso real (2026-09-15):
     una sesion declaro `ninguno` con un pendiente Alta recien creado a la vista en su propia
     seccion `## Pendientes` — el atajo salto directo a este caso sin pasar por el 2, y el
     pendiente se perdio del snippet hasta que se audito el jsonl a mano en una sesion posterior.
     **No es excusa para NO declarar este caso** un pendiente Alta que no sea de esta sesion ni
     este relacionado con ella — ese puede salir en el prompt opcional de Step 8e, no cambia el
     veredicto de `<next-step>`. **Si TODOS los `- [ ]` sin marcar traen `_revisar` futuro** (en `_pendientes.md`), la relectura no
     bloquea el caso 5 — es exactamente la variante de arriba ("Tambien aplica cuando..."), no una
     excepcion a esta regla.

  **Cuando aplica el caso 1**, la linea `Lee memory/sessions/DATE-SLUG.md para el contexto
  completo.` de la plantilla (mas abajo) se extiende con la ruta del plan:
  `Lee memory/sessions/DATE-SLUG.md para el contexto completo, y memory/plans/plan-<slug>.md
  para el resto de las fases.` — el snippet ya probo (sesion 2026-09-14-bloque-b, medida en la
  entrevista que origino este cambio) que nombrar el archivo del plan sin que `<next-step>`
  leyera su estado no bastaba; ahora que si lo lee, la referencia al archivo completo sigue
  haciendo falta para el resto de las fases que no caben en una linea. Fuera del caso 1, la
  linea queda como siempre, sin la segunda clausula.

  **En los casos 2 y 3, la linea `Proximo paso:` cita el `_id: p-…_` del pendiente** (desde
  2.33.0). Fuera del caso 1 (cita un `plan-<slug>` enlazado en `## Plans`) y del caso 5
  (`ninguno — …`), un paso sin id es trabajo que nunca se registro. `checkpoint-audit.py` lo
  marca `SALTADO` en `snippet.proximo_paso`, igual que un id que no esta abierto en
  `_pendientes.md`, uno con `_revisar` futuro, uno con `_bloqueado:` cuyo `_revisar` no ha pasado
  y (2.56.0) un paso que nombra
  una fecha `AAAA-MM-DD` posterior a la de la ficha, en cualquier caso, el 1 incluido. Tambien marca `ninguno`
  cuando la ficha deja un pendiente propio abierto, sin `_revisar` futuro y sin `_bloqueado` (o
  bloqueado con su `_revisar` ya pasado, 2.63.32).

  **Antes de fijar cualquier candidato de los casos 2 o 3 como `<next-step>`, hazte la
  pregunta explicita: "¿esto se puede hacer de inmediato, en la sesion siguiente, sin esperar una
  decision o accion de alguien o algo FUERA de esta sesion?"** Si la respuesta es no, ese
  candidato no es un `<next-step>` — es un pendiente futuro (con `--revisar` si depende de que
  pase tiempo, o con `_bloqueado:` y fuera de `Proximo paso` si depende de una decision, accion
  o condicion ajena), y el siguiente candidato de la escalera (o el caso 5, `ninguno`) es el que
  corresponde. **El usuario no esta FUERA de la sesion** (2.62.11): un pendiente que espera una
  decision suya se hace de inmediato, en la sesion siguiente, con el agente al lado. Es un
  `<next-step>` normal: `Proximo paso: decidir con el usuario <que decisiones, y donde estan
  escritas> (p-…)`, una pregunta por decision con su recomendacion. Nunca lleva `_bloqueado:` y
  nunca colapsa el snippet al caso 5: un `Ninguno` que esconde decisiones del usuario le quita la
  unica forma de verlas (caso real, claude-vzert 2026-10-16, `p-341fdf5e59`). El audit lo avisa en
  `snippet.ninguno_bloqueo` y el hook de cierre lo pregunta en la revision. Desde 2.63.22 el audit
  avisa tambien (`snippet.paso_compartido`, POR-DISEÑO, no suma un rechazo) si otra ficha del mismo
  dia ya deja tu mismo `p-…` como `Proximo paso`: pregunta a esa sesion por SendMessage si lo
  lleva; si lo lleva, rehaz tu paso o usa `ninguno — lo lleva <ficha>` (caso real de otro proyecto,
  2026-10-20, dos cierres con 23 s de diferencia). **Desde 2.33.0 esta pregunta tiene respaldo mecanico, pero solo si el pendiente
  lleva el campo**: nace con `--bloqueado-por "<que espera>"` (Step 3b) o se lo pone
  `pendiente.block` (Step 3a), y entonces el audit rechaza citarlo en `Proximo paso` hasta que
  pase su `_revisar`, que desde 2.63.32 todo bloqueado lleva (hoy+5 si nadie dijo otra fecha; ver
  Step 3b, "Todo bloqueado lleva fecha"). Si para que se mueva hace falta que el usuario le pida
  algo a alguien, preguntale si lo pedira el: si dice que si, no es bloqueo y el paso es
  `pedirle a <quien> <que> (p-…)`. El juicio de
  "esto espera a un tercero" se hace al CREAR el pendiente, no al leer su texto aqui (regla 216:
  nunca clasificar por prosa). Desde 2.60.0 una espera escrita solo en el texto del paso, sin el
  campo, sale como aviso `POR-DISEÑO` en `snippet.marco` (punto 5 del marco, arriba). Es una red de
  formato que no bloquea; el campo sigue siendo la via que el audit hace cumplir.
  Esta pregunta no es un ejercicio retorico: se salto DOS veces, en dos formas de superficie
  distintas, y la segunda ocurrio en la propia sesion que escribio esta regla mas amplia — la
  variante estrecha de abajo no bastaba porque el patron con otras palabras no la disparaba.

  **Sintoma mas comun, para reconocerlo aunque no use estas palabras exactas: "revisar si X
  respondio/actuo"**, cuando X es un agente, persona o proceso FUERA de esta sesion (un peer, un
  mantenedor ajeno, un PR de otro repo, OTRA instalacion que tiene que actualizar algo). Escribirlo
  como si fuera un paso accionable le hace perder tiempo a quien lo lea despues. Dos casos reales:
  2026-09-14, "revisar si goal-spec-skill-7d respondio" en vez del caso 5, `ninguno`; 2026-09-22,
  esta misma sesion (`2026-09-22-snippet-cierre-regresion-claude-vzert`) promovio a `Proximo paso`
  un pendiente formulado como "verificar... una vez OTRA instalacion actualice el plugin" — mismo
  defecto, palabras distintas, sin la frase literal "revisar si X respondio" que la version
  anterior de esta regla buscaba. El usuario lo senalo en vivo, en el propio cierre del cambio que
  arreglaba justo esta clase de fallo en otro proyecto. El seguimiento no es una linea de este
  snippet: es el `_revisar` del pendiente bloqueado (2.63.32). Ese dia sale en el aviso 🔔 del
  cierre y, pasada la fecha, vuelve al hilo como "mirar si X ya llego". Sin esa fecha el pendiente
  no volvia a salir nunca (caso real `p-98a561dc02`, claude-vzert 2026-10-20).

  Incluye aqui los umbrales o criterios que ya se acordaron en esta sesion (un numero, un limite,
  una condicion de exito), si los hay. Sin ellos la sesion siguiente los vuelve a negociar contigo.
- **(Quitado en 2.35.0) la linea `Sigue abierto:`.** Listaba ids de los pendientes de la sesion
  y de los Alta de otras sesiones. Victor (2026-09-23) la senalo como inutil en los dos extremos:
  el agente que recibe el snippet solo actua sobre `Proximo paso`, y al humano una lista de ids no
  le da nada que hacer. Los pendientes propios siguen en `## Pendientes` de la ficha, que la linea
  `Lee …` manda leer. Lo que se podia hacer ya con esa lista lo cubre ahora el prompt opcional de
  **Step 8e**: un prompt completo para otra sesion, sobre un pendiente que vence hoy o uno vencido.
  La medicion que la sostenia (2026-09-11: los pendientes mencionados en el snippet cerraban el 35%
  frente al 19%) no separaba el efecto de la linea del hecho de que el agente elige para el snippet
  lo que ya ve mas accionable; `p-cd965754ec` se redefinio para medir el prompt opcional.
  Las fichas escritas antes del 2026-09-23 conservan su linea y el audit las mide como antes.

- `<callejones sin salida>`: **copia condensada de la seccion `## Callejones sin salida`** del
  session file, solo los que afectan al proximo paso. **Si el session file no tiene esa seccion**
  (lo escribio una version anterior a 2.12.2, o un /backfill-3t anterior a 2.15.1), no la
  crees ni migres nada: omite la linea `No repitas:` y sigue. El resto del snippet no depende
  de ella. Una linea, con el "que hacer en su lugar"
  incluido: `X no funciona porque Y — usa Z`. **Omite la linea entera si esa seccion dice "Ninguno"**
  o si ningun callejon toca el proximo paso; no la rellenes con ruido. Esta es la linea que evita
  que la sesion siguiente repita, a tu costa, el camino que ya se descarto.
- `<done-bar>`: cuando se considera terminado el proximo paso — el entregable concreto y su limite
  de alcance (`un veredicto con numero, sin implementar el resto del plan`). Sacalo del plan si hay
  uno, del criterio de aceptacion si existe, o de lo que el usuario pidio. **Omite la linea si el
  proximo paso es exploratorio** y su final no se puede nombrar de antemano: un done-bar inventado
  es peor que ninguno, porque la sesion siguiente lo trata como acordado contigo.

La ultima linea `Antes de actuar, dime en 3 lineas donde quedamos.` es INVARIABLE — fuerza al agente
de la siguiente sesion a leer el session file y confirmar contexto antes de tocar nada. Va siempre al
final, sola, aunque se omitan las condicionales.

**Por que estas dos lineas.** Las tres originales transmitian solo lo que salio bien. Un snippet que
dice donde quedamos pero no que ya se descarto hace que la sesion siguiente vuelva a intentar el
enfoque muerto — y uno sin done-bar la deja expandirse hasta que el usuario la corta a mano. Son
condicionales, no opcionales: si la informacion existe, la linea va.

**8a. Persistir en el session file**:

**Si el caso 5 aplica** (la sesion no dejo trabajo que retomar, en ningun lado; una decision del
usuario que sigue abierta es trabajo que retomar), reemplaza el
placeholder `<filled in Step 8>` con UNA linea, sin bloque de codigo — sin excepcion por
pendientes Alta del backlog general (esos no entran aqui: los muestran el sidebar de pendientes y el
recall por peticion, y uno de ellos puede salir en el prompt opcional de Step 8e):

```markdown
## Como retomar

Ninguno — <la misma media-linea del caso 5: por que esta sesion se cierra sola>.
```

**En cualquier otro caso**, reemplaza el placeholder `<filled in Step 8>` de la seccion `## Como retomar` con el snippet dentro de un bloque de codigo (aqui con las dos condicionales presentes; omite la linea entera cuando no apliquen):

````markdown
## Como retomar

```
Retomamos: <contexto-1-linea>.

Lee memory/sessions/DATE-SLUG.md para el contexto completo.

Proximo paso: <next-step>.

No repitas: <callejones sin salida>.

Terminas cuando: <done-bar>.

Antes de actuar, dime en 3 lineas donde quedamos.
```
````

Ejemplo real, con las 6 lineas (sin `Sigue abierto:`, quitada en 2.35.0):

````markdown
```
Retomamos: plan v2.13.0 ratificado para que los pendientes dejen de ser un cementerio.

Lee memory/sessions/2026-09-09-pendientes-cementerio-plan.md para el contexto completo.

Proximo paso: medir en seco la precision del cierre por silencio sobre los 98 vencidos (umbrales ya acordados: >=90% de aciertos, cero cierres de items que pedian consultar un dato).

No repitas: clasificar los pendientes con un regex sobre su texto — fallo tres veces y un revisor rompio las tres; leelos y clasifica con criterio declarado.

Terminas cuando: haya un veredicto con numero (entra / no entra) y, si entra, el diseno de las tres senales de deteccion. Nada mas del plan en esa sesion.

Antes de actuar, dime en 3 lineas donde quedamos.
```
````

**8a2. Marcar para retomar el pendiente del `Proximo paso` (2.62.8)** — justo despues de 8a:

```bash
python3 "$JBIN/marcar-retomar.py" "$SESSION_FILE"
```

Pone `_retomar: HOY sessions/<slug>_` en cada `p-…` abierto que cite el `Proximo paso:` (lo que va
tras "ver tambien" no), por evento (`pendiente.retomar`) y compactando. El mod pendientes lo saca en
PLANES ACTIVOS (una fila por ficha, con si su sesion sigue abierta; no en VENCEN, que es solo de
`_revisar`) hasta que el pendiente se cierre, y el clic pega el snippet de esta ficha. Asi un snippet que no se pego —pane cerrado, olvido— no se
pierde entre los demas pendientes (decision de Victor, 2026-10-16). Es un campo aparte de
`_revisar` a proposito: 8e, el hilo y el calendario lo ignoran, asi que no sale como 🔔 en el cierre
de otra sesion ni saca el pendiente del hilo. Si un id tiene `_revisar` futuro, no lo marca y lo
avisa con `⚠`: el `Proximo paso` no debe ser trabajo de fecha futura (regla de 8a), corrige el paso.
Un paso sin `p-…` (un plan, `ninguno — …`) no marca nada y no imprime nada. Su salida (`📌`, `·`,
`⚠`) no va en el cierre; si sale `⚠`, arregla el paso antes de 8b. La marca entra en el commit de
8f con lo demas. Si reescribes el snippet despues, vuelve a correrlo: la marca nombra esta ficha.

**8b. Imprimir al terminal — corre el script, no redactes el bloque otra vez**:

```bash
python3 "$JBIN/print-como-retomar.py" "$SESSION_FILE"
```

**Cuando lo pegas (2.43.0).** En un turno de `/checkpoint-3t` **no pegues todavia** la salida de
8b, ni la de 8e, ni la de 8c. Corre el script igual: comprueba que 8a lleno la seccion. Termina el
turno con el reporte de Step 7. Al terminar, el hook de cierre te pide la revision del cierre
(`REVISION DEL CIERRE:`; desde 2.59.0 en un archivo que su aviso te dice leer con Read). Tu respuesta a esa revision termina con estos bloques, en este orden,
**una sola vez y sin nada despues**: 🔁 snippet (8b), 🔔 o ➕ pendiente (8e) y 🗓️ calendario (8c),
cada uno solo si su script imprime algo (desde 2.44.0). El hook te da los comandos con la ruta
literal de la ficha. Asi el cierre es lo ultimo que ve el usuario y ya trae lo
que corregiste en la revision. Medido en los 4 cierres reales con revision (2026-09-30): pegado
antes de la revision, el snippet quedo enterrado bajo 2.400-4.300 caracteres en 2, y en 1 el agente
lo repitio. Fuera de `/checkpoint-3t` (por ejemplo, rehacer el snippet despues de cerrar un
pendiente que cita) no hay revision: pegalo en el acto, como ultimo bloque.

**Pega su salida tal cual, sin resumirla ni reformularla**, como el primer bloque del cierre. El
cierre (🔁 8b, 🔔/➕ 8e y 🗓️ 8c, en ese orden) va seguido y al final de tu respuesta; en
`/checkpoint-3t`, al final de tu respuesta a la revision del cierre. El script ya decide el formato
correcto por ti — `🔁 Como retomar: Ninguno — …` en una linea si el caso 5 aplica; si no, la
cabecera `🔁 Siguiente sesión — copia y pega:` y el snippet dentro de un fence ``` — leyendo el
MISMO `## Como retomar` que acabas de escribir en 8a. No existe una segunda redaccion que pueda
divergir de la primera, porque no hay una segunda redaccion: hay una lectura.

**Menos texto, un emoji por bloque, solo Retomamos en color (2.44.0).** Victor (2026-10-01),
mirando un cierre real: demasiado texto, y los mismos prompts opcionales se repetian sesion tras
sesion. Cada bloque abre con su emoji (🔁 retomar, 🔔 vence hoy, ➕ opcional, 🗓️ calendario) para
ver de un vistazo donde empieza, sin separadores `───` ni frases de introduccion. Solo el snippet va
en un fence, que en la terminal sale en color: es el bloque principal. El resto va sin fence.

**Por que un script y no "redacta lo mismo otra vez".** Medido en vivo (2026-09-15, este mismo
repo): el agente que acababa de escribir el bloque en 8a, en el turno siguiente, no lo repitio —
escribio su propio resumen en prosa en su lugar, con la instruccion de 8b (idéntica a esta,
antes de este cambio) presente y leida segundos antes. La instruccion en prosa "imprime lo mismo
que en 8a" no impidio que el agente sustituyera el bloque exigido por su propia sintesis, bajo la
idea de que un resumen mas legible era mas util. Comparar 8a contra 8b despues del hecho tampoco
sirve — un comparador a mano es un proxy, no el instrumento (ya diverge en este mismo repo el
contador de backfill, justo donde importaba). La unica version que no se puede saltar por
sustitucion es la que no le da al agente nada que redactar: correr el script y pegar su stdout.

Si el script sale con codigo 1 (`Step 8a todavia no lleno esta seccion`), 8a no corrio — vuelve
ahi antes de continuar, no improvises el bloque a mano.

**La OMISION la vigila un hook Stop desde 2.33.0 (`checkpoint-close-guard.sh`).** El script de
arriba elimina la SUSTITUCION: no hay nada que redactar. No eliminaba la OMISION: en la sesion
5790b9f2 el snippet salio solo en la salida del script (un tool result, que el usuario no ve), y
en otro cierre el recordatorio de calendario quedo "persistido en la ficha" sin pegarse. Al
terminar un turno que corrio /checkpoint-3t o `print-como-retomar.py`, que edito `## Como
retomar` de una ficha, o que cerro, caduco o bloqueo un pendiente citado en el `## Como retomar`
de una ficha de esta sesion (con `journal-emit.py` o con `expire-pendientes.py --apply`), el hook
exige varias cosas en el TEXTO de tu respuesta, nunca en un tool
result:
- cada linea que imprime `print-como-retomar.py`;
- cada linea que imprime `print-recordatorios.py` (los dos primeros recordatorios, sin fence, y
  `+N con fecha futura` si hay mas);
- que `checkpoint-audit.py --solo-snippet` no marque `SALTADO` sobre la ficha final. Step 7a corre
  antes que Step 8 y no ve el snippet.
- en un turno que corrio `/checkpoint-3t` (desde 2.41.0), la salida de Step 7a: la linea
  `resumen:` y cada `SALTADO` que el audit da sobre la ficha final, en su forma de salida.

Si falta algo, bloquea el cierre una vez y te dice que pegar o corregir. Limite: en el segundo
intento seguido ya no bloquea, para no entrar en bucle. Solo avisa al usuario. En un turno de
`/checkpoint-3t` el primer cierre no exige el snippet, 8e ni el calendario: la revision pide
pegarlos al final. El segundo cierre los busca solo DESPUES de `REVISION DEL CIERRE:`, y ademas
comprueba que van en orden (8b, 8e, 8c), que el snippet sale una sola vez ahi y que despues del
ultimo bloque no quedan mas de 300 caracteres (una linea corta). En una ficha desde el 2026-10-01
exige tambien la cabecera con emoji de cada bloque. Si algo de eso
falla, el aviso al usuario trae el cierre completo, tal como lo imprimen los scripts. Limite: si el
hook no corre (instalacion sin hooks), el cierre no se pega; queda en la ficha.

**El snippet no se congela al terminar el checkpoint (2.33.1).** Si DESPUES, en la misma sesion,
cierras, caducas o bloqueas un pendiente que el `## Como retomar` cita, el snippet que el usuario
ya tiene quedo viejo. Rehaz la linea afectada en la ficha, vuelve a correr `print-como-retomar.py`
y pega el snippet nuevo en esa misma respuesta. Caso real: tras el checkpoint de 2.33.0 se resolvio
`p-477bb60303` (el push) y la respuesta no aviso; el snippet seguia listandolo en `Sigue abierto`
(linea quitada en 2.35.0). Lo vigila el hook: dispara tambien en un turno que emite
`pendiente.resolve`, `pendiente.expire` o `pendiente.block` sobre un id citado en la ficha de esta
sesion, y en ese turno vuelve a exigir el snippet y el bloque de pendiente de Step 8e, que se genera en
vivo. En fichas anteriores al 2026-09-23 `checkpoint-audit.py` sigue marcando `SALTADO` en
`snippet.ids_vivos` si `Sigue abierto:` nombra un id que ya no esta abierto. Registrar un pendiente NUEVO tambien puede cambiar el snippet (un Alta nuevo gana
`Proximo paso`); eso no lo detecta ningun script: revisa la escalera y rehaz el snippet.

**Fallback (no JBIN)**: si `print-como-retomar.py` no existe (instalacion mas vieja que esta
version, o el sync de comandos aun no llego), redacta el bloque a mano copiando literalmente lo
que ya escribiste en 8a — el riesgo de divergencia por sustitucion de mas arriba aplica en ese
caso, asi que revisalo dos veces contra el session file antes de imprimirlo.

**8c. Recordatorio de calendario para los pendientes con fecha futura**:

Solo si esta sesion **dejo algo a futuro** (regla de Victor, 2026-10-01): un pendiente que esta
sesion creo, o cuya fecha cambio, y que **nombra una fecha posterior a hoy** — `revisar el
2026-09-22`, `target 2026-10-01`, `T+7`, `en 2 semanas` resuelto a fecha. Un pendiente que ya tenia
esa misma fecha agendada no genera bloque (ver "Un pendiente, un recordatorio vivo", abajo). Si no
hay ninguno, no hay bloque de calendario: no lo anuncies ni lo rellenes. Cada uno va en un bloque
aparte en la ficha (8c-2, **todos**, sin tope); en el cierre se pega lo que imprime:

```bash
python3 "$JBIN/print-recordatorios.py" "$SESSION_FILE"
```

Imprime los dos primeros **sin el fence** del prompt (solo Retomamos va en color) y, si hay mas,
`+N con fecha futura en _pendientes.md`. El tope es para no llenar la terminal.

**Un pendiente, un recordatorio vivo (2.39.2).** Antes de generar el bloque, busca si OTRA ficha
ya tiene un recordatorio con fecha futura para ese mismo `_id:`
(`grep -l "_id: p-…_" memory/sessions/*.md`, seccion `## Recordatorios de calendario`):
- **misma fecha y mismo alcance** → no generes bloque ni lo imprimas: el usuario ya lo agendo. En
  8c-2 escribe solo la linea `- p-… ya agendado para <FECHA> en [[sessions/<otra-ficha>]]`.
- **cambio la fecha o lo que hay que comprobar** → genera el bloque nuevo, reemplaza el bloque de
  la ficha vieja por `Reemplazado por el recordatorio de [[sessions/<esta-ficha>]]. No agendes
  este.`, y dile al usuario en el reporte que borre el evento viejo si ya lo agendo.
Caso real (2026-09-25): reconciliar un pendiente ya agendado re-imprimia su recordatorio, y
quedaron dos para el mismo dia, uno con el alcance viejo; `p-e685e9c92a` llego a tener tres.
`checkpoint-audit.py` (`calendario.duplicado_entre_fichas`) marca `SALTADO` cuando dos fichas
tienen bloque vivo para el mismo id.

**Va fuera del snippet, no dentro.** El snippet se pega al agente de la sesion siguiente; una
instruccion de calendario pegada ahi es ruido para el agente y se pierde para ti. Este bloque se
dirige a ti, y lo que lleva dentro del fence es un prompt para que TU lo guardes en el evento.

**La regla de division.** Una sola, y resuelve cualquier duda de donde va cada cosa:

- **Dentro del fence** va todo lo que el AGENTE necesita para actuar: el `Proyecto:`, el `_id: p-…`,
  la ruta del session file, las cifras y el criterio, y la clausula `Si ya no aplica, cierralo con
  /checkpoint-3t`.
- **Fuera del fence** va solo lo que TU necesitas para decidir si vale la pena abrir el portatil:
  Titulo —con el proyecto delante— y Descripcion.

Nunca subas el id al Titulo, nunca saques la clausula de cierre del fence.

**El proyecto es el unico dato que va en los dos lados, y no es redundancia.** Responde dos
preguntas distintas en dos momentos distintos: fuera del fence contesta *cual de mis recordatorios
es este* cuando miras el mes con recordatorios de varios proyectos encima; dentro contesta *desde
donde se corre esto* cuando pegas el prompt. Sin la linea de dentro, `Contexto:` es una ruta
relativa que no resuelve contra nada.

````
🗓️ Recordatorio para el <FECHA> — ponlo en tu calendario:

Título: [<proyecto>] <la pregunta que se responde ese dia, en una linea>

Descripción:
<2-4 lineas de prosa: que se construyo o decidio, por que, que se
decide ese dia, y que pasa segun el resultado>

Pega esto dentro del evento (es el prompt para el agente):
```
Proyecto: <proyecto> — <ruta absoluta del proyecto>
Retomamos: <pendiente en una linea> _id: p-…_
Contexto: memory/sessions/DATE-SLUG.md
Comprueba: <que hay que mirar ese dia, con las cifras y el criterio si se acordo uno>
Si ya no aplica, cierralo con /checkpoint-3t en vez de dejarlo abierto.
```
````

- `Título`: abre con `[<proyecto>]` y sigue con la pregunta. Tiene que ser legible en la vista de
  mes de un calendario, donde solo se ve esa linea. Nombra **la cosa y la pregunta**, no el item:
  `[3-tier-memory] ¿La linea "Sigue abierto:" cierra mas pendientes?`, no `Medir p-cd965754ec`.
  Sin ids `p-…`, sin rutas de fichero, **~70 caracteres contando el prefijo** — el que se acorta es
  el texto de la pregunta, nunca el prefijo. El calendario corta por la derecha en vista de mes, asi
  que lo unico que sobrevive siempre es lo que va primero, y con recordatorios de varios proyectos
  encima el proyecto es justo el dato que los distingue.
- `[<proyecto>]`: el **basename del directorio raiz del proyecto**, tal cual, entre corchetes —
  `[3-tier-memory]`, `[tienda-web]`. No inventes un nombre "bonito" ni uses el del repo remoto si
  difiere: el basename es lo que veras en la ruta y en el prompt, y dos nombres para el mismo
  proyecto son dos versiones de la verdad.
- `Proyecto:` (primera linea del fence): `<basename> — <ruta absoluta>`, con la ruta **tal cual**,
  sin `~` y sin variables. `Proyecto: tienda-web — /Users/ana/Projects/tienda-web`. El
  agente que recibe este prompt puede estar arrancado en cualquier sitio; `~` depende de que el
  shell lo expanda y en Git Bash/Windows no siempre apunta a lo mismo.
- `Descripción`: prosa, 2-4 lineas, **sin cifras**. Baselines, umbrales y listas por proyecto van
  solo en `Comprueba:`, dentro del fence — la descripcion la lees en el movil para decidir si vale
  la pena abrir el portatil; las cifras son trabajo del agente. Tiene que contestar tres cosas:
  **que era el pendiente**, **que se decide ese dia**, y **que pasa segun el resultado**.
  **Si el pendiente no trae una decision detras** —se construyo algo y nunca se midio, sin criterio
  acordado— dilo tal cual en vez de inventar uno: `Se construyo X en <mes> y nunca se probo contra
  Y. No hay criterio acordado: ese dia hay que decidir uno antes de mirar nada.` Una descripcion
  seca y honesta sirve; una inventada te hace llegar a la fecha creyendo que hubo un acuerdo que
  nunca existio.

**La prueba de que la descripcion sirve**: tapa el fence y lee solo Titulo + Descripcion. Si con
eso no puedes decir de que iba el pendiente ni que vas a hacer ese dia, reescribela. Ese es
exactamente el fallo que este bloque existe para evitar. **Y la prueba del Titulo, mas dura
todavia**: tapa tambien la Descripcion. Si con esa sola linea no sabes **en que proyecto** cae el
recordatorio, el prefijo esta mal puesto o se perdio.

**Ademas, el pendiente nace con la fecha como campo**, no solo en prosa:
`journal-emit.py --type pendiente.add … --revisar YYYY-MM-DD`. El compactador escribe
`— _revisar: YYYY-MM-DD_` en la linea de Tier 2. Ese campo tiene dos consumidores reales:
`expire-pendientes.py` (no caduca un item cuya ventana aun no vence) y el propio barrido manual.

**8c-2. Persistir los recordatorios en el session file**:

Escribe los mismos bloques en el session file, en la seccion `## Recordatorios de calendario`,
entre `## Como retomar` y `## Related`. Uno por pendiente con fecha futura, **todos, sin el tope
de 2** que aplica a la terminal. Encabeza cada uno con `### <FECHA> — <Titulo>` y debajo el bloque
completo. Un pendiente que ya tenia recordatorio vivo en otra ficha con la misma fecha lleva
solo su linea `- p-… ya agendado para <FECHA> en [[sessions/…]]` (Step 8c, "Un pendiente, un
recordatorio vivo"). Si no hubo ninguno, borra la seccion entera en vez de dejarla vacia.

`<Titulo>` del encabezado es **el mismo texto que la linea `Título:` del bloque, caracter por
caracter** — con su prefijo `[<proyecto>]` y con sus tildes. El resto de este fichero va sin tildes
por convencion, y esa costumbre se cuela justo aqui: en 2.15.0 el encabezado quedo con `linea/mas`
y el `Título:` con `línea/más`, dos versiones del mismo titulo en el mismo bloque. Lo encontro un
verificador externo, no la vista.

Los bloques persistidos tienen el **mismo texto** que los impresos — misma regla que en 8a/8b: dos
versiones del mismo recordatorio son dos versiones de la verdad. La unica diferencia la pone
`print-recordatorios.py`: en la ficha el prompt va dentro de su fence (para copiarlo de ahi), en la
terminal sin fence. Si en la terminal salio `+N con fecha futura en _pendientes.md`, en el fichero
estan los N.

**Por que este bloque.** Medido 2026-09-11: **11% de los pendientes nuevos traen una fecha
posterior a su creacion** (28 en 30 dias sobre 5 instalaciones, ~1 al dia) y **395 de 996
abiertos llevan una fecha ya vencida escrita en prosa que ningun codigo leyo nunca**. El
calendario del usuario es el unico disparador que si dispara sin cron, sin servicio externo y sin
depender de que alguien abra el proyecto ese dia. Titulo y Descripcion existen porque un evento
que solo lleva el prompt llega a su fecha sin decirle al humano de que iba: el prompt esta escrito
para el agente, y el que abre el calendario eres tu. **El proyecto se anadio por lo mismo, un nivel
mas arriba** (2.16.0): quien corre el plugin en varios proyectos acumula recordatorios de todos en
un mismo calendario, y tres campos que no dicen *donde* dejan un prompt que no se sabe desde donde
correr. El snippet de 8a/8b no tiene este problema porque se pega en el acto, sabiendo donde estas;
este se pega dentro de un mes.

**8d. Recomendaciones de research sin resolver — ya no van en el cierre (2.44.0)**:

Hasta 2.43.0 este paso pegaba en el cierre las recomendaciones `- [ ]` sin marcar de los research
que la ficha enlaza. Victor (2026-10-01): no le servian, y repetian lo que ya llevaba su pendiente
(la unica sin marcar ese dia ya tenia `p-5f81a0ac93` con fecha). Desde 2.44.0:

- **No hay bloque de research en el cierre** ni seccion `## Recomendaciones de research sin
  resolver` en la ficha (las fichas anteriores la conservan).
- **Cada recomendacion sin marcar cita en su linea el pendiente abierto que la lleva** (`p-…`), o se
  marca `[x]` (implementada o `-- declinado: motivo`). Si no tiene pendiente, proponlo en Step 3b;
  si el usuario lo guarda, pon su id en la linea del research, y si lo descarta, marcala
  `[x] … -- declinado: descartado por el usuario`. Ese pendiente es el que sale despues en las capas del cierre
  (🔔 si vence hoy, ➕ si toca) o en el calendario: la recomendacion no se pierde, que es el caso
  del 2026-09-17 por el que existia este paso (una sesion implemento 1 de 4 recomendaciones y las
  otras 3 no salieron en ningun lado).
- Para ver cuales faltan: `python3 "$JBIN/print-research-recomendaciones.py" "$SESSION_FILE"` (su
  salida es para ti, no se pega). `checkpoint-audit.py` marca `SALTADO` en
  `research.recomendaciones` si alguna sin marcar no cita un pendiente abierto, o si un wikilink de
  `## Research` esta roto.

**8e. El pendiente del cierre: 🔔 vence hoy o ➕ opcional (capas desde 2.44.0)**:

```bash
python3 "$JBIN/print-pendiente-opcional.py" "$SESSION_FILE"
```

**Pega su salida tal cual** justo despues del snippet (8b) y antes del calendario (8c). Si no
imprime nada, no hay nada que pegar. Es para el humano: un prompt completo (proyecto, pendiente con
su id, ficha de origen, clausula de cierre) que puede abrir en otra sesion.

El cierre va en capas (Victor, 2026-10-01): 1) Retomamos, siempre; 2) el pendiente que vence HOY;
3) el opcional. El script imprime a lo sumo uno de los dos bloques, porque la capa 3 exige que no
venza ninguno hoy:

- **🔔 Vence hoy.** Un pendiente con `_revisar` igual a hoy — los ya vencidos no. Sale con cualquier
  snippet, para que no pase desapercibido. Si vencen varios, uno cada vez: el de mayor prioridad y,
  dentro de ella, la fila mas arriba.
- **➕ Opcional.** Solo si el snippet es el caso 5 (`🔁 Como retomar: Ninguno — …`) y no vence
  ninguno hoy. Hasta 2 vencidos (`_revisar` anterior a hoy), el mas viejo primero; si no hay
  ninguno vencido, no sale nada. Hasta 2.63.17 salia entonces el Alta con `_creado` mas reciente;
  desde 2.63.22 no (Victor, d265-d266): sin relacion con la sesion, el mismo Alta salia en cada
  cierre hasta que alguien lo cerraba (uno de otro agente, 14 veces en 10 sesiones de otro proyecto).

Por que capas: hasta 2.43.0 el prompt opcional salia en cada cierre, y los mismos dos vencidos se
repetian durante varias sesiones. Ahora solo sale cuando la sesion no deja nada que retomar.

El script elige por campos de `_pendientes.md` y por la forma de `## Como retomar`, nunca por el
texto (regla 216). Nunca propone un pendiente con `_bloqueado:` sin `_revisar`, uno con `_revisar`
futuro (ya tiene su recordatorio de calendario) ni el que cita `Proximo paso:`. Un bloqueado con
`_revisar` de hoy o vencido si sale (2.63.32): toca mirar si ya llego lo que esperaba.

**No se guarda en la ficha.** Se genera en vivo desde `_pendientes.md`, y el hook de cierre
(`checkpoint-close-guard.sh`) lo vuelve a correr y exige cada linea en tu respuesta. Si en la misma
sesion cambias el estado de un pendiente citado en la ficha, el hook lo pide otra vez con el estado
nuevo. Limite: cerrar DESPUES el pendiente que este bloque propone, sin tocar ninguno de la ficha,
no vuelve a disparar el hook; el propio prompt dice "si ya no aplica, cierralo".

### 8f. Commit de la cola (2.52.0) — ULTIMO paso, despues de 8a-8e

Lo que este Step escribe (el snippet `## Como retomar`, los recordatorios de calendario) y el hash
que Step 6 anoto en la ficha y en `_session-index.md` van despues del commit de Step 6. Hasta 2.51.0
este paso decia "no agregues git commit aqui", y esa cola no la commiteaba nadie: el siguiente
checkpoint de OTRA sesion la barria con su `git add memory/` (en una instalacion real entraron colas
de sesiones de dias antes). Con commits por rutas nadie barre lo ajeno, asi que cada sesion commitea
su cola:

```bash
python3 "$JBIN/checkpoint-commit.py" --memory-dir "$MEMORY_DIR" --session-file "$SESSION_FILE" \
  --mensaje "checkpoint-cola: DATE-SLUG"
```

Usa el MISMO `MEMORY_DIR` y `SESSION_FILE` de Step 6. Lleva la ficha, sus plans/research enlazados y
lo compartido; no lleva nada de otras sesiones. Su hash no se anota en ningun lado (seria otra cola);
`COMMIT skip=sin-cambios` es normal si nada cambio. No es `--amend`: es un commit nuevo, y el hash
de Step 6 sigue valiendo. Lo que edites DESPUES de esto (por ejemplo al contestar la revision del
cierre) entra en el proximo checkpoint de esta misma sesion. Reporta solo la linea `COMMIT` (no
las `  + ruta`) en tu respuesta a la revision del cierre, ANTES de las salidas de 8b, 8e y 8c: el
cierre tiene que terminar con ellas, y el hook de cierre bloquea si despues del ultimo bloque siguen
mas de 300 caracteres.
