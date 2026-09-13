#!/usr/bin/env python3
"""
3-tier-memory plugin: repara el dual-write roto de pendientes (v2.12.3).

Cada pendiente vive en DOS sitios: la linea de `_pendientes.md` (Tier 2, la lista abierta) y
la fila de `pendientes/YYYY-MM.md` (Tier 3, el historial). El compactador del journal escribe
las dos a la vez. Una linea escrita a mano en Tier 2 no genera la fila de Tier 3, y el fallo
es silencioso hasta que se cierra el pendiente: `apply_resolve_monthly` no encuentra la fila,
deja un WARN, y se pierden la fecha de resolucion y la sesion que lo cerro.

Medido el 2026-09-10 en una instalacion real: 49 de 118 pendientes abiertos (42%) sin fila en Tier 3;
ninguno tenia evento propio en `.journal/applied/`, o sea que los 49 se escribieron a mano.
(Desde 2.23.0 `applied/` no se versiona, asi que esa comprobacion solo vale EN LA MAQUINA que
aplico los eventos: en un clon recien traido `applied/` esta vacio y toda fila pareceria
escrita a mano. No lo usa ningun camino de codigo de aqui — es como se midio, no como se
repara — pero quien quiera repetir la medida tiene que hacerlo donde se genero.)
La mayoria es anterior al despliegue del journal (2026-09-03), pero 14 son posteriores: la
fuga seguia abierta con el journal ya en marcha, porque nada impedia escribir Tier 2 a mano.
(La corrida real escribio 51 filas: esos 49 mas 2 pendientes que otra sesion anadio a mano
mientras se reparaba — la fuga en directo.)

Hay una SEGUNDA perdida del mismo historial, independiente de la anterior: una fila cuyo
texto lleva un `|` (`sort | uniq -c`) se parte en mas de 7 celdas, `apply_resolve_monthly`
lee la prioridad ("Alta") como fecha de resolucion, concluye "ya resuelto" y no escribe nada
— y el compactador reporta `applied=1` sin dejar ni un WARN. Ese pendiente no se puede cerrar
nunca. El arreglo va en journal-compact.py (usar `split_cells`, que ya existia, en vez de
`split("|")`, y escapar con `escape_cell` al escribir); aqui esta `--fix-pipes`, que reescribe
las filas ya guardadas con el `|` crudo.

Que hace: por cada id de Tier 2 sin fila en ningun mensual, escribe la fila que le
corresponde en `pendientes/<creado[:7]>.md`, con el MISMO formato que
`journal-compact.apply_add_monthly` — texto, prioridad, creado y origen tomados de la linea
de Tier 2, `Resuelto` y `Sesion resolucion` en blanco. No inventa datos: un pendiente sin
`_creado:` o sin `_id:` no se repara, se reporta.

Que hace ademas (2.22.0): ADOPTA los pendientes abiertos que viven fuera de los tres headers de
prioridad. Un `_pendientes.md` anterior a 2.12.0 se organiza por otra cosa (`## Abiertos`,
`P0 — ...`, por semana o por tema), y esas lineas no tienen prioridad que leer: hasta 2.21.4 no
recibian fila de Tier 3 NUNCA y cada checkpoint las reportaba `NO REPARABLE`, con lo que el agente
se lo contaba a la persona como un dual-write roto. No estaba roto — el archivo es anterior al
mecanismo. Se mueve la linea verbatim al final de la seccion de su prioridad (Media, o Alta si su
texto o su seccion marcan urgencia; `URGENTE_RE`), creando el header con la misma politica que el
compactador. Cada movimiento se imprime con su motivo. Un `- [x]` ya cerrado no se mueve.

Que NO hace:
  - de `_pendientes.md` solo mueve esas lineas huerfanas, y solo con `--apply`: no reescribe su
    texto, no cambia su id, no borra ni reordena ningun otro item, y no toca ninguna otra seccion (la
    de origen se queda donde estaba, aunque quede vacia; su espaciado se colapsa a una linea en
    blanco si el hueco dejaba dos). Todo lo demas de Tier 2 se lee, no se
    escribe. Por eso esto vive aqui y no en el hook SessionStart: mover datos del usuario solo es
    aceptable en el camino que acaba en un commit de git, que es /checkpoint-3t Step 3-pre;
  - no recalcula ids. El id de un pendiente emitido por journal es sha1(texto+creado+origen),
    pero una linea escrita a mano puede llevar un id inventado (31 de 118 en lo medido).
    Recalcularlos obligaria a reescribir las citas de ese id en los session logs, que son
    registro historico. El id vale por ser estable, no por ser reproducible, asi que se
    conserva tal cual. Reemitir ese mismo texto por journal generaria el id canonico y una
    fila duplicada; lo que cierra ese riesgo es no volver a escribir Tier 2 a mano
    (`journal_strict=1` en `memory/.memory-config`).
  - no borra ni reordena filas, y nunca cambia una celda ya escrita. Agrega al final de la
    tabla del mes. La UNICA excepcion es `--fix-pipes`, que si reescribe filas existentes:
    escapa su `|` para devolverlas a 7 celdas, sin tocar el contenido.

Idempotente: una segunda corrida no encuentra nada que reparar y no escribe.

La prioridad sale del header `## Alta|Media|Baja ...` bajo el que vive la linea, que es el
mismo criterio que usa `journal-compact.header_index` para insertarla. Una linea fuera de los tres
headers se adopta (ver arriba) en vez de quedarse sin fila para siempre.

Un pendiente sin `_origen:` SI recibe fila, con `—` en la columna `Origen`: no hubo sesion que lo
emitiera porque es anterior al journal, y bloquearlo por eso era condenarlo a perder su fecha de
cierre, que es justo el dano que esta herramienta evita. Lo que si exige origen es comparar el
hash del id, y eso lo hace `ids_invented` aparte.

Toma el lock del journal (`memory/.journal/.lock`) para no pisar a un compactador
concurrente, igual que `normalize-pendientes.py`. Si no lo consigue, no hace nada.

Uso: repair-dualwrite.py MEMORY_DIR [--apply] [--fix-pipes] [--quiet] [--budget SEG]
  Sin --apply solo informa (dry-run): lista los ids con el mes donde iria cada fila y avisa
  de las filas con `|` crudo y de los ids que no son el sha1 de su contenido. Salida:
  `adopted=N rows_added=N pipes_broken=N pipes_fixed=N unaligned_rows=N unrepairable=N
  odd_values=N header_issues=N ids_invented=N missing_data=N`. En dry-run
  `pipes_fixed` es 0 por construccion: lo que hay que leer es `pipes_broken`.
  Codigos: 0 ok (o lock ocupado); 1 error de entorno (sin _pendientes.md o sin journal-compact).

Pruebas: test-repair-dualwrite.sh (cubre las dos perdidas, la idempotencia y el id conservado).
"""
# sella-huellas: si
import argparse
import hashlib
import importlib.util
import os
import re
import sys
import unicodedata

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

