import io, sys
# test-checkpoint-close-guard.sh fija una fecha para la prueba, el hook y los scripts que lanza con un
# sitecustomize en su mktemp (2.63.27, p-091714b9cf). La mutacion quita el parche: el hook y
# print-pendiente-opcional.py vuelven a leer el dia real, el Alta que vence en HOY (2031-03-15) ya no
# vence hoy y el 8e del fixture sale vacio. Si el aserto no cae, la prueba depende otra vez de la hora.
#
# Uso: m_hoy_fijo.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "sin-parche": [
        ("    datetime.date = _Hoy", "    pass")],
}

p, nombre = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
if nombre not in M:
    print(f"0 sust: mutacion desconocida {nombre}")
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
