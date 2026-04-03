#!/bin/bash
# 3-tier-memory plugin: SessionStart hook
# Injects open pendientes and protocol reminder at session start

# Detect memory directory (Model B first, then Model A fallback)
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  # Model A: try auto-memory
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  if [ -f "$AUTO_DIR/_pendientes.md" ]; then
    MEMORY_DIR="$AUTO_DIR"
  fi
fi

# Exit silently if no memory system found
[ -z "$MEMORY_DIR" ] && exit 0

# Extract open pendientes
PENDIENTES=$(grep -E '^\- \[ \]' "$MEMORY_DIR/_pendientes.md" 2>/dev/null)

if [ -n "$PENDIENTES" ]; then
  echo "PENDIENTES ABIERTOS:"
  echo "$PENDIENTES"
  echo ""
fi

echo "PROTOCOLO: Registrar planes en _plans-index.md, sessions en _session-index.md, y pendientes en _pendientes.md DURANTE ejecucion. No batching."
echo "Usar /3-tier-memory:checkpoint para guardar progreso (actualiza memoria + git commit)."
echo "ANTES de cambios importantes: leer memory/_learnings.md y consultar el topic file relevante."
