#!/usr/bin/env python3
"""
3-tier-memory plugin: repara el formato mixto de memory/_plans-index.md (v2.25.5, p-baa546ddac).

`_plans-index.md` tenia, antes de v2.12.0 (Fase 2 del journal), otro esquema de tabla: 4 columnas
`Fecha | Plan | Status | Resumen`. Desde v2.12.0 `apply_plan_upsert` (journal-compact.py) escribe
SIEMPRE 6 columnas (`pad(split_cells(...), 6)` sobre `Plan | Status | Fecha | Sesion | Pendientes
| Learnings`, ver TABLE_COLUMNS["## Plans"]) sin mirar la cabecera existente. Medido en una
instalacion real (claude-vzert, referenciado en p-04acf30315/p-baa546ddac): una cabecera vieja de
4 columnas convivia con filas nuevas de 6 escritas por el journal — un humano leyendo la tabla
malinterpreta las columnas de cualquier fila nueva, y `apply_plan_upsert` ya documenta (ver su
comentario junto a `find_plan_rows`) que un indice de formato mixto puede volverse ciego a una fila
legacy y duplicarla.

Que hace: en la PRIMERA tabla bajo `## Plans` (misma tabla que usa `need_table`/`apply_plan_upsert`
de journal-compact.py — nunca otra tabla del archivo):
  - una fila de 4 celdas con fecha en la celda 0 (`Fecha|Plan|Status|Resumen`, la forma legacy
    medida) se MIGRA a la forma canonica de 6 (`Plan|Status|Fecha|Sesion|Pendientes|Learnings`),
    con Sesion/Pendientes/Learnings en blanco. `Resumen` no tiene columna destino en el esquema
    nuevo: se anexa a `Status` (`"<status> — resumen: <resumen>"`), visible en la tabla — mismo
    patron que ya usa la anotacion `(fase de plan-X)` sobre esa misma celda. Decision confirmada
    con el usuario (AskUserQuestion, 2026-09-15): la alternativa de un log aparte lo hace invisible
    al leer la tabla, que es justo el dano que este pendiente describe.
  - la cabecera se RE-CABECEA a la forma canonica de 6 SOLO cuando hoy es EXACTAMENTE la forma
    legacy reconocida (`Fecha|Plan|Status|Resumen`, en ese orden) — nunca sobre una cabecera que no
    se reconoce, que se reporta (`header_unrecognized`) y no se toca: cambiar la cabecera de un
    indice ajeno sin saber que forma tiene hoy es la misma clase de riesgo que `header_issues` en
    repair-dualwrite.py se niega a asumir para los mensuales de pendientes.
  - una fila cuyo ancho NO es 4 ni 6, o de 4 celdas SIN fecha en la celda 0, se reporta como
    `unrepairable` y no se toca: admite mas de una lectura y no se adivina (mismo criterio que
    `row_cells`/`unaligned_rows` de repair-dualwrite.py — anclar por FORMA, o reportar).
  - si la migracion de una fila legacy produciria un titulo de Plan (`plain()`) que YA existe en
    otra fila de la tabla, se reporta como `possible_duplicate` y esa fila NO se migra: fusionar
    dos filas del mismo plan sin que un humano las compare es el mismo riesgo que
    `apply_plan_upsert` ya rechaza con Quarantine cuando `find_plan_rows` devuelve mas de una fila.

Que NO hace:
  - no crea la ancla `## Plans` si falta del todo (eso es `need_table`, y solo corre dentro de
    journal-compact.py al aplicar un evento real); si falta, se reporta `no_plans_table=1` y no se
    hace nada mas.
  - no toca ninguna otra tabla del archivo, ni filas huerfanas sin cabecera (`orphan_pipe_rows`
    en journal-compact.py) — ver p-df5d259317, un hallazgo distinto (paperclip: filas de plan sin
    cabecera de tabla en absoluto), fuera de alcance aqui.
  - no fusiona ni borra ninguna fila. Idempotente: una segunda corrida no encuentra nada que
    reparar y no escribe.

Toma el lock del journal (memory/.journal/.lock) igual que repair-dualwrite.py/normalize-pendientes.py,
para no pisar a un compactador concurrente. Si no lo consigue, no hace nada.

Uso: repair-plans-index.py MEMORY_DIR [--apply] [--quiet] [--budget SEG]
  Sin --apply solo informa (dry-run). Salida:
  `legacy_rows_migrated=N header_rewritten=si|no unrepairable_rows=N possible_duplicates=N
  no_plans_table=0|1 header_unrecognized=0|1`. Codigos: 0 ok (o lock ocupado, o sin _plans-index.md
  en un proyecto sin memoria todavia — fail-open, este script puede correr en checkpoint-3t Step
  3-pre); 1 solo si _plans-index.md existe pero no se pudo leer.

Pruebas: test-repair-plans-index.sh.
"""
# sella-huellas: si
import argparse
import importlib.util
import os
import re
import sys
import unicodedata

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


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


