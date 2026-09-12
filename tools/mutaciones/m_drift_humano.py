import io, sys
# Quita la guarda `hay_lector()` de la ruta --check-drift del compactador: vuelve a detectar,
# anotar y RE-SELLAR en sesiones donde nadie va a leer el aviso (agente de Paperclip, corrida no
# atendida, clear/compact). Como --check-drift re-sella al detectar, la deriva se consume para
# siempre sin que la lea nadie.
# La guarda estuvo en session-start.sh (2.21.4) y eso dejaba fuera al OTRO llamante, el
# PostToolUse de Bash. Por eso vive aqui, y por eso esta mutacion tiene que tumbar los asertos de
# LOS DOS caminos.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = """        if not hay_lector():
            sys.exit(0)
"""
n = s.count(viejo)
s = s.replace(viejo, "")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
