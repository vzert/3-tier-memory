#!/usr/bin/env python3
# sella-huellas: no (solo lee el indice de accion; escribe su estado por sesion fuera de memory/)
"""Recall en el momento de la accion (F5 del plan de ciclo de vida de learnings).

Un modulo, dos usos: el hook PreToolUse bin/action-recall.sh lo corre (main) y el banco
tools/recall-bench/recall-bench.py lo importa (candidatos), asi el banco mide el mismo codigo que
corre en produccion.

Que reglas entran: solo las vivas con `cmd` o `path` en su comentario de disparadores (F4, ver
learning_marks.py). build-recall-index.py las escribe en `.action-index.json` (indice_accion), un
fichero pequeno para no cargar el indice completo en cada llamada a una herramienta.

Como casan (precision antes que cobertura: nada de BM25 sobre el comando):
- Bash: el comando se parte en segmentos por `&&`, `||`, `;`, `|`, `&` y parentesis. A cada
  segmento se le quitan delante las palabras que no son el programa: `sudo` y sus opciones, `env`
  y sus `X=Y`, asignaciones `X=Y`, el proxy `rtk` (y `rtk proxy`), y palabras de shell (`while`,
  `if`, `do`, `time`, `nohup`...). Un `cmd` casa si sus palabras son el principio del segmento; la
  primera se compara por su nombre de fichero (`/usr/bin/git` = `git`). Si el programa es un
  interprete (`python3 x.py`, `bash x.sh`) tambien se prueba desde el script.
- Edit/Write/MultiEdit: la ruta, relativa a la raiz del proyecto si esta dentro (si no, tal cual),
  casa con un `path` si fnmatch(ruta, pat) o fnmatch(ruta, "*/" + pat). Los `path` se escriben
  como fragmentos (`templates/*.md`), no siempre desde la raiz.

Orden entre las que casan (fijado ANTES de medir el banco de F5, y justificado por principio, no
por los casos):
  1. prefijo de `cmd` mas largo (en palabras): `git commit` dice mas que `git`;
  2. la regla con menos valores en `cmd` + `path`: una regla con un solo disparador esta acotada a
     esa accion; una con cinco aplica a muchas y dice menos de cada una;
  3. numero de regla mas alto: la mas reciente del topic.
"""
import fnmatch
import json
import os
import re
import shlex
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

MAX_REGLAS = 2          # como mucho 2 reglas por llamada
MAX_CHARS = 1500        # y 1.500 caracteres
VENTANA = 30            # una regla no se repite en la sesion hasta pasadas 30 llamadas
HERRAMIENTAS = ("Bash", "Edit", "Write", "MultiEdit")

_SHELL = {"while", "until", "if", "then", "do", "else", "elif", "!", "time", "nohup", "exec",
          "command", "builtin", "nice", "xargs", "{", "}"}
_INTERPRETES = {"python", "python3", "bash", "sh", "zsh", "node", "ruby", "perl"}
_SHELLS_C = {"bash", "sh", "zsh"}          # `bash -c "<cadena>"`: la cadena es otro comando
_ASIGNACION = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z_][\w-]*)\1")
# La salida del freno: el comentario va AL FINAL de la ultima linea del comando (fuera de comillas
# y fuera de un heredoc). En otro sitio no cuenta: un marcador dentro del cuerpo de un heredoc o en
# una linea intermedia no es el agente diciendo que ya vio la regla.
_VISTA_FIN = re.compile(r"(?:^|\s)#\s*regla-vista:([A-Za-z0-9][A-Za-z0-9._-]*#\d+)\s*$")
_PROFUNDIDAD = 4                        # `bash -c` / `$(...)` anidados: hasta aqui


def _nombre(p, win=None):
    """El nombre del programa como lo compara el hook: sin ruta y, en Windows, sin `.exe` y en
    minusculas (`C:\\Program Files\\Git\\cmd\\Git.exe` = `git`)."""
    win = sys.platform == "win32" if win is None else win
    b = p.replace("\\", "/").rsplit("/", 1)[-1] if win else os.path.basename(p)
    if win:
        b = b.lower()
        if b.endswith(".exe"):
            b = b[:-4]
    return b


