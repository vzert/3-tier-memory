#!/usr/bin/env python3
"""
3-tier-memory plugin: migra por NOMBRE de columna las tablas de memory/_research-index.md que
usan un formato anterior a 2.31.5, hacia la forma canonica de `TABLE_COLUMNS` en journal-compact.py
(`## Active Research`: Tema|Next step|Origen|Archivo; `## Completed Research`: Tema|Resultado|
Archivo). p-cd33654290, continuacion de 2.31.5 (research.upsert ya no pisa filas ajenas, pero deja
en SOLO LECTURA cualquier tabla anclada cuya ultima columna no se llame Archivo ni File —
`research_table_is_canonical` en journal-compact.py — asi que un research nuevo en esas 5
instalaciones medidas (omniroute, scalar-api-docs, seedance-generator, time-tracker, unifi-expert)
va a cuarentena en vez de escribirse).

Por que por NOMBRE y no por FORMA (a diferencia de repair-plans-index.py, que ancla la fila legacy
por su ANCHO + una fecha en la celda 0): medidas las 5 instalaciones, hay 10 formas de cabecera
DISTINTAS (2 tablas x 5 instalaciones) y el mismo ancho no significa lo mismo en dos de ellas —
un `Topic|Result|File|Fecha` (omniroute) y un `Topic|Completed|File|Conclusion` (scalar-api-docs)
tienen las dos 4 celdas, pero la fecha vive en la celda 3 en una y en la celda 1 en la otra. Anclar
por posicion ahi adivina; anclar por el NOMBRE de cada columna no.

Como reconoce si una tabla YA es canonica (y no hay nada que reparar): el nombre Y el orden EXACTOS
de sus columnas tienen que coincidir con `TABLE_COLUMNS[header]` — NO basta con que la ULTIMA
columna se llame Archivo/File (`jc.research_table_is_canonical`, la puerta lenient que usa
`apply_research_upsert` en produccion para decidir si escribe por posicion). Una cabecera como
`Topic|Started|Sesion|File` pasa esa puerta lenient — ya escribe hoy por posicion en produccion, MAL
— y una version anterior de este script la reportaba sana (todos los contadores en cero) sin
tocarla, heredando el hueco en vez de cerrarlo (ronda 2 de adversario, subagente en Opus, 2.31.6,
reproducido sobre copia de una instalacion real: un hallazgo curado se PISO en la escritura
siguiente). Ahora esa forma se reconoce como legacy, igual que cualquier otra, y se migra al orden
canonico real.

Como reconoce una cabecera QUE NO es exactamente canonica: cada celda se pasa por `ROLE_ALIAS`
(colkey -> rol: tema/archivo/resultado/next_step/origen/fecha/extra). La cabecera se RECONOCE solo
si (a) TODOS los nombres tienen rol conocido y (b) hay EXACTAMENTE una columna con rol tema y
EXACTAMENTE una con rol archivo. Cualquier nombre no listado en `ROLE_ALIAS`, o una cabecera con
cero o mas de una columna tema/archivo, se reporta `header_unrecognized` y no se toca — mismo
criterio de "no adivinar" que `header_shape` en repair-plans-index.py, generalizado con un
diccionario en vez de una sola tupla (mismo patron que `_COL_ALIAS` para los mensuales de
pendientes en journal-compact.py, con su propio vocabulario: research usa Slug/Topic/Conclusion/Key
Finding, que no significan lo mismo alli). `ROLE_ALIAS` no cubre todos los nombres que existen en
el disco del usuario (medido: al menos 9 mas, en otras instalaciones no incluidas en la medicion
original de 5) — eso es seguro (esas tablas se quedan tal como estaban, de solo lectura) pero
incompleto; ampliar la cobertura es trabajo de seguimiento, no bloquea esta version.

Como migra una fila reconocida (por rol, nunca por posicion fija):
  - tema -> celda 0 del destino, tal cual.
  - resultado (o next_step/origen en Active) -> su celda PROPIA en el destino, tal cual. Esta celda
    SI queda sujeta al mismo ciclo de vida que ya tiene en una fila nativa de 2.12.0: un evento
    `research.upsert` legitimo que trae `--resultado`/`--next-step`/`--origen` la REEMPLAZA por
    completo, y eso no es una perdida introducida por la migracion — es lo que ese campo esta hecho
    para hacer, migrado o no (medido: ~49 filas en 13 instalaciones tienen su prosa curada
    justo en esta celda, bajo un nombre legacy que SI mapea a un rol canonico como "Key Findings" o
    "Conclusion" — reemplazarla con un `--resultado` nuevo es la semantica correcta del campo, no
    un defecto de este script; ronda 4 de adversario, subagente en Opus, 2.31.6).
  - archivo -> celda final. El enlace original se conserva intacto AL INICIO; cualquier columna
    SIN rol canonico (rol `extra` o `fecha` — la que NO tiene celda propia en el esquema, a
    diferencia de la de arriba) se ANEXA como texto DESPUES del enlace — ` — <NombreOriginal>:
    <valor>` — nunca se descarta, PRECISAMENTE porque esas columnas no tienen otro destino: no hay
    "su propia celda" a la que puedan ir. Por que al Archivo y NO a Resultado/Origen (que serian el
    destino "obvio" por significado si tuvieran que compartir celda con el rol principal): esas dos
    son justo las celdas que `apply_research_upsert` REEMPLAZA por completo cuando un evento normal
    trae `next_step`/`origen`/`resultado` — anexar ahi datos SIN relacion con lo que el evento
    actualiza trasladaba el riesgo de perdida de un evento cualquiera a un evento que use esa
    columna en particular (ronda 3 de adversario externo, 2.31.6: reproducido con un
    `research.upsert --origen` real sobre una fila recien migrada — el Origen migrado, con el
    Started/Sesion originales anexados, se borro entero). Archivo es la UNICA celda que
    `apply_research_upsert` nunca reescribe por posicion — solo la lee, anclado al INICIO
    (`RESEARCH_OPEN_RE.match`), para encontrar la fila — asi que texto anexado despues del enlace
    sobrevive a cualquier UPDATE futuro mientras la fila se quede en su tabla actual (verificado:
    `--next-step`/`--origen` en Active, `--resultado` en Completed). NO sobrevive al UNICO evento
    de maduracion (Active -> Completed): `apply_research_upsert` borra esa fila entera y construye
    la nueva desde cero con solo lo que trae el evento — pero esto ya le pasaba a una nota escrita
    A MANO en esas mismas celdas antes de que este script existiera
    (verificado sobre una fila 100% nativa de 2.12.0), asi que no es un hueco que esta migracion
    abra, es una caracteristica de `apply_research_upsert` fuera de su alcance (ronda 4 de
    adversario externo, 2.31.6). Un valor de columna que por casualidad TENGA la forma exacta de
    la marca se neutraliza antes de anexarse (`_defuse_completado`), para que la UNICA marca que
    este metodo se niega a escribir ahi — `_completado: <fecha>_` — no se cuele por accidente:
    anexarla de verdad vuelve podable (`COMPLETADO_RE`/`MAX_RESEARCH_DONE`) a una fila que antes no
    competia en la poda, y el PRIMER `research.upsert --status completed` normal que llega despues
    borra el excedente sobre 5 sin aviso — medido en una instalacion real: 10 filas historicas sin
    marca, cero borradas; tras
    migrar y un solo evento normal, 6 borradas (ronda 2 de adversario, subagente en Opus, 2.31.6).
    Ninguna fila migrada por este script gana poda por un valor que ESTE metodo haya escrito o
    plegado — todo lo que este metodo AGREGA se neutraliza primero. La UNICA excepcion es una marca
    GENUINA que ya vivia en el Archivo ORIGINAL de una tabla que antes de migrar era de solo
    lectura (ultima columna != Archivo/File): la poda nunca escaneaba esa tabla, sin importar lo
    que hubiera en cualquier celda, y tras migrar SI la escanea — la marca vieja participa en la
    poda por primera vez, no porque este script la haya escrito, sino porque el header ahora
    refleja lo que esa celda siempre decia. No hay forma de distinguir aqui una marca genuina
    (alguien la puso a proposito) de una coincidencia (el texto por casualidad tiene esa forma):
    `_defuse_completado` NUNCA toca el Archivo original, a proposito, porque el caso O exige
    preservar una marca legitima — la misma razon por la que esta ambigüedad no se resuelve por
    codigo. Medido: cero de las instalaciones reales tienen hoy esta forma (una tabla de solo
    lectura con un Archivo que ya trae `_completado:`); es un caso construido, no observado (ronda
    5 de adversario, subagente en Opus, 2.31.6). Fuera de esa unica excepcion documentada, ninguna
    fila migrada gana poda que no tenia, ni pierde nada a la siguiente escritura normal que no
    tenia antes.

Que NO hace:
  - no toca una tabla cuya cabecera YA es EXACTAMENTE canonica (nombre y orden, arriba) — pero SI
    revisa el ancho de sus filas: una fila que no coincide con el ancho canonico bajo una cabecera
    que YA dice ser canonica se reporta `unrepairable`, igual que en cualquier otra forma (nunca se
    adivina por que le sobran o faltan celdas).
  - no toca una tabla con cabecera no reconocida (arriba). No inventa una tabla si `## Active
    Research`/`## Completed Research` no existe del todo (eso es `need_table`, y solo corre dentro
    de journal-compact.py al aplicar un evento real): se reporta `no_active_table`/
    `no_completed_table` y no se hace nada mas ahi.
  - no migra una fila cuyo ancho no coincide con el de SU PROPIA cabecera (una tabla markdown
    siempre alinea filas y cabecera al mismo ancho; un ancho distinto es un `|` crudo sin escapar
    partiendo la fila): se reporta `unrepairable`.
  - no fusiona dos filas: si migrar una fila produciria un Tema (`plain()`) que YA existe en otra
    fila migrada de la MISMA tabla, se reporta `possible_duplicate`.
  - si una tabla tiene ALGUNA fila `unrepairable` o `possible_duplicate` Y su cabecera NO es
    lenient-canonica hoy (`jc.research_table_is_canonical`: su ultima columna no se llama Archivo
    ni File) — o sea, esta genuinamente en cuarentena — no migra NINGUNA fila de esa tabla ni
    reescribe su cabecera: todo o nada. Reescribir la cabecera dejando una fila sin migrar le
    quitaria a ESA fila una proteccion que SI tenia, y un `research.upsert` futuro sobre ella no la
    encontraria (su ultima celda no es el enlace) — le escribiria una fila nueva al lado,
    duplicando en silencio (hallazgo de la primera ronda de adversario externo, 2.31.6).
  - si esa MISMA tabla YA es lenient-canonica hoy (su ultima columna YA se llama Archivo/File,
    aunque el resto no este en orden — la forma que reconoce como legacy por nombre, ver arriba),
    el todo-o-nada NO aplica: esa tabla ya se escribe por posicion en produccion hoy, con o sin
    esta migracion, asi que no tocar nada NO protege a la fila sin migrar (nunca hubo cuarentena
    que perder) — solo deja tambien sin arreglar a las filas que SI calificaban. Se migra lo que se
    puede y se reescribe la cabecera; la fila sin migrar queda exactamente tan expuesta como ya
    estaba, nunca mas (hallazgo de la quinta ronda de adversario, subagente en Opus, 2.31.6:
    reproducido sobre copia de una instalacion real donde el todo-o-nada de la primera version
    bloqueaba TODA la tabla — incluidas las filas que si calificaban — dejando la cabecera lenient
    intacta y el hallazgo curado seguia perdiendose en la siguiente escritura normal).
  - no poda, no borra, no crea la marca `<!-- Sin research activo -->`. Migrar deja las filas
    listas para que `apply_research_upsert` las trate como canonicas la PROXIMA vez que un evento
    las toque — la poda por fecha sigue siendo su trabajo, no el de este script, y ninguna fila
    gana poda por un valor que ESTE metodo haya escrito (ver "archivo" arriba para la unica
    excepcion documentada: una marca genuina ya existente en un Archivo que antes de migrar era de
    solo lectura).

Toma el lock del journal (memory/.journal/.lock) igual que repair-plans-index.py, para no pisar a
un compactador concurrente. Si no lo consigue, no hace nada. Lo adquiere ANTES de leer el archivo
(no despues, como quedo en la primera version): leer y adquirir en el otro orden deja una ventana
donde un compactador concurrente escribe entre las dos lineas y esta corrida sobreescribe esa
escritura con su copia en memoria ya vieja.

Uso: repair-research-index.py MEMORY_DIR [--apply] [--quiet] [--budget SEG]
  Sin --apply solo informa (dry-run). Salida (una linea):
  `active_header_rewritten=si|no active_rows_migrated=N active_unrepairable=N
  active_possible_duplicates=N completed_header_rewritten=si|no completed_rows_migrated=N
  completed_unrepairable=N completed_possible_duplicates=N no_active_table=0|1
  no_completed_table=0|1 active_header_unrecognized=0|1 completed_header_unrecognized=0|1`.
  Codigos: 0 ok (o lock ocupado, o sin _research-index.md en un proyecto sin memoria todavia —
  fail-open, igual que repair-plans-index.py); 1 solo si _research-index.md existe pero no se pudo
  leer.

Pruebas: test-repair-research-index.sh.
"""
# sella-huellas: si
import argparse
import importlib.util
import os
import re
import sys
import unicodedata

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

