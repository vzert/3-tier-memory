#!/bin/bash
# Guardian de reversa de `plan.upsert` + evento `plan.reopen` (2.37.0, pendiente p-014255373e).
#
# El hueco, medido antes del arreglo: `apply_plan_upsert` sobreescribia la celda Status sin
# mirar, asi que el replay de un `plan.upsert --status active` viejo sobre un plan ya
# `completed` daba `applied=1` y la fila volvia a `active`. En silencio. research hacia lo
# contrario (prohibia la reversa con un `return False` mudo). Diseno: CHANGELOG 2.31.0, "3.
# plan.reopen".
#
# Las tres corridas del criterio verificable del diseno son los casos 1, 2 y 3. El resto son los
# bordes: el cierre NUEVO tras un reopen pasa, el replay del propio reopen no reabre un cierre
# posterior, la anotacion de fase sobrevive, inline, fila podada y evento sin ts.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }

fixture() {
  M="$T/m$RANDOM$RANDOM/memory"; mkdir -p "$M"
  printf -- '---\ntype: index\nupdated: 2026-01-01\n---\n# Plans Index\n' > "$M/_plans-index.md"
  LOG="$M/../compact.log"
}
# emit ... -> guarda en $EV la ruta del evento recien emitido (para reinyectarlo despues).
emit() {
  local antes; antes=$(ls "$M/.journal/pending" 2>/dev/null)
  python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@" >/dev/null
  EV=$(comm -13 <(printf '%s\n' "$antes" | sort) <(ls "$M/.journal/pending" | sort) | head -1)
  cp "$M/.journal/pending/$EV" "$M/../$EV.bak"
  EV="$M/../$EV.bak"
}
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" --log "$LOG" "$@"; }
replay() { cp "$1" "$M/.journal/pending/$(basename "$1" .bak)"; compact --quiet >/dev/null; }
status() { grep -F "$1" "$M/_plans-index.md" | awk -F' \\| ' '{print $2}'; }
cuar() { ls "$M/.journal/quarantine/"*.json 2>/dev/null | wc -l | tr -d ' '; }
reab() { grep -c "^plan-$1	" "$M/.journal/reabiertos.log" 2>/dev/null || echo 0; }
up() { emit --type plan.upsert --slug demo --title Demo --date 2026-09-01 "$@"; }

echo "== 1. replay de un upsert --status active viejo sobre un plan completed NO lo reabre =="
fixture
up --status active; ACT=$EV; compact --quiet >/dev/null
up --status completed; compact --quiet >/dev/null
chk "cerrado antes del replay" "completed" "$(status plan-demo)"
replay "$ACT"
chk "sigue completed tras el replay" "completed" "$(status plan-demo)"
chk "sin cuarentena (un replay no es un error)" "0" "$(cuar)"
has "deja aviso con la salida" "$(cat "$LOG")" "plan.reopen --slug demo"

echo "== 2. plan.reopen explicito SI lo reabre, y deja registro =="
emit --type plan.reopen --slug demo; REOPEN=$EV
OUT=$(compact)
chk "active" "active" "$(status plan-demo)"
has "cuenta como aplicado" "$OUT" "applied=1"
chk "una linea plan-demo en reabiertos.log" "1" "$(reab demo)"
chk "sin cuarentena" "0" "$(cuar)"
chk "bump de updated en el indice" "1" "$(grep -c "^updated: $(date +%Y-%m-%d)" "$M/_plans-index.md")"

