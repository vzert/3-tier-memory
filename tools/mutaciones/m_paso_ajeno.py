import io, sys
# Snippet con paso ajeno (2.63.43, auditoria de 101 fichas del 2026-10-22). Cada mutacion apaga una
# pieza y su aserto tiene que caer: (1) paso_ajeno.py, que lee el trabajo de la sesion y las otras
# ventanas; (2) checkpoint-audit.py, los avisos snippet.titulo_paso / paso_no_trabajado /
# paso_otra_ventana; (3) checkpoint-close-guard.sh, que pasa el transcript y lleva el aviso a la
# revision del cierre.
#
# Uso: m_paso_ajeno.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # paso_ajeno.py
    "ajeno-cierre-cuenta": [("                        if TRABAJO.search(cmd) and not en_cierre:",
                             "                        if TRABAJO.search(cmd):")],
    "ajeno-mensaje-cuenta": [('                if b.get("type") == "tool_use" and b.get("name") in HERRAMIENTAS_ACCION \\',
                              '                if b.get("type") == "tool_use" \\')],
    "ajeno-sin-ventana": [("                    or ahora - _epoch(r, mtime) > horas * 3600:",
                           "                    or False:")],
    "ajeno-cierre-no-libera": [("                vistos = set()", "                pass")],
    "ajeno-cierre-otra-cuenta": [("            if en_cierre or r.get(\"type\") != \"assistant\" or not any(i in linea for i in ids) \\",
                                  "            if r.get(\"type\") != \"assistant\" or not any(i in linea for i in ids) \\")],
    "ajeno-memoria-otra-cuenta": [("                        and not _es_memoria((b.get(\"input\") or {}).get(\"file_path\")):",
                                   "                        and True:")],
    "ajeno-cualquier-proyecto": [('glob.escape(base) + "*"', '"*"')],
    # checkpoint-audit.py
    "audit-sin-paso-no-trabajado": [("            elif ajenos:", "            elif False:")],
    "audit-ilegible-afirma": [("            if propio is None:", "            if False:")],
    "audit-sin-otra-ventana": [("            if choques:", "            if False:")],
    "audit-titulo-sin-liga": [("            ligados = any(", "            ligados = False and any(")],
    "audit-sin-titulo-paso": [("            if ligados:", "            if True:")],
    # checkpoint-close-guard.sh
    "guard-sin-ajeno": [("        if avisos_ajeno:", "        if False:")],
    "guard-sin-transcript": [('                           + (["--transcript", tpath] if tpath else []),',
                              "                           + [],")],
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
