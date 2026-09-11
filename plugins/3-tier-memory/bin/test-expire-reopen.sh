#!/bin/bash
# Round-trip de caducidad: expire -> reopen debe devolver _pendientes.md y la fila
# mensual BYTE A BYTE como estaban. Si esto no pasa, --apply no debe usarse nunca.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MEM="$T/memory"; mkdir -p "$MEM/pendientes"
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FAIL $1"; echo "    esperado: $2"; echo "    obtenido: $3"; fi; }

cat > "$MEM/_pendientes.md" <<'EOF'
# Pendientes

## Alta prioridad

- [ ] Item nuevo que no caduca — _origen: [[sessions/2026-09-10-x]]_ — _creado: 2026-09-10_ — _id: p-1111111111_

## Media prioridad

- [ ] Item viejo con `pipe \| dentro` y **negritas** — _origen: [[sessions/2026-01-02-y]]_ — _creado: 2026-01-02_ — _id: p-2222222222_

## Baja prioridad
EOF
cat > "$MEM/pendientes/2026-01.md" <<'EOF'
---
type: pendientes-archive
month: 2026-01
---
# Pendientes — Enero 2026

| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |
|---|---|---|---|---|---|---|
| 1 | Item viejo con `pipe \| dentro` y **negritas** _id: p-2222222222_ | Media | 2026-01-02 | [[sessions/2026-01-02-y]] | | |
EOF
cp "$MEM/_pendientes.md" "$T/antes-index.md"
cp "$MEM/pendientes/2026-01.md" "$T/antes-mensual.md"

echo "== dry-run no escribe =="
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM" --modo edad --days 90 >/dev/null 2>&1
chk "dry-run deja el indice intacto" "$(md5 -q "$T/antes-index.md")" "$(md5 -q "$MEM/_pendientes.md")"

echo "== expire =="
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM" --modo edad --days 90 --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null 2>&1
chk "el viejo salio del indice" "0" "$(grep -c 'p-2222222222' "$MEM/_pendientes.md")"
chk "el nuevo sigue"            "1" "$(grep -c 'p-1111111111' "$MEM/_pendientes.md")"
chk "quedo en _caducados"       "1" "$(grep -c "p-2222222222" "$MEM/pendientes/_caducados.md" 2>/dev/null || true)"
chk "fila mensual = expired"    "1" "$(grep -c 'expired — sin actividad' "$MEM/pendientes/2026-01.md")"

echo "== reopen =="
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM" --revertir p-2222222222 --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null 2>&1
chk "indice byte a byte"   "$(md5 -q "$T/antes-index.md")"   "$(md5 -q "$MEM/_pendientes.md")"
chk "mensual byte a byte"  "$(md5 -q "$T/antes-mensual.md")" "$(md5 -q "$MEM/pendientes/2026-01.md")"
chk "_caducados vacio"     "0" "$(grep -c "p-2222222222" "$MEM/pendientes/_caducados.md" 2>/dev/null || true)"

echo "== idempotencia =="
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM" --revertir p-2222222222 --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null 2>&1
chk "reopen dos veces no duplica" "1" "$(grep -c 'p-2222222222' "$MEM/_pendientes.md")"

echo "== valvula _revisar futuro =="
sed -i '' 's|_creado: 2026-01-02_|_creado: 2026-01-02_ — _revisar: 2027-01-01_|' "$MEM/_pendientes.md"
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM" --modo edad --days 90 --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null 2>&1
chk "no caduca con _revisar futuro" "1" "$(grep -c 'p-2222222222' "$MEM/_pendientes.md")"

echo "== legacy sin fila mensual: la prioridad debe conservarse =="
# Caso real de la primera corrida: items de 2026-04 sin fila en pendientes/YYYY-MM.md.
# Sin la prioridad en la marca, reopen los devolvia todos a Media.
MEM2="$T/mem2"; mkdir -p "$MEM2/pendientes"
cat > "$MEM2/_pendientes.md" <<'EOF'
# Pendientes

## Alta prioridad

- [ ] Legacy alta sin fila mensual — _origen: [[sessions/2026-03-01-z]]_ — _creado: 2026-03-01_ — _id: p-3333333333_

## Media prioridad

## Baja prioridad

