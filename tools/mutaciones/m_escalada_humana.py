import io, sys
# Los puntos de escalada a persona que solo se habian probado a mano (p-667f76a40e): en la ronda 2
# del adversario de p-bd9a53b794 (2026-09-14) se mutaron en un temporal y no quedaron en ningun
# arnes. El cuarto punto, el rotulo gitignore-migrado, ya lo cubre m_migracion_humano.py.
#
# Dos piezas por aviso: el ROTULO en journal-compact.py (sin el, session-start.sh no sabe que el
# aviso es para la persona) y la LLAMADA en session-start.sh (sin ella, el rotulo no se lee). Hay
# dos llamadas, una por cada salida del compactador (JOURNAL_OUT y DRIFT_OUT), y cada una tiene que
# tumbar un aserto distinto: si ambas tumbaran el mismo, una de las dos podria faltar sin que se note.
#
# Uso: m_escalada_humana.py <fichero> <mutacion>
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "rotulo-fuera-de-banda": [
        ('    print("HUMAN-EVENT: fuera-de-banda")\n', "")],
    "rotulo-linea-base-ilegible": [
        ('    print("HUMAN-EVENT: linea-base-ilegible")\n', "")],
    # `:` y no una linea vacia: el `if` que la contiene quedaria con el cuerpo solo de `out`, que
    # sigue siendo bash valido, pero asi el hueco se ve en un diff de la copia.
    "llamada-journal-out": [
        ('    escalar_avisos_humanos "$JOURNAL_OUT"\n', "    : # mutado\n")],
    "llamada-drift-out": [
        ('    escalar_avisos_humanos "$DRIFT_OUT"\n', "    : # mutado\n")],
}

p, nombre = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
if nombre not in M:
    print(f"0 sust: mutacion desconocida «{nombre}»")
    sys.exit(0)
s = io.open(p, encoding="utf-8", newline="").read()
# newline="" conserva los finales de linea del archivo: en el checkout de Windows (autocrlf) son
# CRLF y un patron con "\n" a secas no calza (CI de 5304798: las 4 SIN PROBAR solo en windows).
if "\r\n" in s:
    M[nombre] = [(v.replace("\n", "\r\n"), n.replace("\n", "\r\n")) for v, n in M[nombre]]
cuentas = [s.count(viejo) for viejo, _ in M[nombre]]
if cuentas != [1] * len(cuentas):
    print(f"0 sust de {nombre} (cada sustitucion calza {cuentas} veces; se exige 1)")
    sys.exit(0)
for viejo, nuevo in M[nombre]:
    s = s.replace(viejo, nuevo)
io.open(p, "w", encoding="utf-8", newline="").write(s)
print(f"{len(cuentas)} sust de {nombre}")
