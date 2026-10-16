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

# p-5253bc2114: el resumen YA impreso y despues un error de sintaxis, con stderr fuera de la salida.
# En bash 3.2 sale rc=0 con el resumen como ultima linea (si stderr llega, el mensaje del error es la
# ultima y sin_resumen ya lo ve); solo el `bash -n` previo de run-tests.sh lo caza.
cat > "$T/rota-tras-resumen.sh" <<'EOF'
set -e
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
exec 2>/dev/null
echo "pass=1 fail=0"
echo "== cola (> ```): sin cerrar =="
EOF
echo "== un error de sintaxis DESPUES del resumen =="
chk "error de sintaxis tras el resumen sale FALLA" "FALLA" "$(veredicto "$T/rota-tras-resumen.sh")"
chk "y lo dice: bash -n" "1" "$(bash "$RT" --una prueba bash "$T/rota-tras-resumen.sh" 2>&1 | grep -c 'bash -n: error de sintaxis')"
chk "con el error de bash en la salida" "1" "$(bash "$RT" --una prueba bash "$T/rota-tras-resumen.sh" 2>&1 | grep -q 'rota-tras-resumen.sh: line' && echo 1)"
chk "y el rc de run-tests.sh es 1" "1" "$(bash "$RT" --una prueba bash "$T/rota-tras-resumen.sh" >/dev/null 2>&1; echo $?)"

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
echo "== un salto solo cuenta sobre un resumen verde (adversario, ronda 3) =="
for ult in "RESULT pass=1 fail=1 skip=2" "not-a-summary skip=2" "SKIP=2" "RESULTADO: 5 ok, 1 fallas, 2 saltados" "texto con 3 saltados" \
           "RESULTADO: 5 ok, 0 fallas, 2 saltados, 1 fallas" "TODO VERDE, 2 saltados y murio" \
           "RESULT pass=1 fail=0 skip=2, 3 saltados"; do
  n=$((n+1)); printf 'printf "%%s\\n" %q\n' "$ult" > "$T/noparcial$n.sh"
  chk "FALLA, no salto: «${ult}»" "FALLA" "$(veredicto "$T/noparcial$n.sh")"
done
printf 'echo "SKIP: sin la herramienta"\n' > "$T/skip.sh"
chk "un SKIP sigue siendo skip" "skip" "$(veredicto "$T/skip.sh")"
printf 'echo "pass=1 fail=1"\nexit 1\n' > "$T/roja.sh"
for ult in "RESULT pass=1 fail=0 skip=3" "RESULT: pass=1 fail=0 skip=10" "PASS=5 FAIL=0 SKIP=2" \
           "RESULTADO: 5 ok, 0 fallas, 2 saltados" "TODO VERDE, 2 saltados (sin enlaces reales)" \
           "pass=1 fail=0 skip=2" "RESULT pass=140 fail=0 skip=4"; do
  n=$((n+1)); printf 'printf "%%s\\n" %q\n' "$ult" > "$T/salto$n.sh"
  chk "un skip=N>0 es salto parcial: «${ult}»" "skip" "$(veredicto "$T/salto$n.sh")"
done
chk "una suite roja sigue siendo FALLA" "FALLA" "$(veredicto "$T/roja.sh")"

# p-524e2a5bf7: dos corridas completas a la vez dejaban al Mac sin memoria. Una COPIA de run-tests.sh
# en un repo minimo: su unica suite que corre (test-lenta) anota ini/fin en un registro; las demas
# no existen y fallan al instante. RUN_TESTS_CANDADO propio: el candado de la corrida que lanzo esta
# prueba no debe verse. Toda espera tiene tope: un candado roto no cuelga la prueba, sale FALLA.
echo "== candado: una corrida completa por maquina (p-524e2a5bf7) =="
R="$T/repo"; mkdir -p "$R/tools" "$R/plugins/3-tier-memory/bin" "$T/bin"
cp "$RT" "$R/tools/run-tests.sh"
printf 'echo ini >> "%s"; sleep 2; echo fin >> "%s"; echo "pass=1 fail=0"\n' "$T/registro" "$T/registro" \
  > "$R/plugins/3-tier-memory/bin/test-lenta.sh"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"   # sin el CLI real: no tarda
