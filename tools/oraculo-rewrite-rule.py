#!/usr/bin/env python3
"""Fuerza bruta de `rewrite_rule` (journal-compact.py) contra un parser CommonMark como oraculo.

Propiedad: si rewrite_rule NO cuarentena, entonces (1) la linea i era un item de lista de UNA linea
(su list_item solo abarca i y lineas en blanco), y (2) el documento nuevo parsea IDENTICO al viejo
salvo el texto inline de esa linea. Cualquier otra cosa es una reescritura mala.

Por que existe: la comparacion de sangrias cayo cinco veces, y la quinta respondia bien a su propia
pregunta. Solo un parser de verdad dice cual es la pregunta. Este oraculo encontro 137 clases de
fallo en la version de 2.31.0 que ninguna prueba casera habia visto (2026-09-21).

Necesita markdown-it-py, que el plugin NO usa ni distribuye. Sin el, dice SKIP y sale 0: un SKIP
explicito, no un verde. Instalarlo en un venv:  python3 -m venv v && v/bin/pip install markdown-it-py
y correr  v/bin/python tools/oraculo-rewrite-rule.py  (N3/N4/SEED por entorno).
"""
import sys, itertools, random, importlib.util, os
try:
    from markdown_it import MarkdownIt
except ImportError:
    print("SKIP: sin markdown-it-py no hay oraculo (ver la cabecera de este fichero)")
    sys.exit(0)
SRC = os.environ.get("JC") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                           "plugins", "3-tier-memory", "bin", "journal-compact.py")
spec = importlib.util.spec_from_file_location("jc", SRC); jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
md = MarkdownIt("commonmark")
IND = ["", " ", "  ", "   ", "    ", "\t", " \t", "\t ", "\u00a0", "\v", "\u3000"]
CON = ["- a", "* a", "1. a", "2. a", "-\u00a0a", "- ", "# h", "#t", "```", "~~~", "<div>", "</div>",
       "x", "", "> q", "---", "- - -", "    ", "\u00a0", "  more", "<!--", "-->", "````", "+ a", "1) a", "==", "   ```", "1. a"]
LINES = sorted(set(i + c for i in IND for c in CON))
def toks(text):
    return md.parse(text)
def ok(old, new, i):
    to, tn = toks("\n".join(old) + "\n"), toks("\n".join(new) + "\n")
    if len(to) != len(tn): return "estructura distinta"
    difs = [k for k, (a, b) in enumerate(zip(to, tn))
            if (a.type, a.tag, a.nesting, a.markup, a.map, a.content, a.info) != (b.type, b.tag, b.nesting, b.markup, b.map, b.content, b.info)]
    if len(difs) != 1: return f"{len(difs)} tokens distintos"
    k = difs[0]; t = to[k]
    if t.type != "inline" or t.map != [i, i + 1]: return f"cambio en {t.type} map={t.map}"
    # sube hasta el list_item que lo contiene
    d = 0
    for j in range(k - 1, -1, -1):
        if to[j].type == "paragraph_open" and d == 0: continue
        if to[j].type == "list_item_open":
            m = to[j].map
            if m[0] != i: return f"list_item empieza en {m[0]}"
            if any(old[x].strip(" \t") for x in range(i + 1, m[1])): return f"list_item arrastra lineas {m}"
            return None
        return f"no esta en un list_item (padre {to[j].type})"
    return "sin padre"
def probar(doc):
    malos = []
    for i, l in enumerate(doc):
        if jc.rule_text(l)[1] is None: continue
        new = list(doc)
        try: jc.rewrite_rule(new, i, len(new), "NEW", "t")
        except jc.Quarantine: continue
        r = ok(doc, new, i)
        if r: malos.append((i, r))
    return malos
fallos = {}; n = 0
def reg(doc):
    global n
    n += 1
    for i, r in probar(doc):
        clave = (r.split(" ")[0], doc[i])
        fallos.setdefault(clave, (doc, i, r))
for a, b in itertools.product(LINES, repeat=2): reg([a, b])
random.seed(int(os.environ.get("SEED", "1")))
for _ in range(int(os.environ.get("N3", "60000"))): reg([random.choice(LINES) for _ in range(3)])
for _ in range(int(os.environ.get("N4", "40000"))): reg([random.choice(LINES) for _ in range(4)])
print(f"docs {n}, clases de fallo {len(fallos)}")
for (tipo, li), (doc, i, r) in sorted(fallos.items(), key=lambda x: repr(x[0]))[:60]:
    print(repr(doc), "i=", i, "->", r)
sys.exit(1 if fallos else 0)
