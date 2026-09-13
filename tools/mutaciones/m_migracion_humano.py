import io, sys
# Quita la entrega A LA PERSONA del aviso de migracion en session-start.sh, dejando solo `out`
# (additionalContext), que lo lee el agente y nadie mas. Es el fallo que 2.17.0 arreglo para los
# pendientes y 2.21.0 para la deriva, y que aqui reaparecio: ha cambiado un fichero DEL REPO del
# usuario y quien tiene que correr el `git rm --cached` es una persona.
# Tiene que caer "el canal a la persona lo lleva" — el aserto que mira el campo systemMessage del
# JSON, no que la salida traiga algun texto.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = "    if printf '%s' \"$JOURNAL_OUT\" | grep -q '\\.gitignore actualizado'; then"
n = s.count(viejo)
s = s.replace(viejo, "    if false; then")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
