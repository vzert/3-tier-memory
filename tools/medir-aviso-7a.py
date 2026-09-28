#!/usr/bin/env python3
"""Medicion de 2.41.0: el aviso de Step 7a en el commit del checkpoint, sobre transcripts reales.

Recorre ~/.claude/projects/*/*.jsonl (salvo el proyecto desde el que se corre) y, para cada commit
`checkpoint:` entre DESDE y HASTA, dice si antes hubo una corrida EMPAREJADA de checkpoint-audit.py
(tool_use + su tool_result con `resumen: hecho=N`) y si el PreToolUse viejo aviso (registro
`hook_success` con su texto). Por sesion, si el primer commit fue antes o despues del audit.
Las cifras del CHANGELOG salen de: python3 tools/medir-aviso-7a.py 2026-09-19T20 2026-09-28T15:50
El aviso quedaba en el transcript pero NO llegaba al modelo: ver bin/verify-hook-delivery.sh.
"""
import json, glob, os, re, sys, collections
DESDE, HASTA = (sys.argv[1:3] + ["2026-09-19T20", "9999"])[:2]
# Se excluye el repo del plugin por su raiz PRINCIPAL, no por el cwd: desde un worktree el cwd es
# otro directorio y las sesiones del repo quedaban dentro (adversario de 2.41.0).
import subprocess
_comun = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                        capture_output=True, text=True).stdout.strip()
_raiz = os.path.dirname(_comun) if _comun else os.getcwd()
PROPIO = re.sub(r"[^A-Za-z0-9]", "-", _raiz)
root = os.path.expanduser("~/.claude/projects/")
aviso_tab = collections.Counter(); proys_aviso = set(); orden = collections.Counter()
for f in glob.glob(root + "*/*.jsonl"):
    if os.path.basename(os.path.dirname(f)).startswith(PROPIO): continue   # el repo y sus worktrees
    usos = {}; salidas = set(); avisos = set(); commits = []; n = 0
    for line in open(f, encoding="utf-8", errors="replace"):
        n += 1
        if "checkpoint" not in line and "hecho=" not in line: continue
        try: r = json.loads(line)
        except Exception: continue
        ts = r.get("timestamp", "") or ""
        att = r.get("attachment") or {}
        if att.get("type") == "hook_success" and "no corriste" in (att.get("content") or ""): avisos.add(att.get("toolUseID"))
        c = (r.get("message") or {}).get("content") if isinstance(r.get("message"), dict) else None
        if not isinstance(c, list): continue
        for b in c:
            if not isinstance(b, dict): continue
            if b.get("type") == "tool_use":
                cmd = (b.get("input") or {}).get("command", "") or ""
                if re.search(r"-m\s*['\"]?\s*checkpoint", cmd, re.I) and re.search(r"\bgit\b[^\n;&|]{0,200}\bcommit\b", cmd) and DESDE <= ts < HASTA:
                    commits.append((n, b.get("id")))
                if re.search(r"python3?\s+\S*checkpoint-audit\.py", cmd): usos[b.get("id")] = n
            elif b.get("type") == "tool_result":
                t = b.get("content"); t = t if isinstance(t, str) else json.dumps(t)
                if re.search(r"resumen:\s*hecho=\d+", t): salidas.add(b.get("tool_use_id"))
    audits = sorted(n for u, n in usos.items() if u in salidas)
    for n, cid in commits:
        k = ("con audit" if any(a < n for a in audits) else "sin audit", "aviso" if cid in avisos else "calla")
        aviso_tab[k] += 1
        if k == ("sin audit", "aviso"): proys_aviso.add(f.split("/")[-2])
    if commits:
        p = commits[0][0]
        orden[("audit antes" if any(a < p for a in audits) else "sin audit antes") + " / " + ("audit despues" if any(a > p for a in audits) else "sin audit despues")] += 1
print(f"ventana {DESDE} .. {HASTA}")
for k, v in sorted(aviso_tab.items()): print(f"  {v:4} {k[0]} -> {k[1]}")
print(f"  proyectos con aviso sin audit: {len(proys_aviso)}")
print(f"  sesiones con commit de checkpoint: {sum(orden.values())}")
for k, v in sorted(orden.items()): print(f"  {v:4} primer commit: {k}")
