import io, sys
# 2.63.34 (p-4c4f8274a6): vuelve a escribir el evento directo en el .json final, como antes de
# 2.63.34. El compactador que corre en el hueco lo ve vacio; test-journal-hueco.sh A) debe caer.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = '        tmp = os.path.join(pending, f".{name}.tmp")'
n = s.count(viejo)
s = s.replace(viejo, '        tmp = path')
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sust en el temporal del evento")
