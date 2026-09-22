#!/bin/bash
# Regresion: journal-compact.py repara la tabla '## Sessions' de una instalacion vieja con cabecera
# de 4 columnas (sin 'Commit'). v2.31.4.
#
# Motivacion real: Will-Ops (2026-09-21, hallazgo de Codex). Con 4 columnas, find_row_anywhere
# (que exige 5) no encontraba la fila de la sesion y cada session.add insertaba otra: dos filas por
# sesion, y la poda de MAX_SESSIONS (cuenta filas) dejaba el indice en 5 sesiones en vez de 10.
#
# Casos:
#   1. Cabecera de 4: el segundo session.add de la misma sesion actualiza la fila, no inserta otra.
#   2. Duplicados ya existentes (la forma exacta de Will-Ops): el siguiente session.add, de OTRA
#      sesion, los junta — gana la fila de arriba celda por celda, sin perder el commit.
#   3. La poda cuenta sesiones de verdad: 12 sesiones duplicadas -> quedan las 10 mas nuevas.
#   4. Idempotencia: compactar un evento sin cambios no vuelve a escribir el archivo.
#   5. Tabla de 5 sin duplicados: solo entra la fila nueva, nada mas cambia.
#   6. Lo que no es la forma de este bug no se toca: cabecera de 3 (ni su cabecera ni sus filas
#      repetidas), grupo con fila de 6 celdas.
#   7. Dos sesiones DISTINTAS cuyo Resumen cita la misma sesion no se juntan: la sesion se lee de
#      la celda Sesion, no del resto de la fila (ronda 1 de adversario, unsafe).
#   8. Tabla en orden ascendente (forma de Vecinex): el duplicado que el bug inserto arriba gana,
#      aunque el resto de la tabla vaya de vieja a nueva.
#   9. Un session.add para una sesion que otra fila CITA en su Resumen (forma de unifi-expert,
#      con la fila que cita ARRIBA) actualiza la fila de la sesion, no la que la cita (ronda 2).
#   10. Tabla de 4 columnas (forma vieja, por nombre) bajo OTRO titulo: se adopta como
#       '## Sessions', gana Commit y el session.add de una sesion que ya tenia fila la actualiza
#       (antes: tabla nueva vacia al lado y fila duplicada, limite declarado en 2.31.4). Una
#       tabla de 4 con otros nombres no se adopta, y una de 5 sigue ganando a una de 4.
#   11. DOS tablas de 4 con la cabecera vieja y ninguna de 5: cuarentena, archivo intacto (antes:
#       tabla nueva vacia y la sesion duplicada; ronda 1 de adversario de 2.31.5).
#
# Uso: bash bin/test-session-index-heal.sh    (sin dependencias; sale != 0 si algo falla)

set -u
cd "$(dirname "$0")/.." || exit 1
M=$(mktemp -d) && [ -d "$M" ] || { echo "mktemp fallo"; exit 1; }
export MEMORY_DIR=$M; FAIL=0
trap 'rm -rf "$M"' EXIT
IDX="$M/_session-index.md"

fail() { echo "  FAIL: $1"; FAIL=1; }
emit() { python3 bin/journal-emit.py --type session.add "$@" >/dev/null || fail "emit $*"; }
compact() {   # --quiet no imprime nada si no hubo nada que aplicar; falla solo con cuarentena real
  python3 bin/journal-compact.py --quiet 2>&1 | grep -q 'quarantined=[1-9]' && fail "compactar cuarenteno"
  [ -z "$(ls -A "$M/.journal/quarantine" 2>/dev/null)" ] || fail "quarantine/ no esta vacio"
}
rows_of() { grep -cF "[[sessions/$1\\|" "$IDX"; }
head4() { printf -- '---\ntype: index\n---\n# Session Index\n\n## Sessions\n\n| Fecha | Sesión | Status | Resumen |\n|---|---|---|---|\n' > "$IDX"; }
tail_conv() { printf '\n## Convención\n\n- texto que no se toca\n' >> "$IDX"; }

