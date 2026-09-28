#!/usr/bin/env python3
"""
3-tier-memory plugin: la ruta del proyecto en los bloques de shell de templates/ y commands/.

Por que existe: CLAUDE_PROJECT_DIR llega VACIA a las llamadas Bash del agente (medido
2026-09-24), y el shell no conserva variables de una llamada a la siguiente. 2.39.1 arreglo a
mano los bloques que lo ignoraban, con un recorrido de un solo uso. El primer barrido buscaba una
sola grafia (`ENCODED=$(echo "$CLAUDE_PROJECT_DIR"`) y solo en templates/; un adversario encontro
cinco bloques mas en commands/ con otras formas ($PROJECT_DIR en mkdir, cat >, if -f). Este
script recorre CADA bloque de shell por construccion, no por grafia.

Reglas, por bloque de shell:
  R1 Cualquier mencion de CLAUDE_PROJECT_DIR fuera de un comentario que no sea
     `${CLAUDE_PROJECT_DIR:-X}` con X no vacio. Falla la forma desnuda, `${CLAUDE_PROJECT_DIR}`,
     `${CLAUDE_PROJECT_DIR-X}`, `${#CLAUDE_PROJECT_DIR}`, el nombre en aritmetica, y los
     respaldos vacios `:-}`, `:-""}` y `:-''}` (callan a `set -u` pero siguen dando vacio).
  R2 `$PROJECT_DIR` (tambien `${PROJECT_DIR}`, `${#PROJECT_DIR}`, pegada a otra variable) usada
     sin definirla ANTES en el mismo bloque. `${PROJECT_DIR:-X}` con X no vacio siempre vale.
     Solo cuenta como definicion una asignacion de nivel superior: al inicio de la linea, fuera
     de if/for/while/until/case, de un cuerpo de funcion, de un subshell y de un heredoc, y que no
     sea el prefijo de un comando (`PROJECT_DIR=x cmd` no la deja definida). Tambien valen
     export/declare/readonly/local delante y `read ... PROJECT_DIR`. Los usos del lado derecho de
     la propia asignacion se miran ANTES de darla por definida: `PROJECT_DIR="$PROJECT_DIR/x"`
     falla. Definirla en otro bloque no cuenta: es otra llamada Bash.

Bloque de shell = fence (``` o ~~~, con sangria, dentro de una cita `>` o sin ella) SIN etiqueta
o cuya primera palabra de info es bash, sh, shell, zsh o console. Un comando sin etiqueta se
ejecuta igual (checkpoint-3t Step 6c lo tenia), asi que no queda fuera. Solo exime una etiqueta
explicita de otro lenguaje (text, json, ...). Los ````markdown se recorren por dentro: un ```bash
anidado en una plantilla de ficha tambien cuenta.

Quita comentarios (`#` fuera de comillas, al inicio o tras un blanco), salvo en el cuerpo de un
heredoc, que es texto y se revisa entero. Ante la duda, marca de mas antes que de menos.

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

# Respaldo no vacio: `:-` seguido de algo que no sea `}`, `""}` ni `''}`.
CON_RESPALDO = r":-(?!\}|\"\"\}|''\})"
R1_NOMBRE = re.compile(r"(?<![A-Za-z0-9_])CLAUDE_PROJECT_DIR(?![A-Za-z0-9_])")
R1_BUENO = re.compile(r"\$\{CLAUDE_PROJECT_DIR" + CON_RESPALDO)
R2_USO = re.compile(r"\$(?:\{[#!]?)?PROJECT_DIR(?![A-Za-z0-9_])")
R2_BUENO = re.compile(r"\$\{PROJECT_DIR" + CON_RESPALDO)
R2_DEF = re.compile(r"^\s*(?:(?:export|readonly|local|declare(?:\s+-\w+)*)\s+)?PROJECT_DIR=")
R2_READ = re.compile(r"^\s*read(?:\s+-\w+(?:\s+\S+)?)*\s+(?:\w+\s+)*PROJECT_DIR(?:\s|;|$)")
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
ABRE = re.compile(r"(?:^|[;&|]\s*|\b(?:then|do|else)\s+)(if|for|while|until|case|select)\b")
CIERRA = re.compile(r"(?:^\s*|[;&|]\s*)(fi|done|esac)\b")
ELSE = re.compile(r"(?:^\s*|[;&|]\s*)(else|elif)\b")


def sin_comentario(linea):
    """La linea sin su comentario: `#` fuera de comillas, al inicio o tras un blanco."""
    q = None
    i = 0
    while i < len(linea):
        c = linea[i]
        if q:
            if c == "\\" and q == '"':
                i += 2
                continue
            if c == q:
                q = None
        elif c == "\\":
            i += 2
            continue
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or linea[i - 1] in " \t;"):
            return linea[:i]
        i += 1
    return linea


def fin_de_palabra(s, i):
    """Indice donde termina la palabra de shell que empieza en s[i] (respeta comillas y $())."""
    q = None
    prof = 0
    while i < len(s):
        c = s[i]
        if q:
            if c == "\\" and q == '"':
                i += 2
                continue
            if c == q:
                q = None
        elif c == "\\":
            i += 2
            continue
        elif c in "'\"":
            q = c
        elif s.startswith("$(", i) or s.startswith("${", i):
            prof += 1
            i += 2
            continue
        elif c in ")}" and prof:
            prof -= 1
        elif c in " \t;&|" and not prof:
            return i
        i += 1
    return i


def es_definicion(codigo):
    """True si la linea (sin comentario) deja PROJECT_DIR definida para las lineas siguientes."""
    if R2_READ.match(codigo):
        return True
    m = R2_DEF.match(codigo)
    if not m:
        return False
    resto = codigo[fin_de_palabra(codigo, m.end()):].lstrip()
    # `PROJECT_DIR=x cmd` solo la pone en el entorno de cmd.
    return resto == "" or resto[0] in ";&|"


def usos_malos(texto, nombre_re, bueno_re):
    """Posiciones de menciones que no son la forma con respaldo."""
    buenas = {m.start() + 2 for m in bueno_re.finditer(texto)}   # 2 = len('${')
    return [m for m in nombre_re.finditer(texto) if m.start() not in buenas]


def logicas(cuerpo, ini):
    """Une las lineas que acaban en `\\`. Devuelve (numero de la primera, texto)."""
    out = []
    buf, num = None, None
    for k, l in enumerate(cuerpo):
        if buf is None:
            buf, num = l, ini + k + 1
        else:
            buf = buf[:-1] + l
        if not buf.endswith("\\"):
            out.append((num, buf))
            buf = None
    if buf is not None:
        out.append((num, buf))
    return out


def segmentos(codigo):
    """Parte la linea en comandos por `;` de nivel superior (fuera de comillas y de $() / ${})."""
    out = []
    i = ini = 0
    while i < len(codigo):
        j = fin_de_palabra(codigo, i)
        if j < len(codigo) and codigo[j] == ";" and not codigo.startswith(";;", j):
            out.append(codigo[ini:j])
            ini = j + 1
        i = j + 1
    out.append(codigo[ini:])
    return out


def usos_r2(texto):
    return [m for m in R2_USO.finditer(texto) if not R2_BUENO.match(texto, m.start())]


def revisar_bloque(cuerpo, ini):
    """Fallos (linea, regla, texto) de un bloque.

    La definicion se recuerda con la profundidad a la que se hizo: vale mientras no se salga de
    ese nivel. Dentro de un if o de una funcion vale hasta su fi / } / else, no despues.
    """
    fallos = []
    def_prof = None      # profundidad de la definicion vigente, o None
    prof = 0
    heredocs = []        # terminadores pendientes, en orden
    for num, linea in logicas(cuerpo, ini):
        if heredocs:
            term, quitar_tabs = heredocs[0]
            if (linea.lstrip("\t") if quitar_tabs else linea) == term:
                heredocs.pop(0)
                continue
            # Cuerpo de heredoc: texto que se escribe o se ejecuta despues. Se revisa entero y
            # nada aqui define la variable.
            if usos_malos(linea, R1_NOMBRE, R1_BUENO):
                fallos.append((num, "R1", linea.strip()))
            if def_prof is None and usos_r2(linea):
                fallos.append((num, "R2", linea.strip()))
            continue
        codigo = sin_comentario(linea)
        if usos_malos(codigo, R1_NOMBRE, R1_BUENO):
            fallos.append((num, "R1", linea.strip()))
        r2_mal = False
        for seg in segmentos(codigo):
            s = seg.strip()
            # Cierres antes que el resto: `}`, `)`, fi/done/esac y else/elif (otra rama).
            if re.match(r"^[})](?:\s|$)", s):
                prof -= 1
                s = s[1:].strip()
            prof -= len(CIERRA.findall(s))
            prof = max(prof, 0)
            if def_prof is not None and (prof < def_prof or
                                         (prof == def_prof and ELSE.search(s) and prof > 0)):
                def_prof = None
            # Aperturas: funcion `f() {`, grupo `{`, subshell `(`, if/for/while/until/case.
            m = re.match(r"^(?:function\s+)?[\w.-]+\s*\(\)\s*\{|^\{(?=\s|$)|^\((?!\()", s)
            if m:
                prof += 1
                s = s[m.end():].strip()
            prof += len(ABRE.findall(s))
            malos = usos_r2(s)
            if es_definicion(s):
                fin = R2_DEF.match(s)
                rhs = s[:fin_de_palabra(s, fin.end())] if fin else s
                if def_prof is None and usos_r2(rhs):
                    r2_mal = True
                elif def_prof is None or prof < def_prof:
                    def_prof = prof
                continue
            if malos and def_prof is None:
                r2_mal = True
        if r2_mal:
            fallos.append((num, "R2", linea.strip()))
        for h in HEREDOC.finditer(codigo):
            heredocs.append((h.group(3), h.group(1) == "-"))
    return fallos


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
