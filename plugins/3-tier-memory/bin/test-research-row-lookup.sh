#!/bin/bash
# Regresion: research.upsert encuentra la fila de SU research y nunca borra ni escribe la de otro.
# v2.31.5.
#
# Motivacion real (2026-09-21, medido en 12 instalaciones): find_research_row buscaba el wikilink
# `[[research/<slug>]]` en toda la fila, asi que una fila que CITABA el research pasaba por la suya:
# un update le pisaba celdas y un `completed` la BORRABA de Active. cloudflare-expert:25 lo tiene
# vivo. Tres reglas por la forma de la fila (el enlace abre la celda; un solo dueno; Archivo
# primero) rompieron una por ronda de adversario, siempre con una fila construida. La regla final
# no clasifica mejor: acota la consecuencia.
#   - Tabla cuya ultima columna es Archivo o File: solo cuenta esa ultima celda.
#   - Cualquier otra tabla (formato viejo): la busqueda de siempre, pero sus filas son de SOLO
#     LECTURA: si el evento pide cambiar o borrar una, va a cuarentena y el archivo no se toca.
#
# Casos (ultima columna Archivo/File):
#   1. Fila activa que cita X en su Next step: `completed` de X no la borra ni la toca.
#   2. Cita arriba y fila propia abajo (Completed): el update llega a la propia.
#   4. Archivo decorado (`[[research/x]] · sesion: ...`, forma de cloudflare-expert:33): se
#      actualiza, no se duplica.
#   5. `_completado:` en Archivo: se actualiza, no se duplica.
#   6. Fila `(inline)`: el fallback por titulo sigue funcionando.
#   7. La cita abre su celda (`[[research/x]] es requisito`) en la fila de otro research: no se borra.
#   8. Otro research con el MISMO titulo: el fallback por titulo no lo toma.
#   9. La fila propia de X cita otro research al inicio de su Next step: X se actualiza y se completa
#      sin duplicarse.
#  10. Fila `(inline)` de otro tema que cita X al inicio de una celda: no se borra.
#  12. Archivo vacio, o solo con `_completado:`, y una cita que abre su celda: no se borra.
#  13. Forma de cloudflare-expert:25 (Topic | Status | File, la fila de A cita a B en prosa): la
#      ultima columna es File, asi que `completed` de B no toca la fila de A y B entra en Completed.
#  15. Tabla vieja con File al final (forma de goal-spec-skill, `Topic | Started | Sesion | File`):
#      un research nuevo entra, y su `completed` lo saca de Active sin cuarentena.
#  20. Madurar de Active a Completed preserva lo que el Archivo trae mas alla del enlace desnudo
#      (decoracion, o texto plegado por repair-research-index.py) — antes se perdia siempre, la
#      fila de Completed se reconstruia desde cero (p-115356214b, v2.31.7).
#  21. Madurar defusa una marca `_completado:` REAL que ya viviera en el Archivo de una fila de
#      Active (reapertura a mano de un research previamente completado) antes de anexarla, para no
#      confundir la poda por fecha con la marca vieja.
#  22. Madurar una fila con enlace ALIASADO (`[[research/x\|alias]]`, forma usual en instalaciones
#      reales) no duplica el enlace completo en el Archivo de Completed (adversario en Opus, ronda
#      1 de v2.31.7: el primer intento solo reconocia el enlace desnudo).
#  23. Si la fila de Active Y una de Completed para el mismo slug coexisten (estado anomalo, solo
#      alcanzable a mano) al madurar, el extra de Active NO se anexa a la fila de Completed ya
#      existente — se pierde, en vez de arriesgar un duplicado que un chequeo de substring no puede
#      detectar de forma fiable (adversario en Opus, ronda 1: el primer intento de guardia por
#      substring seguia duplicando).
#  24. DECISION DE DISENO (rondas 2-4 de adversario en Opus, v2.31.7): un alias con un `]` SIN
#      escapar cae al `else` a proposito y duplica el enlace completo (visible, se limpia a mano) —
#      NO se intenta reconocerlo. Rondas 2-3 probaron reconocerlo (perezoso, luego un lookahead) y
#      las dos veces un adversario encontro una entrada donde ese reconocimiento CRUZABA a un `]]`
#      AJENO (un wikilink, un link markdown, un span de codigo, un `]]` escapado en la decoracion) y
#      perdia texto real EN SILENCIO — peor que el duplicado visible que vino a evitar. Un alias con
#      `]` legitimo y un alias mal cerrado seguido de contenido ajeno son la MISMA forma de cadena;
#      ningun regex puede distinguirlas. `[^\]]*` (excluye `]` del todo) es la unica garantia real:
#      si el alias trae CUALQUIER `]`, el match entero falla, nunca hay lectura parcial que perder.
#      Nunca visto en instalaciones reales (solo el caso hipotetico original de la ronda 2); el
#      costo (duplicado cosmetico) se acepta a cambio de la garantia que p-115356214b pide.
#  25. Un alias SIN CERRAR (falta el `]` final) seguido de decoracion con su propio wikilink no
#      pierde esa decoracion en silencio — mismo mecanismo del caso 24: el `]` sin escapar hace
#      fallar el match entero y cae al `else`, que conserva la celda COMPLETA.
#  27. Madurar conserva el Tema de la fila de Active, no el del evento (2.38.0, research.rename).
#  26. Alias sin cerrar seguido de un `]]` ESCAPADO en la decoracion (`nota \]] resto`) tampoco
#      pierde texto — la forma mas afilada que encontro el adversario en la ronda 4 (el `]]` real
#      del cierre roto y el `\]]` escapado de la decoracion son indistinguibles para cualquier
#      regex; `[^\]]*` los trata igual: ambos hacen fallar el match).
# Casos (otra ultima columna: solo lectura):
#   3. Enlace propio en la celda 0 (forma de seedance-generator, `Slug | Topic | Fecha | Sesion`):
#      no se duplica; como el evento pide cambiarla, cuarentena y archivo intacto.
#  11. Ultima columna "Related research": `completed` del research relacionado no borra la fila;
#      cuarentena.
#  14. Un evento sin cambios sobre una fila vieja no va a cuarentena (no-op).
#  16. Research nuevo cuando la tabla ANCLADA es de solo lectura: cuarentena, no se inserta con las
#      columnas cruzadas (ronda 4 de adversario de 2.31.5).
#  17. La poda no borra filas de una tabla Completed de solo lectura, y no hay cuarentena: el
#      evento no pidio podar (ronda 4).
#  18. Completar un research cuya fila vive en otra tabla no escribe el marcador de "vacia" en la
#      tabla anclada de Active si es de solo lectura (ronda 5).
#  19. Insertar en la tabla canonica de Active borra SU marcador de "vacia", no el de otra tabla de
#      solo lectura en la misma seccion (ronda 6).
#
# Uso: bash bin/test-research-row-lookup.sh    (sin dependencias; sale != 0 si algo falla)

