import io, sys
# Mete el hash del bloque ACTUAL en la lista de superados: es el error que cometera la proxima
# version que cambie GITIGNORE_JOURNAL y se olvide de sacar su propio hash. El efecto es que el
# compactador reescribe el fichero en CADA pasada — no corrompe nada, pero remueve el mtime y
# mete ruido en el detector de deriva, y nadie lo notaria sin un aserto.
# Tiene que caer "no re-migra en la pasada siguiente". Si no cae, ese aserto no mide el cinturon.
import hashlib, re
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
cuerpo = re.search(r'GITIGNORE_JOURNAL\s*=\s*"""\\\n(.*?)"""', s, re.S).group(1)
h = hashlib.sha256(cuerpo.encode("utf-8")).hexdigest()
viejo = "GITIGNORE_JOURNAL_SUPERADOS = (\n"
n = s.count(viejo)
s = s.replace(viejo, viejo + '    "%s",\n' % h)
# ...y quita el cinturon, que es justo lo que este descuido tenia que activar
s = s.replace("""    if digest == hashlib.sha256(GITIGNORE_JOURNAL.encode("utf-8")).hexdigest():""",
              """    if False:""")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
