import io, sys
# tools/run-tests.sh exige la linea de resumen a una suite que sale con rc=0 (p-46153b135b). Cada
# mutacion apaga una pieza y su aserto de tools/test-run-tests.sh tiene que caer.
#
# Uso: m_run_tests.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "sin-resumen-no-exigido": [
        ('elif [ "$rc" -eq 0 ] && sin_resumen "$out"; then', 'elif false; then')],
    "resumen-cualquiera": [
        ("sin_resumen() { ! printf '%s' \"$1\" | tail -1 | tr -d '\\r' | grep -qE \"$RESUMEN\"; }",
         "sin_resumen() { ! printf '%s' \"$1\" | grep -qE \"$RESUMEN\"; }")],
    "skip-n-ignorado": [
        ("grep -qE '[1-9][0-9]* saltad|(skip|SKIP)=[0-9]*[1-9]' || return 1",
         "grep -qE '[1-9][0-9]* saltad' || return 1")],
    "parcial-sin-resumen": [
        ('sed -E \'s/, [0-9]+ saltados( \\(sin enlaces reales\\))?$//; s/ (skip|SKIP)=[0-9]+//\' | grep -qE "$RESUMEN"',
         'grep -q .')],
    "saltados-con-cola": [
        ('s/, [0-9]+ saltados( \\(sin enlaces reales\\))?$//',
         's/, [0-9]+ saltad.*$//')],
    "skip-a-cero": [
        ('s/ (skip|SKIP)=[0-9]+//',
         's/(skip|SKIP)=[0-9]+/\\1=0/')],
    "dos-cuentas": [
        ('  [ "$(printf \'%s\\n\' "$ult" | grep -oE \'[0-9]+ saltad|(skip|SKIP)=[0-9]+\' | wc -l | tr -d \' \')" = 1 ] || return 1',
         '  :')],
    "sin-bash-n": [
        ('if [ "$(basename "$1")" = bash ] && [ -f "${2:-}" ] && ! out=$("$1" -n "$2" 2>&1); then',
         'if false; then')],
    "resumen-prefijo": [
        ('RESUMEN="^[[:space:]]*($(IFS=\'|\'; echo \"${RESUMEN_FORMAS[*]}\"))[[:space:]]*\\$"',
         'RESUMEN="^[[:space:]]*($(IFS=\'|\'; echo \"${RESUMEN_FORMAS[*]}\"))"')],
    # p-524e2a5bf7: el candado de una corrida completa por maquina.
    "sin-candado": [
        ("  candado_toma", "  :")],
    "muerto-bloquea": [
        ('elif ! candado_vivo "$quien"; then', 'elif false; then')],
    "una-con-candado": [
        ('if [ "${1:-}" != "--una" ]; then', 'if true; then')],
    "no-suelta": [
        ("_tp_limpia; candado_suelta' EXIT", "_tp_limpia' EXIT")],
    "quita-sin-comprobar": [
        ('  [ -e "$CANDADO" ] || return 0', '  return 0')],
    "permiso-es-muerto": [
        ('  case "$err" in *ermitted*) return 0 ;; esac', '  :')],
    # Cae por la carrera de las ocho corridas con pausa: medido 3 de 3, no es determinista.
    "sin-releer": [
        ('  if [ "$(cat "$CANDADO/pid" 2>/dev/null)" != "$1" ]; then', '  if false; then')],
    "no-crea-espera": [
        ('    if [ ! -d "$CANDADO" ]; then', '    if false; then')],
    "no-crea-corre": [
        ('        exit 2', '        return 0')],
    "pid-cero-vivo": [
        ('  [ "$1" -gt 0 ] 2>/dev/null || return 1', '  :')],
    "candado-en-tmpdir": [
        ('CANDADO="${RUN_TESTS_CANDADO:-/tmp/3tm-run-tests.candado}"',
         'CANDADO="${RUN_TESTS_CANDADO:-${TMPDIR:-/tmp}/3tm-run-tests.candado}"')],
    # p-4be2b6ea23: sin el modo, mutation-check suelto corre la suite completa en vez de su cuerpo.
    "sin-con-candado": [
        ('if [ "${1:-}" = "--con-candado" ]; then shift; type tmp_propio_avisos >/dev/null 2>&1 && tmp_propio_avisos; "$@"; exit $?; fi', ':')],
    # p-7c1fa85c1e: el candado guarda la hora de arranque de su dueno.
    "sin-comparar-hora": [
        ('    elif candado_reusado "$quien"; then', '    elif false; then')],
    "hora-siempre-distinta": [
        ('  [ -n "$ahora" ] && [ "$ahora" != "$guardada" ]', '  true')],
    "sin-hora-es-reusado": [
        ('  [ -n "$guardada" ] || return 1', '  [ -n "$guardada" ] || return 0')],
    "hora-con-tz-local": [
        ('    TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1"', '    LC_ALL=C ps -o lstart= -p "$1"')],
    "sin-escribir-hora": [
        ('      candado_hora "$$" > "$CANDADO/arranque" 2>/dev/null', '      :')],
    # 2026-10-28: la cola de turnos por orden de llegada y los avisos de quien espera.
    "sin-cola": [
        ('  [ -n "$TURNO" ] || return 0', '  return 0')],
    "turno-muerto-vivo": [
        ('    if ! candado_vivo "$pid" || turno_reusado "$t" "$pid"; then',
         '    if turno_reusado "$t" "$pid"; then')],
    "turno-reusado-vivo": [
        ('  [ -n "$ahora_t" ] && [ "$ahora_t" != "$antes" ]', '  false')],
    "turno-vivo-borrado": [
        ('  ahora_t=$(candado_hora "$2")', '  ahora_t=otra')],
    "sin-paciencia": [
        ('    if [ -n "$delante" ] && [ "$libre" -ge "$pac" ]; then', '    if false; then')],
    # Adversario, ronda 1: saltar a todos los de delante a la vez, no solo al parado.
    "salta-todos": [
        ('      delante=$quedan', '      delante=""')],
    "libre-sin-ceder": [
        ('    if [ ! -d "$CANDADO" ] && [ -n "$delante" ]; then', '    if false; then')],
    "turno-no-sale-al-tomar": [
        ('  [ -n "$TURNO" ] && rm -rf "$TURNO"; TURNO=""', '  :')],
    "turno-no-sale-al-morir": [
        ('  [ -z "$TURNO" ] || rm -rf "$TURNO"', '  :')],
    "sin-turno-sale": [
        ('  echo "AVISO run-tests: no puedo sacar turno en $COLA; espero sin orden de llegada." >&2', '  exit 2')],
    "cola-con-p": [
        ('  if { [ -d "$COLA" ] || mkdir "$COLA" 2>/dev/null; } && mkdir "$TURNO" 2>/dev/null; then',
         '  if mkdir -p "$COLA" 2>/dev/null && mkdir "$TURNO" 2>/dev/null; then')],
    "sin-aviso-perdido": [
        ('          *) echo "AVISO run-tests: perdi el turno:', '          *) : "AVISO run-tests: perdi el turno:')],
    "perdido-siempre": [
        ('          *" $quien "*) ;;', '          *" nadie-casa "*) ;;')],
    "sin-aviso-periodico": [
        ('      if [ $(( $(date +%s) - ultimo )) -ge "${RUN_TESTS_CANDADO_AVISO:-600}" ]; then', '      if false; then')],
}
p, nombre = sys.argv[1], sys.argv[2]
s = io.open(p, encoding="utf-8", newline="").read()
cuentas = [s.count(viejo) for viejo, _ in M[nombre]]
if cuentas != [1] * len(cuentas):
    print(f"0 sust de {nombre} (cada sustitucion calza {cuentas} veces; se exige 1)")
    sys.exit(0)
for viejo, nuevo in M[nombre]:
    s = s.replace(viejo, nuevo)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print(f"{len(cuentas)} sust de {nombre}")
