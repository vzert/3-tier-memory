import io, sys
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = "print(json.load(sys.stdin).get('cwd',''))"
n = s.count(viejo)
s = s.replace(viejo, "print((json.load(sys.stdin).get('cwd','') or '') + '/ROTO')")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sust en la rama python del cwd")
