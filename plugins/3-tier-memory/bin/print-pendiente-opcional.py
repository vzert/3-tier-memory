#!/usr/bin/env python3
"""
3-tier-memory plugin: imprime el prompt OPCIONAL del cierre (checkpoint-3t Step 8e, 2.35.0).

Por que existe: hasta 2.34.0 el snippet `Como retomar` traia una linea `Sigue abierto:` con ids de
pendientes. Victor (2026-09-23) la senalo como inutil: el agente que recibe el snippet solo actua
sobre `Proximo paso`, y al humano una lista de ids no le da nada que hacer. Este script la
reemplaza con UN prompt listo para pegar en otra sesion, sobre un pendiente que se puede hacer ya:

  1. los que vencen hoy o ya vencieron (`_revisar: <= hoy`), los mas viejos primero — hasta 2;
  2. si no hay ninguno, el Alta abierto mas reciente (`_creado`, y a igual fecha la fila mas
     arriba bajo `## Alta prioridad`, que es la ultima insertada).

Nunca propone un pendiente con `_bloqueado:` (espera a algo fuera de la sesion), uno con
`_revisar` futuro (ya tiene su recordatorio de calendario) ni el que ya cita `Proximo paso:` de la
ficha. Todo sale de campos estructurados de `_pendientes.md`: nada se decide leyendo el texto
(regla 216). Si no hay candidato no imprime nada y sale con 0.

Se genera EN VIVO desde `_pendientes.md`, no se guarda en la ficha: asi el hook de cierre, que lo
vuelve a correr, siempre compara contra el estado real.

Uso:  print-pendiente-opcional.py SESSION_FILE [--hoy YYYY-MM-DD]
"""
# sella-huellas: no (solo lee _pendientes.md y la ficha; no escribe nada)
import datetime
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

SEP_TOP = "─── (Opcional) Otra sesion para cerrar un pendiente ───"
SEP_BOTTOM = "───────────────────────────────────────────────────────"
ID = re.compile(r"_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])")
ID_CUALQUIERA = re.compile(r"\bp-[0-9a-f]{10}(?![0-9a-f])")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
CREADO = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
BLOQUEADO = re.compile(r"—\s*_bloqueado:")
ORIGEN = re.compile(r"_origen:\s*\[\[(?:\.\./)*(sessions/[^\]|#]+?)(?:\.md)?(?:[|#][^\]]*)?\]\]")
# El texto del pendiente es lo que va antes del primer metadato ` — _campo:`.
METADATO = re.compile(r"\s+—\s+_[a-z]+:")


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
    vencidos = sorted([p for p in vivos if p[4] and p[4] <= hoy], key=lambda p: (p[4], p[7]))
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
    print(SEP_TOP)
    print("Si tienes tiempo, abre otra sesion de Claude Code con este prompt:")
    for pid, texto, prio, creado, rev, _, origen, _ in elegidos:
        motivo = (f"vence hoy (_revisar {rev})" if rev == hoy else
                  f"vencido desde {rev}" if rev else f"{prio} abierto desde {creado}")
        print()
        print(f"Proyecto: {nombre} — {proyecto_dir}")
        print(f"Retomamos: {texto} _id: {pid}_")
        if origen and os.path.exists(os.path.join(memory_dir, origen + ".md")):
            print(f"Contexto: memory/{origen}.md")
        print(f"Motivo: {motivo}")
        print("Si ya no aplica, cierralo con /checkpoint-3t en vez de dejarlo abierto.")
    print(SEP_BOTTOM)
    return 0


if __name__ == "__main__":
    sys.exit(main())
