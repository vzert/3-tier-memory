#!/usr/bin/env python3
"""
3-tier-memory plugin: los vecinos de una regla nueva dentro de su topic (dedup al emitir, 2.46.0).

Un duplicado escrito con otras palabras no se parece lo bastante a la regla vieja para que un
umbral lo atrape (la medida mas alta de un duplicado real esta por debajo de la de muchas reglas
nuevas de verdad), pero si queda entre las K mas parecidas de su topic. Por eso
`journal-emit.py learning.add` imprime esa lista y el agente decide; solo bloquea cuando el
parecido es casi literal (UMBRAL).

La medida, la misma para el emisor y para el banco de recall (tools/recall-bench, que la importa):
  - palabras: `tokenize()` de build-recall-index.py (el tokenizador del recall, importado, no
    copiado) sobre el texto COMPLETO de la regla, sin el marcador de retirada;
  - candidatas: las reglas vivas del topic (numeradas; las vinetas solo si el topic no tiene
    ninguna numerada, como el recall). Una regla retirada no es vecina: el recall ya no la sirve;
  - peso de cada palabra: IDF dentro de las candidatas del topic;
  - parecido: Dice ponderado por IDF, 2*sum(idf de las comunes) / (sum(idf de A) + sum(idf de B)).
    No "solapamiento / palabras de la nueva": esa medida premia a la regla mas larga del topic,
    que entonces sale primera para casi cualquier regla nueva (medido: una regla de 51 KB era la
    vecina n.1 de los ultimos 30 learning.add de un topic real).

Sin dependencias (I4). Se importa desde el directorio de bin/.
"""
# sella-huellas: no (libreria: no escribe nada)
import importlib.util
import math
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import learning_marks  # noqa: E402

K = 8
UMBRAL = 0.5
TITULO_MAX = 200

_REGLA = re.compile(r"^\s*(\d+)\.\s+(.*)$")
_VINETA = re.compile(r"^\s*[-*]\s+(.*)$")
_TITULO = re.compile(r"^\*\*(.+?)\*\*")
_FORMA = re.compile(r"^\*\*[^*]+?\*\* — \S")

_builder = None


def _tokenize(texto):
    """tokenize() de build-recall-index.py: el mismo tokenizador que usa el recall."""
    global _builder
    if _builder is None:
        sys.dont_write_bytecode = True   # sin __pycache__ dentro del plugin instalado
        ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build-recall-index.py")
        spec = importlib.util.spec_from_file_location("build_recall_index", ruta)
        _builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_builder)
    return _builder.tokenize(texto)


def reglas_de(contenido):
    """[(numero|None, texto)] de un topic file, en orden de fichero, retiradas incluidas.

    Numeradas como las lee el recall (`N. texto` en cualquier sangria). Si el fichero no tiene
    ninguna numerada, sus vinetas (el recall indexa entonces el fichero entero). Un topic retirado
    entero (cabecera `# ⊘ ...`) no tiene reglas vivas: devuelve []."""
    if learning_marks.topic_retirado(contenido):
        return []
    lineas = (contenido or "").splitlines()
    nums = [(int(m.group(1)), m.group(2)) for l in lineas for m in [_REGLA.match(l)] if m]
    if nums:
        return nums
    return [(None, m.group(1)) for l in lineas for m in [_VINETA.match(l)] if m]


def titulo(texto, n=100):
    """El `**titulo**` de la regla, o su principio, recortado a n caracteres."""
    t = learning_marks.sin_marca(texto or "")
    m = _TITULO.match(t)
    t = " ".join((m.group(1) if m else t).split())
    return t if len(t) <= n else t[: n - 1].rstrip() + "…"


def vecinos(texto, candidatas, k=K):
    """Las k candidatas mas parecidas a `texto`, de mas a menos: [(parecido, etiqueta, texto)].

    `candidatas` es [(etiqueta, texto)]; las retiradas se saltan aqui. Empates: orden de entrada."""
    vivas = [(e, t) for e, t in candidatas if not learning_marks.regla_retirada(t)]
    docs = [set(_tokenize(learning_marks.sin_marca(t))) for _, t in vivas]
    df = {}
    for d in docs:
        for w in d:
            df[w] = df.get(w, 0) + 1
    n = len(docs)

    def idf(w):
        return math.log((n + 1) / (df.get(w, 0) + 1)) + 1

    q = set(_tokenize(learning_marks.sin_marca(texto or "")))
    pq = sum(idf(w) for w in q)
    res = []
    for (e, t), d in zip(vivas, docs):
        den = pq + sum(idf(w) for w in d)
        s = 2 * sum(idf(w) for w in q & d) / den if den else 0.0
        res.append((s, e, t))
    res.sort(key=lambda x: -x[0])   # sort estable: los empates conservan el orden del fichero
    return res[:k]


def problemas_de_forma(texto):
    """Lista de problemas de forma de una regla nueva ([] si esta bien).

    Exige `**Titulo** — cuerpo`, `**` y comillas invertidas en numero par, y un titulo de como
    mucho TITULO_MAX caracteres. No intenta adivinar una regla truncada por su ultima palabra: un
    final como "sobre el" puede ser "sobre él" sin tilde."""
    t = texto or ""
    p = []
    if not _FORMA.match(t):
        p.append("no empieza por `**Titulo** — cuerpo` (titulo en negrita, espacio, raya —, "
                 "espacio y el cuerpo)")
    if t.count("**") % 2:
        p.append("numero impar de `**`: una negrita sin cerrar")
    if t.count("`") % 2:
        p.append("numero impar de comillas invertidas: un code span sin cerrar")
    m = _TITULO.match(t)
    if m and len(m.group(1)) > TITULO_MAX:
        p.append(f"titulo de {len(m.group(1))} caracteres (maximo {TITULO_MAX}): el titulo es "
                 f"el nombre de la regla, el detalle va en el cuerpo")
    return p
