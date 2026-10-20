#!/usr/bin/env python3
"""
3-tier-memory plugin: avisa al agente, cuando el prompt es un snippet de retomar pegado, si ese
snippet ya quedo viejo (2.63.22).

Por que existe: el snippet `Retomamos:` de Step 8 se copia y se pega a mano, a veces horas despues
y a veces en dos panes. Auditoria del 2026-10-20 sobre los 4 proyectos (sesiones desde 2.62.0): de
5 pegados que el agente llamo "viejos", 4 lo eran de verdad, y en los 4 el agente tuvo que
descubrirlo por su cuenta leyendo la memoria; en otras sesiones el usuario llego a escribir a mano
"revisa si tu snippet sigue vigente". Las dos señales que cubren los 4 casos, sin
disparar en el pegado vigente de control, son estas, y las dos salen de memory/ sin leer prosa
(regla 216):

  A. un `p-…` del paso ya no esta abierto en `_pendientes.md` (cerrado: lo dice su fila mensual;
     o no existe en ningun lado);
  B. una ficha mas nueva que la que el snippet manda leer ya cita ese `p-…`: en su `## Como
     retomar`, en su sello `hilo_paso`, o en la marca `_retomar` del propio pendiente (8a2).

Que lee: el JSON del hook UserPromptSubmit en stdin (campo `prompt`). Solo actua si el prompt
empieza por `Retomamos:` o `Proximo paso:` (el snippet de Step 8 o la tarjeta de 8e/8c) o por
`p-…:` (la tarjeta que pega el mod pendientes); en cualquier otro caso sale sin imprimir nada.

Salida: texto plano para el agente (UserPromptSubmit lo inyecta como contexto), o nada. Es solo
un aviso: nunca bloquea, y no decide si el trabajo sigue haciendo falta (un plan de varias noches
puede seguir abierto con una ficha mas nueva); eso lo confirma el agente con el usuario.

Uso:  snippet-vigente.py --memory-dir DIR < hook.json
"""
# sella-huellas: no (solo lee _pendientes.md, los mensuales y las fichas; no escribe nada)
import importlib.util
import json
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

BIN = os.path.dirname(os.path.abspath(__file__))
TARJETA_MOD = re.compile(r"^(p-[0-9a-f]{10}):")
RETOMAR = re.compile(r"_retomar:\s*\d{4}-\d{2}-\d{2}\s+sessions/(\S+?)_")
FECHA = re.compile(r"^\d{4}-\d{2}-\d{2}")


