#!/usr/bin/env python3
"""
3-tier-memory plugin: compactador unico del journal (v2.12.0, Fase 1).

Aplica los eventos de memory/.journal/pending/ a los indices markdown, en orden de nombre
(= orden de emision), bajo un lock de directorio. Primitiva: mkdir — en POSIX, mkdir(2) es
atomico entre procesos (uno crea, el resto recibe EEXIST); es lo que se midio aqui (macOS,
prueba de aceptacion 10/10). En Windows se asume el mismo comportamiento de CreateDirectory
pero NO se ha medido: queda para Fase 4 del plan (Linux + Git Bash). flock no existe como
CLI en macOS, por eso no se usa. Cada .md se escribe a tmp + os.replace. Cada evento aplicado
se mueve a applied/YYYY-MM/; un evento invalido o cuyo ancla no existe va a quarantine/ con
un archivo .reason al lado. Nunca se pierde un evento en silencio.

Idempotente: re-aplicar un evento ya aplicado es no-op (la linea ya existe / ya no existe).
Deltas anclados, nunca regeneracion: insertar tras el header de prioridad, borrar linea por
id, llenar celda por id. Las ediciones a mano del humano sobreviven.

Lock: memory/.journal/.lock (dir) con acquired_at + owner. TTL 60 s. Un lock vencido lo
reclama exactamente un proceso: el que gana mkdir de .lock-steal re-verifica el TTL y borra.
Portado de bin/lock-tier2-write.sh (0/20 solapes, 1/5 gana el robo).

Uso:
  journal-compact.py [--memory-dir DIR] [--budget SEG] [--log FILE] [--quiet]
    --budget  segundos maximos esperando el lock (default 10; el hook usa 1). Si vence,
              sale 0 sin aplicar: otro compactador tiene el lock y aplicara lo pendiente.
    --log     archivo al que se agregan lineas de traza; escribe `STOLEN` si reclamo un
              lock vencido (contrato de la prueba de aceptacion).
Salida: 0 ok (o lock ocupado); 1 error de entorno. Imprime `JOURNAL applied=N quarantined=N
pending_left=N [noop=N]` salvo --quiet (en ese caso solo imprime si applied>0 o quarantined>0).
`applied` cuenta solo eventos que cambiaron algo; un replay de evento ya aplicado se archiva
y cuenta en `noop`.
"""
import argparse
import json
import os
import re
import shutil
import sys
import time
import unicodedata
import uuid
from datetime import date

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

STALE_SECONDS = 60
POLL_SECONDS = 0.05
REPLACE_RETRIES = 5  # Windows: antivirus/indexador pueden tener el .md abierto un instante
MESES = ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto",
         "Septiembre", "Octubre", "Noviembre", "Diciembre"]
ID_RE = re.compile(r"_id: (p-[0-9a-f]{10})_")
HEADERS = {"alta": "## Alta prioridad", "media": "## Media prioridad", "baja": "## Baja prioridad"}

LOG_FILE = None


def log(msg):
    if LOG_FILE:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(msg + "\n")
    if msg.startswith("WARN"):
        print(msg)  # el agente que corre el checkpoint tiene que verlo, con o sin --log


class Quarantine(Exception):
    """El evento no se puede aplicar de forma segura; va a quarantine/ con este motivo."""


# ----------------------------------------------------------------------------- utilidades
def normalize_text(text):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFC", text or "")).strip()


def read_lines(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().split("\n")


def atomic_write(path, lines):
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    for attempt in range(REPLACE_RETRIES):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if attempt == REPLACE_RETRIES - 1:
                raise
            time.sleep(0.05 * (attempt + 1))


def resolve_memory_dir(explicit):
    cand = explicit or os.environ.get("MEMORY_DIR")
    if cand:
        return os.path.abspath(cand)
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    local = os.path.join(proj, "memory")
    if os.path.isfile(os.path.join(local, "_pendientes.md")):
        return local
    encoded = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(proj))
    auto = os.path.join(os.path.expanduser("~"), ".claude", "projects", encoded, "memory")
    if os.path.isfile(os.path.join(auto, "_pendientes.md")):
        return auto
    return local


