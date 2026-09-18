#!/usr/bin/env python3
"""
3-tier-memory plugin: imprime, para cada research que este SESSION_FILE enlaza en su seccion
`## Research`, las recomendaciones que quedaron SIN RESOLVER en la seccion `## Recomendaciones`
de ese research — checkpoint-3t Step 8d.

Por que existe (mismo principio que print-como-retomar.py, ver ese docstring): si un research
genero varias recomendaciones candidatas y esta sesion solo ejecuto una, las demas no deben
depender de que el agente las recuerde en prosa al cerrar. Este script no redacta nada nuevo: LEE
el `## Recomendaciones` que ya existe en el research (Step 5 de checkpoint-3t.md pide escribirlo
ahi cuando aplica) y lo transforma mecanicamente al formato de bloque de retomar, exactamente como
print-como-retomar.py hace con `## Como retomar`. Una sola fuente de verdad; este script nunca la
reinterpreta.

Que hace: lee la seccion `## Research` de SESSION_FILE, extrae los wikilinks
`[[research/<slug>]]` (o `[[research/<slug>|texto]]`), y para cada uno busca
`memory/research/<slug>.md` (misma carpeta que SESSION_FILE, subiendo a `memory/`) y su seccion
`## Recomendaciones`. Si tiene items `- [ ]` sin marcar, imprime UN bloque por research con esos
items. Si ningun research enlazado tiene items sin marcar (o `## Research` dice "Ninguno", o no
existe la seccion), no imprime nada y sale 0 -- silencio es el caso normal, a diferencia de
`## Como retomar` que siempre tiene contenido que imprimir.

Uso:  print-research-recomendaciones.py SESSION_FILE
"""
# sella-huellas: no (solo lee el session file y los research que enlaza; no escribe nada)
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

SEP_TOP_FMT = "─── Recomendaciones sin resolver: research/{slug} ───"
SEP_BOTTOM = "────────────────────────────────────"
INTRO = "Copia y pega esto al iniciar una nueva sesion de Claude Code:"

UNCHECKED_RE = re.compile(r"^-\s*\[\s\]\s+(.+)$")
LINK_RE = re.compile(r"\[\[research/([^\]|]+?)(?:\|[^\]]*)?\]\]")


def extract_section(text, heading):
    lines = text.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.strip().lower() == heading)
    except StopIteration:
        return None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break
    return "\n".join(lines[start + 1:end])


def unresolved_items(text):
    section = extract_section(text, "## recomendaciones")
    if not section:
        return []
    out = []
    for line in section.splitlines():
        m = UNCHECKED_RE.match(line.strip())
        if m:
            out.append(m.group(1).strip())
    return out


def main():
    if len(sys.argv) != 2:
        print("uso: print-research-recomendaciones.py SESSION_FILE", file=sys.stderr)
        return 2
    session_path = sys.argv[1]
    try:
        with open(session_path, encoding="utf-8") as fh:
            session_text = fh.read()
    except OSError as exc:
        print(f"⚠ print-research-recomendaciones.py: no se pudo leer {session_path}: {exc}",
              file=sys.stderr)
        return 1

    research_section = extract_section(session_text, "## research")
    if not research_section:
        return 0

    slugs = []
    seen = set()
    for m in LINK_RE.finditer(research_section):
        slug = m.group(1)
        if slug not in seen:
            seen.add(slug)
            slugs.append(slug)
    if not slugs:
        return 0

    # memory/ es el directorio que contiene sessions/<este archivo>
    memory_dir = os.path.dirname(os.path.dirname(os.path.abspath(session_path)))

    printed_any = False
    for slug in slugs:
        research_path = os.path.join(memory_dir, "research", f"{slug}.md")
        try:
            with open(research_path, encoding="utf-8") as fh:
                research_text = fh.read()
        except OSError as exc:
            # Hallazgo del adversario externo (codex, ronda 1, 2026-09-17): un `continue` mudo
            # aqui trata IGUAL un research legitimamente `(inline)` (nunca tuvo archivo) que un
            # wikilink ROTO (typo, archivo movido o borrado) -- el segundo caso es exactamente lo
            # que este mecanismo existe para no perder en silencio, y un enlace roto lo perdia
            # igual que si nunca hubiera tenido recomendaciones sin resolver. Avisa, no calla.
            print(f"⚠ print-research-recomendaciones.py: '## Research' enlaza research/{slug} pero "
                  f"no se pudo leer memory/research/{slug}.md ({exc}) -- si es inline (sin archivo "
                  f"propio) ignora este aviso; si el archivo existia, el enlace esta roto y puede "
                  f"haber recomendaciones sin resolver que este script no pudo revisar.",
                  file=sys.stderr)
            continue
        items = unresolved_items(research_text)
        if not items:
            continue
        print(SEP_TOP_FMT.format(slug=slug))
        print(INTRO)
        print()
        print(f"Retomamos las recomendaciones sin resolver de research/{slug}.md:")
        for item in items:
            print(f"- {item}")
        print("Decide, para cada una: abrir un plan, declinarla (marca [x] -- declinado: motivo), "
              "o diferirla explicitamente.")
        print(SEP_BOTTOM)
        printed_any = True

    return 0


if __name__ == "__main__":
    sys.exit(main())
