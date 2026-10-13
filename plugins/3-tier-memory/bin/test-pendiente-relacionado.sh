#!/bin/bash
# Prueba de 2.55.0: pendientes relacionados y el siguiente plan hermano.
#
#  A. `--relacionado` (pendiente.add) y `pendiente.relate` escriben `_relacionado:` en la linea de
#     Tier 2, sobreviven a un `pendiente.update`, no cambian el id y se cuarentenan si vienen mal.
#  B. print-como-retomar.py mete en el snippet una linea con hasta 2 afines Alta/Media ligados al
#     `Proximo paso:` en cualquier direccion, de cualquier sesion, sin bloqueados, sin `_revisar`
#     futuro ni de hoy, Alta antes que Media y el mas viejo primero.
#  C. plan-siguiente-hermano.py elige el hermano abierto por el orden de `## Sub-planes`.
#
# Por que existe: hasta 2.54 el snippet llevaba un solo item y un Media dejado junto a un Alta no
# volvia a ningun snippet salvo que venciera (medido sobre las 8 ultimas fichas de dos proyectos).
#
# Uso: test-pendiente-relacionado.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
linea() { grep -m1 "_id: $1_" "$M/_pendientes.md" || true; }
cuarentena() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }

fixture() {
  rm -rf "$M"; mkdir -p "$M/pendientes" "$M/sessions" "$M/plans"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '# vieja\n' > "$M/sessions/2026-09-01-vieja.md"
  printf -- '# hoy\n' > "$M/sessions/2026-10-13-hoy.md"
}

echo "== A1. --relacionado llega a la linea de Tier 2 y no cambia el id =="
fixture
SIN=$(emit --type pendiente.add --text "media vieja" --prioridad Media --origen "[[sessions/2026-09-01-vieja]]" --creado 2026-09-01)
fixture
CON=$(emit --type pendiente.add --text "media vieja" --prioridad Media --origen "[[sessions/2026-09-01-vieja]]" --creado 2026-09-01 --relacionado plan-foo)
compact --quiet >/dev/null
chk "el id no depende de --relacionado" "$SIN" "$CON"
chk "la linea lleva _relacionado: plan-foo_" "1" "$(linea "$CON" | grep -c ' — _relacionado: plan-foo_$')"
chk "la fila mensual existe (sin el campo, como _bloqueado)" "1" "$(grep -c "_id: ${CON}_" "$M"/pendientes/2026-09.md)"
chk "repair-dualwrite no lo ve como id inventado" "1" "$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1 | grep -c 'ids_invented=0')"

echo "== A2. pendiente.relate reemplaza y quita; pendiente.update lo conserva =="
OTRO=$(emit --type pendiente.add --text "alta nueva" --prioridad Alta --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-10-13)
compact --quiet >/dev/null
emit --type pendiente.relate --id "$CON" --relacionado "$OTRO" --relacionado plan-foo >/dev/null
compact --quiet >/dev/null
chk "relate reemplaza la lista" "1" "$(linea "$CON" | grep -c "_relacionado: ${OTRO}, plan-foo_$")"
emit --type pendiente.update --id "$CON" --text "media vieja corregida" >/dev/null
compact --quiet >/dev/null
chk "update conserva _relacionado:" "1" "$(linea "$CON" | grep -c "_relacionado: ${OTRO}, plan-foo_")"
chk "update cambia el texto" "1" "$(linea "$CON" | grep -c 'media vieja corregida')"
chk "repair-dualwrite tras update: ids_invented=0" "1" "$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1 | grep -c 'ids_invented=0')"
emit --type pendiente.relate --id "$CON" --sin-relacion >/dev/null
compact --quiet >/dev/null
chk "--sin-relacion lo quita" "0" "$(linea "$CON" | grep -c '_relacionado:')"
chk "nada en cuarentena" "0" "$(cuarentena)"

echo "== A3. formas invalidas: el emisor las rechaza y el compactador cuarentena un evento a mano =="
emit --type pendiente.add --text x --prioridad Media --origen "[[sessions/2026-10-13-hoy]]" --relacionado basura >/dev/null 2>&1
chk "emit rechaza un valor libre" "1" "$?"
emit --type pendiente.relate --id "$CON" --relacionado "$CON" >/dev/null 2>&1
chk "emit rechaza relacionarse consigo mismo" "1" "$?"
emit --type pendiente.relate --id "$CON" >/dev/null 2>&1
chk "relate sin --relacionado ni --sin-relacion falla" "1" "$?"
mkdir -p "$M/.journal/pending"
printf '{"v":1,"type":"pendiente.relate","ts":1,"session_id":"t","agent_id":"t","payload":{"id":"%s","relacionado":["x — _id: p-0000000000_"]}}\n' "$CON" \
  > "$M/.journal/pending/0000000000000000001-t-1-0.json"
