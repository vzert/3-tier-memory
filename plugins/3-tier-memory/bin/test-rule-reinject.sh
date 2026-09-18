#!/bin/bash
# Prueba de bin/rule-reinject-count.sh (PostToolUse) + bin/rule-reinject-nudge.sh
# (UserPromptSubmit) -- ver memory/plans/plan-rule-reinjection.md.
#
# rule-reinject-count.sh por si solo NO se prueba por su stdout (no imprime nada util a
# proposito: un PostToolUse que imprime texto plano no llega al agente, medido en este mismo
# repo -- ver journal-guard.sh). Se prueba por su EFECTO en el archivo de estado, y la entrega
# real la prueba rule-reinject-nudge.sh, exactamente como test-drift-nudge.sh prueba el par
# bash-journal-nudge.sh / journal-drift-nudge.sh.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proj"; mkdir -p "$P/memory"
printf -- '---\ntype: index\n---\n# Pendientes\n' > "$P/memory/_pendientes.md"
cat > "$P/memory/_learnings.md" <<'EOF'
---
type: index
---
# Learnings Index

## Quick Reference — Most Critical Rules

1. **Regla uno** — detalle uno
2. **Regla dos** — detalle dos
3. **Regla tres** — detalle tres
4. **Regla cuatro** — detalle cuatro
5. **Regla cinco** — detalle cinco
6. **Regla seis** — detalle seis
7. **Regla siete** — detalle siete
8. **Regla ocho** — detalle ocho

## Related
- [[_pendientes]]
EOF

STATE_DIR_FOR() { ENC=$(echo "$1" | sed 's/[^A-Za-z0-9]/-/g'); echo "$HOME/.claude/projects/$ENC"; }
STATE_DIR="$(STATE_DIR_FOR "$P")"
rm -f "$STATE_DIR"/.rule-reinject-* 2>/dev/null || true

count_call() {   # simula un PostToolUse (cualquier tool) para la sesion $1
  J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PostToolUse','tool_name':'Read','cwd':sys.argv[1],'session_id':sys.argv[2]}))" "$P" "$1")
  printf '%s' "$J" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/rule-reinject-count.sh" >/dev/null 2>&1
}

prompt() {   # simula un UserPromptSubmit para la sesion $1 -> imprime lo que entregue (o nada)
  J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'UserPromptSubmit','cwd':sys.argv[1],'session_id':sys.argv[2],'prompt':'hola'}))" "$P" "$1")
  printf '%s' "$J" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/rule-reinject-nudge.sh" 2>/dev/null
}

echo "== por debajo del intervalo: nada que entregar =="
THREET_RULE_REINJECT_INTERVAL=5 THREET_RULE_REINJECT_COUNT=3
export THREET_RULE_REINJECT_INTERVAL=5 THREET_RULE_REINJECT_COUNT=3
for i in 1 2 3 4; do count_call sesA; done
O=$(prompt sesA)
chk "4 tool calls, intervalo 5: callado" "" "$O"

echo "== cruza el intervalo: entrega en el siguiente prompt =="
count_call sesA   # 5a llamada -> cruza el multiplo de 5
O=$(prompt sesA)
chk "5a tool call, intervalo 5: SI entrega" "1" "$([ -n "$O" ] && echo 1 || echo 0)"
chk "muestra las primeras COUNT=3 reglas" "1" "$(printf '%s' "$O" | grep -c 'Regla uno')"
chk "y no mas de 3 lineas de regla" "3" "$(printf '%s' "$O" | grep -c '^  - [0-9]')"

echo "== no se repite hasta el siguiente multiplo =="
O=$(prompt sesA)
chk "prompt inmediato siguiente, sin tool calls nuevas: callado" "" "$O"

echo "== la ventana rota, no repite las mismas 3 =="
for i in 1 2 3 4 5; do count_call sesA; done   # ahora count=10 -> cruza el 2o multiplo de 5
O=$(prompt sesA)
chk "segunda entrega SI aparece" "1" "$([ -n "$O" ] && echo 1 || echo 0)"
chk "rota a las siguientes 3 (empieza en Regla cuatro)" "1" "$(printf '%s' "$O" | grep -c 'Regla cuatro')"
chk "ya no repite Regla uno en la segunda entrega" "0" "$(printf '%s' "$O" | grep -c 'Regla uno')"

