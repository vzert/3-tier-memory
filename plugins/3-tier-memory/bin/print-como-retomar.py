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
excepcion), la imprime en una sola linea con el emoji del bloque. Si es un bloque de codigo (el
snippet de 6 lineas, con o sin condicionales), imprime una cabecera con el emoji y el snippet
DENTRO de un fence ``` (2.44.0): pegado en la respuesta, el fence es lo que sale en color, y es el
unico bloque del cierre que va en color (Victor lo comprobo el 2026-10-01). Sin separadores ni
texto de introduccion: el emoji marca donde empieza el bloque.
Extras (2.55.0; la regla de hoy es la del hilo, abajo): si el snippet es un bloque y su
`Proximo paso:` cita un `p-…` o un `plan-…`, mete justo debajo una linea `Si ese paso es corto,
suma en la misma sesion: …` con hasta 2 pendientes del hilo. Se calcula EN VIVO desde
`_pendientes.md`, igual que el bloque de Step 8e: no se guarda en la ficha, y el hook de cierre,
que vuelve a correr este script, compara contra el estado real. Si la ficha ya trae esa linea
(escrita a mano), no se duplica.
Hilo (2.57.0, p-b282a8cfc4; de un salto desde 2.62.0): lo que la sesion recibio, sellado por
stamp-hilo.py; lo que nacio en ella; y sus vecinos DIRECTOS por `_relacionado`, solo por ids
abiertos (el cierre transitivo de 2.57.0 cruzaba al trabajo de otro agente). En 2.55.0 los extras
salian solo de `_relacionado`. Debajo va `quedan N en el hilo: <ids>` con lo que no entro. Ver
pendientes_afines.py, "El hilo".
Si la seccion esta vacia o dice solo el placeholder (`<filled in Step 8>`), no imprime nada y
sale con codigo 1 — Step 8a todavia no corrio.

Uso:  print-como-retomar.py SESSION_FILE
"""
# sella-huellas: no (solo lee un session file y lo re-imprime; no escribe nada)
import importlib.util
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

# Un emoji por tipo de bloque del cierre (2.44.0, elegidos por Victor): 🔁 retomar, 🔔 vence hoy y
# ➕ opcional (print-pendiente-opcional.py), 🗓️ calendario (print-recordatorios.py).
CABECERA = "🔁 Siguiente sesión — copia y pega:"
LINEA_CASO5 = "🔁 Como retomar:"
FENCE = "```"


def es_caso5(body):
    """El snippet colapsado del caso 5: `## Como retomar` lleno y SIN bloque de codigo. Lo usa
    tambien print-pendiente-opcional.py para decidir la capa opcional: un solo detector."""
    return bool(body) and body != "<filled in Step 8>" and not FENCE_RE.match(body)


FENCE_RE = re.compile(r"^```(?:markdown)?\s*\n([\s\S]*?)\n```\s*$")


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


AFINES_PREFIJO = "Si ese paso es corto, suma"


def _afines():
    """pendientes_afines.py, junto a este script (por ruta: con `python3 -I` el directorio del
    script no esta en sys.path)."""
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pendientes_afines.py")
    spec = importlib.util.spec_from_file_location("pendientes_afines", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def con_afines(inner, text, path):
    """`inner` con la linea de afines metida tras `Proximo paso:` (y su linea en blanco)."""
    if AFINES_PREFIJO.lower() in inner.lower() or re.search(r"(?im)^quedan\s+\d+\s+en\s+el\s+hilo",
                                                              inner):
        return inner
    memory_dir = os.path.dirname(os.path.dirname(os.path.abspath(path)))
    slug = os.path.splitext(os.path.basename(path))[0]
    try:
        linea = _afines().linea_snippet(text, os.path.join(memory_dir, "_pendientes.md"),
                                        slug=slug)
    except (OSError, UnicodeDecodeError) as exc:
        print(f"⚠ print-como-retomar.py: afines no calculados ({exc})", file=sys.stderr)
        return inner
    if not linea:
        return inner
    lines = inner.split("\n")
    for i, l in enumerate(lines):
        if l.strip().strip("*").strip().lower().startswith(("proximo paso:", "próximo paso:")):
            return "\n".join(lines[:i + 1] + ["", linea] + lines[i + 1:])
    return inner


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

    fence = FENCE_RE.match(body)
    if fence:
        inner = con_afines(fence.group(1).strip("\n"), text, path)
        print(CABECERA)
        print(FENCE)
        print(inner)
        print(FENCE)
        return 0

    # forma de una linea: "Ninguno — <media-linea>." (caso 5, sin excepcion).
    # El markdown de origen a veces envuelve esta "una linea" en varios renglones fisicos (editor,
    # o una sesion anterior a esta convencion) — colapsar a una sola linea real antes de imprimir,
    # o "Como retomar: " queda pegado al primer renglon y el resto sale suelto debajo, partido.
    print(f"{LINEA_CASO5} {' '.join(body.split())}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
