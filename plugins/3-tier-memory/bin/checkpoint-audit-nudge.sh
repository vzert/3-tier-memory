#!/bin/bash
# sella-huellas: no (hook de solo lectura: mira el comando y el transcript, y avisa)
# 3-tier-memory plugin: PreToolUse hook (Bash)
#
# POR QUE EXISTE. `/checkpoint-3t` Step 7a manda correr `checkpoint-audit.py` y pegar su salida
# literal en el reporte de cierre. Eso es prosa: nada obliga a ejecutarlo. Dos verificadores
# independientes (un modelo externo y un subagente) senalaron por separado el mismo punto — el
# unico consumidor de la auditoria es una instruccion en un fichero de texto, asi que un cierre
# que se la salta sale exactamente igual de limpio que uno que la corrio. Es la regla mas cara
# que ya aprendio este repo (la 67): la deteccion que vive en un comando opt-in no llega a nadie;
# la superficie automatica es la unica que alcanza a cada instalacion en cada sesion.
#
# El checkpoint termina comiteando `memory/` con un mensaje que empieza por `checkpoint:`. Ese es
# el ultimo momento en que avisar sirve de algo, y es donde se engancha esto.
#
# NO BLOQUEA. Imprime el aviso y sale 0, igual que `bash-journal-nudge.sh`: el comando se ejecuta
# de todas formas. Un gate aqui seria peor que el problema — dejaria el checkpoint a medias, con
# la memoria escrita y sin commitear, que es el estado mas fragil de todo el flujo.
#
# Se calla cuando:
#   - el comando no es el commit del checkpoint;
#   - el transcript de ESTA sesion muestra una corrida real de `checkpoint-audit.py` (ver abajo
#     que cuenta como corrida y por que);
#   - no hay transcript legible (no se puede afirmar que no corrio: en la duda, silencio, porque
#     un aviso que se repite sin motivo se aprende a ignorar y entonces no avisa de nada).

source "$(dirname "$0")/resolve-project-dir.sh"

HOOK_INPUT="$_HOOK_INPUT" python3 - <<'PY'
import json, os, re, shlex, sys

for _f in (sys.stdout, sys.stderr):
    if hasattr(_f, "reconfigure"):
        _f.reconfigure(encoding="utf-8")

try:
    d = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

if d.get("tool_name") != "Bash":
    sys.exit(0)

cmd = (d.get("tool_input") or {}).get("command", "") or ""
if not cmd:
    sys.exit(0)

# El commit de Step 6c: `git commit -m "checkpoint: DATE-SLUG — resumen"`. Se exige que
# `checkpoint` este en el MENSAJE, no en cualquier parte del comando: pedir solo que aparezca
# hacia saltar el aviso en un commit normal cuyo comando mencionara la ruta del propio script
# (`git commit ... plugins/.../checkpoint-audit.py`). Un aviso que salta cuando no toca se
# aprende a ignorar.
if not (re.search(r"\bgit\b[^\n;&|]{0,200}\bcommit\b", cmd)
        and re.search(r"-m\s*['\"]?\s*checkpoint", cmd, re.I)):
    sys.exit(0)

tpath = d.get("transcript_path", "") or ""
if not tpath or not os.path.isfile(tpath):
    sys.exit(0)   # sin transcript no se puede afirmar nada; callar antes que avisar en falso

