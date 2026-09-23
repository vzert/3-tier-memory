#!/bin/bash

# Salida de python en UTF-8 SIEMPRE. En Windows, python codifica stdout con la pagina de codigos
# local cuando va a una tuberia (cp1252), no en UTF-8: el texto en espanol de este plugin salia con
# los guiones largos y los acentos rotos. Medido en CI el 2026-09-12 sobre la salida real del hook
# de arranque: `item con id — _creado:` llegaba como `item con id \xef\xbf\xbd _creado:`. Es texto
# que se inyecta en el prompt de cada sesion, asi que lo veia el modelo y lo veia el usuario.
# PYTHONUTF8 necesita 3.7+; PYTHONIOENCODING cubre lo anterior. Los dos son no-op fuera de Windows.
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (hook de solo lectura: decide un deny o imprime un aviso, nunca escribe)
# 3-tier-memory plugin: PreToolUse hook (Edit|Write|MultiEdit) — guardia del journal (v2.12.0;
# aviso incondicional desde v2.24.0)
#
# El bloqueo duro (deny) sigue siendo opt-in: solo actua si memory/.memory-config contiene
# `journal_strict=1`. Ahi deniega la edicion directa de los archivos que desde v2.12.0 pertenecen
# al compactador:
#   memory/_*.md                (los indices Tier 2)
#   memory/pendientes/YYYY-MM.md (el archivo mensual de pendientes)
# con el mensaje "usa journal-emit". Todo lo demas (MEMORY.md, sessions/, plans/, research/,
# learnings/<topic>.md, archivos fuera de memory/) pasa sin tocarse.
#
# SIN journal_strict=1 (el caso comun — measured 2026-09-12: la practica totalidad de las
# instalaciones no tienen .memory-config) este hook YA NO sale en silencio: imprime un AVISO (no
# bloquea) en el mismo formato que bin/bash-journal-nudge.sh, que aprendio esta leccion antes.
# Antes de v2.24.0 una escritura a mano via Edit/Write a un indice protegido no generaba NINGUNA
# senal si journal_strict no estaba activado — el incidente de cloudflare-expert 2026-09-12 (12
# ids inventados + filas duplicadas de una migracion escrita a mano) paso exactamente por esta
# asimetria: bash-journal-nudge.sh SI avisaba escrituras por Bash sin depender de la config, pero
# el equivalente para Edit/Write se quedaba mudo. Misma asimetria, mismo fix: avisar siempre,
# bloquear solo si se pidio expresamente.
#
# ESTE PRINT, POR SI SOLO, NO LLEGA AL AGENTE. Medido con `claude -p` (2026-09-14, hallazgo de una
# revision adversarial que marco la afirmacion original como "ungrounded" por vivir solo en la
# conversacion): un PreToolUse o PostToolUse que imprime texto plano y sale 0 va al log de
# depuracion, no al contexto del modelo ni al canal de la persona — el mismo defecto, nunca medido,
# que ya tenia bash-journal-nudge.sh. La medicion quedo como script repetible, no solo como
# prosa: `bin/verify-hook-delivery.sh` (manual, cuesta tokens de API, no vive en bin/test-*.sh)
# monta un proyecto con los tres tipos de hook y un centinela distinto en cada uno, y pregunta al
# modelo cual vio. Se deja el print de todos modos porque es inofensivo y lo ve quien mire el log
# en modo debug, pero la
# entrega REAL —el aviso que de verdad llega al agente, en el siguiente prompt de la MISMA
# sesion— la hace bin/journal-drift-nudge.sh (UserPromptSubmit, el mismo canal que ya usa
# bin/recall.sh) comparando el hash del archivo contra la ultima huella sellada. Ese mecanismo es
# tool-agnostico: pilla igual una escritura por Bash, Edit, Write o MultiEdit, sin necesitar saber
# cual de los dos la causo.
#
# El deny NO es el mecanismo principal de seguridad del journal — es un recordatorio con dientes
# para quien lo pida. Claude Code ha tenido bugs en los que un deny de PreToolUse se ignora
# (issues 18312 y 37210); el alcance real en la version instalada se mide con
# bin/test-journal-guard.sh (unitario) y esta documentado en el README.
#
# Para una edicion manual legitima (merge de reglas en /consolidate-3t, reparar un indice a
# mano): el aviso no impide nada. Con journal_strict=1, pon `journal_strict=0` en
# memory/.memory-config, edita, y vuelve a ponerlo en 1. El hook lee el archivo en cada llamada;
# no hay que reiniciar nada.

source "$(dirname "$0")/resolve-project-dir.sh"

# Detect memory directory (Model B first, then Model A fallback) — mismo criterio que session-start.sh
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  if [ -f "$AUTO_DIR/_pendientes.md" ]; then
    MEMORY_DIR="$AUTO_DIR"
  fi
fi
[ -z "${MEMORY_DIR:-}" ] && exit 0

