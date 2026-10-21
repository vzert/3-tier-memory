import io, sys
# `snippet.ninguno_plan_activo` (2.63.31, p-7fd6a82eaa). Cada mutacion apaga una pieza del chequeo
# de checkpoint-audit.py y su aserto de test-ninguno-plan-activo.sh tiene que caer: (1) el rechazo
# mismo; (2) leer el campo `_relacionado` y no la prosa (regla 216); (3) contar solo planes `active`;
# (4) el corte de fecha (d284); (5) aplicar solo a un snippet `ninguno`; (6) ligar un plan cuyo
# fichero no empieza por `plan-` con `plan-<nombre>`; (7) reconocer el enlace con `../`, `.md` o `#ancla`.
#
# Uso: m_ninguno_plan.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "plan-sin-rechazo": [("        if planes_sin_hilo:", "        if False:")],
    "plan-liga-prosa": [('                ligados |= pe["rel"]',
                         '                ligados |= pe["rel"] | set(re.findall(r"plan-[\\w.-]+", pe["texto"]))')],
    "plan-cualquier-estado": [("        vivos_plan = [p for p in enlazados if plan_activo(memory_dir, p)]",
                               "        vivos_plan = enlazados")],
    "plan-sin-prefijo": [(' and "plan-" + p not in ligados]', "]")],
    "plan-enlace-estricto": [("for p in planes_laxo})", "for p in planes})")],
    "plan-sin-corte": [("fecha_ficha >= DESDE_NINGUNO_PLAN", 'fecha_ficha >= "2000-01-01"')],
    "plan-cualquier-snippet": [("            and es_ninguno_snip:", "            and True:")],
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
