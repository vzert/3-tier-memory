#!/usr/bin/env python3
"""
3-tier-memory plugin: el marcador de regla retirada, en un solo sitio.

Una regla que deja de valer no se borra ni se renumera (las reglas se citan por numero): se marca
al final de SU MISMA linea. Lo escribe `learning.retire` (y `learning.add --supersedes`) en
journal-compact.py, con la forma canonica

    N. **Regla** — detalle — ⊘ RETIRADA (YYYY-MM-DD, <motivo>[ por #M]): <nota>

y lo leen todos los que sirven reglas al agente: build-recall-index.py (y por el,
find-dup-candidates.py y el banco de recall) y el propio compactador. Un solo lector para que
escribir y leer no puedan discrepar.

Que cuenta como retirada (inventariado el 2026-10-01 con
`grep -rhno '⊘ [A-Z]\\+[^:]*' <proyectos>/*/memory/learnings` sobre varias instalaciones):
  - una regla cuya linea lleva `— ⊘ RETIRADA` o `— ⊘ SUPERSEDED` (con o sin "by", con `—` o `--`)
    detras del cuerpo. La forma vieja `⊘ SUPERSEDED (FECHA, …)` y la de /consolidate-3t
    `⊘ SUPERSEDED by [[…]]` cuentan;
  - un topic file cuya cabecera `# ` es `# ⊘ SUPERSEDED …` o `# ⊘ RETIRADA …`: el topic entero.
Que NO cuenta:
  - `⊘` a mitad de frase sin RETIRADA/SUPERSEDED detras ("⊘ la variante X quedo …");
  - el marcador sin el separador `—`/`--` delante (una regla que lo DESCRIBE: "marcar con
    `⊘ SUPERSEDED by`");
  - el marcador dentro de un `code span` (una regla que cita la forma canonica entre comillas
    invertidas no esta retirada por citarla).

Sin dependencias (I4). Se importa desde el directorio de bin/ (sys.path[0] del script que corre).
"""
# sella-huellas: no (libreria: no escribe nada)
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

MOTIVOS = ("obsoleta", "duplicada", "superada")

_SEP_MARCA = re.compile(r"(?:—|--)\s*⊘\s*(?:RETIRADA|SUPERSEDED)\b")
_CABECERA = re.compile(r"^#\s+⊘\s*(?:RETIRADA|SUPERSEDED)\b")
_POR = re.compile(r"⊘\s*RETIRADA\s*\([^)]*?\bpor #(\d+)\)")
_BY = re.compile(r"⊘\s*SUPERSEDED by \[\[[^\]|#]*#(\d+)")


_RACHA = re.compile(r"`+")


def code_spans(texto):
    """Rangos [ini, fin) de los code spans de una linea, como CommonMark: una racha de N comillas
    invertidas abre y cierra con la siguiente racha de exactamente N. Una racha sin pareja es texto.
    Contar comillas sueltas no basta: ``a ` b`` es UN span con una comilla dentro."""
    rachas = [(m.start(), m.end()) for m in _RACHA.finditer(texto)]
    spans, i = [], 0
    while i < len(rachas):
        ini, fin = rachas[i]
        n = fin - ini
        j = next((k for k in range(i + 1, len(rachas)) if rachas[k][1] - rachas[k][0] == n), None)
        if j is None:
            i += 1
            continue
        spans.append((ini, rachas[j][1]))
        i = j + 1
    return spans


def inicio_marca(texto):
    """Posicion donde empieza el marcador (incluido el espacio previo), o None si no lo hay.

    Solo cuenta un marcador fuera de code span (ver code_spans). El comentario de disparadores, que
    va siempre detras, no entra en la busqueda (sus frases no pueden retirar una regla)."""
    t = sin_disparadores(texto or "")
    spans = code_spans(t)
    for m in _SEP_MARCA.finditer(t):
        if not any(a <= m.start() < b for a, b in spans):
            i = m.start()
            while i > 0 and t[i - 1] in " \t":
                i -= 1
            return i
    return None


