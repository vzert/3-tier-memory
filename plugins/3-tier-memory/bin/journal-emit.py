#!/usr/bin/env python3
"""
3-tier-memory plugin: emisor de eventos del journal (v2.12.0, Fases 1 y 2).

Los agentes NO editan los indices compartidos de memory/ a mano. Cada cambio entra como un
evento: un archivo JSON propio en memory/.journal/pending/, creado con O_CREAT|O_EXCL, que
un unico compactador (journal-compact.py) aplica bajo lock. Asi N agentes en la misma
maquina pueden escribir "a la vez" sin pisarse: cada uno solo crea archivos nuevos.

Por que un archivo por evento y no append a uno solo: append concurrente a un mismo archivo
no es atomico entre procesos en todas las plataformas; crear un archivo nuevo con O_EXCL si.
Ver memory/research/concurrent-memory-writes y plans/plan-journal-concurrencia-v2.12.0.

Tipos de evento:
  pendiente.add     --text T --prioridad Alta|Media|Baja --origen O [--creado YYYY-MM-DD]
                    [--revisar YYYY-MM-DD]   (ventana declarada; la lee expire-pendientes.py)
                    [--bloqueado-por "QUE"]  (espera a algo FUERA de la sesion: otra
                    instalacion, un peer, un PR ajeno; checkpoint-audit.py rechaza un
                    `Proximo paso:` que cite un id con `_bloqueado:`)
                    Imprime el id (p-<10 hex>) por stdout.                              (Fase 1)
  pendiente.resolve --id ID --estado resolved|superseded|abandoned [--sesion S] [--nota N]
  pendiente.update  --id ID [--text T] [--prioridad Alta|Media|Baja] [--text-prefix P]
                    Corrige el texto y/o la prioridad de un pendiente VIVO conservando su id.
                    El id es el hash con el que NACIO, no el del texto de hoy: cambiarlo
                    romperia las citas del id en fichas, recordatorios y research, que es lo
                    que hacia el unico camino que habia antes (resolve --superseded + add).
                    Un cambio de texto deja `_actualizado: FECHA_` en la linea; esa marca es
                    lo que le dice a repair-dualwrite.py que ese id es el de nacimiento y no
                    un id inventado (sin ella, `--fix-ids --apply` lo renombraria).
                    `--text-prefix` es el guardian contra la actualizacion perdida entre dos
                    sesiones: si no se pasa, se toma de la linea viva. Exige --text y/o
                    --prioridad. Sobre un pendiente ya cerrado o caducado no hace nada.
  pendiente.expire  --id ID --dias N [--line "<linea verbatim>"]   (caducidad por edad)
  pendiente.reopen  --id ID [--prioridad P]                        (reversa de expire)
  pendiente.window  --id ID --revisar YYYY-MM-DD                  (pone/actualiza la ventana)
  pendiente.block   --id ID (--bloqueado-por "QUE" | --desbloquear)
                    Pone, cambia o quita `_bloqueado: QUE_` en un pendiente VIVO. Existe para
                    marcar en Step 3a uno que nacio sin el campo; no cambia el id.
                    [--text-prefix P]  (si no se da, se toma del archivo si la linea existe)
  session.add       --slug DATE-SLUG --date D --status ST --summary R [--commit C]      (Fase 2)
                    Fila en _session-index.md (arriba de la tabla). Si la fila del slug ya
                    existe, rellena status/summary/commit con lo que se pase. Imprime s-<slug>.
  session.amend     --slug DATE-SLUG [--date D] [--alias A]
                    [--fecha-vieja V] [--sesion-vieja V]                              (2.40.0)
                    Corrige la Fecha y/o el alias de las filas de tabla cuya celda Sesion es
                    [[sessions/DATE-SLUG|...]]. El slug (nombre del fichero) no cambia, y el
                    fichero de la sesion no se toca. --fecha-vieja/--sesion-vieja son el
                    guardian contra la actualizacion perdida; si no se pasan, se toman de la fila
                    viva (con la misma funcion que usa el compactador). Filas duplicadas que no
                    coinciden: se niega; un session.add de la sesion las fusiona. No poda: una
                    fecha corregida hacia atras no expulsa la fila.
  learning.add      --topic T [--text "**Regla** — detalle"] [--section H] [--quickref Q]
                    [--title TT] [--when W] [--importance N]                            (Fase 2)
                    Regla numerada (max+1, bajo lock) en learnings/<topic>.md; crea el topic
                    file y su fila en _learnings.md si faltan; --quickref agrega la version
                    corta al Quick Reference (numerada, max+1). Sin --text solo registra el
                    topic. Imprime l-<10 hex> (o l-topic-<topic>).
                    [--supersedes N [--nota "<una linea>"] [--quickref-prefix QP]]   (2.45.0)
                    La regla nueva REEMPLAZA a la #N del mismo topic: en el mismo escrito, N
                    queda marcada `— ⊘ RETIRADA (FECHA, superada por #M)`. O las dos o ninguna.
                    --quickref-prefix quita la linea vieja de N del Quick Reference.
  learning.retire   --topic T --match-prefix P --motivo obsoleta|duplicada|superada
                    [--por N] [--nota "<una linea>"] [--quickref-prefix QP]           (2.45.0)
                    Retira una regla SIN borrarla ni renumerarla: anade al final de su linea
                    `— ⊘ RETIRADA (FECHA, <motivo>[ por #N]): <nota>`. El recall deja de
                    servirla. --por (la regla viva que la reemplaza) es obligatorio con
                    duplicada|superada y no se admite con obsoleta. --quickref-prefix quita su
                    linea del Quick Reference (sin renumerar el resto). Imprime l-topic-<T>.
  learning.update   --topic T [--match-prefix P --text "<nuevo>"]
                    [--quickref-prefix QP --quickref "<nuevo>"] [--title TT] [--when W]
                    Corrige una regla YA escrita, CONSERVANDO su numero. Un learning no tiene id
                    en la linea: el ancla es topic + prefijo del texto de hoy. El numero se
                    conserva porque las reglas se citan por numero ("learning 106"); renumerar
                    rompe esas citas igual que renombrar el id de un pendiente. Exige al menos
                    uno de los cuatro campos, y --text/--quickref exigen su prefijo: no se
                    reescribe una regla a ciegas.
  plan.upsert       --slug S --title T --status ST [--date D] [--sesion [[sessions/..]]]
                    [--pendientes N] [--learnings N] [--inline|--promote] [--parent P]  (Fase 2)
                    Fila en _plans-index.md por slug (o titulo, solo filas (inline));
                    actualiza celdas dadas.
                    --promote: el plan era --inline y ya tiene plans/plan-S.md; su UNICA fila
                    (inline) titulada T pasa a [[plans/plan-S|T]]. Sin el flag, ese upsert va a
                    cuarentena titulo-ambiguo (la fila (inline) no guarda el slug).
                    --parent anota la celda Status como '<status> (fase de plan-P)'.
  plan.reopen       --slug S [--title T]                                              (2.37.0)
                    Reabre un plan cerrado (completed/abandoned/superseded -> active), conserva
                    '(fase de plan-P)' y deja registro para que el replay del cierre viejo no lo
                    vuelva a cerrar. Es la UNICA forma de reabrir: un plan.upsert que retroceda
                    el status se descarta con aviso. --title solo para un plan --inline.
  research.upsert   --slug S --tema T --status active|completed [--date D] [--next-step N]
                    [--resultado R] [--origen O] [--inline]                             (Fase 2)
                    Fila en Active o Completed de _research-index.md; completed la mueve y
                    marca la celda Archivo con `_completado: D_` (D = --date, hoy por defecto),
                    que es lo que el compactador usa para podar Completed por fecha.
  research.rename   --slug S --tema T [--tema-viejo V]                               (2.38.0)
                    Corrige el tema (celda 0) de la fila cuyo Archivo es [[research/S]], en
                    Active y/o Completed. --tema-viejo es el guardian contra la actualizacion
                    perdida (dos renames del mismo tema); si no se pasa, se toma de la fila
                    viva. Una fila --inline NO se renombra (sin wikilink, su unica identidad es
                    el tema): el compactador la cuarentena. Dale fichero al research primero.

Identidad de un pendiente = sha1(texto normalizado + creado + origen)[:10]. Sin contador,
sin lock: dos agentes que emiten el mismo pendiente el mismo dia producen el mismo id y el
compactador lo aplica una sola vez (deduplicacion). Dos textos distintos con el mismo id
(colision) se cuarentenan en el compactador; nunca se fusionan.

El id es el hash con el que el pendiente NACIO, no el de su texto de hoy: `pendiente.update`
corrige el texto y deja el id intacto, porque ese id ya esta citado en fichas de sesion, en
recordatorios y en research. El precio es que la linea corregida deja de casar con su propio
hash, y hay dos herramientas que miden esa discrepancia — `repair-dualwrite.ids_invented`
(avisa) y `--fix-ids --apply` (RENOMBRA). La marca `_actualizado: FECHA_` que el compactador
deja en la linea es lo que las dos leen para saber que la discrepancia es deliberada.

Salida: 0 ok; 1 argumentos invalidos; 2 no se pudo crear el evento (queda copia en failed/).
Nunca descarta un evento en silencio.

Variables: MEMORY_DIR (o --memory-dir) apunta al directorio memory/. Si no se da, se busca
./memory y luego el auto-memory de Claude Code para el cwd.
"""
# sella-huellas: no (escribe eventos en .journal/pending, nunca un indice)
import argparse
import hashlib
import json
import os
import re
import socket
import sys
import time
import unicodedata
import uuid
from datetime import date

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

