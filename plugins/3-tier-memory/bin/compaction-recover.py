#!/usr/bin/env python3
"""Recupera del JSONL de la sesion el tramo que una compactacion dejo fuera del contexto.

Uso:
    python3 compaction-recover.py --jsonl <ruta.jsonl> --out-dir <dir> [--until-line N]
                                  [--chunk-chars N]
    python3 compaction-recover.py --session-id <id> --jsonl-dir <dir> --out-dir <dir> [...]

Por que existe (2.39.0): hay usuarios que dejan que su sesion se compacte una o varias veces antes
de correr /checkpoint-3t. El checkpoint escribe lo que el agente tiene en contexto, y tras una
compactacion eso es un resumen: los learnings, pendientes, planes y research del tramo compactado se
pierden. Pero el JSONL de la sesion conserva TODO — la compactacion solo agrega una linea
`{"type":"system","subtype":"compact_boundary",...}`; no borra nada de lo anterior.

Que tramo recupera:
  - "checkpoint actual" = el ULTIMO grupo de marcas de checkpoint del archivo. La marca de la
    invocacion en curso ya esta escrita cuando corre este script (se midio: el tool_result
    `Launching skill: checkpoint-3t` llega antes de que corra ningun paso de la plantilla), asi que
    no puede contar como "checkpoint anterior".
  - "checkpoint anterior" = el grupo de marcas previo a ese. Una sola invocacion puede dejar varias
    marcas (`<command-name>/checkpoint-3t`, `Launching skill: checkpoint-3t`, el isMeta
    "Skill /checkpoint-3t is already loaded"), por eso se agrupan por `promptId`: el mismo prompt
    del usuario = la misma invocacion.
  - "checkpoint anterior" solo cuenta si TERMINO: si en su propio turno un Bash devolvio la salida de
    alguno de los scripts que la plantilla corre despues de Step 5 (`ensure-frontmatter.py`,
    `stamp-session-id.py`, `scan-secrets.py`; ver CKPT_DONE). Un checkpoint interrumpido antes de escribir no guardo
    nada; contarlo hacia que el reintento descartara el tramo (recover=0) sin que nadie lo hubiera
    guardado (adversario externo, 2026-09-28). El costo va al otro lado: un checkpoint completo que
    se salto esos cuatro scripts cuenta como no terminado y el siguiente recupera de mas — eso cuesta
    un dedupe en Steps 3a/4; el error contrario pierde el tramo en silencio.
  - Hay que recuperar si existe un `compact_boundary` DESPUES del checkpoint anterior, tambien una
    posterior a la marca del actual (la compactacion puede caer entre que la skill se carga y corre
    Step 0b; adversario externo, 2026-09-28). El tramo va desde la
    linea siguiente a la salida de cierre del checkpoint anterior (ronda 3: empezar en el siguiente
    inicio de turno perdia un Edit autonomo hecho tras el cierre) hasta la ULTIMA de esas
    compactaciones: lo que viene despues sigue en el contexto vivo del agente.
  - Sin checkpoint anterior, el tramo empieza en la linea 1.

Que guarda de cada linea: texto del usuario y del asistente, preguntas de AskUserQuestion con sus
respuestas, y un rastro corto de cada herramienta (ruta del archivo, comando, fragmento de la
edicion). Descarta resultados de herramientas (el 80-90% del peso del archivo), subagentes
(isSidechain), system-reminders y los resumenes de compactacion (son justo lo lossy). Medido sobre
una sesion real de 983K tokens previos a la compactacion: el tramo limpio pesa ~150K caracteres.

Salida: bloques `chunk-NN.md` de hasta --chunk-chars caracteres (cortados entre entradas, nunca a
media entrada) y `manifest.json` en --out-dir. En stdout, una linea:
    recover=1 compactions=N pre_tokens=T chunks=K chars=C lines=A-B out=DIR
    recover=0 reason=<motivo>
    recover=0 reason=fallo-escritura error=<excepcion> [restos=N out=DIR]
        (hubo compactacion y el tramo NO se recupero; restos=N: N archivos con texto crudo que no se
        pudieron borrar ni vaciar)
Con --verificar DIR no recupera nada: comprueba el tramo que dejo una corrida anterior en DIR y
imprime `verificado=1 chunks=K chars=C` o `verificado=0 reason=<motivo>`. Step 0b solo usa los
bloques con verificado=1: una linea recover=1 cortada no prueba que los bloques sigan ahi.
Siempre sale 0 salvo error de uso: el checkpoint NO debe caerse porque esto falle; solo avisa. Si
falla una escritura (o la propia linea de salida), borra los archivos que esta corrida creo antes de
salir. No escribe sobre archivos que ya estaban en --out-dir: los abre con "x".

Los bloques contienen texto crudo de la sesion (puede haber secretos). --out-dir debe estar FUERA de
memory/ y el checkpoint lo borra al terminar.
"""
# sella-huellas: no (solo lee el JSONL y escribe en un directorio temporal fuera de memory/)

