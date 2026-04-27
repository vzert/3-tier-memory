#!/bin/bash
# 3-tier-memory plugin: SessionStart hook
# Injects open pendientes AND learnings at session start

source "$(dirname "$0")/resolve-project-dir.sh"

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

# Detect if running in Paperclip agent
IS_PAPERCLIP_AGENT=false
[ -n "$PAPERCLIP_RUN_ID" ] && IS_PAPERCLIP_AGENT=true

if [ "$IS_PAPERCLIP_AGENT" = true ]; then
  # Paperclip agent: only inject learnings, no pendientes
  if [ -f "$MEMORY_DIR/_learnings.md" ]; then
    LEARNINGS_COUNT=$(sed -n '/## Quick Reference/,/## Related/p' "$MEMORY_DIR/_learnings.md" 2>/dev/null | grep -c '^\- ' || echo 0)
    if [ "$LEARNINGS_COUNT" -gt 0 ]; then
      echo "REGLAS CRITICAS: $LEARNINGS_COUNT. Revisa _learnings.md para ver el detalle."
      echo ""
    fi
  fi
else
  # CLI: inject pendientes + learnings (current behavior)
  PENDIENTES_COUNT=$(grep -cE '^\- \[ \]' "$MEMORY_DIR/_pendientes.md" 2>/dev/null || echo 0)

  if [ "$PENDIENTES_COUNT" -gt 0 ]; then
    echo "PENDIENTES ABIERTOS: $PENDIENTES_COUNT. Revisa _pendientes.md para ver el detalle."
    echo ""
  fi

  if [ -f "$MEMORY_DIR/_learnings.md" ]; then
    LEARNINGS_COUNT=$(sed -n '/## Quick Reference/,/## Related/p' "$MEMORY_DIR/_learnings.md" 2>/dev/null | grep -c '^\- ' || echo 0)
    if [ "$LEARNINGS_COUNT" -gt 0 ]; then
      echo "REGLAS CRITICAS: $LEARNINGS_COUNT. Revisa _learnings.md para ver el detalle."
      echo ""
    fi
  fi
fi

# Migrate old command names to -3t suffix (one-time, for existing installs)
CMDS_DIR="$CLAUDE_PROJECT_DIR/.claude/commands"
TEMPLATES_DIR="${CLAUDE_PLUGIN_ROOT}/templates"
MIGRATED=""

for old_cmd in checkpoint status audit backfill; do
  OLD_FILE="$CMDS_DIR/$old_cmd.md"
  NEW_FILE="$CMDS_DIR/${old_cmd}-3t.md"
  if [ -f "$OLD_FILE" ] && [ ! -f "$NEW_FILE" ]; then
    mv "$OLD_FILE" "$NEW_FILE"
    MIGRATED="$MIGRATED /$old_cmd→/${old_cmd}-3t"
  fi
done

if [ -n "$MIGRATED" ]; then
  echo "MIGRADO:$MIGRATED (renamed to avoid collisions with global skills)."
  echo ""
fi

# Auto-update local commands if plugin has newer versions (also installs missing ones)
UPDATED=""
INSTALLED=""

for cmd in checkpoint-3t status-3t audit-3t backfill-3t save-learning; do
  LOCAL_CMD="$CMDS_DIR/$cmd.md"
  PLUGIN_CMD="$TEMPLATES_DIR/$cmd.md"
  if [ -f "$PLUGIN_CMD" ]; then
    if [ ! -f "$LOCAL_CMD" ]; then
      mkdir -p "$CMDS_DIR"
      cp "$PLUGIN_CMD" "$LOCAL_CMD"
      INSTALLED="$INSTALLED /$cmd"
    elif ! diff -q "$LOCAL_CMD" "$PLUGIN_CMD" >/dev/null 2>&1; then
      cp "$PLUGIN_CMD" "$LOCAL_CMD"
      UPDATED="$UPDATED /$cmd"
    fi
  fi
done

if [ -n "$INSTALLED" ]; then
  echo "INSTALADO:$INSTALLED (nuevos comandos del plugin)."
  echo ""
fi

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
    echo "BACKFILL PENDIENTE: $REMAINING sesiones sin procesar. Run /backfill-3t to import past sessions."
    echo ""
  fi
fi

if [ "$IS_PAPERCLIP_AGENT" = true ]; then
  echo "PROTOCOLO: Usar /save-learning cuando descubras un patron o regla nueva."
else
  echo "PROTOCOLO: Dual-write siempre (indice + archivo detalle) para sessions, pendientes y learnings. Plans y research solo si aplica."
  echo "Usar /checkpoint-3t para guardar progreso."
fi
