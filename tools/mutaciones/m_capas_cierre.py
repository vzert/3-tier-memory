import io, sys
# Las capas y los emojis del cierre de /checkpoint-3t (2.44.0). Cada mutacion apaga una pieza y su
# aserto tiene que caer: la capa ➕ solo en el caso 5, la capa 🔔 solo con `_revisar` igual a hoy y
# una sola, el snippet con su cabecera 🔁, el calendario sin fence, el hook exigiendo las cabeceras
# desde el corte, y el audit pidiendo un pendiente a cada recomendacion de research sin marcar.
#
# Uso: m_capas_cierre.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # print-pendiente-opcional.py
    "capa3-sin-gate": [
        ('if not crp.es_caso5(crp.extract_section(ficha_texto) or ""):', "if False:")],
    "hoy-incluye-vencidos": [
        ("hoy_ = sorted([p for p in vivos if p[4] == hoy],",
         "hoy_ = sorted([p for p in vivos if p[4] and p[4] <= hoy],")],
    "hoy-sin-tope": [
        ("cabecera, elegidos = CABECERA_HOY, hoy_[:1]", "cabecera, elegidos = CABECERA_HOY, hoy_[:2]")],
    # print-como-retomar.py
    "sin-cabecera-retomar": [
        ("        print(CABECERA)", "        pass")],
    # print-recordatorios.py
    "calendario-con-fence": [
        ("if not FENCE_LINEA.match(l) and not LEGADO.match(l)]", "if not LEGADO.match(l)]")],
    # checkpoint-close-guard.sh
    "emoji-no-exigido": [
        ("nueva = bool(m_fecha and m_fecha.group(1) >= CORTE_CAPAS)", "nueva = False")],
    "cabecera-rfind": [
        ("_j = inicio_revision(_todo)", "_j = _todo.rfind(REVISION_CABECERA)")],
    "fences-sin-control": [
        ("            if fences > permitidos:", "            if False:")],
    # checkpoint-audit.py
    "reco-sin-dueno-pasa": [
        ('pendientes_reco.append((r, "sin pendiente que la lleve", l.strip()))', "pass")],
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