import argparse
import json
import os
import re
import sys

# errors="backslashreplace": una ruta con un sustituto (argv con bytes no UTF-8) no tumba el print
# (ronda 4 de Codex sobre 2.41.7: recover=0 reason=sin-jsonl salia 1 con UnicodeEncodeError).
# try: con stdout a un archivo ya cerrado, reconfigure() pide tell() al fd y da OSError al cargar el
# modulo, antes de que salida() pueda protegerlo (ronda 7 de Codex sobre 2.41.10). Si falla, el
# flujo queda como estaba y el print siguiente lo maneja salida().
for _flujo in (sys.stdout, sys.stderr):
    try:
        _flujo.reconfigure(encoding="utf-8", errors="backslashreplace")
    except Exception:
        pass

CHUNK_CHARS_DEFAULT = 100_000
MAX_USER = 4000        # un prompt largo del usuario casi siempre es contexto que importa
MAX_ASSISTANT = 4000
MAX_EDIT = 400         # por cada lado (old/new) de un Edit: 115K de 170K del tramo medido eran esto
MAX_CMD = 400
MAX_AGENT_PROMPT = 800
MAX_ANSWER = 1500
MAX_NOTIFICATION = 2000
MAX_ERROR = 300

CKPT_MARKERS = (
    re.compile(r"<command-name>/?(?:[\w-]+:)?checkpoint-3t</command-name>"),
    re.compile(r"Launching skill: (?:[\w-]+:)?checkpoint-3t\b"),
    re.compile(r"Skill /?(?:[\w-]+:)?checkpoint-3t is already loaded"),
)
# La SALIDA de los scripts que la plantilla corre despues de Step 5 (5c, 5c-bis, 5d, 7a), en el
# resultado de un Bash del turno del checkpoint: prueba que llego a escribir. Se mira la salida y no
# el comando porque un `cat ensure-frontmatter.py` nombra el script sin correrlo (adversario externo,
# ronda 2); las formas exigen numeros donde el fuente tiene `{sealed}` o `%d`, asi que leer el fuente
# tampoco calza. journal-compact.py no vale: tambien corre en Step 3c.
# Ronda 5: checkpoint-audit.py (7a) ya no cuenta, porque tambien se corre como diagnostico sobre una
# ficha a medias. Las salidas de 5c y 5d solo cuentan si el comando lleva --apply: `| tail -n 1`
# sobre una corrida en seco quita la linea DRY-RUN. Medido: 60 de 65 igual que antes.
CKPT_DONE = re.compile(
    r"^(?:SUMMARY frontmatter_sealed=\d+"
    r"|stamped=1 reason=\S"   # stamped=0 tambien sale si la ficha no existe (ronda 4)
    r"|SUMMARY secrets_redacted=\d+ files=\d+)", re.MULTILINE)