def _limpiar(c):
    """(texto, sustituciones). Quita lo que el shell no ejecuta como comando: continuaciones de
    linea, comentarios (`#` al principio de una palabra, fuera de comillas) y cuerpos de heredoc; y
    saca aparte el texto de cada `$(...)` y `...` (fuera de comillas simples), que si se ejecuta.
    En el texto, cada sustitucion queda como una palabra neutra."""
    c = c.replace("\\\r\n", "").replace("\\\n", "")
    out, subs, pend = [], [], []
    i, n, q = 0, len(c), None
    while i < n:
        ch = c[i]
        if q == "'":
            out.append(ch)
            q = None if ch == "'" else q
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            out.append(c[i:i + 2])
            i += 2
            continue
        if q is None:
            if ch in "'\"":
                q = ch
                out.append(ch)
                i += 1
                continue
            if ch == "#" and (i == 0 or c[i - 1] in " \t\n;&|()"):
                j = c.find("\n", i)
                i = n if j < 0 else j
                continue
            if c.startswith("<<", i) and not c.startswith("<<<", i):
                m = _HEREDOC.match(c, i)
                if m:
                    pend.append((m.group(2), c[i + 2:i + 3] == "-"))
                    out.append(" << H ")
                    i = m.end()
                    continue
            if ch == "\n" and pend:
                out.append("\n")
                i += 1
                for delim, tab in pend:
                    while i < n:
                        j = c.find("\n", i)
                        linea = c[i:] if j < 0 else c[i:j]
                        i = n if j < 0 else j + 1
                        if (linea.lstrip("\t") if tab else linea).rstrip("\r") == delim:
                            break
                pend = []
                continue
        elif ch == '"':
            q = None
            out.append(ch)
            i += 1
            continue
        if c.startswith("$(", i) and not c.startswith("$((", i):
            prof, j = 1, i + 2
            while j < n and prof:
                prof += {"(": 1, ")": -1}.get(c[j], 0)
                j += 1
            subs.append(c[i + 2:j - 1] if not prof else c[i + 2:j])
            out.append(" SUBST ")
            i = j
            continue
        if ch == "`":
            j = c.find("`", i + 1)
            j = n if j < 0 else j
            subs.append(c[i + 1:j])
            out.append(" SUBST ")
            i = j + 1
            continue
        out.append(ch)
        i += 1
    return "".join(out), subs


def _palabras(texto):
    """Palabras y operadores del texto ya limpio, como los ve el shell (comillas fuera). El salto
    de linea es un operador (separa comandos), no un espacio."""
    try:
        lx = shlex.shlex(texto, posix=True, punctuation_chars="();<>|&\n")
        lx.whitespace_split = True
        lx.whitespace = " \t\r"
        lx.commenters = ""      # los comentarios ya los quito _limpiar (solo a principio de palabra)
        return list(lx)
    except ValueError:          # comillas sin cerrar: mejor algo que nada
        return texto.split()


def segmentos(comando, _prof=0):
    """Lista de segmentos (listas de palabras) del comando, cada uno empezando por el programa.

    Separan `&&`, `||`, `;`, `|`, `&`, parentesis y el salto de linea. Una redireccion (`<`, `>`,
    `>>`, `<<`, `<<<`, `&>`, `>&`...) NO separa: se come la palabra siguiente (el fichero o el
    delimitador) y el comando sigue (`cat < git push` es `cat push`, no `git push`). Ademas, los
    comandos de `bash|sh|zsh -c "<cadena>"`, `$(...)` y `...` se parten igual, por recursion."""
    texto, subs = _limpiar(comando or "")
    out, cur, saltar = [], [], False
    for t in _palabras(texto):
        es_op = bool(t) and set(t) <= set("&|;()<>\n")
        if saltar and not es_op:
            saltar = False
            continue
        saltar = False
        if es_op and ("<" in t or ">" in t):
            saltar = True
            if len(cur) == 1 and cur[0].isdigit():
                cur = []        # `2>/dev/null git push`: el 2 es el descriptor, no el programa
        elif es_op:
            if cur:
                out.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        out.append(cur)
    segs = [s for s in (_programa(s) for s in out) if s]
    if _prof < _PROFUNDIDAD:
        extra = []
        for s in segs:
            if _nombre(s[0]) in _SHELLS_C:
                for k, t in enumerate(s[1:], 1):
                    if not t.startswith("-"):
                        break
                    if "c" in t.lstrip("-") and not t.startswith("--") and k + 1 < len(s):
                        extra += segmentos(s[k + 1], _prof + 1)
                        break
        for sub in subs:
            extra += segmentos(sub, _prof + 1)
        segs += extra
    return segs


