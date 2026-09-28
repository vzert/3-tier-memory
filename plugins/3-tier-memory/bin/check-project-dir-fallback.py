#!/usr/bin/env python3
"""
3-tier-memory plugin: la ruta del proyecto en los bloques de shell de templates/ y commands/.

Por que existe: CLAUDE_PROJECT_DIR llega VACIA a las llamadas Bash del agente (medido
2026-09-24), y el shell no conserva variables de una llamada a la siguiente. 2.39.1 arreglo a
mano los bloques que lo ignoraban; este script impide que el siguiente bloque vuelva a caer.

Es un CONTRATO de formas permitidas, no un analizador de bash. 2.39.3 intentaba decidir "esta
$PROJECT_DIR definida antes de usarse" siguiendo if, heredocs, subshells y funciones, y cada
ronda del adversario rompio otra forma: esa pregunta no tiene fondo sin un parser de bash
completo. Ahora el checker solo compara texto exacto, y las plantillas se escriben para cumplirlo.
Lo que sea seguro pero no calce con el contrato FALLA: se reescribe a la forma permitida.

Contrato, por bloque de shell. Blanco = solo espacio o tabulador (lo que bash separa; un
tabulador vertical o un NBSP delante hacen que la linea no sea una asignacion). "Linea de
comentario" = su primer caracter no blanco es `#` y la linea anterior no acaba en `\\` (una
continuacion convierte esa linea en codigo). Toda otra linea es "de codigo", tambien dentro de
un heredoc o de una cadena de varias lineas.
  R1 En una linea de codigo, CLAUDE_PROJECT_DIR solo aparece como `${CLAUDE_PROJECT_DIR:-$PWD}`,
     texto exacto. Cualquier otra mencion falla, aunque fuera segura.
  R2 Si alguna linea de codigo nombra PROJECT_DIR, la primera linea de codigo del bloque es
     exactamente la linea canonica (sin comentario al final; la nota va en la linea de arriba):
         PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
     y en el resto de lineas de codigo PROJECT_DIR solo aparece como `$PROJECT_DIR` o
     `${PROJECT_DIR}`. Asi quedan fuera, sin analizarlos, reasignar, `unset`, `read`, `local`,
     `${PROJECT_DIR:=...}` y definirla dentro de un if o en otro bloque.
  R3 Una linea de comentario que nombra cualquiera de las dos no lleva `$` ni backtick: sin ellos
     no hay expansion posible, asi que la linea es texto aunque caiga dentro de un heredoc o de una
     cadena. Se reporta como R1 o R2 segun la variable que nombre.

Por que basta: la linea canonica corre la primera, fuera de todo if/heredoc (no hay nada antes),
y nunca da vacio. Despues, ninguna forma permitida puede cambiar la variable.

Que garantiza: donde el texto del bloque nombra la variable, su valor no esta vacio. Nada mas.
Limites aceptados, por clase (perseguirlos es volver a analizar bash):
  - todo lo que llega a la variable SIN escribir su nombre en el bloque: un nombre armado en
    tiempo de ejecucion (`v=CLAUDE_PROJECT_""DIR; echo "${!v}"`), `${!prefijo@}`, `compgen`,
    `eval`, `source`/`.` de otro fichero, una funcion o alias definidos fuera;
  - lo que un comando CALCULA a partir del valor: `${PWD//${PROJECT_DIR}/}`, `sed`, `dirname`
    pueden dar vacio con un valor no vacio;
  - vaciar PWD antes del respaldo (`PWD=`, `unset PWD`);
  - comandos fuera de un bloque (prosa con `codigo en linea` que el agente copie);
  - la forma permitida escapada o entre comillas simples da un literal, no la ruta (nunca vacio).

Alternativas descartadas: `bash -n` solo valida sintaxis, no dice que corre antes de que; un
parser de verdad (shfmt --to-json, bashlex) es una dependencia, y el plugin no tiene ninguna (si
algun dia hace falta, esa es la salida, no otra heuristica); ejecutar los bloques tiene efectos
(mkdir, cat >, git commit). La version por analisis de 2.39.3 cayo tres rondas seguidas de Codex,
cada una por otra forma (if, heredoc, subshell, `$(...)` multilinea, `<<"1"`).

Bloque de shell = fence (``` o ~~~, con sangria, dentro de una cita `>` o sin ella) SIN etiqueta
o cuya primera palabra de info es bash, sh, shell, zsh o console. Un comando sin etiqueta se
ejecuta igual (checkpoint-3t Step 6c lo tenia), asi que no queda fuera. Solo exime una etiqueta
explicita de otro lenguaje (text, json, ...). Los ````markdown se recorren por dentro: un ```bash
anidado en una plantilla de ficha tambien cuenta. La suite cruza esta cuenta con una en awk.

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

SHELL = {"", "bash", "sh", "shell", "zsh", "console"}
FENCE = re.compile(r"^(\s*(?:>\s?)*)\s*(`{3,}|~{3,})(.*)$")
CITA = re.compile(r"^\s*>\s?")

BLANCO = " \t"
FORMA_R1 = "${CLAUDE_PROJECT_DIR:-$PWD}"
CANONICA = 'PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"'
NOMBRE_R1 = re.compile(r"(?<![A-Za-z0-9_])CLAUDE_PROJECT_DIR(?![A-Za-z0-9_])")
NOMBRE_R2 = re.compile(r"(?<![A-Za-z0-9_])PROJECT_DIR(?![A-Za-z0-9_])")
USO_R2 = re.compile(r"\$PROJECT_DIR(?![A-Za-z0-9_])|\$\{PROJECT_DIR\}")


def revisar_bloque(cuerpo, ini):
    """Fallos (linea, regla, texto) de un bloque, segun el contrato del docstring."""
    fallos = []
    codigo = []          # (numero, linea) de las lineas de codigo
    anterior = ""
    for k, linea in enumerate(cuerpo):
        num = ini + k + 1
        comentario = linea.lstrip(BLANCO).startswith("#") and not anterior.endswith("\\")
        anterior = linea
        if comentario:
            if "$" in linea or "`" in linea:
                if NOMBRE_R1.search(linea):
                    fallos.append((num, "R1", linea.strip()))
                elif NOMBRE_R2.search(linea):
                    fallos.append((num, "R2", linea.strip()))
            continue
        if not linea.strip(BLANCO):
            continue
        codigo.append((num, linea))
        if NOMBRE_R1.search(linea.replace(FORMA_R1, "")):
            fallos.append((num, "R1", linea.strip()))
    if not any(NOMBRE_R2.search(l) for _, l in codigo):
        return sorted(fallos)
    canonica = codigo[0][1].strip(BLANCO) == CANONICA
    for pos, (num, linea) in enumerate(codigo):
        if pos == 0 and canonica:
            continue
        if not canonica and NOMBRE_R2.search(linea):
            fallos.append((num, "R2", linea.strip()))
        elif NOMBRE_R2.search(USO_R2.sub("", linea)):
            fallos.append((num, "R2", linea.strip()))
    return sorted(fallos)


def bloques(lineas, base):
    """(n_linea_de_la_fence, cuerpo) de cada bloque de shell; recursivo en los demas."""
    i = 0
    while i < len(lineas):
        m = FENCE.match(lineas[i])
        if not m or (m.group(2)[0] == "`" and "`" in m.group(3)):
            i += 1
            continue
        citas = m.group(1).count(">")
        marca, info = m.group(2), m.group(3).strip()
        palabra = info.split()[0].lower() if info else ""
        cuerpo = []
        j = i + 1
        while j < len(lineas):
            l = lineas[j]
            for _ in range(citas):
                l = CITA.sub("", l, count=1)
            c = FENCE.match(l)
            if c and c.group(2)[0] == marca[0] and len(c.group(2)) >= len(marca) \
                    and not c.group(3).strip() and not c.group(1).strip():
                break
            cuerpo.append(l)
            j += 1
        if palabra in SHELL:
            yield base + i + 1, cuerpo
        else:
            yield from bloques(cuerpo, base + i + 1)
        i = j + 1


def revisar(ruta):
    with open(ruta, encoding="utf-8") as f:
        lineas = f.read().split("\n")
    fallos = []
    n = 0
    for ini, cuerpo in bloques(lineas, 0):
        n += 1
        fallos += revisar_bloque(cuerpo, ini)
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
