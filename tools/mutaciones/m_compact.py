import io, sys
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = "        fh.write(datos)"
n = s.count(viejo)
s = s.replace(viejo, '        fh.write(datos + "\\n")')
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sust en la escritura atomica")
