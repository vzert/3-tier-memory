#!/usr/bin/env python3
"""Caduca los pendientes que dejaron de ser un compromiso.

DOS MODOS, Y EL BUENO ES EL PRIMERO
    --modo revisar (DEFECTO)  el item declaro su ventana con `_revisar: FECHA` y la fecha paso.
    --modo edad               el item lleva mas de --days dias. **MEDIDO Y DESCARTADO**: sobre una
                              muestra leida de 30 candidatos a N=90, **29 de 30 (97%)** seguian
                              siendo compromisos vivos bajo la rubrica congelada — 19 de 30 solo
                              si se acepta un codigo anadido tras ver los resultados. La edad no
                              discrimina porque este backlog es
                              trabajo real sin priorizar, no basura. El modo se conserva para
                              inspeccion con --dry-run; no se recomienda aplicarlo.

QUE AFIRMA Y QUE NO
    Archivar NO afirma "esto ya se hizo" — afirma "esto dejo de ser un compromiso".
    Esa distincion es la razon de que este mecanismo pueda automatizarse y M2 (cierre
    por silencio) no: M2 tenia que adivinar si el trabajo salio bien (8.6% de precision
    medido); esto solo mira una fecha.

POR QUE LA FECHA BASTA (medido 2026-09-11 sobre las 5 instalaciones locales)
    De 347 cierres historicos con las dos fechas: mediana 0 dias, 76% en <=1 dia,
    88% en <=7 dias, 93% en <=30. Los abiertos de hoy tienen edad mediana 58 dias:
    estan fuera de la ventana en la que ocurre practicamente todo cierre.

    Tasa de cierre tardio (LIMITE INFERIOR del arrepentimiento, no la tasa de error):
    se calcula sobre items que SI cerraron, no sobre los que este script archivaria.
      N=30 -> 6.8% | N=45 -> 2.3% | N=60 -> 2.0% | N=90 -> 1.7% | N=120 -> 1.7%
    La curva se aplana a partir de 45. El default es 90 por margen, no porque 90 sea optimo.

    Leidos los 8 cierres de mas de 45 dias: 2 cerraron como "moot"/"sin accion" (archivar
    habria sido correcto) y 3 eran "verificar X en sesion de dev real" — items que esperan
    un evento externo. Esos son exactamente los que la valvula `_revisar:` protege.

LO QUE ESTE SCRIPT NO PUEDE DECIDIR
    Si el item es trabajo real o una nota. En la muestra medida de 40 items de clase C,
    62% eran tareas reales diferidas. Este script NO las distingue y no lo intenta:
    clasificar un pendiente por su texto con un regex ya fallo tres veces (reglas 93 y 102).
    Por eso archiva, no borra, y por eso existe `--revertir`.

USO
    expire-pendientes.py [--memory-dir DIR] [--days 90]      # dry-run: no escribe nada
    expire-pendientes.py --apply
    expire-pendientes.py --revertir p-xxxxxxxxxx [--apply]

    Emite eventos al journal; NUNCA edita memory/ directamente (regla de un solo escritor).
    El compactador aplica: saca la linea de _pendientes.md, la guarda VERBATIM en
    pendientes/_caducados.md y marca la fila mensual como `expired`.

EXCLUSIONES (se cuentan y se imprimen; no se archivan)
    - sin `_creado:`            -> no se puede saber la edad
    - `_revisar:` en el futuro  -> el item declara su propia ventana y aun no vence
    - `_no-caduca_`             -> marca explicita del usuario
"""
# sella-huellas: no (emite eventos con journal-emit; el compactador escribe y sella)
import argparse
import os
import re
import subprocess
import sys
from datetime import date

# Salida en UTF-8 pase lo que pase. En Windows, python codifica stdout con la pagina de codigos
# local cuando va a una tuberia: con cp437 —la OEM clasica de consola— este fichero MUERE con
# UnicodeEncodeError al imprimir sus guiones largos; no los degrada, se lleva el proceso. Los otros
# cinco scripts de bin/ que imprimen no-ASCII ya lo hacian y estos dos se quedaron fuera.
# Comprobado 2026-09-12 en los dos sentidos: con la guarda sobrevive, sin ella truena.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

BIN = os.path.dirname(os.path.abspath(__file__))
CREADO = re.compile(r"_creado: (\d{4}-\d{2}-\d{2})")
REVISAR = re.compile(r"_revisar: (\d{4}-\d{2}-\d{2})")
ID = re.compile(r"_id: (p-[0-9a-f]{10})_")
NO_CADUCA = "_no-caduca_"


def parse_date(s):
    y, m, d = (int(x) for x in s.split("-"))
    return date(y, m, d)


def resolve_memory_dir(explicit):
    """Misma logica que journal-compact.py. NO llama a resolve-project-dir.sh: ese script no
    imprime nada — esta hecho para `source`, no para `$(...)`. (Hasta 2.14.2 ademas se colgaba
    sin stdin; eso ya no pasa, pero la razon de arriba sigue en pie.)"""
    cand = explicit or os.environ.get("MEMORY_DIR")
    if cand:
        return os.path.abspath(cand)
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    local = os.path.join(proj, "memory")
    if os.path.isfile(os.path.join(local, "_pendientes.md")):
        return local
    encoded = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(proj))
    auto = os.path.join(os.path.expanduser("~"), ".claude", "projects", encoded, "memory")
    if os.path.isfile(os.path.join(auto, "_pendientes.md")):
        return auto
    return local