echo "== caso 1: cabecera de 4, dos session.add de la misma sesion =="
rm -rf "$M/.journal"; head4; tail_conv
emit --slug 2026-09-21-una --date 2026-09-21 --status "con pendientes" --summary "resumen"
compact
emit --slug 2026-09-21-una --date 2026-09-21 --commit '`abc1234`'
compact
[ "$(rows_of 2026-09-21-una)" = 1 ] || fail "esperaba 1 fila, hay $(rows_of 2026-09-21-una)"
grep -q '^| Fecha | Sesión | Status | Resumen | Commit |$' "$IDX" || fail "la cabecera no gano 'Commit'"
grep -q '^|---|---|---|---|---|$' "$IDX" || fail "el separador no gano su quinta celda"
grep -q 'una\]\] | con pendientes | resumen | `abc1234` |$' "$IDX" || fail "la fila no quedo completa"
grep -q 'texto que no se toca' "$IDX" || fail "se perdio contenido fuera de la tabla"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 2: duplicados existentes (forma de Will-Ops) =="
rm -rf "$M/.journal"; head4
{
  echo '| 2026-09-19 | [[sessions/2026-09-19-b\|b]] |  |  | `bbb2222` |'
  echo '| 2026-09-19 | [[sessions/2026-09-19-b\|b]] | con pendientes | resumen b |  |'
  echo '| 2026-09-18 | [[sessions/2026-09-18-a\|a]] |  |  | `aaa1111` |'
  echo '| 2026-09-18 | [[sessions/2026-09-18-a\|a]] | completada | resumen a viejo |  |'
  echo '| 2026-09-18 | [[sessions/2026-09-18-a\|a]] | con pendientes |  |  |'
  echo '| 2026-09-17 | [[sessions/2026-09-17-sola\|sola]] | completada | sola | `ccc3333` |'
} >> "$IDX"; tail_conv
emit --slug 2026-09-21-nueva --date 2026-09-21 --status completada --summary "nueva"
compact
for s in 2026-09-19-b 2026-09-18-a 2026-09-17-sola 2026-09-21-nueva; do
  [ "$(rows_of $s)" = 1 ] || fail "$s: esperaba 1 fila, hay $(rows_of $s)"
done
grep -q 'b\]\] | con pendientes | resumen b | `bbb2222` |$' "$IDX" || fail "b no se junto bien"
# a: 'completada' (fila del medio) esta ARRIBA de 'con pendientes' (la de abajo) -> gana 'completada'
grep -q 'a\]\] | completada | resumen a viejo | `aaa1111` |$' "$IDX" || fail "a no se junto bien: $(grep 'sessions/2026-09-18-a' "$IDX")"
ORDEN=$(grep -o 'sessions/2026-09-[0-9]*-[a-z]*' "$IDX" | tr '\n' ' ')
[ "$ORDEN" = "sessions/2026-09-21-nueva sessions/2026-09-19-b sessions/2026-09-18-a sessions/2026-09-17-sola " ] \
  || fail "orden inesperado: $ORDEN"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 3: la poda cuenta sesiones, no filas =="
rm -rf "$M/.journal"; head4
for d in 12 11 10 09 08 07 06 05 04 03 02 01; do
  echo "| 2026-08-$d | [[sessions/2026-08-$d-s\\|s]] |  |  | \`h$d\` |" >> "$IDX"
  echo "| 2026-08-$d | [[sessions/2026-08-$d-s\\|s]] | completada | r$d |  |" >> "$IDX"
