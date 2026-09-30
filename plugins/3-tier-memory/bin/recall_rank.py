#!/usr/bin/env python3
"""
3-tier-memory plugin: recall scorer (motor de bin/recall.sh).

Puntua cada unidad del indice de recall contra el prompt: solapamiento lexico (BM25-lite) x
decaimiento por antiguedad x importance. Imprime las 4 mejores, o nada si ninguna pasa el umbral.

Era el bloque Python embebido en recall.sh (heredoc PYEOF). Se saco a este fichero en la Fase F0
del plan de ciclo de vida de learnings para que el banco (tools/recall-bench.py) mida el MISMO
motor que corre en produccion, importandolo, en vez de copiarlo. La salida no cambio: se comparo
byte a byte con el bloque viejo sobre 50 prompts reales (tools/recall-bench/test-bench.sh).

Uso (lo que hace recall.sh):
    RECALL_INDEX=<indice.jsonl> RECALL_PROMPT=<texto> recall_rank.py

Como libreria: tokenize(), load_units(), rank(units, prompt, today=None, k=4).
"""
# sella-huellas: no (solo lee el indice derivado e imprime; no escribe nada)
import json
import math
import os
import re
import sys
from datetime import date

# UTF-8 en stdout y stderr, como todo .py de bin/ (ver build-recall-index.py y
# test-utf8-streams.sh). recall.sh ya exporta PYTHONUTF8; esto cubre la llamada directa.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

# Tokenizacion identica a build-recall-index.py (regla 49): mismas stopwords, mismo regex.
STOPWORDS = set("""
a al algo alguna algunas alguno algunos ante antes como con contra cual cuando
de del desde donde dos el ella ellas ellos en entre era eran es esa esas ese eso
esos esta estaba estado estar estas este esto estos fue fueron ha hace hacer han
hasta hay la las le les lo los mas me mi mis mucho muy no nos o os otra otras otro
otros para pero poco por porque que quien se sea ser si sin sobre solo son su sus
tan te tiene todo todos tu tus un una uno unos y ya
the a an and or but if then else for to of in on at by with from into is are was
were be been being this that these those it its as not no do does did have has had
will would can could should may might must about over under more most some any all
you your we our they them he she his her how what when where which who why
""".split())
WORD_RE = re.compile(r"[a-záéíóúüñ0-9]{2,}", re.IGNORECASE)

HALFLIFE = {"session": 30.0, "pendiente": 60.0, "plan": 180.0,
            "research": 180.0, "learning": 3650.0}

LABEL = {"learning": "regla", "session": "sesión", "pendiente": "pendiente",
         "plan": "plan", "research": "research"}


def tokenize(text):
    out, seen = [], set()
    for w in WORD_RE.findall(text.lower()):
        if w in seen or w in STOPWORDS:
            continue
        if len(w) < 3 and not any(c.isdigit() for c in w):
            continue
        seen.add(w)
        out.append(w)
    return out


def load_units(index_path):
    """Unidades del indice JSONL. Cualquier error de lectura o de JSON devuelve None."""
    units = []
    try:
        with open(index_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    units.append(json.loads(line))
    except Exception:
        return None
    return units


def rank(units, prompt, today=None, k=4):
    """Las k mejores (score, relevance, nmatch, unidad) que pasan el umbral; [] si ninguna."""
    q_terms = set(tokenize(prompt))
    if not q_terms or not units:
        return []
    if today is None:
        today = date.today()

    N = len(units)
    # document frequency for IDF (rare terms in the corpus carry more signal)
    df = {}
    for u in units:
        for kw in set(u.get("keywords", [])):
            df[kw] = df.get(kw, 0) + 1

    def idf(term):
        n = df.get(term, 0)
        if n == 0:
            return 0.0
        return math.log(1 + (N - n + 0.5) / (n + 0.5))

    def recency(u):
        f = u.get("fecha", "")
        m = re.match(r"(\d{4})-(\d{2})-(\d{2})", f or "")
        if not m:
            return 0.85  # unknown date → mild neutral weight
        try:
            d = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            return 0.85
        days = max(0, (today - d).days)
        hl = HALFLIFE.get(u.get("tipo"), 180.0)
        return 0.5 ** (days / hl)

    scored = []
    for u in units:
        kws = set(u.get("keywords", []))
        matched = q_terms & kws
        if not matched:
            continue
        relevance = sum(idf(t) for t in matched)
        if relevance <= 0:
            continue
        imp = u.get("importance", 5) or 5
        score = relevance * recency(u) * (imp / 5.0)
        scored.append((score, relevance, len(matched), u))

    # Threshold: require meaningful lexical signal (≥2 matched terms OR one rare term)
    scored = [s for s in scored if s[2] >= 2 or s[1] >= 1.6]
    # sort estable, igual que el bloque original: los empates conservan el orden del indice
    scored.sort(key=lambda x: x[0], reverse=True)
    return scored[:k]


def main():
    index_path = os.environ.get("RECALL_INDEX", "")
    prompt = os.environ.get("RECALL_PROMPT", "")
    # El bloque original salia antes de abrir el indice si el prompt no tenia terminos.
    if not tokenize(prompt):
        return
    units = load_units(index_path)
    top = rank(units or [], prompt)
    if not top:
        return
    print("MEMORIA RELEVANTE A TU PETICIÓN (del sistema 3-tier; ábrela si aplica, ignórala si no):")
    for score, relevance, nmatch, u in top:
        tag = LABEL.get(u.get("tipo"), u.get("tipo"))
        path = u.get("path", "")
        print(f"  - [{tag}] {u.get('texto','')}" + (f"  ({path})" if path else ""))


if __name__ == "__main__":
    main()
