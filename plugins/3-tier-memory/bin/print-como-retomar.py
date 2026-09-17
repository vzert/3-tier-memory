#!/usr/bin/env python3
"""
3-tier-memory plugin: imprime el bloque `## Como retomar` de un session file tal cual quedo
escrito, para que el agente lo pegue en la terminal (checkpoint-3t Step 8b) sin volver a
redactarlo.

Por que existe: Step 8a escribe el snippet en el session file; Step 8b pide imprimir EL MISMO
bloque en la terminal, con separadores visuales, para que el usuario lo copie. Son dos pasos
separados sobre el mismo contenido — y ese es justo el hueco: medido en vivo (2026-09-15, este
mismo repo), el agente que acababa de escribir el bloque en 8a, en el turno siguiente, no lo
repitio — escribio su propio resumen en prosa en su lugar. No fue un olvido de memoria: fue
sustituir un formato exigido por una sintesis propia, bajo la idea de que "un resumen mejor
redactado" era mas util. Dos redacciones independientes del mismo contenido son dos oportunidades
de divergir o de saltarse una.

Este script no compara 8a contra 8b (un comparador a mano es un proxy fragil — measured en este
mismo repo con el contador de backfill, diverge justo donde importa). En vez de eso ELIMINA la
segunda redaccion: 8b deja de ser "escribe el bloque otra vez" y pasa a ser "corre este script y
pega su salida tal cual". Solo hay una fuente de verdad (el session file); este script la
transforma mecanicamente al formato de terminal, nunca la reinterpreta.

Que hace: lee la seccion `## Como retomar` de SESSION_FILE (entre ese encabezado y el siguiente
`## `). Si es la forma de una linea (`Ninguno — ...`, sin bloque de codigo — caso 5, sin
excepcion), la imprime con el formato de linea unica que Step 8b ya define (sin separadores,
para pegar dentro del reporte de Step 7). Si es un bloque de codigo (el snippet de 6 lineas, con
o sin condicionales), la imprime completa con los separadores visuales de Step 8b.
Si la seccion esta vacia o dice solo el placeholder (`<filled in Step 8>`), no imprime nada y
sale con codigo 1 — Step 8a todavia no corrio.

Uso:  print-como-retomar.py SESSION_FILE
"""
# sella-huellas: no (solo lee un session file y lo re-imprime; no escribe nada)
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

SEP_TOP = "─── ¿Como retomar en la siguiente sesion? ───"
SEP_BOTTOM = "─────────────────────────────────────────────"
INTRO = "Copia y pega esto al iniciar una nueva sesion de Claude Code:"


def extract_section(text):
    lines = text.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.strip().lower() == "## como retomar")
    except StopIteration:
        return None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break
    body = "\n".join(lines[start + 1:end]).strip("\n")
    return body


def main():
    if len(sys.argv) != 2:
        print("uso: print-como-retomar.py SESSION_FILE", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"⚠ print-como-retomar.py: no se pudo leer {path}: {exc}", file=sys.stderr)
        return 1

    body = extract_section(text)
    if body is None:
        print(f"⚠ print-como-retomar.py: {path} no tiene seccion '## Como retomar'.", file=sys.stderr)
        return 1
    if not body or body == "<filled in Step 8>":
        print("⚠ print-como-retomar.py: Step 8a todavia no lleno esta seccion.", file=sys.stderr)
        return 1

    fence = re.match(r"^```(?:markdown)?\s*\n([\s\S]*?)\n```\s*$", body)
    if fence:
        inner = fence.group(1).strip("\n")
        print(SEP_TOP)
        print(INTRO)
        print()
        print(inner)
        print(SEP_BOTTOM)
        return 0

    # forma de una linea: "Ninguno — <media-linea>." (caso 5 sin pendiente Alta que agregar).
    # El markdown de origen a veces envuelve esta "una linea" en varios renglones fisicos (editor,
    # o una sesion anterior a esta convencion) — colapsar a una sola linea real antes de imprimir,
    # o "Como retomar: " queda pegado al primer renglon y el resto sale suelto debajo, partido.
    print(f"Como retomar: {' '.join(body.split())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
