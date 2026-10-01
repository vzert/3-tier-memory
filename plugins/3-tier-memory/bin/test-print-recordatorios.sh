#!/bin/bash
# Prueba de bin/print-recordatorios.py (checkpoint-3t Step 8c, 2.44.0).
#
# Lo que importa: que el calendario pegado en el cierre salga SIN fence (solo Retomamos va en
# color), con su cabecera 🗓️ una sola vez, los dos primeros bloques y `+N` si hay mas; y que las
# lineas `ya agendado` (no son bloques) no salgan.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
F="$T/ficha.md"
out() { python3 "$BIN/print-recordatorios.py" "$F" 2>&1; }
viejo() {   # $1 fecha, $2 titulo: bloque con el formato de antes de 2.44.0
  printf -- '### %s — %s\n\n````\n─── Recordatorio para el %s ───\nPonlo en tu calendario:\n\nTítulo: %s\n\nDescripción:\nalgo que decidir.\n\nPega esto dentro del evento (es el prompt para el agente):\n```\nProyecto: demo — /x/demo\nRetomamos: algo _id: p-%s_\nSi ya no aplica, cierralo con /checkpoint-3t en vez de dejarlo abierto.\n```\n────────────────────────────────────\n````\n\n' "$1" "$2" "$1" "$2" "$3"
}
nuevo() {   # $1 fecha, $2 titulo: bloque con la cabecera 🗓️ de 2.44.0
  printf -- '### %s — %s\n\n````\n🗓️ Recordatorio para el %s — ponlo en tu calendario:\n\nTítulo: %s\n\nDescripción:\nalgo.\n\nPega esto dentro del evento (es el prompt para el agente):\n```\nProyecto: demo — /x/demo\n```\n````\n\n' "$1" "$2" "$1" "$2"
}
ficha() { printf -- '---\ndate: 2026-10-01\n---\n# Demo\n\n## Como retomar\n\nNinguno — x.\n\n%s\n\n## Related\n' "$1" > "$F"; }

echo "== sin seccion: nada, rc 0 =="
ficha ""
chk "vacio" "" "$(out)"
python3 "$BIN/print-recordatorios.py" "$F" >/dev/null; chk "rc 0" "0" "$?"

echo "== un bloque con el formato viejo: cabecera 🗓️, sin fence ni separadores =="
ficha "$(printf '## Recordatorios de calendario\n\n'; viejo 2026-10-06 '[demo] ¿Funciona?' aaaaaaaaaa)"
O=$(out)
chk "primera linea 🗓️" "🗓️ Recordatorio para el 2026-10-06 — ponlo en tu calendario:" "$(printf '%s\n' "$O" | head -1)"
chk "sin fences" "0" "$(printf '%s\n' "$O" | grep -c '^\s*`\{3,\}')"
chk "sin separadores ni 'Ponlo en'" "0" "$(printf '%s\n' "$O" | grep -c '───\|^Ponlo en tu calendario')"
chk "titulo" "1" "$(printf '%s\n' "$O" | grep -c '^Título: \[demo\] ¿Funciona?$')"
chk "prompt del evento" "1" "$(printf '%s\n' "$O" | grep -c '^Retomamos: algo _id: p-aaaaaaaaaa_$')"
chk "sin lineas en blanco dobles" "0" "$(printf '%s\n' "$O" | awk 'prev=="" && $0=="" {n++} {prev=$0} END {print n+0}')"

echo "== bloque con la cabecera 🗓️ ya puesta: una sola cabecera =="
ficha "$(printf '## Recordatorios de calendario\n\n'; nuevo 2026-10-06 '[demo] ¿Nuevo?')"
chk "una cabecera" "1" "$(out | grep -c '^🗓️')"

echo "== tres bloques y una linea ya agendado: los dos primeros y +1 =="
ficha "$(printf '## Recordatorios de calendario\n\n- p-0000000000 ya agendado para 2026-10-05 en [[sessions/otra]]\n\n'; viejo 2026-10-06 'uno' aaaaaaaaaa; viejo 2026-10-07 'dos' bbbbbbbbbb; viejo 2026-10-08 'tres' cccccccccc)"
O=$(out)
chk "dos cabeceras" "2" "$(printf '%s\n' "$O" | grep -c '^🗓️')"
chk "el tercero no" "0" "$(printf '%s\n' "$O" | grep -c 'p-cccccccccc')"
chk "+1 con fecha futura" "1" "$(printf '%s\n' "$O" | grep -c '^+1 con fecha futura en _pendientes.md$')"
chk "la linea ya agendado no sale" "0" "$(printf '%s\n' "$O" | grep -c 'ya agendado')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
