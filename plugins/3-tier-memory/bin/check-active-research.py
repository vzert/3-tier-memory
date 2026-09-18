#!/usr/bin/env python3
"""
3-tier-memory plugin: recuerda las recomendaciones de research SIN RESOLVER antes de que el
agente escriba "## Research: Ninguno" en un session log (checkpoint-3t Step 3-pre).

Por que existe: un research puede producir varias recomendaciones candidatas (p.ej. "auditoria
comparativa: 4 ideas a evaluar, prioridad 1-4") y una sesion solo ejecuta UNA. Sin este check, las
otras N-1 quedan como prosa dentro de un research ya marcado `completed`, sin ninguna fila, campo
ni indice que las vuelva a mostrar — se pierden a menos que alguien recuerde abrir ese archivo
concreto. Medido en este mismo repo, 2026-09-17: `research/openwolf-vs-3tier.md` genero 4 ideas,
se implemento 1, y las otras 3 no tenian ningun rastro mecanico hasta que el usuario lo señalo.

Mismo patron que `check-active-plans.py` (que resuelve el problema analogo para planes): SIEMPRE
que exista una seccion `## Recomendaciones` con al menos un `- [ ]` sin marcar en cualquier
research de `memory/research/`, se imprime, sin intentar adivinar si el trabajo de esta sesion se
conecta con ese research en particular (eso ya le fallo una vez a la version de planes — ver el
comentario de check-active-plans.py). No repara nada, no marca nada: solo se asegura de que el
agente lo vea antes de decidir "## Research: Ninguno".

Convencion que este script lee (documentada en checkpoint-3t.md Step 5): un research con mas de
una recomendacion candidata lleva una seccion propia

    ## Recomendaciones
    - [ ] <idea sin decidir>
    - [x] <idea ya resuelta> — implementada en [[plans/plan-x]]
    - [x] <idea declinada> — declinado: <motivo corto>

Modos:
  check-active-research.py <MEMORY_DIR>            texto humano, vacio si no hay nada sin resolver
  check-active-research.py <MEMORY_DIR> --count     solo el numero de research con items sin marcar
"""
# sella-huellas: no (solo lee memory/research/*.md, no escribe nada)
import argparse
import glob
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

UNCHECKED_RE = re.compile(r"^-\s*\[\s\]\s+(.+)$")
CHECKED_RE = re.compile(r"^-\s*\[[xX]\]\s+(.+)$")


def find_unresolved(text):
    """(total_items, [textos sin marcar]) de la seccion '## Recomendaciones', o (0, []) si no
    existe esa seccion o no tiene items."""
    lines = text.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.strip().lower() == "## recomendaciones")
    except StopIteration:
        return 0, []
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break
    total = 0
    unresolved = []
    for line in lines[start + 1:end]:
        s = line.strip()
        m_un = UNCHECKED_RE.match(s)
        m_ck = CHECKED_RE.match(s)
        if m_un:
            total += 1
            unresolved.append(m_un.group(1).strip())
        elif m_ck:
            total += 1
    return total, unresolved


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--count", action="store_true")
    args = ap.parse_args()

    research_dir = os.path.join(args.memory_dir, "research")
    paths = sorted(glob.glob(os.path.join(research_dir, "*.md")))

    findings = []  # [(ruta_relativa, total, [unresolved])]
    unreadable = []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except Exception as exc:
            # Igual que check-active-plans.py: un fichero que no se pudo leer NO es "sin
            # recomendaciones" -- es "no se pudo mirar", y hay que decirlo, nunca callarlo.
            unreadable.append((path, exc))
            continue
        total, unresolved = find_unresolved(text)
        if unresolved:
            rel = os.path.relpath(path, args.memory_dir)
            findings.append((rel, total, unresolved))

    if unreadable:
        for path, exc in unreadable:
            print(f"⚠ check-active-research.py: no se pudo leer {path}: {exc}", file=sys.stderr)
        if args.count:
            print("ERROR")
            sys.exit(1)

    if args.count:
        print(len(findings))
        return

    if not findings:
        return

    n_total = sum(len(u) for _, _, u in findings)
    print(f"{len(findings)} research con {n_total} recomendacion(es) sin resolver:")
    for rel, total, unresolved in findings:
        # `rel` ya es relativo a memory_dir (p.ej. "research/openwolf-vs-3tier.md"): NO anteponer
        # "research/" otra vez -- ese doble prefijo lo encontro este mismo script en su primera
        # corrida real (2026-09-17), antes de que lo corriera el adversario.
        slug = rel[:-3] if rel.endswith(".md") else rel
        print(f"  - {slug} ({len(unresolved)} de {total} sin decidir):")
        for item in unresolved:
            print(f"      - {item}")
    print("Antes de escribir \"## Research: Ninguno\" en el session log, confirma que ninguna de "
          "estas recomendaciones se resolvio (implementada, declinada, o diferida explicitamente) "
          "en esta sesion. Step 8 arma el prompt de retomarlas con print-research-recomendaciones.py.")


if __name__ == "__main__":
    main()
