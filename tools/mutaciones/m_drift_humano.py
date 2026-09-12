import io, sys
# Quita el DIFERIMIENTO del aviso de deriva: vuelve a `human()`, que emit_output descarta cuando
# no hay nadie delante (clear/compact, agente de Paperclip, corrida no atendida). Como
# --check-drift re-sella al detectar, ese aviso se consume para siempre sin que lo lea nadie.
# Es el estado de 2.21.1, que arreglo el canal solo para startup|resume.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = '      defer_human "⚠ MEMORIA: un indice de memory/'
n = s.count(viejo)
s = s.replace(viejo, '      human "⚠ MEMORIA: un indice de memory/')
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