- [ ] Legacy baja sin fila mensual — _origen: [[sessions/2026-03-01-z]]_ — _creado: 2026-03-01_ — _id: p-4444444444_
EOF
cp "$MEM2/_pendientes.md" "$T/antes2.md"
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM2" --modo edad --days 90 --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM2" --quiet >/dev/null 2>&1
chk "los dos legacy salieron" "0" "$(grep -c '^- \[ \]' "$MEM2/_pendientes.md")"
for id in p-3333333333 p-4444444444; do
  python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM2" --revertir $id --apply >/dev/null 2>&1
done
python3 "$BIN/journal-compact.py" --memory-dir "$MEM2" --quiet >/dev/null 2>&1
chk "vuelven a su seccion con su prioridad" "$(md5 -q "$T/antes2.md")" "$(md5 -q "$MEM2/_pendientes.md")"

echo "== modo revisar: solo caduca lo que declaro su ventana y la paso =="
MEM3="$T/mem3"; mkdir -p "$MEM3/pendientes"
printf '# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$MEM3/_pendientes.md"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM3" --type pendiente.add --text "ventana vencida" \
  --prioridad Media --origen "[[sessions/2026-01-01-y]]" --creado 2026-01-01 --revisar 2026-02-01 >/dev/null
python3 "$BIN/journal-emit.py" --memory-dir "$MEM3" --type pendiente.add --text "ventana futura" \
  --prioridad Media --origen "[[sessions/2026-01-01-y]]" --creado 2026-01-01 --revisar 2099-01-01 >/dev/null
python3 "$BIN/journal-emit.py" --memory-dir "$MEM3" --type pendiente.add --text "viejo sin ventana" \
  --prioridad Media --origen "[[sessions/2026-01-01-y]]" --creado 2026-01-01 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM3" --quiet >/dev/null 2>&1
chk "el campo _revisar se escribe" "2" "$(grep -c '_revisar:' "$MEM3/_pendientes.md")"
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM3" --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM3" --quiet >/dev/null 2>&1
chk "caduca SOLO la ventana vencida" "1" "$(grep -c '^- \[ \]' "$MEM3/pendientes/_caducados.md" 2>/dev/null || true)"
chk "la futura sigue abierta"        "1" "$(grep -c 'ventana futura' "$MEM3/_pendientes.md")"
chk "el viejo sin ventana sigue"     "1" "$(grep -c 'viejo sin ventana' "$MEM3/_pendientes.md")"

echo "== pendiente.window: pone la ventana por evento, no a mano =="
MEM4="$T/mem4"; mkdir -p "$MEM4/pendientes"
printf '# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$MEM4/_pendientes.md"
W=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEM4" --type pendiente.add --text "verificar algo" \
  --prioridad Media --origen "[[sessions/2026-01-01-y]]" --creado 2026-01-01)
python3 "$BIN/journal-compact.py" --memory-dir "$MEM4" --quiet >/dev/null 2>&1
python3 "$BIN/journal-emit.py" --memory-dir "$MEM4" --type pendiente.window --id "$W" --revisar 2026-02-01 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM4" --quiet >/dev/null 2>&1
chk "la ventana se escribe"       "1" "$(grep -c '_revisar: 2026-02-01_' "$MEM4/_pendientes.md")"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM4" --type pendiente.window --id "$W" --revisar 2027-03-03 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM4" --quiet >/dev/null 2>&1
chk "reemplaza, no acumula"       "1" "$(grep -c '_revisar:' "$MEM4/_pendientes.md")"
chk "y es la nueva"               "1" "$(grep -c '_revisar: 2027-03-03_' "$MEM4/_pendientes.md")"
chk "una sola linea abierta"      "1" "$(grep -c '^- \[ \]' "$MEM4/_pendientes.md")"

echo "== orden de escritura: el destino se escribe antes que el borrado =="
# Si expire borrara primero, un fallo entre escrituras perderia la linea. Se comprueba el
# invariante observable: tras expire la linea esta en _caducados; tras reopen, en _pendientes.
MEM5="$T/mem5"; mkdir -p "$MEM5/pendientes"
printf '# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n- [ ] linea unica — _origen: [[sessions/2026-01-01-y]]_ — _creado: 2026-01-01_ — _id: p-5555555555_\n\n## Baja prioridad\n' > "$MEM5/_pendientes.md"
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM5" --modo edad --days 90 --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM5" --quiet >/dev/null 2>&1
EN_CAD=$(grep -c 'p-5555555555' "$MEM5/pendientes/_caducados.md" 2>/dev/null || true)
EN_IDX=$(grep -c 'p-5555555555' "$MEM5/_pendientes.md" 2>/dev/null || true)
chk "tras expire existe en exactamente un sitio" "1" "$((EN_CAD + EN_IDX))"
chk "y ese sitio es _caducados"                  "1" "$EN_CAD"
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM5" --revertir p-5555555555 --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM5" --quiet >/dev/null 2>&1
EN_CAD=$(grep -c 'p-5555555555' "$MEM5/pendientes/_caducados.md" 2>/dev/null || true)
EN_IDX=$(grep -c 'p-5555555555' "$MEM5/_pendientes.md" 2>/dev/null || true)
chk "tras reopen existe en exactamente un sitio" "1" "$((EN_CAD + EN_IDX))"
chk "y ese sitio es _pendientes"                 "1" "$EN_IDX"