# ----------------------------------------------------------------------------- lock
class Lock:
    def __init__(self, journal, budget):
        self.dir = os.path.join(journal, ".lock")
        self.steal = os.path.join(journal, ".lock-steal")
        self.budget = budget
        self.owner = f"{os.getpid()}-{uuid.uuid4().hex[:8]}"
        self.held = False

    def _write_marker(self, name, value):
        # tmp + replace: un lector concurrente nunca ve el marcador a medio escribir
        # (un acquired_at vacio se leeria como 0 = vencido y provocaria un robo falso).
        tmp = os.path.join(self.dir, f".{name}.{self.owner}.tmp")
        with open(tmp, "w") as fh:
            fh.write(value)
        os.replace(tmp, os.path.join(self.dir, name))

    def _stamp(self):
        self._write_marker("owner", self.owner)
        self._write_marker("acquired_at", str(int(time.time())))

    def _acquired_at(self):
        """Epoch de adquisicion; si el marcador aun no existe, la mtime del directorio.

        Entre el mkdir y la escritura del marcador hay una ventana real (medida: 2-3 robos
        del mismo lock en 1 de 4 corridas). La mtime del directorio existe desde el mkdir
        mismo, asi que un lock recien creado nunca parece vencido. None = el directorio ya
        no existe (alguien lo libero): no esta vencido, hay que reintentar el mkdir.
        """
        try:
            with open(os.path.join(self.dir, "acquired_at")) as fh:
                return int(fh.read().strip())
        except (OSError, ValueError):
            pass
        try:
            return int(os.stat(self.dir).st_mtime)
        except OSError:
            return None

    def _is_stale(self):
        at = self._acquired_at()
        return at is not None and (int(time.time()) - at) > STALE_SECONDS

    def acquire(self):
        # memory/.journal/ puede no existir aun (proyecto que adopta v2.12.0 y corre el
        # compactador antes de emitir su primer evento: exactamente Step 3-pre del checkpoint).
        # Sin esto, os.mkdir del lock daba FileNotFoundError → "JOURNAL busy" falso.
        try:
            os.makedirs(os.path.dirname(self.dir), exist_ok=True)
        except OSError:
            return False
        deadline = time.monotonic() + self.budget
        while True:
            try:
                os.mkdir(self.dir)
                self._stamp()
                self.held = True
                return True
            except FileExistsError:
                pass
            except OSError:
                return False  # fs de solo lectura, permisos: fail-open, no bloquear
            if self._is_stale():
                # Solo un proceso reclama: el que gana el mkdir del steal-gate. Re-verifica
                # el TTL dentro del gate — el lock pudo refrescarse o cambiar de dueno.
                try:
                    os.mkdir(self.steal)
                    try:
                        if self._is_stale():
                            shutil.rmtree(self.dir, ignore_errors=True)
                            log("STOLEN")
                    finally:
                        try:
                            os.rmdir(self.steal)
                        except OSError:
                            pass
                    continue
                except FileExistsError:
                    pass  # otro esta reclamando; esperar
            if time.monotonic() >= deadline:
                return False
            time.sleep(POLL_SECONDS)

    def refresh(self):
        if self.held:
            try:
                self._write_marker("acquired_at", str(int(time.time())))
            except OSError:
                pass

    def release(self):
        if not self.held:
            return
        try:
            with open(os.path.join(self.dir, "owner")) as fh:
                owner = fh.read().strip()
        except OSError:
            owner = ""
        if owner and owner != self.owner:
            return  # alguien nos robo el lock (TTL vencido): no borrar el suyo
        shutil.rmtree(self.dir, ignore_errors=True)
        self.held = False


# ----------------------------------------------------------------------------- _pendientes.md
def find_id_line(lines, pid):
    for i, line in enumerate(lines):
        if line.lstrip().startswith("- [ ]") and f"_id: {pid}_" in line:
            return i
    return None


def line_text(line):
    s = line.strip()[5:].strip()
    return normalize_text(re.sub(r"\s*—\s*_(origen|creado|id):[^—]*", "", s))


def header_index(lines, prio):
    key = prio.lower()
    for i, line in enumerate(lines):
        if line.strip().lower().startswith(f"## {key}"):
            return i
    return None


def apply_add_index(mem, p):
    path = os.path.join(mem, "_pendientes.md")
    if not os.path.isfile(path):
        raise Quarantine("no-index: _pendientes.md no existe")
    lines = read_lines(path)
    i = find_id_line(lines, p["id"])
    if i is not None:
        if line_text(lines[i]) != normalize_text(p["text"]):
            raise Quarantine(f"id-collision: {p['id']} ya existe con otro texto")
        return False  # idempotente: ya aplicado
    h = header_index(lines, p["prioridad"])
    if h is None:
        raise Quarantine(f"no-anchor: falta el header '{HEADERS.get(p['prioridad'].lower())}'")
    new = (f"- [ ] {p['text']} — _origen: {p['origen']}_ — _creado: {p['creado']}_ "
           f"— _id: {p['id']}_")
    # Insertar tras el header y su linea en blanco (si la hay): lo nuevo arriba.
    at = h + 1
    if at < len(lines) and lines[at].strip() == "":
        at += 1
    lines.insert(at, new)
    # Seccion vacia: el siguiente es otro header; conservar la linea en blanco entre ambos.
    if at + 1 < len(lines) and lines[at + 1].startswith("## "):
        lines.insert(at + 1, "")
    atomic_write(path, lines)
    return True


