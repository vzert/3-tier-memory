#!/usr/bin/env python3
"""
3-tier-memory plugin: JSONL <-> memory/sessions/ matcher (dedup de /backfill-3t Step 1).

POR QUE EXISTE. Step 1 clasificaba "already in memory" comparando `customTitle` del JSONL
con el titulo de la ficha. `customTitle` viene `null` en los 22 JSONL de este proyecto (medido 2026-09-12: 0 de
22). No se ha comprobado en otras versiones de Claude Code, otros modos ni otras
instalaciones: puede que en alguna venga relleno. Da igual para el dedup — cuando venga,
sera informacion de mas, no de menos — pero la medicion es local y asi se dice. Con ese campo vacio la regla no
puede casar nunca: una ejecucion literal reimporta sesiones que ya tienen ficha y las duplica. Lo
unico que impidio el duplicado hasta ahora fue el criterio de un agente leyendo, no la regla
escrita.

LA LLAVE, EN DOS CAPAS:

  1. SELLO (declarado y comprobado, hacia adelante). `/checkpoint-3t` escribe `session_id:` en
     el frontmatter de la ficha (ver stamp-session-id.py). Es lo que DECLARA quien lo escribe —
     "esta ficha salio de esta transcripcion"— y el sellador solo lo acepta si cuadra: que el
     `.jsonl` exista y que la fecha de la ficha caiga en el rango de esa transcripcion. No es una
     prueba criptografica de identidad y no puede serlo: cuando el checkpoint sella, la
     transcripcion aun no contiene la escritura de la ficha. Ataja el error de llamante, que es lo
     que pasa en la practica, y ahorra la heuristica.

  2. ESCRITURA OBSERVADA (determinista, hacia atras). Para las 46 fichas que nunca tendran
     sello: una sesion que escribio su propia ficha dejo esa escritura en su transcripcion.
     Se busca en el JSONL la ESCRITURA del fichero, no su mencion — `cat memory/sessions/x.md`
     (leer) y `cat > memory/sessions/x.md` (escribir) mencionan la misma ruta y significan lo
     contrario. Medido: esta misma sesion menciona la ficha de la sesion anterior 6 veces sin
     haber escrito una sola.

  Y una restriccion de fecha encima, porque una sesion que corrio un backfill escribio las
  fichas de OTRAS sesiones: solo cuenta como ficha propia la que cae dentro del rango de
  fechas del propio JSONL.

ANTE DUDA NO DECIDE. Si no hay prueba de identidad pero SI una ficha de la misma fecha que
nadie mas reclama, el veredicto es `review`: lo resuelve una persona antes de que Step 2
escriba nada. Decidir por parecido tiene un fallo invisible —marcar como ya-importada una
sesion que no lo esta, y perderla para siempre— y esta regla existe para no correr ese riesgo.

Uso:
    match-session-file.py <MEMORY_DIR> <JSONL_DIR> [--current <session_id>]

Salida (stdout): un unico objeto JSON
    {"results": [{"jsonl","stem","dateFirst","dateLast","verdict","reason","matched"}...],
     "counts": {"match":N,"review":N,"process":N,"current":N}}

Veredictos: match | review | process | current
Exit 0 siempre (el que llama decide que hacer con los conteos).
"""
# sella-huellas: no (solo lee JSONL y fichas, y reporta veredictos)
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

# Ficha de sesion: memory/sessions/YYYY-MM-DD-<slug>.md
RUTA_FICHA = re.compile(r'(?:memory/)?sessions/((\d{4}-\d{2}-\d{2})-[A-Za-z0-9._-]+\.md)')
# Una ruta bajo /tmp, un mktemp o un snapshot NO es la ficha: es una copia de trabajo con el
# mismo nombre. Medido 2026-09-12: una sesion que copio una ficha a un directorio temporal para
# una prueba salia como si la hubiera creado, y eso mandaba a REVISAR a la sesion dueña.
SCRATCH = re.compile(r'(/tmp/|/private/tmp/|scratch|snap|\$T\b|\$\{T\}|mktemp|/var/folders/)')
SESSION_ID_FM = re.compile(r'^\s*session_id\s*:\s*([0-9a-fA-F-]{8,})\s*$', re.M)

