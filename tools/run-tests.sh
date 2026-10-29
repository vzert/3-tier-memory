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
# 2.57.0: journal-emit liga un pendiente nuevo al paso del snippet con el que arranco la sesion de
# Claude Code donde corre. Las suites no son esa sesion: sin esto, correr el runner desde Claude Code
# dependeria de como arranco la sesion de quien lo corre.
unset CLAUDE_CODE_SESSION_ID
# Una corrida completa por maquina (p-524e2a5bf7). Varios agentes que esperaban a las suites ajenas
# lanzaban la suite completa a la vez al terminar, y el Mac se quedaba sin memoria (2026-10-15/16).
# El candado es una carpeta: `mkdir` es atomico en macOS, Linux y Git Bash, sin flock (macOS no lo
# trae). La siguiente corrida espera a la que lo tiene y lo dice en stderr. Ruta fija en /tmp, no en
# TMPDIR: hay procesos de la misma maquina con su propio TMPDIR, y no compartian el candado
# (adversario, ronda 3). `--una` no lo toma: la llaman las suites desde dentro de una corrida completa.
# RUN_TESTS_CANDADO cambia la ruta (lo usa test-run-tests.sh para no esperar a la corrida que lo lanzo).
# `--con-candado <comando...>` corre ese comando con el candado tomado: asi lo toma mutation-check.sh
# lanzado solo (p-4be2b6ea23). Quien lo tiene exporta RUN_TESTS_CANDADO_DUENO con su pid, y
# mutation-check no lo pide si ese pid es el del candado y un antecesor suyo: dentro de una corrida se
# esperaria a si mismo.
CANDADO="${RUN_TESTS_CANDADO:-/tmp/3tm-run-tests.candado}"
[ "${1:-}" = "--ruta-candado" ] && { echo "$CANDADO"; exit 0; }   # para test-run-tests.sh
# Quita un candado abandonado. Si no puede (de otro usuario en un /tmp compartido), sale con error:
# reintentar sin fin era un bucle sin pausa (adversario, ronda 1: 507 avisos en 3 s).
candado_quita() {
  rm -rf "$CANDADO" 2>/dev/null
  [ -e "$CANDADO" ] || return 0
  echo "ERROR run-tests: no puedo quitar el candado abandonado $CANDADO ($1). Borralo a mano o usa otro RUN_TESTS_CANDADO." >&2
  exit 2
}
# Vivo: kill -0 sale 0, o falla por permiso (un proceso de otro usuario existe; adversario, ronda 1:
# con pid=1 lo daba por muerto y robaba el candado). Muerto: "No such process". LC_ALL=C exportado
# en la subshell: en glibc el mensaje se traduce ("Operacion no permitida"; adversario, ronda 2).
candado_vivo() {
  local err
  # Un pid vacio, no numerico o 0 no es de nadie: `kill -0 0` sale 0 (senala al propio grupo) y
  # dejaba esperando sin fin (adversario, ronda 5). Solo sale de un archivo roto o hecho a mano.
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ] 2>/dev/null || return 1
  err=$(export LC_ALL=C; kill -0 "$1" 2>&1) && return 0
  case "$err" in *ermitted*) return 0 ;; esac
  return 1
}
# Hora de arranque del pid $1, o nada si no se puede saber. Tiene que salir igual para quien la
# escribe y para quien la lee, sea cual sea su entorno: un lector con otro TZ leia otra `lstart` y
# robaba un candado vivo, dos suites a la vez (adversario, ronda 1). En Linux: el campo 22 de
# /proc/<pid>/stat, tics desde el arranque de la maquina, que no dependen del TZ ni de un salto del
# reloj (la `lstart` de procps si). En macOS: `ps -o lstart=` con TZ=UTC0 y LC_ALL=C (el dia y el mes
# se traducen). El comm del campo 2 puede llevar espacios y parentesis: se corta hasta el ultimo ") ".
# Git Bash no: su /proc/<pid>/stat resta la hora de arranque de Windows a la de creacion, y las dos
# se mueven si alguien cambia el reloj (msys2 process.cc; adversario, ronda 2). Ahi sale vacio (su
# `ps` no tiene -o): se espera como antes, el lado seguro.
candado_hora() {
  if [ "$(uname -s)" = Linux ] && [ -r "/proc/$1/stat" ]; then
    sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '$20 != "" {print "tics " $20}'
  else
    TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^  *//; s/  *$//'
  fi
}
[ "${1:-}" = "--hora-candado" ] && { candado_hora "${2:-}"; exit 0; }   # para test-run-tests.sh
# El pid $1 vive, pero no es el dueno: el candado guardo otra hora de arranque (p-7c1fa85c1e). La
# corrida duena murio (kill -9) y otro proceso reuso su pid; sin esto se esperaba sin fin. Sin hora
# guardada (un candado de antes de 2.63.6) o sin poder leer la de ahora, no se sabe: vivo, como antes.
candado_reusado() {
  local guardada ahora
  guardada=$(cat "$CANDADO/arranque" 2>/dev/null)
  [ -n "$guardada" ] || return 1
  ahora=$(candado_hora "$1")
  [ -n "$ahora" ] && [ "$ahora" != "$guardada" ]
}
# El candado que se vio con el pid $1 parece abandonado. Entre leer ese pid y decidir, su dueno pudo
# soltarlo y otra corrida tomar uno nuevo en la misma ruta: borrarlo a ciegas dejaba dos suites a la
# vez en cada liberacion con tres o mas en cola (adversario, ronda 3). Asi que se borra solo bajo un
# sub-candado (`quitando`, que serializa a quienes quitan) y si el pid sigue siendo el que se vio.
# Un `quitando` huerfano (quien quitaba murio a mitad) se fuerza tras 10 vueltas con el mismo pid.
candado_abandonado() {  # <pid visto, vacio si no habia> <motivo>
  if ! mkdir "$CANDADO/quitando" 2>/dev/null; then
    [ -d "$CANDADO" ] || return 0
    atascado=$(( atascado + 1 ))
    if [ "$atascado" -ge 10 ] && [ "$(cat "$CANDADO/pid" 2>/dev/null)" = "$1" ]; then
      echo "AVISO run-tests: quito el candado abandonado ($2; su sub-candado lleva 10 vueltas sin soltarse): $CANDADO" >&2
      candado_quita "$2"; atascado=0
    fi
    return 0
  fi
  atascado=0
  if [ "$(cat "$CANDADO/pid" 2>/dev/null)" != "$1" ]; then
    rmdir "$CANDADO/quitando" 2>/dev/null; return 0   # ya es otro candado: no se toca
  fi
  # Mismo pid, pero tiene que seguir sin dueno: vivo y con su hora, ya no se quita (p-7c1fa85c1e).
  if [ -n "$1" ] && candado_vivo "$1" && ! candado_reusado "$1"; then
    rmdir "$CANDADO/quitando" 2>/dev/null; return 0
  fi
  echo "AVISO run-tests: quito el candado de una corrida que ya no existe ($2): $CANDADO" >&2
  candado_quita "$2"
}
# Cola de turnos por orden de llegada (2026-10-28). Con solo el `mkdir`, al soltar el candado ganaba
# la corrida que despertara primero: medido, una espero 4 h 42 min y perdio ante otra que habia
# llegado 59 min despues, y una corrida completa dura horas. Cada corrida que espera saca un turno:
# una carpeta `<segundos>-<pid>`, 10 digitos cada uno, asi el orden de los nombres es el de llegada. Va
# en $CANDADO.cola, al lado del candado y no dentro: el candado se borra entero al soltarlo. Solo
# prueba el `mkdir` quien no tiene delante un turno vivo. El candado sigue siendo lo que deja una
# corrida a la vez; la cola solo ordena. Limites: una corrida de antes de este cambio (un worktree
# viejo) no saca turno y se puede colar; dos que llegan en el mismo segundo van por pid; un salto del
# reloj puede desordenar turnos. Si no se puede sacar turno, espera como antes, sin orden.
COLA="$CANDADO.cola"
TURNO=""
candado_turno_saca() {
  TURNO="$COLA/$(printf '%010d-%010d' "$(date +%s)" "$$")"
  # Sin -p: crear la carpeta madre del candado lo haria creable donde no debe (padre inexistente).
  if { [ -d "$COLA" ] || mkdir "$COLA" 2>/dev/null; } && mkdir "$TURNO" 2>/dev/null; then
    # Como en el candado: la hora de arranque dice si el pid de un turno es aun quien lo saco.
    candado_hora "$$" > "$TURNO/arranque" 2>/dev/null
    return 0
  fi
  TURNO=""
  echo "AVISO run-tests: no puedo sacar turno en $COLA; espero sin orden de llegada." >&2
}
# El pid $2 del turno $1 vive, pero no es quien lo saco: otra hora de arranque. Sin hora guardada
# (aun no la escribe) o sin poder leer la de ahora (Git Bash), no se sabe: es suyo, el lado seguro.
turno_reusado() {
  local antes ahora_t
  antes=$(cat "$1/arranque" 2>/dev/null)
  [ -n "$antes" ] || return 1
  ahora_t=$(candado_hora "$2")
  [ -n "$ahora_t" ] && [ "$ahora_t" != "$antes" ]
}
# Imprime los pids con turno vivo delante del suyo, el primero primero, cada uno seguido de un
# espacio; nada si no tiene a nadie delante o no tiene turno. Borra los turnos muertos (kill -9
# mientras esperaba) o con el pid reusado: si no, frenaban la cola para siempre.
candado_delante() {
  local t n pid
  [ -n "$TURNO" ] || return 0
  [ -d "$TURNO" ] || mkdir "$TURNO" 2>/dev/null   # si alguien lo borro, vuelve con su misma llegada
  for t in "$COLA"/*; do
    [ "$t" = "$TURNO" ] && return 0
    [ -d "$t" ] || continue
    n=${t##*-}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    pid=$(( 10#$n ))
    if ! candado_vivo "$pid" || turno_reusado "$t" "$pid"; then rm -rf "$t" 2>/dev/null; continue; fi
    printf '%s ' "$pid"
  done
}
candado_toma() {
  local quien vacio=0 avisado=0 atascado=0 nocrea=0 ini delante libre=0 saltados=" " dueno="" vistos=" " ultimo p
  local pac=${RUN_TESTS_COLA_PACIENCIA:-30} quedan i
  [ "$pac" -ge 1 ] 2>/dev/null || pac=30
  ini=$(date +%s); ultimo=$ini
  candado_turno_saca
  while :; do
    delante=$(candado_delante)
    # Los pids que alguna vez tuvo delante, cada uno una vez: en horas de espera no crece por vuelta.
    for p in $delante; do case "$vistos" in *" $p "*) ;; *) vistos="$vistos$p " ;; esac; done
    # El primero de la cola no toma un candado libre: vive, pero esta parado (Ctrl-Z, SIGSTOP). Cada
    # RUN_TESTS_COLA_PACIENCIA vueltas seguidas (30) con el candado libre se salta UN turno mas, el
    # primero: asi lo toma el siguiente de la cola y los de detras siguen en su orden. Saltar a todos
    # los de delante de una vez los ponia a sortear otra vez (adversario, ronda 1: «D C» 6 de 6).
    if [ -n "$delante" ] && [ ! -d "$CANDADO" ]; then libre=$(( libre + 1 )); else libre=0; fi
    if [ -n "$delante" ] && [ "$libre" -ge "$pac" ]; then
      quedan=""; i=0
      for p in $delante; do
        i=$(( i + 1 ))
        if [ "$i" -le $(( libre / pac )) ]; then
          case "$saltados" in
            *" $p "*) ;;
            *) saltados="$saltados$p "
               echo "AVISO run-tests: el turno de pid $p no toma el candado libre tras $libre vueltas; lo salto." >&2 ;;
          esac
        else
          quedan="$quedan$p "
        fi
      done
      delante=$quedan
    fi
    if [ -z "$delante" ] && mkdir "$CANDADO" 2>/dev/null; then
      # La hora de arranque va ANTES que el pid: quien lee el pid ya la encuentra (p-7c1fa85c1e).
      candado_hora "$$" > "$CANDADO/arranque" 2>/dev/null
      # Si se lo quitaron entre el mkdir y escribir el pid, no es suyo: vuelve a la cola.
      echo "$$" > "$CANDADO/pid" 2>/dev/null && [ "$(cat "$CANDADO/pid" 2>/dev/null)" = "$$" ] && break
    fi
    # Libre, pero el turno es de otra corrida que llego antes: la deja tomarlo.
    if [ ! -d "$CANDADO" ] && [ -n "$delante" ]; then
      sleep "${RUN_TESTS_CANDADO_ESPERA:-1}"; continue
    fi
    # mkdir fallo y la carpeta no existe: no es que otra corrida la tenga, es que no se puede crear
    # (/tmp de solo lectura en un sandbox, padre inexistente). Esperar ahi era colgarse sin decir nada
    # (adversario, ronda 4). Una vez puede ser el hueco entre que una suelta y otra toma; tres
    # seguidas, no. Y correr sin candado dejaba dos suites a la vez (ronda 5, unsafe): sale con rc 2
    # y dice como apuntar el candado a otra carpeta (Victor, d64).
    if [ ! -d "$CANDADO" ]; then
      nocrea=$(( nocrea + 1 ))
      if [ "$nocrea" -ge 3 ]; then
        echo "ERROR run-tests: no puedo crear el candado $CANDADO, y sin el otra corrida completa podria ir a la vez." >&2
        echo "  Apuntalo a una carpeta donde si se pueda escribir: RUN_TESTS_CANDADO=<carpeta>/3tm-run-tests.candado bash tools/run-tests.sh" >&2
        exit 2
      fi
      sleep "${RUN_TESTS_CANDADO_ESPERA:-1}"; continue
    fi
    nocrea=0
    quien=$(cat "$CANDADO/pid" 2>/dev/null)
    # Solo pruebas: ensancha la ventana entre leer el pid y decidir (test-run-tests.sh, ronda 3).
    [ -n "${RUN_TESTS_CANDADO_PAUSA:-}" ] && sleep "$RUN_TESTS_CANDADO_PAUSA"
    if [ -z "$quien" ]; then
      # Recien creado: su dueno aun no escribe el pid. Vacio 10 vueltas = murio entre mkdir y escribirlo.
      vacio=$(( vacio + 1 ))
      if [ "$vacio" -ge 10 ]; then candado_abandonado "" "sin pid tras 10 vueltas"; vacio=0; fi
    elif ! candado_vivo "$quien"; then
      vacio=0; candado_abandonado "$quien" "pid $quien"
    elif candado_reusado "$quien"; then
      vacio=0; candado_abandonado "$quien" "otro proceso reuso su pid $quien"
    else
      vacio=0
      # Solo pruebas: una espera con tope. Una copia rota que espera sin fin a la corrida que la lanzo
      # la cuelga entera, y matarla no basta: bash espera a su hijo antes de morir (medido, 2.63.1).
      if [ -n "${RUN_TESTS_CANDADO_TOPE:-}" ] && [ $(( $(date +%s) - ini )) -ge "$RUN_TESTS_CANDADO_TOPE" ]; then
        echo "ERROR run-tests: RUN_TESTS_CANDADO_TOPE=$RUN_TESTS_CANDADO_TOPE s esperando el candado (pid $quien)." >&2
        exit 3
      fi
      if [ "$avisado" = 0 ]; then
        avisado=1
        echo "run-tests: otra corrida (pid $quien) tiene el candado; espero a que termine." >&2
        echo "  Si ese pid no es una corrida de run-tests.sh, borra el candado: rm -rf \"$CANDADO\"" >&2
      fi
      # Se le adelanto quien nunca tuvo turno delante del suyo: una corrida de antes de la cola, o
      # todas si no hay cola. Quien espera lo ve, con cuanto lleva (antes no se sabia: 5 h a ciegas).
      if [ -n "$dueno" ] && [ "$quien" != "$dueno" ]; then
        case "$vistos" in
          *" $quien "*) ;;
          *) echo "AVISO run-tests: perdi el turno: la corrida pid $quien tomo el candado sin tener turno delante del mio; llevo $(( ($(date +%s) - ini) / 60 )) min esperando." >&2 ;;
        esac
      fi
      dueno=$quien
      # Cada RUN_TESTS_CANDADO_AVISO segundos (600): cuanto lleva, quien lo tiene y quien va delante.
      if [ $(( $(date +%s) - ultimo )) -ge "${RUN_TESTS_CANDADO_AVISO:-600}" ]; then
        ultimo=$(date +%s)
        echo "run-tests: llevo $(( (ultimo - ini) / 60 )) min esperando el candado; lo tiene pid $quien; delante en la cola: ${delante:-nadie}." >&2
      fi
    fi
    sleep "${RUN_TESTS_CANDADO_ESPERA:-1}"
  done
  # Ya lo tiene: su turno sale de la cola y le toca al siguiente.
  [ -n "$TURNO" ] && rm -rf "$TURNO"; TURNO=""
  [ "$avisado" = 1 ] && echo "run-tests: candado tomado; empiezo." >&2
  return 0
}
# Solo el suyo: si se lo quitaron por muerto y otra corrida lo tomo, no lo borra. Su turno, si aun
# esperaba (lo mataron en la cola), tambien sale.
candado_suelta() {
  [ -z "$TURNO" ] || rm -rf "$TURNO"
  [ "$(cat "$CANDADO/pid" 2>/dev/null)" = "$$" ] && rm -rf "$CANDADO"; return 0
}
# Un temporal propio para toda la corrida, borrado tambien si la matan (p-292d06c4c0). Con `-f`:
# test-run-tests corre una COPIA de este script desde otra carpeta, donde no esta (y ya va anidada).
[ -f tools/tmp-propio.sh ] && . tools/tmp-propio.sh
if [ "${1:-}" != "--una" ]; then
  # Un solo trap EXIT: bash lo corre tambien al morir por INT/TERM/HUP (ver tmp-propio.sh), y este
  # reemplaza el de tmp-propio, asi que lo repite. Va ANTES de esperar: si matan a quien espera en la
  # cola, su turno sale y no frena a los de detras.
  trap 'type _tp_limpia >/dev/null 2>&1 && _tp_limpia; candado_suelta' EXIT
  candado_toma
  export RUN_TESTS_CANDADO_DUENO=$$
fi
# El comando de --con-candado sale con su rc; el trap de arriba suelta el candado.
# Los avisos de restos viejos de tmp-propio van antes: el comando hereda el temporal y no los junta.
if [ "${1:-}" = "--con-candado" ]; then shift; type tmp_propio_avisos >/dev/null 2>&1 && tmp_propio_avisos; "$@"; exit $?; fi
FALLOS=0
FALLIDAS=""
TOTAL=0
LENTAS=""
SALTADAS=""
PARCIALES=""

# Ultima linea de una suite que termino: su resumen, ENTERO y con cero fallos. Cada suite tiene el
# suyo; cada alternativa casa la linea completa (un prefijo como `RESULT:` u `OK:` lo imprime
# cualquier seccion a mitad). Una suite NUEVA con otro formato sale FALLA con "sin linea de
# resumen": anade aqui su formato, no le quites el resumen. Limite: una suite que imprime su propio
# resumen a mitad y luego muere con rc=0 sigue pasando; eso solo lo ve la suite.
RESUMEN_FORMAS=(
  'pass=[0-9]+ fail=0'                                  # la mayoria
  'RESULT:? pass=[0-9]+ fail=0( skip=0)?'               # test-bash-nudge, test-journal-guard...
  'RESULT: PASS'                                        # test-anchor-heal, test-journal-race
  'PASS=[0-9]+ FAIL=0( SKIP=0)?'                        # test-backfill-dedup
  'PASS [0-9]+/[0-9]+'                                  # test-project-dir-fallback
  'PASS test-[a-z-]+'                                   # test-research-row-lookup, -session-index-heal
  'TODO VERDE( \(enlaces reales: si\))?'              # varias; test-compaction-recover
  'test-bench: TODO VERDE'                              # tools/recall-bench/test-bench.sh
  'RESULTADO: [0-9]+ ok, 0 fallas'                      # test-plan-reopen, -research-rename, -session-amend
  '== resumen: [0-9]+ ok, 0 fallas =='                  # test-guardar-huellas-escritos, -linea-base-corrupta
  '---- [0-9]+ ok, 0 fallo\(s\)'                      # test-parser
  'OK: ningun fichero trackeado esta excluido por \.gitignore'  # tools/check-ignored-tracked.sh
  'LAS EVALUABLES DISCRIMINAN \(de [0-9]+\)'          # tools/mutation-check.sh
  'docs [0-9]+, clases de fallo 0'                      # tools/oraculo-rewrite-rule.py (con markdown-it-py)
  'OK [0-9]+'                                           # plugins/pendientes/tests/test_pendientes_ahora.py
  # claude plugin test: su ultima linea no cuenta fallos (va en la de antes); un fallo sale rc=1.
  # [1-9] para que "Ran 0 tests" (carpeta sin pruebas) no pase por verde.
  'Ran [1-9][0-9]* tests? across [0-9]+ files?\. \[[0-9.]+m?s\]'  # plugins/pendientes (pane.test.tsx)
)
RESUMEN="^[[:space:]]*($(IFS='|'; echo "${RESUMEN_FORMAS[*]}"))[[:space:]]*\$"

# rc=0 y la ultima linea no es un resumen: la suite murio a mitad. Pasa con `set -e` y un
# `trap '...' EXIT` (bash 3.2): un error de sintaxis a mitad corta la suite y el rc del trap (0)
# tapa el 2 del error (p-46153b135b, test-checkpoint-close-guard.sh, 2026-10-01).
sin_resumen() { ! printf '%s' "$1" | tail -1 | tr -d '\r' | grep -qE "$RESUMEN"; }

# Salto PARCIAL: la ultima linea cuenta casos saltados ("N saltados", skip=N/SKIP=N con N>0) Y, sin
# esa cuenta, es un resumen de RESUMEN (con cero fallos). Se quita solo la cuenta: ", N saltados" al
# FINAL de la linea (ronda 4: borrar todo lo de detras tapaba un ", 1 fallas") y " skip=N"/" SKIP=N". `pass=1 fail=1 skip=2` o una linea
# cualquiera con `skip=2` no son un salto: caen en sin_resumen (adversario, ronda 3).
es_parcial() {
  local ult; ult=$(printf '%s' "$1" | tail -1 | tr -d '\r')
  printf '%s' "$ult" | grep -qE '[1-9][0-9]* saltad|(skip|SKIP)=[0-9]*[1-9]' || return 1
  # Una sola cuenta: con dos (`skip=2, 3 saltados`) quitar ambas fabricaba un verde (ronda 5).
  [ "$(printf '%s\n' "$ult" | grep -oE '[0-9]+ saltad|(skip|SKIP)=[0-9]+' | wc -l | tr -d ' ')" = 1 ] || return 1
  printf '%s' "$ult" | sed -E 's/, [0-9]+ saltados( \(sin enlaces reales\))?$//; s/ (skip|SKIP)=[0-9]+//' | grep -qE "$RESUMEN"
}

correr() {   # $1 = etiqueta, $2... = comando
  local nom="$1"; shift
  local ini fin dur out rc
  ini=$(date +%s)
  # Sintaxis primero, con el MISMO bash que va a correr la suite (p-5253bc2114): un error de
  # sintaxis DESPUES del resumen, con set -e y trap EXIT, sale rc=0 en bash 3.2 con el resumen ya
  # impreso, y ni el rc ni sin_resumen lo ven. Un `rc=$?` en el trap no sirve: ahi $? llega en 0.
  if [ "$(basename "$1")" = bash ] && [ -f "${2:-}" ] && ! out=$("$1" -n "$2" 2>&1); then
    TOTAL=$(( TOTAL + 1 )); FALLOS=$(( FALLOS + 1 )); FALLIDAS="$FALLIDAS $nom"
    printf '  FALLA %-32s %3ss  bash -n: error de sintaxis\n' "$nom" 0
    printf '%s\n' "$out" | sed 's/^/       /'
    return 0
  fi
  out=$("$@" 2>&1); rc=$?
  fin=$(date +%s); dur=$(( fin - ini ))
  TOTAL=$(( TOTAL + 1 ))
  [ "$dur" -ge 5 ] && LENTAS="$LENTAS $nom(${dur}s)"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | tail -1 | grep -q '^SKIP:'; then
    # Un SKIP sale 0 pero NO es verde: no corrio nada. Contarlo como ok es exactamente el arnes
    # que acepta no-evidencia (regla 12). Se lista aparte y el resumen deja de decir TODO VERDE.
    SALTADAS="$SALTADAS $nom"
    printf '  skip %-32s %3ss  %s\n' "$nom" "$dur" "$(printf '%s' "$out" | tail -1 | cut -c1-46)"
  elif [ "$rc" -eq 0 ] && es_parcial "$out"; then
    # Salto PARCIAL: la suite corrio pero dejo casos sin correr (p. ej. el caso 29 de
    # test-session-amend.sh sin chflags), o `skip=N`/`SKIP=N` con N>0 en el resumen (adversario,
    # ronda 2: RESULT pass=1 fail=0 skip=3 salia ok). Tampoco es TODO VERDE.
    PARCIALES="$PARCIALES $nom"
    printf '  skip %-32s %3ss  %s\n' "$nom" "$dur" "$(printf '%s' "$out" | tail -1 | cut -c1-46)"
  elif [ "$rc" -eq 0 ] && sin_resumen "$out"; then
    FALLOS=$(( FALLOS + 1 )); FALLIDAS="$FALLIDAS $nom"
    printf '  FALLA %-32s %3ss  rc=0 sin linea de resumen (murio a mitad?)\n' "$nom" "$dur"
    printf '%s\n' "$out" | tail -5 | sed 's/^/       /'
  elif [ "$rc" -eq 0 ]; then
    printf '  ok   %-32s %3ss  %s\n' "$nom" "$dur" "$(printf '%s' "$out" | tail -1 | cut -c1-46)"
    [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$out" | sed 's/^/       /'
  else
    FALLOS=$(( FALLOS + 1 )); FALLIDAS="$FALLIDAS $nom"
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
correr "test-tmp-propio" bash tools/test-tmp-propio.sh
correr "test-mutation-filtro" bash tools/test-mutation-filtro.sh
correr "check-ignored-tracked" bash tools/check-ignored-tracked.sh
# Que las comprobaciones editadas sigan sabiendo fallar. Un aserto que nunca se ha visto fallar no
# se ha visto funcionar, y en esta sesion tres afirmaron cubrir mas de lo que cubrian.
# RUN_MUTATION=0 la salta y la cuenta como saltada: el CI de macOS y Windows lo usa porque el arnes
# mide si los asertos discriminan, y eso ya lo mide ubuntu (2 h en Windows por nada nuevo).
if [ "${RUN_MUTATION:-1}" = 0 ]; then
  correr "mutation-check" echo "SKIP: RUN_MUTATION=0 (corre en el job de ubuntu)"
else
  correr "mutation-check" bash tools/mutation-check.sh
fi
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
echo "Suites del mod pendientes"
# El mod lee la memoria con la biblioteca de ESTE repo: --lib es su bin/, no un plugin instalado.
correr "pendientes-ahora" python3 -I plugins/pendientes/tests/test_pendientes_ahora.py --lib "$BIN"
# Las pruebas del panel corren dentro del binario de Claude Code. Sin el CLI (los runners de GitHub
# no lo traen) salen SKIP, no verde.
if command -v claude >/dev/null 2>&1; then
  correr "pendientes-pane" claude plugin test plugins/pendientes
else
  correr "pendientes-pane" echo "SKIP: sin el CLI de claude no corre claude plugin test"
fi

echo
type tmp_propio_avisos >/dev/null 2>&1 && tmp_propio_avisos
echo "------------------------------------------------------------"
if [ "$FALLOS" -eq 0 ] && { [ -n "$SALTADAS" ] || [ -n "$PARCIALES" ]; }; then
  echo "VERDE CON SALTOS — $TOTAL sin fallos${SALTADAS:+, sin correr:$SALTADAS}${PARCIALES:+, con casos saltados:$PARCIALES}"
elif [ "$FALLOS" -eq 0 ]; then
  echo "TODO VERDE — $TOTAL/$TOTAL"
else
  # Con los nombres: quien corre el runner con `| tail` (o lo pierde al pasar a segundo plano) no
  # ve la linea FALLA de arriba, y sin ellos acaba culpando a la suite mas lenta (p-578883244d).
  echo "HAY FALLOS — $FALLOS de $TOTAL:$FALLIDAS"
fi
[ -n "$LENTAS" ] && echo "lentas (>=5s):$LENTAS"
echo "bash $BASH_VERSION en $(uname -s)"
exit $(( FALLOS > 0 ))