echo "== un tramo largo sin prompts (2 intervalos de golpe) no se salta una ventana =="
# Hallazgo del adversario externo (codex, ronda 1, 2026-09-17): saltar el puntero directo a
# count/INTERVAL en vez de avanzar de a uno se comia la ventana intermedia para siempre.
rm -f "$STATE_DIR"/.rule-reinject-* 2>/dev/null || true
for i in $(seq 1 15); do count_call sesLong; done   # 15 tool calls de golpe, sin ningun prompt en medio -> DUE=3
O1=$(prompt sesLong)
chk "primer prompt tras 15 tool calls (DUE=3, DELIVERED=0): SI entrega" "1" "$([ -n "$O1" ] && echo 1 || echo 0)"
chk "primera entrega: offset 0 (Regla uno)" "1" "$(printf '%s' "$O1" | grep -c 'Regla uno')"
O2=$(prompt sesLong)
chk "segundo prompt SIN tool calls nuevas: avanza un paso mas (no salta), SI entrega" "1" "$([ -n "$O2" ] && echo 1 || echo 0)"
chk "segunda entrega: offset 1*COUNT, ES Regla cuatro (no se salto)" "1" "$(printf '%s' "$O2" | grep -c 'Regla cuatro')"
O3=$(prompt sesLong)
chk "tercer prompt: ya puesto al dia (DUE=3, DELIVERED llega a 3), tercer offset = Regla siete" "1" "$(printf '%s' "$O3" | grep -c 'Regla siete')"
O4=$(prompt sesLong)
chk "cuarto prompt: ya no quedan entregas pendientes, callado" "" "$O4"

echo "== dos sesiones intercaladas no comparten contador =="
rm -f "$STATE_DIR"/.rule-reinject-* 2>/dev/null || true
count_call sesX; count_call sesY; count_call sesX; count_call sesY; count_call sesX
# sesX lleva 3, sesY lleva 2 -- ninguna cruzo el 5 todavia
OX=$(prompt sesX); OY=$(prompt sesY)
chk "sesX (3 tool calls) callada" "" "$OX"
chk "sesY (2 tool calls) callada" "" "$OY"
count_call sesX; count_call sesX   # sesX llega a 5
OX2=$(prompt sesX); OY2=$(prompt sesY)
chk "sesX (5 tool calls) SI entrega" "1" "$([ -n "$OX2" ] && echo 1 || echo 0)"
chk "sesY (todavia en 2) sigue callada" "" "$OY2"

echo "== intervalo 0 = desactivado =="
rm -f "$STATE_DIR"/.rule-reinject-* 2>/dev/null || true
export THREET_RULE_REINJECT_INTERVAL=0
for i in 1 2 3 4 5 6; do count_call sesZ; done
O=$(prompt sesZ)
chk "intervalo 0: nunca entrega" "" "$O"
export THREET_RULE_REINJECT_INTERVAL=5

echo "== sin _learnings.md: no revienta, no avisa =="
Q="$T/sinlearnings"; mkdir -p "$Q/memory"
printf -- '# Pendientes\n' > "$Q/memory/_pendientes.md"
QSTATE="$(STATE_DIR_FOR "$Q")"; rm -f "$QSTATE"/.rule-reinject-* 2>/dev/null || true
for i in 1 2 3 4 5; do
  J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PostToolUse','tool_name':'Read','cwd':sys.argv[1],'session_id':'sesQ'}))" "$Q")
  printf '%s' "$J" | CLAUDE_PROJECT_DIR="$Q" bash "$BIN/rule-reinject-count.sh" >/dev/null 2>&1
done
set +e
JP=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'UserPromptSubmit','cwd':sys.argv[1],'session_id':'sesQ','prompt':'hola'}))" "$Q")
OP=$(printf '%s' "$JP" | CLAUDE_PROJECT_DIR="$Q" bash "$BIN/rule-reinject-nudge.sh" 2>&1); RC=$?
set -e
chk "sin _learnings.md: exit 0" "0" "$RC"
chk "sin _learnings.md: sin salida" "" "$OP"

echo "== sin sistema de memoria: no revienta =="
Z="$T/vacio"; mkdir -p "$Z"
set +e
JZ=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PostToolUse','tool_name':'Read','cwd':sys.argv[1],'session_id':'sesZZ'}))" "$Z")
printf '%s' "$JZ" | CLAUDE_PROJECT_DIR="$Z" bash "$BIN/rule-reinject-count.sh" >/dev/null 2>&1; RC1=$?
JPZ=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'UserPromptSubmit','cwd':sys.argv[1],'session_id':'sesZZ','prompt':'hola'}))" "$Z")
printf '%s' "$JPZ" | CLAUDE_PROJECT_DIR="$Z" bash "$BIN/rule-reinject-nudge.sh" >/dev/null 2>&1; RC2=$?
set -e
chk "count sin memoria: exit 0" "0" "$RC1"
chk "nudge sin memoria: exit 0" "0" "$RC2"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
