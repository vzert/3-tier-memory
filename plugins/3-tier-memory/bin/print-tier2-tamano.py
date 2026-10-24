#!/usr/bin/env python3
"""
3-tier-memory plugin: mide el tamano de los indices Tier 2 y avisa de los que crecieron de mas
(p-206fd62e68). Lo usa /status-3t en lugar de leer cada indice entero.

Por que existe: los indices no tienen limite (medido 2026-10-21: `_pendientes.md` 206 KB y 371 KB,
`_learnings.md` 71 KB y 461 KB, `_research-index.md` 39 KB). El agente no tenia forma de enterarse
sin leerlos, que es justo lo que hay que evitar.

Imprime una linea por indice que exista:
  <fichero> bytes=N lineas=L largas=K[ GRANDE]
`largas` cuenta las lineas de mas de --largas caracteres (800 por defecto). `GRANDE` sale cuando el
fichero pasa --grande bytes (60000 por defecto) o tiene alguna linea larga: el aviso para recortar
(`/triage-3t`, titulo corto en Tier 2, detalle en Tier 3). Solo mide; no escribe nada.

Uso:  print-tier2-tamano.py MEMORY_DIR [--grande BYTES] [--largas CHARS]
"""
# sella-huellas: no (solo mide ficheros; no escribe nada)
import os
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

INDICES = ("_pendientes.md", "_learnings.md", "_research-index.md", "_plans-index.md",
           "_session-index.md")


def medir(path, largas):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lineas = fh.read().splitlines()
    return os.path.getsize(path), len(lineas), sum(1 for l in lineas if len(l) > largas)


def main():
    args = sys.argv[1:]
    grande, largas = 60000, 800
    try:
        for flag in ("--grande", "--largas"):
            while flag in args:
                i = args.index(flag)
                v = int(args[i + 1])
                if flag == "--grande":
                    grande = v
                else:
                    largas = v
                del args[i:i + 2]
    except (IndexError, ValueError):
        args = []
    if len(args) != 1:
        print("uso: print-tier2-tamano.py MEMORY_DIR [--grande BYTES] [--largas CHARS]",
              file=sys.stderr)
        return 2
    for nombre in INDICES:
        path = os.path.join(args[0], nombre)
        if not os.path.isfile(path):
            continue
        try:
            n, l, k = medir(path, largas)
        except OSError as exc:
            print(f"⚠ print-tier2-tamano.py: {nombre}: {exc}", file=sys.stderr)
            return 1
        marca = " GRANDE" if (n > grande or k) else ""
        print(f"{nombre} bytes={n} lineas={l} largas={k}{marca}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