echo "== 3. el replay del cierre que vino ANTES del reopen no lo vuelve a cerrar =="
# Se recupera el evento de cierre del caso 1 desde applied/.
CIERRE=$(grep -l '"completed"' "$M"/.journal/applied/*/*.json | head -1)
cp "$CIERRE" "$M/.journal/pending/"; compact --quiet >/dev/null
chk "sigue active" "active" "$(status plan-demo)"
has "aviso de cierre revertido" "$(cat "$LOG")" "se reabrio DESPUES de este cierre"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 4. un cierre NUEVO despues del reopen SI cierra =="
up --status completed; NUEVO=$EV; compact --quiet >/dev/null
chk "completed" "completed" "$(status plan-demo)"

echo "== 5. replay del reopen viejo NO reabre el cierre posterior =="
replay "$REOPEN"
chk "sigue completed" "completed" "$(status plan-demo)"
chk "no anota una segunda reapertura" "1" "$(reab demo)"

echo "== 6. reopen idempotente sobre un plan ya abierto: noop mudo, sin registro =="
fixture
up --status active; compact --quiet >/dev/null
emit --type plan.reopen --slug demo
OUT=$(compact)
has "noop" "$OUT" "noop=1"
chk "sin registro" "0" "$(reab demo)"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 7. cerrado -> cerrado no es retroceso: completed -> superseded pasa =="
fixture
up --status completed; compact --quiet >/dev/null
up --status superseded; compact --quiet >/dev/null
chk "superseded" "superseded" "$(status plan-demo)"

echo "== 8. retroceso a un status que no es active (paused) tambien se frena =="
up --status paused; compact --quiet >/dev/null
chk "sigue superseded" "superseded" "$(status plan-demo)"

echo "== 9. la anotacion de fase sobrevive al guardian y al reopen =="
fixture
emit --type plan.upsert --slug padre --title Padre --date 2026-09-01 --status active
emit --type plan.upsert --slug hijo --title Hijo --date 2026-09-01 --status active --parent padre; VIEJO=$EV
compact --quiet >/dev/null
emit --type plan.upsert --slug hijo --title Hijo --date 2026-09-01 --status completed; compact --quiet >/dev/null
chk "cerrado con fase" "completed (fase de plan-padre)" "$(status plan-hijo)"
replay "$VIEJO"
chk "el replay con --parent no lo reabre ni cuarentena" "completed (fase de plan-padre)|0" "$(status plan-hijo)|$(cuar)"
emit --type plan.reopen --slug hijo; compact --quiet >/dev/null
chk "reabierto conserva la fase" "active (fase de plan-padre)" "$(status plan-hijo)"

echo "== 10. plan --inline: se reabre por --title =="
fixture
emit --type plan.upsert --slug suelto --title "Plan suelto" --date 2026-09-01 --status active --inline
compact --quiet >/dev/null
emit --type plan.upsert --slug suelto --title "Plan suelto" --date 2026-09-01 --status completed --inline
compact --quiet >/dev/null
emit --type plan.upsert --slug suelto --title "Plan suelto" --date 2026-09-01 --status active --inline
compact --quiet >/dev/null
chk "upsert active no reabre un inline cerrado" "completed" "$(status 'Plan suelto (inline)')"
emit --type plan.reopen --slug suelto; compact --quiet >/dev/null 2>&1
chk "sin --title: cuarentena no-fila" "1" "$(cuar)"
has "el motivo pide --title" "$(cat "$M"/.journal/quarantine/*.reason)" "falta --title"
emit --type plan.reopen --slug suelto --title "Plan suelto"; compact --quiet >/dev/null
chk "con --title: active" "active" "$(status 'Plan suelto (inline)')"

echo "== 11. plan sin fila (podado): cuarentena con motivo, no invento =="
fixture
emit --type plan.reopen --slug fantasma; compact --quiet >/dev/null 2>&1
chk "cuarentena" "1" "$(cuar)"
has "motivo no-fila" "$(cat "$M"/.journal/quarantine/*.reason)" "no-fila"
chk "no escribio una fila" "0" "$(grep -c fantasma "$M/_plans-index.md")"
chk "no dejo registro" "0" "$(reab fantasma)"

echo "== 12. cierre sin ts tras un reopen: se aplica con aviso (no se pierde la escritura) =="
fixture
up --status completed; compact --quiet >/dev/null
emit --type plan.reopen --slug demo; compact --quiet >/dev/null
up --status completed
python3 - "$(ls "$M"/.journal/pending/*.json)" <<'PY'
import json, sys
p = sys.argv[1]; e = json.load(open(p)); e.pop("ts", None); json.dump(e, open(p, "w"))
PY
compact --quiet >/dev/null
chk "completed" "completed" "$(status plan-demo)"
has "aviso de ts ausente" "$(cat "$LOG")" "no trae ts"

echo "== 13. un evento plan.reopen escrito a mano sin slug: cuarentena malformed =="
fixture
mkdir -p "$M/.journal/pending"
printf '{"v":1,"type":"plan.reopen","ts":1,"session_id":"x","agent_id":"x","payload":{}}' \
  > "$M/.journal/pending/1-x-1-0.json"
compact --quiet >/dev/null 2>&1
has "malformed" "$(cat "$M"/.journal/quarantine/*.reason)" "malformed: plan.reopen sin 'slug'"

echo "== 14. emisor: plan.reopen exige --slug =="
fixture
chk "sale con error" "1" "$(python3 "$BIN/journal-emit.py" --memory-dir "$M" --type plan.reopen >/dev/null 2>&1 && echo 0 || echo 1)"

echo
echo "RESULTADO: $pass ok, $fail fallas"
[ "$fail" -eq 0 ]
