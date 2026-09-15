#!/usr/bin/env bash
# Pruebas de repair-plans-index.py (v2.25.5, p-baa546ddac): repara el formato mixto de
# memory/_plans-index.md — cabecera vieja de 4 columnas (Fecha|Plan|Status|Resumen, pre-journal)
# conviviendo con filas nuevas de 6 (Plan|Status|Fecha|Sesion|Pendientes|Learnings, que
# apply_plan_upsert escribe desde v2.12.0 sin mirar la cabecera). Medido en produccion
# (claude-vzert, ver p-baa546ddac/p-04acf30315).
#
# Lo que estas pruebas defienden:
#   A. una fila legacy de 4 columnas con fecha en la celda 0 se migra a la forma canonica de 6,
#      con el Resumen anexado a Status;
#   B. una cabecera legacy exacta se re-cabecea a la canonica, aunque ya haya filas de 6 debajo
#      (el caso medido en produccion: journal ya escribia filas nuevas bajo la cabecera vieja);
#   C. el caso espejo — cabecera YA canonica con una fila legacy suelta — migra la fila SIN
#      tocar la cabecera;
#   D. una fila de ancho ambiguo (ni 4 con fecha en la celda 0, ni 6) se reporta GRAVE y no se
#      toca;
#   E. un `\|` dentro de una celda no desalinea la fila ni se pierde al migrar;
#   F. una migracion que duplicaria el titulo de una fila canonica existente se reporta y no se
#      aplica;
#   G. es idempotente y dry-run no escribe nada;
#   H. sin _plans-index.md, o sin `## Plans`, no falla — se reporta y no se hace nada mas;
#   I. una cabecera que no es ni canonica ni legacy no se reescribe, pero las filas SI se migran
#      por su propia forma;
#   J. solo toca la tabla de '## Plans' — otra tabla del archivo con el mismo ancho no se toca.
#
# Uso: test-repair-plans-index.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

campo() { echo "$1" | grep -o "$2=[^ ]*"; }

echo "1. cabecera legacy + fila legacy + fila canonica (caso medido en produccion): migra y re-cabecea"
M1="$TMP/m1/memory"; mkdir -p "$M1"
cat > "$M1/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Plans

| Fecha | Plan | Status | Resumen |
|---|---|---|---|
| 2026-08-01 | Plan viejo | active | algo con \| pipe crudo |
| [[plans/plan-x\|Plan nuevo]] | active | 2026-09-14 | [[sessions/x]] | 4 | 2 rules |

## Related
- [[_pendientes]]
EOF
OUT=$(python3 "$BIN/repair-plans-index.py" "$M1")
check "dry-run: 1 migrada" "$(campo "$OUT" legacy_rows_migrated)" "legacy_rows_migrated=1"
check "dry-run: header_rewritten=si" "$(campo "$OUT" header_rewritten)" "header_rewritten=si"
check "dry-run no escribe" "$(grep -c '^| Fecha | Plan | Status | Resumen |$' "$M1/_plans-index.md")" "1"
OUT=$(python3 "$BIN/repair-plans-index.py" "$M1" --apply)
check "apply: 1 migrada" "$(campo "$OUT" legacy_rows_migrated)" "legacy_rows_migrated=1"
check "cabecera canonica" "$(grep -c '^| Plan | Status | Fecha | Sesion | Pendientes | Learnings |$' "$M1/_plans-index.md")" "1"
check "cabecera vieja ya no esta" "$(grep -c '^| Fecha | Plan | Status | Resumen |$' "$M1/_plans-index.md")" "0"
check "fila migrada: Plan en celda 0, Resumen anexado a Status, pipe escapado intacto" \
  "$(grep -F -c '| Plan viejo | active — resumen: algo con \| pipe crudo | 2026-08-01 |  |  |  |' "$M1/_plans-index.md")" "1"
check "fila canonica intacta" "$(grep -c 'Plan nuevo' "$M1/_plans-index.md")" "1"
check "solo una fila migrada, la otra no se duplico" "$(grep -c '^|.*Plan viejo' "$M1/_plans-index.md")" "1"

echo "2. idempotencia: segunda corrida no encuentra nada"
OUT=$(python3 "$BIN/repair-plans-index.py" "$M1" --apply)
check "todo en cero" "$OUT" "legacy_rows_migrated=0 header_rewritten=no unrepairable_rows=0 possible_duplicates=0 no_plans_table=0 header_unrecognized=0"

echo "3. caso espejo: cabecera YA canonica con una fila legacy suelta migra la fila, no la cabecera"
M3="$TMP/m3/memory"; mkdir -p "$M3"
cat > "$M3/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| [[plans/plan-y\|Plan actual]] | active | 2026-09-14 | [[sessions/y]] | 1 |  |
| 2026-01-01 | Plan legacy suelto | completed | resumen viejo |

