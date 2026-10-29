import io, sys
# Valla solo al principio de la linea (2.69.2, p-f30ff01da5): ABRE_BLOQUE de journal-compact.py
# cuenta una valla solo tras sangria, `>` o marcadores de lista, y regla_reescribible niega una
# regla cuyo propio texto abre una valla. Cada mutacion apaga una pieza y su aserto de la seccion 25
# de test-learning-update.sh tiene que caer: el ancla, los marcadores de lista y la regla-valla.
#
# Uso: m_valla_inicio.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "valla-en-cualquier-sitio": [
        (r'ABRE_BLOQUE = re.compile(r"^(?:[ \t>]|(?:[-*+]|\d{1,9}[.)])[ \t])*(?:```|~~~)|',
         r'ABRE_BLOQUE = re.compile(r"(?:```|~~~)|')],
    "sin-marcadores-de-lista": [
        (r'ABRE_BLOQUE = re.compile(r"^(?:[ \t>]|(?:[-*+]|\d{1,9}[.)])[ \t])*(?:```|~~~)|',
         r'ABRE_BLOQUE = re.compile(r"^[ \t>]*(?:```|~~~)|')],
    "regla-valla-pasa": [
        ('    if ABRE_BLOQUE.match(CODIGO_EN_LINEA.sub("c", lines[i])):', '    if False:')],
}

p, nombre = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
if nombre not in M:
    print(f"0 mutacion desconocida: {nombre}")
    sys.exit(0)
with io.open(p, encoding="utf-8", newline="") as fh:
    s = fh.read()
n = 0
for viejo, nuevo in M[nombre]:
    c = s.count(viejo)
    if c != 1:
        print(f"0 sustituciones (el patron aparece {c} veces)")
        sys.exit(0)
    s = s.replace(viejo, nuevo)
    n += 1
with io.open(p, "w", encoding="utf-8", newline="") as fh:
    fh.write(s)
print(f"{n} sustituciones")
