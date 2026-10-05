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
    # camino del deny (ronda 1 del adversario)
    "redireccion-separa": [
        ('        if es_op and ("<" in t or ">" in t):', "        if False:")],
    "sin-heredoc": [
        ("                m = _HEREDOC.match(c, i)", "                m = None")],
    "comentario-no-corta": [
        ('            if ch == "#" and (i == 0 or c[i - 1] in " \\t\\n;&|()"):', "            if False:")],
    "interprete-sin-ruta": [
        ('                if "/" in t or "\\\\" in t or t.startswith("."):', "                if True:")],
    "sin-bash-c": [
        ("                        extra += segmentos(s[k + 1], _prof + 1)", "                        pass")],
    "sin-sustituciones": [
        ("            extra += segmentos(sub, _prof + 1)", "            pass")],
    "descriptor-es-programa": [
        ("            if len(cur) == 1 and cur[0].isdigit():", "            if False:")],
    "vista-en-cualquier-parte": [
        ("    m = _VISTA_FIN.search(lineas[-1]) if lineas else None",
         '    m = re.search(r"regla-vista:([A-Za-z0-9][A-Za-z0-9._-]*#[0-9]+)", comando or "")')],
    "freno-truthy": [
        ('            if r.get("freno") is True and r["id"] not in estado["frenos"]:',
         '            if r.get("freno") and r["id"] not in estado["frenos"]:'),
        ('                and isinstance(r.get("freno"), bool) and isinstance(r.get("n", 0), int)',
         '                and isinstance(r.get("n", 0), int)')],
    "estado-ilegible-vacio": [
        ("        raise EstadoIlegible(ruta)", '        return {"llamadas": 0, "vistas": {}, "frenos": []}')],
    "sin-session-compartida": [
        ('        sid = datos.get("session_id")', '        sid = datos.get("session_id") or "sin-sesion"')],
    "sin-lock": [
        ("        if not _tomar_lock(estado_ruta):", "        if False:")],
    "lock-viejo-se-queda": [
        ("                if time.time() - os.stat(lock).st_mtime > LOCK_VIEJO:", "                if False:")],
    # ronda 2 del adversario
    "heredoc-solo-letras": [
        ("""_HEREDOC = re.compile(r"<<-?[ \\t]*(['\\"]?)([A-Za-z0-9_][\\w.-]*)\\1")""",
         """_HEREDOC = re.compile(r"<<-?[ \\t]*(['\\"]?)([A-Za-z_][\\w-]*)\\1")""")],
    "sin-sustitucion-de-proceso": [
        ('                (q is None and (c.startswith("<(", i) or c.startswith(">(", i))):',
         "                False:")],
    "estado-forma-laxa": [
        ("              and all(isinstance(x, str) for x in e[\"frenos\"]))",
         "              and True)")],
    "windows-sin-minusculas": [
        ("        b = b.lower()", "        pass")],
    "sin-especificidad": [
        ('    hits.sort(key=lambda h: (-h[1], len(h[0].get("cmd") or []) + len(h[0].get("path") or []),',
         '    hits.sort(key=lambda h: (-h[1], 0,')],
    "sin-ventana": [
        ("VENTANA = 30 ", "VENTANA = 0 ")],
    "freno-siempre": [
        ('            if r.get("freno") is True and r["id"] not in estado["frenos"]:', '            if r.get("freno") is True:')],
    "sin-regla-vista": [
        ("    return {m.group(1)} if m else set()", "    return set()")],
    "sin-sudo": [
        ('        elif p == "sudo":', '        elif p == "sudo-no":')],
    "sin-rtk": [
        ('        elif p == "rtk":', '        elif p == "rtk-no":')],
    "sin-separadores": [
        ("        elif es_op:", "        elif False:")],
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
        # el lock (mkdir) falla antes en un directorio sin escritura: se apaga tambien para llegar
        # al camino que este aserto vigila (guardar el estado y callarse si no se puede)
        ("        if not _tomar_lock(estado_ruta):", "        if False:"),
        ("            if not _guardar_estado(estado_ruta, nuevo):", "            if not _guardar_estado(estado_ruta, nuevo) and False:")],
    "aviso-por-defecto": [
        ('                                aviso=os.environ.get("ACTION_AVISO") == "1")',
         '                                aviso=True)')],
    # action-recall.sh
    "via-rapida-ignora-optin": [
        ("""  '{"frenos": 0,'*) [ "$AVISO" = 1 ] || exit 0 ;;""", """  '{"frenos": 0,'*) exit 0 ;;""")],
    "stderr-del-hook": [
        ('python3 "$(dirname "$0")/action_match.py" 2>/dev/null)', 'python3 "$(dirname "$0")/action_match.py"; true)')],
    "reenvia-salida-rota": [
        ('python3 "$(dirname "$0")/action_match.py" 2>/dev/null)', 'python3 "$(dirname "$0")/action_match.py" 2>/dev/null; true)')],
    # build-recall-index.py
    "frenos-sin-contar": [
        ('        f.write(json.dumps({"frenos": sum(1 for r in acc if r["freno"]), "reglas": acc},',
         '        f.write(json.dumps({"frenos": 0, "reglas": acc},')],
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
