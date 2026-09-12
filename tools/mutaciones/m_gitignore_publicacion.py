import io, sys
# Rompe la PUBLICACION ATOMICA del .gitignore del journal: en vez de escribir un temporal
# completo y enlazarlo (una sola operacion: o aparece entero, o no aparece), publica el destino
# primero y escribe dentro. Es exactamente la forma que tenia 2.21.1 y que un adversario marco
# como unsafe: un fallo a mitad deja un fichero truncado que O_EXCL conserva para siempre.
# Si los asertos de "gana exactamente uno" y "el publicado es el fichero ENTERO" no caen con
# esto, es que no miden lo que dicen.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = """    try:
        with open(tmp, "w", encoding="utf-8", newline="\\n") as fh:
            fh.write(GITIGNORE_JOURNAL)
            fh.flush()
            os.fsync(fh.fileno())   # los bytes en disco ANTES de que el fichero sea visible
    except OSError:
        _descartar(tmp)
        return False
"""
n = s.count(viejo)
# publica ANTES de escribir, y trunca el contenido: el fichero existe pero incompleto
s = s.replace(viejo, """    try:
        with open(path, "w", encoding="utf-8", newline="\\n") as fh:
            fh.write(GITIGNORE_JOURNAL[:40])
    except OSError:
        return False
    return True
""")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