# Fast path barato en shell (sin arrancar python): si el JSON del hook ni siquiera menciona un
# `_*.md` o un `pendientes/YYYY-MM.md`, no hay nada que mirar. GENERICO a proposito, no una lista
# de los 5 indices de hoy: el guard de python protege CUALQUIER `memory/_*.md`
# (`^_[^/\\]*\.md$`), no solo esos cinco. Enumerar nombres aqui (como se hizo primero, v2.24.0
# inicial) dejaba un `memory/_otro.md` futuro pasando SIN AVISO por este atajo, antes de que
# python llegara a mirarlo — el mismo defecto de fondo que este archivo existe para cerrar, solo
# que introducido por el propio atajo en vez de por journal_strict. Un falso positivo aqui solo
# cuesta arrancar python de mas; un falso negativo vuelve a dejar una escritura muda.
case "$_HOOK_INPUT" in
  *'"file_path"'*'/_'*'.md'*|*'"file_path"'*'\\_'*'.md'*|*'"file_path"'*'pendientes/20'*'.md'*|*'"file_path"'*'pendientes\\'*'.md'*) ;;
  *) exit 0 ;;
esac

# journal_strict=1 activa el deny; sin el (o sin .memory-config, el caso comun) el hook sigue
# corriendo pero solo para avisar — ya no sale en silencio (v2.24.0).
STRICT=0
CONFIG="$MEMORY_DIR/.memory-config"
if [ -f "$CONFIG" ] && grep -Eq '^[[:space:]]*journal_strict[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$CONFIG"; then
  STRICT=1
fi

HOOK_INPUT="$_HOOK_INPUT" MEMORY_DIR="$MEMORY_DIR" STRICT="$STRICT" python3 - <<'PY'
import json, os, re, subprocess, sys


def native(p):
    # Git Bash en Windows: bash ve rutas POSIX (/tmp/x, /c/Users/x) pero python3 es nativo y las
    # entiende como C:\tmp\x. MSYS ya convierte las variables de entorno que parecen rutas
    # (MEMORY_DIR llega como C:\...), pero no toca el JSON del hook. Sin esto, relpath entre una
    # ruta convertida y otra sin convertir empieza con ".." y la guardia se apaga en silencio
    # (medido en windows-latest, 2026-09-03: 6/6 casos de deny salian vacios). Fail-open.
    if sys.platform == "win32" and p.startswith("/"):
        try:
            out = subprocess.run(["cygpath", "-w", p], capture_output=True, text=True, timeout=5)
            if out.returncode == 0 and out.stdout.strip():
                return out.stdout.strip()
        except Exception:
            pass
    return p


try:
    data = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)  # entrada rara: no bloquear nada por un parse fallido

tool = data.get("tool_name", "")
if tool not in ("Edit", "Write", "MultiEdit"):
    sys.exit(0)
path = (data.get("tool_input") or {}).get("file_path") or ""
if not path:
    sys.exit(0)

path = native(path)
cwd = native(data.get("cwd") or os.getcwd())
if not os.path.isabs(path):
    path = os.path.join(cwd, path)
mem = os.path.realpath(native(os.environ["MEMORY_DIR"]))
# realpath del padre + basename: el archivo puede no existir todavia (Write nuevo).
parent = os.path.realpath(os.path.dirname(path))
full = os.path.join(parent, os.path.basename(path))
try:
    rel = os.path.relpath(full, mem)
except ValueError:
    sys.exit(0)  # otra unidad (Windows): no es memory/
if rel.startswith(".."):
    sys.exit(0)

guarded = re.match(r"^_[^/\\]*\.md$", rel) or re.match(r"^pendientes[/\\]\d{4}-\d{2}\.md$", rel)
if not guarded:
    sys.exit(0)

if os.environ.get("STRICT") == "1":
    reason = (
        f"journal_strict=1: memory/{rel} lo escribe solo el compactador del journal. "
        "Usa journal-emit.py (pendiente.add/resolve/update/reopen, session.add, learning.add/update, plan.upsert/reopen, "
        "research.upsert) y luego journal-compact.py. Para una edicion manual legitima pon "
        "journal_strict=0 en memory/.memory-config, edita y vuelve a ponerlo en 1."
    )
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
else:
    # Aviso, no bloqueo — misma redaccion/contrato que bin/bash-journal-nudge.sh. Sin esto el
    # hook salia en silencio total (el caso comun, sin journal_strict=1): asi paso el incidente
    # de cloudflare-expert 2026-09-12.
    print(
        f"AVISO del plugin 3-tier-memory: Edit/Write esta escribiendo memory/{rel} directamente. "
        "Ese indice lo escribe SOLO el compactador del journal — una linea puesta a mano no "
        "tiene evento que auditar y no genera su fila de Tier 3, asi que al cerrarla se pierden "
        "su fecha de cierre y la sesion que la cerro. "
        "Usa bin/journal-emit.py (pendiente.add/resolve/update/reopen, session.add, learning.add/update, plan.upsert/reopen, "
        "research.upsert) y luego bin/journal-compact.py. "
        "Si la escritura es una reparacion manual deliberada, hazla y despues corre "
        "`journal-compact.py --reseal` para que no se reporte como deriva. "
        "Esto es un aviso, no un bloqueo: puede equivocarse y no impide nada."
    )
PY
exit 0
