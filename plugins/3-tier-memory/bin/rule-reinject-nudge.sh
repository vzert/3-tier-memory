#!/bin/bash

# Salida de python en UTF-8 SIEMPRE. Ver bin/recall.sh para la medicion original (CI 2026-09-12).
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (hook de solo lectura: lee _learnings.md y su propio archivo de estado)
# 3-tier-memory plugin: UserPromptSubmit hook — entrega real de la reinyeccion periodica de
# reglas criticas (v2.26.0, plan [[plans/plan-rule-reinjection]]).
#
# Por que UserPromptSubmit y no el PostToolUse que cuenta (bin/rule-reinject-count.sh): un hook
# PreToolUse/PostToolUse que imprime texto plano y sale 0 NO llega al agente (medido con
# `claude -p`, ver bin/journal-guard.sh). UserPromptSubmit SI entrega -- mismo canal que ya usan
# bin/recall.sh, bin/context-nudge.sh y bin/journal-drift-nudge.sh.
#
# Fuente del contenido: la seccion "## Quick Reference" de _learnings.md, TAL CUAL (curada a
# mano hoy via /save-learning y /consolidate-3t) -- no un calculo dinamico por `importance`.
# Decision explicita de Victor (2026-09-17): evita una dependencia nueva contra el indice
# derivado de recall.
#
# Ventana ROTATIVA, no la lista completa: mostrar las 40+ reglas en cada disparo seria ruido.
# THREET_RULE_REINJECT_COUNT (default 6) lineas por entrega, el puntero avanza en cada entrega
# asi que una sesion larga termina cubriendo toda la lista en vez de repetir siempre las primeras.
#
# Estado por SESION (mismo archivo que ya incrementa bin/rule-reinject-count.sh): "count
# entregado". Este hook entrega cuando count/INTERVAL > entregado, muestra la ventana en el
# offset `entregado * COUNT mod total_lineas`, y avanza entregado en +1 -- NUNCA salta a
# count/INTERVAL de un salto. Encontrado por el adversario externo (codex, ronda 1,
# 2026-09-17): con INTERVAL=25 y un tramo de 50 tool calls sin prompts nuevos, DUE=2 en la
# primera entrega; saltar a entregado=DUE=2 directamente le hace mostrar la ventana en offset 0
# pero DEJA SIN MOSTRAR NUNCA la ventana en offset=1*COUNT -- la rotacion se salta ventanas
# permanentemente cada vez que se acumula mas de un cruce de intervalo entre dos prompts.
# Avanzando de a uno, un tramo largo simplemente reparte esas entregas pendientes en los
# siguientes prompts (una por turno) hasta ponerse al dia, sin saltarse ninguna ventana.
# Si esos dos hooks corrieran en el mismo instante habria una carrera de lectura entre ellos
# sobre el MISMO archivo -- aceptado por la misma razon que documenta rule-reinject-count.sh:
# nunca corrompe memory/, peor caso es una entrega un poco tarde o temprano.

source "$(dirname "$0")/resolve-project-dir.sh"

if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  [ -f "$AUTO_DIR/_pendientes.md" ] && MEMORY_DIR="$AUTO_DIR"
fi
[ -z "$MEMORY_DIR" ] && exit 0

INTERVAL="${THREET_RULE_REINJECT_INTERVAL:-25}"
case "$INTERVAL" in ''|*[!0-9]*) exit 0 ;; esac
[ "$INTERVAL" -le 0 ] && exit 0

WINDOW_COUNT="${THREET_RULE_REINJECT_COUNT:-6}"
case "$WINDOW_COUNT" in ''|*[!0-9]*) WINDOW_COUNT=6 ;; esac
[ "$WINDOW_COUNT" -le 0 ] && exit 0

SESSION_ID=$(printf '%s' "$_HOOK_INPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
STATE_DIR="$HOME/.claude/projects/$ENCODED"
mkdir -p "$STATE_DIR" 2>/dev/null
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '-')
STATEFILE="$STATE_DIR/.rule-reinject-$SAFE_ID"

read -r COUNT DELIVERED < "$STATEFILE" 2>/dev/null
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
case "$DELIVERED" in ''|*[!0-9]*) DELIVERED=0 ;; esac

DUE=$((COUNT / INTERVAL))
[ "$DUE" -le "$DELIVERED" ] && exit 0   # nada nuevo que entregar

LEARNINGS_FILE="$MEMORY_DIR/_learnings.md"
[ -f "$LEARNINGS_FILE" ] || exit 0

OUTPUT=$(LEARNINGS_FILE="$LEARNINGS_FILE" WINDOW_COUNT="$WINDOW_COUNT" OFFSET=$((DELIVERED * WINDOW_COUNT)) python3 <<'PYEOF' 2>/dev/null
import os, re

path = os.environ["LEARNINGS_FILE"]
window = int(os.environ["WINDOW_COUNT"])
offset = int(os.environ["OFFSET"])

try:
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
except OSError:
    raise SystemExit(0)

start = None
for i, l in enumerate(lines):
    if l.strip().lower().startswith("## quick reference"):
        start = i + 1
        break
if start is None:
    raise SystemExit(0)

rules = []
for l in lines[start:]:
    s = l.strip()
    if s.startswith("## "):
        break
    if re.match(r"^\d+\.\s", s):
        rules.append(s)

if not rules:
    raise SystemExit(0)

n = len(rules)
idx = offset % n
picked = [rules[(idx + i) % n] for i in range(min(window, n))]

print("RECORDATORIO PERIÓDICO (3-tier) — reglas críticas del proyecto, para no perderlas de vista "
      "en un tramo largo sin prompts nuevos:")
for r in picked:
    print(f"  - {r}")
PYEOF
)

# Solo actualiza el puntero (y solo imprime) si de verdad hubo algo que mostrar -- si
# _learnings.md no tiene Quick Reference o quedo vacia (memory recien creada, por ejemplo) no
# queremos "gastar" la entrega ni avanzar el offset de una rotacion que nunca se mostro.
if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$OUTPUT"
  printf '%s %s\n' "$COUNT" "$((DELIVERED + 1))" > "$STATEFILE" 2>/dev/null
fi

exit 0
