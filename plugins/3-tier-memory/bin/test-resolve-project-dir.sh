#!/bin/bash
# sella-huellas: no (prueba: no escribe nada en memory/)
# Regresiones de bin/resolve-project-dir.sh (v2.14.3).
#
# El fichero lo sourcean los ocho hooks del plugin y tenia dos defectos que se ven igual desde
# fuera — "el hook no hizo nada":
#   D1  referenciaba $CLAUDE_PLUGIN_ROOT / $CLAUDE_PROJECT_DIR sin proteger, asi que un llamante
#       con `set -u` moria en la primera linea util (p-a4fcd4212a);
#   D2  `_HOOK_INPUT=$(cat)` esperaba EOF para siempre, asi que sin stdin se colgaba (p-0e978674af).
#
# Las dos pruebas rojas son "A/B con -u sin las variables en el entorno" y "fifo que nadie
# escribe". Las demas fijan lo que ya funcionaba, para que el arreglo no lo cambie.
#
# Uso:  bash bin/test-resolve-project-dir.sh
#       RESOLVE_SH=/ruta/a/una/copia.sh bash bin/test-resolve-project-dir.sh   <- para verlo ROJO
#                                                                                contra el original
# Sale != 0 si algo falla.

set -u
RESOLVE_SH="${RESOLVE_SH:-$(cd "$(dirname "$0")" && pwd)/resolve-project-dir.sh}"
[ -f "$RESOLVE_SH" ] || { echo "no existe: $RESOLVE_SH"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; SKIP=0; OUT=""; RC=0
ERR="$TMP/stderr"; DUMP="$TMP/hookinput"
echo "SUT: $RESOLVE_SH"

ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/         /'; return 0; }

# Sonda: sourcea el fichero bajo `set -u` y USA las dos variables y $_HOOK_INPUT despues, que es
# lo que hace un hook de verdad. Si el source aborta, no sale SENTINEL.
cat > "$TMP/probe.sh" <<'EOF'
set -u
source "$RESOLVE_SH"
printf '%s' "$_HOOK_INPUT" > "$DUMP"
printf 'SENTINEL dir=[%s] root=[%s] len=[%s]\n' "$CLAUDE_PROJECT_DIR" "$CLAUDE_PLUGIN_ROOT" "${#_HOOK_INPUT}"
EOF

# Igual, pero bajo `set -e`: el arreglo mete un `read` que devuelve != 0 cuando no llega el primer
# byte. `$(cat)` devolvia 0 siempre, o sea que esto es superficie NUEVA del arreglo, no del defecto.
cat > "$TMP/probe-e.sh" <<'EOF'
set -eu
source "$RESOLVE_SH"
printf 'SENTINEL dir=[%s] len=%s\n' "$CLAUDE_PROJECT_DIR" "${#_HOOK_INPUT}"
EOF

# env -u: CLAUDE_PLUGIN_ROOT suele estar puesto en una sesion real y entonces el codigo viejo
# NUNCA toca la expansion sin proteger — la prueba pasaria sin probar nada.
probe() { # probe_file  (stdin lo pone el llamante) -> OUT, RC
  : > "$ERR"; : > "$DUMP"
  OUT=$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
        RESOLVE_SH="$RESOLVE_SH" DUMP="$DUMP" HOOK_STDIN_TIMEOUT=2 \
        bash "$TMP/$1" 2>"$ERR"); RC=$?
}
sentinel() { # nombre
  if [ "$RC" -eq 0 ] && [ ! -s "$ERR" ] && [ "${OUT#SENTINEL}" != "$OUT" ]; then ok; return 0; fi
  fail "$1" "rc=$RC out='$OUT' err=$(cat "$ERR")"; return 1
}
field() { echo "$OUT" | sed -n "s/.*$1=\[\([^]]*\)\].*/\1/p"; }

JSON='{"session_id":"t","cwd":"'"$TMP"'/proj","hook_event_name":"PreToolUse"}'
mkdir -p "$TMP/proj"

