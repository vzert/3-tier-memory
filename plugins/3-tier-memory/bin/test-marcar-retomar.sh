#!/bin/bash
# Prueba de `marcar-retomar.py` (Step 8a2) y del evento `pendiente.retomar` (2.62.8).
#
# Que tiene que cumplir, y por que:
# - El pendiente que cita el `Proximo paso` de una ficha queda con `_retomar: HOY sessions/<slug>_`,
#   escrito por evento (nunca a mano), para que el mod pendientes lo saque en PLANES ACTIVOS y no se pierda
#   si el snippet no se pega (decision de Victor d65-d68, 2026-10-16).
# - Es un campo APARTE de `_revisar`: con `_revisar` = hoy el 🔔 de 8e de cualquier cierre del dia
#   sacaba el paso de otra sesion y `hacible()` lo sacaba del hilo. El caso 6 mide que con
#   `_retomar` eso no pasa y que con `_revisar` si pasaria (si no, el caso no discrimina).
# - Con `_revisar` FUTURO no se marca: Step 8 no elige trabajo de fecha futura.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
HOY=2026-10-16
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
marcar() { python3 "$BIN/marcar-retomar.py" "$@" --hoy "$HOY"; }
linea() { grep -m1 "_id: $1_" "$M/_pendientes.md" || true; }
cuarentena() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
eventos() { grep -rl '"pendiente.retomar"' "$M/.journal" 2>/dev/null | wc -l | tr -d ' '; }

