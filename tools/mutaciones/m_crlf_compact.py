import io, re, sys
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
n = len(re.findall(r"\.write\(", s))
s = re.sub(r"\.write\(([A-Za-z_][A-Za-z0-9_]*)\)",
           r".write(\1.replace(chr(13)+chr(10), chr(10)) if isinstance(\1,str) else \1)", s)
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} escrituras envueltas")
