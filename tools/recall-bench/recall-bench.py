#!/usr/bin/env python3
"""Banco de pruebas del recall de learnings (Fase F0 de memory/plans/plan-ciclo-de-vida-learnings.md).

Mide, sobre casos REALES, tres cosas que el plan quiere mejorar fase a fase:

- prompt@4: fraccion de casos del canal "prompt" con alguna regla esperada en el top 4 del motor
  de produccion (bin/recall_rank.py, importado: no una copia).
- fuga: reglas "prohibidas" que el motor devuelve (por ejemplo el segundo miembro de un
  duplicado). En F0 es informativa: todavia no hay forma de retirar una regla (F2/F7).
- dedup@8: fraccion de casos "dedup" cuya regla original sale entre los 8 vecinos mas parecidos
  (Jaccard sobre las keywords del indice, dentro del mismo topic) de la regla duplicada.
- accion@2: el canal "accion" (recall en PreToolUse) no existe todavia; su valor en F0 es 0 por
  construccion y queda anotado como no medido. La F5 lo implementa.

Los indices se construyen con build-recall-index.py en un directorio temporal. Los memory/ de los
corpus solo se LEEN. Nunca se corre recall.sh, que compacta el journal y reescribe el indice del
proyecto que resuelve.

Se NIEGA a correr (sale 2) si hay menos de 20 casos de origen "incidente", menos de 5 del canal
accion entre ellos (los de origen "medida" corren pero no cuentan para esos minimos), o algun caso sin
`fuente`, con una `fuente` que no existe, o cuya `cita` no aparece literal en su fuente. La cita es
lo que ata el caso a algo que paso: un caso sin cita comprobable es un caso inventado.

Limite (lo que el banco NO prueba): `origen`, `canal`, `esperadas` y `prohibidas` los declara quien
escribe el caso. El banco comprueba que la fuente existe, que la cita esta en ella y que las reglas
citadas existen sin ambiguedad; no puede comprobar que la regla esperada fuera la que aplicaba, ni
que el caso sea de verdad un incidente. Eso lo revisa una persona sobre casos.jsonl.

Formato de un caso (una linea JSON en casos.jsonl):
  {"id": "...", "corpus": "claude-vzert", "canal": "prompt|accion|dedup",
   "entrada": "<prompt>" | {"tool_name": ..., "tool_input": {...}} | "<topic>#<N>" (dedup),
   "esperadas": ["<topic>#<N>", ...], "prohibidas": ["<topic>#<N>", ...],
   "fuente": "<ruta absoluta>", "cita": "<texto literal de la fuente>", "nota": "...",
   "origen": "incidente|medida"}   (por omision incidente; solo esos cuentan para los minimos)

Uso:
  recall-bench.py [--casos F] [--salida F.json] [--hoy AAAA-MM-DD] [--corpus-raiz DIR]
                  [--comprobar-h8]
  --corpus-raiz: donde viven los proyectos (<raiz>/<corpus>/memory). Por defecto ~/Projects.
  --comprobar-h8: ademas exige la linea base H8 del plan (sale 1 si no se reproduce).
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import date

RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BIN = os.path.join(RAIZ, "plugins", "3-tier-memory", "bin")
AQUI = os.path.dirname(os.path.abspath(__file__))

MIN_CASOS = 20
MIN_ACCION = 5
CANALES = ("prompt", "accion", "dedup")
ORIGENES = ("incidente", "medida")
K = {"prompt": 4, "accion": 2, "dedup": 8}
RULE_RE = re.compile(r"^\s*(\d+)\.\s+(.*)")
ID_RE = re.compile(r"^[A-Za-z0-9_.-]+#\d+$")


def cargar_motor():
    spec = importlib.util.spec_from_file_location("recall_rank", os.path.join(BIN, "recall_rank.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def cargar_builder():
    spec = importlib.util.spec_from_file_location(
        "build_recall_index", os.path.join(BIN, "build-recall-index.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def negarse(msg):
    print(f"recall-bench: NO CORRE — {msg}", file=sys.stderr)
    sys.exit(2)


def reglas_de(memory_dir):
    """{topic: [(N, texto), ...]} en orden de fichero, igual que parse_learnings del builder.

    Un topic file puede repetir un numero (varias listas numeradas que reinician en 1): entonces
    `topic#N` es ambiguo. Todas las apariciones se conservan para mapear el indice; las repetidas
    se etiquetan `topic#N~k` y un caso no puede citarlas (ver ambiguas()).
    """
    out = {}
    ldir = os.path.join(memory_dir, "learnings")
    if not os.path.isdir(ldir):
        return out
    for fn in sorted(os.listdir(ldir)):
        if not fn.endswith(".md"):
            continue
        topic = fn[:-3]
        with open(os.path.join(ldir, fn), encoding="utf-8") as f:
            for line in f:
                m = RULE_RE.match(line)
                if m:
                    out.setdefault(topic, []).append((int(m.group(1)), m.group(2)))
    return out


def numeros(reglas, topic):
    return [n for n, _ in reglas.get(topic, [])]


def ambiguas(reglas, topic):
    ns = numeros(reglas, topic)
    return {n for n in ns if ns.count(n) > 1}


def existe_unica(reglas, rid):
    """None si la regla topic#N existe una sola vez; si no, el motivo."""
    t, n = rid.split("#")
    n = int(n)
    if n not in numeros(reglas, t):
        return "no existe"
    if n in ambiguas(reglas, t):
        return "es ambigua (el numero se repite en el topic file)"
    return None


