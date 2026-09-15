#!/usr/bin/env python3
"""
3-tier-memory plugin: recuerda los planes activos ANTES de que el agente escriba "## Plans:
Ninguno" en un session log (checkpoint-3t Step 3-pre).

Por que existe: un pendiente puede nacer auditando la fase de un plan activo y cerrarse suelto,
sin conectarlo al plan, aunque el propio plan diga "si aparece un hallazgo nuevo, agregalo aqui
como fase nueva en vez de dejarlo suelto" (measured 2026-09-15: le paso exactamente eso a este
mismo repo con p-d72c123065 y plan-hallazgos-piloto-2.25.0 — el agente ejecuto /checkpoint-3t
completo, con la instruccion de planes delante, y aun asi escribio "## Plans: Ninguno" sin
revisar si el pendiente que acababa de cerrar venia de un plan activo). El texto de Step 5 de
checkpoint-3t.md ya cubre "hice trabajo de planeacion nuevo esta sesion" pero nunca pregunta
"lo que cerre esta sesion, ¿pertenece a un plan que YA existe?" — y esa pregunta no se contesta
sola: depende de que el agente se acuerde de mirar, sin que nada se lo recuerde.

Que hace: lee `_plans-index.md`, lista los planes con Status active/draft/testing (incluida la
forma "active (fase de plan-X)"), y los imprime SIEMPRE que existan — no intenta adivinar si
el trabajo de esta sesion se conecta con alguno (eso requeriria seguir cadenas de wikilinks
entre sesiones y planes, fragil y facil de fallar en el otro sentido, falsos negativos). Solo
se asegura de que el agente los vea, en el momento en que los tiene que revisar (justo antes de
Step 3a/Step 5), no que nunca se muestren.

Modos:
  check-active-plans.py <MEMORY_DIR>            texto humano, vacio si no hay planes activos
  check-active-plans.py <MEMORY_DIR> --count     solo el numero (para hooks/otros scripts)
"""
# sella-huellas: no (solo lee memory/_plans-index.md, no escribe nada)
import argparse
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

CELL_SPLIT = re.compile(r"(?<!\\)\|")  # un `\|` dentro de una celda (alias de wikilink) no separa
ACTIVE_STATUSES = ("active", "draft", "testing")


def split_cells(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return [c.strip() for c in CELL_SPLIT.split(s)]


def is_separator(line):
    return re.match(r"^\|\s*:?-+", line.strip()) is not None


def find_active_plans(text):
    """[(titulo, status_completo), ...] para cada fila de '## Plans' cuyo Status empieza con
    active/draft/testing (case-insensitive; el sufijo "(fase de plan-X)" u otro texto no importa
    — se compara solo la PRIMERA palabra del status, igual que hace el resto del plugin al leer
    esta tabla)."""
    lines = text.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.strip().lower() == "## plans")
    except StopIteration:
        return []
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break
    out = []
    in_table = False
    for line in lines[start + 1:end]:
        s = line.strip()
        if not s.startswith("|"):
            continue
        if is_separator(s):
            in_table = True
            continue
        if not in_table:
            continue
        cells = split_cells(s)
        if len(cells) < 2:
            continue
        titulo, status = cells[0], cells[1]
        primera = status.strip().split()[0].lower() if status.strip() else ""
        if primera in ACTIVE_STATUSES:
            out.append((titulo, status))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--count", action="store_true")
    args = ap.parse_args()

    path = os.path.join(args.memory_dir, "_plans-index.md")
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        # El caso normal: un proyecto sin planes registrados todavia, o sin 3-tier-memory. No hay
        # nada que recordar, silencio correcto.
        if args.count:
            print(0)
        return
    except Exception as exc:
        # CUALQUIER OTRO fallo (permisos, decodificacion, es un directorio) NO es "no hay planes"
        # — es "no se pudo mirar", y callarse ahi es exactamente la falla silenciosa que este
        # script existe para evitar (hallazgo de un adversario externo, ronda 2: un `except
        # Exception` unico trataba un fichero corrupto igual que uno inexistente, cero avisos en
        # los dos casos). Se avisa por stderr y --count devuelve un error visible, nunca un 0
        # que se confunda con "sin planes".
        print(f"⚠ check-active-plans.py: no se pudo leer {path}: {exc}", file=sys.stderr)
        if args.count:
            print("ERROR", file=sys.stdout)
        sys.exit(1)

    plans = find_active_plans(text)

    if args.count:
        print(len(plans))
        return

    if not plans:
        return

    print(f"{len(plans)} plan(es) activo(s)/draft/testing en _plans-index.md:")
    for titulo, status in plans:
        limpio = re.sub(r"\[\[([^\]|]+)\\?\|?([^\]]*)\]\]", lambda m: m.group(2) or m.group(1), titulo)
        print(f"  - {limpio} ({status})")
    print("Antes de escribir \"## Plans: Ninguno\" en el session log, confirma que ningun "
          "pendiente que hayas cerrado esta sesion (revisa su _origen -> \"Continuacion de\" -> "
          "plan) es en realidad un hallazgo colateral de alguno de estos — si lo es, agregalo ahi "
          "como fase nueva en vez de dejarlo suelto.")


if __name__ == "__main__":
    main()
