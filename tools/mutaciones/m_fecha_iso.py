import io, sys
# journal-emit (fecha_real) y journal-compact (fecha_iso) exigen AAAA-MM-DD con regex (2.63.7). Cada
# mutacion quita la regex de un fichero y su aserto de test-fecha-iso.sh tiene que caer. Discriminan
# con Python 3.11 o mas (el CI y el python3 de Homebrew): en 3.9 fromisoformat ya rechaza las formas
# anchas y la regex no cambia nada.
#
# Uso: m_fecha_iso.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # journal-emit.py y journal-compact.py: la misma linea, cada mutacion sobre su fichero.
    "sin-regex": [
        ("    if not (isinstance(v, str) and FECHA_ISO_RE.fullmatch(v)):", "    if False:")],
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
