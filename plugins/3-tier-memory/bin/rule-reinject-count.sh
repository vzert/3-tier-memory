#!/bin/bash

# Salida de python en UTF-8 SIEMPRE. Ver bin/recall.sh para la medicion original (CI 2026-09-12).
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (hook de conteo: solo escribe su propio archivo de estado, fuera de memory/)
# 3-tier-memory plugin: PostToolUse hook (matcher "", todas las tools) — contador de tool calls
# para la reinyeccion periodica de reglas criticas (v2.26.0, plan [[plans/plan-rule-reinjection]]).
#
# SOLO CUENTA. NO IMPRIME NADA UTIL A PROPOSITO: un PostToolUse que imprime texto plano y sale 0
# no llega al agente (medido con `claude -p`, ver bin/journal-guard.sh y
# bin/bash-journal-nudge.sh — el mismo hallazgo que obligo a bash-journal-nudge.sh a separar
# "detectar" de "entregar"). La entrega real la hace bin/rule-reinject-nudge.sh en el siguiente
# UserPromptSubmit, el mismo canal que ya usa bin/recall.sh.
#
# Estado por SESION, no por proyecto: dos sesiones concurrentes en el mismo proyecto no deben
# compartir contador (la misma razon de fondo que motivo el journal de eventos). El archivo vive
# en el STATE_DIR per-maquina que ya usa context-nudge.sh, fuera de memory/, nunca se commitea.
#
# Limite aceptado: tool calls PARALELOS dentro de un mismo turno pueden pisarse este incremento
# (dos procesos, mismo archivo, sin lock). Peor caso: el aviso llega un poco tarde o temprano.
# Nunca corrompe memory/ (este archivo no vive ahi). No se agrega locking por proporcionalidad.

source "$(dirname "$0")/resolve-project-dir.sh"

# Solo cuenta si hay un sistema de memoria de verdad (mismo criterio que los demas hooks).
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
if [ ! -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ] \
   && [ ! -f "$HOME/.claude/projects/$ENCODED/memory/_pendientes.md" ]; then
  exit 0
fi

INTERVAL="${THREET_RULE_REINJECT_INTERVAL:-25}"
case "$INTERVAL" in
  ''|*[!0-9]*) exit 0 ;;   # no numerico -> no cuenta (fail-safe, nunca truena)
esac
[ "$INTERVAL" -le 0 ] && exit 0   # 0 = desactivado

SESSION_ID=$(printf '%s' "$_HOOK_INPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

STATE_DIR="$HOME/.claude/projects/$ENCODED"
mkdir -p "$STATE_DIR" 2>/dev/null
SAFE_ID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '-')
STATEFILE="$STATE_DIR/.rule-reinject-$SAFE_ID"

read -r COUNT DELIVERED < "$STATEFILE" 2>/dev/null
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
case "$DELIVERED" in ''|*[!0-9]*) DELIVERED=0 ;; esac

COUNT=$((COUNT + 1))
printf '%s %s\n' "$COUNT" "$DELIVERED" > "$STATEFILE" 2>/dev/null

exit 0
