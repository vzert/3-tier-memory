import io, sys
# Devuelve el aviso de la migracion detras de `if not quiet`. Es como estaba escrito, y un
# adversario lo marco al revisar la publicacion: session-start.sh corre el compactador CON
# --quiet, asi que la ruta REAL de actualizacion reescribia un fichero del repo del usuario sin
# decirselo a nadie, y de paso se tragaba el `git rm --cached` sin el cual su repo queda
# ignorando applied/ y trackeandolo a la vez.
# Tiene que caer "con --quiet el aviso SIGUE saliendo". Si solo cae el caso ruidoso, la suite
# esta midiendo el camino que nadie recorre.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = '''    print(f"JOURNAL .gitignore actualizado: {path}")
    print("  applied/ (eventos ya aplicados) pasa a NO versionarse: su efecto ya esta en los "
          "indices, y el directorio crece con cada checkpoint sin podarse nunca.")
    print("  Si ya lo tenias trackeado, anadirlo al .gitignore no lo des-trackea: "
          "`git rm -r --cached memory/.journal/applied` y commit.")
'''
n = s.count(viejo)
s = s.replace(viejo, '''    if not sys.argv[0]:
        print(f"JOURNAL .gitignore actualizado: {path}")
        print("  aplicado")
''')
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
