#!/usr/bin/env python3
"""
3-tier-memory plugin (2.57.0, p-b282a8cfc4): sella en la ficha lo que la sesion RECIBIO en su
snippet `Retomamos:`, para que el hilo de pendientes no dependa de leer la transcripcion despues.

Por que existe: el hilo (pendientes_afines.py, "El hilo") necesita saber que ids traia el snippet
con el que arranco la sesion. Ese dato solo esta en la transcripcion, y quien imprime el snippet
siguiente (print-como-retomar.py) corre dos veces: en el Step 8b y otra vez en el hook de cierre,
que puede correr sin `CLAUDE_CODE_SESSION_ID`. Si los dos leyeran la transcripcion, podrian dar dos
salidas. Asi que se lee UNA vez, aqui, y se escribe en el frontmatter:

  hilo_paso: p-…, plan-…     los ids del `Proximo paso` recibido
  hilo_heredados: p-…, …     los ids del paso, de la linea de extras y de `quedan N en el hilo`
  hilo_saltos: p-…=N, …      cuantas sesiones seguidas lleva cada heredado sin ser el paso: el de
                             la ficha anterior (la que el snippet manda leer) + 1 si en este
                             snippet tampoco fue el paso. Desde 2.70.0 ya no ordena el hilo:
                             un heredado no tocado no es del hilo (se deja por compatibilidad).
  hilo_retoma: <slug>        la ficha que el snippet mandaba leer (2.63.42): marcar-retomar.py
                             quita el `_retomar` que la apunta, porque esta sesion ya lo consumio.

Desde 2.70.0 escribe ademas, en CADA corrida (un re-checkpoint los refresca), dos campos que
no dependen de `Retomamos:`:

  hilo_trabajados: p-…, …    los pendientes abiertos que la sesion TRABAJO (paso_ajeno.trabajo_propio:
                             los creo, los pidio el usuario, los corrigio o cerro, o edito fuera de
                             memory/ algo que los nombra, fuera del turno del cierre). Haberlos
                             recibido en los extras o en `quedan N` del snippet no cuenta.
  hilo_planes: plan-…, …     los planes cuyo archivo la sesion edito (paso_ajeno.planes_editados).

Con ellos el hilo (pendientes_afines.hilo) es el trabajo propio de la sesion y no lo que el
snippet anterior le paso (decision de Victor del 2026-11-11). Van a stderr como `trabajados=N
planes=M`; la linea de stdout no cambia.

Si la sesion no arranco con `Retomamos:` no se sella el arranque (exit 0, `sellado=0`). Si la ficha no
es de esa transcripcion (la misma guardia que journal-emit: `ficha_de_la_sesion`), tampoco (exit 3). Si la ficha ya
tiene `hilo_paso`, no se pisa: el sello describe el arranque de la sesion y ese no cambia en un
re-checkpoint.

Uso:
  stamp-hilo.py SESSION_FILE (--transcript RUTA | --session-id ID [--jsonl-dir DIR])
"""
# sella-huellas: no (escribe solo el frontmatter de la ficha de esta sesion, no un indice)
import importlib.util
import os
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")


def _af():
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pendientes_afines.py")
    spec = importlib.util.spec_from_file_location("pendientes_afines", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _pa():
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "paso_ajeno.py")
    spec = importlib.util.spec_from_file_location("paso_ajeno", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


CAMPOS_VIVOS = ("hilo_trabajados", "hilo_planes")


def trabajo(af, ficha, trans, rec):
    """Las lineas `hilo_trabajados` y `hilo_planes` de esta sesion, o [] si no se pueden medir."""
    pa = _pa()
    pend = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(ficha))), "_pendientes.md")
    ids = [p["id"] for p in af.pendientes(pend)] if os.path.isfile(pend) else []
    paso = {x for x in rec["paso"] if x.startswith("p-")} if rec else None
    res = pa.trabajo_propio(trans, ids, paso) if ids else {}
    planes = pa.planes_editados(trans)
    if res is None or planes is None:
        return []
    trab = sorted(i for i, (ok, _) in res.items() if ok)
    print(f"trabajados={len(trab)} planes={len(planes)}", file=sys.stderr)
    return ["hilo_trabajados: " + ", ".join(trab), "hilo_planes: " + ", ".join(sorted(planes))]