CKPT_DONE_APPLY = re.compile(r"^SUMMARY (?:frontmatter_sealed|secrets_redacted)=", re.MULTILINE)
# isMeta NO basta para descartar: un `cross-session-message` (otra sesion de Claude que encarga
# trabajo) llega como isMeta y puede ser la peticion que origino todo el tramo (medido en una
# sesion real de este repo). Se descarta solo el ruido meta conocido: el cuerpo de una skill al
# cargarse y los empujones del harness.
META_NOISE = (
    "Base directory for this skill", "# Memory Checkpoint", "[Your previous response had no",
    "Caveat: The messages below were generated",
)
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.DOTALL)
# `<command-args>` NO se descarta: en `/goalspec:interview <texto>` el texto ES la peticion (medido:
# sin esto el bloque decia solo "USER: /goalspec:interview"). Solo se le quitan las etiquetas.
COMMAND_TAGS = re.compile(
    r"<(local-command-caveat|command-message|local-command-stdout)>.*?</\1>", re.DOTALL)


def cut(text, n):
    text = text.strip()
    return text if len(text) <= n else text[:n] + f" […+{len(text) - n}]"


def content_texts(content):
    """Todos los textos planos de un content (str o lista), incluidos tool_result de texto."""
    if isinstance(content, str):
        return [content]
    out = []
    if isinstance(content, list):
        for it in content:
            if not isinstance(it, dict):
                continue
            if it.get("type") == "text":
                out.append(it.get("text", ""))
            elif it.get("type") == "tool_result":
                c = it.get("content")
                if isinstance(c, str):
                    out.append(c)
                elif isinstance(c, list):
                    out.extend(x.get("text", "") for x in c if isinstance(x, dict))
    return out


def is_ckpt_marker(o):
    """Solo cuenta la marca en la FORMA en que el harness la escribe, nunca el texto dentro de otra
    cosa. Un tool_result de Read/grep sobre esta plantilla o sus pruebas CONTIENE la cadena
    `Launching skill: checkpoint-3t`; contarlo como checkpoint haria de esa lectura el "checkpoint
    anterior" y el tramo real se perderia en silencio (recover=0)."""
    if o.get("type") != "user" or o.get("isSidechain"):
        return False
    c = (o.get("message") or {}).get("content")
    items = [{"type": "text", "text": c}] if isinstance(c, str) else (c if isinstance(c, list) else [])
    for it in items:
        if not isinstance(it, dict):
            continue
        if it.get("type") == "tool_result":
            body = "\n".join(content_texts([it])).strip()
            if len(body) < 120 and CKPT_MARKERS[1].match(body):
                return True
        elif it.get("type") == "text":
            t = it.get("text", "").lstrip()
            if CKPT_MARKERS[0].search(t) and (t.startswith("<command-") or t.startswith("<command-message>")):
                return True
            if o.get("isMeta") and CKPT_MARKERS[2].match(t):
                return True
    return False


