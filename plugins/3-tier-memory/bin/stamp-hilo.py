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
                             snippet tampoco fue el paso. Con 2 o
                             mas, el heredado le gana el empate al nuevo (regla 3 de Victor).

Si la sesion no arranco con `Retomamos:` no se sella nada (exit 0, `sellado=0`). Si la ficha no
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
    if "hilo_paso" in af.frontmatter(contenido):
        return salir(0, 0, "ya-sellada")

    # La misma guardia que journal-emit: la ficha tiene que ser de la sesion de esa transcripcion
    # (sin `session_id` de otra, con su fecha dentro de la transcripcion, y escrita por ella).
    if not af.ficha_de_la_sesion(ficha, trans, os.path.splitext(os.path.basename(trans))[0]):
        return salir(3, 0, "la-ficha-no-es-de-esa-transcripcion")
    snip = af.snippet_de_transcripcion(trans)
    if not snip:
        return salir(0, 0, "la-sesion-no-arranco-con-Retomamos")
    rec = af.recibido(snip)

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
    cabeza, cola = contenido[:fin + 1], contenido[fin + 1:]
    nueva = cabeza.rstrip("\n") + "\n" + "\n".join(l.rstrip() for l in lineas) + "\n" + cola
    tmp = ficha + ".stamp-tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(nueva)
    os.replace(tmp, ficha)
    return salir(0, 1, "sellada")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
