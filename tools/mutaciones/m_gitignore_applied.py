import io, sys
# Saca `applied/` del bloque GITIGNORE_JOURNAL: el cambio entero de 2.23.0 deshecho, dejando todo
# lo demas (la migracion, los hashes, el aviso) en su sitio.
# El aserto que tiene que caer es el que le pregunta A GIT —`git check-ignore`—, no el que mira si
# la cadena "applied/" esta en el fichero. Si no cae, es que la suite comprueba la presencia de un
# texto y no el comportamiento, que es exactamente el fallo que este repo lleva ocho releases
# aprendiendo a no cometer.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = """# nunca. Lo que se pierde es un rastro que solo se consulta en la maquina que lo genero.
applied/

"""
n = s.count(viejo)
s = s.replace(viejo, """# nunca. Lo que se pierde es un rastro que solo se consulta en la maquina que lo genero.

""")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
