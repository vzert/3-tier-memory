#!/usr/bin/env python3
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

_SEPARADORES = {"&&", "||", ";", "|", "&", "(", ")", ";;", "|&", "&>", "{", "}"}
_SHELL = {"while", "until", "if", "then", "do", "else", "elif", "!", "time", "nohup", "exec",
          "command", "builtin", "nice", "xargs"}
_INTERPRETES = {"python", "python3", "bash", "sh", "zsh", "node", "ruby", "perl"}
_ASIGNACION = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_VISTA = re.compile(r"#\s*regla-vista:([A-Za-z0-9][A-Za-z0-9._-]*#\d+)")


def _palabras(comando):
    """Palabras y separadores del comando, como los ve el shell (comillas fuera)."""
    try:
        lx = shlex.shlex(comando, posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        lx.commenters = ""      # un `#` dentro de una palabra no es comentario; el de linea si
        return list(lx)
    except ValueError:          # comillas sin cerrar: mejor algo que nada
        return comando.split()


def segmentos(comando):
    """Lista de segmentos (listas de palabras) del comando, cada uno empezando por el programa."""
    out, cur = [], []
    for t in _palabras(comando or ""):
        if t in _SEPARADORES or (t and set(t) <= set("&|;()<>")):
            if cur:
                out.append(cur)
            cur = []
        elif t.startswith("#") and not cur:
            continue
        else:
            cur.append(t)
    if cur:
        out.append(cur)
    return [s for s in (_programa(s) for s in out) if s]


def _programa(seg):
    """Quita delante lo que no es el programa: sudo/env/X=Y/rtk/palabras de shell."""
    s = list(seg)
    while s:
        p = os.path.basename(s[0])
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
    """El segmento y, si el programa es un interprete con un script, el segmento desde el script."""
    yield seg
    if os.path.basename(seg[0]) in _INTERPRETES:
        for i, t in enumerate(seg[1:], 1):
            if not t.startswith("-"):
                yield seg[i:]
                break


def prefijo_cmd(comando, cmds):
    """Longitud en palabras del `cmd` mas largo que es principio de algun segmento; 0 si ninguno."""
    mejor = 0
    for seg in segmentos(comando):
        for var in _variantes(seg):
            cab = [os.path.basename(var[0])] + var[1:]
            for c in cmds:
                ct = c.split()
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
    """Ids `topic#N` que el comando declara vistas con `# regla-vista:topic#N`."""
    return set(_VISTA.findall(comando or ""))


# --- hook ------------------------------------------------------------------------------------

def _leer_estado(ruta):
    try:
        with open(ruta, encoding="utf-8") as f:
            e = json.load(f)
        if isinstance(e, dict):
            return {"llamadas": int(e.get("llamadas", 0)), "vistas": dict(e.get("vistas") or {}),
                    "frenos": list(e.get("frenos") or [])}
    except Exception:
        pass
    return {"llamadas": 0, "vistas": {}, "frenos": []}


def _guardar_estado(ruta, e):
    try:
        tmp = ruta + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(e, f)
        os.replace(tmp, ruta)
        return True
    except Exception:
        return False


def _pie(r, emit, mem):
    t = r.get("topic", "")
    pref = r.get("ancla") or ""
    return f"      ↳ si ya no es cierta: --topic {t} --match-prefix \"{pref}\"" if pref else ""


def _linea_retiro(emit, mem):
    return (f"  (↳ = la regla esta vencida: python3 \"{emit}\""
            + (f" --memory-dir \"{mem}\"" if mem else "")
            + " --type learning.retire <↳> --motivo obsoleta|duplicada|superada [--por N]."
            " Si solo cambio su texto: --type learning.update <↳> --text \"<nuevo>\".)")


def decidir(datos, reglas, estado, raiz=None, emit="", mem=""):
    """(salida JSON o None, estado nuevo). Puro: no lee ni escribe ficheros."""
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
            if r.get("freno") and r["id"] not in estado["frenos"]:
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
    """Hook. Falla en abierto (I6): cualquier error sale 0 y en silencio, sin deny."""
    try:
        datos = json.loads(os.environ.get("ACTION_INPUT", "") or "{}")
        if not isinstance(datos, dict) or datos.get("tool_name") not in HERRAMIENTAS:
            return
        with open(os.environ["ACTION_INDEX"], encoding="utf-8") as f:
            reglas = json.load(f).get("reglas") or []
        if not reglas:
            return
        sid = re.sub(r"[^A-Za-z0-9_-]", "-", str(datos.get("session_id") or "sin-sesion"))
        estado_ruta = os.path.join(os.environ["ACTION_STATE_DIR"], f".action-recall-{sid}.json")
        estado = _leer_estado(estado_ruta)
        salida, nuevo = decidir(datos, reglas, estado, raiz=os.environ.get("ACTION_RAIZ") or None,
                                emit=os.environ.get("ACTION_PIE", ""),
                                mem=os.environ.get("ACTION_MEMORY_DIR", ""))
        if not _guardar_estado(estado_ruta, nuevo):
            # Sin estado no hay deduplicacion ni salida del freno: un deny que no se puede anotar
            # se repetiria siempre. Se calla (fail-open), no frena ni avisa.
            return
        if salida:
            sys.stdout.write(json.dumps(salida, ensure_ascii=False) + "\n")
    except Exception:  # falla en abierto (I6)
        return


if __name__ == "__main__":
    main()
