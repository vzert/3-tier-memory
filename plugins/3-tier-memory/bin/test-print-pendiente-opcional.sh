#!/bin/bash
# Prueba de bin/print-pendiente-opcional.py (checkpoint-3t Step 8e; capas desde 2.44.0).
#
# El bloque de pendiente del cierre tiene dos capas que nunca coinciden: 🔔 UN pendiente que vence
# HOY (acompana a cualquier snippet) y ➕ el opcional (solo con el snippet del caso 5 y sin nada que
# venza hoy). Lo que importa: que elija por CAMPOS (_revisar, _bloqueado, seccion, _creado) y por la
# FORMA de `## Como retomar`, nunca por el texto, y que no proponga lo que no se puede hacer ya
# (bloqueado, fecha futura) ni repita el `Proximo paso`.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proyecto"; M="$P/memory"; F="$M/sessions/2026-09-23-demo.md"
armar() {   # $1 = lineas de Alta, $2 = lineas de Media, $3 = linea Proximo paso, o CASO5
  rm -rf "$P"; mkdir -p "$M/sessions"
  printf '# Pendientes\n\n## Alta prioridad\n\n%b\n## Media prioridad\n\n%b\n## Baja prioridad\n' "$1" "$2" > "$M/_pendientes.md"
  if [ "$3" = CASO5 ]; then
    printf -- '---\ntype: session\ndate: 2026-09-23\n---\n# Demo\n\n## Como retomar\n\nNinguno — la sesion cerro sola.\n\n## Related\n' > "$F"
  else
    printf -- '---\ntype: session\ndate: 2026-09-23\n---\n# Demo\n\n## Como retomar\n\n```\nRetomamos: demo.\n\n%s\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```\n\n## Related\n' "$3" > "$F"
  fi
  printf -- '---\ntype: session\n---\n# Origen\n' > "$M/sessions/2026-09-20-origen.md"
}
L() {   # $1 id, $2 texto, $3 creado, $4 cola de metadatos
  printf -- '- [ ] %s — _origen: [[sessions/2026-09-20-origen]]_ — _creado: %s_ — _id: %s_%s\\n' "$2" "$3" "$1" "$4"
}
out() { python3 "$BIN/print-pendiente-opcional.py" "$F" --hoy 2026-09-23 2>&1; }
PP="Proximo paso: arreglar algo _id: p-9999999999_."

echo "== sin candidatos: no imprime nada y sale 0 =="
armar "" "$(L p-1111111111 'media normal' 2026-09-01 '')" CASO5
chk "vacio" "" "$(out)"
python3 "$BIN/print-pendiente-opcional.py" "$F" --hoy 2026-09-23 >/dev/null; chk "rc 0" "0" "$?"

echo "== ➕ solo en el caso 5: con snippet completo, ni el Alta ni los vencidos salen =="
armar "$(L p-aaaaaaaaaa 'alta nueva' 2026-09-22 '')" "$(L p-2222222222 'media vencida' 2026-09-10 ' — _revisar: 2026-09-15_')" "$PP"
chk "snippet completo y nada vence hoy: nada" "" "$(out)"

echo "== ➕ caso 5, Alta: el _creado mas reciente; a igual fecha, la fila de mas arriba =="
armar "$(L p-aaaaaaaaaa 'alta vieja' 2026-09-01 '')$(L p-bbbbbbbbbb 'alta nueva arriba' 2026-09-20 '')$(L p-cccccccccc 'alta nueva abajo' 2026-09-20 '')" "" CASO5
O=$(out)
chk "cabecera ➕" "1" "$(printf '%s' "$O" | grep -c '^➕ ')"
chk "sin cabecera 🔔" "0" "$(printf '%s' "$O" | grep -c '^🔔')"
chk "elige la nueva de arriba" "1" "$(printf '%s' "$O" | grep -c 'alta nueva arriba _id: p-bbbbbbbbbb_')"
chk "un solo prompt" "1" "$(printf '%s' "$O" | grep -c '^Retomamos:')"
chk "motivo Alta" "1" "$(printf '%s' "$O" | grep -c '^Motivo: Alta abierto desde 2026-09-20')"
chk "texto sin metadatos" "0" "$(printf '%s' "$O" | grep '^Retomamos:' | grep -c '_origen')"
# La ruta se compara por su final: en Windows Python imprime la ruta nativa (C:\...) y $P es la de
# Git Bash (/c/...). Las dos son la misma carpeta; el prompt se pega en el sistema de quien lo lee.
chk "Proyecto con la ruta del proyecto" "1" "$(printf '%s' "$O" | grep -c '^Proyecto: proyecto — .*[/\\]proyecto$')"
chk "Contexto de su _origen" "1" "$(printf '%s' "$O" | grep -c '^Contexto: memory/sessions/2026-09-20-origen.md')"
chk "clausula de cierre" "1" "$(printf '%s' "$O" | grep -c 'cierralo con /checkpoint-3t')"
chk "sin separadores viejos" "0" "$(printf '%s' "$O" | grep -c '───\|Si tienes tiempo, abre')"

echo "== ➕ adversariales: bloqueado y _revisar futuro no se proponen =="
armar "$(L p-aaaaaaaaaa 'alta bloqueada' 2026-09-22 ' — _bloqueado: otra instalacion_')$(L p-bbbbbbbbbb 'alta con fecha futura' 2026-09-22 ' — _revisar: 2026-09-30_')$(L p-dddddddddd 'alta valida' 2026-09-01 '')" "" CASO5
O=$(out)
chk "elige la unica valida" "1" "$(printf '%s' "$O" | grep -c 'p-dddddddddd')"
chk "ni bloqueada ni futura" "0" "$(printf '%s' "$O" | grep -c 'p-aaaaaaaaaa\|p-bbbbbbbbbb')"
armar "$(L p-aaaaaaaaaa 'alta bloqueada' 2026-09-22 ' — _bloqueado: otra instalacion_')" "" CASO5
chk "solo bloqueados: nada" "" "$(out)"
armar "$(L p-aaaaaaaaaa 'la palabra _bloqueado en el texto no bloquea' 2026-09-22 '')" "" CASO5
chk "'_bloqueado' dentro del texto no cuenta (campo, no prosa)" "1" "$(out | grep -c 'p-aaaaaaaaaa')"