def escribir(ficha, contenido, lineas):
    """Pone `lineas` al final del frontmatter, quitando antes las de los campos que reescriben."""
    fin = contenido.find("\n---", 3)
    claves = {l.split(":", 1)[0] for l in lineas}
    cabeza = "\n".join(l for l in contenido[:fin + 1].rstrip("\n").split("\n")
                       if l.split(":", 1)[0] not in claves)
    nueva = cabeza + "\n" + "\n".join(l.rstrip() for l in lineas) + "\n" + contenido[fin + 1:]
    tmp = ficha + ".stamp-tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(nueva)
    os.replace(tmp, ficha)


def salir(code, sellado, motivo):
    print(f"sellado={sellado} motivo={motivo}")
    return code


def main(argv):
    args = list(argv)
    opts = {}
    for k in ("--transcript", "--session-id", "--jsonl-dir"):
        if k in args:
            i = args.index(k)
            if i + 1 >= len(args):
                return salir(2, 0, f"falta-valor-de-{k}")
            opts[k] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    ficha = args[0]
    if not os.path.isfile(ficha):
        return salir(2, 0, f"no-existe-la-ficha:{ficha}")
    af = _af()
    trans = opts.get("--transcript")
    if not trans and opts.get("--session-id"):
        sid = opts["--session-id"]
        jd = opts.get("--jsonl-dir")
        cand = os.path.join(jd, sid + ".jsonl") if jd else None
        trans = cand if cand and os.path.isfile(cand) else af.transcripcion_de(sid)
    if not trans or not os.path.isfile(trans):
        return salir(0, 0, "sin-transcripcion")

    with open(ficha, encoding="utf-8", errors="replace") as fh:
        contenido = fh.read()
    if not contenido.startswith("---"):
        return salir(4, 0, "sin-frontmatter (corre antes ensure-frontmatter.py)")
    fin = contenido.find("\n---", 3)
    if fin == -1:
        return salir(4, 0, "frontmatter-sin-cierre")
    # La misma guardia que journal-emit: la ficha tiene que ser de la sesion de esa transcripcion
    # (sin `session_id` de otra, con su fecha dentro de la transcripcion, y escrita por ella).
    if not af.ficha_de_la_sesion(ficha, trans, os.path.splitext(os.path.basename(trans))[0]):
        return salir(3, 0, "la-ficha-no-es-de-esa-transcripcion")
    snip = af.snippet_de_transcripcion(trans)
    rec = af.recibido(snip) if snip else None
    # 2.70.0: lo trabajado y los planes editados se refrescan en cada corrida, con o sin sello.
    vivos = trabajo(af, ficha, trans, rec)
    if "hilo_paso" in af.frontmatter(contenido):
        if vivos:
            escribir(ficha, contenido, vivos)
        return salir(0, 0, "ya-sellada")
    if not snip:
        if vivos:
            escribir(ficha, contenido, vivos)
        return salir(0, 0, "la-sesion-no-arranco-con-Retomamos")

    previos = {}
    if rec["retoma"]:
        prev = os.path.join(os.path.dirname(os.path.abspath(ficha)), rec["retoma"] + ".md")
        if os.path.isfile(prev):
            with open(prev, encoding="utf-8", errors="replace") as fh:
                previos = af.sello(fh.read())[2]
    paso = set(rec["paso"])
    salt = {i: previos.get(i, 0) + 1 for i in rec["heredados"] if i not in paso}

    lineas = ["hilo_paso: " + ", ".join(rec["paso"]),
              "hilo_heredados: " + ", ".join(rec["heredados"]),
              "hilo_saltos: " + ", ".join(f"{i}={n}" for i, n in sorted(salt.items()))]
    if rec["retoma"]:
        lineas.append("hilo_retoma: " + rec["retoma"])
    escribir(ficha, contenido, lineas + vivos)
    return salir(0, 1, "sellada")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
