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
