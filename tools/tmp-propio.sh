# Temporal propio de una corrida de tools/run-tests.sh o tools/mutation-check.sh (p-292d06c4c0).
#
# Por que existe: las carpetas `mktemp -d` de las suites quedaban en el temporal del sistema cuando
# las mataban. Medido: bash SI corre `trap ... EXIT` con TERM/INT/HUP, asi que pierde la que se crea
# sin trap y se borra al final (cada caso de mutation-check.sh) y cualquiera con un kill -9. El
# 2026-10-14 se acumularon 1840 (14 GB) y llenaron el disco a mitad de la suite (`mktemp: No space
# left on device`).
#
# Que hace, al cargarlo con `.`:
#   1. Crea UNA carpeta `3tm-tests.<pid>.XXXXXX` y exporta TMPDIR hacia ella: el `tempfile` de
#      Python cae dentro, y los `mktemp` de las suites tambien, por la funcion de abajo.
#      `mktemp -d` de macOS 26 NO lee TMPDIR (medido: con TMPDIR puesto crea en /var/folders/.../T);
#      `-p DIR` si funciona alli y en GNU (Linux, Git Bash). Asi que se exporta una funcion `mktemp`
#      que anade `-p "$TMPDIR"` a las llamadas SIN plantilla (las suites solo usan `mktemp -d`); una
#      llamada con plantilla o con otras opciones va tal cual. Las suites corren con `bash`, que
#      hereda las funciones exportadas, sin tocar ninguna suite.
#   2. La borra al salir con un trap EXIT, que bash corre tambien al morir por INT/TERM/HUP
#      (medido en bash 3.2: traps propios para esas senales no cambiaban nada; test-tmp-propio.sh
#      lo vigila en cada plataforma). Lo que gana es que una suite que muere sin su propio trap (un
#      kill -9 a ella, un fallo a medias) deja su carpeta DENTRO de esta, y se va con ella. Lo unico
#      que no se limpia es un kill -9 del propio runner: para eso esta el aviso.
#   3. Junta avisos (no borra) de restos viejos: carpetas `3tm-tests.<pid>.*` cuyo proceso ya no
#      existe y `tmp.*` sueltas de mas de 60 min, con el comando para borrarlas. Borrar el temporal
#      del sistema sin que nadie lo pida no le toca a un runner de pruebas. Los imprime
#      `tmp_propio_avisos` (a stderr), cuando el runner quiera: run-tests al final, porque
#      test-run-tests lee el veredicto de la PRIMERA linea de `run-tests.sh --una`.
#
# Anidado (mutation-check dentro de run-tests, o una tanda dentro de mutation-check): si
# TMP_PROPIO_DIR ya esta puesto, no hace nada y el hijo hereda el TMPDIR del padre.
#
# Lo cargan tools/run-tests.sh y tools/mutation-check.sh. Prueba: tools/test-tmp-propio.sh.

TMP_PROPIO_AVISOS=""
tmp_propio_avisos() { [ -n "$TMP_PROPIO_AVISOS" ] && printf '%s' "$TMP_PROPIO_AVISOS" >&2; return 0; }

if [ -z "${TMP_PROPIO_DIR:-}" ]; then
  _tp_base="${TMPDIR:-/tmp}"; _tp_base="${_tp_base%/}"

  _tp_restos=""; _tp_n=0
  for _tp_d in "$_tp_base"/3tm-tests.*; do
    [ -d "$_tp_d" ] || continue
    _tp_pid="${_tp_d##*/3tm-tests.}"; _tp_pid="${_tp_pid%%.*}"
    case "$_tp_pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$_tp_pid" 2>/dev/null && continue
    _tp_n=$(( _tp_n + 1 )); _tp_restos="$_tp_restos \"$_tp_d\""
  done
  if [ "$_tp_n" -gt 0 ]; then
    TMP_PROPIO_AVISOS="${TMP_PROPIO_AVISOS}AVISO tmp-propio: $_tp_n carpeta(s) de corridas anteriores que murieron sin limpiar en $_tp_base. Borralas con: rm -rf$_tp_restos
"
  fi
  _tp_viejas=$(find "$_tp_base" -maxdepth 1 -type d -name 'tmp.*' -mmin +60 2>/dev/null | wc -l | tr -d ' ')
  if [ "${_tp_viejas:-0}" -gt 0 ]; then
    TMP_PROPIO_AVISOS="${TMP_PROPIO_AVISOS}AVISO tmp-propio: $_tp_viejas carpeta(s) tmp.* de mas de 60 min en $_tp_base (restos de suites anteriores a este arreglo, o de otros programas). Mira cuales son tuyas antes de borrarlas: find \"$_tp_base\" -maxdepth 1 -type d -name 'tmp.*' -mmin +60
"
  fi

  if TMP_PROPIO_DIR=$(mktemp -d "$_tp_base/3tm-tests.$$.XXXXXX" 2>/dev/null); then
    export TMP_PROPIO_DIR
    export TMPDIR="$TMP_PROPIO_DIR"
    mktemp() {
      local _a
      for _a in "$@"; do
        case "$_a" in -d|-q|-u) ;; *) command mktemp "$@"; return ;; esac
      done
      command mktemp -p "${TMPDIR:-/tmp}" "$@"
    }
    export -f mktemp
    _tp_limpia() { [ -n "${TMP_PROPIO_DIR:-}" ] && [ -d "$TMP_PROPIO_DIR" ] && rm -rf "$TMP_PROPIO_DIR"; }
    trap '_tp_limpia' EXIT
  else
    TMP_PROPIO_AVISOS="${TMP_PROPIO_AVISOS}AVISO tmp-propio: no se pudo crear el temporal propio en $_tp_base; las suites usan el del sistema y una que muera dejara su carpeta ahi
"
  fi
  unset _tp_base _tp_restos _tp_n _tp_d _tp_pid _tp_viejas
fi
