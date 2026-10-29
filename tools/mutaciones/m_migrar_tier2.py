import io, sys
# migrar-tier2.py (2.66.0, p-206fd62e68 propuesta f). Cada mutacion apaga una pieza y su aserto de
# test-migrar-tier2.sh tiene que caer: el dry-run que no escribe, la negativa con eventos sin compactar,
# el respaldo, el texto que va a Tier 3 (destino, sub-vinetas, prosa tras los metadatos) y el recorte.
#
# Uso: m_migrar_tier2.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "dry-escribe": [("        if not a.apply:", "        if False:")],
    "sin-negativa-pending": [("        if n:", "        if False:")],
    "sin-respaldo": [("        respaldar(mem, sorted(set(rutas)), carpeta)", "        pass")],
    "no-escribe-destino": [('    if a["faltan"]:', "    if False:")],
    "subvineta-pisa-detalle": [('            detalle = f"{viejo} — {texto}" if viejo else texto',
                                "            detalle = texto")],
    "pierde-prosa": [('    return "".join(f" — {g}" for g in segs), prosa',
                      '    return "".join(f" — {g}" for g in segs), ""')],
    "titulo-sin-recorte": [("    if len(t) <= lim:", "    if True:")],
    # p-cafb3ae9f1: [[learnings/x.md]] vuelve a buscarse como x.md.md.
    "enlace-md-md": [('    sin_md = lambda s: s[:-3] if s.endswith(".md") else s', "    sin_md = lambda s: s")],
    # p-c82b911c23: las dos ramas de contar_aviso que antes no tenian aserto propio.
    "aviso-destino-inexistente": [("                ok = rel_ is not None and os.path.isfile(os.path.join(mem, rel_))",
                                   "                ok = rel_ is not None")],
    "aviso-vineta-padre-sin-id": [("                    ok = k is not None and pendiente_movible(lines[k], True)",
                                   "                    ok = k is not None")],
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
