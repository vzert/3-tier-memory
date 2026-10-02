#!/usr/bin/env bash
# Prueba de tools/run-tests.sh: una suite que muere a mitad sale FALLA aunque su rc sea 0.
#
# Caso real (p-46153b135b, 2026-10-01): test-checkpoint-close-guard.sh murio en la linea 1028 por un
# echo con ``` sin cerrar, sin imprimir pass=/fail=, y salio con rc=0: con `set -e` y un
# `trap 'rm -rf "$T"' EXIT`, bash 3.2 devuelve el rc del trap en vez del 2 del error de sintaxis.
# En bash 5 puede salir 2; el aserto pide FALLA en los dos casos. La suite "exit 0 a mitad" da rc=0
# en cualquier bash: es la que prueba la regla del resumen en todas las plataformas.
#
# sella-huellas: no (trabaja en un temporal propio)
set -u
RT="${RUN_TESTS:-$(cd "$(dirname "$0")" && pwd)/run-tests.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
# veredicto <suite>: la primera palabra de la linea que imprime run-tests.sh (ok / skip / FALLA)
veredicto() { bash "$RT" --una prueba bash "$1" 2>&1 | head -1 | awk '{print $1}'; }

# La forma real: set -e, trap EXIT y un echo con ``` sin cerrar a mitad.
cat > "$T/rota-sintaxis.sh" <<'EOF'
set -e
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
pass=1; fail=0
echo "  ok  uno"
echo "== el pendiente en una cita (> ```): lo reclama =="
echo "  ok  dos"
echo "pass=$pass fail=$fail"
EOF
cat > "$T/exit-a-mitad.sh" <<'EOF'
echo "  ok  uno"
exit 0
echo "pass=1 fail=0"
EOF
# Un resumen a mitad (el de una sub-prueba) no vale: cuenta el de la ULTIMA linea.
cat > "$T/resumen-a-mitad.sh" <<'EOF'
echo "pass=3 fail=0"
echo "  ok  cuatro"
exit 0
EOF

echo "== una suite que muere a mitad =="
chk "la del error de sintaxis con trap sale FALLA" "FALLA" "$(veredicto "$T/rota-sintaxis.sh")"
chk "la que sale con exit 0 a mitad sale FALLA" "FALLA" "$(veredicto "$T/exit-a-mitad.sh")"
chk "un resumen a mitad no la salva" "FALLA" "$(veredicto "$T/resumen-a-mitad.sh")"
chk "y lo dice: sin linea de resumen" "1" "$(bash "$RT" --una prueba bash "$T/exit-a-mitad.sh" 2>&1 | grep -c 'sin linea de resumen')"
chk "y el rc de run-tests.sh es 1" "1" "$(bash "$RT" --una prueba bash "$T/exit-a-mitad.sh" >/dev/null 2>&1; echo $?)"

echo "== las suites que terminan siguen en ok (un formato por familia) =="
n=0
while IFS= read -r ult; do
  n=$((n+1))
  printf 'echo "  ok  algo"\nprintf "%%s\\n" %q\n' "$ult" > "$T/buena$n.sh"
  chk "ok con «${ult}»" "ok" "$(veredicto "$T/buena$n.sh")"
done <<'EOF'
pass=162 fail=0
RESULT pass=48 fail=0
RESULT: pass=23 fail=0
RESULT: PASS
PASS=45 FAIL=0 SKIP=0
PASS 106/106
PASS test-research-row-lookup
TODO VERDE
TODO VERDE (enlaces reales: si)
test-bench: TODO VERDE
RESULTADO: 45 ok, 0 fallas
== resumen: 13 ok, 0 fallas ==
  ---- 26 ok, 0 fallo(s)
OK: ningun fichero trackeado esta excluido por .gitignore
LAS EVALUABLES DISCRIMINAN (de 57)
docs 1240, clases de fallo 0
EOF

echo "== una linea que solo EMPIEZA como un resumen, o con fallos, no vale (adversario, ronda 1) =="
while IFS= read -r ult; do
  n=$((n+1))
  printf 'echo "  ok  algo"\nprintf "%%s\\n" %q\n' "$ult" > "$T/floja$n.sh"
  chk "FALLA con «${ult}» y rc=0" "FALLA" "$(veredicto "$T/floja$n.sh")"
done <<'EOF'
RESULT: 
OK: algo
TODO VERDE de la seccion 3
pass=10 fail=0 extra
pass=3 fail=1
docs 1240, clases de fallo 2
EOF
printf 'printf "pass=1 fail=0\\r\\n"\n' > "$T/crlf.sh"
chk "ok con el resumen en CRLF (Windows)" "ok" "$(veredicto "$T/crlf.sh")"
printf 'echo "SKIP: sin la herramienta"\n' > "$T/skip.sh"
chk "un SKIP sigue siendo skip" "skip" "$(veredicto "$T/skip.sh")"
printf 'echo "pass=1 fail=1"\nexit 1\n' > "$T/roja.sh"
for ult in "RESULT pass=1 fail=0 skip=3" "RESULT: pass=1 fail=0 skip=10" "PASS=5 FAIL=0 SKIP=2"; do
  n=$((n+1)); printf 'printf "%%s\\n" %q\n' "$ult" > "$T/salto$n.sh"
  chk "un skip=N>0 es salto parcial: «${ult}»" "skip" "$(veredicto "$T/salto$n.sh")"
done
chk "una suite roja sigue siendo FALLA" "FALLA" "$(veredicto "$T/roja.sh")"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