SCHEMA_VERSION = 1
PRIORIDADES = ("Alta", "Media", "Baja")
ESTADOS = ("resolved", "superseded", "abandoned")
ID_RE = re.compile(r"^p-[0-9a-f]{10}$")
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
RESEARCH_STATUS = ("active", "completed")
MAX_EXCL_RETRIES = 5


# ----------------------------------------------------------------------------- memoria
def resolve_memory_dir(explicit):
    """MEMORY_DIR explicito > env > ./memory (Model B) > auto-memory (Model A)."""
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


# ----------------------------------------------------------------------------- identidad
def normalize_text(text):
    """Forma canonica del texto para el hash: NFC, espacios colapsados, sin bordes."""
    t = unicodedata.normalize("NFC", text or "")
    t = re.sub(r"\s+", " ", t).strip()
    return t


def pendiente_id(text, creado, origen):
    raw = "\n".join([normalize_text(text), (creado or "").strip(), normalize_text(origen)])
    return "p-" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10]


MOTIVOS_RETIRO = ("obsoleta", "duplicada", "superada")   # = learning_marks.MOTIVOS


def numero_regla(valor, flag):
    """Entero >= 1 de --por / --supersedes, o None si no se paso. Acepta `135` y `#135`."""
    v = (valor or "").strip().lstrip("#")
    if not v:
        return None
    if not v.isdigit() or int(v) < 1:
        sys.exit(f"journal-emit: {flag} debe ser el numero de una regla (p. ej. 99), no {valor!r}")
    return int(v)


