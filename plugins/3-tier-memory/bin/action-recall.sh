#!/bin/bash
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (hook de solo lectura de memory/: inyecta contexto o niega una llamada; solo
# escribe su estado por sesion en el directorio de estado de la maquina, fuera de memory/)
# 3-tier-memory plugin: PreToolUse (Bash|Edit|Write|MultiEdit) — recall en el momento de la accion
# (F5 del plan de ciclo de vida de learnings). Pone delante del agente la regla cuyo disparador
# `cmd`/`path` casa con la llamada, aunque no haya prompt. La logica vive en action_match.py, que
# el banco tools/recall-bench/recall-bench.py importa.
#
# Dos niveles (H9: el additionalContext de PreToolUse llega DESPUES de emitida la llamada, junto a
# su resultado; verify-hook-delivery.sh lo mide):
#   - aviso: JSON additionalContext. Sirve para lo que viene despues (verificar, no repetir).
#   - freno: permissionDecision deny, solo para una regla con `freno=si` que casa por `cmd` y no se
#     ha visto en la sesion. Salida: repetir el comando con `# regla-vista:<topic>#<N>` al final.
# Nunca devuelve allow ni ask. Falla en abierto (I6): sin indice, entrada rota o estado sin
# permiso de escritura, sale 0 y en silencio.
#
# El indice `.action-index.json` lo escribe build-recall-index.py cuando recall.sh reconstruye el
# de recall (en cada prompt, si memory/ cambio). Este hook no lo reconstruye: una regla retirada a
# mitad de turno puede servirse hasta el prompt siguiente.

source "$(dirname "$0")/resolve-project-dir.sh"

ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
STATE_DIR="$HOME/.claude/projects/$ENCODED"
INDEX="$STATE_DIR/.action-index.json"
[ -f "$INDEX" ] || exit 0

# Mismo memory/ que recall.sh (Model B, luego Model A), solo para el pie de retirada.
MEMORY_DIR=""
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -f "$STATE_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$STATE_DIR/memory"
fi

ACTION_INPUT="$_HOOK_INPUT" ACTION_INDEX="$INDEX" ACTION_STATE_DIR="$STATE_DIR" \
  ACTION_RAIZ="$CLAUDE_PROJECT_DIR" ACTION_PIE="$(dirname "$0")/journal-emit.py" \
  ACTION_MEMORY_DIR="$MEMORY_DIR" python3 "$(dirname "$0")/action_match.py" 2>/dev/null
exit 0
