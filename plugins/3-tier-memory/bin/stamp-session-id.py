#!/usr/bin/env python3
"""
3-tier-memory plugin: sella `session_id` en el frontmatter de una ficha de sesion.

POR QUE. Hasta 2.19.5 no habia NINGUNA llave que uniera un `.jsonl` con su ficha en
`memory/sessions/`: el frontmatter llevaba `type`, `date`, `status` e `importance`, y nada mas.
El dedup de `/backfill-3t` se apoyaba en `customTitle`, que viene `null` en los 22 JSONL de este
proyecto (no comprobado en otras versiones ni modos), asi que ahi no podia casar nunca. `bin/match-session-file.py` reconstruye la union hacia atras observando que ficha escribio cada
transcripcion; esto la deja ESCRITA en la ficha, para que el run siguiente no tenga que
reconstruir nada.

QUE ES Y QUE NO ES ESTE SELLO. Lo que se escribe es lo que DECLARA quien llama: "esta ficha salio
de esta transcripcion". No es una prueba criptografica de identidad y no puede serlo — cuando el
checkpoint sella, la transcripcion aun no contiene la escritura de la ficha, asi que no hay nada
contra lo que verificarla. Lo que si se hace es rechazar la declaracion cuando no cuadra: que el
`.jsonl` exista, que la fecha de la ficha caiga dentro del rango de fechas de esa transcripcion, y
que no haya ya un sello distinto. Eso ataja el error de llamante —el UUID arrastrado de otra
sesion—, no a un adversario. Y conviene saber lo flojo que es como filtro: medido en este
proyecto el 2026-09-12, con un dia de margen un mismo UUID podia sellar hasta 14 fichas distintas;
con margen cero, 11. Bajar el margen no arregla eso —hay varias sesiones al dia— y por eso la
correccion de fondo fue dejar de llamarlo "exacto". Lo que si ataja el margen cero, junto con el
fail-cerrado, es el caso grosero: el UUID de otra semana, la fecha ilegible, la transcripcion sin
un solo timestamp valido.

QUIEN LO LLAMA:
  - `/checkpoint-3t` Step 5c, con `$CLAUDE_CODE_SESSION_ID`, sobre la ficha que acaba de escribir.
  - `/backfill-3t` Step 3, con el UUID del `.jsonl` de origen, sobre la ficha que acaba de
    reconstruir — asi el run siguiente la reconoce aunque se pierda `.backfill-progress.json`.

POR QUE COMPRUEBA ANTES DE SELLAR. En el matcher el sello GANA a la evidencia de escritura, asi
que un sello equivocado no produce un duplicado visible: produce el fallo invisible —una sesion
marcada como ya-importada que nunca se importo—. Por eso, con `--jsonl-dir`, se exige que el
`.jsonl` exista de verdad, y nunca se pisa un sello distinto que ya estuviera puesto.

Uso:
    stamp-session-id.py <FICHA.md> <SESSION_ID> [--jsonl-dir DIR]

Salida (stdout): una linea `stamped=<0|1> reason=<...>`
Exit 0 si la ficha queda con el sello correcto (puesto ahora o ya puesto); != 0 si no.
"""
# sella-huellas: no (escribe una clave de frontmatter en una ficha, no toca ningun indice)
import datetime
import json
import os
import re
import sys

# UTF-8 en stdout Y EN STDERR. Se pone en TODOS los .py de bin/: cual imprime no-ASCII no se
# puede decidir leyendo el fuente (una ruta, el mensaje de una excepcion), y el detector que lo
# intentaba fue justo lo que dejo pasar el hueco que arreglo 2.19.x.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

UUID = re.compile(r'^[0-9a-fA-F][0-9a-fA-F-]{7,}$')
SESSION_ID_FM = re.compile(r'^\s*session_id\s*:\s*(\S+)\s*$', re.M)


