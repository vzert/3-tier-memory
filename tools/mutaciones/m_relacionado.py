import io, sys
# Pendientes relacionados y el siguiente plan hermano (2.55.0). Cada mutacion apaga una pieza y su
# aserto de test-pendiente-relacionado.sh tiene que caer: el campo en la linea de Tier 2, el filtro
# del compactador, el evento pendiente.relate, la linea de afines dentro del snippet, cada
# exclusion (bloqueado, ventana futura o de hoy), el orden, el tope de 2, y el orden de hermanos.
#
# Uso: m_relacionado.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # journal-compact.py
    "linea-sin-campo": [('{blq}{rel}")', '{blq}")')],
    "compact-sin-filtro": [('motivo = relacionado_malformado(p.get("relacionado", []))', "motivo = None")],
    "relate-sin-aplicar": [("        return apply_relate(mem, p)", "        return False")],
    # print-como-retomar.py
    "snippet-sin-afines": [('inner = con_afines(fence.group(1).strip("\\n"), text, path)',
                            'inner = fence.group(1).strip("\\n")')],
    # pendientes_afines.py
    "afines-con-bloqueados": [('or p["bloqueado"]:', ":")],
    "afines-con-vence-hoy": [('if p["revisar"] and p["revisar"] >= hoy:', 'if p["revisar"] and p["revisar"] > hoy:')],
    # 2.57.0: el hilo sustituyo al filtro de afines; las mismas piezas, en su codigo nuevo.
    # 2.62.0: el hilo es de un salto; la direccion "el ancla cita al candidato" es esta rama.
    "afines-sin-inversa": [('if p["id"] in semillas:', "if False:")],
    "afines-sin-prioridad": [('out.sort(key=lambda p: (PRIORIDAD_HILO[p["prio"]], p["grupo"], p["creado"], p["fila"]))',
                              'out.sort(key=lambda p: (p["creado"], p["fila"]))')],
    "afines-sin-tope": [("extras = (altas_medias or elegibles)[:MAX_AFINES]", "extras = (altas_medias or elegibles)")],
    # plan-siguiente-hermano.py
    "hermano-fuera-primero": [("for s in en_tabla + fuera:", "for s in fuera + en_tabla:")],
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
