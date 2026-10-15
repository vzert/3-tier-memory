#!/usr/bin/env bash
# Prueba de tools/tmp-propio.sh (p-292d06c4c0): el temporal de una corrida se borra tambien cuando
# la matan, y los restos viejos se avisan sin borrarlos.
#
# Las senales llegan a un runner falso que esta en un `sleep 1` en primer plano, como run-tests
# mientras corre una suite: bash aplaza el trap de TERM/INT/HUP hasta que ese hijo termina, asi que
# la limpieza ocurre al acabar la suite en curso, no al instante. Por eso se espera antes de mirar.
#
# Todo pasa bajo un TMPDIR propio de esta prueba: no se toca el temporal del sistema.
#
# sella-huellas: no (trabaja en un temporal propio)
set -u
AQUI="$(cd "$(dirname "$0")" && pwd)"
HELPER="${TMP_PROPIO:-$AQUI/tmp-propio.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }

BASE="$T/base"; mkdir -p "$BASE"
# El runner falso: carga el ayudante, apunta su TMPDIR, crea una carpeta como haria una suite y se
# queda en primer plano el tiempo justo para recibir la senal.
cat > "$T/runner.sh" <<EOF
. "$HELPER"
tmp_propio_avisos
echo "\$TMPDIR" > "$T/tmpdir"
mktemp -d > "$T/hija"
bash -c 'mktemp -d' > "$T/nieta"
sleep "\${ESPERA:-0}"
exit "\${RC:-0}"
EOF
# unset TMP_PROPIO_DIR: si esta prueba corre dentro de run-tests, el runner falso no debe verse
# anidado.
corre() { env -u TMP_PROPIO_DIR TMPDIR="$BASE" "$@" bash "$T/runner.sh" 2>"$T/err"; }

echo "== 1. una salida normal borra el temporal y conserva el codigo de salida =="
rm -f "$T/tmpdir"
corre RC=3; rc=$?
D=$(cat "$T/tmpdir")
chk "exporta un TMPDIR propio" "$BASE/3tm-tests.x" "$(dirname "$D")/$(basename "$D" | cut -d. -f1).x"
has "la carpeta de la suite cayo dentro" "$(cat "$T/hija")" "^$D/"
# macOS 26: `mktemp -d` no lee TMPDIR; sin la funcion exportada la suite (un bash hijo) caia fuera.
has "y la de un bash hijo, tambien" "$(cat "$T/nieta")" "^$D/"
chk "el codigo de salida se conserva" "3" "$rc"
chk "el temporal ya no existe" "no" "$([ -d "$D" ] && echo si || echo no)"

