#!/usr/bin/env python3
"""
3-tier-memory plugin (2.55.0): el SIGUIENTE plan hermano cuando un hijo cierra.

Por que existe: la regla de "subir en el arbol al cerrar un hijo" (checkpoint-3t.md, Step 5,
pasos 1-4; Step 8 caso 1) existe desde 2.25.1 pero solo en prosa: el agente tenia que cruzar a
mano las anotaciones `(fase de plan-<padre>)` de `_plans-index.md` con la tabla `## Sub-planes`
del padre. Medido el 2026-10-13: 0 tablas `## Sub-planes` y 0 hijos reales en este repo, o sea
que nunca se ejercito. Este script hace ese cruce de forma mecanica.

Que hace, dado el slug de un plan (normalmente el hijo que esta sesion cerro):
  1. Busca su padre en la anotacion `(fase de plan-<padre>)` de su fila del indice.
  2. Junta los hermanos ABIERTOS (`active` o `draft`) por el indice — el indice manda, no la
     tabla (Step 5, paso 2).
  3. Los ordena por las filas de `## Sub-planes` del padre (la fila mas arriba sigue). Un hermano
     abierto que no esta en la tabla va al final y se dice.
Imprime una linea por resultado; la primera es la que va al `<next-step>`:
  SIGUIENTE plan-<slug> (<status>) — hermano en plan-<padre>
  SIN-ORDEN plan-<padre>: N hijos abiertos sin orden declarado en ## Sub-planes — <slugs>
  NINGUNO plan-<padre>: no quedan hijos abiertos — evalua cerrar el padre (Step 5, paso 4)
  SIN-PADRE plan-<slug>: no tiene `(fase de plan-…)` en el indice
Sale 0 en todos esos casos; 1 si falta el indice o el plan.

Uso:  plan-siguiente-hermano.py --memory-dir DIR --plan SLUG   (con o sin el prefijo `plan-`)
"""
# sella-huellas: no (solo lee _plans-index.md y el fichero del padre; no escribe nada)
import argparse
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

FILA = re.compile(r"^\|\s*\[\[plans/plan-([A-Za-z0-9][A-Za-z0-9._-]*?)(?:\\?\|[^\]]*)?\]\]\s*\|\s*([^|]*?)\s*\|")
PADRE = re.compile(r"\(fase de plan-([A-Za-z0-9._-]+)\)")
ABIERTO = ("active", "draft")


def filas(index_path):
    """{slug: status_cell} del indice (la primera fila de cada slug)."""
    out = {}
    with open(index_path, encoding="utf-8") as fh:
        for l in fh:
            m = FILA.match(l.strip())
            if m and m.group(1) not in out:
                out[m.group(1)] = m.group(2)
    return out


def estado(cell):
    return PADRE.sub("", cell).strip().split()[0].lower() if cell.strip() else ""


def orden_subplanes(plan_path):
    """Slugs en el orden de las filas de `## Sub-planes` del padre ([] si no hay tabla)."""
    if not os.path.isfile(plan_path):
        return []
    with open(plan_path, encoding="utf-8") as fh:
        texto = fh.read()
    m = re.search(r"^## Sub-planes[^\n]*\n(.*?)(?=^## |\Z)", texto, re.M | re.S)
    if not m:
        return []
    out = []
    for l in m.group(1).splitlines():
        if not l.strip().startswith("|"):
            continue
        celda = l.strip().strip("|").split("|")[0]
        s = re.search(r"plan-([A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])", celda)
        if s and s.group(1) not in out:
            out.append(s.group(1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--memory-dir", required=True)
    ap.add_argument("--plan", required=True)
    a = ap.parse_args()
    slug = re.sub(r"^plan-", "", a.plan.strip())
    index_path = os.path.join(a.memory_dir, "_plans-index.md")
    if not os.path.isfile(index_path):
        print(f"⚠ plan-siguiente-hermano.py: no existe {index_path}", file=sys.stderr)
        return 1
    idx = filas(index_path)
    if slug not in idx:
        print(f"⚠ plan-siguiente-hermano.py: plan-{slug} no tiene fila en _plans-index.md",
              file=sys.stderr)
        return 1
    m = PADRE.search(idx[slug])
    if not m:
        print(f"SIN-PADRE plan-{slug}: no tiene `(fase de plan-…)` en el indice")
        return 0
    padre = m.group(1)
    abiertos = [s for s, c in idx.items()
                if s != slug and PADRE.search(c) and PADRE.search(c).group(1) == padre
                and estado(c) in ABIERTO]
    if not abiertos:
        print(f"NINGUNO plan-{padre}: no quedan hijos abiertos — evalua cerrar el padre "
              f"(Step 5, paso 4)")
        return 0
    orden = orden_subplanes(os.path.join(a.memory_dir, "plans", f"plan-{padre}.md"))
    en_tabla = [s for s in orden if s in abiertos]
    fuera = sorted(s for s in abiertos if s not in en_tabla)
    if not en_tabla and len(fuera) > 1:
        print(f"SIN-ORDEN plan-{padre}: {len(fuera)} hijos abiertos sin orden declarado en "
              f"## Sub-planes — " + ", ".join(f"plan-{s}" for s in fuera))
        return 0
    for s in en_tabla + fuera:
        nota = "" if s in en_tabla else " (no esta en ## Sub-planes del padre: agregalo)"
        print(f"SIGUIENTE plan-{s} ({estado(idx[s])}) — hermano en plan-{padre}{nota}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
