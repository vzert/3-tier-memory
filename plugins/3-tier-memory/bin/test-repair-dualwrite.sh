#!/usr/bin/env bash
# Pruebas de repair-dualwrite.py y del arreglo del `|` en journal-compact.py.
#
# Cubre las dos perdidas de historial medidas el 2026-09-10 en claude-vzert:
#   A. una linea de Tier 2 escrita a mano no genera fila en Tier 3 (51 de 120 pendientes);
#   B. una fila cuyo texto lleva un `|` tiene mas de 7 celdas, `apply_resolve_monthly` lee la
#      prioridad como fecha de resolucion y concluye "ya resuelto": el pendiente no se puede
#      cerrar NUNCA, y el compactador reporta applied=1 sin dejar ni un WARN.
#
# Uso: test-repair-dualwrite.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

nuevo_memory() {
  local d="$1"
  mkdir -p "$d/pendientes" "$d/.journal/pending"
  cat > "$d/pendientes/2026-09.md" <<'EOF'
---
type: pendientes-archive
month: 2026-09
---
# Pendientes — Septiembre 2026

| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |
|---|---|---|---|---|---|---|

## Related
- [[_pendientes]]
EOF
  cat > "$d/_pendientes.md" <<'EOF'
# Pendientes

## Alta prioridad

- [ ] Pendiente con `sort \| uniq -c` en el texto — _origen: [[sessions/x]]_ — _creado: 2026-09-11_ — _id: p-aaaaaaaaaa_

## Media prioridad

- [ ] Pendiente normal — _origen: [[sessions/y]]_ — _creado: 2026-08-02_ — _id: p-bbbbbbbbbb_

## Related
EOF
}

echo "1. repara los huerfanos de Tier 2 y respeta el mes de _creado_"
M="$TMP/m1"; nuevo_memory "$M"
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M" --apply)
check "dos filas escritas" "$(echo "$OUT" | grep -o 'rows_added=[0-9]*')" "rows_added=2"
check "la de agosto va a su propio mes" \
  "$(grep -c 'p-bbbbbbbbbb' "$M/pendientes/2026-08.md" 2>/dev/null || echo 0)" "1"
check "celdas Resuelto y Sesion vacias" \
  "$(grep -o 'p-aaaaaaaaaa_ .*' "$M/pendientes/2026-09.md" | grep -c '| | |$')" "1"
check "no toca Tier 2" \
  "$(grep -c '^- \[ \]' "$M/_pendientes.md")" "2"

echo "2. es idempotente"
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M" --apply)
check "segunda corrida no escribe" "$(echo "$OUT" | grep -o 'rows_added=[0-9]*')" "rows_added=0"

echo "3. el id se conserva, no se recalcula"
M2="$TMP/m2"; nuevo_memory "$M2"
python3 "$BIN/repair-dualwrite.py" "$M2" --apply --quiet
check "id inventado intacto" "$(grep -c '_id: p-aaaaaaaaaa_' "$M2/pendientes/2026-09.md")" "1"

echo "4. una fila con | en el texto se puede cerrar (bug del split crudo)"
M3="$TMP/m3"; nuevo_memory "$M3"
python3 "$BIN/repair-dualwrite.py" "$M3" --apply --quiet
python3 "$BIN/journal-emit.py" --memory-dir "$M3" --type pendiente.resolve \
  --id p-aaaaaaaaaa --estado resolved --sesion "[[sessions/cierre]]" >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$M3" --quiet >/dev/null
check "la celda Resuelto quedo llena" \
  "$(grep -o 'p-aaaaaaaaaa_.*' "$M3/pendientes/2026-09.md" | grep -c '2026-')" "1"

echo "4b. una nota de cierre con | tampoco parte la fila"
M3b="$TMP/m3b"; nuevo_memory "$M3b"
python3 "$BIN/repair-dualwrite.py" "$M3b" --apply --quiet
python3 "$BIN/journal-emit.py" --memory-dir "$M3b" --type pendiente.resolve \
  --id p-bbbbbbbbbb --estado resolved --sesion "[[sessions/cierre]]" \
  --nota "7 filas con | reparadas" >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$M3b" --quiet >/dev/null
cat > "$TMP/cuenta.py" <<'PYEOF'
import re, sys
s = sys.stdin.read().strip()
print(len(re.split(r"(?<!\\)\|", s.strip("|"))))
PYEOF
check "la fila sigue con 7 celdas" \
  "$(grep 'p-bbbbbbbbbb' "$M3b/pendientes/2026-08.md" | python3 "$TMP/cuenta.py")" "7"

