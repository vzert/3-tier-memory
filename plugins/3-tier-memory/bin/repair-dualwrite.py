#!/usr/bin/env python3
"""
3-tier-memory plugin: repara el dual-write roto de pendientes (v2.12.3).

Cada pendiente vive en DOS sitios: la linea de `_pendientes.md` (Tier 2, la lista abierta) y
la fila de `pendientes/YYYY-MM.md` (Tier 3, el historial). El compactador del journal escribe
las dos a la vez. Una linea escrita a mano en Tier 2 no genera la fila de Tier 3, y el fallo
es silencioso hasta que se cierra el pendiente: `apply_resolve_monthly` no encuentra la fila,
deja un WARN, y se pierden la fecha de resolucion y la sesion que lo cerro.

Medido el 2026-09-10 en claude-vzert: 51 de 120 pendientes abiertos (42%) sin fila en Tier 3;
ninguno tenia evento propio en `.journal/applied/`, o sea que los 51 se escribieron a mano.
La mayoria es anterior al despliegue del journal (2026-09-03), pero 14 son posteriores: la
fuga seguia abierta con el journal ya en marcha, porque nada impedia escribir Tier 2 a mano.

Hay una SEGUNDA perdida del mismo historial, independiente de la anterior: una fila cuyo
texto lleva un `|` (`sort | uniq -c`) se parte en mas de 7 celdas, `apply_resolve_monthly`
lee la prioridad ("Alta") como fecha de resolucion, concluye "ya resuelto" y no escribe nada
— y el compactador reporta `applied=1` sin dejar ni un WARN. Ese pendiente no se puede cerrar
nunca. El arreglo va en journal-compact.py (usar `split_cells`, que ya existia, en vez de
`split("|")`, y escapar con `escape_cell` al escribir); aqui esta `--fix-pipes`, que reescribe
las filas ya guardadas con el `|` crudo.

Que hace: por cada id de Tier 2 sin fila en ningun mensual, escribe la fila que le
corresponde en `pendientes/<creado[:7]>.md`, con el MISMO formato que
`journal-compact.apply_add_monthly` — texto, prioridad, creado y origen tomados de la linea
de Tier 2, `Resuelto` y `Sesion resolucion` en blanco. No inventa datos: un pendiente sin
`_creado:` o sin `_id:` no se repara, se reporta.

Que NO hace:
  - no toca `_pendientes.md` (Tier 2 es la entrada; aqui solo se lee);
  - no recalcula ids. El id de un pendiente emitido por journal es sha1(texto+creado+origen),
    pero una linea escrita a mano puede llevar un id inventado (27 de 119 en claude-vzert).
    Recalcularlos obligaria a reescribir las citas de ese id en los session logs, que son
    registro historico. El id vale por ser estable, no por ser reproducible, asi que se
    conserva tal cual. Reemitir ese mismo texto por journal generaria el id canonico y una
    fila duplicada; lo que cierra ese riesgo es no volver a escribir Tier 2 a mano
    (`journal_strict=1` en `memory/.memory-config`).
  - no reordena ni borra filas. Solo agrega al final de la tabla del mes, y con `--fix-pipes`
    reescribe en su sitio las filas con `|` crudo (mismo contenido, `|` escapado).

Idempotente: una segunda corrida no encuentra nada que reparar y no escribe.

La prioridad sale del header `## Alta|Media|Baja ...` bajo el que vive la linea, que es el
mismo criterio que usa `journal-compact.header_index` para insertarla. Una linea fuera de
los tres headers se reporta como no reparable en vez de adivinar `Media`.

Toma el lock del journal (`memory/.journal/.lock`) para no pisar a un compactador
concurrente, igual que `normalize-pendientes.py`. Si no lo consigue, no hace nada.

Uso: repair-dualwrite.py MEMORY_DIR [--apply] [--fix-pipes] [--quiet] [--budget SEG]
  Sin --apply solo informa (dry-run): lista los ids con el mes donde iria cada fila y avisa
  de las filas con `|` crudo. Salida: `rows_added=N pipes_fixed=N missing_data=N`.
  Codigos: 0 ok (o lock ocupado); 1 error de entorno (sin _pendientes.md o sin journal-compact).

Pruebas: test-repair-dualwrite.sh (cubre las dos perdidas, la idempotencia y el id conservado).
"""
import argparse
import importlib.util
import os
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

