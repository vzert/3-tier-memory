#!/usr/bin/env python3
"""Replay del aviso B (hilo_sin_reconciliar) con la regla por id nombrado de 2.65.0. Solo lectura.

Uso:
  tools/replay-aviso-b-id-nombrado.py MEMORY_DIR CARPETA_DE_TRANSCRIPTS [N]
      los N transcripts mas recientes con /checkpoint-3t (por defecto 200): cuantos cierres avisan, y
      cuantos solo por la regla nueva (el grupo no habria avisado sin ella)
  tools/replay-aviso-b-id-nombrado.py --uno PENDIENTES_MD TRANSCRIPT
      un solo transcript contra un _pendientes.md dado (p. ej. el de un commit anterior, para
      reproducir un incidente con los datos de ese momento): imprime los grupos y sus ids

La ficha propia sale del ultimo `session.add --slug` literal del transcript (sin ella, la sesion
avisaria de sus propios pendientes). Una ficha de un cierre ANTERIOR de la misma sesion cuenta como
ajena, igual que en la auditoria real. Limite: en el modo de carpeta el _pendientes.md es el de hoy; un pendiente cerrado
desde entonces no cuenta, asi que las cifras son un minimo.
"""
import glob
import importlib.util
import os
import re
import sys

for _f in (sys.stdout, sys.stderr):
    if hasattr(_f, "reconfigure"):
        _f.reconfigure(encoding="utf-8")

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plugins", "3-tier-memory", "bin")
SLUG = re.compile(r"--type[\s=]+session\.add\b.*?--slug[\s=]+[\"']?([\w.-]+)")


def carga(nombre):
    spec = importlib.util.spec_from_file_location(nombre, os.path.join(BIN, nombre + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


pa, af = carga("paso_ajeno"), carga("pendientes_afines")


def ficha_propia(regs):
    """La ficha del ULTIMO `session.add` con slug literal: es la del cierre que la auditoria revisa (una
    sesion larga puede cerrar varias veces; un `$S` o un placeholder no cuentan)."""
    ultima = None
    for r in regs:
        if r.get("type") != "assistant":
            continue
        for b in pa._bloques(r):
            if b.get("type") == "tool_use" and b.get("name") == "Bash":
                for m in SLUG.finditer(str((b.get("input") or {}).get("command", ""))):
                    if re.match(r"\d{4}-\d{2}-\d{2}-", m.group(1)):
                        ultima = "memory/sessions/" + m.group(1) + ".md"
    return ultima


def solo_grupo(transcript, pend, propia):
    """Lo que avisaria la regla de grupo sola (sin la regla por id nombrado)."""
    src = open(os.path.join(BIN, "paso_ajeno.py"), encoding="utf-8").read()
    if src.count("        if sueltos:") != 1:
        raise SystemExit("replay: no hallo la regla por id nombrado en paso_ajeno.py")
    ns = {"__name__": "paso_ajeno_grupo"}
    exec(compile(src.replace("        if sueltos:", "        if False:"), "paso_ajeno_grupo", "exec"), ns)
    return ns["hilos_sin_reconciliar"](transcript, pend, propia)


def main():
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "--uno":
        pend = af.pendientes(a[1])
        regs = [r for _, r in pa._registros(a[2])]
        propia = ficha_propia(regs)
        print("ficha propia:", propia)
        print("con la regla nueva:", pa.hilos_sin_reconciliar(a[2], pend, propia))
        print("solo regla de grupo:", solo_grupo(a[2], pend, propia))
        return 0
    if len(a) < 2:
        print(__doc__)
        return 2
    mem, carpeta = a[0], a[1]
    n = int(a[2]) if len(a) > 2 else 200
    pend = af.pendientes(os.path.join(mem, "_pendientes.md"))
    fs = sorted(glob.glob(os.path.join(carpeta, "*.jsonl")), key=os.path.getmtime)[-n:]
    cierres = avisa = nueva = 0
    for f in fs:
        regs = [r for _, r in pa._registros(f)]
        if not any(pa._es_checkpoint(r) for r in regs):
            continue
        cierres += 1
        propia = ficha_propia(regs)
        con = dict(pa.hilos_sin_reconciliar(f, pend, propia) or [])
        if not con:
            continue
        avisa += 1
        sin = dict(solo_grupo(f, pend, propia) or [])
        extra = {g: ids for g, ids in con.items() if g not in sin}
        if extra:
            nueva += 1
            print("  nueva", os.path.basename(f)[:8], extra)
    print(f"cierres {cierres} de {len(fs)}; avisa B: {avisa}; solo por la regla nueva: {nueva}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
