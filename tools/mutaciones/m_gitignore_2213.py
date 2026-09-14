import io, re, sys
# Quita el SEGUNDO hash de GITIGNORE_JOURNAL_SUPERADOS -el del cuerpo de 2.21.3, 38670c0- como si
# una edicion futura de la tupla hubiera perdido esa entrada por descuido. Sin un aserto que
# ejercite el cuerpo de 2.21.3, esto pasaba la suite en verde: solo el primer hash (2.21.0-2.22.1)
# estaba probado.
# Tiene que caer "migra el bloque de 2.21.3". Si no cae, la tupla puede perder una entrada sin que
# nadie lo note.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
m = re.search(r'(GITIGNORE_JOURNAL_SUPERADOS = \(\n\s*"[0-9a-f]{64}",\n)(\s*"[0-9a-f]{64}",\n)(\))', s)
n = 1 if m else 0
if m:
    s = s.replace(m.group(0), m.group(1) + m.group(3))
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
