#!/bin/bash
# Prueba de que una excepcion cualquiera de apply_event ya no atasca el compactador (2.63.11).
#
# validate deja pasar eventos con un campo de texto que no es cadena (session.add con status=1,
# pendiente.add con text=1) o con un sustituto suelto (\ud800) que utf-8 no codifica. apply_event
# lanzaba TypeError / UnicodeEncodeError, que no es Quarantine: la pasada salia con traceback, el
# evento se quedaba en pending/ y, como se aplican en orden de nombre, ningun evento de detras se
# aplicaba nunca (p-ac5a4bb888). Aqui:
#  1-2. un evento asi va a cuarentena con motivo `error-interno: <Tipo>: ...`, la pasada sale 0 y
#       aplica el evento bueno de detras; la pasada siguiente no revienta, no rescata el evento y
#       no reporta deriva (antes guardar_huellas no corria y salia FUERA DEL JOURNAL);
#  3. un fallo de ESCRITURA (OSError) no va a cuarentena: el evento sigue en pending/ y el
#     reintento aplica;
#  4. un indice con bytes que no son utf-8 (UnicodeDecodeError) tampoco: el fallo es del fichero,
#     no del evento, y mandarlo a cuarentena se llevaria todos los eventos de ese indice.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
unset CLAUDE_CODE_SESSION_ID MEMORY_DIR CLAUDE_PROJECT_DIR
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
pend() { ls "$M/.journal/pending" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
razon() { cat "$M"/.journal/quarantine/*.reason 2>/dev/null; }
ORI="[[sessions/2026-10-01-origen]]"
fixture() {
  chmod -R u+w "$M" 2>/dev/null; rm -rf "$M"; mkdir -p "$M/pendientes" "$M/sessions"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '# origen\n' > "$M/sessions/2026-10-01-origen.md"
}
estropear() {  # pone payload[$1] = valor JSON $2 en el evento $3 (0 = el mas antiguo, -1 = el ultimo)
  python3 -I - "$M/.journal/pending" "$1" "$2" "${3:-0}" <<'PY'
import json, os, sys
d, campo, valor, i = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), int(sys.argv[4])
f = sorted(n for n in os.listdir(d) if n.endswith(".json"))[i]
ev = json.load(open(os.path.join(d, f)))
ev["payload"][campo] = valor
json.dump(ev, open(os.path.join(d, f), "w"))
PY
}
echo "python3: $(python3 --version 2>&1)"

caso() {  # $1 etiqueta, $2 campo, $3 valor JSON, $4 tipo de excepcion esperado
  fixture
  emit --type pendiente.add --text "malo" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
  estropear "$2" "$3"
  emit --type pendiente.add --text "bueno detras" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
  chk "$1: los dos eventos estan en pending" "2" "$(pend)"
  RC=0; OUT=$(compact 2>&1) || RC=$?
  chk "$1: la compactacion no revienta" "0" "$(printf '%s' "$OUT" | grep -c 'Traceback')"
  chk "$1: sale 0" "0" "$RC"
  chk "$1: el malo va a cuarentena" "1" "$(cuar)"
  chk "$1: no queda nada en pending" "0" "$(pend)"
  chk "$1: el motivo dice error-interno y el tipo" "1" "$(razon | grep -c "^error-interno: $4: ")"
  chk "$1: el bueno de detras se aplica" "1" "$(grep -c 'bueno detras' "$M/_pendientes.md")"
  RC=0; OUT=$(compact 2>&1) || RC=$?
  chk "$1: la pasada siguiente sale 0" "0" "$RC"
  chk "$1: el malo no se rescata" "1" "$(cuar)"
}

echo "== 1. un campo que no es cadena (TypeError) va a cuarentena y la pasada sigue =="
caso "text=1" text 1 TypeError

echo "== 1b. el bueno DELANTE del malo: la pasada siguiente no reporta deriva =="
# Antes, el bueno se aplicaba, el malo reventaba y guardar_huellas no corria: la pasada siguiente
# veia el indice que el bueno habia cambiado como escrito FUERA DEL JOURNAL.
fixture
emit --type pendiente.add --text "base" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
compact --quiet >/dev/null   # primera linea base de huellas: sin ella no hay deriva que ver
emit --type pendiente.add --text "bueno delante" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
emit --type pendiente.add --text "malo" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
estropear text 1 -1
RC=0; compact >/dev/null 2>&1 || RC=$?
chk "bueno delante: sale 0" "0" "$RC"
chk "bueno delante: se aplica" "1" "$(grep -c 'bueno delante' "$M/_pendientes.md")"
RC=0; OUT=$(compact 2>&1) || RC=$?
chk "bueno delante: la pasada siguiente no reporta deriva" "0" "$(printf '%s' "$OUT" | grep -c 'fuera-de-banda')"

echo "== 2. un sustituto suelto (UnicodeEncodeError) va a cuarentena y la pasada sigue =="
caso "text con \\ud800" text '"x \ud800 y"' UnicodeEncodeError

if [ "$(id -u)" != 0 ]; then
  echo "== 3. un fallo de escritura (OSError) no va a cuarentena: el evento espera al reintento =="
  fixture
  emit --type pendiente.add --text "espera" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
  chmod 444 "$M/_pendientes.md"; chmod 555 "$M"   # mismo truco que test-session-amend.sh (Windows)
  compact --quiet >/dev/null 2>&1
  chmod 755 "$M"; chmod 644 "$M/_pendientes.md"
  chk "OSError: sin cuarentena" "0" "$(cuar)"
  chk "OSError: el evento sigue en pending" "1" "$(pend)"
  compact --quiet >/dev/null 2>&1
  chk "OSError: el reintento aplica" "1" "$(grep -c 'espera' "$M/_pendientes.md")"
fi

echo "== 4. un indice que no es utf-8 (UnicodeDecodeError) no manda el evento a cuarentena =="
fixture
emit --type pendiente.add --text "tras arreglo" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
printf '\xff\xfe roto\n' >> "$M/_pendientes.md"
compact --quiet >/dev/null 2>&1
chk "UnicodeDecodeError: sin cuarentena" "0" "$(cuar)"
chk "UnicodeDecodeError: el evento sigue en pending" "1" "$(pend)"
python3 -I -c 'import sys; p=sys.argv[1]; b=open(p,"rb").read().replace(b"\xff\xfe roto\n", b""); open(p,"wb").write(b)' "$M/_pendientes.md"
compact --quiet >/dev/null 2>&1
chk "UnicodeDecodeError: arreglado el indice, el evento se aplica" "1" "$(grep -c 'tras arreglo' "$M/_pendientes.md")"

echo "error-interno: $pass ok, $fail fallas"
[ "$fail" -eq 0 ]