# En Git Bash el mismo directorio tiene dos ortografias —MSYS (/tmp/x) y nativa (C:/.../Temp/x)— y
# el respaldo de python3 devuelve la segunda mientras el shell construye la primera. Se comparan
# rutas, no cadenas. Fuera de Windows `cygpath` no existe y esto no toca nada. (CI, 2026-09-12.)
norm() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
IN="$TMP/in"   # stdin por REDIRECCION, nunca por tuberia: `x | probe` corre probe en un subshell
printf '%s' "$JSON" > "$IN"

echo "D1 — sourceable bajo set -u:"
probe probe.sh < "$IN"
if sentinel "set -u + stdin con JSON no debe abortar"; then
  [ "$(norm "$(field dir)")" = "$(norm "$TMP/proj")" ] && ok || fail "cwd del JSON mal resuelto: '$(field dir)'"
fi
probe probe.sh < /dev/null
if sentinel "set -u + stdin vacio no debe abortar"; then
  # La propiedad que el llamante necesita: la variable queda DEFINIDA aunque no haya ruta.
  [ "$(field dir)" = "" ] && ok || fail "sin JSON esperaba dir vacio, salio '$(field dir)'"
fi
printf 'esto no es json' > "$TMP/roto"; probe probe.sh < "$TMP/roto"
sentinel "set -u + stdin que no es JSON no debe abortar"
probe probe-e.sh < "$IN"
sentinel "set -e: read devuelve 1 en EOF y no debe matar al llamante"

echo "D2 — sin stdin no se cuelga:"
# Un fifo abierto en lectura-escritura y nunca escrito: el escritor no existe, EOF no llega nunca.
# (Abrirlo solo para escribir bloquearia al propio test.) Codigo viejo: se cuelga y lo mata el
# limite. Codigo nuevo: vuelve al agotar HOOK_STDIN_TIMEOUT=2, con _HOOK_INPUT vacio.
FIFO="$TMP/nadie-escribe"; mkfifo "$FIFO"
exec 9<>"$FIFO"
: > "$ERR"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR RESOLVE_SH="$RESOLVE_SH" DUMP="$DUMP" \
    HOOK_STDIN_TIMEOUT=2 bash "$TMP/probe.sh" > "$TMP/out" 2>"$ERR" < "$FIFO" &
BG=$!; N=0
while kill -0 "$BG" 2>/dev/null && [ "$N" -lt 8 ]; do sleep 1; N=$((N + 1)); done
if kill -0 "$BG" 2>/dev/null; then
  kill -9 "$BG" 2>/dev/null; wait "$BG" 2>/dev/null
  fail "fifo sin escritor: seguia vivo a los 8 s (se cuelga)"
else
  wait "$BG"; RC=$?; OUT=$(cat "$TMP/out")
  if [ "$RC" -eq 0 ] && [ "${OUT#SENTINEL}" != "$OUT" ] && [ "$(field len)" = "0" ]; then ok
  else fail "fifo sin escritor: esperaba volver limpio y vacio" "rc=$RC out='$OUT' err=$(cat "$ERR")"; fi
fi
exec 9>&-; rm -f "$FIFO"

# stdin en un terminal: vuelve al instante, sin esperar el tope. Necesita un pty de verdad; en
# donde `script` no lo de, se salta y se informa (mismo criterio que el bloque cygpath de
# test-journal-guard.sh).
# NO es la prueba roja de D2: `script` cierra el pty al terminar, o sea que manda EOF y `$(cat)`
# del codigo viejo tambien volvia. Medido — con solo D1 arreglado este caso pasa. El discriminador
# de D2 es el fifo de arriba; este fija el camino rapido.
# `script` hereda el stdin del llamante y sin `</dev/null` la deteccion sale distinta segun quien
# corra la suite (medido: 0/3 sin redirigir, 3/3 con /dev/null). Se redirige siempre.
PTY=""
if command -v script >/dev/null 2>&1; then
  if script -q /dev/null /bin/bash -c '[ -t 0 ] && echo TTYOK' </dev/null 2>/dev/null | grep -q TTYOK; then
    PTY="script -q /dev/null"
  elif script -qec '[ -t 0 ] && echo TTYOK' /dev/null </dev/null 2>/dev/null | grep -q TTYOK; then
    PTY="linux"
  fi
