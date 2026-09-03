#!/bin/bash
# Regresiones de bin/normalize-pendientes.py (v2.12.1): anade SOLO los headers de prioridad que
# faltan en _pendientes.md, en el sitio correcto, sin tocar items ni secciones; idempotente.
#
# Casos:
#   1. canonico completo                 -> byte a byte identico, headers_added=0
#   2. variantes que el compactador acepta (`## Alta Prioridad`, `## Media`, `## baja — nuevos`)
#                                        -> identico, headers_added=0
#   3. solo `## Abiertos` + Como usar arriba + Related abajo (unifi-expert)
#                                        -> 3 headers antes de Related, items intactos, Abiertos intacto
#   4. secciones por tema, sin Related (seo)  -> 3 headers al final
#   5. falta solo Baja (Vecinex)          -> Baja despues de la seccion Media, antes de Como usar
#   6. falta solo Alta                    -> Alta justo antes de Media
#   7. faltan Media y Baja                -> ambos tras la seccion Alta, en orden
#   8. archivo inexistente                -> exit 0, headers_added=0
#   9. dry-run sin --apply                -> no escribe
#  10. idempotencia: segunda corrida sobre el caso 3 -> identico, headers_added=0
#  11. lock ocupado (journal/.lock reciente) -> no escribe, exit 0, mensaje busy
#  12. tras normalizar el caso 3, un pendiente.add compacta sin cuarentena (fin a fin)
#  13. archivo CRLF (Windows): se anade el header y TODAS las lineas siguen terminando en CRLF
#  14. headers existentes desordenados (Baja antes de Alta, falta Media): se anade Media una sola
#      vez tras la seccion de Alta, nada se reordena, items intactos
#
# Uso: bash bin/test-normalize-pendientes.sh   (sin dependencias; sale != 0 si algo falla)

set -u
cd "$(dirname "$0")/.." || exit 1
BIN="$PWD/bin"
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp fallo"; exit 1; }
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
items() { grep -c '^- \[ \]' "$1"; }
canon() { grep -cE '^## (Alta|Media|Baja) prioridad$' "$1"; }   # -E: la alternancia BRE \| no es portable (BSD grep)
mk() { mkdir -p "$T/$1"; printf -- "$2" > "$T/$1/_pendientes.md"; }
run() { python3 "$BIN/normalize-pendientes.py" "$T/$1" --apply; }

echo "1 canonico:"
mk c1 '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n- [ ] a\n\n## Media prioridad\n\n- [ ] b\n\n## Baja prioridad\n\n## Related\n- [[x]]\n'
cp "$T/c1/_pendientes.md" "$T/c1.orig"; OUT=$(run c1)
[ "$OUT" = "headers_added=0" ] && cmp -s "$T/c1.orig" "$T/c1/_pendientes.md" && ok || fail "canonico: '$OUT'"

echo "2 variantes aceptadas:"
mk c2 '# Pendientes\n\n## Alta Prioridad\n\n- [ ] a\n\n## Media\n\n- [ ] b\n\n## baja — nuevos\n\n- [ ] c\n'
cp "$T/c2/_pendientes.md" "$T/c2.orig"; OUT=$(run c2)
[ "$OUT" = "headers_added=0" ] && cmp -s "$T/c2.orig" "$T/c2/_pendientes.md" && ok || fail "variantes: '$OUT'"

echo "3 solo Abiertos (unifi-expert):"
mk c3 '---\ntype: index\n---\n# Pendientes\n\n## Como usar\n- texto\n\n## Abiertos\n\n- [ ] uno\n- [ ] dos\n- [ ] tres\n\n## Related\n- [[_session-index]]\n'
OUT=$(run c3); F="$T/c3/_pendientes.md"
[ "$OUT" = "headers_added=3 (Alta prioridad, Media prioridad, Baja prioridad)" ] || fail "abiertos out: '$OUT'"
[ "$(canon "$F")" = 3 ] && [ "$(items "$F")" = 3 ] && grep -q '^## Abiertos$' "$F" && grep -q '^## Como usar$' "$F" && ok || fail "abiertos: headers/items"
# orden y posicion: Alta < Media < Baja < Related, todos despues de Abiertos
A=$(grep -n '^## Alta prioridad$' "$F" | cut -d: -f1); M=$(grep -n '^## Media prioridad$' "$F" | cut -d: -f1)
B=$(grep -n '^## Baja prioridad$' "$F" | cut -d: -f1); R=$(grep -n '^## Related$' "$F" | cut -d: -f1); AB=$(grep -n '^## Abiertos$' "$F" | cut -d: -f1)
[ "$AB" -lt "$A" ] && [ "$A" -lt "$M" ] && [ "$M" -lt "$B" ] && [ "$B" -lt "$R" ] && ok || fail "abiertos orden: Abiertos=$AB A=$A M=$M B=$B R=$R"
# la linea 'tres' sigue pegada a su seccion (ningun header se metio en medio de los items)
sed -n "$AB,$((A-1))p" "$F" | grep -q '^- \[ \] tres$' && ok || fail "abiertos: items partidos"
[ "$(awk 'BEGIN{b=0;m=0} /^$/{b++; if(b>m)m=b; next} {b=0} END{print m}' "$F")" -le 1 ] && ok || fail "abiertos: lineas en blanco dobles"