PRIOS = (("alta", "Alta"), ("media", "Media"), ("baja", "Baja"))
HEADER_RE = re.compile(r"^##\s+", re.I)
ITEM_RE = re.compile(r"^\s*-\s*\[[ xX]\]\s")
# Sufijos de metadatos al final de la linea. Se buscan por separado y en cualquier orden:
# 6 de 119 lineas medidas en una instalacion real no siguen el orden origen/creado/id.
ID_RE = re.compile(r"_id:\s*(p-[0-9a-f]{10})_")
CREADO_RE = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
ORIGEN_RE = re.compile(r"_origen:\s*(\[\[[^\]]+\]\])_")
# Tiene que borrar EXACTAMENTE las mismas claves que `journal-emit.strip_meta` (journal-emit.py),
# que es quien las quita antes de hashear: una clave de menos aqui cambia el texto, cambia el
# sha1 y el pendiente sale como `ids_invented` con un aviso falso de fila duplicada. Paso con
# `revisar` (2026-09-11). Si anades una clave alli, anadela aqui.
META_RE = re.compile(r"\s*—\s*_(?:origen|creado|id|revisar):[^—]*")


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


def cell(text):
    """Texto apto para una celda markdown: una linea, `|` suelto escapado (`\\|` se respeta)."""
    t = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"(?<!\\)\|", r"\\|", t)


