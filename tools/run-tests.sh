#!/usr/bin/env bash
# Corre TODAS las suites del repo y devuelve 1 si alguna falla.
#
# Por que existe: habia 11 suites y ningun runner, asi que solo corrian cuando alguien se acordaba
# de lanzarlas a mano, una por una. Un defecto que una suite ya cubria podia publicarse igual.
#
# Incluye `check-ignored-tracked.sh`, que no es una suite del plugin sino higiene del repo: es el
# unico guard que existe contra volver a publicar un fichero que `.gitignore` excluye.
#
# Uso:  tools/run-tests.sh          (exit 0 = todo verde)
#       tools/run-tests.sh -v       (vuelca la salida completa de cada suite)
#
# Una suite verde sale 0 Y termina con su linea de resumen (ver RESUMEN). rc=0 sin resumen es FALLA.
#
# sella-huellas: no (las suites trabajan en temporales propios; este script solo las invoca)
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 2

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

BIN="plugins/3-tier-memory/bin"
FALLOS=0
TOTAL=0
LENTAS=""
SALTADAS=""
PARCIALES=""

# Ultima linea de una suite que termino: su resumen. Cada suite tiene el suyo (pass=N fail=N,
# TODO VERDE, RESULT: PASS, == resumen: ...). Una suite NUEVA con otro formato sale FALLA con
# "sin linea de resumen": anade aqui su formato, no le quites el resumen.
RESUMEN='^[[:space:]]*(RESULT(ADO)?:? |pass=[0-9]|PASS[ =]|(test-bench: )?TODO VERDE|== resumen: |---- [0-9]+ ok|OK: |LAS EVALUABLES DISCRIMINAN)'

# rc=0 y la ultima linea no es un resumen: la suite murio a mitad. Pasa con `set -e` y un
# `trap '...' EXIT` (bash 3.2): un error de sintaxis a mitad corta la suite y el rc del trap (0)
# tapa el 2 del error (p-46153b135b, test-checkpoint-close-guard.sh, 2026-10-01).
sin_resumen() { ! printf '%s' "$1" | tail -1 | tr -d '\r' | grep -qE "$RESUMEN"; }

correr() {   # $1 = etiqueta, $2... = comando
  local nom="$1"; shift
  local ini fin dur out rc
  ini=$(date +%s)
  out=$("$@" 2>&1); rc=$?
  fin=$(date +%s); dur=$(( fin - ini ))
  TOTAL=$(( TOTAL + 1 ))
  [ "$dur" -ge 5 ] && LENTAS="$LENTAS $nom(${dur}s)"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | tail -1 | grep -q '^SKIP'; then
    # Un SKIP sale 0 pero NO es verde: no corrio nada. Contarlo como ok es exactamente el arnes
    # que acepta no-evidencia (regla 12). Se lista aparte y el resumen deja de decir TODO VERDE.
    SALTADAS="$SALTADAS $nom"
    printf '  skip %-32s %3ss  %s\n' "$nom" "$dur" "$(printf '%s' "$out" | tail -1 | cut -c1-46)"
  elif [ "$rc" -eq 0 ] && printf '%s' "$out" | tail -1 | grep -qE '[1-9][0-9]* saltad'; then
    # Salto PARCIAL: la suite corrio pero dejo casos sin correr (p. ej. el caso 29 de
    # test-session-amend.sh sin chflags). Tampoco es TODO VERDE.
    PARCIALES="$PARCIALES $nom"
    printf '  skip %-32s %3ss  %s\n' "$nom" "$dur" "$(printf '%s' "$out" | tail -1 | cut -c1-46)"
  elif [ "$rc" -eq 0 ] && sin_resumen "$out"; then
    FALLOS=$(( FALLOS + 1 ))
    printf '  FALLA %-32s %3ss  rc=0 sin linea de resumen (murio a mitad?)\n' "$nom" "$dur"
    printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
  elif [ "$rc" -eq 0 ]; then
    printf '  ok   %-32s %3ss  %s\n' "$nom" "$dur" "$(printf '%s' "$out" | tail -1 | cut -c1-46)"
    [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out" | sed 's/^/       /'
  else
    FALLOS=$(( FALLOS + 1 ))
    printf '  FALLA %-32s %3ss  rc=%s\n' "$nom" "$dur" "$rc"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
  return 0
}

# Una sola suite, para tools/test-run-tests.sh:  tools/run-tests.sh --una <etiqueta> <comando...>
if [ "${1:-}" = "--una" ]; then
  shift; correr "$@"; exit $(( FALLOS > 0 ))
fi

echo "Higiene del repo"
correr "test-run-tests" bash tools/test-run-tests.sh
correr "check-ignored-tracked" bash tools/check-ignored-tracked.sh
# Que las comprobaciones editadas sigan sabiendo fallar. Un aserto que nunca se ha visto fallar no
# se ha visto funcionar, y en esta sesion tres afirmaron cubrir mas de lo que cubrian.
correr "mutation-check" bash tools/mutation-check.sh
# learning.update contra un parser CommonMark. Sin markdown-it-py la linea dice SKIP, no verde.
correr "oraculo-rewrite-rule" python3 tools/oraculo-rewrite-rule.py
# Banco de recall (F0 del plan de ciclo de vida de learnings): sabotajes y equivalencia de motores
# sobre un corpus sintetico; casos.jsonl real no se publica.
correr "recall-bench" bash tools/recall-bench/test-bench.sh

echo
echo "Suites del plugin"
# Orden estable: si dos corridas difieren, que no sea por el orden del glob.
for t in $(ls "$BIN"/test-*.sh | sort); do
  correr "$(basename "$t" .sh)" bash "$t"
done

echo
echo "------------------------------------------------------------"
if [ "$FALLOS" -eq 0 ] && { [ -n "$SALTADAS" ] || [ -n "$PARCIALES" ]; }; then
  echo "VERDE CON SALTOS — $TOTAL sin fallos${SALTADAS:+, sin correr:$SALTADAS}${PARCIALES:+, con casos saltados:$PARCIALES}"
elif [ "$FALLOS" -eq 0 ]; then
  echo "TODO VERDE — $TOTAL/$TOTAL"
else
  echo "HAY FALLOS — $FALLOS de $TOTAL"
fi
[ -n "$LENTAS" ] && echo "lentas (>=5s):$LENTAS"
echo "bash $BASH_VERSION en $(uname -s)"
exit $(( FALLOS > 0 ))