HEADERS = ["## Active Research", "## Completed Research"]


def load_compactor(bin_dir):
    """Modulo journal-compact.py del directorio vecino; None si no esta (copia suelta)."""
    path = os.path.join(bin_dir, "journal-compact.py")
    if not os.path.isfile(path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("jc", path)
        jc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(jc)
        return jc
    except Exception:
        return None


def _colkey(cell):
    """Nombre de columna comparable: minusculas, sin tildes, espacios colapsados. Copia deliberada
    de journal-compact._colkey (no importada): esa funcion vive en la seccion de mensuales de
    pendientes, con su propio diccionario de alias (`_COL_ALIAS`); aqui el vocabulario es de
    research (Slug/Topic/Conclusion/Key Finding) y no vale la pena acoplar los dos formatos a una
    sola funcion — mismo criterio que ya documenta repair-plans-index.py para su propia copia."""
    t = unicodedata.normalize("NFD", (cell or "").strip().lower())
    t = "".join(c for c in t if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", t).strip()


# Rol de cada nombre de columna medido en las 5 instalaciones (omniroute, scalar-api-docs,
# seedance-generator, time-tracker, unifi-expert) mas las variantes obvias en ingles/espanol de
# los propios nombres canonicos. Un nombre que no aparece aqui deja la cabecera sin reconocer
# (`header_unrecognized`) en vez de adivinarle un rol — mismo criterio de "reportar, no adivinar"
# que `header_shape` en repair-plans-index.py.
ROLE_ALIAS = {
    "tema": "tema", "topic": "tema",
    "archivo": "archivo", "file": "archivo", "slug": "archivo",
    "resultado": "resultado", "result": "resultado",
    "conclusion": "resultado", "conclusiones": "resultado",
    "key finding": "resultado", "key findings": "resultado",
    "findings": "resultado", "hallazgo": "resultado", "hallazgos": "resultado",
    "next step": "next_step", "siguiente paso": "next_step", "proximo paso": "next_step",
    "origen": "origen", "source": "origen",
    "completed": "fecha", "fecha": "fecha", "completado": "fecha", "date": "fecha",
    "sesion": "extra", "session": "extra", "sesion resolucion": "extra",
    "status": "extra", "estado": "extra", "started": "extra",
}


def classify_header(header_line):
    """[roles] por columna, en el orden en disco, o None si algun nombre no esta en ROLE_ALIAS."""
    roles = [ROLE_ALIAS.get(_colkey(c)) for c in header_line]
    if any(r is None for r in roles):
        return None
    return roles


def header_recognized(roles):
    """Una cabecera solo se reconoce con EXACTAMENTE una columna tema y una archivo — cero o mas
    de una de cualquiera de las dos admite mas de una lectura y no se adivina."""
    return roles is not None and roles.count("tema") == 1 and roles.count("archivo") == 1


def _defuse_completado(jc, text):
    """Rompe cualquier subcadena con la FORMA literal de la marca `_completado: <fecha>_` dentro de
    un valor de columna. `apply_research_upsert` en journal-compact.py busca esa marca en la FILA
    COMPLETA (`COMPLETADO_RE.search(lines[i])`), no solo en el Archivo — asi que un dato de usuario
    que por casualidad contenga ese texto exacto (una nota de Key Findings que DESCRIBE la marca en
    prosa, por ejemplo) vuelve podable una fila migrada aunque la marca nunca la haya escrito este
    script (ronda 5 de adversario, subagente en Opus, 2.31.6: reproducido con Key Findings
    conteniendo "...la fila vieja decia _completado: 2026-01-0N_ en su dia" — 6 de 10 filas
    historicas borradas tras un solo evento). Se aplica a TODO valor nuevo que este metodo escribe
    (Tema, Resultado/Next step/Origen, y cada parte anexada a Archivo) — nunca al Archivo ORIGINAL
    antes de anexarle nada, que es el unico lugar donde una marca real y legitima puede vivir de
    antes y no se debe tocar.

    Quita el guion bajo INICIAL en vez de meter un espacio (ronda 6 de adversario, subagente en
    Opus, 2.31.6): `COMPLETADO_RE` exige ese guion bajo justo antes de "completado:", asi que
    quitarlo ya rompe el match. La primera version metia un espacio (`_completado :`), y eso
    corrompia la comparacion de identidad de una fila `(inline)` (sin wikilink): `find_research_row`
    cae a comparar `plain(Tema)` contra el Tema del evento para encontrarla, y `plain()` (en
    journal-compact.py) SI quita `_`/`*`/backtick pero NO un espacio de mas — con el espacio, el
    Tema defusado ya no hacia `plain()`-match contra el Tema original del evento, `apply_research_
    upsert` no encontraba la fila migrada y le insertaba una fila NUEVA al lado: duplicando en
    silencio, justo lo que el todo-o-nada de la primera ronda existe para impedir, reintroducido
    por otra puerta. Quitar el guion bajo es neutro para `plain()` (que de todos modos lo iba a
    quitar) y sigue rompiendo el match de `COMPLETADO_RE` igual de bien.

    Retrocede sobre TODOS los guiones bajos contiguos antes del match, no solo el que el propio
    match consumio (ronda 7 de adversario externo, 2.31.6): un valor con guiones bajos apilados
    (`__completado: 2020-01-01__`) hace que `COMPLETADO_RE` matchee empezando en el SEGUNDO guion
    bajo — quitar solo ese deja el PRIMERO todavia pegado a "completado:", reconstruyendo la marca
    (`"__completado:...".replace("_completado:", "completado:")` da `"_completado:..."`, que sigue
    matcheando). Repite hasta que no quede ningun match, para el caso (mas raro aun) de que el
    texto tenga mas de una ocurrencia de la forma."""
    result = text
    while True:
        m = jc.COMPLETADO_RE.search(result)
        if not m:
            return result
        start = m.start()
        while start > 0 and result[start - 1] == "_":
            start -= 1
        result = result[:start] + "completado: " + m.group(1) + "_" + result[m.end():]


def fold_extra(jc, base, extra_parts):
    """Anexa partes de texto (ya formateadas `Nombre: valor`) a una celda base (el Archivo, con su
    enlace al inicio intacto), sin perder ninguna y sin celda propia que el esquema canonico no
    tiene. Mismo patron que repair-plans-index.py anexando Resumen a Status, aplicado a la UNICA
    celda que sobrevive a una escritura posicional futura (ver `migrate_row`)."""
    extra_parts = [_defuse_completado(jc, p) for p in extra_parts if p]
    if not extra_parts:
        return base
    suffix = "; ".join(extra_parts)
    return f"{base} — {suffix}" if base else suffix


def migrate_row(jc, cells, roles, header, header_cells, plain_of):
    """Fila destino (list[str]) para '## Active Research'/'## Completed Research', o None si el
    Tema resultante ya esta en `plain_of` (posible duplicado dentro de la MISMA tabla — el llamante
    decide si lo reporta).

    Una columna sin celda propia en el esquema canonico (rol `extra` o `fecha`) se anexa como texto
    al FINAL del Archivo, nunca a Origen/Resultado. La primera version de este metodo anexaba a
    Origen/Resultado — la celda mas parecida por significado — y eso VUELVE A ABRIR el mismo hueco
    que la migracion vino a cerrar: `apply_research_upsert` en journal-compact.py REEMPLAZA esa
    celda entera con el valor del evento cuando el evento trae `next_step`/`origen` (Active, idx 1
    y 2) o `resultado` (Completed, idx 1) — un `research.upsert` normal y corriente que solo quiere
    actualizar el Origen de un research BORRA en el mismo golpe el Started/Sesion que la migracion
    habia preservado ahi (ronda 3 de adversario externo, 2.31.6: reproducido ejecutando
    `apply_research_upsert` de verdad con un evento `--origen` sobre una fila recien migrada).
    Archivo (la ULTIMA celda) es la unica que `apply_research_upsert` NUNCA reescribe por posicion
    — solo la LEE para encontrar la fila (`RESEARCH_OPEN_RE.match`, anclado al INICIO de la celda,
    nunca al final) — asi que texto anexado DESPUES del enlace sobrevive a cualquier UPDATE futuro
    (Active con `--next-step`/`--origen`, Completed con `--resultado`, verificado ejecutando
    `apply_research_upsert` de verdad contra los dos caminos). La unica marca que este metodo se
    niega a escribir ahi es `_completado:` — y cualquier valor de columna que por casualidad TENGA
    esa forma exacta se neutraliza antes de anexarse (`_defuse_completado`, ronda 4 de adversario
    externo, 2.31.6: la exclusion estaba declarada pero no implementada para texto anexado).

    Limite CONOCIDO y PRE-EXISTENTE, no introducido por este script: cuando un research MADURA de
    Active a Completed, `apply_research_upsert` BORRA la fila de Active entera y construye la de
    Completed desde cero con solo lo que trae el evento (`tema`/`resultado`/`slug`) — nunca copia
    Next step, Origen NI Archivo de la fila vieja. Esto ya le pasaba a una nota escrita A MANO en
    esas celdas antes de que este script existiera (verificado: una fila 100% nativa de 2.12.0,
    sin tocar por esta migracion, pierde su Next step/Origen igual al madurar) — no es un hueco que
    esta migracion abra, es una caracteristica de `apply_research_upsert` que esta fuera de su
    alcance (ronda 4 de adversario externo, 2.31.6). El texto que este metodo anexa a Archivo
    sobrevive a TODO update mientras el research se quede en su tabla actual; no sobrevive al UNICO
    evento de maduracion, exactamente como tampoco sobrevivia antes de que existiera este script."""
    tema_i = roles.index("tema")
    archivo_i = roles.index("archivo")
    tema = _defuse_completado(jc, cells[tema_i])
    archivo = cells[archivo_i]   # el Archivo ORIGINAL nunca se defusa: puede llevar una marca real

    extras = []
    if header == "## Active Research":
        next_step = ""
        origen = ""
        for i, rol in enumerate(roles):
            if i in (tema_i, archivo_i):
                continue
            val = cells[i].strip()
            if rol == "next_step" and not next_step:
                next_step = val
            elif rol == "origen" and not origen:
                origen = val
            elif val:
                extras.append(f"{header_cells[i].strip() or 'Dato'}: {val}")
        next_step = _defuse_completado(jc, next_step)
        origen = _defuse_completado(jc, origen)
        archivo = fold_extra(jc, archivo, extras)
        new_cells = [tema, next_step, origen, archivo]
    else:
        resultado = ""
        for i, rol in enumerate(roles):
            if i in (tema_i, archivo_i):
                continue
            val = cells[i].strip()
            if rol == "resultado" and not resultado:
                resultado = val
            elif val:
                extras.append(f"{header_cells[i].strip() or 'Dato'}: {val}")
        resultado = _defuse_completado(jc, resultado)
        archivo = fold_extra(jc, archivo, extras)
        new_cells = [tema, resultado, archivo]

    tp = jc.plain(tema)
    if tp in plain_of:
        return None, tp, False, False
    defused = any("_completado:" in cells[i] for i in range(len(cells)) if i != archivo_i)
    # El Archivo ORIGINAL (antes de fold_extra) puede YA traer algo con forma de marca — nunca se
    # toca (puede ser legitima, ver el docstring), pero si la tabla estaba en cuarentena antes de
    # migrar, esa marca nunca competia en la poda y ahora SI la escanea: el llamante lo reporta,
    # no en silencio (ronda 5 de adversario, subagente en Opus, 2.31.6: "documentar la ambiguedad
    # es correcto; no reportarla cuando ocurre es lo que queda abierto").
    archivo_ya_marcada = bool(jc.COMPLETADO_RE.search(cells[archivo_i]))
    return new_cells, tp, defused, archivo_ya_marcada


def repair_table(jc, lines, header):
    """(nuevas_filas: {indice: cells}, migradas: [(indice, tema, defused, archivo_ya_marcada)],
    no_reparables: [(indice, n)], duplicados: [(indice, tema)], header_rewritten: bool,
    no_table: bool, header_unrecognized: bool, hdr_i, sep_i) — NO escribe; el llamante decide con
    --apply.
    `defused` es True si algun valor de la fila original tenia la forma literal de la marca
    `_completado:` y `_defuse_completado` la neutralizo al copiarla — el llamante lo anuncia,
    porque neutralizar cambia un caracter del texto legacy sin que se vea en el resumen (ronda 4
    de adversario, subagente en Opus, 2.31.6: "un humano que compare antes/despues ve un caracter
    que nadie le anuncio").
    `archivo_ya_marcada` es True si el Archivo ORIGINAL de la fila ya traia una marca real (no
    neutralizada, a proposito) Y la tabla estaba en cuarentena antes de migrar — esa marca nunca
    competia en la poda y desde ahora SI, no porque este script la haya escrito sino porque el
    header ahora la hace visible. Se anuncia por la misma razon que `defused`: un cambio de
    comportamiento silencioso es peor que uno anunciado (ronda 5 de adversario, subagente en Opus,
    2.31.6: "documentar la ambiguedad es correcto; no reportarla cuando ocurre es lo que queda
    abierto")."""
    sec = jc.section_bounds(lines, header)
    if not sec:
        return {}, [], [], [], False, True, False, None, None
    tab = jc.table_in(lines, *sec)
    if not tab:
        return {}, [], [], [], False, True, False, None, None
    hdr_i, sep_i, row_idxs = tab
    header_cells = jc.split_cells(lines[hdr_i])

    # "Ya canonica" exige el nombre Y el orden EXACTOS de TABLE_COLUMNS — no basta con que la
    # ULTIMA columna se llame Archivo/File (`jc.research_table_is_canonical`, que solo mira esa
    # celda y es la puerta que usa `apply_research_upsert` en produccion para decidir si escribe
    # por posicion). Una cabecera como `Topic|Started|Sesion|File` pasa esa puerta lenient — ya
    # escribe hoy por posicion en produccion, mal — y esta funcion la reportaba `header_rewritten=
    # no` con TODOS los contadores en cero, indistinguible de sana: ni la arreglaba ni avisaba
    # (ronda 2 de adversario, subagente en Opus, 2.31.6, reproducido sobre copia de una instalacion
    # real: un hallazgo curado se PISO en la siguiente escritura). Ahora esa forma se reconoce como
    # legacy (por nombre, como cualquier otra) y se migra al orden canonico real, cerrando el hueco
    # en vez de heredarlo.
    canon_keys = [_colkey(c) for c in jc.TABLE_COLUMNS[header]]
    if [_colkey(c) for c in header_cells] == canon_keys:
        # Ya es exactamente la forma canonica: nada que reparar en la cabecera. Las filas SI se
        # revisan por su ancho (una fila que no coincide con `len(canon_keys)` bajo una cabecera
        # que YA dice ser canonica es la misma clase de riesgo que `unrepairable` en cualquier otra
        # forma — se reporta, no se toca, nunca se adivina por que le sobran o faltan celdas).
        no_reparables = [(i, len(jc.split_cells(lines[i])))
                         for i in row_idxs if len(jc.split_cells(lines[i])) != len(canon_keys)]
        return {}, [], no_reparables, [], False, False, False, hdr_i, sep_i

    roles = classify_header(header_cells)
    if not header_recognized(roles):
        return {}, [], [], [], False, False, True, hdr_i, sep_i

    # Si la tabla YA estaba en cuarentena (no lenient-canonica) antes de migrar, la poda nunca la
    # escaneaba — sin importar lo que hubiera en cualquier celda. Tras migrar SI la escanea: una
    # marca genuina que ya vivia en el Archivo original participa en la poda por primera vez, y eso
    # se reporta, no en silencio (ver `migrate_row`, `archivo_ya_marcada`).
    estaba_en_cuarentena = not jc.research_table_is_canonical(lines[hdr_i])

    candidatas = {}
    migradas, no_reparables, duplicados = [], [], []
    plain_of = set()
    for i in row_idxs:
        cells = jc.split_cells(lines[i])
        if len(cells) != len(roles):
            no_reparables.append((i, len(cells)))
            continue
        new_cells, tp, defused, archivo_ya_marcada = migrate_row(
            jc, cells, roles, header, header_cells, plain_of)
        if new_cells is None:
            duplicados.append((i, cells[roles.index("tema")]))
            continue
        plain_of.add(tp)
        candidatas[i] = new_cells
        migradas.append((i, cells[roles.index("tema")], defused,
                          archivo_ya_marcada and estaba_en_cuarentena))

    if no_reparables or duplicados:
        # Todo o nada, PERO solo cuando bloquear preserva una proteccion que hoy existe. Si la
        # cabecera YA es lenient-canonica (`jc.research_table_is_canonical`: su ULTIMA columna ya
        # se llama Archivo/File, aunque el resto no este en orden), la tabla YA se escribe por
        # posicion en produccion hoy — con o sin este script. No tocar nada no protege a las filas
        # sin migrar (nunca estuvieron protegidas: nunca hubo cuarentena que perder) y solo deja
        # tambien sin arreglar a las filas que SI calificaban. Reproducido sobre copia de una
        # instalacion real (ronda 5 de adversario, subagente en Opus, 2.31.6): dos rondas de
        # correccion antes de esta bloqueaban por completo `goal-spec-skill` (2 de 3 filas Active
        # sin migrar por ancho) dejando la cabecera en `Topic|Started|Sesion|File` — que sigue
        # pasando la puerta lenient de journal-compact.py — y el hallazgo curado se seguia
        # perdiendo en la siguiente escritura. Aqui SI se migra lo que se puede y se reescribe la
        # cabecera; las filas sin migrar quedan exactamente tan expuestas como ya estaban, nunca
        # mas.
        #
        # Si la cabecera NO es lenient-canonica (tabla genuinamente en cuarentena hoy), el
        # criterio original sigue aplicando integro: no tocar nada preserva esa cuarentena para las
        # filas sin migrar. `research_row_is_canonical` en journal-compact.py decide por la
        # cabecera de la TABLA, no por la forma de cada fila: reescribirla dejando una fila sin
        # migrar le quitaria a ESA fila una proteccion que si tenia, y un `research.upsert` futuro
        # sobre ella no la encontraria (su ultima celda no es el enlace) — le escribiria una fila
        # nueva al lado, duplicando en silencio (ronda 1 de adversario externo, 2.31.6).
        if not jc.research_table_is_canonical(lines[hdr_i]):
            return {}, [], no_reparables, duplicados, False, False, False, hdr_i, sep_i
        return candidatas, migradas, no_reparables, duplicados, True, False, False, hdr_i, sep_i

    return candidatas, migradas, [], [], True, False, False, hdr_i, sep_i


def apply_changes(jc, lines, header, hdr_i, nuevas_filas):
    for i, cells in nuevas_filas.items():
        lines[i] = jc.join_cells(cells)
    cols = jc.TABLE_COLUMNS[header]
    sep_i = hdr_i + 1
    lines[hdr_i] = "| " + " | ".join(cols) + " |"
    lines[sep_i] = "|" + "|".join("---" for _ in cols) + "|"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--budget", type=float, default=2.0)
    a = ap.parse_args()

    mem = os.path.abspath(a.memory_dir)
    idx = os.path.join(mem, "_research-index.md")

    def campos(vals, sufijo=""):
        (ah, am, au, ad, ch, cm, cu, cd, na, nc, au_h, cu_h) = vals
        print(f"active_header_rewritten={'si' if ah else 'no'} active_rows_migrated={am} "
              f"active_unrepairable={au} active_possible_duplicates={ad} "
              f"completed_header_rewritten={'si' if ch else 'no'} completed_rows_migrated={cm} "
              f"completed_unrepairable={cu} completed_possible_duplicates={cd} "
              f"no_active_table={1 if na else 0} no_completed_table={1 if nc else 0} "
              f"active_header_unrecognized={1 if au_h else 0} "
              f"completed_header_unrecognized={1 if cu_h else 0}{sufijo}")

    if not os.path.isfile(idx):
        if not a.quiet:
            campos((False, 0, 0, 0, False, 0, 0, 0, 0, 0, 0, 0), " (sin _research-index.md)")
        return 0

    jc = load_compactor(os.path.dirname(os.path.abspath(__file__)))
    if jc is None:
        print("repair-research-index: falta journal-compact.py en el mismo bin/", file=sys.stderr)
        return 0

    # El lock se adquiere ANTES de leer, cuando se va a escribir: leer primero y adquirir despues
    # deja una ventana donde un compactador concurrente puede escribir el archivo entre las dos
    # lineas, y esta corrida terminaria sobreescribiendolo con su copia en memoria ya vieja
    # (ronda 1 de adversario externo, 2.31.6). En dry-run no hay escritura que proteger, asi que se
    # lee sin lock, igual que antes.
    lock = None
    if a.apply:
        lock = jc.Lock(os.path.join(mem, ".journal"), a.budget)
        if not lock.acquire():
            if not a.quiet:
                campos((False, 0, 0, 0, False, 0, 0, 0, 0, 0, 0, 0), " (busy)")
            return 0
    try:
        try:
            lines = jc.read_lines(idx)
        except Exception as exc:
            print(f"repair-research-index: no se pudo leer {idx}: {exc}", file=sys.stderr)
            return 1

        results = {}
        for header in HEADERS:
            results[header] = repair_table(jc, lines, header)

        (a_nuevas, a_migradas, a_norep, a_dup, a_hdr, a_notab, a_unrec, a_hi, _) = results[HEADERS[0]]
        (c_nuevas, c_migradas, c_norep, c_dup, c_hdr, c_notab, c_unrec, c_hi, _) = results[HEADERS[1]]

        cambios = bool(a_nuevas) or a_hdr or bool(c_nuevas) or c_hdr

        if not a.quiet:
            sufijo = "" if a.apply or not cambios else " [dry-run: usa --apply]"
            campos((a_hdr, len(a_migradas), len(a_norep), len(a_dup),
                    c_hdr, len(c_migradas), len(c_norep), len(c_dup),
                    a_notab, c_notab, a_unrec, c_unrec), sufijo)
            for header, (migradas, norep, dup, hdr_rw) in (
                    (HEADERS[0], (a_migradas, a_norep, a_dup, a_hdr)),
                    (HEADERS[1], (c_migradas, c_norep, c_dup, c_hdr))):
                for i, tema, defused, archivo_ya_marcada in migradas:
                    verbo = "migrada" if a.apply else "se migraria"
                    print(f"  {verbo} fila de '{header}' linea {i + 1} ({tema}) a la forma canonica.")
                    if defused:
                        print(f"    AVISO: un valor de esta fila tenia la forma literal de "
                              f"'_completado: <fecha>_' y se neutralizo (se le quito el guion "
                              f"bajo inicial) para que no se cuele como marca real.")
                    if archivo_ya_marcada:
                        print(f"    AVISO: el Archivo de esta fila YA tenia una marca "
                              f"'_completado:' antes de migrar, en una tabla que hasta ahora era "
                              f"de solo lectura (la poda nunca la escaneaba) — desde que esta "
                              f"cabecera es canonica, esa marca SI compite en la poda por primera "
                              f"vez. Si no es una marca real, quitala a mano.")
                # Si la cabecera SI se reescribe pese a haber filas sin migrar, esta tabla ya era
                # lenient-canonica (escribible por posicion hoy, con o sin este script) — esas
                # filas quedan exactamente tan expuestas como ya estaban, no mas ni menos. Si la
                # cabecera NO se reescribe, la tabla esta protegida hoy (cuarentena) y este GRAVE
                # es lo unico que la bloquea entera.
                sufijo_grave = (" (esta tabla YA se escribe por posicion en produccion hoy, con o "
                                 "sin esta migracion — esta fila sigue exactamente tan expuesta "
                                 "como ya estaba)") if hdr_rw else (" — el resto de la tabla no se "
                                 "toca hasta que esta fila se repare a mano")
                for i, n in norep:
                    print(f"  GRAVE '{header}' linea {i + 1}: {n} celdas, no coincide con el ancho "
                          f"de su propia cabecera — no se toca. Revisala a mano.{sufijo_grave}")
                for i, tema in dup:
                    print(f"  AVISO '{header}' linea {i + 1} ({tema}) migraria a un Tema que YA "
                          f"tiene otra fila migrada en esta misma tabla — no se migra, para no "
                          f"fusionar dos filas sin que alguien las compare. Unificalas a mano."
                          f"{sufijo_grave}")
            if a_unrec:
                print("  AVISO la cabecera de '## Active Research' no se reconoce (algun nombre de "
                      "columna no esta en ROLE_ALIAS, o falta/sobra Tema o Archivo) — no se toca.")
            if c_unrec:
                print("  AVISO la cabecera de '## Completed Research' no se reconoce (algun nombre "
                      "de columna no esta en ROLE_ALIAS, o falta/sobra Tema o Archivo) — no se toca.")
            if a_notab:
                print("  AVISO no hay tabla bajo '## Active Research' en este archivo — nada que "
                      "reparar aqui (la ancla la crea journal-compact.py al aplicar un evento real).")
            if c_notab:
                print("  AVISO no hay tabla bajo '## Completed Research' en este archivo — nada "
                      "que reparar aqui.")

        if a.apply and cambios:
            # `nuevas_filas` solo sale poblado junto con header_rewritten=True (repair_table
            # siempre marca las dos juntas): no hay caso de filas migradas bajo una cabecera que
            # no se reescribe.
            if a_hdr:
                apply_changes(jc, lines, HEADERS[0], a_hi, a_nuevas)
            if c_hdr:
                apply_changes(jc, lines, HEADERS[1], c_hi, c_nuevas)
            jc.bump_updated(lines)
            jc.atomic_write(idx, lines)
            try:
                jc.guardar_huellas(mem, os.path.join(mem, ".journal"), escritos=[idx])
            except AttributeError:
                pass   # compactador anterior a 2.13.2: no tiene huellas que sellar
        return 0
    finally:
        if lock is not None:
            lock.release()


if __name__ == "__main__":
    sys.exit(main())
