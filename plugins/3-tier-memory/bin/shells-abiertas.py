#!/usr/bin/env python3
"""
3-tier-memory plugin: lista las shells en segundo plano que la sesion dejo vivas (2.63.21).

POR QUE. Un agente cerraba con `/checkpoint-3t`, dejaba su prompt para retomar y seguia con shells
en segundo plano abiertas. Caso real (2026-10-20): un muestreo lanzado con `run_in_background`
seguia escribiendo cada 15 minutos, pero cada muestra salia "Timeout expired", y el Como retomar
pedia leer justo ese log. El agente no puede preguntarle al harness que tareas
tiene vivas, y su memoria de lo que lanzo se pierde con una compactacion. El transcript si lo
guarda todo: este script lo lee.

QUE CUENTA COMO SHELL (decision del usuario, 2026-10-20): solo lo que lanzo la propia sesion, un Bash
con `run_in_background: true` o un `Monitor`. Un proceso con nohup, una pestana de herdr o un
subagente quedan fuera.

COMO DECIDE QUE SIGUE ABIERTA. Una tarea se abre con el id que el harness guarda en el
`toolUseResult` del lanzamiento: `backgroundTaskId` para un Bash (con `run_in_background`, o uno que
paso solo a segundo plano al vencer su timeout) y `taskId` para un Monitor. Medido el 2026-10-20 en
400 JSONL: 985 lanzamientos, todos con ese campo; los 6 resultados con la frase de lanzamiento y sin
el campo eran salidas de Bash normales que la imprimian como dato. Por eso el texto no basta: un
`echo` o un `grep` que imprime "Command running in background with ID: X" al principio abria una
tarea fantasma (revisor externo, ronda 1). Solo si la linea no trae `toolUseResult` (un transcript
mas viejo) se lee el texto del resultado, anclado al inicio ("Command running in background with
ID: <id>", "Command did not complete within ... moved to the background (ID: <id>)", "Monitor
started (task <id>"). Se cierra con cualquiera de estos, el primero que aparezca:
  - una `<task-notification>` con ese `<task-id>` y un `<status>` (completed, failed, stopped, killed);
  - un evento `[Monitor expired ...]` de ese `<task-id>`;
  - el resultado de un TaskStop: "Successfully stopped task: <id>" o "No task found with ID: <id>".
Las notificaciones se buscan solo en lineas del harness (user, queue-operation, attachment), y
nunca dentro de un tool_result: ni un mensaje del agente que cita una notificacion ni la salida de
un Bash que la imprime cierran nada.

QUE NO SABE. No ve si el proceso vive de verdad: una tarea que murio sin notificacion sale como
abierta (falso positivo, se ve porque su salida no crece). Y un /clear o un resume que abre otro
JSONL no hereda las tareas del anterior. Solo lee: nunca para nada; eso lo decide el agente
(Step 7c de checkpoint-3t).

Uso:
    shells-abiertas.py [--session-id ID | --transcript RUTA] [--projects-root DIR] [--ahora EPOCH]

Sin --session-id usa $CLAUDE_CODE_SESSION_ID. Busca <projects-root>/*/<ID>.jsonl (por defecto
~/.claude/projects). Si no lo encuentra imprime `resumen: abiertas=? motivo=<...>` y sale 2.

Salida (stdout), por tarea abierta:
    ABIERTA  <id>  <Bash|Monitor>  <descripcion>
      comando: <primeros 160 caracteres>
      salida: <ruta> (<bytes> bytes, ultima escritura hace <N> min)
      ultimas lineas: <hasta 3 lineas no vacias>
y al final siempre `resumen: abiertas=<N> cerradas=<M>`. Exit 0 si pudo leer el transcript.
"""
# sella-huellas: no (solo lee el transcript y las salidas de las tareas; no escribe nada)
import argparse
import glob
import json
import os
import re
import sys
import time

# UTF-8 en stdout Y EN STDERR, como en el resto de bin/.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

# Solo para transcripts sin `toolUseResult`. Anclados al inicio: un Bash que IMPRIME la frase en
# medio de su salida (un grep sobre otro transcript) no abre nada.
LANZA_BASH = re.compile(r"\s*(?:Command running in background with ID: ([A-Za-z0-9_-]+)"
                        r"|Command did not complete within [^\n]*? moved to the background \(ID: ([A-Za-z0-9_-]+)\))")
LANZA_MONITOR = re.compile(r"\s*Monitor started \(task ([A-Za-z0-9_-]+)")
SALIDA = re.compile(r"Output is being written to: (\S+?)\.?(?:\s|$)")
NOTIF = re.compile(r"<task-notification>(.*?)</task-notification>", re.S)
NOTIF_ID = re.compile(r"<task-id>([A-Za-z0-9_-]+)</task-id>")
NOTIF_FIN = re.compile(r"<status>(completed|failed|stopped|killed)</status>|<event>\[Monitor expired")
STOP_OK = re.compile(r"(?:Successfully stopped task|No task found with ID):? ([A-Za-z0-9_-]+)")
LINEAS_HARNESS = {"user", "queue-operation", "attachment"}


def texto(contenido):
    """El texto plano de un content de mensaje o de tool_result."""
    if isinstance(contenido, str):
        return contenido
    if isinstance(contenido, list):
        partes = []
        for b in contenido:
            if isinstance(b, dict):
                if isinstance(b.get("text"), str):
                    partes.append(b["text"])
                elif "content" in b:
                    partes.append(texto(b["content"]))
            elif isinstance(b, str):
                partes.append(b)
        return "\n".join(partes)
    return ""