def _afines():
    """pendientes_afines.py, junto a este script: su parser del snippet es el unico."""
    ruta = os.path.join(BIN, "pendientes_afines.py")
    spec = importlib.util.spec_from_file_location("pendientes_afines", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _leer(ruta):
    try:
        with open(ruta, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def abiertos(memory_dir):
    """{p-id: linea} de las casillas `- [ ]` de _pendientes.md."""
    out = {}
    for l in (_leer(os.path.join(memory_dir, "_pendientes.md")) or "").splitlines():
        s = l.strip()
        if s.startswith("- [ ]"):
            for pid in re.findall(r"_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])", s):
                out[pid] = s
    return out


def cierre(memory_dir, pid):
    """(fecha, detalle) de la fila mensual del pendiente cerrado, o None si no esta en ninguna."""
    carpeta = os.path.join(memory_dir, "pendientes")
    try:
        meses = sorted(os.listdir(carpeta), reverse=True)
    except OSError:
        return None
    marca = re.compile(r"_id:\s*" + re.escape(pid) + r"_")
    for mes in meses:
        if not mes.endswith(".md"):
            continue
        for l in (_leer(os.path.join(carpeta, mes)) or "").splitlines():
            if not l.startswith("|") or not marca.search(l):
                continue
            celdas = [c.strip() for c in l.strip().strip("|").split("|")]
            # | # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |
            if len(celdas) >= 7 and celdas[-2]:
                return celdas[-2], celdas[-1]
    return None


def seccion_retomar(texto):
    m = re.search(r"^## Como retomar[^\n]*\n(.*?)(?=^## |\Z)", texto or "", re.M | re.S)
    return m.group(1) if m else ""


def fichas_nuevas(memory_dir, slug, pid, pa):
    """Fichas posteriores a `slug` que citan `pid` en su Como retomar o en su sello hilo_paso,
    de la mas nueva a la mas vieja. Posterior = fecha del nombre mayor, o la misma fecha y
    escrita despues."""
    carpeta = os.path.join(memory_dir, "sessions")
    base = os.path.join(carpeta, slug + ".md")
    try:
        mtime_base = os.path.getmtime(base)
    except OSError:
        mtime_base = 0
    fecha_base = slug[:10] if FECHA.match(slug) else ""
    out = []
    try:
        nombres = os.listdir(carpeta)
    except OSError:
        return out
    for n in nombres:
        if not n.endswith(".md") or n[:-3] == slug or not FECHA.match(n):
            continue
        if fecha_base and n[:10] < fecha_base:
            continue
        ruta = os.path.join(carpeta, n)
        try:
            mtime = os.path.getmtime(ruta)
        except OSError:
            continue
        if fecha_base and n[:10] == fecha_base and mtime <= mtime_base:
            continue
        texto = _leer(ruta) or ""
        fm = pa.frontmatter(texto)
        if pid in seccion_retomar(texto) or pid in fm.get("hilo_paso", ""):
            out.append((n[:10], mtime, n[:-3]))
    out.sort(reverse=True)
    return [s for _, _, s in out]


def avisos(prompt, memory_dir):
    pa = _afines()
    texto = pa.PASTED.sub("", pa.RUIDO.sub("", prompt or "")).strip()
    m_mod = TARJETA_MOD.match(texto)
    if m_mod:
        ids, slug = [m_mod.group(1)], None
    elif texto.lower().startswith(("retomamos:", "proximo paso:", "próximo paso:")):
        rec = pa.recibido(texto)
        ids = [x for x in rec["paso"] if x.startswith("p-")]
        slug = rec["retoma"]
    else:
        return []
    vivos = abiertos(memory_dir)
    out = []
    for pid in ids:
        if pid not in vivos:
            c = cierre(memory_dir, pid)
            if c:
                out.append(f"- {pid} ya esta cerrado: resuelto {c[0]} ({c[1][:160]}).")
            else:
                out.append(f"- {pid} no esta en _pendientes.md ni en ningun mensual de pendientes/.")
            continue
        m_ret = RETOMAR.search(vivos[pid])
        nuevas = fichas_nuevas(memory_dir, slug, pid, pa) if slug else []
        if m_ret and m_ret.group(1) != slug and m_ret.group(1) not in nuevas:
            nuevas.insert(0, m_ret.group(1))
        if nuevas:
            extra = f" (y {len(nuevas) - 1} mas)" if len(nuevas) > 1 else ""
            out.append(f"- {pid} sigue abierto, pero una ficha mas nueva ya lo retoma: "
                       f"memory/sessions/{nuevas[0]}.md{extra}. Su `## Como retomar` es el vigente.")
    return out


def main():
    args = sys.argv[1:]
    if len(args) != 2 or args[0] != "--memory-dir":
        print("uso: snippet-vigente.py --memory-dir DIR < hook.json", file=sys.stderr)
        return 2
    try:
        prompt = json.load(sys.stdin).get("prompt", "")
    except (ValueError, AttributeError):
        return 0
    if not isinstance(prompt, str):
        return 0
    lineas = avisos(prompt, args[1])
    if lineas:
        print("SNIPPET POSIBLEMENTE VIEJO (3-tier): el snippet que te pegaron cita trabajo que la "
              "memoria ya movio. Antes de actuar, compruebalo y dilo en tus 3 lineas de donde "
              "quedamos:")
        print("\n".join(lineas))
    return 0


if __name__ == "__main__":
    sys.exit(main())
