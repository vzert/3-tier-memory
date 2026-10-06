#!/usr/bin/env python3
"""
3-tier-memory plugin: cuando toca consolidar (F6 del plan de ciclo de vida de learnings, 2.50.0).

`/consolidate-3t` casi no se usaba (H12: 0 marcadores de retirada en un corpus de 400 reglas): la
consolidacion dependia de que alguien se acordara. Este script lo dice solo, con tres senales:

  - crecimiento: un topic tiene 15 reglas o mas desde la ultima /consolidate-3t. La ultima la
    guarda `memory/.consolidate-state.json` (lo escribe --guardar-estado, que corre
    /consolidate-3t al final). Se cuenta por el NUMERO mas alto del topic, no por las reglas vivas:
    retirar una regla no puede esconder el crecimiento. Un topic sin numeradas cuenta sus vinetas.
    Sin estado (nunca se consolido) el punto de partida es 0: decision de Victor, 2026-10-06 — un
    corpus grande que nunca se consolido es justo el caso que el aviso existe para cubrir;
  - H11: una regla viva cuyo TITULO dice que corrige a otra ("Corrige regla 217: …",
    "Correccion de la regla 5: …", "CORREGIDO el …"). Corregir anadiendo deja las dos reglas en el
    recall; lo correcto es learning.update de la original y learning.retire de la correctora. Se
    mira solo el titulo (`**…**` al principio) y solo esas formas: ante la duda no avisa, porque
    juzgar la prosa del cuerpo es el juicio semantico que este repo ya no hace en un hook;
  - pares fuertes: dos reglas vivas del mismo topic con parecido >= UMBRAL de learning_vecinos (el
    de F3, Dice-IDF). Es O(n^2) por topic, asi que va en --json y --pares, nunca en --aviso.

Modos (uno por llamada):
  --aviso            una linea para el arranque de sesion, o nada. Sale 0 siempre; cualquier fallo
                     es silencio (un aviso no puede tumbar el arranque).
  --json             las tres senales en JSON (para /audit-3t).
  --pares            solo los pares fuertes en JSON (para /consolidate-3t paso 0.5).
  --guardar-estado   escribe memory/.consolidate-state.json con el numero mas alto de cada topic.

Sin dependencias (I4).
"""
# sella-huellas: no (lee los topic files; solo escribe .consolidate-state.json, que no es un indice)
import argparse
import json
import os
import re
import sys
import tempfile
from datetime import date

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import learning_marks  # noqa: E402
import learning_vecinos  # noqa: E402

CRECIMIENTO = 15
ESTADO = ".consolidate-state.json"
# Los mismos ficheros que salta el recall (build-recall-index.py, EXCLUDE_NAME_RE).
_ARCHIVADO = re.compile(r"(\.bak(-|$)|\.zip$|\.archived\.md$|(^|-)archived-)", re.IGNORECASE)
_TITULO = re.compile(r"^\*\*(.+?)\*\*")
_CORRIGE = re.compile(r"^(?:corrige|correcci[oó]n\s+de)\s+(?:la\s+)?regla\s+#?\d+\b", re.IGNORECASE)
_CORREGIDO = re.compile(r"^CORREGIDO\b")


def topics(mem):
    """[(topic, contenido)] de memory/learnings/*.md, sin archivados, en orden de nombre."""
    d = os.path.join(mem, "learnings")
    out = []
    try:
        nombres = sorted(os.listdir(d))
    except OSError:
        return out
    for n in nombres:
        if not n.endswith(".md") or n.startswith(".") or _ARCHIVADO.search(n):
            continue
        p = os.path.join(d, n)
        if not os.path.isfile(p):
            continue
        with open(p, encoding="utf-8", errors="replace") as fh:
            out.append((n[:-3], fh.read()))
    return out


def tamano(contenido):
    """El numero mas alto del topic; sin numeradas, cuantas vinetas. Retiradas incluidas."""
    reglas = learning_vecinos.reglas_de(contenido)
    nums = [n for n, _ in reglas if n is not None]
    return max(nums) if nums else len(reglas)


def es_h11(texto):
    m = _TITULO.match(learning_marks.sin_marca(texto or "").strip())
    if not m:
        return False
    t = m.group(1).strip()
    return bool(_CORRIGE.match(t) or _CORREGIDO.match(t))


