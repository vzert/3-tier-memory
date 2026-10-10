#!/usr/bin/env python3
"""Medicion de 2.54.0: ¿el /checkpoint-3t es el final de la sesion?

Decide donde se hace `Hacerlo ahora` de Step 3b: dentro del checkpoint o despues. Recorre
~/.claude/projects/*/*.jsonl y, para cada /checkpoint-3t (mensaje que empieza con
"# Memory Checkpoint", unico por timestamp+uuid) anterior a HASTA, mira el primer mensaje del
usuario que llega despues y antes del siguiente checkpoint de la misma sesion:
- sin mensaje: la sesion termino ahi;
- sobre el checkpoint: menciona checkpoint, ficha, snippet, pendiente o "falto" (aproximado, por
  palabras clave);
- otro: el usuario pidio otra cosa.
No cuentan como del usuario: tool_result, avisos de hooks, `<...>` del harness ni mensajes de otra
sesion o de un supervisor (adversario de 2.54.0: la primera medicion los contaba).
Tambien cuenta, en sesiones con 2+ checkpoints, que hizo cada checkpoint posterior con la ficha
del primero (Write encima, solo Edit, ficha nueva, ninguna).
Las cifras del CHANGELOG salen de: python3 tools/medir-trabajo-tras-checkpoint.py 2026-10-10T02:00
"""
import json, glob, os, re, sys, collections
HASTA = (sys.argv[1:2] + ["9999"])[0]
MAQUINA = re.compile(r"^(Another Claude session|Nota del supervisor|\[SYSTEM|Caveat:|"
                     r"This session is being continued)", re.I)
SOBRE = re.compile(r"checkpoint|falt[oó]|faltaba|snippet|ficha|como retomar|pendiente", re.I)
FICHA = re.compile(r"sessions/([^/]+\.md)$")


def texto(d):
    c = d.get("message", {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return ""


def del_usuario(d):
    if d.get("type") != "user" or d.get("isSidechain") or d.get("isMeta"):
        return None
    c = d.get("message", {}).get("content")
    if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
        return None
    t = texto(d).strip()
    if not t or t.startswith(("<", "Stop hook", "# Memory Checkpoint", "[Request interrupted")):
        return None
    if MAQUINA.match(t):
        return None
    return t


def escrituras(L, a, b):
    w, e = set(), set()
    for d in L[a:b]:
        c = d.get("message", {}).get("content")
        if not isinstance(c, list):
            continue
        for x in c:
            if x.get("type") == "tool_use" and x.get("name") in ("Write", "Edit", "MultiEdit"):
                m = FICHA.search(x.get("input", {}).get("file_path", ""))
                if m:
                    (w if x["name"] == "Write" else e).add(m.group(1))
    return w, e


vistos, n = set(), 0
primero, trabajo, segundos = collections.Counter(), collections.Counter(), collections.Counter()
for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    try:
        L = [json.loads(l) for l in open(f, encoding="utf-8")]
    except Exception:
        continue
    ck = [i for i, d in enumerate(L) if d.get("type") == "user" and not d.get("isSidechain")
          and texto(d).startswith("# Memory Checkpoint") and d.get("timestamp", "") < HASTA]
    for k, i in enumerate(ck):
        clave = (L[i].get("timestamp"), L[i].get("uuid"))
        if clave in vistos:
            continue
        vistos.add(clave)
        n += 1
        fin = ck[k + 1] if k + 1 < len(ck) else len(L)
        j0 = next((j for j in range(i + 1, fin) if del_usuario(L[j])), None)
        if j0 is None:
            primero["sin mensaje"] += 1
            continue
        t = del_usuario(L[j0])
        cat = "sobre el checkpoint" if SOBRE.search(t[:200]) and len(t) < 300 else "otro"
        primero[cat] += 1
        herr = sum(1 for d in L[j0:fin] if d.get("type") == "assistant"
                   for x in (d.get("message", {}).get("content") or []) if isinstance(x, dict)
                   and x.get("type") == "tool_use")
        if herr >= 5:
            trabajo[cat] += 1
    if len(ck) >= 2:
        w0, e0 = escrituras(L, ck[0], ck[1])
        del_primero = w0 | e0
        for k in range(1, len(ck)):
            w, e = escrituras(L, ck[k], ck[k + 1] if k + 1 < len(ck) else len(L))
            if w & del_primero:
                segundos["Write sobre la ficha del primero"] += 1
            elif e & del_primero:
                segundos["solo Edit sobre la ficha del primero"] += 1
            elif w:
                segundos["ficha nueva"] += 1
            else:
                segundos["sin escribir ficha"] += 1

print(f"checkpoints unicos antes de {HASTA}: {n}")
for c in ("sin mensaje", "sobre el checkpoint", "otro"):
    print(f"  primer mensaje del usuario despues = {c}: {primero[c]} ({100 * primero[c] // max(n, 1)}%)")
for c in ("sobre el checkpoint", "otro"):
    print(f"  {c} y 5+ herramientas despues: {trabajo[c]} ({100 * trabajo[c] // max(n, 1)}%)")
print(f"checkpoints posteriores al primero de su sesion: {sum(segundos.values())}")
for c, v in segundos.most_common():
    print(f"  {c}: {v}")