echo "5. --fix-pipes repara una fila vieja con | CRUDO"
M4="$TMP/m4"; nuevo_memory "$M4"
# Fila escrita por apply_add_monthly antes de escapar: 9 celdas en vez de 7.
sed -i.bak 's#^|---|---|---|---|---|---|---|#|---|---|---|---|---|---|---|\
| 1 | Contar con `sort | uniq -c` _id: p-cccccccccc_ | Alta | 2026-09-11 | [[sessions/z]] | | |#' \
  "$M4/pendientes/2026-09.md"
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M4" --apply --fix-pipes)
check "reporta la fila reparada" "$(echo "$OUT" | grep -o 'pipes_fixed=[0-9]*')" "pipes_fixed=1"
# cuenta.py (creado arriba): un regex con `\|` dentro de `python3 -c` en un `$( )` pasa por dos
# capas de escape de shell y llega corrupto (mide `\\` en vez de `\`).
check "la fila quedo con 7 celdas" \
  "$(grep 'p-cccccccccc' "$M4/pendientes/2026-09.md" | python3 "$TMP/cuenta.py")" "7"
check "sin --fix-pipes solo avisa" \
  "$(nuevo_memory "$TMP/m5"; sed -i.bak 's#^|---|---|---|---|---|---|---|#|---|---|---|---|---|---|---|\
| 1 | x `a | b` _id: p-dddddddddd_ | Alta | 2026-09-11 | [[sessions/z]] | | |#' "$TMP/m5/pendientes/2026-09.md"; python3 "$BIN/repair-dualwrite.py" "$TMP/m5" | grep -c 'no se pueden cerrar')" "1"

echo "6. en dry-run el contador delata la fila rota (lo lee el check 14 de /audit-3t)"
OUT=$(python3 "$BIN/repair-dualwrite.py" "$TMP/m5")
check "pipes_broken cuenta lo encontrado" "$(echo "$OUT" | grep -o 'pipes_broken=[0-9]*')" "pipes_broken=1"
check "pipes_fixed cuenta lo reparado" "$(echo "$OUT" | grep -o 'pipes_fixed=[0-9]*')" "pipes_fixed=0"

echo "7. delata los ids que no son el sha1 de su contenido"
check "ids_invented" \
  "$(python3 "$BIN/repair-dualwrite.py" "$TMP/m1" | grep -o 'ids_invented=[0-9]*')" "ids_invented=2"

echo "8. una fila con | en la NOTA no se desplaza al repararla (bug del 2026-09-11)"
M6="$TMP/m6"; nuevo_memory "$M6"
sed -i.bak 's#^|---|---|---|---|---|---|---|#|---|---|---|---|---|---|---|\
| 1 | texto normal _id: p-eeeeeeeeee_ | Media | 2026-09-11 | [[sessions/z]] | 2026-09-11 | [[sessions/c]] — resolved — 7 filas con | reparadas |#' \
  "$M6/pendientes/2026-09.md"
python3 "$BIN/repair-dualwrite.py" "$M6" --apply --fix-pipes --quiet
ROW=$(grep 'p-eeeeeeeeee' "$M6/pendientes/2026-09.md")
check "sigue con 7 celdas" "$(echo "$ROW" | python3 "$TMP/cuenta.py")" "7"
cat > "$TMP/celda.py" <<'PYEOF'
import re, sys
cells = re.split(r"(?<!\\)\|", sys.stdin.read().strip().strip("|"))
print(cells[int(sys.argv[1])].strip())
PYEOF
check "la prioridad NO se desplazo" "$(echo "$ROW" | python3 "$TMP/celda.py" 2)" "Media"

echo "9. una fila con una COLUMNA de mas no se toca, pero se reporta"
M7="$TMP/m7"; nuevo_memory "$M7"
sed -i.bak 's#^|---|---|---|---|---|---|---|#|---|---|---|---|---|---|---|\
| 1 | texto `a | b` _id: p-ffffffffff_ | Media | 2026-09-11 | [[sessions/z]] | | 2026-09-12 | [[sessions/c]] |#' \
  "$M7/pendientes/2026-09.md"
