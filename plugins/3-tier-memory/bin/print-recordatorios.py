#!/usr/bin/env python3
"""
3-tier-memory plugin: imprime los recordatorios de calendario de un session file para pegarlos en
el cierre de /checkpoint-3t (Step 8c, 2.44.0).

Por que existe: hasta 2.43.0 el agente copiaba a mano los bloques de `## Recordatorios de
calendario` de la ficha. En la ficha el prompt del evento va dentro de un fence ```, y pegado asi
salia en color en la terminal, compitiendo con el snippet. Victor (2026-10-01): solo Retomamos va
en color; el resto, sin color. Quitar el fence a mano es una segunda redaccion, la que
print-como-retomar.py ya elimino para el snippet; este script hace lo mismo con el calendario.

Que hace: lee `## Recordatorios de calendario` de SESSION_FILE, toma los bloques `### FECHA — …`
en su orden y, de los dos primeros, imprime el cuerpo sin las lineas de fence (``` o ````) y sin
los separadores de versiones anteriores (`───…`, `Ponlo en tu calendario:`), con una cabecera
`🗓️ Recordatorio para el FECHA — ponlo en tu calendario:` si el bloque no la trae ya. Si hay mas
de dos, cierra con `+N con fecha futura en _pendientes.md` (la ficha guarda todos). Las lineas
`- p-… ya agendado para …` no son bloques: no se imprimen. Sin seccion o sin bloques, no imprime
nada y sale con 0.

Uso:  print-recordatorios.py SESSION_FILE
"""
# sella-huellas: no (solo lee un session file y lo re-imprime; no escribe nada)
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

EMOJI = "🗓️"
TOPE = 2
FENCE_LINEA = re.compile(r"^\s*(`{3,}|~{3,})\w*\s*$")
LEGADO = re.compile(r"^\s*(─{3}|Ponlo en tu calendario:\s*$)")


def seccion(texto, nombre):
    lineas = texto.splitlines()
    for i, l in enumerate(lineas):
        if l.strip().lower() == "## " + nombre.lower():
            fin = next((j for j in range(i + 1, len(lineas)) if lineas[j].startswith("## ")), len(lineas))
            return lineas[i + 1:fin]
    return None


def bloques(lineas):
    """[(fecha, [lineas del cuerpo])] por cada `### FECHA …`."""
    out = []
    for l in lineas:
        m = re.match(r"^###\s+(\d{4}-\d{2}-\d{2})\b", l)
        if m:
            out.append((m.group(1), []))
        elif out:
            out[-1][1].append(l)
    return out


def main():
    if len(sys.argv) != 2:
        print("uso: print-recordatorios.py SESSION_FILE", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            texto = fh.read()
    except OSError as exc:
        print(f"⚠ print-recordatorios.py: no se pudo leer {sys.argv[1]}: {exc}", file=sys.stderr)
        return 1
    todos = bloques(seccion(texto, "Recordatorios de calendario") or [])
    for n, (fecha, cuerpo) in enumerate(todos[:TOPE]):
        limpio = [l.rstrip() for l in cuerpo if not FENCE_LINEA.match(l) and not LEGADO.match(l)]
        while limpio and not limpio[0].strip():
            limpio.pop(0)
        while limpio and not limpio[-1].strip():
            limpio.pop()
        if n:
            print()
        if not (limpio and limpio[0].startswith(EMOJI)):
            print(f"{EMOJI} Recordatorio para el {fecha} — ponlo en tu calendario:")
            print()
        # Las lineas en blanco seguidas se colapsan a una: el fence quitado dejaba huecos dobles.
        previa_vacia = False
        for l in limpio:
            vacia = not l.strip()
            if not (vacia and previa_vacia):
                print(l)
            previa_vacia = vacia
    if len(todos) > TOPE:
        print()
        print(f"+{len(todos) - TOPE} con fecha futura en _pendientes.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
