import io, sys
# journal-emit rechaza --nota en los tipos que no la guardan (p-3bf672997c). Cada mutacion apaga una
# pieza y su aserto de test-nota-sin-lector.sh tiene que caer: el rechazo general, el de learning.add
# sin --supersedes, y la comparacion contra None (con "verdad/falso" pasaban --nota "" y "   ").
#
# Uso: m_nota_sin_lector.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # journal-emit.py
    "sin-rechazo": [
        ("    if a.nota is not None and a.type not in NOTA_LECTORES:", "    if False:")],
    "add-sin-rechazo": [
        ("        if a.nota is not None and not sup:", "        if False:")],
    "nota-por-verdad": [
        ("    if a.nota is not None and a.type not in NOTA_LECTORES:",
         "    if (a.nota or \"\").strip() and a.type not in NOTA_LECTORES:")],
    "lector-de-mas": [
        ('NOTA_LECTORES = ("pendiente.resolve", "pendiente.update", "learning.retire", "learning.add")',
         'NOTA_LECTORES = ("pendiente.resolve", "pendiente.update", "learning.retire", "learning.add", "pendiente.add")')],
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
