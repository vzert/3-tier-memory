import io, sys
# Codigo en linea antes de la regla (2.63.30, p-274c87b575): regla_reescribible de journal-compact.py
# cambia cada tramo de codigo en linea por una letra antes de buscar una valla o HTML. Cada mutacion
# apaga una pieza y su aserto de la seccion 24 de test-learning-update.sh tiene que caer (desde 2.69.2,
# casos donde el codigo abre la linea: a mitad de linea una valla ya no cuenta): que se quite
# el codigo, que se cambie por una letra y no se borre, y que la tira de cierre tenga el mismo largo.
#
# Uso: m_codigo_en_linea.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "sin-codigo-en-linea": [
        ('ABRE_BLOQUE.search(CODIGO_EN_LINEA.sub("c", x))', 'ABRE_BLOQUE.search(x)')],
    "codigo-borrado": [
        ('CODIGO_EN_LINEA.sub("c", x)', 'CODIGO_EN_LINEA.sub("", x)')],
    "cierre-de-otro-largo": [
        (r'.*?(?<!`)\1(?!`)")', r'.*?(?<!`)`+(?!`)")')],
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