PRIOS = (("alta", "Alta"), ("media", "Media"), ("baja", "Baja"))
HEADER_RE = re.compile(r"^##\s+", re.I)
ITEM_RE = re.compile(r"^\s*-\s*\[[ xX]\]\s")
# Sufijos de metadatos al final de la linea. Se buscan por separado y en cualquier orden:
# 6 de 119 lineas medidas en claude-vzert no siguen el orden origen/creado/id.
ID_RE = re.compile(r"_id:\s*(p-[0-9a-f]{10})_")
CREADO_RE = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
ORIGEN_RE = re.compile(r"_origen:\s*(\[\[[^\]]+\]\])_")
META_RE = re.compile(r"\s*—\s*_(?:origen|creado|id):[^—]*")


def load_compactor(bin_dir):
    """Modulo journal-compact.py del directorio vecino; None si no esta (copia suelta)."""
    path = os.path.join(bin_dir, "journal-compact.py")
    if not os.path.isfile(path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("jc", path)
        jc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(jc)
        return jc
    except Exception:
        return None


def cell(text):
    """Texto apto para una celda markdown: una linea, `|` suelto escapado (`\\|` se respeta)."""
    t = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"(?<!\\)\|", r"\\|", t)


def parse_tier2(path):
    """[(id, texto, prioridad, creado, origen, motivo_si_no_reparable)] de _pendientes.md.

    El texto es la linea sin el `- [ ] ` y sin los sufijos de metadatos, igual que
    `journal-compact.line_text`, para que la celda diga lo mismo que diria el compactador.
    """
    out = []
    prio = None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n").rstrip("\r")
            if HEADER_RE.match(line.strip()):
                low = line.strip().lower()
                prio = next((name for key, name in PRIOS if low.startswith(f"## {key}")), None)
                continue
            if not ITEM_RE.match(line):
                continue
            mid = ID_RE.search(line)
            if not mid:
                continue  # sin id no hay nada que reconciliar: lo pondra el enriquecedor
            pid = mid.group(1)
            body = ITEM_RE.sub("", line, count=1)
            text = re.sub(r"\s+", " ", META_RE.sub("", body)).strip()
            mcre = CREADO_RE.search(line)
            mori = ORIGEN_RE.search(line)
            faltan = []
            if prio is None:
                faltan.append("sin header de prioridad")
            if not mcre:
                faltan.append("sin _creado_")
            if not mori:
                faltan.append("sin _origen_")
            out.append((pid, text, prio,
                        mcre.group(1) if mcre else None,
                        mori.group(1) if mori else None,
                        ", ".join(faltan) if faltan else None))
    return out


def monthly_files(mem):
    d = os.path.join(mem, "pendientes")
    if not os.path.isdir(d):
        return []
    return [os.path.join(d, fn) for fn in sorted(os.listdir(d))
            if re.match(r"^\d{4}-\d{2}\.md$", fn)]


def row_cells(jc, line):
    """Celdas de una fila de la tabla mensual, colapsando el exceso en la celda de texto.

    Dos capas, porque hay filas rotas de dos maneras distintas:
      - `jc.split_cells` respeta `\\|`, asi que una fila escrita con el texto escapado sale ya
        con sus 7 celdas;
      - una fila antigua con el `|` CRUDO (las escribio `apply_add_monthly` antes de escapar)
        sale con mas de 7. El formato es fijo — `| # | texto | prio | creado | origen |
        resuelto | sesion |` — asi que el exceso esta por fuerza dentro del texto: se vuelve a
        unir todo lo que sobra entre la celda 1 y las ultimas 5.
    """
    cells = jc.split_cells(line)
    if len(cells) > 7:
        cells = [cells[0], " | ".join(cells[1:len(cells) - 5])] + cells[-5:]
    return cells


def numbered_rows(jc, path):
    """(indice, celdas) de cada fila numerada del mensual."""
    out = []
    lines = jc.read_lines(path)
    for i, line in enumerate(lines):
        if re.match(r"^\|\s*\d+\s*\|", line.strip()):
            out.append((i, row_cells(jc, line)))
    return lines, out


def existing_ids(jc, mem):
    """Ids que YA tienen fila propia en algun mensual.

    Se busca `_id: X_` solo en la celda de texto, no en el archivo entero: el texto de un
    pendiente puede citar el id de otro (p-2f63bfea40 cita tres), y contarlos inflaria el
    conjunto y dejaria huerfanos sin reparar. Y se busca el ULTIMO `_id:` de esa celda, que es
    el propio: los citados van antes, dentro del texto.
    """
    ids = set()
    for path in monthly_files(mem):
        for _, cells in numbered_rows(jc, path)[1]:
            if len(cells) >= 2:
                ms = ID_RE.findall(cells[1])
                if ms:
                    ids.add(ms[-1])
    return ids


