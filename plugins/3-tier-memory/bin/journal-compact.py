#!/usr/bin/env python3
"""
3-tier-memory plugin: compactador unico del journal (v2.12.0, Fases 1 y 2).

Aplica los eventos de memory/.journal/pending/ a los indices markdown, en orden de nombre
(= orden de emision), bajo un lock de directorio. Primitiva: mkdir — en POSIX, mkdir(2) es
atomico entre procesos (uno crea, el resto recibe EEXIST). Medido con la prueba de aceptacion
(2026-09-03) en macOS, Linux (python:3.12-slim, kernel 6.8) y Windows (Git Bash en
windows-latest, Python 3.12 nativo, sys.platform win32); en Windows ademas una sonda directa:
16 procesos x 40 rondas compiten por el mismo os.mkdir y siempre gana exactamente 1
(CreateDirectoryW es atomico). flock no existe como CLI en macOS, por eso no se usa. Cada .md
se escribe a tmp + os.replace; el os.replace (tambien el que mueve eventos a applied/ y
quarantine/ y el que sella el lock) se reintenta REPLACE_RETRIES veces ante PermissionError
porque en Windows un antivirus, el indexador u otro compactador pueden tener el archivo abierto
un instante; por la misma razon el lock se borra con rmtree_with_retry (medido: sin reintento
el lock quedaba huerfano en 1 de 5 ensayos en Windows). Cada evento aplicado se mueve a
applied/YYYY-MM/; un evento invalido o cuyo ancla no existe va a quarantine/ con un archivo
.reason al lado. Nunca se pierde un evento en silencio. Excepcion deliberada (2.22.0): un ancla
que el compactador sabe escribir sin mover nada se escribe — si falta el header de prioridad de
un `pendiente.add` (o de un `pendiente.reopen`), se crea y el evento se aplica, porque eso es el
estado normal de una instalacion anterior a 2.12.0 y mandarlo a cuarentena convertia una
migracion mecanica en trabajo para una persona.

Idempotente: re-aplicar un evento ya aplicado es no-op (la linea ya existe / ya no existe).
Deltas anclados, nunca regeneracion: insertar tras el header de prioridad, borrar linea por
id, llenar celda por id. Las ediciones a mano del humano sobreviven.

Fase 2 (sesiones, reglas, planes, research) — mismo principio, anclas de tabla:
  session.add      fila arriba de la tabla '## Sessions' de _session-index.md (clave: slug);
                   si ya existe, rellena status/summary/commit; poda a las 10 mas recientes
                   por la columna Fecha (filas sin fecha valida no se podan).
  learning.add     crea learnings/<topic>.md y su fila en '## Topic Files' si faltan; agrega
                   la regla con numero max+1 (bajo este lock: dos agentes nunca reciben el
                   mismo numero) al final de --section o del ultimo bloque antes de
                   '## Related'; si el archivo solo usa bullets, agrega bullet. --quickref
                   agrega la version corta numerada (max+1) en '## Quick Reference'.
                   Idempotente por texto normalizado.
  plan.upsert      fila en '## Plans' por [[plans/plan-<slug>]] o titulo; actualiza Status,
                   Sesion, Pendientes, Learnings (Fecha no cambia en updates); poda
                   completed/abandoned a los 5 mas recientes por Fecha.
  research.upsert  fila en '## Active Research' o '## Completed Research' por
                   [[research/<slug>]] o Tema; completed la mueve de Active a Completed y un
                   research completado no vuelve a Active (monotono: reabrir es a mano). La celda
                   Archivo de una fila completada lleva `_completado: YYYY-MM-DD_` (fecha del
                   evento); la poda de Completed (5 mas recientes) va por esa fecha, y las filas
                   sin ella (a mano, o anteriores a 2.12.0) nunca se podan — igual que sesiones.
  Todo indice que se escribe recibe `updated: <hoy>` en su frontmatter.

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
pending_left=N [rescued=N] [noop=N]` salvo --quiet (en ese caso solo imprime si applied>0,
quarantined>0 o rescued>0). `rescued=N` son eventos que una version anterior mando a cuarentena por
un ancla que esta ya crea sola: se devuelven a pending/ y se aplican en la misma pasada.
`applied` cuenta solo eventos que cambiaron algo; un replay de evento ya aplicado se archiva
y cuenta en `noop`.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import time
import unicodedata
import uuid
from datetime import date

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

STALE_SECONDS = 60
POLL_SECONDS = 0.05
REPLACE_RETRIES = 5  # Windows: antivirus/indexador pueden tener el .md abierto un instante
EOL_DEFAULT = "\n"   # fichero nuevo o sin CRLF: LF, en cualquier sistema operativo
_ESCRITO = {}         # ruta absoluta -> sha256 de lo que atomic_write dejo en ella
MESES = ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio", "Julio", "Agosto",
         "Septiembre", "Octubre", "Noviembre", "Diciembre"]
ID_RE = re.compile(r"_id: (p-[0-9a-f]{10})_")
HEADERS = {"alta": "## Alta prioridad", "media": "## Media prioridad", "baja": "## Baja prioridad"}
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")   # tambien guarda contra '../'
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
CELL_SPLIT = re.compile(r"(?<!\\)\|")   # un `\|` dentro de una celda (alias de wikilink) no separa
MAX_SESSIONS = 10
MAX_PLANS_DONE = 5
MAX_RESEARCH_DONE = 5
COMPLETADO_RE = re.compile(r"_completado: (\d{4}-\d{2}-\d{2})_")
RESEARCH_STATUS = ("active", "completed")

LOG_FILE = None


def log(msg):
    if LOG_FILE:
        # newline="\n" tambien en el append: en modo texto, Windows escribiria CRLF y el log
        # quedaria MEZCLADO segun donde corriera cada pasada que le anade lineas.
        with open(LOG_FILE, "a", encoding="utf-8", newline="\n") as fh:
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


def replace_with_retry(src, dst):
    """os.replace con REPLACE_RETRIES intentos ante PermissionError (Windows: antivirus o
    indexador con el archivo abierto un instante). Entre intentos espera 50, 100, 150 y 200 ms
    (4 esperas para 5 intentos); tras el ultimo fallo propaga sin dormir.
    Otros errores (ENOENT, EXDEV) no se reintentan: no son transitorios."""
    for attempt in range(REPLACE_RETRIES):
        try:
            os.replace(src, dst)
            return
        except PermissionError:
            if attempt == REPLACE_RETRIES - 1:
                raise
            time.sleep(0.05 * (attempt + 1))


def rmtree_with_retry(path):
    """shutil.rmtree con REPLACE_RETRIES intentos. En Windows borrar un archivo que otro proceso
    tiene abierto da PermissionError (WinError 32): un compactador en espera lee acquired_at cada
    50 ms, asi que el que libera el lock choca con el a menudo. Medido en windows-latest
    (2026-09-03): con un solo intento el lock quedaba huerfano y los demas salian "busy" hasta el
    TTL. En POSIX el primer intento siempre basta. Devuelve True si el directorio ya no existe."""
    for attempt in range(REPLACE_RETRIES):
        shutil.rmtree(path, ignore_errors=True)
        if not os.path.exists(path):
            return True
        time.sleep(0.05 * (attempt + 1))
    return not os.path.exists(path)


def detect_eol(path):
    """Salto de linea que YA usa el fichero, para reescribirlo sin convertirlo.

    Misma regla que normalize-pendientes.py (`"\r\n" in text`) y a proposito: los dos tocan los
    mismos ficheros, y si discreparan cada pasada le daria la vuelta al fichero entero. Un fichero
    nuevo, vacio o sin ningun CRLF sale en LF."""
    try:
        with open(path, "rb") as fh:
            return "\r\n" if b"\r\n" in fh.read() else EOL_DEFAULT
    except OSError:
        return EOL_DEFAULT


def atomic_write(path, lines):
    """Escribe `lines` unidas por el salto de linea del propio fichero, garantizando salto final.

    read_lines parte por "\n", asi que el ultimo elemento de un fichero bien formado es "" — el
    centinela del salto final. Cuando un applier inserta AL FINAL (p. ej. apply_add_index sobre una
    seccion vacia que es la ultima del fichero), ese centinela deja de ser el ultimo y el fichero
    queda sin newline final: lo siguiente que se anada con `>>` se pega a la ultima linea. Medido
    2026-09-11 con un item legacy anadido a mano tras un pendiente.add. Se normaliza aqui, en el
    unico sitio por el que pasan todas las escrituras.

    CONTRATO, en tres partes:

    1. Un fichero que llegue SIN salto final sale CON el. Eso rompe el "byte a byte" para esa
       entrada concreta — a proposito: en `memory/` un fichero sin newline final es el bug, no un
       formato a preservar. (Lo marco el adversario en su ronda 3.)
    2. El salto de linea es el que el fichero YA tenia, no el del sistema operativo. `newline=""`
       apaga la traduccion de Python, que era la que mandaba antes: con el modo texto por defecto,
       este mismo fichero salia LF en macOS y CRLF en Windows. Un CRLF sin salto final no recibia
       "un \n pelado" — se convertia ENTERO a LF (medido 2026-09-11 sobre los bytes, no sobre una
       lectura con universal newlines, que es ciega a esto). Un repositorio compartido entre las dos
       plataformas le daba la vuelta al fichero entero en cada compactacion.
    3. `[]` y `[""]` escriben un fichero de cero bytes. Es la representacion correcta del fichero
       vacio y sobrevive el viaje de vuelta: read_lines("") devuelve [""].

    Un fichero con saltos MEZCLADOS sale con uno solo, el que diga detect_eol."""
    if lines and lines[-1] != "":
        lines = list(lines) + [""]
    eol = detect_eol(path)
    tmp = f"{path}.{os.getpid()}.tmp"
    datos = eol.join(lines)
    with open(tmp, "w", encoding="utf-8", newline="") as fh:
        fh.write(datos)
    replace_with_retry(tmp, path)
    # Se apunta el hash de lo que ACABAMOS de escribir. El sellado usa esto en vez de releer el
    # disco, para que una escritura ajena entre la ultima escritura del compactador y su sellado
    # no se cuele en la linea base. Misma razon que el `estado` de --check-drift. (Ronda 7.)
    _ESCRITO[os.path.abspath(path)] = hashlib.sha256(datos.encode("utf-8")).hexdigest()


def resolve_memory_dir(explicit):
    cand = explicit or os.environ.get("MEMORY_DIR")
    if cand:
        return os.path.abspath(cand)
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    local = os.path.join(proj, "memory")
    # .journal/ tambien vale como centinela: si alguien borro _pendientes.md, este es justo el
    # momento en que hay que poder decirlo, no el momento de quedarse ciego. (Ronda 6.)
    if os.path.isfile(os.path.join(local, "_pendientes.md")) or os.path.isdir(os.path.join(local, ".journal")):
        return local
    encoded = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(proj))
    auto = os.path.join(os.path.expanduser("~"), ".claude", "projects", encoded, "memory")
    if os.path.isfile(os.path.join(auto, "_pendientes.md")) or os.path.isdir(os.path.join(auto, ".journal")):
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
        # newline="\n" y encoding explicitos: es un marcador interno, sus bytes no deben depender
        # del sistema operativo ni de la configuracion regional del proceso.
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(value)
        replace_with_retry(tmp, os.path.join(self.dir, name))

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
            except FileExistsError:
                pass
            except OSError:
                return False  # fs de solo lectura, permisos: fail-open, no bloquear
            else:
                self.held = True
                try:
                    self._stamp()
                except OSError:
                    pass  # sin marcador, _acquired_at() usa la mtime del directorio: el lock sigue valido
                return True
            if self._is_stale():
                # Solo un proceso reclama: el que gana el mkdir del steal-gate. Re-verifica
                # el TTL dentro del gate — el lock pudo refrescarse o cambiar de dueno.
                try:
                    os.mkdir(self.steal)
                    try:
                        if self._is_stale():
                            rmtree_with_retry(self.dir)
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
        if not rmtree_with_retry(self.dir):
            log("RELEASE-FAILED")  # quedara huerfano hasta el TTL; lo roba el siguiente
        self.held = False


# ----------------------------------------------------------------------------- _pendientes.md
def find_id_line(lines, pid):
    for i, line in enumerate(lines):
        if line.lstrip().startswith("- [ ]") and f"_id: {pid}_" in line:
            return i
    return None


def line_text(line):
    s = line.strip()[5:].strip()
    return normalize_text(re.sub(r"\s*—\s*_(origen|creado|id|revisar):[^—]*", "", s))


def header_index(lines, prio):
    key = prio.lower()
    for i, line in enumerate(lines):
        if line.strip().lower().startswith(f"## {key}"):
            return i
    return None


# --- Anclas de prioridad: crearlas es parte de aplicar, no trabajo de una persona ------------
# Hasta 2.21.4 un `pendiente.add` sobre un `_pendientes.md` sin el header de su prioridad iba a
# quarantine/ con `no-anchor`, y el aviso pedia intervencion humana. Es el estado NORMAL de toda
# instalacion anterior a 2.12.0 (medido 2026-09-03: 9 de 38 proyectos locales sin al menos uno de
# los tres headers), y desde 2.12.1 el hook SessionStart ya lo arreglaba solo... salvo en los dos
# casos que se dan justo cuando duele: el plugin se actualiza con la sesion YA abierta (no hay
# otro SessionStart), y dos agentes arrancan a la vez (el normalizador pide el lock con 1 s de
# presupuesto y si no lo consigue no hace nada). Un header que falta es un ancla que el
# compactador sabe escribir; escribirla no pierde ni mueve nada, asi que cuarentenar el evento
# era mandarle a una persona un trabajo mecanico. La cuarentena queda para lo que de verdad
# necesita ojos: JSON roto, colision de id, fecha imposible, ancla borrada a mano.
#
# La politica de DONDE se inserta vive aqui y solo aqui: `normalize-pendientes.py` (hook
# SessionStart) importa estas dos funciones de este modulo. Dos copias de la misma regla es como
# se desincronizan (learning 72).
CANON_PRIOS = [("alta", HEADERS["alta"]), ("media", HEADERS["media"]), ("baja", HEADERS["baja"])]
ANY_HEADER_RE = re.compile(r"^##\s+", re.I)


def section_end(lines, start):
    """Indice de la primera linea `## ` despues de `start` (o len(lines))."""
    for i in range(start + 1, len(lines)):
        if ANY_HEADER_RE.match(lines[i]):
            return i
    return len(lines)


def plan_header_insertions(lines, keys=None):
    """[(indice, header)] a insertar para que existan los headers `keys` (default: los tres).

    Un header que falta va pegado a su vecino canonico: al final de la seccion del que le
    precede en el orden Alta, Media, Baja si existe, y si no, justo antes del que le sigue. Si
    los existentes estan desordenados NO se reordenan. Si no hay ninguno, van justo antes de
    `## Related` (o al final). Ninguna otra seccion se toca: `## Abiertos`, `## Como usar` y lo
    que tenga el usuario se quedan donde estan.
    """
    present = {key: header_index(lines, key) for key, _ in CANON_PRIOS}
    missing = [(key, h) for key, h in CANON_PRIOS
               if present[key] is None and (keys is None or key in keys)]
    if not missing:
        return []
    if all(v is None for v in present.values()):
        rel = header_index(lines, "related")
        at = rel if rel is not None else len(lines)
        return [(at, h) for _, h in missing]
    plan = []
    order = [k for k, _ in CANON_PRIOS]
    for key, h in missing:
        i = order.index(key)
        earlier = [present[k] for k in order[:i] if present[k] is not None]
        later = [present[k] for k in order[i + 1:] if present[k] is not None]
        if earlier:
            at = section_end(lines, max(earlier))
        elif later:
            at = min(later)
        else:
            at = len(lines)
        plan.append((at, h))
    return plan


def insert_headers(lines, plan):
    """Aplica un plan de `plan_header_insertions` y devuelve las lineas nuevas."""
    out = list(lines)
    rank = {h: i for i, (_, h) in enumerate(CANON_PRIOS)}
    # De atras hacia delante para que los indices previos sigan valiendo; a igual indice, primero
    # Baja, luego Media, luego Alta, para que queden en orden canonico.
    for at, h in sorted(plan, key=lambda x: (x[0], rank[x[1]]), reverse=True):
        block = [h, ""]
        if at > 0 and out[at - 1].strip() != "":
            block = ["", h, ""]
        if at < len(out) and out[at].strip() == "":
            block = block[:-1]
        out[at:at] = block
    return out


def ensure_header(lines, prio):
    """(lineas, indice_del_header, creado). Crea el header de `prio` si falta."""
    h = header_index(lines, prio)
    if h is not None:
        return lines, h, False
    key = prio.lower()
    if key not in HEADERS:
        return lines, None, False
    lines = insert_headers(lines, plan_header_insertions(lines, keys={key}))
    return lines, header_index(lines, prio), True


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
    lines, h, _creado = ensure_header(lines, p["prioridad"])
    if h is None:
        # Guarda, no camino: `validar` ya cuarentena una prioridad no canonica como `malformed`
        # antes de llegar aqui. Se queda para que un llamador futuro no inserte en None.
        raise Quarantine(f"no-anchor: prioridad '{p['prioridad']}' no es Alta, Media ni Baja")
    rev = f" — _revisar: {p['revisar']}_" if p.get("revisar") else ""
    new = (f"- [ ] {p['text']} — _origen: {p['origen']}_ — _creado: {p['creado']}_ "
           f"— _id: {p['id']}_{rev}")
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
    # `len(lines) - 1` y no `len(lines)`: read_lines parte por "\n", asi que el ultimo elemento
    # es el centinela del salto final del archivo. Borrarlo deja el fichero sin newline final.
    if 0 < i < len(lines) - 1 and lines[i].strip() == "" and lines[i - 1].strip() == "":
        del lines[i]
    atomic_write(path, lines)
    return True


# ----------------------------------------------------------------------------- pendientes/YYYY-MM.md
def escape_cell(text):
    """Texto apto para una celda de tabla: una linea, `|` suelto escapado (`\\|` ya escrito se respeta).

    Inversa de split_cells/CELL_SPLIT. Sin esto, un `|` del texto parte la fila y la deja
    irresoluble (ver apply_resolve_monthly).
    """
    t = re.sub(r"\s+", " ", normalize_text(text))
    return re.sub(r"(?<!\\)\|", r"\\|", t)


def monthly_path(mem, creado):
    return os.path.join(mem, "pendientes", creado[:7] + ".md")


def anotar_nota_perdida(mem, path, pid, nota):
    """Guarda en disco la nota de cierre que no cabe en una fila sin `Sesion resolucion`.

    El `WARN` solo no basta: `recall.sh` corre el compactador con `--quiet >/dev/null 2>&1`, asi
    que por ese camino la nota se iria sin dejar rastro — "no en silencio" era cierto para el
    checkpoint y falso para ese hook (adversario externo, ronda 1, H4). Esto no reescribe la
    tabla de nadie: deja la nota en un log propio del journal, con su id y su fichero, para que
    se pueda recuperar a mano.
    """
    try:
        d = os.path.join(mem, ".journal")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "notas-sin-columna.log"), "a",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(f"{date.today().isoformat()}\t{os.path.basename(path)}\t{pid}\t{nota}\n")
        return True
    except Exception:
        return False


def header_issue(lines):
    """Que le pasa a la cabecera de este mensual, o None si esta bien. No la arregla.

    `ensure_monthly` escribe la cabecera canonica de 7 columnas SOLO al crear el fichero, y
    hasta 2.18.0 nadie la volvia a mirar: un mensual con cabecera de 5 columnas convivia
    indefinidamente con filas de 7 que el propio compactador le escribia encima, sin un aviso.
    Medido 2026-09-11 en una instalacion real: `2026-08.md` con 5 columnas — le faltaba
    `Sesion resolucion`, justo la que registra que sesion cerro el item — y `2026-09.md` con 6.
    """
    hmap = header_map(lines)
    if hmap is None:
        return "cabecera ausente o con nombres de columna que no se reconocen"
    if hmap == list(range(7)):
        return None
    faltan = [CANON_COLS[c] for c in range(7) if c not in hmap]
    return f"cabecera de {len(hmap)} columnas; falta(n): {', '.join(faltan)}"


def ensure_monthly(path, ym):
    if os.path.isfile(path):
        lines = read_lines(path)
        problema = header_issue(lines)
        if problema:
            # No se reescribe: cambiar la cabecera de un historial ajeno es una migracion, y se
            # decidio no hacerla desde aqui. Se avisa, con el fichero y que columna falta.
            log(f"WARN monthly: {os.path.basename(path)} — {problema}. Las filas nuevas se "
                f"escriben con las 7 columnas canonicas; revisa la cabecera a mano.")
        return lines
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


# Columnas canonicas del mensual. El indice es el que usan TODOS los lectores y escritores
# (cells[COL_PRIO] es la prioridad, cells[COL_RESUELTO] la fecha de cierre), sea cual sea la
# forma que la fila tenga EN DISCO. Medido 2026-09-11 en una instalacion real: conviven cuatro
# formas — 7 celdas con numero, 6 con numero (sin `Sesion resolucion`), 6 sin numero y 5 sin
# numero (sin `#` ni `Sesion resolucion`) — porque `ensure_monthly` solo escribe la cabecera
# canonica al CREAR el fichero y nada la valida despues.
COL_NUM, COL_TEXT, COL_PRIO, COL_CREADO, COL_ORIGEN, COL_RESUELTO, COL_SESION = range(7)
CANON_COLS = ["#", "Pendiente", "Prioridad", "Creado", "Origen", "Resuelto", "Sesion resolucion"]
PRIO_CELL = re.compile(r"^(Alta|Media|Baja)$", re.I)
MID_RE = re.compile(r"_id:\s*(p-[0-9a-f]{10})_")
_COL_ALIAS = {"#": 0, "n": 0, "num": 0, "pendiente": 1, "item": 1, "prioridad": 2, "prio": 2,
              "creado": 3, "origen": 4, "resuelto": 5, "sesion resolucion": 6, "sesion": 6}


def _colkey(cell):
    """Nombre de columna comparable: minusculas, sin tildes, espacios colapsados."""
    t = unicodedata.normalize("NFD", (cell or "").strip().lower())
    t = "".join(c for c in t if not unicodedata.combining(c))
    return re.sub(r"\s+", " ", t).strip()


def header_map(lines):
    """[indice canonico de cada columna EN DISCO] leido de la cabecera, o None si no se reconoce.

    Una cabecera corta no tiene columnas *distintas*: tiene las canonicas menos algunas, y es la
    unica fuente que dice CUALES faltan sin adivinar. Se exige que los nombres sean canonicos,
    distintos y en orden creciente; cualquier otra cosa devuelve None y la fila se alinea por su
    forma.
    """
    for line in lines:
        s = line.strip()
        if not s.startswith("|") or is_separator(line):
            continue
        keys = [_colkey(c) for c in split_cells(line)]
        if keys and all(k in _COL_ALIAS for k in keys):
            idx = [_COL_ALIAS[k] for k in keys]
            if len(set(idx)) == len(idx) and idx == sorted(idx):
                return idx
        return None          # la primera fila de tabla no es una cabecera reconocible
    return None


def align_row(line, hmap=None):
    """(cells7, colmap) de una fila de mensual, o (None, motivo) si no se puede alinear.

    `cells7` sale SIEMPRE en orden canonico, asi que quien escribe indexa igual con una fila de
    7, de 6 o de 5 celdas, con numero o sin el. `colmap` dice que columna canonica ocupa cada
    celda en disco, para devolver la fila con SU MISMA forma (ver `render_row`): esto no
    normaliza ni numera nada, que es justo lo que no se quiere hacerle al historial de nadie.

    El ancla es la FECHA de `Creado`, no la prioridad. Una prioridad no canonica (`Media→Alta`,
    escrita a mano) es un problema de VALOR con las columnas en su sitio; exigirla aqui haria
    ilocalizable esa fila y el compactador le escribiria una segunda al lado — el mismo defecto
    que este alineador cierra. Los valores raros se reportan aparte (`odd_value_rows`).

    Donde NO se adivina, y por que. Una fila corta admite mas de una lectura: `| 56 | texto |
    Alta | 2026-07-20 | algo | algo |` puede ser "le falta `Sesion resolucion`" o "le falta
    `Origen`", y la fecha de `Creado` esta en su sitio en las dos. Si se elige mal, un cierre
    escribe la fecha sobre la celda equivocada — o sea que el lector tolerante INTRODUCE la
    perdida de datos que venia a cerrar (adversario externo, ronda 1, H1).
    La cabecera del fichero es lo que rompe el empate, y solo ella:
      - cabecera reconocida y la fila tiene SUS columnas -> mapa exacto;
      - cabecera reconocida y la fila es mas CORTA -> faltan las celdas FINALES, que es lo que
        significa una fila corta en markdown (la tabla la renderiza asi);
      - cabecera reconocida SIN `#` y la fila trae una celda mas, empezando por un numero -> es
        una fila de 7 que el compactador escribio en un fichero de cabecera corta;
      - cabecera NO reconocida -> solo se aceptan las dos formas donde NO falta ninguna columna
        (7 celdas con numero, 6 sin numero). Cualquier otra se devuelve sin alinear, con su
        motivo, y la cuenta `unaligned_rows`.
    """
    raw = split_cells(line)
    n = len(raw)
    if n < 4:
        return None, f"{n} celdas: menos que las cuatro minimas (texto, prioridad, creado, origen)"
    if n > 7:
        return None, f"{n} celdas: mas de 7 (un `|` crudo en el texto parte la fila)"
    numerada = bool(re.match(r"^\s*\d+\s*$", raw[0] or ""))
    cands = []
    if hmap:
        if len(hmap) == n:
            cands.append(list(hmap))
        elif n < len(hmap):
            cands.append(list(hmap[:n]))
        elif numerada and 0 not in hmap and n == len(hmap) + 1:
            cands.append([0] + list(hmap))
    if n == 7 and numerada:
        cands.append(list(range(0, 7)))
    elif n == 6 and not numerada:
        cands.append(list(range(1, 7)))
    for cmap in cands:
        if max(cmap) > 6:
            continue
        cells = [""] * 7
        for pos, col in enumerate(cmap):
            cells[col] = raw[pos]
        if DATE_RE.match(cells[COL_CREADO]):
            return cells, cmap
    if not cands:
        return None, (f"{n} celdas" + (" con numero" if numerada else " sin numero") +
                      ", y la cabecera del fichero no dice que columnas son: la fila admite mas "
                      f"de una lectura y no se adivina")
    return None, (f"{n} celdas y ninguna alineacion deja una fecha en `Creado` "
                  f"(candidatas: {cands})")


def render_row(cells7, cmap):
    """La fila de vuelta con la MISMA forma en disco que tenia. No normaliza ni numera.

    Las dos celdas finales vacias se escriben `| | |` como las escribe `apply_add_monthly`: con
    `join_cells` saldria `|  |  |` y la fila no volveria byte a byte a como nacio.
    """
    return re.sub(r"\|\s+\|\s+\|$", "| | |",
                  "| " + " | ".join(cells7[c] for c in cmap) + " |")


def monthly_rows(lines):
    r"""[(indice, cells7, colmap)] de cada fila alineable del mensual, CON o SIN numero.

    La version anterior filtraba por `^\|\s*\d+\s*\|`, asi que una fila sin la columna `#` no
    existia para nadie: `find_monthly_row` no la encontraba, `apply_add_monthly` escribia una
    SEGUNDA fila para el mismo pendiente y `apply_resolve_monthly` dejaba un WARN y perdia la
    fecha de cierre y la sesion que lo cerro. Medido 2026-09-11: 39 filas asi en una instalacion.
    """
    hmap = header_map(lines)
    out = []
    for i, line in enumerate(lines):
        s = line.strip()
        if not s.startswith("|") or is_separator(line):
            continue
        keys = [_colkey(c) for c in split_cells(line)]
        if keys and all(k in _COL_ALIAS for k in keys):
            continue                      # una fila cuyas celdas son TODAS nombres de columna
                                          # es la cabecera, no un pendiente
        cells, cmap = align_row(line, hmap)
        if cells is None:
            continue
        out.append((i, cells, cmap))
    return out


def table_rows(lines):
    """(indice, celdas) de cada fila NUMERADA de la tabla.

    Deliberadamente solo numeradas: lo unico que queda que la usa es el calculo del numero
    siguiente, que necesita justo las que llevan numero. Para localizar un pendiente por id,
    leer su prioridad o diagnosticar una fila, usar `monthly_rows`, que tambien ve las que no
    lo llevan.
    """
    out = []
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("|") and re.match(r"^\|\s*\d+\s*\|", s):
            cells = split_cells(line)
            out.append((i, cells))
    return out


def last_table_line(lines):
    last = None
    for i, line in enumerate(lines):
        if line.strip().startswith("|"):
            last = i
    return last


CADUCADOS = "_caducados.md"
CADUCADOS_HEAD = [
    "---",
    "type: pendientes-caducados",
    "---",
    "",
    "# Pendientes caducados",
    "",
    "Items archivados por edad (`expire-pendientes.py`). **No estan resueltos**: dejaron de ser un",
    "compromiso. La linea se guarda verbatim para que `pendiente.reopen` la devuelva intacta.",
    "",
]


def caducados_path(mem):
    return os.path.join(mem, "pendientes", CADUCADOS)


def apply_expire_index(mem, p):
    """Archiva la linea VERBATIM en pendientes/_caducados.md y la saca de _pendientes.md.

    ORDEN DELIBERADO: primero el destino, despues el origen. Al reves — como estaba — un fallo
    entre las dos escrituras deja la linea en ningun sitio. Asi el peor caso es que quede en los
    dos, que se ve y se repara. (Hallazgo del adversario, 2026-09-11.)"""
    path = os.path.join(mem, "_pendientes.md")
    if not os.path.isfile(path):
        raise Quarantine("no-index: _pendientes.md no existe")
    lines = read_lines(path)
    i = find_id_line(lines, p["id"])
    if i is None:
        return False  # idempotente: ya caducada o cerrada a mano
    verbatim = lines[i].rstrip("\n")
    # El evento trae la linea que el emisor vio; si cambio desde entonces, gana el disco pero
    # se avisa: el texto del archivo es el que el usuario recuperara con reopen.
    if p.get("line") and normalize_text(p["line"]) != normalize_text(verbatim):
        log(f"WARN expire: la linea {p['id']} cambio desde la emision — se archiva la del disco")

    cpath = caducados_path(mem)
    if os.path.isfile(cpath):
        clines = read_lines(cpath)
    else:
        os.makedirs(os.path.dirname(cpath), exist_ok=True)
        clines = list(CADUCADOS_HEAD)
    # La prioridad va en la marca: un item legacy no tiene fila mensual de donde deducirla, y sin
    # esto reopen lo devolvia a la seccion equivocada (visto en la primera corrida real).
    if not any(f"_id: {p['id']}_" in c for c in clines):
        marca = (f"_caducado: {p.get('fecha') or date.today().isoformat()}_"
                 f" — _dias: {p.get('dias', '?')}_ — _prio: {p.get('prioridad') or '?'}_")
        clines.append(f"{verbatim} — {marca}")
        atomic_write(cpath, clines)

    del lines[i]
    # `len(lines) - 1` y no `len(lines)`: read_lines parte por "\n", asi que el ultimo elemento
    # es el centinela del salto final del archivo. Borrarlo deja el fichero sin newline final.
    if 0 < i < len(lines) - 1 and lines[i].strip() == "" and lines[i - 1].strip() == "":
        del lines[i]
    atomic_write(path, lines)
    return True


def apply_expire_monthly(mem, p):
    """Marca la fila mensual como expired. Misma columna que resolve: el ledger no se bifurca."""
    found = find_monthly_row(mem, p["id"])
    if not found:
        log(f"WARN monthly: sin fila con id {p['id']} — caducado sin fila de Tier 3")
        return False
    path, lines, i, cells, cmap = found
    if cells[COL_RESUELTO]:
        return False  # ya cerrado (idempotente)
    cells[COL_RESUELTO] = p.get("fecha") or date.today().isoformat()
    nota = f"expired — sin actividad en {p.get('dias', '?')} dias"
    if COL_SESION in cmap:
        cells[COL_SESION] = nota
    else:
        guardada = anotar_nota_perdida(mem, path, p["id"], nota)
        destino = (".journal/notas-sin-columna.log" if guardada
                   else "NINGUN SITIO (no se pudo escribir el log)")
        log(f"WARN monthly: {os.path.basename(path)} no tiene columna `Sesion resolucion`; "
            f"{p['id']} queda con la fecha y la nota en {destino}: {nota}")
    lines[i] = render_row(cells, cmap)
    atomic_write(path, lines)
    return True


def apply_window(mem, p):
    """Pone o actualiza `_revisar: FECHA_` en la linea de Tier 2, sin tocar el resto.

    Existe para que /triage-3t no tenga que editar `_pendientes.md` a mano: con
    `journal_strict=1` esa edicion la deniega journal-guard.sh, asi que la instruccion manual
    era inaplicable en la configuracion que el propio plugin recomienda. (Adversario 2026-09-11.)"""
    path = os.path.join(mem, "_pendientes.md")
    if not os.path.isfile(path):
        raise Quarantine("no-index: _pendientes.md no existe")
    lines = read_lines(path)
    i = find_id_line(lines, p["id"])
    if i is None:
        log(f"WARN window: no hay linea abierta con id {p['id']}")
        return False
    nueva = re.sub(r"\s*—\s*_revisar: \d{4}-\d{2}-\d{2}_", "", lines[i].rstrip("\n"))
    nueva = f"{nueva} — _revisar: {p['revisar']}_"
    if nueva == lines[i]:
        return False                      # idempotente: ya tiene esa ventana
    lines[i] = nueva
    atomic_write(path, lines)
    return True


def apply_reopen(mem, p):
    """Reversa exacta de expire: devuelve la linea VERBATIM y limpia la fila mensual."""
    cpath = caducados_path(mem)
    if not os.path.isfile(cpath):
        raise Quarantine("no-caducados: no hay pendientes/_caducados.md que revertir")
    clines = read_lines(cpath)
    idx = None
    for k, line in enumerate(clines):
        if line.lstrip().startswith("- [ ]") and f"_id: {p['id']}_" in line:
            idx = k
            break
    if idx is None:
        return False  # idempotente: ya reabierto
    archivado = clines[idx]
    # Quitar solo la marca que anadio expire; el resto de la linea vuelve intacto.
    mprio = re.search(r"_prio: ([^_]*)_\s*$", archivado)
    prio_archivada = (mprio.group(1).strip() if mprio else "")
    verbatim = re.sub(
        r"\s+—\s+_caducado: \d{4}-\d{2}-\d{2}_ — _dias: [^_]*_(?: — _prio: [^_]*_)?\s*$",
        "", archivado)
    # ORDEN, igual que expire pero al reves: primero devolver la linea viva y solo despues
    # quitarla del archivo. El peor caso vuelve a ser "esta en los dos", nunca "en ninguno".
    path = os.path.join(mem, "_pendientes.md")
    lines = read_lines(path)
    if find_id_line(lines, p["id"]) is None:
        prio = p.get("prioridad") or prio_archivada
        if prio in ("", "?"):
            prio = ""
        if not prio:
            found = find_monthly_row(mem, p["id"])
            prio = found[3][COL_PRIO] if found else ""
        # Igual que en apply_add_index: si el header no esta, se crea. Sin prioridad conocida
        # (ni en el evento, ni en la linea archivada, ni en la fila mensual) el destino es Media.
        prio_key = prio.lower() if prio and prio.lower() in HEADERS else "media"
        lines, h, _creado = ensure_header(lines, prio_key)
        if h is None:
            raise Quarantine("no-anchor: _pendientes.md sin header de prioridad donde reinsertar")
        at = h + 1
        if at < len(lines) and lines[at].strip() == "":
            at += 1
        lines.insert(at, verbatim)
        if at + 1 < len(lines) and lines[at + 1].startswith("## "):
            lines.insert(at + 1, "")
        atomic_write(path, lines)

    clines = read_lines(cpath)           # releer antes de borrar: entre medias pudo escribir otro
    for k, line in enumerate(clines):
        if line.lstrip().startswith("- [ ]") and f"_id: {p['id']}_" in line:
            del clines[k]
            atomic_write(cpath, clines)
            break

    found = find_monthly_row(mem, p["id"])
    if found:
        mpath, mlines, i, cells, cmap = found
        # Una fila sin columna `Sesion resolucion` no pudo guardar el "expired —...", asi que la
        # marca de caducado es la FECHA: se limpia igual, y no se exige la nota para reabrir.
        if cells[COL_SESION].startswith("expired") or \
                (COL_SESION not in cmap and cells[COL_RESUELTO]):
            cells[COL_RESUELTO] = ""
            cells[COL_SESION] = ""
            mlines[i] = render_row(cells, cmap)
            atomic_write(mpath, mlines)
    return True


def find_monthly_row(mem, pid):
    """Busca la fila de ese id en cualquier mensual. (path, lines, idx, cells7, colmap) o None.

    El id se busca en la CELDA DE TEXTO y se toma el ULTIMO `_id:` de esa celda, que es el
    propio: el texto de un pendiente puede citar el id de otro, y buscar `_id: X_` en la linea
    entera devolvia la fila del que lo cita. Antes no se notaba porque la mitad de las filas era
    invisible; al verlas todas, ese falso positivo crece, asi que se cierra aqui.
    """
    d = os.path.join(mem, "pendientes")
    if not os.path.isdir(d):
        return None
    for fn in sorted(os.listdir(d), reverse=True):
        if not re.match(r"^\d{4}-\d{2}\.md$", fn):
            continue
        path = os.path.join(d, fn)
        lines = read_lines(path)
        for i, cells, cmap in monthly_rows(lines):
            ids = MID_RE.findall(cells[COL_TEXT])
            if ids and ids[-1] == pid:
                return path, lines, i, cells, cmap
    return None


def apply_add_monthly(mem, p):
    found = find_monthly_row(mem, p["id"])
    if found:
        return False
    path = monthly_path(mem, p["creado"])
    lines = ensure_monthly(path, p["creado"][:7])
    nums = [int(c[0]) for _, c in table_rows(lines) if c and c[0].isdigit()]
    n = (max(nums) + 1) if nums else 1
    # cell(): un `|` crudo del texto partiria la fila y la haria irresoluble (ver apply_resolve_monthly).
    row = (f"| {n} | {escape_cell(p['text'])} _id: {p['id']}_ | {p['prioridad']} | {p['creado']} "
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
    path, lines, i, cells, cmap = found
    # Las celdas llegan YA alineadas a las columnas canonicas (ver align_row): con una fila de 5
    # o 6 celdas, indexar en crudo ponia la fecha de cierre sobre `Origen`. Y el alineador usa
    # split_cells, no split("|"): un `|` dentro del texto (`sort \\| uniq -c`) partia la fila en
    # mas de 7 celdas y el pendiente no se podia cerrar nunca, en silencio.
    if cells[COL_RESUELTO]:
        return False  # ya resuelto (idempotente)
    parts = [x for x in (p.get("sesion", ""), p["estado"], p.get("nota", "")) if x]
    cells[COL_RESUELTO] = p.get("fecha") or date.today().isoformat()
    # escape_cell tambien aqui: una nota de cierre con un `|` (`7 filas con | reparadas`) volvia
    # a partir la fila en mas de 7 celdas, justo el defecto que este arreglo cierra del otro lado.
    nota = escape_cell(" — ".join(parts))
    if COL_SESION in cmap:
        cells[COL_SESION] = nota
    elif nota:
        # La fila no tiene donde guardarla. Se escribe la fecha (que si cabe), la nota va al log
        # del journal —que SOBREVIVE a un `--quiet >/dev/null`— y ademas se avisa. Normalizar la
        # fila aqui reescribiria historial ajeno, que es lo que se decidio no hacer.
        guardada = anotar_nota_perdida(mem, path, p["id"], nota)
        destino = (".journal/notas-sin-columna.log" if guardada
                   else "NINGUN SITIO (no se pudo escribir el log)")
        log(f"WARN monthly: {os.path.basename(path)} no tiene columna `Sesion resolucion`; "
            f"{p['id']} cierra con fecha y la nota queda en {destino}: {nota}")
    lines[i] = render_row(cells, cmap)
    atomic_write(path, lines)
    return True



# ----------------------------------------------------------------------------- tablas (Fase 2)
def split_cells(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return [c.strip() for c in CELL_SPLIT.split(s)]


def join_cells(cells):
    return "| " + " | ".join(cells) + " |"


def pad(cells, n):
    cells = list(cells)
    while len(cells) < n:
        cells.append("")
    return cells


def is_separator(line):
    return re.match(r"^\|\s*:?-+", line.strip()) is not None


def section_bounds(lines, header):
    """(start, end) del bloque bajo un header `## X`: start = indice del header, end = indice
    del siguiente `## ` (o len). None si el header no existe."""
    start = None
    for i, line in enumerate(lines):
        if line.strip().lower().startswith(header.lower()):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("## "):
            end = j
            break
    return start, end


def table_in(lines, start, end):
    """(header_row, sep_row, [filas de datos]) de la primera tabla en [start, end). None si no hay."""
    i = start
    while i + 1 < end:
        if lines[i].strip().startswith("|") and is_separator(lines[i + 1]):
            rows = []
            k = i + 2
            while k < end and lines[k].strip().startswith("|"):
                rows.append(k)
                k += 1
            return i, i + 1, rows
        i += 1
    return None


# Columnas de cada tabla-ancla que `need_table` sabe crear si el header falta DEL TODO. Mismo
# texto que documenta setup-memory.md Step 3 — si un dia difieren, el header nuevo sale con las
# columnas de aqui, no las de ahi, asi que hay que mantenerlos iguales a mano.
TABLE_COLUMNS = {
    "## Sessions": ["Fecha", "Sesion", "Status", "Resumen", "Commit"],
    "## Plans": ["Plan", "Status", "Fecha", "Sesion", "Pendientes", "Learnings"],
    "## Topic Files": ["Topic", "File", "When to consult"],
    "## Active Research": ["Tema", "Next step", "Origen", "Archivo"],
    "## Completed Research": ["Tema", "Resultado", "Archivo"],
}

# fname que need_table recibe para cada header de arriba — RESCATABLE_RE (mas abajo) lo usa para
# generar, sin duplicar el texto a mano, el motivo exacto que este archivo ya no cuarentena.
ANCHOR_FILES = {
    "## Sessions": "_session-index.md",
    "## Plans": "_plans-index.md",
    "## Topic Files": "_learnings.md",
    "## Active Research": "_research-index.md",
    "## Completed Research": "_research-index.md",
}


def find_tables(lines):
    """Todas las tablas markdown del archivo (no solo bajo un header dado).

    [(indice_del_header_de_seccion_o_None, hdr, sep, [filas])]. `indice_del_header_de_seccion` es
    la linea `## ...` que precede a la tabla (saltando lineas en blanco), o None si la tabla no
    esta bajo ningun `## `. Lo usa `need_table` para ADOPTAR una tabla ya existente con otro
    nombre de header, en vez de crear una segunda tabla vacia al lado de la real.
    """
    out = []
    i, n = 0, len(lines)
    while i + 1 < n:
        if lines[i].strip().startswith("|") and is_separator(lines[i + 1]):
            hdr, sep = i, i + 1
            rows = []
            k = sep + 1
            while k < n and lines[k].strip().startswith("|"):
                rows.append(k)
                k += 1
            j = hdr - 1
            while j >= 0 and lines[j].strip() == "":
                j -= 1
            sec_header = j if (j >= 0 and lines[j].startswith("## ")) else None
            out.append((sec_header, hdr, sep, rows))
            i = k
        else:
            i += 1
    return out


def orphan_pipe_rows(lines):
    """Cuenta lineas que empiezan por `|` y NO pertenecen a NINGUNA tabla que `find_tables`
    reconozca (necesita cabecera + fila separadora encima). Medido en 4 instalaciones reales
    (2026-09-14, revision adversarial): 98 filas asi, la mayoria en `paperclip` — filas de tabla
    sueltas de una version anterior a este formato, sin cabecera ni separador. Son invisibles
    para `find_row_anywhere`, asi que `need_table` las trata como una señal de dano previo, no
    como algo que auto-crear o adoptar pueda ver de forma segura.
    """
    cubiertas = set()
    for _sec, hdr, sep, rows in find_tables(lines):
        cubiertas.add(hdr)
        cubiertas.add(sep)
        cubiertas.update(rows)
    return sum(1 for i, line in enumerate(lines)
               if i not in cubiertas and line.strip().startswith("|"))


def need_table(lines, header, fname):
    sec = section_bounds(lines, header)
    if not sec:
        columns = TABLE_COLUMNS.get(header)
        if columns is None:
            raise Quarantine(f"no-anchor: falta '{header}' en {fname}")
        # Ancla ausente del todo — no un dato roto, un header que nunca se creo (instalacion
        # anterior a este anexo, o generada con otro texto: '## Historial de Sesiones' en vez de
        # '## Sessions'). Mismo criterio que ensure_header() para '## Alta/Media/Baja prioridad'
        # desde 2.22.0: el compactador crea el ancla que falta al aplicar, en vez de mandar el
        # evento a cuarentena.
        #
        # ADOPTAR, no duplicar (hallazgo adversarial 2026-09-14, reproducido contra datos reales
        # de 5 instalaciones): la primera version de este anexo creaba la tabla VACIA al final del
        # archivo cuando el header no aparecia, dejando la tabla vieja (con sus filas) intacta
        # PERO INVISIBLE para el resto de este modulo — `apply_session_add`/`apply_plan_upsert`
        # buscan duplicados SOLO en las filas de la tabla que devuelve `need_table`, asi que un
        # evento para una fila que ya existia en la tabla vieja no la encontraba y la insertaba
        # OTRA VEZ en la tabla nueva: el indice se partia en dos tablas con la misma fila, en
        # silencio. Antes de este anexo eso iba a cuarentena — visible y recuperable —, asi que la
        # version anterior de este mismo cambio dejaba el archivo PEOR que antes de tocarlo.
        #
        # Filas de tabla HUERFANAS (dano previo, no causado por este anexo): lineas que empiezan
        # por `|` pero no pertenecen a NINGUNA tabla que `find_tables` reconozca, porque no tienen
        # cabecera ni separador encima (medido en 4 instalaciones reales: 98 filas asi, la mayoria
        # en paperclip). Ni adoptar ni crear vacio es seguro aqui: esas filas son INVISIBLES para
        # `find_row_anywhere`, asi que un upsert futuro para una de ellas las duplicaria en
        # silencio. Antes de 2.24.0 esta instalacion no podia recibir NADA sin ancla — el evento
        # se cuarentenaba, visible y recuperable — asi que crear la tabla aqui seria PEOR que antes
        # para un archivo que ya esta danado. Se preserva esa misma seguridad: cuarentena, no
        # adivinar. Hallazgo adversarial, 2026-09-14 (ronda 4, sobre datos reales de paperclip).
        huerfanas = orphan_pipe_rows(lines)
        if huerfanas:
            raise Quarantine(
                f"no-anchor: falta '{header}' en {fname} y el archivo tiene {huerfanas} fila(s) "
                f"de tabla sin cabecera reconocible (dano previo) — crear o adoptar una tabla aqui "
                f"arriesga duplicar una de esas filas la proxima vez que se actualice. Repara esas "
                f"filas a mano antes de que esto se aplique solo.")

        # Cada uno de estos 5 archivos existe para UN SOLO tipo de tabla (o dos en
        # _research-index.md, distinguibles por su numero de columnas), asi que si hay EXACTAMENTE
        # una tabla en el archivo con el mismo numero de columnas que el ancla canonica, esa tabla
        # ES la tabla real con otro nombre — se renombra su header IN PLACE (o se le antepone el
        # header canonico si no tenia ninguno) y sus filas quedan, intactas, bajo el ancla correcta.
        # Solo cuando hay CERO o MAS DE UNA candidata (ambiguo: no se puede saber cual es, o de
        # verdad no hay ninguna) se crea una tabla vacia nueva, que es el unico caso donde la
        # version anterior de este cambio era correcta.
        candidatas = [t for t in find_tables(lines) if len(split_cells(lines[t[1]])) == len(columns)]
        if len(candidatas) == 1:
            sec_header, hdr, _sep, _rows = candidatas[0]
            if sec_header is not None:
                lines[sec_header] = header
            else:
                lines[hdr:hdr] = [header, ""]
        else:
            if lines and lines[-1].strip() != "":
                lines.append("")
            lines.append(header)
            lines.append("")
            lines.append("| " + " | ".join(columns) + " |")
            lines.append("|" + "|".join("---" for _ in columns) + "|")
        sec = section_bounds(lines, header)
    tab = table_in(lines, *sec)
    if not tab:
        raise Quarantine(f"no-anchor: '{header}' de {fname} no tiene tabla")
    return sec, tab


def plain(cell_text):
    """Texto de celda sin wikilinks ni enfasis, normalizado y en minusculas, para comparar."""
    t = re.sub(r"\[\[([^\]|]*?)(?:\\\|([^\]]*))?\]\]", lambda m: m.group(2) or m.group(1), cell_text)
    t = re.sub(r"\((?:inline|backfill)\)", "", t, flags=re.I)
    return normalize_text(re.sub(r"[*_`]", "", t)).lower()


def bump_updated(lines):
    if lines and lines[0].strip() == "---":
        for i in range(1, min(len(lines), 20)):
            if lines[i].strip() == "---":
                return
            if lines[i].startswith("updated:"):
                lines[i] = f"updated: {date.today().isoformat()}"
                return


def link_re(prefix, slug):
    return re.compile(r"\[\[" + re.escape(prefix + slug) + r"(\\\||\||\]\])")


def find_row_anywhere(lines, ncols, key_re):
    """Busca una fila que ya cite `key_re` (un wikilink EXACTO: `[[prefijo-slug]]`) en CUALQUIER
    tabla de `ncols` columnas del archivo — no solo en la que devuelve `need_table`.

    Hallazgo adversarial (2026-09-14): cuando el ancla falta y hay MAS de una tabla candidata del
    mismo ancho (ambiguo), `need_table` crea una tabla vacia nueva en vez de adivinar cual de las
    viejas adoptar — correcto, no se puede saber cual es sin ambiguedad. Pero la busqueda de
    duplicados de `apply_session_add`/`apply_plan_upsert` solo miraba las filas de ESA tabla
    (vacia), asi que una fila que ya vivia en una de las tablas viejas (paperclip: 70 planes bajo
    '## Active Plans'; scalar-api-docs: bajo '## Active/Completed Plans') quedaba invisible y se
    insertaba OTRA VEZ en la nueva — la misma duplicacion silenciosa que el ancla-adopcion (2.24.0,
    misma noche) ya arreglo para el caso de UNA sola candidata. Aqui se cierra para N candidatas:
    la busqueda de duplicados mira TODO el archivo, la insercion de una fila nueva sigue yendo solo
    a la tabla canonica.

    DELIBERADAMENTE sin el fallback por titulo plano (`tplain`) que si usan `apply_plan_upsert`/
    `apply_research_upsert` para un item `--inline` (sin wikilink). Una segunda ronda adversarial
    encontro que ampliar TAMBIEN ese fallback a todo el archivo enganchaba, por coincidencia de
    texto, una tabla ajena del mismo ancho de columnas que no tenia nada que ver (un ejemplo
    construido: una tabla '## Inventory' de 6 columnas con una fila 'Same Title') — pisando una
    celda que no era la del plan/research real. El wikilink es una cita EXACTA de un slug (`p-`,
    `[[plans/plan-<slug>]]`, etc.) y no tiene ese riesgo; el titulo plano si, porque solo depende
    de que el texto coincida. Por eso el fallback por titulo se queda ACOTADO a la tabla canonica
    en cada llamante (ver apply_plan_upsert / apply_research_upsert), como antes de esta ronda.
    """
    for _sec_header, hdr, _sep, rows in find_tables(lines):
        if len(split_cells(lines[hdr])) != ncols:
            continue
        for i in rows:
            if key_re.search(lines[i]):
                return i
    return None


def delete_rows(lines, idxs):
    for i in sorted(idxs, reverse=True):
        del lines[i]


def check_slug(value, what):
    if not isinstance(value, str) or not SLUG_RE.match(value):
        raise Quarantine(f"malformed: {what} '{value}' no es un slug valido")
    return value


# ----------------------------------------------------------------------------- _session-index.md
def session_alias(slug):
    return slug[11:] if re.match(r"^\d{4}-\d{2}-\d{2}-.+", slug) else slug


def apply_session_add(mem, p):
    path = os.path.join(mem, "_session-index.md")
    if not os.path.isfile(path):
        raise Quarantine("no-index: _session-index.md no existe")
    lines = read_lines(path)
    orig = list(lines)
    (start, end), (hdr, sep, rows) = need_table(lines, "## Sessions", "_session-index.md")
    key = link_re("sessions/", p["slug"])
    hit = find_row_anywhere(lines, 5, key)
    if hit is not None:
        cells = pad(split_cells(lines[hit]), 5)
        new = list(cells)
        for idx, k in ((2, "status"), (3, "summary"), (4, "commit")):
            if p.get(k):
                new[idx] = p[k]
        if new == cells:
            return False
        lines[hit] = join_cells(new)
    else:
        row = join_cells([p["date"], f"[[sessions/{p['slug']}\\|{session_alias(p['slug'])}]]",
                          p.get("status") or "", p.get("summary") or "", p.get("commit") or ""])
        lines.insert(sep + 1, row)   # la mas nueva arriba
        # Poda: solo filas con Fecha valida compiten; el resto se conserva tal cual.
        _, (hdr, sep, rows) = need_table(lines, "## Sessions", "_session-index.md")
        dated = [(i, split_cells(lines[i])[0]) for i in rows]
        dated = [(i, d) for i, d in dated if DATE_RE.match(d)]
        if len(dated) > MAX_SESSIONS:
            dated.sort(key=lambda x: (x[1], -x[0]), reverse=True)   # misma fecha: la de arriba gana
            delete_rows(lines, [i for i, _ in dated[MAX_SESSIONS:]])
    if lines == orig:
        return False   # la fila entro y la poda la saco en el acto (mas vieja que las 10): noop
    bump_updated(lines)
    atomic_write(path, lines)
    return True


# ----------------------------------------------------------------------------- learnings
def rule_text(line):
    """(numero|None, texto|None) de una linea de regla numerada o bullet."""
    s = line.strip()
    m = re.match(r"^(\d+)\.\s+(.*)$", s)
    if m:
        return int(m.group(1)), m.group(2)
    m = re.match(r"^[-*]\s+(.*)$", s)
    if m:
        return None, m.group(1)
    return None, None


def body_region(lines):
    """(inicio del cuerpo tras el frontmatter, indice de '## Related' o len)."""
    start = 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                start = i + 1
                break
    related = len(lines)
    for i in range(start, len(lines)):
        if lines[i].strip().lower().startswith("## related"):
            related = i
            break
    return start, related


def insert_at_section_end(lines, start, end, new_line):
    """Inserta new_line al final del bloque [start, end), antes de las lineas en blanco que
    preceden al siguiente header, y garantiza una linea en blanco despues."""
    at = end
    while at - 1 > start and lines[at - 1].strip() == "":
        at -= 1
    if at - 1 == start:            # seccion vacia: dejar una linea en blanco tras el header
        lines.insert(at, "")
        at += 1
    lines.insert(at, new_line)
    if at + 1 < len(lines) and lines[at + 1].strip() != "":
        lines.insert(at + 1, "")
    return at


def apply_learning_add(mem, p):
    topic = check_slug(p["topic"], "topic")
    title = p.get("title") or topic
    changed = False
    today = date.today().isoformat()

    tpath = os.path.join(mem, "learnings", topic + ".md")
    if not os.path.isfile(tpath):
        os.makedirs(os.path.dirname(tpath), exist_ok=True)
        fm = ["---", "type: learnings", f"topic: {topic}", f"created: {today}",
              f"updated: {today}", "status: active"]
        if p.get("importance"):
            fm.append(f"importance: {p['importance']}")
        fm += [f"last_verified: {today}", "---"]
        atomic_write(tpath, fm + [f"# {title}", "", "## Rules", "", "## Related",
                                  "- [[_learnings|Learnings Index]]", ""])
        changed = True

    ipath = os.path.join(mem, "_learnings.md")
    if not os.path.isfile(ipath):
        raise Quarantine("no-index: _learnings.md no existe")
    ilines = read_lines(ipath)
    tkey = link_re("learnings/", topic)
    if not any(tkey.search(l) for l in ilines):
        _, (hdr, sep, rows) = need_table(ilines, "## Topic Files", "_learnings.md")
        at = (rows[-1] + 1) if rows else (sep + 1)
        ilines.insert(at, join_cells([title, f"[[learnings/{topic}]]", p.get("when") or ""]))
        bump_updated(ilines)
        atomic_write(ipath, ilines)
        changed = True

    text = normalize_text(p.get("text") or "")
    if text:
        lines = read_lines(tpath)
        start, related = body_region(lines)
        parsed = [rule_text(l) for l in lines[start:related]]
        if not any(t and normalize_text(t) == text for _, t in parsed):
            nums = [n for n, _ in parsed if n]
            bullets = any(n is None and t for n, t in parsed)
            numbered = bool(nums) or not bullets
            new_line = f"{max(nums) + 1 if nums else 1}. {text}" if numbered else f"- {text}"
            section = p.get("section") or ""
            sec = section_bounds(lines, f"## {section}") if section else None
            if sec and sec[0] < related:
                insert_at_section_end(lines, sec[0], min(sec[1], related), new_line)
            elif section:
                at = related
                while at - 1 > start and lines[at - 1].strip() == "":
                    at -= 1
                lines[at:at] = ["", f"## {section}", "", new_line]
            else:
                insert_at_section_end(lines, start, related, new_line)
            bump_updated(lines)
            atomic_write(tpath, lines)
            changed = True

    q = normalize_text(p.get("quickref") or "")
    if q:
        ilines = read_lines(ipath)
        sec = section_bounds(ilines, "## Quick Reference")
        if not sec:
            raise Quarantine("no-anchor: falta '## Quick Reference' en _learnings.md "
                             "(la regla ya quedo en el topic file; agrega el Quick Ref a mano)")
        s0, s1 = sec
        parsed = [rule_text(l) for l in ilines[s0:s1]]
        if not any(t and normalize_text(t) == q for _, t in parsed):
            nums = [n for n, _ in parsed if n]
            insert_at_section_end(ilines, s0, s1, f"{max(nums) + 1 if nums else 1}. {q}")
            bump_updated(ilines)
            atomic_write(ipath, ilines)
            changed = True
    return changed


# ----------------------------------------------------------------------------- _plans-index.md
def apply_plan_upsert(mem, p):
    slug = check_slug(p["slug"], "slug")
    path = os.path.join(mem, "_plans-index.md")
    if not os.path.isfile(path):
        raise Quarantine("no-index: _plans-index.md no existe")
    lines = read_lines(path)
    orig = list(lines)
    _, (hdr, sep, rows) = need_table(lines, "## Plans", "_plans-index.md")
    key = link_re("plans/plan-", slug)
    tplain = plain(p["title"])
    hit = find_row_anywhere(lines, 6, key)
    if hit is None:
        # Fallback por titulo plano SOLO en la tabla canonica (no en todo el archivo): es para un
        # plan `--inline` (sin wikilink que buscar), y ampliarlo a cualquier tabla del mismo ancho
        # arriesga enganchar una fila ajena por coincidencia de texto. Ver find_row_anywhere.
        hit = next((i for i in rows if plain(split_cells(lines[i])[0]) == tplain), None)
    if hit is not None:
        cells = pad(split_cells(lines[hit]), 6)
        new = list(cells)
        for idx, k in ((1, "status"), (3, "sesion"), (4, "pendientes"), (5, "learnings")):
            if p.get(k):
                new[idx] = p[k]
        # La celda 0 tambien: `--title` se aceptaba y se ignoraba en silencio al actualizar, asi
        # que el indice conservaba el titulo con el que nacio el plan aunque su contenido ya dijera
        # otra cosa. Campo sin lector. Se reconstruye respetando la forma que tenia la celda
        # (enlace o `(inline)`), nunca inventando una nueva. Medido 2026-09-11 sobre
        # plan-pendientes-diferidos-v2.13.0, cuyo titulo nombraba dos mecanismos ya descartados.
        if p.get("title"):
            new[0] = (f"{p['title']} (inline)" if cells[0].rstrip().endswith("(inline)")
                      else f"[[plans/plan-{slug}\\|{p['title']}]]")
        if new == cells:
            return False
        lines[hit] = join_cells(new)
    else:
        plan_cell = f"{p['title']} (inline)" if p.get("inline") \
            else f"[[plans/plan-{slug}\\|{p['title']}]]"
        lines.insert(sep + 1, join_cells([plan_cell, p["status"], p["date"], p.get("sesion") or "",
                                          p.get("pendientes") or "", p.get("learnings") or ""]))
    _, (hdr, sep, rows) = need_table(lines, "## Plans", "_plans-index.md")
    done = []
    for i in rows:
        c = pad(split_cells(lines[i]), 3)
        st = c[1].lower().split()
        if st and st[0] in ("completed", "abandoned") and DATE_RE.match(c[2]):
            done.append((i, c[2]))
    if len(done) > MAX_PLANS_DONE:
        done.sort(key=lambda x: (x[1], -x[0]), reverse=True)
        delete_rows(lines, [i for i, _ in done[MAX_PLANS_DONE:]])
    if lines == orig:
        return False
    bump_updated(lines)
    atomic_write(path, lines)
    return True


# ----------------------------------------------------------------------------- _research-index.md
ACTIVE_PLACEHOLDER = "<!-- Sin research activo -->"


def find_research_row(lines, header, key, tplain):
    _, (hdr, sep, rows) = need_table(lines, header, "_research-index.md")
    # find_row_anywhere, no solo `rows`: mismo motivo que apply_session_add/apply_plan_upsert
    # (hallazgo adversarial 2026-09-14) — con 2+ tablas candidatas del mismo ancho, `need_table`
    # crea una nueva y una fila que ya vivia en una vieja quedaba invisible para el duplicado.
    hit = find_row_anywhere(lines, len(TABLE_COLUMNS[header]), key)
    if hit is None:
        # Fallback por titulo plano SOLO en la tabla canonica: mismo riesgo de colision ajena que
        # en apply_plan_upsert si se ampliara a todo el archivo. Ver find_row_anywhere.
        hit = next((i for i in rows if plain(split_cells(lines[i])[0]) == tplain), None)
    return sep, rows, hit


def apply_research_upsert(mem, p):
    slug = check_slug(p["slug"], "slug")
    path = os.path.join(mem, "_research-index.md")
    if not os.path.isfile(path):
        raise Quarantine("no-index: _research-index.md no existe")
    lines = read_lines(path)
    need_table(lines, "## Active Research", "_research-index.md")
    need_table(lines, "## Completed Research", "_research-index.md")
    key = link_re("research/", slug)
    tplain = plain(p["tema"])
    archivo = "(inline)" if p.get("inline") else f"[[research/{slug}]]"
    changed = False

    if p["status"] == "active":
        sep, rows, hit = find_research_row(lines, "## Completed Research", key, tplain)
        if hit is not None:
            return False               # ya maduro: un research no vuelve a Active (monotono;
                                       # reabrir es una edicion a mano). Asi un replay de un
                                       # `active` viejo no deshace el `completed`.
        sep, rows, hit = find_research_row(lines, "## Active Research", key, tplain)
        if hit is not None:
            cells = pad(split_cells(lines[hit]), 4)
            new = list(cells)
            for idx, k in ((1, "next_step"), (2, "origen")):
                if p.get(k):
                    new[idx] = p[k]
            if new != cells:
                lines[hit] = join_cells(new)
                changed = True
        else:
            lines.insert(sep + 1, join_cells([p["tema"], p.get("next_step") or "",
                                              p.get("origen") or "", archivo]))
            changed = True
            a0, a1 = section_bounds(lines, "## Active Research")
            for j in range(a0, a1):
                if lines[j].strip() == ACTIVE_PLACEHOLDER:
                    del lines[j]
                    break
    else:
        sep, rows, hit = find_research_row(lines, "## Active Research", key, tplain)
        if hit is not None:            # madura: sale de Active
            del lines[hit]
            changed = True
            a0, a1 = section_bounds(lines, "## Active Research")
            tab = table_in(lines, a0, a1)
            if tab and not tab[2]:
                lines.insert(tab[1] + 1, ACTIVE_PLACEHOLDER)
        sep, rows, hit = find_research_row(lines, "## Completed Research", key, tplain)
        fecha = p.get("date") or time.strftime("%Y-%m-%d", time.gmtime(int(p.get("_ts", 0)) / 1e9))
        if hit is not None:
            cells = pad(split_cells(lines[hit]), 3)
            new = list(cells)
            if p.get("resultado"):
                new[1] = p["resultado"]
            if not COMPLETADO_RE.search(new[2]):
                # Fila anterior a 2.12.0 (o a mano): recibe la marca con la fecha del evento y
                # desde ahora compite en la poda por fecha.
                new[2] = f"{new[2]} _completado: {fecha}_".strip()
            if new != cells:
                lines[hit] = join_cells(new)
                changed = True
        else:
            lines.insert(sep + 1, join_cells([p["tema"], p.get("resultado") or "",
                                              f"{archivo} _completado: {fecha}_"]))
            changed = True
        # Poda por fecha, nunca por posicion: solo compiten las filas con `_completado:`; una fila
        # sin fecha (a mano, o anterior a 2.12.0) se conserva. Asi un `completed` viejo re-aplicado
        # entra con su fecha vieja y es el que sale, no una fila mas nueva del fondo.
        sep, rows, _ = find_research_row(lines, "## Completed Research", key, tplain)
        dated = []
        for i in rows:
            m = COMPLETADO_RE.search(lines[i])
            if m:
                dated.append((i, m.group(1)))
        if len(dated) > MAX_RESEARCH_DONE:
            dated.sort(key=lambda x: (x[1], -x[0]), reverse=True)
            delete_rows(lines, [i for i, _ in dated[MAX_RESEARCH_DONE:]])
            changed = True
    if changed:
        bump_updated(lines)
        atomic_write(path, lines)
    return changed


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
        # El compactador es su propia frontera de confianza: un evento puede llegar de otro
        # emisor, o escrito a mano. DATE_RE solo valida la forma y `2026-99-99` la pasa, se
        # persiste en la linea y luego revienta a los consumidores. (Adversario, ronda 3.)
        for campo in ("creado", "revisar"):
            v = p.get(campo)
            if not v:
                continue
            try:
                date.fromisoformat(str(v))
            except (ValueError, TypeError):
                raise Quarantine(f"malformed: pendiente.add con '{campo}' irreal: {v!r}")
    elif t == "pendiente.resolve":
        for k in ("id", "estado"):
            if not p.get(k):
                raise Quarantine(f"malformed: pendiente.resolve sin '{k}'")
    elif t == "pendiente.expire":
        if not p.get("id"):
            raise Quarantine("malformed: pendiente.expire sin 'id'")
        if not str(p.get("dias", "")).isdigit():
            raise Quarantine("malformed: pendiente.expire sin 'dias' numerico")
    elif t == "pendiente.reopen":
        if not p.get("id"):
            raise Quarantine("malformed: pendiente.reopen sin 'id'")
    elif t == "pendiente.window":
        if not p.get("id"):
            raise Quarantine("malformed: pendiente.window sin 'id'")
        # DATE_RE solo valida la forma: `2026-99-99` la pasa y luego revienta a los consumidores.
        try:
            date.fromisoformat(str(p.get("revisar", "")))
        except (ValueError, TypeError):
            raise Quarantine("malformed: pendiente.window sin 'revisar' con fecha real")
    elif t == "session.add":
        for k in ("slug", "date"):
            if not p.get(k):
                raise Quarantine(f"malformed: session.add sin '{k}'")
        if not (p.get("status") or p.get("summary") or p.get("commit")):
            raise Quarantine("malformed: session.add sin status/summary/commit")
        if not DATE_RE.match(str(p["date"])):
            raise Quarantine(f"malformed: date '{p['date']}' invalida")
        check_slug(p["slug"], "slug")
        return t, p
    elif t == "learning.add":
        if not p.get("topic"):
            raise Quarantine("malformed: learning.add sin 'topic'")
        check_slug(p["topic"], "topic")
        return t, p
    elif t == "plan.upsert":
        for k in ("slug", "title", "status", "date"):
            if not p.get(k):
                raise Quarantine(f"malformed: plan.upsert sin '{k}'")
        if not DATE_RE.match(str(p["date"])):
            raise Quarantine(f"malformed: date '{p['date']}' invalida")
        check_slug(p["slug"], "slug")
        return t, p
    elif t == "research.upsert":
        for k in ("slug", "tema", "status"):
            if not p.get(k):
                raise Quarantine(f"malformed: research.upsert sin '{k}'")
        if p["status"] not in RESEARCH_STATUS:
            raise Quarantine(f"malformed: status '{p['status']}' de research desconocido")
        if p.get("date") and not DATE_RE.match(str(p["date"])):
            raise Quarantine(f"malformed: date '{p['date']}' invalida")
        p["_ts"] = ev.get("ts", 0)   # respaldo para eventos sin `date` (emisor viejo)
        check_slug(p["slug"], "slug")
        return t, p
    else:
        raise Quarantine(f"malformed: tipo '{t}' desconocido")
    if not re.match(r"^p-[0-9a-f]{10}$", str(p["id"])):
        raise Quarantine(f"malformed: id '{p['id']}' invalido")
    return t, p


def apply_event(mem, ev):
    t, p = validate(ev)
    if t == "pendiente.add":
        a = apply_add_index(mem, p)
        b = apply_add_monthly(mem, p)
        return a or b
    if t == "pendiente.resolve":
        a = apply_resolve_index(mem, p)
        b = apply_resolve_monthly(mem, p)
        return a or b
    if t == "pendiente.expire":
        a = apply_expire_index(mem, p)
        b = apply_expire_monthly(mem, p)
        return a or b
    if t == "pendiente.reopen":
        return apply_reopen(mem, p)
    if t == "pendiente.window":
        return apply_window(mem, p)
    if t == "session.add":
        return apply_session_add(mem, p)
    if t == "learning.add":
        return apply_learning_add(mem, p)
    if t == "plan.upsert":
        return apply_plan_upsert(mem, p)
    return apply_research_upsert(mem, p)


def move_to(src, dest_dir, reason=None):
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(src))
    if os.path.exists(dest):
        dest += f".{uuid.uuid4().hex[:6]}"
    replace_with_retry(src, dest)
    if reason:
        with open(dest + ".reason", "w", encoding="utf-8", newline="\n") as fh:
            fh.write(reason + "\n")


# ------------------------------------------------------- huellas de los indices (v2.13.2)
# journal_strict deniega Edit/Write/MultiEdit sobre los indices, pero el hook es PreToolUse y
# **Bash no esta en su matcher**: un `>>`, un `sed -i` o un heredoc de Python escriben igual.
# No es un descuido de quien lo hace: una sesion en modo auto recibe la instruccion explicita de
# preferir Bash sobre Edit/Write, asi que ahi el guard no se salta a veces — se salta siempre.
# Medido 2026-09-11 sobre el historial JSONL: 96 escrituras a mano a un indice protegido desde que
# el journal es obligatorio (2026-09-02), en 9 proyectos, la ultima ese mismo dia.
#
# Esto NO intenta impedirlo — parsear Bash es adivinar, y un falso positivo bloquea trabajo bueno.
# Compara BYTES: el compactador guarda el sha256 de cada indice al escribirlo, y si en la pasada
# siguiente no coincide, alguien escribio fuera del journal. Exacto, sin falsos positivos, y
# despues del hecho a proposito: el objetivo es que no se acumule en silencio, no bloquear.
INDICES_FIJOS = ("_pendientes.md", "_learnings.md", "_session-index.md",
                 "_plans-index.md", "_research-index.md")
MENSUAL_RE = re.compile(r"^\d{4}-\d{2}\.md$")


def indices_protegidos(mem):
    """Los ficheros que pertenecen al compactador. Mismo conjunto que journal-guard.sh."""
    out = [n for n in INDICES_FIJOS if os.path.isfile(os.path.join(mem, n))]
    d = os.path.join(mem, "pendientes")
    if os.path.isdir(d):
        out += [f"pendientes/{n}" for n in sorted(os.listdir(d)) if MENSUAL_RE.match(n)]
    return out


def huella(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def _ruta_huellas(journal):
    return os.path.join(journal, "fingerprints.json")


def leer_huellas(journal):
    try:
        with open(_ruta_huellas(journal), encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def leer_estado(mem):
    """Hash de cada indice protegido, en UNA lectura. La unidad que se compara Y se sella."""
    return {rel: h for rel in indices_protegidos(mem)
            if (h := huella(os.path.join(mem, rel))) is not None}


def guardar_huellas(mem, journal, estado=None):
    """Re-sella la linea base con `estado`, o releyendo el disco si no se da.

    PASAR `estado` ES LO QUE CIERRA LA VENTANA, y costo dos intentos. La ronda 6 marco que
    --check-drift no tomaba el lock; lo arregle tomandolo. La ronda 7 mostro que no bastaba:
    **una escritura por Bash nunca pide `.journal/.lock`**, asi que tomar el lock no la bloquea ni
    la hace esperar. La ventana real no estaba entre dos `acquire`, sino entre las DOS LECTURAS DE
    BYTES — la de detectar y la de sellar — estuviera el lock libre o tomado. Lo que se sella tiene
    que ser exactamente lo que se comparo: una sola lectura, reusada. Si algo se escribe despues,
    queda FUERA de la linea base y la comprobacion siguiente lo ve."""
    d = leer_estado(mem) if estado is None else dict(estado)
    # Para los ficheros que ESTE proceso escribio, vale mas lo que escribio que lo que hay en
    # disco: si alguien los toco despues, esa escritura debe quedar FUERA de la linea base para
    # que la comprobacion siguiente la vea.
    for rel in list(d):
        h = _ESCRITO.get(os.path.abspath(os.path.join(mem, rel)))
        if h:
            d[rel] = h
    os.makedirs(journal, exist_ok=True)
    tmp = f"{_ruta_huellas(journal)}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(d, fh, indent=1, sort_keys=True)
    replace_with_retry(tmp, _ruta_huellas(journal))


def hay_lector():
    """¿Va a leer alguien lo que --check-drift imprima?

    AQUI Y NO EN EL LLAMANTE, y costo cinco rondas adversariales aprenderlo. `--check-drift`
    RE-SELLA la linea base al detectar, para que el aviso salga una vez y no en cada sesion. Si
    nadie lee ese aviso, el re-sellado lo borra para siempre: visto una vez, a nadie, y no vuelve.

    2.21.4 puso la guarda en `session-start.sh`. El adversario encontro el agujero en una frase:
    **hay DOS llamantes**. `bash-journal-nudge.sh` corre esto en CADA PostToolUse de Bash y no
    sabe nada de quien mira, asi que la deriva se consumia igual por ese lado. Poner la guarda
    tambien alli habria sido la misma forma por tercera vez — la decision pertenece a donde esta
    el EFECTO (el re-sellado), no a cada sitio que llama.

    Dos senales de entorno y una explicita:
      - PAPERCLIP_RUN_ID: agente de Paperclip, no hay pantalla.
      - CLAUDE_CODE_SESSION_ATTENDED=0: corrida no interactiva. Solo el "0" explicito apaga; si
        la variable no existe (CLI mas viejo) se deja pasar, que es el comportamiento de antes.
      - THREET_SIN_LECTOR=1: lo pone el llamante que SABE algo que el entorno no dice — p. ej.
        session-start.sh con `source` de clear/compact, donde hay agente pero no persona.
    """
    if os.environ.get("PAPERCLIP_RUN_ID"):
        return False
    if os.environ.get("CLAUDE_CODE_SESSION_ATTENDED") == "0":
        return False
    if os.environ.get("THREET_SIN_LECTOR") == "1":
        return False
    return True


def detectar_fuera_de_banda(mem, journal, estado=None):
    """Indices cuyo contenido no es el que dejo el compactador la ultima vez.

    Un indice sin huella previa no cuenta: es la primera pasada tras instalar esto, o un fichero
    nuevo. Sellar sin avisar es lo correcto ahi — avisar seria ruido en cada instalacion."""
    prev = leer_huellas(journal)
    if estado is None:
        estado = leer_estado(mem)
    if not prev:
        return []
    ahora = list(estado)
    fuera = []
    for rel in ahora:
        p = prev.get(rel)
        if p is None:
            # Fichero que existe y no estaba sellado. Un mensual NUEVO lo crea el compactador y
            # sella al terminar, asi que verlo aqui significa que lo puso otro. (Ronda 6.)
            fuera.append(f"{rel} (nuevo, no lo creo el compactador)")
            continue
        h = estado.get(rel)
        if h and h != p:
            fuera.append(rel)
    # Y los que DESAPARECIERON. Era el hueco mas grave: borrar _pendientes.md entero no disparaba
    # nada, porque indices_protegidos() solo devuelve los que existen. (Ronda 6.)
    for rel in prev:
        if rel not in ahora:
            fuera.append(f"{rel} (BORRADO)")
    return fuera


def anotar_fuera_de_banda(journal, fuera):
    """Deja rastro con fecha. La linea base se re-sella despues, asi que el aviso sale UNA vez;
    sin este log no quedaria constancia de que paso."""
    if not fuera:
        return
    os.makedirs(journal, exist_ok=True)
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        with open(os.path.join(journal, "out-of-band.log"), "a",
                  encoding="utf-8", newline="\n") as fh:
            for rel in fuera:
                fh.write(f"{ts}\t{rel}\n")
    except OSError:
        pass


def avisar_fuera_de_banda(fuera):
    if not fuera:
        return
    print(f"⚠ FUERA DEL JOURNAL: {len(fuera)} indice(s) cambiaron sin pasar por el compactador: "
          + ", ".join(fuera))
    print("  Los indices los escribe SOLO el compactador (journal_strict). Una edicion a mano "
          "—con Edit/Write o con Bash, que el guard no cubre— se pierde en la siguiente pasada")
    print("  y no deja evento que auditar. Usa bin/journal-emit.py. Queda anotado en "
          ".journal/out-of-band.log; este aviso no se repite.")
    print("  SI ACABAS DE HACER `git pull`/`git checkout`/`git merge`: es esperado y NO es una "
          "edicion a mano. La linea base vive por copia de trabajo (.journal/fingerprints.json no")
    print("  se versiona), asi que los indices que llegan por git no son los que sello ESTA "
          "maquina. Los cambios NO se pierden —son el contenido que acabas de traer, ya "
          "aplicado en la otra copia—; corre "
          "`journal-compact.py --reseal` para aceptarlos como linea base.")


GITIGNORE_JOURNAL = """\
# Lo escribe journal-compact.py cuando falta. Puedes editarlo: no se sobreescribe.
#
# QUE NO SE VERSIONA — estado por copia de trabajo. La deteccion de escrituras fuera del
# journal compara contra lo que sello EL COMPACTADOR DE ESTA MAQUINA, asi que la linea base
# no significa nada en otra. Versionarla ademas da un conflicto de merge garantizado: cambia
# en cada compactacion, y dos maquinas tocan las mismas claves del JSON.
fingerprints.json
# Append de dos maquinas = conflicto que git no sabe fusionar. Y lo que se anoto aqui es lo
# que se toco a mano EN ESTA copia.
out-of-band.log
# Estado vivo de un proceso. Nunca tiene sentido fuera de la maquina que lo tomo.
.lock/
.lock-steal/