def _programa(seg):
    """Quita delante lo que no es el programa: sudo/env/X=Y/rtk/palabras de shell."""
    s = list(seg)
    while s:
        p = _nombre(s[0])
        if p in _SHELL or _ASIGNACION.match(s[0]):
            s = s[1:]
        elif p == "sudo":
            s = s[1:]
            while s and s[0].startswith("-"):
                # -u usuario / -g grupo llevan argumento
                s = s[2:] if s[0] in ("-u", "-g", "-C", "-h", "-p") else s[1:]
        elif p == "env":
            s = s[1:]
            while s and (s[0].startswith("-") or _ASIGNACION.match(s[0])):
                s = s[1:]
        elif p == "rtk":
            s = s[2:] if len(s) > 1 and s[1] == "proxy" else s[1:]
        else:
            break
    return s


def _variantes(seg):
    """El segmento y, si el programa es un interprete seguido de un SCRIPT (una ruta: lleva `/` o
    empieza por `.`), el segmento desde el script: `python3 bin/journal-emit.py` casa con
    `cmd=journal-emit.py`. `bash git push` no es `git push` (git no es una ruta)."""
    yield seg
    if _nombre(seg[0]) in _INTERPRETES:
        for i, t in enumerate(seg[1:], 1):
            if not t.startswith("-"):
                if "/" in t or "\\" in t or t.startswith("."):
                    yield seg[i:]
                break


def prefijo_cmd(comando, cmds):
    """Longitud en palabras del `cmd` mas largo que es principio de algun segmento; 0 si ninguno."""
    mejor = 0
    for seg in segmentos(comando):
        for var in _variantes(seg):
            cab = [_nombre(var[0])] + var[1:]
            for c in cmds:
                ct = c.split()
                ct = [_nombre(ct[0])] + ct[1:] if ct else ct
                if ct and cab[:len(ct)] == ct:
                    mejor = max(mejor, len(ct))
    return mejor


def ruta_relativa(file_path, raiz):
    if raiz and file_path and os.path.isabs(file_path):
        try:
            rel = os.path.relpath(file_path, raiz)
        except ValueError:
            return file_path
        if not rel.startswith(".."):
            return rel.replace("\\", "/")
    return (file_path or "").replace("\\", "/")


def casa_path(ruta, pats):
    return any(fnmatch.fnmatchcase(ruta, p) or fnmatch.fnmatchcase(ruta, "*/" + p) for p in pats)


def candidatos(reglas, tool_name, tool_input, raiz=None, reciente=True):
    """Reglas del indice de accion que casan con la llamada, en el orden fijado (ver arriba).

    Devuelve [(regla, prefijo)] con prefijo = palabras del cmd que caso (1 para un path).
    `reciente=False` cambia solo el ultimo desempate (numero mas BAJO primero): lo usa el banco
    para medir cuanto depende el resultado de ese criterio; el hook usa siempre el fijado."""
    tool_input = tool_input or {}
    hits = []
    if tool_name == "Bash":
        comando = tool_input.get("command") or ""
        for r in reglas:
            if r.get("cmd"):
                n = prefijo_cmd(comando, r["cmd"])
                if n:
                    hits.append((r, n))
    elif tool_name in ("Edit", "Write", "MultiEdit"):
        ruta = ruta_relativa(tool_input.get("file_path") or "", raiz)
        if ruta:
            for r in reglas:
                if r.get("path") and casa_path(ruta, r["path"]):
                    hits.append((r, 1))
    hits.sort(key=lambda h: (-h[1], len(h[0].get("cmd") or []) + len(h[0].get("path") or []),
                             -int(h[0].get("n", 0)) if reciente else int(h[0].get("n", 0))))
    return hits


def vistas_en(comando):
    """Ids `topic#N` que el comando declara vistas: `# regla-vista:topic#N` al final de su ULTIMA
    linea no vacia (ver _VISTA_FIN)."""
    lineas = [l for l in (comando or "").splitlines() if l.strip()]
    m = _VISTA_FIN.search(lineas[-1]) if lineas else None
    return {m.group(1)} if m else set()


def indice_valido(reglas):
    """True si el indice de accion tiene la forma que escribe build-recall-index.py. Un indice con
    otra forma (escrito a mano, de otra version, a medias) no se sirve: un `freno: "no"` es verdad
    en Python y frenaria. Falla en abierto."""
    if not isinstance(reglas, list):
        return False
    for r in reglas:
        if not (isinstance(r, dict) and isinstance(r.get("id"), str) and isinstance(r.get("texto"), str)
                and isinstance(r.get("freno"), bool) and isinstance(r.get("n", 0), int)
                and all(isinstance(r.get(k, []), list) and all(isinstance(v, str) for v in r.get(k, []))
                        for k in ("cmd", "path"))):
            return False
    return True


