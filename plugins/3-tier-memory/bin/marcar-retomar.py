#!/usr/bin/env python3
"""
3-tier-memory plugin: marca con `_retomar: HOY sessions/<slug>_` el pendiente que cita el
`Proximo paso` del snippet de una ficha (checkpoint-3t Step 8a2, 2.62.8).

Por que existe: el snippet `Retomamos:` de Step 8 se copia y se pega a mano. Si el pane se cierra o
el snippet se olvida, el paso queda enterrado entre los demas pendientes: el mod pendientes solo ve
el `Proximo paso` de la ULTIMA ficha, y otra sesion que cierre despues lo desplaza. Con la marca, el
mod saca ese pendiente en PLANES ACTIVOS (una fila por ficha, con si su sesion sigue abierta) hasta
que se cierre, y el clic pega el snippet de la ficha nombrada en la marca. Decision de Victor
(d65-d68, 2026-10-16; seccion propia y no VENCEN desde el mod 0.3.0, d372).

Por que un campo aparte y no `_revisar`: con `_revisar` = hoy, el 🔔 de 8e de CUALQUIER cierre del
dia sacaba el paso de otra sesion, y `hacible()` dejaba de proponerlo en el hilo de una sesion que
lo retoma ese mismo dia. `_retomar` solo lo lee el mod; 8e, el hilo y el calendario lo ignoran.

Que hace: lee `## Como retomar` de SESSION_FILE, toma los `p-…` del `Proximo paso:` (sin lo que va
tras "ver tambien"), y para cada uno que siga abierto en `_pendientes.md`:
  - con `_revisar` FUTURO: no lo marca y avisa (Step 8 no debe elegir trabajo de fecha futura);
  - si ya tiene esta misma marca: nada;
  - si no: emite `pendiente.retomar` y, al final, compacta.
Un `Proximo paso` sin `p-…` (un plan, `ninguno — …`) no marca nada. Nunca crea un pendiente.

Despues quita la marca que esta sesion consumio (2.63.42): si la sesion arranco con el snippet de
otra ficha F (`hilo_retoma: F` en su frontmatter, de stamp-hilo.py) y uno de los ids de ese paso
(`hilo_paso`) sigue abierto con `_retomar … sessions/F_` y no quedo marcado ahora, emite
`pendiente.retomar --quitar --ficha sessions/F`. Sin esto la marca vieja seguia en PLANES ACTIVOS
y el clic del mod pegaba un snippet ya hecho cuando el paso nuevo caia en otro pendiente (caso real
de proyecto-edge, 2026-10-22: la ficha de la Fase 4 retomo la de la Fase 3 y marco otro
pendiente). Si la marca ya apunta a otra ficha, el compactador no la toca.

Por ultimo liga los hermanos al paso (2.65.2): si un id del paso es un pendiente abierto NACIDO en
esta sesion (`_origen: [[sessions/<slug>]]` de esta ficha), cada otro pendiente abierto nacido en
ella que no tenga `_relacionado` recibe `pendiente.relate` con ese id. Uno que ya cita algo no
se toca: tiene su ancla, y sumarle el paso lo meteria en el hilo de otro tema. La liga al
nacer (journal-emit) solo apunta al paso RECIBIDO; sin esto, en una sesion que no recibio paso, o
cuyo paso escrito es uno de sus propios pendientes, los hermanos seguian en el hilo de la sesion
siguiente solo si su snippet se sellaba (caso real de otro proyecto, 2026-10-26: un paso y tres
hermanos sin liga). Un paso viejo no liga nada: lo que nacio aqui ya lo liga la liga al nacer.

Salida: una linea por id. Codigo 0 salvo error de uso o de escritura.

Uso:  marcar-retomar.py SESSION_FILE [--hoy YYYY-MM-DD] [--memory-dir DIR]
"""
# sella-huellas: no (no escribe indices: emite por journal-emit.py y aplica con journal-compact.py)
import datetime
import importlib.util
import os
import re
import subprocess
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

