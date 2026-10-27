#!/bin/bash
# Prueba de 2.63.47 (p-206fd62e68): los indices Tier 2 dejan de crecer sin limite.
#
#  1. pendiente.add --titulo: Tier 2 lleva solo el titulo, Tier 3 (mensual) lleva el detalle entero,
#     el id es el hash del titulo y repair-dualwrite no lo toma por inventado (regla 143).
#  2. El replay del mismo add no duplica ni cuarentena; pendiente.update conserva el detalle.
#  3. --titulo de mas de 200 caracteres o vacio se rechaza sin escribir evento.
#  4. Sin --titulo, un --text largo AVISA por stderr y se escribe igual (compat con /backfill-3t).
#  5. --quickref y research.upsert largos avisan y escriben igual.
#  6. print-pendientes-alcance.py: cuenta y solo imprime lo vencido y lo tocado, recortado.
#  7. print-tier2-tamano.py marca GRANDE.
#
# Uso: test-tier2-limites.sh (exit 0 = todo verde). Resumen final: "pass=N fail=M".
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

M="$T/m"; mkdir -p "$M/pendientes"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" --quiet >/dev/null 2>&1; }
linea() { grep -- "_id: $1_" "$M/_pendientes.md"; }
fila() { cat "$M"/pendientes/*.md 2>/dev/null | grep -- "_id: $1_"; }
ORI="[[sessions/2026-10-23-x]]"
DET=$(python3 -c 'print("detalle largo " + "palabra "*60 + "FIN")')

echo "== 1. add con --titulo =="
A=$(emit --type pendiente.add --titulo "Titulo corto del pendiente" --text "$DET" --prioridad Alta --origen "$ORI" 2>"$T/err")
chk "add con --titulo: sin aviso de largo" "0" "$(grep -c 'AVISO pendiente.add' "$T/err")"
compact
chk "Tier 2: el titulo esta" "1" "$(linea "$A" | grep -c 'Titulo corto del pendiente')"
chk "Tier 2: el detalle NO esta" "0" "$(linea "$A" | grep -c 'palabra palabra')"
chk "Tier 3: la fila lleva titulo y detalle entero" "1" "$(fila "$A" | grep -c 'Titulo corto del pendiente — detalle: detalle largo .*FIN _id:')"
R=$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1)
chk "repair-dualwrite: ids_invented=0" "1" "$(echo "$R" | grep -c 'ids_invented=0')"
chk "repair-dualwrite: rows_added=0" "1" "$(echo "$R" | grep -c 'rows_added=0')"

echo "== 2. replay y update =="
emit --type pendiente.add --titulo "Titulo corto del pendiente" --text "$DET" --prioridad Alta --origen "$ORI" --creado "$(date +%F)" >/dev/null 2>&1
compact
chk "replay: una sola linea en Tier 2" "1" "$(grep -c -- "_id: ${A}_" "$M/_pendientes.md")"
chk "replay: una sola fila en Tier 3" "1" "$(fila "$A" | wc -l | tr -d ' ')"
chk "replay: nada en cuarentena" "0" "$(ls "$M/.journal/quarantine" 2>/dev/null | grep -c json)"
emit --type pendiente.update --id "$A" --text "Titulo corregido" >/dev/null 2>&1; compact
chk "update: Tier 2 con el titulo nuevo" "1" "$(linea "$A" | grep -c 'Titulo corregido')"
chk "update: Tier 3 conserva el detalle" "1" "$(fila "$A" | grep -c 'Titulo corregido — detalle: detalle largo .*FIN _id:')"

echo "== 3. --titulo invalido =="
LARGO=$(python3 -c 'print("x"*201)')
N0=$(ls "$M/.journal/pending" 2>/dev/null | wc -l | tr -d ' ')
emit --type pendiente.add --titulo "$LARGO" --text "algo" --prioridad Alta --origen "$ORI" >/dev/null 2>"$T/err"; rc=$?
chk "titulo de 201 caracteres: rechazado" "1" "$rc"
emit --type pendiente.add --titulo "" --text "algo" --prioridad Alta --origen "$ORI" >/dev/null 2>&1; rc=$?
chk "titulo vacio: rechazado" "1" "$rc"
chk "ninguno escribio evento" "$N0" "$(ls "$M/.journal/pending" 2>/dev/null | wc -l | tr -d ' ')"

echo "== 4. --text largo sin --titulo avisa y escribe =="
B=$(emit --type pendiente.add --text "$DET" --prioridad Media --origen "$ORI" 2>"$T/err"); rc=$?
chk "sale 0" "0" "$rc"
chk "avisa por stderr y nombra --titulo" "1" "$(grep -c 'AVISO pendiente.add --text.*--titulo' "$T/err")"
compact
chk "Tier 2 lleva el texto entero (compat)" "1" "$(linea "$B" | grep -c 'FIN')"
C=$(emit --type pendiente.add --text "texto corto" --prioridad Media --origen "$ORI" 2>"$T/err")
chk "texto corto: sin aviso de largo" "0" "$(grep -c 'AVISO pendiente.add' "$T/err")"

echo "== 5. quickref y research =="
emit --type learning.add --topic t1 --text "**Regla** — x" --quickref "$(python3 -c 'print("q"*301)')" >/dev/null 2>"$T/err"; rc=$?
chk "quickref de 301: sale 0" "0" "$rc"
chk "quickref de 301: avisa" "1" "$(grep -c 'AVISO learning.add --quickref' "$T/err")"
emit --type learning.add --topic t1 --text "**Regla** — y" --quickref "corto" >/dev/null 2>"$T/err"
chk "quickref corto: sin aviso" "0" "$(grep -c 'AVISO learning.add --quickref' "$T/err")"
emit --type research.upsert --slug r1 --status active --tema "$(python3 -c 'print("t"*201)')" --inline >/dev/null 2>"$T/err"; rc=$?
chk "research tema de 201: sale 0" "0" "$rc"
chk "research tema de 201: avisa" "1" "$(grep -c 'AVISO research.upsert --tema' "$T/err")"
emit --type research.upsert --slug r2 --status active --tema "corto" --next-step "$(python3 -c 'print("n"*301)')" --inline >/dev/null 2>"$T/err"
chk "research next-step de 301: avisa" "1" "$(grep -c 'AVISO research.upsert --next-step' "$T/err")"

echo "== 6. print-pendientes-alcance =="
M2="$T/m2"; mkdir -p "$M2"
cat > "$M2/_pendientes.md" <<EOT
# Pendientes

## Alta prioridad

- [ ] vencido uno — _origen: [[sessions/a]]_ — _creado: 2026-10-01_ — _id: p-aaaaaaaaaa_ — _revisar: 2026-10-05_
- [ ] futuro — _origen: [[sessions/a]]_ — _creado: 2026-10-01_ — _id: p-bbbbbbbbbb_ — _revisar: 2099-01-01_
- [ ] $(python3 -c 'print("z"*500)') — _origen: [[sessions/a]]_ — _creado: 2026-10-01_ — _id: p-cccccccccc_

## Media prioridad

- [ ] sin ventana — _origen: [[sessions/a]]_ — _creado: 2026-10-01_ — _id: p-dddddddddd_
- [x] cerrado — _origen: [[sessions/a]]_ — _creado: 2026-10-01_ — _id: p-eeeeeeeeee_
EOT
S=$(python3 "$BIN/print-pendientes-alcance.py" "$M2" --hoy 2026-10-23 --ids p-cccccccccc,p-eeeeeeeeee)
chk "cuenta abiertos/vencidos/tocados" "ABIERTOS=4 VENCIDOS=1 TOCADOS=2" "$(echo "$S" | head -1)"
chk "imprime el vencido" "1" "$(echo "$S" | grep -c '^p-aaaaaaaaaa | Alta .* | vencido | vencido uno')"
chk "no imprime el futuro ni el sin ventana" "0" "$(echo "$S" | grep -c 'p-bbbbbbbbbb\|p-dddddddddd')"
chk "el tocado largo sale recortado" "1" "$(echo "$S" | grep -c '^p-cccccccccc .* | tocado | z\{200\}…\[+300\]$')"
chk "un id cerrado sale no-abierto" "1" "$(echo "$S" | grep -c '^p-eeeeeeeeee | no-abierto$')"
python3 "$BIN/print-pendientes-alcance.py" "$M2" --hoy 2026-13-45 >/dev/null 2>&1; rc=$?
chk "fecha irreal: error de uso" "2" "$rc"
python3 "$BIN/print-pendientes-alcance.py" "$T/no-existe" >/dev/null 2>&1; rc=$?
chk "sin _pendientes.md: sale 1" "1" "$rc"

M3="$T/m3"; mkdir -p "$M3"
cat > "$M3/_pendientes.md" <<EOT
# Pendientes

## Alta prioridad

- [ ] revisar justo hoy — _origen: [[sessions/a]]_ — _creado: 2026-10-01_ — _id: p-ffffffffff_ — _revisar: 2026-10-23_
EOT
S=$(python3 "$BIN/print-pendientes-alcance.py" "$M3" --hoy 2026-10-23)
chk "_revisar == hoy: sale con motivo hoy, no vencido" "1" "$(echo "$S" | grep -c '^p-ffffffffff | Alta .* | hoy | revisar justo hoy')"

echo "== 7. print-tier2-tamano =="
Z=$(python3 "$BIN/print-tier2-tamano.py" "$M2" --largas 400)
chk "linea larga: GRANDE" "1" "$(echo "$Z" | grep -c '^_pendientes.md bytes=[0-9]* lineas=[0-9]* largas=1 GRANDE$')"
Z=$(python3 "$BIN/print-tier2-tamano.py" "$M2" --largas 600)
chk "con tope mayor: sin GRANDE" "0" "$(echo "$Z" | grep -c GRANDE)"
Z=$(python3 "$BIN/print-tier2-tamano.py" "$M3" --grande 10)
chk "fichero sin lineas largas pasa --grande: GRANDE" "1" "$(echo "$Z" | grep -c '^_pendientes.md bytes=[0-9]* lineas=[0-9]* largas=0 GRANDE$')"
Z=$(python3 "$BIN/print-tier2-tamano.py" "$M3")
chk "fichero chico sin lineas largas: sin GRANDE" "0" "$(echo "$Z" | grep -c GRANDE)"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
