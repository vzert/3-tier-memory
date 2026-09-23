#!/bin/bash
# Evento `research.rename` (2.38.0, pendiente p-9a59328616): corregir el tema de un research.
#
# El hueco: el tema es la celda 0 de la fila y `research.upsert` nunca la reescribe (ni en Active
# ni en Completed), asi que un tema equivocado no tenia correccion por evento, y con
# journal_strict tampoco a mano. Diseno: CHANGELOG 2.31.0, "1. research.rename".
#
# Las dos corridas del criterio verificable del diseno son los casos 1-3 (fila con fichero, y un
# upsert posterior con el tema VIEJO no duplica ni deshace el rename) y el caso 4 (fila --inline:
# cuarentena sin-identidad, fichero intacto). El resto son los bordes: el replay del PROPIO rename
# tras uno posterior es noop (como plan.reopen), dos renames concurrentes del mismo tema, evento
# sin ts, la fila en Completed, la fila en las dos tablas, alias, tabla vieja y el emisor.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }

# $1 = filas de Active, $2 = filas de Completed, con las cabeceras canonicas.
fixture() {
  M="$T/m$RANDOM$RANDOM/memory"; mkdir -p "$M/research"
  printf -- '---\ntype: index\nupdated: 2026-01-01\n---\n# Research\n\n## Active Research\n\n| Tema | Next step | Origen | Archivo |\n|---|---|---|---|\n%s\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n%s\n## Related\n- [[_pendientes]]\n' "$1" "$2" > "$M/_research-index.md"
  IDX="$M/_research-index.md"; LOG="$M/../compact.log"
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
sha() { shasum -a 256 "$IDX" | cut -d' ' -f1; }
reg() { grep -c "^research-$1	" "$M/.journal/reabiertos.log" 2>/dev/null || echo 0; }
rn() { emit --type research.rename "$@"; }

FILA='| Tema viejo | leer | [[sessions/s]] | [[research/demo]] |'

echo "== 1. renombrar una fila CON fichero: el tema viejo sale 0 veces, el nuevo 1, el enlace intacto =="
fixture "$FILA" ""
rn --slug demo --tema "Tema nuevo"
OUT=$(compact)
has "aplicado" "$OUT" "applied=1"
chk "tema viejo" "0" "$(n 'Tema viejo')"
chk "tema nuevo" "1" "$(n '| Tema nuevo | leer | [[sessions/s]] | [[research/demo]] |')"
chk "sin cuarentena" "0" "$(cuar)"
chk "registrado con su ts" "1" "$(reg demo)"
chk "bump de updated" "1" "$(grep -c "^updated: $(date +%Y-%m-%d)" "$IDX")"

echo "== 2. un research.upsert active posterior con el tema VIEJO no duplica ni revierte =="
emit --type research.upsert --slug demo --tema "Tema viejo" --status active --next-step "seguir"
compact --quiet >/dev/null
chk "una sola fila de demo" "1" "$(n '[[research/demo]]')"
chk "tema viejo sigue en 0" "0" "$(n 'Tema viejo')"
chk "el upsert si actualiza su celda" "1" "$(n '| Tema nuevo | seguir |')"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 3. un research.upsert completed con el tema VIEJO madura la fila CON el tema nuevo =="
emit --type research.upsert --slug demo --tema "Tema viejo" --status completed --resultado "hecho" --date 2026-09-20
compact --quiet >/dev/null
chk "una sola fila de demo" "1" "$(n '[[research/demo]]')"
chk "tema viejo sigue en 0" "0" "$(n 'Tema viejo')"
chk "en Completed con el tema nuevo" "1" "$(n '| Tema nuevo | hecho | [[research/demo]] _completado: 2026-09-20_ |')"

echo "== 4. una fila --inline NO se renombra: cuarentena sin-identidad, fichero intacto =="
fixture '| Suelto | leer | [[sessions/s]] | (inline) |' ""
ANTES=$(sha)
rn --slug suelto --tema "Otro nombre" --tema-viejo "Suelto"
compact --quiet >/dev/null 2>&1
chk "cuarentena" "1" "$(cuar)"
has "motivo sin-identidad" "$(razon)" "^sin-identidad:"
has "dice como arreglarlo" "$(razon)" "research/suelto"
chk "fichero intacto" "$ANTES" "$(sha)"

echo "== 5. slug sin fila: cuarentena no-fila, fichero intacto =="
fixture "$FILA" ""
ANTES=$(sha)
rn --slug fantasma --tema "X" --tema-viejo "Y"
compact --quiet >/dev/null 2>&1
chk "cuarentena" "1" "$(cuar)"
has "motivo no-fila" "$(razon)" "^no-fila:"
chk "fichero intacto" "$ANTES" "$(sha)"

echo "== 6. A->B, B->C y replay de A->B: sigue en C, noop, sin cuarentena =="
fixture "$FILA" ""
rn --slug demo --tema "Tema B"; AB=$EV; compact --quiet >/dev/null
rn --slug demo --tema "Tema C"; BC=$EV; compact --quiet >/dev/null
chk "en C" "1" "$(n '| Tema C |')"
replay "$AB"
chk "sigue en C tras el replay de A->B" "1|0" "$(n '| Tema C |')|$(n 'Tema B')"
chk "sin cuarentena (un replay no es un error)" "0" "$(cuar)"
has "aviso en el log" "$(cat "$LOG")" "research.rename"

echo "== 7. replay del ULTIMO rename: noop, no anota otra vez =="
OUT=$(cp "$BC" "$M/.journal/pending/$(basename "$BC" .bak)"; compact)
has "noop" "$OUT" "noop=1"
chk "sigue en C" "1" "$(n '| Tema C |')"
chk "dos registros, no tres" "2" "$(reg demo)"

echo "== 8. rename al tema que ya tiene: noop mudo =="
rn --slug demo --tema "Tema C"
OUT=$(compact)
has "noop" "$OUT" "noop=1"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 9. dos renames del MISMO tema emitidos antes de compactar: el segundo va a cuarentena =="
fixture "$FILA" ""
rn --slug demo --tema "Rama uno"
rn --slug demo --tema "Rama dos"
compact --quiet >/dev/null 2>&1
chk "gana el primero" "1|0" "$(n '| Rama uno |')|$(n 'Rama dos')"
chk "el segundo en cuarentena" "1" "$(cuar)"
has "motivo tema-cambiado" "$(razon)" "^tema-cambiado:"

echo "== 10. evento sin ts: cuarentena malformed, fichero intacto =="
fixture "$FILA" ""
ANTES=$(sha)
rn --slug demo --tema "Sin ts"
python3 - "$M/.journal/pending" <<'PY'
import json, os, sys
d = sys.argv[1]
for f in os.listdir(d):
    p = os.path.join(d, f); ev = json.load(open(p)); ev.pop("ts", None)
    json.dump(ev, open(p, "w"))
PY
compact --quiet >/dev/null 2>&1
chk "cuarentena" "1" "$(cuar)"
has "motivo malformed ts" "$(razon)" "malformed: research.rename sin 'ts'"
chk "fichero intacto" "$ANTES" "$(sha)"

echo "== 11. una fila en Completed tambien se renombra =="
fixture "" '| Viejo cerrado | salio bien | [[research/cerrado]] _completado: 2026-09-01_ |'
rn --slug cerrado --tema "Nuevo cerrado"; compact --quiet >/dev/null
chk "renombrada, marca intacta" "1|0" "$(n '| Nuevo cerrado | salio bien | [[research/cerrado]] _completado: 2026-09-01_ |')|$(n 'Viejo cerrado')"

echo "== 12. el mismo slug en Active y en Completed (reapertura a mano): se renombran las dos =="
fixture "$FILA" '| Tema viejo | salio | [[research/demo]] _completado: 2026-09-01_ |'
rn --slug demo --tema "Tema doble"; compact --quiet >/dev/null
chk "dos filas con el tema nuevo, 0 con el viejo" "2|0" "$(n '| Tema doble |')|$(n 'Tema viejo')"

echo "== 13. enlace con alias: se encuentra, el alias queda intacto =="
fixture '| Con alias | leer | [[sessions/s]] | [[research/ali\|el alias]] |' ""
rn --slug ali --tema "Alias renombrado"; compact --quiet >/dev/null
chk "renombrada con alias intacto" "1" "$(n '| Alias renombrado | leer | [[sessions/s]] | [[research/ali\|el alias]] |')"

echo "== 14. una fila que solo CITA el research no es suya =="
fixture '| Ajeno | ver [[research/demo]] | [[sessions/s]] | [[research/ajeno]] |
'"$FILA" ""
rn --slug demo --tema "Solo la mia"; compact --quiet >/dev/null
chk "la ajena intacta, la propia renombrada" "1|1" "$(n '| Ajeno |')|$(n '| Solo la mia |')"

echo "== 15. tabla de formato viejo: cuarentena research-legacy, fichero intacto =="
M="$T/legacy/memory"; mkdir -p "$M"; IDX="$M/_research-index.md"; LOG="$M/../compact.log"
printf -- '---\ntype: index\n---\n# Research\n\n## Active Research\n\n| Slug | Topic | Fecha | Sesion |\n|---|---|---|---|\n| [[research/viejo]] | Topic viejo | 2026-01-01 | s |\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n' > "$IDX"
ANTES=$(sha)
rn --slug viejo --tema "Topic nuevo" --tema-viejo "Topic viejo"; compact --quiet >/dev/null 2>&1
has "motivo research-legacy" "$(razon)" "^research-legacy:"
chk "fichero intacto" "$ANTES" "$(sha)"

echo "== 16. emisor: sin fila y sin --tema-viejo sale con error y no emite =="
fixture "" ""
if emit --type research.rename --slug nadie --tema "X"; then r=emitio; else r=rechazo; fi
chk "rechaza" "rechazo" "$r"
has "dice por que" "$(cat "$M/../emit.err")" "tema-viejo"
chk "pending vacio" "0" "$(ls "$M/.journal/pending" 2>/dev/null | wc -l | tr -d ' ')"

echo "== 17. emisor: rellena --tema-viejo desde la fila por slug, y escapa '|' del tema nuevo =="
fixture "$FILA" ""
rn --slug demo --tema "Con | barra"
chk "tema_viejo en el payload" "Tema viejo" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["payload"]["tema_viejo"])' "$EV")"
compact --quiet >/dev/null
chk "barra escapada, fila de 4 columnas" "1" "$(n '| Con \| barra | leer | [[sessions/s]] | [[research/demo]] |')"

echo "== 18. replay del ULTIMO rename tras una edicion a mano de la celda: noop, sin cuarentena =="
# Un replay es un replay aunque la celda haya cambiado despues por fuera del journal: la guarda de
# orden es `<=`, no `<`. Con `<` este caso caia en tema-cambiado (adversario, ronda delta).
fixture "$FILA" ""
rn --slug demo --tema "Tema B"; AB=$EV; compact --quiet >/dev/null
sed -i.bak 's/| Tema B |/| Tema a mano |/' "$IDX"
replay "$AB"
chk "sigue la edicion a mano" "1" "$(n '| Tema a mano |')"
chk "sin cuarentena" "0" "$(cuar)"

echo
echo "RESULTADO: $pass ok, $fail fallas"
[ "$fail" = 0 ]
