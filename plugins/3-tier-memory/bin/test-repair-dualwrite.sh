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

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