def _colkey(cell):
    """Nombre de columna comparable: minusculas, sin tildes, espacios colapsados. Copia deliberada
    de journal-compact._colkey (no importada): esa funcion vive en la seccion de _pendientes.md,
    con su propio diccionario de alias; aqui el vocabulario es distinto (Plan/Status/Fecha/Sesion/
    Pendientes/Learnings/Resumen) y no vale la pena acoplar los dos formatos a una sola funcion."""
    t = unicodedata.normalize("NFD", (cell or "").strip().lower())
    t = "".join(c for c in t if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", t).strip()


CANONICAL_HEADER = ["plan", "status", "fecha", "sesion", "pendientes", "learnings"]
LEGACY_HEADER = ["fecha", "plan", "status", "resumen"]


def header_shape(jc, header_line):
    """'canonical' | 'legacy' | 'unknown', segun los nombres EXACTOS y en ESE orden de la cabecera.

    Solo estas dos formas estan documentadas (TABLE_COLUMNS["## Plans"] es la canonica; la legacy
    es la que cita el pendiente que origino este script, medida en produccion). Cualquier otra cosa
    es 'unknown': no se reescribe una cabecera cuya forma no se reconoce con certeza.
    """
    keys = [_colkey(c) for c in jc.split_cells(header_line)]
    if keys == CANONICAL_HEADER:
        return "canonical"
    if keys == LEGACY_HEADER:
        return "legacy"
    return "unknown"


def classify_row(jc, line):
    """('canonical', cells6) | ('legacy', cells6_migradas) | ('unrepairable', cells) de una fila
    de datos de la tabla '## Plans'.

    Ancla por FORMA, nunca por conteo solo: una fila de 4 celdas es legacy SOLO si la celda 0 tiene
    pinta de fecha (`Fecha|Plan|Status|Resumen`, el orden medido en produccion) — de lo contrario
    admite mas de una lectura y se reporta sin tocar, mismo criterio que `align_row`/`row_cells` en
    journal-compact.py/repair-dualwrite.py.
    """
    cells = jc.split_cells(line)
    n = len(cells)
    if n == 6:
        return "canonical", cells
    if n == 4 and DATE_RE.match(cells[0]):
        fecha, plan, status, resumen = cells
        resumen = resumen.strip()
        new_status = f"{status} — resumen: {resumen}" if resumen else status
        return "legacy", [plan, new_status, fecha, "", "", ""]
    return "unrepairable", cells


def repair(jc, lines):
    """(cambios, migradas, no_reparables, duplicados_posibles, cabecera_reescrita, sin_tabla,
    cabecera_no_reconocida) — NO escribe; el llamante decide con --apply.

    `cambios` es True si hay algo que aplicar (cabecera y/o al menos una fila)."""
    sec = jc.section_bounds(lines, "## Plans")
    if not sec:
        return False, [], [], [], False, True, False, (None, None, {})
    tab = jc.table_in(lines, *sec)
    if not tab:
        return False, [], [], [], False, True, False, (None, None, {})
    hdr_i, sep_i, row_idxs = tab

    forma = header_shape(jc, lines[hdr_i])
    cabecera_no_reconocida = forma == "unknown"

    # Titulos (plain()) ya presentes en filas CANONICAS de la tabla, para detectar una migracion
    # que duplicaria un plan que ya tiene fila en la forma nueva. Solo se compara contra filas
    # canonicas: dos filas legacy del mismo plan (dano previo, no causado por esta migracion) se
    # reportarian dos veces como 'legacy' y quien lea el resumen lo nota igual.
    titulos_canonicos = set()
    clasificadas = {}
    for i in row_idxs:
        tipo, cells = classify_row(jc, lines[i])
        clasificadas[i] = (tipo, cells)
        if tipo == "canonical":
            titulos_canonicos.add(jc.plain(cells[0]))

    migradas, no_reparables, duplicados = [], [], []
    nuevas_filas = {}
    for i in row_idxs:
        tipo, cells = clasificadas[i]
        if tipo == "canonical":
            continue
        if tipo == "unrepairable":
            no_reparables.append((i, len(cells)))
            continue
        # tipo == "legacy"
        titulo = jc.plain(cells[0])
        if titulo in titulos_canonicos:
            duplicados.append((i, cells[0]))
            continue
        nuevas_filas[i] = cells
        migradas.append((i, cells[0]))

    # La cabecera se re-cabecea siempre que hoy sea exactamente la legacy reconocida, aunque no
    # haya ninguna fila legacy que migrar (p.ej. todas las filas ya son de 6 celdas bajo una
    # cabecera vieja de 4: exactamente el caso medido en produccion que origino este pendiente).
    cabecera_reescrita = forma == "legacy"
    cambios = bool(nuevas_filas) or cabecera_reescrita
    return cambios, migradas, no_reparables, duplicados, cabecera_reescrita, False, cabecera_no_reconocida, (
        hdr_i, sep_i, nuevas_filas)


def apply_changes(jc, lines, hdr_i, sep_i, nuevas_filas, cabecera_reescrita):
    for i, cells in nuevas_filas.items():
        lines[i] = jc.join_cells(cells)
    if cabecera_reescrita:
        cols = jc.TABLE_COLUMNS["## Plans"]
        lines[hdr_i] = "| " + " | ".join(cols) + " |"
        lines[sep_i] = "|" + "|".join("---" for _ in cols) + "|"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--budget", type=float, default=2.0)
    a = ap.parse_args()

    mem = os.path.abspath(a.memory_dir)
    idx = os.path.join(mem, "_plans-index.md")
    if not os.path.isfile(idx):
        # Fail-open: sin _plans-index.md no hay nada que reparar (proyecto nuevo, o sin
        # 3-tier-memory todavia). Este script puede correr desde checkpoint-3t Step 3-pre, igual
        # que check-active-plans.py.
        if not a.quiet:
            print("legacy_rows_migrated=0 header_rewritten=no unrepairable_rows=0 "
                  "possible_duplicates=0 no_plans_table=0 header_unrecognized=0 (sin _plans-index.md)")
        return 0

    jc = load_compactor(os.path.dirname(os.path.abspath(__file__)))
    if jc is None:
        print("repair-plans-index: falta journal-compact.py en el mismo bin/", file=sys.stderr)
        return 0

    try:
        lines = jc.read_lines(idx)
    except Exception as exc:
        print(f"repair-plans-index: no se pudo leer {idx}: {exc}", file=sys.stderr)
        return 1

    lock = None
    if a.apply:
        lock = jc.Lock(os.path.join(mem, ".journal"), a.budget)
        if not lock.acquire():
            if not a.quiet:
                print("legacy_rows_migrated=0 header_rewritten=no unrepairable_rows=0 "
                      "possible_duplicates=0 no_plans_table=0 header_unrecognized=0 (busy)")
            return 0
    try:
        (cambios, migradas, no_reparables, duplicados, cabecera_reescrita, sin_tabla,
         cabecera_no_reconocida, extra) = repair(jc, lines)

        if not a.quiet:
            sufijo = "" if a.apply or not cambios else " [dry-run: usa --apply]"
            print(f"legacy_rows_migrated={len(migradas)} "
                  f"header_rewritten={'si' if cabecera_reescrita else 'no'} "
                  f"unrepairable_rows={len(no_reparables)} "
                  f"possible_duplicates={len(duplicados)} "
                  f"no_plans_table={1 if sin_tabla else 0} "
                  f"header_unrecognized={1 if cabecera_no_reconocida else 0}{sufijo}")
            for i, titulo in migradas:
                verbo = "migrada" if a.apply else "se migraria"
                print(f"  {verbo} fila de '## Plans' linea {i + 1} ({titulo}) de 4 columnas "
                      f"(Fecha|Plan|Status|Resumen) a 6 (Plan|Status|Fecha|Sesion|Pendientes|"
                      f"Learnings); el Resumen se anexo a Status.")
            for i, n in no_reparables:
                print(f"  GRAVE '## Plans' linea {i + 1}: {n} celdas, no se puede anclar por "
                      f"forma (ni 4 con fecha en la celda 0, ni 6) — no se toca. Revisala a mano.")
            for i, titulo in duplicados:
                print(f"  AVISO '## Plans' linea {i + 1} ({titulo}) parece legacy pero YA existe "
                      f"otra fila canonica con el mismo titulo — no se migra, para no fusionar dos "
                      f"filas sin que alguien las compare. Unificalas a mano.")
            if cabecera_no_reconocida:
                print("  AVISO la cabecera de '## Plans' no es ni la forma canonica ni la legacy "
                      "reconocida — no se reescribe (las filas SI se migran por su forma propia).")
            if sin_tabla:
                print("  AVISO no hay tabla bajo '## Plans' en este archivo — nada que reparar "
                      "aqui (la ancla la crea journal-compact.py al aplicar un evento real).")

        if a.apply and cambios:
            hdr_i, sep_i, nuevas_filas = extra
            apply_changes(jc, lines, hdr_i, sep_i, nuevas_filas, cabecera_reescrita)
            jc.bump_updated(lines)
            jc.atomic_write(idx, lines)
            try:
                jc.guardar_huellas(mem, os.path.join(mem, ".journal"), escritos=[idx])
            except AttributeError:
                pass   # compactador anterior a 2.13.2: no tiene huellas que sellar
        return 0
    finally:
        if lock is not None:
            lock.release()


if __name__ == "__main__":
    sys.exit(main())