def validar(casos, raiz):
    # Solo cuentan para los minimos los casos declarados de incidente (origen "incidente", el valor
    # por omision). Los de origen "medida" (las frases con que se midio H8 en el plan) corren y se
    # reportan, pero no son citas de un incidente y no pueden completar el minimo.
    for c in casos:
        if c.get("origen", "incidente") not in ORIGENES:
            negarse(f"{c.get('id')}: origen desconocido {c.get('origen')!r}")
    reales = [c for c in casos if c.get("origen", "incidente") == "incidente"]
    if len(reales) < MIN_CASOS:
        negarse(f"hay {len(reales)} casos; hacen falta al menos {MIN_CASOS} (de origen incidente)")
    n_accion = sum(1 for c in reales if c.get("canal") == "accion")
    if n_accion < MIN_ACCION:
        negarse(f"hay {n_accion} casos del canal accion; hacen falta al menos {MIN_ACCION}")
    ids = set()
    reglas_cache = {}
    for c in casos:
        cid = c.get("id") or "<sin id>"
        if cid in ids:
            negarse(f"id repetido: {cid}")
        ids.add(cid)
        fuente = c.get("fuente")
        if not fuente:
            negarse(f"{cid}: sin fuente")
        if not os.path.isabs(fuente) or not os.path.isfile(fuente):
            negarse(f"{cid}: la fuente no existe: {fuente}")
        cita = c.get("cita")
        if not cita:
            negarse(f"{cid}: sin cita")
        with open(fuente, encoding="utf-8") as f:
            if cita not in f.read():
                negarse(f"{cid}: la cita no aparece literal en la fuente")
        if c.get("canal") not in CANALES:
            negarse(f"{cid}: canal desconocido {c.get('canal')!r}")
        mem = os.path.join(raiz, c.get("corpus", ""), "memory")
        if not c.get("corpus") or not os.path.isdir(mem):
            negarse(f"{cid}: el corpus no existe: {mem}")
        if c["corpus"] not in reglas_cache:
            reglas_cache[c["corpus"]] = reglas_de(mem)
        reglas = reglas_cache[c["corpus"]]
        esperadas = c.get("esperadas")
        if not isinstance(esperadas, list) or not esperadas:
            negarse(f"{cid}: sin esperadas")
        if set(esperadas) & set(c.get("prohibidas") or []):
            negarse(f"{cid}: una regla no puede ser esperada y prohibida a la vez")
        for rid in esperadas + list(c.get("prohibidas") or []):
            if not ID_RE.match(rid):
                negarse(f"{cid}: id de regla mal formado {rid!r} (se espera topic#N)")
            motivo = existe_unica(reglas, rid)
            if motivo:
                negarse(f"{cid}: la regla {rid} {motivo} en {c['corpus']}")
        e = c.get("entrada")
        if c["canal"] == "prompt" and not (isinstance(e, str) and e.strip()):
            negarse(f"{cid}: entrada de prompt vacia")
        if c["canal"] == "accion" and not (isinstance(e, dict) and e.get("tool_name")):
            negarse(f"{cid}: entrada de accion sin tool_name")
        if c["canal"] == "dedup":
            if not (isinstance(e, str) and ID_RE.match(e)):
                negarse(f"{cid}: entrada de dedup debe ser topic#N")
            motivo = existe_unica(reglas, e)
            if motivo:
                negarse(f"{cid}: la regla {e} {motivo} en {c['corpus']}")
    return reglas_cache


