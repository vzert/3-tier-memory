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
MC="${MUTATION_CHECK:-$(cd "$(dirname "$0")" && pwd)/mutation-check.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Candado propio para toda llamada a run-tests.sh de esta prueba. Dentro de una corrida completa el
# candado real lo tiene el runner que lanzo esta prueba: si un `--una` lo pidiera (la mutacion
# una-con-candado de mutation-check), esperaria sin fin. Colgo el CI del PR #35 cinco horas.
export RUN_TESTS_CANDADO="$T/candado-de-las-llamadas"
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
printf '[ -n "${QUIEN:-}" ] && echo "$QUIEN" >> "%s"; echo ini >> "%s"; sleep 1; echo fin >> "%s"; echo "pass=1 fail=0"\n' \
  "$T/orden" "$T/registro" "$T/registro" \
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
  wait "$1" 2>/dev/null; TERMINA_RC=$?; return 0   # rc del proceso, si es hijo de esta prueba
}
# completa <salida> [script]: una corrida completa de la copia (o de [script] de la copia, p. ej.
# mutation-check.sh), en segundo plano; deja su pid en LANZADO. MUTA=1 corre mutation-check dentro,
# TOPE pone RUN_TESTS_CANDADO_TOPE y DUENO el RUN_TESTS_CANDADO_DUENO heredado (vacio = ninguno).
# QUIEN lo anota la suite en $T/orden; PACIENCIA y AVISO son los de la cola y el aviso periodico.
# Desacoplada de esta prueba (doble fork, la adopta init). Medido: con las corridas como hijas de esta
# prueba, quitar la relectura del pid no tumbaba el caso de la carrera (0 de 3); desacopladas, 3 de 3.
# La causa no esta medida (no son zombis: bash recoge a sus hijas). `exec` conserva el pid anotado.
completa() {
  rm -f "$1.pid"
  ( RUN_TESTS_CANDADO="$CAND" RUN_TESTS_CANDADO_ESPERA=0.2 RUN_TESTS_CANDADO_PAUSA="${PAUSA:-}" RUN_MUTATION="${MUTA:-0}" \
      RUN_TESTS_CANDADO_TOPE="${TOPE:-}" RUN_TESTS_CANDADO_DUENO="${DUENO:-}" \
      QUIEN="${QUIEN:-}" RUN_TESTS_COLA_PACIENCIA="${PACIENCIA:-}" RUN_TESTS_CANDADO_AVISO="${AVISO:-}" \
      PATH="$T/bin:$PATH" bash -c 'echo $$ > "$0.pid"; exec bash "$1" >"$0.out" 2>"$0.err"' "$1" "$R/tools/${2:-run-tests.sh}" & )
  local i=0; while [ ! -s "$1.pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$(( i + 1 )); done
  LANZADO=$(cat "$1.pid" 2>/dev/null)
}
# Ocho a la vez, no dos (adversario, ronda 3): con un tercero en cola, el que espera veia morir al
# dueno justo al soltarlo y borraba el candado que otro acababa de tomar. Con dos no se ve.
: > "$T/registro"; pids=""
# PAUSA=0.5 ensancha la ventana entre leer el pid y decidir: sin el sub-candado, el choque sale.
PAUSA=0.5; for i in 1 2 3 4 5 6 7 8; do completa "$T/r$i"; pids="$pids $LANZADO"; done; PAUSA=
rcs=""; for p in $pids; do termina "$p" 120; rcs="$rcs$?"; done
chk "las ocho corridas terminan" "00000000" "$rcs"
chk "una tras otra: ninguna suite empieza antes de que acabe la anterior" \
  "ini fin ini fin ini fin ini fin ini fin ini fin ini fin ini fin" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
chk "las siete que esperaron lo dicen en stderr" "7" "$(cat "$T"/r?.err | grep -c 'espero a que termine')"
chk "ninguna quito el candado de otra por muerto" "0" "$(cat "$T"/r?.err | grep -c 'ya no existe')"
chk "y suelta el candado al terminar" "no" "$([ -e "$CAND" ] && echo si || echo no)"

# Un candado de una corrida muerta (kill -9) no bloquea para siempre.
bash -c 'exit 0' & muerto=$!; wait "$muerto"
mkdir "$CAND"; echo "$muerto" > "$CAND/pid"; : > "$T/registro"
completa "$T/c"; c=$LANZADO
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
  completa "$T/d"; d=$LANZADO
  chk "un candado abandonado que no se puede quitar no deja un bucle sin fin" "0" "$(termina "$d" 15; echo $?)"
  chk "y sale con error que lo dice" "1" "$(grep -c 'no puedo quitar el candado' "$T/d.err")"
  chk "un solo aviso, no uno por vuelta" "1" "$(grep -c 'quito el candado' "$T/d.err")"
  chmod 755 "$CAND"; rm -rf "$CAND"
fi
chmod 755 "$T/sonda"
# Un pid vivo de otro usuario (kill -0 falla por permiso) no es un candado muerto: no se lo roba.
if [ "$( (export LC_ALL=C; kill -0 1) 2>&1 | grep -c ermitted)" = 1 ]; then
  mkdir "$CAND"; echo 1 > "$CAND/pid"
  completa "$T/e"; e=$LANZADO
  chk "el candado de un pid vivo de otro usuario se respeta: sigue esperando" "1" "$(termina "$e" 4; echo $?)"
  chk "y avisa que espera" "1" "$(grep -c 'espero a que termine' "$T/e.err")"
  rm -rf "$CAND"
else
  echo "  (sin probar aqui: kill -0 1 no falla por permiso; no cuenta) pid vivo de otro usuario"
fi

# Un candado que no se puede crear (padre inexistente, /tmp de solo lectura) colgaba la corrida sin
# decir nada (adversario, ronda 4). Correr sin el dejaba dos suites a la vez (ronda 5): sale con rc 2.
: > "$T/registro"; CAND_BUENO="$CAND"; CAND="$T/no-existe/candado"
completa "$T/f"; f=$LANZADO; CAND="$CAND_BUENO"
chk "un candado que no se puede crear no cuelga la corrida" "0" "$(termina "$f" 30; echo $?)"
chk "y no corre la suite sin candado" "" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
chk "y dice como apuntarlo con RUN_TESTS_CANDADO" "1" "$(grep -c 'RUN_TESTS_CANDADO=<carpeta>' "$T/f.err")"
RUN_TESTS_CANDADO="$T/no-existe/candado" RUN_TESTS_CANDADO_ESPERA=0.1 bash "$R/tools/run-tests.sh" >/dev/null 2>&1 & h=$!
TERMINA_RC=; termina "$h" 30; chk "y sale con rc 2" "0 2" "$? $TERMINA_RC"

# Un pid 0 en el candado: kill -0 0 sale 0 y la corrida esperaba sin fin (adversario, ronda 5).
mkdir "$CAND"; echo 0 > "$CAND/pid"; : > "$T/registro"
completa "$T/g"; g=$LANZADO
chk "un candado con pid 0 cuenta como abandonado: no espera sin fin" "0" "$(termina "$g" 30; echo $?)"
chk "y corre su suite" "ini fin" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
rm -rf "$CAND"

# p-7c1fa85c1e: el pid de una corrida muerta lo reusa otro proceso vivo. El candado guarda la hora de
# arranque de su dueno (`arranque`); si el pid vive con otra hora, no es el dueno: se quita. Sin hora
# guardada (candado de antes de 2.63.6) se espera como siempre. Solo donde run-tests sabe leer la
# hora (`--hora-candado`, la misma funcion con que la escribe).
sleep 60 & reusado=$!
hora=$(bash "$R/tools/run-tests.sh" --hora-candado "$reusado")
if [ -n "$hora" ]; then
  mkdir "$CAND"; echo "$reusado" > "$CAND/pid"; echo "Thu Jan  1 00:00:00 1970" > "$CAND/arranque"
  : > "$T/registro"; TOPE=10; completa "$T/h"; h=$LANZADO; TOPE=
  chk "un pid reusado por otro proceso vivo (otra hora de arranque) no hace esperar sin fin" "0" "$(termina "$h" 30; echo $?)"
  chk "con el pid reusado, quita el candado y corre su suite" "ini fin" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
  chk "con el pid reusado, no se agota esperando y avisa que lo quita" "0 1" \
    "$(grep -c 'RUN_TESTS_CANDADO_TOPE' "$T/h.err") $(grep -c 'otro proceso reuso su pid' "$T/h.err")"
  rm -rf "$CAND"
  mkdir "$CAND"; echo "$reusado" > "$CAND/pid"; echo "$hora" > "$CAND/arranque"; : > "$T/registro"
  completa "$T/i"; i=$LANZADO
  chk "un pid vivo con su misma hora de arranque es el dueno: espera" "1" "$(termina "$i" 4; echo $?)"
  chk "y no corre su suite con el dueno vivo" "" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
  rm -rf "$CAND"
  # La corrida que toma el candado guarda su propia hora: sin eso, lo de arriba no se activa nunca.
  : > "$T/registro"; completa "$T/j"; j=$LANZADO
  n=0; while [ ! -s "$T/registro" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$(( n + 1 )); done
  chk "la corrida que toma el candado guarda su hora de arranque" "$(bash "$R/tools/run-tests.sh" --hora-candado "$j")" \
    "$(cat "$CAND/arranque" 2>/dev/null)"
  termina "$j" 30 >/dev/null
  # Quien escribe y quien lee pueden tener otro TZ: con `lstart` en hora local, un lector con otro TZ
  # veia otra hora y robaba el candado de un dueno vivo (adversario, ronda 1).
  mkdir "$CAND"; echo "$reusado" > "$CAND/pid"; : > "$T/registro"
  TZ=Pacific/Kiritimati bash "$R/tools/run-tests.sh" --hora-candado "$reusado" > "$CAND/arranque"
  completa "$T/z"; z=$LANZADO
  chk "un lector con otro TZ que el dueno no le roba el candado: espera" "1" "$(termina "$z" 4; echo $?)"
  [ "$(uname -s)" = Linux ] && [ -r "/proc/$reusado/stat" ] && echo "  SKIP aqui la hora sale de /proc, que no depende del TZ: un lector con otro TZ que el dueno no le roba el candado"
  rm -rf "$CAND"
else
  echo "  (sin probar aqui: run-tests no sabe leer la hora de arranque; no cuenta) pid reusado"
fi
# Git Bash no lee la hora: su /proc se mueve si cambia el reloj, y robaria un candado vivo
# (adversario, ronda 2). Este aserto solo corre ahi; si alguien quita la guarda de Linux, cae.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*)
  chk "en Git Bash la hora de arranque sale vacia: se espera como antes" "" "$hora" ;;
esac
mkdir "$CAND"; echo "$reusado" > "$CAND/pid"; : > "$T/registro"
completa "$T/k"; k=$LANZADO
chk "un candado sin hora de arranque (de antes de 2.63.6) con su pid vivo: espera" "1" "$(termina "$k" 4; echo $?)"
rm -rf "$CAND"
kill "$reusado" 2>/dev/null; wait "$reusado" 2>/dev/null

# Ruta fija, no del TMPDIR: procesos de la misma maquina con otro TMPDIR no compartian el candado.
chk "el candado no depende de TMPDIR" "/tmp/3tm-run-tests.candado" \
  "$(env -u RUN_TESTS_CANDADO TMPDIR="$T/otro" bash "$R/tools/run-tests.sh" --ruta-candado)"

# --una lo llaman las suites DENTRO de una corrida completa: con el candado tomado no espera.
mkdir "$CAND"; echo "$$" > "$CAND/pid"
RUN_TESTS_CANDADO="$CAND" bash "$R/tools/run-tests.sh" --una prueba bash "$T/skip.sh" >/dev/null 2>&1 & u=$!
chk "--una no toma el candado: no espera a la corrida que lo tiene" "0" "$(termina "$u" 10; echo $?)"
rm -rf "$CAND"

# Cola de turnos (2026-10-28): al soltar, ganaba quien despertara primero. Medido: una corrida espero
# 4 h 42 min y perdio ante otra que llego 59 min despues. El dueno de estas pruebas es un sleep con
# su hora de arranque: vive todo lo que haga falta y no corre nada.
echo "== candado: cola de turnos por orden de llegada =="
# duenofalso <pid>: deja el candado con ese pid y su hora, como lo deja una corrida que lo tomo.
duenofalso() { mkdir -p "$CAND"; bash "$R/tools/run-tests.sh" --hora-candado "$1" > "$CAND/arranque"; echo "$1" > "$CAND/pid"; }
# turnos: cuantos turnos hay en la cola. espera_turnos <n>: hasta que haya n (tope 10 s).
turnos() { ls "$CAND.cola" 2>/dev/null | wc -l | tr -d ' '; }
espera_turnos() { local i=0; while [ "$(turnos)" -lt "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$(( i + 1 )); done; }
# turno <pid> <segundos>: la ruta del turno que sacaria ese pid a esa hora (epoch).
turno() { printf '%s/%010d-%010d' "$CAND.cola" "$2" "$1"; }
# Seis que llegan una por segundo con el candado tomado; el dueno suelta cuando la sexta ya tiene
# turno. Sin cola gana la que despierta primero: el orden sale al azar (1 en 720).
sleep 120 & dueno1=$!; duenofalso "$dueno1"
: > "$T/registro"; : > "$T/orden"; pids=""
for i in 1 2 3 4 5 6; do QUIEN=w$i completa "$T/w$i"; pids="$pids $LANZADO"; espera_turnos "$i"; sleep 1.1; done
chk "seis que esperan sacan cada una su turno" "6" "$(turnos)"
rm -rf "$CAND"
rcs=""; for p in $pids; do termina "$p" 120; rcs="$rcs$?"; done
chk "las seis de la cola terminan" "000000" "$rcs"
chk "seis que esperan entran en orden de llegada" "w1 w2 w3 w4 w5 w6" "$(tr '\n' ' ' < "$T/orden" | sed 's/ $//')"
chk "la cola tambien deja una tras otra" "ini fin ini fin ini fin ini fin ini fin ini fin" \
  "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
chk "ninguna de la cola dice que perdio el turno" "0" "$(cat "$T"/w?.err | grep -c 'perdi el turno')"
chk "y la cola queda vacia" "0" "$(turnos)"
kill "$dueno1" 2>/dev/null; wait "$dueno1" 2>/dev/null

# Quien toma el candado saca su turno de la cola: la cola es solo de quienes esperan.
: > "$T/registro"; completa "$T/a"; a=$LANZADO
i=0; while ! grep -q ini "$T/registro" && [ "$i" -lt 100 ]; do sleep 0.1; i=$(( i + 1 )); done
chk "el turno sale de la cola al tomar el candado" "0" "$(turnos)"
termina "$a" 30 >/dev/null

# El turno de una corrida muerta (kill -9 en la cola) no frena a las de detras.
bash -c 'exit 0' & muerto=$!; wait "$muerto"
mkdir -p "$(turno "$muerto" 1)"; : > "$T/registro"
PACIENCIA=1000; completa "$T/x"; x=$LANZADO; PACIENCIA=
chk "el turno de una corrida muerta no frena la cola" "0" "$(termina "$x" 20; echo $?)"
chk "y su turno se borra" "no" "$([ -e "$(turno "$muerto" 1)" ] && echo si || echo no)"

# Un turno vivo delante, pero parado (Ctrl-Z): tras PACIENCIA vueltas con el candado libre, prueba el
# siguiente. Y no le borra el turno: sigue vivo y con su hora.
sleep 60 & parado=$!; tp=$(turno "$parado" 2)
mkdir -p "$tp"; bash "$R/tools/run-tests.sh" --hora-candado "$parado" > "$tp/arranque"; : > "$T/registro"
PACIENCIA=5; completa "$T/y"; y=$LANZADO; PACIENCIA=
chk "un turno vivo que no toma el candado libre no frena la cola para siempre" "0" "$(termina "$y" 20; echo $?)"
chk "y dice que prueba en su lugar" "1" "$(grep -c 'no toma el candado libre' "$T/y.err")"
chk "un turno vivo con su hora no se borra" "si" "$([ -d "$tp" ] && echo si || echo no)"

# Aviso: con ese turno parado delante (PACIENCIA alta: nunca prueba), el candado pasa de un dueno a
# otro que no tenia turno, como una corrida de antes de la cola que se cuela. Quien espera lo dice, y
# cada AVISO segundos dice cuanto lleva.
sleep 60 & dueno2=$!; sleep 60 & dueno3=$!; duenofalso "$dueno2"
PACIENCIA=100000; AVISO=1; completa "$T/p"; pz=$LANZADO; PACIENCIA=; AVISO=
i=0; while ! grep -q 'espero a que termine' "$T/p.err" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$(( i + 1 )); done
rm -rf "$CAND"; duenofalso "$dueno3"; sleep 3.5
kill "$pz" 2>/dev/null; termina "$pz" 10 >/dev/null
chk "quien espera dice que perdio el turno ante una que no tenia turno" "1" \
  "$(grep -c "perdi el turno: la corrida pid $dueno3 " "$T/p.err")"
chk "y cada AVISO segundos dice cuanto lleva esperando" "si" \
  "$([ "$(grep -c 'min esperando el candado; lo tiene pid' "$T/p.err")" -ge 2 ] && echo si || echo no)"
# La mataron en la cola (TERM): su turno sale y no frena a las de detras. Queda solo el del parado.
chk "matar a quien espera en la cola saca su turno" "1" "$(turnos)"
kill "$dueno2" "$dueno3" "$parado" 2>/dev/null; wait "$dueno2" "$dueno3" "$parado" 2>/dev/null
rm -rf "$CAND" "$CAND.cola"

# Un turno con su pid reusado por otro proceso vivo (otra hora de arranque) no es de quien lo saco.
sleep 60 & otro=$!
if [ -n "$(bash "$R/tools/run-tests.sh" --hora-candado "$otro")" ]; then
  tr_=$(turno "$otro" 3); mkdir -p "$tr_"; echo "otra hora" > "$tr_/arranque"; : > "$T/registro"
  PACIENCIA=1000; completa "$T/r"; rr=$LANZADO; PACIENCIA=
  chk "un turno con el pid reusado no frena la cola" "0" "$(termina "$rr" 20; echo $?)"
  chk "y se borra" "no" "$([ -e "$tr_" ] && echo si || echo no)"
else
  echo "  SKIP aqui no se lee la hora de arranque: un turno con el pid reusado no frena la cola"
fi
kill "$otro" 2>/dev/null; wait "$otro" 2>/dev/null

# Sin poder sacar turno (la cola es un archivo), espera como antes, sin orden, y lo dice.
rm -rf "$CAND.cola"; : > "$CAND.cola"; : > "$T/registro"
completa "$T/z"; zz=$LANZADO
chk "sin poder sacar turno, la corrida no se cuelga" "0" "$(termina "$zz" 20; echo $?)"
chk "y corre su suite sin turno" "ini fin" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
chk "y avisa que no tiene turno" "1" "$(grep -c 'no puedo sacar turno' "$T/z.err")"
rm -f "$CAND.cola"

# p-4be2b6ea23: mutation-check.sh lanzado solo toma el mismo candado. Su copia es el mutation-check
# real hasta la marca del candado, y despues un cuerpo que anota mc-ini/mc-fin en el registro (los
# 236 casos de verdad tardan minutos). Todo lo que pueda esperar va con tope (TOPE): una copia rota
# que espera a la corrida que la lanzo no se muere con kill, porque bash espera a su hijo.
echo "== candado: mutation-check.sh lanzado solo (p-4be2b6ea23) =="
sed -n '1,/^# --- hasta aqui el candado/p' "$MC" > "$R/tools/mutation-check.sh"
printf 'echo mc-ini >> "%s"; sleep 1; echo mc-fin >> "%s"; echo "LAS EVALUABLES DISCRIMINAN (de 1)"\n' \
  "$T/registro" "$T/registro" >> "$R/tools/mutation-check.sh"
chk "mutation-check.sh tiene la marca donde se corta su copia" "1" "$(grep -c '^# --- hasta aqui el candado' "$MC")"
chk "la copia lleva el candado de mutation-check" "1" "$(grep -c '^  exec bash tools/run-tests.sh --con-candado' "$R/tools/mutation-check.sh")"
# Tres sueltos y una completa a la vez, no dos (regla: con dos no se ve la carrera de la liberacion).
: > "$T/registro"; pids=""; TOPE=40
for i in 1 2 3; do completa "$T/m$i" mutation-check.sh; pids="$pids $LANZADO"; done
completa "$T/mr"; pids="$pids $LANZADO"; TOPE=
rcs=""; for p in $pids; do termina "$p" 90; rcs="$rcs$?"; done
chk "tres mutation-check sueltos y una corrida completa a la vez terminan" "0000" "$rcs"
chk "tres mutation-check sueltos y una corrida completa: una tras otra" \
  "ini fin ini fin ini fin ini fin" "$(sed 's/^mc-//' "$T/registro" | tr '\n' ' ' | sed 's/ $//')"
chk "los tres mutation-check corren su cuerpo, no la suite completa" "3" "$(grep -c '^mc-ini$' "$T/registro")"
chk "los tres que esperaron lo dicen en stderr" "3" "$(cat "$T"/m[123].err "$T/mr.err" | grep -c 'espero a que termine')"
chk "y sueltan el candado" "no" "$([ -e "$CAND" ] && echo si || echo no)"

# Dentro de una corrida completa, mutation-check no pide el candado que ya tiene su runner.
: > "$T/registro"; MUTA=1; TOPE=10; completa "$T/n"; n=$LANZADO; MUTA=; TOPE=
chk "dentro de una corrida completa no se espera a si mismo: termina" "0" "$(termina "$n" 40; echo $?)"
chk "dentro de una corrida completa no se espera a si mismo: mutation-check sale ok" "1" \
  "$(grep -c '^  ok   mutation-check' "$T/n.out")"
chk "y corre las dos, una tras otra" "mc-ini mc-fin ini fin" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"

# Un RUN_TESTS_CANDADO_DUENO heredado que no es el pid del candado no lo salta: espera.
mkdir "$CAND"; echo "$$" > "$CAND/pid"; : > "$T/registro"
DUENO=1; completa "$T/o" mutation-check.sh; o=$LANZADO; DUENO=
chk "una variable heredada que no casa con el candado no lo salta: espera" "1" "$(termina "$o" 4; echo $?)"
chk "y no corre su cuerpo" "" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
rm -rf "$CAND"

# Un candado abandonado con el pid de una corrida muerta, y ese mismo pid heredado: no es de nadie.
bash -c 'exit 0' & muerto=$!; wait "$muerto"
mkdir "$CAND"; echo "$muerto" > "$CAND/pid"; : > "$T/registro"
DUENO=$muerto; completa "$T/q" mutation-check.sh; q=$LANZADO; DUENO=
chk "un dueno heredado que ya murio no vale: toma el candado" "0" "$(termina "$q" 30; echo $?)"
chk "un dueno heredado que ya murio no vale: quita el abandonado y corre" "1 mc-ini mc-fin" \
  "$(grep -c 'ya no existe' "$T/q.err") $(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"

# Un candado con el pid de un proceso vivo ajeno, y ese pid en la variable: no es un antecesor de
# mutation-check, asi que espera en vez de saltarse el candado (adversario externo, ronda 2).
sleep 60 & ajeno=$!
mkdir "$CAND"; echo "$ajeno" > "$CAND/pid"; : > "$T/registro"
DUENO=$ajeno; completa "$T/v" mutation-check.sh; v=$LANZADO; DUENO=
chk "un candado falsificado con un pid vivo ajeno como dueno no lo salta: espera" "1" "$(termina "$v" 4; echo $?)"
chk "y no corre su cuerpo con el falsificado" "" "$(tr '\n' ' ' < "$T/registro" | sed 's/ $//')"
kill "$ajeno" 2>/dev/null; wait "$ajeno" 2>/dev/null; rm -rf "$CAND"

# Relanzado una vez y sin ver aun el candado: sale con error, no se relanza sin fin. Se simula con
# MUT_RELANZADO igual al pid de esta prueba, que es su padre.
: > "$T/registro"
( cd "$T" && MUT_RELANZADO=$$ RUN_TESTS_CANDADO="$CAND" RUN_TESTS_CANDADO_DUENO= RUN_TESTS_CANDADO_TOPE=10 \
    exec bash "$R/tools/mutation-check.sh" >"$T/s.out" 2>"$T/s.err" ) & s=$!
TERMINA_RC=; termina "$s" 20
chk "un relanzado que no ve el candado no se relanza sin fin: sale con rc 2" "0 2" "$? $TERMINA_RC"
chk "y lo dice" "1" "$(grep -c 'no me relanzo otra vez' "$T/s.err")"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
