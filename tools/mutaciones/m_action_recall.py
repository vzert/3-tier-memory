import io, sys
# Recall en el momento de la accion (F5 del plan de ciclo de vida de learnings): action_match.py y
# el indice de accion de build-recall-index.py. Cada mutacion apaga una pieza y su aserto de
# test-action-recall.sh tiene que caer.
#
# Uso: m_action_recall.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # action_match.py
    "sin-especificidad": [
        ('    hits.sort(key=lambda h: (-h[1], len(h[0].get("cmd") or []) + len(h[0].get("path") or []),',
         '    hits.sort(key=lambda h: (-h[1], 0,')],
    "sin-ventana": [
        ("VENTANA = 30 ", "VENTANA = 0 ")],
    "freno-siempre": [
        ('            if r.get("freno") and r["id"] not in estado["frenos"]:', '            if r.get("freno"):')],
    "sin-regla-vista": [
        ('    return set(_VISTA.findall(comando or ""))', "    return set()")],
    "sin-sudo": [
        ('        elif p == "sudo":', '        elif p == "sudo-no":')],
    "sin-rtk": [
        ('        elif p == "rtk":', '        elif p == "rtk-no":')],
    "sin-separadores": [
        ('        if t in _SEPARADORES or (t and set(t) <= set("&|;()<>")):', '        if t == ";":')],
    "sin-palabras-shell": [
        ('_SHELL = {"while", "until", "if", "then", "do", "else", "elif", "!", "time", "nohup", "exec",',
         '_SHELL = {"while", "until", "if", "then", "else", "elif", "!", "nohup", "exec",')],
    "sin-tope-chars": [
        ("MAX_CHARS = 1500 ", "MAX_CHARS = 100000 ")],
    "edit-frena": [
        ('    if tool == "Bash":', '    if True:')],
    "path-sin-sufijo": [
        ('    return any(fnmatch.fnmatchcase(ruta, p) or fnmatch.fnmatchcase(ruta, "*/" + p) for p in pats)',
         "    return any(fnmatch.fnmatchcase(ruta, p) for p in pats)")],
    "estado-sin-guardar-habla": [
        ("        if not _guardar_estado(estado_ruta, nuevo):", "        if not _guardar_estado(estado_ruta, nuevo) and False:")],
    # build-recall-index.py
    "indice-con-retiradas": [
        ("            if not m or learning_marks.regla_retirada(m.group(2)):", "            if not m:")],
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