def parse_tier2(path):
    """[(id, texto, prioridad, creado, origen, [faltas])] de _pendientes.md.

    El texto es la linea sin el `- [ ] ` y sin los sufijos de metadatos, igual que
    `journal-compact.line_text`, para que la celda diga lo mismo que diria el compactador.
    """
    out = []
    prio = None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n").rstrip("\r")
            if HEADER_RE.match(line.strip()):
                low = line.strip().lower()
                prio = next((name for key, name in PRIOS if low.startswith(f"## {key}")), None)
                continue
            if not ITEM_RE.match(line):
                continue
            mid = ID_RE.search(line)
            if not mid:
                continue  # sin id no hay nada que reconciliar: lo pondra el enriquecedor
            pid = mid.group(1)
            body = ITEM_RE.sub("", line, count=1)
            text = re.sub(r"\s+", " ", META_RE.sub("", body)).strip()
            mcre = CREADO_RE.search(line)
            mori = ORIGEN_RE.search(line)
            faltan = []
            if prio is None:
                faltan.append("sin header de prioridad")
            if not mcre:
                faltan.append("sin _creado_")
            # `sin _origen_` NO bloquea la fila: es el estado normal de un pendiente anterior al
            # journal (no hubo sesion que lo emitiera) y la columna `Origen` admite "—". Antes
            # bloqueaba, y el resultado era que esos pendientes no tenian fila de Tier 3 nunca:
            # al cerrarlos se perdian la fecha de cierre y la sesion que los cerro, que es
            # exactamente el dano que esta herramienta existe para evitar. Lo que si necesita
            # origen es el hash del id, y `ids_invented` lo comprueba por separado.
            out.append((pid, text, prio,
                        mcre.group(1) if mcre else None,
                        mori.group(1) if mori else None,
                        faltan))
    return out


# Un pendiente legacy va a Media salvo que su texto (o el header no canonico bajo el que vive)
# diga que corre prisa. La lista es CORTA y conservadora a proposito: equivocarse hacia Media es
# un pendiente que se atiende mas tarde; equivocarse hacia Alta contamina el bloque que el hook
# SessionStart le ensena a la persona en cada arranque. Se imprime cada decision para que se
# pueda auditar de un vistazo.
URGENTE_RE = re.compile(
    r"\b(urgente|urgent|cr[ií]tic[oa]|critical|bloquea|blocker|blocking|asap|p0|"
    r"ca[ií]d[oa]|roto|broken|prod(?:ucci[oó]n)?\s+(?:roto|ca[ií]d[oa]|down))\b", re.I)


def adopt_orphans(jc, mem, apply_):
    """Mueve los pendientes que viven FUERA de los headers de prioridad a uno canonico.

    Un `_pendientes.md` anterior a 2.12.0 organiza sus items por otra cosa (`## Abiertos`,
    `P0 — ...`, por semana o por tema). Esas lineas no tienen prioridad que leer, asi que hasta
    2.21.4 no recibian fila de Tier 3 NUNCA: cada checkpoint las reportaba `NO REPARABLE` y el
    agente lo trasladaba como si alguien hubiera roto el dual-write. No estaba roto: el archivo
    es anterior al mecanismo. Adoptarlas es la migracion que nadie iba a correr a mano.

    Se mueve la linea VERBATIM (id, creado y texto intactos) al final de la seccion de su
    prioridad, creando el header si falta (`journal-compact.ensure_header`, misma politica que el
    compactador y que normalize-pendientes). La seccion de origen se queda donde estaba: solo
    pierde esa linea. Los items que YA viven bajo un header canonico no se tocan.

    Lo unico que cambia ademas de la linea movida es el ESPACIADO donde estaba: si al quitarla
    quedan dos lineas en blanco seguidas, se colapsan a una (igual que `apply_resolve_index`). No es
    contenido, pero no es "nada": sin decirlo, una comparacion byte a byte del fichero desmiente la
    garantia. El salto de linea del fichero (LF o CRLF) se conserva, y un fichero sin salto final
    sale CON el, que es lo que hace `atomic_write` con todo lo que escribe.

    Vive aqui, y no en el hook SessionStart, por una razon: esto MUEVE datos del usuario, y el
    unico camino que lo deja junto a un commit de git —reversible— es /checkpoint-3t Step 3-pre.
    `normalize-pendientes.py` sigue creando solo los headers vacios en cada arranque.

    Devuelve [(pid, prioridad, motivo, se_movio)]; con apply_=False no escribe nada.
    """
    path = os.path.join(mem, "_pendientes.md")
    lines = jc.read_lines(path)
    huerfanos = []           # (indice, linea, pid, destino, motivo)
    header = ""
    for i, line in enumerate(lines):
        if HEADER_RE.match(line.strip()):
            header = line.strip()
            continue
        if not ITEM_RE.match(line):
            continue
        abierto = line.lstrip().startswith("- [ ]")
        mid = ID_RE.search(line)
        if not mid:
            continue         # sin id no hay nada que reconciliar: lo pone el enriquecedor
        low = header.lower()
        if any(low.startswith(f"## {key}") for key, _ in PRIOS):
            continue         # ya tiene ancla
        fuente = URGENTE_RE.search(line) or URGENTE_RE.search(header)
        destino = "alta" if fuente else "media"
        motivo = (f"'{fuente.group(0)}' en {'su texto' if URGENTE_RE.search(line) else 'su seccion'}"
                  if fuente else "sin senal de urgencia")
        if not abierto:
            # Un `- [x]` ya cerrado NO se mueve: la linea desaparece en cuanto el checkpoint emita
            # su `pendiente.resolve`. Pero su fila de Tier 3 si hace falta, y hace falta ANTES de
            # ese cierre: sin ella `apply_resolve_monthly` deja un WARN y se pierden la fecha de
            # cierre y la sesion que lo cerro. La prioridad de un item cerrado ya no decide nada,
            # asi que se registra como Media y se dice.
            destino, motivo = "media", "cerrado fuera de los headers: solo se registra la fila"
        huerfanos.append((i, line, mid.group(1), destino, motivo, abierto))
    salida = [(pid, d.capitalize(), m, ab) for _, _, pid, d, m, ab in huerfanos]
    movibles = [h for h in huerfanos if h[5]]
    if not movibles or not apply_:
        return salida

    # Quitar de atras hacia delante para que los indices previos sigan valiendo.
    for i, *_ in sorted(movibles, reverse=True):
        del lines[i]
        # No dejar dos lineas en blanco seguidas donde estaba la borrada (igual que
        # apply_resolve_index). `len(lines) - 1`: el ultimo elemento es el centinela del salto
        # final, borrarlo dejaria el fichero sin newline.
        if 0 < i < len(lines) - 1 and lines[i].strip() == "" and lines[i - 1].strip() == "":
            del lines[i]
    # Insertar al FINAL de la seccion destino, en el orden original: lo que la persona ya tenia
    # priorizado arriba se queda arriba.
    for destino in ("alta", "media"):
        bloque = [h[1] for h in movibles if h[3] == destino]
        if not bloque:
            continue
        lines, h, _ = jc.ensure_header(lines, destino)
        # Suelo: justo despues del header y de la linea en blanco que lo sigue (el formato que
        # escribe el compactador). Techo: antes de las lineas en blanco que cierran la seccion.
        suelo = h + 1
        if suelo < len(lines) and lines[suelo].strip() == "":
            suelo += 1
        at = jc.section_end(lines, h)
        while at > suelo and lines[at - 1].strip() == "":
            at -= 1
        lines[at:at] = bloque
        # Igual que apply_add_index: no dejar el bloque pegado al header siguiente.
        fin = at + len(bloque)
        if fin < len(lines) and lines[fin].startswith("## "):
            lines.insert(fin, "")
    jc.atomic_write(path, lines)
    return salida