echo "== ➕ caso 5, vencidos: ganan a los Alta, hasta 2, el mas viejo primero, de cualquier prioridad =="
armar "$(L p-aaaaaaaaaa 'alta nueva' 2026-09-22 '')" "$(L p-2222222222 'media vencida' 2026-09-10 ' — _revisar: 2026-09-15_')$(L p-3333333333 'media vencida segunda' 2026-09-10 ' — _revisar: 2026-09-20_')$(L p-4444444444 'media vencida tercera' 2026-09-10 ' — _revisar: 2026-09-21_')" CASO5
O=$(out)
chk "dos prompts" "2" "$(printf '%s' "$O" | grep -c '^Retomamos:')"
chk "una sola cabecera" "1" "$(printf '%s' "$O" | grep -c '^➕ ')"
chk "primero el mas viejo" "p-2222222222" "$(printf '%s' "$O" | grep '^Retomamos:' | head -1 | grep -o 'p-[0-9a-f]*')"
chk "segundo el siguiente" "p-3333333333" "$(printf '%s' "$O" | grep '^Retomamos:' | sed -n 2p | grep -o 'p-[0-9a-f]*')"
chk "el Alta no entra" "0" "$(printf '%s' "$O" | grep -c 'p-aaaaaaaaaa')"
chk "motivo vencido" "1" "$(printf '%s' "$O" | grep -c '^Motivo: vencido desde 2026-09-15')"
armar "" "$(L p-1111111111 'vencida pero bloqueada' 2026-09-10 ' — _revisar: 2026-09-15 — _bloqueado: un peer_')" CASO5
chk "vencida y bloqueada: nada" "" "$(out)"

echo "== ➕ origen sin ficha: sin linea Contexto =="
armar "$(printf -- '- [ ] alta sin origen — _creado: 2026-09-22_ — _id: p-aaaaaaaaaa_\\n')" "" CASO5
O=$(out)
chk "propone" "1" "$(printf '%s' "$O" | grep -c 'p-aaaaaaaaaa')"
chk "sin Contexto" "0" "$(printf '%s' "$O" | grep -c '^Contexto:')"

echo "== 🔔 vence HOY: con cualquier snippet, uno solo, y tapa a la capa ➕ =="
# El vencido va ARRIBA del que vence hoy: si la capa tomara tambien los vencidos, ganaria el.
armar "$(L p-aaaaaaaaaa 'alta nueva' 2026-09-22 '')" "$(L p-2222222222 'media vencida' 2026-09-10 ' — _revisar: 2026-09-15_')$(L p-1111111111 'media vence hoy' 2026-09-10 ' — _revisar: 2026-09-23_')" "$PP"
O=$(out)
chk "cabecera 🔔" "1" "$(printf '%s' "$O" | grep -c '^🔔 ')"
chk "el que vence hoy" "1" "$(printf '%s' "$O" | grep -c '^Retomamos: media vence hoy _id: p-1111111111_')"
chk "uno solo" "1" "$(printf '%s' "$O" | grep -c '^Retomamos:')"
chk "el vencido no (solo el de hoy)" "0" "$(printf '%s' "$O" | grep -c 'p-2222222222')"
chk "sin linea Motivo" "0" "$(printf '%s' "$O" | grep -c '^Motivo:')"
armar "" "$(L p-1111111111 'media vence hoy' 2026-09-10 ' — _revisar: 2026-09-23_')$(L p-2222222222 'media vencida' 2026-09-10 ' — _revisar: 2026-09-15_')" CASO5
O=$(out)
chk "caso 5 y vence uno hoy: 🔔" "1" "$(printf '%s' "$O" | grep -c '^🔔 ')"
chk "y no ➕ (el vencido no sale)" "0" "$(printf '%s' "$O" | grep -c '^➕\|p-2222222222')"

echo "== 🔔 varios vencen hoy: uno cada vez, el de mayor prioridad y luego la fila de arriba =="
armar "$(L p-aaaaaaaaaa 'alta vence hoy' 2026-09-01 ' — _revisar: 2026-09-23_')" "$(L p-1111111111 'media vence hoy' 2026-09-10 ' — _revisar: 2026-09-23_')" "$PP"
chk "gana el Alta" "1" "$(out | grep -c '^Retomamos:.*p-aaaaaaaaaa')"
chk "uno solo" "1" "$(out | grep -c '^Retomamos:')"
armar "" "$(L p-1111111111 'media arriba' 2026-09-10 ' — _revisar: 2026-09-23_')$(L p-2222222222 'media abajo' 2026-09-10 ' — _revisar: 2026-09-23_')" "$PP"
chk "misma prioridad: la de arriba" "1" "$(out | grep -c '^Retomamos:.*p-1111111111')"

echo "== 🔔 adversariales: bloqueado y el del Proximo paso no salen aunque venzan hoy =="
armar "$(L p-aaaaaaaaaa 'hoy bloqueada' 2026-09-22 ' — _revisar: 2026-09-23 — _bloqueado: un peer_')$(L p-cccccccccc 'hoy del proximo paso' 2026-09-22 ' — _revisar: 2026-09-23_')" "" "**Próximo paso:** hacer lo del _id: p-cccccccccc_."
chk "nada" "" "$(out)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