def apply_resolve_index(mem, p):
    path = os.path.join(mem, "_pendientes.md")
    if not os.path.isfile(path):
        raise Quarantine("no-index: _pendientes.md no existe")
    lines = read_lines(path)
    i = find_id_line(lines, p["id"])
    if i is None:
        return False  # ya borrada (idempotente) o cerrada a mano
    prefix = normalize_text(p.get("text_prefix") or "")
    if prefix and not line_text(lines[i]).startswith(prefix):
        raise Quarantine(f"prefix-mismatch: la linea {p['id']} no empieza por '{prefix[:40]}'")
    del lines[i]
    # No dejar dos lineas en blanco seguidas donde estaba la borrada.
    if 0 < i < len(lines) and lines[i].strip() == "" and lines[i - 1].strip() == "":
        del lines[i]
    atomic_write(path, lines)
    return True


# ----------------------------------------------------------------------------- pendientes/YYYY-MM.md
def monthly_path(mem, creado):
    return os.path.join(mem, "pendientes", creado[:7] + ".md")


def ensure_monthly(path, ym):
    if os.path.isfile(path):
        return read_lines(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    y, m = ym.split("-")
    mes = MESES[int(m) - 1] if 1 <= int(m) <= 12 else m
    return [
        "---", "type: pendientes-archive", f"month: {ym}",
        f"created: {date.today().isoformat()}", "---",
        f"# Pendientes — {mes} {y}", "",
        "| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |",
        "|---|---|---|---|---|---|---|",
        "", "## Related", "- [[_pendientes]]", "",
    ]


def table_rows(lines):
    """(indice, celdas) de cada fila numerada de la tabla."""
    out = []
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("|") and re.match(r"^\|\s*\d+\s*\|", s):
            cells = [c.strip() for c in s.strip().strip("|").split("|")]
            out.append((i, cells))
    return out


def last_table_line(lines):
    last = None
    for i, line in enumerate(lines):
        if line.strip().startswith("|"):
            last = i
    return last


def find_monthly_row(mem, pid):
    """Busca la fila con ese id en cualquier mensual. Devuelve (path, lines, idx) o None."""
    d = os.path.join(mem, "pendientes")
    if not os.path.isdir(d):
        return None
    for fn in sorted(os.listdir(d), reverse=True):
        if not re.match(r"^\d{4}-\d{2}\.md$", fn):
            continue
        path = os.path.join(d, fn)
        lines = read_lines(path)
        for i, cells in table_rows(lines):
            if f"_id: {pid}_" in lines[i]:
                return path, lines, i
    return None


def apply_add_monthly(mem, p):
    found = find_monthly_row(mem, p["id"])
    if found:
        return False
    path = monthly_path(mem, p["creado"])
    lines = ensure_monthly(path, p["creado"][:7])
    nums = [int(c[0]) for _, c in table_rows(lines) if c and c[0].isdigit()]
    n = (max(nums) + 1) if nums else 1
    row = (f"| {n} | {p['text']} _id: {p['id']}_ | {p['prioridad']} | {p['creado']} "
           f"| {p['origen']} | | |")
    at = last_table_line(lines)
    if at is None:
        raise Quarantine(f"no-anchor: {os.path.basename(path)} no tiene tabla")
    lines.insert(at + 1, row)
    atomic_write(path, lines)
    return True


def apply_resolve_monthly(mem, p):
    found = find_monthly_row(mem, p["id"])
    if not found:
        log(f"WARN monthly: sin fila con id {p['id']} — llenar Resuelto a mano si aplica")
        return False
    path, lines, i = found
    cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
    while len(cells) < 7:
        cells.append("")
    if cells[5]:
        return False  # ya resuelto (idempotente)
    parts = [x for x in (p.get("sesion", ""), p["estado"], p.get("nota", "")) if x]
    cells[5] = p.get("fecha") or date.today().isoformat()
    cells[6] = " — ".join(parts)
    lines[i] = "| " + " | ".join(cells) + " |"
    atomic_write(path, lines)
    return True


# ----------------------------------------------------------------------------- dispatch
def validate(ev):
    if not isinstance(ev, dict) or ev.get("v") != 1:
        raise Quarantine("malformed: esquema desconocido (v != 1)")
    t = ev.get("type")
    p = ev.get("payload")
    if not isinstance(p, dict):
        raise Quarantine("malformed: payload ausente")
    if t == "pendiente.add":
        for k in ("id", "text", "prioridad", "origen", "creado"):
            if not p.get(k):
                raise Quarantine(f"malformed: pendiente.add sin '{k}'")
        if p["prioridad"].lower() not in HEADERS:
            raise Quarantine(f"malformed: prioridad '{p['prioridad']}' desconocida")
    elif t == "pendiente.resolve":
        for k in ("id", "estado"):
            if not p.get(k):
                raise Quarantine(f"malformed: pendiente.resolve sin '{k}'")
    else:
        raise Quarantine(f"malformed: tipo '{t}' desconocido")
    if not re.match(r"^p-[0-9a-f]{10}$", p["id"]):
        raise Quarantine(f"malformed: id '{p['id']}' invalido")
    return t, p


def apply_event(mem, ev):
    t, p = validate(ev)
    if t == "pendiente.add":
        a = apply_add_index(mem, p)
        b = apply_add_monthly(mem, p)
        return a or b
    a = apply_resolve_index(mem, p)
    b = apply_resolve_monthly(mem, p)
    return a or b


def move_to(src, dest_dir, reason=None):
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(src))
    if os.path.exists(dest):
        dest += f".{uuid.uuid4().hex[:6]}"
    os.replace(src, dest)
    if reason:
        with open(dest + ".reason", "w", encoding="utf-8") as fh:
            fh.write(reason + "\n")