compact --quiet >/dev/null 2>&1
chk "un relacionado con texto libre va a cuarentena" "1" "$(cuarentena)"
chk "y la linea no cambio" "0" "$(linea "$CON" | grep -c '_relacionado:')"
rm -f "$M/.journal/quarantine"/*
printf '{"v":1,"type":"pendiente.relate","ts":2,"session_id":"t","agent_id":"t","payload":{"id":"%s","relacionado":["plan-x\\n"]}}\n' "$CON" \
  > "$M/.journal/pending/0000000000000000002-t-1-0.json"
compact --quiet >/dev/null 2>&1
chk "un relacionado con salto de linea final va a cuarentena" "1" "$(cuarentena)"
chk "y no parte la linea" "0" "$(grep -c '^_$' "$M/_pendientes.md")"

echo "== B. afines en el snippet =="
fixture
A=$(emit --type pendiente.add --text "alta corta de hoy" --prioridad Alta --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-10-13)
compact --quiet >/dev/null
M1=$(emit --type pendiente.add --text "media de una sesion vieja que cita al alta" --prioridad Media --origen "[[sessions/2026-09-01-vieja]]" --creado 2026-09-01 --relacionado "$A")
M2=$(emit --type pendiente.add --text "media de hoy que cita al alta" --prioridad Media --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-10-13 --relacionado "$A")
M3=$(emit --type pendiente.add --text "media suelta" --prioridad Media --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-09-02)
M4=$(emit --type pendiente.add --text "media ligada pero bloqueada" --prioridad Media --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-08-01 --relacionado "$A" --bloqueado-por "un PR ajeno")
M5=$(emit --type pendiente.add --text "media ligada con ventana futura" --prioridad Media --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-08-02 --relacionado "$A" --revisar 2099-01-01)
B1=$(emit --type pendiente.add --text "baja ligada" --prioridad Baja --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-08-03 --relacionado "$A")
compact --quiet >/dev/null
F="$M/sessions/2026-10-13-hoy.md"
cat > "$F" <<EOF
# hoy

## Como retomar

\`\`\`
Retomamos: algo.

Lee memory/sessions/2026-10-13-hoy.md para el contexto completo.

Proximo paso: hacer la alta corta — $A.

Antes de actuar, dime en 3 lineas donde quedamos.
\`\`\`

## Related
EOF
OUT=$(python3 "$BIN/print-como-retomar.py" "$F")
AF=$(printf '%s\n' "$OUT" | grep '^Si ese paso es corto' || true)
chk "hay linea de afines" "1" "$(printf '%s\n' "$OUT" | grep -c '^Si ese paso es corto, suma en la misma sesion: ')"
chk "trae la media vieja (arrastre entre sesiones)" "1" "$(printf '%s' "$AF" | grep -c "$M1")"
chk "trae la media de hoy" "1" "$(printf '%s' "$AF" | grep -c "$M2")"
chk "la mas vieja va primero" "$M1" "$(printf '%s' "$AF" | grep -o 'p-[0-9a-f]\{10\}' | head -1)"
chk "no trae la suelta" "0" "$(printf '%s' "$AF" | grep -c "$M3")"
chk "no trae la bloqueada" "0" "$(printf '%s' "$AF" | grep -c "$M4")"
chk "no trae la de ventana futura" "0" "$(printf '%s' "$AF" | grep -c "$M5")"
chk "no trae la Baja" "0" "$(printf '%s' "$AF" | grep -c "$B1")"
chk "va justo tras Proximo paso y una linea en blanco" "Si ese paso es corto" \
  "$(printf '%s\n' "$OUT" | awk '/^Proximo paso:/{getline; getline; print substr($0,1,20)}')"
chk "el fence sigue cerrado al final" '```' "$(printf '%s\n' "$OUT" | tail -1)"

echo "== B1b. tope de 2, Alta antes que Media, y nada que venza hoy (eso es la capa 🔔) =="
A2=$(emit --type pendiente.add --text "alta ligada mas nueva" --prioridad Alta --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-10-12 --relacionado "$A")
M6=$(emit --type pendiente.add --text "media ligada que vence hoy" --prioridad Media --origen "[[sessions/2026-10-13-hoy]]" --creado 2026-07-01 --relacionado "$A" --revisar "$(date +%F)")
compact --quiet >/dev/null
AF=$(python3 "$BIN/print-como-retomar.py" "$F" | grep '^Si ese paso es corto' || true)
chk "con 3 elegibles salen solo 2" "2" "$(printf '%s' "$AF" | grep -o 'p-[0-9a-f]\{10\}' | wc -l | tr -d ' ')"
chk "el Alta ligado va primero aunque sea mas nuevo" "$A2" "$(printf '%s' "$AF" | grep -o 'p-[0-9a-f]\{10\}' | head -1)"
chk "no trae la que vence hoy" "0" "$(printf '%s' "$AF" | grep -c "$M6")"
emit --type pendiente.relate --id "$A2" --sin-relacion >/dev/null
emit --type pendiente.relate --id "$M6" --sin-relacion >/dev/null
compact --quiet >/dev/null

echo "== B2. direccion inversa: el ancla cita a la media =="
emit --type pendiente.relate --id "$A" --relacionado "$M3" >/dev/null
emit --type pendiente.relate --id "$M1" --sin-relacion >/dev/null
compact --quiet >/dev/null
AF=$(python3 "$BIN/print-como-retomar.py" "$F" | grep '^Si ese paso es corto' || true)
chk "la media que el ancla cita entra" "1" "$(printf '%s' "$AF" | grep -c "$M3")"
chk "la que perdio la relacion sale" "0" "$(printf '%s' "$AF" | grep -c "$M1")"

echo "== B3. plan compartido: el ancla y la media citan el mismo plan =="
emit --type pendiente.relate --id "$A" --relacionado plan-bar >/dev/null
emit --type pendiente.relate --id "$M1" --relacionado plan-bar >/dev/null
emit --type pendiente.relate --id "$M2" --sin-relacion >/dev/null
compact --quiet >/dev/null
AF=$(python3 "$BIN/print-como-retomar.py" "$F" | grep '^Si ese paso es corto' || true)
chk "la media del mismo plan entra" "1" "$(printf '%s' "$AF" | grep -c "$M1")"
chk "la que el ancla ya no cita no entra" "0" "$(printf '%s' "$AF" | grep -c "$M3")"

echo "== B4. sin relacion, sin cambios: snippet identico al de la ficha =="
emit --type pendiente.relate --id "$A" --sin-relacion >/dev/null
emit --type pendiente.relate --id "$M1" --sin-relacion >/dev/null
for i in "$M4" "$M5" "$B1"; do emit --type pendiente.relate --id "$i" --sin-relacion >/dev/null; done
compact --quiet >/dev/null
chk "no hay linea de afines" "0" "$(python3 "$BIN/print-como-retomar.py" "$F" | grep -c '^Si ese paso es corto')"

echo "== B5. Proximo paso que cita un plan: entran los pendientes ligados a ese plan =="
sed -i.bak "s/^Proximo paso: .*/Proximo paso: Fase actual: 2 — seguir plan-bar./" "$F" && rm -f "$F.bak"
emit --type pendiente.relate --id "$M2" --relacionado plan-bar >/dev/null
compact --quiet >/dev/null
AF=$(python3 "$BIN/print-como-retomar.py" "$F" | grep '^Si ese paso es corto' || true)
chk "entra la media ligada al plan citado" "1" "$(printf '%s' "$AF" | grep -c "$M2")"

