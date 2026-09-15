#!/usr/bin/env bash
# Pruebas de check-active-plans.py (v2.25.4, p-<pendiente-plan-linkage>): el recordatorio de
# checkpoint-3t Step 3-pre que lista los planes active/draft/testing ANTES de que el agente
# escriba "## Plans: Ninguno" — para que un pendiente que nace auditando la fase de un plan no
# se cierre suelto sin conectarlo (incidente real 2026-09-15, este mismo repo: p-d72c123065 vs
# plan-hallazgos-piloto-2.25.0).
#
# Lo que estas pruebas defienden:
#   A. sin _plans-index.md, o sin ningun plan active/draft/testing, no imprime nada (silencioso);
#   B. un plan completed/superseded NO cuenta — solo active/draft/testing;
#   C. "active (fase de plan-X)" (sufijo tras el status) SI cuenta — se compara solo la primera
#      palabra del status, igual que el resto del plugin;
#   D. el titulo con wikilink-alias (`[[plans/plan-x\|Titulo bonito]]`) se imprime "Titulo bonito",
#      no la ruta cruda — el mismo caso real que trae _plans-index.md de este repo;
#   E. --count devuelve solo el numero, para uso en otros scripts/hooks;
#   F. un `\|` DENTRO de una celda (el alias del wikilink) no se confunde con el separador de
#      columnas de la tabla — sin esto, la fila entera se desalinea.
#
# Uso: test-check-active-plans.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

correr() { python3 "$BIN/check-active-plans.py" "$1" ${2:-}; }

echo "1. sin _plans-index.md, silencioso y --count da 0"
P1="$TMP/p1/memory"; mkdir -p "$P1"
check "sin salida" "$(correr "$P1")" ""
check "count=0" "$(correr "$P1" --count)" "0"

echo "2. sin ningun plan active/draft/testing (solo completed/superseded), silencioso"
P2="$TMP/p2/memory"; mkdir -p "$P2"
cat > "$P2/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| Old thing | completed | 2026-01-01 |  |  |  |
| Superseded thing | superseded — reemplazado por otro | 2026-01-01 |  |  |  |

## Related
EOF
check "sin salida" "$(correr "$P2")" ""
check "count=0" "$(correr "$P2" --count)" "0"

echo "3. active/draft/testing SI cuentan, incluido el sufijo (fase de plan-X); completed no se cuela"
P3="$TMP/p3/memory"; mkdir -p "$P3"
cat > "$P3/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| [[plans/plan-hallazgos-piloto-2.25.0\|Cerrar los hallazgos colaterales del piloto de 2.25.0]] | active | 2026-09-14 | [[sessions/x]] | 2 |  |
| [[plans/plan-hijo-x\|Hijo suelto]] | active (fase de plan-hallazgos-piloto-2.25.0) | 2026-09-14 |  |  |  |
| Bloque A | draft | 2026-09-12 |  |  |  |
| Ya cerrado | completed | 2026-01-01 |  |  |  |

## Related
EOF
OUT3="$(correr "$P3")"
check "count=3" "$(correr "$P3" --count)" "3"
check "titulo de-linkeado, no la ruta cruda" \
  "$(printf '%s' "$OUT3" | grep -c 'Cerrar los hallazgos colaterales del piloto de 2.25.0 (active)')" "1"
check "no imprime la ruta cruda plans/plan-hallazgos" \
  "$(printf '%s' "$OUT3" | grep -c 'plans/plan-hallazgos')" "0"
check "el sufijo (fase de plan-X) SI cuenta" \
  "$(printf '%s' "$OUT3" | grep -c 'Hijo suelto (active (fase de plan-hallazgos-piloto-2.25.0))')" "1"
check "draft tambien cuenta" "$(printf '%s' "$OUT3" | grep -c 'Bloque A (draft)')" "1"
check "completed NO aparece" "$(printf '%s' "$OUT3" | grep -c 'Ya cerrado')" "0"
check "trae el recordatorio de Plans: Ninguno" \
  "$(printf '%s' "$OUT3" | grep -c 'Plans: Ninguno')" "1"

echo "4. un \\| dentro de una celda (alias del wikilink) no desalinea la fila"
P4="$TMP/p4/memory"; mkdir -p "$P4"
cat > "$P4/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| [[plans/plan-x\|Titulo con \| pipe crudo dentro]] | active | 2026-09-14 |  |  |  |

## Related
EOF
check "count=1 (la fila no se parte en mas columnas de las que tiene)" "$(correr "$P4" --count)" "1"

echo "5. un _plans-index.md ILEGIBLE (no inexistente) avisa, no se confunde con 'sin planes'"
# Hallazgo de un adversario externo (ronda 2): un solo 'except Exception' trataba "no existe" y
# "existe pero no se pudo leer" IGUAL — silencio en los dos casos. Aqui _plans-index.md es un
# DIRECTORIO en vez de un archivo, asi que abrirlo lanza IsADirectoryError — cualquier excepcion
# que NO sea FileNotFoundError debe avisar por stderr y salir con rc!=0, nunca contar como "0
# planes" silencioso.
P5="$TMP/p5/memory"; mkdir -p "$P5"
mkdir -p "$P5/_plans-index.md"
python3 "$BIN/check-active-plans.py" "$P5" >"$TMP/o5.out" 2>"$TMP/o5.err"; RC5=$?
check "sale con error (no exit 0 silencioso)" "$([ "$RC5" -ne 0 ] && echo si || echo no)" "si"
check "avisa por stderr, no se calla" "$(grep -c 'no se pudo leer' "$TMP/o5.err")" "1"
check "stdout normal queda vacio (no imprime un 0 disfrazado de conteo)" "$([ -s "$TMP/o5.out" ] && echo tiene || echo vacio)" "vacio"
RC5B=0
python3 "$BIN/check-active-plans.py" "$P5" --count >"$TMP/o5b.out" 2>/dev/null || RC5B=$?
check "--count tambien sale con error, no imprime 0" "$([ "$RC5B" -ne 0 ] && echo si || echo no)" "si"
check "--count no imprime un 0 que se confunda con 'sin planes'" "$(grep -c '^0$' "$TMP/o5b.out")" "0"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