def regla_retirada(texto):
    """True si el texto de una regla (o su linea entera) lleva el marcador de retirada."""
    return inicio_marca(texto) is not None


def sin_marca(texto):
    """El texto de la regla sin el marcador ni el comentario de disparadores: lo que la regla DICE.

    Es lo que comparan la idempotencia del journal (es_misma_regla, find_rule_anchored) y los
    vecinos de learning.add: ni retirarla ni enriquecerla la hacen otra regla."""
    t = sin_disparadores(texto or "")
    i = inicio_marca(t)
    return t if i is None else t[:i].rstrip()


def sufijo_marca(texto):
    """El marcador tal cual esta escrito (con su espacio previo), o "" si no lo hay. Sin el
    comentario de disparadores (ver sufijo_disparadores)."""
    t = sin_disparadores(texto or "")
    i = inicio_marca(t)
    return "" if i is None else t[i:]


# --- Disparadores (F4 del plan de ciclo de vida de learnings) --------------------------------------
#
# Frases con las que alguien que NO conoce la regla describiria el momento en que aplica, mas los
# comandos, rutas y herramientas de ese momento. Los escribe una vez el agente que escribe la regla
# (expansion del documento al escribir, doc2query): el recall es lexico y sin dependencias (H13),
# asi que una parafrasis solo encuentra la regla si sus palabras estan en ella. Van en la MISMA
# linea de la regla (I2: rewrite_rule solo reescribe reglas de una linea; nada de ficheros
# paralelos), al final de todo, como comentario HTML en linea:
#
#     N. **Regla** — cuerpo[ — ⊘ RETIRADA (...)] <!-- disparadores: frases=a | b | c; cmd=git commit; path=docs/*; tool=Bash -->
#
# Un comentario HTML no se ve al renderizar el markdown. Validado con markdown-it-py sobre 1953
# reglas reescribibles de 4 corpus: 0 cambios de estructura (paso 1 de F4).
#
# Lo que NO puede llevar: `--` (CommonMark 0.29-0.30 y GFM cortan el comentario ahi y el resto se
# veria como texto), `<` ni `>`, y los separadores del propio formato dentro de un valor (`;`
# entre campos, `|` entre frases, `,` entre comandos/rutas/herramientas, `=` tras la clave).

CAMPOS_DISPARADORES = ("frases", "cmd", "path", "tool", "freno")
FRASES_MIN, FRASES_MAX = 3, 6
_DISP = re.compile(r"[ \t]*<!--[ \t]*disparadores:(.*?)-->[ \t]*$")


def _inicio_disparadores(texto):
    """(posicion del comentario con su espacio previo, contenido) o (None, None). Solo un
    comentario al FINAL de la linea y fuera de code span cuenta."""
    m = _DISP.search(texto or "")
    if not m or any(a <= m.start() < b for a, b in code_spans(texto)):
        return None, None
    return m.start(), m.group(1)


def sin_disparadores(texto):
    """El texto sin el comentario de disparadores (ni el espacio que lo precede)."""
    i, _ = _inicio_disparadores(texto)
    return texto if i is None else texto[:i].rstrip()


def sufijo_disparadores(texto):
    """El comentario tal cual esta escrito (con su espacio previo), o "" si no lo hay."""
    i, _ = _inicio_disparadores(texto)
    return "" if i is None else texto[i:]


