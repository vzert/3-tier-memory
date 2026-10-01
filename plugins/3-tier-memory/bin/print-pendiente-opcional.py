#!/usr/bin/env python3
"""
3-tier-memory plugin: imprime el bloque de PENDIENTE del cierre de /checkpoint-3t (Step 8e): a lo
sumo uno de dos, segun la capa que toque (2.44.0, reglas de Victor del 2026-10-01).

  🔔 vence hoy — UN pendiente con `_revisar` igual a hoy (los ya vencidos no). Acompana a
     Retomamos, sea cual sea el snippet, para que no pase desapercibido. Si vencen varios, sale
     uno cada vez: el de mayor prioridad y, dentro de ella, la fila mas arriba.
  ➕ opcional — solo si el snippet es el caso 5 (`Ninguno — …`, nada que retomar) y no vence
     ninguno hoy. Elige como antes de 2.44.0: hasta 2 vencidos (`_revisar` < hoy), el mas viejo
     primero; si no hay, el Alta abierto mas reciente (`_creado`; a igual fecha, la fila mas
     arriba bajo `## Alta prioridad`, que es la ultima insertada).

Por que capas: hasta 2.43.0 el prompt opcional salia en cada cierre y los mismos dos vencidos se
repetian sesion tras sesion. Las dos capas nunca coinciden (la opcional exige que no venza
ninguno hoy), asi que el cierre lleva a lo sumo un bloque de pendiente, justo despues del snippet.

Nunca propone un pendiente con `_bloqueado:` (espera a algo fuera de la sesion), uno con
`_revisar` futuro (ya tiene su recordatorio de calendario) ni el que ya cita `Proximo paso:` de la
ficha. Todo sale de campos estructurados de `_pendientes.md` y de la forma de `## Como retomar`:
nada se decide leyendo el texto (regla 216). Si no hay candidato no imprime nada y sale con 0.

Se genera EN VIVO desde `_pendientes.md`, no se guarda en la ficha: asi el hook de cierre, que lo
vuelve a correr, siempre compara contra el estado real.

Uso:  print-pendiente-opcional.py SESSION_FILE [--hoy YYYY-MM-DD]
"""
# sella-huellas: no (solo lee _pendientes.md y la ficha; no escribe nada)
import datetime
import os
import re
import importlib.util
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

CABECERA_HOY = "🔔 Vence hoy — ábrelo en otra sesión:"
CABECERA_OPCIONAL = "➕ Opcional — otra sesión, si tienes tiempo:"
PRIORIDAD = {"Alta": 0, "Media": 1, "Baja": 2}
ID = re.compile(r"_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])")
ID_CUALQUIERA = re.compile(r"\bp-[0-9a-f]{10}(?![0-9a-f])")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
CREADO = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
BLOQUEADO = re.compile(r"—\s*_bloqueado:")
ORIGEN = re.compile(r"_origen:\s*\[\[(?:\.\./)*(sessions/[^\]|#]+?)(?:\.md)?(?:[|#][^\]]*)?\]\]")
# El texto del pendiente es lo que va antes del primer metadato ` — _campo:`.
METADATO = re.compile(r"\s+—\s+_[a-z]+:")


def _como_retomar():
    """print-como-retomar.py, junto a este script: su detector del caso 5 es el unico."""
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "print-como-retomar.py")
    spec = importlib.util.spec_from_file_location("print_como_retomar", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def proximo_paso_ids(ficha_texto):
    m = re.search(r"^## Como retomar[^\n]*\n(.*?)(?=^## |\Z)", ficha_texto, re.M | re.S)
    if not m:
        return set()
    for l in m.group(1).splitlines():
        s = l.strip().strip("*").strip().lower()
        if s.startswith(("proximo paso:", "próximo paso:")):
            return set(ID_CUALQUIERA.findall(l))
    return set()


def pendientes(path):
    """[(id, texto, prioridad, creado, revisar, bloqueado, origen, fila)]"""
    out, prio = [], None
    with open(path, encoding="utf-8") as fh:
        for n, l in enumerate(fh):
            s = l.strip()
            m_h = re.match(r"^##\s+(alta|media|baja)\b", s, re.I)
            if m_h:
                prio = m_h.group(1).capitalize()
                continue
            if not s.startswith("- [ ]"):
                continue
            m_id = ID.search(s)
            if not m_id:
                continue
            texto = METADATO.split(s[5:].strip(), 1)[0].strip()
            rev, cre, ori = REVISAR.search(s), CREADO.search(s), ORIGEN.search(s)
            out.append((m_id.group(1), texto, prio, cre.group(1) if cre else "",
                        rev.group(1) if rev else None, bool(BLOQUEADO.search(s)),
                        ori.group(1) if ori else None, n))
    return out


def main():
    args = [a for a in sys.argv[1:]]
    hoy = datetime.date.today().isoformat()
    if "--hoy" in args:
        i = args.index("--hoy")
        hoy = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print("uso: print-pendiente-opcional.py SESSION_FILE [--hoy YYYY-MM-DD]", file=sys.stderr)
        return 2
    ficha = os.path.abspath(args[0])
    memory_dir = os.path.dirname(os.path.dirname(ficha))
    proyecto_dir = os.path.dirname(memory_dir)
    pend_path = os.path.join(memory_dir, "_pendientes.md")
    try:
        ficha_texto = open(ficha, encoding="utf-8").read()
        todos = pendientes(pend_path)
    except OSError as exc:
        print(f"⚠ print-pendiente-opcional.py: {exc}", file=sys.stderr)
        return 1

    fuera = proximo_paso_ids(ficha_texto)
    vivos = [p for p in todos if not p[5] and p[0] not in fuera]
    hoy_ = sorted([p for p in vivos if p[4] == hoy], key=lambda p: (PRIORIDAD.get(p[2], 3), p[7]))
    if hoy_:
        cabecera, elegidos = CABECERA_HOY, hoy_[:1]
    else:
        crp = _como_retomar()
        if not crp.es_caso5(crp.extract_section(ficha_texto) or ""):
            return 0
        cabecera = CABECERA_OPCIONAL
        vencidos = sorted([p for p in vivos if p[4] and p[4] < hoy], key=lambda p: (p[4], p[7]))
        if vencidos:
            elegidos = vencidos[:2]
        else:
            alta = [p for p in vivos if p[2] == "Alta" and not (p[4] and p[4] > hoy)]
            # _creado mas reciente primero; a igual fecha, la fila mas arriba (la ultima insertada).
            alta.sort(key=lambda p: (-int(p[3].replace("-", "") or 0), p[7]))
            elegidos = alta[:1]
    if not elegidos:
        return 0

    nombre = os.path.basename(proyecto_dir)
    print(cabecera)
    for i, (pid, texto, prio, creado, rev, _, origen, _) in enumerate(elegidos):
        if i:
            print()
        print(f"Proyecto: {nombre} — {proyecto_dir}")
        print(f"Retomamos: {texto} _id: {pid}_")
        if origen and os.path.exists(os.path.join(memory_dir, origen + ".md")):
            print(f"Contexto: memory/{origen}.md")
        if cabecera == CABECERA_OPCIONAL:
            print(f"Motivo: vencido desde {rev}" if rev else f"Motivo: {prio} abierto desde {creado}")
        print("Si ya no aplica, cierralo con /checkpoint-3t en vez de dejarlo abierto.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
