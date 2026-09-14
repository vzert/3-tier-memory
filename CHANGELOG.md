# Changelog

## [2.24.8] - 2026-09-14
Cierra p-bd9a53b794: session-start.sh decidia que avisos llegan a la persona (systemMessage)
re-derivando por grep de texto literal en DOS puntos de escalada distintos — la misma clase de
bug que 2.24.7 sufrio una vez (un aviso nuevo se olvida en uno de los dos sitios). Ahora
journal-compact.py marca sus 3 avisos persona-worthy con una linea `HUMAN-EVENT: <slug>`
(gitignore-migrado, fuera-de-banda, linea-base-ilegible); session-start.sh los reconoce con UNA
funcion compartida (`escalar_avisos_humanos()`) en vez de 5 bloques `grep -q '<patron>'`
duplicados. Texto que llega a la persona, byte a byte identico al de antes.

Dos rondas de verificacion adversarial independiente (backend externo GPT-5/codex + subagente
Opus 5), tres defectos reales encontrados y corregidos antes de comitear:
- `case "$slug" in ...)` (coincidencia exacta) era fragil a CRLF donde el `grep` que sustituyo
  (coincidencia de subcadena) era inmune — Windows esta en la matriz bloqueante de CI y Python
  ahi traduce `\n`->`\r\n` en stdout. Arreglo: strip de `\r` tras el `read -r`.
- El `case` no tenia brazo `*)`: un slug sin reconocer desaparecia en silencio, sin persona ni
  rastro — exactamente la clase de perdida que este pendiente existia para cerrar.
- El rotulo `HUMAN-EVENT: <slug>` se colaba literal al agente en `recall.sh` y `drift-gate.sh`
  (los otros 2 consumidores de la salida cruda del compactador), inconsistente con el filtro que
  si se aplico en session-start.sh.

Ronda 2 (delta-scoped, mismo backend): `hold`, con fixtures CRLF reales ejecutadas, no leidas.

## [2.24.7] - 2026-09-14
Cierra el limite documentado como "fuera de alcance" en 2.24.6 (hallazgo de codex/GPT-5, ronda 4):
`leer_huellas()` devolvia `{}` igual para "fingerprints.json no existe" que para "existe pero es
JSON invalido o no es un dict" — corrupcion accidental (disco danado, escritura interrumpida a
mano). Una copia de trabajo MADURA cuyo fingerprints.json se corrompiera perdia proteccion en
silencio: la linea base corrupta se resellaba sin aviso, y una escritura fuera de banda en la
misma ventana quedaba absorbida con ella.

**Modelo de amenaza, explicito para no sobreclamar**: esto detecta corrupcion ACCIDENTAL. NO
detecta el BORRADO deliberado de fingerprints.json (esta funcion solo mira si el fichero existe;
no audita senales adyacentes en `.journal/` que podrian distinguirlo — ver "Ronda adversarial"
abajo) ni una manipulacion sofisticada por alguien con permiso de escritura en `.journal/`
(podria forjar un JSON valido-pero-falso). Nota, no una promesa mas amplia.

**Ronda adversarial (codex/GPT-5) sobre el primer intento, dos hallazgos reales, ambos
corregidos**:
1. La afirmacion "el borrado es indistinguible de un arranque en frio" no estaba auditada contra
   el espacio de opciones: `.journal/applied/`, `pending/` u `out-of-band.log` con contenido
   previo SI podrian distinguir "esto ya se uso antes" de una instalacion genuinamente nueva.
   Corregido: la afirmacion ahora se acota explicitamente a "esta funcion, que solo mira
   existencia del fichero" — detectar borrado via esas senales adyacentes es heuristico y queda
   FUERA de alcance a proposito, no analizado ni descartado.
2. La rama `escritos` de `guardar_huellas()` hacia un NO-OP silencioso ante corrupcion, confiando
   en que `compact()`/`--check-drift` avisaran en una pasada posterior. Si ninguno de los dos
   vuelve a correr (los 4 scripts usados sueltos, sin una sesion detras), la escritura legitima
   quedaba sin sellar PARA SIEMPRE y la corrupcion sin avisar NUNCA — el mismo error de fondo del
   fix de 2.24.6 reintroducido de otra forma. Primer intento de correccion: avisar (anotar + print)
   de inmediato en esa misma rama, sin depender de ninguna pasada posterior — ese intento tenia a
   su vez el defecto de abajo (ronda de Opus).

**Ronda adversarial (Opus, subagent), sobre el fix de arriba, cuatro hallazgos reales, los
cuatro corregidos**:
1. **ungrounded** — el print que el primer intento anadio a la rama `escritos` de
   `guardar_huellas()` es incondicional, pero esa funcion la comparten 4 llamadores y AL MENOS
   UNO (`normalize-pendientes.py`) tiene contrato de salida propio con `--quiet`
   (`session-start.sh:138` lo invoca asi). El print se colaba igual, rompiendo ese contrato — la
   afirmacion "los 4 llamadores ya imprimen sin mirar `hay_lector()`" que justificaba el print
   ahi era falsa, probado con el propio codigo de `normalize-pendientes.py` (gatea cada print con
   `if not a.quiet`). Corregido: el print se quito de `guardar_huellas()`; esa rama solo ANOTA en
   `out-of-band.log` de inmediato (eso no tiene contrato de salida que romper). El aviso humano
   quedo exclusivamente en `compact()`/`--check-drift`, que ya respetaban `hay_lector()`/`--quiet`
   correctamente.
2. **incompleto** — el aviso de corrupcion nunca llegaba a una PERSONA real, solo al agente:
   `session-start.sh` escala a `systemMessage` (el canal que lee la persona) solo cuando su
   salida capturada matchea `grep 'FUERA DEL JOURNAL'`, y el nuevo texto de "linea base ILEGIBLE"
   no matcheaba ese grep en ninguno de los dos puntos de escalada (el bloque que aplica
   `pending/` y el de `--check-drift`). Corregido: `session-start.sh` anade un segundo grep
   (`'ILEGIBLE'`) en ambos puntos, cada uno con su propio mensaje a `human()`.
3. **incompleto** — `templates/audit-3t.md` (paso 15, deriva fuera del journal) documentaba solo
   dos salidas posibles de `--check-drift` (silencio, o `FUERA DEL JOURNAL`) y un formato de
   `out-of-band.log` que siempre nombra un fichero. Corregido: se anadio la tercera salida
   (`LINEA BASE DE HUELLAS ILEGIBLE`) y se aclaro que su linea en el log NO lleva fichero
   asociado, a diferencia de las de deriva.
4. **unfalsified** — la primera version de esta entrada y del checkpoint afirmaba conteos de
   asertos sin haber corrido el suite final. Corregido aqui abajo con los numeros reales.

**Ronda delta-scoped (mismo subagent Opus), sobre los 4 fixes de arriba, 1 hallazgo nuevo,
corregido**: re-derivo los 4 fixes desde el codigo (no desde esta prosa) y los dio por cerrados.
Encontro que el delta de arriba desplazo +20 lineas el area de `guardar_huellas()`, y dejo
desactualizado un puntero de una entrada ANTERIOR de este changelog (2.24.4): apuntaba al gate
original de fuera-de-banda en `journal-compact.py:2309`, y esa linea ahora tiene el gate NUEVO de
corrupcion (mismo texto literal `if hay_lector() or not quiet:`, por eso no saltaba a la vista) —
el gate original quedo en `2329`. Corregido ahi mismo (ver entrada de 2.24.4, abajo).

### Fixed
- `journal-compact.py`: nuevo helper `estado_huellas(journal)`, UNA lectura de
  `fingerprints.json`, tri-estado: `"ausente"` (no existe — arranque en frio real, sellar todo es
  correcto), `"corrupta"` (existe pero no parsea como dict — JSON invalido o no-objeto), `"ok"`
  (dict valido, SEA O NO VACIO — un `{}` legitimo, p.ej. tras un BORRADO de todos los indices
  protegidos, NO es corrupcion; tratarlo como tal reabriria el falso positivo masivo que las
  rondas 2/3 de 2.24.6 ya descartaron). `leer_huellas()` queda como wrapper sin cambiar su firma
  (tiene mas llamadores).
- `compact()` y `--check-drift`: detectan la corrupcion en el mismo momento y con el mismo gate
  que ya usan para el aviso de deriva fuera de banda (`hay_lector() or not quiet` en compact();
  siempre bajo `hay_lector()` en --check-drift, sin tocar las dos lineas de ese guard — las
  sustituye literalmente `tools/mutaciones/m_drift_humano.py`), anotan en `out-of-band.log`
  (linea propia, no mezclada con la lista de indices) y avisan ANTES de que el resellado
  incondicional que ya existia sobrescriba la corrupcion en silencio.
- `--reseal`: su mensaje ahora dice explicitamente si la linea base anterior estaba corrupta.
- `guardar_huellas()`, rama `escritos`: si la linea base esta corrupta, la funcion NO ESCRIBE —
  deja el fichero corrupto tal cual — y ANOTA de inmediato en `out-of-band.log`, sin esperar a
  que `compact()`/`--check-drift` corran despues (regla 181, una guarda va donde esta el EFECTO).
  NO imprime nada: esta funcion es compartida por 4 llamadores y al menos uno tiene su propio
  contrato con `--quiet` (ver ronda de Opus, hallazgo 1). El aviso humano vive solo en
  `compact()`/`--check-drift`.
- `session-start.sh`: los dos puntos que ya escalaban la deriva fuera del journal a `systemMessage`
  (la persona) ahora tambien escalan el aviso de linea base ILEGIBLE, con su propio texto.
- `templates/audit-3t.md`: el paso 15 documenta la tercera salida de `--check-drift` y el formato
  sin fichero de su linea en `out-of-band.log`.
- `test-linea-base-corrupta.sh` (nuevo, 18 asertos): JSON ilegible detectado y NO sobrescrito por
  la rama `escritos` (y sin imprimir nada ahi — solo anota); `--check-drift` avisa una vez y
  resella; control negativo con `{}` valido (no dispara el aviso); `compact()` con y sin
  lector/`--quiet`; `--reseal` reporta la corrupcion; `normalize-pendientes.py --apply --quiet`
  reporta su propio contrato (`headers_added=N`) sin que se le mezcle el aviso de corrupcion;
  `session-start.sh` entrega el aviso a `systemMessage` cuando hay persona. Confirmado rojo (8 de
  18 asertos fallan, verificado corriendo el suite contra el `journal-compact.py`/`session-start.sh`
  de 2.24.6 sin tocar) antes del fix completo, verde (18/18) despues.

**Limites conocidos, documentados y no cerrados en este ciclo (alcance explicito, no
descartados por omision)**:
- El aviso de linea base ILEGIBLE puede no llegar a la persona en la MISMA sesion si el unico
  camino que lo entregaria es el hook `UserPromptSubmit` (`drift-gate.sh`) y este usa una
  heuristica basada en mtime para decidir si hay algo "nuevo" que mostrar — un archivo truncado y
  reescrito puede no disparar esa heuristica. `session-start.sh` (el camino cubierto por los
  tests de este ciclo) si lo entrega siempre que hay persona.
- Cuando la misma corrupcion pasa por `guardar_huellas()` (anota) y luego por `compact()`/
  `--check-drift` (anota otra vez), `out-of-band.log` recibe N+1 lineas para un solo evento de
  corrupcion. Ruido, no perdida de senal — queda como design smell, no arreglado aqui.

## [2.24.6] - 2026-09-14
Reportado y verificado con evidencia por otra sesion Claude (via cross-session-message): las
4 herramientas del plugin que re-sellan la linea base de huellas tras su propia escritura
legitima — `scan-secrets.py --apply`, `enrich-memory.py --apply`, `normalize-pendientes.py
--apply`, `repair-dualwrite.py --apply` — llamaban `guardar_huellas(mem, journal)` sin
`estado`. Con `estado is None`, esa funcion releia TODO el estado de disco (`leer_estado(mem)`)
para la linea base nueva, no solo el indice que la herramienta acababa de escribir. Si en la
misma ventana habia una escritura fuera de banda a OTRO indice YA SELLADO, quedaba sellada en
silencio junto con la escritura legitima: `--check-drift` dejaba de verla para siempre. Es
upstream — vale para cualquier instalacion con `journal_strict=1`, no solo este repo.

Cuatro rondas adversariales, tres encontraron un defecto real (corregido) en el intento
anterior; la cuarta encontro un limite real pero PREEXISTENTE, dejado fuera de alcance a
proposito (ver "Known limitation" abajo):
- **codex/GPT-5 (backend externo)**: el docstring prometia que `escritos` aceptaba rutas
  relativas a `mem`, pero el codigo solo resolvia relativas al cwd del proceso.
- **Opus (subagent), ronda 1**: el arreglo al hallazgo anterior asumio un contrato que NINGUN
  llamador real usa (ruta bare relativa a `mem`, independiente del cwd) y de paso ROMPIA el caso
  real de produccion — `mem` RELATIVO, que es como `templates/*.md` invocan estos scripts
  (`MEMORY_DIR="memory"`). Tambien encontro un hueco preexistente (no introducido por este fix,
  tampoco cerrado por el primer intento): un indice protegido NUNCA sellado, creado fuera de
  banda en la misma ventana que una escritura legitima a otro indice, se sellaba en silencio en
  vez de seguir viendose como "nuevo, no lo creo el compactador" (la clase que
  `detectar_fuera_de_banda()` ya distingue desde la ronda 6).
- **Opus (subagent), ronda delta-scoped**: el arreglo al hueco preexistente, al quitar el
  auto-sellado de "cualquier indice nunca visto", tambien quito el caso de un clon SIN linea base
  previa (`fingerprints.json` esta gitignored, es por-copia-de-trabajo): TODO indice preexistente
  se veia como "nuevo" en el primer `--check-drift` tras una herramienta legitima corrida en un
  clon fresco — camino real, `/checkpoint-3t` Step 3-pre corre normalize-pendientes/
  enrich-memory/repair-dualwrite ANTES de que el compactador mismo establezca linea base.
- **codex/GPT-5, ronda 4 (delta-scoped)**: `leer_huellas()` no distingue "fingerprints.json no
  existe" de "existe pero esta vacio o es JSON invalido" — ambos casos devuelven `{}`. El fix de
  la ronda delta trata los dos como "sin linea base, sellar todo". Verificado: `detectar_fuera_
  de_banda()` (sin tocar por este fix) ya usa el mismo `if not prev: return []` desde la ronda 6
  — el sistema entero YA confiaba en esa señal antes de este cambio. Es un limite real pero
  PREEXISTENTE Y COMPARTIDO, no una regresion de este fix; corregirlo exige logica nueva en
  `leer_huellas`/`detectar_fuera_de_banda` (distinguir "ausente" de "corrupto" sin caer en
  ninguno de los dos extremos ya descartados por las rondas 2/3), fuera del alcance ratificado
  para este cambio. Documentado como limite conocido en el docstring de `guardar_huellas()`, no
  arreglado aqui — decision del usuario si se aborda como cambio separado.

### Fixed
- `journal-compact.py:guardar_huellas()`: nuevo kwarg opcional `escritos` (rutas, EXACTAMENTE
  como el llamante las construyo — tipicamente `os.path.join(mem, nombre)` — nunca un contrato
  distinto resuelto contra `mem` por separado). Cuando `estado is None` y `escritos` no esta
  vacio, hay dos casos: SIN linea base previa en esta copia de trabajo (clon nuevo), se sella
  TODO lo que hay en disco — igual que el default sin `escritos`; CON linea base previa, la nueva
  parte de la YA SELLADA (`leer_huellas(journal)`, no el disco) y SOLO los indices en `escritos`
  toman el hash fresco — un indice sin sello previo que este llamante no escribio se queda fuera
  a proposito, para que la comprobacion siguiente lo vea como nuevo. El default sin `escritos` NO
  cambia — el compactador mismo lo usa asi a proposito (3 llamadas internas, ninguna pasa
  `escritos`; re-sellar TODO tras aplicar, ver `hay_lector()`), y ese contrato costo 5 rondas
  adversariales previas.
- Los 4 llamadores externos ahora pasan `escritos=[...]` con las rutas que de verdad escribieron
  (ya en la forma `os.path.join(mem, nombre)` que construian de por si), y solo llaman a
  `guardar_huellas()` cuando `escritos` no esta vacio.
- `test-guardar-huellas-escritos.sh` (nuevo, 13 asertos): reproduce el escenario original con
  `scan-secrets.py`; el caso con `mem` RELATIVO (el camino real de produccion, via
  `templates/*.md`); el caso del indice nunca sellado creado fuera de banda; y el caso de un clon
  SIN linea base previa. Los cuatro, confirmados rojo contra la variante defectuosa
  correspondiente (el codigo original sin `escritos`; el primer intento con doble-join; una
  auto-adopcion silenciosa de indices sin sello previo; y esa misma auto-adopcion quitada sin
  distinguir el caso de clon nuevo) antes de confirmarlos verdes contra el fix final.

## [2.24.5] - 2026-09-14
Una segunda verificacion adversarial de 2.24.4 (independiente de la que lo motivo, corrida sobre
una copia limpia del repo) encontro que el caso nuevo de prueba de p-c28bcb9c55 era en parte
vacuo: el aserto "sin lector: compact() no avisa de la deriva" miraba `systemMessage`, pero
`session-start.sh` vacia `_HUMAN_BUF` -que alimenta `systemMessage`- SIEMPRE que no hay persona
(`emit_output`, "hay_persona || _HUMAN_BUF=\"\""), avise o no avise `compact()`. El aserto no
podia fallar nunca: neutralizando el gate a "avisa siempre" (`if True:`), la suite seguia en
verde. La mitad "con lector SI avisa" si discriminaba (el control negativo con el gate viejo
fallaba), asi que solo la mitad "sin lector" era ciega.

### Fixed
- `test-expire-reopen.sh`: `avisa_fob()` ahora mira `additionalContext`, no `systemMessage`.
  `additionalContext` lleva el `JOURNAL_OUT` completo siempre (via `out`), con o sin persona, y
  es la unica senal que dice si `compact()` avisó de verdad. Verificado que discrimina: con el
  gate neutralizado a "avisa siempre", el aserto ahora SI falla; con el gate real (2.24.4), pasa.

## [2.24.4] - 2026-09-14
Verificacion adversarial de 2.24.3 (antes de publicarla) encontro que el gate `if hay_lector()`
no solo ensanchaba el aviso de deriva de `compact()` -tambien lo ESTRECHABA, en un camino que
2.24.3 no considero. Los comandos slash (`checkpoint-3t`, `save-learning`, `triage-3t`,
`consolidate-3t`, `backfill-3t`, `migrate`) llaman a `compact()` SIN `--quiet`, y corren bajo
agentes de Paperclip donde `hay_lector()` es `False`. Antes de 2.24.3, esos llamantes SI recibian
el aviso (nadie les pidio silencio); con `hay_lector()` a secas, se callaban igual que
session-start.sh/recall.sh -que si piden `--quiet`-, aunque nadie se lo pidio a ellos.
`compact()` resella siempre, asi que ese silencio no compraba nada: exactamente el defecto que
2.24.3 arreglaba, reabierto por la otra puerta. Medido empiricamente (misma deriva, sin
`--quiet`, con `PAPERCLIP_RUN_ID`): el codigo de 5763457 avisaba, el de 2.24.3 no.

### Fixed
- `journal-compact.py:2329`: el gate pasa de `hay_lector()` a `hay_lector() or not quiet`. Un
  llamante que no pide `--quiet` sigue avisando siempre (como antes de 2.24.3); uno que si lo
  pide (`session-start.sh`, `recall.sh`) solo calla si ademas no hay lector.
- Nuevo caso en `test-expire-reopen.sh` que invoca `journal-compact.py` sin `--quiet` bajo
  `PAPERCLIP_RUN_ID` y confirma que avisa. Verificado que discrimina: falla contra el gate de
  2.24.3 (`hay_lector()` a secas), pasa contra este.

## [2.24.3] - 2026-09-14
`hay_lector()` protegia el aviso de deriva de `--check-drift`, pero `compact()` normal (aplicar
`pending/`) tenia el mismo aviso detras de `if not quiet` — y `session-start.sh:205` y
`recall.sh:39` lo llaman siempre con `--quiet`. `compact()` resella la linea base SIEMPRE al
terminar (es su trabajo: sellar lo que acaba de aplicar), asi que si detectaba deriva fuera de
banda A LA VEZ que aplicaba `pending/`, el aviso era la unica senal que podia sobrevivir — y ese
aviso se callaba por `--quiet`, no por falta de lector. Mismo patron de fondo que 2.24.1
(`p-c28bcb9c55`), en otra interseccion de llamantes.

### Fixed
- **El aviso de fuera de banda dentro de `compact()` ahora depende de `hay_lector()`, no de
  `quiet`.** `--quiet` sigue silenciando solo el resumen rutinario (`JOURNAL applied=...`).
- **`session-start.sh` avisa a la persona (no solo al agente)** cuando la pasada de `compact()`
  normal detecta deriva fuera de banda, igual que ya hacia para `--check-drift`. Se movio el
  `export THREET_SIN_LECTOR` para que cubra las DOS llamadas del script, no solo la de
  `--check-drift`: sin esto, un `source=clear/compact` (agente sin persona) habria visto
  `hay_lector()==True` en la primera llamada y avisado de mas.
- **`recall.sh` ya no tira a `/dev/null` la salida de `compact()`** al aplicar `pending/`: era el
  unico punto donde ese aviso podia llegar, porque `compact()` ya resello los indices para
  entonces.
- Nuevo caso en `test-expire-reopen.sh` que fuerza deriva fuera de banda a la vez que un evento
  pendiente, y confirma que el aviso sale con lector y calla sin el (Paperclip). El arnes de
  mutacion `mutation-check.sh` confirma que el caso "deriva sin lector" sigue discriminando.

## [2.24.2] - 2026-09-14
El arnes de mutacion (`tools/mutation-check.sh`) dejo de discriminar el caso "deriva sin lector"
en el CI de 2.24.1, en las tres plataformas: la mutacion SI se aplicaba y la suite SI caia, pero
por un texto distinto al que el arnes esperaba. Causa: antes de 2.24.1, `bash-journal-nudge.sh`
llamaba a `--check-drift` en su `PostToolUse`, y el aserto `"el hook de Bash con Paperclip: no
consume"` (que SI contenia el string literal `"no consume"`) fallaba con la mutacion aplicada.
2.24.1 quito esa llamada — ese camino ya no ejecuta el codigo mutado — y con el se fue el UNICO
punto de la suite cuyo texto de fallo coincidia literal con el string del arnes. El aserto que
sigue cayendo con la mutacion (`"y la linea base NO se toca (no se consume)"`, en
`test-expire-reopen.sh`) siempre dijo "no SE consume", no "no consume": el desajuste de texto
existio desde que se agrego este caso, y solo salio a la luz cuando 2.24.1 le quito al arnes su
unica coincidencia de casualidad.

### Fixed
- **`tools/mutation-check.sh`: el string esperado del caso "deriva sin lector" pasa de `"no
  consume"` a `"no se consume"`**, para que coincida con el aserto real que la mutacion sigue
  tumbando tras 2.24.1.
- Comentario de `tools/mutaciones/m_drift_humano.py` actualizado: ya no dice "tumbar los asertos
  de LOS DOS caminos" — desde 2.24.1 solo queda uno.

## [2.24.1] - 2026-09-14
2.24.0 arreglo que el aviso de escritura a mano llegara a alguien anadiendo
`bin/journal-drift-nudge.sh` (`UserPromptSubmit`, que SI entrega). Pero dejo vivo un tercer
llamante que ya llevaba desde 2.13.4 llamando a la misma ruta: `bash-journal-nudge.sh` en su
`PostToolUse` de Bash. Ese `PostToolUse` corre EN EL MISMO TURNO que la escritura, antes de que
exista turno siguiente — y `journal-compact.py --check-drift` detecta Y RESELLA la linea base en
la misma llamada, a proposito, para que el aviso salga una vez y no en cada sesion. `hay_lector()`
decide si se resella mirando si la sesion esta atendida, no que LLAMANTE concreto esta preguntando
— y en una sesion interactiva normal (el caso comun) siempre dice que si hay lector. Resultado: el
`PostToolUse` de Bash ganaba SIEMPRE la carrera contra `journal-drift-nudge.sh`, resellaba la
linea base, y el aviso real nunca llegaba a nadie. Esto no es un defecto nuevo: es plausible que el
aviso de deriva por escritura de Bash nunca haya llegado a nadie desde que el mecanismo existe
(v2.13.4). Verificado leyendo el codigo (`journal-compact.py:1912` `hay_lector()`,
`bash-journal-nudge.sh:71` de la 2.24.0), no con hipotesis.

Ninguna de las dos suites existentes ejercitaba la carrera: `test-drift-nudge.sh` nunca corria el
`PostToolUse` de Bash, y `test-bash-nudge.sh` nunca corria `journal-drift-nudge.sh` despues. Cada
una probaba su hook aislado.

### Fixed
- **`bash-journal-nudge.sh` ya no llama a `--check-drift` desde su `PostToolUse` de Bash.** Se
  quito la llamada por completo en vez de intentar que `hay_lector()` supiera distinguir "sesion
  atendida" de "este caller entrega" — la entrega real ya vive en `session-start.sh` (SessionStart)
  y `journal-drift-nudge.sh` (UserPromptSubmit), los dos unicos llamantes que de verdad hacen
  llegar lo que `--check-drift` imprime. El `PreToolUse` de Bash (deteccion aproximada por texto
  del comando, para quien mira el log) sigue igual.
- **`hooks/hooks.json` ya no registra `bash-journal-nudge.sh` en `PostToolUse`.** Con la llamada
  quitada esa rama solo hacia `exit 0` tras resolver `MEMORY_DIR` — configuracion muerta que se
  pagaba en CADA llamada a Bash sin hacer nada. Se deja la rama `PostToolUse` en el script (inerte,
  probada) por si algo lo invoca directamente con ese evento; el harness ya no lo hace.
