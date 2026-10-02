import io, sys
# Disparadores de una regla (2.48.0, F4 del plan de ciclo de vida de learnings). Cada mutacion apaga
# una pieza y su aserto de test-learning-disparadores.sh tiene que caer: el peso de las frases en el
# recall, las frases en el indice, el comentario fuera del texto que se muestra, la conservacion en
# learning.update, el marcador DELANTE del comentario, el rechazo de `--` y la validacion del
# compactador como frontera propia.
#
# Uso: m_learning_disparadores.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # recall_rank.py
    "sin-peso": [
        ("PESO_DISPARADORES = 1.5", "PESO_DISPARADORES = 1.0")],
    # build-recall-index.py
    "frases-sin-indexar": [
        ('            u["kw_disparadores"] = extra', "            pass")],
    "mostrar-comentario": [
        ("    texto = truncate(learning_marks.sin_disparadores(texto) if regla else texto)",
         "    texto = truncate(texto)")],
    # journal-compact.py
    "update-pierde-disparadores": [
        ("                  else learning_marks.sufijo_disparadores(viejo))", '                  else "")')],
    "compactador-sin-validar": [
        ("    d = p.get(\"disparadores\")", "    return")],
    # learning_marks.py
    "marca-detras": [
        ("    return sin_disparadores(texto) + marca + sufijo_disparadores(texto)", "    return texto + marca")],
    "acepta-guiones": [
        ('    if "--" in s or "<" in s or ">" in s or "\\n" in s:', '    if "<" in s or ">" in s or "\\n" in s:')],
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
