#!/usr/bin/env python3
"""Cuantos de los ultimos N learning.add reales habria bloqueado el dedup al emitir (F3, 2.46.0).

Reproduce cada evento `learning.add` con texto de `<memory>/.journal/applied/` contra el topic tal
como estaba al emitirlo: las reglas del topic con numero MENOR que el que el compactador le dio
(numera max+1). Una regla retirada entra como viva si su retirada es del mismo dia que el evento o
posterior, o si su marcador no trae fecha (ante la duda, candidata: solo puede subir la cuenta). Usa la funcion de `journal-emit.py` (bin/learning_vecinos.py,
importada) y su UMBRAL. Imprime, por evento, sus 3 vecinos mas parecidos, y al final cuantos
habrian llegado al umbral. Un bloqueo no es por si solo un bloqueo FALSO: cada uno se mira a mano
(¿la regla nueva era la misma leccion que su vecino?) y el juicio va al resultado de la fase.

Es tambien el lector del campo `decision` que `learning.add --decision` deja en el payload (2.46.0):
por evento imprime la decision, y al final cuantos `learning.add` la traen (`con_decision`). Mide si
el paso 0 del checkpoint se esta usando de verdad.

Solo LEE el memory/. Limites: un learning.update posterior cambia el texto de hoy de una regla, y
entonces el evento ya no se encuentra en su topic (sale como `no-encontrada`, no se cuenta); y las
candidatas llevan su texto de HOY, no el que tenian al emitir.

Uso: bloqueos-reales.py <memory_dir> [--ultimos 30] [--salida F.json]
"""
import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugins", "3-tier-memory", "bin")
sys.path.insert(0, os.path.abspath(BIN))
import learning_marks  # noqa: E402
import learning_vecinos as lv  # noqa: E402


def plano(t):
    return " ".join((t or "").split())


_FECHA_MARCA = re.compile(r"\((\d{4}-\d{2}-\d{2})")


def fecha_evento(e):
    """YYYY-MM-DD del evento (ts en ns, UTC), o "" si no lo trae."""
    ts = e.get("ts")
    if not isinstance(ts, int):
        return ""
    return datetime.fromtimestamp(ts / 1e9, tz=timezone.utc).date().isoformat()


def retirada_despues(texto, dia):
    """True si la retirada de la regla es del mismo dia que el evento o posterior, o si no se sabe.

    Ante la duda la regla cuenta como viva al emitir: una candidata de mas solo puede subir la
    cuenta de bloqueos, que es el lado seguro para un criterio de "menos de 2"."""
    m = _FECHA_MARCA.search(learning_marks.sufijo_marca(texto))
    return not (m and dia) or m.group(1) >= dia


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
                          "titulo": lv.titulo(texto),
                          "decision": (e.get("payload") or {}).get("decision") or None})
            continue
        n = ns[0]
        dia = fecha_evento(e)
        cand = []
        for k, t in reglas:
            if not k or k >= n:
                continue
            if learning_marks.regla_retirada(t) and retirada_despues(t, dia):
                # Al emitir, esta regla seguia viva: entra como candidata, sin el marcador.
                t = learning_marks.sin_marca(t)
            cand.append((f"#{k}", t))
        top = lv.vecinos(texto, cand, k=3)
        filas.append({"topic": topic, "regla": n, "titulo": lv.titulo(texto),
                      "decision": (e.get("payload") or {}).get("decision") or None,
                      "estado": "bloquearia" if top and top[0][0] >= lv.UMBRAL else "pasa",
                      "vecinos": [{"regla": et, "parecido": round(s, 3), "titulo": lv.titulo(t)}
                                  for s, et, t in top]})
    for r in filas:
        v = " | ".join(f"{x['regla']} {x['parecido']:.2f}" for x in r.get("vecinos", []))
        print(f"{r['estado']:<13} {r['topic']}#{r['regla']}  [{r.get('decision') or 'sin decision'}]  {v}")
    medidos = [r for r in filas if r["estado"] != "no-encontrada"]
    bloq = [r for r in medidos if r["estado"] == "bloquearia"]
    con_dec = sum(1 for r in filas if r.get("decision"))
    print(f"learning.add medidos={len(medidos)} de {len(filas)} bloquearian={len(bloq)} "
          f"(umbral {lv.UMBRAL}) con_decision={con_dec} de {len(filas)}")
    if a.salida:
        with open(a.salida, "w", encoding="utf-8") as f:
            f.write(json.dumps({"umbral": lv.UMBRAL, "medidos": len(medidos),
                                "bloquearian": len(bloq), "con_decision": con_dec, "eventos": filas},
                               ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
