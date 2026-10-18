import io, sys
# journal-emit rechaza todo flag que su tipo no lee (p-7ae84c8ef2, 2.63.2). Cada mutacion apaga una
# pieza y su aserto de test-flags-sin-lector.sh tiene que caer: el rechazo, una fila de FLAGS_DE con
# un flag de mas o de menos, los comunes, y la deteccion de "se paso" (con sys.argv a mano no se ven
# las abreviaturas ni `--flag=valor`; mirando el valor no se ve `--x ""`).
#
# Uso: m_flags_sin_lector.py <fichero> <mutacion>
# Patrones de una sola linea, sin "\n": el checkout de Windows trae CRLF (regla 322).
# Cada sustitucion tiene que calzar EXACTAMENTE una vez; si no, imprime 0 -> SIN PROBAR.
M = {
    # journal-emit.py
    "sin-rechazo": [
        ("    if sobran:", "    if False:")],
    "fila-de-mas": [
        ('    "pendiente.add": {"text", ', '    "pendiente.add": {"dias", "text", ')],
    "fila-de-menos": [
        ('    "pendiente.expire": {"id", "dias", "prioridad", "line"},',
         '    "pendiente.expire": {"id", "dias", "prioridad"},')],
    "comunes-de-mas": [
        ('FLAGS_COMUNES = {"type", "memory_dir", "session"}',
         'FLAGS_COMUNES = {"type", "memory_dir", "session", "text"}')],
    "argv-sin-abreviar": [
        ("        return set(vars(ap.parse_args(argv)))",
         "        return {x[2:].split(\"=\")[0].replace(\"-\", \"_\") for x in (argv or sys.argv[1:]) if x.startswith(\"--\")} & {act.dest for act, _ in viejos}")],
    "argv-sin-igual": [
        ("        return set(vars(ap.parse_args(argv)))",
         "        return {x[2:].replace(\"-\", \"_\") for x in (argv or sys.argv[1:]) if x.startswith(\"--\") and \"=\" not in x} & {act.dest for act, _ in viejos}")],
    "por-valor": [
        ("    pasados = flags_pasados(ap)",
         "    pasados = {k for k, v in vars(ap.parse_args()).items() if v and str(v).strip()}")],
}

p, nombre = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
if nombre not in M:
    print(f"0 sust: mutacion desconocida {nombre}")
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
