import io, sys
# test-checkpoint-close-guard.sh convierte con cygpath las rutas que txcmd mete dentro del texto del
# comando (2.63.18): en Git Bash, MSYS no convierte una ruta dentro de otro texto y el guard, en el
# Python nativo de Windows, no encontraba la ficha. La mutacion quita la conversion; el aserto "arnes Git
# Bash" tiene que caer en Windows. Fuera de Git Bash no hay cygpath y la suite imprime su SKIP.
#
# Uso: m_arnes_cygpath.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "sin-cygpath": [
        ("  if command -v cygpath >/dev/null 2>&1; then", "  if false; then")],
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
