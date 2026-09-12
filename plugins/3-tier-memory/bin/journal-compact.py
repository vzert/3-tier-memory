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
.reason al lado. Nunca se pierde un evento en silencio.

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
pending_left=N [noop=N]` salvo --quiet (en ese caso solo imprime si applied>0 o quarantined>0).
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
        h = header_index(lines, prio) if prio else None
        if h is None:
            h = header_index(lines, "media")
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


def need_table(lines, header, fname):
    sec = section_bounds(lines, header)
    if not sec:
        raise Quarantine(f"no-anchor: falta '{header}' en {fname}")
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
    hit = next((i for i in rows if key.search(lines[i])), None)
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
    hit = next((i for i in rows if key.search(lines[i])
                or plain(split_cells(lines[i])[0]) == tplain), None)
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
    hit = next((i for i in rows if key.search(lines[i])
                or plain(split_cells(lines[i])[0]) == tplain), None)
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