echo "== paginacion: cerrar items de un lote no hace que el siguiente se salte otros =="
MEM6="$T/mem6"; mkdir -p "$MEM6/pendientes"
printf '# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$MEM6/_pendientes.md"
for n in 1 2 3 4 5 6; do
  python3 "$BIN/journal-emit.py" --memory-dir "$MEM6" --type pendiente.add --text "item numero $n" \
    --prioridad Media --origen "[[sessions/2026-01-0$n-y]]" --creado "2026-01-0$n" >/dev/null
done
python3 "$BIN/journal-compact.py" --memory-dir "$MEM6" --quiet >/dev/null 2>&1
CUR=$(python3 "$BIN/triage-scan.py" --memory-dir "$MEM6" --limit 3 | sed -n 's/^Siguiente lote:  --desde \([^ ]*\) .*/\1/p')
chk "el cursor lleva la fecha del 3er item" "2026-01-03" "${CUR%%:*}"
# cerrar los 3 del primer lote y pedir el siguiente lote con el cursor
for n in 1 2 3; do
  ID=$(grep "item numero $n" "$MEM6/_pendientes.md" | grep -o 'p-[0-9a-f]*')
  python3 "$BIN/journal-emit.py" --memory-dir "$MEM6" --type pendiente.resolve --id "$ID" \
    --estado resolved --sesion "[[sessions/2026-09-11-x]]" >/dev/null
done
python3 "$BIN/journal-compact.py" --memory-dir "$MEM6" --quiet >/dev/null 2>&1
SIG=$(python3 "$BIN/triage-scan.py" --memory-dir "$MEM6" --desde "$CUR" --limit 3 | grep -c 'item numero')
chk "el lote siguiente trae los 3 restantes" "3" "$SIG"
for n in 4 5 6; do
  chk "  no se salto el item $n" "1" "$(python3 "$BIN/triage-scan.py" --memory-dir "$MEM6" --desde "$CUR" --limit 3 | grep -c "item numero $n")"
done

echo "== paginacion dura: varios items EL MISMO DIA y items sin _creado =="
# El adversario (ronda 2) mostro que un cursor solo-fecha e inclusivo se repite para siempre
# cuando hay mas items del mismo dia que --limit y el usuario los deja abiertos, y que los items
# sin `_creado` no se podian pasar. Aqui: 5 del mismo dia + 1 sin fecha, en lotes de 2.
MEM7="$T/mem7"; mkdir -p "$MEM7/pendientes"
printf '# Pendientes\n\n## Media prioridad\n' > "$MEM7/_pendientes.md"
for n in 1 2 3 4 5; do
  python3 "$BIN/journal-emit.py" --memory-dir "$MEM7" --type pendiente.add --text "mismodia $n" \
    --prioridad Media --origen "[[sessions/2026-01-01-y]]" --creado 2026-01-01 >/dev/null
done
python3 "$BIN/journal-compact.py" --memory-dir "$MEM7" --quiet >/dev/null 2>&1
printf -- '- [ ] legacy sin fecha — _origen: [[sessions/2026-01-01-y]]_ — _id: p-9999999999_\n' >> "$MEM7/_pendientes.md"

: > "$T/vistos.txt"; CUR=""; RONDAS=0
while [ "$RONDAS" -lt 8 ]; do
  RONDAS=$((RONDAS+1))
  if [ -z "$CUR" ]; then
    python3 "$BIN/triage-scan.py" --memory-dir "$MEM7" --limit 2 > "$T/lote.txt" 2>&1
  else
    python3 "$BIN/triage-scan.py" --memory-dir "$MEM7" --desde "$CUR" --limit 2 > "$T/lote.txt" 2>&1
  fi
  grep -E '^  p-' "$T/lote.txt" | awk '{print $1}' >> "$T/vistos.txt"
  CUR=$(sed -n 's/^Siguiente lote:  --desde \([^ ]*\) .*/\1/p' "$T/lote.txt")
  [ -z "$CUR" ] && break
