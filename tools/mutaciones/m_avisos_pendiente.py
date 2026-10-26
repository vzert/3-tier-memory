import io, sys
# Cuatro avisos del pendiente con texto falso (2.64.0, incidente real del 2026-10-24). Cada mutacion
# apaga una pieza y su aserto tiene que caer: (1) el ⚠ del 🔔 (print-pendiente-opcional.py y el
# hook de cierre); (2) el aviso de plan/handoff/ficha editado sin reconciliar (paso_ajeno.py,
# checkpoint-audit.py); (3) el aviso de solape al pendiente.add (journal-emit.py); (4) la pregunta
# en prosa al cierre (checkpoint-close-guard.sh).
#
# Uso: m_avisos_pendiente.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # print-pendiente-opcional.py
    "aviso-siempre": [("    if not hits:", "    if False:")],
    "aviso-en-opcional": [("        if cabecera == CABECERA_HOY:", "        if True:")],
    # checkpoint-close-guard.sh
    "guard-sin-aviso-pendiente": [("        if avisos_pendiente:", "        if False:")],
    "guard-sin-aviso-hilo": [("        if avisos_hilo:", "        if False:")],
    "guard-sin-aviso-prosa": [("        if avisos_prosa:", "        if False:")],
    "prosa-sin-corte-emoji": [("        if any(l.startswith(e) for e in EMOJIS):", "        if False:")],
    "prosa-sin-signo": [('    return ult if ult.endswith("?") and "¿" in ult else ""',
                         '    return ult if ult.endswith("?") else ""')],
    # paso_ajeno.py
    "hilo-sin-update": [("        if ids and not nombra and not (set(ids) & tocados_ids):", "        if ids and not nombra:")],
    "hilo-sin-alta": [("        if ids and not nombra and not (set(ids) & tocados_ids):", "        if ids and not (set(ids) & tocados_ids):")],
    "hilo-alta-suelta": [("        nombra = any(k in cmd for cmd in altas for k in claves)", "        nombra = bool(altas)")],
    "hilo-sin-bash": [("                    if ESCRIBE.search(cmd):", "                    if False:")],
    "hilo-ficha-propia": [("        if m and m.group(1) != propia:", "        if m:")],
    # 2.65.0: id nombrado en la edicion (par real del incidente)
    "hilo-sin-id-nombrado": [("        if sueltos:", "        if False:")],
    "hilo-id-sin-texto-edit": [("                nombrados.append((ruta, set(ID_PEND.findall(txt))))", "                nombrados.append((ruta, set()))")],
    "hilo-id-sin-bash": [('                            nombrados.append(("/memory/plans/" + pl + ".md", set(ID_PEND.findall(cmd))))', "                            pass")],
    "hilo-id-sin-bloqueo": [("    reconciliados = tocados_ids | bloqueados_ids", "    reconciliados = tocados_ids")],
    "hilo-id-con-write": [('for k in ("old_string", "new_string"))', 'for k in ("old_string", "new_string", "content"))')],
    "hilo-id-bash-ficha": [("                        if not BASH_FICHA.search(cmd):", "                        if True:")],
    # checkpoint-audit.py
    "audit-sin-hilo": [("            if sin:", "            if False:")],
    # journal-emit.py
    "solape-sin-aviso": [("        if hallazgos:", "        if False:")],
    "solape-plan-completado": [("                if activo:", "                if True:")],
    "solape-sin-propuesto": [('startswith(("active", "proposed"))', 'startswith(("active",))')],
    "solape-generico": [('        if base.startswith("_") or base in REFS_GENERICAS:', "        if False:")],
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