done
emit --slug 2026-08-13-s --date 2026-08-13 --status completada --summary r13
compact
N=$(grep -c '^| 2026-08-' "$IDX")
[ "$N" = 10 ] || fail "esperaba 10 filas, hay $N"
grep -q '2026-08-04-s' "$IDX" || fail "la 10a sesion mas nueva (08-04) se podo"
grep -q '2026-08-03-s' "$IDX" && fail "la 11a (08-03) debio podarse"
grep -q '2026-08-05-s\\|s\]\] | completada | r05 | `h05` |' "$IDX" || fail "08-05 no quedo junta"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 4: idempotencia =="
BEFORE=$(cksum < "$IDX")
emit --slug 2026-08-13-s --date 2026-08-13 --status completada --summary r13
compact
[ "$(cksum < "$IDX")" = "$BEFORE" ] || fail "un evento sin cambios reescribio el archivo"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 5: tabla de 5 sin duplicados =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Sessions\n\n| Fecha | Sesion | Status | Resumen | Commit |\n|:---|---|---|---|---|\n| 2026-09-01 | [[sessions/2026-09-01-x\\|x]] | completada | x |  |\n' > "$IDX"
cp "$IDX" "$M/antes"
emit --slug 2026-09-02-y --date 2026-09-02 --status completada --summary y
compact
DIFF=$(diff "$M/antes" "$IDX" | grep '^[<>]')
[ "$DIFF" = '> | 2026-09-02 | [[sessions/2026-09-02-y\|y]] | completada | y |  |' ] || fail "cambio algo mas que la fila nueva: $DIFF"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 6: formas ajenas al bug no se tocan =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Sessions\n\n| Fecha | Sesion | Resumen |\n|---|---|---|\n' > "$IDX"
emit --slug 2026-09-03-z --date 2026-09-03 --summary z
compact
grep -q '^| Fecha | Sesion | Resumen |$' "$IDX" || fail "una cabecera de 3 se ensancho"
rm -rf "$M/.journal"; head4
{
  echo '| 2026-09-04 | [[sessions/2026-09-04-w\|w]] |  |  | `w1` | extra |'
  echo '| 2026-09-04 | [[sessions/2026-09-04-w\|w]] | completada | w |  |'
} >> "$IDX"
emit --slug 2026-09-05-v --date 2026-09-05 --summary v
compact
[ "$(rows_of 2026-09-04-w)" = 2 ] || fail "un grupo con fila de 6 celdas se junto"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 6b: filas repetidas bajo cabecera de 3 no se juntan =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Sessions\n\n| Fecha | Sesion | Resumen |\n|---|---|---|\n| 2026-09-06 | [[sessions/2026-09-06-t\\|t]] | uno |\n| 2026-09-06 | [[sessions/2026-09-06-t\\|t]] | dos |\n' > "$IDX"
emit --slug 2026-09-07-u --date 2026-09-07 --summary u
compact
[ "$(rows_of 2026-09-06-t)" = 2 ] || fail "filas repetidas bajo cabecera de 3 se juntaron"
grep -q 't\]\] | uno |$' "$IDX" || fail "una fila bajo cabecera de 3 se altero"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 7: dos sesiones que citan la misma sesion en el Resumen =="
rm -rf "$M/.journal"; head4
{
  echo '| 2026-09-10 | sesion-p (sin enlace) | completada | sigue a [[sessions/2026-09-01-ref]] | `p1` |'
  echo '| 2026-09-09 | sesion-q (sin enlace) | completada | tambien cita [[sessions/2026-09-01-ref]] | `q1` |'
} >> "$IDX"
emit --slug 2026-09-11-r --date 2026-09-11 --summary r
compact
grep -q '^| 2026-09-10 | sesion-p (sin enlace) | completada | sigue a \[\[sessions/2026-09-01-ref\]\] | `p1` |$' "$IDX" || fail "p se altero o desaparecio"
grep -q '^| 2026-09-09 | sesion-q (sin enlace) | completada | tambien cita \[\[sessions/2026-09-01-ref\]\] | `q1` |$' "$IDX" || fail "q desaparecio (se junto con p por el enlace del Resumen)"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 8: tabla ascendente (forma de Vecinex) con un duplicado del bug arriba =="
rm -rf "$M/.journal"; head4
{
  echo '| 2026-03-22 | [[sessions/2026-03-22-k\|k]] |  |  | `k99` |'
  echo '| 2026-03-21 | [[sessions/2026-03-21-j\|j]] | completada | j | |'
  echo '| 2026-03-22 | [[sessions/2026-03-22-k\|k]] | con pendientes | k viejo | `k00` |'
  echo '| 2026-03-29 | [[sessions/2026-03-29-l\|l]] | completada | l | |'
} >> "$IDX"
emit --slug 2026-09-12-m --date 2026-09-12 --summary m
compact
[ "$(rows_of 2026-03-22-k)" = 1 ] || fail "k no se junto"
grep -q 'k\]\] | con pendientes | k viejo | `k99` |$' "$IDX" || fail "k: gano el commit viejo: $(grep 'sessions/2026-03-22-k' "$IDX")"
ORDEN=$(grep -o 'sessions/2026-0[39]-[0-9]*-[a-z]' "$IDX" | tr '\n' ' ')
[ "$ORDEN" = "sessions/2026-09-12-m sessions/2026-03-22-k sessions/2026-03-21-j sessions/2026-03-29-l " ] || fail "orden: $ORDEN"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 9: el Resumen de otra fila cita la sesion (forma de unifi-expert) =="
rm -rf "$M/.journal"; head4
{
  echo '| 2026-08-02 | [[sessions/2026-08-02-build]] | completada | validacion completada en [[sessions/2026-08-02-skill]] | `2af581f` |'
  echo '| 2026-08-02 | [[sessions/2026-08-02-skill]] | completada | skill construido | `b827493` |'
} >> "$IDX"
emit --slug 2026-08-02-skill --date 2026-08-02 --commit '`c0ffee1`'
compact
grep -q '^| 2026-08-02 | \[\[sessions/2026-08-02-build\]\] | completada | validacion completada en \[\[sessions/2026-08-02-skill\]\] | `2af581f` |$' "$IDX" \
  || fail "la fila que cita se altero: $(grep 'sessions/2026-08-02-build' "$IDX")"
