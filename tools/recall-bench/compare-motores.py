#!/usr/bin/env python3
"""Compara byte a byte el motor viejo de recall (bloque Python embebido en bin/recall.sh en un
commit dado) con bin/recall_rank.py, sobre prompts reales.

Criterio de aceptacion de la Fase F0 (memory/plans/plan-ciclo-de-vida-learnings.md): la
extraccion de recall_rank.py es un cambio sin efecto. Para probarlo:

- los indices se construyen con build-recall-index.py en un directorio temporal a partir de los
  memory/ de varios proyectos. Solo se LEEN esos memory/: nunca se corre recall.sh entero, que
  compacta el journal y reescribe el indice del proyecto que resuelve;
- los prompts salen de los JSONL de ~/.claude/projects (mensajes de usuario escritos a mano, no
  resultados de herramientas ni comandos), elegidos de forma determinista;
- los dos motores corren con el mismo entorno (RECALL_INDEX, RECALL_PROMPT) en la misma pasada,
  asi que comparten date.today();
- cada prompt se prueba contra un indice distinto (rotando), y la prueba solo vale si al menos
  --min-con-salida prompts devuelven algo: comparar dos salidas vacias no prueba nada.

Sale 0 si todo coincide y hay suficientes salidas no vacias; 1 si no.

Uso:
  compare-motores.py [--commit 3119885] [--n 50] [--min-con-salida 30]
                     [--corpus-raiz ~/Projects] [--max-corpus 4]
                     [--nuevo <ruta a recall_rank.py>]   (para el sabotaje de test-bench.sh)
                     [--prompts <fichero, un JSON string por linea>] [--memorias <dir,dir>]
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile

RAIZ = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BIN = os.path.join(RAIZ, "plugins", "3-tier-memory", "bin")

# UTF-8 en stdout y stderr, como los .py de bin/ (regla 63): en Windows el flujo sigue la pagina de
# codigos local y los mensajes en espanol salen rotos.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")



def bloque_viejo(commit):
    r = subprocess.run(
        ["git", "-C", RAIZ, "show", f"{commit}:plugins/3-tier-memory/bin/recall.sh"],
        capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        # Un checkout superficial (CI sin fetch-depth: 0) no tiene el commit de referencia.
        print(f"no se puede leer recall.sh en {commit}: {r.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    fuente = r.stdout
    ini = fuente.index("python3 <<'PYEOF'")
    ini = fuente.index("\n", ini) + 1
    fin = fuente.index("\nPYEOF\n", ini)
    return fuente[ini:fin] + "\n"


def descubrir(raiz, maximo):
    """Los `maximo` memory/ con mas reglas numeradas bajo raiz/*/memory: los corpus mas grandes de
    esta instalacion, sin nombrar ninguno. Empates por nombre, para que sea determinista."""
    cands = []
    for mem in sorted(glob.glob(os.path.join(raiz, "*", "memory"))):
        n = 0
        for f in glob.glob(os.path.join(mem, "learnings", "*.md")):
            try:
                n += sum(1 for l in open(f, encoding="utf-8") if l[:1].isdigit())
            except Exception:
                continue
        if n:
            cands.append((-n, mem))
    return [m for _, m in sorted(cands)[:maximo]]


def prompts_reales(n):
    """Mensajes de usuario tecleados, de todos los proyectos, en orden determinista."""
    vistos, salida = set(), []
    for f in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))):
        try:
            lineas = open(f, encoding="utf-8").read().splitlines()
        except Exception:
            continue
        for l in lineas:
            try:
                r = json.loads(l)
            except Exception:
                continue
            if r.get("type") != "user" or r.get("isMeta") or r.get("isSidechain"):
                continue
            c = (r.get("message") or {}).get("content")
            if not isinstance(c, str):
                continue  # los tool_result vienen como lista
            t = c.strip()
            if not (15 <= len(t) <= 600) or t.startswith("<") or t.startswith("/") \
                    or "Caveat:" in t or t in vistos:
                continue
            vistos.add(t)
            salida.append(t)
    # muestreo determinista y repartido: cada k-esimo del total
    if len(salida) <= n:
        return salida
    paso = len(salida) / n
    return [salida[int(i * paso)] for i in range(n)]


def correr(cmd, indice, prompt):
    env = dict(os.environ, RECALL_INDEX=indice, RECALL_PROMPT=prompt,
               PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    r = subprocess.run(cmd, capture_output=True, env=env, timeout=60)
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", default="3119885")
    ap.add_argument("--n", type=int, default=50)
    ap.add_argument("--min-con-salida", type=int, default=30)
    ap.add_argument("--corpus-raiz", default=os.path.expanduser("~/Projects"))
    ap.add_argument("--max-corpus", type=int, default=4)
    ap.add_argument("--nuevo", default=os.path.join(BIN, "recall_rank.py"))
    ap.add_argument("--prompts", default="")
    ap.add_argument("--memorias", default="")
    a = ap.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        viejo = os.path.join(tmp, "motor_viejo.py")
        open(viejo, "w", encoding="utf-8").write(bloque_viejo(a.commit))

        memorias = [m for m in a.memorias.split(",") if m] or descubrir(a.corpus_raiz, a.max_corpus)
        if not memorias:
            print(f"no hay ningun memory/ con reglas bajo {a.corpus_raiz}; usa --memorias",
                  file=sys.stderr)
            return 1
        indices = []
        for m in memorias:
            if not os.path.isdir(m):
                print(f"falta el memory/: {m}", file=sys.stderr)
                return 1
            out = os.path.join(tmp, f"idx-{len(indices)}.jsonl")
            subprocess.run([sys.executable, os.path.join(BIN, "build-recall-index.py"), m, out],
                           capture_output=True, check=True)
            indices.append((m, out))

        if a.prompts:
            prompts = [json.loads(l) for l in open(a.prompts, encoding="utf-8") if l.strip()]
        else:
            prompts = prompts_reales(a.n)
        if len(prompts) < a.n:
            print(f"solo hay {len(prompts)} prompts, hacen falta {a.n}", file=sys.stderr)
            return 1

        distintos, con_salida = 0, 0
        for i, p in enumerate(prompts):
            mem, idx = indices[i % len(indices)]
            sv = correr([sys.executable, viejo], idx, p)
            sn = correr([sys.executable, a.nuevo], idx, p)
            if sv:
                con_salida += 1
            if sv != sn:
                distintos += 1
                print(f"DISTINTO #{i} ({os.path.basename(os.path.dirname(mem))}): {p[:70]!r}")
                print(f"  viejo {len(sv)} bytes, nuevo {len(sn)} bytes")

        print(f"prompts={len(prompts)} indices={len(indices)} iguales={len(prompts) - distintos} "
              f"distintos={distintos} con_salida={con_salida}")
        if distintos:
            return 1
        if con_salida < a.min_con_salida:
            print(f"solo {con_salida} prompts con salida (< {a.min_con_salida}): la comparacion "
                  f"no prueba nada", file=sys.stderr)
            return 1
        return 0


if __name__ == "__main__":
    sys.exit(main())
