import io, re, sys
# Destruye el CRLF al escribir. Los asertos que cuentan CR POR BYTES tienen que verlo; los que lo
# contaban con `grep` no lo veian en Git Bash, que es por lo que se cambiaron.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
n = len(re.findall(r"\.write\(", s))
s = re.sub(r"\.write\(([A-Za-z_][A-Za-z0-9_]*)\)",
           r".write(\1.replace(chr(13)+chr(10), chr(10)))", s)
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} escrituras envueltas")
