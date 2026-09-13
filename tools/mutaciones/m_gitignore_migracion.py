import io, sys
# Rompe la GUARDA de la migracion del .journal/.gitignore: quita la comprobacion de que el
# contenido sea, entero, un bloque que publicamos nosotros, y lo reescribe siempre. Es la forma
# ingenua de "actualizar a todo el mundo", y se lleva por delante la propiedad que costo dos
# rondas adversariales en 2.21.x: si el usuario lo edito, su version manda.
# Si el CONTROL NEGATIVO ("NO toca el del usuario (un byte basta)") no cae con esto, es que la
# suite solo mira los casos que SI migran, y eso no distingue "migra lo nuestro" de "pisa lo que
# encuentre".
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = """    digest = hashlib.sha256(crudo.replace(b"\\r\\n", b"\\n")).hexdigest()
    if digest not in GITIGNORE_JOURNAL_SUPERADOS:
        return False          # o es el de hoy, o lo toco el usuario: en ambos casos, no se toca
"""
n = s.count(viejo)
s = s.replace(viejo, """    digest = hashlib.sha256(crudo.replace(b"\\r\\n", b"\\n")).hexdigest()
""")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