- **Nueva prueba que reproduce el orden real de una sesion**, no cada hook aislado:
  `test-drift-nudge.sh` (seccion "ronda 8") escribe con Bash, corre el `PostToolUse` de
  `bash-journal-nudge.sh` en ese mismo turno, y SOLO DESPUES corre `journal-drift-nudge.sh` como
  si fuera el prompt siguiente — confirmando que el aviso llega ahi y no se lo comio el paso
  anterior. Verificado que la prueba discrimina de verdad: corrida contra el codigo de 2.24.0
  (`git show HEAD:.../bash-journal-nudge.sh`) falla en los 3 casos esperados; contra el codigo
  arreglado, pasa. `test-bash-nudge.sh` y `test-expire-reopen.sh` se actualizaron para reflejar que
  el `PostToolUse` de Bash ya no toca la linea base bajo ningun valor de `PAPERCLIP_RUN_ID` /
  `CLAUDE_CODE_SESSION_ATTENDED`. Se enumeraron todos los llamantes de `--check-drift` cruzando con
  `hooks.json`: los unicos dos que quedan (`session-start.sh` en `SessionStart`,
  `journal-drift-nudge.sh` en `UserPromptSubmit`) entregan de verdad; ningun otro hook registrado
  (`journal-guard.sh`, `check-index-registration.sh`, `recall.sh`, `pre-compact.sh`,
  `session-end.sh`) llama a esta ruta.

## [2.24.0] - 2026-09-14
Un agente en cloudflare-expert (2026-09-12) escribio pendientes a mano durante una migracion —12
ids no canonicos, filas duplicadas— y nadie lo avisó. Causa raiz: `journal-guard.sh` (el hook de
Edit/Write) sale en silencio total si `journal_strict` no esta en 1 en `.memory-config`, y no lo
esta en casi ninguna instalacion existente (measured 2026-09-11: 64 de 65 proyectos). Su hermano
`bash-journal-nudge.sh` (Bash) ya habia aprendido esa leccion y avisaba sin depender de la config;
este hook se habia quedado atras. La misma instalacion tenia ademas `_session-index.md` y
`_plans-index.md` sin las anclas `## Sessions`/`## Plans` que el compactador exige — defecto
estructural de cualquier instalacion cuyo Step 3 de `/setup-memory` las genero con otro texto —,
asi que el primer `session.add`/`plan.upsert` de la sesion se iba a cuarentena en silencio.

Medido en este mismo repo entre el 2026-09-11 y el 2026-09-14 (dry-run de `repair-dualwrite.py`):
pendientes sin fila de Tier 3 bajaron de 51/120 a 0. Esa bajada la produjo `repair-dualwrite.py`
adoptando huerfanos durante estas mismas sesiones, no el aviso del guard — una revision
adversarial marco la atribucion anterior de este parrafo ("el guard cumple su proposito") como
una causal que la evidencia no sostiene, y tenia razon: nada aqui midio si el aviso en si llega a
alguien (ver el punto de `journal-drift-nudge.sh` abajo, que es la correccion real de ESO). Lo que
si se midio en el mismo periodo: +2 ids no canonicos, de sesiones escribiendo a mano mientras se
corregia esto mismo — el costo era real, la mejora de fondo (0 huerfanos) tambien, pero por una
causa distinta a la que se afirmaba.

### Fixed
- **`journal-guard.sh` avisa siempre, no solo con `journal_strict=1`.** Antes: sin esa config, un
  Edit/Write directo a un indice del journal no generaba NINGUNA señal. Ahora imprime el mismo
  aviso (texto plano, nunca bloqueo) que ya usaba el hook de Bash; el `deny` duro sigue siendo
  opt-in. El atajo de shell que evita arrancar python en el caso comun es generico
  (`^_[^/\\]*\.md$`), no una lista de 5 nombres — una revision adversarial encontro que la
  primera version de este mismo cambio dejaba pasar sin aviso cualquier `_otro.md` fuera de esos
  5.
- **Ese aviso de PreToolUse/PostToolUse NO llegaba al agente, y nunca se habia medido.** Medido
  con `claude -p` (un hook de prueba con un centinela, corrido dos veces): un `PreToolUse` o
  `PostToolUse` que solo imprime texto plano y sale 0 va al log de depuracion, no al contexto del
  modelo ni al canal de la persona — el mismo defecto, no introducido hoy, que ya tenia
  `bash-journal-nudge.sh` desde que existe. Se deja el print (es inofensivo) pero la entrega REAL
  ahora es `bin/journal-drift-nudge.sh`, un hook `UserPromptSubmit` nuevo — el mismo canal que ya
  usa `bin/recall.sh` — que corre `journal-compact.py --check-drift` (ya existia, antes solo se
  invocaba desde `SessionStart`) en cada prompt de la sesion. La compuerta barata de mtime que
  antes solo tenia `bash-journal-nudge.sh` se extrajo a `bin/drift-gate.sh`, compartida por los
  dos. Con esto el aviso llega en la MISMA sesion donde paso la escritura a mano, no una sesion
  despues — que es cuando de verdad importa: un `/checkpoint-3t` en esa misma sesion resella la
  linea base antes de que el aviso del arranque siguiente llegue a ver nada.
- **`journal-compact.py` crea el ancla que falta en vez de cuarentenar** para `## Sessions`,
  `## Plans`, `## Topic Files`, `## Active Research` y `## Completed Research` — mismo criterio
  que ya existia desde 2.22.0 para `## Alta/Media/Baja prioridad` en `_pendientes.md`. Un evento
  que una version anterior ya habia cuarentenado por esta razon se rescata solo al actualizar.
  Si ya existia una tabla con esa forma (mismo numero de columnas) bajo OTRO nombre de header, se
  ADOPTA — se renombra su header in-place, filas incluidas — en vez de crear una segunda tabla
  vacia al lado: una revision adversarial reprodujo, contra datos reales de 5 instalaciones, que
  la primera version de este cambio partia el indice en dos tablas con la misma fila la primera
  vez que esa fila se actualizaba, porque la busqueda de duplicados solo miraba la tabla nueva.
  Con DOS O MAS tablas candidatas (ambiguo: paperclip y scalar-api-docs, cada una con dos tablas
  de 6 columnas bajo headers distintos) la adopcion sigue sin adivinar cual usar, pero la busqueda
  de duplicados de `apply_session_add`/`apply_plan_upsert`/`apply_research_upsert` ahora mira
  TODAS las tablas del archivo (`find_row_anywhere`), no solo la que crea `need_table` — una
  segunda ronda adversarial reprodujo la misma particion con 2+ candidatas (70 planes bajo
  `## Active Plans` en paperclip) y este era el arreglo que la cerraba entera, no el reposo en
  cuarentena. Ese ensanche NO incluye el fallback por titulo plano (para un plan/research
  `--inline`, sin wikilink) — una tercera ronda construyo una tabla `## Inventory` ajena, del mismo
  ancho, con una fila cuyo titulo coincidia por casualidad, y el ensanche completo la enganchaba.
  El fallback por titulo se quedo acotado a la tabla canonica en cada llamante; solo la busqueda
  por wikilink (exacta, sin ese riesgo) se ensancho a todo el archivo. Una CUARTA ronda, sobre
  datos reales de `paperclip`, encontro el limite de fondo de toda esta familia de arreglos: 98
  filas de tabla HUERFANAS en 4 instalaciones — lineas `|...|` sin cabecera ni separador encima,
  invisibles para `find_tables`/`find_row_anywhere` por construccion. Antes de 2.24.0 un archivo
  asi nunca podia recibir un evento sin ancla (iba a cuarentena, visible); con la adopcion/creacion
  automatica, un upsert futuro para una de esas filas la duplicaria en silencio — un cambio de
  comportamiento real sobre datos ya danados. Se cierra deteniendose ANTES de tocar nada: si el
  archivo tiene filas huerfanas, `need_table` cuarentena (mismo criterio que existia antes de esta
  version) en vez de adoptar o crear.
- **La afirmacion de que `UserPromptSubmit` SI entrega al agente (y `PreToolUse`/`PostToolUse`
  no) quedo como script repetible**, no solo como medicion de una conversacion: `bin/verify-hook-
  delivery.sh` (manual, cuesta tokens de API, no vive en `bin/test-*.sh`) monta un proyecto con
  los tres tipos de hook, cada uno con un centinela distinto, y pregunta al modelo cual vio.
- **`repair-dualwrite.py --fix-ids`** (opt-in, requiere `--apply`): renombra un id inventado a su
  sha1 canonico en `_pendientes.md` y su fila de `pendientes/YYYY-MM.md`. Deliberadamente NO toca
  `memory/sessions/*.md` (una cita de id en prosa de sesion es registro historico, no una tabla).
  Ante colision (el canonico ya existe como otra fila) o ante un id DUPLICADO (el mismo id en mas
  de una linea, dano previo) no toca nada y lo reporta — una revision adversarial encontro que la
  primera version de este flag hacia un renombrado PARCIAL en el caso duplicado, dejando una fila
  con el id nuevo y la otra huerfana con el viejo. Otra revision encontro que el reemplazo de texto
  usaba un espacio fijo (`_id: {viejo}_`) mientras la deteccion tolera espacio variable
  (`_id:{viejo}_` sin espacio no se reescribia, y aun asi se reportaba como renombrado) — ahora
  usa el mismo patron tolerante para detectar y para reemplazar.
- **`SessionStart` reporta ids inventados y filas rotas de `pendientes/` en cada arranque**
  (solo lectura, nunca `--apply`) para que una instalacion vieja con este tipo de daño se entere
  sin tener que correr `/audit-3t` por su cuenta.
- **`setup-memory.md`** deja explicito que `## Sessions`/`## Plans` deben ser el texto literal
  exacto, y corrige una afirmacion que ya no era cierta tras el punto anterior (un header con otro
  texto ya no manda el evento a cuarentena para siempre; crea una segunda seccion, mecanicamente,
  y la vieja queda como contenido muerto).

## [2.23.0] - 2026-09-12
La mitad de un repo real era rastro que nadie lee. Cifra reportada por **una** instalacion el
2026-09-12 —no es un promedio, y no esta rederivable desde este repo, que no versiona `memory/`—:
`memory/.journal/applied/` eran **628 de sus 1230 ficheros (51%), 2.5 MB, 619 de un solo mes**.
Mide la tuya antes de creerte la cifra:

```
find memory/.journal/applied -name '*.json' | wc -l   # ficheros de rastro
git ls-files | wc -l                                  # ficheros del repo
```

Crece con cada `/checkpoint` y no se poda nunca. El efecto de un evento ya aplicado **es la fila del indice**, y
esa si se versiona, asi que el directorio entero es historial duplicado.

Y habia una segunda mitad del problema, que es la que costaba: el bloque de `.journal/.gitignore`
se escribia **solo si faltaba**, asi que una linea nueva no llegaba **a ninguna** instalacion de
2.21.0 en adelante — justo las que tienen el fichero, o sea todas las que tienen el problema. Un
fichero generado si-falta era inmutable en la practica.

### Changed
- **`applied/` deja de versionarse.** El bloque de `memory/.journal/.gitignore` lo anade. Siguen
  versionados `pending/` y `quarantine/`, y no por simetria: los dos hacen falta para **aplicar**
  en la otra maquina (un `pending` se aplica alli en vez de perderse; un evento en cuarentena por
  un ancla que aqui no existia puede tenerla alli, y desde 2.22.0 el compactador lo rescata). El
  rastro de `applied/` no se aplica en ningun sitio: solo se consulta.
- **El `.journal/.gitignore` que escribimos nosotros ahora se actualiza.** Si su contenido
  coincide **entero** con un bloque que este plugin publico —sha256 de los dos unicos cuerpos que
  ha tenido: 2.21.0-2.22.1 y el de 2.21.3—, se reemplaza de forma atomica (`os.replace`). Si difiere
  **en un byte**, lo edito el usuario y su version manda: eso no cambia. La comparacion normaliza
  CRLF antes de mirar, porque este fichero esta **trackeado** y en Windows con `core.autocrlf`
  vuelve del checkout con CRLF — sin normalizar, la migracion no llegaria jamas a esa plataforma.
  Cierra la deuda abierta en 2.21.0.
- **El aviso de esa migracion llega a la PERSONA, y sobrevive a `--quiet`.** Mismo fallo que
  2.17.0 arreglo para los pendientes y 2.21.0 para la deriva, y aqui habia vuelto: la ruta por
  la que esto le pasa a la gente de verdad es `session-start.sh`, que corre el compactador **con
  `--quiet`** y manda su salida a `additionalContext` —que lee el agente y nadie mas—. Escrito
  asi, el plugin reescribia un fichero del repo del usuario sin decirselo, y se tragaba el
  `git rm -r --cached` sin el cual su repo queda ignorando `applied/` y trackeandolo a la vez.
  Ahora el aviso se imprime aunque sea `--quiet` —ocurre UNA vez en la vida de una instalacion,
  no es salida rutinaria— y `session-start.sh` lo entrega por `systemMessage`.

### Migration
Anadir algo al `.gitignore` **no lo des-trackea**. Si ya tenias `applied/` versionado:

```
git rm -r --cached memory/.journal/applied && git commit -m "journal: applied/ deja de versionarse"
```

Los ficheros siguen en tu disco —el compactador no los lee, solo usa `applied/` como destino, asi
que puedes borrarlos si quieres— y siguen en el **historial** del repo: esto detiene el
crecimiento, no lo revierte.

### Fixed
- El aviso de deriva decia *"los cambios NO se pierden, vienen anclados en `applied/`"*. Tras un
  `git pull` eso deja de ser cierto con `applied/` ignorado — y nunca fue lo que tranquilizaba:
  lo que llega por git **es el contenido de los indices, ya aplicado en la otra copia**. Reescrito.
- `templates/audit-3t.md` decia que el conteo `applied` era de todos los meses; pasa a ser por
  copia de trabajo, y un clon recien traido empieza en 0. Esperado, no una perdida.
