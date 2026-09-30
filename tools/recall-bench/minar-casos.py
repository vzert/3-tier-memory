#!/usr/bin/env python3
"""Propone casos para el banco de recall a partir de las fichas de sesion de UNA instalacion.

Busca en memory/sessions/*.md las lineas donde el agente reconoce que una regla ya existia cuando
cometio el error ("la regla 82 ya lo decia", "ya estaba documentado", "rule 12 already..."). Es el
caso que el banco mide: la regla estaba escrita y no llego a tiempo. De cada linea saca:

- la frase del momento: lo que va antes de la primera "→" (formato de "Callejones sin salida" de
  /checkpoint-3t), sin la leccion que viene despues. Esa frase es la entrada y la cita del caso;
- los numeros de regla citados, resueltos contra learnings/<topic>.md de esa misma memoria. Si un
  numero existe en varios topics, el caso sale con todas las opciones en `esperadas_candidatas`;
- el canal: accion si la frase trae un comando entre comillas invertidas que empieza por una orden
  de shell conocida (Bash con ese comando), prompt en otro caso.

Cada candidato sale con "revisar": true. recall-bench.py se NIEGA a correr con un caso asi: una
persona decide si el caso es un incidente, si la regla esperada era la que aplicaba, y quita el
campo. El minador propone; no decide.

Solo LEE los memory/. No escribe nada salvo --salida.

Uso:
  minar-casos.py --proyecto <ruta a un proyecto con memory/> [--proyecto ...] [--salida F.jsonl]
"""
import argparse
import glob
import json
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

DISPARO = re.compile(
    r"ya (?:lo )?(?:dec[ií]a|exist[ií]a|escrit|estaba (?:documentad|escrit|en))|regla \d+ ya|"
    r"learning \d+ ya|rule \d+ already|already (?:existed|documented|a rule)|"
    r"(?:la|esa) regla ya|estaba documentad|documentad[oa] y no|no lo consult|reincidencia|"
    r"pese a (?:estar|la regla)|already covered|was documented", re.IGNORECASE)
NUMERO = re.compile(r"(?:reglas?|rules?|learnings?)\s+#?(\d+)(?:\s*(?:y|and|,)\s*#?(\d+))?",
                    re.IGNORECASE)
RULE_RE = re.compile(r"^\s*(\d+)\.\s+")
ANCLA = re.compile(r"\[\[learnings/[A-Za-z0-9_.-]+?(?:\.md)?#(\d+)[\]|]")
ENLACE = re.compile(r"\[\[learnings/([A-Za-z0-9_.-]+?)(?:\.md)?(?:[#|][^\]]*)?\]\]|learnings/([A-Za-z0-9_.-]+?)\.md")
ORDENES = ("git", "rm", "grep", "ssh", "timeout", "curl", "find", "sed", "cp", "mv", "cat",
           "python3", "python", "bash", "npm", "docker", "kubectl", "gh", "rsync", "scp", "claude")
COMANDO = re.compile(r"`([^`]+)`")


def topics_por_numero(mem):
    out = {}
    for f in sorted(glob.glob(os.path.join(mem, "learnings", "*.md"))):
        topic = os.path.basename(f)[:-3]
        vistos = {}
        with open(f, encoding="utf-8") as fh:
            for l in fh:
                m = RULE_RE.match(l)
                if m:
                    n = int(m.group(1))
                    vistos[n] = vistos.get(n, 0) + 1
        for n, veces in vistos.items():
            if veces == 1:  # un numero repetido en el mismo topic es ambiguo: no se propone
                out.setdefault(n, []).append(f"{topic}#{n}")
    return out


def momento(linea):
    """La frase antes de la primera flecha, sin la vineta ni negritas sueltas del principio."""
    t = linea.strip()
    if t.startswith("- "):
        t = t[2:]
    if "→" in t:
        t = t.split("→", 1)[0]
    return t.strip().strip("*").strip()


def canal_de(frase):
    for cmd in COMANDO.findall(frase):
        primera = cmd.strip().split()[0] if cmd.strip() else ""
        if primera in ORDENES:
            return "accion", {"tool_name": "Bash", "tool_input": {"command": cmd.strip()}}
    return "prompt", frase


def minar(proyecto):
    mem = os.path.join(proyecto, "memory")
    if not os.path.isdir(mem):
        print(f"minar-casos: no hay memory/ en {proyecto}", file=sys.stderr)
        return []
    por_numero = topics_por_numero(mem)
    nombre = os.path.basename(os.path.normpath(proyecto))
    out = []
    for ficha in sorted(glob.glob(os.path.join(mem, "sessions", "*.md"))):
        with open(ficha, encoding="utf-8") as fh:
            texto = fh.read()
        for i, linea in enumerate(texto.splitlines(), 1):
            if not DISPARO.search(linea):
                continue
            # Solo si la linea cita la regla (numero o enlace a su topic): "ya estaba" sin regla
            # suele ser otra cosa (un pendiente que ya existia, un arbol que ya estaba en develop).
            topics = {a or b for a, b in ENLACE.findall(linea)}
            if not NUMERO.search(linea) and not topics:
                continue
            frase = momento(linea)
            if len(frase) < 12 or frase not in texto:
                continue
            nums = []
            for m in NUMERO.finditer(linea):
                nums += [int(x) for x in m.groups() if x]
            # [[learnings/topic#7]]: el numero va en el ancla del enlace
            nums += [int(n) for n in ANCLA.findall(linea)]
            candidatas = sorted({rid for n in nums for rid in por_numero.get(n, [])})
            unicas = []
            for n in nums:
                opciones = por_numero.get(n, [])
                if topics:  # el enlace de la misma linea dice de que topic es el numero
                    opciones = [r for r in opciones if r.split("#")[0] in topics] or opciones
                if len(opciones) == 1:
                    unicas.append(opciones[0])
            canal, entrada = canal_de(frase)
            caso = {
                "id": f"{nombre}-{os.path.basename(ficha)[:10]}-l{i}",
                "corpus": os.path.abspath(proyecto),
                "canal": canal,
                "entrada": entrada,
                "esperadas": sorted(set(unicas)),
                "prohibidas": [],
                "fuente": os.path.abspath(ficha),
                "cita": frase,
                "origen": "incidente",
                "revisar": True,
                "nota": "propuesto por minar-casos: " + linea.strip()[:200],
            }
            if len(candidatas) > len(caso["esperadas"]):
                caso["esperadas_candidatas"] = candidatas
            out.append(caso)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proyecto", action="append", required=True)
    ap.add_argument("--salida", default="")
    a = ap.parse_args()
    casos = [c for p in a.proyecto for c in minar(p)]
    lineas = "".join(json.dumps(c, ensure_ascii=False) + "\n" for c in casos)
    if a.salida:
        with open(a.salida, "w", encoding="utf-8") as f:
            f.write(lineas)
    else:
        sys.stdout.write(lineas)
    con_regla = sum(1 for c in casos if c["esperadas"])
    accion = sum(1 for c in casos if c["canal"] == "accion")
    print(f"minar-casos: {len(casos)} candidatos ({con_regla} con regla resuelta, {accion} de accion); "
          f"todos con \"revisar\": true", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
