#!/bin/bash
# Prueba de bin/journal-drift-nudge.sh (UserPromptSubmit) — la entrega REAL del aviso de deriva.
#
# Motivo (2026-09-14): un hook PreToolUse/PostToolUse que solo imprime texto plano con exit 0 no
# llega al agente (medido con `claude -p`, ver journal-guard.sh). UserPromptSubmit SI entrega —
# mismo canal que bin/recall.sh, que se ve en cada turno. Este hook corre `journal-compact.py
# --check-drift` (ya existia) en ese canal, en vez de solo en el arranque de la sesion (que solo
# se ve UNA vez y puede llegar despues de que un checkpoint ya resello la linea base).
#
# No prueba que Claude Code entregue additionalContext de verdad: eso ya se midio por separado
# con `claude -p` fuera de este arnes. Prueba que el SCRIPT decide bien: avisa cuando hay deriva,
# calla cuando no, no repite, y comparte la compuerta con bash-journal-nudge.sh sin duplicar logica.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proj"; mkdir -p "$P/memory/pendientes" "$P/memory/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$P/memory/_pendientes.md"

prompt() {   # simula un UserPromptSubmit -> AVISA|callado
  J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'UserPromptSubmit','cwd':sys.argv[1],'prompt':'hola'}))" "$P")
  O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/journal-drift-nudge.sh" 2>/dev/null)
  [ -n "$O" ] && echo AVISA || echo callado
}

echo "== sella la linea base antes de empezar =="
python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --check-drift >/dev/null 2>&1

echo "== sin cambios: callado en cada prompt =="
chk "primer prompt sin deriva" callado "$(prompt)"
chk "segundo prompt sin deriva" callado "$(prompt)"

echo "== escritura a mano entre dos prompts: avisa en el SIGUIENTE, no antes =="
printf -- '- [ ] a mano en medio de la sesion\n' >> "$P/memory/_pendientes.md"
chk "el prompt siguiente SI avisa"       AVISA   "$(prompt)"
chk "y no se repite en el prompt de despues" callado "$(prompt)"

echo "== --reseal (reparacion manual deliberada) tambien lo consume aqui =="
printf -- '- [ ] reparacion manual\n' >> "$P/memory/_pendientes.md"
R=$(python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --reseal 2>&1)
chk "reseal acepta el cambio" "1" "$(printf '%s' "$R" | grep -c 'aceptados como linea base')"
chk "y el prompt siguiente calla" callado "$(prompt)"

echo "== un proyecto sin .journal/ no ve nada (mismo criterio que bash-journal-nudge.sh) =="
Q="$T/sinjournal"; mkdir -p "$Q/memory"
printf -- '# Pendientes\n' > "$Q/memory/_pendientes.md"
J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'UserPromptSubmit','cwd':sys.argv[1],'prompt':'hola'}))" "$Q")
O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$Q" bash "$BIN/journal-drift-nudge.sh" 2>/dev/null)
chk "sin .journal/ -> callado" callado "$([ -n "$O" ] && echo AVISA || echo callado)"

echo "== sin sistema de memoria: no revienta =="
Z="$T/vacio"; mkdir -p "$Z"
J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'UserPromptSubmit','cwd':sys.argv[1],'prompt':'hola'}))" "$Z")
set +e
O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$Z" bash "$BIN/journal-drift-nudge.sh" 2>&1); RC=$?
set -e
chk "exit 0"            "0" "$RC"
chk "sin salida"         ""  "$O"

echo "== bash-journal-nudge.sh (PostToolUse) YA NO comparte esta ruta: 2.24.1 le quito la llamada =="
# Antes (2.13.4-2.24.0) los dos hooks compartian drift-gate.sh. Ganaba SIEMPRE el de PostToolUse
# porque corre en el mismo turno que la escritura, antes de que exista turno siguiente — y
# --check-drift resella al detectar, asi que el aviso real nunca llegaba a nadie. Se prueba lo
# contrario de lo que probaba esta seccion hasta 2.24.0: que ya NO lo sourcea.
chk "bash-journal-nudge.sh YA NO sourcea drift-gate.sh" "0" "$(grep -c 'source.*drift-gate.sh' "$BIN/bash-journal-nudge.sh")"
chk "journal-drift-nudge.sh sourcea drift-gate.sh" "1" "$(grep -c 'source.*drift-gate.sh' "$BIN/journal-drift-nudge.sh")"

echo "== ronda 8: el orden REAL de una sesion — escritura por Bash, su PostToolUse, y el prompt siguiente =="
# Esto es lo que ninguna de las dos suites anteriores ejercitaba: test-drift-nudge.sh nunca corria
# el PostToolUse de Bash, y test-bash-nudge.sh nunca corria journal-drift-nudge.sh despues. Cada
# una probaba su hook aislado. La carrera solo aparece con las DOS, en este orden, sobre el MISMO
# proyecto — que es exactamente como pasa en una sesion real.
W="$T/carrera"; mkdir -p "$W/memory/pendientes" "$W/memory/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$W/memory/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$W/memory" --check-drift >/dev/null 2>&1

# 1) Bash escribe un indice a mano.
printf -- '- [ ] a mano, en medio de la sesion\n' >> "$W/memory/_pendientes.md"

# 2) Su PostToolUse corre EN EL MISMO TURNO, antes de que exista un turno siguiente.
JPOST=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PostToolUse','tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':'echo x >> memory/_pendientes.md'}}))" "$W")
OPOST=$(printf '%s' "$JPOST" | CLAUDE_PROJECT_DIR="$W" bash "$BIN/bash-journal-nudge.sh" 2>/dev/null)
chk "el PostToolUse de Bash no dice nada (no entrega igual)" "" "$OPOST"

# 3) El prompt SIGUIENTE de la misma sesion dispara journal-drift-nudge.sh (UserPromptSubmit).
JPROMPT=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'UserPromptSubmit','cwd':sys.argv[1],'prompt':'hola'}))" "$W")
OPROMPT=$(printf '%s' "$JPROMPT" | CLAUDE_PROJECT_DIR="$W" bash "$BIN/journal-drift-nudge.sh" 2>/dev/null)
chk "el prompt siguiente SI avisa (el PostToolUse no se lo comio)" "1" "$([ -n "$OPROMPT" ] && echo 1 || echo 0)"

# Control: si se repitiera el prompt, ya no deberia avisar (se resello en el paso 3).
JPROMPT2=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'UserPromptSubmit','cwd':sys.argv[1],'prompt':'hola de nuevo'}))" "$W")
OPROMPT2=$(printf '%s' "$JPROMPT2" | CLAUDE_PROJECT_DIR="$W" bash "$BIN/journal-drift-nudge.sh" 2>/dev/null)
chk "y no se repite en el prompt de despues" "" "$OPROMPT2"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