def monthly_files(mem):
    d = os.path.join(mem, "pendientes")
    if not os.path.isdir(d):
        return []
    return [os.path.join(d, fn) for fn in sorted(os.listdir(d))
            if re.match(r"^\d{4}-\d{2}\.md$", fn)]


PRIO_CELL = re.compile(r"^(Alta|Media|Baja)$", re.I)
FECHA_CELL = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def row_cells(jc, line):
    """Celdas de una fila mensual, colapsando el exceso DONDE DE VERDAD ESTA.

    `jc.split_cells` respeta `\\|`, asi que una fila bien escrita sale con sus 7 celdas. Una con
    el `|` CRUDO sale con mas, y el exceso puede estar en DOS sitios: el texto del pendiente
    (celda 1) o la nota de cierre (celda 6, la ultima). Colapsar siempre contra el texto —como
    hacia la primera version— desplaza las columnas de una fila cuyo pipe estaba en la nota, y
    el resultado tiene 7 celdas, asi que ya nadie lo detecta. Paso exactamente eso el
    2026-09-11 con la fila 149 de esa instalacion.

    Se ancla por FORMA, que es verificable: prioridad es Alta|Media|Baja y creado es una fecha,
    siempre en las celdas 2 y 3. Se busca esa pareja; lo que va antes es el texto y lo que va
    despues son origen/resuelto/sesion. Si no aparece, se devuelve la fila tal cual y quien
    llame decide: nunca se adivina.
    """
    cells = jc.split_cells(line)
    if len(cells) <= 7:
        return cells
    for i in range(1, len(cells) - 1):
        if PRIO_CELL.match(cells[i]) and FECHA_CELL.match(cells[i + 1]):
            resto = cells[i:]
            if len(resto) == 5:
                # El exceso estaba entero en el texto: prioridad, creado, origen, resuelto y
                # sesion quedan uno a uno y la fila se reconstruye sin adivinar nada.
                return [cells[0], " | ".join(cells[1:i])] + resto
            if (len(resto) > 5 and i == 2
                    and not any(FECHA_CELL.match(x) for x in cells[6:])):
                # El texto estaba entero y el exceso esta en la nota de cierre, que es la
                # ultima celda: se reune solo ella. La condicion de la fecha distingue este
                # caso del de una fila con una COLUMNA de mas: ahi la fecha de resolucion
                # aparece suelta despues de la celda 5, y reunirla la enterraria en la celda
                # de la sesion. Preservar el texto no basta si la columna deja de significar
                # lo que dice su cabecera.
                return cells[:6] + [" | ".join(cells[6:])]
            # Exceso a los dos lados: no hay forma de saber que celda de la cola es cual.
            # Se devuelve tal cual y quien llama lo reporta sin tocarlo.
            return cells
    return cells


