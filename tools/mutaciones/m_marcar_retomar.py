import io, sys
# marcar-retomar.py normaliza --hoy con regex propio, igual en Python 3.9 y 3.11+ (p-0ccd79fe36,
# 2.63.7). Cada mutacion apaga una pieza y su aserto de test-marcar-retomar.sh tiene que caer en
# cualquier Python: la forma sin guiones, la de semana ISO y la regla de guiones (todos o ninguno).
# Limite: volver a date.fromisoformat no lo ve un CI con 3.11+ (ahi acepta las tres formas).
#
# Uso: m_marcar_retomar.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # marcar-retomar.py
    "sin-forma-ancha": [
        ('HOY_DIA = re.compile(r"(\\d{4})-?(\\d{2})-?(\\d{2})")',
         'HOY_DIA = re.compile(r"(\\d{4})-(\\d{2})-(\\d{2})")')],
    "sin-semana": [
        ("    m = HOY_SEMANA.fullmatch(valor)", "    m = None")],
    "guiones-sueltos": [
        ('    if m and valor.count("-") in (0, 2):              # todos los guiones o ninguno',
         '    if m:')],
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
