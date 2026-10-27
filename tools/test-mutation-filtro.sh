#!/usr/bin/env bash
# Prueba del filtro de tools/mutation-check.sh: como decide si un caso cayo, es vacuo o no se evalua aqui.
#
# Por que existe (p-984862c40d): caso() daba un caso por "no evaluable aqui" con cualquier linea SKIP del
# aserto, aunque la misma suite lo tumbara con FALLA: una mutacion que si cae no se contaba. caso_tools() lo
# arreglo en 2.63.6; esta prueba vigila las dos. Saca caso() y caso_tools() del mutation-check.sh real (o del
# que apunte MUTATION_CHECK, para las mutaciones) y las corre contra suites falsas en un temporal.
#
# sella-huellas: no (trabaja en un temporal propio)
set -u
MC="${MUTATION_CHECK:-$(cd "$(dirname "$0")" && pwd)/mutation-check.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

sed -n '/^caso() {/,/^}/p; /^caso_tools() {/,/^}/p; /^solo() {/,/^}/p' "$MC" > "$T/funciones.sh"
chk "mutation-check.sh tiene caso(), caso_tools() y solo()" "3" "$(grep -cE '^(caso(_tools)?|solo)\(\) \{' "$T/funciones.sh")"
mkdir -p "$T/src" "$T/tools" "$T/mut"
: > "$T/src/obj.sh"; : > "$T/tools/obj.sh"
# El mutador falso aplica siempre una sustitucion: lo que se mide es el filtro, no la mutacion.
printf 'import sys\nopen(sys.argv[1], "a").write("#\\n")\nprint("1 sust")\n' > "$T/mut/m.py"
# suite <nombre> <rc> <lineas...>: una suite falsa que imprime esas lineas y sale con ese rc.
suite() {
  local n="$1" rc="$2"; shift 2
  { for l in "$@"; do printf 'echo %q\n' "$l"; done; echo "exit $rc"; } > "$T/src/$n.sh"
  cp "$T/src/$n.sh" "$T/tools/$n.sh"
}
suite skip-solo   0 "  ok  otra cosa" "  SKIP aqui no aplica: el aserto X"
suite skip-falla  1 "  SKIP aqui no aplica: el aserto X" "  FALLA el aserto X: esperaba 1, salio 0"
suite falla-solo  1 "  FALLA el aserto X: esperaba 1, salio 0"
suite nada        0 "  ok  el aserto X"
suite skip-minus  0 "  ok  un skip=2 dentro del aserto X"
# veredicto <funcion> <suite>: la marca que imprime la funcion (--, ok, NO, ~~, ??).
veredicto() {
  ( cd "$T" && bash -c '. ./funciones.sh; mio() { return 0; }; SRC=src; MUT=mut; PEND=0; TOTAL=0
      if [ "$1" = caso ]; then caso et obj.sh m.py "$2.sh" "el aserto X"
      else caso_tools et obj.sh m.py "$2.sh" "el aserto X"; fi' _ "$1" "$2" 2>&1 ) | awk 'NF {print $1; exit}'
}
for f in caso caso_tools; do
  echo "== $f =="
  chk "$f: un SKIP del aserto, sin FALLA, no se evalua aqui" "--" "$(veredicto "$f" skip-solo)"
  chk "$f: SKIP y FALLA del mismo aserto: cae, el SKIP no tapa el FALLA" "ok" "$(veredicto "$f" skip-falla)"
  chk "$f: un FALLA del aserto cae" "ok" "$(veredicto "$f" falla-solo)"
  chk "$f: ni SKIP ni FALLA con rc 0: el aserto es vacuo" "NO" "$(veredicto "$f" nada)"
done
chk "caso_tools: un skip en minusculas dentro de otro aserto no es un SKIP" "NO" "$(veredicto caso_tools skip-minus)"

echo "== MUT_SOLO (p-3a58571ac9) =="
# La etiqueta de los casos de veredicto() es "et".
for f in caso caso_tools; do
  chk "MUT_SOLO: $f que casa corre" "ok" "$(MUT_SOLO='^et$' veredicto "$f" falla-solo)"
  chk "MUT_SOLO: un caso que no casa no corre ($f)" "" "$(MUT_SOLO='^otro$' veredicto "$f" falla-solo)"
done
chk "MUT_SOLO vacio: corre todo" "ok" "$(MUT_SOLO='' veredicto caso falla-solo)"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
