#!/bin/bash
# Regresion: journal-compact.py crea '## Sessions' / '## Plans' (y por extension '## Topic
# Files', '## Active Research', '## Completed Research') cuando el header falta DEL TODO, en vez
# de mandar el evento a cuarentena — mismo criterio que ya existia desde 2.22.0 para el header de
# prioridad de _pendientes.md. v2.24.0.
#
# Motivacion real: cloudflare-expert (2026-09-12) tenia _session-index.md y _plans-index.md sin
# estas anclas — defecto estructural de instalaciones cuyo Step 3 de /setup-memory las genero con
# otro texto — y el primer session.add/plan.upsert de la sesion se fue a quarantine/ en silencio.
#
# Cubre dos casos:
#   1. Ancla ausente HOY: el evento se aplica en el momento (no cuarentena), la seccion vieja con
#      otro texto (si la habia) queda intacta, y la nueva seccion tiene la fila.
#   2. Ancla ausente AYER: un evento que una version anterior ya habia cuarentenado por esa razon
#      se rescata (vuelve a pending/ y se aplica) al actualizar el plugin, sin que nadie lo pida.
#
# Uso: bash bin/test-anchor-heal.sh    (sin dependencias; sale != 0 si algo falla)

set -u
cd "$(dirname "$0")/.." || exit 1
M=$(mktemp -d) && [ -d "$M" ] || { echo "mktemp fallo"; exit 1; }
export MEMORY_DIR=$M; FAIL=0
trap 'rm -rf "$M"' EXIT