fi
if [ -z "$PTY" ]; then
  SKIP=$((SKIP + 1)); echo "  SKIP terminal en stdin (sin pty utilizable)"
else
  S=$SECONDS
  if [ "$PTY" = "linux" ]; then
    O=$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR RESOLVE_SH="$RESOLVE_SH" DUMP="$DUMP" \
        HOOK_STDIN_TIMEOUT=9 script -qec "bash $TMP/probe.sh" /dev/null </dev/null 2>/dev/null)
  else
    O=$(env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR RESOLVE_SH="$RESOLVE_SH" DUMP="$DUMP" \
        HOOK_STDIN_TIMEOUT=9 script -q /dev/null /bin/bash "$TMP/probe.sh" </dev/null 2>/dev/null)
  fi
  W=$((SECONDS - S))
  if [ "${O#*SENTINEL}" != "$O" ] && [ "$W" -lt 5 ]; then ok
  else fail "terminal en stdin: esperaba volver en <5 s con SENTINEL (tardo ${W}s)" "$O"; fi
fi

echo "lo que ya funcionaba (no debe cambiar):"
probe probe.sh < "$IN"
if sentinel "CLAUDE_PLUGIN_ROOT se deduce de la ruta del script"; then
  EXPECT="$(cd "$(dirname "$RESOLVE_SH")/.." && pwd)"
  [ "$(field root)" = "$EXPECT" ] && ok || fail "root: esperaba '$EXPECT', salio '$(field root)'"
fi
: > "$ERR"; : > "$DUMP"
OUT=$(printf '%s' "$JSON" | env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$TMP/desde-entorno" \
      RESOLVE_SH="$RESOLVE_SH" DUMP="$DUMP" HOOK_STDIN_TIMEOUT=2 bash "$TMP/probe.sh" 2>"$ERR"); RC=$?
if [ "$RC" -eq 0 ] && [ "$(norm "$(field dir)")" = "$(norm "$TMP/desde-entorno")" ]; then ok
else fail "el entorno gana sobre el cwd del JSON" "rc=$RC out='$OUT' err=$(cat "$ERR")"; fi

# _HOOK_INPUT llega entero a los llamantes: seis hooks lo reenvian a un parser de JSON o lo
# comparan con `case`. Multilinea y 20 KB, que es donde un reensamblado por lineas se rompe.
# Las dos siguientes NO discriminan D1 ni D2: vigilan el ARREGLO, porque el tope que cierra D2 es
# tambien la forma mas facil de truncar. journal-guard.sh es PreToolUse de Write: `tool_input.content`
# trae el fichero entero, megabytes, que no llegan en un solo trozo.
#   (a) 5 MB de una vez, con limite de tiempo;
#   (b) un productor que manda un cacho, PARA MAS QUE EL TOPE y manda el resto. Medido: acotar la
#       lectura entera (`read -r -d '' -t 2`, la primera forma que se probo) deja 0 bytes aqui.
HUGE="$TMP/huge"
python3 -c "import sys;sys.stdout.write('{\"cwd\":\"$TMP/proj\",\"content\":\"' + 'z'*5000000 + '\"}')" > "$HUGE"
S=$SECONDS; probe probe.sh < "$HUGE"; W=$((SECONDS - S))
if sentinel "JSON de 5 MB: llega entero"; then
  IN=$(wc -c < "$HUGE" | tr -d ' '); GOT=$(wc -c < "$DUMP" | tr -d ' ')
  [ "$IN" = "$GOT" ] && ok || fail "5 MB truncado: entraron $IN bytes, salieron $GOT"
  [ "$W" -lt 10 ] && ok || fail "5 MB tardo ${W}s (el tope son 10 s): se esta leyendo byte a byte"
fi
SLOW='import sys,time;sys.stdout.write("{\"cwd\":\"/x\",\"a\":\"" + "z"*300);sys.stdout.flush();time.sleep(4);sys.stdout.write("z"*300 + "\"}");sys.stdout.flush()'
: > "$ERR"; : > "$DUMP"
OUT=$(python3 -c "$SLOW" | env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR RESOLVE_SH="$RESOLVE_SH" \
      DUMP="$DUMP" HOOK_STDIN_TIMEOUT=2 bash "$TMP/probe.sh" 2>"$ERR"); RC=$?
GOT=$(wc -c < "$DUMP" | tr -d ' ')
if [ "$RC" -eq 0 ] && [ "$GOT" = "619" ]; then ok
else fail "productor que pausa 4 s con el tope en 2 s: el mensaje debe llegar entero" \
     "rc=$RC bytes=$GOT (esperaba 619) err=$(cat "$ERR")"; fi

BIG=$(python3 -c "print('{\"cwd\":\"/x\",\"big\":\"' + 'z'*20000 + '\"}')")
printf '%s' "$BIG" > "$TMP/big"; probe probe.sh < "$TMP/big"
if sentinel "JSON de 20 KB sobrevive"; then
  [ "$(cat "$DUMP")" = "$BIG" ] && ok || fail "20 KB: _HOOK_INPUT no coincide (len=$(wc -c < "$DUMP"))"
fi
ML='{"a":1,
"b":"dos"}'
printf '%s\n' "$ML" > "$TMP/ml"; probe probe.sh < "$TMP/ml"
if sentinel "JSON multilinea sobrevive"; then
  [ "$(cat "$DUMP")" = "$ML" ] && ok || fail "multilinea: _HOOK_INPUT no coincide: <$(cat "$DUMP")>"
