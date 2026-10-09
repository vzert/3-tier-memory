import io, sys
# Candidatos a pendiente decididos por el usuario (2.53.0). Cada mutacion apaga una pieza y su aserto
# tiene que caer: el pendiente nacido en la sesion sin `guardado`, la pregunta que no se hizo, el
# `_descartado:` como cierre de un defecto, el filtro de --solo-snippet, y en el hook de cierre el
# conteo de AskUserQuestion respondidos (sin pasarlo, o contando un modal rechazado).
#
# Uso: m_candidatos.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # checkpoint-audit.py
    "sin-origen": [
        ("            sin_si = sorted(i for i, o in origen_c.items() if o == slug and i not in guardados)",
         "            sin_si = []")],
    "sin-pregunta": [
        ("            if preguntas_usuario == 0:", "            if False:")],
    "descartado-no-cierra": [
        ("            if not ids_b and not evid and not desc:", "            if not ids_b and not evid:")],
    "solo-snippet-sin-candidatos": [
        ('        return [x for x in h if x.clave.startswith(("snippet.", "bugs.", "pendientes.candidatos"))',
         '        return [x for x in h if x.clave.startswith(("snippet.", "bugs."))')],
    # checkpoint-close-guard.sh
    "guard-no-pasa": [
        ('        extra += ["--preguntas-usuario", str(respondidas)]', "        pass")],
    "guard-error-cuenta": [
        ("        respondidas = sum(1 for i in preguntas if i in resultados and i not in con_error)",
         "        respondidas = sum(1 for i in preguntas if i in resultados)")],
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
