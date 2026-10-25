#!/usr/bin/env python3
"""La lista corta "que hago ahora" de un proyecto 3-tier, como JSON en stdout.

Uso: pendientes-ahora.py --memory-dir DIR [--hoy AAAA-MM-DD] [--max N] [--lib DIR]
                         [--session-id ID] [--projects-root DIR] [--sessions-dir DIR]

Orden (tres grupos, sin repetir un id):
  1. hilo  — los ids del `Proximo paso` de la ficha de ESTA ventana que sigan abiertos, y luego el
             hilo de esa ficha (pendientes_afines.hilo: _relacionado, planes, nuevos de la sesion).
             La ficha de esta ventana (0.3.1): la que escribio esta sesion (`session_id:` de su
             cabecera) o, si aun no escribio ninguna, la que manda leer el `Retomamos:` que la
             persona pego (o que trajo el system prompt). Sin ficha, los `p-…` que la persona cito en
             sus prompts de esta ventana hacen de paso, y el hilo sale de ellos. Sin `--session-id`,
             o en una ventana sin prompt, no hay hilo: la ficha mas nueva del proyecto suele ser de
             otra ventana viva (ya sale en `planes`), y su hilo no es "el trabajo actual" de esta.
  2. vence — `_revisar` de hoy o pasado: el mas viejo arriba.
  3. alta  — Alta sin `_bloqueado`, sin `_revisar` futuro y sin fecha futura en el texto.
Un pendiente con `_retomar` de hoy o pasado (y sin `_revisar` futuro) no entra en hilo ni en alta:
va a `planes` (abajo). Solo entra en vence si ademas tiene `_revisar` de hoy o pasado: esa fecha es
real.
Tope `--max` (7 por defecto) repartido por cupos (hilo 3, vence 2, alta 2; lo que un grupo no
usa lo rellena el siguiente en orden); el resto se cuenta en `quedan`. Dentro de vence, Alta antes
que Media antes que Baja.

En curso: cada elegido lleva `en_curso` si alguien ya lo esta haciendo: su id aparece en un
commit posterior a la ultima ficha, o en un prompt de la persona en esta sesion (--session-id) o
en otra sesion viva del proyecto (transcripcion con actividad en 2 h). De un `Retomamos:`, solo
el Proximo paso.

Planes activos (0.3.0): `planes` es una fila por ficha que nombran las marcas `_retomar` vigentes,
la mas reciente arriba, todas, fuera del tope. Cada una trae la ficha, su `Proximo paso`, el
snippet `## Como retomar` (el clic lo pega), los pendientes que la citan y `ventana`: si sigue
abierta la sesion que escribio la ficha (`session_id:` de su cabecera) u otra que pego su paso.
"abierta" sale de un proceso vivo de Claude Code (SESIONES_DIR, un <pid>.json por proceso) con ese id o, con
`retomada`, de una ventana viva del proyecto (o de un worktree suyo) cuya persona pego el paso, o
cuyo system prompt lo trae (el relevo de lookout); si no hay, "cerrada" con los dias desde la
ultima actividad de su transcripcion. Sin ese registro (otra plataforma, otra version), solo queda
la transcripcion: "activa" (actividad en 2 h) o "sin actividad" con los dias. Un plan
sale de la lista cuando se cierra su pendiente o cuando otro checkpoint mueve la marca o la quita
(3-tier-memory 2.63.42: la sesion que retomo el snippet la consume).

Contexto del clic: cada elegido lleva `origen` (rutas memory/... que existen, de su `_origen`),
`origen_texto` (el `_origen` tal cual si no nombra ningun archivo que exista; si no, null) y
`relacionado` (los valores de su `_relacionado`), para que el pendiente pegado al prompt diga que
leer. Con `_retomar`, ademas `retomar`, `retomar_ficha` y `retomar_snippet` (el bloque `## Como
retomar` de esa ficha, sin fence): el clic pega el snippet entero.

No escribe nada. No copia el parser: importa pendientes_afines.py del plugin 3-tier-memory
(--lib, o $THREE_TIER_BIN, o el repo del proyecto, o la version mas alta del cache). La excepcion
son `_origen`, `_relacionado` y `_retomar`, que lee de la linea (ver contexto_por_id).
Si algo falla, sale 0 con {"ok": false, "error": ...}: el mod lo pinta en vez de callar.

`resumen.sin_id`: lineas `- [ ]` del archivo que pendientes_afines no devuelve (sin `_id`). El
panel no puede mostrarlas; `abiertos` cuenta solo las que ve, y el mod pinta las dos cifras.
"""
import calendar
import datetime
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True  # no dejar __pycache__ en la carpeta del plugin 3-tier-memory

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

FICHA_FECHA = re.compile(r"^(\d{4}-\d{2}-\d{2})")
# Transcripciones y registro de procesos vivos de Claude Code (un <pid>.json por sesion abierta).
PROYECTOS_DIR = os.path.join(os.path.expanduser("~"), ".claude", "projects")
SESIONES_DIR = os.path.join(os.path.expanduser("~"), ".claude", "sessions")


def version(path):
    m = re.search(r"[\\/](\d+)\.(\d+)\.(\d+)[\\/]bin[\\/]", path)
    return tuple(int(x) for x in m.groups()) if m else (-1,)


