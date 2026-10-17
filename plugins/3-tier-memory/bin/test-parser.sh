#!/bin/bash
# Regresiones de los bloques python de session-start.sh: el detector de hook local que vuelca
# pendientes y la guarda de ambito al instalar comandos.
#
# Hasta 2.62 este archivo probaba tambien el parser de _pendientes.md que alimentaba la lista
# de pendientes del arranque. Ese parser se fue con la lista (medido: el agente no la usaba, 0 de
# 40 sesiones); el cruce de pendientes por peticion vive en build-recall-index.py y tiene sus
# propias pruebas. El nombre del archivo se queda para no mover run-tests.sh ni la CI.
#
# Cada caso aqui es un fallo que YA OCURRIO en produccion o que una verificacion
# adversarial encontro antes de publicarse. Todos comparten la misma forma: el hook
# se queda callado y el usuario no tiene como notarlo.
#
# Uso: bash bin/test-parser.sh    (sin dependencias; sale != 0 si algo falla)

set -u
HOOK="$(dirname "$0")/session-start.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ERR="$TMP/stderr"

# Un test que acepta cualquier salida acepta tambien un traceback: la ausencia del
# patron y la muerte del script se ven igual. Por eso stderr va aparte y se exige
# salida limpia ANTES de mirar el patron — el arnes no puede consumir no-evidencia.
run() { # comando de python -> stdout; falla si escribio en stderr o salio != 0
  : > "$ERR"
  OUT=$("$@" 2>"$ERR"); RC=$?
  [ "$RC" -eq 0 ] && [ ! -s "$ERR" ]
}
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; shift; [ -n "${1:-}" ] && echo "$1" | sed 's/^/         /'; }

# --- detector de hook local que vuelca pendientes ------------------------------
# Vive en el mismo hook. Hasta 2.62 se llamaba "duplicado" (el plugin inyectaba pendientes y
# el volcado se le sumaba). Los casos de aqui los encontro una verificacion adversarial: la
# deteccion pasaba por alto formas de escritura perfectamente normales, o sea fallaba en silencio.
DUP="$TMP/dupcheck.py"
python3 - "$HOOK" "$DUP" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
a = next(i for i, l in enumerate(lines) if "<<'DUPEOF'" in l)
b = next(i for i, l in enumerate(lines) if l.strip() == "DUPEOF" and i > a)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines[a + 1:b]))
PY