ANTES=$(grep 'p-ffffffffff' "$M7/pendientes/2026-09.md")
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M7" --apply --fix-pipes)
check "la reporta como no reparable" "$(echo "$OUT" | grep -o 'unrepairable=[0-9]*')" "unrepairable=1"
check "y NO la toco" "$(grep 'p-ffffffffff' "$M7/pendientes/2026-09.md")" "$ANTES"

echo "10. un pendiente con ventana (_revisar_) NO se reporta como id inventado"
# El id lo calcula journal-emit sobre el texto SIN metadatos; repair-dualwrite lo re-deriva.
# Mientras su META_RE no borraba `_revisar:`, el texto que hasheaba llevaba la ventana pegada,
# el sha1 salia distinto y TODO pendiente con ventana se reportaba como inventado (2026-09-11).
M8="$TMP/m8"; nuevo_memory "$M8"
rm -f "$M8/_pendientes.md"
cat > "$M8/_pendientes.md" <<'EOF'
# Pendientes

## Alta prioridad

## Media prioridad

## Baja prioridad

## Related
EOF
python3 "$BIN/journal-emit.py" --memory-dir "$M8" --type pendiente.add \
  --text "Medir el ratio cierra/entra dentro de un mes" --prioridad media \
  --origen "[[sessions/ventana]]" --creado 2026-09-11 --revisar 2026-10-11 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$M8" --quiet >/dev/null
check "la linea llego con su ventana" "$(grep -c '_revisar: 2026-10-11_' "$M8/_pendientes.md")" "1"
check "ids_invented=0" \
  "$(python3 "$BIN/repair-dualwrite.py" "$M8" | grep -o 'ids_invented=[0-9]*')" "ids_invented=0"

# Devuelve el header `## ...` bajo el que vive la linea que contiene $2 en el fichero $1.
seccion_de() { awk -v pat="$2" '/^## /{h=$0} index($0,pat){print h; exit}' "$1"; }

echo "11. adopcion: los pendientes de una instalacion pre-2.12.0 reciben ancla y fila"
# El caso reportado el 2026-09-12: `_pendientes.md` organizado por `## Abiertos`, sin headers de
# prioridad. Antes de 2.22.0 esas lineas daban `NO REPARABLE ... sin header de prioridad` en CADA
# checkpoint y no tenian fila de Tier 3 nunca, asi que al cerrarlas se perdia la fecha de cierre.
M9="$TMP/m9"; nuevo_memory "$M9"
cat > "$M9/_pendientes.md" <<'EOF'
# Pendientes

## Como usar
Marca con [x] y corre /checkpoint-3t.

## Abiertos

- [ ] Revisar el pipeline de staging — _creado: 2026-09-01_ — _id: p-1111111111_
- [ ] URGENTE: el worker de colas esta caido — _creado: 2026-09-02_ — _id: p-2222222222_
- [x] esto ya se cerro — _creado: 2026-09-01_ — _id: p-3333333333_

## Related
- [[MEMORY]]
EOF
OUT9=$(python3 "$BIN/repair-dualwrite.py" "$M9" --apply --fix-pipes)
check "adopta los dos abiertos"        "$(echo "$OUT9" | grep -o 'adopted=[0-9]*')" "adopted=2"
check "y ninguno queda sin reparar"    "$(echo "$OUT9" | grep -o 'missing_data=[0-9]*')" "missing_data=0"
check "el urgente va a Alta"           "$(seccion_de "$M9/_pendientes.md" p-2222222222_)" "## Alta prioridad"
check "el otro va a Media"             "$(seccion_de "$M9/_pendientes.md" p-1111111111_)" "## Media prioridad"
check "el cerrado NO se movio"         "$(seccion_de "$M9/_pendientes.md" p-3333333333_)" "## Abiertos"
check "las secciones del usuario siguen ahi" \
  "$(grep -c -e '^## Como usar' -e '^## Abiertos' "$M9/_pendientes.md")" "2"
check "y cada uno tiene su fila de Tier 3" \
  "$(grep -c -e 'p-1111111111_' -e 'p-2222222222_' "$M9/pendientes/2026-09.md")" "2"
check "con Origen '-' porque no hubo sesion que los emitiera" \
  "$(grep 'p-1111111111_' "$M9/pendientes/2026-09.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')" "—"
check "el cerrado tambien recibe fila, con prioridad Media" \
  "$(grep 'p-3333333333_' "$M9/pendientes/2026-09.md" | awk -F'|' '{gsub(/ /,"",$4); print $4}')" "Media"