# Un `>` que redirige, `tee`, `sed -i`, `cp`/`mv` de destino: escritura.
# Se mira SOLO el tramo de comando inmediatamente anterior a la ruta, cortado en `;`, `&&`,
# `||`, `|` y salto de linea, para que un redirect de otro tramo no contamine este.
ESCRITURA = re.compile(r'(>>?|\btee\b|\bsed\b[^|;&\n]*\s-i\b|\bcp\b|\bmv\b|\bdd\b[^|;&\n]*\bof=)')
CORTE = re.compile(r'[;\n]|&&|\|\||\|')


# Los timestamps del JSONL son UTC (`...Z`); la fecha del nombre de la ficha la pone el
# checkpoint en hora LOCAL. Una sesion de las 21:36 de CDMX es ya el dia siguiente en UTC, asi
# que comparar las dos crudas desplaza un dia y deja fuera la ficha propia. Medido 2026-09-12:
# dos de los cinco "sin ficha" del primer run SI la tenian, y una ejecucion literal las habria
# duplicado — el mismo fallo que este script existe para impedir.
# Se convierte a local Y se deja un margen de un dia a cada lado: la maquina que reimporta puede
# estar en otro huso que la que escribio la ficha. El margen NO afloja la prueba de identidad
# (sigue exigiendose la escritura observada), solo la comprobacion de cordura de la fecha.
MARGEN_DIAS = 1


def fecha_local(ts):
    """'2026-09-10T03:36:01.268Z' -> '2026-09-09' en el huso de esta maquina."""
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


def en_rango(fecha, primera, ultima):
    """fecha dentro de [primera-MARGEN, ultima+MARGEN], todo en ISO YYYY-MM-DD."""
    if not (fecha and primera and ultima):
        return False
    try:
        f = datetime.date.fromisoformat(fecha)
        a = datetime.date.fromisoformat(primera) - datetime.timedelta(days=MARGEN_DIAS)
        b = datetime.date.fromisoformat(ultima) + datetime.timedelta(days=MARGEN_DIAS)
    except (ValueError, TypeError):
        return False
    return a <= f <= b


def distancia_dias(fecha, referencia):
    """|fecha - referencia| en dias; grande si alguna no parsea, para que nunca gane."""
    try:
        a = datetime.date.fromisoformat(fecha)
        b = datetime.date.fromisoformat(referencia)
    except (ValueError, TypeError):
        return 10 ** 6
    return abs((a - b).days)


def stem(nombre):
    """UUID sin extension, para comparar JSONL y sello en el mismo alfabeto."""
    if not nombre:
        return ""
    base = os.path.basename(str(nombre))
    return base[:-6] if base.endswith(".jsonl") else base


def fichas_existentes(memory_dir):
    """{nombre_fichero: {'date':..., 'session_id':...}} de memory/sessions/."""
    out = {}
    d = os.path.join(memory_dir, "sessions")
    if not os.path.isdir(d):
        return out
    for nombre in os.listdir(d):
        p = os.path.join(d, nombre)
        # isfile: un DIRECTORIO llamado `algo.md` no es una ficha. Mismo defecto que el
        # contador de 2.15.2 tenia con `ls *.jsonl` sobre un directorio.
        if not nombre.endswith(".md") or not os.path.isfile(p):
            continue
        m = re.match(r'(\d{4}-\d{2}-\d{2})-', nombre)
        sid = ""
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                cabeza = fh.read(600)
            g = SESSION_ID_FM.search(cabeza)
            if g:
                sid = g.group(1).strip()
        except OSError:
            pass
        out[nombre] = {"date": m.group(1) if m else "", "session_id": sid}
    return out


