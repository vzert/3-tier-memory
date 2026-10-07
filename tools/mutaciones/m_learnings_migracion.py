import io, sys
# Enlace Quick Reference -> regla y learnings-migracion.py (2.51.0, F7 del plan de ciclo de vida de
# learnings). Cada mutacion apaga una pieza y su aserto de test-learnings-migracion.sh tiene que
# caer: la marca que escribe learning.add, la que conserva learning.update, la idempotencia del
# replay, el enlace al topic con numero repetido, la comprobacion del destino y del valor, que el
# recall y el recordatorio la quiten, y del script: el aviso sin lo bloqueado, la comprobacion antes
# de emitir, el prefijo unico, los candidatos con numero repetido, lo decidido y el canal humano.
#
# Uso: m_learnings_migracion.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # journal-compact.py
    "add-sin-marca": [
        ('                marca = learning_marks.comentario_regla_qr(qr_regla) if qr_regla else ""',
         '                marca = ""')],
    "add-duplica": [
        ("            if not any(t and normalize_text(learning_marks.sin_regla_qr(t)) == q",
         "            if not any(t and normalize_text(t) == q")],
    "repetido-numera": [
        ("        if n_regla is not None and len(reglas_numero(lines, s2, r2, n_regla)) == 1:",
         "        if n_regla is not None:")],
    "update-borra-marca": [
        ("                 else learning_marks.sufijo_regla_qr(viejo))", '                 else "")')],
    "sin-comprobar-destino": [
        ("            comprobar_regla_qr(mem, qregla)", "            pass")],
    "compactador-sin-validar": [
        ("            if not learning_marks.valor_regla_qr_valido(qr):", "            if False:")],
    # build-recall-index.py
    "indice-con-marca": [
        ("            s = learning_marks.sin_regla_qr(line.strip())", "            s = line.strip()")],
    # rule-reinject-nudge.sh
    "recordatorio-con-marca": [
        ("        rules.append(sin_regla_qr(s))", "        rules.append(s)")],
    # learnings-migracion.py
    "aviso-cuenta-bloqueadas": [
        ('    sin_marca = [x["qr"] for x in qr if x["marca"] is None and not x["rota"] and not x["bloqueo"]]',
         '    sin_marca = [x["qr"] for x in qr if x["marca"] is None and not x["rota"]]')],
    "aplicar-sin-comprobar": [
        ("            bloqueo = _no_reescribible(compactador(), mem, rid)", '            bloqueo = ""')],
    "prefijo-no-unico": [
        ("        if not any(r.startswith(pc) for r in rivales) or corte >= len(t):", "        if True:")],
    "candidatos-con-repetidos": [
        ("                cand += [(topic if rid in rep else rid, t) for t in ts]",
         "                cand += [(rid, t) for t in ts]")],
    "decididas-ignoradas": [
        ("    sin_disp_vivas = sorted(set(sin_disp) - decididas)", "    sin_disp_vivas = sorted(set(sin_disp))")],
    # session-start.sh
    "aviso-solo-agente": [
        ('      human "$MIGRAR_AVISO"', "      :")],
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
