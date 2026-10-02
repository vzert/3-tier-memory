#!/usr/bin/env python3
"""
3-tier-memory plugin: recall scorer (motor de bin/recall.sh).

Puntua cada unidad del indice de recall contra el prompt: solapamiento lexico (BM25-lite) x
decaimiento por antiguedad x importance. Imprime las 4 mejores, o nada si ninguna pasa el umbral.

Era el bloque Python embebido en recall.sh (heredoc PYEOF). Se saco a este fichero en la Fase F0
del plan de ciclo de vida de learnings para que el banco (tools/recall-bench/recall-bench.py) mida el MISMO
motor que corre en produccion, importandolo, en vez de copiarlo. La salida no cambio: se comparo
byte a byte con el bloque viejo sobre 50 prompts reales (tools/recall-bench/compare-motores.py).

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

# Peso de una palabra que la unidad solo tiene por sus frases de disparo (F4: `kw_disparadores`,
# las escribe build-recall-index.py desde el comentario `<!-- disparadores: ... -->` de la regla).
# Las frases describen a proposito el momento en que la regla aplica, con las palabras de quien no
# la conoce; una palabra del cuerpo puede estar de paso. Fijado ANTES de medir (sesion F4,
# 2026-10-02); tools/recall-bench reporta tambien 1,0 y 2,0. Un indice sin el campo puntua igual
# que antes de F4.
PESO_DISPARADORES = 1.5

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
    # document frequency for IDF (rare terms in the corpus carry more signal). Solo hace falta la de
    # los terminos del prompt: idf() solo se llama sobre `matched`, que es un subconjunto. Contar
    # todas las palabras del indice en cada prompt era el grueso del tiempo con muchas unidades
    # (F4: las vinetas como unidades llevan paperclip de 2.222 a 5.450). Mismo resultado.
    conjuntos = []
    df = dict.fromkeys(q_terms, 0)
    for u in units:
        kws = set(u.get("keywords", []))
        kwd = set(u.get("kw_disparadores", [])) - kws
        conjuntos.append((kws, kwd))
        for t in q_terms & (kws | kwd):
            df[t] += 1

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
    for u, (kws, kwd) in zip(units, conjuntos):
        matched = q_terms & (kws | kwd)
        if not matched:
            continue
        relevance = sum(idf(t) * (PESO_DISPARADORES if t in kwd else 1.0) for t in matched)
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
    # Pie de retirada (2.45.0, F2 del plan de ciclo de vida): solo si recall.sh pasa RECALL_PIE
    # (la ruta de journal-emit.py). Sin la variable la salida es la del motor de F0, y
    # tools/recall-bench/compare-motores.py sigue comparando byte a byte contra el bloque viejo.
    emit = os.environ.get("RECALL_PIE", "")
    con_pie = False
    for score, relevance, nmatch, u in top:
        tag = LABEL.get(u.get("tipo"), u.get("tipo"))
        path = u.get("path", "")
        print(f"  - [{tag}] {u.get('texto','')}" + (f"  ({path})" if path else ""))
        ancla = ancla_retiro(u) if emit else None
        if ancla:
            con_pie = True
            print(f"      ↳ si ya no es cierta: --topic {ancla[0]} --match-prefix \"{ancla[1]}\"")
    if con_pie:
        mem = os.environ.get("RECALL_MEMORY_DIR", "")
        print(f"  (↳ = la regla esta vencida: python3 \"{emit}\""
              + (f" --memory-dir \"{mem}\"" if mem else "")
              + " --type learning.retire <↳> --motivo obsoleta|duplicada|superada [--por N]."
              " Si solo cambio su texto: --type learning.update <↳> --text \"<nuevo>\".)")


def ancla_retiro(u):
    """(topic, prefijo) para retirar o corregir una regla numerada servida; None si no es una.

    El prefijo son las 6 primeras palabras sin enfasis: journal-compact compara el prefijo con el
    texto sin `*`, `_` ni comillas invertidas. Se corta antes de un caracter que el shell
    interpretaria dentro de comillas dobles."""
    if not u.get("regla"):
        return None
    # `[/\\]`: build-recall-index arma la ruta con os.path.join, que en Windows usa `\`.
    m = re.match(r"^memory[/\\]learnings[/\\]([A-Za-z0-9][A-Za-z0-9._-]*)\.md$", u.get("path", ""))
    if not m:
        return None
    pref = " ".join(re.sub(r"[*_`]", "", u.get("texto", "")).split()[:6])
    pref = re.split(r'["$\\!]', pref)[0].strip()
    return (m.group(1), pref) if pref else None


if __name__ == "__main__":
    main()
