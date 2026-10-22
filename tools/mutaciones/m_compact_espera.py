import io, sys
# 2.63.34 (p-4c4f8274a6): quita la espera del compactador ante un .json ilegible y reciente; un
# emisor viejo vuelve a perder su evento. test-journal-hueco.sh B) debe caer. Con arg "viejo",
# en vez de quitarla la hace eterna (nunca va a cuarentena).
p = sys.argv[1]; modo = sys.argv[2] if len(sys.argv) > 2 else ""
s = io.open(p, encoding="utf-8").read()
if modo == "viejo":
    viejo, nuevo = "        return abs(time.time() - os.path.getmtime(path)) < STALE_SECONDS", "        return True"
else:
    viejo, nuevo = "                if es_reciente(src):", "                if False:"
n = s.count(viejo)
s = s.replace(viejo, nuevo)
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sust en la espera del .json ilegible")
