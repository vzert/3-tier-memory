import io, sys
# El hilo de pendientes (2.57.0, p-b282a8cfc4). Cada mutacion apaga una pieza de la regla de Victor
# y su aserto de test-hilo-pendientes.sh tiene que caer: (1) la liga al nacer y su guardia contra
# fichas de otra sesion; el sello (campo partido, snippet pegado, saltos); (2) el cierre recursivo;
# (3) el empate nuevo/heredado y el heredado saltado, y el chequeo del audit; (4) el paso recibido
# en el hilo; (5) la Baja solo sin Alta ni Media, y `quedan N`.
#
# Uso: m_hilo.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # journal-emit.py
    "liga-sin-auto": [("auto = [x for x in paso_recibido(origen, memory_dir, a.transcript)",
                       "auto = [x for x in []")],
    "liga-sin-guardia": [("if transcript and not af.ficha_de_la_sesion(", "if False and not af.ficha_de_la_sesion(")],
    # pendientes_afines.py
    "campo-una-linea": [("if not sig.strip() or ETIQUETA.match(sig):", "if True:")],
    "pasted-sin-quitar": [('texto = PASTED.sub("", texto).strip()', "texto = texto.strip()")],
    "guardia-sin-escritura": [("and escribio_la_ficha(transcripcion, os.path.basename(ficha_path))",
                               "and (True or escribio_la_ficha(transcripcion, os.path.basename(ficha_path)))")],
    "ruta-por-sufijo": [('if b.get("name") in ESCRIBE and (ruta == "sessions/" + nombre',
                         'if b.get("name") in ESCRIBE and (ruta.endswith("sessions/" + nombre)')],
    "leer-cuenta-como-escribir": [('ESCRIBE = ("Write", "Edit", "MultiEdit")', 'ESCRIBE = ("Write", "Edit", "MultiEdit", "Read")')],
    "hilo-sin-cierre": [('if p["id"] not in miembros and ids_rel & miembros:', "if False:")],
    "hilo-sin-recibido": [('miembros = set(heredados) | nuevos | ids_pp | {x for x in paso_rec if x.startswith("p-")}',
                           "miembros = nuevos | ids_pp")],
    "empate-sin-nuevo": [('return 1 if p["id"] in nuevos else 2', "return 2")],
    "empate-sin-saltos": [('if p["id"] not in nuevos and salt.get(p["id"], 0) >= 2:', "if False:")],
    "baja-con-alta": [("extras = (altas_medias or elegibles)[:MAX_AFINES]", "extras = elegibles[:MAX_AFINES]")],
    # Que puede ser extra (2.61.0): pendientes_afines.motivo_no_extra y extras_y_quedan.
    "extras-sin-citados": [("citados = citados_fuera_del_paso(ficha_texto)", "citados = set()")],
    "extras-sin-no-repitas": [('for inicio in ("terminas cuando:", "no repitas:"):',
                               'for inicio in ("terminas cuando:",):')],
    "extras-sin-vivo": [("    if EN_VIVO.search(t):", "    if False:")],
    "extras-sin-ok": [("    if ESPERA_OK.search(t):", "    if False:")],
    "extras-vivo-laxo": [(r'r"\b(?:confirmar|verificar|probar|comprobar|medir|validar)\s+(?:\S+\s+){0,3}?"',
                          r'r"\b(?:confirmar|verificar|probar|comprobar|medir|validar)\b[^.;]{0,80}?\b"')],
    "extras-ok-con-ajena": [("    if ESPERA_OK.search(t):", "    if ESPERA_OK.search(t) or ESPERA_AJENA.search(t):")],
    "extras-filtra-quedan": [('return extras, [p for p in resto if p["id"] not in vistos]',
                              'return extras, [p for p in elegibles if p["id"] not in vistos]')],
    "sin-quedan": [("    if quedan:", "    if False:")],
    # stamp-hilo.py
    "sello-sin-guardia": [('if not af.ficha_de_la_sesion(ficha, trans, os.path.splitext(os.path.basename(trans))[0]):',
                           "if False:")],
    "saltos-sin-previo": [("salt = {i: previos.get(i, 0) + 1", "salt = {i: 0 + 1")],
    # print-como-retomar.py
    "print-sin-slug": [("                                        slug=slug)", "                                        slug=None)")],
    # checkpoint-audit.py
    "audit-todos-los-ids": [("citados = ID_PENDIENTE.findall(pp)[:1]", "citados = ID_PENDIENTE.findall(pp)")],
    "audit-sin-hilo": [('if mejor is not None and mejor <= rango[primero["id"]]:', "if True:")],
    # El marco del Proximo paso (2.60.0): pendientes_afines.senales_marco, el audit y el hook.
    "marco-sin-espera": [("m = ESPERA_AJENA.search(_sin_tildes(paso))", "m = None")],
    "marco-sin-ids": [("    if len(ids) >= 2:", "    if len(ids) >= 99:")],
    "marco-con-ver-tambien": [('ids = sorted(set(ID_P.findall(VER_TAMBIEN.sub("", paso))))', "ids = sorted(set(ID_P.findall(paso)))")],
    "marco-sin-lista": [("if len(set(ITEM_LISTA.findall(paso))) >= 2:", "if False:")],
    "marco-sin-largo": [("    if len(paso) > LARGO_AVISO:", "    if False:")],
    "marco-con-tildes": [("m = ESPERA_AJENA.search(_sin_tildes(paso))", "m = ESPERA_AJENA.search(paso)")],
    "marco-primera-linea": [("senales = af.senales_marco(entero)", "senales = af.senales_marco(pp)")],
    "marco-saltado": [('h.append(Hallazgo(DISENO, "snippet.marco",', 'h.append(Hallazgo(SALTADO, "snippet.marco",')],
    "marco-con-ninguno": [('            and not pp.lower().startswith(("ninguno", "nada accionable")):', "            and True:")],
    "guard-sin-marco": [("        if avisos_marco:", "        if False:")],
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