def monthly_table_rows(jc, path):
    """(lines, [(indice, cells7, colmap)]) de cada fila ALINEABLE del mensual, con numero o sin el.

    Antes filtraba por `^\\|\\s*\\d+\\s*\\|`, igual que el compactador, asi que una fila sin la
    columna `#` no existia para este script: concluia "este pendiente de Tier 2 no tiene fila de
    Tier 3" y escribia una numerada al lado. El duplicado lo creaba la reparacion. Medido
    2026-09-11 en una instalacion real: 39 filas sin numero y 11 duplicados ya materializados.
    """
    lines = jc.read_lines(path)
    return lines, jc.monthly_rows(lines)


def existing_ids(jc, mem):
    """Ids que YA tienen fila propia en algun mensual.

    Se busca `_id: X_` solo en la celda de texto, no en el archivo entero: el texto de un
    pendiente puede citar el id de otro (p-2f63bfea40 cita tres), y contarlos inflaria el
    conjunto y dejaria huerfanos sin reparar. Y se busca el ULTIMO `_id:` de esa celda, que es
    el propio: los citados van antes, dentro del texto.
    """
    ids = set()
    for path in monthly_files(mem):
        for _, cells, _cmap in monthly_table_rows(jc, path)[1]:
            ms = ID_RE.findall(cells[jc.COL_TEXT])
            if ms:
                ids.add(ms[-1])
    return ids


def broken_pipe_rows(jc, mem):
    """[(path, idx, linea_nueva)] de filas cuyo texto lleva un `|` crudo.

    Esas filas tienen mas de 7 celdas, asi que `apply_resolve_monthly` lee la prioridad como
    fecha de resolucion, concluye "ya resuelto" y no escribe nada: el pendiente no se puede
    cerrar nunca, en silencio. Reescribirlas con el `|` escapado las devuelve a 7 celdas.
    """
    out, unrep = [], []
    for path in monthly_files(mem):
        lines = jc.read_lines(path)
        for i, line in enumerate(lines):
            s = line.strip()
            if not s.startswith("|") or jc.is_separator(line):
                continue
            if len(jc.split_cells(line)) <= 7:
                continue
            if not re.match(r"^\|\s*\d+\s*\|", s):
                # Fila con `|` crudo y SIN numero: el colapso de `row_cells` asume que la celda 0
                # es el numero, asi que reconstruirla moveria el texto a la columna equivocada.
                # Se reporta y no se toca: adivinar aqui es exactamente lo que este script no hace.
                m = ID_RE.findall(line)
                unrep.append((os.path.basename(path), i + 1, m[-1] if m else "?"))
                continue
            cells = row_cells(jc, line)
            if len(cells) != 7 or not PRIO_CELL.match(cells[2]):
                # No se pudo anclar por forma. NO se toca, pero tampoco se calla: una fila que
                # no cae en ningun contador es justo el fallo que este script existe para
                # cerrar. Va a `unrepairable`.
                m = ID_RE.findall(line)
                unrep.append((os.path.basename(path), i + 1, m[-1] if m else "?"))
                continue
            cells[1] = jc.escape_cell(cells[1])
            cells[6] = jc.escape_cell(cells[6])
            out.append((path, i, jc.join_cells(cells)))
    return out, unrep