ficha() {  # ficha SLUG "texto del Proximo paso"
  cat > "$M/sessions/$1.md" <<EOF
---
type: session
date: $HOY
---
# demo

## Como retomar

\`\`\`
Retomamos: demo de $1.

Lee memory/sessions/$1.md para el contexto completo.

Proximo paso: $2

Terminas cuando: la prueba pasa.

Antes de actuar, dime en 3 lineas donde quedamos.
\`\`\`
EOF
}

fixture() {
  rm -rf "$M"; mkdir -p "$M/pendientes" "$M/sessions"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '# origen\n' > "$M/sessions/2026-10-01-origen.md"
  A=$(emit --type pendiente.add --text "anadir el paso A al checkpoint" --prioridad Alta \
        --origen "[[sessions/2026-10-01-origen]]" --creado 2026-10-01)
  B=$(emit --type pendiente.add --text "medir el paso B en vivo" --prioridad Media \
        --origen "[[sessions/2026-10-01-origen]]" --creado 2026-10-01)
  F=$(emit --type pendiente.add --text "revisar el despliegue del viernes" --prioridad Alta \
        --origen "[[sessions/2026-10-01-origen]]" --creado 2026-10-01 --revisar 2026-10-30)
  compact --quiet >/dev/null
}

echo "== 1. marca el pendiente del Proximo paso, por evento =="
fixture
ficha 2026-10-16-uno "hacer $A (el paso A)."
OUT=$(marcar "$M/sessions/2026-10-16-uno.md")
chk "la linea lleva _retomar con hoy y la ficha" "1" "$(linea "$A" | grep -c "_retomar: $HOY sessions/2026-10-16-uno_")"
chk "lo dice en una linea" "1" "$(printf '%s\n' "$OUT" | grep -c "📌 $A: retomar $HOY")"
chk "uno y solo un evento pendiente.retomar" "1" "$(eventos)"
chk "conserva el texto" "1" "$(linea "$A" | grep -c 'anadir el paso A al checkpoint')"
chk "no toca _revisar (no lo tenia)" "0" "$(linea "$A" | grep -c '_revisar:')"
chk "no toca otro pendiente" "0" "$(linea "$B" | grep -c '_retomar:')"
chk "sin cuarentena" "0" "$(cuarentena)"
chk "repair-dualwrite: ids_invented=0" "1" "$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1 | grep -c 'ids_invented=0')"

echo "== 2. idempotente: otra pasada no emite ni duplica =="
OUT=$(marcar "$M/sessions/2026-10-16-uno.md")
chk "dice que ya esta" "1" "$(printf '%s\n' "$OUT" | grep -c 'ya marcado')"
chk "sigue habiendo un solo evento" "1" "$(eventos)"
chk "un solo campo _retomar" "1" "$(linea "$A" | grep -o '_retomar:' | wc -l | tr -d ' ')"

echo "== 3. otra ficha que cita el mismo pendiente al dia siguiente lo reemplaza =="
ficha 2026-10-17-dos "seguir con $A."
python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-17-dos.md" --hoy 2026-10-17 >/dev/null
chk "con su fecha y su ficha" "1" "$(linea "$A" | grep -c '_retomar: 2026-10-17 sessions/2026-10-17-dos_')"
chk "y un solo campo" "1" "$(linea "$A" | grep -o '_retomar:' | wc -l | tr -d ' ')"

echo "== 4. _revisar futuro: no lo marca y avisa =="
fixture
ficha 2026-10-16-fut "hacer $F."
OUT=$(marcar "$M/sessions/2026-10-16-fut.md")
chk "sin marca" "0" "$(linea "$F" | grep -c '_retomar:')"
chk "avisa del _revisar futuro" "1" "$(printf '%s\n' "$OUT" | grep -c "⚠ $F: tiene _revisar futuro (2026-10-30)")"
chk "sin eventos" "0" "$(eventos)"

echo "== 5. sin id, ninguno, cerrado y 'ver tambien': no marca =="
fixture
ficha 2026-10-16-plan "seguir el plan-demo, fase 2."
chk "paso sin p-: sin salida" "" "$(marcar "$M/sessions/2026-10-16-plan.md")"
cat > "$M/sessions/2026-10-16-ninguno.md" <<'EOF'
# demo

## Como retomar

Ninguno — la sesion cerro todo.
EOF
chk "caso 5 (ninguno): sin salida" "" "$(marcar "$M/sessions/2026-10-16-ninguno.md")"
ficha 2026-10-16-ver "hacer $A; ver tambien $B."
marcar "$M/sessions/2026-10-16-ver.md" >/dev/null
chk "el de ver tambien no se marca" "0" "$(linea "$B" | grep -c '_retomar:')"
chk "el del paso si" "1" "$(linea "$A" | grep -c '_retomar:')"
emit --type pendiente.resolve --id "$B" --estado resolved --nota "hecho" >/dev/null; compact --quiet >/dev/null
ficha 2026-10-16-cerrado "hacer $B."
OUT=$(marcar "$M/sessions/2026-10-16-cerrado.md")
chk "uno cerrado: lo dice y no emite" "1" "$(printf '%s\n' "$OUT" | grep -c "$B: no esta abierto")"
chk "sin cuarentena" "0" "$(cuarentena)"

echo "== 6. 8e y hacible() no cambian con _retomar (y si cambiarian con _revisar) =="
fixture
ficha 2026-10-16-uno "hacer $A."
ficha 2026-10-16-otra "hacer $B."
OPC() { python3 "$BIN/print-pendiente-opcional.py" "$M/sessions/2026-10-16-otra.md" --hoy "$HOY"; }
HAC() { python3 -I -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("pa", sys.argv[1]); pa = importlib.util.module_from_spec(s); s.loader.exec_module(pa)
p = [x for x in pa.pendientes(sys.argv[2]) if x["id"] == sys.argv[3]][0]
print(pa.hacible(p, sys.argv[4]))' "$BIN/pendientes_afines.py" "$M/_pendientes.md" "$A" "$HOY"; }
ANTES_8E=$(OPC); ANTES_H=$(HAC)
marcar "$M/sessions/2026-10-16-uno.md" >/dev/null
chk "8e de OTRA sesion: igual que sin la marca" "$ANTES_8E" "$(OPC)"
chk "8e no saca el pendiente marcado" "0" "$(OPC | grep -c "$A")"
chk "hacible() igual que sin la marca" "$ANTES_H" "$(HAC)"
chk "hacible() sigue en True" "True" "$(HAC)"
chk "el texto que ve el hilo no lleva la marca" "0" "$(python3 -I -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("pa", sys.argv[1]); pa = importlib.util.module_from_spec(s); s.loader.exec_module(pa)
print([x["texto"] for x in pa.pendientes(sys.argv[2]) if x["id"] == sys.argv[3]][0])' "$BIN/pendientes_afines.py" "$M/_pendientes.md" "$A" | grep -c '_retomar')"
emit --type pendiente.window --id "$A" --revisar "$HOY" >/dev/null; compact --quiet >/dev/null
chk "control: con _revisar = hoy el 8e ajeno SI lo saca" "1" "$(OPC | grep -c "$A")"
chk "control: con _revisar = hoy hacible() da False" "False" "$(HAC)"

echo "== 7. pendiente.update conserva la marca y el despojador la quita del texto =="
fixture
ficha 2026-10-16-uno "hacer $A."
marcar "$M/sessions/2026-10-16-uno.md" >/dev/null
emit --type pendiente.update --id "$A" --text "anadir el paso A al checkpoint y probarlo" >/dev/null
compact --quiet >/dev/null
chk "texto nuevo" "1" "$(linea "$A" | grep -c 'y probarlo')"
chk "la marca sigue" "1" "$(linea "$A" | grep -c "_retomar: $HOY sessions/2026-10-16-uno_")"
chk "una sola marca" "1" "$(linea "$A" | grep -o '_retomar:' | wc -l | tr -d ' ')"
chk "sin cuarentena" "0" "$(cuarentena)"
chk "repair-dualwrite: ids_invented=0" "1" "$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1 | grep -c 'ids_invented=0')"

echo "== 8. al cerrar el pendiente, la linea abierta desaparece =="
emit --type pendiente.resolve --id "$A" --estado resolved --nota "hecho" >/dev/null; compact --quiet >/dev/null
chk "ya no hay linea abierta" "0" "$(grep -c "^- \[ \].*_id: ${A}_" "$M/_pendientes.md")"

echo "== 9. el emisor rechaza una ficha o una fecha malas =="
fixture
set +e
emit --type pendiente.retomar --id "$A" --retomar "$HOY" --ficha "sessions/x y" >/dev/null 2>&1; R1=$?
emit --type pendiente.retomar --id "$A" --retomar 2026-99-99 --ficha "sessions/x" >/dev/null 2>&1; R2=$?
emit --type pendiente.retomar --id "$A" --retomar "$HOY" --ficha "plans/x" >/dev/null 2>&1; R3=$?
emit --type pendiente.retomar --id "$A" --retomar "$HOY" --ficha "sessions/x.md" >/dev/null 2>&1; R4=$?
set -e
chk "ficha con espacio: error" "1" "$([ "$R1" -ne 0 ] && echo 1 || echo 0)"
chk "fecha imposible: error" "1" "$([ "$R2" -ne 0 ] && echo 1 || echo 0)"
chk "fuera de sessions/: error" "1" "$([ "$R3" -ne 0 ] && echo 1 || echo 0)"
chk "sessions/x.md se acepta sin el .md" "0" "$R4"
compact --quiet >/dev/null
chk "y se escribe como sessions/x" "1" "$(linea "$A" | grep -c "_retomar: $HOY sessions/x_")"

echo "== 9b. el emisor exige AAAA-MM-DD; marcar-retomar normaliza --hoy =="
fixture
set +e
emit --type pendiente.retomar --id "$A" --retomar 20261016 --ficha "sessions/x" >/dev/null 2>&1; R5=$?
emit --type pendiente.retomar --id "$A" --retomar 2026-W42-5 --ficha "sessions/x" >/dev/null 2>&1; R6=$?
set -e
chk "fecha 20261016 (sin guiones): error" "1" "$([ "$R5" -ne 0 ] && echo 1 || echo 0)"
chk "fecha 2026-W42-5 (semana ISO): error" "1" "$([ "$R6" -ne 0 ] && echo 1 || echo 0)"
chk "y no dejan evento" "0" "$(eventos)"
# Las tres formas en CUALQUIER Python 3: date.fromisoformat solo acepta las dos anchas desde 3.11, y
# el python3 de macOS es 3.9 (p-0ccd79fe36). Se lee el codigo de salida: con `set -e` un rc=2 aqui
# abortaba la suite y en 3.9 los casos de despues nunca corrian.
for forma in 20261016 2026-W42-5 2026-10-16; do
  fixture
  ficha 2026-10-16-uno "hacer $A."
  RC=0; python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-16-uno.md" --hoy "$forma" >/dev/null 2>&1 || RC=$?
  chk "marcar-retomar --hoy $forma sale 0" "0" "$RC"
  chk "marcar-retomar --hoy $forma escribe 2026-10-16" "1" "$(linea "$A" | grep -c '_retomar: 2026-10-16 sessions/2026-10-16-uno_')"
  chk "sin cuarentena con $forma" "0" "$(cuarentena)"
done
# Una fecha imposible en cualquiera de las formas sale con error de uso y no marca nada.
for forma in 20261332 2026-W54-1 2026-02-30 2026-1016 hoy; do
  fixture
  ficha 2026-10-16-uno "hacer $A."
  RC=0; python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-16-uno.md" --hoy "$forma" >/dev/null 2>&1 || RC=$?
  chk "marcar-retomar --hoy $forma sale 2" "2" "$RC"
  chk "marcar-retomar --hoy $forma no marca" "0" "$(linea "$A" | grep -c '_retomar:' || true)"
done

echo "== 10. el compactador cuarentena un evento escrito a mano con ficha o fecha malas =="
# El emisor tambien las rechaza (caso 9); esto cubre un evento que no paso por el (adversario,
# 2026-10-16).
fixture
mkdir -p "$M/.journal/pending"
for caso in 'ficha:sessions/x\n' 'retomar:20261016' 'retomar:2026-W42-5'; do
  python3 -I - "$M/.journal/pending" "$A" "$caso" <<'PY'
import json, os, sys, time
d, pid, caso = sys.argv[1], sys.argv[2], sys.argv[3]
campo, valor = caso.split(":", 1)
p = {"id": pid, "retomar": "2026-10-16", "ficha": "sessions/x", "fecha": "2026-10-16"}
p[campo] = valor.replace("\\n", "\n")
ev = {"v": 1, "type": "pendiente.retomar", "ts": time.time_ns(), "payload": p}
n = f"{time.time_ns()}-{campo}-{len(os.listdir(d))}.json"
open(os.path.join(d, n), "w", encoding="utf-8").write(json.dumps(ev))
PY
done
compact --quiet >/dev/null
chk "los tres a cuarentena" "3" "$(cuarentena)"
chk "la linea no cambio" "0" "$(linea "$A" | grep -c '_retomar:')"
chk "y no se partio (sin una linea suelta '_')" "0" "$(grep -c '^_$' "$M/_pendientes.md" || true)"

# 2.63.42: la sesion que retomo el snippet de otra ficha consume su marca, aunque su paso nuevo
# caiga en otro pendiente (caso real de cloudflare-expert, 2026-10-22: la ficha de la Fase 4 retomo
# la de la Fase 3, marco otro pendiente y la marca vieja siguio en PLANES ACTIVOS del mod).
sellar() {  # sellar SLUG "hilo_paso" "hilo_retoma" — agrega el sello de stamp-hilo.py
  python3 -I - "$M/sessions/$1.md" "$2" "$3" <<'PY'
import sys
ruta, paso, retoma = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(ruta, encoding="utf-8").read()
extra = f"hilo_paso: {paso}\n" + (f"hilo_retoma: {retoma}\n" if retoma else "")
open(ruta, "w", encoding="utf-8").write(t.replace("\n---\n", "\n" + extra + "---\n", 1))
PY
}

echo "== 11. la sesion que retomo el snippet quita la marca vieja si su paso cae en otro pendiente =="
fixture
ficha 2026-10-16-uno "hacer $A (el paso A)."
marcar "$M/sessions/2026-10-16-uno.md" >/dev/null
ficha 2026-10-17-dos "medir $B."
sellar 2026-10-17-dos "$A" 2026-10-16-uno
OUT=$(python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-17-dos.md" --hoy 2026-10-17)
chk "A ya no tiene _retomar" "0" "$(linea "$A" | grep -c '_retomar:' || true)"
chk "B queda marcado con la ficha nueva" "1" "$(linea "$B" | grep -c '_retomar: 2026-10-17 sessions/2026-10-17-dos_')"
chk "lo dice en una linea" "1" "$(printf '%s\n' "$OUT" | grep -c "🧹 $A: sin _retomar")"
chk "A sigue abierto, con su texto" "1" "$(linea "$A" | grep -c '^- \[ \] .*anadir el paso A')"
chk "sin cuarentena" "0" "$(cuarentena)"
OUT=$(python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-17-dos.md" --hoy 2026-10-17)
chk "otra pasada no emite nada nuevo para A" "0" "$(printf '%s\n' "$OUT" | grep -c "🧹" || true)"

echo "== 12. si el paso nuevo vuelve a citar el pendiente, la marca se mueve, no se borra =="
fixture
ficha 2026-10-16-uno "hacer $A (el paso A)."
marcar "$M/sessions/2026-10-16-uno.md" >/dev/null
ficha 2026-10-17-dos "seguir con $A."
sellar 2026-10-17-dos "$A" 2026-10-16-uno
python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-17-dos.md" --hoy 2026-10-17 >/dev/null
chk "A apunta a la ficha nueva" "1" "$(linea "$A" | grep -c '_retomar: 2026-10-17 sessions/2026-10-17-dos_')"
chk "con un solo campo" "1" "$(linea "$A" | grep -o '_retomar:' | wc -l | tr -d ' ')"

echo "== 13. una marca que otra sesion ya movio a su ficha no se toca =="
fixture
ficha 2026-10-16-uno "hacer $A (el paso A)."
marcar "$M/sessions/2026-10-16-uno.md" >/dev/null
ficha 2026-10-17-otra "hacer $A otra vez."
python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-17-otra.md" --hoy 2026-10-17 >/dev/null
ficha 2026-10-17-dos "medir $B."
sellar 2026-10-17-dos "$A" 2026-10-16-uno
python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-17-dos.md" --hoy 2026-10-17 >/dev/null
chk "A conserva la marca de la otra sesion" "1" "$(linea "$A" | grep -c '_retomar: 2026-10-17 sessions/2026-10-17-otra_')"
emit --type pendiente.retomar --id "$A" --quitar --ficha sessions/2026-10-16-uno >/dev/null
compact --quiet >/dev/null
chk "un --quitar con otra ficha tampoco la toca" "1" "$(linea "$A" | grep -c '_retomar: 2026-10-17 sessions/2026-10-17-otra_')"
chk "sin cuarentena" "0" "$(cuarentena)"

echo "== 14. sin hilo_retoma (ficha anterior a 2.63.42, o no arranco con un snippet) no quita nada =="
fixture
ficha 2026-10-16-uno "hacer $A (el paso A)."
marcar "$M/sessions/2026-10-16-uno.md" >/dev/null
ficha 2026-10-17-dos "medir $B."
sellar 2026-10-17-dos "$A" ""
python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-17-dos.md" --hoy 2026-10-17 >/dev/null
chk "A conserva su marca" "1" "$(linea "$A" | grep -c '_retomar: 2026-10-16 sessions/2026-10-16-uno_')"

echo "== 15. un paso nuevo sin p-… (ninguno, un plan) tambien consume la marca =="
fixture
ficha 2026-10-16-uno "hacer $A (el paso A)."
marcar "$M/sessions/2026-10-16-uno.md" >/dev/null
ficha 2026-10-17-dos "ninguno — esperar al lunes."
sellar 2026-10-17-dos "$A" 2026-10-16-uno
python3 "$BIN/marcar-retomar.py" "$M/sessions/2026-10-17-dos.md" --hoy 2026-10-17 >/dev/null
chk "A ya no tiene _retomar" "0" "$(linea "$A" | grep -c '_retomar:' || true)"

echo "== 16. el emisor: --quitar exige --ficha y no admite --retomar =="
RC=0; emit --type pendiente.retomar --id "$A" --quitar >/dev/null 2>&1 || RC=$?
chk "sin --ficha sale con error" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
RC=0; emit --type pendiente.retomar --id "$A" --quitar --ficha sessions/x --retomar 2026-10-17 >/dev/null 2>&1 || RC=$?
chk "con --retomar sale con error" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