def broken_pipe_rows(jc, mem):
    """[(path, idx, linea_nueva)] de filas cuyo texto lleva un `|` crudo.

    Esas filas tienen mas de 7 celdas, asi que `apply_resolve_monthly` lee la prioridad como
    fecha de resolucion, concluye "ya resuelto" y no escribe nada: el pendiente no se puede
    cerrar nunca, en silencio. Reescribirlas con el `|` escapado las devuelve a 7 celdas.
    """
    out = []
    for path in monthly_files(mem):
        lines = jc.read_lines(path)
        for i, line in enumerate(lines):
            if not re.match(r"^\|\s*\d+\s*\|", line.strip()):
                continue
            if len(jc.split_cells(line)) <= 7:
                continue
            cells = row_cells(jc, line)
            cells[1] = jc.escape_cell(cells[1])
            out.append((path, i, jc.join_cells(cells)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--fix-pipes", action="store_true",
                    help="reescribe con `|` escapado las filas que hoy no se pueden cerrar")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--budget", type=float, default=2.0)
    a = ap.parse_args()

    mem = os.path.abspath(a.memory_dir)
    idx = os.path.join(mem, "_pendientes.md")
    if not os.path.isfile(idx):
        print(f"repair-dualwrite: no existe {idx}", file=sys.stderr)
        return 1

    jc = load_compactor(os.path.dirname(os.path.abspath(__file__)))
    if jc is None:
        print("repair-dualwrite: falta journal-compact.py en el mismo bin/", file=sys.stderr)
        return 1

    lock = None
    if a.apply:
        lock = jc.Lock(os.path.join(mem, ".journal"), a.budget)
        if not lock.acquire():
            if not a.quiet:
                print("rows_added=0 pipes_fixed=0 (journal busy; reintenta luego)")
            return 0
    try:
        # Primero las filas con `|` crudo: hasta que se reescriben, su `_id:` cae fuera de la
        # celda de texto y `existing_ids` las contaria como ausentes, duplicandolas.
        pipes = broken_pipe_rows(jc, mem)
        if pipes and a.fix_pipes and a.apply:
            por_path = {}
            for path, i, nueva in pipes:
                por_path.setdefault(path, []).append((i, nueva))
            for path, cambios in por_path.items():
                lines = jc.read_lines(path)
                for i, nueva in cambios:
                    lines[i] = nueva
                jc.atomic_write(path, lines)

        have = existing_ids(jc, mem)
        added = 0
        broken = []
        pending = []
        for pid, text, prio, creado, origen, motivo in parse_tier2(idx):
            if pid in have:
                continue
            if motivo:
                broken.append((pid, motivo))
                continue
            pending.append((pid, text, prio, creado, origen))

        # Agrupar por mes para abrir y reescribir cada mensual una sola vez.
        por_mes = {}
        for item in pending:
            por_mes.setdefault(item[3][:7], []).append(item)

        for ym in sorted(por_mes):
            path = os.path.join(mem, "pendientes", ym + ".md")
            lines = jc.ensure_monthly(path, ym) if not os.path.isfile(path) else jc.read_lines(path)
            at = jc.last_table_line(lines)
            if at is None:
                broken += [(i[0], f"{ym}.md no tiene tabla") for i in por_mes[ym]]
                continue
            nums = [int(c[0]) for _, c in jc.table_rows(lines) if c and c[0].isdigit()]
            n = (max(nums) + 1) if nums else 1
            nuevas = []
            for pid, text, prio, creado, origen in por_mes[ym]:
                nuevas.append(f"| {n} | {cell(text)} _id: {pid}_ | {prio} | {creado} "
                              f"| {origen} | | |")
                n += 1
                added += 1
            if a.apply:
                lines[at + 1:at + 1] = nuevas
                jc.atomic_write(path, lines)
            elif not a.quiet:
                for pid, *_ in por_mes[ym]:
                    print(f"  {pid} -> pendientes/{ym}.md")

        if not a.quiet:
            sufijo = "" if a.apply else " [dry-run: usa --apply]"
            fixed = len(pipes) if (a.fix_pipes and a.apply) else 0
            print(f"rows_added={added} pipes_fixed={fixed} missing_data={len(broken)}{sufijo}")
            if pipes and not (a.fix_pipes and a.apply):
                print(f"  AVISO {len(pipes)} filas con `|` crudo no se pueden cerrar "
                      f"(apply_resolve_monthly las lee como ya resueltas): usa --fix-pipes")
            for pid, motivo in broken:
                print(f"  NO REPARABLE {pid}: {motivo}")
        return 0
    finally:
        if lock is not None:
            lock.release()


if __name__ == "__main__":
    sys.exit(main())
