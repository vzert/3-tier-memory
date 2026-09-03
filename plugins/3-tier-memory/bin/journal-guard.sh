#!/bin/bash
# 3-tier-memory plugin: PreToolUse hook (Edit|Write|MultiEdit) — guardia estricta del journal (v2.12.0)
#
# OFF por defecto. Solo actua si memory/.memory-config contiene `journal_strict=1`. En ese caso
# deniega la edicion directa de los archivos que desde v2.12.0 pertenecen al compactador:
#   memory/_*.md                (los indices Tier 2)
#   memory/pendientes/YYYY-MM.md (el archivo mensual de pendientes)
# con el mensaje "usa journal-emit". Todo lo demas (MEMORY.md, sessions/, plans/, research/,
# learnings/<topic>.md, archivos fuera de memory/) pasa sin tocarse.
#
# No es el mecanismo principal de seguridad del journal — es un recordatorio con dientes para
# quien lo pida. Claude Code ha tenido bugs en los que un deny de PreToolUse se ignora
# (issues 18312 y 37210); el alcance real en la version instalada se mide con
# bin/test-journal-guard.sh (unitario) y esta documentado en el README.
#
# Para una edicion manual legitima (merge de reglas en /consolidate-3t, reparar un indice a
# mano): pon `journal_strict=0` en memory/.memory-config, edita, y vuelve a ponerlo en 1.
# El hook lee el archivo en cada llamada; no hay que reiniciar nada.

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

# Fast path: sin config o sin journal_strict=1, no hay nada que hacer.
CONFIG="$MEMORY_DIR/.memory-config"
[ -f "$CONFIG" ] || exit 0
grep -Eq '^[[:space:]]*journal_strict[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$CONFIG" || exit 0

HOOK_INPUT="$_HOOK_INPUT" MEMORY_DIR="$MEMORY_DIR" python3 - <<'PY'
import json, os, re, sys

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

cwd = data.get("cwd") or os.getcwd()
if not os.path.isabs(path):
    path = os.path.join(cwd, path)
mem = os.path.realpath(os.environ["MEMORY_DIR"])
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

reason = (
    f"journal_strict=1: memory/{rel} lo escribe solo el compactador del journal. "
    "Usa journal-emit.py (pendiente.add/resolve, session.add, learning.add, plan.upsert, "
    "research.upsert) y luego journal-compact.py. Para una edicion manual legitima pon "
    "journal_strict=0 en memory/.memory-config, edita y vuelve a ponerlo en 1."
)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": reason,
}}))
PY
exit 0
