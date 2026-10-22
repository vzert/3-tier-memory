import io, sys
# checkpoint-close-guard.sh solo toma como ficha un argumento sessions/*.md de print-como-retomar.py
# (2.63.3, p-bea9639b92). La mutacion quita el filtro y el aserto del sed real de
# test-checkpoint-close-guard.sh tiene que caer. `variable-callada` (p-e1799cd04c) deja de tomar la
# ficha de la sesion cuando el argumento es una variable sin resolver ("$SESSION_FILE"): cae el aserto
# de Step 8b. `asigna-ignorada` no expande las asignaciones del comando: cae el aserto del triage.
#
# Uso: m_ficha_sesion.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    "ficha-cualquiera": [
        ("                if f and FICHA_RE.search(f) and (\"$\" not in a or os.path.isfile(f)):",
         "                if f and (\"$\" not in a or os.path.isfile(f)):")],
    "variable-callada": [
        ("                    con_variable = True", "                    pass")],
    "asigna-ignorada": [
        ("                e = expandir(a, asigna) if a else a", "                e = a")],
    # p-0c334693d4: sin la conversion con cygpath caen en Git Bash los asertos "ruta Git Bash"; fuera
    # de Git Bash la suite imprime su SKIP y el caso sale "no evaluable aqui".
    "sin-nativa": [
        ("    ruta = nativa(ruta)", "    pass")],
    # p-47b5252196: las tres formas de la ficha de Step 8b con variable, cada una con su aserto.
    "bash-ignorado": [
        ('    fichas_sesion.extend(escritas_por_bash(_v) if _tipo == "bash" else [_v])',
         '    fichas_sesion.extend([] if _tipo == "bash" else [_v])')],
    "sin-sello-ignorado": [
        ("        or next((f for f in _propias if sin_sello_con_retomar(f)), None)", "        or None")],
    "sin-sello-sin-retomar": [
        ('    return not re.search(r"(?m)^session_id:", texto[:2000]) and seccion(texto, "Como retomar") is not None',
         '    return not re.search(r"(?m)^session_id:", texto[:2000])')],
    "cd-con-punto-y-coma": [
        ('''_RE_CD = re.compile(r"(?:^|[;&|\\n]\\s*)cd\\s+(\\"[^\\"]+\\"|'[^']+'|[^\\s;&|)]+)")''',
         '''_RE_CD = re.compile(r"(?:^|[;&|\\n]\\s*)cd\\s+(\\"[^\\"]+\\"|'[^']+'|\\S+)")''')],
    "barras-solo-slash": [
        ('SESION_RE_G = re.compile(r"(?:^|[/\\\\])memory[/\\\\]sessions[/\\\\][^/\\\\]+\\.md$")',
         'SESION_RE_G = re.compile(r"(?:^|/)memory/sessions/[^/]+\\.md$")')],
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
