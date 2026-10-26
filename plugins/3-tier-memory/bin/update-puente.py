#!/usr/bin/env python3
"""
3-tier-memory plugin: pone al dia el puente YA instalado (p-6ba77d2ea4). Lo corre session-start.sh.

Por que existe: desde 2.63.47 el puente nuevo manda `/status-3t` + `grep` en vez de leer los
indices Tier 2 enteros (crecen sin limite: 206 KB y 371 KB medidos). Los puentes ya instalados
siguen diciendo "Read `memory/_pendientes.md`" y "Read `memory/_learnings.md`", y el agente los lee
enteros al arrancar cada sesion.

Que toca: SOLO el par de lineas exacto de la plantilla vieja, juntas y en este orden, bajo
`## At session start`:
  1. Read `memory/_pendientes.md` — open action items
  2. Read `memory/_learnings.md` — consult before making changes
Un puente que la persona edito (otro texto en esas lineas, un par separado, una sola linea, otro
idioma) NO se toca ni se avisa: no hay forma segura de saber que quiso decir. Medido en 35 puentes
reales: 27 llevan el par exacto, el resto tiene lineas propias.

Idempotente: con el texto nuevo ya puesto no escribe. Escribe con ficheros temporales + rename y
deja una copia `MEMORY.md.pre-2.64.2` la primera vez. Fail-open: ante cualquier error sale 0 sin
tocar nada (el hook de arranque no puede romperse por esto).

Imprime `ACTUALIZADO` si reescribio, nada en cualquier otro caso. Con --dry-run solo imprime
`ACTUALIZARIA`.

Uso:  update-puente.py RUTA/MEMORY.md [--dry-run]
"""
# sella-huellas: no (reescribe el puente de auto-memoria, que no es un indice con huellas)
import os
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

VIEJO = (
    "1. Read `memory/_pendientes.md` — open action items\n"
    "2. Read `memory/_learnings.md` — consult before making changes\n"
)
NUEVO = (
    "1. Run `/status-3t` — counts of open action items, plus the ones due. Do NOT read "
    "`memory/_pendientes.md` or `memory/_learnings.md` whole: they grow without limit\n"
    "2. Look things up with `grep -i \"<term>\" memory/_pendientes.md memory/_learnings.md` "
    "— consult before making changes\n"
)
COPIA = "MEMORY.md.pre-2.64.2"


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = "--dry-run" in sys.argv[1:]
    if len(args) != 1:
        print("uso: update-puente.py RUTA/MEMORY.md [--dry-run]", file=sys.stderr)
        return 2
    path = args[0]
    try:
        # newline="" conserva los fin de linea tal cual: un puente con CRLF no casa y no se toca.
        with open(path, encoding="utf-8", newline="") as fh:
            texto = fh.read()
        if texto.count(VIEJO) != 1:
            return 0
        if dry:
            print("ACTUALIZARIA")
            return 0
        copia = os.path.join(os.path.dirname(path), COPIA)
        if not os.path.exists(copia):
            with open(copia, "w", encoding="utf-8", newline="") as fh:
                fh.write(texto)
        tmp = path + ".tmp-%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8", newline="") as fh:
            fh.write(texto.replace(VIEJO, NUEVO))
        os.replace(tmp, path)
        print("ACTUALIZADO")
    except Exception as exc:  # fail-open: el arranque no se rompe por el puente
        print("update-puente: %s" % exc, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