def is_turn_start(o):
    """Una linea que ABRE un turno nuevo: un prompt del usuario, pero tambien lo que el harness
    inyecta para despertar al agente sin prompt escrito — una `<task-notification>` de una tarea en
    segundo plano, un `cross-session-message`, un tick de un loop autonomo. Un adversario lo rompio
    (2.39.0, ronda 1): con "solo prompts escritos", checkpoint -> notificacion -> Edit ->
    compactacion daba recover=0 y el Edit se perdia. Lo unico que NO abre turno es lo que forma
    parte del turno en curso: tool_result, el cuerpo de una skill, las marcas del checkpoint."""
    if o.get("type") != "user" or o.get("isSidechain") or o.get("isCompactSummary"):
        return False
    c = (o.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
            return False
        c = "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    if not isinstance(c, str):
        return False
    s = c.strip()
    if not s or s.startswith("<local-command") or s.startswith(META_NOISE):
        return False
    return not is_ckpt_marker(o)


def load(path, until_line):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            if until_line and n > until_line:
                break
            try:
                rows.append((n, json.loads(line)))
            except ValueError:
                continue   # linea a medio escribir (el harness sigue anexando) o corrupta
    return rows


def is_typed_prompt(o):
    """Un inicio de turno que escribio una persona: no una notificacion de tarea, ni un mensaje de
    otra sesion, ni un tick de loop. El harness lo marca en `origin.kind`: "human" en lo escrito,
    "task-notification" o "peer" en lo que inyecta (medido en 300 JSONL, 2026-09-28). Mirar el
    contenido no basta: un prompt escrito puede empezar pegando una notificacion (adversario
    externo, ronda 3). Sin `origin` (versiones anteriores del harness) se mira el contenido."""
    if not is_turn_start(o) or o.get("isMeta"):
        return False
    origin = o.get("origin")
    if isinstance(origin, dict) and origin.get("kind"):
        return origin.get("kind") == "human"
    return not "\n".join(content_texts((o.get("message") or {}).get("content"))).lstrip().startswith(
        ("<task-notification>", "<cross-session-message", "<<autonomous-loop"))


def ckpt_finished(rows, group, next_group_start):
    """Linea donde, en el turno de esa invocacion, un Bash que corre `python3` devolvio la salida de
    un script de CKPT_DONE (no en DRY-RUN), o 0 si no la hay. El tramo a recuperar empieza tras esa
    linea: lo que el agente hizo despues del cierre, aun sin prompt nuevo, no lo guardo nadie
    (adversario externo, ronda 3).
    El turno va desde su primera marca hasta el siguiente prompt ESCRITO o la siguiente invocacion.
    Una notificacion de tarea en medio no lo cierra: el agente sigue con el checkpoint despues de
    ella (adversario externo, ronda 2: cerrar ahi daba por no terminado un checkpoint completo)."""
    first, _, last = group
    bash_ids = {}   # id del tool_use Bash -> si su comando lleva --apply
    for n, o in rows:
        if n <= first:
            continue
        if n >= next_group_start or (n > last and is_typed_prompt(o)):
            return False
        if o.get("isSidechain"):
            continue
        content = (o.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for it in content:
            if not isinstance(it, dict):
                continue
            if (o.get("type") == "assistant" and it.get("type") == "tool_use" and it.get("name") == "Bash"
                    and "python3" in str((it.get("input") or {}).get("command", ""))):
                bash_ids[it.get("id")] = "--apply" in str((it.get("input") or {}).get("command", ""))
            elif (o.get("type") == "user" and it.get("type") == "tool_result"
                  and it.get("tool_use_id") in bash_ids):
                # Sin exigir is_error falso: el Bash de un checkpoint real salio con codigo 6 por otro
                # comando y ensure-frontmatter.py si termino. La linea de resumen solo sale al final.
                body = "\n".join(content_texts([it]))
                m = CKPT_DONE.search(body)
                if (m and "DRY-RUN" not in body
                        and (bash_ids[it.get("tool_use_id")] or not CKPT_DONE_APPLY.match(m.group(0)))):
                    return n
    return 0


def find_range(rows):
    """Devuelve (info, None) si hay que recuperar, o (None, motivo)."""
    boundaries = [(n, o) for n, o in rows
                  if o.get("type") == "system" and o.get("subtype") == "compact_boundary"
                  and not o.get("isSidechain")]
    if not boundaries:
        return None, "sin-compactacion"

    groups = []            # [(primera_linea, promptId)]
    for n, o in rows:
        if not is_ckpt_marker(o):
            continue
        pid = o.get("promptId")
        if groups and ((pid and pid == groups[-1][1]) or (not pid and n - groups[-1][2] <= 3)):
            groups[-1] = (groups[-1][0], groups[-1][1], n)
            continue
        groups.append((n, pid, n))

    last_line = rows[-1][0] if rows else 0
    if groups:
        current_start = groups[-1][0]
        done = [f for f in (ckpt_finished(rows, g, groups[i + 1][0])
                             for i, g in enumerate(groups[:-1])) if f]
        prev_end = done[-1] if done else 0
    else:
        current_start = last_line + 1   # corrida manual, fuera de un checkpoint
        prev_end = 0

    lost = [(n, o) for n, o in boundaries if n > prev_end]
    if not lost:
        return None, "checkpoint-posterior-a-la-compactacion"

    end = lost[-1][0]
    # prev_end es la linea donde el checkpoint anterior dio su salida de cierre. Se empieza justo
    # despues, no en el siguiente inicio de turno: un Edit autonomo tras el cierre y antes de un
    # prompt nuevo se perdia (adversario externo, ronda 3). La cola del checkpoint (reporte, snippet)
    # entra de mas; eso cuesta un dedupe, no un tramo perdido.
    start = prev_end + 1 if prev_end else 1
    info = {
        "from_line": start,
        "to_line": end,
        "previous_checkpoint_line": prev_end or None,
        "current_checkpoint_line": current_start if groups else None,
        "compactions": [
            {"line": n, "timestamp": o.get("timestamp"),
             "trigger": (o.get("compactMetadata") or {}).get("trigger"),
             "pre_tokens": (o.get("compactMetadata") or {}).get("preTokens")}
            for n, o in lost],
    }
    return info, None


def render_tool_use(it):
    name = it.get("name", "?")
    inp = it.get("input") or {}
    if name in ("Edit", "MultiEdit"):
        edits = inp.get("edits") or [inp]
        parts = [f"TOOL {name} {inp.get('file_path', '')}"]
        for e in edits:
            parts.append(f"  - old: {cut(str(e.get('old_string', '')), MAX_EDIT)}")
            parts.append(f"  + new: {cut(str(e.get('new_string', '')), MAX_EDIT)}")
        return "\n".join(parts)
    if name == "Write":
        return f"TOOL Write {inp.get('file_path', '')}\n  {cut(str(inp.get('content', '')), MAX_EDIT)}"
    if name == "Bash":
        d = inp.get("description")
        return f"TOOL Bash{' (' + d + ')' if d else ''}: {cut(str(inp.get('command', '')), MAX_CMD)}"
    if name == "AskUserQuestion":
        qs = inp.get("questions") or []
        lines = ["ASK (pregunta al usuario):"]
        for q in qs:
            opts = " | ".join(o.get("label", "") for o in q.get("options", []) if isinstance(o, dict))
            lines.append(f"  ? {q.get('question', '')}  [{opts}]")
        return "\n".join(lines)
    if name in ("Agent", "Task", "SendMessage"):
        p = inp.get("prompt") or inp.get("message") or ""
        who = inp.get("subagent_type") or inp.get("to") or inp.get("description") or ""
        return f"TOOL {name} {who}: {cut(str(p), MAX_AGENT_PROMPT)}"
    if name in ("Read", "Glob", "Grep"):
        return f"TOOL {name} {inp.get('file_path') or inp.get('pattern') or ''}"
    if name == "Skill":
        return f"TOOL Skill {inp.get('skill', '')} {cut(str(inp.get('args', '')), MAX_CMD)}"
    return f"TOOL {name}"


def render(o, ask_ids):
    """Texto de una linea del JSONL para el bloque, o None si no aporta."""
    if o.get("isSidechain") or o.get("isCompactSummary"):
        return None
    t = o.get("type")
    msg = o.get("message") or {}
    c = msg.get("content")
    ts = (o.get("timestamp") or "")[:16].replace("T", " ")
    out = []
    if t == "assistant" and isinstance(c, list):
        for it in c:
            if not isinstance(it, dict):
                continue
            if it.get("type") == "text" and it.get("text", "").strip():
                out.append(f"ASSISTANT: {cut(it['text'], MAX_ASSISTANT)}")
            elif it.get("type") == "tool_use":
                if it.get("name") == "AskUserQuestion":
                    ask_ids.add(it.get("id"))
                out.append(render_tool_use(it))
    elif t == "user":
        if o.get("isMeta") and any(x.strip().startswith(META_NOISE) for x in content_texts(c)):
            return None
        if isinstance(c, str):
            s = COMMAND_TAGS.sub("", REMINDER.sub("", c)).strip()
            s = re.sub(r"</?command-(?:name|args)>", " ", s)
            s = re.sub(r"[ \t]+", " ", s).strip()
            if s.startswith("<task-notification>"):
                out.append(f"AGENT-RESULT: {cut(s, MAX_NOTIFICATION)}")
            elif s:
                out.append(f"USER: {cut(s, MAX_USER)}")
        elif isinstance(c, list):
            for it in c:
                if not isinstance(it, dict):
                    continue
                if it.get("type") == "text":
                    s = REMINDER.sub("", it.get("text", "")).strip()
                    if s:
                        out.append(f"USER: {cut(s, MAX_USER)}")
                elif it.get("type") == "tool_result":
                    body = "\n".join(content_texts([it]))
                    if it.get("tool_use_id") in ask_ids:
                        out.append(f"ANSWER (respuesta del usuario): {cut(body, MAX_ANSWER)}")
                    elif it.get("is_error"):
                        out.append(f"TOOL-ERROR: {cut(body, MAX_ERROR)}")
    if not out:
        return None
    return f"[{ts}] " + "\n".join(out) if ts else "\n".join(out)


def salida(linea):
    """Imprime una linea de resultado. Si stdout esta roto, lo cambia por None: sin eso, el vaciado
    al salir falla otra vez y Python sale 120 (ronda 6: las salidas tempranas no estaban cubiertas)."""
    try:
        print(linea)
        sys.stdout.flush()
    except Exception:
        sys.stdout = None


def verificar(d):
    """Comprueba el tramo de DIR: manifest JSON, cada bloque dentro de DIR (no un enlace) y la suma de
    caracteres igual a la del manifest. Un bloque borrado, vaciado o cortado da verificado=0."""
    try:
        with open(os.path.join(d, "manifest.json"), encoding="utf-8") as fh:
            m = json.load(fh)
        chunks, chars = m.get("chunks"), m.get("chars")
        if not (isinstance(chunks, list) and chunks and isinstance(chars, int)):
            return "verificado=0 reason=manifest-incompleto"
        base, total = os.path.realpath(d), 0
        for p in chunks:
            if not isinstance(p, str) or os.path.islink(p) or \
                    os.path.dirname(os.path.realpath(p)) != base:
                return "verificado=0 reason=bloque-fuera-de-dir"
            with open(p, encoding="utf-8", errors="replace", newline="") as fh:
                total += len(fh.read())
    except Exception as e:
        return f"verificado=0 reason={type(e).__name__}"
    if total != chars:
        return f"verificado=0 reason=caracteres chars={chars} leidos={total}"
    return f"verificado=1 chunks={len(chunks)} chars={total}"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--jsonl")
    ap.add_argument("--session-id")
    ap.add_argument("--jsonl-dir")
    ap.add_argument("--projects-root", default=os.path.expanduser("~/.claude/projects"),
                    help="donde buscar <session-id>.jsonl si no esta en --jsonl-dir")
    ap.add_argument("--out-dir")
    ap.add_argument("--verificar", metavar="DIR",
                    help="no recupera: comprueba el tramo que dejo una corrida anterior en DIR")
    ap.add_argument("--until-line", type=int, default=0,
                    help="evaluar el archivo como si terminara en esta linea (pruebas y auditoria)")
    ap.add_argument("--chunk-chars", type=int, default=CHUNK_CHARS_DEFAULT)
    a = ap.parse_args()
    if a.verificar:
        salida(verificar(a.verificar))
        return 0
    if not a.out_dir:
        ap.error("falta --out-dir")

    path = a.jsonl
    if not path:
        if not a.session_id:
            salida("recover=0 reason=sin-session-id")
            return 0
        path = os.path.join(a.jsonl_dir or "", a.session_id + ".jsonl")
        if not (a.jsonl_dir and os.path.isfile(path)):
            # --jsonl-dir sale de CLAUDE_PROJECT_DIR, que en las llamadas Bash del agente llega VACIA
            # (medido 2026-09-24; el mismo patron ya habia fallado en Step 5c-bis, d971c55a:2569).
            # El session id es un UUID: buscarlo bajo todos los proyectos no puede confundirse.
            import glob
            hits = sorted(glob.glob(os.path.join(glob.escape(a.projects_root), "*",
                                                 glob.escape(a.session_id) + ".jsonl")),
                          key=os.path.getmtime)
            if hits:
                path = hits[-1]
    if not os.path.isfile(path):
        salida(f"recover=0 reason=sin-jsonl path={path}")
        return 0

    rows = load(path, a.until_line)
    info, why = find_range(rows)
    if info is None:
        salida(f"recover=0 reason={why}")
        return 0

    entries, ask_ids = [], set()
    for n, o in rows:
        if n < info["from_line"]:
            continue
        if n >= info["to_line"]:
            break
        r = render(o, ask_ids)
        if r:
            entries.append(r)

    # Tamano objetivo balanceado: con el tope a secas, 101K salian como 99K + 3K (medido) y un
    # subagente hacia casi todo el trabajo. Se reparte el total entre los bloques que hagan falta.
    total_chars = sum(len(e) + 2 for e in entries)
    n_chunks = max(1, -(-total_chars // a.chunk_chars))
    target = -(-total_chars // n_chunks)
    chunks, cur, size = [], [], 0
    for e in entries:
        if cur and size + len(e) > target and len(chunks) < n_chunks - 1:
            chunks.append(cur)
            cur, size = [], 0
        cur.append(e)
        size += len(e) + 2
    if cur:
        chunks.append(cur)

    # Si una escritura falla, se borra lo que esta corrida creo y se sale 0 con motivo: un bloque a
    # medias tiene texto crudo de la sesion y Step 0b solo lo usa si ve recover=1 (Codex, ronda 1
    # sobre 2.39.x: manifest.json como directorio dejaba chunk-01.md y salia 1).
    # Ronda 2 (sobre 2.41.7): los archivos se abren con "x" y se anotan DESPUES de abrirlos, asi que
    # un archivo o enlace que ya estaba no se pisa, no se sigue ni se borra; errors="replace" porque
    # un \ud800 suelto es JSON valido y no se codifica en UTF-8; y la linea de salida se escribe y
    # vacia dentro del try: si stdout falla, nadie sabra que los bloques existen.
    # Antes del try: un preTokens que no es numero no es un fallo de escritura (ronda 4).
    pre = sum(c["pre_tokens"] for c in info["compactions"]
              if isinstance(c.get("pre_tokens"), int) and not isinstance(c.get("pre_tokens"), bool))
    # Ronda 4: se captura Exception (un TypeError o MemoryError a media escritura dejaba el bloque);
    # un --out-dir que es enlace no se sigue (solo el ultimo tramo: en macOS /tmp y /var son enlaces);
    # cada archivo se anota con su identidad (dev, ino) para no borrar ni vaciar lo que otro puso en
    # su lugar; y se limpia al reves, manifest primero: si el manifest existe, los bloques estan.
    paths, created, total = [], [], 0
    try:
        if os.path.islink(os.path.normpath(a.out_dir)):
            raise OSError(f"--out-dir es un enlace: {a.out_dir}")
        os.makedirs(a.out_dir, exist_ok=True)
        for i, ch in enumerate(chunks, 1):
            p = os.path.join(a.out_dir, f"chunk-{i:02d}.md")
            body = (f"# Tramo compactado — bloque {i} de {len(chunks)}\n"
                    f"# Lineas {info['from_line']}-{info['to_line']} de {os.path.basename(path)}\n\n"
                    + "\n\n".join(ch) + "\n")
            with open(p, "x", encoding="utf-8", errors="replace", newline="\n") as fh:
                st = os.fstat(fh.fileno())
                created.append((p, st.st_dev, st.st_ino))
                fh.write(body)
            paths.append(p)
            total += len(body)

        info.update({"jsonl": path, "chunks": paths, "chars": total, "entries": len(entries)})
        mp = os.path.join(a.out_dir, "manifest.json")
        with open(mp, "x", encoding="utf-8", errors="replace", newline="\n") as fh:
            st = os.fstat(fh.fileno())
            created.append((mp, st.st_dev, st.st_ino))
            json.dump(info, fh, ensure_ascii=False, indent=2)

        print(f"recover=1 compactions={len(info['compactions'])} pre_tokens={pre} chunks={len(paths)} "
              f"chars={total} lines={info['from_line']}-{info['to_line']} out={a.out_dir}")
        sys.stdout.flush()
        # La linea ya llego: el vaciado al salir no tiene nada que escribir, pero si falla Python sale
        # 120 con los bloques validos (ronda 4, con un stdout falso; una tuberia real no lo hace).
        # None y no os.devnull: abrir un archivo puede fallar (ronda 5); con None, Python no vacia nada.
        sys.stdout = None
    except Exception as e:
        # ValueError: un stdout ya cerrado (ronda 3). Si no se puede borrar un archivo, se vacia; si
        # tampoco, queda y la linea lo dice (restos=N) para que Step 0b avise. Un archivo que ya no
        # esta, o que ya no es el que esta corrida creo, no se toca ni se cuenta. Se captura Exception
        # y no OSError: un MemoryError en la limpieza salia 1 con el bloque lleno (ronda 5).
        restos = 0
        for p, dev, ino in reversed(created):
            try:
                st = os.lstat(p)
            except FileNotFoundError:
                continue
            except Exception:
                restos += 1
                continue
            if (st.st_dev, st.st_ino) != (dev, ino):
                continue
            try:
                os.remove(p)
                continue
            except FileNotFoundError:
                continue
            except Exception:
                pass
            try:
                st = os.lstat(p)
            except FileNotFoundError:
                continue
            except Exception:
                st = None
            if st is not None and (st.st_dev, st.st_ino) != (dev, ino):
                continue
            try:
                fd = os.open(p, os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    st = os.fstat(fd)
                    if (st.st_dev, st.st_ino) == (dev, ino):
                        os.ftruncate(fd, 0)
                finally:
                    # Un close que falla despues de vaciar no deja resto (ronda 6).
                    try:
                        os.close(fd)
                    except Exception:
                        pass
            except FileNotFoundError:
                pass
            except Exception:
                restos += 1
        linea = f"recover=0 reason=fallo-escritura error={type(e).__name__}"
        if restos:
            linea += f" restos={restos} out={ascii(a.out_dir)}"
        # La linea de stdout va primero y el detalle con ascii(): tras reconfigure(encoding=...)
        # stderr es estricto y un sustituto en el mensaje lo haria fallar (ronda 3).
        try:
            print(linea)
            sys.stdout.flush()
        except Exception:
            # stdout roto: sin esto, el vaciado al salir falla otra vez y Python sale 120. Con
            # cualquier excepcion, no solo OSError/UnicodeError/ValueError (ronda 5).
            sys.stdout = None
        try:
            print(f"compaction-recover: {ascii(str(e))}", file=sys.stderr)
        except Exception:
            pass
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
