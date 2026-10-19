import io, sys
# checkpoint-close-guard.sh solo dispara con la invocacion REAL de print-como-retomar.py (2.63.8,
# p-1fe14aa592). Cada mutacion apaga una pieza y su aserto de test-checkpoint-close-guard.sh tiene que
# caer: `mencion-cuenta` vuelve a la busqueda por mencion (el git diff con una ficha real dispara);
# `python-no-cuenta` deja de reconocer el script como argumento de python3.
#
# Uso: m_invocacion_retomar.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "mencion-cuenta": [
        (r'        lx = shlex.shlex(texto, posix=True, punctuation_chars=";&|()\n")',
         "        raise ValueError")],
    "python-no-cuenta": [
        ('            elif _RE_PYTHON.match(os.path.basename(prog.replace("\\\\", "/"))):',
         '            elif False and _RE_PYTHON.match(os.path.basename(prog.replace("\\\\", "/"))):')],
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
print(f"{len(cuentas)} sust de {nombre}")