done
TOTAL=$(grep -c 'p-' "$T/vistos.txt")
DISTINTOS=$(sort -u "$T/vistos.txt" | grep -c 'p-')
chk "el cursor termina, no hay bucle" "1" "$([ "$RONDAS" -lt 8 ] && echo 1 || echo 0)"
chk "alcanza los 6 items"             "6" "$DISTINTOS"
chk "y no repite ninguno"             "6" "$TOTAL"
chk "el sin-fecha tambien sale"       "1" "$(grep -c 'p-9999999999' "$T/vistos.txt")"

echo "== fallo inyectado entre las dos escrituras de expire =="
# Si el destino no se puede escribir, expire debe fallar ANTES de borrar el origen.
MEM8="$T/mem8"; mkdir -p "$MEM8/pendientes"
printf '# Pendientes\n\n## Media prioridad\n\n- [ ] no me pierdas — _origen: [[sessions/2026-01-01-y]]_ — _creado: 2026-01-01_ — _id: p-8888888888_\n' > "$MEM8/_pendientes.md"
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM8" --modo edad --days 90 --apply >/dev/null 2>&1
chmod a-w "$MEM8/pendientes"          # el destino pasa a ser inescribible
python3 "$BIN/journal-compact.py" --memory-dir "$MEM8" --quiet >/dev/null 2>&1
chmod u+w "$MEM8/pendientes"
chk "con el destino inescribible, la linea NO se pierde" "1" "$(grep -c 'p-8888888888' "$MEM8/_pendientes.md")"
# y al reintentar con el destino escribible, el traspaso se completa
python3 "$BIN/journal-compact.py" --memory-dir "$MEM8" --quiet >/dev/null 2>&1
EN_CAD=$(grep -c 'p-8888888888' "$MEM8/pendientes/_caducados.md" 2>/dev/null || true)
EN_IDX=$(grep -c 'p-8888888888' "$MEM8/_pendientes.md" 2>/dev/null || true)
chk "al reintentar queda en exactamente un sitio" "1" "$((EN_CAD + EN_IDX))"

echo "== fecha irreal rechazada =="
MEM9="$T/mem9"; mkdir -p "$MEM9/pendientes"
printf '# Pendientes\n\n## Media prioridad\n' > "$MEM9/_pendientes.md"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM9" --type pendiente.window --id p-7777777777 --revisar 2026-99-99 >/dev/null 2>&1
chk "el emisor rechaza 2026-99-99" "1" "$?"

echo "== cursor: id invalido o cerrado no se traga items en silencio =="
MEMA="$T/mema"; mkdir -p "$MEMA/pendientes"
printf '# Pendientes\n\n## Media prioridad\n' > "$MEMA/_pendientes.md"
for n in 1 2 3; do
  python3 "$BIN/journal-emit.py" --memory-dir "$MEMA" --type pendiente.add --text "cur $n" \
    --prioridad Media --origen "[[sessions/2026-01-01-y]]" --creado 2026-01-01 >/dev/null
done
python3 "$BIN/journal-compact.py" --memory-dir "$MEMA" --quiet >/dev/null 2>&1
dig() { python3 -c "import hashlib,sys; print(hashlib.sha1(('triage-cursor:'+sys.argv[1]).encode()).hexdigest()[:4])" "$1"; }

