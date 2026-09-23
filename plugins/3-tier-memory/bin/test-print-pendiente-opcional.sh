#!/bin/bash
# Prueba de bin/print-pendiente-opcional.py (checkpoint-3t Step 8e, 2.35.0).
#
# El prompt opcional reemplaza la linea `Sigue abierto:` del snippet. Lo que importa: que elija por
# CAMPOS (_revisar, _bloqueado, seccion Alta, _creado), nunca por el texto, y que no proponga lo
# que no se puede hacer ya (bloqueado, fecha futura) ni repita el `Proximo paso`.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proyecto"; M="$P/memory"; F="$M/sessions/2026-09-23-demo.md"
armar() {   # $1 = lineas de Alta, $2 = lineas de Media, $3 = linea Proximo paso
  rm -rf "$P"; mkdir -p "$M/sessions"
  printf '# Pendientes\n\n## Alta prioridad\n\n%b\n## Media prioridad\n\n%b\n## Baja prioridad\n' "$1" "$2" > "$M/_pendientes.md"
  printf -- '---\ntype: session\ndate: 2026-09-23\n---\n# Demo\n\n## Como retomar\n\n```\nRetomamos: demo.\n\n%s\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```\n\n## Related\n' "$3" > "$F"
  printf -- '---\ntype: session\n---\n# Origen\n' > "$M/sessions/2026-09-20-origen.md"
}
L() {   # $1 id, $2 texto, $3 creado, $4 cola de metadatos
  printf -- '- [ ] %s — _origen: [[sessions/2026-09-20-origen]]_ — _creado: %s_ — _id: %s_%s\\n' "$2" "$3" "$1" "$4"
}
out() { python3 "$BIN/print-pendiente-opcional.py" "$F" --hoy 2026-09-23 2>&1; }
PP="Proximo paso: arreglar algo _id: p-9999999999_."

echo "== sin candidatos: no imprime nada y sale 0 =="
armar "" "$(L p-1111111111 'media normal' 2026-09-01 '')" "$PP"
chk "vacio" "" "$(out)"
python3 "$BIN/print-pendiente-opcional.py" "$F" --hoy 2026-09-23 >/dev/null; chk "rc 0" "0" "$?"

echo "== Alta: el _creado mas reciente; a igual fecha, la fila de mas arriba =="
armar "$(L p-aaaaaaaaaa 'alta vieja' 2026-09-01 '')$(L p-bbbbbbbbbb 'alta nueva arriba' 2026-09-20 '')$(L p-cccccccccc 'alta nueva abajo' 2026-09-20 '')" "" "$PP"
O=$(out)
chk "elige la nueva de arriba" "1" "$(printf '%s' "$O" | grep -c 'alta nueva arriba _id: p-bbbbbbbbbb_')"
chk "un solo prompt" "1" "$(printf '%s' "$O" | grep -c '^Retomamos:')"
chk "motivo Alta" "1" "$(printf '%s' "$O" | grep -c '^Motivo: Alta abierto desde 2026-09-20')"
chk "texto sin metadatos" "0" "$(printf '%s' "$O" | grep '^Retomamos:' | grep -c '_origen')"
# La ruta se compara por su final: en Windows Python imprime la ruta nativa (C:\...) y $P es la de
# Git Bash (/c/...). Las dos son la misma carpeta; el prompt se pega en el sistema de quien lo lee.
chk "Proyecto con la ruta del proyecto" "1" "$(printf '%s' "$O" | grep -c '^Proyecto: proyecto — .*[/\\]proyecto$')"
chk "Contexto de su _origen" "1" "$(printf '%s' "$O" | grep -c '^Contexto: memory/sessions/2026-09-20-origen.md')"
chk "clausula de cierre" "1" "$(printf '%s' "$O" | grep -c 'cierralo con /checkpoint-3t')"