# Margen CERO. `fecha_local()` ya convierte el timestamp UTC del JSONL al huso de esta maquina, y
# el sello siempre se escribe en la maquina que tiene la transcripcion delante, asi que no hay
# desfase entre husos que absorber. Con un dia de margen a cada lado, un UUID cualquiera de este
# proyecto podia sellar entre 3 y 14 fichas distintas —lo midio un adversario externo el
# 2026-09-12— y eso no es una comprobacion, es un colador. (El matcher SI conserva su margen: ahi
# se comparan ficheros que pudieron escribirse en otra maquina.)
MARGEN_DIAS = 0


def fecha_del_nombre(ruta):
    """'…/2026-09-12-slug.md' -> '2026-09-12'. Vacio si el nombre no empieza por fecha."""
    m = re.match(r'(\d{4}-\d{2}-\d{2})-', os.path.basename(ruta))
    return m.group(1) if m else ""


def fecha_local(ts):
    """Timestamp UTC del JSONL -> fecha en el huso de esta maquina."""
    if not isinstance(ts, str) or len(ts) < 10:
        return None
    # Si no parsea, se devuelve None, NO `ts[:10]`. Ese recorte fabricaba una fecha con pinta de
    # buena a partir de cualquier cadena ("2020-06-15XXXXXXX" -> "2020-06-15"), y con eso una
    # transcripcion sin un solo timestamp valido pasaba por transcripcion fechada: el fail-cerrado
    # de mas abajo no llegaba a ejecutarse jamas. Lo encontro un adversario en la tercera ronda,
    # construyendo el fichero de basura y sellando contra el.
    try:
        dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except (ValueError, TypeError, OSError):
        return None
    try:
        # OverflowError: un ano ISO valido (0001, 9999) puede salirse de [MINYEAR, MAXYEAR] al
        # convertir a huso local si el huso empuja la fecha al otro lado del limite. Lo encontro
        # un adversario en la cuarta ronda: sin este except la excepcion no capturada tumbaba el
        # proceso entero -- en el matcher, TODO el corpus, no solo esta transcripcion -- en vez de
        # devolver None y dejar que el fail-cerrado de mas abajo actue.
        return dt.astimezone().date().isoformat() if dt.tzinfo else dt.date().isoformat()
    except (ValueError, OSError, OverflowError):
        return None


def rango_local(transcripcion):
    """(primera, ultima) fecha local de la transcripcion, o (None, None) si no se puede leer."""
    primera = ultima = None
    try:
        with open(transcripcion, encoding="utf-8", errors="replace") as fh:
            for linea in fh:
                try:
                    o = json.loads(linea)
                except (ValueError, TypeError):
                    continue
                f = fecha_local(o.get("timestamp"))
                if not f:
                    continue
                if primera is None or f < primera:
                    primera = f
                if ultima is None or f > ultima:
                    ultima = f
    except OSError:
        return None, None
    return primera, ultima


def en_rango(fecha, primera, ultima):
    try:
        f = datetime.date.fromisoformat(fecha)
        a = datetime.date.fromisoformat(primera) - datetime.timedelta(days=MARGEN_DIAS)
        b = datetime.date.fromisoformat(ultima) + datetime.timedelta(days=MARGEN_DIAS)
    except (ValueError, TypeError, OverflowError):
        # Fail CERRADO. La version anterior devolvia True aqui —"no se puede decidir, pues pasa"—
        # y eso convertia una fecha ilegible en una puerta de servicio hacia el unico fallo que
        # este script existe para impedir. Si no se puede comprobar, no se sella.
        #
        # `OverflowError` aqui es LATENTE, no activa: con `MARGEN_DIAS = 0` la resta y la suma no
        # desbordan nunca. Se nombra porque el mismo `en_rango` de `match-session-file.py` (margen 1)
        # SI abortaba el proceso entero por esto, y la unica diferencia entre los dos es una
        # constante. Subir el margen aqui no debe reabrir ese fallo.
        return False
    return a <= f <= b


def salir(codigo, sellado, razon):
    print("stamped=%d reason=%s" % (sellado, razon))
    return codigo


