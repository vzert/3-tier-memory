#!/usr/bin/env python3
"""
3-tier-memory plugin: imprime el bloque de PENDIENTE del cierre de /checkpoint-3t (Step 8e): a lo
sumo uno de dos, segun la capa que toque (2.44.0, reglas de Victor del 2026-10-01).

  🔔 vence hoy — UN pendiente con `_revisar` igual a hoy (los ya vencidos no). Acompana a
     Retomamos, sea cual sea el snippet, para que no pase desapercibido. Si vencen varios, sale
     uno cada vez: el de mayor prioridad y, dentro de ella, la fila mas arriba.
  ➕ opcional — solo si el snippet es el caso 5 (`Ninguno — …`, nada que retomar) y no vence
     ninguno hoy. Hasta 2 vencidos (`_revisar` < hoy), el mas viejo primero; si no hay ninguno
     vencido, no sale nada. Hasta 2.63.17 salia entonces el Alta abierto mas reciente; se quito en
     2.63.22 (decision de Victor, d265-d266): sin relacion con la sesion, el mismo Alta salia en
     cada cierre hasta que alguien lo cerraba (medido: uno de otro agente salio 14 veces en 10
     sesiones de otro proyecto, sin que nadie lo tomara). El backlog ya lo muestran el sidebar de
     pendientes y el recall por peticion.

Por que capas: hasta 2.43.0 el prompt opcional salia en cada cierre y los mismos dos vencidos se
repetian sesion tras sesion. Las dos capas nunca coinciden (la opcional exige que no venza
ninguno hoy), asi que el cierre lleva a lo sumo un bloque de pendiente, justo despues del snippet.

Nunca propone un pendiente con `_bloqueado:` sin `_revisar` (espera a algo fuera de la sesion y no
dice cuando mirar), uno con `_revisar` futuro (ya tiene su recordatorio de calendario) ni el que ya
cita `Proximo paso:` de la ficha. Un `_bloqueado:` con `_revisar` de hoy o vencido SI sale (2.63.32):
ese dia toca mirar si ya llego lo que esperaba; sin esto el bloqueo lo escondia tambien aqui. Todo sale de campos estructurados de `_pendientes.md` y de la forma de `## Como retomar`:
nada se decide leyendo el texto (regla 216). Si no hay candidato no imprime nada y sale con 0.

Se genera EN VIVO desde `_pendientes.md`, no se guarda en la ficha: asi el hook de cierre, que lo
vuelve a correr, siempre compara contra el estado real.

Aviso ⚠ (2.64.0): si el pendiente del 🔔 lo nombro, en las ultimas 2 h, una herramienta de accion
de OTRA ventana viva del proyecto (`paso_ajeno.otras_ventanas`), el bloque lleva una linea
`⚠ tocado en otra ventana …: verifica el texto antes de abrirlo`. Nace de un cierre real donde el
🔔 mostro el texto viejo de un pendiente que otra sesion ya habia resuelto. La senal sale del
transcript (ids), nunca del texto del pendiente (regla 216); no suprime ni bloquea el 🔔. Sin
`--transcript` busca el de esta sesion por `CLAUDE_CODE_SESSION_ID`; sin transcript no avisa (falla
abierto). El hook de cierre no exige esta linea (`exigidas` la salta): la reporta como aviso.

Uso:  print-pendiente-opcional.py SESSION_FILE [--hoy YYYY-MM-DD] [--transcript RUTA]
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


def _paso_ajeno():
    """paso_ajeno.py, junto a este script."""
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "paso_ajeno.py")
    spec = importlib.util.spec_from_file_location("paso_ajeno", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def transcript_de_sesion(proyecto_dir):
    """Transcript de esta sesion: `CLAUDE_CODE_SESSION_ID` bajo ~/.claude/projects/<ruta con - >."""
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if not re.fullmatch(r"[0-9a-fA-F-]{8,64}", sid):
        return None
    base = os.path.join(os.path.expanduser("~"), ".claude", "projects")
    cod = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(proyecto_dir))
    ruta = os.path.join(base, cod, sid + ".jsonl")
    return ruta if os.path.isfile(ruta) else None


def aviso_otra_ventana(pid, transcript, horas=2):
    """Linea ⚠ si otra ventana corrio una herramienta de accion con el id en las ultimas horas."""
    if not transcript or not os.path.isfile(transcript):
        return None
    try:
        hits = _paso_ajeno().otras_ventanas(transcript, [pid], horas=horas).get(pid) or []
    except Exception:
        return None
    if not hits:
        return None
    return (f"⚠ tocado en otra ventana en las ultimas {horas} h ({len(hits)} sesion(es)): "
            "verifica que el texto siga siendo cierto antes de abrirlo.")


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
    transcript = None
    if "--transcript" in args:
        i = args.index("--transcript")
        transcript = args[i + 1] if i + 1 < len(args) else None
        del args[i:i + 2]
    if "--hoy" in args:
        i = args.index("--hoy")
        hoy = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print("uso: print-pendiente-opcional.py SESSION_FILE [--hoy YYYY-MM-DD] [--transcript RUTA]", file=sys.stderr)
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
    vivos = [p for p in todos if not (p[5] and not p[4]) and p[0] not in fuera]
    hoy_ = sorted([p for p in vivos if p[4] == hoy], key=lambda p: (PRIORIDAD.get(p[2], 3), p[7]))
    if hoy_:
        cabecera, elegidos = CABECERA_HOY, hoy_[:1]
    else:
        crp = _como_retomar()
        if not crp.es_caso5(crp.extract_section(ficha_texto) or ""):
            return 0
        cabecera = CABECERA_OPCIONAL
        vencidos = sorted([p for p in vivos if p[4] and p[4] < hoy], key=lambda p: (p[4], p[7]))
        elegidos = vencidos[:2]
    if not elegidos:
        return 0

    nombre = os.path.basename(proyecto_dir)
    print(cabecera)
    for i, (pid, texto, prio, creado, rev, bloq, origen, _) in enumerate(elegidos):
        if i:
            print()
        print(f"Proyecto: {nombre} — {proyecto_dir}")
        print(f"Retomamos: {texto} _id: {pid}_")
        if origen and os.path.exists(os.path.join(memory_dir, origen + ".md")):
            print(f"Contexto: memory/{origen}.md")
        if cabecera == CABECERA_OPCIONAL:
            print(f"Motivo: vencido desde {rev}")
        if cabecera == CABECERA_HOY:
            av = aviso_otra_ventana(pid, transcript or transcript_de_sesion(proyecto_dir))
            if av:
                print(av)
        if bloq:
            print("Espera a alguien de fuera: mira si ya llego; si no, dale otra fecha.")
        print("Si ya no aplica, cierralo con /checkpoint-3t en vez de dejarlo abierto.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