set -u
cd "$(dirname "$0")/.." || exit 1
M=$(mktemp -d) && [ -d "$M" ] || { echo "mktemp fallo"; exit 1; }
export MEMORY_DIR=$M; FAIL=0
trap 'rm -rf "$M"' EXIT
IDX="$M/_research-index.md"
mkdir -p "$M/sessions"; printf -- '---\ntype: session\n---\n' > "$M/sessions/s.md"   # el --origen existe

fail() { echo "  FAIL: $1"; FAIL=1; }
emit() { python3 bin/journal-emit.py --type research.upsert "$@" >/dev/null || fail "emit $*"; }
compact() {
  python3 bin/journal-compact.py --quiet 2>&1 | grep -q 'quarantined=[1-9]' && fail "compactar cuarenteno"
  [ -z "$(ls -A "$M/.journal/quarantine" 2>/dev/null)" ] || fail "quarantine/ no esta vacio"
}
compact_quarantine() {   # espera cuarentena research-legacy y el archivo intacto
  cp "$IDX" "$M/antes"
  python3 bin/journal-compact.py --quiet >/dev/null 2>&1
  cmp -s "$M/antes" "$IDX" || fail "el archivo cambio: $(diff "$M/antes" "$IDX" | grep '^[<>]' | head -2)"
  grep -qs '^research-legacy:' "$M"/.journal/quarantine/*.reason || fail "no se cuarenteno con research-legacy"
}
canon() {   # $1 = filas de Active, $2 = filas de Completed, con las cabeceras canonicas
  rm -rf "$M/.journal"
  printf -- '---\ntype: index\n---\n# Research\n\n## Active Research\n\n| Tema | Next step | Origen | Archivo |\n|---|---|---|---|\n%s\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n%s\n## Related\n- [[_pendientes]]\n' "$1" "$2" > "$IDX"
}
has() { grep -qF -- "$1" "$IDX"; }
count() { grep -cF -- "$1" "$IDX"; }

echo "== caso 1: fila activa que cita X =="
CITA='| Otro tema | seguir; ver [[research/x-citado]] antes | [[sessions/s]] | [[research/otro]] |'
canon "$CITA
" ""
emit --slug x-citado --tema "X citado" --status completed --resultado "hecho" --date 2026-09-21
compact
has "$CITA" || fail "la fila que cita se borro o se altero"
has '| X citado | hecho | [[research/x-citado]] _completado: 2026-09-21_ |' || fail "X no entro en Completed"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 2: cita arriba, fila propia abajo =="
CITA2='| Y | ver [[research/x2]] tambien | [[research/y]] _completado: 2026-09-01_ |'
canon "" "$CITA2
| X2 | viejo | [[research/x2]] _completado: 2026-09-02_ |
"
emit --slug x2 --tema "X2" --status completed --resultado "nuevo" --date 2026-09-21
compact
has "$CITA2" || fail "la fila que cita se altero"
has '| X2 | nuevo | [[research/x2]] _completado: 2026-09-02_ |' || fail "la fila propia no recibio el update: $(grep 'x2\]\] _' "$IDX")"
[ "$(count '[[research/x2]] _completado')" = 1 ] || fail "X2 se duplico"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 3: tabla vieja, enlace en la celda 0 (forma de seedance-generator) =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Active Research\n\n| Slug | Topic | Fecha | Sesion |\n|---|---|---|---|\n| [[research/z0]] | Z0 | 2026-04-20 | s |\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n' > "$IDX"
emit --slug z0 --tema "Z0" --status active --next-step "paso nuevo" --origen "[[sessions/s]]"
compact_quarantine
[ "$(count '[[research/z0]]')" = 1 ] || fail "Z0 se duplico"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 4: Archivo decorado (forma de cloudflare-expert:33) =="
canon "" "| W | r | [[research/w-deco]] · sesion: [[sessions/2026-07-25-x]] |
"
emit --slug w-deco --tema "W" --status completed --resultado "r2" --date 2026-09-21
compact
[ "$(count '[[research/w-deco]]')" = 1 ] || fail "W se duplico"
has '| W | r2 | [[research/w-deco]] · sesion: [[sessions/2026-07-25-x]] _completado: 2026-09-21_ |' \
  || fail "W no se actualizo: $(grep 'w-deco' "$IDX")"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 5: _completado en Archivo =="
canon "" "| V | r | [[research/v5]] _completado: 2026-09-03_ |
"
emit --slug v5 --tema "V" --status completed --resultado "r5" --date 2026-09-21
compact
[ "$(count '[[research/v5]]')" = 1 ] || fail "V se duplico"
has '| V | r5 | [[research/v5]] _completado: 2026-09-03_ |' || fail "V no se actualizo"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 6: fila (inline) por titulo =="
canon "| Tema inline | paso | [[sessions/s]] | (inline) |
" ""
emit --slug tema-inline --tema "Tema inline" --status active --next-step "paso 2" --inline
compact
[ "$(count 'Tema inline')" = 1 ] || fail "la fila inline se duplico"
has '| Tema inline | paso 2 | [[sessions/s]] | (inline) |' || fail "la fila inline no se actualizo"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 7: la cita abre su celda, en la fila de otro research =="
CITA7='| Otro | [[research/x7]] es requisito | [[sessions/s]] | [[research/otro7]] |'
canon "$CITA7
" ""
emit --slug x7 --tema "X7" --status completed --resultado "hecho" --date 2026-09-21
compact
has "$CITA7" || fail "la fila que cita se borro o se altero"
has '| X7 | hecho | [[research/x7]] _completado: 2026-09-21_ |' || fail "X7 no entro en Completed"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 8: otro research con el mismo titulo =="
OTRO8='| Titulo compartido | ver [[research/x8]] | [[sessions/s]] | [[research/otro8]] |'
canon "$OTRO8
" ""
emit --slug x8 --tema "Titulo compartido" --status completed --resultado "hecho" --date 2026-09-21
compact
has "$OTRO8" || fail "la fila de otro research con el mismo titulo se borro o se altero"
has '| Titulo compartido | hecho | [[research/x8]] _completado: 2026-09-21_ |' || fail "X8 no entro en Completed"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 9: la fila propia cita otro research al inicio de una celda =="
canon "| X9 | [[research/y9]] es requisito | [[sessions/s]] | [[research/x9]] |
" ""
emit --slug x9 --tema "X9" --status active --next-step "[[research/y9]] ya esta" --origen "[[sessions/s]]"
compact
[ "$(count '[[research/x9]]')" = 1 ] || fail "X9 se duplico en Active"
has '| X9 | [[research/y9]] ya esta | [[sessions/s]] | [[research/x9]] |' || fail "X9 no se actualizo: $(grep 'x9' "$IDX")"
emit --slug x9 --tema "X9" --status completed --resultado "hecho" --date 2026-09-21
compact
[ "$(count '[[research/x9]]')" = 1 ] || fail "X9 quedo en Active y en Completed"
has '| X9 | hecho | [[research/x9]] _completado: 2026-09-21_ |' || fail "X9 no paso a Completed"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 10: fila (inline) de otro tema que cita X al inicio de una celda =="
INL='| Y10 | [[research/x10]] es requisito | [[sessions/s]] | (inline) |'
canon "$INL
" ""
emit --slug x10 --tema "X10" --status completed --resultado "hecho" --date 2026-09-21
compact
has "$INL" || fail "la fila inline que cita se borro o se altero"
has '| X10 | hecho | [[research/x10]] _completado: 2026-09-21_ |' || fail "X10 no entro en Completed"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 11: tabla vieja con ultima columna 'Related research' =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Active Research\n\n| Tema | Next step | Origen | Related research |\n|---|---|---|---|\n| [[research/y11]] | next | s | [[research/x11]] |\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n' > "$IDX"
emit --slug x11 --tema "X11" --status completed --resultado "hecho" --date 2026-09-21
compact_quarantine
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 12: Archivo vacio o solo _completado, y una cita que abre su celda =="
VAC='| Y12 | [[research/x12]] es requisito | [[sessions/s]] |  |'
canon "$VAC
" ""
emit --slug x12 --tema "X12" --status completed --resultado "hecho" --date 2026-09-21
compact
has "$VAC" || fail "la fila con Archivo vacio se borro o se altero"
canon "" "| Y12c | [[research/x12c]] es requisito | _completado: 2026-09-20_ |
"
emit --slug x12c --tema "X12c" --status completed --resultado "hecho" --date 2026-09-21
compact
has '| Y12c | [[research/x12c]] es requisito | _completado: 2026-09-20_ |' || fail "la fila con Archivo solo _completado se altero"
has '| X12c | hecho | [[research/x12c]] _completado: 2026-09-21_ |' || fail "X12c no entro en Completed"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 13: forma de cloudflare-expert:25 =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Active Research\n\n| Topic | Status | File |\n|---|---|---|\n| Acceso a SQL-LIVE | En progreso, ver [[research/b13]] | [[research/a13]] |\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n' > "$IDX"
A13='| Acceso a SQL-LIVE | En progreso, ver [[research/b13]] | [[research/a13]] |'
emit --slug b13 --tema "B13" --status completed --resultado "hecho" --date 2026-09-21
compact
has "$A13" || fail "la fila de A se borro o se altero"
has '| B13 | hecho | [[research/b13]] _completado: 2026-09-21_ |' || fail "B13 no entro en Completed"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 14: evento sin cambios sobre una fila vieja =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Active Research\n\n| Tema | Next step | Origen | Archivo |\n|---|---|---|---|\n\n## Completed Research\n\n| Topic | File | Resultado |\n|---|---|---|\n| U14 | [[research/u14]] _completado: 2026-09-01_ | r |\n' > "$IDX"
cp "$IDX" "$M/antes14"
emit --slug u14 --tema "U14" --status active --next-step "x"
compact
cmp -s "$M/antes14" "$IDX" || fail "un active de un research ya completado cambio el archivo"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 15: ciclo completo en tabla vieja con File al final =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Active Research\n\n| Topic | Started | Sesion | File |\n|---|---|---|---|\n| Viejo | 2026-08-01 | s | [[research/viejo15]] |\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n' > "$IDX"
emit --slug x15 --tema "X15" --status active --next-step "paso" --origen "[[sessions/s]]"
compact
has '| X15 | paso | [[sessions/s]] | [[research/x15]] |' || fail "X15 no entro en Active"
emit --slug x15 --tema "X15" --status completed --resultado "hecho" --date 2026-09-21
compact
[ "$(count '[[research/x15]]')" = 1 ] || fail "X15 quedo en Active y en Completed"
has '| X15 | hecho | [[research/x15]] _completado: 2026-09-21_ |' || fail "X15 no paso a Completed"
has '| Viejo | 2026-08-01 | s | [[research/viejo15]] |' || fail "la fila vieja se altero"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 16: research nuevo con tabla anclada de solo lectura =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Active Research\n\n| Slug | Topic | Fecha | Sesion |\n|---|---|---|---|\n\n## Completed Research\n\n| Topic | File | Resultado |\n|---|---|---|\n' > "$IDX"
emit --slug n16 --tema "N16" --status active --next-step "paso" --origen "[[sessions/s]]"
compact_quarantine
rm -rf "$M/.journal"
emit --slug n16b --tema "N16b" --status completed --resultado "r" --date 2026-09-21
compact_quarantine
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 17: la poda no toca una tabla Completed de solo lectura =="
rm -rf "$M/.journal"
{
  # ultima columna 'Fecha' (solo lectura), y filas que un evento sin cambios deja igual: el evento
  # llega a la poda sin pedir ninguna escritura
  printf -- '---\ntype: index\n---\n## Active Research\n\n| Tema | Next step | Origen | Archivo |\n|---|---|---|---|\n\n## Completed Research\n\n| Topic | Result | Fecha |\n|---|---|---|\n'
  for d in 01 02 03 04 05 06 07; do echo "| T$d | r$d | [[research/p$d]] _completado: 2026-09-${d}_ |"; done
} > "$IDX"
cp "$IDX" "$M/antes17"
emit --slug p07 --tema "T07" --status completed --date 2026-09-21
compact
cmp -s "$M/antes17" "$IDX" || fail "la poda borro filas de una tabla de solo lectura: $(diff "$M/antes17" "$IDX" | grep '^[<>]' | head -2)"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 18: el marcador de Active vacia no va en una tabla de solo lectura =="
rm -rf "$M/.journal"
printf -- '---\ntype: index\n---\n## Active Research\n\n| Slug | Topic | Fecha | Sesion |\n|---|---|---|---|\n\n## Otra\n\n| Tema | Next step | Origen | Archivo |\n|---|---|---|---|\n| X18 | paso | [[sessions/s]] | [[research/x18]] |\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n' > "$IDX"
emit --slug x18 --tema "X18" --status completed --resultado "hecho" --date 2026-09-21
compact
grep -q 'Sin research activo' "$IDX" && fail "se escribio el marcador en la tabla de solo lectura"
has '| X18 | hecho | [[research/x18]] _completado: 2026-09-21_ |' || fail "X18 no paso a Completed"
[ "$(count '[[research/x18]]')" = 1 ] || fail "X18 quedo duplicado"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 19: solo se borra el marcador de la tabla donde se inserta =="
rm -rf "$M/.journal"
# la canonica NO tiene marcador; la de solo lectura, si: la busqueda en toda la seccion borraba ese
printf -- '---\ntype: index\n---\n## Active Research\n\n| Tema | Next step | Origen | Archivo |\n|---|---|---|---|\n| Otro | p | [[sessions/s]] | [[research/otro19]] |\n\n| Slug | Topic | Fecha | Sesion |\n|---|---|---|---|\n<!-- Sin research activo -->\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n' > "$IDX"
emit --slug x19 --tema "X19" --status active --next-step "paso" --origen "[[sessions/s]]"
compact
has '| X19 | paso | [[sessions/s]] | [[research/x19]] |' || fail "X19 no entro"
sed -n '/| Slug | Topic/,/^$/p' "$IDX" | grep -q 'Sin research activo' || fail "se borro el marcador de la tabla de solo lectura"
# y el camino normal: la canonica vacia con SU marcador lo pierde al recibir la primera fila
canon "<!-- Sin research activo -->
" ""
emit --slug x19b --tema "X19b" --status active --next-step "paso" --origen "[[sessions/s]]"
compact
has '| X19b | paso | [[sessions/s]] | [[research/x19b]] |' || fail "X19b no entro"
grep -q 'Sin research activo' "$IDX" && fail "el marcador propio no se borro al insertar"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 20: madurar preserva lo que el Archivo trae mas alla del enlace desnudo (p-115356214b) =="
canon "| Nativa | paso viejo | [[sessions/s]] | [[research/nativa20]] . sesion: [[sessions/2026-01-01-x]] |
" ""
emit --slug nativa20 --tema "Nativa" --status completed --resultado "r20" --date 2026-09-22
compact
has '| Nativa | r20 | [[research/nativa20]] . sesion: [[sessions/2026-01-01-x]] _completado: 2026-09-22_ |' \
  || fail "la decoracion del Archivo no sobrevivio a la maduracion: $(grep 'nativa20' "$IDX")"
[ "$(count '[[research/nativa20]]')" = 1 ] || fail "nativa20 se duplico"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 21: madurar defusa una marca _completado real de una reapertura a mano =="
canon "| Reabierta | paso | [[sessions/s]] | [[research/reabierta21]] _completado: 2026-01-01_ |
" ""
emit --slug reabierta21 --tema "Reabierta" --status completed --resultado "r21" --date 2026-09-22
compact
has '| Reabierta | r21 | [[research/reabierta21]] completado: 2026-01-01_ _completado: 2026-09-22_ |' \
  || fail "la marca vieja no se defuso o la nueva no se escribio: $(grep 'reabierta21' "$IDX")"
grep -c '_completado: 2026-01-01_' "$IDX" | grep -qx 0 || fail "sobrevivio una marca real vieja sin defusar"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 22: madurar un enlace aliasado no duplica el enlace completo =="
canon "| Stack comparison | paso | [[sessions/s]] | [[research/arch\\|arch]] . sesion: [[sessions/2026-04-16-x]] |
" ""
emit --slug arch --tema "Stack comparison" --status completed --resultado "Next.js" --date 2026-09-22
compact
has '| Stack comparison | Next.js | [[research/arch]] . sesion: [[sessions/2026-04-16-x]] _completado: 2026-09-22_ |' \
  || fail "el alias no se reconocio o el enlace se duplico: $(grep 'research/arch' "$IDX")"
[ "$(count '[[research/arch')" = 1 ] || fail "arch se duplico"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 23: Active y Completed coexisten para el mismo slug (estado a mano) — sin duplicado =="
canon "| Re | paso | [[sessions/s]] | [[research/re23]] sesion: X _completado: 2026-01-01_ |
" "| Re | r1 | [[research/re23]] sesion: X _completado: 2026-01-01_ |
"
emit --slug re23 --tema "Re" --status completed --resultado "r2" --date 2026-09-22
compact
has '| Re | r2 | [[research/re23]] sesion: X _completado: 2026-01-01_ |' \
  || fail "la fila de Completed no se actualizo como se esperaba: $(grep 're23' "$IDX")"
[ "$(count 'sesion: X')" = 1 ] || fail "el extra de Active se duplico en Completed"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 24: alias con corchete sin escapar cae al else (duplica, pero no pierde nada) =="
canon "| Br | paso | [[sessions/s]] | [[research/br24\\|a]b]] |
" ""
emit --slug br24 --tema "Br" --status completed --resultado "r" --date 2026-09-22
compact
grep -qF 'a]b]]' "$IDX" || fail "se perdio texto: $(grep 'research/br24' "$IDX")"
has '| Br | r | [[research/br24]] [[research/br24\|a]b]] _completado: 2026-09-22_ |' \
  || fail "no cayo al else esperado: $(grep 'research/br24' "$IDX")"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 25: alias SIN CERRAR con decoracion propia no pierde texto en silencio =="
canon "| T | paso | [[sessions/s]] | [[research/x25\\|alias] . sesion: [[sessions/2026-01-01-y]] nota importante |
" ""
emit --slug x25 --tema "T" --status completed --resultado "r" --date 2026-09-22
compact
grep -qF 'sesion: [[sessions/2026-01-01-y]] nota importante' "$IDX" \
  || fail "se perdio texto en silencio: $(grep 'research/x25' "$IDX")"
has '[[research/x25]] [[research/x25\|alias] . sesion: [[sessions/2026-01-01-y]] nota importante _completado: 2026-09-22_' \
  || fail "no cayo al else esperado (duplicado visible, sin perdida): $(grep 'research/x25' "$IDX")"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 26: alias sin cerrar con un ]] ESCAPADO despues no pierde texto en silencio =="
canon "| T | paso | [[sessions/s]] | [[research/x26\\|alias] nota \\]] resto |
" ""
emit --slug x26 --tema "T" --status completed --resultado "r" --date 2026-09-22
compact
grep -qF 'nota \]] resto' "$IDX" || fail "se perdio texto en silencio: $(grep 'research/x26' "$IDX")"
[ "$FAIL" = 0 ] && echo "  ok"

echo "== caso 27: madurar conserva el Tema de la fila de Active, no el del evento (2.38.0) =="
# Un upsert nunca corrige el tema. Antes de 2.38.0 la fila de Completed se reconstruia con el tema
# del EVENTO, asi que un `completed` emitido con un tema desfasado (p. ej. el anterior a un
# research.rename) lo cambiaba al madurar. Un research que nace ya completado sigue usando el suyo.
canon "| Tema vigente | paso | [[sessions/s]] | [[research/t27]] |
" ""
emit --slug t27 --tema "Tema desfasado" --status completed --resultado "ok" --date 2026-09-22
emit --slug n27 --tema "Nace cerrado" --status completed --resultado "ok" --date 2026-09-22
compact
has '| Tema vigente | ok | [[research/t27]] _completado: 2026-09-22_ |' \
  || fail "el tema de Active no se conservo al madurar: $(grep 'research/t27' "$IDX")"
[ "$(count 'Tema desfasado')" = 0 ] || fail "el tema del evento piso al de la fila"
has '| Nace cerrado | ok | [[research/n27]] _completado: 2026-09-22_ |' \
  || fail "un research sin fila previa perdio su tema: $(grep 'research/n27' "$IDX")"
[ "$FAIL" = 0 ] && echo "  ok"

[ "$FAIL" = 0 ] && echo "PASS test-research-row-lookup" || { echo "FAIL test-research-row-lookup"; exit 1; }
