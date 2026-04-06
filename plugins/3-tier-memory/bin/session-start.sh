#!/bin/bash
# 3-tier-memory plugin: SessionStart hook
# Injects open pendientes AND learnings at session start

# Auto-enable marketplace auto-update (idempotent, runs silently)
KM_FILE="$HOME/.claude/plugins/known_marketplaces.json"
if [ -f "$KM_FILE" ]; then
  HAS_MARKETPLACE=$(python3 -c "
import json
try:
    d = json.load(open('$KM_FILE'))
    m = d.get('3-tier-memory-marketplace')
    if m and not m.get('autoUpdate'):
        print('fix')
    else:
        print('ok')
except: print('ok')
" 2>/dev/null)

  if [ "$HAS_MARKETPLACE" = "fix" ]; then
    python3 -c "
import json
f = '$KM_FILE'
d = json.load(open(f))
d['3-tier-memory-marketplace']['autoUpdate'] = True
json.dump(d, open(f, 'w'), indent=2)
" 2>/dev/null && echo "AUTO-UPDATE: enabled for 3-tier-memory marketplace."
  fi
fi

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

# Auto-update local commands if plugin has newer versions
CMDS_DIR="$CLAUDE_PROJECT_DIR/.claude/commands"
TEMPLATES_DIR="${CLAUDE_PLUGIN_ROOT}/templates"
UPDATED=""

for cmd in checkpoint status audit backfill; do
  LOCAL_CMD="$CMDS_DIR/$cmd.md"
  PLUGIN_CMD="$TEMPLATES_DIR/$cmd.md"
  if [ -f "$LOCAL_CMD" ] && [ -f "$PLUGIN_CMD" ]; then
    if ! diff -q "$LOCAL_CMD" "$PLUGIN_CMD" >/dev/null 2>&1; then
      cp "$PLUGIN_CMD" "$LOCAL_CMD"
      UPDATED="$UPDATED /$cmd"
    fi
  fi
done

if [ -n "$UPDATED" ]; then
  echo "ACTUALIZADO:$UPDATED se actualizaron a la version mas reciente del plugin."
  echo ""
fi

# Notify if JSONL backfill is pending
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g')
JSONL_DIR="$HOME/.claude/projects/$ENCODED"
if [ -d "$JSONL_DIR" ]; then
  JSONL_COUNT=$(ls "$JSONL_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  PROCESSED=0
  PROGRESS_FILE="$JSONL_DIR/.backfill-progress.json"
  if [ -f "$PROGRESS_FILE" ]; then
    PROCESSED=$(python3 -c "import json; print(len(json.load(open('$PROGRESS_FILE')).get('processed',[])))" 2>/dev/null || echo 0)
  fi
  REMAINING=$((JSONL_COUNT - PROCESSED - 1))  # -1 for current session
  if [ "$REMAINING" -gt 0 ]; then
    echo "BACKFILL PENDIENTE: $REMAINING sesiones sin procesar. Run /backfill to import past sessions."
    echo ""
  fi
fi

echo "PROTOCOLO: Dual-write siempre (indice + archivo detalle) para sessions, pendientes y learnings. Plans y research solo si aplica."
echo "Usar /checkpoint para guardar progreso."
