#!/usr/bin/env python3
"""Cuantos de los ultimos N learning.add reales habria bloqueado el dedup al emitir (F3, 2.46.0).

Reproduce cada evento `learning.add` con texto de `<memory>/.journal/applied/` contra el topic tal
como estaba al emitirlo: las reglas del topic con numero MENOR que el que el compactador le dio
(numera max+1), retiradas fuera. Usa la funcion de `journal-emit.py` (bin/learning_vecinos.py,
importada) y su UMBRAL. Imprime, por evento, sus 3 vecinos mas parecidos, y al final cuantos
habrian llegado al umbral. Un bloqueo no es por si solo un bloqueo FALSO: cada uno se mira a mano
(¿la regla nueva era la misma leccion que su vecino?) y el juicio va al resultado de la fase.

Solo LEE el memory/. Limite: un learning.update posterior cambia el texto de hoy de una regla, y
entonces el evento ya no se encuentra en su topic (sale como `no-encontrada`, no se cuenta).

Uso: bloqueos-reales.py <memory_dir> [--ultimos 30] [--salida F.json]
"""
import argparse
import glob
import json
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugins", "3-tier-memory", "bin")
sys.path.insert(0, os.path.abspath(BIN))
import learning_marks  # noqa: E402
import learning_vecinos as lv  # noqa: E402


def plano(t):
    return " ".join((t or "").split())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--ultimos", type=int, default=30)
    ap.add_argument("--salida", default="")
    a = ap.parse_args()
    eventos = []
    for p in glob.glob(os.path.join(a.memory_dir, ".journal", "applied", "*", "*.json")):
        try:
            with open(p, encoding="utf-8") as f:
                e = json.load(f)
        except (OSError, ValueError):
            continue
        if e.get("type") == "learning.add" and (e.get("payload") or {}).get("text"):
            eventos.append(e)
    eventos.sort(key=lambda e: e.get("ts", 0))
    filas = []
    for e in eventos[-a.ultimos:]:
        topic, texto = e["payload"]["topic"], plano(e["payload"]["text"])
        try:
            with open(os.path.join(a.memory_dir, "learnings", topic + ".md"), encoding="utf-8") as f:
                reglas = lv.reglas_de(f.read())
        except OSError:
            reglas = []
        ns = [n for n, t in reglas if n and plano(learning_marks.sin_marca(t)) == texto]
        if len(ns) != 1:
            filas.append({"topic": topic, "regla": None, "estado": "no-encontrada",
                          "titulo": lv.titulo(texto)})
            continue
        n = ns[0]
        cand = [(f"#{k}", t) for k, t in reglas if k and k < n]
        top = lv.vecinos(texto, cand, k=3)
        filas.append({"topic": topic, "regla": n, "titulo": lv.titulo(texto),
                      "estado": "bloquearia" if top and top[0][0] >= lv.UMBRAL else "pasa",
                      "vecinos": [{"regla": et, "parecido": round(s, 3), "titulo": lv.titulo(t)}
                                  for s, et, t in top]})
    for r in filas:
        v = " | ".join(f"{x['regla']} {x['parecido']:.2f}" for x in r.get("vecinos", []))
        print(f"{r['estado']:<13} {r['topic']}#{r['regla']}  {v}")
    medidos = [r for r in filas if r["estado"] != "no-encontrada"]
    bloq = [r for r in medidos if r["estado"] == "bloquearia"]
    print(f"learning.add medidos={len(medidos)} de {len(filas)} bloquearian={len(bloq)} "
          f"(umbral {lv.UMBRAL})")
    if a.salida:
        with open(a.salida, "w", encoding="utf-8") as f:
            f.write(json.dumps({"umbral": lv.UMBRAL, "medidos": len(medidos),
                                "bloquearian": len(bloq), "eventos": filas},
                               ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
