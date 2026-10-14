import io, sys
# Filtro de rutas ignoradas de checkpoint-commit.py (issue #11). Un modo por pieza del arreglo:
#   sin-no-index   -> vuelve el check-ignore de antes: applied/ versionado aborta el commit.
#   sin-add-n      -> --no-index a secas: un archivo versionado que casa con un patron se pierde.
#   sin-reintento  -> el `git add -n` no espera al index.lock: con el candado ajeno da por ignorado
#                     lo que no lo esta.
p, modo = sys.argv[1], sys.argv[2]
s = io.open(p, encoding="utf-8").read()
if modo == "sin-no-index":
    viejo, nuevo = '"check-ignore", "--no-index", "-z", "--stdin"', '"check-ignore", "-z", "--stdin"'
elif modo == "sin-add-n":
    viejo, nuevo = "if l.strip() and add_rechaza(l)}", "if l.strip()}"
elif modo == "sin-reintento":
    viejo, nuevo = 'if "index.lock" not in ad.stderr:', "if True:"
else:
    sys.exit(f"modo desconocido: {modo}")
n = s.count(viejo)
io.open(p, "w", encoding="utf-8").write(s.replace(viejo, nuevo))
print(f"{n} sust ({modo})")
