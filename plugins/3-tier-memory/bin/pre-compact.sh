#!/bin/bash
# 3-tier-memory plugin: PreCompact hook
# Injects urgent checkpoint reminder before context compaction

source "$(dirname "$0")/resolve-project-dir.sh"

# Detect memory directory
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  if [ -f "$AUTO_DIR/_pendientes.md" ]; then
    MEMORY_DIR="$AUTO_DIR"
  fi
fi

# Exit silently if no memory system found
[ -z "$MEMORY_DIR" ] && exit 0

echo "COMPACTACION INMINENTE — Ejecuta /checkpoint-3t AHORA antes de que se pierda contexto de la conversacion."
echo ""
echo "Si no puedes ejecutar /checkpoint-3t completo, como minimo:"
echo "1. Registra los pendientes abiertos con /checkpoint-3t (Step 3b emite eventos al journal; no edites memory/_pendientes.md a mano)"
echo "2. Escribe los learnings nuevos a memory/learnings/"
echo "3. Actualiza memory/_session-index.md con esta sesion"
