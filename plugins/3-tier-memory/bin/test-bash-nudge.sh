#!/bin/bash
# Prueba del aviso de Bash (bash-journal-nudge.sh). No prueba que Claude Code honre el hook: eso
# es del harness. Prueba que el script decide bien y que NO depende de .memory-config.
#
# OJO con el arnes: `echo "$JSON"` en zsh interpreta los `\n` del JSON y lo corrompe antes de que
# llegue al script, y entonces TODOS los casos salen "callado" — que parece un pase limpio. Usar
# `printf '%s'`. (Me mordio al escribir esto, 2026-09-11.)
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proj"; mkdir -p "$P/memory/pendientes" "$P/memory/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$P/memory/_pendientes.md"

pre() {   # $1 = comando -> imprime AVISA|callado
  J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PreToolUse','tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':sys.argv[2]}}))" "$P" "$1")
  O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/bash-journal-nudge.sh" 2>/dev/null)
  [ -n "$O" ] && echo AVISA || echo callado
}

echo "== PreToolUse: formas de escritura que se han visto de verdad en el historial =="
chk "redireccion >>"          AVISA "$(pre 'echo x >> memory/_pendientes.md')"
chk "redireccion >"           AVISA "$(pre 'printf x > memory/_session-index.md')"
chk "sed -i"                  AVISA "$(pre 'sed -i "" s/a/b/ memory/_learnings.md')"
chk "tee"                     AVISA "$(pre 'tee -a memory/pendientes/2026-09.md < /tmp/x')"
chk "cp"                      AVISA "$(pre 'cp /tmp/x memory/_plans-index.md')"
chk "heredoc python open(w)"  AVISA "$(pre 'python3 - <<PY
open("memory/pendientes/2026-09.md","w")
PY')"

echo "== y lo que NO debe disparar (un aviso que grita en falso deja de leerse) =="
chk "lectura con cat"                  callado "$(pre 'cat memory/_pendientes.md')"
chk "grep"                             callado "$(pre 'grep -c foo memory/_learnings.md')"
chk "redireccion de stderr (2>)"       callado "$(pre 'wc -l memory/_pendientes.md 2> /tmp/err')"
chk "escritura fuera de memory/"       callado "$(pre 'echo hola > /tmp/otro.md')"
chk "comando sin relacion"             callado "$(pre 'git status')"
for h in journal-compact repair-dualwrite normalize-pendientes enrich-memory; do
  chk "herramienta del plugin: $h"     callado "$(pre "python3 bin/$h.py memory --apply")"
done

echo "== no depende de .memory-config: es el punto entero =="
# 64 de 65 proyectos no tienen config. Si el aviso dependiera de journal_strict estaria inerte
# justo donde mas falta hace.
chk "sin .memory-config -> AVISA igual" AVISA "$(pre 'echo x >> memory/_pendientes.md')"
printf 'journal_strict=0\n' > "$P/memory/.memory-config"
chk "con journal_strict=0 -> AVISA igual" AVISA "$(pre 'echo x >> memory/_pendientes.md')"
rm -f "$P/memory/.memory-config"

echo "== un proyecto sin journal no ve nada =="
Q="$T/sinjournal"; mkdir -p "$Q/memory"
printf -- '# Pendientes\n' > "$Q/memory/_pendientes.md"
J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PreToolUse','tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':'echo x >> memory/_pendientes.md'}}))" "$Q")
O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$Q" bash "$BIN/bash-journal-nudge.sh" 2>/dev/null)
chk "sin .journal/ -> callado" callado "$([ -n "$O" ] && echo AVISA || echo callado)"

echo "== PostToolUse: exacto, por bytes, no por texto del comando =="
python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --check-drift >/dev/null 2>&1
post() {
  J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PostToolUse','tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':'x'}}))" "$P")
  O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/bash-journal-nudge.sh" 2>/dev/null)
  [ -n "$O" ] && echo AVISA || echo callado
}
chk "sin cambios -> callado"                callado "$(post)"
printf -- '- [ ] a mano\n' >> "$P/memory/_pendientes.md"
chk "tras escritura a mano -> AVISA"        AVISA   "$(post)"
chk "y no se repite (se re-sello)"          callado "$(post)"

echo "== --reseal: el camino sancionado para una reparacion manual =="
printf -- '- [ ] reparacion manual deliberada\n' >> "$P/memory/_pendientes.md"
R=$(python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --reseal 2>&1)
chk "reseal acepta el cambio"  "1" "$(printf '%s' "$R" | grep -c 'aceptados como linea base')"
chk "y despues no hay deriva"  callado "$(post)"

echo "RESULT pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
