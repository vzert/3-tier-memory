#!/usr/bin/env python3
"""Mutaciones de session.amend (2.40.0) y de escribir_anotado: cada una tiene que hacer caer su suite.

Por que existe: el CHANGELOG de 2.40.0 dice que cada mutacion medida hace fallar al menos un aserto,
y un adversario externo objeto, con razon, que esa frase no se podia reproducir desde el commit.
Esta es la lista, con el texto exacto que cambia cada una.

Regla del arnes (la de tools/mutation-check.sh): si una mutacion no se aplica exactamente una vez,
es SIN PROBAR, no aprobada. Sale 1 si alguna queda SIN PROBAR o si su suite no cae.

No esta en tools/run-tests.sh a proposito: un mutador que deja de aplicarse cuando el fuente cambia
pone rojo el runner (pendiente ALTA sobre mutation-check.sh). Se corre a mano al tocar este codigo:
    python3 tools/mutation-session-amend.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(RAIZ, "plugins", "3-tier-memory", "bin")
C, E = "journal-compact.py", "journal-emit.py"
SA, RR, PR = "test-session-amend.sh", "test-research-rename.sh", "test-plan-reopen.sh"

MUTACIONES = [
    # (etiqueta, fichero, texto original, texto mutado, suites que deben caer)
    ("replay <= -> <", C,
     "        if previos and ts <= max(previos):\n            if ts < max(previos):\n"
     "                log(f\"WARN session.amend",
     "        if previos and ts < max(previos):\n            if ts < max(previos):\n"
     "                log(f\"WARN session.amend", [SA]),
    ("sin guarda de replay", C,
     "        clave = f\"session-{campo[2]}-{slug}\"\n        previos = ts_registrados(mem, clave)",
     "        clave = f\"session-{campo[2]}-{slug}\"\n        previos = []", [SA]),
    ("clave de replay por sesion", C,
     "        clave = f\"session-{campo[2]}-{slug}\"", "        clave = f\"session-x-{slug}\"", [SA]),
    ("anotacion por sesion", C,
     "        anotaciones.append((f\"session-{que}-{slug}\", ts, \"el session.amend\"))",
     "        anotaciones.append((f\"session-x-{slug}\", ts, \"el session.amend\"))", [SA]),
    ("sin guarda de valor viejo", C, "        if actual != viejo:", "        if False:", [SA]),
    ("sin filas-distintas", C, "        if len(actuales) > 1:", "        if False:", [SA]),
    ("no salta la celda ya nueva", C,
     "        pendientes = [i for i in hits if nuevas[i][c] != nuevo]",
     "        pendientes = list(hits)", [SA]),
    ("ancla en la fila entera", C,
     "            m = SESSION_CELL_RE.match(cells[1]) if len(cells) > 1 else None\n"
     "            if m and m.group(1) == slug:\n                out.append(i)",
     "            if f\"[[sessions/{slug}\" in lines[i]:\n                out.append(i)", [SA]),
    ("solo la primera fila", C,
     "                out.append(i)\n    return out\n\n\ndef apply_session_amend",
     "                return [i]\n    return out\n\n\ndef apply_session_amend", [SA]),
    ("solo tablas de 5 columnas", C,
     "        if len(split_cells(lines[hdr])) not in (4, 5):\n            continue\n"
     "        for i in rows:\n            cells = split_cells(lines[i])\n            m = SESSION_CELL_RE",
     "        if len(split_cells(lines[hdr])) != 5:\n            continue\n"
     "        for i in rows:\n            cells = split_cells(lines[i])\n            m = SESSION_CELL_RE",
     [SA]),
    ("el amend poda como session.add", C,
     "    bump_updated(lines)\n    escribir_anotado(mem, anotaciones, path, lines)",
     "    _, (hdr, sep, rows) = need_table(lines, \"## Sessions\", \"_session-index.md\")\n"
     "    dated = [(i, split_cells(lines[i])[0]) for i in rows]\n"
     "    dated = [(i, d) for i, d in dated if DATE_RE.match(d)]\n"
     "    if len(dated) > MAX_SESSIONS:\n"
     "        dated.sort(key=lambda x: (x[1], -x[0]), reverse=True)\n"
     "        delete_rows(lines, [i for i, _ in dated[MAX_SESSIONS:]])\n"
     "    bump_updated(lines)\n    escribir_anotado(mem, anotaciones, path, lines)", [SA]),
    ("sin fecha real (compactador)", C,
     "                date.fromisoformat(str(p[\"date\"]))\n            except ValueError:\n"
     "                raise Quarantine(f\"malformed: session.amend con date irreal",
     "                pass\n            except ValueError:\n"
     "                raise Quarantine(f\"malformed: session.amend con date irreal", [SA]),
    ("sin forma de fecha (compactador)", C,
     "            if not DATE_RE.match(str(p[\"date\"])):\n"
     "                raise Quarantine(f\"malformed: session.amend con date",
     "            if False:\n                raise Quarantine(f\"malformed: session.amend con date", [SA]),
    ("sin validar el alias", C,
     "            if not isinstance(p[\"alias\"], str) or re.search(r\"[|\\[\\]\\n\\\\]\", p[\"alias\"]) \\",
     "            if not isinstance(p[\"alias\"], str) or False \\", [SA]),
    ("sin exigir ts", C,
     "        if p[\"_ts\"] <= 0:\n            raise Quarantine(\"malformed: session.amend sin",
     "        if False:\n            raise Quarantine(\"malformed: session.amend sin", [SA]),
    # escribir_anotado: compartido por session.amend, research.rename y plan.reopen
    ("sin anular la anotacion", C,
     "        vivas = desanotar(mem, hechas) if hechas else []",
     "        vivas = []", [SA, RR, PR]),
    ("escribir antes de anotar", C,
     "        for clave, ts, que in anotaciones:\n            anotar_reabierto(mem, clave, ts, que=que)\n"
     "            hechas.append((clave, ts))\n        atomic_write(path, lines)",
     "        atomic_write(path, lines)\n        for clave, ts, que in anotaciones:\n"
     "            anotar_reabierto(mem, clave, ts, que=que)\n            hechas.append((clave, ts))",
     [SA, RR, PR]),
    ("anulacion sin signo (+ts)", C,
     "                fh.write(f\"{campo_log(clave)}\\t-{campo_log(str(ts))}",
     "                fh.write(f\"{campo_log(clave)}\\t{campo_log(str(ts))}", [SA]),
    ("registro como conjunto, no multiconjunto", C,
     "                        cuenta[n] = max(0, cuenta.get(n, 0) - 1)",
     "                        cuenta[n] = -10 ** 9   # un ts anulado queda muerto: diferencia de conjuntos",
     [SA]),
    ("cuarentena no-registro sin disparar", C,
     "        if vivas:\n            raise Quarantine(", "        if False:\n            raise Quarantine(", [SA]),
    ("fecha vieja vacia rechazada (compactador)", C,
     "            if not isinstance(p.get(\"fecha_vieja\"), str):",
     "            if not p.get(\"fecha_vieja\"):", [SA]),
    # emisor
    ("emisor: fecha del slug por defecto", E,
     "        fecha = (a.date or \"\").strip()", "        fecha = (a.date or slug[:10]).strip()", [SA]),
    ("emisor: sin forma de fecha", E,
     "        if fecha and not (DATE_RE.match(fecha) and fecha_real(fecha)):",
     "        if fecha and not fecha_real(fecha):", [SA]),
    ("emisor: acepta duplicadas distintas", E,
     "        if (fecha and a.fecha_vieja is None and len(fechas) > 1) or \\",
     "        if False and (fecha and a.fecha_vieja is None and len(fechas) > 1) or False and \\",
     [SA]),
    ("emisor: toda linea con '|'", E,
     "    for i in jc.session_owned_rows(lines, slug):",
     "    for i in [k for k, l in enumerate(lines) if l.startswith(\"|\") and f\"[[sessions/{slug}\" in l]:",
     [SA]),
    ("emisor: fecha vieja vacia rechazada", E,
     "        if (fecha and fvieja is None) or (alias and not svieja):",
     "        if (fecha and not fvieja) or (alias and not svieja):", [SA]),
    ("emisor: cuenta pares distintos", E,
     "        out.append((cells[0], cells[1]))\n    return out",
     "        if (cells[0], cells[1]) not in out:\n            out.append((cells[0], cells[1]))\n"
     "    return out", [SA]),
]


def correr(suite, d):
    """(cae, ultima linea). Cae solo si sale != 0 Y hay algun aserto FALLA: una suite que revienta
    antes de sus asertos sale != 0 sin haber medido nada, y contarla como "cae" aprobaria una
    mutacion que ningun aserto detecta (adversario externo, ronda 4). Limite: estas suites callan
    el stderr del compactador, asi que un mutado que ni compila tambien produce FALLA y cuenta
    como caido; por eso cada mutacion de la lista es codigo valido."""
    r = subprocess.run(["bash", os.path.join(d, suite)], capture_output=True, text=True)
    ultima = (r.stdout.strip().splitlines() or [""])[-1]
    return r.returncode != 0 and "  FALLA " in r.stdout, ultima


def main():
    malas = 0
    for etiqueta, fichero, viejo, nuevo, suites in MUTACIONES:
        with open(os.path.join(BIN, fichero), encoding="utf-8") as fh:
            src = fh.read()
        n = src.count(viejo)
        if n != 1:
            print(f"  ?? {etiqueta:36} se aplica {n} veces -> SIN PROBAR")
            malas += 1
            continue
        for suite in suites:
            d = tempfile.mkdtemp()
            try:
                for f in os.listdir(BIN):
                    if os.path.isfile(os.path.join(BIN, f)):
                        shutil.copy(os.path.join(BIN, f), d)
                with open(os.path.join(d, fichero), "w", encoding="utf-8") as fh:
                    fh.write(src.replace(viejo, nuevo))
                cae, ultima = correr(suite, d)
            finally:
                subprocess.run(["chmod", "-R", "u+w", d])
                shutil.rmtree(d, ignore_errors=True)
            if not cae:
                print(f"  NO {etiqueta:36} {suite} NO cae por un aserto ({ultima})")
                malas += 1
            else:
                print(f"  ok {etiqueta:36} {suite}: {ultima}")
    total = sum(len(m[4]) for m in MUTACIONES)
    print(f"\n{total - malas} de {total} (mutacion, suite) caen" if not malas
          else f"\n{malas} SIN PROBAR o sin caer")
    return 1 if malas else 0


if __name__ == "__main__":
    sys.exit(main())