def es_escritura(cmd, inicio, fichero):
    """True si esta ocurrencia de la ruta es una ESCRITURA del fichero.

    Tres idiomas, porque en este repo conviven los tres y el que mas se usa no lleva `>`:

      (a) redireccion de shell:  `cat > memory/sessions/x.md <<EOF`, `tee`, `sed -i`, `cp`, `mv`.
          Se mira solo el tramo anterior a la ruta, cortado en `;`, `&&`, `||`, `|` y salto de
          linea, para que el redirect de otro tramo no contamine este.

      (b) literal dentro de open():  `open("memory/sessions/x.md", "w")`.

      (c) ruta ligada a una variable y escrita por ella:
              p="memory/sessions/x.md"
              s=open(p,encoding="utf-8").read()
              open(p,"w").write(s)
          Este es el idioma dominante cuando el estilo de salida obliga a editar por Bash, y era
          justo el que se escapaba: `python3 - <<'PY'` no lleva ningun operador de escritura
          delante de la ruta. Medido 2026-09-12 — una sesion de 1881 lineas que habia escrito su
          ficha salia clasificada como lectura, y con ella se habria reimportado duplicada.

    Leer NO cuenta: `cat memory/sessions/x.md` y `open(p).read()` mencionan la ruta igual que la
    escritura y significan lo contrario.
    """
    tramo = cmd[:inicio]
    cortes = [m.end() for m in CORTE.finditer(tramo)]
    if cortes:
        tramo = tramo[cortes[-1]:]
    op = ESCRITURA.search(tramo)
    if op:
        # `cp SRC DST` y `mv SRC DST` escriben el DESTINO, no el origen. Sin esta comprobacion
        # copiar una ficha a un temporal contaba como haberla escrito.
        if re.search(r'\b(cp|mv)\b', op.group(0)):
            resto = cmd[inicio:]
            corte = CORTE.search(resto)
            resto = resto[:corte.start()] if corte else resto
            tokens = resto.split()
            if len(tokens) > 1:      # hay algo despues: la ruta era el ORIGEN
                return False
        return True

    esc = re.escape(fichero)
    # (b) literal con modo de escritura en el mismo open()
    if re.search(r'open\s*\(\s*[\'"][^\'"]*' + esc + r'[\'"]\s*,\s*[\'"][wax]', cmd):
        return True
    if re.search(r'[\'"][^\'"]*' + esc + r'[\'"]\s*\)?\s*\.\s*write', cmd):
        return True

    # (c) variables ligadas a esta ruta, y luego usadas para escribir
    for m in re.finditer(r'(\w+)\s*=\s*[\'"][^\'"]*' + esc + r'[\'"]', cmd):
        var = re.escape(m.group(1))
        if re.search(r'open\s*\(\s*' + var + r'\b[^)]*[\'"][wax]', cmd):
            return True
        if re.search(r'\b' + var + r'\s*\)?\s*\.\s*write', cmd):
            return True
        if re.search(r'write_text\s*\(', cmd) and re.search(r'\(\s*' + var + r'\b', cmd):
            return True
        if re.search(r'>\s*"?\$\{?' + var + r'\b', cmd):
            return True
    return False



def lee_tambien(cmd, fichero):
    """True si el mismo comando LEE ese fichero (ademas de escribirlo).

    Escribir un fichero que primero se lee es MODIFICARLO; escribirlo sin leerlo es CREARLO.
    La diferencia decide si la sesion tiene ficha PROPIA o solo toco la de otra: `/enrich-3t` y
    `/consolidate-3t` reescriben fichas ajenas, y contar eso como ficha propia produciria el
    fallo invisible — marcar como ya-importada una sesion que no lo esta.
    """
    esc = re.escape(fichero)
    # `cat ficha.md` lee; `cat > ficha.md <<EOF` escribe. Lo que los separa es el redirect
    # entre el comando y la ruta, asi que el tramo intermedio no puede contener `>`.
    if re.search(r'\b(cat|less|head|tail)\s+[^|;&>\n]*' + esc, cmd):
        return True
    if re.search(r'\bsed\s+-n\b[^|;&\n]*' + esc, cmd):
        return True
    if re.search(r'\bgrep\b[^|;&\n]*' + esc, cmd):
        return True
    if re.search(r'open\s*\(\s*[\'"][^\'"]*' + esc + r'[\'"]\s*[,)][^)]*\)\s*\.\s*read', cmd):
        return True
    for m in re.finditer(r'(\w+)\s*=\s*[\'"][^\'"]*' + esc + r'[\'"]', cmd):
        var = re.escape(m.group(1))
        if re.search(r'open\s*\(\s*' + var + r'\b(?![^)]*[\'"][wax])[^)]*\)\s*\.\s*read', cmd):
            return True
        if re.search(r'read_text\s*\(\s*\)?', cmd) and re.search(r'\(\s*' + var + r'\b', cmd):
            return True
    return False


