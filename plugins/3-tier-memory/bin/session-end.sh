#!/bin/bash
# 3-tier-memory plugin: SessionEnd hook
# Reminds to checkpoint if no checkpoint was saved this session

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

# Check if there's a session file for today
TODAY=$(date +%Y-%m-%d)
TODAY_SESSION=$(find "$MEMORY_DIR/sessions" -name "${TODAY}-*.md" 2>/dev/null | head -1)

if [ -z "$TODAY_SESSION" ]; then
  echo "SESION TERMINANDO SIN CHECKPOINT. Ejecuta /checkpoint-3t antes de cerrar para guardar pendientes, learnings y el log de esta sesion."
fi
