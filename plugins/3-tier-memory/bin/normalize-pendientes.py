#!/usr/bin/env python3
"""
3-tier-memory plugin: garantiza los tres headers de prioridad en memory/_pendientes.md (v2.12.1).

El compactador del journal inserta cada `pendiente.add` bajo un header que empiece por
`## alta`, `## media` o `## baja` (sin distinguir mayusculas; `header_index` en
journal-compact.py). Si falta, el evento va a quarantine/ con `no-anchor`. Instalaciones que
adoptaron el plugin antes de 2.12.0 usan a veces otros headers (`## Abiertos`, `P0 — ...`,
secciones por semana o por tema): medido 2026-09-03 en 38 proyectos locales, 9 no tenian al
menos uno de los tres. Este script anade SOLO los headers que faltan; nunca mueve, borra ni
reescribe items ni secciones existentes. Idempotente: con los tres presentes no toca el archivo.

Donde inserta:
  - si ya existe algun header canonico, el que falta va pegado a su vecino canonico: al final
    de la seccion del header que le precede en el orden Alta, Media, Baja si existe, y si no,
    justo antes del que le sigue. Si los existentes estan desordenados (p. ej. Baja antes de
    Alta) NO se reordenan: el nuevo se coloca segun esa misma regla y el archivo conserva su
    orden; el compactador no exige orden, solo que el header exista;
  - si no existe ninguno, los tres van justo antes de `## Related` (o al final del archivo).
  `## Como usar` y cualquier otra seccion se quedan donde estan. Se conserva el tipo de salto
  de linea del archivo (LF o CRLF) y no se toca ninguna otra linea.

Toma el lock del journal (memory/.journal/.lock, mismo que el compactador) para que dos
sesiones que arranquen a la vez no anadan el header dos veces; si no consigue el lock en el
presupuesto, no hace nada (lo hara la siguiente sesion). Escribe tmp + el os.replace con reintento
del compactador (replace_with_retry; en Windows un antivirus puede tener el .md abierto). Lock y
reintento vienen de journal-compact.py, que en el plugin siempre esta en este mismo directorio; si
no se encuentra (copia suelta del script) se escribe con os.replace y sin lock.

Uso: normalize-pendientes.py MEMORY_DIR [--apply] [--quiet] [--budget SEG]
  Sin --apply solo informa. Salida: `headers_added=N (Alta prioridad, ...)` o nada con --quiet
  si N=0. Exit 0 siempre que el archivo exista o no (fail-open: es un hook de SessionStart).
"""
import argparse
import importlib.util
import os
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

CANON = [("alta", "## Alta prioridad"), ("media", "## Media prioridad"), ("baja", "## Baja prioridad")]
HEADER_RE = re.compile(r"^##\s+", re.I)


def find_header(lines, key):
    for i, line in enumerate(lines):
        if line.strip().lower().startswith(f"## {key}"):
            return i
    return None


def section_end(lines, start):
    """Indice de la primera linea de header `## ` despues de `start` (o len(lines))."""
    for i in range(start + 1, len(lines)):
        if HEADER_RE.match(lines[i]):
            return i
    return len(lines)


def plan_insertions(lines):
    """Devuelve [(indice, header)] a insertar, calculado sobre `lines` sin modificar."""
    present = {key: find_header(lines, key) for key, _ in CANON}
    missing = [(key, h) for key, h in CANON if present[key] is None]
    if not missing:
        return []
    if all(v is None for v in present.values()):
        rel = find_header(lines, "related")
        at = rel if rel is not None else len(lines)
        return [(at, h) for _, h in missing]
    plan = []
    for key, h in missing:
        order = [k for k, _ in CANON]
        idx = order.index(key)
        later = [present[k] for k in order[idx + 1:] if present[k] is not None]
        earlier = [present[k] for k in order[:idx] if present[k] is not None]
        if earlier:
            at = section_end(lines, max(earlier))
        elif later:
            at = min(later)
        else:
            at = len(lines)
        plan.append((at, h))
    return plan


def insert(lines, plan):
    out = list(lines)
    # De atras hacia delante para que los indices previos sigan valiendo; a igual indice,
    # se inserta primero Baja, luego Media, luego Alta, para que queden en orden canonico.
    rank = {h: i for i, (_, h) in enumerate(CANON)}
    for at, h in sorted(plan, key=lambda x: (x[0], rank[x[1]]), reverse=True):
        block = [h, ""]
        if at > 0 and out[at - 1].strip() != "":
            block = ["", h, ""]
        if at < len(out) and out[at].strip() == "":
            block = block[:-1]
        out[at:at] = block
    return out


def load_compactor(bin_dir):
    """Modulo journal-compact.py del directorio vecino (Lock y replace_with_retry); None si no esta."""
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--budget", type=float, default=1.0)
    a = ap.parse_args()
    path = os.path.join(a.memory_dir, "_pendientes.md")
    if not os.path.isfile(path):
        if not a.quiet:
            print("headers_added=0 (sin _pendientes.md)")
        return 0
    lock = None
    jc = load_compactor(os.path.dirname(os.path.abspath(__file__)))
    if a.apply and jc is not None:
        lock = jc.Lock(os.path.join(a.memory_dir, ".journal"), a.budget)
        if not lock.acquire():
            if not a.quiet:
                print("headers_added=0 (journal busy; se reintenta en la proxima sesion)")
            return 0
    try:
        # newline="" conserva los saltos tal cual (CRLF en archivos escritos en Windows); se
        # parte y se vuelve a unir con el mismo separador para no reescribir ninguna otra linea.
        with open(path, encoding="utf-8", newline="") as fh:
            text = fh.read()
        eol = "\r\n" if "\r\n" in text else "\n"
        lines = text.split(eol)
        plan = plan_insertions(lines)
        if not plan:
            if not a.quiet:
                print("headers_added=0")
            return 0
        names = ", ".join(h[3:] for _, h in sorted(plan, key=lambda x: x[0]))
        if a.apply:
            new = eol.join(insert(lines, plan))
            tmp = f"{path}.{os.getpid()}.tmp"
            with open(tmp, "w", encoding="utf-8", newline="") as fh:
                fh.write(new)
            (jc.replace_with_retry if jc is not None else os.replace)(tmp, path)
            print(f"headers_added={len(plan)} ({names})")
        else:
            print(f"headers_added={len(plan)} ({names}) [dry-run: usa --apply]")
        return 0
    finally:
        if lock is not None:
            lock.release()


if __name__ == "__main__":
    sys.exit(main())
