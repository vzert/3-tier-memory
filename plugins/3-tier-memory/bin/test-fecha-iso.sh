#!/bin/bash
# Prueba de que las fechas del journal son AAAA-MM-DD en cualquier Python 3 (2.63.7).
#
# date.fromisoformat acepta 20261016 y 2026-W42-5 desde Python 3.11 (en 3.9 no). journal-emit validaba
# --creado y --revisar con el, asi que con 3.11+ dejaba pasar `--creado 20261016`; el compactador
# escribia la linea de Tier 2, reventaba al crear la fila mensual (ValueError en ensure_monthly) y el
# evento se quedaba en pending/: cada compactacion siguiente reventaba igual y ningun evento nuevo se
# aplicaba. Aqui:
#  1. el emisor rechaza las formas anchas en cada flag de fecha, y acepta AAAA-MM-DD (control);
#  2. un evento con fecha ancha escrito a mano en pending/ va a cuarentena, la pasada sigue y aplica
#     el evento bueno que va detras, y la linea mala no llega a _pendientes.md.
# Corre con el python3 del PATH: verde en 3.9 y en 3.14.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset CLAUDE_CODE_SESSION_ID MEMORY_DIR CLAUDE_PROJECT_DIR
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
pend() { ls "$M/.journal/pending" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
ORI="[[sessions/2026-10-01-origen]]"
fixture() {
  rm -rf "$M"; mkdir -p "$M/pendientes" "$M/sessions"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '# origen\n' > "$M/sessions/2026-10-01-origen.md"
}
echo "python3: $(python3 --version 2>&1)"

echo "== 1. el emisor solo acepta AAAA-MM-DD =="
fixture
ID=$(emit --type pendiente.add --text "base" --prioridad Baja --origen "$ORI" --creado 2026-10-01)
compact --quiet >/dev/null
chk "control: --creado 2026-10-01 se acepta" "1" "$(printf '%s' "$ID" | grep -c '^p-')"
for forma in 20261016 2026-W42-5 2026W425 2026-10-16x; do
  RC=0; emit --type pendiente.add --text "c $forma" --prioridad Baja --origen "$ORI" --creado "$forma" >/dev/null 2>&1 || RC=$?
  chk "pendiente.add --creado $forma: error" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
  RC=0; emit --type pendiente.add --text "r $forma" --prioridad Baja --origen "$ORI" --revisar "$forma" >/dev/null 2>&1 || RC=$?
  chk "pendiente.add --revisar $forma: error" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
  RC=0; emit --type pendiente.window --id "$ID" --revisar "$forma" >/dev/null 2>&1 || RC=$?
  chk "pendiente.window --revisar $forma: error" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
done
chk "y no dejan evento" "0" "$(pend)"
RC=0; emit --type pendiente.window --id "$ID" --revisar 2026-11-01 >/dev/null 2>&1 || RC=$?
chk "control: pendiente.window --revisar 2026-11-01 se acepta" "0" "$RC"

echo "== 2. un evento con fecha ancha en pending/ va a cuarentena y la pasada sigue =="
for campo in creado revisar; do
  fixture
  mkdir -p "$M/.journal/pending"
  python3 -I - "$M/.journal/pending" "$campo" <<'PY'
import hashlib, json, os, sys, time
d, campo = sys.argv[1], sys.argv[2]
def ev(texto, extra, ts):
    p = {"text": texto, "prioridad": "Baja", "origen": "[[sessions/2026-10-01-origen]]",
         "creado": "2026-10-01", "revisar": ""}
    p.update(extra)
    p["id"] = "p-" + hashlib.sha1((texto + p["creado"] + p["origen"]).encode()).hexdigest()[:10]
    return {"v": 1, "type": "pendiente.add", "ts": ts, "session_id": "prueba", "agent_id": "a",
            "payload": p}
t = time.time_ns()
for i, e in enumerate([ev("malo", {campo: "20261016"}, t), ev("bueno detras", {}, t + 1)]):
    json.dump(e, open(os.path.join(d, f"{t + i}-prueba-1-{i}.json"), "w"))
PY
  RC=0; OUT=$(compact 2>&1) || RC=$?
  chk "$campo ancho: la compactacion no revienta" "0" "$(printf '%s' "$OUT" | grep -c 'Traceback')"
  chk "$campo ancho: sale 0" "0" "$RC"
  chk "$campo ancho: el malo va a cuarentena" "1" "$(cuar)"
  chk "$campo ancho: no queda nada en pending" "0" "$(pend)"
  chk "$campo ancho: el bueno de detras se aplica" "1" "$(grep -c 'bueno detras' "$M/_pendientes.md")"
  chk "$campo ancho: la linea mala no llega a _pendientes.md" "0" "$(grep -c '\- \[ \] malo' "$M/_pendientes.md" || true)"
  RC=0; OUT=$(compact 2>&1) || RC=$?
  chk "$campo ancho: la pasada siguiente tampoco revienta" "0" "$RC"
done

echo "== 3. la fecha del marcador de CUALQUIER evento: con forma ancha va a cuarentena =="
# El emisor siempre pone la fecha de hoy; esto cubre un evento escrito o editado a mano. Antes solo
# learning.add/retire la validaban, y un resolve con fecha 20261016 llegaba a la celda Resuelto y a
# `_resuelto: 20261016_`, que MARCA_RESUELTO_RE no quita al reabrir (revisor, ciclo 2).
ancha() {  # cambia la fecha del ultimo evento de pending/ por 20261016
  python3 -I - "$M/.journal/pending" <<'PY'
import json, os, sys
d = sys.argv[1]
f = sorted(os.listdir(d))[-1]
ev = json.load(open(os.path.join(d, f)))
ev["payload"]["fecha"] = "20261016"
json.dump(ev, open(os.path.join(d, f), "w"))
PY
}
for tipo in resolve expire reopen update window retomar; do
  fixture
  A=$(emit --type pendiente.add --text "el de $tipo" --prioridad Baja --origen "$ORI" --creado 2026-10-01)
  if [ "$tipo" = reopen ]; then
    emit --type pendiente.resolve --id "$A" --estado resolved --sesion "$ORI" >/dev/null
  fi
  compact --quiet >/dev/null
  case "$tipo" in
    resolve) emit --type pendiente.resolve --id "$A" --estado resolved --sesion "$ORI" ;;
    expire)  emit --type pendiente.expire --id "$A" --dias 30 ;;
    reopen)  emit --type pendiente.reopen --id "$A" ;;
    update)  emit --type pendiente.update --id "$A" --prioridad Media ;;
    window)  emit --type pendiente.window --id "$A" --revisar 2026-11-01 ;;
    retomar) emit --type pendiente.retomar --id "$A" --retomar 2026-10-19 --ficha sessions/2026-10-01-origen ;;
  esac >/dev/null
  ancha
  emit --type pendiente.add --text "bueno tras $tipo" --prioridad Baja --origen "$ORI" >/dev/null
  RC=0; OUT=$(compact 2>&1) || RC=$?
  chk "$tipo con fecha ancha: sale 0 sin traceback" "0:0" "$RC:$(printf '%s' "$OUT" | grep -c Traceback)"
  chk "$tipo con fecha ancha: va a cuarentena" "1" "$(cuar)"
  chk "$tipo con fecha ancha: el bueno de detras se aplica" "1" "$(grep -c "bueno tras $tipo" "$M/_pendientes.md")"
  chk "$tipo con fecha ancha: 20261016 no llega a la memoria" "0" "$(grep -rl 20261016 "$M" --exclude-dir=.journal | wc -l | tr -d ' ')"
done

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
