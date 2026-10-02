import io, sys
# Dedup al emitir de learning.add (2.47.0, F3 del plan de ciclo de vida de learnings). Cada mutacion
# apaga una pieza y su aserto de test-learning-dedup.sh tiene que caer: stdout limpio, el bloqueo,
# --solo-vecinos sin escribir, la exencion del mismo texto, las retiradas fuera de los vecinos, la
# medida Dice (frente a "comunes / palabras de la nueva"), --decision en el payload, reemplaza:N como
# --supersedes, corrige:N rechazado, el chequeo de forma y el chequeo learnings.decision.
#
# Uso: m_learning_dedup.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # journal-emit.py
    "vecinos-por-stdout": [
        ('        print(f"  {e:>5}  {s:.2f}  {lv.titulo(t)}", file=sys.stderr)',
         '        print(f"  {e:>5}  {s:.2f}  {lv.titulo(t)}")')],
    "sin-bloqueo": [
        ("    if vec and vec[0][0] >= lv.UMBRAL and not decision and not solo_vecinos:", "    if False:")],
    "solo-vecinos-escribe": [
        ("                return                            # no escribe nada: solo la lista para decidir",
         "                pass")],
    "sin-identidad": [
        ("        if t and jc.es_misma_regla(t, text):", "        if False:")],
    "decision-fuera-del-payload": [
        ('                base["payload"]["decision"] = decision', "                pass")],
    "reemplaza-sin-supersedes": [
        ('            sup = int(decision.split(":")[1])     # reemplaza:N es --supersedes N (F2)',
         "            pass")],
    "corrige-sin-citar": [
        ('f"--match-prefix {shlex.quote(pref)} --text "', 'f"--match-prefix \\"{pref}\\" --text "')],
    "corrige-aceptado": [
        ('    if m.group(1) == "corrige":', "    if False:")],
    # learning_vecinos.py
    "retirada-es-vecina": [
        ("    vivas = [(e, t) for e, t in candidatas if not learning_marks.regla_retirada(t)]",
         "    vivas = list(candidatas)")],
    "medida-sobre-la-nueva": [
        ("        s = 2 * sum(idf(w) for w in q & d) / den if den else 0.0",
         "        s = sum(idf(w) for w in q & d) / pq if pq else 0.0")],
    "forma-sin-titulo": [
        ("    if not _FORMA.match(t):", "    if False:")],
    "negrita-impar": [
        ('    if t.count("**") % 2:', "    if False:")],
    "comilla-impar": [
        ('    if t.count("`") % 2:', "    if False:")],
    "titulo-largo": [
        ("    if m and len(m.group(1)) > TITULO_MAX:", "    if False:")],
    # checkpoint-audit.py
    "audit-sin-decision": [
        ('            malas.append(f"{l.strip()[:120]} — sin `decision:` valida")', "            pass")],
    "audit-numero-inexistente": [
        ("            if n not in nums:", "            if False:")],
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
