#!/bin/bash
# Prueba de que journal-emit rechaza --nota en los tipos de evento que no la guardan (p-3bf672997c).
#
# Antes salia rc=0, escribia el evento y la nota se perdia sin avisar: quien la paso creia que
# quedo escrita. 2.62.4 lo arreglo solo en pendiente.update (su caso 14b en
# test-pendiente-update.sh); aqui van los demas tipos. Solo leen --nota pendiente.resolve,
# learning.retire y learning.add con --supersedes (o --decision reemplaza:N): esos son el control.
#
# Se compara contra None, no contra la cadena: `--nota ""` y `--nota "   "` tambien se rechazan,
# porque quien las paso esperaba guardar algo (lo que el adversario encontro en 2.62.4).
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
eventos() { ls "$M/.journal/pending" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
ID=p-0123456789

fixture() {
  rm -rf "$M"; mkdir -p "$M/pendientes" "$M/sessions" "$M/learnings"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '# demo\n' > "$M/sessions/2026-10-16-demo.md"
  printf -- '# uno\n\n## Reglas\n\n1. **Regla vieja** — texto viejo\n' > "$M/learnings/uno.md"
}

# rechaza <etiqueta> <args del evento sin --nota>: prueba la nota con texto, vacia y de espacios.
rechaza() {
  local et="$1"; shift
  local cual nota RC E
  # Sin este control el rechazo seria vacuo: el evento podria caer por otro flag mal puesto.
  fixture
  chk "$et sin --nota pasa" "0" "$(emit "$@" >/dev/null 2>&1; echo $?)"
  # Etiquetas en ASCII: mutation-check las busca con grep, y Git Bash no siempre corre en UTF-8.
  for cual in texto vacia espacios; do
    case "$cual" in texto) nota="verificado en el checkout" ;; vacia) nota="" ;; espacios) nota="   " ;; esac
    fixture
    RC=0; E=$(emit "$@" --nota "$nota" 2>&1 >/dev/null) || RC=$?
    chk "$et con nota $cual sale con error" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
    chk "$et con nota $cual no deja evento" "0" "$(eventos)"
  done
  chk "$et: el mensaje dice que no la guarda" "1" "$(printf '%s' "$E" | grep -c 'no guarda --nota\|solo guarda --nota')"
  chk "$et: el mensaje dice donde va" "1" "$(printf '%s' "$E" | grep -c 'metela en el --text')"
}

ADD=(--type pendiente.add --text "algo por hacer" --prioridad Baja --origen "[[sessions/2026-10-16-demo]]")

echo "== 1. pendiente.add, expire y reopen rechazan --nota =="
rechaza "pendiente.add" "${ADD[@]}"
rechaza "pendiente.expire" --type pendiente.expire --id "$ID" --dias 30
rechaza "pendiente.reopen" --type pendiente.reopen --id "$ID"

echo "== 2. una muestra de los demas tipos que no la leen =="
rechaza "pendiente.window" --type pendiente.window --id "$ID" --revisar 2026-11-01
rechaza "session.add" --type session.add --slug 2026-10-16-demo --date 2026-10-16 --summary "demo"
rechaza "plan.upsert" --type plan.upsert --slug demo --title "Demo" --status active
rechaza "learning.update" --type learning.update --topic uno --match-prefix "**Regla vieja**" --text "texto nuevo"
# learning.add lee --nota SOLO con --supersedes: sin el, se perdia igual que en los otros.
rechaza "learning.add sin --supersedes" --type learning.add --topic uno --text "**Regla nueva** — otra cosa" --decision nueva

echo "== 3. control: sin --nota pasan, y los lectores la siguen aceptando =="
fixture
chk "pendiente.add sin --nota pasa" "0" "$(emit "${ADD[@]}" >/dev/null 2>&1; echo $?)"
chk "y deja su evento" "1" "$(eventos)"
fixture
chk "pendiente.resolve con --nota pasa" "0" \
  "$(emit --type pendiente.resolve --id "$ID" --estado resolved --text-prefix "x" --nota "cerrado" >/dev/null 2>&1; echo $?)"
fixture
chk "learning.add --supersedes con --nota pasa" "0" \
  "$(emit --type learning.add --topic uno --text "**Regla nueva** — reemplaza" --supersedes 1 --nota "cambio" >/dev/null 2>&1; echo $?)"
fixture
chk "learning.retire con --nota pasa" "0" \
  "$(emit --type learning.retire --topic uno --match-prefix "**Regla vieja**" --motivo obsoleta --nota "ya no aplica" >/dev/null 2>&1; echo $?)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