mkproj() { # dir, comando-del-hook
  mkdir -p "$1/.claude/hooks" "$1/memory"
  printf '#!/bin/bash\nP=$(grep -E "^- \\[ \\]" "$CLAUDE_PROJECT_DIR/memory/_pendientes.md")\necho "$P"\n' > "$1/.claude/hooks/session-start.sh"
  printf '# P\n\n## Alta prioridad\n- [ ] x\n' > "$1/memory/_pendientes.md"
  # El comando se serializa con json.dumps: escribirlo con printf rompia el JSON en
  # cuanto llevaba comillas, y entonces el detector no leia nada — un test que pasa
  # porque su fixture esta roto es exactamente la no-evidencia que este arnes rechaza.
  # El comando viaja por FICHERO, no por una variable de entorno. En Git Bash, MSYS convierte los
  # valores de entorno que parecen rutas: un comando que empieza por `/usr/bin/env ...` se
  # reescribia a la forma de Windows antes de llegar a python y el fixture quedaba mutilado. El
  # detector funcionaba —comprobado en CI contra un fixture escrito sin pasar por el entorno— y lo
  # que fallaba era el montaje. Por stdin tampoco puede ser: ahi va el propio programa. La RUTA del
  # fichero si es convertible sin dano, porque es una ruta de verdad. (CI, 2026-09-12.)
  printf '%s' "$2" > "$1/.claude/.cmd.tmp"
  python3 - "$1/.claude/settings.local.json" "$1/.claude/.cmd.tmp" <<'PY'
import json, sys
cfg = {"hooks": {"SessionStart": [{"matcher": "", "hooks": [
    {"type": "command", "command": open(sys.argv[2], encoding="utf-8").read()}]}]}}
json.dump(cfg, open(sys.argv[1], "w", encoding="utf-8"))
PY
  rm -f "$1/.claude/.cmd.tmp"
}
expect() { # nombre, dir, si|no
  if ! python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$2/.claude/settings.local.json" 2>/dev/null; then
    fail "$1 (fixture invalido: settings.local.json no es JSON)"; return
  fi
  if ! CLAUDE_PROJECT_DIR="$2" MEMORY_DIR="$2/memory" run python3 "$DUP"; then
    fail "$1 (el detector murio)" "$(cat "$ERR")"; return
  fi
  # El marcador exacto, no "hubo salida": un traceback no es una deteccion.
  local got=no; echo "$OUT" | grep -q '^HOOK DE PENDIENTES' && got=si
  if [ "$got" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok   $1"
  else fail "$1 (esperado=$3 obtenido=$got)" "$OUT"; fi
}

# El aviso ya no puede llamar "duplicado" al volcado: el plugin dejo de inyectar pendientes y no
# hay nada que duplicar. Debe dar el tamano y la medicion, y decir que /migrate no lo borra solo.
mkproj "$TMP/d0" 'bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
if ! CLAUDE_PROJECT_DIR="$TMP/d0" MEMORY_DIR="$TMP/d0/memory" run python3 "$DUP"; then
  fail "texto del aviso (el detector murio)" "$(cat "$ERR")"
elif echo "$OUT" | grep -qi 'duplic\|ya inyecta'; then
  fail "el aviso no dice que el volcado duplica al plugin" "$OUT"
elif ! echo "$OUT" | grep -q 'vuelca [0-9]* B de pendientes crudos'; then
  fail "el aviso da el tamano del volcado" "$OUT"
elif ! echo "$OUT" | grep -q '1 de 40' || ! echo "$OUT" | grep -q 'no lo borra por defecto'; then
  fail "el aviso da la medicion y que /migrate no borra por defecto" "$OUT"
else
  PASS=$((PASS + 1)); echo "  ok   el aviso da tamano y medicion, sin llamarlo duplicado"
fi

# Forma con llaves: se expandia solo $CLAUDE_PROJECT_DIR, no ${CLAUDE_PROJECT_DIR}.
mkproj "$TMP/d1" 'bash ${CLAUDE_PROJECT_DIR}/.claude/hooks/session-start.sh'
expect "detecta \${CLAUDE_PROJECT_DIR} con llaves" "$TMP/d1" si

# Un comando con dos scripts: se miraba solo el primero, asi que un huerfano lo tapaba.
mkproj "$TMP/d2" 'bash $CLAUDE_PROJECT_DIR/.claude/hooks/no-existe.sh && bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
expect "huerfano primero no tapa al script real" "$TMP/d2" si

# El propio hook del plugin no es duplicado de si mismo.
mkproj "$TMP/d3" 'bash "${CLAUDE_PLUGIN_ROOT}/bin/session-start.sh"'
expect "no se autodenuncia (CLAUDE_PLUGIN_ROOT)" "$TMP/d3" no

# Entrada huerfana sola: la reporta /migrate, no es duplicacion de contexto.
mkproj "$TMP/d4" 'bash $CLAUDE_PROJECT_DIR/.claude/hooks/no-existe.sh'
rm -f "$TMP/d4/.claude/hooks/session-start.sh"
expect "entrada huerfana no cuenta como duplicado" "$TMP/d4" no

# Solo MENCIONADO, no ejecutado: buscar ".sh" en el texto del comando mandaba al
# usuario a /migrate por un echo. Falso positivo encontrado por verificacion adversarial.
mkproj "$TMP/d5" 'echo "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh"'
expect "ruta solo mencionada no es ejecucion" "$TMP/d5" no

# ...pero detras de un interprete si cuenta, aunque no sea el primer token.
mkproj "$TMP/d6" '/usr/bin/env bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
expect "interprete + script si es ejecucion" "$TMP/d6" si

# Marcador dentro del script pero mas alla de 200 KB: el tope de lectura lo ocultaba.
mkproj "$TMP/d7" 'bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
python3 - "$TMP/d7/.claude/hooks/session-start.sh" <<'PY'
import sys
p = sys.argv[1]
body = "#!/bin/bash\n" + ("# relleno\n" * 30000) + 'echo "$(cat memory/_pendientes.md)"\n'
open(p, "w", encoding="utf-8").write(body)
PY
expect "marcador mas alla de 200 KB se detecta" "$TMP/d7" si

# Prefijos que no cambian que se ejecuta, y ruta relativa. Los cinco se escapaban.
mkproj "$TMP/d8" 'exec bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
expect "exec bash" "$TMP/d8" si
mkproj "$TMP/d9" 'nohup bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
expect "nohup bash" "$TMP/d9" si
mkproj "$TMP/d10" 'command bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
expect "command bash" "$TMP/d10" si
mkproj "$TMP/d11" 'FOO=1 bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
expect "asignacion antes del interprete" "$TMP/d11" si
mkproj "$TMP/d12" 'bash ./.claude/hooks/session-start.sh'
expect "ruta relativa" "$TMP/d12" si

# `builtin bash x.sh` no ejecuta nada (bash no es builtin): tratarlo como prefijo
# transparente reportaba una ejecucion inexistente.
mkproj "$TMP/d13" 'builtin bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh'
expect "builtin no es prefijo transparente" "$TMP/d13" no

# `-c` lleva un PROGRAMA, no una ruta: aplanar sus tokens colaba una mencion.
mkproj "$TMP/d14" 'bash -c "echo ./.claude/hooks/session-start.sh"'
expect "mencion dentro de -c no es ejecucion" "$TMP/d14" no

# ...pero si el programa de -c si ejecuta el script, cuenta.
mkproj "$TMP/d15" 'bash -c "bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh"'
expect "ejecucion dentro de -c si cuenta" "$TMP/d15" si

# -c solo es un programa si quien lo recibe es una shell.
mkproj "$TMP/d16" 'echo -c "bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh"'
expect "-c de un no-interprete no es ejecucion" "$TMP/d16" no

# --- guarda de ambito: no instalar comandos en el ambito USER --------------------
# Si la sesion se abre desde $HOME, "$CLAUDE_PROJECT_DIR/.claude/commands" ES
# ~/.claude/commands (ambito user), y el usuario termina con cada comando duplicado
# en todos sus proyectos, sin rastro del origen. Se prueba con un HOME falso.
FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME/memory"
printf '# P\n\n## Alta prioridad\n- [ ] x\n' > "$FAKEHOME/memory/_pendientes.md"

: > "$ERR"
HOME="$FAKEHOME" CLAUDE_PROJECT_DIR="$FAKEHOME" CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)" \
  bash "$HOOK" < /dev/null > "$TMP/home.out" 2>"$ERR"