# Un evento YA APLICADO no le hace falta a nadie mas: su efecto es la fila del indice, y esa si
# se versiona. Cifra reportada por UNA instalacion (2026-09-12), no un promedio: 628 de 1230
# ficheros del repo (51%), 2.5 MB, 619 de un solo mes. Crece con cada checkpoint y no se poda
# nunca. Lo que se pierde es un rastro que solo se consulta en la maquina que lo genero.
applied/

# QUE SI SE VERSIONA, a proposito: pending/ y quarantine/.
# Las dos hacen falta para APLICAR en la otra maquina, no como rastro:
#   - pending/: un evento emitido y aun sin aplicar llega a la otra maquina y se aplica alli,
#     en vez de perderse. Re-aplicar es no-op (el compactador es idempotente), asi que no
#     duplica nada si ambas lo aplican.
#   - quarantine/: un evento cuya ancla no existia aqui puede existir en la otra copia, y desde
#     2.22.0 el compactador lo rescata alli. Sin versionarlo no hay nada que rescatar.
"""


# sha256 de CADA cuerpo de GITIGNORE_JOURNAL que se llego a publicar y que esta version deja
# atras, con los saltos normalizados a \n. Medido sobre el historial, no de memoria: el literal
# solo ha tenido dos cuerpos desde que existe (`git log -S GITIGNORE_JOURNAL`).
#   9bfbd258...  2.21.0 a 2.22.1 — el bloque que versionaba applied/
#   5a88eb4a...  2.21.3 unicamente — el mismo mas la linea de human-pending.txt, que 2.21.4 quito
# Por que hashes y no el texto entero: la comparacion tiene que ser TODO-O-NADA. Si el fichero
# del usuario coincide entero con algo que publicamos, no lo escribio el: lo escribimos nosotros,
# y actualizarlo es nuestro. Si difiere en un byte, lo toco el, y "su version manda" sigue en pie
# sin ninguna excepcion que razonar.
GITIGNORE_JOURNAL_SUPERADOS = (
    "9bfbd25838599ef37b7c30cd2d6794c9723760a0ab854a550312261f6a1844a8",
    "5a88eb4a7cafae7cc8cb86137322c04550fc34cc9d94de15b09414ff02d65dac",
)


def _migrar_gitignore_journal(path):
    """Actualiza un .journal/.gitignore que escribimos nosotros. Deja intacto el que toco alguien.

    Por que hace falta: `escribir_gitignore_journal` es write-if-absent, asi que una linea nueva
    del bloque NUNCA llegaba a quien ya tenia el fichero — o sea, a todas las instalaciones de
    2.21.0 en adelante, que son justo las que tienen el problema. Un fichero generado si-falta es
    inmutable en la practica, y esa era la deuda (p-a374ff1ece).

    NORMALIZA CRLF ANTES DE COMPARAR, y no es cosmetico: en los repos que versionan `memory/`
    este fichero esta TRACKEADO, asi que en Windows con `core.autocrlf` vuelve del checkout con
    CRLF. Comparando bytes crudos, el compactador no reconoceria su propio bloque y la migracion
    no llegaria jamas a la plataforma donde menos se mira.

    Se publica con `os.replace`, no con `os.link`: aqui SI queremos pisar el destino, y `replace`
    es atomico — o queda el fichero viejo entero, o el nuevo entero, nunca uno a medias."""
    try:
        with open(path, "rb") as fh:
            crudo = fh.read()
    except OSError:
        return False          # no poder leerlo no es motivo para no compactar
    digest = hashlib.sha256(crudo.replace(b"\r\n", b"\n")).hexdigest()
    if digest not in GITIGNORE_JOURNAL_SUPERADOS:
        return False          # o es el de hoy, o lo toco el usuario: en ambos casos, no se toca
    if digest == hashlib.sha256(GITIGNORE_JOURNAL.encode("utf-8")).hexdigest():
        # Cinturon: si una version futura cambia el bloque y se olvida de sacar su hash de la
        # lista, esto evita reescribirlo en cada pasada (y con ello remover el mtime y la deriva).
        return False
    tmp = f"{path}.{os.getpid()}.mig"
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(GITIGNORE_JOURNAL)
            fh.flush()
            os.fsync(fh.fileno())
        # RELEER JUSTO ANTES DE PISAR, y no es paranoia de mas: entre el primer read y el replace
        # hay una escritura con fsync, que puede tardar. Si el usuario guarda su edicion en ese
        # hueco, la perderiamos — y "su version manda" es la propiedad que costo dos rondas
        # adversariales en 2.21.x. Con la escritura ya hecha, lo que queda entre comprobar y
        # publicar son dos syscalls.
        # NO CIERRA LA VENTANA DEL TODO y no se puede: nuestro lock no lo toma el editor del
        # usuario, y POSIX no da un "reemplaza solo si sigue siendo esto". Se reduce, se dice, y
        # el contenido pisado seria un bloque generado por nosotros, no trabajo suyo.
        with open(path, "rb") as fh:
            if hashlib.sha256(fh.read().replace(b"\r\n", b"\n")).hexdigest() != digest:
                _descartar(tmp)
                return False   # cambio bajo nuestros pies: es del usuario, se queda como esta
        os.replace(tmp, path)
    except OSError:
        _descartar(tmp)
        return False
    # SE IMPRIME AUNQUE SEA --quiet, y no es una excepcion caprichosa: la ruta por la que esto
    # le pasa a la gente de verdad es `session-start.sh`, que corre el compactador CON --quiet.
    # Gatearlo aqui era reescribir un fichero del repo del usuario y no decirselo, ni a el ni al
    # agente — y con ello perder el `git rm --cached`, sin el cual su repo queda a medias:
    # ignorado y trackeado a la vez. `--quiet` calla la linea rutinaria de cada pasada; esto
    # ocurre UNA vez en la vida de una instalacion.
    print(f"JOURNAL .gitignore actualizado: {path}")
    print("  applied/ (eventos ya aplicados) pasa a NO versionarse: su efecto ya esta en los "
          "indices, y el directorio crece con cada checkpoint sin podarse nunca.")
    print("  Si ya lo tenias trackeado, anadirlo al .gitignore no lo des-trackea: "
          "`git rm -r --cached memory/.journal/applied` y commit.")
    return True


def escribir_gitignore_journal(journal):
    """Deja claro que de .journal/ es estado local y que es registro compartido.

    SE ESCRIBE SI FALTA: una instalacion existente ya tiene .journal/ creado, asi que colgar
    esto del makedirs inicial dejaria fuera justo a quien le hace falta.

    Y SI YA ESTA, SE ACTUALIZA SOLO CUANDO LO ESCRIBIMOS NOSOTROS (2.23.0): si su contenido
    coincide entero con un bloque que publicamos, es nuestro y la linea nueva le toca; si difiere
    en un byte, lo edito el usuario y su version manda. Ver `_migrar_gitignore_journal`. Antes de
    esto un bloque generado si-falta era inmutable, y una linea nueva no llegaba a nadie.

    Por que hace falta: sin esto el plugin no tenia postura sobre que de `.journal/` es estado
    por copia de trabajo y que es registro compartido, asi que `fingerprints.json` acababa
    versionado y daba conflicto en cada checkpoint desde dos maquinas.

    DOS PROPIEDADES, Y HACEN FALTA LAS DOS. Costo dos rondas adversariales aprender que arreglar
    una rompiendo la otra no es arreglar:
      - EXCLUSIVA: si ya hay un fichero, no se toca. La primera version hacia `if exists` y luego
        `replace`, y en ese hueco cabe la escritura de otro, asi que el compactador pisaba el
        fichero del usuario. (Ronda 1: unsafe.)
      - COMPLETA: nunca se publica un fichero a medias. La segunda version cerro el hueco con
        `O_EXCL` sobre el destino, pero escribia DENTRO del fichero ya publicado: un fallo de E/S
        o una muerte del proceso dejaba un `.gitignore` truncado — y `O_EXCL` lo conserva para
        siempre, porque en la pasada siguiente ve que existe. (Ronda 2: unsafe otra vez, por el
        arreglo de la ronda 1.)
    Se escribe entero en un temporal, se fuerza a disco, y se PUBLICA con `os.link`, que falla si
    el destino existe. El enlace es una sola operacion del sistema de ficheros: o aparece el
    fichero completo, o no aparece nada. Las dos propiedades salen de la misma llamada."""
    path = os.path.join(journal, ".gitignore")
    if os.path.exists(path):
        # Ya existe: no se crea, pero SI se actualiza cuando su contenido es, entero, un bloque
        # que publicamos nosotros. Un fichero con una sola diferencia es del usuario y se respeta.
        return _migrar_gitignore_journal(path)
    try:
        os.makedirs(journal, exist_ok=True)
    except OSError:
        return False          # no poder escribirlo no es motivo para no compactar
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(GITIGNORE_JOURNAL)
            fh.flush()
            os.fsync(fh.fileno())   # los bytes en disco ANTES de que el fichero sea visible
    except OSError:
        _descartar(tmp)
        return False
    try:
        try:
            os.link(tmp, path)
            return True
        except FileExistsError:
            return False      # gano otro, o ya estaba: su version manda
        except (OSError, AttributeError, NotImplementedError):
            # Sin enlaces duros. Pasa en algunos sistemas de ficheros y puede pasar en
            # Windows/MSYS, donde este plugin ya se ha roto antes por suponer POSIX. Se cae a
            # O_EXCL sobre el destino: sigue siendo exclusivo, y la ventana de fichero a medias
            # se reduce a que el proceso MUERA a mitad — un error de E/S se limpia solo, abajo.
            return _gitignore_por_o_excl(path)
    finally:
        _descartar(tmp)


def _descartar(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _gitignore_por_o_excl(path):
    """Respaldo para sistemas sin enlaces duros. Si la escritura falla, BORRA lo que publico:
    dejar un fichero truncado seria peor que no dejar ninguno, porque O_EXCL lo conserva."""
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        return False
    except OSError:
        return False
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(GITIGNORE_JOURNAL)
            fh.flush()
            os.fsync(fh.fileno())
        return True
    except OSError:
        _descartar(path)
        return False


# Un evento que la version anterior mando a cuarentena por un ancla que AHORA se crea sola sigue
# ahi para siempre: el hook SessionStart avisa a la persona en cada arranque de un trabajo que ya
# no existe. Actualizar el plugin tiene que limpiar lo que el plugin viejo dejo, o el aviso se
# queda mintiendo hasta que alguien borre el par a mano. Se rescata SOLO el motivo que esta
# version sabe resolver; cualquier otro se queda donde esta.
# Ancla al final (`\s*$`) a proposito: sin ella, un `.reason` que EMPIEZA por un motivo rescatable y
# sigue con otra causa tambien se rescataria. Hoy ningun camino escribe un motivo asi —`move_to`
# guarda exactamente el texto de la Quarantine— pero el motivo es lo UNICO que decide si un evento
# vuelve a aplicarse, y una coincidencia parcial ahi es un evento aplicado por el parecido de su
# prefijo.
# v2.24.0: need_table() ahora crea '## Sessions', '## Plans', '## Topic Files', '## Active
# Research' y '## Completed Research' cuando faltan del todo (mismo criterio que el header de
# prioridad desde 2.22.0) — un evento que una version anterior cuarenteno por esa ausencia se
# rescata igual. El motivo se genera desde TABLE_COLUMNS/ANCHOR_FILES, no se retipea a mano: asi
# no puede desalinearse del texto que need_table() realmente escribe en el .reason.
_ANCHOR_RESCUE_REASONS = [
    re.escape(f"no-anchor: falta '{h}' en {ANCHOR_FILES[h]}") for h in TABLE_COLUMNS
]
RESCATABLE_RE = re.compile(
    r"^(?:no-anchor: (?:falta el header '## (?:Alta|Media|Baja) prioridad'"
    r"|_pendientes\.md sin header de prioridad donde reinsertar)"
    r"|" + "|".join(_ANCHOR_RESCUE_REASONS) + r")\s*$", re.I)


def rescatar_cuarentena(journal):
    """Devuelve a pending/ los eventos cuarentenados por un ancla que ya se crea sola. Cuenta."""
    qdir = os.path.join(journal, "quarantine")
    pending = os.path.join(journal, "pending")
    if not os.path.isdir(qdir):
        return 0
    n = 0
    for name in sorted(os.listdir(qdir)):
        if not name.endswith(".reason"):
            continue
        rpath = os.path.join(qdir, name)
        jpath = rpath[:-len(".reason")]
        if not os.path.isfile(jpath):
            continue
        try:
            with open(rpath, encoding="utf-8") as fh:
                motivo = fh.read().strip()
        except OSError:
            continue
        if not RESCATABLE_RE.match(motivo):
            continue
        try:
            os.makedirs(pending, exist_ok=True)
            replace_with_retry(jpath, os.path.join(pending, os.path.basename(jpath)))
        except OSError:
            continue        # lo reintenta la proxima pasada; nada se pierde
        _descartar(rpath)
        log(f"RESCUED {os.path.basename(jpath)}")
        n += 1
    return n


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
    applied = quarantined = noop = rescued = 0
    # Bajo el lock, como toda escritura del compactador. Es O_EXCL, asi que seria seguro fuera
    # de el; va aqui para que no haya una segunda regla sobre que se escribe sin lock.
    escribir_gitignore_journal(journal)
    # Antes de aplicar nada: si un indice no es el que dejo la pasada anterior, alguien escribio
    # fuera del journal. Tiene que ir AQUI — en cuanto el compactador escriba, su propio cambio
    # tapa la diferencia y ya no se puede distinguir.
    fuera = detectar_fuera_de_banda(mem, journal)
    if fuera:
        anotar_fuera_de_banda(journal, fuera)
        for rel in fuera:
            log(f"OUT-OF-BAND {rel}")
        if not quiet:
            avisar_fuera_de_banda(fuera)
    try:
        # Bajo el lock y antes de re-listar: lo rescatado entra en ESTA pasada.
        rescued = rescatar_cuarentena(journal)
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
        guardar_huellas(mem, journal)   # nueva linea base: lo que deja ESTE compactador
    finally:
        lock.release()
    left = len([n for n in os.listdir(pending) if n.endswith(".json")]) \
        if os.path.isdir(pending) else 0
    qdir = os.path.join(journal, "quarantine")
    qtotal = len([n for n in os.listdir(qdir) if n.endswith(".json")]) if os.path.isdir(qdir) else 0
    if not quiet or applied or quarantined or rescued:
        print(f"JOURNAL applied={applied} quarantined={quarantined} pending_left={left}"
              + (f" rescued={rescued}" if rescued else "")
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
    ap.add_argument("--reseal", action="store_true",
                    help="acepta el estado actual de los indices como la nueva linea base. Para "
                         "DESPUES de una reparacion manual deliberada — p. ej. una fila que "
                         "repair-dualwrite marco 'unrepairable' y hay que rehacer a mano. Sin "
                         "esto, esa reparacion legitima se reportaria como deriva")
    ap.add_argument("--check-drift", action="store_true",
                    help="solo comprueba si algun indice cambio fuera del journal; no aplica "
                         "eventos, no toma el lock, no escribe nada salvo el log de constancia")
    a = ap.parse_args()
    LOG_FILE = a.log
    mem = resolve_memory_dir(a.memory_dir)
    if not os.path.isdir(mem):
        sys.exit(f"journal-compact: no existe el directorio de memoria: {mem}")
    if a.reseal:
        # El unico camino sancionado para una edicion manual. Existe porque /audit-3t dice
        # "rehazla a mano" de una fila que no se puede anclar por forma, y sin esto el sistema se
        # contradecia: te manda editar a mano un fichero cuyo contrato es que no se edita a mano,
        # y luego te denuncia por haberlo hecho.
        journal = os.path.join(mem, ".journal")
        lock = Lock(journal, min(a.budget, 5.0))
        if not lock.acquire():
            sys.exit("journal-compact: el journal esta ocupado; reintenta el --reseal en un momento")
        try:
            estado = leer_estado(mem)
            antes = detectar_fuera_de_banda(mem, journal, estado)
            guardar_huellas(mem, journal, estado)
        finally:
            lock.release()
        if antes:
            print(f"resellado: {len(antes)} indice(s) aceptados como linea base nueva: "
                  + ", ".join(antes))
        else:
            print("resellado: ningun indice habia cambiado; la linea base ya estaba al dia")
        sys.exit(0)
    if a.check_drift:
        # Entrada propia porque session-start.sh solo llama al compactador cuando pending/ tiene
        # algo, y la deriva que interesa es justo la de una sesion que NO dejo eventos.
        #
        # NO SE MIRA SI NO HAY QUIEN LO LEA. Esta comprobacion re-sella al detectar; sin lector,
        # ese re-sellado consume la deriva en silencio y no vuelve. La deriva YA ES PERSISTENTE
        # —un hash que no coincide— asi que no hay nada que guardar: basta con no tocarla y la
        # ve la primera sesion que tenga a alguien delante. Sale 0: no es un error, es que no
        # era el momento.
        if not hay_lector():
            sys.exit(0)
        journal = os.path.join(mem, ".journal")
        # SI toma el lock, y lo dijo el adversario en la ronda 6: sin el, esta comprobacion puede
        # leer un indice que un compactador concurrente ACABA de reescribir legitimamente pero
        # todavia no ha sellado (compact() sella al final, dentro del lock). Eso producia un
        # "FUERA DEL JOURNAL" falso y una linea falsa en out-of-band.log — es decir, la afirmacion
        # "exacto, cero falsos positivos" era falsa. Si el lock esta ocupado no se comprueba nada:
        # hay un compactador trabajando y el sellara al terminar.
        # UNA sola adquisicion para detectar, anotar y re-sellar. La primera version lo partia en
        # dos locks y el adversario local (ronda 7) lo reprodujo: una edicion Y que cayera en el
        # hueco entre ambos se ABSORBIA en silencio — `fuera` ya estaba calculado y no la incluia,
        # asi que no salia en el aviso ni en out-of-band.log, pero `guardar_huellas()` hashea el
        # disco en ESE instante y la sellaba como linea base. Sin log, sin aviso, sin evento.
        # Ventana mas angosta que la original, misma clase de perdida.
        lock = Lock(journal, min(a.budget, 2.0))
        if not lock.acquire():
            sys.exit(0)
        try:
            estado = leer_estado(mem)                      # UNA lectura de bytes
            fuera = detectar_fuera_de_banda(mem, journal, estado)
            if fuera:
                anotar_fuera_de_banda(journal, fuera)
                avisar_fuera_de_banda(fuera)
            if fuera or not leer_huellas(journal):
                # ...y se sella ESE MISMO estado, no lo que haya en disco ahora. Lo que se
                # escriba despues queda fuera de la linea base y lo ve la comprobacion siguiente.
                guardar_huellas(mem, journal, estado)
        finally:
            lock.release()
        sys.exit(0)
    sys.exit(compact(mem, a.budget, a.quiet))


if __name__ == "__main__":
    main()