CAND="$T/candado"
# termina <pid> <segundos>: 0 si el proceso acaba a tiempo; si no, lo mata y devuelve 1.
termina() {
  local i=0
  while kill -0 "$1" 2>/dev/null; do
    [ "$i" -ge $(( $2 * 5 )) ] && { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; return 1; }
    sleep 0.2; i=$(( i + 1 ))
  done
  wait "$1" 2>/dev/null; return 0
}
completa() {  # <salida>: una corrida completa de la copia, en segundo plano; deja su pid en $!
  RUN_TESTS_CANDADO="$CAND" RUN_MUTATION=0 PATH="$T/bin:$PATH" bash "$R/tools/run-tests.sh" >"$1.out" 2>"$1.err" &
}
: > "$T/registro"
completa "$T/a"; a=$!
completa "$T/b"; b=$!
termina "$a" 60; ra=$?; termina "$b" 60; rb=$?
chk "las dos corridas terminan" "0 0" "$ra $rb"
chk "una tras otra: la suite de la segunda empieza al acabar la de la primera" "ini fin ini fin" \
  "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
chk "la que espero lo dice en stderr" "1" "$(cat "$T/a.err" "$T/b.err" | grep -c 'espero a que termine')"
chk "y suelta el candado al terminar" "no" "$([ -e "$CAND" ] && echo si || echo no)"

# Un candado de una corrida muerta (kill -9) no bloquea para siempre.
bash -c 'exit 0' & muerto=$!; wait "$muerto"
mkdir "$CAND"; echo "$muerto" > "$CAND/pid"; : > "$T/registro"
completa "$T/c"; c=$!
chk "con el candado de un pid muerto, la corrida no se queda esperando" "0" "$(termina "$c" 30; echo $?)"
chk "y corre su suite" "ini fin" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
chk "y avisa que lo quito" "1" "$(grep -c 'ya no existe' "$T/c.err")"

# Adversario, ronda 1: un candado abandonado que no se puede borrar (de otro usuario en un /tmp
# compartido) hacia un bucle sin pausa y sin fin. Ahora sale con error. Se simula con chmod 555,
# solo donde chmod de verdad impide borrar (no en Windows, ni como root).
mkdir "$T/sonda"; : > "$T/sonda/f"; chmod 555 "$T/sonda"
if rm -f "$T/sonda/f" 2>/dev/null; then
  echo "  (sin probar aqui: chmod 555 no impide borrar; no cuenta) candado que no se puede quitar"
else
  bash -c 'exit 0' & muerto=$!; wait "$muerto"
  mkdir "$CAND"; echo "$muerto" > "$CAND/pid"; chmod 555 "$CAND"
  completa "$T/d"; d=$!
  chk "un candado abandonado que no se puede quitar no deja un bucle sin fin" "0" "$(termina "$d" 15; echo $?)"
  chk "y sale con error que lo dice" "1" "$(grep -c 'no puedo quitar el candado' "$T/d.err")"
  chk "un solo aviso, no uno por vuelta" "1" "$(grep -c 'quito el candado' "$T/d.err")"
  chmod 755 "$CAND"; rm -rf "$CAND"
fi
chmod 755 "$T/sonda"
# Un pid vivo de otro usuario (kill -0 falla por permiso) no es un candado muerto: no se lo roba.
if [ "$( (export LC_ALL=C; kill -0 1) 2>&1 | grep -c ermitted)" = 1 ]; then
  mkdir "$CAND"; echo 1 > "$CAND/pid"
  completa "$T/e"; e=$!
  chk "el candado de un pid vivo de otro usuario se respeta: sigue esperando" "1" "$(termina "$e" 4; echo $?)"
  chk "y avisa que espera" "1" "$(grep -c 'espero a que termine' "$T/e.err")"
  rm -rf "$CAND"
else
  echo "  (sin probar aqui: kill -0 1 no falla por permiso; no cuenta) pid vivo de otro usuario"
fi

# --una lo llaman las suites DENTRO de una corrida completa: con el candado tomado no espera.
mkdir "$CAND"; echo "$$" > "$CAND/pid"
RUN_TESTS_CANDADO="$CAND" bash "$R/tools/run-tests.sh" --una prueba bash "$T/skip.sh" >/dev/null 2>&1 & u=$!
chk "--una no toma el candado: no espera a la corrida que lo tiene" "0" "$(termina "$u" 10; echo $?)"
rm -rf "$CAND"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