def escaneo_jsonl(path):
    """Devuelve (dateFirst, dateLast, fichas_escritas:set, lineas)."""
    escritas = set()
    creadas = set()
    primera = ultima = None
    lineas = 0
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return None, None, escritas, creadas, 0
    with fh:
        for linea in fh:
            lineas += 1
            try:
                o = json.loads(linea)
            except (ValueError, TypeError):
                continue
            fecha = fecha_local(o.get("timestamp"))
            if fecha:
                if primera is None or fecha < primera:
                    primera = fecha
                if ultima is None or fecha > ultima:
                    ultima = fecha
            msg = o.get("message")
            cont = msg.get("content") if isinstance(msg, dict) else None
            if not isinstance(cont, list):
                continue
            for c in cont:
                if not isinstance(c, dict) or c.get("type") != "tool_use":
                    continue
                inp = c.get("input")
                if not isinstance(inp, dict):
                    continue
                # Write/Edit/MultiEdit/NotebookEdit: file_path ES el destino escrito.
                fp = inp.get("file_path")
                if isinstance(fp, str):
                    for m in RUTA_FICHA.finditer(fp):
                        if SCRATCH.search(fp[max(0, m.start() - 40):m.start()]):
                            continue
                        escritas.add(m.group(1))
                        # Write sobrescribe el fichero entero: creacion. Edit exige que ya
                        # existiera: modificacion.
                        if c.get("name") in ("Write", "NotebookEdit"):
                            creadas.add(m.group(1))
                # Bash: la ruta aparece igual al leer que al escribir; decide el operador.
                cmd = inp.get("command")
                if isinstance(cmd, str) and cmd:
                    for m in RUTA_FICHA.finditer(cmd):
                        if SCRATCH.search(cmd[max(0, m.start() - 40):m.start()]):
                            continue
                        if es_escritura(cmd, m.start(), m.group(1)):
                            escritas.add(m.group(1))
                            if not lee_tambien(cmd, m.group(1)):
                                creadas.add(m.group(1))
    return primera, ultima, escritas, creadas, lineas


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    actual = ""
    if "--current" in sys.argv:
        i = sys.argv.index("--current")
        if i + 1 < len(sys.argv):
            actual = stem(sys.argv[i + 1])
    if len(args) < 2:
        print(json.dumps({"error": "uso: match-session-file.py <MEMORY_DIR> <JSONL_DIR> "
                                   "[--current <session_id>]"}, ensure_ascii=False))
        return 0
    memory_dir, jsonl_dir = args[0], args[1]

    fichas = fichas_existentes(memory_dir)
    por_sello = {}
    selladas = set()
    for nombre, meta in fichas.items():
        if meta["session_id"]:
            por_sello.setdefault(stem(meta["session_id"]), nombre)
            # Una ficha sellada TIENE dueño, exista o no ya el .jsonl de esa sesion (los
            # transcripts se borran; las fichas no). Sin esto, la ficha de una sesion cuyo
            # .jsonl desaparecio quedaba "huerfana" y mandaba a REVISAR a cualquier sesion de
            # la misma fecha: ruido puro, y de los que se firman en bloque sin mirar.
            selladas.add(nombre)

    if not os.path.isdir(jsonl_dir):
        print(json.dumps({"error": "no existe %s" % jsonl_dir}, ensure_ascii=False))
        return 0

    jsonls = sorted(n for n in os.listdir(jsonl_dir)
                    if n.endswith(".jsonl")
                    and not n.startswith(".")
                    and os.path.isfile(os.path.join(jsonl_dir, n)))

    # Primera pasada: identidad probada (sello o escritura observada en rango).
    datos = {}
    reclamadas = set(selladas)
    for nombre in jsonls:
        s = stem(nombre)
        primera, ultima, escritas, creadas, lineas = escaneo_jsonl(os.path.join(jsonl_dir, nombre))
        propias = sorted(
            f for f in creadas
            if f in fichas
            and en_rango(fichas[f]["date"], primera, ultima)
        )
        solo_tocadas = sorted(
            f for f in (escritas - creadas)
            if f in fichas
            and en_rango(fichas[f]["date"], primera, ultima)
        )
        datos[nombre] = {"stem": s, "primera": primera, "ultima": ultima,
                         "propias": propias, "tocadas": solo_tocadas,
                         "creadas_todas": {f for f in creadas if f in fichas},
                         "lineas": lineas}
        if s in por_sello:
            reclamadas.add(por_sello[s])
        # Toda ficha ESCRITA por esta sesion queda reclamada, este o no en su rango: un run de
        # backfill escribe fichas de fechas viejas y esas tienen dueño igual. Reclamar solo las
        # en-rango dejaba huerfanas las escritas por un backfill, y eso mandaba a REVISAR a
        # cualquier sesion corta de esa misma fecha.
        reclamadas.update(f for f in escritas if f in fichas)

    # Quien creo cada ficha. Sirve para distinguir "modifique la mia" de "reescribi la de otra".
    creador = {}
    for nombre in jsonls:
        for f in datos[nombre]["creadas_todas"]:
            creador.setdefault(f, set()).add(datos[nombre]["stem"])
    creadas_por_otra = {}
    for nombre in jsonls:
        mio = datos[nombre]["stem"]
        creadas_por_otra[mio] = {f for f, quienes in creador.items() if quienes - {mio}}

    resultados = []
    conteos = {"match": 0, "review": 0, "process": 0, "current": 0}
    for nombre in jsonls:
        d = datos[nombre]
        s = d["stem"]
        if actual and s == actual:
            v, razon, casada = "current", "sesion en curso", ""
        elif s in por_sello:
            v, razon, casada = "match", "sello session_id", por_sello[s]
        elif d["propias"]:
            v = "match"
            razon = "escribio su ficha"
            casada = min(d["propias"], key=lambda f: distancia_dias(fichas[f]["date"], d["primera"]))
            if len(d["propias"]) > 1:
                razon = "escribio su ficha (+%d fichas ajenas en rango)" % (len(d["propias"]) - 1)
        elif d["tocadas"]:
            # Escribio una ficha de su rango habiendola leido antes: la modifico. Casi siempre
            # es la suya (el checkpoint la crea con la ruta en una variable —invisible para el
            # escaneo— y luego corrige secciones leyendola). Solo hay duda de verdad cuando OTRA
            # sesion creo esa misma ficha: ahi esto huele a /enrich-3t o /consolidate-3t
            # reescribiendo ficha ajena, y contarlo como ficha propia perderia esta sesion en
            # silencio. Esa es la unica que va a REVISAR.
            ajenas = [f for f in d["tocadas"] if f in creadas_por_otra.get(s, set())]
            if ajenas:
                v = "review"
                razon = "modifico ficha creada por otra sesion: %s" % ", ".join(ajenas[:3])
                casada = ""
            else:
                v = "match"
                razon = "modifico su ficha"
                casada = min(d["tocadas"],
                             key=lambda f: distancia_dias(fichas[f]["date"], d["primera"]))
        else:
            # Sin prueba de identidad. ¿Hay ficha de su rango que nadie reclame?
            huerfanas = sorted(
                f for f, meta in fichas.items()
                if f not in reclamadas
                and en_rango(meta["date"], d["primera"], d["ultima"])
            )
            if huerfanas:
                v = "review"
                razon = "ficha de la misma fecha sin dueño: %s" % ", ".join(huerfanas[:3])
                casada = ""
            else:
                v, razon, casada = "process", "sin ficha", ""
        conteos[v] += 1
        resultados.append({"jsonl": nombre, "stem": s,
                           "dateFirst": d["primera"], "dateLast": d["ultima"],
                           "lineCount": d["lineas"],
                           "verdict": v, "reason": razon, "matched": casada})

    print(json.dumps({"results": resultados, "counts": conteos},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
