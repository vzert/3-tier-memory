#!/bin/bash

# Salida de python en UTF-8 SIEMPRE. Ver bin/recall.sh para la medicion original (CI 2026-09-12).
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (hook de solo lectura: inyecta contexto)
# 3-tier-memory plugin: UserPromptSubmit hook — avisa si el snippet de retomar pegado ya quedo
# viejo (paso cerrado, o una ficha mas nueva ya lo retoma). La logica y el porque estan en
# bin/snippet-vigente.py (2.63.22).

source "$(dirname "$0")/resolve-project-dir.sh"

# Fast path: casi todos los prompts no son un snippet; sin esto se lanzaria python en cada uno.
case "$_HOOK_INPUT" in
  *Retomamos:*|*'oximo paso:'*|*'"prompt":"p-'*|*'"prompt": "p-'*) ;;
  *) exit 0 ;;
esac

if [ -f "$MEMORY_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$MEMORY_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  [ -f "$AUTO_DIR/_pendientes.md" ] && MEMORY_DIR="$AUTO_DIR"
fi
[ -z "$MEMORY_DIR" ] && exit 0

printf '%s' "$_HOOK_INPUT" | python3 -I "$(dirname "$0")/snippet-vigente.py" --memory-dir "$MEMORY_DIR" 2>/dev/null
exit 0
