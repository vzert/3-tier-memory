import io, sys
# snippet.hilo_externo (2.67.1, p-d691ef721b). Cada mutacion es una version rota del arreglo de L1
# (la negacion cuenta en toda la clausula de delante de `leido completo`) o de L2 (`abierto` solo
# cuenta suelto). Las 11 pruebas de vigilancia de la seccion 7g de test-hilos-externos.sh se vieron
# caer a mano contra estas roturas; aqui caen en cada corrida.
#
# Uso: m_hilo_externo.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
CLAUSULA = '            clausula = re.split(r"[—;,:|]", l[:m.start()])[-1]'
M = {
    # L1: la clausula no se corta en `—;,:|`: un `no` de una lectura anterior niega la siguiente.
    "sin-cortar-clausula": [(CLAUSULA, "            clausula = l[:m.start()]")],
    # L1: la negacion se busca en toda la linea, tambien detras de la fecha.
    "linea-entera": [(CLAUSULA, "            clausula = l")],
    # L1: la etiqueta entre comillas invertidas cuenta como parte de la frase.
    "etiqueta-cuenta": [('return not negacion.search(re.sub(r"`[^`]*`", "", clausula))',
                         "return not negacion.search(clausula)")],
    # L1: `\b` en vez de `(?<![\w-])`: el `no` de `no-tocar` cuenta como negacion.
    "neg-con-guiones": [('negacion = re.compile(r"(?<![\\w-])(?:no|nunca|sin|jam[aá]s)(?![\\w-])", re.I)',
                         'negacion = re.compile(r"\\b(?:no|nunca|sin|jam[aá]s)\\b", re.I)')],
    # L3, el callejon de 2.67.1: exigir fecha ISO tras `leido completo` rompe `el 26 de octubre`.
    "fecha-iso": [('r"d[ií]a|on|at)\\W{1,3}){0,3}\\d", l, re.I)):',
                   'r"d[ií]a|on|at)\\W{1,3}){0,3}\\d{4}-\\d\\d-\\d\\d", l, re.I)):')],
    # L2: el arreglo quita el aviso en vez de afinarlo, en la linea suelta o en la del hilo.
    "abierto-suelto-sin-aviso": [("                if abierto_suelto.search(l):", "                if False:")],
    "abierto-hilo-sin-aviso": [("                if abierto_suelto.search(plano):", "                if False:")],
}

p, nombre = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
if nombre not in M:
    print(f"0 sust: mutacion desconocida «{nombre}»")
    sys.exit(0)
s = io.open(p, encoding="utf-8", newline="").read()
cuentas = [s.count(viejo) for viejo, _ in M[nombre]]
if cuentas != [1] * len(cuentas):
    print(f"0 sust de {nombre} (cada sustitucion calza {cuentas} veces; se exige 1)")
    sys.exit(0)
for viejo, nuevo in M[nombre]:
    s = s.replace(viejo, nuevo)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print(f"{len(M[nombre])} sust de {nombre}")
