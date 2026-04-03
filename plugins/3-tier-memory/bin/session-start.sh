#!/bin/bash
# 3-tier-memory plugin: SessionStart hook
# Injects open pendientes AND learnings at session start

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

# Inject open pendientes
PENDIENTES=$(grep -E '^\- \[ \]' "$MEMORY_DIR/_pendientes.md" 2>/dev/null)

if [ -n "$PENDIENTES" ]; then
  echo "PENDIENTES ABIERTOS:"
  echo "$PENDIENTES"
  echo ""
fi

# Inject learnings quick reference
if [ -f "$MEMORY_DIR/_learnings.md" ]; then
  # Extract the Quick Reference section
  LEARNINGS=$(sed -n '/## Quick Reference/,/## Related/p' "$MEMORY_DIR/_learnings.md" 2>/dev/null | head -20 | grep -v '^## ')
  if [ -n "$LEARNINGS" ]; then
    echo "LEARNINGS — REGLAS CRITICAS:"
    echo "$LEARNINGS"
    echo ""
  fi
fi

echo "PROTOCOLO: Dual-write siempre (indice + archivo detalle) para sessions, pendientes y learnings. Plans y research solo si aplica."
echo "Usar /checkpoint para guardar progreso."
