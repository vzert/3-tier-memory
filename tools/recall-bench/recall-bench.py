#!/usr/bin/env python3
"""Banco de pruebas del recall de learnings (Fase F0 de memory/plans/plan-ciclo-de-vida-learnings.md).

Sirve a cualquier instalacion del plugin: el codigo no sabe nada de ningun proyecto concreto. Lo
concreto vive en un fichero de casos. Hay dos:

- `corpus-neutro/casos.jsonl`, publicado: un corpus de memoria con reglas de patrones comunes (git,
  CI, shell, publicacion, proceso del agente) y sus casos. Corre en tools/run-tests.sh y en la CI.
- `casos.jsonl` (no se publica, .gitignore): los casos de TU instalacion, sobre los memory/ de tus
  proyectos. `minar-casos.py` propone candidatos sacados de tus fichas de sesion.

Mide, sobre casos declarados con cita comprobable, tres cosas que el plan quiere mejorar:

- prompt@4: fraccion de casos del canal "prompt" con alguna regla esperada en el top 4 del motor
  de produccion (bin/recall_rank.py, importado: no una copia).
- fuga: reglas "prohibidas" que el motor devuelve (por ejemplo el segundo miembro de un
  duplicado). En F0 es informativa: todavia no hay forma de retirar una regla (F2/F7).
- dedup@8: fraccion de casos "dedup" cuya regla original sale entre los 8 vecinos mas parecidos
  de la regla duplicada, con la funcion que imprime `journal-emit.py learning.add` (desde 2.46.0,
  bin/learning_vecinos.py: Dice-IDF sobre el texto completo, mismo topic, reglas anteriores).
- accion@2: el canal "accion" (recall en PreToolUse) no existe todavia; su valor en F0 es 0 por
  construccion y queda anotado como no medido. La F5 lo implementa.

Los indices se construyen con build-recall-index.py en un directorio temporal. Los memory/ de los
corpus solo se LEEN. Nunca se corre recall.sh, que compacta el journal y reescribe el indice del
proyecto que resuelve.

Se NIEGA a correr (sale 2) si hay menos de 20 casos con cita (origen "incidente" o "neutro"),
menos de 5 del canal accion entre ellos, algun caso sin `fuente`, con una `fuente` que no existe, o
cuya `cita` no aparece literal en su fuente, o algun caso todavia marcado `"revisar": true` (un
candidato de minar-casos.py que nadie reviso: el campo, con cualquier valor, se quita al revisar). Los de origen "medida" corren y cuentan en las
metricas, pero no completan los minimos.

Limite (lo que el banco NO prueba): `origen`, `canal`, `esperadas` y `prohibidas` los declara quien
escribe el caso. El banco comprueba que la fuente existe, que la cita esta en ella y que las reglas
citadas existen sin ambiguedad; no puede comprobar que la regla esperada fuera la que aplicaba, ni
que el caso sea de verdad un incidente. Eso lo revisa una persona.

Formato de un caso (una linea JSON):
  {"id": "...", "corpus": "<nombre bajo --corpus-raiz> | <ruta a un proyecto con memory/>",
   "canal": "prompt|accion|dedup",
   "entrada": "<prompt>" | {"tool_name": ..., "tool_input": {...}} | "<topic>#<N>" (dedup),
   "esperadas": ["<topic>#<N>", ...], "prohibidas": ["<topic>#<N>", ...],
   "fuente": "<ruta>", "cita": "<texto literal de la fuente>", "nota": "...",
   "origen": "incidente|neutro|medida",
   "linea_base_esperada": {"contiene": [...], "excluye": [...]},   (opcional)
   "procedencia": {"fuente": "<ruta>", "cita": "<texto literal>"}}   (opcional)
  - Rutas relativas (`corpus`, `fuente`) se resuelven contra la carpeta del fichero de casos.
  - `origen`: incidente (por omision) = un error real de tu instalacion; neutro = un incidente real
    reescrito en terminos generales para el corpus publicado; medida = una frase con la que se
    midio algo, no un incidente.
  - `procedencia`: una segunda fuente, fuera del corpus, que documenta el incidente (por ejemplo el
    CHANGELOG publico). Se comprueba como la cita. Sin ella, la procedencia es solo la `nota`.
  - `linea_base_esperada`: lo que el motor de HOY devuelve para ese caso (prompt: el top 4; dedup:
    los 8 vecinos). Con --comprobar-linea-base el banco sale 1 si no se reproduce. Sirve para fijar
    una medida (por ejemplo "este duplicado sale junto al original") y ver cuando una fase la cambia.

Uso:
  recall-bench.py [--casos F] [--salida F.json] [--hoy AAAA-MM-DD] [--corpus-raiz DIR]
                  [--comprobar-linea-base]
  --casos: por defecto tools/recall-bench/casos.jsonl (el de tu instalacion).
  --corpus-raiz: donde viven los proyectos cuyo `corpus` es un nombre. Por defecto ~/Projects.
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

# UTF-8 en stdout y stderr, como los .py de bin/ (regla 63): en Windows el flujo sigue la pagina de
# codigos local y los mensajes en espanol salen rotos.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")


RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BIN = os.path.join(RAIZ, "plugins", "3-tier-memory", "bin")
AQUI = os.path.dirname(os.path.abspath(__file__))

MIN_CASOS = 20
MIN_ACCION = 5
CANALES = ("prompt", "accion", "dedup")
ORIGENES = ("incidente", "neutro", "medida")
CON_CITA = ("incidente", "neutro")
K = {"prompt": 4, "accion": 2, "dedup": 8}
RULE_RE = re.compile(r"^\s*(\d+)\.\s+(.*)")
ID_RE = re.compile(r"^[A-Za-z0-9_.-]+#\d+$")


def cargar_motor():
    spec = importlib.util.spec_from_file_location("recall_rank", os.path.join(BIN, "recall_rank.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def cargar_vecinos():
    sys.path.insert(0, BIN)
    import learning_vecinos
    return learning_vecinos


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


def resolver(ruta, base):
    """Ruta absoluta tal cual; relativa, contra la carpeta del fichero de casos."""
    return ruta if os.path.isabs(ruta) else os.path.normpath(os.path.join(base, ruta))


def memory_de(corpus, raiz, base):
    """El memory/ de un corpus: un nombre bajo --corpus-raiz, o una ruta a un proyecto."""
    if "/" in corpus or "\\" in corpus or corpus.startswith("."):
        return os.path.join(resolver(corpus, base), "memory")
    return os.path.join(raiz, corpus, "memory")


def validar_ids(cid, corpus, reglas, rids):
    for rid in rids:
        if not isinstance(rid, str) or not ID_RE.match(rid):
            negarse(f"{cid}: id de regla mal formado {rid!r} (se espera topic#N)")
        motivo = existe_unica(reglas, rid)
        if motivo:
            negarse(f"{cid}: la regla {rid} {motivo} en {corpus}")


def validar(casos, raiz, base):
    for c in casos:
        if c.get("origen", "incidente") not in ORIGENES:
            negarse(f"{c.get('id')}: origen desconocido {c.get('origen')!r}")
        if "revisar" in c:
            negarse(f"{c.get('id')}: es un candidato sin revisar (\"revisar\": true); revisalo y "
                    f"quita el campo, o sacalo del fichero")
    # Solo cuentan para los minimos los casos con cita (incidente o neutro). Los de origen "medida"
    # corren y se reportan, pero no son citas de un incidente y no pueden completar el minimo.
    con_cita = [c for c in casos if c.get("origen", "incidente") in CON_CITA]
    if len(con_cita) < MIN_CASOS:
        negarse(f"hay {len(con_cita)} casos; hacen falta al menos {MIN_CASOS} "
                f"(de origen incidente o neutro)")
    n_accion = sum(1 for c in con_cita if c.get("canal") == "accion")
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
        fuente = resolver(fuente, base)
        if not os.path.isfile(fuente):
            negarse(f"{cid}: la fuente no existe: {fuente}")
        cita = c.get("cita")
        if not cita:
            negarse(f"{cid}: sin cita")
        with open(fuente, encoding="utf-8") as f:
            if cita not in f.read():
                negarse(f"{cid}: la cita no aparece literal en la fuente")
        # procedencia (opcional): una segunda fuente, independiente del corpus, que documenta el
        # incidente de origen (p. ej. el CHANGELOG publico). Se comprueba igual que fuente y cita.
        pr = c.get("procedencia")
        if pr is not None:
            if not isinstance(pr, dict) or not pr.get("fuente") or not pr.get("cita"):
                negarse(f"{cid}: procedencia necesita 'fuente' y 'cita'")
            pf = resolver(pr["fuente"], base)
            if not os.path.isfile(pf):
                negarse(f"{cid}: la fuente de la procedencia no existe: {pf}")
            with open(pf, encoding="utf-8") as f:
                if pr["cita"] not in f.read():
                    negarse(f"{cid}: la cita de la procedencia no aparece literal en su fuente")
        if c.get("canal") not in CANALES:
            negarse(f"{cid}: canal desconocido {c.get('canal')!r}")
        if not c.get("corpus"):
            negarse(f"{cid}: sin corpus")
        mem = memory_de(c["corpus"], raiz, base)
        if not os.path.isdir(mem):
            negarse(f"{cid}: el corpus no existe: {mem}")
        if mem not in reglas_cache:
            reglas_cache[mem] = reglas_de(mem)
        c["_mem"] = mem
        reglas = reglas_cache[mem]
        esperadas = c.get("esperadas")
        if not isinstance(esperadas, list) or not esperadas:
            negarse(f"{cid}: sin esperadas")
        if set(esperadas) & set(c.get("prohibidas") or []):
            negarse(f"{cid}: una regla no puede ser esperada y prohibida a la vez")
        validar_ids(cid, c["corpus"], reglas, esperadas + list(c.get("prohibidas") or []))
        e = c.get("entrada")
        if c["canal"] == "prompt" and not (isinstance(e, str) and e.strip()):
            negarse(f"{cid}: entrada de prompt vacia")
        if c["canal"] == "accion" and not (isinstance(e, dict) and e.get("tool_name")):
            negarse(f"{cid}: entrada de accion sin tool_name")
        if c["canal"] == "dedup":
            if not (isinstance(e, str) and ID_RE.match(e)):
                negarse(f"{cid}: entrada de dedup debe ser topic#N")
            validar_ids(cid, c["corpus"], reglas, [e])
        lb = c.get("linea_base_esperada")
        if lb is not None:
            if c["canal"] == "accion":
                negarse(f"{cid}: el canal accion no tiene linea base que fijar todavia")
            if not isinstance(lb, dict) or set(lb) - {"contiene", "excluye"} or not lb:
                negarse(f"{cid}: linea_base_esperada solo admite 'contiene' y 'excluye'")
            if not any(isinstance(v, list) and v for v in lb.values()):
                negarse(f"{cid}: linea_base_esperada sin ninguna regla: no fijaria nada")
            validar_ids(cid, c["corpus"], reglas, list(lb.get("contiene", [])) + list(lb.get("excluye", [])))
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
        amb = ambiguas(reglas, topic)
        vistos = {}
        for n, texto in rs:
            vistos[n] = vistos.get(n, 0) + 1
            rid = f"{topic}#{n}" if n not in amb else f"{topic}#{n}~{vistos[n]}"
            pendientes.setdefault((rel, builder.truncate(texto)), []).append(rid)
    for u in units:
        cola = pendientes.get((u.get("path"), u.get("texto")))
        u["_rid"] = cola.pop(0) if cola else None
    return units


def etiqueta(u):
    return u.get("_rid") or f"{u.get('tipo')}:{u.get('path')}"


def cargar_casos(ruta):
    if not os.path.isfile(ruta):
        negarse(f"no existe el fichero de casos: {ruta}")
    casos = []
    with open(ruta, encoding="utf-8") as f:
        for i, l in enumerate(f, 1):
            if l.strip():
                try:
                    casos.append(json.loads(l))
                except json.JSONDecodeError as e:
                    negarse(f"linea {i} de casos no es JSON: {e}")
    return casos


def medir(casos, reglas_por_mem, hoy):
    motor, builder, vecinos_mod = cargar_motor(), cargar_builder(), cargar_vecinos()
    detalle = []
    with tempfile.TemporaryDirectory() as tmp:
        indices = {}
        for i, (mem, reglas) in enumerate(reglas_por_mem.items()):
            indices[mem] = indice_con_ids(mem, reglas, builder, tmp, f"idx-{i}")
        for c in casos:
            units = indices[c["_mem"]]
            esperadas, prohibidas = set(c["esperadas"]), set(c.get("prohibidas") or [])
            r = {"id": c["id"], "canal": c["canal"], "corpus": c["corpus"],
                 "origen": c.get("origen", "incidente")}
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
                # Los vecinos los calcula la MISMA funcion que imprime journal-emit.py learning.add
                # (bin/learning_vecinos.py, importada): Dice ponderado por IDF sobre el texto
                # completo de cada regla, retiradas fuera. Candidatas: las reglas del topic con
                # numero MENOR que la del caso, que es lo que el topic tenia cuando se emitio (el
                # compactador numera max+1). La regla del caso puede estar retirada (desde 2.45.0
                # el duplicado se retira) y sigue siendo un caso valido: la pregunta es si al
                # emitirla se habria visto la original.
                topic, n = c["entrada"].split("#")[0], int(c["entrada"].split("#")[1])
                amb = ambiguas(reglas_por_mem[c["_mem"]], topic)
                todas = reglas_por_mem[c["_mem"]][topic]
                texto = next(t for k, t in todas if k == n)
                cand = [(f"{topic}#{k}", t) for k, t in todas if k < n and k not in amb]
                orden = [e for _, e, _ in vecinos_mod.vecinos(texto, cand, k=len(cand))]
                puestos = {e: (orden.index(e) + 1 if e in orden else None) for e in sorted(esperadas)}
                r["devueltas"] = orden[:K["dedup"]]
                r["puestos"] = puestos
                r["candidatas"] = len(orden)
                r["acierto"] = any(p is not None and p <= K["dedup"] for p in puestos.values())
                r["fuga"] = []
            lb = c.get("linea_base_esperada")
            if lb is not None:
                dev = set(r["devueltas"])
                falta = sorted(set(lb.get("contiene", [])) - dev)
                sobra = sorted(set(lb.get("excluye", [])) & dev)
                r["linea_base"] = "ok" if not (falta or sobra) else \
                    f"NO: falta {falta}, sobra {sobra}"
            detalle.append(r)
    return detalle


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--casos", default=os.path.join(AQUI, "casos.jsonl"))
    ap.add_argument("--salida", default="")
    ap.add_argument("--hoy", default="")
    ap.add_argument("--corpus-raiz", default=os.path.expanduser("~/Projects"))
    ap.add_argument("--comprobar-linea-base", action="store_true")
    a = ap.parse_args()

    casos = cargar_casos(a.casos)
    base = os.path.dirname(os.path.abspath(a.casos))
    reglas_por_mem = validar(casos, a.corpus_raiz, base)
    hoy = date.fromisoformat(a.hoy) if a.hoy else date.today()
    detalle = medir(casos, reglas_por_mem, hoy)

    def frac(canal):
        cs = [d for d in detalle if d["canal"] == canal]
        return {"aciertos": sum(d["acierto"] for d in cs), "casos": len(cs),
                "valor": round(sum(d["acierto"] for d in cs) / len(cs), 3) if cs else None}

    res = {
        "hoy": hoy.isoformat(),
        "motor": "plugins/3-tier-memory/bin/recall_rank.py",
        "casos": len(casos),
        "casos_con_cita": sum(1 for c in casos if c.get("origen", "incidente") in CON_CITA),
        # cuantos traen una procedencia comprobada fuera del corpus; el resto es declarada
        "procedencia_verificada": sum(1 for c in casos if c.get("procedencia")),
        "metricas": {
            "prompt@4": frac("prompt"),
            "accion@2": dict(frac("accion"), nota="no medido: canal inexistente en F0"),
            "dedup@8": dict(frac("dedup"), fuente_palabras="bin/learning_vecinos.py (la de journal-emit learning.add): Dice ponderado por IDF, tokenize() del texto completo de cada regla, mismo topic, reglas con numero menor que la del caso, retiradas fuera"),
            "fuga": {"valor": sum(len(d["fuga"]) for d in detalle),
                     "nota": "reglas prohibidas devueltas; desde 2.45.0 (F2) una regla retirada no se sirve"},
        },
        "detalle": detalle,
    }
    if a.salida:
        with open(a.salida, "w", encoding="utf-8") as f:
            f.write(json.dumps(res, ensure_ascii=False, indent=2) + "\n")
    m = res["metricas"]
    print(f"casos={len(casos)} prompt@4={m['prompt@4']['aciertos']}/{m['prompt@4']['casos']} "
          f"accion@2=0/{m['accion@2']['casos']} (no medido) "
          f"dedup@8={m['dedup@8']['aciertos']}/{m['dedup@8']['casos']} fuga={m['fuga']['valor']} "
          f"procedencia_verificada={res['procedencia_verificada']}/{res['casos_con_cita']}")

    if a.comprobar_linea_base:
        fijados = [d for d in detalle if "linea_base" in d]
        malos = [d for d in fijados if d["linea_base"] != "ok"]
        for d in malos:
            print(f"LINEA BASE NO SE REPRODUCE: {d['id']}: {d['linea_base']} "
                  f"(devuelve {d['devueltas']})", file=sys.stderr)
        if not fijados:
            print("recall-bench: --comprobar-linea-base sin ningun caso con linea_base_esperada",
                  file=sys.stderr)
            return 1
        if malos:
            return 1
        print(f"linea base reproducida: {len(fijados)} casos fijados")
    return 0


if __name__ == "__main__":
    sys.exit(main())
