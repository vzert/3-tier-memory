#!/usr/bin/env bash
# Contrato de /migrate 2e con el volcado de pendientes de un hook propio del proyecto (2.63.0).
#
# Desde que session-start.sh dejo de inyectar pendientes (medido: el agente no usaba la lista,
# 0 de 40 sesiones), un hook propio que vuelca _pendientes.md ya no DUPLICA nada. /migrate lo
# leia como duplicado y media esa duplicacion con la linea "PENDIENTES ABIERTOS (N)" del plugin,
# que ya no existe: con el texto viejo, el agente que corre /migrate buscaria una linea que nunca
# llega. El consumidor de migrate.md es el modelo que lo ejecuta, asi que lo que se puede probar
# es el texto que va a leer: que no le pida la linea muerta, que no llame duplicado al volcado, y
# que quitarlo sea una opcion explicita y nunca la de por defecto.
#
# Uso: test-migrate-volcado-pendientes.sh   (exit 0 = todo verde)
set -u
MD="$(cd "$(dirname "$0")/.." && pwd)/commands/migrate.md"
FAIL=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=1; }

[ -s "$MD" ] || { echo "  FAIL no existe $MD"; exit 1; }

# Solo la seccion 2e: un acierto en otra parte del archivo no prueba nada de esta.
SEC=$(awk '/^### 2e\./{on=1} /^## Step 3/{on=0} on' "$MD")
[ -n "$SEC" ] || { echo "  FAIL no se encontro la seccion 2e"; exit 1; }

printf '%s' "$SEC" | grep -q 'PENDIENTES ABIERTOS' \
  && bad "2e no pide la linea PENDIENTES ABIERTOS, que el plugin ya no emite" \
  || ok "2e no pide la linea PENDIENTES ABIERTOS, que el plugin ya no emite"
printf '%s' "$SEC" | grep -q 'CEILING\|BODY_CAP\|NON_PENDIENTE_RE' \
  && bad "2e no cita constantes del parser que se fue de session-start.sh" \
  || ok "2e no cita constantes del parser que se fue de session-start.sh"
printf '%s' "$SEC" | grep -q '\[PARTIAL\]\|OVERLAPS WITH THE PLUGIN' \
  && bad "el volcado ya no se rotula como solapado con el plugin" \
  || ok "el volcado ya no se rotula como solapado con el plugin"
printf '%s' "$SEC" | grep -q '\[PENDIENTES\]' \
  && ok "el volcado tiene su propia etiqueta" || bad "el volcado tiene su propia etiqueta"
printf '%s' "$SEC" | grep -q '0 of 40' \
  && ok "2e da la medicion" || bad "2e da la medicion"
printf '%s' "$SEC" | grep -q 'never remove it by default' \
  && ok "quitar el volcado nunca es el defecto" || bad "quitar el volcado nunca es el defecto"
# La opcion por defecto (la 1) conserva el volcado; quitarlo es la 2.
printf '%s' "$SEC" | grep -q '^  1) Drop only the \[DUPLICATE\] lines, keep the dump' \
  && ok "la opcion 1 conserva el volcado" || bad "la opcion 1 conserva el volcado"
printf '%s' "$SEC" | grep -q '^  2) Also drop the \[PENDIENTES\] dump' \
  && ok "la opcion 2 lo quita, de forma explicita" || bad "la opcion 2 lo quita, de forma explicita"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