def numero_por_prefijo(memory_dir, topic, prefijo):
    """Numero de la UNICA regla numerada del topic cuyo texto empieza por `prefijo`, o None.

    Viaja en el evento de learning.retire: el ancla es el texto de hoy, y si un learning.update
    posterior cambia el principio de la regla, en un replay del retire el prefijo ya no casa. Con
    el numero, el compactador reconoce que esa regla ya esta retirada (replay, I3) en vez de
    mandarlo a cuarentena. Misma comparacion que journal-compact (sin `*`, `_`, comillas
    invertidas ni mayusculas)."""
    def plano(t):
        return normalize_text(re.sub(r"[*_`]", "", t)).lower()
    path = os.path.join(memory_dir, "learnings", topic + ".md")
    try:
        with open(path, encoding="utf-8") as f:
            lineas = f.read().splitlines()
    except OSError:
        return None
    pp = plano(prefijo)
    hits = []
    for l in lineas:
        m = re.match(r"^\s*(\d+)\.\s+(.*)$", l)
        if m and pp and plano(m.group(2)).startswith(pp):
            hits.append(int(m.group(1)))
    return hits[0] if len(hits) == 1 else None


def una_linea(texto):
    """La nota del marcador vive en la linea de la regla (I2): sin saltos de linea."""
    return normalize_text(texto or "")


def learning_id(topic, text):
    raw = "\n".join([topic.strip(), normalize_text(text)])
    return "l-" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10]


def cell(text):
    """Texto apto para una celda de tabla markdown: una linea, `|` suelto escapado.

    Un `\\|` ya escrito por el agente (alias de wikilink, `[[a\\|b]]`) se respeta.
    """
    t = normalize_text(text)
    return re.sub(r"(?<!\\)\|", r"\\|", t)


def need(value, msg):
    v = normalize_text(value or "")
    if not v:
        sys.exit(f"journal-emit: {msg}")
    return v


def check_slug(value, what):
    v = (value or "").strip()
    if not SLUG_RE.match(v):
        sys.exit(f"journal-emit: {what} debe ser un slug (letras, digitos, . _ -), no '{v}'")
    return v


def check_date(value, what, default=None):
    v = (value or default or "").strip()
    if not DATE_RE.match(v):
        sys.exit(f"journal-emit: {what} debe ser YYYY-MM-DD")
    return v


# ----------------------------------------------------------------------------- escritura
def session_id():
    sid = os.environ.get("CLAUDE_SESSION_ID") or os.environ.get("THREET_SESSION_ID")
    if sid:
        return re.sub(r"[^A-Za-z0-9_-]", "-", sid)[:64]
    return uuid.uuid4().hex


def agent_id():
    aid = os.environ.get("THREET_AGENT_ID")
    if aid:
        return aid[:64]
    try:
        host = socket.gethostname()
    except Exception:
        host = "host"
    return f"{os.environ.get('USER') or os.environ.get('USERNAME') or 'user'}@{host}"


