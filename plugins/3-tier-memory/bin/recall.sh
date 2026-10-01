#!/bin/bash

# Salida de python en UTF-8 SIEMPRE. En Windows, python codifica stdout con la pagina de codigos
# local cuando va a una tuberia (cp1252), no en UTF-8: el texto en espanol de este plugin salia con
# los guiones largos y los acentos rotos. Medido en CI el 2026-09-12 sobre la salida real del hook
# de arranque: `item con id — _creado:` llegaba como `item con id \xef\xbf\xbd _creado:`. Es texto
# que se inyecta en el prompt de cada sesion, asi que lo veia el modelo y lo veia el usuario.
# PYTHONUTF8 necesita 3.7+; PYTHONIOENCODING cubre lo anterior. Los dos son no-op fuera de Windows.
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (hook de solo lectura: inyecta contexto)
# 3-tier-memory plugin: UserPromptSubmit hook — relevance recall.
# Surfaces the memory units most relevant to the user's prompt, scored by
# lexical overlap (BM25-lite) × recency decay × importance. Silent when nothing
# is relevant (avoids polluting context with noise).

source "$(dirname "$0")/resolve-project-dir.sh"

# Detect memory dir (Model B first, then Model A fallback) — same logic as session-start
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  [ -f "$AUTO_DIR/_pendientes.md" ] && MEMORY_DIR="$AUTO_DIR"
fi
[ -z "$MEMORY_DIR" ] && exit 0

# Journal (v2.12.0): un evento que nadie compacto (el agente que lo emitio se cerro antes de
# su checkpoint) se aplica en el siguiente prompt de cualquier sesion. Fast path: un listado
# de directorio; solo se lanza python3 si pending/ tiene algo.
JOURNAL_PENDING="$MEMORY_DIR/.journal/pending"
if [ -f "$CLAUDE_PLUGIN_ROOT/bin/journal-compact.py" ] && [ -d "$JOURNAL_PENDING" ] \
   && [ -n "$(ls -A "$JOURNAL_PENDING" 2>/dev/null)" ]; then
  # No tirar stdout a /dev/null (p-c28bcb9c55): compact() puede detectar deriva fuera de banda
  # al aplicar pending/ y avisar (si hay_lector()) — igual que journal-drift-nudge.sh mas abajo
  # en la lista de UserPromptSubmit, este stdout llega al agente. Perderlo aqui era perder el
  # UNICO aviso posible, porque compact() ya resello los indices al terminar.
  JOURNAL_OUT=$(python3 "$CLAUDE_PLUGIN_ROOT/bin/journal-compact.py" --memory-dir "$MEMORY_DIR" --budget 1 --quiet 2>/dev/null)
  # `HUMAN-EVENT: <slug>` (p-bd9a53b794) es un rotulo interno para session-start.sh, que si lo
  # filtra de lo que ve el agente — nunca formo parte del texto que este hook mostraba antes.
  # Sin este filtro se cuela literal en additionalContext, ruido de protocolo que este hook no
  # tenia. Este script no tiene canal a persona (es UserPromptSubmit de solo agente): el rotulo
  # no tiene a donde escalar aqui, asi que se descarta sin mas.
  [ -n "$JOURNAL_OUT" ] && printf '%s\n\n' "$(printf '%s\n' "$JOURNAL_OUT" | grep -v '^HUMAN-EVENT: ')"
fi

# Derived recall index lives alongside other per-machine state (like
# .backfill-progress.json), NOT in memory/ — so it never gets committed.
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
STATE_DIR="$HOME/.claude/projects/$ENCODED"
mkdir -p "$STATE_DIR" 2>/dev/null
INDEX="$STATE_DIR/.recall-index.jsonl"
BUILDER="$CLAUDE_PLUGIN_ROOT/bin/build-recall-index.py"

# Rebuild if missing or stale (any memory file newer than the index)
NEEDS_BUILD=false
if [ ! -f "$INDEX" ]; then
  NEEDS_BUILD=true
elif [ -n "$(find "$MEMORY_DIR" -name '*.md' -not -path '*/archive/*' -not -name '*.bak*' -not -name '*.archived.md' -not -name 'archived-*.md' -newer "$INDEX" -print -quit 2>/dev/null)" ]; then
  NEEDS_BUILD=true
elif [ "$BUILDER" -nt "$INDEX" ] || [ "$(dirname "$BUILDER")/learning_marks.py" -nt "$INDEX" ]; then
  # Un constructor nuevo (2.45.0: salta las reglas retiradas y marca las numeradas) no sirve de
  # nada sobre un indice que construyo el viejo: sin cambios en memory/, nadie lo reconstruia.
  NEEDS_BUILD=true
fi
if [ "$NEEDS_BUILD" = true ] && [ -f "$BUILDER" ]; then
  python3 "$BUILDER" "$MEMORY_DIR" "$INDEX" >/dev/null 2>&1
fi
[ -f "$INDEX" ] || exit 0

PROMPT=$(echo "$_HOOK_INPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('prompt',''))" 2>/dev/null)
[ -z "$PROMPT" ] && exit 0

# El motor vive en recall_rank.py desde la Fase F0 (plan ciclo de vida de learnings): el banco
# tools/recall-bench/recall-bench.py lo importa, asi mide el mismo codigo que corre aqui.
# RECALL_PIE (2.45.0): cada regla servida lleva debajo su topic y su prefijo, y una linea final
# dice como retirarla o corregirla por el journal. El agente que descubre en su trabajo que una
# regla esta vencida tiene la orden delante, en vez de seguirla o editarla a mano.
RECALL_INDEX="$INDEX" RECALL_PROMPT="$PROMPT" RECALL_PIE="$(dirname "$0")/journal-emit.py" \
  RECALL_MEMORY_DIR="$MEMORY_DIR" python3 "$(dirname "$0")/recall_rank.py" 2>/dev/null

exit 0