OUT9B=$(python3 "$BIN/repair-dualwrite.py" "$M9" --apply --fix-pipes)
check "y no vuelve a salir en el informe una vez tiene fila" \
  "$(echo "$OUT9B" | grep -c 'p-3333333333')" "0"
check "idempotente: la segunda corrida no adopta ni anade nada" \
  "$(echo "$OUT9B" | grep -o 'adopted=0 rows_added=0')" "adopted=0 rows_added=0"
check "ids_invented=0 (adoptar no recalcula ids)" \
  "$(echo "$OUT9B" | grep -o 'ids_invented=[0-9]*')" "ids_invented=0"

echo "12. el compactador crea el ancla que falta en vez de cuarentenar (2.22.0)"
M10="$TMP/m10"; nuevo_memory "$M10"
printf '# Pendientes\n\n## Abiertos\n\n- [ ] algo del usuario\n\n## Related\n' > "$M10/_pendientes.md"
python3 "$BIN/journal-emit.py" --memory-dir "$M10" --type pendiente.add \
  --text "nuevo sobre archivo legacy" --prioridad Alta --origen "[[sessions/x]]" --creado 2026-09-12 >/dev/null
OUT10=$(python3 "$BIN/journal-compact.py" --memory-dir "$M10")
check "se aplica sin cuarentena" "$(echo "$OUT10" | grep -o 'applied=1 quarantined=0')" "applied=1 quarantined=0"
check "creo el header de Alta" "$(grep -c '^## Alta prioridad' "$M10/_pendientes.md")" "1"
check "y no toco la seccion del usuario" "$(grep -c '^- \[ \] algo del usuario' "$M10/_pendientes.md")" "1"
check "0 eventos en cuarentena" "$(ls "$M10/.journal/quarantine" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "13. al actualizar, el evento que la version vieja cuarenteno se rescata y se aplica"
# Sin esto, el hook SessionStart le avisa a la PERSONA en cada arranque de un trabajo manual que
# ya no existe: el motivo por el que se cuarenteno (ancla ausente) lo resuelve ahora el
# compactador solo. Actualizar el plugin tiene que limpiar lo que dejo el plugin viejo.
M11="$TMP/m11"; nuevo_memory "$M11"
printf '# Pendientes\n\n## Abiertos\n\n- [ ] algo del usuario\n\n## Related\n' > "$M11/_pendientes.md"
mkdir -p "$M11/.journal/quarantine"
cat > "$M11/.journal/quarantine/1700000000000000000-viejo-1-0.json" <<'EOF'
{"v":1,"type":"pendiente.add","ts":1700000000000000000,"session_id":"vieja","agent_id":"vieja","payload":{"id":"p-4444444444","text":"quedo en cuarentena al actualizar","prioridad":"Alta","origen":"[[sessions/2026-09-11-x]]","creado":"2026-09-11"}}
EOF
printf "no-anchor: falta el header '## Alta prioridad'\n" > "$M11/.journal/quarantine/1700000000000000000-viejo-1-0.json.reason"
OUT11=$(python3 "$BIN/journal-compact.py" --memory-dir "$M11")
check "se rescata y se aplica"  "$(echo "$OUT11" | grep -o 'applied=1 quarantined=0 pending_left=0 rescued=1')" "applied=1 quarantined=0 pending_left=0 rescued=1"
check "la cuarentena queda vacia" "$(ls "$M11/.journal/quarantine" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "el pendiente entra al indice" "$(grep -c 'p-4444444444_' "$M11/_pendientes.md")" "1"
check "y tiene su fila de Tier 3"    "$(grep -c 'p-4444444444_' "$M11/pendientes/2026-09.md")" "1"

echo "14. un motivo que esta version NO sabe resolver se queda en cuarentena"
M12="$TMP/m12"; nuevo_memory "$M12"
printf '# Pendientes\n\n## Alta prioridad\n\n## Related\n' > "$M12/_pendientes.md"
mkdir -p "$M12/.journal/quarantine"
cat > "$M12/.journal/quarantine/1700000000000000000-otro-1-0.json" <<'EOF'
{"v":1,"type":"pendiente.add","ts":1700000000000000000,"session_id":"vieja","agent_id":"vieja","payload":{"id":"p-5555555555","text":"colision de id","prioridad":"Alta","origen":"[[sessions/2026-09-11-x]]","creado":"2026-09-11"}}
EOF
printf 'id-collision: p-5555555555 ya existe con otro texto\n' > "$M12/.journal/quarantine/1700000000000000000-otro-1-0.json.reason"
python3 "$BIN/journal-compact.py" --memory-dir "$M12" >/dev/null
check "sigue en cuarentena" "$(ls "$M12/.journal/quarantine"/*.json 2>/dev/null | wc -l | tr -d ' ')" "1"
check "y no entro al indice"  "$(grep -c 'p-5555555555' "$M12/_pendientes.md")" "0"

