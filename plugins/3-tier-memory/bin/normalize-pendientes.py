#!/usr/bin/env python3
"""
3-tier-memory plugin: garantiza los tres headers de prioridad en memory/_pendientes.md (v2.12.1).

El compactador del journal inserta cada `pendiente.add` bajo un header que empiece por
`## alta`, `## media` o `## baja` (sin distinguir mayusculas; `header_index` en
journal-compact.py). Instalaciones que adoptaron el plugin antes de 2.12.0 usan a veces otros
headers (`## Abiertos`, `P0 — ...`, secciones por semana o por tema): medido 2026-09-03 en 38
proyectos locales, 9 no tenian al menos uno de los tres. Este script anade SOLO los headers que
faltan; nunca mueve, borra ni reescribe items ni secciones existentes. Idempotente: con los tres
presentes no toca el archivo.

Desde 2.22.0 esto es PREVENCION, no la unica red: si un evento llega antes de que este hook haya
pasado (el plugin se actualizo con la sesion ya abierta, o el lock estaba ocupado), el compactador
crea el header que falte y aplica el evento en vez de cuarentenarlo. Este hook sigue existiendo
porque deja el archivo con los tres headers completos y en su sitio de una vez, no de uno en uno.

DONDE se inserta lo decide `plan_header_insertions`/`insert_headers` de journal-compact.py, que es
el unico sitio donde vive esa regla (dos copias de la misma politica es como se desincronizan:
learning 72). Resumen: el header que falta va pegado a su vecino canonico, y si no hay ninguno los
tres van justo antes de `## Related`. `## Abiertos`, `## Como usar` y cualquier otra seccion se
quedan donde estan. Se conserva el tipo de salto de linea del archivo (LF o CRLF).

Toma el lock del journal (memory/.journal/.lock, mismo que el compactador) para que dos sesiones
que arranquen a la vez no anadan el header dos veces; si no consigue el lock en el presupuesto, no
hace nada (lo hara la siguiente sesion, o el compactador al aplicar). Escribe tmp + os.replace con
reintento (`replace_with_retry`; en Windows un antivirus puede tener el .md abierto). Lock, reintento
y politica vienen de journal-compact.py, que en el plugin siempre esta en este mismo directorio; sin
el no hay nada que aplicar y el script sale 0 avisando por stderr.

Uso: normalize-pendientes.py MEMORY_DIR [--apply] [--quiet] [--budget SEG]
  Sin --apply solo informa. Salida: `headers_added=N (Alta prioridad, ...)` o nada con --quiet
  si N=0. Exit 0 siempre que el archivo exista o no (fail-open: es un hook de SessionStart).
"""
# sella-huellas: si
import argparse
import importlib.util
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

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
    if jc is None:
        # Copia suelta del script sin su journal-compact.py al lado: la politica de insercion
        # vive alli (una sola copia, learning 72), asi que aqui no hay nada que aplicar. Fail-open
        # porque esto corre en SessionStart: avisa por stderr y sale 0.
        print("normalize-pendientes: falta journal-compact.py en el mismo bin/", file=sys.stderr)
        if not a.quiet:
            print("headers_added=0 (sin journal-compact.py)")
        return 0
    if a.apply:
        lock = jc.Lock(os.path.join(a.memory_dir, ".journal"), a.budget)
        if not lock.acquire():
            if not a.quiet:
                print("headers_added=0 (journal busy; se reintenta en la proxima sesion)")
            return 0
    try:
        # newline="" conserva los saltos tal cual (CRLF en archivos escritos en Windows); se
        # parte y se vuelve a unir con el mismo separador para no reescribir ninguna otra linea.
        # La REGLA de deteccion es la misma que detect_eol() de journal-compact.py — si los dos
        # discreparan, cada pasada le daria la vuelta al fichero entero. Se parte por `\r?\n` y no
        # por `eol`: en un fichero de saltos MEZCLADOS, partir por "\r\n" dejaba el "\n" suelto
        # dentro de la ultima celda y rompia esa fila. Al reunir con `eol`, el fichero mezclado
        # sale con un solo salto, igual que lo dejaria atomic_write.
        with open(path, encoding="utf-8", newline="") as fh:
            text = fh.read()
        eol = "\r\n" if "\r\n" in text else "\n"
        lines = re.split(r"\r?\n", text)
        plan = jc.plan_header_insertions(lines)
        if not plan:
            if not a.quiet:
                print("headers_added=0")
            return 0
        names = ", ".join(h[3:] for _, h in sorted(plan, key=lambda x: x[0]))
        if a.apply:
            new = eol.join(jc.insert_headers(lines, plan))
            tmp = f"{path}.{os.getpid()}.tmp"
            with open(tmp, "w", encoding="utf-8", newline="") as fh:
                fh.write(new)
            jc.replace_with_retry(tmp, path)
            # Re-sellar: anadir una cabecera que falta es una escritura LEGITIMA del plugin. Sin
            # esto, el detector de deriva de journal-compact (2.13.2) la denunciaria como
            # "fuera del journal" y el aviso perderia todo su valor por cansancio.
            try:
                jc.guardar_huellas(a.memory_dir, os.path.join(a.memory_dir, ".journal"))
            except AttributeError:
                pass   # compactador anterior a 2.13.2
            print(f"headers_added={len(plan)} ({names})")
        else:
            print(f"headers_added={len(plan)} ({names}) [dry-run: usa --apply]")
        return 0
    finally:
        if lock is not None:
            lock.release()


if __name__ == "__main__":
    sys.exit(main())