echo "== B6. un slug valido que termina en '-' o '.' tambien es ancla =="
emit --type pendiente.relate --id "$M2" --relacionado plan-baz- >/dev/null
compact --quiet >/dev/null
sed -i.bak "s/^Proximo paso: .*/Proximo paso: Fase actual: 1 — seguir plan-baz-./" "$F" && rm -f "$F.bak"
AF=$(python3 "$BIN/print-como-retomar.py" "$F" | grep '^Si ese paso es corto' || true)
chk "plan-baz- citado al final de una frase trae su media" "1" "$(printf '%s' "$AF" | grep -c "$M2")"
emit --type pendiente.relate --id "$M2" --relacionado plan-qux. >/dev/null
compact --quiet >/dev/null
sed -i.bak "s/^Proximo paso: .*/Proximo paso: seguir plan-qux./" "$F" && rm -f "$F.bak"
AF=$(python3 "$BIN/print-como-retomar.py" "$F" | grep '^Si ese paso es corto' || true)
chk "plan-qux. (slug con punto final) trae su media" "1" "$(printf '%s' "$AF" | grep -c "$M2")"

echo "== C. siguiente plan hermano =="
fixture
printf -- '---\ntype: index\n---\n# Plans\n\n| Plan | Status | Date | Session | Pendientes | Learnings |\n|---|---|---|---|---|---|\n' > "$M/_plans-index.md"
emit --type plan.upsert --slug padre --title "Padre" --status active --date 2026-10-01 >/dev/null 2>&1
compact --quiet >/dev/null
for h in hijo-a hijo-b hijo-c; do
  emit --type plan.upsert --slug "$h" --title "$h" --status active --date 2026-10-02 --parent padre >/dev/null 2>&1
  compact --quiet >/dev/null
