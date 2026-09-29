import io, sys
# Las 24 mutaciones del contrato de check-project-dir-fallback.py (2.41.4). Corrieron a mano en un
# temporal el 2026-09-29 y no quedaban en ningun arnes (p-ea044c780b): un cambio del checker que
# dejara la suite vacua no se habria notado. Cada una rompe UNA pieza del contrato; el caso de
# mutation-check.sh nombra el aserto que tiene que caer por ella.
#
# Uso: m_contrato_projdir.py <fichero> <mutacion>
# Cada sustitucion tiene que calzar EXACTAMENTE una vez: con cero la mutacion no se aplico, y con
# dos se habria roto algo mas que la pieza que dice romper. En ambos casos imprime 0 -> SIN PROBAR.
M = {
    "r1-sin-quitar-forma": [
        ('NOMBRE_R1.search(linea.replace(FORMA_R1, ""))', "NOMBRE_R1.search(linea)")],
    "r1-apagada": [
        ('if NOMBRE_R1.search(linea.replace(FORMA_R1, "")):', "if False:")],
    "forma-r1-floja": [
        ('FORMA_R1 = "${CLAUDE_PROJECT_DIR:-$PWD}"', 'FORMA_R1 = "${CLAUDE_PROJECT_DIR"')],
    "canonica-ignorada": [
        ("canonica = codigo[0][1].strip(BLANCO) == CANONICA", "canonica = False")],
    "canonica-en-cualquier-linea": [
        ("canonica = codigo[0][1].strip(BLANCO) == CANONICA",
         "canonica = any(l.strip(BLANCO) == CANONICA for _, l in codigo)"),
        ("if pos == 0 and canonica:", "if canonica and linea.strip(BLANCO) == CANONICA:")],
    "canonica-con-comentario": [
        ("canonica = codigo[0][1].strip(BLANCO) == CANONICA",
         "canonica = codigo[0][1].strip(BLANCO).startswith(CANONICA)")],
    "usos-posteriores-libres": [
        ('elif NOMBRE_R2.search(USO_R2.sub("", linea)):', "elif False:")],
    "llave-sin-cerrar": [
        (r'|\$\{PROJECT_DIR\}")', r'|\$\{PROJECT_DIR")')],
    "r3-apagada": [
        ('if "$" in linea or "`" in linea:', "if False:")],
    "r3-sin-backtick": [
        ('if "$" in linea or "`" in linea:', 'if "$" in linea:')],
    "r2-en-comentario-apagada": [
        ("elif NOMBRE_R2.search(linea):", "elif False:")],
    "sin-etiqueta-fuera": [
        ('SHELL = {"", "bash",', 'SHELL = {"bash",')],
    "sin-bloques": [
        ("for ini, cuerpo in bloques(lineas, 0):", "for ini, cuerpo in []:")],
    "strip-en-vez-de-blanco": [
        ("canonica = codigo[0][1].strip(BLANCO) == CANONICA",
         "canonica = codigo[0][1].strip() == CANONICA")],
    "canonica-insegura": [
        ("""CANONICA = 'PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"'""",
         """CANONICA = 'PROJECT_DIR="${CLAUDE_PROJECT_DIR}"'""")],
    "r4-apagada": [
        ('fallos += [(num, "R4", l.strip()) for num, l in codigo if NOMBRE_R4.search(l)]', "pass")],
    "sin-unir-lineas": [
        ("if continua(buf) and not comentario:", "if False:")],
    "barra-par-une": [
        ('return (len(linea) - len(linea.rstrip("\\\\"))) % 2 == 1', 'return linea.endswith("\\\\")')],
    "comentario-continua": [
        ("if continua(buf) and not comentario:", "if continua(buf):")],
    "continuada-como-comentario": [
        ("buf = buf[:-1] + linea",
         'buf = buf[:-1] + linea\n            comentario = comentario or linea.lstrip(BLANCO).startswith("#")')],
    "sin-newline-vacio": [
        ('open(ruta, encoding="utf-8", newline="")', 'open(ruta, encoding="utf-8")')],
    "r4-solo-ifs": [
        ("(?:IFS|set|shopt|setopt|unsetopt|emulate|options)", "(?:IFS)")],
    "r4-sin-set": [
        ("(?:IFS|set|shopt|", "(?:IFS|shopt|")],
    "r4-sin-options": [
        ("|emulate|options)", "|emulate)")],
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