echo "== adversariales: bloqueado, _revisar futuro y el del Proximo paso no se proponen =="
armar "$(L p-aaaaaaaaaa 'alta bloqueada' 2026-09-22 ' — _bloqueado: otra instalacion_')$(L p-bbbbbbbbbb 'alta con fecha futura' 2026-09-22 ' — _revisar: 2026-09-30_')$(L p-cccccccccc 'alta del proximo paso' 2026-09-22 '')$(L p-dddddddddd 'alta valida' 2026-09-01 '')" "" "**Próximo paso:** hacer lo del _id: p-cccccccccc_."
O=$(out)
chk "elige la unica valida" "1" "$(printf '%s' "$O" | grep -c 'p-dddddddddd')"
chk "ni bloqueada, ni futura, ni la del paso" "0" "$(printf '%s' "$O" | grep -c 'p-aaaaaaaaaa\|p-bbbbbbbbbb\|p-cccccccccc')"
armar "$(L p-aaaaaaaaaa 'alta bloqueada' 2026-09-22 ' — _bloqueado: otra instalacion_')" "" "$PP"
chk "solo bloqueados: nada" "" "$(out)"
armar "$(L p-aaaaaaaaaa 'la palabra _bloqueado en el texto no bloquea' 2026-09-22 '')" "" "$PP"
chk "'_bloqueado' dentro del texto no cuenta (campo, no prosa)" "1" "$(out | grep -c 'p-aaaaaaaaaa')"

echo "== vencidos: ganan a los Alta, hasta 2, el mas viejo primero, de cualquier prioridad =="
armar "$(L p-aaaaaaaaaa 'alta nueva' 2026-09-22 '')" "$(L p-1111111111 'media vence hoy' 2026-09-10 ' — _revisar: 2026-09-23_')$(L p-2222222222 'media vencida' 2026-09-10 ' — _revisar: 2026-09-15_')$(L p-3333333333 'media vencida tercera' 2026-09-10 ' — _revisar: 2026-09-20_')" "$PP"
O=$(out)
chk "dos prompts" "2" "$(printf '%s' "$O" | grep -c '^Retomamos:')"
chk "primero el mas viejo" "p-2222222222" "$(printf '%s' "$O" | grep '^Retomamos:' | head -1 | grep -o 'p-[0-9a-f]*')"
chk "segundo el siguiente" "p-3333333333" "$(printf '%s' "$O" | grep '^Retomamos:' | sed -n 2p | grep -o 'p-[0-9a-f]*')"
chk "el Alta no entra" "0" "$(printf '%s' "$O" | grep -c 'p-aaaaaaaaaa')"
chk "motivo vencido" "1" "$(printf '%s' "$O" | grep -c '^Motivo: vencido desde 2026-09-15')"
armar "" "$(L p-1111111111 'media vence hoy' 2026-09-10 ' — _revisar: 2026-09-23_')" "$PP"
chk "motivo vence hoy" "1" "$(out | grep -c '^Motivo: vence hoy (_revisar 2026-09-23)')"
armar "" "$(L p-1111111111 'vencida pero bloqueada' 2026-09-10 ' — _revisar: 2026-09-15 — _bloqueado: un peer_')" "$PP"
chk "vencida y bloqueada: nada" "" "$(out)"

echo "== origen sin ficha: sin linea Contexto =="
armar "$(printf -- '- [ ] alta sin origen — _creado: 2026-09-22_ — _id: p-aaaaaaaaaa_\\n')" "" "$PP"
O=$(out)
chk "propone" "1" "$(printf '%s' "$O" | grep -c 'p-aaaaaaaaaa')"
chk "sin Contexto" "0" "$(printf '%s' "$O" | grep -c '^Contexto:')"

echo "== caso 5 colapsado (sin Proximo paso): igual propone =="
armar "$(L p-aaaaaaaaaa 'alta valida' 2026-09-22 '')" "" "x"
python3 - "$F" <<'PY'
import sys, re; p=sys.argv[1]; t=open(p, encoding="utf-8").read()
t=re.sub(r"## Como retomar\n.*?\n## Related", "## Como retomar\n\nNinguno — la sesion cerro sola.\n\n## Related", t, flags=re.S)
open(p, "w", encoding="utf-8").write(t)
PY
chk "propone" "1" "$(out | grep -c 'p-aaaaaaaaaa')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