BIN = os.path.dirname(os.path.abspath(__file__))
ID_LINEA = re.compile(r"_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
RETOMAR = re.compile(r"_retomar:\s*(\d{4}-\d{2}-\d{2})\s+(\S+?)_\s*(?=—|$)")


def _afines():
    """pendientes_afines.py, junto a este script (por ruta: con `python3 -I` el directorio del
    script no esta en sys.path)."""
    ruta = os.path.join(BIN, "pendientes_afines.py")
    spec = importlib.util.spec_from_file_location("pendientes_afines", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ids_del_paso(paso, pa):
    """Los `p-…` del texto del paso, en orden y sin repetir; lo que va tras "ver tambien" no."""
    texto = pa.VER_TAMBIEN.sub("", paso or "")
    vistos = []
    for i in pa.ID_P.findall(texto):
        if i not in vistos:
            vistos.append(i)
    return vistos


def abiertos(pend_path):
    """{id: linea} de las lineas `- [ ]` con id."""
    out = {}
    with open(pend_path, encoding="utf-8") as fh:
        for l in fh:
            s = l.strip()
            if not s.startswith("- [ ]"):
                continue
            m = ID_LINEA.search(s)
            if m and m.group(1) not in out:
                out[m.group(1)] = s
    return out


# Las tres formas que acepta --hoy. Con regex propio y no con date.fromisoformat: este solo acepta
# 20261016 y 2026-W42-5 desde Python 3.11, y el python3 de macOS es 3.9 (p-0ccd79fe36).
HOY_DIA = re.compile(r"(\d{4})-?(\d{2})-?(\d{2})")      # 2026-10-16 o 20261016 (no 2026-1016)
HOY_SEMANA = re.compile(r"(\d{4})-?W(\d{2})-?(\d)")     # 2026-W42-5 o 2026W425


def fecha_hoy(valor):
    """AAAA-MM-DD de `valor` en una de las tres formas, o ValueError."""
    m = HOY_DIA.fullmatch(valor)
    if m and valor.count("-") in (0, 2):              # todos los guiones o ninguno
        return datetime.date(*map(int, m.groups())).isoformat()
    m = HOY_SEMANA.fullmatch(valor)
    if m and valor.count("-") in (0, 2):
        return datetime.date.fromisocalendar(*map(int, m.groups())).isoformat()
    raise ValueError(valor)


def main(argv):
    args, hoy, memory_dir = [], None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--hoy", "--memory-dir"):
            if i + 1 >= len(argv):
                print(f"uso: falta el valor de {a}", file=sys.stderr)
                return 2
            if a == "--hoy":
                hoy = argv[i + 1]
            else:
                memory_dir = argv[i + 1]
            i += 2
            continue
        args.append(a)
        i += 1
    if len(args) != 1:
        print("uso: marcar-retomar.py SESSION_FILE [--hoy YYYY-MM-DD] [--memory-dir DIR]",
              file=sys.stderr)
        return 2
    path = args[0]
    try:
        # Normaliza `20261016` o `2026-W42-5` a AAAA-MM-DD; lo que llega al emisor siempre tiene esa
        # forma.
        hoy = fecha_hoy(hoy) if hoy else datetime.date.today().isoformat()
    except ValueError:
        print(f"uso: --hoy no es una fecha: {hoy}", file=sys.stderr)
        return 2
    memory_dir = memory_dir or os.path.dirname(os.path.dirname(os.path.abspath(path)))
    pend_path = os.path.join(memory_dir, "_pendientes.md")
    try:
        with open(path, encoding="utf-8") as fh:
            texto = fh.read()
    except OSError as exc:
        print(f"⚠ marcar-retomar.py: no se pudo leer {path}: {exc}", file=sys.stderr)
        return 1
    pa = _afines()
    ids = ids_del_paso(pa.proximo_paso(texto), pa)
    fm = pa.frontmatter(texto)
    retoma = (fm.get("hilo_retoma") or "").strip()
    consumidos = [i for i in pa.lista(fm.get("hilo_paso")) if i.startswith("p-")] if retoma else []
    if not ids and not consumidos:
        return 0
    if not os.path.isfile(pend_path):
        print(f"⚠ marcar-retomar.py: no existe {pend_path}", file=sys.stderr)
        return 1
    ficha = "sessions/" + os.path.splitext(os.path.basename(path))[0]
    vivos = abiertos(pend_path)
    emitidos = 0
    marcados = set()
    for pid in ids:
        linea = vivos.get(pid)
        if linea is None:
            print(f"· {pid}: no esta abierto; sin marca")
            continue
        rev = REVISAR.search(linea)
        if rev and rev.group(1) > hoy:
            print(f"⚠ {pid}: tiene _revisar futuro ({rev.group(1)}); no se marca. Step 8 no elige "
                  "trabajo de fecha futura: revisa el Proximo paso")
            continue
        ret = RETOMAR.search(linea)
        if ret and ret.group(1) == hoy and ret.group(2) == ficha:
            print(f"· {pid}: ya marcado para retomar hoy")
            continue
        r = subprocess.run([sys.executable, os.path.join(BIN, "journal-emit.py"),
                            "--memory-dir", memory_dir, "--type", "pendiente.retomar",
                            "--id", pid, "--retomar", hoy, "--ficha", ficha],
                           capture_output=True, text=True, encoding="utf-8")
        if r.returncode != 0:
            print(f"⚠ marcar-retomar.py: journal-emit fallo con {pid}: {r.stderr.strip()}",
                  file=sys.stderr)
            return 1
        emitidos += 1
        marcados.add(pid)
        print(f"📌 {pid}: retomar {hoy} (sale en PLANES ACTIVOS del mod pendientes hasta que se cierre)")
    vieja = "sessions/" + retoma
    for pid in consumidos:
        linea = vivos.get(pid)
        if linea is None or pid in marcados or vieja == ficha:
            continue
        ret = RETOMAR.search(linea)
        if not ret or ret.group(2) != vieja:
            continue
        r = subprocess.run([sys.executable, os.path.join(BIN, "journal-emit.py"),
                            "--memory-dir", memory_dir, "--type", "pendiente.retomar",
                            "--id", pid, "--quitar", "--ficha", vieja],
                           capture_output=True, text=True, encoding="utf-8")
        if r.returncode != 0:
            print(f"⚠ marcar-retomar.py: journal-emit fallo con {pid}: {r.stderr.strip()}",
                  file=sys.stderr)
            return 1
        emitidos += 1
        print(f"🧹 {pid}: sin _retomar ({vieja} ya se retomo en esta sesion)")
    slug = os.path.splitext(os.path.basename(path))[0]
    nacidos = {p["id"]: p for p in pa.pendientes(pend_path) if p["origen"] == slug}
    for pid in ids:
        if pid not in nacidos:
            continue
        for hid, h in nacidos.items():
            # Solo el hermano SIN liga: ese es el que se caia. Uno que ya cita algo (el paso
            # recibido, un plan, otro pendiente) tiene su ancla, y sumarle este paso lo meteria en
            # el hilo de otro tema que nacio en la misma sesion.
            if hid in ids or h["rel"]:
                continue
            nuevo = [pid]
            cmd = [sys.executable, os.path.join(BIN, "journal-emit.py"), "--memory-dir", memory_dir,
                   "--type", "pendiente.relate", "--id", hid]
            for x in nuevo:
                cmd += ["--relacionado", x]
            r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
            if r.returncode != 0:
                print(f"⚠ marcar-retomar.py: journal-emit fallo con {hid}: {r.stderr.strip()}",
                      file=sys.stderr)
                return 1
            emitidos += 1
            h["rel"] = set(nuevo)
            print(f"🔗 {hid}: ligado al paso {pid} (nacieron en la misma sesion)")
    if emitidos:
        r = subprocess.run([sys.executable, os.path.join(BIN, "journal-compact.py"),
                            "--memory-dir", memory_dir, "--quiet"],
                           capture_output=True, text=True, encoding="utf-8")
        if r.returncode != 0:
            print(f"⚠ marcar-retomar.py: journal-compact fallo: {r.stderr.strip()}",
                  file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
