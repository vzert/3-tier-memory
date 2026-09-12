#!/usr/bin/env python3
"""Reune la EVIDENCIA de cada pendiente abierto para que un humano (o su agente) decida.

NO CLASIFICA. Tres mediciones de este proyecto dicen por que:
    - regla 93: un regex sobre el texto no puede decir el criterio de cierre (fallo 3 veces).
    - regla 102: tampoco la decidibilidad (21 -> 10 -> 0 al apretar la definicion).
    - 2026-09-11: caducar por edad se lleva 29 de 30 items que seguian VIVOS bajo la rubrica
      congelada (19 de 30 solo si se acepta un codigo anadido tras ver los resultados).
Este script solo junta lo que hace falta para leer el item con contexto. La decision la toma
quien lee, item por item, como en el Step 3a del checkpoint.

LA SENAL QUE IMPORTA
    "¿alguna sesion POSTERIOR habla de este tema?" — es lo unico que separa
    "ya se hizo y nadie lo marco" de "sigue vivo y nadie lo ha tocado".
    Se calcula por solape de palabras significativas (>=5 letras) entre el texto del pendiente y
    el de cada session file con fecha posterior a `_creado`. **Es un emparejador por texto: sirve
    para apuntar a que fichero leer, no para concluir nada.** Por eso imprime el slug de la sesion
    mas reciente que casa: para ir a leerla.

PAGINACION POR CURSOR ESTABLE, NO POR POSICION
    Un `--offset` numerico se rompe en cuanto el lote anterior cierra items: la lista se acorta,
    todo se corre hacia adelante y el lote siguiente **se salta** los que ocuparon los huecos.

    El cursor es `--desde <fecha>:<id>:<digito>` — la clave de orden del ultimo item mostrado, mas
    un digito de control. Ni la fecha de creacion ni el id cambian porque otros items se cierren,
    y el par es unico, asi que el lote siguiente empieza EXACTAMENTE despues del ultimo visto: ni
    repite ni salta. El digito solo detecta que la cadena llegue manglada; **no** demuestra
    procedencia — es una sha1 publica del id, y el adversario de la ronda 5 fabrico un cursor
    valido con ella. Contra un id inventado lo que protege es que el item tenga `_id` persistente,
    que es lo que pone `enrich-memory.py`. (Rondas 4 y 5 del adversario.)

    Una primera version usaba solo la fecha y era **inclusiva**: con mas items del mismo dia que
    `--limit`, y si el usuario los dejaba abiertos, el mismo lote se repetia para siempre y los
    demas de ese dia no se alcanzaban nunca. Los items sin `_creado` tampoco se podian pasar.
    (Los dos, hallazgo del adversario en su segunda ronda, 2026-09-11.) Por eso la clave lleva el
    id, y los items sin fecha van al final con la clave `SIN`, alcanzables como cualquier otro.

USO
    triage-scan.py [--memory-dir DIR] [--desde FECHA:ID:DIGITO] [--limit 25] [--prioridad Alta]
    triage-scan.py --tsv > barrido.tsv

SALIDA POR ITEM
    id · prioridad · edad · origen · ventana(_revisar:) · sesiones posteriores que mencionan el tema
"""
# sella-huellas: no (solo lee _pendientes.md y reporta; el barrido cierra por eventos)
import argparse
import glob
import hashlib
import os
import re
import sys
import unicodedata
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
ORIGEN = re.compile(r"_origen: ([^_]+)_")
ID = re.compile(r"_id: (p-[0-9a-f]{10})_")
META = re.compile(r"\s*—\s*_(origen|creado|id|revisar):[^—]*")


def parse_date(s):
    y, m, d = (int(x) for x in s.split("-"))
    return date(y, m, d)


def norm(t):
    t = unicodedata.normalize("NFKD", t).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9 ]", " ", t.lower())


def sig(t):
    return {w for w in norm(t).split() if len(w) >= 5}


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


def cargar_sesiones(mem):
    """[(fecha, slug, palabras)] de cada session file con fecha en el nombre."""
    out = []
    for f in sorted(glob.glob(os.path.join(mem, "sessions", "*.md"))):
        slug = os.path.basename(f)[:-3]
        m = re.match(r"^(\d{4}-\d{2}-\d{2})", slug)
        if not m:
            continue
        try:
            out.append((parse_date(m.group(1)), slug,
                        sig(open(f, encoding="utf-8", errors="replace").read())))
        except OSError:
            continue
    return out


def sintetico(texto):
    """Id sintetico de un item sin `_id`, derivado de su texto y no de su posicion en el fichero."""
    # Solo se colapsan los espacios: `norm()` quita acentos y puntuacion, y eso haria colisionar
    # items realmente distintos. Aqui hace falta identidad, no parecido.
    base = re.sub(r"\s+", " ", unicodedata.normalize("NFC", texto)).strip()
    h = hashlib.sha1(base.encode("utf-8")).hexdigest()[:10]
    return f"sin-id-{h}"