## Related
EOF
OUT=$(python3 "$BIN/repair-plans-index.py" "$M3" --apply)
check "1 migrada" "$(campo "$OUT" legacy_rows_migrated)" "legacy_rows_migrated=1"
check "header_rewritten=no (ya era canonica)" "$(campo "$OUT" header_rewritten)" "header_rewritten=no"
check "fila migrada respeta Status con resumen" "$(grep -c 'completed — resumen: resumen viejo' "$M3/_plans-index.md")" "1"
check "fila canonica no se toco" "$(grep -c 'Plan actual' "$M3/_plans-index.md")" "1"

echo "4. una fila de ancho ambiguo (5 celdas) se reporta GRAVE y no se toca"
M4="$TMP/m4/memory"; mkdir -p "$M4"
cat > "$M4/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| Plan raro | active | 2026-09-01 | [[sessions/z]] | 3 |

## Related
EOF
OUT=$(python3 "$BIN/repair-plans-index.py" "$M4" --apply)
check "0 migradas" "$(campo "$OUT" legacy_rows_migrated)" "legacy_rows_migrated=0"
check "1 no reparable" "$(campo "$OUT" unrepairable_rows)" "unrepairable_rows=1"
check "la fila de 5 celdas no se toco" "$(grep -c '^| Plan raro | active | 2026-09-01 | \[\[sessions/z\]\] | 3 |$' "$M4/_plans-index.md")" "1"

echo "5. una migracion que duplicaria un titulo canonico existente se reporta, no se aplica"
M5="$TMP/m5/memory"; mkdir -p "$M5"
cat > "$M5/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| Plan repetido | active | 2026-09-10 |  |  |  |
| 2026-01-01 | Plan repetido | completed | resumen viejo |

## Related
EOF
OUT=$(python3 "$BIN/repair-plans-index.py" "$M5" --apply)
check "0 migradas (posible duplicado)" "$(campo "$OUT" legacy_rows_migrated)" "legacy_rows_migrated=0"
check "1 posible duplicado" "$(campo "$OUT" possible_duplicates)" "possible_duplicates=1"
check "la fila legacy sigue con 4 celdas (no se toco)" \
  "$(grep -c '^| 2026-01-01 | Plan repetido | completed | resumen viejo |$' "$M5/_plans-index.md")" "1"

echo "6. sin _plans-index.md no falla (proyecto nuevo)"
M6="$TMP/m6/memory"; mkdir -p "$M6"
OUT=$(python3 "$BIN/repair-plans-index.py" "$M6"); RC6=$?
check "exit 0" "$RC6" "0"
check "avisa sin _plans-index.md" "$(echo "$OUT" | grep -c 'sin _plans-index.md')" "1"

echo "7. _plans-index.md sin '## Plans' no falla, reporta no_plans_table=1"
M7="$TMP/m7/memory"; mkdir -p "$M7"
cat > "$M7/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Related
EOF
OUT=$(python3 "$BIN/repair-plans-index.py" "$M7" --apply)
check "no_plans_table=1" "$(campo "$OUT" no_plans_table)" "no_plans_table=1"
check "archivo intacto" "$(grep -c '## Plans' "$M7/_plans-index.md")" "0"

echo "8. cabecera no reconocida (ni canonica ni legacy): no se reescribe, filas SI se migran por forma"
M8="$TMP/m8/memory"; mkdir -p "$M8"
cat > "$M8/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Plans

| Nombre | Estado | Cuando |
|---|---|---|
| 2026-05-01 | Plan viejo raro | active | texto suelto |

## Related
EOF
OUT=$(python3 "$BIN/repair-plans-index.py" "$M8" --apply)
check "header_unrecognized=1" "$(campo "$OUT" header_unrecognized)" "header_unrecognized=1"
check "header_rewritten=no" "$(campo "$OUT" header_rewritten)" "header_rewritten=no"
check "la fila igual se migro por su forma (4 celdas, fecha en la 0)" "$(campo "$OUT" legacy_rows_migrated)" "legacy_rows_migrated=1"
check "cabecera vieja no reconocida sigue intacta" "$(grep -c '^| Nombre | Estado | Cuando |$' "$M8/_plans-index.md")" "1"

echo "9. solo toca la tabla de '## Plans' — otra tabla del archivo con el mismo ancho no se toca"
M9="$TMP/m9/memory"; mkdir -p "$M9"
cat > "$M9/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Otra Tabla

| Fecha | Plan | Status | Resumen |
|---|---|---|---|
| 2026-01-01 | No es un plan real | activo | no tocar |

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| Plan real | active | 2026-09-01 |  |  |  |

## Related
EOF
OUT=$(python3 "$BIN/repair-plans-index.py" "$M9" --apply)
check "0 migradas (la fila legacy esta fuera de '## Plans')" "$(campo "$OUT" legacy_rows_migrated)" "legacy_rows_migrated=0"
check "'## Otra Tabla' intacta" "$(grep -c '^| Fecha | Plan | Status | Resumen |$' "$M9/_plans-index.md")" "1"
check "fila ajena intacta" "$(grep -c 'No es un plan real' "$M9/_plans-index.md")" "1"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
