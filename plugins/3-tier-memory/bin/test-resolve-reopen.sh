#!/bin/bash
# Prueba de la REVERSA de `pendiente.resolve` (2.31.0).
#
# El hueco que cierra, medido el 2026-09-19 (pendiente p-d949b88e8a):
# `apply_expire_index` archivaba la linea verbatim en pendientes/_caducados.md, asi que
# `pendiente.reopen` podia devolverla intacta. `apply_resolve_index` hacia `del lines[i]` y no
# guardaba nada, asi que `reopen` —que solo miraba _caducados.md— devolvia False EN SILENCIO sobre
# un pendiente resuelto. Un cierre equivocado no tenia vuelta atras por evento.
#
# Ese dia se reabrio p-532174ff63 a mano en tres pasos, y solo funciono por tres casualidades: el
# `pendiente.add` original seguia en .journal/applied/, `--creado` permitia reproducir
# sha1(texto+creado+origen), y journal_strict estaba apagado. Con journal_strict=1 el paso 2 esta
# denegado y no habia salida limpia.
#
# Las dos propiedades que este fichero vigila:
#
# 1. LA LINEA VUELVE BYTE A BYTE. No "equivalente": identica. Si el reopen la reconstruyera, la
#    cola de metadatos (_origen/_creado/_id/_revisar y cualquier clave que el compactador todavia
#    no conozca) se perderia, y con ella el id que la hace encontrable. Casos 2 y 3.
#
# 2. LOS DOS SILENCIOS SE SEPARAN. "ya estaba reabierto" y "se cerro antes de 2.31.0 y no hay nada
#    que devolver" eran el mismo `return False` mudo. El segundo pasa a cuarentena con motivo.
#    Casos 6 y 7.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
linea() { grep -m1 "_id: $1_" "$M/_pendientes.md" 2>/dev/null || true; }
fila() { grep -m1 "_id: $1_" "$M"/pendientes/2026-09.md 2>/dev/null || true; }
# `grep -c` sobre un fichero que no existe no imprime nada: sin el `|| echo 0` el helper devuelve
# cadena vacia y un `chk ... "0"` falla diciendo que esperaba 0 y salio '' — que es cierto pero
# oculta que el caso real (el fichero no se creo) es justo el que se queria comprobar.
# Se comprueba que el fichero EXISTA en vez de apoyarse en el estado de salida de grep. Con el
# fichero presente `grep -c` ya imprime 0 cuando no hay coincidencias; lo que no maneja es el
# fichero ausente, que aqui es un caso legitimo (antes del primer cierre no hay _resueltos.md).
# Un `|| echo 0` no sirve para eso: `grep -c` sale 1 tambien cuando cuenta 0, asi que imprimiria
# las dos cosas, "0\n0", y la comparacion falla por un motivo que no es el que se esta probando.
cuenta_en() { if [ -f "$1" ]; then grep -c "$2" "$1" | tr -d ' '; else echo 0; fi; }
arch() { cuenta_en "$M/pendientes/_resueltos.md" "_id: $1_"; }
cad() { cuenta_en "$M/pendientes/_caducados.md" "_id: $1_"; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
motivo() { cat "$M/.journal/quarantine"/*.reason 2>/dev/null | tr '\n' ' '; }

fixture() {
  rm -rf "$M"; mkdir -p "$M/pendientes" "$M/sessions"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '# demo\n' > "$M/sessions/2026-09-19-demo.md"
  ID=$(emit --type pendiente.add --text "verificar el nudge en una instalacion real" \
        --prioridad Alta --origen "[[sessions/2026-09-19-demo]]" --creado 2026-09-19)
  compact --quiet >/dev/null
  L0=$(linea "$ID"); F0=$(fila "$ID")
}
cerrar() {
  emit --type pendiente.resolve --id "$ID" --estado resolved \
    --sesion "[[sessions/2026-09-19-demo]]" --nota "cerrado por error" >/dev/null
  compact --quiet >/dev/null
}

echo "== 1. resolve archiva la linea VERBATIM y la saca del indice =="
fixture; cerrar
chk "ya no esta viva" "0" "$(printf '%s' "$(linea "$ID")" | grep -c .)"
chk "esta archivada en _resueltos.md" "1" "$(arch "$ID")"
chk "el archivo conserva el texto entero" "1" "$(grep -c 'verificar el nudge en una instalacion real' "$M/pendientes/_resueltos.md")"
chk "y conserva la cola de metadatos" "1" "$(grep -c "_origen: \[\[sessions/2026-09-19-demo\]\]_ — _creado: 2026-09-19_ — _id: ${ID}_" "$M/pendientes/_resueltos.md")"
chk "la marca lleva el estado del cierre" "1" "$(grep -c '_estado: resolved_' "$M/pendientes/_resueltos.md")"
chk "y la prioridad de la que salio" "1" "$(grep -c '_prio: alta_' "$M/pendientes/_resueltos.md")"
chk "NO toca _caducados.md (son dos cosas distintas)" "0" "$(cad "$ID")"

echo "== 2. reopen devuelve la linea BYTE A BYTE =="
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null
chk "la linea vuelve identica a la original" "$L0" "$(linea "$ID")"
chk "vuelve a su seccion Alta, no a Media" "1" "$(sed -n '/## Alta/,/## Media/p' "$M/_pendientes.md" | grep -c "_id: ${ID}_")"
chk "sale del archivo" "0" "$(arch "$ID")"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 3. reopen limpia las celdas Resuelto/Sesion de la fila mensual =="
# Ningun evento las deshacia: es literalmente el paso que hubo que hacer a mano el 2026-09-19.
chk "la fila mensual vuelve identica" "$F0" "$(fila "$ID")"
chk "sin fecha de resolucion" "0" "$(printf '%s' "$(fila "$ID")" | grep -c 'resolved')"

echo "== 4. reopen es idempotente: dos veces no duplica ni cuarentena =="
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null
chk "sigue habiendo UNA sola linea" "1" "$(grep -c "_id: ${ID}_" "$M/_pendientes.md")"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 5. replay de resolve: no duplica la entrada del archivo =="
fixture; cerrar
cp "$M"/.journal/applied/*/*.json "$M"/.journal/pending/
compact --quiet >/dev/null 2>&1 || true
chk "una sola entrada en el archivo" "1" "$(arch "$ID")"

echo "== 6. cerrado ANTES de 2.31.0: cuarentena con motivo, no silencio =="
# Se simula el estado que dejaba la version vieja: fila mensual cerrada, pero sin linea archivada.
fixture; cerrar
rm -f "$M/pendientes/_resueltos.md"
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
has "motivo no-archivado" "$(motivo)" "no-archivado"
has "el motivo dice POR QUE no hay nada que devolver" "$(motivo)" "antes de 2.31.0"
has "y dice que hacer en su lugar" "$(motivo)" "pendiente.add"
chk "no invento una linea" "0" "$(printf '%s' "$(linea "$ID")" | grep -c .)"

echo "== 7. un id que nunca existio sigue siendo noop mudo, NO cuarentena =="
# El otro silencio: no hay nada roto que reportar, no hay que gritar.
fixture
emit --type pendiente.reopen --id "p-0000000000" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "sin cuarentena" "0" "$(cuar)"
chk "y no escribio nada" "0" "$(grep -c 'p-0000000000' "$M/_pendientes.md")"

echo "== 8. expire + reopen sigue funcionando (sin regresion) =="
fixture
emit --type pendiente.expire --id "$ID" --dias 90 >/dev/null
compact --quiet >/dev/null
chk "va a _caducados.md, no a _resueltos.md" "1" "$(cad "$ID")"
chk "y NO a _resueltos.md" "0" "$(arch "$ID")"
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null
chk "reopen lo devuelve byte a byte" "$L0" "$(linea "$ID")"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 9. los dos archivos conviven: un resuelto y un caducado a la vez =="
fixture
ID2=$(emit --type pendiente.add --text "otro pendiente distinto" --prioridad Baja \
        --origen "[[sessions/2026-09-19-demo]]" --creado 2026-09-19)
compact --quiet >/dev/null
cerrar
emit --type pendiente.expire --id "$ID2" --dias 90 >/dev/null
compact --quiet >/dev/null
chk "el resuelto en _resueltos.md" "1" "$(arch "$ID")"
chk "el caducado en _caducados.md" "1" "$(cad "$ID2")"
chk "cada uno en el suyo, sin cruzarse" "0" "$(( $(arch "$ID2") + $(cad "$ID") ))"
emit --type pendiente.reopen --id "$ID2" >/dev/null
compact --quiet >/dev/null
chk "reopen del caducado no toca al resuelto" "1" "$(arch "$ID")"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 10. checkpoint-audit no cuenta el archivo como fila mensual =="
# Antes hacia glob de pendientes/*.md y los concatenaba como pajar: un id que SOLO estuviera
# archivado contaba como "tiene su fila mensual", dando por hecho un dual-write que no existe.
# Era falso ya con _caducados.md; _resueltos.md, que crece en CADA cierre, lo volvia lo normal.
fixture; cerrar
rm -f "$M"/pendientes/2026-09.md          # solo queda el archivo, sin fila mensual real
printf -- '---\ntype: session\n---\n# s\n\n## Pendientes\n\n- [ ] x — _id: %s_\n' "$ID" > "$M/sessions/2026-09-20-x.md"
O=$(python3 "$BIN/checkpoint-audit.py" --session-file "$M/sessions/2026-09-20-x.md" --no-git "$M" 2>&1 || true)
has "el audit ve el id huerfano en vez de darlo por bueno" "$O" "sin fila"

echo "== 11. replay del cierre DESPUES de reabrir: NO vuelve a cerrar =="
# El caso que el adversario externo rompio, y la razon por la que el caso 5 no bastaba: alli el
# replay corria con el pendiente AUN cerrado, que es el facil. Aqui se reabre primero. El reopen
# devuelve la linea VIVA, asi que el evento viejo la encuentra otra vez en apply_resolve_index y
# la cerraba de nuevo — deshaciendo en silencio una decision deliberada del usuario.
fixture; cerrar
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null
chk "reabierto y vivo" "1" "$(printf '%s' "$(linea "$ID")" | grep -c .)"
cp "$M"/.journal/applied/*/*.json "$M"/.journal/pending/
compact --quiet >/dev/null 2>&1 || true
chk "tras el replay SIGUE vivo" "1" "$(printf '%s' "$(linea "$ID")" | grep -c .)"
chk "y la linea es la original" "$L0" "$(linea "$ID")"
chk "la fila mensual NO vuelve a marcarse resuelta" "0" "$(printf '%s' "$(fila "$ID")" | grep -c 'resolved')"
chk "no lo archiva otra vez" "0" "$(arch "$ID")"
chk "sin cuarentena: es un replay, no un error" "0" "$(cuar)"

echo "== 12. un cierre NUEVO despues de reabrir SI funciona =="
# La guarda frena la reaplicacion del cierre ya revertido, no los cierres futuros. Se distingue
# por el ts del evento; si se frenara por id, un pendiente reabierto no se podria volver a cerrar.
emit --type pendiente.resolve --id "$ID" --estado resolved \
  --sesion "[[sessions/2026-09-19-demo]]" --nota "ahora si" >/dev/null
compact --quiet >/dev/null
chk "el cierre nuevo se aplica" "0" "$(printf '%s' "$(linea "$ID")" | grep -c .)"
chk "y queda archivado para poder revertirlo otra vez" "1" "$(arch "$ID")"
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null
chk "que se puede revertir de nuevo, byte a byte" "$L0" "$(linea "$ID")"

echo "== 13. el archivo no le deja al usuario contabilidad del journal encima =="
# `_ev:` es la clave de idempotencia del archivado. Si viajara de vuelta en el reopen, la linea
# restaurada llevaria un sufijo que nunca tuvo y "byte a byte" seria falso.
fixture; cerrar
chk "el archivo si lleva _ev: (lo necesita)" "1" "$(grep -c '_ev: ' "$M/pendientes/_resueltos.md")"
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null
chk "la linea restaurada NO lleva _ev:" "0" "$(printf '%s' "$(linea "$ID")" | grep -c '_ev:')"
chk "ni _resuelto: ni _prio:" "0" "$(printf '%s' "$(linea "$ID")" | grep -cE '_resuelto:|_prio:')"

echo "== 14. si no se puede anotar la reversa, el reopen NO se hace a medias =="
# Toda la proteccion contra "un replay deshace el reopen" vive en .journal/reabiertos.log. Una
# version anterior restauraba la linea igual y solo dejaba un WARN cuando no podia escribirlo: el
# reopen quedaba hecho pero SIN proteccion, o sea deshecho mas tarde y en silencio — el mismo fallo
# por la puerta del manejo de errores. Ahora cuarentena y no toca nada.
# El fichero se hace INESCRIBIBLE poniendo un directorio en su lugar (IsADirectoryError, universal);
# `chmod 000` no sirve en Windows/Git Bash (learning 125).
fixture; cerrar
mkdir -p "$M/.journal/reabiertos.log"
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null 2>&1 || true
chk "cuarentena 1" "1" "$(cuar)"
has "motivo no-registro" "$(motivo)" "no-registro"
chk "el pendiente NO volvio al indice" "0" "$(printf '%s' "$(linea "$ID")" | grep -c .)"
chk "y sigue archivado, no se perdio" "1" "$(arch "$ID")"
rmdir "$M/.journal/reabiertos.log"

echo "== 15. con el registro ya escribible, el mismo reopen funciona =="
# Cierra el caso anterior: la cuarentena era por el registro, no por otra cosa.
rm -rf "$M/.journal/quarantine"
emit --type pendiente.reopen --id "$ID" >/dev/null
compact --quiet >/dev/null
chk "ahora si vuelve, byte a byte" "$L0" "$(linea "$ID")"
chk "sin cuarentena" "0" "$(cuar)"
chk "y la reversa quedo anotada" "1" "$(grep -c "$ID" "$M/.journal/reabiertos.log")"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