def scan(mem, days, hoy, modo="revisar"):
    """Devuelve (candidatos, excluidos). Cada candidato: (id, edad, prioridad, linea).

    modo="revisar": candidato = `_revisar:` en el pasado. La edad se calcula igual (va al evento
    y al informe), pero no decide. modo="edad": candidato = mas de `days` dias."""
    path = os.path.join(mem, "_pendientes.md")
    if not os.path.isfile(path):
        sys.exit(f"expire-pendientes: no existe {path}")
    cands, excl = [], {"sin _creado": 0, "_revisar futuro": 0, "_no-caduca_": 0,
                       "sin _id": 0, "mas nuevo que el umbral": 0, "sin _revisar": 0}
    prio = "?"
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            h = re.match(r"^##+\s*(.+)", raw)
            if h:
                t = h.group(1).lower()
                prio = ("Alta" if "alta" in t else
                        "Media" if "media" in t else
                        "Baja" if "baja" in t else prio)
                continue
            if not raw.lstrip().startswith("- [ ]"):
                continue
            line = raw.rstrip("\n")
            if NO_CADUCA in line:
                excl["_no-caduca_"] += 1
                continue
            mc = CREADO.search(line)
            if not mc:
                excl["sin _creado"] += 1
                continue
            mr = REVISAR.search(line)
            if mr and parse_date(mr.group(1)) > hoy:
                excl["_revisar futuro"] += 1
                continue
            mi = ID.search(line)
            if not mi:
                excl["sin _id"] += 1
                continue
            edad = (hoy - parse_date(mc.group(1))).days
            if modo == "revisar":
                if not mr:
                    excl["sin _revisar"] += 1
                    continue
            elif edad <= days:
                excl["mas nuevo que el umbral"] += 1
                continue
            cands.append((mi.group(1), edad, prio, line))
    return cands, excl


def emit(mem, args):
    cmd = ["python3", os.path.join(BIN, "journal-emit.py"), "--memory-dir", mem] + args
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"expire-pendientes: journal-emit fallo: {r.stderr.strip()}")
    return r.stdout.strip()


def texto_visible(line, n=88):
    t = re.sub(r"\s*—\s*_(origen|creado|id|revisar):[^_]*_", "", line.strip()[5:].strip())
    t = re.sub(r"\s+", " ", t)
    return t[:n] + ("…" if len(t) > n else "")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--memory-dir")
    ap.add_argument("--modo", choices=("revisar", "edad"), default="revisar",
                    help="revisar: `_revisar:` vencido (defecto). edad: >--days dias (descartado)")
    ap.add_argument("--days", type=int, default=90,
                    help="edad en dias por encima de la cual el item deja de ser compromiso (90)")
    ap.add_argument("--apply", action="store_true",
                    help="emite los eventos; sin esto es dry-run y no escribe nada")
    ap.add_argument("--revertir", metavar="ID",
                    help="devuelve un pendiente caducado a _pendientes.md, verbatim")
    ap.add_argument("--limit", type=int, default=0,
                    help="caduca como mucho N items (0 = sin tope)")
    a = ap.parse_args()

    mem = resolve_memory_dir(a.memory_dir)
    if not os.path.isdir(mem):
        sys.exit(f"expire-pendientes: no existe el directorio de memoria: {mem}")
    hoy = date.today()

    if a.revertir:
        if not re.match(r"^p-[0-9a-f]{10}$", a.revertir):
            sys.exit("expire-pendientes: --revertir necesita un id p-<10 hex>")
        if not a.apply:
            print(f"DRY-RUN revertir {a.revertir} — con --apply se emite pendiente.reopen")
            return
        emit(mem, ["--type", "pendiente.reopen", "--id", a.revertir])
        print(f"REOPEN emitido para {a.revertir}. Corre journal-compact.py para aplicarlo.")
        return

    cands, excl = scan(mem, a.days, hoy, a.modo)
    cands.sort(key=lambda c: -c[1])
    if a.limit:
        cands = cands[:a.limit]

    print(f"memoria: {mem}")
    if a.modo == "revisar":
        print(f"modo: `_revisar:` vencido (hoy {hoy.isoformat()})")
    else:
        print(f"modo: EDAD, mas de {a.days} dias (hoy {hoy.isoformat()})")
        print("  AVISO: medido 2026-09-11 — 29 de 30 candidatos a N=90 seguian VIVOS bajo la")
        print("  rubrica congelada (19 de 30 si se acepta un codigo posterior al resultado).")
        print("  Este modo es para inspeccionar, no para aplicar.")
    print(f"candidatos: {len(cands)}")
    por_prio = {}
    for _, _, p, _ in cands:
        por_prio[p] = por_prio.get(p, 0) + 1
    if por_prio:
        print("  por prioridad: " + ", ".join(f"{k} {v}" for k, v in sorted(por_prio.items())))
        print(f"  edad: max {cands[0][1]}d, min {cands[-1][1]}d")
    print("excluidos: " + ", ".join(f"{k} {v}" for k, v in excl.items() if v))
    print()
    print("Archivar no dice que se hizo; dice que dejo de ser un compromiso.")
    print("Todo vuelve con --revertir <id>.")
    print()
    for pid, edad, prio, line in cands[:15]:
        print(f"  {edad:4d}d {prio:5s} {pid} {texto_visible(line)}")
    if len(cands) > 15:
        print(f"  … y {len(cands) - 15} mas")

    if not a.apply:
        print()
        print(f"DRY-RUN. Nada escrito. Para aplicarlo: --apply --modo {a.modo}")
        return

    n = 0
    for pid, edad, prio, line in cands:
        emit(mem, ["--type", "pendiente.expire", "--id", pid, "--prioridad", prio,
                   "--dias", str(edad), "--line", line])
        n += 1
    print()
    print(f"EXPIRE emitidos: {n}. Corre journal-compact.py para aplicarlos.")
    print(f"Reversa: expire-pendientes.py --revertir <id> --apply")


if __name__ == "__main__":
    main()
