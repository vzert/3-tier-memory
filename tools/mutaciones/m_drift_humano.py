import io, sys
# Quita la guarda `hay_persona` del aviso de deriva: vuelve a MIRAR (y por tanto a re-sellar) en
# sesiones donde el mensaje a la persona se descarta — clear/compact, agente de Paperclip, corrida
# no atendida. Como --check-drift re-sella al detectar, ese aviso se consume para siempre sin que
# lo lea nadie. Es el estado de 2.21.1.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = '[ -d "$MEMORY_DIR/.journal" ] && hay_persona; then'
n = s.count(viejo)
s = s.replace(viejo, '[ -d "$MEMORY_DIR/.journal" ]; then')
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