INSTALADOS=$(find "$FAKEHOME/.claude/commands" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
# Desde 2.17.0 el hook emite UN objeto JSON, no texto plano: el aviso vive dentro de
# `additionalContext`. Se lee como JSON a proposito — buscarlo con grep sobre el crudo
# pasaria igual con un JSON roto, y un JSON roto es "el hook no hizo nada".
AVISO=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
ctx = d.get('hookSpecificOutput', {}).get('additionalContext', '')
print('si' if any(l.startswith('AVISO:') for l in ctx.splitlines()) else '')
" "$TMP/home.out" 2>/dev/null)
if [ "$INSTALADOS" -eq 0 ] && [ "$AVISO" = "si" ]; then
  PASS=$((PASS + 1)); echo "  ok   no instala comandos en el ambito USER"
else
  fail "no instala comandos en el ambito USER (instalados=$INSTALADOS)" "$(head -5 "$TMP/home.out")"
fi

# Control: desde un proyecto normal si los instala.
PROJ="$TMP/proyecto"
mkdir -p "$PROJ/memory"
printf '# P\n\n## Alta prioridad\n- [ ] x\n' > "$PROJ/memory/_pendientes.md"
: > "$ERR"
HOME="$FAKEHOME" CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)" \
  bash "$HOOK" < /dev/null > "$TMP/proj.out" 2>"$ERR"
INSTALADOS=$(find "$PROJ/.claude/commands" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "$INSTALADOS" -gt 0 ]; then
  PASS=$((PASS + 1)); echo "  ok   si instala comandos en un proyecto normal"
else
  fail "si instala comandos en un proyecto normal (instalados=$INSTALADOS)" "$(head -5 "$TMP/proj.out")"
fi

echo "  ---- $PASS ok, $FAIL fallo(s)"
[ "$FAIL" -eq 0 ]