# CUANTO TRANSCRIPT SE LEE. La prueba que se busca son DOS registros (la llamada y su resultado),
# asi que un corte no solo puede tirarla: puede PARTIRLA y dejar media, que es un aviso en falso
# tras una corrida legitima. Medido sobre un fichero de 40 MB, leer y prefiltrar la cola entera
# cuesta 0,05 s contra un timeout de 10 s — la ventana estrecha no compraba nada. Se sube a 64 MB,
# que en la practica es el fichero completo, y solo se descarta la primera linea cuando de verdad
# hubo corte (si no hubo, no hay linea partida que descartar).
COLA = 64 * 1024 * 1024
try:
    with open(tpath, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        total = fh.tell()
        cortado = total > COLA
        fh.seek(max(0, total - COLA))
        cola = fh.read().decode("utf-8", "replace")
except Exception:
    sys.exit(0)

# QUE CUENTA COMO CORRIDA, Y POR QUE ESTO NO ES UN grep.
#
# Buscar `checkpoint-audit.py` en el texto era un defecto grave y auto-infligido: ese nombre esta
# en el aviso de aqui abajo, asi que en cuanto el hook avisaba una vez, el intento siguiente veia
# su propio aviso y se callaba — el nudge se desactivaba solo tras usarlo una vez.
#
# Buscar `resumen: hecho=<n>` (la ultima linea que imprime checkpoint-audit.py) en CUALQUIER parte
# de la cola tampoco vale, y es el defecto que arregla esta version: el texto plano no distingue de
# donde viene la cadena. La apagaban tres cosas que no son evidencia de nada —
#   1. un bloque de auditoria PEGADO en un prompt del usuario;
#   2. un fichero inyectado como `attachment` (CLAUDE.md, una ficha de sesion, el recall);
#   3. un `cat`/`grep` de una ficha de sesion ANTERIOR — y Step 7a manda precisamente pegar la
#      salida LITERAL del audit en esa ficha, asi que toda ficha vieja lleva la cadena dentro.
# Es el learning 12: un arnes que acepta no-evidencia no vigila nada.
#
# La prueba que si es evidencia son las DOS mitades juntas, emparejadas por el id de la llamada:
#   - un bloque `tool_use` cuyo comando INVOCA el script (no que lo nombre: `grep x audit.py` no
#     cuenta, `python3 "$JBIN/checkpoint-audit.py"` si), y
#   - el `tool_result` de ESA misma llamada, cuya salida trae la linea de resumen.
# Falsificar eso ya no es un descuido, es escribir a mano un comando que finge ser el audit.
#
# La clasificacion es ESTRUCTURAL, no por `type` del registro, porque en el JSONL real de Claude
# Code un `tool_result` se graba dentro de un registro `type:"user"` (comprobado sobre transcripts
# reales). Mirar el `type` y descartar `user` habria roto el caso bueno. Lo que se mira es el tipo
# del BLOQUE dentro de `message.content`: `tool_use` solo lo emite el assistant y `tool_result`
# solo llega como resultado de una herramienta. Un prompt del usuario es `content` string o un
# bloque `text`, y un `attachment` no tiene `message` — ninguno de los dos entra por aqui.

LINEA_RESUMEN = re.compile(r"resumen:\s*hecho=\d+")

# QUE COMANDO CUENTA COMO INVOCACION. No vale una expresion regular sobre el texto del comando:
# un adversario externo rompio la primera version con `python3 -c \'print("resumen: hecho=9")\'
# checkpoint-audit.py`, que casaba porque el nombre aparecia detras de un lanzador de python, sin
# ser el programa que se ejecuta. Tampoco valia `checkpoint-audit.pyc`, que casaba por no exigir
# frontera tras `.py`. Asi que el comando se TOKENIZA y se pregunta cual es el fichero que el
# segmento ejecuta de verdad: ni `-c` ni `-m` ejecutan un fichero, y `grep`/`cat`/`echo` sobre el
# script tampoco. Falla cerrado: lo que no se puede tokenizar no cuenta como corrida.
OPERADORES = re.compile(r"[;&|\n()]+")
LANZADOR = re.compile(r"^(?:python[\d.]*|py)$")
ASIGNACION = re.compile(r"^[A-Za-z_]\w*=")
SIN_FICHERO = {"-c", "-m", "--command", "--module"}   # lo que sigue es codigo o modulo, no un fichero
OPCION_CON_VALOR = {"-X", "-W"}
ENVOLTURAS = {"env", "uv", "pipx", "nohup", "time", "stdbuf", "nice"}


def programa_ejecutado(tokens):
    """El basename del fichero que este segmento ejecuta de verdad, o None."""
    i, n, saltos = 0, len(tokens), 0
    while i < n and saltos < 8:
        t = tokens[i]
        base = os.path.basename(t)
        if ASIGNACION.match(t):                 # VAR=valor delante del programa
            i += 1
            continue
        if base in ENVOLTURAS:
            i += 1
            saltos += 1
            while i < n and tokens[i] in ("run", "--"):   # `uv run`, `pipx run`
                i += 1
            continue
        if LANZADOR.match(base):
            i += 1
            saltos += 1
            while i < n:
                op = tokens[i]
                if op in SIN_FICHERO:
                    return None                 # `-c CODIGO` / `-m MODULO`: no ejecuta un fichero
                if op.startswith("-") and op != "-":
                    i += 2 if op in OPCION_CON_VALOR else 1
                    continue
                break
            continue
        return base
    return None


def invoca_el_audit(orden):
    for trozo in OPERADORES.split(orden):
        if "checkpoint-audit.py" not in trozo:
            continue
        try:
            tokens = shlex.split(trozo)
        except ValueError:
            continue                            # comillas sin cerrar: no cuenta como corrida
        if programa_ejecutado(tokens) == "checkpoint-audit.py":
            return True
    return False


def texto_de(contenido):
    """El contenido de un bloque puede ser una cadena o una lista de sub-bloques."""
    if isinstance(contenido, str):
        return contenido
    if isinstance(contenido, list):
        partes = []
        for sub in contenido:
            if isinstance(sub, dict):
                partes.append(sub.get("text") or sub.get("content") or "")
            elif isinstance(sub, str):
                partes.append(sub)
        return "\n".join(p for p in partes if isinstance(p, str))
    return ""


ids_comando = set()   # ids de llamadas cuyo comando INVOCA el audit
ids_salida = set()    # ids de llamadas cuya salida trae la linea de resumen

lineas = cola.split("\n")
if cortado and len(lineas) > 1:
    lineas = lineas[1:]   # solo si hubo corte: esa primera linea puede venir partida

for linea in lineas:
    # Prefiltro barato: parsear 4 MB de JSON linea a linea dentro de un hook es como se rompen
    # los hooks. Solo se parsea lo que puede aportar una de las dos mitades.
    if "checkpoint-audit.py" not in linea and "hecho=" not in linea:
        continue
    try:
        reg = json.loads(linea)
    except Exception:
        continue
    if not isinstance(reg, dict):
        continue
    contenido = ((reg.get("message") or {}) if isinstance(reg.get("message"), dict) else {}).get("content")
    if not isinstance(contenido, list):
        continue
    for bloque in contenido:
        if not isinstance(bloque, dict):
            continue
        tipo = bloque.get("type")
        if tipo == "tool_use":
            entrada = bloque.get("input")
            if isinstance(entrada, dict):
                orden = entrada.get("command")
                if not isinstance(orden, str):
                    orden = " ".join(v for v in entrada.values() if isinstance(v, str))
            elif isinstance(entrada, str):
                orden = entrada
            else:
                orden = ""
            if orden and invoca_el_audit(orden):
                bid = bloque.get("id")
                if isinstance(bid, str):
                    ids_comando.add(bid)
        elif tipo == "tool_result":
            if LINEA_RESUMEN.search(texto_de(bloque.get("content"))):
                bid = bloque.get("tool_use_id")
                if isinstance(bid, str):
                    ids_salida.add(bid)

if ids_comando & ids_salida:
    sys.exit(0)

# INVARIANTE: este texto no puede contener nada que silencie al hook — ni `resumen: hecho=<n>`,
# ni el script en posicion ejecutable. Nombrarlo en prosa es seguro justo porque nombrarlo ya no
# cuenta como corrida. Hay un aserto que lo comprueba en test-checkpoint-audit-nudge.sh.
print(
    "AVISO del plugin 3-tier-memory: vas a comitear el checkpoint y en esta sesion no corriste "
    "`bin/checkpoint-audit.py` (Step 7a). Ese paso es el unico que mide que pasos del checkpoint "
    "quedaron HECHO / SALTADO / PARCIAL / POR-DISENO, y su salida va LITERAL en el reporte de "
    "Step 7. Sin el, el cierre solo cuenta lo que salio bien — que es exactamente el hueco por el "
    "que el usuario tenia que preguntar 'falto algo de tu checkpoint?' al final de cada sesion. "
    "Correlo antes de cerrar: "
    "python3 \"$JBIN/checkpoint-audit.py\" \"$MEMORY_DIR\" --session-file \"$SESSION_FILE\" "
    "--repo-root . "
    "Esto es un aviso, no un bloqueo: el commit se ejecuta igual."
)
PY
exit 0