done
emit --type plan.upsert --slug hijo-a --title hijo-a --status completed --date 2026-10-03 >/dev/null 2>&1
compact --quiet >/dev/null
chk "los hijos llevan la anotacion en el indice" "3" "$(grep -c '(fase de plan-padre)' "$M/_plans-index.md")"
H() { python3 "$BIN/plan-siguiente-hermano.py" --memory-dir "$M" --plan "$1"; }
chk "sin ## Sub-planes y dos abiertos: SIN-ORDEN" "1" "$(H hijo-a | grep -c '^SIN-ORDEN plan-padre: 2 hijos abiertos')"
printf -- '# Padre\n\n## Sub-planes\n\n| Sub-plan | Estado | Fase actual |\n|---|---|---|\n| [[plans/plan-hijo-a]] | completed | - |\n| [[plans/plan-hijo-c]] | active | 1 |\n| [[plans/plan-hijo-b]] | active | 1 |\n' > "$M/plans/plan-padre.md"
chk "con tabla: sigue la fila mas arriba abierta" "SIGUIENTE plan-hijo-c (active) — hermano en plan-padre" "$(H hijo-a | head -1)"
printf -- '# Padre\n\n## Sub-planes\n\n| Sub-plan | Estado | Fase actual |\n|---|---|---|\n| [[plans/plan-hijo-c.md|C]] | active | 1 |\n| [[plans/plan-hijo-b]] | active | 1 |\n' > "$M/plans/plan-padre.md"
chk "una fila escrita plan-x.md cuenta como plan-x" "SIGUIENTE plan-hijo-c (active) — hermano en plan-padre" "$(H hijo-a | head -1)"
chk "y no le pone la nota agregalo" "0" "$(H hijo-a | grep -c 'hijo-c.*agregalo')"
printf -- '# Padre\n\n## Sub-planes\n\n| Sub-plan | Estado | Fase actual |\n|---|---|---|\n| [[plans/plan-hijo-a]] | completed | - |\n| [[plans/plan-hijo-c]] | active | 1 |\n| [[plans/plan-hijo-b]] | active | 1 |\n' > "$M/plans/plan-padre.md"
chk "con prefijo plan- tambien" "SIGUIENTE plan-hijo-c (active) — hermano en plan-padre" "$(H plan-hijo-a | head -1)"
emit --type plan.upsert --slug hijo-aa --title hijo-aa --status draft --date 2026-10-02 --parent padre >/dev/null 2>&1
compact --quiet >/dev/null
chk "un hermano fuera de la tabla va al final y se dice" \
  "SIGUIENTE plan-hijo-aa (draft) — hermano en plan-padre (no esta en ## Sub-planes del padre: agregalo)" "$(H hijo-a | tail -1)"
chk "y no desplaza a la fila de la tabla" "SIGUIENTE plan-hijo-c (active) — hermano en plan-padre" "$(H hijo-a | head -1)"
emit --type plan.upsert --slug hijo-aa --title hijo-aa --status abandoned --date 2026-10-03 >/dev/null 2>&1
compact --quiet >/dev/null
emit --type plan.upsert --slug hijo-z- --title hijo-z- --status active --date 2026-10-02 --parent padre >/dev/null 2>&1
compact --quiet >/dev/null
printf -- '# Padre\n\n## Sub-planes\n\n| Sub-plan | Estado | Fase actual |\n|---|---|---|\n| [[plans/plan-hijo-z-]] | active | 1 |\n| [[plans/plan-hijo-c]] | active | 1 |\n| [[plans/plan-hijo-b]] | active | 1 |\n' > "$M/plans/plan-padre.md"
chk "un slug que termina en '-' respeta su fila" "SIGUIENTE plan-hijo-z- (active) — hermano en plan-padre" "$(H hijo-a | head -1)"
emit --type plan.upsert --slug hijo-z- --title hijo-z- --status abandoned --date 2026-10-03 >/dev/null 2>&1
compact --quiet >/dev/null
printf -- '# Padre\n\n## Sub-planes\n\n| Sub-plan | Estado | Fase actual |\n|---|---|---|\n| [[plans/plan-hijo-a]] | completed | - |\n| [[plans/plan-hijo-c]] | active | 1 |\n| [[plans/plan-hijo-b]] | active | 1 |\n' > "$M/plans/plan-padre.md"
emit --type plan.upsert --slug hijo-c --title hijo-c --status completed --date 2026-10-04 >/dev/null 2>&1
emit --type plan.upsert --slug hijo-b --title hijo-b --status completed --date 2026-10-04 >/dev/null 2>&1
compact --quiet >/dev/null
chk "sin hermanos abiertos: NINGUNO" "1" "$(H hijo-b | grep -c '^NINGUNO plan-padre')"
chk "un plan sin padre: SIN-PADRE" "1" "$(H padre | grep -c '^SIN-PADRE plan-padre')"
H no-existe >/dev/null 2>&1
chk "plan sin fila: sale 1" "1" "$?"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