def unaligned_rows(jc, mem):
    """Filas de 7 celdas o menos que NO se pueden alinear con las columnas canonicas.

    Devuelve [(fichero, linea, id, medidas)] donde `medidas` dice lo que se midio, no lo que se
    supone: celdas, `|` crudos, `\\|` escapados, y el motivo que dio el alineador. Hasta 2.18.0
    este informe afirmaba UNA causa — "el dato original se perdio al colapsar mal las celdas;
    reconstruyela de un respaldo" — y la senal que lo disparaba (prioridad o fecha no canonicas)
    la produce al menos otra: una fila escrita a mano con un valor no canonico, donde no se
    perdio nada. Caso real, `2026-07.md:111` de una instalacion: `Media→Alta` en la celda de
    prioridad, las 7 celdas en su sitio, 8 `|` crudos y ningun escape. Un colapso mal hecho
    habria dejado `|` crudos DENTRO de una celda, que vuelven a partir la fila: por eso una fila
    colapsada aparece con MAS de 7 celdas (la cuenta `pipes_broken`), no aqui.
    """
    out = []
    for path in monthly_files(mem):
        lines = jc.read_lines(path)
        hmap = jc.header_map(lines)
        for i, line in enumerate(lines):
            t = line.strip()
            if not t.startswith("|") or jc.is_separator(line):
                continue
            celdas = jc.split_cells(line)
            if len(celdas) > 7:
                continue                      # eso es `pipes_broken`, no una fila desalineada
            if [jc._colkey(c) for c in celdas] and all(
                    jc._colkey(c) in jc._COL_ALIAS for c in celdas):
                continue                      # la cabecera
            cells, motivo = jc.align_row(line, hmap)
            if cells is not None:
                continue
            m = ID_RE.findall(line)
            medidas = (f"{len(celdas)} celdas, {t.count('|')} `|` crudos, "
                       f"{t.count(chr(92) + '|')} escapados; {motivo}")
            out.append((os.path.basename(path), i + 1, m[-1] if m else "?", medidas))
    return out


def odd_value_rows(jc, mem):
    """Filas BIEN alineadas cuya `Prioridad` no es Alta, Media ni Baja.

    No falta nada ni se movio nada: es un valor no canonico, casi siempre escrito a mano
    (`Media→Alta`). Se separa de `unaligned_rows` a proposito — las dos cosas daban el mismo
    mensaje y ese mensaje afirmaba una perdida de datos que en este caso no existe.
    """
    out = []
    for path in monthly_files(mem):
        lines = jc.read_lines(path)
        for _i, cells, _cmap in jc.monthly_rows(lines):
            prio = cells[jc.COL_PRIO]
            if prio and not PRIO_CELL.match(prio):
                ms = ID_RE.findall(cells[jc.COL_TEXT])
                out.append((os.path.basename(path), _i + 1, ms[-1] if ms else "?", prio))
    return out


def header_issues(jc, mem):
    """[(fichero, problema)] de los mensuales cuya cabecera no es la canonica de 7 columnas.

    `journal-compact.ensure_monthly` escribe la cabecera solo al CREAR el fichero y nada la
    validaba despues, asi que un mensual con cabecera de 5 columnas convivia indefinidamente con
    filas de 7 que el propio compactador le escribia encima. Aqui solo se informa: cambiar la
    cabecera de un historial es una migracion, y no se hace desde este script.
    """
    out = []
    for path in monthly_files(mem):
        problema = jc.header_issue(jc.read_lines(path))
        if problema:
            out.append((os.path.basename(path), problema))
    return out


