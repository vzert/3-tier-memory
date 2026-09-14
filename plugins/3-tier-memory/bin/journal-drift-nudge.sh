#!/bin/bash

# Salida de python en UTF-8 SIEMPRE — ver la nota completa en session-start.sh/journal-compact.py.
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (lee e invoca a --check-drift, que resella SOLO si detecta algo — ver ahi)
# 3-tier-memory plugin: UserPromptSubmit hook — entrega REAL del aviso de deriva. v2.24.0.
#
# POR QUE EXISTE ESTO Y NO BASTABA CON journal-guard.sh/bash-journal-nudge.sh. Ambos avisan por
# PreToolUse/PostToolUse imprimiendo texto plano con exit 0 — y eso NO llega al agente. Medido con
# `claude -p` (2026-09-14, hallazgo de una revision adversarial): un hook PreToolUse o PostToolUse
# que solo imprime y sale 0 va al log de depuracion, no al contexto del modelo ni al de la
# persona. Se confirmo con un centinela en cada uno de los dos eventos: el modelo respondio "no
# lo vi" las dos veces, con la escritura real ya confirmada en disco (el hook SI corrio).
#
# `UserPromptSubmit` es distinto: SI entrega texto plano a stdout al agente (es el mismo canal que
# ya usan bin/recall.sh y bin/context-nudge.sh, medibles en cada turno de esta misma sesion). Asi
# que el aviso de deriva —`journal-compact.py --check-drift`, que ya existia desde 2.13.2 y ya
# usaba bin/session-start.sh para avisar en el arranque de la SIGUIENTE sesion— se corre TAMBIEN
# aqui, en cada prompt, para que llegue en la MISMA sesion donde paso la escritura a mano, no una
# sesion despues (que es cuando de verdad importa: el incidente de cloudflare-expert 2026-09-12
# tuvo un /checkpoint-3t corriendo en la misma sesion que la escritura a mano, y ese `--check-drift`
# resella la linea base sin que nadie viera el aviso antes).
#
# --check-drift es idempotente y se autolimita: resella la linea base en cuanto avisa, asi que
# esto no repite el mismo aviso en cada prompt de la sesion (una vez visto, --check-drift calla
# hasta la proxima escritura fuera del journal) ni pisa lo que ya hace SessionStart (que llama la
# misma funcion; si esta ya avisto y resello, SessionStart no vuelve a decir nada).
#
# La compuerta barata de mtime (no arrancar python si nada cambio desde el ultimo sellado) vive en
# drift-gate.sh, compartida con bin/bash-journal-nudge.sh — no hay logica propia aqui aparte de
# localizar memory/ y llamarla.

source "$(dirname "$0")/resolve-project-dir.sh"

if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ] || [ -d "$CLAUDE_PROJECT_DIR/memory/.journal" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  A="$HOME/.claude/projects/$ENCODED/memory"
  { [ -f "$A/_pendientes.md" ] || [ -d "$A/.journal" ]; } && MEMORY_DIR="$A"
fi
[ -z "${MEMORY_DIR:-}" ] && exit 0
[ -d "$MEMORY_DIR/.journal" ] || exit 0     # el proyecto no usa el journal: nada que decir

source "$(dirname "$0")/drift-gate.sh"
drift_gate_check "$MEMORY_DIR" "$(dirname "$0")"
exit 0