fi

# Sin jq en el PATH se usa el respaldo de python3. El PATH minimo deja python3 pero no jq.
JQLESS="$TMP/bin"; mkdir -p "$JQLESS"
for c in python3 bash sed cat env; do P=$(command -v $c) && ln -sf "$P" "$JQLESS/$c"; done
: > "$ERR"; : > "$DUMP"
# `env -i` borra SYSTEMROOT, y el python de Windows NO ARRANCA sin el: el respaldo moria antes de
# empezar y el caso acusaba al codigo de no resolver el cwd. Se conserva solo esa variable, y solo
# donde existe, para que el entorno siga siendo minimo en POSIX. (CI, 2026-09-12.)
SYSROOT_KEEP=""; [ -n "${SYSTEMROOT:-}" ] && SYSROOT_KEEP="SYSTEMROOT=$SYSTEMROOT"
# En Windows `bash.exe` carga sus DLL por PATH, asi que un PATH reducido a un directorio de enlaces
# le quita las suyas y no arranca: `error while loading shared libraries`. La precondicion de este
# caso —un entorno sin jq pero con bash— no se puede construir ahi. Se sonda y se salta con aviso,
# igual que el caso del pty. Un salto contado es honesto; un fallo dice que el codigo esta mal
# cuando lo que falta es el escenario. (CI, 2026-09-12.)
if ! env -i $SYSROOT_KEEP PATH="$JQLESS" "$JQLESS/bash" -c 'exit 0' 2>/dev/null; then
  SKIP=$((SKIP + 1)); echo "  SKIP sin jq: el respaldo de python3 (el bash aislado no arranca aqui)"
else
OUT=$(printf '%s' "$JSON" | env -i $SYSROOT_KEEP PATH="$JQLESS" RESOLVE_SH="$RESOLVE_SH" DUMP="$DUMP" \
      HOOK_STDIN_TIMEOUT=2 "$JQLESS/bash" "$TMP/probe.sh" 2>"$ERR"); RC=$?
if [ "$RC" -eq 0 ] && [ "$(norm "$(field dir)")" = "$(norm "$TMP/proj")" ]; then ok
else fail "sin jq: el respaldo de python3 debe resolver el cwd" "rc=$RC out='$OUT' err=$(cat "$ERR")"; fi
fi

echo "RESULT: pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
