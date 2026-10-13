#!/usr/bin/env python3
"""
3-tier-memory plugin (2.55.0): pendientes AFINES al `Proximo paso:` de una ficha.

Por que existe: hasta 2.54 el snippet `Como retomar` llevaba un solo item. Un Media que la sesion
dejaba junto a un Alta no volvia a ningun snippet salvo que venciera su `_revisar` (medido sobre
las 8 ultimas fichas de este repo y de claude-vzert: p-f667380493, p-95d33b9363, p-b0b80cfb23 y
p-564b0bdc82 no volvieron nunca). Y un Alta corta no traia nada con que completar la sesion.

Que hace: toma los anclas que cita la linea `Proximo paso:` de `## Como retomar` (ids `p-…` y
slugs `plan-…`) y devuelve hasta 2 pendientes abiertos Alta o Media ligados a ellos por el campo
`_relacionado:` (journal-emit `--relacionado` / `pendiente.relate`), en CUALQUIER direccion:
  - el candidato cita un ancla en su `_relacionado:`, o
  - un pendiente ancla cita al candidato en su `_relacionado:`, o
  - el candidato y un pendiente ancla citan el mismo `plan-…`.
Sin importar de que sesion vengan: el arrastre entre sesiones es justo el punto.

Nunca devuelve uno con `_bloqueado:`, uno con `_revisar` futuro (ya tiene su recordatorio de
calendario), uno que vence hoy (lo muestra la capa 🔔 de print-pendiente-opcional.py) ni uno que
ya cita el `Proximo paso:`. Orden: Alta antes que Media; dentro, el `_creado` mas viejo primero
(el que mas tiempo lleva esperando); a igual fecha, la fila mas arriba. Todo sale de campos
estructurados: nada se decide leyendo el texto (regla 216). En particular NO decide si el paso
es "corto": eso no esta en ningun campo, asi que la linea lo deja dicho como condicion para
quien retoma ("si ese paso es corto").

Lo usa print-como-retomar.py (la linea `Si ese paso es corto, suma…` dentro del snippet).

Uso directo (diagnostico):  pendientes_afines.py SESSION_FILE [--hoy YYYY-MM-DD]
"""
# sella-huellas: no (solo lee _pendientes.md y la ficha; no escribe nada)
import datetime
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