# --- hook ------------------------------------------------------------------------------------

class EstadoIlegible(Exception):
    """El fichero de estado existe pero no se entiende: el hook se calla, no lo pisa."""


def _leer_estado(ruta):
    """El estado de la sesion; uno nuevo si no hay fichero. Si el fichero EXISTE y no se entiende,
    EstadoIlegible: empezar de cero volveria a frenar una regla ya vista (salida perdida)."""
    try:
        f = open(ruta, encoding="utf-8")
    except FileNotFoundError:
        return {"llamadas": 0, "vistas": {}, "frenos": []}
    try:
        with f:
            e = json.load(f)
        ok = (isinstance(e, dict) and isinstance(e.get("llamadas"), int)
              and isinstance(e.get("vistas"), dict) and isinstance(e.get("frenos"), list))
    except Exception:
        ok = False
    if not ok:
        raise EstadoIlegible(ruta)
    return {"llamadas": e["llamadas"], "vistas": dict(e["vistas"]), "frenos": list(e["frenos"])}


def _guardar_estado(ruta, e):
    """Escritura atomica con un temporal UNICO (dos llamadas a la vez no comparten temporal)."""
    import tempfile
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(ruta), prefix=".action-recall-", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            json.dump(e, f)
        os.replace(tmp, ruta)
        return True
    except Exception:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return False


LOCK_ESPERA = 0.1       # segundos que una llamada espera el lock del estado antes de callarse
LOCK_VIEJO = 10         # un lock mas viejo que esto es de un proceso muerto: se quita


def _tomar_lock(ruta):
    """Lock por sesion con mkdir (atomico en las tres plataformas, como el del journal). True si lo
    tomo. Si no (otra llamada de la misma sesion lo tiene), el hook se calla: falla en abierto."""
    import time
    lock = ruta + ".lock"
    fin = time.monotonic() + LOCK_ESPERA
    while True:
        try:
            os.mkdir(lock)
            return True
        except FileExistsError:
            try:
                if time.time() - os.stat(lock).st_mtime > LOCK_VIEJO:
                    os.rmdir(lock)
                    continue
            except OSError:
                pass
        except OSError:
            return False
        if time.monotonic() > fin:
            return False
        time.sleep(0.01)


def _soltar_lock(ruta):
    try:
        os.rmdir(ruta + ".lock")
    except OSError:
        pass


def _pie(r, emit, mem):
    t = r.get("topic", "")
    pref = r.get("ancla") or ""
    return f"      ↳ si ya no es cierta: --topic {t} --match-prefix \"{pref}\"" if pref else ""


def _linea_retiro(emit, mem):
    return (f"  (↳ = la regla esta vencida: python3 \"{emit}\""
            + (f" --memory-dir \"{mem}\"" if mem else "")
            + " --type learning.retire <↳> --motivo obsoleta|duplicada|superada [--por N]."
            " Si solo cambio su texto: --type learning.update <↳> --text \"<nuevo>\".)")