for sig in TERM INT HUP; do
  echo "== 2. matado con $sig: el temporal se borra al acabar la suite en curso =="
  rm -f "$T/tmpdir"
  env -u TMP_PROPIO_DIR TMPDIR="$BASE" ESPERA=1 bash "$T/runner.sh" 2>/dev/null &
  p=$!
  n=0; while [ ! -s "$T/tmpdir" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
  D=$(cat "$T/tmpdir")
  kill -"$sig" "$p"
  wait "$p" 2>/dev/null
  chk "tras $sig el temporal ya no existe" "no" "$([ -d "$D" ] && echo si || echo no)"
done

echo "== 3. anidado: con TMP_PROPIO_DIR puesto no crea otro =="
# Con un padre de verdad que cargo el ayudante: un TMP_PROPIO_DIR puesto a mano no exporta la
# funcion mktemp, y en macOS 26 el `mktemp -d` del runner caia en el temporal del sistema (2 carpetas
# por corrida de esta prueba, medido).
rm -f "$T/tmpdir"
env -u TMP_PROPIO_DIR TMPDIR="$BASE" bash -c '. "$1"; echo "$TMPDIR" > "$2/padre"; bash "$2/runner.sh"' \
  _ "$HELPER" "$T" 2>/dev/null
P=$(cat "$T/padre")
chk "hereda el TMPDIR del padre" "$P" "$(cat "$T/tmpdir")"
has "y la carpeta del hijo cae en la del padre" "$(cat "$T/hija")" "^$P/"
has "y la de un bash nieto, tambien" "$(cat "$T/nieta")" "^$P/"
chk "y no deja carpetas propias" "0" "$(ls -d "$BASE"/3tm-tests.* 2>/dev/null | wc -l | tr -d ' ')"

echo "== 4. restos viejos: avisa, con el comando, y no borra =="
sleep 0 & muerto=$!; wait "$muerto"
mkdir -p "$BASE/3tm-tests.$muerto.abcdef" "$BASE/3tm-tests.$$.vivo1" "$BASE/tmp.viejo1" "$BASE/tmp.nuevo1"
touch -t 202001010000 "$BASE/tmp.viejo1"
corre
E=$(cat "$T/err")
has "avisa de la carpeta de un proceso muerto" "$E" "1 carpeta(s) de corridas anteriores"
has "con el comando para borrarla" "$E" "rm -rf \"$BASE/3tm-tests.$muerto.abcdef\""
chk "no avisa de la de un proceso vivo" "0" "$(printf '%s' "$E" | grep -c "3tm-tests.$$.vivo1")"
has "avisa de las tmp.* de mas de 60 min" "$E" "1 carpeta(s) tmp.\* de mas de 60 min"
chk "no borra la del proceso muerto" "si" "$([ -d "$BASE/3tm-tests.$muerto.abcdef" ] && echo si || echo no)"
chk "ni la tmp.* vieja" "si" "$([ -d "$BASE/tmp.viejo1" ] && echo si || echo no)"

echo "== 5. pkill del run-tests de verdad a mitad de una suite: no deja carpetas tmp.* nuevas =="
# Una copia del run-tests.sh real y de este ayudante, en un repo minimo. pkill mata al runner Y a la
# suite (un Ctrl-C, o `pkill -f 'run-tests|mutation-check'`). Medido: bash SI corre el `trap ... EXIT`
# con TERM/INT/HUP, asi que una suite con su trap se limpia sola. La que deja restos es la que crea
# su carpeta SIN trap y la borra al final, como cada caso de mutation-check.sh (`D=$(mktemp -d)`):
# esa es la suite lenta de aqui. Control: la misma copia SIN tmp-propio.sh deja la carpeta, asi que
# el caso sabe fallar.
RT_REAL="${RUN_TESTS:-$AQUI/run-tests.sh}"
cat > "$T/suite-lenta.sh" <<'EOF'
d=$(mktemp -d "$TMPDIR/tmp.XXXXXX"); echo "$d" > "$MARCA"
sleep 5
rm -rf "$d"; echo "pass=1 fail=0"
EOF
mata_a_mitad() {  # <repo> <base>: arranca run-tests --una, lo mata con pkill a mitad y espera
  local repo="$1" base="$2" n=0 p
  rm -f "$T/marca"
  env -u TMP_PROPIO_DIR TMPDIR="$base" MARCA="$T/marca" \
    bash "$repo/tools/run-tests.sh" --una lenta bash "$T/suite-lenta.sh" >/dev/null 2>&1 &
  p=$!
  while [ ! -s "$T/marca" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
  pkill -TERM -f "$repo/tools/run-tests.sh"; pkill -TERM -f "$T/suite-lenta.sh"
  wait "$p" 2>/dev/null
  n=0; while pgrep -f "$T/suite-lenta.sh" >/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n+1)); done
}
cuenta() { ls -d "$1"/tmp.* "$1"/3tm-tests.* 2>/dev/null | wc -l | tr -d ' '; }
for caso in con sin; do
  R="$T/repo-$caso"; B="$T/base-$caso"; mkdir -p "$R/tools" "$B"
  cp "$RT_REAL" "$R/tools/run-tests.sh"
  [ "$caso" = con ] && cp "$HELPER" "$R/tools/tmp-propio.sh"
  antes=$(cuenta "$B")
  mata_a_mitad "$R" "$B"
  chk "la suite llego a crear su carpeta ($caso tmp-propio)" "si" "$([ -s "$T/marca" ] && echo si || echo no)"
  if [ "$caso" = con ]; then
    chk "tras pkill no quedan carpetas nuevas" "$antes" "$(cuenta "$B")"
  else
    chk "control: sin tmp-propio el mismo pkill deja la carpeta" "$((antes+1))" "$(cuenta "$B")"
  fi
done

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