echo "15. un motivo que EMPIEZA por uno rescatable pero sigue con otra causa no se rescata"
# El regex del rescate decide si un evento vuelve a aplicarse. Sin ancla final, una coincidencia de
# prefijo bastaba: un evento aplicado por el parecido de su primera frase.
M13="$TMP/m13"; nuevo_memory "$M13"
printf '# Pendientes\n\n## Alta prioridad\n\n## Related\n' > "$M13/_pendientes.md"
mkdir -p "$M13/.journal/quarantine"
cat > "$M13/.journal/quarantine/1700000000000000000-prefijo-1-0.json" <<'EOF'
{"v":1,"type":"pendiente.add","ts":1700000000000000000,"session_id":"vieja","agent_id":"vieja","payload":{"id":"p-6666666666","text":"prefijo enganoso","prioridad":"Alta","origen":"[[sessions/2026-09-11-x]]","creado":"2026-09-11"}}
EOF
printf "no-anchor: falta el header '## Alta prioridad' y ademas el fichero lo borro alguien a mano\n" \
  > "$M13/.journal/quarantine/1700000000000000000-prefijo-1-0.json.reason"
python3 "$BIN/journal-compact.py" --memory-dir "$M13" >/dev/null
check "sigue en cuarentena"  "$(ls "$M13/.journal/quarantine"/*.json 2>/dev/null | wc -l | tr -d ' ')" "1"
check "y no entro al indice" "$(grep -c 'p-6666666666' "$M13/_pendientes.md")" "0"

echo "16. la adopcion conserva CRLF, el pipe crudo del texto y no pierde ninguna otra linea"
M14="$TMP/m14"; nuevo_memory "$M14"
printf '# Pendientes\r\n\r\n## Como usar\r\nlee esto\r\n\r\n## Abiertos\r\n\r\n- [ ] corre `sort | uniq -c` — _creado: 2026-09-01_ — _id: p-7777777777_\r\n\r\n## Related\r\n- [[x]]\r\n' > "$M14/_pendientes.md"
cp "$M14/_pendientes.md" "$TMP/m14.orig"
python3 "$BIN/repair-dualwrite.py" "$M14" --apply --fix-pipes >/dev/null
# La comprobacion de "no pierde ninguna otra linea" tiene que MIRAR todas, no cuatro elegidas: cada
# linea no vacia del original sigue estando (el conteo total si puede cambiar, porque la adopcion
# crea headers y colapsa el hueco).
# En python y no con `grep -Fxq`: en esta maquina `grep` es ugrep, que con una linea que empieza por
# `-` la toma como opcion y con una linea vacia genera una alternancia invalida. El banco decia
# "falta" de las 7 lineas que SI estaban.
PERDIDAS=$(python3 - "$TMP/m14.orig" "$M14/_pendientes.md" <<'PYX'
import sys
orig = open(sys.argv[1], encoding="utf-8", newline="").read().split("\n")
ahora = set(open(sys.argv[2], encoding="utf-8", newline="").read().split("\n"))
print(sum(1 for l in orig if l.strip() and l not in ahora))
PYX
)
check "ninguna linea no vacia del original se perdio" "$PERDIDAS" "0"
check "todas las lineas siguen terminando en CRLF" \
  "$(tr -cd '\r' < "$M14/_pendientes.md" | wc -c | tr -d ' ')" "$(grep -c '' "$M14/_pendientes.md")"
check "el texto del item no cambio" \
  "$(grep -c 'corre `sort | uniq -c` — _creado: 2026-09-01_ — _id: p-7777777777_' "$M14/_pendientes.md")" "1"
check "las dos secciones del usuario y su contenido siguen" \
  "$(grep -c -e '^## Como usar' -e '^lee esto' -e '^## Abiertos' -e '^- \[\[x\]\]' "$M14/_pendientes.md")" "4"
check "su fila mensual tiene el | escapado" \
  "$(grep -c 'sort \\| uniq -c' "$M14/pendientes/2026-09.md")" "1"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