PRIORIDAD = {"Alta": 0, "Media": 1}
MAX_AFINES = 2
TEXTO_MAX = 90
ID = re.compile(r"_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])")
ID_CUALQUIERA = re.compile(r"(?<![0-9A-Za-z-])p-[0-9a-f]{10}(?![0-9a-f])")
PLAN_CUALQUIERA = re.compile(r"(?<![0-9A-Za-z-])plan-[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
CREADO = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
BLOQUEADO = re.compile(r"—\s*_bloqueado:")
RELACIONADO = re.compile(r"—\s*_relacionado:\s*([^—]*?)_?\s*(?=—|$)")
METADATO = re.compile(r"\s+—\s+_[a-z]+:")


def proximo_paso(ficha_texto):
    """La linea `Proximo paso:` de `## Como retomar`, o None."""
    m = re.search(r"^## Como retomar[^\n]*\n(.*?)(?=^## |\Z)", ficha_texto, re.M | re.S)
    if not m:
        return None
    for l in m.group(1).splitlines():
        s = l.strip().strip("*").strip().lower()
        if s.startswith(("proximo paso:", "próximo paso:")):
            return l
    return None


def anclas(linea):
    """(ids, planes) que cita la linea. Un `plan-x.md` cuenta como `plan-x`."""
    if not linea:
        return set(), set()
    planes = {re.sub(r"\.md$", "", p) for p in PLAN_CUALQUIERA.findall(linea)}
    return set(ID_CUALQUIERA.findall(linea)), planes


def pendientes(path):
    """[{id, texto, prio, creado, revisar, bloqueado, rel, fila}] de las lineas `- [ ]`."""
    out, prio = [], None
    with open(path, encoding="utf-8") as fh:
        for n, l in enumerate(fh):
            s = l.strip()
            m_h = re.match(r"^##\s+(alta|media|baja)\b", s, re.I)
            if m_h:
                prio = m_h.group(1).capitalize()
                continue
            if s.startswith("## "):
                prio = None
                continue
            if not s.startswith("- [ ]"):
                continue
            m_id = ID.search(s)
            if not m_id:
                continue
            m_rel = RELACIONADO.search(s)
            rel = {x.strip() for x in m_rel.group(1).split(",") if x.strip()} if m_rel else set()
            rev, cre = REVISAR.search(s), CREADO.search(s)
            out.append({"id": m_id.group(1), "texto": METADATO.split(s[5:].strip(), 1)[0].strip(),
                        "prio": prio, "creado": cre.group(1) if cre else "9999-99-99",
                        "revisar": rev.group(1) if rev else None,
                        "bloqueado": bool(BLOQUEADO.search(s)), "rel": rel, "fila": n})
    return out


def afines(ficha_texto, pend_path, hoy=None):
    """Hasta MAX_AFINES pendientes (dicts de `pendientes`) afines al `Proximo paso:`. [] si la
    ficha no cita nada, si no hay `_pendientes.md` o si nada esta ligado."""
    hoy = hoy or datetime.date.today().isoformat()
    ids, planes = anclas(proximo_paso(ficha_texto))
    if not (ids or planes) or not os.path.isfile(pend_path):
        return []
    todos = pendientes(pend_path)
    por_id = {p["id"]: p for p in todos}
    # Lo que citan los pendientes ancla: sus enlaces directos y sus planes.
    citados_por_ancla = set()
    for i in ids:
        if i in por_id:
            citados_por_ancla |= por_id[i]["rel"]
    planes_ancla = planes | {x for x in citados_por_ancla if x.startswith("plan-")}
    anclas_todas = ids | planes_ancla
    elegibles = []
    for p in todos:
        if p["id"] in ids or p["prio"] not in PRIORIDAD or p["bloqueado"]:
            continue
        if p["revisar"] and p["revisar"] >= hoy:
            continue   # futuro: su recordatorio de calendario; hoy: la capa 🔔
        if (p["rel"] & anclas_todas) or p["id"] in citados_por_ancla:
            elegibles.append(p)
    elegibles.sort(key=lambda p: (PRIORIDAD[p["prio"]], p["creado"], p["fila"]))
    return elegibles[:MAX_AFINES]


def corto(texto):
    t = " ".join(texto.split())
    return t if len(t) <= TEXTO_MAX else t[:TEXTO_MAX - 1].rstrip() + "…"


def linea_snippet(ficha_texto, pend_path, hoy=None):
    """La linea que print-como-retomar.py mete en el snippet, o None si no hay afines."""
    elegidos = afines(ficha_texto, pend_path, hoy)
    if not elegidos:
        return None
    partes = [f"{p['id']} ({p['prio']}) — {corto(p['texto'])}" for p in elegidos]
    return "Si ese paso es corto, suma en la misma sesion: " + "; ".join(partes) + "."


def main():
    args = sys.argv[1:]
    hoy = None
    if "--hoy" in args:
        i = args.index("--hoy")
        hoy = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print("uso: pendientes_afines.py SESSION_FILE [--hoy YYYY-MM-DD]", file=sys.stderr)
        return 2
    ficha = os.path.abspath(args[0])
    memory_dir = os.path.dirname(os.path.dirname(ficha))
    with open(ficha, encoding="utf-8") as fh:
        texto = fh.read()
    l = linea_snippet(texto, os.path.join(memory_dir, "_pendientes.md"), hoy)
    if l:
        print(l)
    return 0


if __name__ == "__main__":
    sys.exit(main())
