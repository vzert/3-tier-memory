#!/bin/bash
# 3-tier-memory plugin: PreCompact hook
# Injects urgent checkpoint reminder before context compaction

# Detect memory directory
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  if [ -f "$AUTO_DIR/_pendientes.md" ]; then
    MEMORY_DIR="$AUTO_DIR"
  fi
fi

# Exit silently if no memory system found
[ -z "$MEMORY_DIR" ] && exit 0

echo "COMPACTACION INMINENTE — Ejecuta /checkpoint AHORA antes de que se pierda contexto de la conversacion."
echo ""
echo "Si no puedes ejecutar /checkpoint completo, como minimo:"
echo "1. Escribe los pendientes abiertos a memory/_pendientes.md"
echo "2. Escribe los learnings nuevos a memory/learnings/"
echo "3. Actualiza memory/_session-index.md con esta sesion"