def write_event(memory_dir, event):
    """Crea pending/<utc-ns>-<session>-<pid>-<seq>.json con O_EXCL. Devuelve la ruta.

    El nombre ya es unico por construccion (session_id completo + pid + seq). Si aun asi
    O_EXCL falla, se reintenta con seq+1 hasta MAX_EXCL_RETRIES; si se agota, el evento se
    guarda en failed/ con sufijo .err y se sale con 2 — el llamador lo reporta.
    """
    journal = os.path.join(memory_dir, ".journal")
    pending = os.path.join(journal, "pending")
    os.makedirs(pending, exist_ok=True)
    payload = json.dumps(event, ensure_ascii=False, indent=1)
    ts_ns = time.time_ns()
    sid = event["session_id"]
    pid = os.getpid()
    last_err = None
    for seq in range(MAX_EXCL_RETRIES):
        name = f"{ts_ns}-{sid}-{pid}-{seq}.json"
        path = os.path.join(pending, name)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError as e:
            last_err = e
            continue
        # newline="\n": un evento del journal es un artefacto generado; sus bytes son los mismos
        # en cualquier sistema, y asi el hash de un evento no depende de donde se emitio.
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(payload)
        return path
    failed = os.path.join(journal, "failed")
    os.makedirs(failed, exist_ok=True)
    fpath = os.path.join(failed, f"{ts_ns}-{sid}-{pid}.json.err")
    with open(fpath, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(payload)
        fh.write(f"\n# error: {last_err}\n")
    sys.stderr.write(f"journal-emit: no se pudo crear el evento tras {MAX_EXCL_RETRIES} "
                     f"intentos; copia en {fpath}\n")
    sys.exit(2)


# ----------------------------------------------------------------------------- lookup
def find_line_text(memory_dir, pid):
    """Texto de la linea con ese id en _pendientes.md (sin metadatos), o None."""
    path = os.path.join(memory_dir, "_pendientes.md")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("- [ ]") and f"_id: {pid}_" in s:
                    return strip_meta(s[5:].strip())
    except OSError:
        return None
    return None


RESEARCH_OPEN_RE = re.compile(r"^\[\[research/([^\]|\\]+)(?:\\\||\||\]\])")
CELL_SPLIT = re.compile(r"(?<!\\)\|")


def find_research_tema(memory_dir, slug):
    """Tema (celda 0) de la fila de _research-index.md cuya ULTIMA celda abre con
    `[[research/<slug>]]`, o None. Misma regla que `find_research_owned_row` del compactador para
    las tablas canonicas: una fila que solo CITA el research en otra celda no es suya."""
    path = os.path.join(memory_dir, "_research-index.md")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if not s.startswith("|"):
                    continue
                s = s[1:]
                if s.endswith("|") and not s.endswith("\\|"):
                    s = s[:-1]
                cells = [c.strip() for c in CELL_SPLIT.split(s)]
                m = RESEARCH_OPEN_RE.match(cells[-1]) if cells else None
                if m and m.group(1) == slug and cells[0]:
                    return cells[0]
    except OSError:
        return None
    return None


def _compactador():
    """El modulo journal-compact.py de este mismo directorio. session.amend lee la fila con SU
    `session_owned_rows`, no con una copia: una copia divergia (leia filas `|` sueltas fuera de
    toda tabla, que el compactador no ve), y el valor viejo que emitia no era el de la fila que el
    compactador iba a corregir (adversario de 2.40.0)."""
    import importlib.util
    sys.dont_write_bytecode = True   # sin __pycache__ dentro del plugin instalado
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "journal-compact.py")
    spec = importlib.util.spec_from_file_location("journal_compact", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def find_session_cells(memory_dir, slug):
    """(Fecha, celda Sesion) de CADA fila de la sesion segun `session_owned_rows` del compactador
    ([] si no hay fila). Mas de un par distinto = filas duplicadas que no coinciden: el llamante se
    niega a emitir."""
    path = os.path.join(memory_dir, "_session-index.md")
    if not os.path.isfile(path):
        return []
    jc = _compactador()
    lines = jc.read_lines(path)
    out = []
    for i in jc.session_owned_rows(lines, slug):
        cells = jc.split_cells(lines[i])
        out.append((cells[0], cells[1]))
    return out


def fecha_real(v):
    """True solo si `v` es una fecha del calendario. `re` valida la FORMA: `2026-99-99` la pasa,
    y los consumidores (`triage-scan.py`, `expire-pendientes.py`) revientan al parsearla.
    (Hallazgo del adversario, ronda 2, 2026-09-11.)"""
    try:
        date.fromisoformat(str(v))
        return True
    except (ValueError, TypeError):
        return False


def limpiar_bloqueado(valor):
    """Texto de `_bloqueado: …_` en una sola linea y sin el separador de la cola de metadatos.

    Un `—` dentro del valor partiria la cola: los despojadores (`[^—]*`) cortarian ahi y el resto
    del valor se quedaria pegado al TEXTO del pendiente, cambiando su hash re-derivado. Un `_`
    final cerraria la cursiva antes de tiempo."""
    v = normalize_text(valor or "").replace("—", "-").strip().strip("_").strip()
    return v[:160]


def strip_meta(text):
    # Las mismas claves que `META_RE` en repair-dualwrite.py, que re-deriva este hash para
    # detectar ids inventados. Si divergen, todo pendiente con la clave que falte se reporta
    # como id inventado. Si anades una clave aqui, anadela alli.
    text = re.sub(r"\s*—\s*_(?:origen|creado|id|revisar|actualizado|bloqueado):[^—]*", "", text)
    return text.strip()


# ----------------------------------------------------------------------------- main
def memory_dir_de(a):
    """El memory/ que este proceso va a usar, para poder mirar si el origen existe."""
    try:
        return resolve_memory_dir(a.memory_dir)
    except Exception:
        return None


def avisar_origen_colgante(origen, mem):
    """Avisa —no bloquea— si --origen apunta a un session file que no existe todavia.

    El orden de /checkpoint-3t es Step 2 (escribir el session file) y DESPUES Step 3 (emitir los
    pendientes), asi que en el flujo normal el fichero ya esta y esto no dispara nunca. Dispara
    cuando alguien emite un pendiente a media sesion con un slug inventado: el enlace de Tier 2
    queda colgando y `check-wikilinks.py` lo delata despues, si alguien lo corre.

    Paso en esta sesion, dos veces con dos slugs distintos, y lo encontro otro agente leyendo el
    indice — no una prueba. Avisa y NO bloquea a proposito: emitir antes de escribir es raro pero
    legitimo si el checkpoint llega luego, y un exit aqui perderia el evento.

    Cubre los tres sitios donde se nombra una sesion: `pendiente.add --origen`,
    `research.upsert --origen` y `plan.upsert --sesion`. Los tres, porque los tres enlaces rotos
    mas viejos de este repo son de PLANES apuntando a sesiones que nunca se escribieron.
    """
    m = re.match(r"^\[\[sessions/([^\]|]+?)(\|[^\]]*)?\]\]$", (origen or "").strip())
    if not m or not mem:
        return
    if not os.path.isfile(os.path.join(mem, "sessions", m.group(1) + ".md")):
        print(f"journal-emit: AVISO — el origen [[sessions/{m.group(1)}]] no existe todavia en "
              f"{os.path.join(mem, 'sessions')}. Si no lo escribes en el checkpoint, el enlace de "
              f"Tier 2 queda roto.", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description="Emite un evento al journal de memory/.")
    ap.add_argument("--type", required=True,
                    choices=["pendiente.add", "pendiente.resolve", "pendiente.update",
                             "pendiente.expire", "pendiente.reopen", "pendiente.window",
                             "pendiente.block",
                             "session.add", "session.amend",
                             "learning.add", "learning.update", "learning.retire",
                             "plan.upsert", "plan.reopen", "research.upsert",
                             "research.rename"])
    ap.add_argument("--memory-dir")
    ap.add_argument("--session")
    # pendiente.add
    ap.add_argument("--text")
    ap.add_argument("--prioridad")
    ap.add_argument("--origen")
    ap.add_argument("--creado")
    ap.add_argument("--revisar")
    ap.add_argument("--bloqueado-por", dest="bloqueado_por")
    ap.add_argument("--desbloquear", action="store_true")
    # pendiente.resolve
    ap.add_argument("--id")
    ap.add_argument("--estado")
    ap.add_argument("--sesion", default="")
    ap.add_argument("--nota", default="")
    ap.add_argument("--text-prefix")
    # pendiente.expire / pendiente.reopen
    ap.add_argument("--dias")
    ap.add_argument("--line")
    # session.add / plan.upsert / research.upsert
    ap.add_argument("--slug")
    ap.add_argument("--date")
    ap.add_argument("--status")
    ap.add_argument("--summary")
    ap.add_argument("--commit", default="")
    ap.add_argument("--title")
    ap.add_argument("--pendientes", default="")
    ap.add_argument("--learnings", default="")
    ap.add_argument("--inline", action="store_true")
    ap.add_argument("--promote", action="store_true")
    ap.add_argument("--parent")
    ap.add_argument("--tema")
    ap.add_argument("--tema-viejo", dest="tema_viejo")   # research.rename
    ap.add_argument("--alias")                             # session.amend
    ap.add_argument("--fecha-vieja", dest="fecha_vieja")
    ap.add_argument("--sesion-vieja", dest="sesion_vieja")
    ap.add_argument("--next-step", default="")
    ap.add_argument("--resultado", default="")
    # learning.add
    ap.add_argument("--topic")
    ap.add_argument("--section", default="")
    ap.add_argument("--quickref", default="")
    # learning.update: anclas de prefijo (un learning no tiene id que citar)
    ap.add_argument("--match-prefix", default="")
    ap.add_argument("--quickref-prefix", default="")
    ap.add_argument("--when", default="")
    ap.add_argument("--importance", default="")
    # learning.retire / learning.add --supersedes (2.45.0)
    ap.add_argument("--motivo", default="")
    ap.add_argument("--por", default="")
    ap.add_argument("--supersedes", default="")
    a = ap.parse_args()

    memory_dir = resolve_memory_dir(a.memory_dir)
    if not os.path.isdir(memory_dir):
        sys.exit(f"journal-emit: no existe el directorio de memoria: {memory_dir}")

    sid = re.sub(r"[^A-Za-z0-9_-]", "-", a.session)[:64] if a.session else session_id()
    base = {
        "v": SCHEMA_VERSION,
        "type": a.type,
        "ts": time.time_ns(),
        "session_id": sid,
        "agent_id": agent_id(),
    }

    if a.type == "pendiente.add":
        text = normalize_text(a.text or "")
        if not text:
            sys.exit("journal-emit: pendiente.add necesita --text")
        prio = (a.prioridad or "").strip().capitalize()
        if prio not in PRIORIDADES:
            sys.exit(f"journal-emit: --prioridad debe ser una de {PRIORIDADES}")
        origen = normalize_text(a.origen or "")
        if not origen:
            sys.exit("journal-emit: pendiente.add necesita --origen (p. ej. [[sessions/...]])")
        avisar_origen_colgante(origen, memory_dir_de(a))
        creado = (a.creado or date.today().isoformat()).strip()
        if not fecha_real(creado):
            sys.exit("journal-emit: --creado debe ser una fecha real YYYY-MM-DD")
        revisar = (a.revisar or "").strip()
        if revisar and not fecha_real(revisar):
            sys.exit("journal-emit: --revisar debe ser una fecha real YYYY-MM-DD")
        # `revisar` NO entra en el hash: es la ventana, no la identidad. Anadirla cambiaria el id
        # de un pendiente que ya existe y el compactador lo veria como uno nuevo.
        pid = pendiente_id(text, creado, origen)
        # `bloqueado` tampoco entra en el hash, por lo mismo que `revisar`: es un estado del
        # pendiente, no su identidad.
        bloqueado = limpiar_bloqueado(a.bloqueado_por)
        base["payload"] = {"id": pid, "text": text, "prioridad": prio,
                           "origen": origen, "creado": creado, "revisar": revisar}
        if bloqueado:
            base["payload"]["bloqueado"] = bloqueado
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type == "session.add":
        slug = check_slug(a.slug, "--slug")
        base["payload"] = {
            "slug": slug,
            "date": check_date(a.date, "--date", default=slug[:10]),
            "status": cell(a.status or ""),
            "summary": cell(a.summary or ""),
            "commit": cell(a.commit or ""),
        }
        if not base["payload"]["status"] and not base["payload"]["summary"] \
                and not base["payload"]["commit"]:
            sys.exit("journal-emit: session.add necesita --status, --summary o --commit")
        write_event(memory_dir, base)
        print(f"s-{slug}")
        return

    if a.type == "session.amend":
        slug = check_slug(a.slug, "--slug")
        # Sin --date no hay campo date: NO se toma slug[:10] por defecto como en session.add. Un
        # amend solo de alias que trajera la fecha del slug desharia un amend de fecha anterior.
        fecha = (a.date or "").strip()
        alias = normalize_text(a.alias or "")
        if not fecha and not alias:
            sys.exit("journal-emit: session.amend necesita --date o --alias")
        if fecha and not (DATE_RE.match(fecha) and fecha_real(fecha)):
            sys.exit("journal-emit: --date debe ser una fecha real YYYY-MM-DD")
        if alias and re.search(r"[|\[\]\\]", alias):
            sys.exit("journal-emit: --alias no puede llevar '|', '[', ']' ni '\\'")
        vivas = find_session_cells(memory_dir, slug)
        fechas = {f for f, _ in vivas}
        sesiones = {c for _, c in vivas}
        if (fecha and a.fecha_vieja is None and len(fechas) > 1) or \
                (alias and a.sesion_vieja is None and len(sesiones) > 1):
            sys.exit(f"journal-emit: sessions/{slug} tiene {len(vivas)} filas que no dicen lo mismo "
                     f"en _session-index.md. Emite antes un session.add de esa sesion (p. ej. "
                     f"--status con el que ya tiene): fusiona las filas duplicadas.")
        fvieja = a.fecha_vieja if a.fecha_vieja is not None else (vivas[0][0] if vivas else None)
        svieja = a.sesion_vieja if a.sesion_vieja is not None else (vivas[0][1] if vivas else None)
        # fvieja puede ser "" (fila con la Fecha vacia): se exige que exista, no que tenga texto.
        if (fecha and fvieja is None) or (alias and not svieja):
            sys.exit(f"journal-emit: no encuentro en _session-index.md una fila cuya celda Sesion "
                     f"sea [[sessions/{slug}...]], asi que no se de que valores se parte. Pasa "
                     f"--fecha-vieja/--sesion-vieja con lo que dice hoy la fila")
        base["payload"] = {"slug": slug}
        if fecha:
            base["payload"].update({"date": fecha, "fecha_vieja": fvieja.strip()})
        if alias:
            base["payload"].update({"alias": alias, "sesion_vieja": svieja.strip()})
        write_event(memory_dir, base)
        print(f"s-{slug}")
        return

    if a.type == "learning.add":
        topic = check_slug(a.topic, "--topic")
        text = normalize_text(a.text or "")
        imp = (a.importance or "").strip()
        if imp and not (imp.isdigit() and 0 <= int(imp) <= 10):
            sys.exit("journal-emit: --importance debe ser un entero 0-10")
        base["payload"] = {
            "topic": topic,
            "text": text,
            "section": normalize_text(a.section),
            "quickref": normalize_text(a.quickref),
            "title": normalize_text(a.title or ""),
            "when": cell(a.when),
            "importance": imp,
        }
        base["payload"]["id"] = learning_id(topic, text) if text else f"l-topic-{topic}"
        sup = numero_regla(a.supersedes, "--supersedes")
        qprefix = normalize_text(a.quickref_prefix or "")
        if sup:
            if not text:
                sys.exit("journal-emit: --supersedes necesita --text (la regla que reemplaza a la vieja)")
            base["payload"].update({"supersedes": sup, "nota": una_linea(a.nota),
                                    "quickref_prefix": qprefix,
                                    "fecha": date.today().isoformat()})
        elif qprefix:
            sys.exit("journal-emit: en learning.add, --quickref-prefix solo va con --supersedes "
                     "(quita la linea del Quick Reference de la regla reemplazada)")
        write_event(memory_dir, base)
        print(base["payload"]["id"])
        return

    if a.type == "learning.retire":
        topic = check_slug(a.topic, "--topic")
        mprefix = normalize_text(a.match_prefix or "")
        motivo = (a.motivo or "").strip().lower()
        por = numero_regla(a.por, "--por")
        if not mprefix:
            sys.exit("journal-emit: learning.retire necesita --match-prefix (el prefijo del texto "
                     "ACTUAL de la regla) — una regla no tiene id, sin ancla no se sabe cual retirar")
        if motivo not in MOTIVOS_RETIRO:
            sys.exit(f"journal-emit: --motivo debe ser uno de {MOTIVOS_RETIRO}")
        if motivo == "obsoleta" and por:
            sys.exit("journal-emit: --motivo obsoleta no lleva --por (nada la reemplaza); si otra "
                     "regla la reemplaza, el motivo es duplicada o superada")
        if motivo != "obsoleta" and not por:
            sys.exit(f"journal-emit: --motivo {motivo} necesita --por N (la regla viva que la "
                     f"reemplaza, en el mismo topic)")
        base["payload"] = {
            "topic": topic,
            "match_prefix": mprefix,
            "numero": numero_por_prefijo(memory_dir, topic, mprefix),
            "motivo": motivo,
            "por": por,
            "nota": una_linea(a.nota),
            "quickref_prefix": normalize_text(a.quickref_prefix or ""),
            "fecha": date.today().isoformat(),
        }
        write_event(memory_dir, base)
        print(f"l-topic-{topic}")
        return

    if a.type == "learning.update":
        topic = check_slug(a.topic, "--topic")
        text = normalize_text(a.text or "")
        quickref = normalize_text(a.quickref or "")
        mprefix = normalize_text(a.match_prefix or "")
        qprefix = normalize_text(a.quickref_prefix or "")
        title = normalize_text(a.title or "")
        when = cell(a.when)
        # Un learning no tiene `_id:` en su linea, asi que el unico ancla posible es el texto de
        # hoy. Reescribir sin ancla seria "corrige la regla que sea": se rechaza en la emision,
        # no en el compactador, para que el error salga donde la persona puede corregirlo.
        if text and not mprefix:
            sys.exit("journal-emit: --text necesita --match-prefix (el prefijo del texto ACTUAL "
                     "de la regla) — una regla no tiene id, sin ancla no se sabe cual reescribir")
        if quickref and not qprefix:
            sys.exit("journal-emit: --quickref necesita --quickref-prefix (el prefijo de la regla "
                     "ACTUAL del Quick Reference)")
        if mprefix and not text:
            sys.exit("journal-emit: --match-prefix sin --text no corrige nada")
        if qprefix and not quickref:
            sys.exit("journal-emit: --quickref-prefix sin --quickref no corrige nada")
        if not (text or quickref or title or when):
            sys.exit("journal-emit: learning.update necesita al menos uno de --text, --quickref, "
                     "--title o --when")
        base["payload"] = {
            "topic": topic,
            "match_prefix": mprefix,
            "text": text,
            "quickref_prefix": qprefix,
            "quickref": quickref,
            "title": title,
            "when": when,
        }
        write_event(memory_dir, base)
        print(f"l-topic-{topic}")
        return

    if a.type == "plan.upsert":
        slug = check_slug(a.slug, "--slug")
        parent = check_slug(a.parent, "--parent") if a.parent else ""
        if parent == slug:
            sys.exit("journal-emit: --parent no puede ser el propio plan")
        if parent and a.inline:
            sys.exit("journal-emit: --parent y --inline no se pueden combinar en el mismo evento "
                      "-- un plan --inline no lleva wikilink en el indice y el guardian de ciclos "
                      "no lo puede rastrear como eslabon (compact.py lo rechaza igual si ya era "
                      "--inline de un evento anterior)")
        if a.promote and a.inline:
            sys.exit("journal-emit: --promote y --inline no se pueden combinar -- --promote convierte "
                      "la fila (inline) del plan en una fila con su wikilink")
        base["payload"] = {
            "slug": slug,
            "title": cell(need(a.title, "plan.upsert necesita --title")),
            "status": cell(need(a.status, "plan.upsert necesita --status")),
            "date": check_date(a.date, "--date", default=date.today().isoformat()),
            "sesion": cell(a.sesion),
            "pendientes": cell(a.pendientes),
            "learnings": cell(a.learnings),
            "inline": bool(a.inline),
            "promote": bool(a.promote),
            "parent": parent,
        }
        avisar_origen_colgante(a.sesion, memory_dir)   # en plan.upsert el campo se llama --sesion
        write_event(memory_dir, base)
        print(f"pl-{slug}")
        return

    if a.type == "plan.reopen":
        base["payload"] = {
            "slug": check_slug(a.slug, "--slug"),
            "title": cell(a.title or ""),   # solo hace falta para un plan --inline (sin wikilink)
        }
        write_event(memory_dir, base)
        print(f"pl-{base['payload']['slug']}")
        return

    if a.type == "research.upsert":
        slug = check_slug(a.slug, "--slug")
        status = (a.status or "").strip().lower()
        if status not in RESEARCH_STATUS:
            sys.exit(f"journal-emit: --status debe ser uno de {RESEARCH_STATUS}")
        base["payload"] = {
            "slug": slug,
            "tema": cell(need(a.tema, "research.upsert necesita --tema")),
            "status": status,
            "date": check_date(a.date, "--date", default=date.today().isoformat()),
            "next_step": cell(a.next_step),
            "resultado": cell(a.resultado),
            "origen": cell(a.origen or ""),
            "inline": bool(a.inline),
        }
        avisar_origen_colgante(a.origen, memory_dir)
        write_event(memory_dir, base)
        print(f"r-{slug}")
        return

    if a.type == "research.rename":
        slug = check_slug(a.slug, "--slug")
        viejo = a.tema_viejo
        if viejo is None:
            viejo = find_research_tema(memory_dir, slug)
        if not viejo:
            sys.exit(f"journal-emit: no encuentro en _research-index.md una fila cuyo Archivo sea "
                     f"[[research/{slug}]], asi que no se de que tema se parte. Pasa "
                     f"--tema-viejo \"<tema actual>\" (ojo: una fila --inline no se renombra; "
                     f"dale fichero al research primero)")
        base["payload"] = {
            "slug": slug,
            "tema": cell(need(a.tema, "research.rename necesita --tema")),
            "tema_viejo": cell(viejo),
        }
        write_event(memory_dir, base)
        print(f"r-{slug}")
        return

    if a.type == "pendiente.update":
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        # El texto que llega puede venir pegado de la linea entera (con sus `— _origen:` y su
        # `— _id:`). Esos sufijos los POSEE el compactador: si entraran aqui, la linea acabaria
        # con dos `_id:` y el pendiente dejaria de resolverse por id. Se quitan y se avisa.
        crudo = normalize_text(a.text or "")
        text = strip_meta(crudo) if crudo else ""
        if crudo and text != crudo:
            print("journal-emit: AVISO — se quitaron los metadatos (_origen/_creado/_id/"
                  "_revisar/_actualizado) del --text; esos campos los conserva el compactador "
                  "de la linea viva, no se reescriben desde el evento.", file=sys.stderr)
        if crudo and not text:
            sys.exit("journal-emit: pendiente.update recibio un --text que es SOLO metadatos")
        prio = (a.prioridad or "").strip().capitalize()
        if prio and prio not in PRIORIDADES:
            sys.exit(f"journal-emit: --prioridad debe ser una de {PRIORIDADES}")
        if not text and not prio:
            sys.exit("journal-emit: pendiente.update necesita --text y/o --prioridad")
        prefix = a.text_prefix
        if prefix is None:
            current = find_line_text(memory_dir, pid)
            prefix = current[:40] if current else ""
        base["payload"] = {"id": pid, "text": text, "prioridad": prio,
                           "text_prefix": normalize_text(prefix),
                           "fecha": date.today().isoformat()}
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type == "pendiente.window":
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        rev = (a.revisar or "").strip()
        if not fecha_real(rev):
            sys.exit("journal-emit: pendiente.window necesita --revisar con una fecha real")
        base["payload"] = {"id": pid, "revisar": rev, "fecha": date.today().isoformat()}
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type == "pendiente.block":
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        bloqueado = limpiar_bloqueado(a.bloqueado_por)
        if bool(bloqueado) == bool(a.desbloquear):
            sys.exit("journal-emit: pendiente.block necesita --bloqueado-por \"QUE\" o "
                     "--desbloquear (uno de los dos)")
        base["payload"] = {"id": pid, "bloqueado": bloqueado}
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type in ("pendiente.expire", "pendiente.reopen"):
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        if a.type == "pendiente.expire":
            dias = (a.dias or "").strip()
            if not dias.isdigit():
                sys.exit("journal-emit: pendiente.expire necesita --dias <entero>")
            prio = (a.prioridad or "").strip().capitalize()
            if prio and prio not in PRIORIDADES:
                sys.exit(f"journal-emit: --prioridad debe ser una de {PRIORIDADES}")
            base["payload"] = {"id": pid, "dias": int(dias), "prioridad": prio,
                               "line": (a.line or "").rstrip("\n"),
                               "fecha": date.today().isoformat()}
        else:
            prio = (a.prioridad or "").strip().capitalize()
            if prio and prio not in PRIORIDADES:
                sys.exit(f"journal-emit: --prioridad debe ser una de {PRIORIDADES}")
            base["payload"] = {"id": pid, "prioridad": prio,
                               "fecha": date.today().isoformat()}
        write_event(memory_dir, base)
        print(pid)
        return

    # pendiente.resolve
    pid = (a.id or "").strip()
    if not ID_RE.match(pid):
        sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
    estado = (a.estado or "").strip().lower()
    if estado not in ESTADOS:
        sys.exit(f"journal-emit: --estado debe ser uno de {ESTADOS}")
    prefix = a.text_prefix
    if prefix is None:
        current = find_line_text(memory_dir, pid)
        prefix = current[:40] if current else ""
    base["payload"] = {"id": pid, "estado": estado, "sesion": normalize_text(a.sesion),
                       "nota": normalize_text(a.nota), "text_prefix": normalize_text(prefix),
                       "fecha": date.today().isoformat()}
    write_event(memory_dir, base)
    print(pid)


if __name__ == "__main__":
    main()