def main():
    argv = sys.argv[1:]
    jsonl_dir = ""
    if "--jsonl-dir" in argv:
        i = argv.index("--jsonl-dir")
        if i + 1 < len(argv):
            jsonl_dir = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if len(argv) < 2:
        return salir(2, 0, "uso: stamp-session-id.py <FICHA.md> <SESSION_ID> [--jsonl-dir DIR]")

    ficha, sid = argv[0], argv[1].strip()
    if not sid or not UUID.match(sid):
        return salir(2, 0, "session-id-no-parece-uuid:%s" % (sid or "<vacio>"))
    if not os.path.isfile(ficha):
        return salir(2, 0, "no-existe-la-ficha:%s" % ficha)

    # Prueba de que ese id corresponde a ESTA ficha. Comprobar solo que el UUID tenga algun
    # `.jsonl` no basta: con eso cualquier id existente puede sellar cualquier ficha sin sellar, y
    # como en el matcher el sello GANA a la evidencia de escritura, el resultado es justo la
    # perdida invisible que esto existe para impedir. Lo encontro un adversario externo el
    # 2026-09-12, antes de publicar. Asi que ademas se exige que las fechas cuadren: la fecha del
    # nombre de la ficha tiene que caer dentro del rango de la transcripcion, con un dia de margen
    # a cada lado (los ts del JSONL son UTC, el nombre de la ficha es hora local, y una sesion
    # puede cruzar la medianoche).
    if jsonl_dir:
        transcripcion = os.path.join(jsonl_dir, sid + ".jsonl")
        if not os.path.isfile(transcripcion):
            return salir(3, 0, "no-hay-jsonl-para-ese-id:%s" % sid)
        fecha_ficha = fecha_del_nombre(ficha)
        primera, ultima = rango_local(transcripcion)
        # TODA rama de esta comprobacion falla CERRADO: si no se puede comprobar, no se sella.
        # Que "no he podido comprobarlo" dejara pasar el sello era justo lo contrario de para lo
        # que sirve. Los casos que el banco fija, cada uno con su mutacion: nombre sin fecha,
        # transcripcion sin un solo timestamp valido, fecha del nombre imposible (revienta dentro
        # de `en_rango`), y fechas que no cuadran —incluido un solo dia de diferencia—. No se
        # afirma que sean TODAS las formas de fallar: se afirma que la salida por defecto de cada
        # rama es no sellar, que es lo que se puede sostener.
        if not fecha_ficha:
            return salir(6, 0, "el-nombre-de-la-ficha-no-empieza-por-fecha")
        if not (primera and ultima):
            return salir(6, 0, "la-transcripcion-no-tiene-timestamps-legibles")
        if not en_rango(fecha_ficha, primera, ultima):
            return salir(6, 0, "la-ficha-es-de-%s y-la-transcripcion-de-%s..%s"
                         % (fecha_ficha, primera, ultima))

    with open(ficha, encoding="utf-8", errors="replace") as fh:
        contenido = fh.read()

    if not contenido.startswith("---"):
        # Sellar un fichero sin frontmatter significaria inventarselo entero, y de eso se ocupa
        # ensure-frontmatter.py, que es quien tiene esa responsabilidad.
        return salir(4, 0, "sin-frontmatter (corre antes ensure-frontmatter.py)")
    fin = contenido.find("\n---", 3)
    if fin == -1:
        return salir(4, 0, "frontmatter-sin-cierre")

    cabeza, cola = contenido[:fin + 1], contenido[fin + 1:]
    ya = SESSION_ID_FM.search(cabeza)
    if ya:
        if ya.group(1).strip() == sid:
            return salir(0, 0, "ya-sellada-con-el-mismo-id")
        # Pisar el sello de otra sesion es exactamente el fallo invisible que esto evita.
        return salir(5, 0, "ya-sellada-con-otro-id:%s" % ya.group(1).strip())

    nueva = cabeza.rstrip("\n") + "\nsession_id: " + sid + "\n" + cola

    # Escritura atomica: un checkpoint interrumpido no debe dejar la ficha a medias.
    tmp = ficha + ".stamp-tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(nueva)
    os.replace(tmp, ficha)
    return salir(0, 1, "sellada")


if __name__ == "__main__":
    sys.exit(main())
