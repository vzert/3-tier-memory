#!/usr/bin/env python3
"""Mide candidatas de senal estructurada para p-272254efc5 sobre sesiones reales.

Uso: tools/medir-senal-defecto.py <PROJECT_DIR> <TRANSCRIPTS_DIR>

Por cada JSONL que escribio o edito una ficha de `<PROJECT_DIR>/memory/sessions/`:
  - cierres: cuantos TURNOS distintos (prompt real del usuario → siguiente) corrieron
    /checkpoint-3t o print-como-retomar.py. Candidata (c): un cierre rehecho.
  - veredicto: el ultimo `[ADVERSARY-VERDICT: break|hold` que el assistant escribio.
  - ninguno: si el `Proximo paso:` de la ficha final empieza por `ninguno`/`nada accionable`.
  - bugs: bullets de primer nivel en `## Bugs fixed` que no son "Ninguno". Candidata (b).
Imprime una fila por sesion y los totales. No clasifica texto: solo cuenta eventos y secciones.
"""
import glob, json, os, re, sys

proj, tdir = sys.argv[1], sys.argv[2]
SES = re.compile(r"(?:^|/)memory/sessions/([^/]+)\.md$")
VER = re.compile(r"^\[ADVERSARY-VERDICT:\s*(break|hold)\b", re.M)
INY = re.compile(r"^\s*(?:Another Claude session sent a message|<teammate-message|"
                 r"<task-notification>|\[SYSTEM NOTIFICATION)")


def prompt_real(r):
    if r.get("type") != "user" or r.get("isMeta"):
        return False
    c = (r.get("message") or {}).get("content")
    if isinstance(c, list):
        t = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
        if not t:
            return False
        c = t[0]
    return isinstance(c, str) and not INY.match(c)


def seccion(texto, nombre):
    m = re.search(r"^## " + re.escape(nombre) + r"[^\n]*\n(.*?)(?=^## |\Z)", texto, re.M | re.S)
    return m.group(1) if m else ""


filas = []
for jf in sorted(glob.glob(os.path.join(tdir, "*.jsonl"))):
    turno, cierres, fichas, ultimo = 0, set(), [], None
    try:
        lineas = open(jf, encoding="utf-8", errors="replace").read().splitlines()
    except Exception:
        continue
    for ln in lineas:
        try:
            r = json.loads(ln)
        except Exception:
            continue
        if prompt_real(r):
            turno += 1
            c = (r.get("message") or {}).get("content")
            if isinstance(c, str) and "<command-name>/checkpoint-3t</command-name>" in c:
                cierres.add(turno)
        if r.get("type") != "assistant":
            continue
        for b in (r.get("message") or {}).get("content") or []:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                for v in VER.findall(b.get("text", "")):
                    ultimo = v
            if b.get("type") != "tool_use":
                continue
            inp = b.get("input") or {}
            if b.get("name") == "Skill" and str(inp.get("skill", "")).split(":")[-1] == "checkpoint-3t":
                cierres.add(turno)
            if b.get("name") == "Bash" and "print-como-retomar.py" in (inp.get("command") or ""):
                cierres.add(turno)
            m = SES.search(inp.get("file_path") or "")
            if b.get("name") in ("Write", "Edit", "MultiEdit") and m:
                fichas.append(m.group(1))
    if not fichas:
        continue
    slug = fichas[-1]
    ruta = os.path.join(proj, "memory", "sessions", slug + ".md")
    if not os.path.exists(ruta):
        continue
    t = open(ruta, encoding="utf-8").read()
    pp = re.search(r"^\**Pr[oó]ximo paso:\**\s*(.*)$", seccion(t, "Como retomar"), re.M | re.I)
    ret = seccion(t, "Como retomar").strip().lower()
    ninguno = (pp and pp.group(1).lower().startswith(("ninguno", "nada accionable"))) or \
              (not pp and ret.startswith("ninguno"))
    bugs = [l for l in seccion(t, "Bugs fixed").splitlines()
            if re.match(r"^ {0,3}(?:[-*+]|\d+[.)])\s", l)
            and not re.match(r"^ {0,3}(?:[-*+]|\d+[.)])\s+\**ninguno\**\s*\.?\s*$", l, re.I)]
    filas.append((os.path.basename(jf)[:8], slug, len(cierres), ultimo or "-", bool(ninguno), len(bugs)))

print(f"{'jsonl':8} {'cierres':>7} {'verd':>5} {'ning':>4} {'bugs':>4}  ficha")
for f in filas:
    print(f"{f[0]:8} {f[2]:>7} {f[3]:>5} {str(f[4])[0]:>4} {f[5]:>4}  {f[1]}")
n = len(filas)
ning = [f for f in filas if f[4]]
print(f"\nsesiones={n} ninguno={len(ning)}")
print(f"(c) ninguno y cierres>=2: {sum(1 for f in ning if f[2] >= 2)}  | cierres>=2 total: {sum(1 for f in filas if f[2] >= 2)}")
print(f"(v) ninguno y ultimo veredicto break: {sum(1 for f in ning if f[3] == 'break')}")
print(f"(b) ninguno y Bugs fixed no vacio: {sum(1 for f in ning if f[5])}  | Bugs fixed no vacio total: {sum(1 for f in filas if f[5])}")
