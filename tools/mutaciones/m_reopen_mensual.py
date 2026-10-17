import io, sys
# Pasada muerta de un pendiente.reopen entre sacar la linea del archivo y limpiar la fila mensual
# (p-c103c7df05). Cada mutacion apaga una pieza del arreglo, y su aserto de test-resolve-reopen.sh
# (casos 25 y 26) tiene que caer.
#
# Uso: m_reopen_mensual.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "sin-terminar": [("            if ya_anotado:", "            if False:")],
    "sin-pedir-registro": [("            if ya_anotado:", "            if True:")],
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