def textos_harness(o):
    """Los textos de una linea del harness donde puede venir una task-notification."""
    msg = o.get("message") or {}
    contenido = msg.get("content")
    if isinstance(contenido, list):
        # Los bloques de texto, nunca un tool_result: la salida de un Bash no es el harness.
        yield texto([b for b in contenido if isinstance(b, dict) and b.get("type") == "text"])
    else:
        yield texto(contenido)
    if isinstance(o.get("content"), str):
        yield o["content"]
    att = o.get("attachment")
    if isinstance(att, dict):
        for k in ("prompt", "content"):
            if isinstance(att.get(k), str):
                yield att[k]


def analizar(ruta):
    lanzados = {}   # tool_use_id -> {tipo, descripcion, comando}
    tareas = {}     # task_id -> {...}
    orden = []
    cerradas = set()
    stops = {}      # tool_use_id de un TaskStop -> True
    with open(ruta, encoding="utf-8", errors="replace") as fh:
        for linea in fh:
            try:
                o = json.loads(linea)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            tipo = o.get("type")
            contenido = (o.get("message") or {}).get("content")
            if tipo == "assistant" and isinstance(contenido, list):
                for b in contenido:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    nombre, entrada = b.get("name"), b.get("input") or {}
                    # Todo Bash es candidato: uno sin run_in_background pasa a segundo plano si vence su timeout.
                    if nombre == "Bash":
                        lanzados[b.get("id")] = {"tipo": "Bash", "descripcion": entrada.get("description") or "",
                                                 "comando": entrada.get("command") or ""}
                    elif nombre == "Monitor":
                        lanzados[b.get("id")] = {"tipo": "Monitor", "descripcion": entrada.get("description") or "",
                                                 "comando": entrada.get("command") or ""}
                    elif nombre == "TaskStop":
                        stops[b.get("id")] = True
                continue
            if tipo not in LINEAS_HARNESS:
                continue
            if tipo == "user" and isinstance(contenido, list):
                resultados = [b for b in contenido if isinstance(b, dict) and b.get("type") == "tool_result"]
                # toolUseResult describe el tool_result de la linea: solo vale si hay uno.
                tur = o.get("toolUseResult") if len(resultados) == 1 else None
                for b in resultados:
                    uid, res = b.get("tool_use_id"), texto(b.get("content"))
                    if uid in lanzados:
                        info = lanzados.pop(uid)
                        if isinstance(tur, dict):
                            tid = tur.get("backgroundTaskId" if info["tipo"] == "Bash" else "taskId")
                        else:
                            m = LANZA_BASH.match(res) or LANZA_MONITOR.match(res)
                            tid = next(g for g in m.groups() if g) if m else None
                        if isinstance(tid, str) and tid:
                            info = dict(info)
                            ms = SALIDA.search(res)
                            info["salida"] = ms.group(1) if ms else ""
                            tareas[tid] = info
                            orden.append(tid)
                    elif uid in stops:
                        stops.pop(uid)
                        for m in STOP_OK.finditer(res):
                            cerradas.add(m.group(1))
            for t in textos_harness(o):
                if "<task-notification>" not in t:
                    continue
                for bloque in NOTIF.findall(t):
                    mi = NOTIF_ID.search(bloque)
                    if mi and NOTIF_FIN.search(bloque):
                        cerradas.add(mi.group(1))
    return [(tid, tareas[tid]) for tid in orden], cerradas


def ultimas_lineas(ruta, n=3):
    try:
        with open(ruta, "rb") as fh:
            fh.seek(0, 2)
            tam = fh.tell()
            fh.seek(max(0, tam - 8192))
            cola = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return []
    return [l.strip() for l in cola.splitlines() if l.strip()][-n:]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--session-id")
    ap.add_argument("--transcript")
    ap.add_argument("--projects-root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--ahora", type=float, help="epoch para calcular la edad de la salida (pruebas)")
    a = ap.parse_args()

    ruta = a.transcript
    if not ruta:
        sid = a.session_id or os.environ.get("CLAUDE_CODE_SESSION_ID", "")
        if not sid:
            print("resumen: abiertas=? motivo=sin-session-id (pasa --session-id o --transcript)")
            return 2
        cand = glob.glob(os.path.join(a.projects_root, "*", sid + ".jsonl"))
        if len(cand) != 1:
            print("resumen: abiertas=? motivo=%s" % ("no-hay-jsonl" if not cand else "jsonl-en-varios-proyectos"))
            return 2
        ruta = cand[0]
    if not os.path.isfile(ruta):
        print("resumen: abiertas=? motivo=no-hay-jsonl")
        return 2

    lanzadas, cerradas = analizar(ruta)
    ahora = a.ahora if a.ahora is not None else time.time()
    abiertas = [(tid, i) for tid, i in lanzadas if tid not in cerradas]
    for tid, i in abiertas:
        print("ABIERTA  %s  %s  %s" % (tid, i["tipo"], i["descripcion"] or "(sin descripcion)"))
        print("  comando: %s" % " ".join(i["comando"].split())[:160])
        if i.get("salida"):
            try:
                st = os.stat(i["salida"])
                print("  salida: %s (%d bytes, ultima escritura hace %d min)"
                      % (i["salida"], st.st_size, max(0, int((ahora - st.st_mtime) // 60))))
                for l in ultimas_lineas(i["salida"]):
                    print("  ultimas lineas: %s" % l[:200])
            except OSError:
                print("  salida: %s (no existe)" % i["salida"])
    print("resumen: abiertas=%d cerradas=%d" % (len(abiertas), len(lanzadas) - len(abiertas)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