def indice_con_ids(memory_dir, reglas, builder, tmp, nombre):
    """Construye el indice en tmp y anota en cada unidad de learning su id topic#N."""
    out = os.path.join(tmp, f"{nombre}.jsonl")
    subprocess.run([sys.executable, os.path.join(BIN, "build-recall-index.py"), memory_dir, out],
                   capture_output=True, check=True)
    units = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
    # (path, texto truncado) -> [N...] en orden de aparicion, como los emite el builder
    pendientes = {}
    for topic, rs in reglas.items():
        rel = os.path.join("memory", "learnings", f"{topic}.md")
        vistos = {}
        for n, texto in rs:
            vistos[n] = vistos.get(n, 0) + 1
            rid = f"{topic}#{n}" if vistos[n] == 1 and n not in ambiguas(reglas, topic) \
                else f"{topic}#{n}~{vistos[n]}"
            pendientes.setdefault((rel, builder.truncate(texto)), []).append(rid)
    for u in units:
        cola = pendientes.get((u.get("path"), u.get("texto")))
        u["_rid"] = cola.pop(0) if cola else None
    return units


def etiqueta(u):
    return u.get("_rid") or f"{u.get('tipo')}:{u.get('path')}"


def jaccard(a, b):
    a, b = set(a), set(b)
    return len(a & b) / len(a | b) if a | b else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--casos", default=os.path.join(AQUI, "casos.jsonl"))
    ap.add_argument("--salida", default="")
    ap.add_argument("--hoy", default="")
    ap.add_argument("--corpus-raiz", default=os.path.expanduser("~/Projects"))
    ap.add_argument("--comprobar-h8", action="store_true")
    a = ap.parse_args()

    if not os.path.isfile(a.casos):
        negarse(f"no existe el fichero de casos: {a.casos}")
    casos = []
    for i, l in enumerate(open(a.casos, encoding="utf-8"), 1):
        if l.strip():
            try:
                casos.append(json.loads(l))
            except json.JSONDecodeError as e:
                negarse(f"linea {i} de casos no es JSON: {e}")
    reglas_por_corpus = validar(casos, a.corpus_raiz)

    hoy = date.fromisoformat(a.hoy) if a.hoy else date.today()
    motor, builder = cargar_motor(), cargar_builder()
    detalle = []
    with tempfile.TemporaryDirectory() as tmp:
        indices = {}
        for corpus, reglas in reglas_por_corpus.items():
            indices[corpus] = indice_con_ids(os.path.join(a.corpus_raiz, corpus, "memory"),
                                             reglas, builder, tmp, corpus)
        for c in casos:
            units = indices[c["corpus"]]
            esperadas, prohibidas = set(c["esperadas"]), set(c.get("prohibidas") or [])
            r = {"id": c["id"], "canal": c["canal"], "corpus": c["corpus"]}
            if c["canal"] == "prompt":
                top = [etiqueta(u) for *_, u in motor.rank(units, c["entrada"], today=hoy, k=K["prompt"])]
                r["devueltas"] = top
                r["acierto"] = bool(esperadas & set(top))
                r["fuga"] = sorted(prohibidas & set(top))
            elif c["canal"] == "accion":
                r["devueltas"] = []
                r["acierto"] = False
                r["fuga"] = []
                r["nota"] = "canal inexistente en F0: 0 por construccion (lo implementa F5)"
            else:
                por_id = {u["_rid"]: u for u in units if u.get("_rid")}
                nuevo = por_id.get(c["entrada"])
                if nuevo is None:
                    print(f"recall-bench: {c['id']}: la regla {c['entrada']} no esta en el indice",
                          file=sys.stderr)
                    sys.exit(1)
                topic = c["entrada"].split("#")[0]
                vecinos = [u for u in units if u.get("_rid") and u["_rid"].split("#")[0] == topic
                           and u["_rid"] != c["entrada"]]
                # orden estable: empates conservan el orden del indice
                vecinos.sort(key=lambda u: jaccard(nuevo["keywords"], u["keywords"]), reverse=True)
                orden = [u["_rid"] for u in vecinos]
                puestos = {e: (orden.index(e) + 1 if e in orden else None) for e in sorted(esperadas)}
                r["puestos"] = puestos
                r["candidatas"] = len(orden)
                r["acierto"] = any(p is not None and p <= K["dedup"] for p in puestos.values())
                r["fuga"] = []
            detalle.append(r)

    def frac(canal):
        cs = [d for d in detalle if d["canal"] == canal]
        return {"aciertos": sum(d["acierto"] for d in cs), "casos": len(cs),
                "valor": round(sum(d["acierto"] for d in cs) / len(cs), 3) if cs else None}

    res = {
        "hoy": hoy.isoformat(),
        "motor": "plugins/3-tier-memory/bin/recall_rank.py",
        "casos": len(casos),
        "casos_incidente": sum(1 for c in casos if c.get("origen", "incidente") == "incidente"),
        "metricas": {
            "prompt@4": frac("prompt"),
            "accion@2": dict(frac("accion"), nota="no medido: canal inexistente en F0"),
            "dedup@8": dict(frac("dedup"), fuente_palabras="keywords del indice (Jaccard)"),
            "fuga": {"valor": sum(len(d["fuga"]) for d in detalle),
                     "nota": "informativa en F0: ninguna regla es retirable todavia"},
        },
        "detalle": detalle,
    }
    texto = json.dumps(res, ensure_ascii=False, indent=2) + "\n"
    if a.salida:
        with open(a.salida, "w", encoding="utf-8") as f:
            f.write(texto)
    m = res["metricas"]
    print(f"casos={len(casos)} prompt@4={m['prompt@4']['aciertos']}/{m['prompt@4']['casos']} "
          f"accion@2=0/{m['accion@2']['casos']} (no medido) "
          f"dedup@8={m['dedup@8']['aciertos']}/{m['dedup@8']['casos']} fuga={m['fuga']['valor']}")

    if a.comprobar_h8:
        return comprobar_h8(detalle)
    return 0


