#!/bin/bash
# Prueba de 2.63.29: todo pendiente `_bloqueado` lleva `_revisar`, y ese dia vuelve a salir.
# Caso real (claude-vzert, 2026-10-20): `p-98a561dc02` quedo bloqueado ("que la cuenta de infra
# instale el plugin y que un dev mande un mensaje"), sin fecha, con snippet `Ninguno`; nada lo
# iba a volver a mostrar. Medido ese dia: 50 de 54 bloqueados abiertos en 7 proyectos sin fecha.
#
#  1. journal-emit.py: `--bloqueado-por` sin `--revisar` nace con `_revisar: hoy+5`; con fecha, la
#     respeta. `pendiente.block` pone hoy+5 salvo que la linea traiga un `_revisar` futuro.
#  2. checkpoint-audit.py: SALTADO `pendientes.bloqueado_sin_fecha` si la ficha lista un bloqueado
#     sin `_revisar` (tambien en --solo-snippet, el modo del hook de cierre); fichas anteriores al
#     corte no se miden.
#  3. Un bloqueado con `_revisar` pasado puede ser `Proximo paso` (mirar si ya llego) y entra en el
#     hilo; con `_revisar` futuro, no.
#  4. expire-pendientes.py no caduca un bloqueado con `_revisar` vencido.
#  5. print-pendiente-opcional.py saca el bloqueado el dia de su `_revisar` (🔔).
#
# Contra 2.63.22 los casos 1-5 salen rojos. Uso: test-bloqueado-fecha.sh (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

HOY=$(python3 -c 'import datetime;print(datetime.date.today().isoformat())')
MAS5=$(python3 -c 'import datetime;print((datetime.date.today()+datetime.timedelta(days=5)).isoformat())')

echo "== 1. journal-emit: la ventana del bloqueado =="
M="$T/m1"; mkdir -p "$M/pendientes"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" --quiet >/dev/null 2>&1; }
linea() { grep -- "_id: $1_" "$M/_pendientes.md"; }
A=$(emit --type pendiente.add --text "mirar si infra instalo el plugin" --prioridad Media \
     --origen "[[sessions/2026-10-20-x]]" --bloqueado-por "que infra instale el plugin" 2>"$T/err")
compact
chk "add sin --revisar: _revisar hoy+5" "1" "$(linea "$A" | grep -c "_revisar: ${MAS5}_")"
chk "y lo avisa por stderr" "1" "$(grep -c 'ventana por defecto' "$T/err")"
B=$(emit --type pendiente.add --text "mirar si el dev mando el mensaje" --prioridad Media \
     --origen "[[sessions/2026-10-20-x]]" --bloqueado-por "un dev" --revisar 2026-12-01 2>/dev/null)
compact
chk "add con --revisar: respeta la fecha" "1" "$(linea "$B" | grep -c '_revisar: 2026-12-01_')"
C=$(emit --type pendiente.add --text "sin bloqueo" --prioridad Baja --origen "[[sessions/2026-10-20-x]]" 2>/dev/null)
compact
chk "add sin bloqueo: sin ventana" "0" "$(linea "$C" | grep -c '_revisar:')"
emit --type pendiente.block --id "$C" --bloqueado-por "otra instalacion" >/dev/null 2>&1; compact
chk "block sin --revisar en linea sin ventana: hoy+5" "1" "$(linea "$C" | grep -c "_revisar: ${MAS5}_")"
emit --type pendiente.window --id "$C" --revisar 2099-01-01 >/dev/null; compact
emit --type pendiente.block --id "$C" --bloqueado-por "otra instalacion" >/dev/null 2>&1; compact
chk "block sin --revisar conserva un _revisar futuro" "1" "$(linea "$C" | grep -c '_revisar: 2099-01-01_')"
emit --type pendiente.window --id "$C" --revisar 2020-01-01 >/dev/null; compact
emit --type pendiente.block --id "$C" --bloqueado-por "otra instalacion" >/dev/null 2>&1; compact
chk "block sin --revisar sobre un _revisar vencido: hoy+5" "1" "$(linea "$C" | grep -c "_revisar: ${MAS5}_")"
emit --type pendiente.block --id "$C" --bloqueado-por "otra instalacion" --revisar 2026-11-11 >/dev/null; compact
chk "block con --revisar reemplaza la ventana" "1 1" "$(linea "$C" | grep -c '_revisar: 2026-11-11_') $(linea "$C" | grep -o '_revisar:' | wc -l | tr -d ' ')"
emit --type pendiente.block --id "$C" --desbloquear >/dev/null; compact
chk "--desbloquear quita el bloqueo y deja la ventana" "0 1" "$(linea "$C" | grep -c '_bloqueado:') $(linea "$C" | grep -c '_revisar: 2026-11-11_')"
chk "--revisar con --desbloquear: error" "1" "$(emit --type pendiente.block --id "$C" --desbloquear --revisar 2026-11-11 >/dev/null 2>&1; echo $?)"
chk "sin cuarentena" "0" "$(ls "$M/.journal/quarantine" 2>/dev/null | wc -l | tr -d ' ')"