echo "4 por tema, sin Related (seo):"
mk c4 '# Pendientes\n\n## Daily 2026-08-07\n\n- [ ] x\n\n## Weekly W34\n\n- [ ] y\n'
OUT=$(run c4); F="$T/c4/_pendientes.md"
[ "$(canon "$F")" = 3 ] && [ "$(items "$F")" = 2 ] && [ "$(tail -c 1 "$F" | od -An -c | tr -d ' ')" = '\n' ] && [ "$(grep -n '^## Baja prioridad$' "$F" | cut -d: -f1)" -gt "$(grep -n '^## Weekly W34$' "$F" | cut -d: -f1)" ] && ok || fail "seo: '$OUT'"

echo "5 falta Baja (Vecinex):"
mk c5 '# Pendientes\n\n## Alta prioridad\n\n- [ ] a\n\n## Media prioridad\n\n- [ ] b1\n- [ ] b2\n\n## Como usar\n- texto\n\n## Related\n- [[x]]\n'
OUT=$(run c5); F="$T/c5/_pendientes.md"
[ "$OUT" = "headers_added=1 (Baja prioridad)" ] || fail "vecinex out: '$OUT'"
B=$(grep -n '^## Baja prioridad$' "$F" | cut -d: -f1); CU=$(grep -n '^## Como usar$' "$F" | cut -d: -f1); B2=$(grep -n '^- \[ \] b2$' "$F" | cut -d: -f1)
[ "$B2" -lt "$B" ] && [ "$B" -lt "$CU" ] && [ "$(items "$F")" = 3 ] && ok || fail "vecinex pos: b2=$B2 B=$B CU=$CU"

echo "6 falta Alta:"
mk c6 '# Pendientes\n\n## Media prioridad\n\n- [ ] b\n\n## Baja prioridad\n\n- [ ] c\n'
OUT=$(run c6); F="$T/c6/_pendientes.md"
A=$(grep -n '^## Alta prioridad$' "$F" | cut -d: -f1); M=$(grep -n '^## Media prioridad$' "$F" | cut -d: -f1)
[ "$OUT" = "headers_added=1 (Alta prioridad)" ] && [ "$A" -lt "$M" ] && [ "$((M - A))" -le 2 ] && ok || fail "alta: '$OUT' A=$A M=$M"

echo "7 faltan Media y Baja:"
mk c7 '# Pendientes\n\n## Alta prioridad\n\n- [ ] a1\n- [ ] a2\n\n## Related\n- [[x]]\n'
OUT=$(run c7); F="$T/c7/_pendientes.md"
A2=$(grep -n '^- \[ \] a2$' "$F" | cut -d: -f1); M=$(grep -n '^## Media prioridad$' "$F" | cut -d: -f1); B=$(grep -n '^## Baja prioridad$' "$F" | cut -d: -f1); R=$(grep -n '^## Related$' "$F" | cut -d: -f1)
[ "$OUT" = "headers_added=2 (Media prioridad, Baja prioridad)" ] && [ "$A2" -lt "$M" ] && [ "$M" -lt "$B" ] && [ "$B" -lt "$R" ] && ok || fail "media+baja: '$OUT' a2=$A2 M=$M B=$B R=$R"

echo "8 inexistente:"
mkdir -p "$T/c8"; OUT=$(run c8); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "headers_added=0 (sin _pendientes.md)" ] && ok || fail "inexistente: rc=$RC '$OUT'"

echo "9 dry-run:"
mk c9 '# Pendientes\n\n## Abiertos\n\n- [ ] x\n'
cp "$T/c9/_pendientes.md" "$T/c9.orig"; OUT=$(python3 "$BIN/normalize-pendientes.py" "$T/c9")
echo "$OUT" | grep -q '^headers_added=3 .*dry-run' && cmp -s "$T/c9.orig" "$T/c9/_pendientes.md" && ok || fail "dry-run: '$OUT'"