def leer_estado(mem):
    """{topic: n} de la ultima consolidacion, o {} si no hay estado usable (= desde 0)."""
    try:
        with open(os.path.join(mem, ESTADO), encoding="utf-8") as fh:
            e = json.load(fh)
    except (OSError, ValueError):
        return {}
    t = e.get("topics") if isinstance(e, dict) else None
    if not isinstance(t, dict):
        return {}
    return {k: v for k, v in t.items()
            if isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool) and v >= 0}


def senales(mem, con_pares):
    estado = leer_estado(mem)
    crec, h11, pares = [], [], []
    for topic, contenido in topics(mem):
        n = tamano(contenido)
        delta = n - estado.get(topic, 0)
        if delta >= CRECIMIENTO:
            crec.append({"topic": topic, "reglas": n, "desde": estado.get(topic, 0), "crecio": delta})
        vivas = [(num, t) for num, t in learning_vecinos.reglas_de(contenido)
                 if not learning_marks.regla_retirada(t)]
        for num, t in vivas:
            if es_h11(t):
                h11.append({"topic": topic, "regla": num, "titulo": learning_vecinos.titulo(t)})
        if con_pares:
            cand = [(f"{topic}#{num}" if num is not None else f"{topic}#-", t) for num, t in vivas]
            for s, a, b in learning_vecinos.pares(cand):
                pares.append({"topic": topic, "a": a, "b": b, "parecido": round(s, 3)})
    crec.sort(key=lambda x: -x["crecio"])
    return {"crecimiento": crec, "h11": h11, "pares": pares, "umbral_crecimiento": CRECIMIENTO,
            "umbral_pares": learning_vecinos.UMBRAL, "con_estado": bool(estado)}


def linea_aviso(s):
    partes = []
    c = s["crecimiento"]
    if c:
        t = c[0]
        cola = f" (y {len(c) - 1} topic{'s' if len(c) > 2 else ''} mas)" if len(c) > 1 else ""
        desde = "desde la ultima /consolidate-3t" if s["con_estado"] else "y nunca se consolido"
        partes.append(f"learnings/{t['topic']}.md crecio {t['crecio']} reglas {desde}{cola}")
    h = s["h11"]
    if h:
        ids = ", ".join(f"{x['topic']}#{x['regla']}" for x in h[:3]) + (" …" if len(h) > 3 else "")
        partes.append(f"{len(h)} regla{'s' if len(h) > 1 else ''} que corrige{'n' if len(h) > 1 else ''} "
                      f"a otra sigue{'n' if len(h) > 1 else ''} viva{'s' if len(h) > 1 else ''} ({ids})")
    if not partes:
        return ""
    return "CONSOLIDAR: " + "; ".join(partes) + ". Corre /consolidate-3t."


def guardar_estado(mem):
    datos = {"fecha": date.today().isoformat(),
             "topics": {t: tamano(c) for t, c in topics(mem)}}
    fd, tmp = tempfile.mkstemp(prefix=".consolidate-state.", suffix=".tmp", dir=mem)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(datos, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, os.path.join(mem, ESTADO))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return datos


def main():
    ap = argparse.ArgumentParser(description="Senales de que toca /consolidate-3t.")
    ap.add_argument("--memory-dir", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--aviso", action="store_true")
    g.add_argument("--json", action="store_true")
    g.add_argument("--pares", action="store_true")
    g.add_argument("--guardar-estado", dest="guardar", action="store_true")
    a = ap.parse_args()
    mem = a.memory_dir
    if a.aviso:
        try:
            if os.path.isdir(mem):
                l = linea_aviso(senales(mem, con_pares=False))
                if l:
                    print(l)
        except Exception:
            pass
        return 0
    if not os.path.isdir(mem):
        sys.exit(f"consolidate-aviso: no existe {mem}")
    if a.guardar:
        d = guardar_estado(mem)
        print(f"consolidate-aviso: estado guardado ({len(d['topics'])} topics, {d['fecha']})")
        return 0
    s = senales(mem, con_pares=True)
    if a.pares:
        s = {"pares": s["pares"], "umbral_pares": s["umbral_pares"]}
    print(json.dumps(s, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
