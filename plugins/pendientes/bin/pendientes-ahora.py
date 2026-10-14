#!/usr/bin/env python3
"""La lista corta "que hago ahora" de un proyecto 3-tier, como JSON en stdout.

Uso: pendientes-ahora.py --memory-dir DIR [--hoy AAAA-MM-DD] [--max N] [--lib DIR]
                         [--session-id ID] [--projects-root DIR]

Orden (tres grupos, sin repetir un id):
  1. hilo  — los ids del `Proximo paso` de la ultima ficha que sigan abiertos, y luego el hilo
             de esa ficha (pendientes_afines.hilo: _relacionado, planes, nuevos de la sesion).
  2. vence — `_revisar` de hoy o pasado: vencidos primero (el mas viejo arriba), luego hoy.
  3. alta  — Alta sin `_bloqueado`, sin `_revisar` futuro y sin fecha futura en el texto.
Tope `--max` (7 por defecto) repartido por cupos (hilo 3, vence 2, alta 2; lo que un grupo no
usa lo rellena el siguiente en orden); el resto se cuenta en `quedan`. Dentro de vence, Alta antes
que Media antes que Baja.

En curso: cada elegido lleva `en_curso` si alguien ya lo esta haciendo: su id aparece en un
commit posterior a la ultima ficha, o en un prompt de la persona en esta sesion (--session-id) o
en otra sesion viva del proyecto (transcripcion con actividad en 2 h). De un `Retomamos:`, solo
el Proximo paso.

Contexto del clic: cada elegido lleva `origen` (rutas memory/... que existen, de su `_origen`),
`origen_texto` (el `_origen` tal cual si no nombra ningun archivo que exista; si no, null) y
`relacionado` (los valores de su `_relacionado`), para que el pendiente pegado al prompt diga que
leer.

No escribe nada. No copia el parser: importa pendientes_afines.py del plugin 3-tier-memory
(--lib, o $THREE_TIER_BIN, o el repo del proyecto, o la version mas alta del cache). La excepcion
son `_origen` y `_relacionado`, que lee de la linea (ver contexto_por_id).
Si algo falla, sale 0 con {"ok": false, "error": ...}: el mod lo pinta en vez de callar.
"""
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


def fecha_futura(pa, texto, hoy):
    """pa.fecha_futura (2.56.0+); con un plugin anterior no hay red de fechas en el texto."""
    return pa.fecha_futura(texto, hoy) if hasattr(pa, "fecha_futura") else None


def hacible(pa, p, hoy):
    """Como pendientes_afines.hacible, pero sin su filtro de prioridad (el paso puede ser Baja)."""
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
CAMPO = r"—\s*_{}:\s*(.*?)_?\s*(?=—|$)"
ORIGEN_CAMPO = re.compile(CAMPO.format("origen"))
RELACIONADO_CAMPO = re.compile(CAMPO.format("relacionado"))
# [[sessions/x]], [[plans/plan-x|alias]] o una ruta suelta sessions/x(.md)
DESTINO = re.compile(r"\[\[([^\]|#]+)|(?<![\w/])((?:sessions|plans|research)/[\w.-]+)")
ID_LINEA = re.compile(r"_id:\s*(p-[0-9a-f]{10})")


def contexto_por_id(pend_path, memory_dir):
    """{id: {"origen": [rutas memory/... que existen], "relacionado": [...]}} de _pendientes.md."""
    out = {}
    with open(pend_path, encoding="utf-8") as fh:
        for linea in fh:
            s = linea.strip()
            m = ID_LINEA.search(s) if s.startswith("- [") else None
            if not m:
                continue
            origen = []
            mo = ORIGEN_CAMPO.search(s)
            for a, b in DESTINO.findall(mo.group(1)) if mo else []:
                rel = (a or b).strip()
                rel = rel if rel.endswith(".md") else rel + ".md"
                ruta = "memory/" + rel
                if ruta not in origen and os.path.isfile(os.path.join(memory_dir, rel)):
                    origen.append(ruta)
            mr = RELACIONADO_CAMPO.search(s)
            relacionado = [x.strip() for x in mr.group(1).split(",") if x.strip()] if mr else []
            # Sin archivo que exista ("barrido A04", una ficha borrada): el texto tal cual, que
            # sigue siendo una pista. Con archivo, el texto sobra.
            crudo = mo.group(1).strip() if mo and not origen else ""
            out[m.group(1)] = {"origen": origen, "origen_texto": crudo or None,
                               "relacionado": relacionado}
    return out


