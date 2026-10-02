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

Cada regla entra con el texto que tenia al emitir: se deshacen hacia atras los learning.update
posteriores al evento con el texto escrito antes (ver texto_en). Solo LEE el memory/. Limites: si
el evento que escribio el texto anterior ya no esta en applied/, la regla entra con su texto de hoy
y el evento lleva `texto_incierto` (se cuenta y se imprime); un evento cuya regla ya no se encuentra
sale `no-encontrada` y no se cuenta.

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


def cmp(t):
    """Forma de comparar un prefijo de learning.update con un texto, la del emisor y el compactador
    (sin `*`, `_`, comillas invertidas ni mayusculas)."""
    return plano(re.sub(r"[*_`]", "", t or "")).lower()


def texto_en(topic, actual, ts, escritos, updates):
    """(texto que tenia la regla en el instante ts, seguro) a partir de su texto de HOY.

    Deshace hacia atras cada learning.update del topic posterior a ts que dejo el texto actual: el
    texto anterior es el del ultimo evento (add o update) del topic, anterior al update, que empieza
    por su --match-prefix. Si no lo encuentra (el evento ya no esta en applied/), devuelve el texto
    que tiene y seguro=False: el resultado de ese evento lleva la marca `texto_incierto`."""
    t = plano(learning_marks.sin_marca(actual))
    for u in sorted((u for u in updates.get(topic, []) if u["ts"] > ts), key=lambda u: -u["ts"]):
        if plano(u["text"]) != t:
            continue
        previos = [w for w in escritos.get(topic, []) if w["ts"] < u["ts"]
                   and cmp(w["text"]).startswith(cmp(u["prefix"]))]
        if not previos:
            return t, False
        t = plano(max(previos, key=lambda w: w["ts"])["text"])
    return t, True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--ultimos", type=int, default=30)
    ap.add_argument("--salida", default="")
    a = ap.parse_args()
    eventos = []
    escritos, updates = {}, {}   # por topic: todo texto escrito (add/update) y los updates
    for p in glob.glob(os.path.join(a.memory_dir, ".journal", "applied", "*", "*.json")):
        try:
            with open(p, encoding="utf-8") as f:
                e = json.load(f)
        except (OSError, ValueError):
            continue
        pl, ts = e.get("payload") or {}, e.get("ts", 0)
        if e.get("type") == "learning.add" and pl.get("text"):
            eventos.append(e)
            escritos.setdefault(pl.get("topic"), []).append({"ts": ts, "text": pl["text"]})
        elif e.get("type") == "learning.update" and pl.get("text") and pl.get("match_prefix"):
            escritos.setdefault(pl.get("topic"), []).append({"ts": ts, "text": pl["text"]})
            updates.setdefault(pl.get("topic"), []).append(
                {"ts": ts, "text": pl["text"], "prefix": pl["match_prefix"]})
    eventos.sort(key=lambda e: e.get("ts", 0))
    filas = []
    for e in eventos[-a.ultimos:]:
        topic, texto = e["payload"]["topic"], plano(e["payload"]["text"])
        try:
            with open(os.path.join(a.memory_dir, "learnings", topic + ".md"), encoding="utf-8") as f:
                reglas = lv.reglas_de(f.read())
        except OSError:
            reglas = []
        # Cada regla con el texto que tenia justo despues del evento (deshaciendo los updates
        # posteriores); la del evento es la que entonces decia su texto.
        ts = e.get("ts", 0)
        # Un topic de vinetas no tiene numeros: el orden es el del fichero (el compactador anade
        # cada vineta detras), y la etiqueta es su posicion (`-P`).
        orden = [(k if k else i, t) for i, (k, t) in enumerate(reglas, 1)]
        hist = [(k, t, texto_en(topic, t, ts, escritos, updates)) for k, t in orden]
        ns = [k for k, t, (h, _) in hist if h == texto]
        if len(ns) != 1:
            filas.append({"topic": topic, "regla": None, "estado": "no-encontrada",
                          "titulo": lv.titulo(texto),
                          "decision": (e.get("payload") or {}).get("decision") or None})
            continue
        n = ns[0]
        dia = fecha_evento(e)
        cand, incierto = [], False
        for k, t, (h, seguro) in hist:
            if k >= n:
                continue
            if learning_marks.regla_retirada(t) and not retirada_despues(t, dia):
                continue                           # ya estaba retirada al emitir
            # Viva al emitir (o retirada despues): entra con el texto que tenia entonces.
            cand.append((f"#{k}" if reglas[0][0] else f"-{k}", h))
            incierto = incierto or not seguro
        top = lv.vecinos(texto, cand, k=3)
        filas.append({"topic": topic, "regla": n, "titulo": lv.titulo(texto),
                      "decision": (e.get("payload") or {}).get("decision") or None,
                      "estado": "bloquearia" if top and top[0][0] >= lv.UMBRAL else "pasa",
                      "texto_incierto": incierto,
                      "vecinos": [{"regla": et, "parecido": round(s, 3), "titulo": lv.titulo(t)}
                                  for s, et, t in top]})
    for r in filas:
        v = " | ".join(f"{x['regla']} {x['parecido']:.2f}" for x in r.get("vecinos", []))
        print(f"{r['estado']:<13} {r['topic']}#{r['regla']}  [{r.get('decision') or 'sin decision'}]  {v}")
    medidos = [r for r in filas if r["estado"] != "no-encontrada"]
    bloq = [r for r in medidos if r["estado"] == "bloquearia"]
    con_dec = sum(1 for r in filas if r.get("decision"))
    inc = sum(1 for r in medidos if r.get("texto_incierto"))
    print(f"learning.add medidos={len(medidos)} de {len(filas)} bloquearian={len(bloq)} "
          f"(umbral {lv.UMBRAL}) con_decision={con_dec} de {len(filas)} texto_incierto={inc}")
    if a.salida:
        with open(a.salida, "w", encoding="utf-8") as f:
            f.write(json.dumps({"umbral": lv.UMBRAL, "medidos": len(medidos),
                                "bloquearian": len(bloq), "con_decision": con_dec,
                                "texto_incierto": inc, "eventos": filas},
                               ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
