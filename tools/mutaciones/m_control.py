import io, sys
# El CONTROL afirma que el arbol de prueba tiene MAS DE UNA candidata, o sea que el patron viejo
# elegia a ciegas. Para probar que discrimina hay que dejar una sola: se muta el FIXTURE, porque
# eso es lo que ese aserto mide.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = "for v in 2.9.0 2.10.0; do"
n = s.count(viejo)
s = s.replace(viejo, "for v in 2.9.0; do")
# y el clon del marketplace, que es la otra candidata
viejo2 = 'mkdir -p "$H/.claude/plugins/marketplaces/mkt/plugins/3-tier-memory/bin"'
n2 = s.count(viejo2)
s = s.replace(viejo2, 'mkdir -p "$H/.claude/plugins/marketplaces/mkt/plugins/3-tier-memory/bin" # (fixture reducido)')
s = s.replace(': > "$H/.claude/plugins/marketplaces/mkt/plugins/3-tier-memory/bin/journal-emit.py"', 'true')
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n}+{n2} reducciones del fixture")
