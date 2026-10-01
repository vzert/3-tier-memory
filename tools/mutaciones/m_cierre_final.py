import io, sys
# El cierre al FINAL de checkpoint-close-guard.sh (2.43.0): en un turno de /checkpoint-3t el snippet,
# el calendario, 8d y 8e se pegan despues de la revision del cierre. Cuatro piezas, cada una con su
# aserto en test-checkpoint-close-guard.sh: diferir el primer cierre, medir solo tras la revision
# en el cierre reentrante, ensenarle al usuario el cierre que no quedo al final, y la cola.
#
# Uso: m_cierre_final.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "diferido-apagado": [
        ("diferido = bool(por_checkpoint and m_fecha and m_fecha.group(1) >= DESDE_REVISION)",
         "diferido = False")],
    "orden-apagado": [
        ("base = visto_tras_revision if (diferido and reentrante) else visto", "base = visto")],
    "sin-anexo": [
        ("    if anexo:", "    if False:")],
    "sin-cola": [
        ("if bloques and not otros and len(v) - cursor > COLA_MAX:", "if False:")],
}

p, nombre = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
if nombre not in M:
    print(f"0 sust: mutacion desconocida «{nombre}»")
    sys.exit(0)
s = io.open(p, encoding="utf-8", newline="").read()
cuentas = [s.count(viejo) for viejo, _ in M[nombre]]
if cuentas != [1] * len(cuentas):
    print(f"0 sust de {nombre} (cada sustitucion calza {cuentas} veces; se exige 1)")
    sys.exit(0)
for viejo, nuevo in M[nombre]:
    s = s.replace(viejo, nuevo)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print(f"{len(cuentas)} sust de {nombre}")
