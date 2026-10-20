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

echo "== 5. un evento que falla a MEDIAS no deja escrito nada: los indices vuelven a como estaban =="
# pendiente.resolve escribe _pendientes.md (quita la linea) y _resueltos.md (la archiva) y despues
# revienta en la fila mensual con una nota que no es cadena (revisor externo, ronda 3). Sin deshacer,
# el evento iba a cuarentena con el pendiente ya cerrado en el indice y abierto en el mensual.
huella() {  # hash de cada .md de memory/ fuera de .journal, con su ruta
  (cd "$M" && find . -path ./.journal -prune -o -type f -name '*.md' -print | LC_ALL=C sort | while read -r f; do
    printf '%s %s\n' "$f" "$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f")"
  done)
}
for campo in nota sesion estado; do
  fixture
  A=$(emit --type pendiente.add --text "a cerrar con $campo" --prioridad Baja --origen "$ORI" --creado 2026-10-01)
  compact --quiet >/dev/null
  ANTES=$(huella)
  emit --type pendiente.resolve --id "$A" --estado resolved --sesion "$ORI" >/dev/null
  estropear "$campo" '["x"]'
  RC=0; OUT=$(compact 2>&1) || RC=$?
  chk "resolve $campo lista: sale 0" "0" "$RC"
  chk "resolve $campo lista: va a cuarentena como error-interno" "1" "$(razon | grep -c '^error-interno: ')"
  chk "resolve $campo lista: los indices quedan como estaban" "$ANTES" "$(huella)"
  chk "resolve $campo lista: el pendiente sigue abierto" "1" "$(grep -c "a cerrar con $campo" "$M/_pendientes.md")"
  chk "resolve $campo lista: sin temporales sueltos" "0" "$(find "$M" -name '*.tmp' | wc -l | tr -d ' ')"
  emit --type pendiente.add --text "despues de $campo" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
  RC=0; OUT=$(compact 2>&1) || RC=$?
  chk "resolve $campo lista: la pasada siguiente aplica" "1" "$(grep -c "despues de $campo" "$M/_pendientes.md")"
  chk "resolve $campo lista: y no reporta deriva" "0" "$(printf '%s' "$OUT" | grep -c 'fuera-de-banda')"
done

echo "== 6. un sustituto suelto no deja el temporal de atomic_write =="
fixture
emit --type pendiente.add --text "base" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
compact --quiet >/dev/null
ANTES=$(huella)
emit --type pendiente.add --text "sust" --prioridad Baja --origen "$ORI" --creado 2026-10-01 >/dev/null
estropear text '"x \ud800 y"'
compact --quiet >/dev/null 2>&1
chk "sustituto: sin temporales sueltos" "0" "$(find "$M" -name '*.tmp' | wc -l | tr -d ' ')"
chk "sustituto: los indices quedan como estaban" "$ANTES" "$(huella)"

echo "== 7. lo que el evento anoto en reabiertos.log tambien se anula =="
# pendiente.reopen anota el cierre que revierte ANTES de tocar el indice y escribe _pendientes.md
# antes de limpiar la fila mensual. Ningun campo del evento hace fallar esa limpieza (por eso se
# fuerza: el compactador se importa y limpiar_mensual_reabierto lanza TypeError). Sin anular la
# anotacion, el reopen bueno de despues veria ese cierre como ya revertido y no reabriria.
fixture
A=$(emit --type pendiente.add --text "a reabrir" --prioridad Baja --origen "$ORI" --creado 2026-10-01)
emit --type pendiente.resolve --id "$A" --estado resolved --sesion "$ORI" >/dev/null
compact --quiet >/dev/null
ANTES=$(huella)
emit --type pendiente.reopen --id "$A" >/dev/null
RC=0; python3 -I - "$BIN/journal-compact.py" "$M" <<'PY' >/dev/null 2>&1 || RC=$?
import importlib.util, sys
spec = importlib.util.spec_from_file_location("jc", sys.argv[1])
jc = importlib.util.module_from_spec(spec)
mem = sys.argv[2]
sys.argv = [sys.argv[1]]
spec.loader.exec_module(jc)
def falla(*a, **k):
    raise TypeError("limpieza forzada")
