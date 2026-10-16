import io, sys
# Fila de plan podada (2.62.2, p-fb70d4600d). Cada mutacion apaga una pieza del guardian que lee el
# frontmatter de plans/plan-<slug>.md, y su aserto del caso 17 de test-plan-reopen.sh tiene que caer.
#
# Uso: m_plan_poda.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "sin-guardian": [("        if fm in PLAN_CERRADO:", "        if False:")],
    "sin-comillas": [("""v = m.group(1).strip().strip("'\\"").lower().split()""",
                      "v = m.group(1).strip().lower().split()")],
    "solo-completed": [("        if fm in PLAN_CERRADO:", '        if fm == "completed":')],
    "sin-registro-poda": [('anotaciones += [(f"poda-plan-{s}", ts, "la poda") for s in podados]', "pass")],
    "sin-condicion-registro": [('            and ts_registrados(mem, f"poda-plan-{slug}"):', "            :")],
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
