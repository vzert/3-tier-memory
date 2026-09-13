import io, sys
# Quita la NORMALIZACION de saltos de linea antes de comparar el .journal/.gitignore. El fichero
# esta TRACKEADO en los repos que versionan memory/, asi que en Windows con core.autocrlf vuelve
# del checkout con CRLF: sin normalizar, el compactador no reconoce su propio bloque y la
# migracion no llega jamas a esa plataforma. El fallo es silencioso —no hay error, simplemente no
# pasa nada— asi que sin un aserto que lo mida no se descubre hasta que alguien lo reporta.
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
viejo = 'hashlib.sha256(crudo.replace(b"\\r\\n", b"\\n")).hexdigest()'
n = s.count(viejo)
s = s.replace(viejo, 'hashlib.sha256(crudo).hexdigest()')
io.open(p, "w", encoding="utf-8").write(s)
print(f"{n} sustituciones")
