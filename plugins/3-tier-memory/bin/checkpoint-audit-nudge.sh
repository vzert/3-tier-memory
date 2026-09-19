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
#   - el transcript de ESTA sesion ya muestra una corrida de `checkpoint-audit.py`;
#   - no hay transcript legible (no se puede afirmar que no corrio: en la duda, silencio, porque
#     un aviso que se repite sin motivo se aprende a ignorar y entonces no avisa de nada).

source "$(dirname "$0")/resolve-project-dir.sh"

HOOK_INPUT="$_HOOK_INPUT" python3 - <<'PY'
import json, os, re, sys

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

# Solo la cola: Step 7a corre a pocos pasos del commit, y parsear un transcript entero en un hook
# con timeout de 10s es como se rompen los hooks.
COLA = 4 * 1024 * 1024
try:
    with open(tpath, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        fh.seek(max(0, fh.tell() - COLA))
        cola = fh.read().decode("utf-8", "replace")
except Exception:
    sys.exit(0)

# La senal de silencio tiene que ser prueba de que el audit CORRIO, no de que alguien lo nombro.
# Buscar `checkpoint-audit.py` era un defecto grave y auto-infligido: ese nombre esta en el texto
# de aviso de aqui abajo, asi que en cuanto el hook avisaba una vez, el intento siguiente veia su
# propio aviso en el transcript y se callaba — el nudge se desactivaba solo tras usarlo una vez.
# Tambien lo habrian silenciado un prompt del usuario, un trozo del template o un comando fallido
# que solo mencionaran el nombre.
#
# `resumen: hecho=` es la ultima linea que imprime checkpoint-audit.py y no aparece en ningun otro
# sitio: ni en el template, ni en el aviso de abajo (comprobado). Solo la produce una corrida real.
if re.search(r"resumen:\s*hecho=\d+", cola):
    sys.exit(0)

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
