#!/bin/bash
# Evento `session.amend` (2.40.0, pendiente p-fd3d3bdcab): corregir la Fecha y el alias de una
# sesion en _session-index.md.
#
# El hueco: `session.add` rellena status/summary/commit de una fila existente y nunca toca la
# celda 0 (Fecha) ni la 1 (`[[sessions/<slug>\|alias]]`), asi que una fecha o un alias
# equivocados no tenian correccion por evento, y con journal_strict tampoco a mano. Diseno:
# CHANGELOG 2.31.0, "2. session.amend".
#
# El criterio verificable del diseno es el caso 3: con la tabla llena (10 sesiones), corregir la
# fecha de una fila hacia atras la deja presente — el amend no poda; la poda sigue en session.add.
# El resto son los bordes que comparte con research.rename: el replay del PROPIO amend tras uno
# posterior es noop, el replay del ultimo tras una edicion a mano tambien, dos amends concurrentes
# (mismo campo: cuarentena; campos distintos: aplican los dos), ancla a la celda y no a la fila,
# evento sin ts, tabla vieja de 4 columnas y el emisor.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'chflags -R nouappnd "$T" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }

# $1 = filas de la tabla, $2 = cabecera (por defecto la de 5 columnas).
fixture() {
  M="$T/m$RANDOM$RANDOM/memory"; mkdir -p "$M/sessions"
  local cab="${2:-| Fecha | Sesion | Status | Resumen | Commit |
|---|---|---|---|---|}"
  printf -- '---\ntype: index\nupdated: 2026-01-01\n---\n# Sessions\n\n## Sessions\n\n%s\n%s\n\n## Related\n- [[_pendientes]]\n' "$cab" "$1" > "$M/_session-index.md"
  IDX="$M/_session-index.md"; LOG="$M/../compact.log"
}
# emit ... -> guarda en $EV una copia del evento recien emitido (para reinyectarlo despues).
emit() {
  local antes; antes=$(ls "$M/.journal/pending" 2>/dev/null)
  python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@" >/dev/null 2>"$M/../emit.err" || return 1
  EV=$(comm -13 <(printf '%s\n' "$antes" | sort) <(ls "$M/.journal/pending" | sort) | head -1)
  cp "$M/.journal/pending/$EV" "$M/../$EV.bak"
  EV="$M/../$EV.bak"
}
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" --log "$LOG" "$@"; }
replay() { cp "$1" "$M/.journal/pending/$(basename "$1" .bak)"; compact --quiet >/dev/null; }
cuar() { ls "$M/.journal/quarantine/"*.json 2>/dev/null | wc -l | tr -d ' '; }
razon() { cat "$M"/.journal/quarantine/*.reason 2>/dev/null; }
n() { grep -cF -- "$1" "$IDX"; }
filas() { grep -c '^| [0-9]' "$IDX"; }
sha() { shasum -a 256 "$IDX" | cut -d' ' -f1; }
reg() { cat "$M/.journal/reabiertos.log" 2>/dev/null | grep -c "^session-[a-z]*-$1	"; }
am() { emit --type session.amend "$@"; }
# Escribe a mano un evento session.amend (otro emisor, o un evento editado): $1 = payload JSON,
# $2 = ts ("" para omitirlo), $3 = nombre del fichero (el compactador aplica por orden de nombre).
evento() {
  mkdir -p "$M/.journal/pending"
  python3 - "$M/.journal/pending" "$1" "$2" "${3:-0000-manual.json}" <<'PY'
import json, os, sys
d, payload, ts, nombre = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3], sys.argv[4]
ev = {"v": 1, "type": "session.amend", "session_id": "t", "agent_id": "t", "payload": payload}
if ts:
    ev["ts"] = int(ts)
json.dump(ev, open(os.path.join(d, nombre), "w"))
PY
}

S='2026-09-20-demo'
FILA="| 2026-09-20 | [[sessions/$S\|demo]] | ok | hizo algo | \`abc1234\` |"

echo "== 1. corregir la Fecha: celda 0 nueva, el resto de la fila y del fichero intactos =="
fixture "$FILA"
ANTES=$(grep -v '2026-09-20-demo\|^updated:' "$IDX" | shasum | cut -d' ' -f1)
am --slug "$S" --date 2026-09-18
OUT=$(compact)
has "aplicado" "$OUT" "applied=1"
chk "fila corregida" "1" "$(n "| 2026-09-18 | [[sessions/$S\|demo]] | ok | hizo algo | \`abc1234\` |")"
chk "el resto del fichero identico" "$ANTES" "$(grep -v '2026-09-20-demo\|^updated:' "$IDX" | shasum | cut -d' ' -f1)"
chk "sin cuarentena" "0" "$(cuar)"
chk "registrado con su ts" "1" "$(reg "$S")"
chk "bump de updated" "1" "$(grep -c "^updated: $(date +%Y-%m-%d)" "$IDX")"

echo "== 2. corregir el alias: el wikilink sigue apuntando al slug =="
fixture "$FILA"
am --slug "$S" --alias "Demo corregido"
compact --quiet >/dev/null
chk "alias nuevo, destino intacto" "1" "$(n "| 2026-09-20 | [[sessions/$S\|Demo corregido]] | ok |")"
chk "el alias viejo no queda" "0" "$(n '\|demo]]')"

echo "== 3. tabla llena: corregir la fecha de la fila de arriba hacia atras NO la poda =="
# 11 filas, no 10: con 10 una poda copiada de session.add (`> MAX_SESSIONS`) no borra nada y el
# caso no la veria. Una tabla con una fila de mas es real (edicion a mano, o una fila sin fecha
# que despues la recibe) y es donde la poda en el amend expulsaria la fila recien corregida.
ROWS=""
for d in 30 29 28 27 26 25 24 23 22 21 20; do
  ROWS="$ROWS| 2026-08-$d | [[sessions/2026-08-$d-s$d\|s$d]] | ok | r | |
"
done
fixture "${ROWS%?}"
am --slug 2026-08-30-s30 --date 2026-01-01
compact --quiet >/dev/null
chk "siguen 11 filas" "11" "$(filas)"
chk "la corregida sigue, con su fecha nueva" "1" "$(n '| 2026-01-01 | [[sessions/2026-08-30-s30\|s30]] |')"
chk "la mas vieja por fecha tambien sigue" "1" "$(n '2026-08-20-s20')"
emit --type session.add --slug 2026-09-01-nueva --date 2026-09-01 --status ok --summary nueva
compact --quiet >/dev/null
chk "el siguiente session.add poda, y por fecha: sale la corregida" "10|0|0|1" "$(filas)|$(n '2026-08-30-s30')|$(n '2026-08-20-s20')|$(n '2026-08-21-s21')"

echo "== 4. tras corregir el alias, el session.add del commit encuentra la fila y no toca 0/1 =="
fixture "| 2026-09-20 | [[sessions/$S\|demo]] | ok | hizo algo | |"
am --slug "$S" --alias "Alias nuevo" --date 2026-09-19; compact --quiet >/dev/null
emit --type session.add --slug "$S" --date 2026-09-20 --commit '`fff0000`'
compact --quiet >/dev/null
chk "una sola fila, commit lleno, fecha y alias corregidos" "1|1" "$(n "$S")|$(n "| 2026-09-19 | [[sessions/$S\|Alias nuevo]] | ok | hizo algo | \`fff0000\` |")"

echo "== 5. A->B, B->C y replay de A->B: sigue en C, noop, sin cuarentena =="
fixture "$FILA"
am --slug "$S" --date 2026-09-10; AB=$EV; compact --quiet >/dev/null
am --slug "$S" --date 2026-09-11; BC=$EV; compact --quiet >/dev/null
chk "en C" "1" "$(n "| 2026-09-11 | [[sessions/$S")"
replay "$AB"
chk "sigue en C tras el replay de A->B" "1|0" "$(n "| 2026-09-11 | [[sessions/$S")|$(n '2026-09-10')"
chk "sin cuarentena (un replay no es un error)" "0" "$(cuar)"
has "aviso en el log" "$(cat "$LOG")" "WARN session.amend"

echo "== 6. replay del ULTIMO amend: noop, no anota otra vez =="
OUT=$(cp "$BC" "$M/.journal/pending/$(basename "$BC" .bak)"; compact)
has "noop" "$OUT" "noop=1"
chk "dos registros, no tres" "2" "$(reg "$S")"

echo "== 7. replay del ULTIMO amend tras una edicion a mano de la celda: noop, sin cuarentena =="
# Un replay es un replay aunque la celda haya cambiado despues por fuera del journal: la guarda
# de orden es `<=`, no `<`. Con `<` este caso caeria en celda-cambiada.
fixture "$FILA"
am --slug "$S" --date 2026-09-10; AB=$EV; compact --quiet >/dev/null
sed -i.bak "s/| 2026-09-10 | \[\[sessions\/$S/| 2026-09-12 | [[sessions\/$S/" "$IDX"
replay "$AB"
chk "sigue la edicion a mano" "1" "$(n "| 2026-09-12 | [[sessions/$S")"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 8. dos amends de la MISMA celda emitidos antes de compactar: el segundo a cuarentena =="
fixture "$FILA"
am --slug "$S" --date 2026-09-01
am --slug "$S" --date 2026-09-02
compact --quiet >/dev/null 2>&1
chk "gana el primero" "1|0" "$(n "| 2026-09-01 |")|$(n '2026-09-02')"
chk "el segundo en cuarentena" "1" "$(cuar)"
has "motivo celda-cambiada" "$(razon)" "^celda-cambiada:"

echo "== 9. dos amends de celdas DISTINTAS emitidos antes de compactar: aplican los dos =="
fixture "$FILA"
am --slug "$S" --date 2026-09-01
am --slug "$S" --alias "Otro alias"
compact --quiet >/dev/null 2>&1
chk "las dos correcciones" "1" "$(n "| 2026-09-01 | [[sessions/$S\|Otro alias]] |")"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 10. un amend solo de alias no devuelve la fecha a la del slug =="
fixture "$FILA"
am --slug "$S" --date 2026-09-05; compact --quiet >/dev/null
am --slug "$S" --alias "Solo alias"
chk "el payload no lleva date" "no" "$(python3 -c 'import json,sys; print("si" if "date" in json.load(open(sys.argv[1]))["payload"] else "no")' "$EV")"
compact --quiet >/dev/null
chk "la fecha corregida se queda" "1" "$(n "| 2026-09-05 | [[sessions/$S\|Solo alias]] |")"

echo "== 11. una fila que solo CITA la sesion no es suya =="
fixture "| 2026-09-21 | [[sessions/2026-09-21-otra\|otra]] | ok | sigue [[sessions/$S]] | |
$FILA"
am --slug "$S" --date 2026-09-19; compact --quiet >/dev/null
chk "la ajena intacta, la propia corregida" "1|1" "$(n '| 2026-09-21 | [[sessions/2026-09-21-otra')|$(n "| 2026-09-19 | [[sessions/$S")"

echo "== 12. la misma sesion dos veces (instalacion vieja): se corrigen las dos, no se fusionan =="
fixture "$FILA
| 2026-09-20 | [[sessions/$S\|demo]] | ok | otra vez | |"
am --slug "$S" --date 2026-09-17; compact --quiet >/dev/null
chk "dos filas corregidas" "2|0" "$(n "| 2026-09-17 | [[sessions/$S")|$(n '| 2026-09-20 |')"

echo "== 13. tabla vieja de 4 columnas: se corrige y no se le agrega Commit =="
fixture "| 2026-09-20 | [[sessions/$S\|demo]] | ok | algo |" "| Fecha | Sesion | Status | Resumen |
|---|---|---|---|"
am --slug "$S" --date 2026-09-16 --alias "Viejo formato"; compact --quiet >/dev/null
chk "corregida, 4 columnas" "1|0" "$(n "| 2026-09-16 | [[sessions/$S\|Viejo formato]] | ok | algo |")|$(n 'Commit')"

echo "== 14. slug sin fila: cuarentena no-fila, fichero intacto =="
fixture "$FILA"
ANTES=$(sha)
am --slug 2026-01-01-fantasma --date 2026-01-02 --fecha-vieja 2026-01-01
compact --quiet >/dev/null 2>&1
has "motivo no-fila" "$(razon)" "^no-fila:"
has "menciona la poda" "$(razon)" "mas recientes"
chk "fichero intacto" "$ANTES" "$(sha)"

echo "== 15. amend a los valores que ya tiene: noop mudo =="
fixture "$FILA"
am --slug "$S" --date 2026-09-20 --alias demo
OUT=$(compact)
has "noop" "$OUT" "noop=1"
chk "sin registro" "0" "$(reg "$S")"

echo "== 16. eventos escritos a mano: sin ts, fecha irreal, alias con '|' o sin valor viejo -> malformed =="
V='"fecha_vieja": "2026-09-20", "sesion_vieja": "[[sessions/2026-09-20-demo\\|demo]]"'
malo() {  # $1 = nombre, $2 = payload, $3 = ts, $4 = motivo esperado
  fixture "$FILA"; local antes; antes=$(sha)
  evento "$2" "$3"; compact --quiet >/dev/null 2>&1
  has "$1: malformed" "$(razon)" "^malformed:.*$4"
  chk "$1: fichero intacto" "$antes" "$(sha)"
}
malo "sin ts" "{\"slug\": \"$S\", \"date\": \"2026-09-01\", $V}" "" "session.amend sin 'ts'"
malo "fecha irreal" "{\"slug\": \"$S\", \"date\": \"2026-99-99\", $V}" 5 "date irreal"
malo "fecha sin forma" "{\"slug\": \"$S\", \"date\": \"20260901\", $V}" 5 "invalida"
malo "alias con barra" "{\"slug\": \"$S\", \"alias\": \"a|b\", $V}" 5 "alias"
malo "sin fecha_vieja" "{\"slug\": \"$S\", \"date\": \"2026-09-01\"}" 5 "sin 'fecha_vieja'"
malo "nada que corregir" "{\"slug\": \"$S\", $V}" 5 "nada que corregir"

echo "== 17. emisor: sin fila y sin valor viejo sale con error y no emite =="
fixture "$FILA"
if am --slug 2026-01-01-nadie --date 2026-01-02; then r=emitio; else r=rechazo; fi
chk "rechaza" "rechazo" "$r"
has "dice que pasar" "$(cat "$M/../emit.err")" "fecha-vieja"
chk "pending vacio" "0" "$(ls "$M/.journal/pending" 2>/dev/null | wc -l | tr -d ' ')"

echo "== 18. emisor: sin --date ni --alias, alias con '[' y fecha irreal se rechazan =="
fixture "$FILA"
for args in "" "--alias a[b" "--date 2026-02-30" "--date 20260901"; do
  # shellcheck disable=SC2086
  if am --slug "$S" $args; then r=emitio; else r=rechazo; fi
  chk "rechaza '${args:-sin campos}'" "rechazo" "$r"
done
chk "pending vacio" "0" "$(ls "$M/.journal/pending" 2>/dev/null | wc -l | tr -d ' ')"

echo "== 19. emisor: toma los valores viejos de la fila por su celda Sesion, no de una que la cita =="
fixture "| 2026-09-21 | [[sessions/2026-09-21-otra\|otra]] | ok | sigue [[sessions/$S\|x]] | |
$FILA"
am --slug "$S" --date 2026-09-19 --alias nuevo
chk "fecha_vieja y sesion_vieja de la fila propia" "2026-09-20|[[sessions/$S\|demo]]" \
  "$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["payload"]; print(p["fecha_vieja"]+"|"+p["sesion_vieja"])' "$EV")"

# ---------------------------------------------------------------- ronda 1 del adversario (Fable)
VF='"fecha_vieja": "2026-09-20"'
VS='"sesion_vieja": "[[sessions/2026-09-20-demo\\|demo]]"'

echo "== 20. celdas distintas con el orden de ts al reves del orden de aplicacion: aplican las dos =="
# Con una sola clave por sesion, la Fecha (ts 100) se descartaba como replay del alias (ts 200).
fixture "$FILA"
evento "{\"slug\": \"$S\", \"alias\": \"Alias 200\", $VS}" 200 0000-a.json
evento "{\"slug\": \"$S\", \"date\": \"2026-09-02\", $VF}" 100 0001-b.json
OUT=$(compact)
has "las dos aplicadas" "$OUT" "applied=2"
chk "fecha y alias corregidos" "1" "$(n "| 2026-09-02 | [[sessions/$S\|Alias 200]] |")"

echo "== 21. celdas distintas con el MISMO ts: aplican las dos =="
fixture "$FILA"
evento "{\"slug\": \"$S\", \"alias\": \"Alias igual\", $VS}" 100 0000-a.json
evento "{\"slug\": \"$S\", \"date\": \"2026-09-03\", $VF}" 100 0001-b.json
compact --quiet >/dev/null 2>&1
chk "fecha y alias corregidos" "1" "$(n "| 2026-09-03 | [[sessions/$S\|Alias igual]] |")"

echo "== 22. la MISMA celda con el orden de ts al reves: gana el ts mayor, el otro noop con WARN =="
fixture "$FILA"
evento "{\"slug\": \"$S\", \"alias\": \"Nuevo\", $VS}" 200 0000-a.json
evento "{\"slug\": \"$S\", \"alias\": \"Viejo\", $VS}" 100 0001-b.json
OUT=$(compact)
has "uno aplicado, uno noop" "$OUT" "applied=1 quarantined=0.*noop=1"
chk "gana el ts mayor" "1|0" "$(n "[[sessions/$S\|Nuevo]]")|$(n 'Viejo]]')"
has "aviso en el log" "$(cat "$LOG")" "WARN session.amend"

echo "== 23. dos amends al MISMO valor nuevo emitidos antes de compactar: el segundo noop, no cuarentena =="
fixture "$FILA"
am --slug "$S" --date 2026-09-04
am --slug "$S" --date 2026-09-04
OUT=$(compact)
has "aplicado + noop, sin cuarentena" "$OUT" "applied=1 quarantined=0.*noop=1"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 24. filas duplicadas con valores DISTINTOS: el emisor se niega; a mano, cuarentena filas-distintas =="
DUP="| 2026-09-21 | [[sessions/$S\|demo]] | ok | copia editada | |
$FILA"
fixture "$DUP"
if am --slug "$S" --date 2026-09-05; then r=emitio; else r=rechazo; fi
chk "el emisor se niega" "rechazo" "$r"
has "dice como fusionarlas" "$(cat "$M/../emit.err")" "session.add"
ANTES=$(sha)
evento "{\"slug\": \"$S\", \"date\": \"2026-09-05\", $VF}" 5
compact --quiet >/dev/null 2>&1
has "motivo filas-distintas" "$(razon)" "^filas-distintas:"
has "dice como fusionarlas" "$(razon)" "session.add"
chk "fichero intacto" "$ANTES" "$(sha)"
emit --type session.add --slug "$S" --date 2026-09-20 --status ok; compact --quiet >/dev/null 2>&1
chk "el session.add las fusiona" "1" "$(n "$S")"
am --slug "$S" --date 2026-09-05; compact --quiet >/dev/null 2>&1
chk "y el amend ya aplica" "1" "$(n "| 2026-09-05 | [[sessions/$S")"

echo "== 25. una fila duplicada ya corregida y otra no: se corrige la que falta, sin cuarentena =="
fixture "| 2026-09-06 | [[sessions/$S\|demo]] | ok | ya corregida | |
$FILA"
evento "{\"slug\": \"$S\", \"date\": \"2026-09-06\", $VF}" 5
compact --quiet >/dev/null 2>&1
chk "las dos con la fecha nueva, sin cuarentena" "2|0" "$(n "| 2026-09-06 | [[sessions/$S")|$(cuar)"

echo "== 26. una fila '|' suelta fuera de toda tabla no es la fila de la sesion, tampoco para el emisor =="
M="$T/huerfana/memory"; mkdir -p "$M"; IDX="$M/_session-index.md"; LOG="$M/../compact.log"
printf -- '---\ntype: index\n---\n# Sessions\n\n| 2026-09-19 | [[sessions/%s\\|demo]] | ok | huerfana | |\n\n## Sessions\n\n| Fecha | Sesion | Status | Resumen | Commit |\n|---|---|---|---|---|\n%s\n' "$S" "$FILA" > "$IDX"
am --slug "$S" --date 2026-09-07
chk "fecha_vieja de la fila de la tabla" "2026-09-20" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["payload"]["fecha_vieja"])' "$EV")"
compact --quiet >/dev/null 2>&1
chk "corregida la de la tabla, la suelta intacta, sin cuarentena" "1|1|0" "$(n "| 2026-09-07 | [[sessions/$S")|$(n '| 2026-09-19 |')|$(cuar)"
printf -- '---\ntype: index\n---\n# Sessions\n\n| 2026-09-19 | [[sessions/2026-09-19-suelta\\|s]] | ok | huerfana | |\n' > "$IDX"
if am --slug 2026-09-19-suelta --date 2026-09-08; then r=emitio; else r=rechazo; fi
chk "slug solo en una fila suelta: el emisor se niega" "rechazo" "$r"

echo "== 27. la escritura del indice falla: la anotacion se retira y el reintento aplica =="
fixture "$FILA"
am --slug "$S" --date 2026-09-09
chmod 555 "$M"
compact --quiet >/dev/null 2>&1
chmod 755 "$M"
chk "sin anotacion tras el fallo" "0" "$(reg "$S")"
chk "el evento sigue en pending" "1" "$(ls "$M/.journal/pending" | wc -l | tr -d ' ')"
OUT=$(compact)
has "el reintento aplica" "$OUT" "applied=1"
chk "fecha corregida y anotada" "1|1" "$(n "| 2026-09-09 | [[sessions/$S")|$(reg "$S")"

# ---------------------------------------------------------------- ronda 2 (Sonnet y Codex)
echo "== 28. el registro no se puede escribir: cuarentena no-registro y el indice NO cambia =="
# Separa anotar-antes-de-escribir de escribir-antes-de-anotar: con el orden invertido el indice
# quedaria corregido sin registro, y un replay viejo lo pisaria despues.
fixture "$FILA"
am --slug "$S" --date 2026-09-11
ANTES=$(sha)
: > "$M/.journal/reabiertos.log"; chmod 444 "$M/.journal/reabiertos.log"
compact --quiet >/dev/null 2>&1
chmod 644 "$M/.journal/reabiertos.log"
has "motivo no-registro" "$(razon)" "^no-registro:"
chk "indice intacto" "$ANTES" "$(sha)"

echo "== 29. falla el indice Y no se puede retirar la anotacion: cuarentena no-registro, no un replay mudo =="
# Doble falla real: el registro admite append (la anotacion entra) pero no rename encima (no se
# puede retirar), y memory/ no deja escribir el indice. Sin la cuarentena, el evento quedaba en
# pending/ con su anotacion y el reintento lo archivaba como replay sin aplicarlo.
if command -v chflags >/dev/null 2>&1; then
  fixture "$FILA"
  am --slug "$S" --date 2026-09-12
  ANTES=$(sha)
  : > "$M/.journal/reabiertos.log"; chflags uappnd "$M/.journal/reabiertos.log"
  chmod 555 "$M"
  compact --quiet >/dev/null 2>&1
  chmod 755 "$M"; chflags nouappnd "$M/.journal/reabiertos.log"
  has "motivo no-registro" "$(razon)" "^no-registro:"
  has "nombra la linea a borrar" "$(razon)" "session-fecha-$S"
  chk "indice intacto, el evento fuera de pending" "$ANTES|0" "$(sha)|$(ls "$M/.journal/pending" | wc -l | tr -d ' ')"
  chk "sin temporal huerfano" "0" "$(ls "$M/.journal" | grep -c '\.tmp$')"
else
  echo "  SKIP doble falla: sin chflags (solo macOS/BSD)"
fi

echo "== 31. una fila con la Fecha VACIA tambien se corrige =="
fixture "|  | [[sessions/$S\|demo]] | ok | sin fecha | |"
am --slug "$S" --date 2026-09-20
chk "fecha_vieja vacia en el payload" "" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["payload"]["fecha_vieja"])' "$EV")"
compact --quiet >/dev/null 2>&1
chk "fecha puesta, sin cuarentena" "1|0" "$(n "| 2026-09-20 | [[sessions/$S\|demo]] | ok | sin fecha |")|$(cuar)"

echo "== 30. emisor: el aviso de filas duplicadas cuenta filas, no pares distintos =="
fixture "$FILA
$FILA
| 2026-09-21 | [[sessions/$S\|demo]] | ok | otra | |"
am --slug "$S" --date 2026-09-13 || true
has "dice 3 filas" "$(cat "$M/../emit.err")" "tiene 3 filas"

echo "== 32. si la escritura del registro falla a medias, el registro original queda intacto =="
# Inyeccion de fallo: writelines lanza OSError DESPUES de abrir el fichero. Con temporal + rename
# el registro no se toca; con una reescritura en sitio, `open(..., "w")` ya lo habria truncado y
# se perderian las anotaciones de TODAS las claves (pendientes, planes, research).
fixture "$FILA"
mkdir -p "$M/.journal"
printf 'p-0123456789\t1\t2026-09-01\nplan-otro\t2\t2026-09-01\nsession-fecha-%s\t3\t2026-09-01\n' "$S" > "$M/.journal/reabiertos.log"
ANTES=$(shasum "$M/.journal/reabiertos.log" | cut -d' ' -f1)
R=$(python3 - "$BIN/journal-compact.py" "$M" "$S" <<'PY'
import builtins, importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("jc", sys.argv[1]); jc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jc)
real = builtins.open
class Roto:
    def __init__(self, fh): self.fh = fh
    def __enter__(self): return self
    def __exit__(self, *a): self.fh.close()
    def writelines(self, _): raise OSError("disco lleno (inyectado)")
    def write(self, _): raise OSError("disco lleno (inyectado)")
def falso(f, mode="r", *a, **k):
    fh = real(f, mode, *a, **k)
    return Roto(fh) if "w" in mode and ".journal" in str(f) else fh
builtins.open = falso
print(jc.desanotar(sys.argv[2], [(f"session-fecha-{sys.argv[3]}", 3)]))
PY
)
chk "desanotar informa el fallo" "False" "$R"
chk "registro intacto" "$ANTES" "$(shasum "$M/.journal/reabiertos.log" | cut -d' ' -f1)"
chk "sin temporal huerfano" "0" "$(ls "$M/.journal" | grep -c '\.tmp$')"

echo
echo "RESULTADO: $pass ok, $fail fallas"
[ "$fail" = 0 ]