def digito(cid):
    """Digito de control del cursor. Detecta que la cadena venga MANGLADA, y nada mas.

    Lo que hace: si copias el cursor y se pierde un caracter, o lo escribes mal, el digito deja
    de cuadrar y el script lo dice en vez de cortar por un id que no querias.

    Lo que NO hace, y esto se afirmo mal en la ronda 4: **no demuestra procedencia**. Se calcula
    con una sha1 publica sobre el propio id, asi que cualquiera que la corra fabrica un cursor
    valido. El adversario de la ronda 5 construyo `2026-01-01:p-deadbeef00:8ae6` — id inventado,
    digito correcto — y el script salio con codigo 0. La afirmacion "distingue un cursor copiado
    de uno tecleado" era falsa y esta retirada.

    Lo que SI da procedencia es que el item tenga un `_id` persistente: entonces no hay id
    sintetico, no hay renumeracion, y un `p-...` inventado cae sobre una clave de orden real o no
    cae. Eso ya existe — `enrich-memory.py` (`enrich_ids`) se lo pone a los items que tienen
    `_creado`. Ver la regla 114 de learnings/3tier-memory-system.
    """
    return hashlib.sha1(f"triage-cursor:{cid}".encode("utf-8")).hexdigest()[:4]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--memory-dir")
    ap.add_argument("--desde", metavar="FECHA:ID:DIGITO",
                    help="cursor estable que imprime el lote previo, copiado TAL CUAL "
                         "(p.ej. 2026-04-02:p-ab12cd34ef:9f3c). El digito del final detecta que la "
                         "cadena llegue manglada; no demuestra que venga de un lote")
    ap.add_argument("--limit", type=int, default=25)
    ap.add_argument("--prioridad", choices=("Alta", "Media", "Baja"))
    ap.add_argument("--tsv", action="store_true", help="salida completa en TSV, sin paginar")
    a = ap.parse_args()

    mem = resolve_memory_dir(a.memory_dir)
    path = os.path.join(mem, "_pendientes.md")
    if not os.path.isfile(path):
        sys.exit(f"triage-scan: no existe {path}")
    hoy = date.today()
    sesiones = cargar_sesiones(mem)

    items, prio, sin_id = [], "?", {}
    for raw in open(path, encoding="utf-8", errors="replace"):
        h = re.match(r"^##+\s*(.+)", raw)
        if h:
            t = h.group(1).lower()
            prio = ("Alta" if "alta" in t else "Media" if "media" in t else
                    "Baja" if "baja" in t else prio)
            continue
        if not raw.lstrip().startswith("- [ ]"):
            continue
        line = raw.rstrip("\n")
        mi, mc = ID.search(line), CREADO.search(line)
        texto = re.sub(r"\s+", " ", META.sub("", line.strip()[5:].strip()))
        creado = parse_date(mc.group(1)) if mc else None
        mr = REVISAR.search(line)
        if mr:
            f = parse_date(mr.group(1))
            ventana = f"vence {mr.group(1)}" if f > hoy else f"VENCIDA {mr.group(1)}"
        else:
            ventana = "—"
        mo = ORIGEN.search(line)
        origen = re.sub(r"\[\[sessions/|\]\]|\[\[|\]\]", "", mo.group(1)).strip() if mo else "—"
        w = sig(texto)
        posteriores = []
        if creado and len(w) >= 3:
            for fecha, slug, palabras in sesiones:
                if fecha > creado and len(w & palabras) / len(w) >= 0.5:
                    posteriores.append(slug)
        if not mi:
            # Sin `_id` no hay desempate estable. La ronda 3 les dio uno sintetico por POSICION,
            # y la ronda 4 lo rompio: la posicion cambia cuando se cierra un item anterior, asi
            # que `sin-id-0002` pasaba a ser `sin-id-0001` y el corte estricto se lo saltaba para
            # siempre. Ahora sale del TEXTO del item, que no depende de que haya alrededor.
            # Dos items de texto identico colisionan a proposito: son indistinguibles para el
            # cursor de todas formas, y el sufijo los separa de forma estable mientras ellos lo sean.
            clave_txt = sintetico(texto)
            sin_id[clave_txt] = sin_id.get(clave_txt, 0) + 1
            n_rep = sin_id[clave_txt]
            sid = clave_txt if n_rep == 1 else f"{clave_txt}-{n_rep}"
        items.append({
            "id": mi.group(1) if mi else sid,
            "prio": prio,
            "edad": (hoy - creado).days if creado else None,
            "creado": creado,
            "origen": origen,
            "ventana": ventana,
            "post": posteriores,
            "texto": texto,
        })

    abiertos_totales = len(items)   # ANTES del filtro: distingue "no hay nada" de "el filtro no casa"
    if a.prioridad:
        items = [i for i in items if i["prio"] == a.prioridad]
    # Clave de orden = (creado, id). Los sin fecha van al final con date.max, y su id los ordena
    # igual que a los demas, asi que el cursor tambien los pasa.
    def clave(i):
        return (i["creado"] or date.max, i["id"])

    def cursor_de(i):
        c = i["creado"].isoformat() if i["creado"] else "SIN"
        return f"{c}:{i['id']}:{digito(i['id'])}"

    items.sort(key=clave)
    total = len(items)
    saltados = 0
    if a.desde:
        partes = a.desde.split(":")
        if len(partes) != 3:
            sys.exit("triage-scan: --desde debe ser FECHA:ID:DIGITO (o SIN:ID:DIGITO), tal como lo "
                     "imprime el lote previo. Copialo entero, incluido el digito del final.")
        cf, cid, dig = partes
        try:
            corte = (date.max if cf == "SIN" else date.fromisoformat(cf), cid)
        except ValueError:
            sys.exit(f"triage-scan: '{cf}' no es una fecha real ni 'SIN'")
        if not re.match(r"^(p-[0-9a-f]{10}|sin-id-[0-9a-f]{10}(-\d+)?)$", cid):
            sys.exit(f"triage-scan: '{cid}' no es un id valido; copia el cursor tal cual lo "
                     f"imprime el lote previo")
        # El digito solo detecta una cadena manglada. NO demuestra procedencia: es una sha1
        # publica del propio id (roto por el adversario en la ronda 5). Contra un id inventado lo
        # que protege de verdad es que el item tenga `_id` persistente. Ver digito().
        if dig != digito(cid):
            sys.exit(f"triage-scan: el digito de control de '{a.desde}' no cuadra con '{cid}'; la "
                     f"cadena llego manglada. Copia el cursor entero, tal cual lo imprime el lote "
                     f"previo. (El digito solo detecta eso: NO demuestra que el cursor venga de "
                     f"un lote.)")
        # NO se exige que el cursor siga abierto: cerrarlo es justo lo que hace el barrido, y el
        # corte (fecha, id) funciona igual sobre un id que ya no existe — para eso es estable.
        if not any(i["id"] == cid for i in items):
            print(f"  aviso: {cid} ya no esta abierto (normal si lo cerraste en el lote previo); "
                  f"el corte sigue siendo exacto", file=sys.stderr)
        restantes = [i for i in items if clave(i) > corte]   # ESTRICTO: ni repite ni salta
        saltados = total - len(restantes)
        items = restantes

    if a.tsv:
        print("id\tprioridad\tedad\torigen\tventana\tn_posteriores\tultima_posterior\ttexto")
        for i in items:
            print(f"{i['id']}\t{i['prio']}\t{i['edad']}\t{i['origen']}\t{i['ventana']}\t"
                  f"{len(i['post'])}\t{i['post'][-1] if i['post'] else '—'}\t{i['texto']}")
        return

    sel = items[:a.limit]
    print(f"memoria: {mem}")
    print(f"abiertos: {total}" + (f" (prioridad {a.prioridad})" if a.prioridad else ""))
    if a.desde:
        print(f"cursor --desde {a.desde}: {saltados} ya pasaron por un lote previo, "
              f"{len(items)} por revisar")
    if not items:
        # Sin cursor, "tras ese cursor" no se refiere a nada: es lo primero que ve una instalacion
        # nueva, cuyo _pendientes.md esta vacio.
        if a.desde:
            print("\nNo queda nada por revisar tras ese cursor.")
        elif abiertos_totales == 0:
            print("\nNo hay pendientes abiertos: nada que barrer.")
        else:
            print(f"\nNinguno de los {abiertos_totales} pendientes abiertos es de "
                  f"prioridad {a.prioridad}.")
        return
    print(f"mostrando {len(sel)}, mas viejos primero")
    print()
    print("La columna 'posteriores' NO decide nada: dice que sesiones hablan del mismo tema")
    print("despues de que el item nacio. Sirve para saber que fichero leer antes de opinar.")
    print()
    for i in sel:
        edad = f"{i['edad']}d" if i["edad"] is not None else "?"
        print(f"  {i['id']}  {i['prio']:5s}  {edad:>5s}  ventana: {i['ventana']}")
        print(f"    {i['texto'][:150]}")
        print(f"    origen: {i['origen']}")
        if i["post"]:
            print(f"    posteriores ({len(i['post'])}): {', '.join(i['post'][-3:])}")
        else:
            print("    posteriores: ninguna — nadie volvio a tocar el tema")
        print()
    if len(items) > a.limit and sel:
        print(f"Siguiente lote:  --desde {cursor_de(sel[-1])} --limit {a.limit}")
        print("  (el cursor es (fecha, id), no una posicion: cerrar items de este lote no")
        print("   descoloca el siguiente, y el corte es estricto — ni repite ni salta.)")


if __name__ == "__main__":
    main()
