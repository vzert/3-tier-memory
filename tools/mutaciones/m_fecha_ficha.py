import io, sys
# La fecha de la ficha y el sello de session_id (2.72.0, plan de hilos H7). Cada mutacion apaga una
# pieza y su aserto de test-fecha-ficha.sh (o de test-checkpoint-close-guard.sh) tiene que caer.
#
# Uso: m_fecha_ficha.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # fecha-ficha.py: la fecha UTC en vez de la local.
    "fecha-utc": [("    fecha = _sello().fecha_local(ahora)", "    fecha = ahora[:10]")],
    # templates/checkpoint-3t.md: el Step 1 vuelve a tomar la fecha de `date -u`.
    "plantilla-date-u": [('{ [ -n "$_FF" ] && python3 "$_FF" --slug "SLUG"; } ||',
                          'echo "DATE=$(date -u +%Y-%m-%d)"; true ||')],
    # fecha-ficha.py: un instante sin zona pasa; el .md del slug se queda.
    "ahora-sin-zona": [('    if pedido and not re.search(', '    if False and not re.search(')],
    "slug-con-md": [('        if slug.endswith(".md"):', '        if False:')],
    # stamp-session-id.py: sin limite de fecha en la segunda oportunidad.
    "sello-utc-margen": [("        if not (primera and ultima and en_rango(fecha_del_nombre(ficha), primera, ultima)):",
                          "        if not (primera and ultima):")],
    # checkpoint-audit.py: el audit sella en vez de mirar; audita fichas viejas; comando sin comillas.
    "audit-sin-seco": [('        r = subprocess.run([sys.executable] + base + ["--dry-run"],',
                        '        r = subprocess.run([sys.executable] + base,')],
    "audit-sin-comillas": [('corrige="python3 " + " ".join(shlex.quote(x) for x in base)))',
                            'corrige="python3 " + " ".join(base)))')],
    # stamp-session-id.py: sin la segunda oportunidad; con ella para cualquiera; --dry-run que escribe.
    "sello-sin-evidencia": [("            if not escrita_por_la_sesion(ficha, transcripcion):", "            if True:")],
    "sello-evidencia-gratis": [("            if not escrita_por_la_sesion(ficha, transcripcion):", "            if False:")],
    "seco-escribe": [("    if en_seco:", "    if False:")],
    # checkpoint-audit.py
    "audit-sin-chequeo": [("        sello_de_sesion(h, session_file, texto, hoy)", "        pass")],
    "audit-sin-variable": [('    sid = (os.environ.get("CLAUDE_CODE_SESSION_ID") or "").strip()',
                            '    sid = (os.environ.get("CLAUDE_CODE_SESSION_ID") or "aaaaaaaa-1111-4222-8333-444444444444").strip()')],
    "audit-ficha-ajena": [("    if not propia:", "    if False:")],
    "audit-sin-cerca": [("        if cerca:", "        if True:")],
    "audit-comando-siempre": [("    if sellaria:", "    if True:")],
    # checkpoint-close-guard.sh: el hook le pasa la variable a su audit.
    "hook-con-variable": [('                                    if k != "CLAUDE_CODE_SESSION_ID"})',
                           '                                    if k != "NINGUNA"})')],
}
p, nombre = sys.argv[1], sys.argv[2]
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
