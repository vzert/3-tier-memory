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
  - Hay que recuperar si existe un `compact_boundary` DESPUES del checkpoint anterior y ANTES del
    actual. El tramo va desde el primer prompt REAL del usuario tras el checkpoint anterior (asi no
    entra la ejecucion de ese checkpoint, que ya guardo lo suyo) hasta la ULTIMA de esas
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
Siempre sale 0 salvo error de uso: el checkpoint NO debe caerse porque esto falle; solo avisa.

Los bloques contienen texto crudo de la sesion (puede haber secretos). --out-dir debe estar FUERA de
memory/ y el checkpoint lo borra al terminar.
"""
# sella-huellas: no (solo lee el JSONL y escribe en un directorio temporal fuera de memory/)

import argparse
import json
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

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
    if o.get("type") != "user" or o.get("isSidechain"):
        return False
    for t in content_texts((o.get("message") or {}).get("content")):
        if any(p.search(t) for p in CKPT_MARKERS):
            return True
    return False


def is_real_prompt(o):
    """Un prompt que el usuario escribio: string, no meta, no resumen, no notificacion ni comando."""
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
    if not s or s.startswith("<task-notification>") or s.startswith("<local-command"):
        return False
    if o.get("isMeta") and (s.startswith(META_NOISE) or "cross-session-message" not in s):
        return False
    return not any(p.search(s) for p in CKPT_MARKERS)


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
        prev_end = groups[-2][2] if len(groups) >= 2 else 0
    else:
        current_start = last_line + 1   # corrida manual, fuera de un checkpoint
        prev_end = 0

    lost = [(n, o) for n, o in boundaries if prev_end < n < current_start]
    if not lost:
        return None, "checkpoint-posterior-a-la-compactacion"

    end = lost[-1][0]
    start = 1
    if prev_end:
        start = next((n for n, o in rows if prev_end < n < end and is_real_prompt(o)), None)
        if start is None:
            return None, "sin-prompts-entre-checkpoint-y-compactacion"
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--jsonl")
    ap.add_argument("--session-id")
    ap.add_argument("--jsonl-dir")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--until-line", type=int, default=0,
                    help="evaluar el archivo como si terminara en esta linea (pruebas y auditoria)")
    ap.add_argument("--chunk-chars", type=int, default=CHUNK_CHARS_DEFAULT)
    a = ap.parse_args()

    path = a.jsonl
    if not path:
        if not (a.session_id and a.jsonl_dir):
            print("recover=0 reason=sin-session-id")
            return 0
        path = os.path.join(a.jsonl_dir, a.session_id + ".jsonl")
    if not os.path.isfile(path):
        print(f"recover=0 reason=sin-jsonl path={path}")
        return 0

    rows = load(path, a.until_line)
    info, why = find_range(rows)
    if info is None:
        print(f"recover=0 reason={why}")
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

    os.makedirs(a.out_dir, exist_ok=True)
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

    paths, total = [], 0
    for i, ch in enumerate(chunks, 1):
        p = os.path.join(a.out_dir, f"chunk-{i:02d}.md")
        body = (f"# Tramo compactado — bloque {i} de {len(chunks)}\n"
                f"# Lineas {info['from_line']}-{info['to_line']} de {os.path.basename(path)}\n\n"
                + "\n\n".join(ch) + "\n")
        with open(p, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        paths.append(p)
        total += len(body)

    info.update({"jsonl": path, "chunks": paths, "chars": total, "entries": len(entries)})
    with open(os.path.join(a.out_dir, "manifest.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump(info, fh, ensure_ascii=False, indent=2)

    pre = sum(c.get("pre_tokens") or 0 for c in info["compactions"])
    print(f"recover=1 compactions={len(info['compactions'])} pre_tokens={pre} chunks={len(paths)} "
          f"chars={total} lines={info['from_line']}-{info['to_line']} out={a.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
