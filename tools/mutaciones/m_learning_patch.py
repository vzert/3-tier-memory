import io, sys
# Guarda ambiguous de localizar_parche (2.69.3, p-effa16d8b6): con dos reglas que empiezan por el
# prefijo, learning.patch va a cuarentena y no escribe nada. La mutacion se queda con la primera
# que casa, y el aserto de la seccion 8 de test-learning-patch.sh tiene que caer.
#
# Uso: m_learning_patch.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "sin-guarda-ambiguous": [
        ("""        raise Quarantine(f"ambiguous: {len(hits)} reglas de {donde} empiezan por '{prefix[:40]}' — \"""",
         """        hits = hits[:1]; (f"ambiguous: {len(hits)} reglas de {donde} empiezan por '{prefix[:40]}' — \"""")],
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
