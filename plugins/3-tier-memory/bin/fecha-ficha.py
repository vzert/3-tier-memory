#!/usr/bin/env python3
"""
3-tier-memory plugin: la fecha con la que se nombra la ficha de una sesion.

POR QUE. `/checkpoint-3t` decia `DATE = today` y la fecha la elegia el agente. En una sesion que
trabaja con servidores, logs y `date -u`, el agente arrastra la fecha UTC; entre las 18:00 y las
24:00 de un huso al oeste de Greenwich esa fecha ya es la del dia siguiente. Medido en otro
proyecto: 8 de 71 checkpoints hechos a esas horas nombraron la ficha con la fecha UTC, y
`stamp-session-id.py`, que compara con la fecha LOCAL de la transcripcion con margen cero, no
sello ninguna de las 8. En las 8 el contexto de la sesion traia la fecha local correcta.

QUE HACE. Imprime la fecha LOCAL de esta maquina con la misma conversion que usa el sello
(`fecha_local` de `stamp-session-id.py`, cargada de ese fichero: una sola definicion). Una fecha
que un script compara no la escribe el agente de memoria.

Uso:
    fecha-ficha.py [--slug SLUG] [--ahora ISO_UTC]

Salida (stdout):
    DATE=YYYY-MM-DD            siempre, primera linea
    SLUG=<slug sin fecha>      con --slug
    SLUG_FECHA=YYYY-MM-DD      solo si el slug empezaba por una fecha
    AVISO: ...                 solo si esa fecha no es DATE

`--ahora` (o la variable `THREET_AHORA`) fija el instante, en ISO con zona (`2026-05-10T01:00:00Z`):
existe para las pruebas, que necesitan un cierre a las 20:00 sin esperar a esa hora.
Exit 0 si imprimio DATE; 2 si el instante pedido no se puede leer (no se inventa una fecha).
"""
# sella-huellas: no (solo imprime; no escribe ningun fichero)
import datetime
import importlib.util
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")


def _sello():
    """`stamp-session-id.py` como modulo: de ahi sale `fecha_local`, la conversion que el sello
    compara. Reimplementarla aqui dejaria dos definiciones de "fecha local" que pueden separarse."""
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stamp-session-id.py")
    spec = importlib.util.spec_from_file_location("stamp_session_id", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv):
    args = list(argv)
    opts = {}
    for k in ("--slug", "--ahora"):
        if k in args:
            i = args.index(k)
            if i + 1 >= len(args):
                print("fecha-ficha.py: falta el valor de %s" % k, file=sys.stderr)
                return 2
            opts[k] = args[i + 1]
            del args[i:i + 2]
    if args:
        print(__doc__.strip().split("Uso:")[1].split("\n\n")[0].strip(), file=sys.stderr)
        return 2

    ahora = opts.get("--ahora", os.environ.get("THREET_AHORA") or "")
    pedido = "--ahora" in opts or bool(ahora)
    if not pedido:
        ahora = datetime.datetime.now(datetime.timezone.utc).isoformat()
    fecha = _sello().fecha_local(ahora)
    # Un instante sin zona no dice de que huso es: se rechaza en vez de tomarlo por local o por UTC.
    if pedido and not re.search(r"(Z|[+-]\d{2}:?\d{2})$", ahora.strip()):
        fecha = None
    if not fecha:
        print("fecha-ficha.py: no se pudo leer el instante %r (ISO con zona, p. ej. "
              "2026-05-10T01:00:00Z)" % ahora, file=sys.stderr)
        return 2
    salida = ["DATE=" + fecha]

    if "--slug" in opts:
        slug = opts["--slug"].strip()
        if re.search(r"[\x00-\x1f]", slug):
            print("fecha-ficha.py: el slug trae saltos de linea o caracteres de control", file=sys.stderr)
            return 2
        if slug.endswith(".md"):
            slug = slug[:-3]
        m = re.match(r"(\d{4}-\d{2}-\d{2})-(.+)$", slug)
        try:
            # Solo cuenta como fecha lo que es una fecha: `2026-99-99-x` es un slug raro, no un dia.
            m and datetime.date.fromisoformat(m.group(1))
        except ValueError:
            m = None
        if not m:
            salida.append("SLUG=" + slug)
        else:
            salida.append("SLUG=" + m.group(2))
            salida.append("SLUG_FECHA=" + m.group(1))
            if m.group(1) != fecha:
                salida.append("AVISO: el slug traia la fecha %s y la fecha local es %s. Usa DATE, salvo que "
                      "esta sesion ya haya citado [[sessions/%s]] en un evento (un --origen o "
                      "--sesion ya emitido): ese enlace no se puede renombrar, asi que conserva "
                      "ese nombre." % (m.group(1), fecha, slug))
    print("\n".join(salida))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
