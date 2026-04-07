#!/bin/bash
# 3-tier-memory plugin: PostToolUse hook (Write|Edit)
# Detects files written to memory/ subdirectories that aren't registered in their index

source "$(dirname "$0")/resolve-project-dir.sh"
INPUT="$_HOOK_INPUT"
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Exit if no file path or not in a memory directory
[ -z "$FILE_PATH" ] && exit 0
[[ "$FILE_PATH" != *"/memory/"* ]] && exit 0

# Detect memory directory
if [ -f "$CLAUDE_PROJECT_DIR/memory/MEMORY.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's|/|-|g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  if [ -f "$AUTO_DIR/MEMORY.md" ]; then
    MEMORY_DIR="$AUTO_DIR"
  fi
fi

[ -z "$MEMORY_DIR" ] && exit 0

BASENAME=$(basename "$FILE_PATH" .md)
INDEX_FILE=""

if [[ "$FILE_PATH" == *"memory/plans/"* ]]; then
  INDEX_FILE="$MEMORY_DIR/_plans-index.md"
elif [[ "$FILE_PATH" == *"memory/research/"* ]]; then
  INDEX_FILE="$MEMORY_DIR/_research-index.md"
elif [[ "$FILE_PATH" == *"memory/sessions/"* ]]; then
  INDEX_FILE="$MEMORY_DIR/_session-index.md"
elif [[ "$FILE_PATH" == *"memory/learnings/"* ]]; then
  INDEX_FILE="$MEMORY_DIR/_learnings.md"
elif [[ "$FILE_PATH" == *"memory/pendientes/"* ]]; then
  INDEX_FILE="$MEMORY_DIR/_pendientes.md"
fi

if [ -n "$INDEX_FILE" ] && [ -n "$BASENAME" ]; then
  if ! grep -q "$BASENAME" "$INDEX_FILE" 2>/dev/null; then
    echo "Archivo '$BASENAME' creado en memory/ pero NO registrado en $(basename "$INDEX_FILE"). Registrarlo ahora."
  fi
fi

exit 0
