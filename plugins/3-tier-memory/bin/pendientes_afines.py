#!/usr/bin/env python3
"""
3-tier-memory plugin (2.55.0, 2.56.0): pendientes AFINES al `Proximo paso:` de una ficha.

Por que existe: hasta 2.54 el snippet `Como retomar` llevaba un solo item. Un Media que la sesion
dejaba junto a un Alta no volvia a ningun snippet salvo que venciera su `_revisar` (medido sobre
las 8 ultimas fichas de este repo y de otro proyecto: p-f667380493, p-95d33b9363, p-b0b80cfb23 y
p-564b0bdc82 no volvieron nunca). Y un Alta corta no traia nada con que completar la sesion.

Que hace: toma los anclas que cita la linea `Proximo paso:` de `## Como retomar` (ids `p-…` y
slugs `plan-…`) y devuelve hasta 2 pendientes abiertos Alta o Media ligados a ellos por el campo
`_relacionado:` (journal-emit `--relacionado` / `pendiente.relate`), en CUALQUIER direccion:
  - el candidato cita un ancla en su `_relacionado:`, o
  - un pendiente ancla cita al candidato en su `_relacionado:`, o
  - el candidato y un pendiente ancla citan el mismo `plan-…`.
Sin importar de que sesion vengan: el arrastre entre sesiones es justo el punto.

Nunca devuelve uno con `_bloqueado:`, uno con `_revisar` futuro (ya tiene su recordatorio de
calendario), uno que vence hoy (lo muestra la capa 🔔 de print-pendiente-opcional.py), uno cuyo
texto nombra una fecha ISO posterior a hoy (ver `fecha_futura`) ni uno que ya cita el `Proximo
paso:`. Orden: Alta antes que Media; dentro, el `_creado` mas viejo primero (el que mas tiempo
lleva esperando); a igual fecha, la fila mas arriba. Todo lo demas sale de campos estructurados
(regla 216). En particular NO decide si el paso es "corto": eso no esta en ningun campo, asi que
la linea lo deja dicho como condicion para quien retoma ("si ese paso es corto").

La excepcion de la fecha (2.56.0) es un chequeo de FORMATO, no de significado: una fecha
`AAAA-MM-DD` posterior a hoy en el texto. Caso real (otro proyecto, 2026-10-13): la linea sumo
un pendiente Alta, "revision a 24 h desde el 2026-10-14", sin `_revisar`; el agente que retomo no
pudo hacerlo ese dia. El campo `_revisar` sigue siendo la via principal (Step 3b lo exige); esto
es la red para cuando falta.

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
PLAN_CUALQUIERA = re.compile(r"(?<![0-9A-Za-z-])plan-[A-Za-z0-9][A-Za-z0-9._-]*")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
CREADO = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
BLOQUEADO = re.compile(r"—\s*_bloqueado:")
RELACIONADO = re.compile(r"—\s*_relacionado:\s*([^—]*?)_?\s*(?=—|$)")
METADATO = re.compile(r"\s+—\s+_[a-z]+:")
# Una fecha ISO suelta: no la de un slug (`2026-10-14-algo`, `backup_2026-10-14_x`) ni parte de
# un numero mayor. La `T` de un timestamp (`2026-10-14T09:00Z`) si cuenta.
FECHA_ISO = re.compile(r"(?<![\w-])(\d{4}-\d{2}-\d{2})(?![\d_])(?![A-SU-Za-z])(?!-[0-9A-Za-z])")
# El final de un rango ("del 2026-10-01 al 2026-10-14") cuyo inicio ya llego: la ventana esta
# abierta hoy, no es una espera.
INICIO_RANGO = re.compile(r"(\d{4}-\d{2}-\d{2})\s*(?:al|a|hasta|–|—|-)\s*$", re.I)
# Un plazo ("antes del 2026-12-01") se puede cumplir hoy: no es una espera.
PLAZO = re.compile(r"(?:antes\s+del?|a\s+m[aá]s\s+tardar(?:\s+el)?|vence(?:\s+el)?|"
                   r"l[ií]mite:?|plazo:?|deadline:?)\s*$", re.I)


def fecha_futura(texto, hoy):
    """La primera fecha `AAAA-MM-DD` de `texto` posterior a `hoy` que no es un plazo, o None.

    Es la red de 2.56.0 para el trabajo que espera una fecha y no trae `_revisar`. La usan la
    linea de afines (excluye el pendiente) y checkpoint-audit.py (`snippet.proximo_paso`). No ve
    fechas escritas de otra forma ("manana", "14-oct", "tras la revision"): esas siguen
    dependiendo de que el pendiente nazca con `--revisar` o `_bloqueado:`."""
    texto = texto or ""
    for m in FECHA_ISO.finditer(texto):
        f = m.group(1)
        antes = texto[max(0, m.start() - 25):m.start()]
        rango = INICIO_RANGO.search(antes)
        if f > hoy and not PLAZO.search(antes) and not (rango and rango.group(1) <= hoy):
            return f
    return None


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


def lecturas_plan(cita):
    """Todas las lecturas de una cita `plan-…` sacada de prosa o de una celda, la mas larga primero.

    Un slug valido puede terminar en `.`, `-` o `_` (journal-emit lo acepta), y una cita puede
    llevar `.md` y despues el punto de la frase. Ningun regex sabe donde acaba el slug, asi que se
    generan TODAS las lecturas que salen de aplicar, en cualquier orden y hasta agotarlas, dos
    recortes: quitar un signo final y quitar un `.md` final. `plan-a-.md.` da `plan-a-.md.`,
    `plan-a-.md`, `plan-a-` y `plan-a`. La usan esta linea de afines y
    plan-siguiente-hermano.py: una sola definicion (2.55.0; dos copias distintas de esta logica
    dieron tres rondas de adversario seguidas)."""
    vistas, cola = [], [cita]
    while cola:
        v = cola.pop(0)
        if v in vistas or len(v) <= len("plan-") or not v.startswith("plan-"):
            continue
        vistas.append(v)
        if v[-1] in "._-":
            cola.append(v[:-1])
        if v.endswith(".md"):
            cola.append(v[:-3])
    return sorted(vistas, key=len, reverse=True)


def canonica(cita):
    """La lectura mas corta de `lecturas_plan` (sin signos ni `.md` finales), o None."""
    lect = lecturas_plan(cita)
    return lect[-1] if lect else None


def anclas(linea):
    """(ids, planes) que cita la linea. Un `plan-x.md` cuenta como `plan-x`.

    Un slug valido puede terminar en `-`, `.` o `_` (journal-emit lo acepta), y en prosa un `.`
    final suele ser el punto de la frase: se toman las DOS lecturas. Un ancla de mas solo casa
    con un pendiente que cite exactamente ese valor, asi que sobra sin dano."""
    if not linea:
        return set(), set()
    planes = set()
    for p in PLAN_CUALQUIERA.findall(linea):
        planes.update(lecturas_plan(p))
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
        if fecha_futura(p["texto"], hoy):
            continue   # espera una fecha que no esta en `_revisar`: hoy no se puede hacer
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
