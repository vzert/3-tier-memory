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

    Solo cuenta un marcador fuera de code span (ver code_spans)."""
    spans = code_spans(texto or "")
    for m in _SEP_MARCA.finditer(texto or ""):
        if not any(a <= m.start() < b for a, b in spans):
            i = m.start()
            while i > 0 and texto[i - 1] in " \t":
                i -= 1
            return i
    return None


def regla_retirada(texto):
    """True si el texto de una regla (o su linea entera) lleva el marcador de retirada."""
    return inicio_marca(texto) is not None


def sin_marca(texto):
    """El texto de la regla sin el marcador (ni el espacio que lo precede)."""
    i = inicio_marca(texto)
    return texto if i is None else texto[:i].rstrip()


def sufijo_marca(texto):
    """El marcador tal cual esta escrito (con su espacio previo), o "" si no lo hay."""
    i = inicio_marca(texto)
    return "" if i is None else texto[i:]


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


def marca_canonica(fecha, motivo, por=None, nota=""):
    """` — ⊘ RETIRADA (YYYY-MM-DD, <motivo>[ por #N])[: <nota>]`, con el espacio inicial."""
    cuerpo = f"{fecha}, {motivo}" + (f" por #{por}" if por else "")
    return f" — ⊘ RETIRADA ({cuerpo})" + (f": {nota}" if nota else "")