def compact(mem, budget, quiet):
    journal = os.path.join(mem, ".journal")
    pending = os.path.join(journal, "pending")
    if not os.path.isdir(pending):
        names = []
    else:
        names = sorted(n for n in os.listdir(pending) if n.endswith(".json"))
    # El lock se toma aunque pending/ este vacio: la prueba de robo de lock depende de eso y
    # es barato (un mkdir). El fast-path "no llamar si no hay nada" vive en los hooks.
    lock = Lock(journal, budget)
    if not lock.acquire():
        log("BUSY")
        if not quiet:
            print(f"JOURNAL busy pending_left={len(names)}")
        return 0
    applied = quarantined = noop = 0
    try:
        # Re-listar bajo lock: entre el listado y el mkdir pudieron entrar eventos.
        names = sorted(n for n in os.listdir(pending) if n.endswith(".json")) \
            if os.path.isdir(pending) else []
        for n in names:
            src = os.path.join(pending, n)
            try:
                with open(src, encoding="utf-8") as fh:
                    ev = json.load(fh)
            except (OSError, ValueError) as e:
                move_to(src, os.path.join(journal, "quarantine"), f"malformed: {e}")
                quarantined += 1
                log(f"QUARANTINE {n} malformed")
                continue
            try:
                changed = apply_event(mem, ev)
            except Quarantine as q:
                move_to(src, os.path.join(journal, "quarantine"), str(q))
                quarantined += 1
                log(f"QUARANTINE {n} {q}")
                continue
            ym = time.strftime("%Y-%m", time.gmtime(int(ev.get("ts", 0)) / 1e9))
            move_to(src, os.path.join(journal, "applied", ym))
            if changed:
                applied += 1
                log(f"APPLIED {n}")
            else:
                noop += 1  # replay de un evento ya aplicado: se archiva, no cuenta como cambio
                log(f"NOOP {n}")
            lock.refresh()
    finally:
        lock.release()
    left = len([n for n in os.listdir(pending) if n.endswith(".json")]) \
        if os.path.isdir(pending) else 0
    qdir = os.path.join(journal, "quarantine")
    qtotal = len([n for n in os.listdir(qdir) if n.endswith(".json")]) if os.path.isdir(qdir) else 0
    if not quiet or applied or quarantined:
        print(f"JOURNAL applied={applied} quarantined={quarantined} pending_left={left}"
              + (f" noop={noop}" if noop else "")
              + (f" quarantine_total={qtotal}" if qtotal else ""))
    return 0


def main():
    global LOG_FILE
    ap = argparse.ArgumentParser(description="Aplica los eventos pendientes del journal.")
    ap.add_argument("--memory-dir")
    ap.add_argument("--budget", type=float, default=10.0)
    ap.add_argument("--log")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    LOG_FILE = a.log
    mem = resolve_memory_dir(a.memory_dir)
    if not os.path.isdir(mem):
        sys.exit(f"journal-compact: no existe el directorio de memoria: {mem}")
    sys.exit(compact(mem, a.budget, a.quiet))


if __name__ == "__main__":
    main()