echo "10 idempotencia (caso 3 otra vez):"
cp "$T/c3/_pendientes.md" "$T/c3.after"; OUT=$(run c3)
[ "$OUT" = "headers_added=0" ] && cmp -s "$T/c3.after" "$T/c3/_pendientes.md" && ok || fail "idempotencia: '$OUT'"

echo "11 lock ocupado:"
mk c11 '# Pendientes\n\n## Abiertos\n\n- [ ] x\n'
mkdir -p "$T/c11/.journal/.lock"; date +%s > "$T/c11/.journal/.lock/acquired_at"; echo other > "$T/c11/.journal/.lock/owner"
cp "$T/c11/_pendientes.md" "$T/c11.orig"; OUT=$(python3 "$BIN/normalize-pendientes.py" "$T/c11" --apply --budget 0.3); RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'busy' && cmp -s "$T/c11.orig" "$T/c11/_pendientes.md" && [ -d "$T/c11/.journal/.lock" ] && ok || fail "lock: rc=$RC '$OUT'"

echo "12 fin a fin: pendiente.add tras normalizar el caso 3:"
export MEMORY_DIR="$T/c3"
python3 "$BIN/journal-emit.py" --type pendiente.add --text "nuevo tras normalizar" --prioridad Baja --origen "[[sessions/test]]" >/dev/null \
  && OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$T/c3")
echo "$OUT" | grep -q '^JOURNAL applied=1 quarantined=0 pending_left=0' && grep -q '^- \[ \] nuevo tras normalizar' "$T/c3/_pendientes.md" && ok || fail "fin a fin: '$OUT'"
# control: la misma emision sobre un archivo sin normalizar SI va a cuarentena
mk c12 '# Pendientes\n\n## Abiertos\n\n- [ ] x\n'; export MEMORY_DIR="$T/c12"
python3 "$BIN/journal-emit.py" --type pendiente.add --text "sin header" --prioridad Baja --origen "[[sessions/test]]" >/dev/null \
  && OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$T/c12")
echo "$OUT" | grep -q 'quarantined=1' && ok || fail "control cuarentena: '$OUT'"
unset MEMORY_DIR

echo "13 CRLF:"
mkdir -p "$T/c13"; printf '# Pendientes\r\n\r\n## Abiertos\r\n\r\n- [ ] x\r\n\r\n## Related\r\n- [[x]]\r\n' > "$T/c13/_pendientes.md"
OUT=$(run c13); F="$T/c13/_pendientes.md"
NL=$(tr -cd '\n' < "$F" | wc -c | tr -d ' '); CR=$(tr -cd '\r' < "$F" | wc -c | tr -d ' ')
[ "$OUT" = "headers_added=3 (Alta prioridad, Media prioridad, Baja prioridad)" ] && [ "$NL" = "$CR" ] && [ "$NL" -gt 8 ] && [ "$(canon "$F")" = 0 ] && [ "$(grep -c $'^## Alta prioridad\r$' "$F")" = 1 ] && ok || fail "crlf: '$OUT' nl=$NL cr=$CR"

echo "14 desordenados (Baja antes de Alta, falta Media):"
mk c14 '# Pendientes\n\n## Baja prioridad\n\n- [ ] c\n\n## Alta prioridad\n\n- [ ] a1\n- [ ] a2\n\n## Related\n- [[x]]\n'
cp "$T/c14/_pendientes.md" "$T/c14.orig"; OUT=$(run c14); F="$T/c14/_pendientes.md"
A2=$(grep -n '^- \[ \] a2$' "$F" | cut -d: -f1); M=$(grep -n '^## Media prioridad$' "$F" | cut -d: -f1); R=$(grep -n '^## Related$' "$F" | cut -d: -f1)
[ "$OUT" = "headers_added=1 (Media prioridad)" ] && [ "$(grep -c '^## Media prioridad$' "$F")" = 1 ] && [ "$A2" -lt "$M" ] && [ "$M" -lt "$R" ] && [ "$(items "$F")" = 3 ] \
  && [ "$(grep -v '^## Media prioridad$' "$F" | awk 'NR>1 || 1' | grep -c .)" = "$(grep -c . "$T/c14.orig")" ] && ok || fail "desordenados: '$OUT' a2=$A2 M=$M R=$R"
# solo se anadieron lineas: el original es subsecuencia del resultado (diff sin lineas '<')
[ "$(diff "$T/c14.orig" "$F" | grep -c '^<')" = 0 ] && ok || fail "desordenados: se borro o cambio alguna linea"

echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
