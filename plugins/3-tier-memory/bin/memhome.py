"""
3-tier-memory plugin: memory-home.sh para los scripts de Python (2.52.0).

Una sola implementacion de la regla (memory-home.sh); aqui solo se la llama. Por que hace falta en
Python: CLAUDE_PROJECT_DIR llega VACIA a las llamadas Bash del agente, asi que un `journal-emit.py`
sin --memory-dir resolvia `<cwd>/memory`, y en un worktree enlazado ese es el worktree, no la
memoria del repo. Medido por el adversario de 2.52.0 (ronda 1): con memory/ ignorada el
`session.add --commit` de Step 6 salia 1 ("no existe el directorio de memoria"); con memory/
versionada el evento caia en el journal de la copia del worktree y la del principal nunca lo veia.

Sin bash, o si el script falla, todo queda sin cambios (lo de antes de 2.52.0).
"""
# sella-huellas: no (libreria: no escribe nada)
import os
import subprocess
import sys

# Guarda de flujos (test-utf8-streams.sh): la exige a todo .py del plugin, tambien a una libreria.
for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

_MH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory-home.sh")
_cache = {}


def home(proj):
    """La carpeta cuya memory/ se usa para el proyecto `proj` (memory-home.sh)."""
    if not proj or not os.path.isfile(_MH):
        return proj
    if proj in _cache:
        return _cache[proj]
    out = proj
    try:
        r = subprocess.run(["bash", _MH, proj], capture_output=True, text=True, timeout=20)
        if r.returncode == 0 and r.stdout.strip():
            out = r.stdout.rstrip("\n")
    except Exception:
        pass
    _cache[proj] = out
    return out


def normaliza(mem):
    """Un directorio de memoria dado (`<carpeta>/memory`, explicito o relativo al cwd) pasa a la
    memoria del worktree principal si <carpeta> esta en un worktree enlazado. Cualquier otra forma
    (memoria auto de Claude Code, un nombre distinto de memory) queda igual."""
    mem = os.path.abspath(mem)
    if os.path.basename(mem.rstrip(os.sep)) != "memory":
        return mem
    padre = os.path.dirname(mem.rstrip(os.sep))
    h = home(padre)
    if h and h != padre:
        return os.path.join(h, "memory")
    return mem