def ids_invented(idx_path):
    """Ids de Tier 2 que NO coinciden con `sha1(texto+creado+origen)[:10]` de su propia linea.

    Mide una DISCREPANCIA, no un origen: lo mas comun es un id escrito a mano, pero tambien la
    produce una linea cuyo texto se edito despues de asignarle el id, o un id que emitio una
    version anterior del algoritmo. La consecuencia es la misma en los tres casos: si alguien
    reemite ESE MISMO pendiente por journal, el emisor calcula el id canonico, no lo encuentra
    en el archivo y escribe una segunda linea y una segunda fila para el mismo pendiente.

    Se reportan para que se vea venir; no se recalculan, porque ya estan citados en session logs.
    """
    out = []
    prio_ignorada = None  # parse_tier2 ya valida los campos; aqui solo interesa el hash
    for pid, text, _p, creado, origen, faltan in parse_tier2(idx_path):
        if faltan or origen is None:
            continue   # sin origen no hay hash que comparar (linea anterior al journal)
        raw = "\n".join([re.sub(r"\s+", " ", unicodedata.normalize("NFC", text)).strip(),
                          creado,
                          re.sub(r"\s+", " ", unicodedata.normalize("NFC", origen)).strip()])
        if "p-" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10] != pid:
            out.append(pid)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--fix-pipes", action="store_true",
                    help="reescribe con `|` escapado las filas que hoy no se pueden cerrar")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--budget", type=float, default=2.0)
    a = ap.parse_args()

    mem = os.path.abspath(a.memory_dir)
    idx = os.path.join(mem, "_pendientes.md")
    if not os.path.isfile(idx):
        print(f"repair-dualwrite: no existe {idx}", file=sys.stderr)
        return 1

    jc = load_compactor(os.path.dirname(os.path.abspath(__file__)))
    if jc is None:
        print("repair-dualwrite: falta journal-compact.py en el mismo bin/", file=sys.stderr)
        return 1

    lock = None
    if a.apply:
        lock = jc.Lock(os.path.join(mem, ".journal"), a.budget)
        if not lock.acquire():
            if not a.quiet:
                print("adopted=0 rows_added=0 pipes_broken=0 pipes_fixed=0 unaligned_rows=0 "
                      "unrepairable=0 odd_values=0 header_issues=0 (busy)")
            return 0
    try:
        # Primero las filas con `|` crudo: hasta que se reescriben, su `_id:` cae fuera de la
        # celda de texto y `existing_ids` las contaria como ausentes, duplicandolas.
        pipes, unrepairable = broken_pipe_rows(jc, mem)
        if pipes and a.fix_pipes and a.apply:
            por_path = {}
            for path, i, nueva in pipes:
                por_path.setdefault(path, []).append((i, nueva))
            for path, cambios in por_path.items():
                lines = jc.read_lines(path)
                for i, nueva in cambios:
                    lines[i] = nueva
                jc.atomic_write(path, lines)

        # La adopcion va ANTES de cualquier lectura de Tier 2: mueve lineas, y tanto
        # `ids_invented` como el reparto por mes tienen que ver el archivo ya adoptado.
        adoptados_todos = adopt_orphans(jc, mem, a.apply)

        have = existing_ids(jc, mem)
        # Un huerfano CERRADO no se mueve nunca, asi que seguiria saliendo en cada corrida una vez
        # escrita su fila. Se reporta solo mientras haya algo que hacer con el; si no, callar es
        # lo correcto: un aviso que reaparece sin trabajo detras es el que deja de leerse.
        adoptados = [x for x in adoptados_todos if x[3] or x[0] not in have]
        inventados = ids_invented(idx)
        desalineadas = unaligned_rows(jc, mem)
        valores_raros = odd_value_rows(jc, mem)
        cabeceras = header_issues(jc, mem)
        added = 0
        broken = []
        pending = []
        # La prioridad que decidio la adopcion vale para la fila aunque la linea no se haya
        # movido todavia (dry-run) o no se mueva nunca (un `- [x]` cerrado): sin este respaldo el
        # item se reportaria NO REPARABLE justo al lado de su propia linea ADOPTADO, que es
        # contradecirse, y en el caso cerrado se quedaria sin fila para siempre.
        prio_adoptada = {pid: prio for pid, prio, _, _ in adoptados_todos}
        for pid, text, prio, creado, origen, faltan in parse_tier2(idx):
            if pid in have:
                continue
            if prio is None and pid in prio_adoptada:
                prio = prio_adoptada[pid]
                faltan = [f for f in faltan if f != "sin header de prioridad"]
            if faltan:
                broken.append((pid, ", ".join(faltan)))
                continue
            pending.append((pid, text, prio, creado, origen))

        # Agrupar por mes para abrir y reescribir cada mensual una sola vez.
        por_mes = {}
        for item in pending:
            por_mes.setdefault(item[3][:7], []).append(item)

        for ym in sorted(por_mes):
            path = os.path.join(mem, "pendientes", ym + ".md")
            lines = jc.ensure_monthly(path, ym) if not os.path.isfile(path) else jc.read_lines(path)
            at = jc.last_table_line(lines)
            if at is None:
                broken += [(i[0], f"{ym}.md no tiene tabla") for i in por_mes[ym]]
                continue
            nums = [int(c[0]) for _, c in jc.table_rows(lines) if c and c[0].isdigit()]
            n = (max(nums) + 1) if nums else 1
            nuevas = []
            for pid, text, prio, creado, origen in por_mes[ym]:
                nuevas.append(f"| {n} | {cell(text)} _id: {pid}_ | {prio} | {creado} "
                              f"| {origen or '—'} | | |")
                n += 1
                added += 1
            if a.apply:
                lines[at + 1:at + 1] = nuevas
                jc.atomic_write(path, lines)
            elif not a.quiet:
                for pid, *_ in por_mes[ym]:
                    print(f"  {pid} -> pendientes/{ym}.md")

        # Re-sellar la linea base de huellas antes de reportar: esta herramienta escribe los
        # indices de forma LEGITIMA y /checkpoint-3t la corre en su Step 3-pre. Sin esto, el
        # detector de deriva de journal-compact avisaria de "escritura fuera del journal" en
        # cada reparacion: un falso positivo en un camino sancionado, que es justo lo que
        # haria que nadie volviera a hacer caso del aviso.
        if a.apply:
            try:
                jc.guardar_huellas(mem, os.path.join(mem, ".journal"))
            except AttributeError:
                pass   # compactador anterior a 2.13.2: no tiene huellas que sellar
        if not a.quiet:
            sufijo = "" if a.apply else " [dry-run: usa --apply]"
            # pipes_broken cuenta lo ENCONTRADO y se imprime siempre; pipes_fixed cuenta lo
            # REPARADO. Al reves, un consumidor en dry-run (el check 14 de /audit-3t) leeria
            # siempre 0 y daria por sana una memoria con filas irresolubles.
            fixed = len(pipes) if (a.fix_pipes and a.apply) else 0
            print(f"adopted={sum(1 for x in adoptados if x[3])} "
                  f"rows_added={added} pipes_broken={len(pipes)} pipes_fixed={fixed} "
                  f"unaligned_rows={len(desalineadas)} unrepairable={len(unrepairable)} "
                  f"odd_values={len(valores_raros)} header_issues={len(cabeceras)} "
                  f"ids_invented={len(inventados)} "
                  f"missing_data={len(broken)}{sufijo}")
            for pid, prio, motivo, movido in adoptados:
                if movido:
                    verbo = "movido" if a.apply else "se moveria"
                    print(f"  ADOPTADO {pid}: {verbo} a '## {prio} prioridad' ({motivo}). Estaba "
                          f"fuera de los headers de prioridad, asi que no podia recibir su fila de "
                          f"Tier 3: es estado anterior al journal, no una escritura a mano.")
                else:
                    print(f"  ADOPTADO {pid}: se queda donde esta y su fila de Tier 3 se escribe "
                          f"con prioridad {prio} ({motivo}).")
            if pipes and not fixed:
                print(f"  AVISO {len(pipes)} filas con `|` crudo no se pueden cerrar "
                      f"(apply_resolve_monthly las lee como ya resueltas): usa --fix-pipes")
            for fn, ln, pid in unrepairable:
                print(f"  GRAVE {fn}:{ln} ({pid}) tiene celdas de mas que no se pueden anclar "
                      f"por forma: no se toca, porque cualquier reparacion automatica moveria "
                      f"datos de columna. Revisala a mano.")
            for fn, ln, pid, medidas in desalineadas:
                print(f"  GRAVE {fn}:{ln} ({pid}) no se puede alinear con las columnas "
                      f"canonicas. Medido: {medidas}. Causas posibles, de mas a menos probable: "
                      f"(1) fila escrita a mano a la que le faltan columnas de en medio; "
                      f"(2) `Creado` con una fecha no canonica o vacia; (3) columnas colapsadas "
                      f"mal por una version anterior — esta ultima dejaria `|` crudos dentro de "
                      f"una celda y la fila saldria con MAS de 7 celdas, asi que si arriba dice "
                      f"7 o menos y 0 escapados, NO se ha perdido ningun dato. Compruebalo "
                      f"contra su linea de Tier 2 antes de reescribir nada.")
            for fn, ln, pid, prio in valores_raros:
                print(f"  AVISO {fn}:{ln} ({pid}) esta bien alineada pero su `Prioridad` es "
                      f"'{prio}', que no es Alta, Media ni Baja. No falta ni se movio nada: es "
                      f"un valor no canonico, y `header_index` no sabra donde reinsertar la "
                      f"linea si se reabre. Corrige el valor, no la fila.")
            for fn, problema in cabeceras:
                # La consecuencia NO es la misma segun la columna que falte: sin `Sesion
                # resolucion` un cierre pierde la sesion que lo cerro; sin `#` solo se queda sin
                # numerar. Decirlo al reves es afirmar un dano que no se midio.
                extra = ("un cierre no tiene donde guardar la sesion que lo cerro"
                         if "Sesion resolucion" in problema
                         else "las filas nuevas salen numeradas y las viejas no, nada mas")
                print(f"  AVISO {fn}: {problema}. El compactador le escribe filas de 7 columnas "
                      f"encima y las filas cortas se leen igual; {extra}. Arreglar la cabecera "
                      f"es una migracion y no se hace desde aqui.")
            if inventados:
                print(f"  AVISO {len(inventados)} ids de Tier 2 no coinciden con el sha1 de su "
                      f"linea. Si alguien reemite ese mismo pendiente por journal saldra el id "
                      f"canonico y una fila duplicada: {inventados[0]} ...")
            for pid, motivo in broken:
                print(f"  NO REPARABLE {pid}: {motivo}")
        return 0
    finally:
        if lock is not None:
            lock.release()


if __name__ == "__main__":
    sys.exit(main())
