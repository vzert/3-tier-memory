import io, sys
# Auditoria de hilos y snippet de retomar (2.63.22). Cada mutacion apaga una pieza y su aserto tiene
# que caer: (1) snippet-vigente.py, el aviso al pegar un snippet viejo (paso cerrado, ficha mas
# nueva, marca `_retomar`, tarjeta del mod); (2) checkpoint-audit.py y checkpoint-close-guard.sh,
# el aviso al cerrar `snippet.paso_compartido`; (3) print-pendiente-opcional.py, el ➕ sin el
# respaldo del Alta mas nuevo (decision de Victor, d265-d266).
#
# Uso: m_paso_vigente.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # snippet-vigente.py
    "vigente-sin-cerrado": [("            if c:", "            if False:")],
    "vigente-sin-ficha-nueva": [("        nuevas = fichas_nuevas(memory_dir, slug, pid, pa) if slug else []",
                                 "        nuevas = []")],
    "vigente-sin-marca": [("        if m_ret and m_ret.group(1) != slug and m_ret.group(1) not in nuevas:",
                           "        if False:")],
    "vigente-sin-tarjeta-mod": [("    m_mod = TARJETA_MOD.match(texto)", "    m_mod = None")],
    "vigente-mismo-dia-sin-mtime": [("        if fecha_base and n[:10] == fecha_base and mtime <= mtime_base:",
                                     "        if False:")],
    # checkpoint-audit.py
    "audit-sin-paso-compartido": [("        if compartido:", "        if False:")],
    "audit-compartido-cualquier-dia": [('fecha_ficha + "-*.md"', '"*.md"')],
    # checkpoint-close-guard.sh
    "guard-sin-compartido": [("        if avisos_compartido:", "        if False:")],
    # print-pendiente-opcional.py
    "opcional-con-alta": [("        elegidos = vencidos[:2]",
                           "        elegidos = vencidos[:2] or [p for p in vivos if p[2] == \"Alta\"][:1]")],
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