echo "== caso 1: ancla ausente hoy (session.add) =="
printf -- '---\ntype: index\n---\n# Sesiones\n\n## Historial de Sesiones\n\n(vieja, con otro texto)\n' > "$M/_session-index.md"
ID=$(python3 bin/journal-emit.py --type session.add --slug 2026-01-01-prueba --date 2026-01-01 --status done --summary "prueba anclas" 2>&1)
OUT=$(python3 bin/journal-compact.py --quiet 2>&1)
echo "  compact: $OUT"
echo "$OUT" | grep -q 'quarantined=0' || { echo "  FAIL: se cuarenteno (se esperaba aplicado en el momento)"; FAIL=1; }
grep -q '^## Sessions$' "$M/_session-index.md" || { echo "  FAIL: '## Sessions' no se creo"; FAIL=1; }
grep -q 'Historial de Sesiones' "$M/_session-index.md" || { echo "  FAIL: la seccion vieja desaparecio"; FAIL=1; }
grep -q '2026-01-01-prueba' "$M/_session-index.md" || { echo "  FAIL: la fila de la sesion no aparece"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 1b: ancla ausente hoy (plan.upsert) =="
printf -- '---\ntype: index\n---\n# Planes\n' > "$M/_plans-index.md"
python3 bin/journal-emit.py --type plan.upsert --slug prueba-anclas --title "Prueba anclas" --status active --date 2026-01-01 >/dev/null
OUT=$(python3 bin/journal-compact.py --quiet 2>&1)
echo "  compact: $OUT"
echo "$OUT" | grep -q 'quarantined=0' || { echo "  FAIL: se cuarenteno"; FAIL=1; }
grep -q '^## Plans$' "$M/_plans-index.md" || { echo "  FAIL: '## Plans' no se creo"; FAIL=1; }
grep -q 'plan-prueba-anclas' "$M/_plans-index.md" || { echo "  FAIL: la fila del plan no aparece"; FAIL=1; }
[ "$FAIL" = 0 ] || echo "  (ver FAILs arriba)"

echo "== caso 2: rescate de un evento cuarentenado por esta razon en una version anterior =="
rm -rf "$M/.journal" "$M/_session-index.md"
printf -- '---\ntype: index\n---\n# Sesiones\n\n## Historial de Sesiones\n\n' > "$M/_session-index.md"
python3 bin/journal-emit.py --type session.add --slug 2026-02-02-rescate --date 2026-02-02 --status done --summary "rescate" >/dev/null
PENDFILE=$(ls "$M"/.journal/pending/*.json)
mkdir -p "$M/.journal/quarantine"
BASENAME=$(basename "$PENDFILE")
mv "$PENDFILE" "$M/.journal/quarantine/$BASENAME"
printf "no-anchor: falta '## Sessions' en _session-index.md\n" > "$M/.journal/quarantine/$BASENAME.reason"
OUT=$(python3 bin/journal-compact.py --quiet 2>&1)
echo "  compact: $OUT"
echo "$OUT" | grep -q 'rescued=1' || { echo "  FAIL: no reporto rescued=1 ($OUT)"; FAIL=1; }
[ -z "$(ls -A "$M/.journal/quarantine" 2>/dev/null)" ] || { echo "  FAIL: quarantine/ no quedo vacio"; FAIL=1; }
grep -q '2026-02-02-rescate' "$M/_session-index.md" || { echo "  FAIL: la fila rescatada no aparece"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 3: la tabla YA EXISTE con otro nombre de header y filas reales — se adopta, no se duplica (hallazgo del adversario, 2026-09-14) =="
rm -rf "$M/.journal"
cat > "$M/_session-index.md" <<'EOF'
---
type: index
---
# Sesiones

## Convención

| Fecha | Sesion | Status | Resumen | Commit |
|---|---|---|---|---|
| 2026-03-03 | [[sessions/2026-03-03-existente\|existente]] | active | resumen viejo | |

## Related
EOF
python3 bin/journal-emit.py --type session.add --slug 2026-03-03-existente --date 2026-03-03 --status done --summary "resumen actualizado" >/dev/null
OUT=$(python3 bin/journal-compact.py --quiet 2>&1)
echo "  compact: $OUT"
echo "$OUT" | grep -q 'quarantined=0' || { echo "  FAIL: se cuarenteno"; FAIL=1; }
N=$(grep -c '2026-03-03-existente' "$M/_session-index.md")
[ "$N" = "1" ] || { echo "  FAIL: la fila se duplico (aparece $N veces, se esperaba 1)"; FAIL=1; }
grep -q 'resumen actualizado' "$M/_session-index.md" || { echo "  FAIL: no se actualizo la fila existente"; FAIL=1; }
grep -q '^## Sessions$' "$M/_session-index.md" || { echo "  FAIL: el header no se renombro a '## Sessions'"; FAIL=1; }
grep -q '^## Convención$' "$M/_session-index.md" && { echo "  FAIL: quedo una segunda seccion '## Convención' — se duplico en vez de renombrar"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 4: DOS tablas candidatas (ambiguo) — no adivina, crea la vacia como antes =="
rm -rf "$M/.journal"
cat > "$M/_plans-index.md" <<'EOF'
---
type: index
---
# Planes

## Draft Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| plan viejo A | active | 2026-01-01 | | | |

## Archived Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| plan viejo B | completed | 2026-01-02 | | | |

## Related
EOF
python3 bin/journal-emit.py --type plan.upsert --slug ambiguo --title "Plan ambiguo" --status active --date 2026-03-04 >/dev/null
OUT=$(python3 bin/journal-compact.py --quiet 2>&1)
echo "  compact: $OUT"
echo "$OUT" | grep -q 'quarantined=0' || { echo "  FAIL: se cuarenteno"; FAIL=1; }
grep -q '^## Plans$' "$M/_plans-index.md" || { echo "  FAIL: no se creo '## Plans' nueva ante la ambiguedad"; FAIL=1; }
grep -q '^## Draft Plans$' "$M/_plans-index.md" || { echo "  FAIL: 'Draft Plans' desaparecio (no debia tocarse)"; FAIL=1; }
grep -q '^## Archived Plans$' "$M/_plans-index.md" || { echo "  FAIL: 'Archived Plans' desaparecio (no debia tocarse)"; FAIL=1; }
grep -q 'plan-ambiguo' "$M/_plans-index.md" || { echo "  FAIL: el plan nuevo no aparece"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 5: ambiguo (2 tablas candidatas) pero la fila YA EXISTE en una de las viejas — se actualiza ahi, no se duplica (hallazgo del adversario, ronda 2) =="
rm -rf "$M/.journal"
cat > "$M/_plans-index.md" <<'EOF'
---
type: index
---
# Planes

## Active Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| [[plans/plan-existente\|Plan existente]] | active | 2026-01-01 | | | |

## Lifecycle

## Completed Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| plan viejo completado | completed | 2026-01-02 | | | |

## Related
EOF
python3 bin/journal-emit.py --type plan.upsert --slug existente --title "Plan existente" --status completed --date 2026-03-05 >/dev/null
OUT=$(python3 bin/journal-compact.py --quiet 2>&1)
echo "  compact: $OUT"
echo "$OUT" | grep -q 'quarantined=0' || { echo "  FAIL: se cuarenteno"; FAIL=1; }
N=$(grep -c 'plan-existente' "$M/_plans-index.md")
[ "$N" = "1" ] || { echo "  FAIL: la fila se duplico entre las dos tablas ambiguas (aparece $N veces, se esperaba 1)"; FAIL=1; }
grep -q '| \[\[plans/plan-existente\\|Plan existente\]\] | completed |' "$M/_plans-index.md" || { echo "  FAIL: no se actualizo el status a completed"; FAIL=1; }
grep -q 'plan viejo completado' "$M/_plans-index.md" || { echo "  FAIL: la otra tabla vieja se toco de mas"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 6: el fallback por titulo plano NO cruza a una tabla ajena del mismo ancho (ronda 3 del adversario) =="
rm -rf "$M/.journal"
cat > "$M/_plans-index.md" <<'EOF'
---
type: index
---
# Planes

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|

## Inventory

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| Same Title | active | 2020-01-01 | | | |

## Related
EOF
python3 bin/journal-emit.py --type plan.upsert --slug nuevo-inline --title "Same Title" --status active --date 2026-03-06 --inline >/dev/null
OUT=$(python3 bin/journal-compact.py --quiet 2>&1)
echo "  compact: $OUT"
echo "$OUT" | grep -q 'quarantined=0' || { echo "  FAIL: se cuarenteno"; FAIL=1; }
N=$(grep -c 'Same Title' "$M/_plans-index.md")
[ "$N" = "2" ] || { echo "  FAIL: se esperaban 2 apariciones de 'Same Title' (una en cada tabla), salieron $N"; FAIL=1; }
INV_UNTOUCHED=$(grep -A4 '^## Inventory$' "$M/_plans-index.md" | grep -c '2020-01-01')
[ "$INV_UNTOUCHED" = "1" ] || { echo "  FAIL: la fila de la tabla ajena 'Inventory' se toco"; FAIL=1; }
PLANS_NEW=$(sed -n '/^## Plans$/,/^## Inventory$/p' "$M/_plans-index.md" | grep -c 'Same Title (inline)')
[ "$PLANS_NEW" = "1" ] || { echo "  FAIL: no se inserto la fila nueva en '## Plans' (se enganchó a Inventory en vez de insertar)"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 7: filas de tabla HUERFANAS (sin cabecera ni separador) -> cuarentena, no auto-crear (hallazgo del adversario, ronda 4, sobre paperclip real) =="
rm -rf "$M/.journal"
cat > "$M/_plans-index.md" <<'EOF'
---
type: index
---
# Planes

| plan huerfano viejo | active | 2025-01-01 | | | |
| otro plan huerfano | completed | 2025-01-02 | | | |

## Related
EOF
python3 bin/journal-emit.py --type plan.upsert --slug nuevo-sobre-huerfanas --title "Plan nuevo" --status active --date 2026-03-07 >/dev/null
OUT=$(python3 bin/journal-compact.py --quiet 2>&1)
echo "  compact: $OUT"
echo "$OUT" | grep -q 'quarantined=1' || { echo "  FAIL: no se cuarenteno (se esperaba, por las filas huerfanas)"; FAIL=1; }
grep -q '^## Plans$' "$M/_plans-index.md" && { echo "  FAIL: se creo '## Plans' de todos modos, sobre datos huerfanos"; FAIL=1; }
REASON_FILE=$(ls "$M/.journal/quarantine"/*.reason 2>/dev/null | head -1)
[ -n "$REASON_FILE" ] && grep -q 'fila(s) de tabla sin cabecera reconocible' "$REASON_FILE" || { echo "  FAIL: el motivo de cuarentena no menciona las filas huerfanas"; FAIL=1; }
[ "$FAIL" = 0 ] && echo "  ok"

echo "RESULT: $([ "$FAIL" = 0 ] && echo PASS || echo FAIL)"
[ "$FAIL" = 0 ]