def buscar_lib(memory_dir, lib=None):
    """La carpeta bin/ con pendientes_afines.py, o None. Devuelve tambien de donde salio."""
    candidatos = []
    if lib:
        candidatos.append(("--lib", lib))
    if os.environ.get("THREE_TIER_BIN"):
        candidatos.append(("THREE_TIER_BIN", os.environ["THREE_TIER_BIN"]))
    proyecto = os.path.dirname(os.path.abspath(memory_dir))
    candidatos.append(("proyecto", os.path.join(proyecto, "plugins", "3-tier-memory", "bin")))
    cache = glob.glob(os.path.expanduser(
        "~/.claude/plugins/cache/*/3-tier-memory/*/bin/pendientes_afines.py"))
    for p in sorted(cache, key=version, reverse=True):
        candidatos.append(("cache", os.path.dirname(p)))
    for origen, d in candidatos:
        if os.path.isfile(os.path.join(d, "pendientes_afines.py")):
            return origen, d
    return None, None


def cargar(bin_dir):
    spec = importlib.util.spec_from_file_location(
        "pendientes_afines", os.path.join(bin_dir, "pendientes_afines.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ultima_ficha(memory_dir):
    """La ficha de sesion mas reciente: fecha del nombre, luego mtime. None si no hay."""
    fichas = [f for f in glob.glob(os.path.join(memory_dir, "sessions", "*.md"))
              if FICHA_FECHA.match(os.path.basename(f))]
    if not fichas:
        return None
    return max(fichas, key=lambda f: (FICHA_FECHA.match(os.path.basename(f)).group(1),
                                      os.path.getmtime(f)))


def ficha_de_esta_ventana(memory_dir, session_id, projects_root=None, pa=None):
    """La ficha cuyo hilo es el trabajo de esta ventana, o None (0.3.1). Primero la que escribio esta
    sesion (la mas nueva con su `session_id:`); si no escribio ninguna, la que manda leer el ultimo
    `Retomamos:` que recibio (prompt de la persona o system prompt del relevo)."""
    if not session_id:
        return None
    propias = [f for f in glob.glob(os.path.join(memory_dir, "sessions", "*.md"))
               if FICHA_FECHA.match(os.path.basename(f)) and session_id_de(f) == session_id]
    if propias:
        return max(propias, key=lambda f: (FICHA_FECHA.match(os.path.basename(f)).group(1),
                                           os.path.getmtime(f)))
    if pa is None or not hasattr(pa, "recibido"):
        return None
    proyecto = os.path.dirname(os.path.abspath(memory_dir))
    tx = transcripcion(session_id, proyecto, projects_root)
    if not tx:
        return None
    retoma = None
    for t in snippet_de_sistema(tx) + textos_de_persona(tx):
        if re.search(r"retomamos:", t, re.I):
            slug = pa.recibido(t).get("retoma")
            if slug and os.path.isfile(os.path.join(memory_dir, "sessions", slug + ".md")):
                retoma = slug
    return os.path.join(memory_dir, "sessions", retoma + ".md") if retoma else None


def ids_de_esta_ventana(memory_dir, session_id, projects_root=None, pa=None):
    """Los `p-…` que la persona cito en los prompts de esta ventana, en orden de aparicion (0.3.1).
    De un `Retomamos:` solo los del paso (ids_del_texto)."""
    if not session_id:
        return []
    proyecto = os.path.dirname(os.path.abspath(memory_dir))
    tx = transcripcion(session_id, proyecto, projects_root)
    if not tx:
        return []
    vistos = []
    for t in textos_de_persona(tx):
        for i in sorted(ids_del_texto(t, pa), key=t.find):
            if i not in vistos:
                vistos.append(i)
    return vistos


def fecha_futura(pa, texto, hoy):
    """pa.fecha_futura (2.56.0+); con un plugin anterior no hay red de fechas en el texto."""
    return pa.fecha_futura(texto, hoy) if hasattr(pa, "fecha_futura") else None


def hacible(pa, p, hoy):
    """Como pendientes_afines.hacible, pero sin su filtro de prioridad (el paso puede ser Baja) y
    dejando fuera todo `_bloqueado`, aun con su `_revisar` ya pasado (3-tier-memory 2.63.32 lo
    vuelve hacible): ese sale en "vence", que cuenta todo `_revisar` de hoy o pasado."""
    if p["bloqueado"]:
        return False
    if p.get("revisar") and p["revisar"] >= hoy:
        return False
    return not fecha_futura(pa, p["texto"], hoy)


ETIQUETA = re.compile(r"^\s*([^:()\[\]]{2,30}?):\s+(?=\S)")
CORTE = re.compile(r"\s+\(|\.\s|;\s|\s—\s|:\s|,\s+(?:que|y|pero|porque)\s")
TITULO_MAX = 60


def etiqueta_y_resto(texto):
    """('Snippet de cierre', 'implementar ...') si el texto abre con un tema corto y ':'."""
    m = ETIQUETA.match(texto)
    if m and len(m.group(1).split()) <= 4:
        return m.group(1).strip(), texto[m.end():]
    return None, texto


def titulo_auto(texto):
    """El titulo de corte automatico: sin la etiqueta, hasta la primera pausa, <= TITULO_MAX."""
    _, resto = etiqueta_y_resto(" ".join(texto.split()))
    m = CORTE.search(resto)
    t = resto[:m.start()] if m and m.start() >= 12 else resto
    if len(t) > TITULO_MAX:
        t = t[:TITULO_MAX].rsplit(" ", 1)[0].rstrip(",;:") + "…"
    primera = t.split(" ", 1)[0]
    if "/" in primera or "." in primera or "_" in primera:  # una ruta o un comando: tal cual
        return t
    return t[:1].upper() + t[1:]


def dias_vencido(revisar, hoy):
    if not revisar or revisar > hoy:
        return None
    a = datetime.date.fromisoformat(revisar)
    return (datetime.date.fromisoformat(hoy) - a).days


# Contexto que el clic pega con el pendiente: la ficha (o plan, research) de _origen y los ids/planes
# de _relacionado. Se leen de la linea, no de la biblioteca: la de 3-tier-memory < 2.57.0 no trae
# `origen`, y la de 2.57.0 solo lo trae si es una ficha de sessions/.
# El campo acaba donde empieza el siguiente ("— _nombre:"), no en cualquier raya: un valor puede
# llevar una.
CAMPO = r"—\s*_{}:\s*(.*?)_?\s*(?=—\s*_[^\s_:]+:|$)"
ORIGEN_CAMPO = re.compile(CAMPO.format("origen"))
RELACIONADO_CAMPO = re.compile(CAMPO.format("relacionado"))
# `_retomar: FECHA sessions/<slug>_` (3-tier-memory 2.62.8, marcar-retomar.py en Step 8): el pendiente
# que cita el `Proximo paso` de esa ficha. Sale en `planes` desde FECHA hasta que se cierre, y el clic
# pega el snippet de la ficha. Un campo aparte de `_revisar`: 8e y el hilo no lo ven. Desde 0.3.0
# no sale en vence: va a `planes`, una fila por ficha.
RETOMAR_CAMPO = re.compile(r"—\s*_retomar:\s*(\d{4}-\d{2}-\d{2})\s+(sessions/[\w.-]+?)_?\s*(?=—|$)")
FENCE = re.compile(r"^```[^\n]*\n(.*?)\n```\s*$", re.S)
# [[sessions/x]], [[plans/plan-x|alias]] o una ruta suelta sessions/x(.md)
DESTINO = re.compile(r"\[\[([^\]|#]+)|(?<![\w/])((?:sessions|plans|research)/[\w.-]+)")
ID_LINEA = re.compile(r"_id:\s*(p-[0-9a-f]{10})")


def contexto_por_id(pend_path, memory_dir):
    """{id: {"origen": [rutas memory/... que existen], "relacionado": [...]}} de _pendientes.md."""
    out = {}
    raiz = os.path.realpath(memory_dir)
    with open(pend_path, encoding="utf-8") as fh:
        for linea in fh:
            s = linea.strip()
            # Solo abiertos: un "- [x]" con el mismo id no pisa el contexto del abierto.
            m = ID_LINEA.search(s) if s.startswith("- [ ]") else None
            if not m:
                continue
            origen = []
            mo = ORIGEN_CAMPO.search(s)
            for a, b in DESTINO.findall(mo.group(1)) if mo else []:
                rel = (a or b).strip()
                rel = rel if rel.endswith(".md") else rel + ".md"
                # Solo archivos dentro de memory/: un [[../x]] o una ruta absoluta van como texto.
                real = os.path.realpath(os.path.join(raiz, rel))
                if os.path.commonpath([raiz, real]) != raiz or not os.path.isfile(real):
                    continue
                ruta = "memory/" + os.path.relpath(real, raiz).replace(os.sep, "/")
                if ruta not in origen:
                    origen.append(ruta)
            mr = RELACIONADO_CAMPO.search(s)
            relacionado = [x.strip() for x in mr.group(1).split(",") if x.strip()] if mr else []
            # Sin archivo que exista ("barrido A04", una ficha borrada): el texto tal cual, que
            # sigue siendo una pista. Con archivo, el texto sobra.
            crudo = mo.group(1).strip() if mo and not origen else ""
            out[m.group(1)] = {"origen": origen, "origen_texto": crudo or None,
                               "relacionado": relacionado, "retomar": retomar_de(s, raiz)}
    return out


def retomar_de(linea, raiz):
    """{"fecha", "ficha", "snippet"} de `_retomar:`, o None. `snippet` es el bloque `## Como retomar`
    de la ficha sin el fence (None si la ficha no existe, sale de memory/ o no trae bloque)."""
    m = RETOMAR_CAMPO.search(linea)
    if not m:
        return None
    rel = m.group(2) + ".md"
    real = os.path.realpath(os.path.join(raiz, rel))
    snippet = None
    if os.path.commonpath([raiz, real]) == raiz and os.path.isfile(real):
        try:
            with open(real, encoding="utf-8") as fh:
                sec = re.search(r"^## Como retomar[^\n]*\n(.*?)(?=^## |\Z)", fh.read(), re.M | re.S)
        except (OSError, UnicodeDecodeError):
            sec = None
        f = FENCE.match(sec.group(1).strip()) if sec else None
        snippet = f.group(1).strip() if f else None
    return {"fecha": m.group(1), "ficha": "memory/" + rel, "snippet": snippet}


def retomar_vigente(c, p, hoy):
    """La fecha de `_retomar` si ya llego (<= hoy) y el pendiente no espera un `_revisar` futuro."""
    r = (c or {}).get("retomar")
    if not r or r["fecha"] > hoy or (p.get("revisar") and p["revisar"] > hoy):
        return None
    return r["fecha"]


def item(p, grupo, motivo, pa, hoy, ctx=None, vence=None):
    texto = " ".join(p["texto"].split())
    c = (ctx or {}).get(p["id"], {})
    r = c.get("retomar")
    return {
        "etiqueta": etiqueta_y_resto(texto)[0],
        "titulo_auto": titulo_auto(texto),
        "dias": dias_vencido(vence or p.get("revisar"), hoy),
        "edad": dias_vencido(p.get("creado"), hoy),
        "id": p["id"],
        "prio": p["prio"],
        "texto": " ".join(p["texto"].split()),
        "corto": pa.corto(p["texto"]),
        "grupo": grupo,
        "motivo": motivo,
        "revisar": p.get("revisar"),
        "creado": p.get("creado"),
        "origen": c.get("origen", []),
        "origen_texto": c.get("origen_texto"),
        "relacionado": c.get("relacionado", []),
        "retomar": r["fecha"] if r else None,
        "retomar_ficha": r["ficha"] if r else None,
        "retomar_snippet": r["snippet"] if r else None,
    }


ID_SUELTO = re.compile(r"(?<![0-9A-Za-z-])p-[0-9a-f]{10}(?![0-9a-f])")
VIVA_SEGUNDOS = 2 * 60 * 60  # una sesion que espera respuesta sigue viva
CABEZA_BYTES = 256 * 1024
COLA_BYTES = 512 * 1024
SISTEMA_BYTES = 2 * 1024 * 1024


def ids_en_commits(proyecto, desde):
    """{id: n} de los commits posteriores a `desde` (epoch) cuyo mensaje cita el id. {} sin git."""
    try:
        out = subprocess.run(
            ["git", "-C", proyecto, "log", f"--since=@{int(desde)}", "--format=%s%n%b%x1e"],
            capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return {}
    if out.returncode != 0:
        return {}
    cuenta = {}
    for commit in out.stdout.split("\x1e"):
        for i in set(ID_SUELTO.findall(commit)):
            cuenta[i] = cuenta.get(i, 0) + 1
    return cuenta


def lineas_de(ruta):
    """Las lineas de la cabeza y la cola de una transcripcion (el medio de un archivo de MB no)."""
    try:
        with open(ruta, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            tam = fh.tell()
            fh.seek(0)
            if tam <= CABEZA_BYTES + COLA_BYTES:
                partes = [fh.read()]
            else:
                cabeza = fh.read(CABEZA_BYTES)
                fh.seek(tam - COLA_BYTES)
                partes = [cabeza, fh.read()]
    except OSError:
        return []
    lineas = []
    for i, crudo in enumerate(partes):
        ls = crudo.decode("utf-8", "replace").splitlines()
        # Un corte a mitad de linea deja trozos: fuera la ultima de la cabeza y la primera de la cola.
        if len(partes) == 2:
            ls = ls[:-1] if i == 0 else ls[1:]
        lineas.extend(ls)
    return lineas


def snippet_de_sistema(ruta):
    """El `Retomamos:` que una sesion recibio en sus instrucciones de sistema (el relevo de lookout lo
    pone ahi, no en un prompt): el texto desde `Retomamos:` de cada `prompt_snapshot`, o []. Lee linea
    a linea los primeros SISTEMA_BYTES: el snapshot llega tras el system prompt y los primeros
    recordatorios, mas alla de la cabeza que lee textos_de_persona (medido: en el byte 279397)."""
    out, leidos = [], 0
    try:
        fh = open(ruta, "rb")
    except OSError:
        return out
    with fh:
        for crudo in fh:
            leidos += len(crudo)
            if leidos > SISTEMA_BYTES:
                break
            if b'"prompt_snapshot"' not in crudo:
                continue
            try:
                a = json.loads(crudo.decode("utf-8", "replace")).get("attachment") or {}
            except ValueError:
                continue
            sp = a.get("systemPrompt") if isinstance(a, dict) and a.get("type") == "prompt_snapshot" else None
            # Una lista de partes (texto o bloques {"text": ...}) o, en otra version, un texto.
            if isinstance(sp, list):
                sp = "\n".join(x if isinstance(x, str) else str(x.get("text", "")) if isinstance(x, dict)
                               else "" for x in sp)
            if isinstance(sp, str):
                i = sp.find("Retomamos:")
                if i >= 0:
                    out.append(sp[i:])
    return out


def textos_de_persona(ruta):
    """Lo que escribio la persona en una transcripcion: prompts, no salidas de herramientas (que
    citan ids a montones) ni mensajes meta. Lee la cabeza (el "Retomamos:" con que arranca una
    sesion retomada) y la cola (lo ultimo que pidio); el medio de un archivo de MB no."""
    textos = []
    for linea in lineas_de(ruta):
        try:
            d = json.loads(linea)
        except ValueError:
            continue
        if d.get("type") != "user" or d.get("isMeta"):
            continue
        # Solo lo que escribio la persona. Las filas nuevas lo dicen en origin.kind ("human" frente
        # a "task-notification"); las viejas no traen origin, y ahi los avisos de tareas y los
        # mensajes de otros agentes se reconocen por su cabecera.
        origen = d.get("origin")
        if isinstance(origen, dict) and origen.get("kind") != "human":
            continue
        c = (d.get("message") or {}).get("content")
        if isinstance(c, str):
            partes = [c]
        elif isinstance(c, list):
            partes = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
        else:
            partes = []
        for t in partes:
            cabeza = t.lstrip()[:300]
            if cabeza.startswith("<task-notification") or "teammate-message" in cabeza \
                    or "Another Claude session sent a message" in cabeza:
                continue
            textos.append(t)
    return textos


def ids_del_texto(texto, pa):
    """Los ids que un prompt pone en marcha. En un snippet `Retomamos:` solo los del Proximo
    paso: los extras ("si ese paso es corto…", "quedan N") son sugerencias, no trabajo empezado."""
    if pa is not None and hasattr(pa, "recibido") and re.search(r"retomamos:", texto, re.I):
        return {x for x in pa.recibido(texto)["paso"] if x.startswith("p-")}
    return set(ID_SUELTO.findall(texto))


def ids_en_sesiones(proyecto, session_id, ahora, projects_root=None, pa=None):
    """({id}, {id: minutos}): ids que la persona cito en ESTA sesion, y en otras sesiones vivas
    (actividad en las ultimas 2 h) del proyecto con los minutos desde su ultima actividad."""
    raiz = projects_root or PROYECTOS_DIR
    carpeta = os.path.join(raiz, re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(proyecto)))
    aqui, otras = set(), {}
    for f in glob.glob(os.path.join(carpeta, "*.jsonl")):
        sid = os.path.splitext(os.path.basename(f))[0]
        es_esta = bool(session_id) and sid == session_id
        try:
            viva = ahora - os.path.getmtime(f) <= VIVA_SEGUNDOS
        except OSError:
            continue
        if not (es_esta or viva):
            continue
        ids = set()
        for t in textos_de_persona(f):
            ids |= ids_del_texto(t, pa)
        if es_esta:
            aqui |= ids
            continue
        minutos = int((ahora - os.path.getmtime(f)) // 60)
        for i in ids:
            otras[i] = min(minutos, otras.get(i, minutos))
    return aqui, otras


def marcar_en_curso(elegidos, memory_dir, ficha, session_id, projects_root=None, pa=None):
    """Pone `en_curso` = {"donde": "aqui"|"otra sesion"|"commits", "n": commits, "hace_min": m}
    en los elegidos
    que alguien ya esta haciendo. Devuelve las fuentes que se pudieron leer."""
    proyecto = os.path.dirname(os.path.abspath(memory_dir))
    desde = os.path.getmtime(ficha) if ficha else time.time() - 7 * 86400
    commits = ids_en_commits(proyecto, desde)
    aqui, otras = ids_en_sesiones(proyecto, session_id, time.time(), projects_root, pa)
    for e in elegidos:
        i = e["id"]
        if i in aqui:
            e["en_curso"] = {"donde": "aqui", "n": commits.get(i, 0)}
        elif i in otras:
            e["en_curso"] = {"donde": "otra sesion", "n": commits.get(i, 0), "hace_min": otras[i]}
        elif i in commits:
            e["en_curso"] = {"donde": "commits", "n": commits[i]}
        else:
            e["en_curso"] = None
    return {"commits": len(commits), "sesion": bool(session_id)}


SESSION_ID = re.compile(r"^session_id:\s*([0-9A-Za-z-]+)\s*$", re.M)


def session_id_de(ficha):
    """El `session_id:` de la cabecera de una ficha, o None (ficha vieja, borrada)."""
    try:
        with open(ficha, encoding="utf-8") as fh:
            cabeza = fh.read(2048)
    except (OSError, UnicodeDecodeError):
        return None
    if not cabeza.startswith("---"):
        return None
    fin = cabeza.find("\n---", 3)
    m = SESSION_ID.search(cabeza[:fin] if fin > 0 else cabeza)
    return m.group(1) if m else None


def epoch_utc(texto):
    """`procStart` del registro ("Thu Oct 22 15:21:58 2026", en UTC) como epoch, o None."""
    try:
        return calendar.timegm(time.strptime(" ".join(str(texto).split()), "%a %b %d %H:%M:%S %Y"))
    except (ValueError, TypeError):
        return None


def epoch_local(texto):
    """La salida de `ps -o lstart=` (misma forma, en hora local) como epoch, o None."""
    try:
        return time.mktime(time.strptime(" ".join(texto.split()), "%a %b %d %H:%M:%S %Y"))
    except (ValueError, TypeError, OverflowError):
        return None


def tick_de_arranque(pid):
    """Campo 22 (`starttime`, ticks desde el arranque) de /proc/<pid>/stat, o None si no hay /proc.
    El nombre del proceso va entre parentesis y puede llevar espacios o `)`: se corta tras el ULTIMO."""
    try:
        with open("/proc/%d/stat" % pid, encoding="utf-8", errors="replace") as fh:
            resto = fh.read().rsplit(")", 1)[1]
        return int(resto.split()[19])
    except (OSError, IndexError, ValueError):
        return None


def proceso_vivo(pid, inicio):
    """True si el proceso `pid` existe y, cuando el registro trae `procStart`, arranco a esa hora
    (un pid reusado por otro proceso no cuenta). En macOS `procStart` es texto de fecha en UTC y `ps` responde en hora
    local: se comparan como epoch, con 2 s de margen."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    except OSError:
        return False
    if not inicio:
        return True
    if isinstance(inicio, int) or str(inicio).isdigit():
        # Linux: Claude Code escribe el `starttime` de /proc (medido: cadena de digitos, 2.1.304 a 2.1.310)
        visto = tick_de_arranque(pid)
        return True if visto is None else visto == int(inicio)  # sin /proc el pid existe
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=5)
    except (OSError, subprocess.SubprocessError):
        return True  # sin ps no se puede comparar; el pid existe
    esperado, visto = epoch_utc(inicio), epoch_local(out.stdout) if out.returncode == 0 else None
    if esperado is None or visto is None:
        return True  # sin las dos horas no se puede comparar; el pid existe
    return abs(esperado - visto) <= 2


def sesiones_abiertas(sessions_dir):
    """{session_id: cwd} de los procesos vivos de Claude Code, o None si no hay registro que leer: sin
    la carpeta, o sin ninguna entrada legible (vacia, rota). Un registro asi no prueba que una ventana
    este cerrada; con None manda la transcripcion ("activa" / "sin actividad"). En Windows tambien
    None: alli os.kill(pid, 0) no pregunta si el proceso vive (0 es CTRL_C_EVENT: se lo manda) y no
    hay `ps` para comparar la hora de arranque, asi que un pid reusado pasaria por vivo."""
    if os.name == "nt" or not os.path.isdir(sessions_dir):
        return None
    abiertas, legibles = {}, 0
    for f in glob.glob(os.path.join(sessions_dir, "*.json")):
        try:
            with open(f, encoding="utf-8") as fh:
                d = json.load(fh)
            pid = int(d.get("pid"))
        except (OSError, ValueError, TypeError, AttributeError):
            continue
        sid = d.get("sessionId")
        if sid:
            legibles += 1
        if sid and proceso_vivo(pid, d.get("procStart")):
            abiertas[sid] = d.get("cwd") or ""
    return abiertas if legibles else None


def del_proyecto(cwd, proyecto):
    """True si `cwd` es el proyecto o un worktree suyo (su `.git` es un archivo que apunta a
    <proyecto>/.git/worktrees/...)."""
    if not cwd:
        return False
    real, raiz = os.path.realpath(cwd), os.path.realpath(proyecto)
    if real == raiz:
        return True
    try:
        with open(os.path.join(real, ".git"), encoding="utf-8") as fh:
            m = re.match(r"gitdir:\s*(.+)", fh.read().strip())
    except (OSError, UnicodeDecodeError):
        return False
    if not m:
        return False
    gitdir = os.path.realpath(os.path.join(real, m.group(1)))
    return gitdir.startswith(os.path.join(raiz, ".git") + os.sep)


def transcripcion(sid, cwd, projects_root):
    """La transcripcion de una sesion: la carpeta de su cwd y, si no esta (un worktree, cwd
    desconocido), la que la tenga."""
    raiz = projects_root or PROYECTOS_DIR
    if cwd:
        f = os.path.join(raiz, re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(cwd)), sid + ".jsonl")
        if os.path.isfile(f):
            return f
    hallados = glob.glob(os.path.join(raiz, "*", sid + ".jsonl"))
    return hallados[0] if hallados else None


def ventana(sid, ficha_real, proyecto, abiertas, hoy, ahora, session_id=None, projects_root=None,
            retomada_en=None):
    """{"estado", "dias", "fuente", "aqui", "retomada"} de un plan: abierto si sigue viva la sesion
    que escribio la ficha o una que pego su paso (`retomada_en`, el id de esa sesion). Sin registro
    de procesos, `retomada_en` sale de las sesiones con actividad en 2 h."""
    if retomada_en and retomada_en != sid:
        return {"estado": "abierta" if abiertas is not None else "activa", "dias": 0,
                "fuente": "proceso" if abiertas is not None else "transcripcion",
                "aqui": bool(session_id) and retomada_en == session_id, "retomada": True}
    if not sid:
        return {"estado": None, "dias": None, "fuente": None, "aqui": False, "retomada": False}
    aqui = bool(session_id) and sid == session_id
    if abiertas is not None and sid in abiertas:
        return {"estado": "abierta", "dias": 0, "fuente": "proceso", "aqui": aqui, "retomada": False}
    tx = transcripcion(sid, proyecto, projects_root)
    try:
        ultima = os.path.getmtime(tx) if tx else None
        if ultima is None:
            raise OSError
    except OSError:
        try:
            ultima = os.path.getmtime(ficha_real)
        except OSError:
            ultima = None
    dias = None
    if ultima is not None:
        dia = datetime.date.fromtimestamp(ultima).isoformat()
        dias = max(0, (datetime.date.fromisoformat(hoy) - datetime.date.fromisoformat(dia)).days)
    if abiertas is not None:
        return {"estado": "cerrada", "dias": dias, "fuente": "proceso", "aqui": aqui, "retomada": False}
    activa = ultima is not None and ahora - ultima <= VIVA_SEGUNDOS
    return {"estado": "activa" if activa else "sin actividad", "dias": dias,
            "fuente": "transcripcion", "aqui": aqui, "retomada": False}


def ids_de_ventanas(pa, proyecto, abiertas, session_id, projects_root):
    """{session_id: {ids}} que la persona pego en cada ventana viva del proyecto (de un `Retomamos:`,
    solo el Proximo paso). Con registro: todas las vivas, aunque lleven dias quietas. Sin el: las
    transcripciones con actividad en 2 h (y esta sesion)."""
    out = {}
    if abiertas is not None:
        for sid, cwd in abiertas.items():
            if not del_proyecto(cwd, proyecto):
                continue
            tx = transcripcion(sid, cwd, projects_root)
            if tx:
                ids = set()
                for t in textos_de_persona(tx) + snippet_de_sistema(tx):
                    ids |= ids_del_texto(t, pa)
                out[sid] = ids
        return out
    aqui, otras = ids_en_sesiones(proyecto, session_id, time.time(), projects_root, pa)
    if session_id:
        out[session_id] = aqui
    for i in otras:
        out.setdefault("otra sesion", set()).add(i)
    return out


def planes_activos(pa, todos, ctx, memory_dir, hoy, session_id=None, projects_root=None,
                   sessions_dir=None):
    """Una fila por ficha que nombran las marcas `_retomar` vigentes, la mas reciente arriba."""
    por_ficha = {}
    for p in todos:
        f = retomar_vigente(ctx.get(p.get("id")), p, hoy) if p.get("id") else None
        if not f:
            continue
        r = ctx[p["id"]]["retomar"]
        g = por_ficha.setdefault(r["ficha"], {"ficha": r["ficha"], "desde": f, "snippet": r["snippet"],
                                              "pendientes": []})
        g["desde"] = min(g["desde"], f)
        g["snippet"] = g["snippet"] or r["snippet"]
        texto = " ".join(p["texto"].split())
        g["pendientes"].append({"id": p["id"], "prio": p["prio"], "texto": texto,
                                "titulo_auto": titulo_auto(texto), "revisar": p.get("revisar")})
    if not por_ficha:
        return []
    proyecto = os.path.dirname(os.path.abspath(memory_dir))
    abiertas = sesiones_abiertas(sessions_dir or SESIONES_DIR)
    ahora = time.time()
    vistos_en = ids_de_ventanas(pa, proyecto, abiertas, session_id, projects_root)
    out = []
    for g in por_ficha.values():
        real = os.path.join(os.path.dirname(os.path.abspath(memory_dir)), g["ficha"])
        paso = None
        if os.path.isfile(real):
            try:
                with open(real, encoding="utf-8") as fh:
                    paso = pa.proximo_paso(fh.read())
            except (OSError, UnicodeDecodeError):
                paso = None
        sid = session_id_de(real)
        g["slug"] = os.path.splitext(os.path.basename(g["ficha"]))[0]
        g["fecha"] = (FICHA_FECHA.match(g["slug"]) or [None])[0]
        g["proximo_paso"] = " ".join(paso.split()) if paso else None
        g["session_id"] = sid
        ids = {p["id"] for p in g["pendientes"]}
        # La ventana que lo retomo: esta sesion primero, luego cualquiera (no la que escribio la ficha).
        en = [v for v, vi in vistos_en.items() if v != sid and ids & vi]
        en.sort(key=lambda v: v != session_id)
        g["ventana"] = ventana(sid, real, proyecto, abiertas, hoy, ahora, session_id, projects_root,
                               en[0] if en else None)
        out.append(g)
    out.sort(key=lambda g: (g["fecha"] or "", g["desde"], g["slug"]), reverse=True)
    return out


CUPO = (("hilo", 3), ("vence", 2), ("alta", 2))


def repartir(elegidos, maximo):
    """Cada grupo entra hasta su cupo; los huecos que dejen se rellenan en el orden de la lista.
    Asi cinco vencidos de Media no echan fuera la Alta de hoy. Conserva el orden de los grupos."""
    toma = set()
    for grupo, cupo in CUPO:
        for e in [e for e in elegidos if e["grupo"] == grupo][:cupo]:
            if len(toma) < maximo:
                toma.add(e["id"])
    for e in elegidos:
        if len(toma) >= maximo:
            break
        toma.add(e["id"])
    return [e for e in elegidos if e["id"] in toma]


def calcular(memory_dir, hoy, maximo, lib=None, session_id=None, projects_root=None,
             sessions_dir=None):
    pend_path = os.path.join(memory_dir, "_pendientes.md")
    if not os.path.isfile(pend_path):
        return {"ok": False, "error": f"no hay {pend_path}"}
    origen, bin_dir = buscar_lib(memory_dir, lib)
    if not bin_dir:
        return {"ok": False, "error": "no encuentro pendientes_afines.py del plugin 3-tier-memory"}
    pa = cargar(bin_dir)
    todos = pa.pendientes(pend_path)
    por_id = {p["id"]: p for p in todos if p.get("id")}
    ctx = contexto_por_id(pend_path, memory_dir)

    elegidos, vistos = [], set()
    # Los pasos de un snippet (`_retomar` vigente) van a `planes`, no a la lista.
    en_plan = {p["id"] for p in todos if p.get("id") and retomar_vigente(ctx.get(p["id"]), p, hoy)}

    def poner(p, grupo, motivo, vence=None):
        if p.get("id") in en_plan and grupo != "vence":
            return
        if p.get("id") and p["id"] not in vistos:
            vistos.add(p["id"])
            elegidos.append(item(p, grupo, motivo, pa, hoy, ctx, vence))

    ficha = ultima_ficha(memory_dir)
    propia = ficha_de_esta_ventana(memory_dir, session_id, projects_root, pa)
    paso_texto = texto = slug = None
    if propia:
        with open(propia, encoding="utf-8") as fh:
            texto = fh.read()
        slug = os.path.splitext(os.path.basename(propia))[0]
    else:
        # Sin ficha: los ids que la persona cito aqui hacen de paso (el hilo sale de ellos).
        citados = [i for i in ids_de_esta_ventana(memory_dir, session_id, projects_root, pa)
                   if i in por_id]
        if citados:
            texto = "## Como retomar\n\nProximo paso: " + " ".join(citados) + "\n"
    if texto is not None:
        paso_texto = pa.proximo_paso(texto)
        ids_paso = sorted(pa.anclas(paso_texto)[0], key=lambda i: (paso_texto or "").find(i))
        # El paso solo entra si se puede hacer hoy: el mismo filtro que hilo() (sin _bloqueado,
        # sin _revisar de hoy o futuro, sin fecha futura en el texto). Lo que vence hoy sale en
        # "vence"; lo bloqueado o futuro no es "que hago ahora".
        for i in ids_paso:
            if i in por_id and hacible(pa, por_id[i], hoy):
                poner(por_id[i], "hilo", "proximo paso")
        # hilo() llego en 3-tier-memory 2.57.0; con un plugin anterior queda solo el paso.
        if hasattr(pa, "hilo"):
            for p in pa.hilo(texto, pend_path, slug, hoy):
                poner(p, "hilo", "ligado al paso")

    # La fecha que vence: `_revisar` de hoy o pasado. `_retomar` no es una fecha que vence: va a
    # `planes` (0.3.0; hasta 0.2.4 salia aqui y se confundia con lo que vence de verdad).
    def vence(p):
        return p["revisar"] if p.get("revisar") and p["revisar"] <= hoy else None

    def motivo_vence(p, f):
        return "vence hoy" if f == hoy else f"vencido {f}"

    vencen = [p for p in todos if vence(p)]
    rango = {"Alta": 0, "Media": 1}
    vencen.sort(key=lambda p: (rango.get(p["prio"], 2), vence(p), p["fila"]))
    for p in vencen:
        poner(p, "vence", motivo_vence(p, vence(p)), vence(p))

    for p in todos:
        if (p["prio"] == "Alta" and not p["bloqueado"]
                and not (p.get("revisar") and p["revisar"] > hoy)
                and not fecha_futura(pa, p["texto"], hoy)):
            poner(p, "alta", "Alta libre")

    fuentes = marcar_en_curso(elegidos, memory_dir, ficha, session_id, projects_root, pa)
    planes = planes_activos(pa, todos, ctx, memory_dir, hoy, session_id, projects_root, sessions_dir)
    mostrados = repartir(elegidos, maximo)
    abiertos = len(todos)
    # Lo que la libreria se salta (hoy, la linea sin `_id`): medido 2026-10-18, 1395 de 2987 en 39
    # proyectos, y el panel decia "0 abiertos" en 18. Se cuenta aparte en vez de tocar
    # pendientes_afines.pendientes(), que hilo() y el resto usan dando por hecho que hay id.
    with open(pend_path, encoding="utf-8") as fh:
        lineas = sum(1 for l in fh if l.strip().startswith("- [ ]"))
    return {
        "ok": True,
        "hoy": hoy,
        "ficha": os.path.basename(propia) if propia else None,
        "proximo_paso": " ".join(paso_texto.split()) if paso_texto else None,
        "items": mostrados,
        "planes": planes,
        "resto": [e for e in elegidos if e not in mostrados],
        "quedan": len(elegidos) - len(mostrados),
        "candidatos": len(elegidos),
        "totales": {g: sum(1 for e in elegidos if e["grupo"] == g) for g, _ in CUPO},
        "resumen": {
            "abiertos": abiertos,
            "vencidos": sum(1 for p in vencen if vence(p) < hoy),
            "hoy": sum(1 for p in vencen if vence(p) == hoy),
            "alta": sum(1 for p in todos if p["prio"] == "Alta"),
            "bloqueados": sum(1 for p in todos if p["bloqueado"]),
            "sin_id": max(0, lineas - abiertos),
            "planes": len(planes),
        },
        "en_curso_fuentes": fuentes,
        "lib": {"origen": origen, "dir": bin_dir, "hilo": hasattr(pa, "hilo")},
    }


def main(argv):
    memory_dir, hoy, maximo, lib = None, datetime.date.today().isoformat(), 7, None
    session_id, projects_root, sessions_dir = None, None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--memory-dir", "--hoy", "--max", "--lib", "--session-id", "--projects-root",
                 "--sessions-dir") and i + 1 < len(argv):
            v = argv[i + 1]
            if a == "--sessions-dir":
                sessions_dir = v
            elif a == "--session-id":
                session_id = v
            elif a == "--projects-root":
                projects_root = v
            elif a == "--memory-dir":
                memory_dir = v
            elif a == "--hoy":
                hoy = v
            elif a == "--max":
                maximo = int(v)
            else:
                lib = v
            i += 2
            continue
        print(f"argumento desconocido: {a}", file=sys.stderr)
        return 2
    if not memory_dir:
        print("uso: pendientes-ahora.py --memory-dir DIR [--hoy AAAA-MM-DD] [--max N] [--lib DIR]",
              file=sys.stderr)
        return 2
    try:
        out = calcular(memory_dir, hoy, maximo, lib, session_id, projects_root, sessions_dir)
    except Exception as exc:  # el mod pinta el error; no queremos un panel vacio sin motivo
        out = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
