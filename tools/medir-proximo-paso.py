#!/usr/bin/env python3
"""Mide `snippet.proximo_paso` (checkpoint-audit.py, 2.33.0) sobre las fichas de una memoria real.

Uso: tools/medir-proximo-paso.py <MEMORY_DIR> [DESDE YYYY-MM-DD]

Imprime cuantas fichas dan HECHO/SALTADO y el desglose por motivo. OJO al leerlo: es una medicion
RETROACTIVA contra el `_pendientes.md` de HOY. Un id "no esta abierto" puede ser dos cosas, y se
separan mirando la historia de la propia memoria (pendientes/*.md, que nunca se borra):
  - `cerrado despues`: el id tiene fila en la historia con una fecha de cierre IGUAL O POSTERIOR a
    la ficha — en el cierre real estaba abierto (artefacto de medir hacia atras);
  - `ya cerrado`: la fecha de cierre es ANTERIOR a la ficha, o la fila no trae fecha de cierre —
    no se puede afirmar que estuviera abierto; se cuenta como defecto posible, no como artefacto;
  - `desconocido aqui`: el id no aparece en ninguna parte de esta memoria (un id de otra
    instalacion, o inventado). Eso SI es un defecto del snippet, no un artefacto.
"""
import collections, glob, json, os, re, subprocess, sys

mem = sys.argv[1]
desde = sys.argv[2] if len(sys.argv) > 2 else "0000"
aud = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "plugins", "3-tier-memory",
                   "bin", "checkpoint-audit.py")
fichas = sorted(f for f in glob.glob(os.path.join(mem, "sessions", "*.md"))
                if os.path.basename(f) >= desde)
historia = [l for p in sorted(glob.glob(os.path.join(mem, "pendientes", "*.md")))
            for l in open(p, encoding="utf-8").read().splitlines() if l.lstrip().startswith("|")]


def clase_cerrado(pid, fecha_ficha):
    filas = [l for l in historia if pid in l]
    if not filas:
        return "no esta abierto: desconocido aqui"
    fechas = re.findall(r"\d{4}-\d{2}-\d{2}", filas[-1])
    # La ULTIMA fecha de la fila es la de cierre (Resuelto va despues de Creado); con una sola
    # fecha no hay cierre registrado.
    if len(fechas) >= 2 and fechas[-1] >= fecha_ficha:
        return "no esta abierto: cerrado despues"
    return "no esta abierto: ya cerrado"
estado, motivo, retro_solo = collections.Counter(), collections.Counter(), 0
for f in fichas:
    r = subprocess.run([sys.executable, aud, mem, "--session-file", f, "--solo-snippet", "--json"],
                       capture_output=True, text=True)
    for x in json.loads(r.stdout or "[]"):
        if x["clave"] != "snippet.proximo_paso":
            continue
        estado[x["estado"]] += 1
        ms = set()
        for l in x["lineas"] or [x["detalle"]]:
            m_id = re.match(r"(p-[0-9a-f]{10}) no esta abierto", l)
            if m_id:
                ms.add(clase_cerrado(m_id.group(1), os.path.basename(f)[:10]))
            else:
                ms.add(re.sub(r"p-[0-9a-f]{10}", "p-…", l).split(":")[0][:48])
        if x["estado"] == "SALTADO":
            for m in ms:
                motivo[m] += 1
            if all(m == "no esta abierto: cerrado despues" for m in ms):
                retro_solo += 1
print(f"fichas={len(fichas)} " + " ".join(f"{k}={v}" for k, v in sorted(estado.items())))
print(f"SALTADO solo por ids cerrados despues (artefacto retroactivo): {retro_solo}")
for m, n in motivo.most_common():
    print(f"  {n:>3}  {m}")
