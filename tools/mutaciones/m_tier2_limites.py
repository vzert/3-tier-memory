import io, sys
# Tier 2 con titulo corto (2.63.47, p-206fd62e68) y puente viejo (2.64.2, p-6ba77d2ea4). Cada mutacion
# apaga una pieza y su aserto tiene que caer: (1) journal-emit.py, el tope y la validacion de
# --titulo, el detalle que pasa a Tier 3 y el aviso de largo; (2) journal-compact.py, el detalle que
# sobrevive a un update y el separador de la celda; (3) print-pendientes-alcance.py, el alcance del
# cierre; (4) print-tier2-tamano.py, la marca GRANDE; (5) update-puente.py, el casado exacto, la copia
# y el dry-run.
#
# Uso: m_tier2_limites.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # journal-emit.py
    "emit-titulo-sin-tope": [("            if len(titulo) > TITULO_MAX:", "            if False:")],
    "emit-titulo-vacio-pasa": [("        if a.titulo is not None and not titulo:", "        if False:")],
    "emit-titulo-pierde-detalle": [("                detalle, text = text, titulo", "                detalle, text = \"\", titulo")],
    "emit-sin-aviso-largo": [("    if len(valor) > tope:", "    if False:")],
    # journal-compact.py
    "compact-update-pierde-detalle": [("celda_texto(p['text'], detalle_de_celda(cells[COL_TEXT]))", "celda_texto(p['text'])")],
    "compact-sin-detalle-en-fila": [("celda_texto(p['text'], p.get('detalle', ''))", "celda_texto(p['text'])")],
    # print-pendientes-alcance.py
    "alcance-sin-recorte": [("    if len(texto) <= tope:", "    if True:")],
    "alcance-vencido-incluye-hoy": [("        if p[3] and p[3] < hoy:", "        if p[3] and p[3] <= hoy:")],
    "alcance-imprime-futuros": [("        else:\n            continue", "        else:\n            filas.append((p, 'futuro'))")],
    # print-tier2-tamano.py
    "tamano-sin-largas": [("(n > grande or k)", "(n > grande)")],
    "tamano-sin-bytes": [("(n > grande or k)", "(k)")],
    # update-puente.py
    "puente-casa-todo": [("        if texto.count(VIEJO) != 1:", "        if False:")],
    "puente-sin-copia": [("        if not os.path.exists(copia):", "        if False:")],
    "puente-dry-escribe": [("        if dry:", "        if False:")],
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