jc.limpiar_mensual_reabierto = falla
sys.exit(jc.compact(mem, 5.0, True))
PY
chk "reopen forzado: sale 0" "0" "$RC"
chk "reopen forzado: va a cuarentena como error-interno" "1" "$(razon | grep -c '^error-interno: TypeError: limpieza forzada')"
chk "reopen forzado: los indices quedan como estaban" "$ANTES" "$(huella)"
vivas() {  # anotaciones de $1 en reabiertos.log sin su anulacion
  python3 -I - "$M/.journal/reabiertos.log" "$1" <<'PY'
import sys, collections
c = collections.Counter()
try:
    for l in open(sys.argv[1], encoding="utf-8"):
        k, ts = l.split("\t")[:2]
        if k == sys.argv[2]:
            c[ts.lstrip("-")] += -1 if ts.startswith("-") else 1
except FileNotFoundError:
    pass
print(sum(v for v in c.values() if v > 0))
PY
}
chk "reopen forzado: ninguna anotacion queda viva" "0" "$(vivas "$A")"
emit --type pendiente.reopen --id "$A" >/dev/null
compact --quiet >/dev/null 2>&1
chk "reopen bueno despues: el pendiente vuelve a estar abierto" "1" "$(grep -c 'a reabrir' "$M/_pendientes.md")"

echo "== 8. atomic_write que falla fuera de un evento tampoco deja su temporal =="
# Dentro de un evento, deshacer_evento restaura con el mismo nombre de temporal y se lo lleva; fuera
# (o cuando el fallo sube como OSError y no hay deshacer) solo lo borra atomic_write.
fixture
RC=0; python3 -I - "$BIN/journal-compact.py" "$M/_pendientes.md" <<'PY' >/dev/null 2>&1 || RC=$?
import importlib.util, sys
spec = importlib.util.spec_from_file_location("jc", sys.argv[1])
jc = importlib.util.module_from_spec(spec)
path = sys.argv[2]
sys.argv = [sys.argv[1]]
spec.loader.exec_module(jc)
try:
    jc.atomic_write(path, ["x \ud800 y", ""])
except UnicodeEncodeError:
    sys.exit(0)
sys.exit(3)
PY
chk "atomic_write con sustituto: lanza UnicodeEncodeError" "0" "$RC"
chk "atomic_write con sustituto: sin temporales sueltos" "0" "$(find "$M" -name '*.tmp' | wc -l | tr -d ' ')"

echo "== 9. una restauracion que falla se nombra en el motivo y no deja temporal =="
# Forzado: tras escribir _pendientes.md, el resolve revienta y el os.replace de la restauracion de
# ese fichero da PermissionError (revisor externo, ronda 6: ahi quedaba el temporal).
fixture
A=$(emit --type pendiente.add --text "restauracion rota" --prioridad Baja --origen "$ORI" --creado 2026-10-01)
compact --quiet >/dev/null
emit --type pendiente.resolve --id "$A" --estado resolved --sesion "$ORI" >/dev/null
RC=0; python3 -I - "$BIN/journal-compact.py" "$M" <<'PY' >/dev/null 2>&1 || RC=$?
import importlib.util, sys
spec = importlib.util.spec_from_file_location("jc", sys.argv[1])
jc = importlib.util.module_from_spec(spec)
mem = sys.argv[2]
sys.argv = [sys.argv[1]]
spec.loader.exec_module(jc)
real = jc.replace_with_retry
def falla(*a, **k):
    def rota(src, dst):   # solo la restauracion: la escritura del resolve ya ocurrio
        if dst.endswith("_pendientes.md"):
            jc.replace_with_retry = real
            raise PermissionError(13, "denegado")
        return real(src, dst)
    jc.replace_with_retry = rota
    jc.apply_resolve_monthly = orig
    raise TypeError("resolve forzado")
orig = jc.apply_resolve_monthly
jc.apply_resolve_monthly = falla
sys.exit(jc.compact(mem, 5.0, True))
PY
chk "restauracion rota: sale 0" "0" "$RC"
chk "restauracion rota: el motivo nombra el fichero" "1" "$(razon | grep -c 'NO se pudo restaurar, queda a medias: _pendientes.md')"
chk "restauracion rota: sin temporales sueltos" "0" "$(find "$M" -name '*.tmp' | wc -l | tr -d ' ')"

echo "RESULTADO: $pass ok, $fail fallas"
[ "$fail" -eq 0 ]