grep -q '^| 2026-08-02 | \[\[sessions/2026-08-02-skill\]\] | completada | skill construido | `c0ffee1` |$' "$IDX" \
  || fail "la fila de la sesion no recibio el commit: $(grep '^| 2026-08-02 | \[\[sessions/2026-08-02-skill' "$IDX")"
[ "$(grep -c '^| 2026-08-02 ' "$IDX")" = 2 ] || fail "cambio el numero de filas"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 10: tabla de 4 bajo otro titulo =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n# Session Index\n\n## Historial\n\n| Fecha | Sesión | Status | Resumen |\n|---|---|---|---|\n| 2026-09-20 | [[sessions/2026-09-20-h\\|h]] | con pendientes | h |\n\n## Convención\n\n- x\n' > "$IDX"
emit --slug 2026-09-20-h --date 2026-09-20 --commit '`h0h0h0h`'
compact
[ "$(grep -c '^## Sessions$' "$IDX")" = 1 ] || fail "no quedo un solo '## Sessions'"
grep -q '^## Historial$' "$IDX" && fail "'## Historial' no se renombro"
[ "$(rows_of 2026-09-20-h)" = 1 ] || fail "h se duplico: $(rows_of 2026-09-20-h) filas"
grep -q 'h\]\] | con pendientes | h | `h0h0h0h` |$' "$IDX" || fail "h no recibio el commit: $(grep 'sessions/2026-09-20-h' "$IDX")"
grep -q '^| Fecha | Sesión | Status | Resumen | Commit |$' "$IDX" || fail "la cabecera adoptada no gano Commit"
# 4 columnas con otros nombres: no se adopta
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Notas\n\n| A | B | C | D |\n|---|---|---|---|\n| 1 | 2 | 3 | 4 |\n' > "$IDX"
emit --slug 2026-09-21-n --date 2026-09-21 --summary n
compact
grep -q '^## Notas$' "$IDX" || fail "una tabla ajena de 4 se renombro"
grep -q '^| 1 | 2 | 3 | 4 |$' "$IDX" || fail "una tabla ajena de 4 se altero"
grep -q '^| Fecha | Sesion | Status | Resumen | Commit |$' "$IDX" || fail "no se creo la tabla canonica nueva"
# una de 5 bajo otro titulo sigue ganando aunque haya una de 4 con los nombres viejos
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Viejas\n\n| Fecha | Sesion | Status | Resumen |\n|---|---|---|---|\n\n## Otra\n\n| Fecha | Sesion | Status | Resumen | Commit |\n|---|---|---|---|---|\n' > "$IDX"
emit --slug 2026-09-21-o --date 2026-09-21 --summary o
compact
grep -q '^## Viejas$' "$IDX" || fail "la de 4 se adopto habiendo una de 5"
[ "$(sed -n '/^## Sessions$/,$p' "$IDX" | grep -c 'Commit |$')" = 1 ] || fail "la de 5 no se adopto como '## Sessions'"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 11: dos tablas viejas de 4 =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## A\n\n| Fecha | Sesion | Status | Resumen |\n|---|---|---|---|\n| 2026-09-20 | [[sessions/2026-09-20-q\\|q]] | x | q |\n\n## B\n\n| Fecha | Sesion | Status | Resumen |\n|---|---|---|---|\n' > "$IDX"
cp "$IDX" "$M/antes11"
emit --slug 2026-09-20-q --date 2026-09-20 --commit '`q1`'
python3 bin/journal-compact.py --quiet >/dev/null 2>&1
cmp -s "$M/antes11" "$IDX" || fail "el archivo cambio: $(diff "$M/antes11" "$IDX" | head -3)"
grep -qs "tablas con la cabecera vieja" "$M"/.journal/quarantine/*.reason || fail "no se cuarenteno con el motivo esperado"
rm -rf "$M/.journal"
[ "$FAIL" = 0 ] && echo "  ok"

[ "$FAIL" = 0 ] && echo "PASS test-session-index-heal" || { echo "FAIL test-session-index-heal"; exit 1; }
