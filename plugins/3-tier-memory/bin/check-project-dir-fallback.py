#!/usr/bin/env python3
"""
3-tier-memory plugin: la ruta del proyecto en los bloques bash de templates/ y commands/.

Por que existe: CLAUDE_PROJECT_DIR llega VACIA a las llamadas Bash del agente (medido
2026-09-24), y el shell no conserva variables de una llamada a la siguiente. 2.39.1 arreglo a
mano los bloques que lo ignoraban, con un recorrido de un solo uso. El primer barrido buscaba una
sola grafia (`ENCODED=$(echo "$CLAUDE_PROJECT_DIR"`) y solo en templates/; un adversario encontro
cinco bloques mas en commands/ con otras formas ($PROJECT_DIR en mkdir, cat >, if -f). Este
script recorre CADA bloque bash por construccion, no por grafia.

Reglas, por bloque bash:
  R1 `$CLAUDE_PROJECT_DIR` sin respaldo: vale `${CLAUDE_PROJECT_DIR:-...}`; falla la forma
     desnuda, `${CLAUDE_PROJECT_DIR}`, el respaldo vacio `${CLAUDE_PROJECT_DIR:-}` (calla a
     `set -u` pero sigue dando vacio) y cualquier otro operador.
  R2 `$PROJECT_DIR` usada sin definirla antes en el MISMO bloque (`PROJECT_DIR=` al inicio de
     una linea previa o de la misma linea). Definirla en otro bloque no cuenta: es otra llamada.

Bloque bash = fence (``` o ~~~, con sangria o sin ella) cuya primera palabra de info es bash, sh,
shell o zsh. Los bloques sin etiqueta NO se revisan: hoy solo traen prosa o salida de ejemplo
(migrate "[MISSING] ... $CLAUDE_PROJECT_DIR/...", audit-3t "Read: <$CLAUDE_PROJECT_DIR>/...").
Un comando para ejecutar va en un bloque ```bash. Los bloques no-shell (````markdown y demas) se
recorren por dentro: un ```bash anidado en una plantilla de ficha tambien cuenta.

No quita comentarios ni heredocs: marca de mas antes que de menos.

Usage:
    check-project-dir-fallback.py [RUTA ...]    (ficheros .md o directorios; por defecto
                                                  templates/ y commands/ del plugin)

Output: una linea `<fichero>:<linea>: R1|R2 <texto>` por fallo y una linea RESUMEN.
Exit 0 sin fallos, 1 con fallos, 2 si una ruta no existe.
"""
# sella-huellas: no (solo lee y reporta)
import os
import re
import sys

# UTF-8 en stdout y stderr: ver check-wikilinks.py.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

SHELL = {"bash", "sh", "shell", "zsh"}
FENCE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
R1 = re.compile(r"\$CLAUDE_PROJECT_DIR\b|\$\{CLAUDE_PROJECT_DIR(?!:-[^}])")
R2_USO = re.compile(r"(?<![A-Za-z0-9_])\$\{?PROJECT_DIR\b")
R2_DEF = re.compile(r"^\s*(export\s+)?PROJECT_DIR=")


def bloques(lineas, base):
    """(info, n_linea_1a_del_cuerpo, cuerpo) de cada fence; recursivo en los no-shell."""
    i = 0
    while i < len(lineas):
        m = FENCE.match(lineas[i])
        if not m or (m.group(1)[0] == "`" and "`" in m.group(2)):
            i += 1
            continue
        marca, info = m.group(1), m.group(2).strip()
        palabra = info.split()[0].lower() if info else ""
        j = i + 1
        while j < len(lineas):
            c = FENCE.match(lineas[j])
            if c and c.group(1)[0] == marca[0] and len(c.group(1)) >= len(marca) \
                    and not c.group(2).strip():
                break
            j += 1
        cuerpo = lineas[i + 1:j]
        if palabra in SHELL:
            yield palabra, base + i + 1, cuerpo
        else:
            yield from bloques(cuerpo, base + i + 1)
        i = j + 1


def revisar(ruta):
    with open(ruta, encoding="utf-8") as f:
        lineas = f.read().split("\n")
    fallos = []
    n = 0
    for _info, ini, cuerpo in bloques(lineas, 0):
        n += 1
        definida = False
        for k, linea in enumerate(cuerpo):
            num = ini + k + 1
            if R2_DEF.match(linea):
                definida = True
            if R1.search(linea):
                fallos.append((num, "R1", linea.strip()))
            if not definida and R2_USO.search(linea):
                fallos.append((num, "R2", linea.strip()))
    return n, fallos


def main(args):
    if not args:
        raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        args = [os.path.join(raiz, "templates"), os.path.join(raiz, "commands")]
    ficheros = []
    for a in args:
        if os.path.isdir(a):
            ficheros += sorted(os.path.join(a, x) for x in os.listdir(a) if x.endswith(".md"))
        elif os.path.isfile(a):
            ficheros.append(a)
        else:
            print(f"no existe: {a}", file=sys.stderr)
            return 2
    total_bloques = 0
    total_fallos = 0
    for f in ficheros:
        n, fallos = revisar(f)
        total_bloques += n
        for num, regla, texto in fallos:
            print(f"{f}:{num}: {regla} {texto[:120]}")
        total_fallos += len(fallos)
    print(f"RESUMEN {len(ficheros)} ficheros, {total_bloques} bloques shell, {total_fallos} fallos")
    return 1 if total_fallos else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