def item(p, grupo, motivo, pa, hoy, ctx=None):
    texto = " ".join(p["texto"].split())
    c = (ctx or {}).get(p["id"], {})
    return {
        "etiqueta": etiqueta_y_resto(texto)[0],
        "titulo_auto": titulo_auto(texto),
        "dias": dias_vencido(p.get("revisar"), hoy),
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
    }


ID_SUELTO = re.compile(r"(?<![0-9A-Za-z-])p-[0-9a-f]{10}(?![0-9a-f])")
VIVA_SEGUNDOS = 2 * 60 * 60  # una sesion que espera respuesta sigue viva
CABEZA_BYTES = 256 * 1024
COLA_BYTES = 512 * 1024


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


def textos_de_persona(ruta):
    """Lo que escribio la persona en una transcripcion: prompts, no salidas de herramientas (que
    citan ids a montones) ni mensajes meta. Lee la cabeza (el "Retomamos:" con que arranca una
    sesion retomada) y la cola (lo ultimo que pidio); el medio de un archivo de MB no."""
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
    textos = []
    for linea in lineas:
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
    raiz = projects_root or os.path.expanduser("~/.claude/projects")
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


def calcular(memory_dir, hoy, maximo, lib=None, session_id=None, projects_root=None):
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

    def poner(p, grupo, motivo):
        if p.get("id") and p["id"] not in vistos:
            vistos.add(p["id"])
            elegidos.append(item(p, grupo, motivo, pa, hoy, ctx))

    ficha = ultima_ficha(memory_dir)
    paso_texto = None
    if ficha:
        with open(ficha, encoding="utf-8") as fh:
            texto = fh.read()
        slug = os.path.splitext(os.path.basename(ficha))[0]
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

    vencen = [p for p in todos if p.get("revisar") and p["revisar"] <= hoy]
    rango = {"Alta": 0, "Media": 1}
    vencen.sort(key=lambda p: (rango.get(p["prio"], 2), p["revisar"], p["fila"]))
    for p in vencen:
        poner(p, "vence", "vence hoy" if p["revisar"] == hoy else f"vencido {p['revisar']}")

    for p in todos:
        if (p["prio"] == "Alta" and not p["bloqueado"]
                and not (p.get("revisar") and p["revisar"] > hoy)
                and not fecha_futura(pa, p["texto"], hoy)):
            poner(p, "alta", "Alta libre")

    fuentes = marcar_en_curso(elegidos, memory_dir, ficha, session_id, projects_root, pa)
    mostrados = repartir(elegidos, maximo)
    abiertos = len(todos)
    return {
        "ok": True,
        "hoy": hoy,
        "ficha": os.path.basename(ficha) if ficha else None,
        "proximo_paso": " ".join(paso_texto.split()) if paso_texto else None,
        "items": mostrados,
        "resto": [e for e in elegidos if e not in mostrados],
        "quedan": len(elegidos) - len(mostrados),
        "candidatos": len(elegidos),
        "totales": {g: sum(1 for e in elegidos if e["grupo"] == g) for g, _ in CUPO},
        "resumen": {
            "abiertos": abiertos,
            "vencidos": sum(1 for p in vencen if p["revisar"] < hoy),
            "hoy": sum(1 for p in vencen if p["revisar"] == hoy),
            "alta": sum(1 for p in todos if p["prio"] == "Alta"),
            "bloqueados": sum(1 for p in todos if p["bloqueado"]),
        },
        "en_curso_fuentes": fuentes,
        "lib": {"origen": origen, "dir": bin_dir, "hilo": hasattr(pa, "hilo")},
    }


def main(argv):
    memory_dir, hoy, maximo, lib = None, datetime.date.today().isoformat(), 7, None
    session_id, projects_root = None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--memory-dir", "--hoy", "--max", "--lib", "--session-id", "--projects-root") \
                and i + 1 < len(argv):
            v = argv[i + 1]
            if a == "--session-id":
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
        out = calcular(memory_dir, hoy, maximo, lib, session_id, projects_root)
    except Exception as exc:  # el mod pinta el error; no queremos un panel vacio sin motivo
        out = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