def problemas_disparadores(s):
    """Lista de problemas de una cadena `frases=...; cmd=...; path=...; tool=...` ([] si vale)."""
    if not isinstance(s, str) or not s.strip():
        return ["vacia"]
    malos = []
    if "--" in s or "<" in s or ">" in s or "\n" in s:
        malos.append("lleva '--', '<', '>' o un salto de linea (cortaria el comentario HTML)")
    vistos = set()
    for campo in s.split(";"):
        campo = campo.strip()
        if not campo:
            continue
        clave, igual, valor = campo.partition("=")
        clave = clave.strip()
        if not igual or clave not in CAMPOS_DISPARADORES:
            malos.append(f"campo {campo[:40]!r}: tiene que ser clave=valor con clave en "
                         f"{', '.join(CAMPOS_DISPARADORES)}")
            continue
        if clave in vistos:
            malos.append(f"campo {clave!r} repetido")
        vistos.add(clave)
        if "=" in valor:
            malos.append(f"campo {clave!r}: '=' dentro de un valor")
        if clave == "frases":
            frases = [f.strip() for f in valor.split("|")]
            if any(not f for f in frases):
                malos.append("frases: una frase vacia (dos '|' seguidos o al borde)")
            if not FRASES_MIN <= len(frases) <= FRASES_MAX:
                malos.append(f"frases: {len(frases)}; tienen que ser de {FRASES_MIN} a {FRASES_MAX}")
        elif clave == "freno":
            if valor.strip() != "si":
                malos.append("freno: el unico valor es 'si'")
        elif "|" in valor or any(not v.strip() for v in valor.split(",")):
            malos.append(f"{clave}: valores separados por ',' sin vacios ni '|'")
    if "frases" not in vistos:
        malos.append("falta frases=")
    return malos


def disparadores_de(texto):
    """{'frases': [...], 'cmd': [...], 'path': [...], 'tool': [...], 'freno': bool} del comentario
    de la linea, o None si no lo tiene o no es valido (un comentario roto no se sirve a medias)."""
    _, contenido = _inicio_disparadores(texto)
    if contenido is None or problemas_disparadores(contenido.strip()):
        return None
    d = {"frases": [], "cmd": [], "path": [], "tool": [], "freno": False}
    for campo in contenido.split(";"):
        clave, _, valor = campo.strip().partition("=")
        clave = clave.strip()
        if clave == "frases":
            d["frases"] = [f.strip() for f in valor.split("|")]
        elif clave == "freno":
            d["freno"] = True
        elif clave:
            d[clave] = [v.strip() for v in valor.split(",")]
    return d


def comentario_disparadores(s):
    """` <!-- disparadores: <s normalizada> -->`, con el espacio inicial, para pegar al final de la
    linea. `s` ya tiene que haber pasado problemas_disparadores()."""
    partes = []
    for campo in s.split(";"):
        clave, _, valor = campo.strip().partition("=")
        clave = clave.strip()
        if not clave:
            continue
        sep = " | " if clave == "frases" else ", "
        vals = [v.strip() for v in valor.split("|" if clave == "frases" else ",")]
        partes.append(f"{clave}={sep.join(vals)}")
    return f" <!-- disparadores: {'; '.join(partes)} -->"


def retirada_por(texto):
    """El numero M de `por #M` (canonico) o de `SUPERSEDED by [[...#M]]`; None si no lo dice."""
    s = sufijo_marca(texto)
    m = _POR.search(s) or _BY.search(s)
    return int(m.group(1)) if m else None


def topic_retirado(contenido):
    """True si la primera cabecera `# ` del topic file (tras el frontmatter) lo retira entero."""
    lineas = (contenido or "").splitlines()
    i = 0
    if lineas and lineas[0].strip() == "---":
        for j in range(1, len(lineas)):
            if lineas[j].strip() == "---":
                i = j + 1
                break
    for linea in lineas[i:]:
        if linea.startswith("# "):
            return bool(_CABECERA.match(linea))
    return False


def con_marca(texto, marca):
    """El texto de la regla con `marca` (ver marca_canonica) puesta DELANTE de su comentario de
    disparadores: el comentario va siempre al final de la linea."""
    return sin_disparadores(texto) + marca + sufijo_disparadores(texto)


def marca_canonica(fecha, motivo, por=None, nota=""):
    """` — ⊘ RETIRADA (YYYY-MM-DD, <motivo>[ por #N])[: <nota>]`, con el espacio inicial."""
    cuerpo = f"{fecha}, {motivo}" + (f" por #{por}" if por else "")
    return f" — ⊘ RETIRADA ({cuerpo})" + (f": {nota}" if nota else "")
