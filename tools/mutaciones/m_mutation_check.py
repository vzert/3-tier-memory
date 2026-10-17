import io, sys
# tools/mutation-check.sh lanzado solo toma el candado de tools/run-tests.sh (p-4be2b6ea23). Cada
# mutacion apaga una pieza y su aserto de tools/test-run-tests.sh tiene que caer.
#
# Uso: m_mutation_check.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
SI = 'if [ "$(cat "$(bash tools/run-tests.sh --ruta-candado)/pid" 2>/dev/null)" != "${RUN_TESTS_CANDADO_DUENO:-ninguno}" ]; then'
M = {
    "sin-candado": [
        ('  exec bash tools/run-tests.sh --con-candado bash tools/mutation-check.sh "$@"', '  :')],
    "siempre-pide": [(SI, 'if true; then')],
    "solo-la-variable": [(SI, 'if [ -z "${RUN_TESTS_CANDADO_DUENO:-}" ]; then')],
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