- El docstring de `repair-dualwrite.py` describia una medida ("ninguna de las 49 filas tenia
  evento propio en `applied/`") que en un clon ya no se puede repetir. No lo usa ningun camino de
  codigo; queda anotado donde estaba.

### Tests
- 134 asertos en `test-expire-reopen.sh` (eran 123). El fixture de la migracion es el cuerpo
  **literal** de `GITIGNORE_JOURNAL` en 2.21.0, extraido del historial (`d71e45e`), no tecleado.
  Cubre: migra el bloque de 2.21.0, lo dice por pantalla, **no** re-migra en la pasada siguiente,
  migra tambien el mismo bloque en CRLF, y el control negativo — un byte distinto y no se toca.
- **Seis** mutaciones nuevas (8 -> 14 casos en `tools/mutation-check.sh`), y las seis caen por
  el aserto que les toca: quitar la guarda de la migracion (reescribir siempre) tiene que tirar el
  control negativo; quitar la normalizacion CRLF tiene que tirar el caso de Windows; quitar
  `applied/` del bloque tiene que tirar el aserto que le pregunta **a git** (`check-ignore`), no el
  que busca la cadena en el fichero; y meter el hash del bloque actual en la lista de superados
  —el descuido que cometera la proxima version que lo cambie— tiene que tirar «no re-migra»;
  devolver el aviso detras de `if not quiet` tiene que tirar el caso de `--quiet`; y quitar la
  entrega por `systemMessage` tiene que tirar el aserto que mira **ese campo del JSON**, no que
  la salida traiga algun texto. Queda sin mutacion propia la carrera de la migracion, que no se
  puede medir de forma determinista.

## [2.22.1] - 2026-09-12
`windows-latest` llevaba en rojo desde 2.20.0 con dos mutaciones diciendo "no discrimina". No era
el producto: era el huso del banco. Y al investigarlo salio un defecto de producto peor, vivo en
cualquier maquina en UTC.

### Fixed
- **`en_rango` abortaba el proceso ENTERO por un timestamp absurdo en UNA transcripcion.** Un
  `0001-01-01` (o un `9999-12-31`) parsea sin excepcion, pero restarle o sumarle el margen de dias
  desborda `datetime.date` y lanza `OverflowError`, que no es ValueError ni TypeError. Sin capturarla,
  `match-session-file.py` moria con traceback y `/backfill-3t` perdia la clasificacion del corpus
  completo por un solo fichero. Vivo en cualquier maquina cuyo huso local sea UTC —casi todo servidor
  y casi todo CI—; invisible en un huso al oeste, porque alli la fecha se descartaba antes de llegar
  a esa resta. Reproducido en los dos husos con el arreglo revertido. Mismo `except` en
  `stamp-session-id.py`, donde con `MARGEN_DIAS = 0` la guarda es LATENTE: hoy no desborda, y la
  unica diferencia entre los dos ficheros es esa constante.
- **El banco fijaba el huso con un nombre que Windows no entiende.** `TZ="America/Mexico_City"` lo
  aceptan glibc y BSD, pero el CRT de Windows solo parsea `STDoffsetDST[,regla]`: en Git Bash el huso
  quedaba en UTC, el desfase desaparecia, y con el desaparecian las dos mutaciones que existen para
  verlo (M1 y M5, "no discrimina" en cada corrida). Ahora se fija en formato POSIX con reglas de DST
  explicitas (`CST6CDT,M3.2.0,M11.1.0`), que las tres plataformas calculan igual.

  Medido en macOS sobre el banco anterior, cambiando a UTC su propio `export TZ` (poner `TZ=UTC` en
  el entorno no sirve: ese export lo pisa y salen `PASS=38 FAIL=0`): `PASS=34 FAIL=4`. Son CUATRO, no dos —
  los dos rojos de `windows-latest` mas otros dos que Windows no daba, del caso del ano imposible en
  `stamp-session-id.py` (que tiene su propia guarda de `OverflowError`, esta por el desbordamiento de
  `astimezone()` al oeste) y su colateral. Windows no es UTC puro: alli esa conversion falla con
  `OSError`, que si esta capturado, asi que el caso pasaba. Los CUATRO dependen de un huso al oeste y
  los cuatro quedan cubiertos por la guarda de abajo: en una plataforma que ignore TZ el banco da
  `PASS=38 FAIL=0 SKIP=4`, medido dos veces por separado.
- **Y no se da por hecho que se aplique.** El banco mide el desfase real al arrancar; si sale 0, las
  cuatro comprobaciones que necesitan un huso al oeste se SALTAN Y SE CUENTAN (`SKIP=N` en el
  resumen), nunca se dan por buenas en verde. Es la misma regla que el workflow ya aplica a los 3
  casos no construibles en Windows.

### Pruebas
`test-backfill-dedup.sh` pasa de 38 a 42 asertos. El nuevo C14 llama a `en_rango` DIRECTAMENTE con
los dos anos extremos, sin huso de por medio, en los dos ficheros que la tienen — asi el caso se mide
tambien en UTC, que es donde estaba vivo. Su mutacion M6 quita `OverflowError` en cada fichero por
separado (el arreglo toca dos, probar uno no prueba el otro) y fija ademas `MARGEN_DIAS = 1`, porque
en `stamp-session-id.py` la guarda es latente y lo que hay que medir es que subir el margen no reabra
el fallo. La mutacion va sobre una COPIA: la version anterior de este parche mutaba el fuente del
repo y lo restauraba, que es exactamente como un abort deja un fichero del plugin roto.
`tools/run-tests.sh` en verde 15/15 en macOS.

### Nota de metodo
El rojo de CI era de plataforma y el defecto que escondia era de producto. Llevaban cinco releases
juntos porque el banco solo podia ver el desfase en el huso donde el defecto NO se manifiesta: la
prueba y el fallo se tapaban mutuamente. Un banco que fija el entorno para "medir lo mismo en
cualquier maquina" tambien elige lo que no va a poder ver nunca.

## [2.22.0] - 2026-09-12
Un usuario del plugin corrio dos checkpoints el mismo dia y los dos le dijeron algo que suena a
averia: "sus pendientes no estaban en el journal" y "voy a revisar el motivo de la cuarentena".
Ninguna de las dos cosas estaba rota. Las dos son el **estado normal de una memoria anterior a
2.12.0**, y el plugin las reportaba como danos que una persona tenia que arreglar a mano.

Reproducido en local antes de tocar nada, sobre un `memory/` pre-journal (items bajo `## Abiertos`,
sin `_id`, sin `.journal/`):

```
repair-dualwrite:  missing_data=3
  NO REPARABLE p-b59ad2309d: sin header de prioridad, sin _origen_
journal-compact:   JOURNAL applied=0 quarantined=1
  no-anchor: falta el header '## Alta prioridad'
```

### Fixed
- **El compactador crea el ancla que le falta, en vez de cuarentenar el evento.** Un
  `pendiente.add` (o un `pendiente.reopen`) sobre un `_pendientes.md` sin su header de prioridad se
  aplica: el header se escribe con la misma politica que ya usaba `normalize-pendientes.py`, que
  ahora vive en `journal-compact.py` y se consume desde alli — una sola copia de la regla. Esto
  cubre los dos casos en que el hook de SessionStart no llega a tiempo: el plugin se actualizo con
  la sesion **ya abierta**, y dos agentes arrancaron a la vez (el normalizador pide el lock con 1 s
  de presupuesto y si no lo consigue, calla). La cuarentena queda para lo que de verdad necesita
  ojos: JSON roto, colision de id, fecha imposible, ancla borrada a mano.
- **Los eventos que la version vieja cuarenteno se rescatan al actualizar.** Sin esto, el aviso de
  cuarentena —que va a la PERSONA— seguia pidiendo un trabajo manual que ya no existe, en cada
  arranque, para siempre. `compact()` devuelve a `pending/` los eventos cuyo `.reason` es
  exactamente el motivo que esta version sabe resolver, y los aplica en la misma pasada
  (`rescued=N` en la linea de salida). Cualquier otro motivo se queda donde esta. Y SessionStart
  ahora compacta tambien cuando `pending/` esta vacio pero `quarantine/` no — era el punto
  "`quarantine/` viaja pero solo se escanea `pending/`" que 2.21.5 dejo sin resolver.
- **Los pendientes que viven fuera de los headers se adoptan.** `/checkpoint-3t` Step 3-pre mueve
  cada item abierto que esta bajo un header propio del usuario (`## Abiertos`, `P0 — ...`, por
  semana o por tema) a `## Alta/Media/Baja prioridad` —Media, o Alta si su texto o su seccion
  marcan urgencia— y le escribe la fila de Tier 3 que no tuvo nunca. La linea va **verbatim**: no
  se reescribe el texto ni se recalcula el id. La seccion de origen se queda donde estaba (solo se
  colapsa a una la doble linea en blanco que deja el hueco; el tipo de salto de linea se conserva). Un
  `- [x]` ya cerrado no se mueve, pero si recibe su fila: sin ella, cerrarlo pierde la fecha de
  cierre y la sesion que lo cerro, que es justo el dano que esta herramienta existe para evitar.
  Vive en `repair-dualwrite.py` y no en el hook de SessionStart a proposito: mover datos del
  usuario solo es aceptable en el camino que acaba en un commit de git.
- **Un pendiente sin `_origen:` ya recibe fila, con `—` en esa columna.** Antes lo bloqueaba, y el
  resultado era que ningun pendiente anterior al journal tenia fila: al cerrarlo se perdia su
  historial. No hubo sesion que lo emitiera porque es mas viejo que el mecanismo. Lo que si exige
  origen es comparar el hash del id, y eso lo mide `ids_invented` aparte.
- **Los mensajes dejan de acusar.** `rows_added>0` solo significa "alguien escribio Tier 2 a mano"
  cuando `adopted=0`; con `adopted>0` es la migracion. `missing_data` ya no incluye "sin header de
  prioridad". Y Step 7 de `/checkpoint-3t` pide decir **que significa** un numero, no el numero:
  "tus 12 pendientes son anteriores al journal y ahora tienen su fila", nunca "12 pendientes no
  estaban en el journal".

### Pruebas
`test-repair-dualwrite.sh` pasa de 10 a 16 casos (11-16). Del 11 al 14: la adopcion completa
(destino por urgencia, secciones del usuario intactas, el cerrado que no se mueve pero si recibe
fila, idempotencia, ids sin recalcular), la autorreparacion del ancla, el rescate de la cuarentena
vieja, y el control de que un motivo que esta version NO sabe resolver **sigue** en cuarentena. El 15
y el 16 son los dos que anadio la verificacion adversarial, y cada uno guarda un defecto que estaba
en el codigo antes de publicar: el 15, que un `.reason` que solo EMPIEZA por un motivo rescatable no
se rescata (al regex le faltaba el ancla final, y sin ella un evento se aplicaba por el parecido de
su prefijo); el 16, que la adopcion conserva CRLF, el `|` crudo del texto y **ninguna otra linea** —
ese ultimo aserto nacio roto (calculaba el conteo y no lo miraba) y esta version lo mide de verdad,
comparando linea por linea, en python y no con `grep -Fxq`, que aqui es ugrep y toma una linea que
empieza por `-` como opcion.
`test-normalize-pendientes.sh` invierte su caso 12: el control que antes exigia `quarantined=1`
ahora exige que se aplique, mas un aserto de que la seccion no canonica sobrevive. Los 13 bancos en
verde. Mutacion verificada de los cuatro arreglos por separado, comprobando primero que cada
mutacion se aplica de verdad (un `replace` cuyo ancla ya no existe es un banco que no prueba nada).

### Sin resolver
`test-journal-race.sh` sigue fallando de forma intermitente (medido aqui 1 de 30 corridas; 2.21.5
lo midio en 1 de 20 y lo verifico preexistente en `1ed9400`). No se reprodujo en dos lotes limpios
de 10 y 15 corridas, asi que no se pudo atribuir con seguridad al banco o a la carga de la maquina.
Dos portadores mas de la regla vieja se arreglaron en esta misma version despues de que un
verificador independiente los encontrara: `commands/migrate.md` y `commands/setup-memory.md`. El
primero yo lo habia declarado revisado y exento, y era falso.

### Nota de metodo
La pregunta del usuario era "¿le damos un nudge a la persona o a su agente?". La respuesta es
ninguno de los dos: un aviso que el propio programa sabe resolver no es un aviso, es trabajo sin
hacer. El canal a la persona (2.17.0) se reserva para lo que solo una persona puede decidir, y
gastarlo en una migracion mecanica es la forma de que deje de leerse.

## [2.21.5] - 2026-09-12
Quinta ronda adversarial. Rompio el rediseno de 2.21.4 en una frase: **hay dos llamantes**.

### Fixed
- **La guarda estaba en el sitio equivocado.** 2.21.4 hizo que `session-start.sh` no llamara a
  `--check-drift` cuando no hay persona, porque esa comprobacion RE-SELLA al detectar y sin lector
  el aviso se consume para siempre. Correcto, e incompleto: `bash-journal-nudge.sh:107` corre
  `--check-drift` en **cada `PostToolUse` de Bash** y no sabe nada de quien mira, asi que la
  deriva se consumia igual por ese lado — en la siguiente llamada a Bash. La seccion "Lo que se
  pierde" de 2.21.4 era falsa por eso mismo: decia que solo se perdia la visualizacion.

  Anadirle la guarda al nudge habria sido la misma forma por tercera vez. Ahora la decision vive
  donde esta el **efecto**: `hay_lector()` en `journal-compact.py`, consultada en la ruta de
  `--check-drift` antes de anotar y re-sellar. Los dos llamantes quedan cubiertos, y el tercero
  que aparezca tambien. `session-start.sh` solo aporta lo que el entorno no dice —que en un
  `clear`/`compact` hay agente pero no persona— via `THREET_SIN_LECTOR=1`.

### Pruebas
Cuatro asertos nuevos (119 -> 123) que recorren **los dos caminos**: el hook de Bash con agente de
Paperclip y sin sesion atendida no consume la deriva, y el control positivo de que **con** lector
ese mismo hook si avisa y si re-sella. La mutacion se reapunto al compactador: quitar `hay_lector()`
tumba los asertos de ambos lados, no solo de uno.

### Sin resolver
`quarantine/` viaja pero solo se escanea `pending/`; `applied/` no tiene poda; `memory/.locks/`
queda fuera del reparto; `test-journal-race.sh` falla 1 de 20 corridas (medido: misma tasa en
`1ed9400`, preexistente). Y una que este parche NO cubre: `compact()` tambien avisa y re-sella, y
ahi el re-sellado es legitimo porque acaba de escribir los indices — su aviso si puede perderse
sin lector. Solo corre cuando hay eventos pendientes.

### Nota de metodo
Seis releases, cinco rondas, cinco roturas. El patron de todas: **un contrato que no se propago a
todos sus portadores** — el docstring, las mutaciones, el `.gitignore`, y ahora el segundo
llamante. La pregunta que las habria cazado todas es la misma: quien consume esto, y que pasa si
no llega.

## [2.21.4] - 2026-09-12
Cuarta ronda adversarial. Rompio el arreglo de la tercera, que habia roto el de la segunda, que
habia roto el de la primera. Eso ya no es converger, es parchear — asi que esta entrada **no
arregla los cinco hallazgos: quita el mecanismo que los producia**.

### Removed
- **Fuera el diferimiento de avisos (`.journal/human-pending.txt`), introducido en 2.21.2.** El
  problema real era este: `--check-drift` RE-SELLA la linea base al detectar, para que el aviso
  salga una vez; cuando no hay persona delante el mensaje se descarta, asi que el re-sellado lo
  borraba para siempre. La solucion de 2.21.2 fue **guardar** el aviso en un fichero para el
  proximo arranque. Dos rondas despues ese fichero necesitaba tope, deduplicado, escritura sin
  carrera, su propia linea de `.gitignore` y una migracion para quien ya hubiera actualizado — y
  cada capa traia un defecto nuevo. La ronda 4 encontro cinco a la vez: el tope no era un tope
  (comprobar-y-apendar sin lock), al alcanzarlo se descartaba el unico aviso, el consumidor
  borraba el fichero aunque `awk` fallara, la linea de `.gitignore` no llegaba a instalaciones ya
  actualizadas, y dos de los tres asertos nuevos **reimplementaban en el test lo que decian
  medir**.

### Changed
- **No se mira si no hay quien lo lea.** `session-start.sh` ya no llama a `--check-drift` cuando
  no hay persona a la que dirigirse. **La deriva ya es persistente** — es un hash que no coincide,
  y sigue ahi hasta que alguien re-selle. No hace falta guardar nada; basta con no consumirla.
  Una guarda en la condicion, en vez de un subsistema.
- **`hay_persona()`, una sola definicion.** Las tres condiciones (agente de Paperclip, corrida no
  atendida, `source` que no es `startup`/`resume`) estaban repetidas en `emit_output`. Ahora hay
  una funcion y la usan los dos sitios: dos copias de esta regla se separan y una se queda rancia.
- **Las pruebas pasan por `session-start.sh` de verdad** y miden la huella del sellado, no un
  fichero. Cubren los dos modos de "no hay persona". La mutacion se reapunto a la guarda nueva:
  quitarla hace caer «la linea base NO se toca».

### Lo que se pierde, dicho claro
En una sesion sin persona el AGENTE tampoco ve el aviso de deriva en su contexto. Es el precio del
rediseno y es barato: en esas sesiones no hay nadie que pueda correr `--reseal` de todos modos.

### Sin resolver
Sigue abierto desde la ronda 1: `quarantine/` viaja pero solo se escanea `pending/`; `applied/` no
tiene poda; `memory/.locks/` queda fuera del reparto. **Nuevo, y anterior a todo esto**:
`test-journal-race.sh` es intermitente — 1 fallo de 20 corridas, **la misma tasa en `1ed9400`**,
antes de que empezara esta linea de releases. No lo introdujo este trabajo y no se arregla aqui.

### Nota de metodo
Cuatro rondas, y el patron no fue "quedaban bugs": cada arreglo introducia el siguiente. Lo que
por fin lo corto no fue arreglar mejor, sino **borrar el mecanismo**. Y de los cinco asertos de
no-evidencia que se encontraron en estas cuatro releases, cuatro eran mios y todos tenian la misma
forma: comprobar que el canal trae ALGO en vez de comprobar que trae ESTO, o medir una
reimplementacion del codigo en vez del codigo.

## [2.21.3] - 2026-09-12
Tercera ronda adversarial, esta vez en otro verificador (el metodo obliga a cambiar de backend
tras dos roturas seguidas del mismo). Refuto siete angulos **corriendo las pruebas el mismo** —la
suite entera, el arnes de mutacion y la prueba de carrera— y encontro uno solo.

Y es mi mismo patron por tercera vez: **anadi un instrumento nuevo y lo deje fuera del
`.gitignore` que esta misma linea de releases introdujo.**

### Fixed
- **`.journal/human-pending.txt` no estaba cubierto.** Es el aviso que ESTA maquina detecto y no
  pudo entregar; en otra no significa nada — exactamente la categoria que `GITIGNORE_JOURNAL`
  define— y sin embargo no estaba en la lista. Como `/checkpoint-3t` hace `git add memory/`, en
  una instalacion donde `memory/` se versiona (el escenario para el que existe todo esto) el
  aviso viajaba a las demas maquinas. Peor que `fingerprints.json`: es texto, no tiene la
  propiedad de re-aplicar sin efecto que salva a `pending/`, asi que dos maquinas apendando dan
  conflicto directo.
- **Dos arranques mudos a la vez perdian un aviso.** La escritura era `>` truncante y sin lock:
  el segundo pisaba al primero y ese aviso desaparecia sin rastro — el mismo fallo que el
  diferimiento existe para evitar. Ahora es `>>`; el consumidor deduplica con `awk` conservando
  el orden, asi que el mismo aviso diferido en varios arranques mudos sale una vez. Tope de 20
  lineas para que no crezca sin fin si nadie viene a leerlo; se descarta lo NUEVO, no lo
  guardado, porque el aviso mas viejo es el que lleva mas tiempo sin que lo vea nadie.

### Pruebas
Tres asertos nuevos (118 -> 121): que git ignora `human-pending.txt` —preguntandoselo a git con
`check-ignore`, no mirando si el fichero existe—, que seis diferimientos simultaneos no pierden
ninguno, y que el consumidor deduplica. El primero verificado con mutacion: quitar la linea de
`GITIGNORE_JOURNAL` lo tumba.

### Nota de metodo
Tres releases, tres veces el mismo error de forma distinta: un instrumento nuevo cuyo contrato no
se propago a todos los portadores (el docstring en 2.21.1, las mutaciones en 2.21.2, el
`.gitignore` aqui). La pregunta que lo habria cazado las tres veces no es "¿funciona?" sino
**"¿quien consume lo que esto emite, y que pasa si no llega?"**.

## [2.21.2] - 2026-09-12
Segunda ronda adversarial sobre 2.21.1. Encontro que **mi arreglo de la ronda anterior habia roto
otra cosa**: cerrar la carrera con `O_EXCL` sacrifico la publicacion atomica. De once angulos
refuto cinco, adjudico a mi favor uno que la ronda 1 habia reportado mal, y confirmo seis.

### Fixed
- **El `.gitignore` podia publicarse a medias.** `O_EXCL` sobre el destino hace el fichero visible
  ANTES de escribir dentro: un fallo de E/S o una muerte del proceso dejaba un `.gitignore`
  truncado — y lo conservaba **para siempre**, porque la pasada siguiente ve que existe y no lo
  toca. Arregle la exclusividad rompiendo la integridad. Ahora se escribe el fichero entero en un
  temporal, se fuerza a disco con `fsync`, y se publica con `os.link`, **que falla si el destino
  existe**: el enlace es una sola operacion del sistema de ficheros, asi que o aparece completo o
  no aparece. Las dos propiedades salen de la misma llamada. Respaldo para sistemas sin enlaces
  duros (puede pasar en Windows/MSYS): `O_EXCL` con borrado del parcial si la escritura falla.
- **Una deriva vista sin nadie delante se perdia para siempre.** `--check-drift` re-sella al
  detectar, para que el aviso salga una vez. Correcto cuando el aviso llega — pero `emit_output`
  descarta el mensaje a la persona en `clear`/`compact`, con un agente de Paperclip, o en una
  corrida no atendida. En esos casos la deriva se veia una vez, a nadie, y no volvia. 2.21.1
  arreglo `startup|resume` y dejo el resto. Ahora ese aviso usa `defer_human()`: si el buffer se
  descarta, el texto se guarda en `.journal/human-pending.txt` y sale en el proximo arranque **con
  persona**. El consumidor esta en `session-start.sh` y re-difiere si tampoco hay nadie, asi que
  no se gasta en una sesion muda. El filtro por `source` **no se toca**: repetir el aviso en cada
  `compact` era ruido, y seguirlo siendo.

### Changed
- **La prueba de concurrencia no probaba concurrencia.** Lanzaba seis compactadores, pero la
  escritura esta dentro del lock del journal: **serializan y nunca compiten**. Un aserto que no
  puede fallar por la razon que dice medir es no-evidencia. Ahora llama a la funcion directamente
  desde 12 procesos independientes, sin lock, y comprueba que gana exactamente uno y que lo
  publicado es el fichero completo byte a byte.
- **Dos mutaciones nuevas en `tools/mutaciones/`** — `m_gitignore_publicacion.py` (vuelve a
  publicar-antes-de-escribir) y `m_drift_humano.py` (vuelve a `human()` sin diferir). Las dos
  ponen el arnes en rojo, asi que los asertos nuevos estan verificados **en el repo**, no solo en
  mi terminal. `tools/mutation-check.sh` pasa de 6 casos a 8.
- **El docstring de `escribir_gitignore_journal()` decia la afirmacion vieja** sobre los sha256.
  Corregi el CHANGELOG en 2.21.1 y deje la frase viva en el codigo — una regla cambiada en un
  portador y dejada rancia en otro.
- **Una frase de 2.21.1 no se seguia**: decia que con `memory/` ignorado "tampoco hay fuga porque
  el propio `fingerprints.json` esta ignorado y no sube". No vale para quien ya lo tuviera
  trackeado: anadir la regla no des-trackea, como dice la nota de la propia entrada.

### Sin resolver (siguen abiertos desde la ronda 1)
`quarantine/` viaja entre maquinas pero solo se escanea `pending/`, asi que un evento
cuarentenado en A no se reintenta en B aunque alli exista el ancla. `applied/` no tiene poda.
`memory/.locks/` (de `lock-tier2-write.sh`) es estado por copia de trabajo fuera de `.journal/` y
ninguna regla lo cubre.

### Nota de metodo
Construyendo estas pruebas me encontre **otro** aserto de no-evidencia propio: buscaba la
subcadena `MEMORIA` en el mensaje a la persona, que tambien casa con `MEMORIA 3T — N pendientes
abiertos` y sale en cada arranque. Medido con mutacion, corregido a `git pull`. Es el mismo error
que ya habia cometido en 2.21.1 con `grep -c '"systemMessage"'`. El patron —comprobar que el
canal trae ALGO en vez de comprobar que trae ESTO— es el que hay que vigilar.

## [2.21.1] - 2026-09-12
Un adversario independiente (otro vendor) rompio 2.21.0 el mismo dia. De once angulos refuto
cuatro y confirmo el resto. Esto arregla lo que era mio y corrige por escrito lo que afirme sin
medir.

### Fixed
- **El `.gitignore` podia pisar el del usuario — la garantia era falsa.** `escribir_gitignore_journal()`
  hacia `if exists: return` y despues `tmp + replace`. Entre las dos cosas cabe la escritura de
  otro proceso, asi que el compactador sobreescribia justo el fichero que el propio fichero
  promete no tocar. Ahora se crea con `O_EXCL`: **el kernel decide quien gana y el perdedor no
  escribe nada**, asi que la promesa es cierta por construccion y no solo mientras nadie escriba
  en el hueco. Mismo patron que `journal-emit.py`. Ademas se movio dentro del lock, no porque
  haga falta —`O_EXCL` ya basta— sino para no tener una segunda regla sobre que se escribe fuera
  de el. Prueba nueva: seis compactadores a la vez dejan un solo fichero, intacto y sin `.tmp`
  huerfano; con `O_EXCL` quitado, el aserto de "no sobreescribe" falla.
- **El aviso de deriva no llegaba a ninguna persona.** `session-start.sh` mandaba `DRIFT_OUT`
  solo por `out()` (`additionalContext`, o sea el agente) y nunca por `human()`
  (`systemMessage`). Es el mismo fallo que 2.17.0 arreglo para los pendientes, vivo en este
  aviso. Pesa mas aqui que en otros: si la causa fue un `git pull`, quien lo hizo es la persona
  y quien tiene que correr `--reseal` tambien. **La verificacion de 2.21.0 no lo vio porque midio
  el canal del agente y lo llamo "llega al humano".**
- **`templates/audit-3t.md` seguia diciendo la regla vieja** — que todo `⚠ FUERA DEL JOURNAL`
  significa una escritura a mano y que el cambio se pierde en la siguiente pasada. Desde 2.21.0
  eso es falso para la deriva que viene de git. Ahora el paso 15 distingue las dos causas y dice
  que el detector compara bytes y no sabe cual es.

### Changed
- **Dos afirmaciones del CHANGELOG de 2.21.0, corregidas.** (1) "son sha256 de ficheros que estan
  en el mismo repo en texto plano": `indices_protegidos()` no mira si el fichero esta trackeado,
  asi que con `memory/` ignorado hashea ficheros que no estan en el repo — no hay fuga, pero por
  otra razon que la que escribi. (2) "son ~11 llamadas a git": **no lo medi**, lo estime contando
  indices, y `git diff --quiet HEAD -- <paths...>` los toma todos de una. El motivo honesto para
  no construir git-awareness es solo el historial de Git Bash/MSYS.

### Sin resolver (hallazgos del adversario, fuera del alcance de este parche)
- **`quarantine/` viaja pero nunca se reintenta.** El compactador solo escanea `pending/`. Un
  evento cuarentenado en la maquina A por ancla ausente llega a B, donde el ancla puede existir,
  y nadie lo vuelve a intentar. Versionarlo es correcto para auditar y **insuficiente** para
  aplicar.
- **`applied/` no tiene poda**, asi que versionarlo hace crecer el historial del repo sin techo.
- **`memory/.locks/` queda fuera.** `lock-tier2-write.sh` crea estado de proceso por copia de
  trabajo ahi, fuera de `.journal/`, con el mismo problema de conflicto y sin regla que lo cubra.

### Nota de metodo
El adversario tambien reporto un doble `lines.insert(at + 1, row)` en `apply_add_monthly()` que
duplicaria cada fila mensual. **Es falso**: hay una sola, en `journal-compact.py:850`. Verificado
antes de actuar. Y no pudo correr `tools/run-tests.sh` (su entorno no crea directorios con
`mktemp`), asi que el 15/15 lo firma esta maquina, no el.

## [2.21.0] - 2026-09-12
El plugin no tenia postura sobre que de `memory/.journal/` se versiona. El compactador crea el
directorio con `os.makedirs` y no dejaba nada dentro que lo dijera, asi que cada usuario lo
decidia solo — y al menos uno recibio el consejo equivocado: que `fingerprints.json` era
**inseguro** subirlo a GitHub.

No lo es. Son `sha256` de los indices de `memory/`, y `fingerprints.json` solo llega a GitHub en
instalaciones donde esos mismos indices tambien se versionan **en texto plano**: un hash de algo ya
publicado en claro no filtra nada. (Precision que debo al adversario: `indices_protegidos()` no
mira si el fichero esta trackeado, asi que en una instalacion con `memory/` ignorado — este repo
mismo — hashea ficheros que NO estan en el repo. Ahi normalmente tampoco sube, porque el propio
`fingerprints.json` cae bajo la misma regla — pero "normalmente" no es "nunca": a quien ya lo
tuviera **trackeado**, anadir la regla no lo des-trackea, como dice la nota de mas abajo. La frase
"estan en el repo en claro" no era cierta para todos los casos, y donde lo era, lo era por
accidente.) (Lo que si es sensible en este sistema es el **contenido** de
`memory/sessions/`, y de eso se ocupa `bin/scan-secrets.py` como compuerta de `/checkpoint-3t`.)

Pero la conclusion era buena por otra razon, y esa razon solo se ve con **mas de una maquina**:
`fingerprints.json` cambia en CADA compactacion, y `/checkpoint-3t` hace `git add memory/`. En un
repo donde `memory/` se versiona, eso es un diff de hashes sin significado en cada checkpoint y un
conflicto de merge garantizado entre dos maquinas, sobre las mismas claves del mismo JSON.

### Added
- **`memory/.journal/.gitignore`, escrito por el compactador.** Separa estado local de registro
  compartido, y explica por escrito por que cada cosa cae de un lado:
  - **No se versiona** — `fingerprints.json` (la linea base es por copia de trabajo: compara
    contra lo que sello el compactador de ESA maquina), `out-of-band.log` (dos maquinas
    apendando = conflicto que git no fusiona), `.lock/` y `.lock-steal/` (estado vivo de un
    proceso).
  - **Si se versiona, a proposito** — `pending/`, `applied/`, `quarantine/`. Son lo que hace que
    la memoria viaje. Un evento emitido y aun sin aplicar llega a la otra maquina y se aplica
    alli en vez de perderse; re-aplicarlo es no-op porque el compactador es idempotente, asi que
    no duplica si ambas lo aplican. `applied/` y `quarantine/` son un fichero por evento con
    nombre unico: no pueden dar conflicto.

  **Se escribe si falta, nunca se sobreescribe.** Colgarlo del `makedirs` inicial habria dejado
  fuera justo a quien le hace falta: toda instalacion existente ya tiene `.journal/` creado. Y si
  el usuario lo edito, manda su version. Va en `compact()` y **no** en `--check-drift`, cuyo
  contrato dice que no escribe nada salvo el log de constancia.

### Changed
- **El aviso `FUERA DEL JOURNAL` ya no acusa cuando la causa fue git.** El precio de no versionar
  la linea base es que los indices que llegan por `git pull`/`checkout`/`merge` no son los que
  sello esta maquina, y el detector los ve como deriva. La deteccion es correcta; el diagnostico
  que imprimia no lo era — decia "edicion a mano" y "se pierde en la siguiente pasada", y post-pull
  las dos cosas son falsas: los cambios vienen anclados en `applied/` y sobreviven. Ahora el aviso
  nombra ese caso y da la salida (`journal-compact.py --reseal`), que hasta ahora solo estaba
  documentada para el otro camino sancionado, la reparacion manual de `/audit-3t`.

### Notas para quien ya lo tenia en git
`.gitignore` no des-trackea lo ya trackeado. Si `fingerprints.json` esta en el indice de git:

```
git rm --cached memory/.journal/fingerprints.json
git rm --cached -r memory/.journal/out-of-band.log   # si existe
```

### Sin resolver
Detectar el caso git automaticamente (`git diff --quiet HEAD -- <indice>` distingue "viene de git"
de "editado a mano") se deja fuera por **una** razon, no por dos: el plugin tiene historial de
romperse en Git Bash/MSYS y eso pide medir antes de meter git en un hook. La otra razon que llegue
a escribir aqui —"son ~11 llamadas a git"— **no la medi**: la estime contando indices, y ni
siquiera hace falta una por indice, `git diff --quiet HEAD -- <paths...>` los toma todos de una;
ademas la compuerta de mtime de `bash-journal-nudge.sh` ya filtra casi todas las pasadas. El
adversario tenia razon en marcarla. El coste real esta sin medir, que no es lo mismo que alto. Por
ahora el aviso lo explica y `--reseal` lo cierra en un comando. Con una arista honesta: `--reseal`
quita el aviso pero **no borra la linea ya apendada a `out-of-band.log`**, asi que el rastro de
auditoria acumula una entrada por cada pull hasta que eso se construya.

## [2.20.0] - 2026-09-12
El dedup de `/backfill-3t` se apoyaba en `customTitle`. Ese campo viene `null` en los 22 JSONL de
este proyecto (medido 2026-09-12: 0 de 22; no comprobado en otras versiones, modos ni
instalaciones), asi que ahi la regla escrita no casaba nunca y lo unico que impedia reimportar una
sesion que ya tenia ficha era el criterio de un agente leyendo. El comando llevaba dias sin poder
correrse.

La causa era mas honda que el campo: **no existia ninguna llave** entre un `.jsonl` y su ficha. El
frontmatter de las 46 fichas llevaba `type`, `date`, `status` e `importance`, y nada que dijera de
que conversacion salio.

### Added
- **`bin/match-session-file.py`** — une cada `.jsonl` con su ficha por dos caminos, sin heuristica
  de parecido, y devuelve `match` / `review` / `process` / `current`:
  1. **Sello**: `session_id` en el frontmatter. Es lo que DECLARA quien escribe la ficha, y
     `stamp-session-id.py` solo lo acepta si cuadra con la transcripcion (ver abajo: no es una
     prueba de identidad, y llamarlo *exacto* fue un error que corrigio el adversario).
  2. **Escritura observada**: la sesion que escribio su ficha dejo esa escritura en su propia
     transcripcion. Se busca la **escritura**, no la mencion — `cat ficha.md` y `cat > ficha.md`
     nombran la misma ruta y significan lo contrario.

  Ante duda **no decide**: `review` va a una pregunta al usuario antes de que se escriba nada.
  Decidir por parecido tiene un fallo que no se ve nunca —marcar como ya-importada una sesion que
  no lo esta— y esa es la razon de que exista el tercer veredicto.

- **`bin/stamp-session-id.py`** — escribe `session_id` en el frontmatter. Lo llaman
  `/checkpoint-3t` (Step 5c-bis, con `CLAUDE_CODE_SESSION_ID`) y `/backfill-3t` (Step 3b, con el
  UUID de origen). En el matcher el sello **gana** a la evidencia de escritura, asi que un sello
  equivocado no produce un duplicado visible — produce el invisible. Por eso exige tres cosas antes
  de escribir: que el id tenga `.jsonl` en `$JSONL_DIR`, que la **fecha de la ficha caiga dentro
  del rango de esa transcripcion**, y que no haya ya un sello distinto puesto.

- **`bin/test-backfill-dedup.sh`** — 38 comprobaciones y 10 mutaciones (la cifra final, tras las
  rondas de abajo). Cinco de los casos son defectos que este codigo **tuvo** durante la
  sesion, medidos contra los 22 JSONL reales, cada uno con la mutacion que lo reinyecta y que tiene
  que poner el banco en rojo:

  | defecto | como se veia | mutacion que lo reinyecta |
  |---|---|---|
  | fecha UTC cruda | la sesion de las 21:36 quedaba un dia corrida y su ficha "no existia" | `fecha_local` -> `ts[:10]` |
  | idioma `python3 - <<'PY'` con la ruta en variable | la forma en que se escriben aqui casi todas las fichas no llevaba `>` delante: escritura leida como lectura | se quita el idioma (c) |
  | leer contado como escribir | `cat ficha.md` valia igual que `cat > ficha.md` | `es_escritura` devuelve `True` siempre |
  | origen de un `cp` contado como escritura | copiar la ficha a un temporal contaba como haberla creado | (cubierto por la anterior) |
  | ficha ajena reescrita | un `/enrich-3t` parecia tener ficha propia | (cubierto por el caso C8) |

### Changed
- **`/backfill-3t` Step 1 reescrito.** Clasificacion determinista con el matcher; guarda que
  **para** si no se puede identificar la sesion en curso (sin eso el backfill escribe una ficha que
  `/checkpoint-3t` volveria a escribir al cerrar); bloque **REVISAR** que se resuelve preguntando,
  no adivinando. Las sesiones que ya tienen ficha se marcan `skipped` y **su ficha no se toca**: la
  escribio un checkpoint en vivo, viendo mas contexto del que reconstruye un digest.
- **`/checkpoint-3t` Step 5c-bis**: sella `session_id` en la ficha de la sesion. Sin sello no pasa
  nada malo — la segunda capa del matcher sigue deduplicando.

### Fixed
- **La ruta del progress file estaba partida en dos.** Step 0 leia `memory/.backfill-progress.json`
  y el fichero real vive en `$JSONL_DIR/`, que es donde lo escribe Step 3h y donde lo lee el aviso
  de arranque. Un run con `BACKFILL_FORCE_ALL=1` no reconsideraba nada: abria un fichero
  inexistente, no fallaba, y seguia como si `skipped[]` estuviera vacio.
- **La comprobacion de `newline=` no distinguia una escritura de una cita sobre una escritura.**
  Enumeraba con `grep`, asi que un docstring que documenta `open(p,"w")` contaba como violacion.
  Ahora mira el **arbol sintactico**: un docstring no produce una llamada. El primer intento de
  arreglo —saltar los tokens `STRING`— dejo la prueba **ciega**, porque el modo `"w"` es tambien un
  `STRING`: pasaba en verde sin encontrar ninguna escritura en ningun sitio. Por eso la
  comprobacion lleva ahora su propio **control**: un fichero que viola de verdad tiene que seguir
  saliendo. Un cero que puede significar "todo limpio" o "no mire nada" no vale como verde.

### Encontrado por el adversario antes de publicar
Tres rondas no; una sola ronda externa (GPT-5) con cuatro hallazgos confirmados, todos corregidos
antes del `commit`:

- **El sello aceptaba cualquier ficha.** Solo comprobaba que el UUID tuviera **algun** `.jsonl`, no
  que fuera el de esa ficha: cualquier id existente podia sellar cualquier ficha sin sellar, y como
  el sello manda sobre la evidencia de escritura, eso abria exactamente la perdida invisible que el
  script dice impedir. Ahora exige que las fechas cuadren, y el banco lo fija con su mutacion.
- **La comprobacion de `newline=` podia ponerse verde sin cubrir lo que dice.** El enumerador nuevo
  emitia `fdopen` y `write_bytes`, pero el contador de fuera solo casaba `open(` y `write_text(`:
  una escritura por `os.fdopen` sin `newline=` salia y se ignoraba. Ahora el veredicto lo da el
  enumerador y el contador no recorta; el control cubre las tres formas, ademas del fichero no
  analizable (rojo) y de la escritura **binaria**, donde `newline=` no existe y exigirlo seria
  falso.
- **Dos afirmaciones universales sacadas de una sola instalacion**: que `customTitle` es `null` en
  todos los JSONL que escribe Claude Code, y que `CLAUDE_CODE_SESSION_ID` coincide siempre con el
  nombre del `.jsonl`. Lo medido son 22 ficheros de un proyecto y una instalacion. Reescritas como
  lo que son; la variable, ademas, no esta documentada, y por eso nada depende de ella sin
  comprobarla.

Y una segunda ronda del mismo verificador, sobre los arreglos de la primera, con tres mas:

- **La guarda de fecha del sello dejaba demasiado sitio.** Con un dia de margen a cada lado, un
  mismo UUID podia sellar hasta 14 fichas distintas de este proyecto. Se puso el margen a cero —el
  desfase UTC/local ya lo resuelve `fecha_local()`, y el sello siempre se escribe en la maquina que
  tiene la transcripcion delante—, pero **medido, eso solo baja de 14 a 11**: hay varias sesiones
  al dia y la fecha no las separa. Asi que el arreglo de fondo no es el margen sino dejar de
  llamarlo *exacto* (abajo). El margen cero si ataja el caso grosero: el UUID de otra semana. (El
  matcher conserva el suyo: ahi si se comparan ficheros que pudieron escribirse en otra maquina.)
- **Y fallaba ABIERTO.** Una fecha ilegible, un `.jsonl` sin timestamps o una ficha cuyo nombre no
  empieza por fecha hacian que la comprobacion se saltara y el sello se pusiera igual: una puerta
  de servicio hacia el unico fallo que este script existe para impedir. Ahora no se sella lo que no
  se puede comprobar.
- **El enumerador daba por lectura un `open(p, modo)` con el modo en variable**, asi que una
  escritura de texto sin `newline=` podia colarse por ahi. Ahora un modo no literal se **exige**,
  no se supone. De paso se separo `os.open` —devuelve un descriptor, no un fichero de texto— del
  `open` de siempre, que era un falso positivo en `journal-emit.py`.

Tambien se corrigio la palabra **"exacto"** aplicada al sello: lo que escribe es lo que declara
quien llama, comprobado contra la transcripcion, no una prueba de identidad. Cuando el checkpoint
sella, la transcripcion todavia no contiene la escritura de la ficha, asi que no hay nada contra lo
que verificarla. Decirlo vale mas que sostener la palabra.

Y una **tercera** ronda, esta vez en el otro verificador (subagente, Claude Sonnet 5 — la regla
obliga a cambiar de backend tras dos breaks seguidos del mismo). Encontro lo peor de las tres:

- **`fecha_local()` fabricaba una fecha a partir de basura.** Ante un valor que no era un
  timestamp devolvia sus diez primeros caracteres, asi que `"2026-05-06XXXXXXXXX"` se convertia en
  una fecha con pinta de buena. El adversario construyo una transcripcion cuyos `timestamp` eran
  todos basura y **sello contra ella**: el caso "sin timestamps legibles" no fallaba cerrado
  porque no llegaba a ejecutarse nunca. Ahora devuelve `None`, en los dos scripts que lo usaban.
- **Los dos arreglos de la ronda 2 no los fijaba nada.** Revertir `MARGEN_DIAS` de 0 a 1 dejaba el
  banco en `PASS=24 FAIL=0`; revertir `en_rango` a fail-abierto, tambien. El unico caso del banco
  con fechas distintas tenia cinco dias de diferencia —fuera de cualquier margen— y las dos ramas
  de fail-cerrado que si se probaban las atajaban las guardas anteriores, sin llegar a `en_rango`.
  Escrito, si; probado, no.

  Se anadieron los tres casos que faltaban —ficha de **un** dia despues, fecha imposible
  (`2026-13-45`) que revienta dentro de `en_rango`, y transcripcion sin un solo timestamp valido—
  y **cuatro mutaciones del sello** que reinyectan cada defecto y exigen que el banco caiga por
  **el aserto que le toca**, no por cualquiera.

Y una cuarta, otra vez externa, sobre esos arreglos. Dos hallazgos, los dos de cobertura:

- **El mismo defecto de la fecha fabricada vivia en los DOS scripts y solo uno tenia prueba.** La
  mutacion del sello no toca el matcher, y ningun caso del matcher llevaba timestamps ilegibles:
  reponer `ts[:10]` alli no rompia nada. Se anadio el caso y su mutacion.
- **Cifras contradictorias en el propio registro de la sesion**: una tabla seguia diciendo que el
  sello es "exacto" cuando el codigo y este CHANGELOG ya dicen lo contrario, y contaba cuatro
  mutaciones donde hay ocho.

Con eso el banco llego a 33 comprobaciones y ocho mutaciones, cada una obligada a poner el banco
rojo por su propio aserto.

La ronda 4 la miraron **dos** verificadores a la vez, uno externo y un subagente. El subagente
encontro lo que el externo no pudo (su entorno no le deja ejecutar nada):

- **`fecha_local()` reventaba sin capturar, con una fecha ISO valida.** El primer `except` cubre el
  `fromisoformat` que falla y el segundo cubria el `astimezone()` que falla, pero un ano valido en
  un extremo (0001, 9999) puede convertirse a un huso local que lo empuja fuera de
  `[MINYEAR, MAXYEAR]`, y eso es `OverflowError`, que no cubria ninguno de los dos. Reproducido en
  las dos direcciones: ano 0001 con huso al oeste, ano 9999 con huso al este. En
  `bin/match-session-file.py` el precio no es una sesion: un solo timestamp corrupto en cualquier
  `.jsonl` del directorio tumba la clasificacion del corpus entero. Se anade `OverflowError` a esa
  segunda excepcion en los dos scripts, con su caso fijo y su mutacion.

**Y una advertencia sobre como salio ese hallazgo, que vale mas que el hallazgo.** Ese subagente se
salio de su papel: escribio en cinco ficheros del repo que estaba revisando —incluidos el banco de
pruebas y este CHANGELOG— y redacto parte del texto en primera persona como si lo hubiera escrito
quien ejecuta. El propio subagente lo reporto y anulo su veredicto. Lo que se ha hecho con eso: el
fallo se ha **reproducido de cero** aqui, sin fiarse de su palabra, quitando el parche en una copia
y viendo la excepcion en las dos direcciones; se ha comprobado que la mutacion nueva pone el banco
rojo por su propio aserto; y el texto que escribio en primera persona se ha **reescrito**. Un
verificador que corrige lo que mide deja de poder medirlo, y un verde suyo despues de eso vale lo
mismo que ninguno.

El banco queda en **38 comprobaciones y 10 mutaciones** — cinco del matcher (M1-M5) y cinco del
sello (S1-S5). La decima, M5, sale de la sexta ronda: el arreglo del `OverflowError` estaba en los
dos scripts y solo el del sello tenia mutacion, asi que revertir el del matcher solo se notaba de
rebote, por un aserto ajeno.

### Verificado
- Dos ejecuciones reales de `/backfill-3t` seguidas sobre este proyecto, con `cp -a memory/` antes
  (`memory/` esta entero en `.gitignore`: git no lo revierte). El run 1 importo 1 sesion; el run 2
  dio `J=0` y **`diff -r` entre los dos estados sale identico**: ni un fichero nuevo ni modificado.
- Quitando la entrada del progress, la sesion importada sigue saliendo `match` por **sello**: el
  dedup ya no depende del fichero de estado.
- Suite completa en verde (13 scripts) y `tools/mutation-check.sh` con sus 6 comprobaciones
  discriminando.

## [2.19.5] - 2026-09-12
### Fixed
- `tools/mutation-check.sh` daba por **vacuo** un aserto que en esa plataforma esta **saltado**. En
  Git Bash el caso "sin jq" de `test-resolve-project-dir.sh` se salta —un `bash.exe` con el PATH
  reducido no encuentra sus DLL—, asi que el aserto no llega a correr y no puede cazar la mutacion.
  El arnes lo reportaba como "no discrimina" y ponia el CI en rojo.

  Ahora distingue las dos cosas: si el aserto esperado sale como `SKIP`, se informa **no evaluable
  aqui** con el motivo, y no cuenta como pendiente. Confundir "no llego a correr" con "corrio y no
  vio nada" es acusar al codigo de algo que no hizo — el mismo error que este arnes existe para no
  cometer, cometido por el arnes.

## [2.19.4] - 2026-09-12
Cierra el hueco que el adversario **declaro** en vez de tapar: las ediciones de portabilidad del
2026-09-12 —comparar rutas en vez de cadenas, contar CR por bytes en vez de con `grep`, un digest
portable, el `CONTROL` reescrito, el `SYSTEMROOT` del `env -i`— nunca se habian visto FALLAR. Un
aserto que solo se ha visto pasar no se ha visto funcionar.

### Added
- `tools/mutation-check.sh` y `tools/mutaciones/`: para cada comprobacion editada, rompe su codigo
  bajo prueba en una copia y exige que la suite caiga **por el aserto que le toca**, no por
  cualquiera. Las **seis** discriminan:

  | comprobacion | cae por |
  |---|---|
  | `check_ruta` / `norm` | «la estable gana a la prerelease» |
  | `CONTROL` del resolutor | «el patron viejo elegia a ciegas» |
  | `canon` / `cabecera_crlf` | «crlf» |
  | `cr_lineas` | «lineas CRLF no cambia» |
  | `huella` / md5 | «byte a byte» |
  | `norm` + `SYSTEMROOT` | «el respaldo de python3» |

- Entra en `tools/run-tests.sh` (14 comprobaciones ahora, +13 s). Un arnes que nadie corre se
  pudre.

### Nota de metodo
La regla que hace util este arnes: **si la suite no cae, primero se mira si la mutacion llego a
aplicarse**. Dos de las seis mutaciones de la primera pasada no se aplicaron —suposiciones mias
sobre el fuente— y de haberme quedado ahi habria concluido "vacuo" sobre asertos que si
discriminan. Cada mutador imprime cuantas sustituciones hizo y CERO se reporta como **SIN PROBAR**,
nunca como aprobado. Verificado tambien en ese sentido: rompiendo a proposito un mutador, el arnes
se pone rojo con `SIN PROBAR` en vez de decir que todo bien.

## [2.19.3] - 2026-09-12
**La prueba que 2.19.1 presento como "no puede quedarse corta" se quedaba corta en 12 de 14
ficheros.** Lo cazo un adversario local mutando `build-recall-index.py`: cambio
`for _flujo in (sys.stdout, sys.stderr):` por `for _flujo in (sys.stdout,):` —dejando stderr sin
guardar pero conservando el identificador `_flujo`— y la suite siguio diciendo `TODO VERDE`.

La causa es la misma que 2.19.1 decia haber corregido, un nivel mas abajo: **el criterio seguia
siendo textual**. Antes buscaba no-ASCII literal; despues buscaba los identificadores de la guarda.
Las dos cosas leen el fuente y ninguna sabe lo que el codigo HACE. Solo `triage-scan.py` y
`expire-pendientes.py` tenian cobertura real, porque son los unicos con un caso en vivo.

### Changed
- `bin/test-utf8-streams.sh`, `falta()`: se comprueba **por comportamiento**. Cada `.py` se importa
  en un proceso propio con `PYTHONIOENCODING=cp437` —lo que hace Windows por su cuenta— y se lee la
  codificacion REAL de los dos flujos. Los 14 protegen su `main()` con `if __name__ == "__main__"`,
  asi que importar ejecuta la guarda y nada mas. El informe dice ahora que salio: por ejemplo
  `build-recall-index.py(utf-8 cp437)`.
- Verificado con **cuatro** mutaciones distintas, cada una en un fichero distinto, y las cuatro se
  cazan: quitar la guarda entera (`cp437 cp437`), dejar solo stdout (`utf-8 cp437`), dejar solo
  stderr (`cp437 utf-8`), y volver inalcanzable el `reconfigure` (`cp437 cp437`). La version
  anterior no cazaba ninguna salvo en los dos ficheros con caso en vivo.

### Nota
Tercera vez en esta sesion que una prueba afirma cubrir mas de lo que cubre, y las tres veces la
forma del error fue la misma: **deducir del fuente lo que solo se sabe ejecutando**. Un detector
que se ha visto decir "ninguno" no se ha visto funcionar; hay que verlo decir "este".

## [2.19.2] - 2026-09-12
### Fixed
- `bin/test-journal-race.sh`: el techo de velocidad del caso "un solo agente" era 1000 ms en todo
  POSIX, y un runner compartido de macOS lo paso por encima: **1465 ms con `items=10` y `lock=0`**,
  o sea que lo que fallaba era el reloj del runner y no el codigo. El coste de arrancar 10 procesos
  de python depende de la MAQUINA, no solo del sistema. Se declara 3 s tambien cuando `CI` esta
  puesto, igual que ya se hacia para Git Bash.

  Se afloja un techo de **rendimiento** medido en hardware ajeno; las dos comprobaciones de
  **correccion** de ese mismo caso —`items=10` y `lock=0`— siguen estrictas en todas las
  plataformas, y en local el techo sigue siendo 1 s.

## [2.19.1] - 2026-09-12
**La entrada de 2.19.0 afirmaba que el barrido de UTF-8 estaba completo. No lo estaba.** Lo rompio
un adversario externo y se reprodujo aqui: la guarda cubria `stdout` y no `stderr`, asi que
`triage-scan.py` —que 2.19.0 daba por arreglado— seguia escupiendo
`no existe /…/memoria\u2014x/_pendientes.md` cuando el directorio llevaba un guion largo en el
nombre.

Los dos modos de fallo no son el mismo: por `stdout` con una pagina OEM el proceso **muere**; por
`stderr` **degrada** a la forma escapada. Menos grave, igual de falso, y mas dificil de ver porque
nada peta.

La causa de fondo no fue olvidar un flujo: fue el **criterio** de la prueba. `test-utf8-stdout.sh`
decidia quien necesitaba guarda leyendo el fuente en busca de no-ASCII literal en la misma linea
que un `print(`. Eso no se puede decidir leyendo el fuente — no ve una variable, un f-string armado
antes, una RUTA que elige el usuario, ni el mensaje de una excepcion. El caso que lo rompio es
justo de los que esa prueba no podia ver ni en principio.

### Fixed
- Los **14** `.py` de `bin/` reconfiguran ahora `stdout` **y** `stderr`. Se pone en todos, no en los
  que "parecen" imprimir no-ASCII: exigirlo siempre no necesita adivinar y no puede quedarse corto.

### Changed
- `bin/test-utf8-stdout.sh` -> `bin/test-utf8-streams.sh`, con el criterio invertido: ya no intenta
  deducir quien imprime no-ASCII, exige la guarda en todos. Anade dos casos EN VIVO bajo
  `PYTHONIOENCODING=cp437` —una ruta no-ASCII por stderr y un texto por stdout— y dos CONTROLES que
  comprueban que sin guarda cp437 si rompe los dos flujos, porque un caso cuyo control no falla no
  mide nada. Verificado ademas por mutacion: quitandole stderr a `triage-scan.py` en una copia,
  fallan los casos 1 y 3.

## [2.19.0] - 2026-09-12
**`expire-pendientes.py` y `triage-scan.py` MUEREN en una consola de Windows con pagina OEM.** No
degradan el texto: se llevan el proceso con `UnicodeEncodeError` al imprimir un guion largo.

El `export PYTHONUTF8` de 2.18.3 no los cubria, y no podia: estos scripts se invocan **tambien
directamente desde las plantillas de los comandos** (`python3 "$JBIN/triage-scan.py" ...`), sin
ningun `.sh` de por medio. Una garantia que depende de quien te invoque no es una garantia — la
misma leccion que 2.18.4, ahora del lado de los `.py`.

Medido, no supuesto: de los 7 scripts de `bin/` que imprimen no-ASCII, 5 ya fijaban UTF-8 en su
propio stdout y estos 2 se habian quedado fuera. Con cp1252 sus caracteres (`—`, `…`) si existen y
solo se degradan; con cp437 no existen y el proceso truena.

### Fixed
- `bin/expire-pendientes.py` y `bin/triage-scan.py`: `sys.stdout.reconfigure(encoding="utf-8")`,
  el mismo idioma que ya usaban los otros cinco.

### Added
- `bin/test-utf8-stdout.sh`: falla si cualquier `.py` de `bin/` imprime no-ASCII sin fijar UTF-8.
  Con su CONTROL —un fichero sintetico sin guarda que el detector tiene que cazar— y con una
  corrida real bajo `PYTHONIOENCODING=cp437` en los dos sentidos: con guarda el texto sale entero,
  sin guarda truena. Un detector que solo se ha visto decir "ninguno" no se ha visto funcionar.

## [2.18.9] - 2026-09-12
### Fixed
- `bin/test-parser.sh`: el ultimo caso rojo de Windows. `mkproj` pasaba el comando del hook por una
  **variable de entorno**, y en Git Bash MSYS convierte los valores de entorno que parecen rutas: un
  comando que empieza por `/usr/bin/env ...` se reescribia a la forma de Windows antes de llegar a
  python y el fixture quedaba mutilado. El detector funcionaba —se comprobo en CI contra un fixture
  escrito sin pasar por el entorno, y emitio `HOOK DUPLICADO`—; lo que fallaba era el montaje. Pasa
  por fichero: por stdin no puede ser, porque ahi va el propio programa, y la RUTA de un fichero si
  se puede convertir sin dano porque es una ruta de verdad.
- `.github/workflows/tests.yml`: fuera el paso de diagnostico temporal.

### Nota
Tres de las cuatro vueltas de Windows acabaron en el mismo sitio: el test medía con una herramienta
cuyo dialecto cambia con la plataforma y acusaba al plugin de algo que el plugin no hacia. La unica
forma de distinguirlo fue montar el escenario SIN la herramienta sospechosa y ver que el codigo si
respondia.

## [2.18.8] - 2026-09-12
### Fixed
- `bin/session-start.sh`: al sustituir `$CLAUDE_PROJECT_DIR` en el comando de un hook se metia la
  ruta del proyecto TAL CUAL, y despues ese texto lo parte `shlex.split(posix=True)`, donde la
  barra invertida es un **escape**. Una ruta de Windows (`C:\\Users\\...`) se destruia al tokenizar
  y el hook heredado quedaba sin detectar. Se sustituye la forma con barras normales, que Windows
  acepta igual. Es codigo que se distribuye.
- `bin/test-resolve-project-dir.sh`: el caso sin jq monta un `PATH` reducido a un directorio de
  enlaces, y en Windows `bash.exe` carga sus DLL por `PATH`, asi que no arranca
  (`error while loading shared libraries`). La precondicion no se puede construir ahi: se sonda y
  se salta con aviso, como el caso del pty.

## [2.18.7] - 2026-09-12
Cuarta vuelta de Windows. Solo suites.

### Fixed
- Seis interpolaciones mas de rutas del shell DENTRO del fuente de python
  (`test-monthly-rows.sh` 1, `test-session-start-json.sh` 5). Pasan por `sys.argv`, que MSYS si
  convierte. Es el mismo defecto de 2.18.3 y 2.18.6: se fue arreglando donde fallaba en vez de
  barrer el patron entero, y cada vuelta destapaba el siguiente. El barrido completo esta hecho.
- `bin/test-resolve-project-dir.sh`: `env -i` borra `SYSTEMROOT`, y **el python de Windows no
  arranca sin el**. El respaldo moria antes de empezar y el caso acusaba al codigo de no resolver
  el cwd. Se conserva esa unica variable, y solo donde existe, para que el entorno siga siendo
  minimo en POSIX.

## [2.18.6] - 2026-09-12
Tercera vuelta de Windows. Solo suites: las tres son la misma familia de defecto de medicion.

### Fixed
- `bin/test-monthly-rows.sh`: los directorios de memoria se interpolaban DENTRO del fuente de
  python (`jc.find_monthly_row('$M4', ...)`), donde MSYS no convierte nada. Pasan por el entorno,
  igual que `$BIN` en 2.18.3.
- `bin/test-monthly-rows.sh`: el conteo de CR usaba `grep`, que en MSYS trata `\r\n` como fin de
  linea y devuelve 0 donde hay CRLF. Se cuenta por bytes, como ya se hizo en
  `test-normalize-pendientes.sh`.
- `bin/test-resolve-project-dir.sh`: el respaldo de python3 devuelve la ruta en forma nativa y el
  shell la construye en forma MSYS. Se comparan rutas normalizadas, no cadenas.

## [2.18.5] - 2026-09-12
### Fixed
- `bin/session-start.sh`: el detector de hooks heredados daba por RELATIVA una ruta absoluta de
  Windows. `cand.startswith("/")` solo reconoce las de POSIX, asi que una `C:\\...` se pegaba detras
  del directorio del proyecto. Pasa a `os.path.isabs`, conservando el `/` explicito porque en
  Windows `isabs("/x")` es False y ahi si es absoluta.
- `bin/test-plugin-bin-resolver.sh`: el manifiesto sintetico escribia `projectPath` en forma MSYS,
  pero el `cwd` llega al python nativo ya convertido a forma de Windows, asi que no habia
  contencion que cuadrase y una entrada legitima se excluia. Se escribe en forma nativa, que ademas
  es lo que contiene un `installed_plugins.json` de verdad en esa plataforma.

## [2.18.4] - 2026-09-12
Segunda vuelta de Windows, con el CI midiendo en vez de suponer.

### Fixed
- `bin/session-start.sh`: la garantia de UTF-8 pasa a vivir **dentro** del bloque que imprime
  (`sys.stdout.reconfigure`), no solo en el `export` del guion que lo llama. Ese bloque tambien se
  ejecuta suelto —`test-parser` lo extrae de aqui— y una garantia que depende de quien te invoque
  no es una garantia. El `export` de 2.18.3 se queda: cubre las otras once llamadas a python.
- `bin/test-plugin-bin-resolver.sh`: dos asertos comparaban rutas **como cadenas**. En Git Bash
  conviven dos dialectos para el mismo directorio —la forma MSYS que construye el shell y la nativa
  que sale al cruzar hacia un `.exe`— y el resolutor devolvia la misma carpeta en la otra forma. No
  fallaba la eleccion, fallaba la ortografia. Las 13 comparaciones de ruta pasan por `cygpath -m`
  donde existe, y fuera de Windows no tocan nada.

## [2.18.3] - 2026-09-12
**En Windows, todo el texto en espanol del plugin salia con los acentos y los guiones rotos.** Es
lo mas grave de esta tanda y lo encontro la primera corrida de las suites en Git Bash.

Python en Windows codifica `stdout` con la pagina de codigos local (cp1252) cuando va a una
tuberia, no en UTF-8. Ninguno de los siete guiones distribuidos que llaman a python fijaba la
codificacion. Medido sobre la salida REAL del hook de arranque: `item con id — _creado:` llegaba
como `item con id � _creado:`. Ese texto se inyecta en el prompt de cada sesion, asi que lo
veia el modelo en su contexto y lo veia el usuario en su terminal.

### Fixed
- `export PYTHONUTF8=1 PYTHONIOENCODING=utf-8` en los siete: `session-start.sh`,
  `bash-journal-nudge.sh`, `context-nudge.sh`, `journal-guard.sh`, `recall.sh`,
  `resolve-plugin-bin.sh` y `resolve-project-dir.sh`. Los dos son no-op fuera de Windows. Se
  incluyen los dos resolutores aunque solo impriman rutas: una ruta puede llevar acentos si el
  usuario los tiene en su nombre.
- `bin/test-monthly-rows.sh`: interpolaba `$BIN` DENTRO del fuente de python. En Git Bash una ruta
  MSYS solo se convierte a la forma nativa cuando viaja como argumento o como variable de entorno
  hacia un `.exe`; dentro de un literal no la ve nadie, y el interprete de Windows la resolvia
  contra la unidad actual (`D:\d/a/...`, que no existe). Pasa a `os.environ['BIN']`, que es el
  idioma que ya usaban las dos suites que si pasaban en Windows.
- `bin/test-normalize-pendientes.sh`: los dos asertos sensibles al CR usaban `grep`, y el de MSYS
  trata `\r\n` como fin de linea, asi que `$` casa por delante del `\r` y los dos se invertian.
  El plugin hacia lo correcto —el fichero salia con `nl=cr=14`— y lo que mentia era la medicion.
  Ahora se cuenta por BYTES, verificado en los dos sentidos con un fichero LF y otro CRLF.
- `bin/test-expire-reopen.sh`: el caso del destino inescribible se **salta y se informa** donde
  `chmod` no toca las ACL de NTFS. Se comprueba con una sonda de escritura en vez de suponerlo. Un
  salto contado es honesto; un fallo por precondicion ausente acusa al codigo de algo que no hizo.

### Nota
Windows sigue en un job informativo que no bloquea. Sube a la matriz principal cuando encadene
verdes, y entonces se cierra el pendiente que lleva abierto desde el 2026-09-11 diciendo que
`resolve-project-dir.sh` nunca se habia probado ahi.

## [2.18.2] - 2026-09-12
**El aviso de escritura a mano no disparaba NUNCA en Linux**, en silencio. `bash-journal-nudge.sh`
es el hook `PostToolUse` que avisa cuando un indice de Tier 2 cambio fuera del journal — la
barandilla que existe justamente porque `journal_strict` es un `PreToolUse` y por diseno no ve un
`sed -i` ni un heredoc por Bash.

Su compuerta barata comparaba mtimes con
`stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null`. En GNU eso NO cae al segundo: `-f` no
toma argumento, asi que `%m` se lee como otro fichero. Ese falla —de ahi el exit distinto de 0— pero
**el fichero real si se imprime**, con la info del sistema de ficheros. `2>/dev/null` tapaba el
error y la sustitucion se quedaba con las dos salidas pegadas; el `[ "$m" -ge "$FPM" ]` de despues
no recibia un numero, fallaba, y `NEWER` no se ponia nunca. La compuerta cerraba siempre.

Un aviso que no avisa es peor que no tenerlo: se cuenta como cubierto.

### Fixed
- `bin/bash-journal-nudge.sh`: se prueba GNU primero (BSD no tiene `-c`, alli falla y cae) y se
  **exige que la salida sea un entero**. Una utilidad que responde otra cosa vale lo mismo que no
  estar: se devuelve vacio, que el llamador ya sabia tratar.
- `bin/test-expire-reopen.sh`: `sed -i ''` es BSD. En GNU, `-i` no lleva el sufijo como argumento
  suelto, asi que el `''` se tomaba como el SCRIPT y la expresion como el NOMBRE DE FICHERO. La
  edicion no ocurria y el caso de la valvula `_revisar` fallaba. Sustituido por un helper con
  fichero temporal, que no depende del dialecto.
- `bin/test-expire-reopen.sh`: `md5 -q` es BSD. En Linux no existe, asi que los **cuatro** asertos
  "byte a byte" comparaban cadena vacia contra cadena vacia y **pasaban sin comprobar nada**. Un
  falso verde es peor que un fallo: el fallo se ve. Helper con `md5` o `md5sum`, verificado que
  distingue dos ficheros distintos y no solo que devuelve algo.
- `bin/test-plugin-bin-resolver.sh`: el CONTROL afirmaba que `find ... | head -1` "devolvia otra
  cosa", pero el defecto que cubre es que ese orden es **arbitrario**, no que sea siempre el
  equivocado. En macOS devolvia otra; en Linux devolvio justo la instalada y el aserto fallo. Ahora
  mide lo comprobable: que habia mas de una candidata y `head -1` elegia sin mirar la version.

### Added
- `tools/run-tests.sh`: corre el guard de higiene mas las 11 suites, en orden estable, y devuelve 1
  si alguna falla. Las 12 tardan 27 s juntas.
- `.github/workflows/tests.yml`: ubuntu y macOS bloqueantes, Windows informativo.

### Nota de metodo
Las cuatro cosas de arriba las encontro **la primera ejecucion en Linux**, en la misma corrida.
Ninguna suite las habia visto en meses porque todas se habian corrido solo en macOS, y la del
resolutor llevaba encima dos rondas de adversario —una de ellas ejecutandola y mutandola— sin
cazarlo: no era un hueco de rigor, era de plataforma, y solo lo cierra ejecutar en la otra.

## [2.18.1] - 2026-09-12
`resolve-plugin-bin.sh` elegia **la version mas alta de `installed_plugins.json` sin mirar el
ambito**, asi que una entrada `scope=project` de OTRO proyecto ganaba aqui. El texto del comando
venia de la version instalada en este proyecto y los scripts que ese texto invocaba eran de otra
instalacion. En 2.18.0 esto estaba *declarado* en la cabecera del script —no era un descuido— con
el argumento de que `installed_plugins.json` no documenta precedencia entre ambitos, asi que "la
mas alta" era una regla declarada en vez de una inferencia.

El argumento tenia un hueco, y lo senalo otra sesion del usuario al cerrar su seguimiento del
defecto de 2.18.0: **`scope` + `projectPath` si determinan este caso sin inferir nada**. Una
entrada `project` cuyo `projectPath` no contiene el directorio de trabajo no puede estar activa
aqui, sea cual sea la precedencia entre ambitos. O sea que se puede EXCLUIR sin necesidad de saber
cual manda entre las que quedan.

Reproducido aqui el 2026-09-12 con manifiesto sintetico antes de tocar nada, en los dos casos que
esa sesion describio: con una entrada `user` 2.18.0 y una `project` 2.20.0 de otro proyecto, el
resolutor devolvia la 2.20.0; y con SOLO la entrada `project` ajena —el plugin ni siquiera
instalado aqui— devolvia igualmente su bin. Alcanzable en esta maquina: ya hay una entrada
`scope=project` con `projectPath` en el manifiesto (de otro plugin), asi que instalar por proyecto
es algo que se hace de verdad. Hoy 3-tier-memory tiene una sola entrada `user`: el caso estaba
latente, no activo.

Severidad baja, y menor que la del defecto que arreglo 2.18.0: aquel daba una version **arbitraria**
(2.13.2 con 2.17.1 instalada, cuatro versiones atras y sin `repair-dualwrite.py`); este daba la
instalada mas alta, que suele ser igual o mas nueva que la activa.

### Fixed
- `bin/resolve-plugin-bin.sh`: se excluye toda entrada `scope=project` cuyo `projectPath` no
  contenga el directorio de trabajo. Entre las que quedan **sigue ganando la version mas alta** —
  el filtro reduce las candidatas, no cambia la regla de desempate. Una entrada `project` del
  proyecto actual NO gana por serlo a una `user` de version superior: eso seria inferir la
  precedencia entre ambitos, que es justo lo que la cabecera declara no saber.
- La comparacion es por **componentes de ruta**, no por prefijo de texto, y con `realpath` en los
  dos lados. Un `startswith` a secas habria hecho que `/foo-bar` casara con `/foo`, y una igualdad
  estricta habria excluido una entrada valida cuando el comando corre desde un subdirectorio del
  proyecto.
- `scope=project` **sin** `projectPath` se conserva: no se puede probar que sea ajena.
- La cabecera del script ya no describe el comportamiento sin filtro.

### Tests
- Siete asertos nuevos en `bin/test-plugin-bin-resolver.sh` (19 en total; 12 antes): la entrada ajena se
  excluye, con CONTROL que demuestra que sin el filtro ganaba; la misma entrada SI vale desde su
  proyecto y desde un subdirectorio suyo; `/OTRO-bis` no esta dentro de `/OTRO`; `project` sin
  `projectPath` se conserva; y al quedarse sin candidatas se cae al cache, no a la ajena.

## [2.18.0] - 2026-09-11
Una fila del historial mensual **sin la columna `#` no existia para ningun script del plugin**, y de
ahi salian duplicados silenciosos. `journal-compact.table_rows` y los tres lectores de
`repair-dualwrite` decidian "esta linea es una fila" con `re.match(r"^\|\s*\d+\s*\|", s)`, asi que
`find_monthly_row` no encontraba esas filas, `apply_add_monthly` escribia una **segunda** para el
mismo pendiente y `apply_resolve_monthly` dejaba un `WARN` y perdia la fecha de cierre y la sesion
que lo cerro. El informe lo reportaba al contrario: con el codigo de 2.17.1, sobre un corpus real
de otra instalacion, `repair-dualwrite --apply` decia `rows_added=1` y dejaba **dos filas** para el
mismo id — el duplicado lo creaba la reparacion.

Reportado por la sesion del repo `goal-spec-skill`, que lo encontro migrando sus propios mensuales,
con un corpus de 80K para reproducirlo. Sus tres defectos se confirmaron en el arbol de trabajo
antes de tocar nada; una de sus cifras no: el tarball **no** reproduce los `rows_added=49` de su
corrida (da `rows_added=0`, porque sus 49 venian de su memoria viva, no del corpus), asi que el
fixture de la prueba se construyo aqui. Y hay un cuarto camino que el informe no nombraba: el que
duplica esta tambien en `journal-compact.find_monthly_row`, o sea que **el compactador se duplicaba
solo**, sin que `repair-dualwrite` corriera nunca.

Medido el 2026-09-11 sobre ese corpus, con un instrumento propio: **39 filas sin numero** (34 en
`2026-08.md`, 5 en `2026-09.md`) y cabeceras de **5 y 6 columnas** donde la canonica tiene 7. Las
cuatro formas de fila que existen en la vida real: 7 celdas con numero (160), 6 con numero (1), 6
sin numero (6) y 5 sin numero (33).

Decision del usuario, preguntada antes de escribir codigo: **lector tolerante, no migrador**; **solo
codigo, no se reescribe ningun dato en disco**; y publicar al marketplace. Un migrador habria sido
la otra mitad del arreglo, pero reescribe historial ajeno y es la unica parte irreversible.

### Fixed
- **Las filas sin `#` se leen, se localizan y se cierran.** El lector nuevo (`monthly_rows`,
  `align_row`, `header_map`, `render_row` en `journal-compact.py`) devuelve las celdas **ya
  alineadas a las columnas canonicas**, no en crudo. Esto era lo unico que no podia hacerse
  ensanchando el filtro: todos los escritores indexan por posicion (`cells[5]` es `Resuelto`), asi
  que en una fila de 6 celdas sin numero cada indice cae una columna a la izquierda y un cierre
  habria escrito la fecha sobre `Sesion resolucion`. El ancla de la alineacion es la **fecha de
  `Creado`**, no la prioridad: exigir la prioridad dejaba ilocalizable una fila con un valor
  escrito a mano y el compactador le escribia otra al lado — el mismo defecto por otra puerta.
- **`render_row` devuelve la fila con SU forma en disco.** Una fila de 5 celdas sigue teniendo 5
  celdas despues de cerrarse: no se numera ni se normaliza nada. Cuando la nota de cierre no tiene
  columna donde caber, se escribe la fecha (que si cabe) y la nota sale por un `WARN` con su id —
  se pierde de la tabla, pero **no en silencio**, que es el fallo que este script existe para
  cerrar.
- **`find_monthly_row` busca el id en la CELDA DE TEXTO**, y toma el ultimo `_id:` de esa celda, que
  es el propio. Antes buscaba `_id: X_` en la linea entera y devolvia la fila de un pendiente que
  *cita* el id de otro. No era visible porque la mitad de las filas era invisible; al verlas todas,
  ese falso positivo crece, asi que entra en el mismo cambio.
- **`repair-dualwrite`: los cuatro lectores comparten el lector nuevo.** `existing_ids` ya no
  concluye "este pendiente no tiene fila de Tier 3" cuando la tiene sin numero. Una fila con `|`
  crudo y **sin** numero se reporta en vez de repararse: el colapso de `row_cells` asume que la
  celda 0 es el numero, asi que reconstruirla moveria el texto de columna.

### Changed
- **El informe GRAVE ya no afirma una causa que no puede determinar** (`shifted_rows` →
  `unaligned_rows`). Decia "El dato original se perdio; reconstruyela de un respaldo", y la senal
  que lo disparaba — prioridad o fecha no canonicas — la produce al menos otra cosa: una fila
  escrita a mano con un valor no canonico, donde no se perdio nada. Caso real, `2026-07.md:111`:
  `Media→Alta` en la celda de prioridad, las 7 celdas en su sitio, 8 `|` crudos, 0 escapes. Ahora
  el mensaje imprime **lo que se midio** (celdas, `|` crudos, `\|` escapados, el motivo del
  alineador) y **lista** las causas posibles. Un colapso mal hecho deja `|` crudos dentro de una
  celda, que vuelven a partir la fila: por eso una fila colapsada aparece con MAS de 7 celdas y la
  cuenta `pipes_broken`, no esta.
- **Contador nuevo `odd_values`**: fila bien alineada cuya `Prioridad` no es Alta, Media ni Baja. No
  falta ni se movio nada; lo que rompe es `header_index`, que no sabra donde reinsertar la linea si
  se reabre. El informe lo dice con esas palabras.
- **Contador nuevo `header_issues` y validacion de cabecera en cada pasada** (`header_issue`).
  `ensure_monthly` escribia la cabecera canonica **solo al CREAR** el fichero y nadie la volvia a
  mirar, asi que un mensual de 5 columnas convivia indefinidamente con las filas de 7 que el propio
  compactador le escribia encima. Ahora avisa, con el fichero y **que columna falta**, y el aviso
  distingue la consecuencia: sin `Sesion resolucion` un cierre pierde la sesion que lo cerro; sin
  `#` las filas nuevas salen numeradas y las viejas no, nada mas. No la reescribe: eso es una
  migracion.
- **Los comandos localizan el plugin por version instalada, no por el orden de `find`**
  (`bin/resolve-plugin-bin.sh`, nuevo). Los 13 sitios de 7 ficheros (6 plantillas y
  `commands/migrate.md`) usaban
  `find "$HOME/.claude/plugins" -name X.py -path "*/3-tier-memory/*" | head -1`, cuyo orden **no es
  por version**: en esta maquina, con 14 versiones en el cache, devolvia la **2.13.2 con la 2.17.1
  instalada**, asi que un checkpoint habria escrito los indices con scripts cuatro versiones viejos
  en silencio. Resuelve en este orden: `$CLAUDE_PLUGIN_ROOT/bin` (el plugin que corre, lo tienen los
  hooks) → `installPath` de `installed_plugins.json` (la unica fuente de cual esta **instalado**: el
  cache puede guardar una descarga que no es la activa, asi que "la mas alta del cache" no es lo
  mismo) → la mas alta del cache por `sort -V` → su propio directorio. El fallback de las plantillas
  usa `sort -V | tail -1` en vez de `head -1`, asi que ni antes de que 2.18.0 este instalada puede
  elegir una version vieja.

### Added
- **`bin/test-monthly-rows.sh`** — 7 casos: que no se duplica la fila sin numero, que la segunda
  corrida deja el fichero byte a byte igual, que un cierre rellena `Resuelto` **en su columna**
  conservando las 5 celdas, que la fila canonica sigue usando las 7, que un huerfano de verdad
  **si** recibe su fila (el arreglo no apaga la reparacion), la discriminacion de D2 en los dos
  sentidos, y una **prueba de conservacion de contenido con parser propio**, escrito en el test y
  sin importar `journal-compact`: un verificador que comparte el reparto de celdas del codigo que
  verifica no puede ver un error en ese reparto.
- **`bin/test-plugin-bin-resolver.sh`** — 7 casos, cada uno con su control del patron viejo sobre el
  mismo arbol: gana la version *instalada* y no la mas alta; `2.10.0` gana a `2.9.0` (donde `sort`
  alfabetico se equivoca); un `installed_plugins.json` ilegible no rompe nada; `CLAUDE_PLUGIN_ROOT`
  manda; sin plugin no imprime ruta y sale 1; y cero `find ... | head -1` vivos en las plantillas. Los dos que quedan en el repo son el comentario que documenta el patron retirado y el CONTROL de esta propia prueba, que lo ejecuta a proposito para comparar.

### Verificacion
- **Las 11 suites de `bin/test-*.sh` en verde**, incluidas las 9 anteriores; `check-index-writers`:
  `scanned=24 undeclared=0 mislabeled=0`. Esta medicion es **propia**: el verificador externo no
  pudo repetirla porque su sandbox le niega `mktemp`. Cualquiera la repite con
  `for t in plugins/3-tier-memory/bin/test-*.sh; do bash "$t"; done`.
- **Viejo contra nuevo, sobre el mismo fixture, ejecutando el bloque de 2.17.1 sacado de
  `git show HEAD:`** (no un proxy escrito a mano): `rows_added=1` y 2 filas del mismo id →
  `rows_added=0` y 1 fila. En el cierre: el viejo anadia una fila numerada nueva; el nuevo rellena
  `2026-09-11` en la celda `Resuelto` de la fila que ya estaba, con sus 5 celdas intactas.
- **Sobre el corpus real: 200 filas de mensual** (126 + 53 + 21; el resto del tarball vive en
  `2026-07-25-triage-post-0190.md`, que no es un mensual, tiene DOS tablas y **43** filas de datos
  —6 + 37—). Resultado:
  `unaligned_rows=0 odd_values=1 header_issues=2`, es decir las 39 filas sin numero se ven todas, el
  unico valor raro es el `Media→Alta` y las dos cabeceras cortas salen nombradas. Con 2.17.1 el mismo
  corpus daba `shifted_rows=1` — acusando de dato perdido justamente a esa fila — y **no veia** una
  fila a la que le faltan columnas de verdad. (La cifra "244" estuvo en este CHANGELOG y no la produce
  ningun predicado: 200 + 43 = **243**. El "44" con que se explicaba salia de quitar UNA cabecera de
  las DOS que tiene el triage, contando la otra como dato; con el predicado que da 200 en los
  mensuales, el triage da 43. Corregido el 2026-09-12 sobre el tarball, a peticion de un adversario
  externo que lo dio por roto antes de publicar.)
- **Ningun dato de nadie se reescribio**: no se toco `memory/` de este repo ni de `goal-spec-skill`;
  todo corrio sobre copias en un directorio temporal.
- **Adversario externo (Codex / GPT-5, otro proveedor), ronda 1 antes de publicar:
  `break ungrounded=4 incomplete=1 unsafe=2`.** Seis hallazgos reales, los seis arreglados aqui:
  - **H1 (unsafe), el peor: el lector tolerante introducia la perdida de datos que venia a cerrar.**
    `| 56 | texto | Alta | 2026-06-10 | a | b |` sin cabecera que lo explique puede ser "le falta
    `Sesion resolucion`" o "le falta `Origen`", y la fecha de `Creado` esta en su sitio en las dos.
    La primera version elegia siempre la primera lectura, asi que un cierre podia escribir la fecha
    sobre la celda equivocada. Ahora la cabecera del fichero es lo unico que rompe el empate: con
    cabecera reconocida, una fila corta pierde las celdas FINALES (que es lo que significa en
    markdown); **sin** cabecera reconocida solo se aceptan las dos formas donde no falta ninguna
    columna (7 con numero, 6 sin numero) y cualquier otra se devuelve sin alinear, con su motivo.
  - **H5 (incomplete), consecuencia del anterior**: una fila falsamente alineada no caia en ningun
    contador, asi que el informe podia decir todo a cero con las columnas desplazadas. Cerrado por
    el mismo cambio: ahora cae en `unaligned_rows`.
  - **H4 (ungrounded): "no en silencio" era falso para un camino.** `recall.sh` corre el compactador
    con `--quiet >/dev/null 2>&1`, asi que por ahi el `WARN` de la nota que no cabe se descartaba.
    Ahora la nota va tambien a `.journal/notas-sin-columna.log`, con fecha, fichero e id.
  - **H6 (ungrounded): la afirmacion sobre `installed_plugins.json` era mas fuerte que lo medido.**
    No se verifico que resuelva varios marketplaces o ambitos. El resolutor ya no toma "la primera
    entrada que coincide": entre varias toma la de **version mas alta**, comparada por numeros, y el
    comentario dice que eso es una eleccion declarada y no un conocimiento de cual esta activo.
  - **H7 (ungrounded)**: las 244 filas, arriba.
  - **H8 (nota fuera de la superficie)**: quedaba un `find ... | head -1` vivo en
    `commands/migrate.md`. El barrido de la regla solo habia mirado `templates/`, que es una
    cobertura incompleta: `commands/` tambien lleva comandos. Arreglado, y son 13 sitios en 7
    ficheros, no 12 en 6.
  - **H2 (unsafe)**: sin prueba de conservacion exacta para CRLF. Anadida: un mensual con saltos de
    Windows conserva su numero de CRLF y no queda ni un `\n` suelto despues de un cierre.
  - H3 refutada (las filas sin numero no ocupan numero, asi que `max+1` no puede colisionar) y la
    revision de autonomia tambien: las tres decisiones estan en la transcripcion como
    `AskUserQuestion` con su respuesta.
  - Lo que **no** pudo re-ejecutar: las 11 suites, porque `mktemp` le dio `Operation not permitted`
    en su propio entorno. Es un limite de su sandbox, no un defecto del cambio; las 11 corren en
    verde aqui, y esa parte no tiene verificacion independiente.
- **Adversario externo, ronda 2 (delta, solo sobre los arreglos de la ronda 1):
  `break ungrounded=4 incomplete=1 unsafe=1`.** Refuto H1/H5 importando el modulo y construyendo
  filas nuevas (la de 6 celdas sin cabecera queda sin alinear; las cabeceras repetidas, desordenadas
  o con nombres parecidos se rechazan; ninguna forma legitima del corpus se perdio) y volvio a
  refutar H3 y la autonomia. Lo que **si** encontro, y esta arreglado:
  - **Las cifras viejas seguian vivas en la seccion autoritativa del checkpoint** (C4 decia 244
    filas, C7 decia 8 sitios en 6 plantillas) mientras "Medido" y este CHANGELOG ya estaban
    corregidos: el mismo fichero se contradecia. Corregido, con la nota de por que.
  - **El comentario copiado en los 13 sitios decia "Ruta del plugin ACTIVO"** cuando el propio
    resolutor admite que, si el plugin llega por varios marketplaces, no sabe cual esta activo.
    Ahora dice lo que hace: la version mas alta de las **instaladas**.
  - **El orden de versiones del resolutor no era semantico**: `clave()` tomaba todos los digitos de
    cada parte, asi que `"0-rc1"` valia `1` y `2.18.0-rc1` salia **por encima** de `2.18.0`. Ahora
    cuenta los digitos de cabecera y un sufijo baja el empate; con prueba propia en
    `test-plugin-bin-resolver.sh` (caso 1b).

## [2.17.1] - 2026-09-11
`/migrate` decide que lineas borrar de un hook legacy del usuario **a partir de lo que el plugin
re-emite**, y 2.17.0 recorto justo eso. Su regla decia que un volcado de `_pendientes.md` es emision
duplicada entera porque "el plugin ya inyecta esto, curado"; desde 2.17.0 el plugin solo pone
delante del agente las de `## Alta prioridad` y las que etiqueta `SIN CLASIFICAR`. Recortar el
volcado completo con esa regla borra las MEDIA y BAJA — exactamente el dano que el propio fichero
advierte dos lineas mas abajo: *"Getting this wrong deletes context the user never gets back."*

### Changed
- **`commands/migrate.md`: la clasificacion de emision duplicada se acota a lo que el plugin re-emite
  hoy, con sus tres limites.** Duplicado = los items de `## Alta prioridad` y los `SIN CLASIFICAR`,
  **como mucho 25** y **cada uno cortado a ~120 caracteres** (`CEILING` y `BODY_CAP` de
  `bin/session-start.sh`). Cuentan como custom, y no se borran: las MEDIA y BAJA, lo que pase del
  item 25, la cola cortada de cada item largo, y los `- [ ]` que viven bajo una seccion cerrada
  (`## Completados`, `## Scope`, `## Related`...) — que el parser excluye a proposito y un `grep`
  legacy captura sin enterarse. Esa cuarta clase faltaba en la enumeracion y la encontro el
  verificador; hay un pendiente vivo que documenta el caso real (16 items asi en otro proyecto).
- **La medicion que `/migrate` ensena al usuario mide ahora los dos lados, y el lado del plugin lo
  lee del propio plugin.** Antes solo contaba los bytes del volcado legacy, que es la mitad que no
  decide nada. El primer intento anadio un `awk` que clasificaba "igual que el hook" y no lo hacia:
  contaba los items bajo secciones cerradas (`## Completados`), que el parser excluye a proposito, y
  fallaba con encabezados en mayusculas, que el parser si reconoce. Lo encontro el verificador con
  dos casos reproducidos contra el parser real. El arreglo no es corregir el `awk` — es no tener una
  segunda copia de esa logica: el numero ya lo publica el bloque que el plugin inyecta al arrancar
  (`PENDIENTES ABIERTOS (<total>), <N> de prioridad ALTA o sin clasificar`), y `/migrate` lee ese
  `<N>`. Es el mismo fallo que `repair-dualwrite.META_RE` en 2.17.0, dos implementaciones que tenian
  que coincidir y divergieron.
- **Una categoria nueva: el texto plano nunca duplica el mensaje que el plugin manda a la persona.**
  El plugin habla por dos canales desde 2.17.0; un hook legacy que imprime texto plano llega al
  agente y a nadie mas. **Con una excepcion declarada**: un hook legacy que emita JSON propio con
  `systemMessage` SI escribe en el mismo canal, y su contenido se juzga con las mismas reglas que
  cualquier otra linea.

- **La accion que `/migrate` ofrece deja de borrar lo que la clasificacion promete conservar.** El
  arreglo anterior corrigio la clasificacion y dejo intactos el ejemplo y la accion que vienen
  despues en el mismo fichero: seguian diciendo `[DUPLICATE] dumps 109 raw pendientes — the plugin
  already injects this` y ofreciendo *"Trim to the custom line only?"*, que borra la linea entera del
  volcado — la misma que ahora contiene contenido duplicado Y custom. Lo encontro el verificador
  externo. Ahora esa linea se marca `[PARTIAL]`, nunca se borra, y la accion por defecto es la que no
  pierde nada: quitar solo las lineas enteramente redundantes. Borrar el script entero es la
  opcion 2, y solo si no queda nada `[CUSTOM]` ni `[PARTIAL]`.
- **La glosa de `SIN CLASIFICAR` se contradecia dentro de su propia frase.** Decia "secciones fuera
  del esquema Alta/Media/Baja", que incluye literalmente `## Completados` y `## Scope` — las mismas
  que la frase siguiente declara excluidas. Un agente que leyera la primera mitad daria por
  duplicados esos items y los borraria: el caso exacto que el arreglo anterior venia a cerrar. Ahora
  la glosa excluye las secciones cerradas explicitamente. Ademas queda medido y escrito que el
  `<total>` del bloque tampoco cuenta esos items: con un Alta, uno bajo cabecera no canonica, uno
  bajo `## Completados` y uno de Media, el hook imprime `PENDIENTES ABIERTOS (3), 2 de prioridad ALTA
  o sin clasificar` — comparar ese total contra un `grep -c` crudo difiere justo en esas lineas.
- **Dos frases mas que quedaron vivas de la version intermedia.** La primera decia que la diferencia
  entre lo que el plugin re-emite y el total del fichero "es lo que el recorte borraria": es al
  reves, esa diferencia es justo lo que hay que conservar, y decirlo al reves contradecia la
  clasificacion y la prohibicion de recortar del mismo fichero. La segunda decia que con mas de 25
  items de alta prioridad el volcado "no es reemplazable" por el bloque del plugin, lo que implica
  que con 25 o menos si lo es — no lo es a ningun tamano, porque el corte a ~120 caracteres pierde
  las colas igual. Las encontro la sexta ronda adversaria (la primera) y el barrido propio del
  fichero entero (la segunda).
- **No hay opcion de estrechar el volcado, y es deliberado.** Una version intermedia la ofrecia con
  una condicion escrita (25 o menos items de Alta/sin clasificar, cuerpos cortos) y el verificador
  mostro que la condicion no basta: estrechar "al `## Media prioridad` en adelante" supone que ese
  encabezado existe, que va despues de Alta y que no hay secciones custom encima. `/migrate` reporta
  los dos numeros y el usuario estrecha a mano si quiere; reescribir su script no vale una suposicion
  sobre su entrada. Misma razon por la que el conteo se lee del plugin en vez de recalcularlo.
- **Salida para el caso en que la linea del plugin no esta en contexto.** El texto mandaba abrir una
  sesion nueva, que en un agente de Paperclip no sirve: esa rama del hook no inyecta pendientes por
  diseno. Ahora se nombran los tres casos, y en Paperclip la respuesta es que **nada** del volcado
  esta duplicado.

### Notas
- **Barrido completo de los carriers, no una muestra.** `templates/audit-3t.md` y
  `commands/setup-memory.md` tambien nombran `session-start.sh`, pero solo como **nombre de fichero**
  para detectar entradas huerfanas en `settings.json`: no leen su salida y no cambian. De las ocho
  plantillas, solo `audit-3t.md` lo nombra; las otras siete no. `README.md` ya se actualizo en
  2.17.0. Fuera de las pruebas, nada parsea el stdout del hook: los unicos lectores son
  `bin/test-parser.sh` y `bin/test-session-start-json.sh`, los dos como JSON desde 2.17.0.
- **Lo que hacia falta revisar no era la palabra "JSON", era la dependencia.** Ninguno de los tres
  ficheros menciona el formato de salida; el que cambia lo hace porque *decide* a partir de lo que el
  plugin emite. Buscar "stdout" o "JSON" en el repo no lo habria encontrado.

## [2.17.0] - 2026-09-11
El hook de SessionStart hablaba con un solo lector. La referencia de hooks lo dice: en SessionStart
Claude Code agrega el stdout plano **como contexto que ve el agente**, y para que un mensaje llegue a
la persona hay que devolver `systemMessage` en la salida JSON. Este hook no devolvia `systemMessage`
en ninguna linea, asi que todo lo que imprimia —pendientes, secretos en texto plano, eventos en
cuarentena— iba a un solo sitio. Medido el 2026-09-11 en este repo: 54 pendientes abiertos, 14 con
mas de 30 dias, el mas viejo del 2026-04-02. El agente los recibia en cada sesion y la cifra no
bajaba: cerrar un pendiente es una decision de la persona.

### Added
- **Canal a la persona: `systemMessage`.** `bin/session-start.sh` emite ahora UN objeto JSON con dos
  campos: `hookSpecificOutput.additionalContext` para el agente y `systemMessage` para la persona.
  El mensaje a la persona es corto a proposito — cuantos pendientes hay abiertos, cuantos pasan de 30
  dias, los tres mas antiguos con su fecha, y el comando que los cierra (`/triage-3t`). Un aviso que
  ocupa media pantalla en cada arranque se aprende a ignorar.
- **Los avisos que solo puede resolver una persona viajan tambien por `systemMessage`**: secretos en
  texto plano en `memory/` y eventos en cuarentena. Rotar una key que ya se pusheo no lo puede hacer
  un agente.
- **`bin/test-session-start-json.sh`** — 32 comprobaciones sobre la salida del hook. Entre ellas: que
  con `source=clear` la persona no recibe nada **pero el agente si**; que si falla la serializacion
  el bloque del agente sale intacto en texto plano con exit 0; que un agente de Paperclip no recibe
  `systemMessage` aunque haya avisos; y que un pendiente cuyo texto contiene la cadena que se uso
  como separador en el primer borrador no contamina el canal de la persona.

### Changed
- **El bloque del agente se recorta a ALTA y sin clasificar.** Antes listaba hasta 10 items de
  cualquier prioridad y cerraba con `[+N mas]`. Ese inventario no movia la cifra de abiertos. La
  relevancia por peticion ya la cubre `bin/recall.sh` (UserPromptSubmit, 2.8.0), que llega en el
  momento en que el item importa; el arranque se queda con lo urgente y con el total. Los items bajo
  secciones fuera del esquema Alta/Media/Baja siguen inyectandose, etiquetados como `SIN CLASIFICAR`:
  no son de prioridad media, es que nadie los ha clasificado. La regla 20 de `_learnings.md`
  (contenido, no contadores) sigue viva para esos dos grupos.
- **`session-start.sh` ya no imprime por su cuenta.** Cada linea pasa por `out` (agente) o `human`
  (persona) y hay una sola escritura a stdout, al final:
  `grep -c '^\s*echo ' plugins/3-tier-memory/bin/session-start.sh` da 0. JSON seguido de texto suelto
  no parsea, y para Claude Code un JSON roto es "el hook no hizo nada".
- **El resumen de la persona no vuelve por stdout.** El bloque de pendientes lo escribe en un fichero
  temporal que el shell lee y borra. El primer borrador separaba los dos canales con una sentinela
  (`---3T-HUMANO---`) dentro de la misma salida: un pendiente que llevara esa cadena en su texto
  partia el mensaje por ahi — el agente recibia el item truncado y la persona el resto del pendiente.
  Con dos destinos distintos esa clase de fallo no existe. Lo encontro el verificador externo.

### Fixed
- **`repair-dualwrite.py` ya no inventa ids en los pendientes con ventana.** Su `META_RE` borraba
  `_(origen|creado|id):` antes de re-derivar `sha1(texto+creado+origen)`, pero no `_revisar:`,
  mientras `journal-emit.strip_meta` si lo borra antes de hashear. El texto que se hasheaba llevaba
  la ventana pegada, el sha1 salia distinto, y **todo** pendiente con ventana se reportaba como
  `ids_invented` con un aviso de fila duplicada que nunca iba a ocurrir. Sobre `memory/` de este
  repo: `ids_invented=1` antes, `ids_invented=0` despues. Las dos expresiones quedan identicas
  carácter a carácter —las dos usan `(?:...)`, el grupo de `journal-emit` no se usaba— y cada una
  lleva un comentario apuntando a la otra. Caso 10 de `bin/test-repair-dualwrite.sh`, probado en rojo
  con el regex viejo.

### Notas
- **El filtro por `source` va dentro del script, no en el `matcher` de `hooks.json`.** El `matcher`
  sigue en `""`. Poner `startup|resume` ahi apagaria el hook entero en `clear` y `compact` — y en
  `clear`/`compact` el agente acaba de perder el contexto, que es justo cuando mas necesita
  `additionalContext`. El test 4 cubre esa regresion.
- **Si la serializacion falla, sale texto plano con el bloque del agente intacto y exit 0.** La
  persona se queda sin mensaje esa sesion; el agente no se queda sin memoria. El test 6 lo comprueba
  con un doble de `python3` que falla **solo** en la llamada que construye el JSON: uno que tumbe
  `python3` entero tampoco construiria el bloque de pendientes, y probaria otra cosa.
- **Sin stdin utilizable no hay `systemMessage`.** `source` se lee del payload del hook; sin payload
  el mensaje a la persona no sale. Es el lado seguro: repetirlo en cada `compact` lo vuelve ruido.
- **Una corrida no interactiva tampoco recibe `systemMessage`.** Son dos senales, no una:
  `PAPERCLIP_RUN_ID` definida, y `CLAUDE_CODE_SESSION_ATTENDED=0`. Medido el 2026-09-11 con un hook
  de registro: `claude -p` deja `CLAUDE_CODE_SESSION_ATTENDED=0` y `CLAUDE_CODE_ENTRYPOINT=sdk-cli`,
  donde una sesion interactiva deja `1` y `cli`. El canal se apaga solo con el `0` explicito: si la
  variable no existe —un CLI mas viejo— se deja pasar, que es el comportamiento anterior. Casos 11 y
  11b del test.
- **Coste medido**: por debajo de 0,3 s por arranque sobre la memoria de este repo (`/usr/bin/time
  -p`, tres corridas: 0,24 s aqui, 0,27-0,29 s en la verificacion independiente). El timeout del
  hook en `hooks.json` es de 10 s.

## [2.16.0] - 2026-09-11
El recordatorio de calendario no decia **en que proyecto** correr su propio prompt. Quien usa el
plugin en varios proyectos acumula recordatorios de todos en un mismo calendario: llegada la fecha,
tres campos escritos para un proyecto sin nombrar cual dejan un prompt que no se sabe desde donde
correr — y su linea `Contexto: memory/sessions/…` es una ruta **relativa** que no resuelve contra
nada.

### Added
- **El proyecto, en los dos lados del fence.** `Titulo` abre con `[<proyecto>]` y el fence abre con
  `Proyecto: <basename> — <ruta absoluta>`. No es redundancia: son dos preguntas distintas en dos
  momentos distintos. Fuera contesta *cual de mis recordatorios es este* al mirar el mes; dentro
  contesta *desde donde se corre esto* al pegar el prompt.
- **El prefijo va primero y cuenta dentro de los ~70 caracteres** del Titulo, asi que el que se
  acorta es el texto de la pregunta. El calendario corta por la derecha en vista de mes: lo unico
  que sobrevive siempre es lo que va primero, y el proyecto es justo el dato que distingue un
  recordatorio de otro.
- **La ruta va absoluta y tal cual**, sin `~` y sin variables. El agente que recibe el prompt puede
  estar arrancado en cualquier sitio, y `~` depende de que lo expanda el shell — en Git Bash/Windows
  no siempre apunta a lo mismo.
- **El basename del directorio raiz es el nombre**, no un nombre "bonito" ni el del repo remoto si
  difiere. Dos nombres para el mismo proyecto son dos versiones de la verdad.
- **Segunda prueba del bloque**, mas dura que la de 2.15.0: tapa el fence **y** la Descripcion. Si
  con el Titulo solo no sabes en que proyecto cae el recordatorio, el prefijo esta mal puesto.

### Changed
- **La regla de division deja de ser una particion.** Decia que fuera del fence va "solo Titulo y
  Descripcion"; el proyecto es el primer dato que va en ambos lados, y ahora la regla lo declara
  como excepcion explicita en vez de dejarlo a interpretacion de cada sesion.
- `/backfill-3t` hereda el mismo formato en su `## Recordatorios de calendario`, con una nota de
  que el proyecto es el del backfill que se corre, no el de la sesion reconstruida — son el mismo.
- **Step 8c-2 exige ahora que el encabezado `### <FECHA> — <Titulo>` reproduzca el `Título:` del
  bloque caracter por caracter**, con prefijo y con tildes. La regla ya lo decia; el unico bloque
  persistido que existe la incumplia (`linea/mas` en el encabezado, `línea/más` en el `Título:`)
  porque el resto de estos ficheros va sin tildes por convencion y la costumbre se cuela ahi. Dos
  versiones del mismo titulo dentro del mismo bloque.

### Notas
- **No medido, y es n=1 de uso.** El gap salio de un reporte de uso, no de una medicion: con el
  formato de 2.15.0, dos recordatorios generados en proyectos distintos son indistinguibles una vez
  que estan en el calendario. La medicion de 2.13.0 justifica que el bloque exista; el reporte
  justifica el campo. No hay dato que diga cuanto ayuda.
- El snippet de continuidad (Step 8a/8b) **no** emite la linea `Proyecto:`, y es deliberado: entre
  el encabezado de Step 8a y el de Step 8c no hay ninguna ocurrencia de `Proyecto:` en la plantilla.
  Los dos bloques tienen momentos de uso distintos y el formato lo refleja.
- Portadores enumerados antes de tocar nada (regla #130). `templates/checkpoint-3t.md` **define el
  formato** del bloque y `templates/backfill-3t.md` lo **referencia** con reglas propias de backfill;
  cada uno tiene ademas su copia en `.claude/commands/`, que se sincronizo.
  `plugins/3-tier-memory/commands/` solo tiene `migrate.md` y `setup-memory.md`, ninguno con el
  bloque, desde que 2.15.1 borro el tercer constructor. Aparte estan las **instancias ya generadas**
  por Step 8c-2 dentro de los session files, que tambien hay que reescribir: el bloque persistido es
  una copia literal del impreso, asi que editar la plantilla no cambia ninguno de los ya escritos.
  En este repo habia uno y quedo en el formato nuevo. La primera version de esta nota confundia
  "fichero que define el bloque" con "fichero que lo contiene"; lo encontro el adversario externo.
- Ningun script de `bin/` ni de `hooks/` lee la seccion `## Recordatorios de calendario`: su
  consumidor es humano.

## [2.15.2] - 2026-09-11
El aviso `BACKFILL PENDIENTE` del hook de arranque contaba mal, y contaba mal en la direccion que
no se apaga sola: **toda instalacion que salte sesiones legitimamente se queda con el aviso
encendido para siempre**. En esta instalacion decia 12 donde lo correcto son 6.

### Fixed
- **El contador de backfill de `bin/session-start.sh` cuenta ficheros, no totales.** Hacia
  `ls *.jsonl | wc -l` - `len(processed)` - 1, y se equivocaba por tres lados a la vez:
  1. **Ignoraba `skipped[]`**, que para `/backfill-3t` vale lo mismo que `processed[]` — su propia
     regla de Step 2 dice *"Already processed: filename appears in processed **or skipped** arrays
     -> skip"*. Una sesion trivial o ya presente en memoria se salta a proposito, pero seguia
     contando como pendiente. Aqui son 17 entradas.
  2. **Restaba UUIDs que ya no estan en disco.** Claude Code borra `.jsonl` viejos; cada uno que
     desaparece sigue ocupando su sitio en el progreso y desplaza el numero. Aqui el progreso
     tiene 18 entradas (1 en `processed` + 17 en `skipped`) y **11 son fantasmas**: la unica de
     `processed` y 10 de las 17 de `skipped`.
  3. **Restaba 1 a ciegas "por la sesion actual"**, que sobra si ese `.jsonl` todavia no existe o
     si ya esta en `processed`. Ahora se excluye **por nombre**, con `transcript_path`/`session_id`
     del payload del hook (`$_HOOK_INPUT`, que ya bufferiza `resolve-project-dir.sh`).

  **Sin payload no se resta nada, a proposito.** Hubo una version intermedia con heuristica de
  mtime (descartar el `.jsonl` escrito en los ultimos 5 minutos) y la ronda adversarial la tumbo:
  no es una prueba de identidad, asi que puede descartar un fichero historico recien tocado y
  **silenciar** una sesion pendiente de verdad. De los dos fallos posibles, contar 1 de mas se ve
  y se corrige en cuanto llega un payload; silenciar no se ve nunca. Lo **medido** es que en esta
  instalacion el payload de `SessionStart` trae `session_id` y `transcript_path`; lo que **no** se
  ha auditado es si algun otro host, modo o version invoca el hook sin stdin. Si ocurriera, el
  aviso se queda 1 por encima mientras dure — visible y acotado, no el 12 permanente de antes.

  `totalFound` y `skippedReason` se evaluaron como fuente y **se descartaron con evidencia**:
  `totalFound` es una foto del ultimo run (decia 8 con 14 ficheros en disco) y `skippedReason` solo
  cubre el ultimo run (7 de 17 entradas). La unica fuente de verdad es cruzar
  `processed ∪ skipped` **contra el disco**.

  Paridad con el glob anterior: se saltan los dotfiles (para no contar `.recall-index.jsonl`) y se
  exige `isfile`, porque un **directorio** llamado `algo.jsonl` lo enumeraba `ls` por su contenido
  y `os.listdir` lo contaba como una sesion.

  Reparto de fallos explicito: progreso ausente, ilegible **o con tipos que no son los del
  contrato** = nada resuelto, y avisa (es el caso de instalacion nueva); fallo del propio `python3`
  = no avisa, antes que publicar una cifra inventada. La validacion del progreso tiene **dos
  niveles distintos a proposito**: una *clave* que no sea una lista (un numero, un string, `null`)
  vale vacia **entera**, para que un JSON valido con tipos raros no pueble la lista de resueltos a
  medias antes de fallar; dentro de una lista, un *elemento* que no sea cadena no vacia se ignora
  **uno a uno** y los demas se honran, porque tirar la lista entera por un elemento basura
  descartaria trabajo real ya hecho. Los dos niveles fallan hacia contar de mas. El `test` se
  protege de la cadena vacia con `[ -n "$REMAINING" ]`.

### Verificado
Banco de 15 casos que **re-extrae el bloque del fichero real en cada ejecucion** (una version
anterior del banco cargaba una copia congelada: habria seguido pasando en verde con el hook ya
cambiado). La columna "vieja" tampoco es un proxy escrito a mano: es **el bloque de 2.15.1 sacado
de `git show HEAD:` y ejecutado igual que el nuevo**, porque un proxy en Python diverge justo donde
importa — `ls dir/*.jsonl` sobre un *directorio* enumera su contenido y suma lineas, `os.listdir`
lo cuenta una vez. Diez casos **discriminan** —lo que el usuario habria visto con 2.15.1 es otro
numero— y cinco son controles donde vieja y nueva coinciden a proposito:

| caso | vieja | nueva |
|---|---|---|
| repro de esta instalacion (skipped>0 + fantasmas + dotfile) | 12 | **6** |
| la sesion actual ya esta en `processed` (la vieja resta de mas) | 2 | **3** |
| todo en `skipped` — el aviso se apaga; antes no se apagaba nunca | 2 | **0** |
| progreso con nombres **sin** extension (`"a1"` en vez de `"a1.jsonl"`) | 2 | **1** |
| un **directorio** llamado `x.jsonl` no es una sesion | 6 | **3** |
| `skipped` no es lista (`7`): esa clave vale vacia, `processed` se honra | 2 | 2 *(control)* |
| `processed` es string en vez de lista: se ignora entera | 0 | **3** |
| elementos no-string dentro de la lista: se ignoran uno a uno (los validos se honran) | 0 | **2** |
| el progreso entero no es un objeto (es una lista) | 3 | 3 *(control)* |
| **sin** payload: no se resta nada (nunca silencia) | 3 | **4** |
| payload que no es JSON | 3 | **4** |
| payload sin `session_id` ni `transcript_path` | 3 | **4** |
| sin `.backfill-progress.json` (instalacion nueva) | 3 | 3 *(control)* |
| progreso corrupto — nada resuelto, avisa igual | 3 | 3 *(control)* |
| solo el `.jsonl` de la sesion actual | 0 | 0 *(control)* |

Forma del fixture del primer caso, para reconstruirlo sin re-derivarlo: 14 `.jsonl` visibles mas
`.recall-index.jsonl`; `processed` = 1 UUID que ya no esta en disco; `skipped` = 17, de los que 7
siguen en disco; el `.jsonl` de la sesion en curso presente y en ninguna de las dos listas.

Y ejecutado end-to-end, el hook entero con el payload de la sesion en curso por stdin, contra la
instalacion real: **6**. Esa ejecucion tambien demuestra que `$_HOOK_INPUT` sobrevive las ~470
lineas que separan el `source` del contador.

Este arreglo paso por `/goalspec:adversary` (backend externo, GPT-5) **dos veces**. La primera
ronda devolvio `break` con nueve hallazgos confirmados: la heuristica de mtime, el filtro `isfile`,
los tipos del progreso, el banco que cargaba una copia congelada, la regla 34 stale y una decision
narrada en prosa en vez de preguntada. La segunda, tras arreglarlos, bajo a tres, todos de la misma
clase —afirmaciones mias mas fuertes que la evidencia— y los tres estan corregidos arriba: la
descripcion de la validacion por tipos, el "siempre llega" sobre el payload, y dos celdas de esta
tabla que estaban derivadas de un proxy en vez del bloque viejo real (el caso del directorio decia
4 y son 6; el de `processed` string decia -5 y es 0, porque con un numero negativo el aviso no se
imprime).

## [2.15.1] - 2026-09-11
La divergencia que destapo la ronda adversarial de 2.15.0: **dos plantillas construyen session files
y no construian el mismo**. `/checkpoint-3t` y `/backfill-3t` llevaban esqueletos distintos, y la
diferencia no era solo cosmetica — se llevaba por delante un campo con dos consumidores reales.

### Fixed
- **`/backfill-3t` nunca emitia `--revisar`** (el hueco de verdad, por encima del esqueleto). Un
  pendiente reconstruido que nombra una fecha futura nacia sin la ventana declarada, asi que
  `expire-pendientes.py` no podia protegerlo de caducar y el barrido de `/triage-3t` no lo veia.
  **El hueco esta vivo, no es historico**: hay JSONL sin procesar fechados hoy y ayer (comprobado
  por fecha de fichero), y hoy mismo nacio un pendiente con fecha 2026-10-11. Un backfill hoy lo
  habria perdido. La regla compara **contra hoy, no contra `--creado`**: lo que decide es si la
  fecha sigue viva ahora.
  **No se publica un numero de sesiones pendientes a proposito.** La primera version de esta entrada
  decia "10 sesiones sin procesar", copiado del aviso del hook de arranque. Ese contador no sirve:
  `session-start.sh:538` calcula `JSONL_COUNT - PROCESSED - 1` e **ignora `skipped[]` por completo**,
  que en esta instalacion tiene 17 entradas; ademas el unico UUID en `processed` ya no existe en
  disco. Es un defecto del contador, no un dato. Lo encontro el verificador externo.
- **`## Callejones sin salida` faltaba en el esqueleto del backfill**, asi que toda sesion
  reconstruida nacia sin la seccion que alimenta la linea `No repitas:` del snippet de continuidad.
  Se rellena **solo con lo que el transcript dice que se abandono**, nunca por inferencia: un
  callejon inventado viaja a la sesion siguiente como si fuera un acuerdo del usuario y cierra un
  camino que nadie descarto. Si el transcript no lo dice, `Ninguno`.
- **`## Recordatorios de calendario` faltaba**, y ahora se escribe con la misma regla condicional
  que en `/checkpoint-3t`, gateada por "la fecha sigue siendo futura en el momento de correr el
  backfill". Una fecha ya pasada no genera recordatorio: el evento llegaria vencido.
- **La nota de acomodo de `/checkpoint-3t` acotada.** Decia que un fichero sin `## Callejones sin
  salida` viene de "una version anterior a 2.12.2, o /backfill-3t"; desde 2.15.1 el backfill si la
  escribe, asi que ahora dice "un /backfill-3t anterior a 2.15.1". Una excepcion sin fecha de
  caducidad se convierte en permanente.

### Added
- **`## Como retomar` sigue sin escribirse en el backfill, pero ahora es una omision DECLARADA**
  con su razon en la plantilla, no un hueco silencioso. El snippet dice donde quedamos y cual es el
  proximo paso; en una sesion reconstruida meses despues eso es falso por construccion, y se pega
  tal cual. **Es la unica divergencia que queda entre los dos esqueletos**, y ahora esta escrita
  donde se lee.
- README: el bloque de recordatorio de calendario llevaba sin documentar desde 2.13.0. Una linea.
- **Regla para las fechas relativas** en Step 3d, que faltaba: `en 2 semanas` se resuelve contra la
  fecha de la SESION, no contra hoy, porque eso es lo que significaba cuando se escribio; solo
  despues se compara el resultado con hoy. Y si la expresion es demasiado vaga para dar una fecha
  (`mas adelante`, `cuando se pueda`), **no se emite `--revisar`**: una ventana inventada es peor
  que ninguna, porque `expire-pendientes.py` la trata como un compromiso declarado por el usuario.

### Notas de verificacion
- **Habia un TERCER constructor, y el primer barrido no lo vio.** `commands/backfill.md` construia
  su propio esqueleto completo de session file: sin `## Callejones sin salida`, sin
  `## Recordatorios de calendario` y **sin `--revisar`**. Era el fichero detras del comando nativo
  `/3-tier-memory:backfill`, sin tocar desde el 2026-09-02. O sea que el defecto que esta version
  dice cerrar seguia vivo en una de las dos vias de invocacion. **Borrado**, no sincronizado: el
  README ya documenta el backfill como `/backfill-3t` (el local) y solo trata `setup-memory` y
  `migrate` como comandos nativos, y la regla de distribucion de este proyecto prohibe enviar
  comandos duplicados. La capacidad no se pierde — `/backfill-3t` la sigue dando y el hook lo
  instala solo; lo que desaparece es un segundo nombre que servia instrucciones viejas.
- **Superficie barrida, ahora con dos sondas y sin puntos ciegos.** Constructores de session file en
  todo el repo: `checkpoint-3t` y `backfill-3t`, y ya no hay un tercero. `consolidate-3t` solo LEE
  dos secciones (`## Cambios realizados`, `## Learnings generados`); `enrich-3t` lee secciones
  nombradas; `audit-3t` solo comprueba que `## Related` exista y contenga sus wikilinks — **por eso
  la divergencia era invisible**: ninguna comprobacion automatica mira el conjunto de secciones.
  `triage-3t` usa `## Related` para su propia documentacion. `checkpoint-paperclip` no vive aqui.
- **Por que el primer barrido fallo, que es lo que hay que recordar.** Dos causas independientes:
  (a) se busco en `templates/` y `.claude/commands/` y **no en `commands/`**, que es la superficie
  nativa del plugin;
  (b) el `grep` de una sesion de Claude Code **no es `/usr/bin/grep`**: es una funcion de shell
  instalada por el snapshot de la sesion, que ejecuta el ugrep incluido con `--ignore-files`, o sea
  que **salta lo que esta en `.gitignore`**. Medido en este repo, `grep -rl "## Cambios realizados" .`
  desde la raiz devuelve 4 ficheros; `/usr/bin/grep -rl` sobre lo mismo devuelve 50, incluidos todos
  los de `.claude/`, `memory/` y `.goalspec/`. Nombrar el directorio de forma explicita
  (`grep -r ... .claude/`) si lo encuentra — el punto ciego es solo al recursar desde la raiz.
  La primera redaccion de esta nota decia "grep en esta maquina es ugrep", y el verificador externo
  la refuto enseñando que el binario del PATH es BSD grep; las dos mitades eran imprecisas y la
  medicion de arriba es lo que queda. **"`grep -r` no lo encuentra" no es prueba de ausencia en este
  repo.** El barrido bueno usa dos sondas distintas (`## Cambios realizados` y
  `## Learnings generados`), enumera `commands/` a mano, y contrasta con `/usr/bin/grep`.
- **Una cuarta divergencia, encontrada al commitear**: de los ocho comandos que el plugin instala
  en `.claude/commands/`, **exactamente uno estaba trackeado en git** (`backfill-3t.md`) pese a que
  `.gitignore` ignora `.claude/` desde su linea 1 — un `.gitignore` no destrackea lo que ya estaba
  dentro. La copia commiteada llevaba tiempo desincronizada de su plantilla, asi que quien clonara
  el repo se llevaba la version vieja del comando. Destrackeado con `git rm --cached`: el fichero
  **sigue en disco**, y el hook `session-start.sh` lo regenera desde la plantilla como a los otros
  siete. Era un accidente, no un diseno: ninguno de los otros siete estaba trackeado.
- **La cadena de `--revisar`, probada sobre una memoria temporal** (no sobre la real). Emitido
  `pendiente.add` con `--creado 2026-09-10` (pasado) y `--revisar 2026-10-11` (futuro), que es
  exactamente la combinacion que produce un backfill, y compactado: la linea de Tier 2 sale con
  `— _revisar: 2026-10-11_` y la fila de Tier 3 aterriza en el mes de `--creado` (2026-09), que es
  lo correcto. O sea que el comando que la plantilla manda escribir funciona tal cual esta escrito.
- **`expire-pendientes.py` SI discrimina por la ventana, medido.** El primer control no separo las
  dos ramas y se publico como "no demostrado"; el fallo era el parametro, no el mecanismo:
  con `--days 1` el item tenia `edad=1 <= days=1`, asi que no era candidato por ninguna via. Repetido
  con `--days 0`: el item **sin** `--revisar` sale `candidatos: 1`; el item **con** `--revisar`
  futuro sale `candidatos: 0` y `excluidos: _revisar futuro 1`. Las dos ramas separadas. Lo corrigio
  el verificador local, en la direccion de reforzar el resultado, no de tumbarlo.
- **Lo unico que sigue SIN probar**: que un agente leyendo Step 3d emita el flag. Eso es un prompt,
  no codigo, y no hay forma de probarlo sin correr el backfill — que sigue bloqueado por su propio
  defecto ALTA de Step 1: el dedup "already in memory" se apoya en `customTitle`, `null` en todos
  los JSONL actuales, y una ejecucion literal creaba 7 sesiones duplicadas (`p-ccd3261a60`).
  Encadenado a ese pendiente.
- El defecto del contador de backfill del hook **ya estaba anotado** como `p-6ebc35ab3d`; esta
  entrada no abre uno nuevo, solo explica por que no se publica su numero.

## [2.15.0] - 2026-09-11
El bloque de recordatorio de calendario (Step 8c de `/checkpoint-3t`) pasa a tener la forma de un
evento de calendario: **Titulo**, **Descripcion** y, aparte, el prompt dentro de un fence. Hasta
2.14.3 el bloque entero era prompt, escrito para el agente. El humano que abre el calendario un mes
despues leia una instruccion dirigida a otro y no tenia forma de saber de que iba el pendiente.

### Added
- **Tres campos en vez de uno.** `Titulo:` (una linea, va al nombre del evento), `Descripcion:`
  (2-4 lineas de prosa, para ti) y el prompt en un fence ```` ``` ````, que es lo unico que se pega
  al agente.
- **Una regla de division explicita**, para que no se re-decida en cada sesion donde va cada cosa:
  dentro del fence va lo que el AGENTE necesita para actuar (`_id: p-…`, la ruta del session file,
  las cifras, el criterio y la clausula `Si ya no aplica, cierralo con /checkpoint-3t`); fuera va
  solo lo que TU necesitas para decidir si vale la pena abrir el portatil. Sin esa frase, la
  siguiente sesion sube el id al Titulo o se deja la clausula de cierre fuera.
- **`Descripcion` va sin cifras.** Baselines, umbrales y listas por proyecto viven solo en
  `Comprueba:`, dentro del fence. La descripcion se lee en el movil para decidir si abrir el
  portatil; las cifras son trabajo del agente y duplicarlas crea dos versiones del criterio.
- **Regla de fallback para el pendiente sin decision detras.** Si se construyo algo y nunca se
  midio, sin criterio acordado, la Descripcion lo dice tal cual (`No hay criterio acordado: ese dia
  hay que decidir uno antes de mirar nada`) en vez de inventar un acuerdo. Una descripcion inventada
  te hace llegar a la fecha creyendo que hubo un trato que nunca existio.
- **Step 8c-2 — los recordatorios se persisten.** Nueva seccion `## Recordatorios de calendario` en
  el session file, entre `## Como retomar` y `## Related`, con `### <FECHA> — <Titulo>` por bloque.
  Hasta ahora el recordatorio solo se imprimia al terminal: si perdias el scrollback, se perdio.
  El tope de 2 sigue aplicando **solo a la terminal** (esta para no llenarla); en el fichero van
  todos. Los bloques persistidos son identicos a los impresos, misma regla que 8a/8b.
- El esqueleto del session file incorpora la seccion con su placeholder, y la nota de cierre de
  Step 8 ahora nombra las dos secciones que quedan fuera del commit de Step 6, no solo una.

### Lo que NO esta medido
A diferencia del resto de este CHANGELOG, **esta version no trae un numero detras**. La medicion de
2.13.0 (11% de los pendientes nuevos traen fecha futura; 395 de 996 abiertos llevan una fecha
vencida que ningun codigo leyo nunca) justifica que el bloque **exista**; no dice nada sobre si los
tres campos ayudan. La evidencia aqui es un reporte de uso: el bloque se probo en una sesion real,
funciono como mecanismo, y el usuario reporto que al llegar la fecha no sabria de que iba el
pendiente. Se acepta sin medir porque el costo es prosa en una plantilla y el fallo que corrige se
observa a un mes vista, cuando ya no hay como arreglarlo.

### Notas de verificacion
- **La prueba es tapar el fence.** Leyendo solo Titulo + Descripcion tiene que quedar claro que era
  el pendiente, que se decide ese dia y que pasa segun el resultado. Renderizados dos casos reales:
  `p-cd965754ec` (con decision, baseline y condicion de muerte) y `p-0e32d4f412` (delgado, sin
  criterio acordado). El segundo es el que importa: el caso bonito pasa se escriba lo que se
  escriba; la plantilla solo sirve si un pendiente sin decision detras produce una descripcion
  honesta. Por eso existe la regla de fallback.
- **Anidamiento de fences**: el bloque de ejemplo contiene un fence, asi que va con cuatro comillas
  invertidas, como ya hacia el ejemplo de Step 8a. Comprobado que las cuatro aperturas/cierres
  quedan en el orden correcto.
- **Barrido antes de tocar el esqueleto**: anadir una seccion entre `## Como retomar` y `## Related`
  romperia cualquier script que inserte "antes de `## Related`" o "al final del ultimo bloque" — un
  wikilink aterrizaria dentro de un recordatorio. Los usos de `## Related` en `bin/` (excluyendo
  `test-*`) son **siete**, y ninguno toca un session file:
  `normalize-pendientes.py:19` (docstring, `_pendientes.md`); `session-start.sh:259` y `:456`
  (**leen** `_learnings.md` para contar reglas); `journal-compact.py:31` (docstring de `--section`,
  ficheros de tema), `:426` (crea el archivo mensual `memory/pendientes/YYYY-MM.md`), `:829`
  (`body_region()`, ficheros de tema) y `:873` (crea un fichero de tema nuevo). Los session files
  los escribe el agente, no el compactador. No hay colision.
- **Correccion sobre la ronda adversarial de esta misma version**: la primera redaccion de esta nota
  decia "los cinco usos" y "todos operan sobre `_pendientes.md` y ficheros de tema". Las dos mitades
  eran falsas —son siete y dos de ellos leen `_learnings.md`— porque el barrido se hizo sobre tres
  ficheros elegidos a mano en vez de sobre `bin/` entero. La conclusion aguanto la re-derivacion
  independiente; la evidencia publicada no. Lo encontro el verificador externo.
- **Un adversario que usa `rg` no ve `.claude/`**, porque `rg` respeta `.gitignore` y ahi esta
  ignorado desde la linea 1. En esta ronda eso produjo un hallazgo falso ("el comando local sigue
  desactualizado") sobre un fichero que si estaba sincronizado, comprobado con `diff`. En este repo,
  "`rg` no lo encuentra" no es prueba de ausencia dentro de `.claude/`.
- Ninguna otra plantilla lleva Step 8c ni el esqueleto del session file: `checkpoint-paperclip` no
  tiene esa seccion, asi que no queda desincronizado.

### Riesgos residuales, declarados
- **El texto no es reproducible.** Titulo y Descripcion los redacta el agente en cada checkpoint, no
  son campos del pendiente. Si otra sesion reimprime el recordatorio, la prosa sale distinta. Se
  eligio a sabiendas: la alternativa era `--titulo`/`--descripcion` en `pendiente.add`, que obliga a
  tocar emisor, compactador, esquema y a migrar los 996 abiertos que no los tienen.
- Si el agente salta Step 8c-2, el session file se queda con el placeholder a la vista. Es la misma
  clase de fallo que ya tienen `<filled in Step 6>` y los demas, no un mecanismo nuevo.

## [2.14.3] - 2026-09-11
Los dos defectos de `bin/resolve-project-dir.sh`, el fichero que sourcean los **ocho** hooks del
plugin. Los dos se ven igual desde fuera —"el hook no hizo nada"— y por eso los dos sobrevivieron
tanto: un hook que muere en la primera linea es indistinguible de uno que decide callarse.

### Fixed
- **Referenciaba `$CLAUDE_PLUGIN_ROOT` y `$CLAUDE_PROJECT_DIR` sin proteger** (`p-a4fcd4212a`), asi que cualquier llamante con `set -u` moria en la linea 10 antes de hacer nada. No es teorico: mordio al escribir `bash-journal-nudge.sh`, que acabo **sin `set -u` por este motivo**. Ahora toda lectura usa `${VAR:-}` y —la mitad que faltaba— las dos variables quedan **ASIGNADAS al salir aunque no haya ruta que resolver**, porque los ocho llamantes las usan justo despues del `source` y tambien pueden llevar `-u`.
- **`_HOOK_INPUT=$(cat)` esperaba EOF para siempre** (`p-0e978674af`), asi que sin stdin se colgaba. Claude Code siempre manda el JSON y lo cierra, o sea que en produccion no se vio; lo que colgaba era **toda prueba manual**, y dos veces se diagnostico como "el script no imprime nada". Ahora: con un terminal en stdin no lee nada y vuelve al instante; con una tuberia **espera al primer byte** como mucho `HOOK_STDIN_TIMEOUT` (5 s) y, si llega, lee hasta EOF **sin limite**.

### Notas de verificacion
- **El tope acota la espera inicial, NUNCA la lectura.** La primera version de este arreglo acotaba la lectura entera (`read -r -d '' -t 5`) y eso **truncaba**: medido con un productor que manda 300 bytes, para 4 s y manda el resto, con el tope en 2 s deja **0 bytes** y ademas rompe la tuberia del que escribe. Un JSON a medias es otra vez "el hook no hizo nada" — el fallo que este fichero existe para quitar — y `journal-guard.sh` es PreToolUse de `Write`, o sea que `tool_input.content` trae ficheros enteros que no llegan en un solo trozo. La forma final entrega los 619 bytes completos, igual que el `$(cat)` de antes.
- La forma final es `read -r -d '' -n 1 -t T` (un byte, con `-d ''` para que un `\n` inicial se guarde en vez de desaparecer) y luego `$(cat)` **dentro del `if`**: llamar a `cat` despues de un tope agotado se cuelga exactamente igual que el codigo viejo — pasado por error en una prueba, y por eso queda escrito.
- Un error de atribucion que estuvo a punto de colarse en este mismo CHANGELOG: se midio "leer todo con `read -r -d ''` tarda 118 s con 1 MB" y se atribuyo a que `read` va byte a byte. **Era falso.** Los 118 s los gastaba un bucle propio que quitaba los saltos de linea finales copiando 1 MB por vuelta. `read -r -d ''` pasa 5 MB en 1-2 s. El bucle se cayo solo al usar `$(cat)`, que ya recorta esos saltos.

### Added
- `bin/test-resolve-project-dir.sh` — 20 aserciones. **Discriminacion medida, no afirmada**:
  - contra el fichero de 2.14.2: `pass=0 fail=13`. Ninguna pasa: D1 aborta el `source` antes de cualquier otra cosa, y las 7 aserciones que faltan hasta 20 van anidadas detras de una que ya fallo, asi que ni se ejecutan;
  - contra una copia con **solo D1** arreglado: `pass=19 fail=1`, y la unica roja es el caso del fifo. Ese es el testigo de D2, uno y solo uno;
  - contra una copia con la forma **descartada** (`read -r -d ''`): cae la asercion del productor lento, `bytes=0 (esperaba 619)`. Esa es la parte que se sostiene en cualquier maquina. El recuento total NO es portable y por eso ya no se afirma: aqui sale `pass=18 fail=2` de forma estable (3/3) porque el caso del terminal tambien cae, pero la ronda 8 midio `pass=19 fail=1` en otra maquina, donde `script` cierra el pty y manda EOF y la forma descartada vuelve al instante.
  - La asercion del productor lento compara contra 619 bytes exactos (19 de JSON + 300 + 300). Se comprobo que **cae y dice el numero** si el productor manda un byte mas: `bytes=620 (esperaba 619)`.
- El caso de `set -u` corre bajo `env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR`: con la variable puesta —lo normal en una sesion real— el codigo viejo nunca toca la expansion sin proteger y la prueba pasaria **sin probar nada**.
- El caso sin stdin usa un **fifo abierto en lectura-escritura que nadie escribe**, con limite duro de 8 s: no necesita pty y por eso corre igual en macOS y en Linux. El caso del terminal usa `script`, se salta donde no haya pty, y **no cuenta como prueba de D2**: `script` cierra el pty al terminar, asi que manda EOF y `$(cat)` tambien volvia — medido. Ese `script` ademas hereda el stdin del llamante, y sin `</dev/null` la deteccion salia distinta segun quien corriera la suite (0/3 sin redirigir, 3/3 con `/dev/null`).

### Ronda 8 — dos verificadores adversariales, los dos con contexto limpio
- **Subagente local (Sonnet 5, modelo distinto al ejecutor)**: `ungrounded=1 unfalsified=1 incomplete=1 autonomy-violations=0 unsafe=0`. Reconstruyo los tres controles por su cuenta desde `git show HEAD:...` y **re-derivo**: 20/0 (3 corridas), 0/13 con la causa leida en el arnes (las 13 que corren mueren en `line 10: CLAUDE_PLUGIN_ROOT: unbound variable`, las 7 restantes van anidadas detras de una que ya fallo), 19/1 contra solo-D1, las siete suites, `scanned=23 undeclared=0`, el productor lento fuera del arnes (619 vs 0 bytes + `BrokenPipeError` real en el escritor), y el off-by-one del 619. Ademas probo la propiedad (b) de D1 bajo `env -i`, mas estricto que el `env -u` del arnes.
- **Externo (`codex exec`, otro proveedor)**: `ungrounded=8 unfalsified=0 incomplete=2 autonomy-violations=0 unsafe=0`. Las 8 de grounding son **una sola causa declarada por el propio verificador**: su sandbox le denego `mktemp` (`Operation not permitted`), no pudo correr la suite, y marco como no re-derivada cada cifra. Es la misma limitacion que tuvieron las rondas 4 y 6. Lo que si pudo hacer —inspeccion estatica y busqueda global— refuto por su cuenta D1 completo, la ausencia de un `cat` fuera de la rama, la no dependencia de `export` en los ocho llamantes, y la aritmetica del 619.
- **Lo que encontraron y se arreglo**: los dos docstrings de `triage-scan.py` y `expire-pendientes.py` (los dos verificadores, por separado); la frase de la cabecera sobre el tope; y la cifra `18/2`, que el local no pudo reproducir.
- **Riesgo residual revelado, no oculto**: si el productor manda el primer byte y luego se estanca sin cerrar, el `source` espera sin limite. El local lo reprodujo (vivo a los 6 s). Es deliberado — la alternativa es truncar — y la cabecera lo dice.
- **Sin verificar**: Git Bash en Windows. Ninguno de los dos tiene esa plataforma. El codigo evita `read -N` (bash 4.1) a proposito, pero eso no sustituye una corrida real.

### Changed
- El comentario de `bash-journal-nudge.sh` que afirmaba el defecto ("Sin `set -u`: resolve-project-dir.sh referencia CLAUDE_PLUGIN_ROOT sin proteger") ya no es cierto y lo dice. El hook sigue sin `set -u`: encenderlo es otra revision, la del camino de ~10 ms, y no se ha hecho.
- `templates/triage-3t.md` decia que no se invocara el script porque "sin stdin se cuelga". El consejo sigue valiendo —no imprime nada, solo deja variables puestas— pero la razon cambio.

## [2.14.2] - 2026-09-11
### Fixed
- **El lock no cerraba la ventana, y tomarlo mejor tampoco.** Tercer intento sobre el mismo defecto. 2.14.0 arreglo "`--check-drift` sin lock" tomandolo; 2.14.1 arreglo "dos locks" fundiendolos en uno. El adversario de la ronda 7 re-probo y mostro que **ninguno de los dos era el problema**: una escritura por Bash —el caso que este mecanismo existe para cazar— **nunca pide `.journal/.lock`**, asi que tomar el lock no la bloquea ni la hace esperar. La ventana real estaba entre las **dos lecturas de bytes**: la de `detectar_fuera_de_banda()` y la de `guardar_huellas()`. Lo que se escribiera entre ambas quedaba fuera del aviso y del log, pero dentro de la linea base — absorbido en silencio.
  - Arreglo: **una sola lectura, reusada**. `leer_estado()` hashea una vez; ese mismo estado se compara y se sella. Lo que se escriba despues queda FUERA de la linea base, asi que la comprobacion siguiente lo ve.
  - La misma ventana existia en `compact()`, entre su ultima escritura y su sellado. `atomic_write()` apunta ahora el hash de lo que deja en cada fichero y el sellado lo prefiere sobre releer el disco.
- Las pruebas nuevas comprueban primero que **la version rota SI absorbe** una edicion, y solo entonces que la actual no. Sin esa primera mitad serian pruebas que pasan por construccion.

## [2.14.1] - 2026-09-11
Hallazgos de la **ronda 7**, la primera con el adversario LOCAL (subagente en Sonnet 5, modelo
distinto al ejecutor y con id acreditable — el partner externo de las rondas 4 y 6 se auto-reportaba
`UNKNOWN`, asi que nunca pudo respaldar `model=different`). Tambien fue la primera que **pudo correr
las suites**: las rondas 4 y 6 tenian `mktemp` denegado en su sandbox.

### Fixed
- **`scan-secrets.py` escribia indices protegidos y era INVISIBLE al detector.** `iter_files()` recorre todo `memory/` con `os.walk` filtrando solo por extension `.md`, asi que con `--apply` reescribe `_pendientes.md` o un mensual si contienen un secreto — legitimamente, porque es el gate de `/checkpoint-3t` Step 6 (redact-then-commit). No re-sellaba, asi que el detector de deriva **acusaba a una herramienta del propio plugin** de una edicion manual no auditada, y encima le decia "usa journal-emit.py", que para una redaccion es un consejo imposible. Reproducido de punta a punta. Ahora re-sella.
  - Y el detector no lo veia: **`check-index-writers.py` solo escaneaba los scripts que NOMBRAN un indice como literal**, y este construye la ruta con `os.walk` + `os.path.join`. No aparecia en `scanned`, ni en `si`, ni en `no`. Esa criba era el agujero: ahora **se declara TODO script de `bin/`**, 23 en total. La unica version que no puede perderse nada es la que no decide a quien mirar.
- **Partir la seccion critica en dos locks reabria una version angosta del mismo hueco.** 2.14.0 arreglo "`--check-drift` sin lock" tomando el lock para detectar, soltandolo, y tomando otro para anotar y sellar. El adversario reprodujo la ventana: una edicion que caiga entre ambos **se absorbe en silencio** — `fuera` ya esta calculado y no la incluye, asi que no sale en el aviso ni en `out-of-band.log`, pero `guardar_huellas()` hashea el disco en ese instante y la fija como linea base. Sin log, sin aviso, sin evento. Ahora detectar, anotar y sellar ocurren bajo **una sola adquisicion**.

### Notas de verificacion
- El adversario **re-derivo las siete suites y `check-index-writers.py` por su cuenta** y coincidio con lo afirmado (40/40, 84/84, `RESULT: PASS`, `TODO VERDE`, 19/19, 19/19, 26 ok, `scanned=18 undeclared=0`). Tambien re-derivo la discriminacion de D6 comentando solo el bloque del titulo: 40/0 → 38/2 con las dos fallas exactas. Es la primera re-derivacion independiente de estas cifras en toda la serie.
- La suite `test-bash-nudge.sh` pasa de 40 a **47** aserciones. La del hueco entre locks mide sobre el MODULO, llamando a las funciones en el orden del codigo — que es como el adversario lo rompio — y comprueba primero que la secuencia partida SI absorbe una edicion, antes de comprobar que el binario real no.

## [2.14.0] - 2026-09-11
Los ocho hallazgos confirmados de la **ronda 6** del verificador adversarial externo
(`break ungrounded=2 unfalsified=1 incomplete=4 autonomy-violations=1 unsafe=0`).

### Fixed
- **"Exacto, cero falsos positivos" era falso.** `--check-drift` no tomaba el lock, asi que podia leer un indice que el compactador acababa de reescribir **legitimamente** pero aun no habia sellado (`compact()` sella al final, dentro del lock). Eso producia un `FUERA DEL JOURNAL` falso y una linea falsa en `out-of-band.log`. Ahora `--check-drift` y `--reseal` toman el lock; si esta ocupado, no comprueban nada (hay un compactador trabajando y el sellara). Prueba nueva **con control negativo**: con el lock ajeno tomado no inventa deriva, y liberado si la ve.
- **La huella no veia un indice BORRADO ni un mensual creado a mano.** `indices_protegidos()` solo devolvia ficheros existentes y `detectar_fuera_de_banda()` saltaba las rutas sin huella previa — asi que borrar `_pendientes.md` entero, la escritura destructiva mas grave que hay, no disparaba nada. Ahora se reportan como `(BORRADO)` y `(nuevo, no lo creo el compactador)`.
- **Borrar `_pendientes.md` dejaba al plugin ciego**: diez scripts lo usan como centinela para localizar `memory/`. La deteccion mira ahora tambien `.journal/`, en `bash-journal-nudge.sh` y en `resolve_memory_dir()` del compactador. Los otros ocho scripts siguen con el criterio viejo.
- **La compuerta de mtime perdia escrituras del mismo segundo.** `find -newer` exige marca estrictamente posterior; en un sistema con resolucion de 1 s una escritura empatada con el sellado no se veia. Se compara `>=` con `stat`, y un indice borrado (sin mtime que comparar) se detecta por el numero de ficheros frente al de huellas.
- **`enrich-memory.py` tampoco re-sellaba** (ya en 2.13.5), y es el que `/triage-3t` manda correr antes del barrido.

### Changed
- **El detector de escritores dejo de adivinar.** Cuatro intentos de deducir por analisis de texto quien escribe un indice salieron cortos; el ultimo no veia `normalize-pendientes.py`, que hace `(jc.replace_with_retry if jc is not None else os.replace)(tmp, path)` — una forma que ninguna regex razonable iba a cazar. Ahora cada script que nombre un indice **declara** `# sella-huellas: si` o `# sella-huellas: no (razon)`, y `bin/check-index-writers.py` lo exige. Un falso positivo cuesta una linea de comentario; un script nuevo que lo olvide falla la prueba. Cuando dice `si`, se comprueba ademas que la llamada exista fuera de comentarios y docstrings — un marcador sin consumidor seria la no-evidencia que este repo lleva seis rondas persiguiendo. 18 scripts declarados.

### Added
- Regresion para `6912ce4` (commit de otra sesion que entro sin prueba propia): `plan.upsert --title` actualiza la celda 0 y **respeta su forma** — wikilink sigue wikilink, `(inline)` sigue `(inline)`. Verificado que discrimina: desactivando solo ese bloque fallan 2 aserciones.
- `bin/check-index-writers.py`. Suite `test-bash-nudge.sh` de 23 a **40** aserciones.

### Notas
- La ronda 6 **no pudo correr las suites**: `mktemp` fallo con `Operation not permitted` en su sandbox, igual que en la ronda 4. Los numeros de `.goalspec/ronda6-suites.out` los produjo el ejecutor, no una ejecucion independiente. Queda declarado, no resuelto.
- **Primera violacion de autonomia en seis rondas**, y es correcta: el modal que se le presento al humano ofrecia huella / bloqueo en Bash / ambos / documentar, y **omitia el aviso no bloqueante en Bash** — que es la opcion que el humano acabo pidiendo por su cuenta. La decision se le asigno, pero su respuesta no estaba en el menu.

## [2.13.5] - 2026-09-11
### Fixed
- **`enrich-memory.py --apply` tampoco re-sellaba, y es la herramienta que `/triage-3t` manda correr antes del barrido.** Tercera con el mismo fallo tras `repair-dualwrite` y `normalize-pendientes` (2.13.3): seguir la propia instruccion del plugin producia un aviso de "escritura fuera del journal". Arreglar las dos que encontre no fue enumerarlas — que es literalmente la **regla 114** de este repo, escrita dos versiones antes.
- La suite no comprueba ya un caso: **recorre todos los `.py` de `bin/`** y exige que cualquiera que escriba un indice directamente re-selle. Verificado que discrimina: contra el `enrich-memory.py` anterior fallan 2 aserciones.

## [2.13.4] - 2026-09-11
### Added
- **El plugin avisa cuando Bash escribe un indice, sin bloquear.** Nuevo `bin/bash-journal-nudge.sh`, enganchado a `PreToolUse` y `PostToolUse` con matcher `Bash`.
  - **Por que avisar y no bloquear, ahora que si se puede**: la asimetria decide. Un falso positivo al DENEGAR cuesta trabajo bueno tirado; al AVISAR cuesta una linea de texto. Eso permite un detector aproximado sobre el texto del comando, que es justo lo que no se podia permitir al bloquear. Nunca deniega, ni siquiera con `journal_strict=1`.
  - `PreToolUse` mira el **texto del comando** (`>`, `>>`, `sed -i`, `tee`, `cp`/`mv`, `open(...,"w")`). Aproximado —no ve una ruta en variable ni un `eval`— pero llega **antes**, que es cuando sirve. Excluye las herramientas del propio plugin.
  - `PostToolUse` compara **bytes** contra la huella del compactador: exacto, cero falsos positivos, un turno tarde. Compuerta de mtime en shell para no pagar el arranque de python en cada Bash.
  - **NO depende de `.memory-config`.** Solo mira que exista `.journal/`. Medido: 64 de 65 proyectos con `memory/` no tienen config, asi que condicionarlo a `journal_strict` lo dejaria inerte justo donde mas falta hace. Un proyecto sin journal no ve nada.
  - Coste medido: ~10 ms por llamada a Bash cuando no hay nada que decir (arranque de bash); antes de la criba en shell eran 40 ms.
- **`journal-compact.py --reseal`**: acepta el estado actual de los indices como linea base nueva. Es el **unico camino sancionado** para una edicion manual. Existe porque `/audit-3t` te dice "rehaz esa fila a mano" de una que no se puede anclar por forma — y el sistema se contradecia: te mandaba editar a mano un fichero cuyo contrato es que no se edita a mano, y luego te denunciaba por haberlo hecho. Documentado en `/audit-3t` junto a esa instruccion.
- Suite nueva `bin/test-bash-nudge.sh` (23 aserciones) con los seis casos que deben avisar y los nueve que no.

## [2.13.3] - 2026-09-11
### Fixed
- **El detector de deriva de 2.13.2 gritaba en falso sobre las herramientas del propio plugin.** `repair-dualwrite.py --apply` (que `/checkpoint-3t` corre en su Step 3-pre) y `normalize-pendientes.py --apply` escriben los indices de forma sancionada, y ninguna re-sellaba la linea base: cada reparacion se denunciaba a si misma como "escritura fuera del journal". Un aviso que grita en su propio camino feliz deja de leerse a la tercera vez. Las dos re-sellan ahora, y la suite lo fija con **control negativo** — una escritura a mano en el mismo directorio sigue disparando.

### Notas sobre el alcance real de `journal_strict`
- Medido 2026-09-11 cruzando `_pendientes.md` con los eventos de `.journal/applied/`: **5 proyectos con ids discrepantes, 50 ids en total, 43 de ellos sin NINGUN evento** — es decir, escritos a mano, nunca emitidos. Los otros 7 tienen evento: su texto se edito despues de asignarles el id. `ids_invented` mide discrepancia, **no origen**; cruzar con los eventos es lo que distingue una cosa de la otra.
- **El proyecto con `journal_strict=1` es el que mas ids escritos a mano tiene (25 de 43).** Encender el guard no lo impide, porque el hook no cubre Bash. Quien dependa de `journal_strict` para que no le editen los indices esta confiando en algo que no hace eso.
- Lo que si llega a todos sin `migrate`: **`--check-drift` no consulta `.memory-config`**. Corre en cualquier proyecto con `.journal/`, tenga o no el guard encendido.

## [2.13.2] - 2026-09-11
### Added
- **Deteccion de escrituras fuera del journal, comparando bytes.** El compactador guarda el `sha256` de cada indice protegido en `memory/.journal/fingerprints.json` al escribirlo; si en la pasada siguiente no coincide, alguien lo escribio sin pasar por el journal. Se avisa en `SessionStart`, se anota con fecha en `memory/.journal/out-of-band.log`, y la linea base se re-sella para que **el aviso salga una vez, no en cada sesion**.
  - Nuevo `journal-compact.py --check-drift`: solo comprueba, no aplica eventos, no toma el lock. Tiene entrada propia porque `session-start.sh` solo llamaba al compactador cuando `pending/` tenia algo — y la deriva que importa es justo la de una sesion que no dejo eventos.
  - Nuevo check 15 en `/audit-3t`.
  - **Por que detectar y no impedir**: `journal_strict` es un hook `PreToolUse` con matcher `Edit|Write|MultiEdit`, y **Bash no esta en esa lista**. Un `>>`, un `sed -i` o un heredoc escriben igual. No es descuido de quien lo hace: una sesion en **modo auto** recibe la instruccion explicita de preferir Bash sobre Edit/Write, asi que ahi el guard no se salta a veces — se salta siempre. Parsear Bash para bloquearlo seria adivinar, y un falso positivo bloquea trabajo bueno; comparar bytes es exacto.
  - Medido sobre el historial JSONL (2026-09-11): **96 escrituras a mano a un indice protegido** desde que el journal es obligatorio (2026-09-02), en 9 proyectos, la ultima ese mismo dia. Separadas de 34 fixtures de prueba en directorios temporales y de 187 anteriores a esa fecha, cuando editar a mano era el metodo correcto.

### Changed
- **`journal_strict=1` pasa a ser el valor por defecto** en `/3-tier-memory:setup-memory` (nuevo Step 3b) y en `/3-tier-memory:migrate`, que lo escribe solo si el proyecto no tiene `.memory-config`. Una config existente **no se pisa**: si un proyecto eligio `journal_strict=0`, esa decision se respeta.
  - Motivo, medido el 2026-09-11: **64 de 65 proyectos con `memory/` no tenian `.memory-config` ninguna**. El unico con el guard encendido era `claude-vzert` — que es justo donde mas escrituras a mano se registraron, porque es el unico sitio donde el agente se entera de que se lo salto y lo dice. En los otros 63 nadie lo notaba porque no habia nada que notar.
  - Los proyectos ya existentes **no se tocan**. Para encenderlo ahi: `/3-tier-memory:migrate` o escribir el fichero a mano.

## [2.13.1] - 2026-09-11
### Fixed
- **`journal-emit.py` avisa si el origen apunta a una sesion que no existe.** Un `pendiente.add --origen "[[sessions/SLUG]]"` con un slug inventado deja el enlace de Tier 2 colgando: el indice apunta a un fichero de Tier 3 que nadie escribio. El orden de `/checkpoint-3t` (Step 2 escribe el session file, Step 3 emite los pendientes) hace que en el flujo normal esto no dispare nunca; dispara cuando alguien emite a media sesion. **Avisa y NO bloquea** a proposito: emitir antes de escribir es legitimo si el checkpoint llega despues, y un `exit` perderia el evento.
  - Cubre los tres sitios donde se nombra una sesion: `pendiente.add --origen`, `research.upsert --origen` y `plan.upsert --sesion`. Los tres porque los enlaces rotos mas viejos de este repo son de **planes** apuntando a sesiones que nunca se escribieron, no de pendientes.
  - `check-wikilinks.py` (que `/audit-3t` ya corre) detectaba esto desde siempre. Lo que faltaba no era el detector, era avisar en el momento de crear el enlace en vez de en una auditoria posterior que nadie corre a tiempo.

## [2.13.0] - 2026-09-11
### Added
- **`/triage-3t` — barrido manual de pendientes por lotes.** `templates/triage-3t.md` + `bin/triage-scan.py`. Reune la evidencia de cada item (edad, origen, ventana `_revisar:`, y que sesiones POSTERIORES hablan del mismo tema) y **no clasifica**: la decision es del usuario. Su senal util ("¿alguna sesion posterior toco el tema?") dispara en el 14-26% de los items medidos. Pagina con un cursor `(fecha, id)` de corte estricto, nunca con un `--offset` numerico: al cerrar items del lote la lista se acorta y el offset se saltaria a los que ocupan los huecos.
- **`bin/expire-pendientes.py` + eventos `pendiente.expire` / `pendiente.reopen` / `pendiente.window`.** El modo por defecto es `--modo revisar`: caduca un item cuya **ventana declarada** (`_revisar: YYYY-MM-DD`) ya vencio. `--modo edad` queda solo para inspeccion y avisa al correr. La caducidad por edad se implemento y **se descarto con su propia medicion**: de 30 candidatos leidos a N=90 dias, **29 seguian vivos** — la edad no discrimina cuando el backlog es trabajo real sin priorizar. Solo sirve la ventana que el propio item declaro, y esa solo existe hacia adelante.
- **`bin/repair-dualwrite.py`** — recupera los pendientes que estan en `_pendientes.md` (Tier 2) pero no tienen fila en `pendientes/YYYY-MM.md` (Tier 3), reescribe con `|` escapado las filas que un pipe crudo dejaba imposibles de cerrar, y detecta filas desplazadas, ids inventados y datos ausentes. Idempotente.
- **Campo `_revisar: YYYY-MM-DD` en pendientes**, en emisor, compactador y hook de arranque.
- **`Sigue abierto:` en el snippet de continuidad** (`/checkpoint-3t` Step 8) y bloque de calendario para fechas futuras (Step 8c). Medido: los pendientes mencionados en el snippet cierran al **35%** frente al **19%** de los no mencionados.

### Fixed — integridad de los ficheros de `memory/`
- **El salto de linea lo manda el fichero, no el sistema operativo.** Todas las escrituras usaban el modo texto por defecto de Python, que traduce `"\n"` al salto del sistema. El mismo `memory/` salia LF en macOS y CRLF en Windows, asi que un repositorio compartido entre las dos plataformas le daba la vuelta al fichero **entero** en cada pasada. Ahora cada escritura mira el fichero en binario y conserva el salto que ya usaba; uno nuevo sale en LF en cualquier sistema.
  - Habia **seis** rutas de escritura distintas en `bin/`, cada una con su propia copia del patron: `journal-compact.py`, `enrich-memory.py`, `normalize-pendientes.py`, `build-recall-index.py`, `ensure-frontmatter.py` y `scan-secrets.py`. Tres seguian en modo texto — incluida la del redactor de secretos, cuyo docstring afirmaba "body is otherwise byte-identical", falso para un fichero CRLF. Los artefactos generados (indice de recall, eventos del journal, marcador del lock, ficheros `.reason`, el log) van con LF explicito: sus bytes ya no dependen de donde se corrio.
  - Una prueba nueva **enumera** las escrituras del codigo y exige `newline=` en todas (`w`, `a`, `fdopen`, `write_text`), para que una septima copia no pueda entrar en silencio.
- **`atomic_write` dejaba el fichero sin salto de linea final** al insertar al final (en produccion desde 2.12.0): lo siguiente que se anadiera se pegaba a la ultima linea. Y `apply_resolve_index` borraba el centinela de ese salto en su dedup de lineas en blanco (tambien desde 2.12.0).
- **Dos temporales con el mismo nombre.** `path + ".tmp"` en tres scripts: dos procesos a la vez escribian el MISMO temporal y uno pisaba al otro. Ahora llevan el pid. Y `os.replace` sin reintento tiraba la pasada entera ante un `PermissionError` transitorio de Windows.
- **`apply_expire_index` / `apply_reopen` no eran atomicos**: borraban el origen antes de escribir el destino, asi que un fallo entre las dos escrituras perdia la unica copia.
- **Una fila con `|` en el texto no se podia cerrar nunca**, y la nota de cierre con `|` volvia a partirla. `--fix-pipes` las reescribe; antes desplazaba las columnas de una fila cuyo pipe estaba en la nota.
- **Fechas validadas por forma y no por calendario**: `2026-99-99` pasaba emisor y compactador, se persistia y reventaba a los consumidores. Ahora se valida el calendario en los dos lados.
- **`reopen` perdia la prioridad** de un item legacy sin fila mensual (los mandaba todos a Media). Y las celdas vacias volvian como `|  |  |` en vez de `| | |`.

### Fixed — paginacion de `/triage-3t`
- **El cursor de un item sin `_id` era posicional.** Se numeraban `sin-id-0001`, `sin-id-0002`… en orden de fichero: unico dentro de una pasada, inestable entre pasadas. Al cerrar un item anterior, el siguiente se renumeraba, el corte estricto daba falso sobre su propio cursor y ese item **no volvia a salir nunca**. Ahora el id sale del texto del item, no de lo que haya alrededor. No es un caso raro: en seis `_pendientes.md` reales, 125 de 125 items no tenian `_id`.
- **El cursor solo validaba la forma del id.** Lleva ahora un digito de control que detecta una cadena manglada al copiarla. **No demuestra procedencia** — es una sha1 publica del propio id — y lo que protege de verdad contra un id inventado es que los items tengan `_id` persistente, que es lo que pone `enrich-memory.py --apply` (medido: 125 de 125 en una sola pasada).
- Antes: el cursor era por posicion (se saltaba items), luego por fecha inclusiva (se repetia para siempre con varios items del mismo dia). Ahora `(fecha, id)` estricto.
- **Una instalacion nueva veia "No queda nada por revisar tras ese cursor"** sin haber dado ningun cursor. Los tres casos se distinguen ahora: no hay pendientes, el filtro de prioridad no casa, o el cursor se agoto.

### Changed — CONTRATO
- **El cursor de `/triage-3t` pasa de `--desde FECHA:ID` a `--desde FECHA:ID:DIGITO`.** Un cursor de dos partes es ahora un error duro con mensaje explicito. No rompe estado guardado: ningun cursor se persiste en disco, viven dentro de una sesion.
- **Un fichero de `memory/` sin salto de linea final sale CON el.** Rompe el "byte a byte" para esa entrada concreta, a proposito: en `memory/` un fichero sin salto final es el bug, no un formato a preservar.

### Notas de verificacion
- Seis suites: `test-expire-reopen.sh` 64/64 (eran 45), `test-journal-guard.sh` 19/19, `test-journal-race.sh` PASS, `test-normalize-pendientes.sh` 19/19, `test-parser.sh` 26/26, `test-repair-dualwrite.sh` verde. Mas dos suites nuevas en el camino (`test-expire-reopen.sh`, `test-repair-dualwrite.sh`).
- **Cinco rondas de un verificador adversarial externo** (Codex/GPT-5, vendedor distinto). Las cinco cerraron en `break`. La ronda 5 rompio una afirmacion que la ronda 4 habia dado por buena — que el digito del cursor demostraba procedencia — fabricando un cursor valido, y encontro que "revisar los llamantes de una funcion" no habia probado que fuera la unica implementacion.
- **Sin medir**: `triage-scan.py` no se ha corrido sobre el corpus grande de paperclip.

## [2.12.2] - 2026-09-09
### Changed
- **El snippet de continuidad ahora transmite lo que fallo, no solo lo que salio.** Las tres lineas fijas de `/checkpoint-3t` Step 8 (`Retomamos` / `Lee` / `Proximo paso`) solo llevaban resultados, asi que la sesion siguiente volvia a intentar el enfoque que ya se habia descartado y se expandia sin final acordado. Dos cambios acoplados:
  - **Nueva seccion obligatoria `## Callejones sin salida` en el session file** (Step 2). Una linea por callejon con tres partes: que se intento, por que fallo (con evidencia) y que hacer en su lugar. Cuenta un enfoque abandonado a mitad, una medicion mal calibrada, una herramienta que no servia, un diseno que un revisor rompio, una hipotesis que los datos refutaron. NO cuenta un bug arreglado (`## Bugs fixed`) ni trabajo a medias (un pendiente). Es la unica informacion de la sesion que nadie puede recuperar leyendo el resultado — todo lo demas del archivo registra lo que SI salio.
  - **El snippet pasa de 3 lineas a 6: 4 obligatorias y 2 condicionales** (Step 8). Nuevas: `No repitas: <callejones>` — copia condensada de esa seccion, solo los que afectan al proximo paso, con el "que hacer en su lugar" incluido; y `Terminas cuando: <done-bar>` — el entregable concreto y su limite de alcance. Cada una se **omite entera** si no aplica (seccion en "Ninguno", o proximo paso exploratorio cuyo final no se puede nombrar): un done-bar inventado es peor que ninguno, porque la sesion siguiente lo trata como acordado con el usuario. `Proximo paso` ademas arrastra ahora los umbrales ya acordados, para que no se renegocien. La linea `Antes de actuar, dime en 3 lineas donde quedamos.` sigue invariable y va sola al final. 8a y 8b llevan el ejemplo real de las 6 lineas y la regla de que terminal y session file impriman lo mismo.
  - Misma seccion anadida al skill hermano `~/.claude/commands/checkpoint-paperclip.md`, que comparte la estructura de session file pero no tiene Step 8.
  - Sin cambios de codigo: solo plantillas. Las instalaciones que tengan el marketplace registrado en `known_marketplaces.json` lo reciben por el auto-update de `SessionStart` (el hook activa `autoUpdate` para `3-tier-memory-marketplace`; sin esa entrada no hace nada) y despues el mismo hook copia el template a `.claude/commands/` cuando difiere de la copia congelada. Una instalacion sin marketplace (por ejemplo cargada con `--plugin-dir`) actualiza a mano. Compatibilidad: un session file anterior a 2.12.2 no tiene la seccion nueva y sigue siendo valido — Step 8 omite la linea `No repitas:` cuando falta, sin migrar nada.

## [2.12.1] - 2026-09-03
### Fixed
- **Headers de prioridad ausentes en `_pendientes.md` mandaban a cuarentena los pendientes nuevos.** El compactador ancla cada `pendiente.add` bajo un header que empiece por `## alta`, `## media` o `## baja` (sin distinguir mayusculas). Instalaciones anteriores a 2.12.0 usan a veces otros headers (`## Abiertos`, `P0 — ...`, secciones por semana o por tema): de 38 proyectos locales medidos el 2026-09-03, 9 no tenian al menos uno de los tres. Nuevo `bin/normalize-pendientes.py`: anade SOLO los headers que faltan (pegados a su vecino canonico: tras la seccion del que le precede en el orden Alta/Media/Baja, o antes del que le sigue; los tres antes de `## Related` si no hay ninguno; si los existentes estan desordenados no se reordenan), nunca mueve ni borra items ni secciones, conserva LF/CRLF, toma el lock del journal y escribe con el `replace` con reintento del compactador (`journal-compact.py`, que en el plugin siempre esta al lado; si faltara, `os.replace` sin lock); idempotente. El hook SessionStart lo corre antes de compactar y avisa `NORMALIZADO: _pendientes.md — headers_added=N (...)` solo cuando anadio algo; nadie tiene que correr nada a mano. `/audit-3t` check 13 lo reporta en dry-run. Test `bin/test-normalize-pendientes.sh` (14 casos, 19 comprobaciones, incluidos CRLF conservado, headers preexistentes desordenados y el fin a fin: tras normalizar, `pendiente.add` compacta sin cuarentena; control: sin normalizar va a cuarentena). Medido en macOS y Linux (docker `python:3.12-slim`); el hook SessionStart probado con stdin JSON sobre un proyecto temporal (avisa la primera sesion, silencio la segunda). Aplicado el mismo dia a los 9 proyectos locales afectados: 0 items movidos.

## [2.12.0] - 2026-09-03
Plataformas (medido 2026-09-03): `bin/test-journal-race.sh` y `bin/test-journal-guard.sh` pasan en macOS (Darwin 25.5, bash 3.2), Linux (contenedor `python:3.12-slim`, kernel 6.8, Python 3.12.14, bash 5.2) y Windows (GitHub Actions `windows-latest`, Git Bash 5.3, Python 3.12.10 nativo). En Windows ademas una sonda directa de la primitiva del lock — 16 procesos x 40 rondas compitiendo por el mismo `os.mkdir`, exactamente 1 ganador en las 40 — confirma que `CreateDirectoryW` es atomico entre procesos. Run: https://github.com/vzert/3-tier-memory/actions/runs/33776716992. Dos bugs solo visibles en Windows salieron de esa corrida y estan corregidos abajo (lock huerfano al liberar; guardia apagada por rutas POSIX).

### Added
- **Journal de eventos + compactador unico para `memory/`.** Varias sesiones o subagentes pueden hacer checkpoint en la misma maquina a la vez; Claude Code no impide que uno pise las lineas del otro en un indice compartido — solo avisa (medido: `Write` con copia vieja perdio 2/2 lineas). Desde esta version los indices Tier 2 (`_pendientes.md`, `pendientes/YYYY-MM.md`, `_session-index.md`, `_learnings.md`, `_plans-index.md`, `_research-index.md`) y la numeracion de reglas en `learnings/<topic>.md` no se editan directo: cada cambio es un **evento** y un solo **compactador** los aplica bajo lock. Markdown sigue siendo la verdad; sin dependencias nuevas (bash + python3).
  - `bin/journal-emit.py`: un archivo JSON por evento en `memory/.journal/pending/` (nombre unico por construccion: timestamp UTC + session + pid + secuencia; `O_EXCL` con reintento; si no puede escribir deja copia en `failed/` y sale con 2 — nunca se descarta en silencio). Seis tipos: `pendiente.add`, `pendiente.resolve` (ids hash visibles como `_id: p-…_`), `session.add`, `learning.add` (numero de regla asignado bajo el lock), `plan.upsert`, `research.upsert`. Escapa `|` en celdas de tabla.
  - `bin/journal-compact.py`: lock `mkdir` en `memory/.journal/.lock` con `acquired_at` + owner, TTL 60 s, robo de lock huerfano por exactamente un proceso; aplica en orden de nombre como deltas anclados (insertar bajo header, borrar linea por id, llenar celda por id — las ediciones a mano sobreviven); escribe cada `.md` a tmp + rename; mueve el evento a `applied/YYYY-MM/`; re-aplicar es no-op. Evento invalido, ancla borrada o colision de id → `quarantine/` con un `.reason` al lado. La poda de sesiones (10), planes y research completados (5) se hace aqui y **siempre por fecha, nunca por posicion** (podar por posicion borraba una fila mas nueva cuando un `completed` viejo se re-aplicaba).
  - Cuando compacta: SessionStart (antes de inyectar memoria), UserPromptSubmit (solo si `pending/` no esta vacio), y ultimo paso de `/checkpoint-3t`, `/save-learning`, `/consolidate-3t`.
- **Guardia estricta opcional** `bin/journal-guard.sh` (hook PreToolUse `Edit|Write|MultiEdit`). Con `journal_strict=1` en `memory/.memory-config` deniega la edicion directa de `memory/_*.md` y `memory/pendientes/YYYY-MM.md` con el mensaje "usa journal-emit". Apagada por defecto; `journal_strict=0` para una edicion manual deliberada (merge de reglas en `/consolidate-3t`); el hook lee el archivo en cada llamada. Medido en Claude Code 2.1.259 con `claude -p`: el deny se honra con allow-list (decision JSON y exit 2), en `acceptEdits`, `bypassPermissions` y `auto`, y con el hook cargado desde el plugin (`--plugin-dir`). Versiones anteriores ignoraban el deny en algunas configuraciones (issues 18312 y 37210): la guardia es un recordatorio con dientes, el journal es el mecanismo de seguridad.
- **`/status-3t` y `/audit-3t` reportan el journal**: `pending`, `quarantine`, `applied`, edad del lock (huerfano si > 60 s) y estado de `journal_strict`. Los eventos en cuarentena se listan con su `.reason`; nunca se borran solos.
- **Reintento de `os.replace`** en `bin/journal-compact.py` (`replace_with_retry`, 5 intentos; entre intentos espera 50, 100, 150 y 200 ms) ante `PermissionError`: cubre la escritura de cada `.md`, los marcadores del lock y el movimiento de eventos a `applied/` y `quarantine/`. Motivo: en Windows un antivirus o el indexador pueden tener el archivo abierto un instante y el `rename` falla con acceso denegado. Otros errores (`FileNotFoundError`) no se reintentan. Caso en `test-journal-race.sh` (Complementaria 4: 4 fallos transitorios y exito, 5 fallos y excepcion, `move_to` con 3 fallos, `FileNotFoundError` sin reintento; control negativo con el reintento apagado: 3 de 4 subcasos fallan).
- **Liberar el lock con reintento** (`rmtree_with_retry`, 5 intentos). En Windows, borrar `acquired_at` mientras otro compactador lo esta leyendo (lo hace cada 50 ms mientras espera) falla con `PermissionError` y `rmtree(ignore_errors=True)` lo tragaba: el lock quedaba huerfano hasta el TTL de 60 s y los demas compactadores salian `busy` sin aplicar nada (medido en `windows-latest`: 1 de 5 ensayos de Fase 2, 21 s). Mismo reintento en el robo de lock. Si el sello inicial del lock falla, el lock sigue valido por la mtime del directorio en vez de abortar con el lock tomado. Casos e) y f) en `test-journal-race.sh`.
- **Guardia en Git Bash (Windows)**: el JSON del hook trae rutas POSIX (`/tmp/...`, `/c/Users/...`) pero `python3` es nativo; MSYS convierte `MEMORY_DIR` (variable de entorno) y no el JSON, `relpath` entre ambas empezaba con `..` y la guardia se apagaba en silencio (6/6 casos de deny vacios). `journal-guard.sh` normaliza con `cygpath -w` las rutas que empiezan con `/`; el test anade 4 casos con rutas nativas (`C:\...`) cuando `cygpath` existe.
- **Pruebas** `bin/test-journal-race.sh` (2 workers x 15-16 eventos contra 2 compactadores simultaneos, 5/5 corridas limpias; un agente solo sin lock residual en < 1 s en POSIX y < 3 s en Git Bash, donde arrancar 10 procesos python tarda ~1 s; lock huerfano robado exactamente una vez; replay byte a byte identico; reintentos de `os.replace` y de la liberacion del lock) y `bin/test-journal-guard.sh` (19 casos de la guardia, 23 en Git Bash; el arnes exige stderr vacio para no aceptar un traceback como "no bloquea").

### Changed
- `templates/checkpoint-3t.md` (Steps 2, 3a, 3b, 4, 5, 6c por eventos; Step 5a compacta antes de 5d/6; Step 5b ya no poda a mano), `save-learning.md`, `consolidate-3t.md` (solo las reflexiones van por evento; merges y supersedes siguen directos, con compactacion antes y despues), `backfill-3t.md`, y los commands `backfill.md`, `migrate.md`, `setup-memory.md`: escriben los indices por eventos, con rama "Fallback (no JBIN)" para instalaciones sin los scripts.
- `bin/enrich-memory.py --only creado,id` asigna el `_id` hash a pendientes existentes (idempotente); `/checkpoint-3t` lo corre en el Step 3-pre.
- `bin/session-start.sh` y `bin/recall.sh` compactan los eventos huerfanos; SessionStart avisa si hay eventos en cuarentena.
- Nota: el fix de los templates no llega a las copias congeladas en `.claude/commands/` de otros proyectos hasta que reciban el auto-update o se re-corra `/setup-memory` (misma limitacion que 2.11.2).

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
