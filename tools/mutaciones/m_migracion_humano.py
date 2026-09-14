import io, sys
# Quita la entrega A LA PERSONA del aviso de migracion, dejando solo `out` (additionalContext),
# que lo lee el agente y nadie mas. Es el fallo que 2.17.0 arreglo para los pendientes y 2.21.0
# para la deriva, y que aqui reaparecio: ha cambiado un fichero DEL REPO del usuario y quien
# tiene que correr el `git rm --cached` es una persona.
#
# p-bd9a53b794: la decision de que es persona-worthy se movio de session-start.sh (un grep por
# CONTENIDO del aviso, en DOS sitios distintos que se podian desincronizar) a journal-compact.py,
# que ahora rotula sus propios avisos con una linea `HUMAN-EVENT: <slug>`. session-start.sh
# reconoce el slug UNA vez (escalar_avisos_humanos()) y ahi vive el texto que lee la persona; por
# eso este mutador ya no toca el texto en session-start.sh, toca el rotulo en origen — quitarlo
# es la forma de simular "la persona deja de enterarse" sin tocar el texto que otros asertos
# (git pull / rm -r --cached en la salida cruda del compactador) tambien verifican.
# Tiene que caer "el canal a la persona lo lleva" — el aserto que mira el campo systemMessage del
# JSON, no que la salida traiga algun texto (el resto de prints de _migrar_gitignore_journal
# siguen igual, asi que el agente sigue viendo el aviso).
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = '''    print("HUMAN-EVENT: gitignore-migrado")
'''
n = s.count(viejo)
s = s.replace(viejo, "")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
