#!/usr/bin/env python3
"""Replay de los avisos B (hilo_sin_reconciliar) y D (pregunta en prosa) de 2.64.0 sobre transcripts
reales, para medir cuantos cierres avisarian. Solo lectura.

Uso:  tools/replay-avisos-pendiente.py MEMORY_DIR CARPETA_DE_TRANSCRIPTS [N]
  MEMORY_DIR            el memory/ del proyecto (usa su _pendientes.md de HOY, no el de entonces)
  CARPETA_DE_TRANSCRIPTS  ~/.claude/projects/<ruta con - en vez de no alfanumericos>
  N                     los N transcripts mas recientes (por defecto 60)
Imprime: cuantos de los N traen /checkpoint-3t, cuantos disparan B y D, y cada caso con su sesion.

Limites: el _pendientes.md es el de hoy (un pendiente cerrado desde entonces no cuenta), y D mira el
ULTIMO texto del asistente de la sesion, no la ventana del primer Stop que mira el hook.
"""
import glob
import importlib.util
import json
import os
import re
import sys

for _f in (sys.stdout, sys.stderr):
    if hasattr(_f, "reconfigure"):
        _f.reconfigure(encoding="utf-8")

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plugins", "3-tier-memory", "bin")


def carga(nombre):
    spec = importlib.util.spec_from_file_location(nombre, os.path.join(BIN, nombre + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mem, carpeta = sys.argv[1], sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    pa, af = carga("paso_ajeno"), carga("pendientes_afines")
    pend = af.pendientes(os.path.join(mem, "_pendientes.md"))
    fs = sorted(glob.glob(os.path.join(carpeta, "*.jsonl")), key=os.path.getmtime)[-n:]
    src = open(os.path.join(BIN, "checkpoint-close-guard.sh"), encoding="utf-8").read()
    m = re.search(r"(def pregunta_final\(texto\):.*?)\n\n\ndef exigidas", src, re.S)
    ns = {"re": re, "EMOJIS": ("🔁", "🔔", "➕", "🗓️")}
    exec(m.group(1), ns)
    cierres = b = d = 0
    for f in fs:
        regs = [json.loads(l) for l in open(f, encoding="utf-8", errors="replace") if l.strip().startswith("{")]
        if not any(pa._es_checkpoint(r) for r in regs):
            continue
        cierres += 1
        sin = pa.hilos_sin_reconciliar(f, pend, None)
        if sin:
            b += 1
            print("B", os.path.basename(f)[:8], sin[:2])
        ult = ""
        for r in regs:
            if r.get("type") == "assistant":
                t = "\n".join(x.get("text", "") for x in pa._bloques(r) if x.get("type") == "text")
                if t.strip():
                    ult = t
        q = ns["pregunta_final"](ult)
        if q:
            d += 1
            print("D", os.path.basename(f)[:8], q[-120:])
    print(f"transcripts con /checkpoint-3t: {cierres} de {len(fs)}; B: {b}; D: {d}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