def decidir(datos, reglas, estado, raiz=None, emit="", mem="", aviso=True):
    """(salida JSON o None, estado nuevo). Puro: no lee ni escribe ficheros.

    `aviso=False` (lo que hace el hook salvo opt-in, ver action-recall.sh): solo el freno. El aviso
    no paso el criterio de F5 (accion@2 0,69 < 0,8 y 8,95 inyecciones cada 20 llamadas con los
    disparadores de F4), asi que no se sirve por defecto."""
    tool = datos.get("tool_name", "")
    ti = datos.get("tool_input") or {}
    estado = {"llamadas": estado["llamadas"] + 1, "vistas": dict(estado["vistas"]),
              "frenos": list(estado["frenos"])}
    n = estado["llamadas"]
    hits = candidatos(reglas, tool, ti, raiz)
    if not hits:
        return None, estado
    # `# regla-vista:topic#N` en el comando: el agente ya la tuvo en cuenta; no vuelve a frenar
    declaradas = vistas_en(ti.get("command") or "") if tool == "Bash" else set()
    for rid in declaradas:
        if rid not in estado["frenos"]:
            estado["frenos"].append(rid)
        estado["vistas"][rid] = n
    # Freno: regla con freno=si que casa por cmd y no se ha visto en la sesion
    if tool == "Bash":
        for r, _ in hits:
            if r.get("freno") is True and r["id"] not in estado["frenos"]:
                estado["frenos"].append(r["id"])
                estado["vistas"][r["id"]] = n
                motivo = (f"Regla de memoria ({r['id']}) para esta accion: {r['texto']}\n"
                          f"Si ya la tuviste en cuenta y el comando es correcto, repitelo con el "
                          f"comentario `# regla-vista:{r['id']}` al final y no se volvera a frenar "
                          f"en esta sesion.")
                pie = _pie(r, emit, mem)
                if pie and emit:
                    motivo += "\n" + pie + "\n" + _linea_retiro(emit, mem)
                return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                               "permissionDecision": "deny",
                                               "permissionDecisionReason": motivo}}, estado
    if not aviso:
        return None, estado
    # Aviso: hasta 2 reglas que no se hayan servido en las ultimas VENTANA llamadas
    elegidas = []
    for r, _ in hits:
        ult = estado["vistas"].get(r["id"])
        if ult is not None and n - ult < VENTANA:
            continue
        elegidas.append(r)
        if len(elegidas) == MAX_REGLAS:
            break
    if not elegidas:
        return None, estado
    cab = "MEMORIA PARA ESTA ACCION (reglas del sistema 3-tier cuyo disparador casa con la llamada):"
    lineas, usadas = [cab], []
    for r in elegidas:
        bloque = [f"  - [{r['id']}] {r['texto']}"]
        pie = _pie(r, emit, mem) if emit else ""
        if pie:
            bloque.append(pie)
        cola = [_linea_retiro(emit, mem)] if emit and pie else []
        if len("\n".join(lineas + bloque + cola)) > MAX_CHARS:
            if usadas:
                break
            # una sola regla que no cabe: se recorta su texto, nunca se pasa del tope
            sobra = len("\n".join(lineas + bloque + cola)) - MAX_CHARS
            bloque[0] = bloque[0][:max(0, len(bloque[0]) - sobra - 1)].rstrip() + "…"
        lineas += bloque
        usadas.append(r)
    if emit and any(_pie(r, emit, mem) for r in usadas):
        lineas.append(_linea_retiro(emit, mem))
    for r in usadas:
        estado["vistas"][r["id"]] = n
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                   "additionalContext": "\n".join(lineas)}}, estado


def main():
    """Hook. Falla en abierto (I6): cualquier error sale 0 y en silencio, sin deny. Tambien se
    calla con un indice de forma rara, sin session_id, con el estado ilegible o sin el lock."""
    try:
        datos = json.loads(os.environ.get("ACTION_INPUT", "") or "{}")
        if not isinstance(datos, dict) or datos.get("tool_name") not in HERRAMIENTAS:
            return
        with open(os.environ["ACTION_INDEX"], encoding="utf-8") as f:
            reglas = json.load(f).get("reglas")
        if not reglas or not indice_valido(reglas):
            return
        # Sin session_id no es una llamada de Claude Code (siempre lo manda): sin el no hay estado
        # por sesion ni salida del freno, asi que no se frena ni se avisa.
        sid = datos.get("session_id")
        if not isinstance(sid, str) or not sid.strip():
            return
        sid = re.sub(r"[^A-Za-z0-9_-]", "-", sid)
        estado_ruta = os.path.join(os.environ["ACTION_STATE_DIR"], f".action-recall-{sid}.json")
        if not _tomar_lock(estado_ruta):
            return
        try:
            estado = _leer_estado(estado_ruta)
            salida, nuevo = decidir(datos, reglas, estado, raiz=os.environ.get("ACTION_RAIZ") or None,
                                    emit=os.environ.get("ACTION_PIE", ""),
                                    mem=os.environ.get("ACTION_MEMORY_DIR", ""),
                                    aviso=os.environ.get("ACTION_AVISO") == "1")
            if not _guardar_estado(estado_ruta, nuevo):
                # Sin estado no hay deduplicacion ni salida del freno: un deny que no se puede
                # anotar se repetiria siempre. Se calla (fail-open), no frena ni avisa.
                return
        finally:
            _soltar_lock(estado_ruta)
        if salida:
            sys.stdout.write(json.dumps(salida, ensure_ascii=False) + "\n")
    except Exception:  # falla en abierto (I6)
        return


if __name__ == "__main__":
    main()