echo "== 2-3. checkpoint-audit: bloqueado sin fecha y bloqueado vencido =="
M="$T/m2"; SLUG=2026-10-20-canal
# memoria COLA: el pendiente del caso real; COLA va al final de su linea. p-1111111111 es otro
# bloqueado del indice que la ficha no lista.
memoria() {
  mkdir -p "$M/sessions" "$M/pendientes"
  cat > "$M/_pendientes.md" <<EOF
---
type: index
---
# Pendientes

## Alta prioridad

## Media prioridad

- [ ] Cerrar la Fase 4 con una prueba real de infra — _origen: [[sessions/$SLUG]]_ — _creado: 2026-10-20_ — _id: p-98a561dc02_ — _bloqueado: que la cuenta de infra instale el plugin y que un dev mande un mensaje_$1
- [ ] Otro bloqueado viejo — _origen: [[sessions/2026-09-01-x]]_ — _creado: 2026-09-01_ — _id: p-1111111111_ — _bloqueado: otra instalacion_$2

## Baja prioridad
EOF
}
# ficha FECHA RETOMAR
ficha() {
  python3 - "$M/sessions/$SLUG.md" "$1" "$2" <<'PY'
import sys
p, fecha, retomar = sys.argv[1], sys.argv[2], sys.argv[3].replace("\\n", "\n")
open(p, "w", encoding="utf-8").write(
    f"---\ntype: session\ndate: {fecha}\n---\n# Canal\n\n## Contexto\nalgo\n\n## Bugs fixed\n- Ninguno\n\n"
    "## Plans\n- Ninguno\n\n## Research\n- Ninguno\n\n## Learnings generados\n- Ninguno\n\n"
    "## Pendientes\n- [ ] Cerrar la Fase 4 con una prueba real de infra — `p-98a561dc02`\n\n"
    f"## Commits\n- `abc1234`\n\n## Como retomar\n\n{retomar}\n\n## Related\n- [[_pendientes]]\n")
PY
}
audit() { python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$SLUG.md" --no-git --hoy 2026-10-20 --solo-snippet "$@" 2>&1; }
estado() { audit --json | python3 -c "import json,sys; print(' '.join(x['estado'] for x in json.load(sys.stdin) if x['clave']==sys.argv[1]) or '-')" "$1"; }
NINGUNO='Ninguno — lo unico abierto espera a infra (`p-98a561dc02`).'
paso() { printf '```\nRetomamos: bandeja.\n\nLee memory/sessions/%s.md para el contexto completo.\n\nProximo paso: %s\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```' "$SLUG" "$1"; }

memoria "" ""
ficha 2026-10-20 "$NINGUNO"
chk "caso real: bloqueado de la ficha sin fecha es SALTADO (modo del hook)" "SALTADO" "$(estado pendientes.bloqueado_sin_fecha)"
chk "nombra el pendiente" "1" "$(audit --json | python3 -c "import json,sys; print(sum('p-98a561dc02' in l for x in json.load(sys.stdin) if x['clave']=='pendientes.bloqueado_sin_fecha' for l in x.get('lineas') or []))")"
memoria " — _revisar: 2026-10-25_" ""
ficha 2026-10-20 "$NINGUNO"
chk "con _revisar: ya no es SALTADO; el otro del indice sale como aviso" "POR-DISEÑO" "$(estado pendientes.bloqueado_sin_fecha)"
memoria " — _revisar: 2026-10-25_" " — _revisar: 2026-10-25_"
chk "todos con fecha: HECHO" "HECHO" "$(estado pendientes.bloqueado_sin_fecha)"
memoria "" ""
ficha 2026-10-19 "$NINGUNO"
chk "ficha anterior al corte: no se mide" "-" "$(estado pendientes.bloqueado_sin_fecha)"

memoria " — _revisar: 2026-10-19_" " — _revisar: 2026-10-25_"
ficha 2026-10-20 "$(paso 'mirar si infra ya instalo el plugin y el dev mando el mensaje (p-98a561dc02).')"
chk "bloqueado con _revisar pasado: puede ser Proximo paso" "HECHO" "$(estado snippet.proximo_paso)"
memoria " — _revisar: 2026-10-25_" " — _revisar: 2026-10-25_"
chk "bloqueado con _revisar futuro: sigue fuera de Proximo paso" "SALTADO" "$(estado snippet.proximo_paso)"
memoria " — _revisar: 2026-10-19_" " — _revisar: 2026-10-25_"
ficha 2026-10-20 "$NINGUNO"
chk "Ninguno colapsado con un bloqueado ya vencido: SALTADO en el hilo (hay que mirarlo)" "SALTADO" "$(estado snippet.hilo)"
ficha 2026-10-20 "$(paso 'nada accionable hoy — espera a infra (p-98a561dc02).')"
chk "ninguno en bloque con un bloqueado propio ya vencido: SALTADO" "SALTADO" "$(estado snippet.proximo_paso)"
hac() { python3 -c "import importlib.util,sys;s=importlib.util.spec_from_file_location('a',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(m.hacible({'prio':'Media','bloqueado':sys.argv[2]=='1','revisar':sys.argv[3] or None,'texto':'x'},'2026-10-20'))" "$BIN/pendientes_afines.py" "$@"; }
chk "hacible: bloqueado vencido si, con fecha futura no, sin fecha no, sin bloqueo si" "True False False True" "$(hac 1 2026-10-19) $(hac 1 2026-10-25) $(hac 1 '') $(hac 0 '')"

echo "== 4. expire-pendientes no caduca un bloqueado vencido =="
M="$T/m4"; mkdir -p "$M"
cat > "$M/_pendientes.md" <<'EOF'
# Pendientes

## Media prioridad

- [ ] espera vencida — _origen: [[sessions/2026-09-01-x]]_ — _creado: 2026-09-01_ — _id: p-2222222222_ — _bloqueado: un dev_ — _revisar: 2026-09-10_
- [ ] ventana vencida — _origen: [[sessions/2026-09-01-x]]_ — _creado: 2026-09-01_ — _id: p-3333333333_ — _revisar: 2026-09-10_
EOF
OUT=$(python3 "$BIN/expire-pendientes.py" --memory-dir "$M" 2>&1)
chk "el bloqueado no es candidato; el otro si" "0 1" "$(printf '%s\n' "$OUT" | grep -c p-2222222222) $(printf '%s\n' "$OUT" | grep -c p-3333333333)"
chk "lo cuenta como excluido" "1" "$(printf '%s\n' "$OUT" | grep -c '_bloqueado 1')"

echo "== 5. print-pendiente-opcional: el dia de su _revisar sale el bloqueado =="
M="$T/m5"; mkdir -p "$M/sessions"
cat > "$M/_pendientes.md" <<'EOF'
# Pendientes

## Media prioridad

- [ ] mirar si infra instalo el plugin — _origen: [[sessions/2026-10-20-x]]_ — _creado: 2026-10-20_ — _id: p-4444444444_ — _bloqueado: infra_ — _revisar: 2026-10-25_
- [ ] bloqueado viejo sin fecha — _origen: [[sessions/2026-09-01-x]]_ — _creado: 2026-09-01_ — _id: p-5555555555_ — _bloqueado: otro_
EOF
printf -- '---\ntype: session\ndate: 2026-10-25\n---\n# x\n\n## Como retomar\n\nNinguno — nada.\n' > "$M/sessions/2026-10-25-x.md"
OUT=$(python3 "$BIN/print-pendiente-opcional.py" "$M/sessions/2026-10-25-x.md" --hoy 2026-10-25)
chk "sale el bloqueado que vence hoy, con su aviso" "1 1" "$(printf '%s\n' "$OUT" | grep -c p-4444444444) $(printf '%s\n' "$OUT" | grep -c 'Espera a alguien de fuera')"
OUT=$(python3 "$BIN/print-pendiente-opcional.py" "$M/sessions/2026-10-25-x.md" --hoy 2026-10-20)
chk "antes de su fecha no sale, y el bloqueado sin fecha nunca" "0 0" "$(printf '%s\n' "$OUT" | grep -c p-4444444444) $(printf '%s\n' "$OUT" | grep -c p-5555555555)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