python3 "$BIN/triage-scan.py" --memory-dir "$MEMA" --desde "2026-01-01:zzz:0000" >/dev/null 2>&1
chk "id con forma invalida -> error"  "1" "$?"
python3 "$BIN/triage-scan.py" --memory-dir "$MEMA" --desde "2026-01-01:p-0000000000" >/dev/null 2>&1
chk "cursor sin digito -> error"      "1" "$?"
# Un id ya cerrado NO es error: cerrarlo es lo que hace el barrido, y el corte (fecha,id) sigue
# siendo exacto sobre un id que ya no existe. Solo avisa. Pero su digito TIENE que cuadrar.
python3 "$BIN/triage-scan.py" --memory-dir "$MEMA" --desde "2026-01-01:p-0000000000:$(dig p-0000000000)" >/dev/null 2>&1
chk "id ya cerrado, digito bueno -> NO es error" "0" "$?"
python3 "$BIN/triage-scan.py" --memory-dir "$MEMA" --desde "2026-01-01:p-0000000000:beef" >/dev/null 2>&1
chk "cursor manglado (digito malo) -> error"     "1" "$?"
# Ronda 5: la ronda 4 afirmo que el digito distinguia un cursor copiado de uno inventado, y solo
# probaba el caso facil (digito deliberadamente MAL). El adversario fabrico un id inventado con el
# digito BIEN calculado — sha1 publica — y paso. La afirmacion se retiro; esta asercion fija el
# comportamiento real, que es ACEPTARLO con aviso. No es un error: contra un id inventado lo que
# protege es que el item tenga `_id` persistente, no el digito.
python3 "$BIN/triage-scan.py" --memory-dir "$MEMA" --desde "2026-01-01:p-deadbeef00:$(dig p-deadbeef00)" >/dev/null 2>&1
chk "id inventado con digito BIEN -> NO es error, se acepta" "0" "$?"
chk "y avisa de que ese id no esta abierto" "1" "$(python3 "$BIN/triage-scan.py" --memory-dir "$MEMA" --desde "2026-01-01:p-deadbeef00:$(dig p-deadbeef00)" 2>&1 >/dev/null | grep -c 'ya no esta abierto')"
VAL=$(python3 "$BIN/triage-scan.py" --memory-dir "$MEMA" --limit 1 | sed -n 's/^Siguiente lote:  --desde \([^ ]*\) .*/\1/p')
chk "el cursor que imprime trae 3 partes" "3" "$(printf '%s' "$VAL" | awk -F: '{print NF}')"
python3 "$BIN/triage-scan.py" --memory-dir "$MEMA" --desde "$VAL" --limit 5 >/dev/null 2>&1
chk "el cursor que el imprime si vale" "0" "$?"

echo "== ronda 4: el id sintetico de un item sin _id no depende de la posicion =="
# La ronda 3 los numeraba por posicion. Al cerrar el primero, el segundo pasaba de sin-id-0002 a
# sin-id-0001 y el corte estricto se lo saltaba PARA SIEMPRE. Ahora sale del texto del item.
MEMF="$T/memf"; mkdir -p "$MEMF/pendientes"
printf '# Pendientes\n\n## Media prioridad\n\n' > "$MEMF/_pendientes.md"
printf -- '- [ ] primero sin id\n- [ ] segundo sin id\n' >> "$MEMF/_pendientes.md"
ID_ANTES=$(python3 "$BIN/triage-scan.py" --memory-dir "$MEMF" --tsv | grep 'segundo sin id' | cut -f1)
# se cierra el PRIMERO: en la version por posicion, esto renumeraba al segundo
printf '# Pendientes\n\n## Media prioridad\n\n' > "$MEMF/_pendientes.md"
printf -- '- [ ] segundo sin id\n' >> "$MEMF/_pendientes.md"
ID_DESPUES=$(python3 "$BIN/triage-scan.py" --memory-dir "$MEMF" --tsv | grep 'segundo sin id' | cut -f1)
chk "el id del segundo no cambia al cerrar el primero" "$ID_ANTES" "$ID_DESPUES"
chk "y no es un contador posicional" "0" "$(printf '%s' "$ID_DESPUES" | grep -c '^sin-id-0*[0-9]\{1,4\}$')"

echo "== el compactador rechaza una fecha irreal aunque el emisor no la vea =="
MEMB="$T/memb"; mkdir -p "$MEMB/pendientes/" "$MEMB/.journal/pending"
printf '# Pendientes\n\n## Media prioridad\n' > "$MEMB/_pendientes.md"
cat > "$MEMB/.journal/pending/0000000000000-fake.json" <<'EOJ'
{"v":1,"type":"pendiente.add","ts":1,"session_id":"t","agent_id":"t","payload":{"id":"p-abcdef0123","text":"fecha imposible","prioridad":"Media","origen":"[[sessions/2026-01-01-y]]","creado":"2026-99-99"}}
EOJ
python3 "$BIN/journal-compact.py" --memory-dir "$MEMB" --quiet >/dev/null 2>&1
chk "no entra al indice"        "0" "$(grep -c 'p-abcdef0123' "$MEMB/_pendientes.md")"
chk "y queda en cuarentena"     "1" "$(ls "$MEMB/.journal/quarantine"/*.json 2>/dev/null | wc -l | tr -d ' ')"

