import io, sys
# learning.retire / learning.add --supersedes y sus lectores (2.45.0, F2 del plan de ciclo de vida de
# learnings). Cada mutacion apaga una pieza y su aserto de test-learning-retire.sh tiene que caer:
# el filtro del recall, la validacion de --por, el ciclo, que learning.update conserve el marcador
# (y su replay), que el Quick Reference no reutilice un numero, que --supersedes compruebe el Quick
# Reference ANTES de escribir el topic, que el marcador entre comillas invertidas no cuente, la
# cabecera que retira un topic entero y que el pie del recall dependa de RECALL_PIE.
#
# Uso: m_learning_retire.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # build-recall-index.py
    "recall-sin-filtro": [
        ("                    if not learning_marks.regla_retirada(m.group(1)):", "                    if True:")],
    # journal-compact.py
    "por-sin-validar": [
        ("            comprobar_por(lines, start, related, por, n, donde)", "            pass")],
    "ciclo-sin-detectar": [
        ("        if propio is not None and learning_marks.retirada_por(tp) == propio:", "        if False:")],
    # Desde 2.48.0 (F4) la linea final de learning.update es cuerpo + marca + disparadores.
    "update-pierde-marca": [
        ('        marca = "" if (text and learning_marks.regla_retirada(text)) else learning_marks.sufijo_marca(viejo)',
         '        marca = ""')],
    "replay-update-retirada": [
        ("        if pn and (normalize_text(t) == pn or normalize_text(learning_marks.sin_marca(t)) == pn):",
         "        if pn and normalize_text(t) == pn:")],
    "retire-replay-sin-numero": [
        ("        if len(h) == 1 and learning_marks.regla_retirada(rule_text(lines[h[0]])[1]):", "        if False:")],
    "add-no-ve-retirada": [
        ("    return normalize_text(t) == text or normalize_text(learning_marks.sin_marca(t)) == text",
         "    return normalize_text(t) == text")],
    "supersedes-replay-tras-update": [
        ("                    if existe is None and por_r and len(reglas_numero(lines, start, related, por_r)) == 1:",
         "                    if False:")],
    "fila-antes-de-validar": [
        ("    if not sup:", "    if True:")],
    "qr-reutiliza-numero": [
        ('insert_at_section_end(ilines, s0, s1, f"{max(qnums) + 1 if qnums else 1}. {q}")',
         'insert_at_section_end(ilines, s0, s1, f"{max([n for n, _ in (rule_text(l) for l in ilines[s0:s1]) if n] or [0]) + 1}. {q}")')],
    "supersedes-qr-tarde": [
        ("                quitar_qr = quickref_a_quitar(read_lines(ipath), qp, retirada_ya)", "                pass"),
        ("    if q or quitar_qr:",
         "    if qp and sup: quitar_qr = quickref_a_quitar(read_lines(ipath), qp, False)\n    if q or quitar_qr:")],
    # learning_marks.py
    "marca-en-backticks": [
        ("        if not any(a <= m.start() < b for a, b in spans):", "        if True:")],
    "cabecera-ignorada": [
        ("            return bool(_CABECERA.match(linea))", "            return False")],
    # recall.sh
    "indice-viejo-sirve": [
        ('elif [ "$BUILDER" -nt "$INDEX" ] || [ "$(dirname "$BUILDER")/learning_marks.py" -nt "$INDEX" ]; then',
         "elif false; then")],
    # recall_rank.py
    "pie-siempre": [
        ("        ancla = ancla_retiro(u) if emit else None", "        ancla = ancla_retiro(u)")],
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
