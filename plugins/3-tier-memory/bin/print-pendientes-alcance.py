#!/usr/bin/env python3
"""
3-tier-memory plugin: imprime SOLO los pendientes del alcance de checkpoint-3t Step 3a, en vez de
mandar al agente a leer `_pendientes.md` entero (p-206fd62e68).

Por que existe: Step 3-pre decia "THEN read `memory/_pendientes.md`". Con un backlog real eso son
200-370 KB en contexto en cada cierre (medido 2026-10-21: proyecto-edge 206 KB con 217 abiertos,
paperclip 371 KB), y el alcance obligatorio de 3a es cerrado: los pendientes que la sesion toco y los
que traen `_revisar` vencida o de hoy. Lo demas solo se cuenta. Este script imprime exactamente eso.

Que imprime (stdout):
  ABIERTOS=N VENCIDOS=V TOCADOS=T
  y una linea por pendiente del alcance:
  <id> | <Alta|Media|Baja> | creado <fecha> | revisar <fecha|-> | <motivo> | <texto recortado>

  motivo: `vencido` (_revisar < hoy), `hoy` (_revisar == hoy) o `tocado` (id dado con --ids).
  Un id pedido que no esta abierto sale como `<id> | no-abierto` (cerrado o inexistente): el agente
  lo ve en vez de creer que se reviso.

El texto se recorta a --max caracteres (200 por defecto) y la linea lo dice (`…[+N]`). El detalle
completo vive en `memory/pendientes/YYYY-MM.md` (Tier 3); `grep <id>` lo trae. Nada se decide
leyendo el texto: todo sale de campos estructurados (regla 216).

Uso:  print-pendientes-alcance.py MEMORY_DIR [--ids p-a,p-b] [--hoy YYYY-MM-DD] [--max N]
"""
# sella-huellas: no (solo lee _pendientes.md; no escribe nada)
import datetime
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

# Identicas a print-pendiente-opcional.py (mismo formato de linea, dos lectores: regla 143/148).
ID = re.compile(r"_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
CREADO = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
METADATO = re.compile(r"\s+—\s+_[a-z]+:")
MAX_DEFECTO = 200


def abiertos(path):
    """[(id, prioridad, creado, revisar|None, texto)] de las lineas `- [ ]` con `_id:`."""
    out, prio = [], "?"
    with open(path, encoding="utf-8") as fh:
        for l in fh:
            s = l.strip()
            m_h = re.match(r"^##\s+(alta|media|baja)\b", s, re.I)
            if m_h:
                prio = m_h.group(1).capitalize()
                continue
            if not s.startswith("- [ ]"):
                continue
            m_id = ID.search(s)
            if not m_id:
                continue
            rev, cre = REVISAR.search(s), CREADO.search(s)
            texto = METADATO.split(s[5:].strip(), 1)[0].strip()
            out.append((m_id.group(1), prio, cre.group(1) if cre else "-",
                        rev.group(1) if rev else None, texto))
    return out


def recorta(texto, tope):
    if len(texto) <= tope:
        return texto
    return f"{texto[:tope].rstrip()}…[+{len(texto) - tope}]"


def main():
    args = sys.argv[1:]
    hoy, ids, tope = datetime.date.today().isoformat(), [], MAX_DEFECTO
    try:
        while "--hoy" in args:
            i = args.index("--hoy")
            hoy = args[i + 1]
            del args[i:i + 2]
        while "--ids" in args:
            i = args.index("--ids")
            ids += [x.strip() for x in args[i + 1].split(",") if x.strip()]
            del args[i:i + 2]
        while "--max" in args:
            i = args.index("--max")
            tope = int(args[i + 1])
            del args[i:i + 2]
    except (IndexError, ValueError):
        args = []
    try:
        datetime.date.fromisoformat(hoy)
    except ValueError:
        args = []
    if len(args) != 1:
        print("uso: print-pendientes-alcance.py MEMORY_DIR [--ids p-a,p-b] [--hoy YYYY-MM-DD] "
              "[--max N]", file=sys.stderr)
        return 2
    path = os.path.join(args[0], "_pendientes.md")
    try:
        todos = abiertos(path)
    except OSError as exc:
        print(f"⚠ print-pendientes-alcance.py: {exc}", file=sys.stderr)
        return 1

    por_id = {p[0]: p for p in todos}
    vistos, filas = set(), []
    for p in todos:
        if p[3] and p[3] < hoy:
            filas.append((p, "vencido"))
        elif p[3] == hoy:
            filas.append((p, "hoy"))
        else:
            continue
        vistos.add(p[0])
    vencidos = len(filas)
    tocados = 0
    for pid in ids:
        if pid in vistos:
            continue
        vistos.add(pid)
        tocados += 1
        filas.append((por_id.get(pid) or pid, "tocado"))

    print(f"ABIERTOS={len(todos)} VENCIDOS={vencidos} TOCADOS={tocados}")
    for p, motivo in filas:
        if isinstance(p, str):
            print(f"{p} | no-abierto")
            continue
        pid, prio, creado, rev, texto = p
        print(f"{pid} | {prio} | creado {creado} | revisar {rev or '-'} | {motivo} | "
              f"{recorta(texto, tope)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
