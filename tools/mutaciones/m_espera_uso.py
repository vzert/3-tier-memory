import io, sys
# Paso que espera uso real o tiempo (2.71.0, cierre de 2.70.0 del 2026-11-11). Cada mutacion apaga una
# pieza y su aserto de test-espera-uso.sh tiene que caer: (1) pendientes_afines.espera_uso, las dos
# formas y sus excepciones; (2) checkpoint-audit.py, el SALTADO de snippet.proximo_paso y su corte;
# (3) journal-emit.py, el aviso al nacer sin --revisar.
#
# Uso: m_espera_uso.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # pendientes_afines.py
    "espera-sin-tiempo": [("    m = ESPERA_TIEMPO.search(p)", "    m = None")],
    "espera-sin-version": [("        nuevas = sorted(medidas & versiones_publicadas(ficha_texto))",
                            "        nuevas = []")],
    "espera-cualquier-version": [("        nuevas = sorted(medidas & versiones_publicadas(ficha_texto))",
                                  "        nuevas = sorted(medidas)")],
    "espera-banco-cuenta": [("    if not PRUEBA_MONTADA.search(p):", "    if True:")],
    "espera-reload-cuenta": [("    if SESION_NUEVA.search(p):", "    if False:")],
    "espera-sin-ficha-calla": [("        if ficha_texto is None:", "        if False:")],
    # checkpoint-audit.py
    "audit-espera-no-bloquea": [("                if espera:", "                if False:")],
    "audit-espera-sin-corte": [("            if fecha_ficha and fecha_ficha >= DESDE_ESPERA_USO:", "            if True:")],
    # journal-emit.py
    "emit-sin-aviso": [('            avisar_espera_uso(text + " " + (detalle or ""), origen, memory_dir_de(a))', "            pass")],
    "emit-aviso-con-revisar": [("        if not revisar:", "        if True:")],
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