echo "== contrato: atomic_write normaliza el salto de linea final =="
# Cambio de comportamiento deliberado: un fichero sin newline final sale CON el. En memory/ eso
# es el bug (lo siguiente que se anada con >> se pega), no un formato que preservar.
MEMC="$T/memc"; mkdir -p "$MEMC/pendientes"
printf '# Pendientes\n\n## Media prioridad\n\n- [ ] sin newline final — _origen: [[sessions/2026-01-01-y]]_ — _creado: 2026-01-01_ — _id: p-6666666666_' > "$MEMC/_pendientes.md"
chk "el fixture empieza SIN newline final" "0" "$(tail -c 1 "$MEMC/_pendientes.md" | od -An -c | grep -c '\\n')"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMC" --type pendiente.window --id p-6666666666 --revisar 2026-12-01 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEMC" --quiet >/dev/null 2>&1
chk "tras escribir, termina CON newline"   "1" "$(tail -c 1 "$MEMC/_pendientes.md" | od -An -c | grep -c '\\n')"
chk "y la linea sigue entera"              "1" "$(grep -c 'sin newline final' "$MEMC/_pendientes.md")"
chk "y el fichero LF sigue en LF"          "0" "$(tr -dc '\r' < "$MEMC/_pendientes.md" | wc -c | tr -d ' ')"

echo "== contrato: atomic_write NO convierte un fichero CRLF =="
# El salto de linea lo manda el fichero, no el sistema operativo. Con el modo texto por defecto
# esto salia LF en macOS y CRLF en Windows: el mismo memory/ compartido entre las dos plataformas
# le daba la vuelta al fichero entero en cada compactacion. Se mide sobre los BYTES: `tail -c 1`
# ve un "\n" igual en los dos casos, asi que contar \r es lo unico que lo distingue.
MEMD="$T/memd"; mkdir -p "$MEMD/pendientes"
printf '# Pendientes\r\n\r\n## Media prioridad\r\n\r\n- [ ] crlf sin newline final — _origen: [[sessions/2026-01-01-y]]_ — _creado: 2026-01-01_ — _id: p-7777777777_' > "$MEMD/_pendientes.md"
CR_ANTES="$(tr -dc '\r' < "$MEMD/_pendientes.md" | wc -c | tr -d ' ')"
chk "el fixture empieza en CRLF y sin newline final" "4" "$CR_ANTES"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMD" --type pendiente.window --id p-7777777777 --revisar 2026-12-01 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEMD" --quiet >/dev/null 2>&1
chk "sigue siendo CRLF, no se convirtio a LF" "5" "$(tr -dc '\r' < "$MEMD/_pendientes.md" | wc -c | tr -d ' ')"
chk "y termina con CRLF, no con un \\n pelado" "1" "$(tail -c 2 "$MEMD/_pendientes.md" | od -An -c | grep -c '\\r  \\n')"
chk "la linea sigue entera"                   "1" "$(grep -c 'crlf sin newline final' "$MEMD/_pendientes.md")"

echo "== normalize-pendientes y journal-compact no discrepan en el salto =="
# Si las dos herramientas detectaran el salto con reglas distintas, cada pasada le daria la vuelta
# al fichero. Aqui normalize- escribe primero (le faltan cabeceras) y compact- despues.
MEME="$T/meme"; mkdir -p "$MEME/pendientes"
printf '# Pendientes\r\n\r\n## Alta prioridad\r\n\r\n- [ ] solo alta — _origen: [[sessions/2026-01-01-y]]_ — _creado: 2026-01-01_ — _id: p-8888888888_\r\n' > "$MEME/_pendientes.md"
python3 "$BIN/normalize-pendientes.py" --memory-dir "$MEME" --apply --quiet >/dev/null 2>&1
CR_TRAS_NORM="$(tr -dc '\r' < "$MEME/_pendientes.md" | wc -c | tr -d ' ')"
python3 "$BIN/journal-emit.py" --memory-dir "$MEME" --type pendiente.window --id p-8888888888 --revisar 2026-12-01 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEME" --quiet >/dev/null 2>&1
CR_TRAS_COMPACT="$(tr -dc '\r' < "$MEME/_pendientes.md" | wc -c | tr -d ' ')"
chk "normalize- conservo el CRLF"             "1" "$([ "$CR_TRAS_NORM" -gt 0 ] && echo 1 || echo 0)"
chk "compact- no le dio la vuelta despues"    "$CR_TRAS_NORM" "$CR_TRAS_COMPACT"

echo "RESULT pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
