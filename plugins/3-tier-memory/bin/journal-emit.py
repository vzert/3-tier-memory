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
                    Imprime el id (p-<10 hex>) por stdout.                              (Fase 1)
  pendiente.resolve --id ID --estado resolved|superseded|abandoned [--sesion S] [--nota N]
                    [--text-prefix P]  (si no se da, se toma del archivo si la linea existe)
  session.add       --slug DATE-SLUG --date D --status ST --summary R [--commit C]      (Fase 2)
                    Fila en _session-index.md (arriba de la tabla). Si la fila del slug ya
                    existe, rellena status/summary/commit con lo que se pase. Imprime s-<slug>.
  learning.add      --topic T [--text "**Regla** — detalle"] [--section H] [--quickref Q]
                    [--title TT] [--when W] [--importance N]                            (Fase 2)
                    Regla numerada (max+1, bajo lock) en learnings/<topic>.md; crea el topic
                    file y su fila en _learnings.md si faltan; --quickref agrega la version
                    corta al Quick Reference (numerada, max+1). Sin --text solo registra el
                    topic. Imprime l-<10 hex> (o l-topic-<topic>).
  plan.upsert       --slug S --title T --status ST [--date D] [--sesion [[sessions/..]]]
                    [--pendientes N] [--learnings N] [--inline]                         (Fase 2)
                    Fila en _plans-index.md por slug (o titulo); actualiza celdas dadas.
  research.upsert   --slug S --tema T --status active|completed [--date D] [--next-step N]
                    [--resultado R] [--origen O] [--inline]                             (Fase 2)
                    Fila en Active o Completed de _research-index.md; completed la mueve y
                    marca la celda Archivo con `_completado: D_` (D = --date, hoy por defecto),
                    que es lo que el compactador usa para podar Completed por fecha.

Identidad de un pendiente = sha1(texto normalizado + creado + origen)[:10]. Sin contador,
sin lock: dos agentes que emiten el mismo pendiente el mismo dia producen el mismo id y el
compactador lo aplica una sola vez (deduplicacion). Dos textos distintos con el mismo id
(colision) se cuarentenan en el compactador; nunca se fusionan.

Salida: 0 ok; 1 argumentos invalidos; 2 no se pudo crear el evento (queda copia en failed/).
Nunca descarta un evento en silencio.

Variables: MEMORY_DIR (o --memory-dir) apunta al directorio memory/. Si no se da, se busca
./memory y luego el auto-memory de Claude Code para el cwd.
"""
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

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

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
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
        return path
    failed = os.path.join(journal, "failed")
    os.makedirs(failed, exist_ok=True)
    fpath = os.path.join(failed, f"{ts_ns}-{sid}-{pid}.json.err")
    with open(fpath, "w", encoding="utf-8") as fh:
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


def strip_meta(text):
    text = re.sub(r"\s*—\s*_(origen|creado|id):[^—]*", "", text)
    return text.strip()


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description="Emite un evento al journal de memory/.")
    ap.add_argument("--type", required=True,
                    choices=["pendiente.add", "pendiente.resolve", "session.add",
                             "learning.add", "plan.upsert", "research.upsert"])
    ap.add_argument("--memory-dir")
    ap.add_argument("--session")
    # pendiente.add
    ap.add_argument("--text")
    ap.add_argument("--prioridad")
    ap.add_argument("--origen")
    ap.add_argument("--creado")
    # pendiente.resolve
    ap.add_argument("--id")
    ap.add_argument("--estado")
    ap.add_argument("--sesion", default="")
    ap.add_argument("--nota", default="")
    ap.add_argument("--text-prefix")
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
    ap.add_argument("--tema")
    ap.add_argument("--next-step", default="")
    ap.add_argument("--resultado", default="")
    # learning.add
    ap.add_argument("--topic")
    ap.add_argument("--section", default="")
    ap.add_argument("--quickref", default="")
    ap.add_argument("--when", default="")
    ap.add_argument("--importance", default="")
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
        creado = (a.creado or date.today().isoformat()).strip()
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", creado):
            sys.exit("journal-emit: --creado debe ser YYYY-MM-DD")
        pid = pendiente_id(text, creado, origen)
        base["payload"] = {"id": pid, "text": text, "prioridad": prio,
                           "origen": origen, "creado": creado}
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
        write_event(memory_dir, base)
        print(base["payload"]["id"])
        return

    if a.type == "plan.upsert":
        slug = check_slug(a.slug, "--slug")
        base["payload"] = {
            "slug": slug,
            "title": cell(need(a.title, "plan.upsert necesita --title")),
            "status": cell(need(a.status, "plan.upsert necesita --status")),
            "date": check_date(a.date, "--date", default=date.today().isoformat()),
            "sesion": cell(a.sesion),
            "pendientes": cell(a.pendientes),
            "learnings": cell(a.learnings),
            "inline": bool(a.inline),
        }
        write_event(memory_dir, base)
        print(f"pl-{slug}")
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
        write_event(memory_dir, base)
        print(f"r-{slug}")
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