H8_TRIO = {"gate-review-pre-push-vps#99", "gate-review-pre-push-vps#108", "gate-review-pre-push-vps#135"}


def comprobar_h8(detalle):
    """H8 del plan: las dos parafrasis sacan 0 de {99,108,135}; la tercera saca 99 y 135 juntas."""
    por_id = {d["id"]: d for d in detalle}
    fallos = []
    for cid in ("cv-h8-parafrasis-1", "cv-h8-parafrasis-2"):
        d = por_id.get(cid)
        if d is None:
            fallos.append(f"falta el caso {cid}")
        elif H8_TRIO & set(d["devueltas"]):
            fallos.append(f"{cid} devuelve {sorted(H8_TRIO & set(d['devueltas']))}, H8 dice 0 de 3")
    d = por_id.get("cv-h8-aborto")
    if d is None:
        fallos.append("falta el caso cv-h8-aborto")
    elif not {"gate-review-pre-push-vps#99", "gate-review-pre-push-vps#135"} <= set(d["devueltas"]):
        fallos.append(f"cv-h8-aborto devuelve {d['devueltas']}, H8 dice 99 y 135 juntas")
    for f in fallos:
        print(f"H8 NO SE REPRODUCE: {f}", file=sys.stderr)
    if not fallos:
        print("H8 reproducida: 0 de 3 en las dos parafrasis; 99 y 135 juntas en el aborto")
    return 1 if fallos else 0


if __name__ == "__main__":
    sys.exit(main())
