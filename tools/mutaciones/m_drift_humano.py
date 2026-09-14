import io, sys
# Quita la guarda `hay_lector()` de la ruta --check-drift del compactador: vuelve a detectar,
# anotar y RE-SELLAR en sesiones donde nadie va a leer el aviso (agente de Paperclip, corrida no
# atendida, clear/compact). Como --check-drift re-sella al detectar, la deriva se consume para
# siempre sin que la lea nadie.
# La guarda estuvo en session-start.sh (2.21.4) y eso dejaba fuera al OTRO llamante, el
# PostToolUse de Bash. Por eso vive aqui.
#
# 2.24.1 quito la llamada de bash-journal-nudge.sh a --check-drift (ganaba la carrera y se
# comia el aviso real): desde entonces solo queda UN camino que ejecuta esta guarda,
# session-start.sh/journal-drift-nudge.sh. El aserto de test-expire-reopen.sh que la detecta
# es el de "no se toca (no se consume)" via `arranque compact`/Paperclip — no uno sobre
# bash-journal-nudge.sh, que ya no toca la linea base bajo ningun caso.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = """        if not hay_lector():
            sys.exit(0)
"""
n = s.count(viejo)
s = s.replace(viejo, "")
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
