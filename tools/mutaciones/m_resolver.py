import io, sys
# Rompe la ELECCION del resolutor: la mas BAJA en vez de la mas alta. Si las comparaciones de ruta
# de la suite (`check_ruta`/`norm`) siguen midiendo algo, tienen que verlo.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = "print(max(cands)[1])"
n = s.count(viejo)
io.open(p, "w", encoding="utf-8").write(s.replace(viejo, "print(min(cands)[1])"))
print(f"{n} sust en la eleccion de version")
