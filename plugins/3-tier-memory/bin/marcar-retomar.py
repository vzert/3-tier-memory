#!/usr/bin/env python3
"""
3-tier-memory plugin: marca con `_retomar: HOY sessions/<slug>_` el pendiente que cita el
`Proximo paso` del snippet de una ficha (checkpoint-3t Step 8a2, 2.62.8).

Por que existe: el snippet `Retomamos:` de Step 8 se copia y se pega a mano. Si el pane se cierra o
el snippet se olvida, el paso queda enterrado entre los demas pendientes: el mod pendientes solo ve
el `Proximo paso` de la ULTIMA ficha, y otra sesion que cierre despues lo desplaza. Con la marca, el
mod saca ese pendiente en VENCEN ("retomar hoy"; al dia siguiente, "retomar desde FECHA") hasta
que se cierre, y el clic pega el snippet de la ficha nombrada en la marca. Decision de Victor
(d65-d68, 2026-10-16).

Por que un campo aparte y no `_revisar`: con `_revisar` = hoy, el 🔔 de 8e de CUALQUIER cierre del
dia sacaba el paso de otra sesion, y `hacible()` dejaba de proponerlo en el hilo de una sesion que
lo retoma ese mismo dia. `_retomar` solo lo lee el mod; 8e, el hilo y el calendario lo ignoran.

Que hace: lee `## Como retomar` de SESSION_FILE, toma los `p-…` del `Proximo paso:` (sin lo que va
tras "ver tambien"), y para cada uno que siga abierto en `_pendientes.md`:
  - con `_revisar` FUTURO: no lo marca y avisa (Step 8 no debe elegir trabajo de fecha futura);
  - si ya tiene esta misma marca: nada;
  - si no: emite `pendiente.retomar` y, al final, compacta.
Un `Proximo paso` sin `p-…` (un plan, `ninguno — …`) no marca nada. Nunca crea un pendiente.

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
        hoy = datetime.date.fromisoformat(hoy).isoformat() if hoy else datetime.date.today().isoformat()
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
    if not ids:
        return 0
    if not os.path.isfile(pend_path):
        print(f"⚠ marcar-retomar.py: no existe {pend_path}", file=sys.stderr)
        return 1
    ficha = "sessions/" + os.path.splitext(os.path.basename(path))[0]
    vivos = abiertos(pend_path)
    emitidos = 0
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
        print(f"📌 {pid}: retomar {hoy} (sale en VENCEN del mod pendientes hasta que se cierre)")
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
