#!/bin/bash
# Round-trip de caducidad: expire -> reopen debe devolver _pendientes.md y la fila
# mensual BYTE A BYTE como estaban. Si esto no pasa, --apply no debe usarse nunca.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MEM="$T/memory"; mkdir -p "$MEM/pendientes"
pass=0; fail=0; skip=0
chk(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FAIL $1"; echo "    esperado: $2"; echo "    obtenido: $3"; fi; }

# Portabilidad BSD/GNU. El CI del 2026-09-12 corrio esta suite en Linux por primera vez y encontro
# las dos cosas de golpe:
#   - `sed -i ''` es BSD. En GNU, `-i` no lleva el sufijo como argumento suelto, asi que el '' se
#     toma como el SCRIPT y la expresion como el NOMBRE DE FICHERO: la edicion no ocurria y el caso
#     de la valvula `_revisar` fallaba.
#   - `md5 -q` es BSD. En Linux no existe, asi que los cuatro asertos "byte a byte" comparaban
#     cadena vacia contra cadena vacia y pasaban SIN COMPROBAR NADA. Un falso verde es peor que un
#     fallo: el fallo se ve.
huella(){ if command -v md5 >/dev/null 2>&1; then md5 -q "$1"
          elif command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d" " -f1
          else echo "SIN-DIGEST-$1"; fi; }
edita(){ local f="$1"; shift; sed "$@" "$f" > "$f.__tmp" && mv "$f.__tmp" "$f"; }

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
chk "dry-run deja el indice intacto" "$(huella "$T/antes-index.md")" "$(huella "$MEM/_pendientes.md")"

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
chk "indice byte a byte"   "$(huella "$T/antes-index.md")"   "$(huella "$MEM/_pendientes.md")"
chk "mensual byte a byte"  "$(huella "$T/antes-mensual.md")" "$(huella "$MEM/pendientes/2026-01.md")"
chk "_caducados vacio"     "0" "$(grep -c "p-2222222222" "$MEM/pendientes/_caducados.md" 2>/dev/null || true)"

echo "== idempotencia =="
python3 "$BIN/expire-pendientes.py" --memory-dir "$MEM" --revertir p-2222222222 --apply >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null 2>&1
chk "reopen dos veces no duplica" "1" "$(grep -c 'p-2222222222' "$MEM/_pendientes.md")"

echo "== valvula _revisar futuro =="
edita "$MEM/_pendientes.md" -e 's|_creado: 2026-01-02_|_creado: 2026-01-02_ — _revisar: 2027-01-01_|'
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
chk "vuelven a su seccion con su prioridad" "$(huella "$T/antes2.md")" "$(huella "$MEM2/_pendientes.md")"

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
# En Git Bash/Windows `chmod` no toca las ACL de NTFS, asi que el directorio SIGUE siendo
# escribible y la precondicion de este caso no se puede construir. Se comprueba en vez de
# suponerlo —y en vez de dar por fallado un caso que no se ha llegado a montar—: si la sonda
# entra, se salta y se informa. Un salto contado es honesto; un fallo por precondicion ausente
# dice que el codigo esta mal cuando lo que falta es el escenario. (Medido en CI, 2026-09-12.)
if : > "$MEM8/pendientes/.sonda-escritura" 2>/dev/null; then
  rm -f "$MEM8/pendientes/.sonda-escritura"
  chmod u+w "$MEM8/pendientes"
  skip=$((skip+1)); echo "  SKIP con el destino inescribible, la linea NO se pierde (chmod no lo hace inescribible aqui)"
else
  python3 "$BIN/journal-compact.py" --memory-dir "$MEM8" --quiet >/dev/null 2>&1
  chmod u+w "$MEM8/pendientes"
  chk "con el destino inescribible, la linea NO se pierde" "1" "$(grep -c 'p-8888888888' "$MEM8/_pendientes.md")"
fi
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


echo "== ronda 5: ninguna ruta de escritura del plugin convierte el salto de linea =="
# La ronda 4 reviso los llamantes de UNA implementacion de atomic_write y declaro el contrato
# cumplido. Habia SEIS rutas de escritura en bin/, y tres seguian en modo texto. Esta prueba no
# revisa llamantes: enumera las escrituras del codigo y exige `newline=` en todas, para que una
# septima copia no pueda entrar en silencio.
# El patron cubre las CUATRO formas de abrir para escribir que usa este plugin: open(...,"w"),
# open(...,"a"), os.fdopen(...) y Path.write_text. La primera version solo miraba la primera y se
# le escapaban dos — el mismo defecto de "la prueba afirma menos que su nombre" que la ronda 5
# confirmo contra otra prueba de este mismo fichero.
# El enumerador mira TOKENS, no texto: un `grep` cuenta tambien los ejemplos escritos dentro de
# un docstring o un comentario, y eso convierte documentar una escritura en un fallo. Paso el
# 2026-09-12 con match-session-file.py, que documenta en su docstring los tres idiomas de
# escritura que sabe reconocer: dos falsos positivos, cero escrituras. Un instrumento que no
# distingue la evidencia de una cita sobre la evidencia esta roto, aunque su regla sea correcta.
enumerar_escrituras() {
  python3 - "$1" <<'ENUMPY'
import ast, os, sys

# Se mira el ARBOL SINTACTICO, no el texto. Un `grep` cuenta tambien los ejemplos escritos dentro
# de un docstring, asi que documentar una escritura se convertia en un fallo: paso el 2026-09-12
# con match-session-file.py, que documenta en su docstring los idiomas de escritura que reconoce
# — dos falsos positivos, cero escrituras. El primer intento de arreglo (saltar los tokens STRING)
# dejo la prueba CIEGA: el modo "w" es tambien un token STRING, asi que ya no encontraba ninguna
# escritura y pasaba en verde sin mirar nada. Una prueba que se pone verde por dejar de mirar es
# peor que la que fallaba. Con el arbol no hay ambiguedad: un docstring no produce una llamada.
MODOS_ESCRITURA = ("w", "a", "x", "+")


def clasificar(nodo):
    # Devuelve (es_escritura, exige_newline). Tres reglas, y las dos ultimas fallan CERRADO:
    #   - en binario `newline=` no existe, asi que exigirlo seria falso;
    #   - un modo que no es literal ("w" calculado en tiempo de ejecucion) NO se da por lectura:
    #     asumirlo dejaba colar una escritura de texto sin `newline=`, y el control solo cubria
    #     modos literales. Lo encontro un adversario externo el 2026-09-12;
    #   - `os.open` es otra cosa: devuelve un descriptor, no un fichero de texto, y no tiene
    #     `newline=`. Confundirlo con el `open` de siempre daba un falso positivo en journal-emit.
    f = nodo.func
    es_atributo = isinstance(f, ast.Attribute)
    nombre = f.attr if es_atributo else getattr(f, "id", "")
    modulo = getattr(f.value, "id", "") if es_atributo and isinstance(f.value, ast.Name) else ""

    if nombre == "write_bytes":
        return True, False
    if nombre == "open" and modulo == "os":
        return False, False          # os.open: descriptor, no fichero de texto
    if nombre in ("fdopen", "write_text", "open"):
        if nombre == "write_text":
            return True, True
        modo = None
        literal = False
        if len(nodo.args) > 1:
            if isinstance(nodo.args[1], ast.Constant):
                modo, literal = nodo.args[1].value, True
            else:
                return True, True    # modo dinamico: se exige, no se supone
        for kw in nodo.keywords:
            if kw.arg == "mode":
                if isinstance(kw.value, ast.Constant):
                    modo, literal = kw.value.value, True
                else:
                    return True, True
        if nombre == "fdopen":
            return True, not (isinstance(modo, str) and "b" in modo)
        if not literal or not isinstance(modo, str):
            return False, False      # open(p) a secas: lectura
        if not any(c in modo for c in MODOS_ESCRITURA):
            return False, False
        return True, "b" not in modo
    return False, False


bin_dir = sys.argv[1]
for nombre in sorted(os.listdir(bin_dir)):
    if not nombre.endswith(".py") or nombre.startswith("test-"):
        continue
    ruta = os.path.join(bin_dir, nombre)
    try:
        with open(ruta, "rb") as fh:
            fuente = fh.read().decode("utf-8", "replace")
        arbol = ast.parse(fuente)
    except (OSError, SyntaxError, ValueError) as e:
        # Un fichero que no se puede analizar NO se salta en silencio: se reporta como escritura
        # sin newline= para que la prueba se ponga roja. Saltarlo seria el mismo punto ciego.
        # Un fichero que no se puede analizar NO se salta en silencio: se marca FALTA para que
        # la prueba se ponga roja. Saltarlo seria el mismo punto ciego.
        print("%s:0:FALTA-NEWLINE NO-ANALIZABLE %s" % (ruta, e))
        continue
    lineas = fuente.splitlines()
    for nodo in ast.walk(arbol):
        if not isinstance(nodo, ast.Call):
            continue
        escritura, exige = clasificar(nodo)
        if not escritura:
            continue
        tiene = any(kw.arg == "newline" for kw in nodo.keywords)
        if exige and not tiene:
            veredicto = "FALTA-NEWLINE"
        elif exige:
            veredicto = "ok newline="
        else:
            veredicto = "ok binario"
        texto = lineas[nodo.lineno - 1].strip() if 0 < nodo.lineno <= len(lineas) else ''
        print("%s:%d:%s :: %s" % (ruta, nodo.lineno, veredicto, texto))
ENUMPY
}

ESCRITURAS=$(enumerar_escrituras "$BIN")
# Se cuenta el VEREDICTO del enumerador, no un recorte por nombre de funcion. Recortar aqui era
# el hueco: el enumerador emitia `fdopen` y el contador no lo miraba, asi que una escritura por
# `os.fdopen` sin `newline=` salia y se ignoraba. Lo encontro un adversario externo el 2026-09-12.
SIN_NEWLINE=$(printf '%s\n' "$ESCRITURAS" | grep -c 'FALTA-NEWLINE' || true)
chk "toda escritura (w/a/fdopen/write_text) declara newline=" "0" "$SIN_NEWLINE"
# CONTROL DEL PROPIO ENUMERADOR. La version anterior de esta comprobacion se puso verde por
# dejar de mirar: saltaba los tokens STRING y el modo "w" es un STRING, asi que no encontraba
# ninguna escritura en ningun sitio. Sin este control eso no se ve — un cero puede significar
# "todo limpio" o "no miro nada", y son indistinguibles desde fuera.
CTRL="$T/ctrl-newline"; mkdir -p "$CTRL"
# Las TRES formas que el contador tiene que ver. Recortar por nombre de funcion fue el hueco por
# el que `fdopen` pasaba sin mirarse, asi que el control las cubre una a una.
printf 'def f(p):\n    open(p, "w").write("x")\n' > "$CTRL/viola.py"
printf 'import os\ndef f(fd):\n    os.fdopen(fd, "w").write("x")\n' > "$CTRL/viola_fdopen.py"
printf 'from pathlib import Path\ndef f(p):\n    Path(p).write_text("x")\n' > "$CTRL/viola_wtext.py"
printf 'from pathlib import Path\ndef f(p):\n    Path(p).write_bytes(b"x")\n    open(p, "wb").write(b"y")\n' > "$CTRL/binaria.py"
printf 'def f(p):\n    """ejemplo citado: open(p,"w").write(s)"""\n    return open(p, "w", newline="")\n' > "$CTRL/cita.py"
printf 'def f(p, modo):\n    open(p, modo).write("x")\n' > "$CTRL/modo_dinamico.py"
printf 'import os\ndef f(p):\n    return os.open(p, os.O_WRONLY | os.O_CREAT, 0o644)\n' > "$CTRL/osopen.py"
printf 'def f(p):\n    return open(p).read()\n' > "$CTRL/solo_lee.py"
printf 'def f(:\n' > "$CTRL/rota.py"
CTRL_OUT=$(enumerar_escrituras "$CTRL")
falta() { printf '%s\n' "$CTRL_OUT" | grep 'FALTA-NEWLINE' | grep -c "$1"; }
chk "caza open(...,w) sin newline="        "1" "$(falta viola.py)"
chk "caza os.fdopen sin newline="          "1" "$(falta viola_fdopen.py)"
chk "caza Path.write_text sin newline="    "1" "$(falta viola_wtext.py)"
chk "un fichero no analizable sale ROJO"   "1" "$(falta rota.py)"
# Y lo que NO debe exigir: en binario `newline=` no existe, y una cita no es una escritura.
chk "NO exige newline= en escritura binaria"      "0" "$(falta binaria.py)"
chk "NO cuenta el ejemplo citado en un docstring" "0" "$(falta cita.py)"
# Un modo calculado no se da por lectura: si no se sabe, se exige. Y `os.open` no es un fichero
# de texto, asi que pedirle `newline=` seria un falso positivo (lo daba en journal-emit.py).
chk "caza open(p, modo) con el modo en variable" "1" "$(falta modo_dinamico.py)"
chk "NO exige newline= a os.open"                "0" "$(falta osopen.py)"
chk "NO marca un open() de solo lectura"         "0" "$(falta solo_lee.py)"
if [ "$SIN_NEWLINE" != "0" ]; then printf '%s\n' "$ESCRITURAS" | grep 'FALTA-NEWLINE' | sed 's/^/     /'; fi
# Y el comportamiento, no solo la forma: un fichero CRLF sobrevive a cada herramienta.
MEMG="$T/memg"; mkdir -p "$MEMG/sessions"
printf -- '---\ntype: session\n---\n# t\r\ncuerpo\r\n' > "$MEMG/sessions/s.md"
CR0=$(tr -dc '\r' < "$MEMG/sessions/s.md" | wc -c | tr -d ' ')
python3 "$BIN/ensure-frontmatter.py" "$MEMG" --apply >/dev/null 2>&1
python3 "$BIN/scan-secrets.py" "$MEMG" --apply >/dev/null 2>&1
python3 "$BIN/enrich-memory.py" "$MEMG" --apply >/dev/null 2>&1
CR1=$(tr -dc '\r' < "$MEMG/sessions/s.md" | wc -c | tr -d ' ')
chk "el fixture nace en CRLF"                      "1" "$([ "$CR0" -gt 0 ] && echo 1 || echo 0)"
chk "y sigue en CRLF tras las tres herramientas"   "1" "$([ "$CR1" -gt 0 ] && echo 1 || echo 0)"

echo "== los tres mensajes de lista vacia dicen cual de los tres casos es =="
# Una instalacion NUEVA tiene _pendientes.md vacio, y lo primero que veia era "No queda nada por
# revisar tras ese cursor" — sin haber dado ningun cursor. Y el primer arreglo confundia "no hay
# nada" con "el filtro no casa", porque contaba DESPUES de filtrar.
MEMH="$T/memh"; mkdir -p "$MEMH/pendientes"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n' > "$MEMH/_pendientes.md"
chk "memoria vacia -> lo dice sin hablar de cursores" "1" "$(python3 "$BIN/triage-scan.py" --memory-dir "$MEMH" | grep -c 'No hay pendientes abiertos')"
printf -- '- [ ] uno alta — _creado: 2026-01-01_ — _id: p-1111111111_\n' >> "$MEMH/_pendientes.md"
chk "filtro sin resultados -> dice cuantos hay y de que prioridad" "1" "$(python3 "$BIN/triage-scan.py" --memory-dir "$MEMH" --prioridad Baja | grep -c 'Ninguno de los 1 pendientes abiertos es de prioridad Baja')"
# El cursor del ULTIMO item: tras el no queda nada, que es el caso de "cursor agotado". Se
# construye con dig() en vez de parsear la salida — el script solo imprime "Siguiente lote"
# cuando QUEDA algo, asi que del ultimo lote no se puede copiar ninguno.
printf -- '- [ ] dos alta — _creado: 2026-01-02_ — _id: p-2222222222_\n' >> "$MEMH/_pendientes.md"
CUR_FIN="2026-01-02:p-2222222222:$(dig p-2222222222)"
chk "cursor agotado -> ESE si habla del cursor" "1" "$(python3 "$BIN/triage-scan.py" --memory-dir "$MEMH" --desde "$CUR_FIN" 2>/dev/null | grep -c 'tras ese cursor')"

echo "== el emisor avisa si --origen apunta a un session file que no existe =="
# Lo encontro OTRO agente leyendo el indice, no una prueba: se emitieron 5 pendientes con dos
# slugs inventados distintos y los enlaces de Tier 2 quedaron colgando. El orden de la plantilla
# (Step 2 escribe la sesion, Step 3 emite) hace que en el flujo normal esto no dispare nunca.
# Avisa y NO bloquea: un exit aqui perderia el evento, y emitir antes de escribir es legitimo si
# el checkpoint llega despues.
MEMI="$T/memi"; mkdir -p "$MEMI/sessions" "$MEMI/pendientes"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMI/_pendientes.md"
AV=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEMI" --type pendiente.add --text "colgante" \
      --prioridad Media --origen "[[sessions/2026-01-01-no-existe]]" --creado 2026-01-01 2>&1 >/dev/null)
chk "origen inventado -> avisa"           "1" "$(printf '%s' "$AV" | grep -c 'no existe todavia')"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMI" --type pendiente.add --text "colgante2" \
      --prioridad Media --origen "[[sessions/2026-01-01-no-existe]]" --creado 2026-01-02 >/dev/null 2>&1
chk "y NO bloquea: el evento se emite" "0" "$?"
printf -- '---\ntype: session\n---\n# x\n' > "$MEMI/sessions/2026-01-01-si-existe.md"
AV2=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEMI" --type pendiente.add --text "buena" \
      --prioridad Media --origen "[[sessions/2026-01-01-si-existe]]" --creado 2026-01-01 2>&1 >/dev/null)
chk "origen que existe -> callado"        "0" "$(printf '%s' "$AV2" | grep -c 'no existe todavia')"
AV3=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEMI" --type pendiente.add --text "alias" \
      --prioridad Media --origen "[[sessions/2026-01-01-si-existe|Un titulo]]" --creado 2026-01-01 2>&1 >/dev/null)
chk "alias [[sessions/x|Titulo]] -> callado" "0" "$(printf '%s' "$AV3" | grep -c 'no existe todavia')"
# Los tres enlaces rotos mas viejos del repo son de PLANES, no de pendientes: el aviso tiene que
# cubrir tambien plan.upsert (donde el campo se llama --sesion) y research.upsert.
AV4=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEMI" --type plan.upsert --slug pp --title T \
      --status active --sesion "[[sessions/2026-01-01-no-existe]]" 2>&1 >/dev/null)
chk "plan.upsert --sesion colgante -> avisa"     "1" "$(printf '%s' "$AV4" | grep -c 'no existe todavia')"
AV5=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEMI" --type research.upsert --slug rr --tema T \
      --status active --origen "[[sessions/2026-01-01-no-existe]]" 2>&1 >/dev/null)
chk "research.upsert --origen colgante -> avisa" "1" "$(printf '%s' "$AV5" | grep -c 'no existe todavia')"
AV6=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEMI" --type plan.upsert --slug pq --title T \
      --status active --sesion "[[sessions/2026-01-01-si-existe]]" 2>&1 >/dev/null)
chk "plan.upsert con sesion real -> callado"     "0" "$(printf '%s' "$AV6" | grep -c 'no existe todavia')"

echo "== deteccion por huella: un indice escrito fuera del journal se delata =="
# journal_strict es PreToolUse sobre Edit|Write|MultiEdit y Bash NO esta en su matcher, asi que
# un `>>` escribe igual. Medido 2026-09-11: 96 escrituras a mano desde que el journal es
# obligatorio. Esto no lo impide —parsear Bash es adivinar— sino que compara BYTES.
MEMJ="$T/memj"; mkdir -p "$MEMJ/pendientes" "$MEMJ/sessions"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMJ/_pendientes.md"
printf -- '---\ntype: session\n---\n# s\n' > "$MEMJ/sessions/2026-01-01-x.md"
D1=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMJ" --check-drift 2>&1)
chk "primera pasada: sella en silencio"      "0" "$(printf '%s' "$D1" | grep -c 'FUERA DEL JOURNAL')"
chk "y deja el fichero de huellas"           "1" "$([ -f "$MEMJ/.journal/fingerprints.json" ] && echo 1 || echo 0)"
D2=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMJ" --check-drift 2>&1)
chk "sin cambios: callado"                   "0" "$(printf '%s' "$D2" | grep -c 'FUERA DEL JOURNAL')"
# el camino LEGITIMO no debe avisar: es lo que decide si esto sirve o es ruido
python3 "$BIN/journal-emit.py" --memory-dir "$MEMJ" --type pendiente.add --text "por el journal" \
  --prioridad Media --origen "[[sessions/2026-01-01-x]]" --creado 2026-01-01 >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMJ" --quiet >/dev/null 2>&1
D3=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMJ" --check-drift 2>&1)
chk "emit+compact (legitimo): NO avisa"      "0" "$(printf '%s' "$D3" | grep -c 'FUERA DEL JOURNAL')"
# y ahora el bypass de verdad
printf -- '- [ ] escrito a mano saltandose el journal\n' >> "$MEMJ/_pendientes.md"
D4=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMJ" --check-drift 2>&1)
chk "escritura por Bash: SI avisa"           "1" "$(printf '%s' "$D4" | grep -c 'FUERA DEL JOURNAL')"
chk "y nombra el fichero"                    "1" "$(printf '%s' "$D4" | grep -c '_pendientes.md')"
chk "y queda constancia con fecha"           "1" "$(grep -c '_pendientes.md' "$MEMJ/.journal/out-of-band.log")"
D5=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMJ" --check-drift 2>&1)
chk "el aviso no se repite (re-sellado)"     "0" "$(printf '%s' "$D5" | grep -c 'FUERA DEL JOURNAL')"
# el mensual tambien esta vigilado, no solo los _*.md de la raiz
chk "vigila tambien pendientes/YYYY-MM.md"   "1" "$(grep -c 'pendientes/2026-01.md' "$MEMJ/.journal/fingerprints.json")"
printf -- '\n' >> "$MEMJ/pendientes/2026-01.md"
D6=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMJ" --check-drift 2>&1)
chk "y delata un cambio en el mensual"       "1" "$(printf '%s' "$D6" | grep -c 'pendientes/2026-01.md')"

echo "== las herramientas LEGITIMAS del plugin no disparan el aviso de deriva =="
# El aviso solo vale si no grita en falso. repair-dualwrite.py lo corre /checkpoint-3t en su
# Step 3-pre y normalize-pendientes.py anade cabeceras que faltan: las dos escriben indices de
# forma sancionada. Sin re-sellar, cada checkpoint denunciaria su propia reparacion.
MEMK="$T/memk"; mkdir -p "$MEMK/pendientes" "$MEMK/sessions"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMK/_pendientes.md"
printf -- '---\ntype: session\n---\n# s\n' > "$MEMK/sessions/2026-01-01-x.md"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMK" --type pendiente.add --text "uno" --prioridad Media \
  --origen "[[sessions/2026-01-01-x]]" --creado 2026-01-01 >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMK" --quiet >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMK" --check-drift >/dev/null 2>&1
# se borra la fila de Tier 3 para darle a repair-dualwrite algo legitimo que reconstruir
grep -v '^| 1 |' "$MEMK/pendientes/2026-01.md" > "$MEMK/p.tmp" && mv "$MEMK/p.tmp" "$MEMK/pendientes/2026-01.md"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMK" --check-drift >/dev/null 2>&1   # re-sella el borrado
python3 "$BIN/repair-dualwrite.py" "$MEMK" --apply >/dev/null 2>&1
D=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMK" --check-drift 2>&1)
chk "repair-dualwrite --apply NO dispara el aviso" "0" "$(printf '%s' "$D" | grep -c 'FUERA DEL JOURNAL')"
# normalize-pendientes: se le quita una cabecera para que tenga algo que anadir
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n- [ ] x — _origen: [[sessions/2026-01-01-x]]_ — _creado: 2026-01-01_ — _id: p-5555555555_\n' > "$MEMK/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMK" --check-drift >/dev/null 2>&1   # re-sella
python3 "$BIN/normalize-pendientes.py" "$MEMK" --apply >/dev/null 2>&1
D2=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMK" --check-drift 2>&1)
chk "normalize-pendientes --apply NO dispara"      "0" "$(printf '%s' "$D2" | grep -c 'FUERA DEL JOURNAL')"
# y el control negativo: una escritura de verdad a mano SI dispara, en el mismo directorio
printf -- '- [ ] a mano\n' >> "$MEMK/_pendientes.md"
D3=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMK" --check-drift 2>&1)
chk "control negativo: la escritura a mano SI dispara" "1" "$(printf '%s' "$D3" | grep -c 'FUERA DEL JOURNAL')"

echo "== .journal/.gitignore: git tiene que ignorar la linea base y VERSIONAR los eventos =="
# El fichero de huellas es estado POR COPIA DE TRABAJO: la deteccion compara contra lo que sello
# el compactador de ESTA maquina. Versionarlo da conflicto en cada checkpoint desde dos maquinas.
# Los eventos son lo contrario: son lo que hace que la memoria viaje. Que el fichero EXISTA no
# prueba nada (regla del repo: un aserto que mira el nombre no mira el comportamiento), asi que
# esto le pregunta a git de verdad con `check-ignore`.
MEMG="$T/gitrepo/memory"; mkdir -p "$MEMG/sessions"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMG/_pendientes.md"
printf -- '---\ntype: session\n---\n# s\n' > "$MEMG/sessions/2026-01-01-x.md"
# --check-drift NO debe escribirlo: su contrato dice "no escribe nada salvo el log de constancia"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMG" --check-drift >/dev/null 2>&1
chk "--check-drift NO escribe el .gitignore"  "0" "$([ -f "$MEMG/.journal/.gitignore" ] && echo 1 || echo 0)"
# compact() si, y una instalacion VIEJA ya tiene .journal/ creado: por eso no cuelga del makedirs
python3 "$BIN/journal-emit.py" --memory-dir "$MEMG" --type pendiente.add --text "uno" \
  --prioridad Media --origen "[[sessions/2026-01-01-x]]" --creado 2026-01-01 >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMG" --quiet >/dev/null 2>&1
chk "compact lo escribe aunque .journal/ ya existiera" "1" "$([ -f "$MEMG/.journal/.gitignore" ] && echo 1 || echo 0)"

if command -v git >/dev/null 2>&1; then
  ( cd "$T/gitrepo" && git init -q . >/dev/null 2>&1 )
  gi(){ ( cd "$T/gitrepo" && git check-ignore -q "$1" >/dev/null 2>&1 && echo 1 || echo 0 ); }
  chk "git IGNORA fingerprints.json"          "1" "$(gi memory/.journal/fingerprints.json)"
  chk "git IGNORA out-of-band.log"            "1" "$(gi memory/.journal/out-of-band.log)"
  chk "git IGNORA el lock"                    "1" "$(gi memory/.journal/.lock/owner)"
  # applied/ NO viaja desde 2.23.0: su efecto ya es la fila del indice, y el directorio crece
  # ~600 ficheros al mes sin poda (medido: 628 de 1230 ficheros de un repo real).
  APL=$(ls "$MEMG/.journal/applied"/*/*.json 2>/dev/null | head -1)
  chk "hay un evento en applied/ que probar"  "1" "$([ -n "$APL" ] && echo 1 || echo 0)"
  chk "git IGNORA applied/ (ya aplicado)"     "1" "$(gi "${APL#"$T/gitrepo/"}")"
  # control positivo: lo que SI tiene que viajar, porque hace falta APLICARLO en la otra copia
  chk "git NO ignora pending/ (viaja)"        "0" "$(gi memory/.journal/pending/x.json)"
  chk "git NO ignora quarantine/ (viaja)"     "0" "$(gi memory/.journal/quarantine/x.json)"
else
  skip=$((skip+7)); echo "  skip sin git: 7 asertos de check-ignore"
fi

echo "== el .gitignore que escribimos NOSOTROS se actualiza; el que toco el usuario, no =="
# Por que hace falta: escribir_gitignore_journal es write-if-absent, asi que hasta 2.23.0 una
# linea nueva del bloque no llegaba NUNCA a quien ya tenia el fichero — o sea, a toda instalacion
# de 2.21.0 en adelante, justo las que tienen el problema. El fixture de abajo es el cuerpo
# LITERAL de GITIGNORE_JOURNAL en 2.21.0 (commit d71e45e), sha256 9bfbd258...: extraido del
# historial, no tecleado. Que la migracion lo reconozca es lo unico que prueba que llega a una
# instalacion real, y no solo a un repo recien creado.
mig_fixture() { cat <<'GI_2210'
# Lo escribe journal-compact.py cuando falta. Puedes editarlo: no se sobreescribe.
#
# QUE NO SE VERSIONA — estado por copia de trabajo. La deteccion de escrituras fuera del
# journal compara contra lo que sello EL COMPACTADOR DE ESTA MAQUINA, asi que la linea base
# no significa nada en otra. Versionarla ademas da un conflicto de merge garantizado: cambia
# en cada compactacion, y dos maquinas tocan las mismas claves del JSON.
fingerprints.json
# Append de dos maquinas = conflicto que git no sabe fusionar. Y lo que se anoto aqui es lo
# que se toco a mano EN ESTA copia.
out-of-band.log
# Estado vivo de un proceso. Nunca tiene sentido fuera de la maquina que lo tomo.
.lock/
.lock-steal/

# QUE SI SE VERSIONA, a proposito: pending/, applied/ y quarantine/.
# Son el registro de eventos, y es lo que hace que la memoria viaje entre maquinas.
#   - pending/: un evento emitido y aun sin aplicar llega a la otra maquina y se aplica alli,
#     en vez de perderse. Re-aplicar es no-op (el compactador es idempotente), asi que no
#     duplica nada si ambas lo aplican.
#   - applied/ y quarantine/: rastro auditable. Un fichero por evento, nombre unico, sin
#     conflictos posibles.
GI_2210
}
# 1) el bloque de 2.21.0 SE ACTUALIZA, y despues git si ignora applied/
MEMM="$T/mig"; mkdir -p "$MEMM/.journal" "$MEMM/sessions"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMM/_pendientes.md"
printf -- '---\ntype: session\n---\n# s\n' > "$MEMM/sessions/2026-01-01-x.md"
mig_fixture > "$MEMM/.journal/.gitignore"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMM" --type pendiente.add --text "uno" \
  --prioridad Media --origen "[[sessions/2026-01-01-x]]" --creado 2026-01-01 >/dev/null 2>&1
MOUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMM" 2>&1)
chk "migra el bloque de 2.21.0"               "1" "$(grep -c '^applied/$' "$MEMM/.journal/.gitignore")"
chk "y lo dice por pantalla"                  "1" "$(printf '%s' "$MOUT" | grep -c 'gitignore actualizado')"
chk "avisa del git rm --cached"               "1" "$(printf '%s' "$MOUT" | grep -c 'rm -r --cached')"
# 2) NO lo repite en la pasada siguiente: el bloque de hoy no esta en la lista de superados
python3 "$BIN/journal-emit.py" --memory-dir "$MEMM" --type pendiente.add --text "dos" \
  --prioridad Media --origen "[[sessions/2026-01-01-x]]" --creado 2026-01-01 >/dev/null 2>&1
M2=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMM" 2>&1)
chk "no re-migra en la pasada siguiente"      "0" "$(printf '%s' "$M2" | grep -c 'gitignore actualizado')"
# 3) CRLF: este fichero esta TRACKEADO, asi que en Windows con core.autocrlf vuelve del checkout
#    con CRLF. Sin normalizar, el compactador no reconoceria su propio bloque y la migracion no
#    llegaria jamas a la plataforma donde menos se mira. Control de la normalizacion, no cosmetico.
MEMC="$T/migcrlf"; mkdir -p "$MEMC/.journal" "$MEMC/sessions"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMC/_pendientes.md"
printf -- '---\ntype: session\n---\n# s\n' > "$MEMC/sessions/2026-01-01-x.md"
mig_fixture | python3 -c 'import sys,io; io.open(sys.argv[1],"wb").write(sys.stdin.buffer.read().replace(b"\n", b"\r\n"))' "$MEMC/.journal/.gitignore"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMC" --type pendiente.add --text "uno" \
  --prioridad Media --origen "[[sessions/2026-01-01-x]]" --creado 2026-01-01 >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMC" --quiet >/dev/null 2>&1
chk "migra tambien el mismo bloque en CRLF"   "1" "$(grep -c '^applied/$' "$MEMC/.journal/.gitignore")"
# 4) CONTROL NEGATIVO: un byte distinto y ya es del usuario. Un aserto que solo mira los casos
#    que migran no distingue "migra lo nuestro" de "pisa lo que encuentre".
MEMU="$T/migusr"; mkdir -p "$MEMU/.journal" "$MEMU/sessions"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMU/_pendientes.md"
printf -- '---\ntype: session\n---\n# s\n' > "$MEMU/sessions/2026-01-01-x.md"
{ mig_fixture; printf 'mi-linea-propia\n'; } > "$MEMU/.journal/.gitignore"
cp "$MEMU/.journal/.gitignore" "$T/migusr-antes"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMU" --type pendiente.add --text "uno" \
  --prioridad Media --origen "[[sessions/2026-01-01-x]]" --creado 2026-01-01 >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMU" --quiet >/dev/null 2>&1
chk "NO toca el del usuario (un byte basta)"  "0" "$(cmp -s "$T/migusr-antes" "$MEMU/.journal/.gitignore" && echo 0 || echo 1)"
chk "y por tanto no le mete applied/"         "0" "$(grep -c '^applied/$' "$MEMU/.journal/.gitignore")"

# No se pisa lo que el usuario haya puesto
printf 'mio\n' > "$MEMG/.journal/.gitignore"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMG" --quiet >/dev/null 2>&1
chk "no sobreescribe un .gitignore propio"    "mio" "$(cat "$MEMG/.journal/.gitignore")"

echo "== tras un git pull el aviso de deriva explica que hacer, en vez de acusar =="
# El coste de NO versionar la linea base: los indices que llegan por git no son los que sello
# esta maquina, asi que el detector los ve como deriva. Es correcto pero suena a acusacion.
printf -- '- [ ] llego por git\n' >> "$MEMG/_pendientes.md"
DG=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMG" --check-drift 2>&1)
chk "el aviso nombra git pull"                "1" "$(printf '%s' "$DG" | grep -c 'git pull')"
# Primer arranque para ESTABILIZAR, sin aserto: session-start corre normalize-pendientes antes
# del detector, y normalize re-sella. Si el fixture necesita normalizar, se lleva por delante la
# deriva que queremos medir y el aserto de abajo mide el arnes, no el producto.
CLAUDE_PLUGIN_ROOT="$(cd "$BIN/.." && pwd)" CLAUDE_PROJECT_DIR="$T/gitrepo" \
  bash "$BIN/session-start.sh" >/dev/null 2>&1 <<J
{"hook_event_name":"SessionStart","source":"startup","cwd":"$T/gitrepo"}
J
# El aviso de deriva salia SOLO por additionalContext hasta 2.21.0: lo veia el agente y nunca una
# persona, el mismo fallo que 2.17.0 arreglo para los pendientes. Y aqui pesa mas, porque quien
# hizo el `git pull` y quien tiene que correr --reseal es la persona.
python3 "$BIN/journal-compact.py" --memory-dir "$MEMG" --reseal >/dev/null 2>&1
printf -- '- [ ] otra que llego por git\n' >> "$MEMG/_pendientes.md"
HUM=$(CLAUDE_PLUGIN_ROOT="$(cd "$BIN/.." && pwd)" CLAUDE_PROJECT_DIR="$T/gitrepo" \
  bash "$BIN/session-start.sh" <<J 2>/dev/null
{"hook_event_name":"SessionStart","source":"startup","cwd":"$T/gitrepo"}
J
)
chk "el texto a la persona nombra git pull"   "1" "$(printf '%s' "$HUM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if "git pull" in d.get("systemMessage","") else 0)' 2>/dev/null || echo 0)"
chk "y le dice que corra --reseal"            "1" "$(printf '%s' "$HUM" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if "--reseal" in d.get("systemMessage","") else 0)' 2>/dev/null || echo 0)"
chk "el JSON sigue siendo valido con el texto largo" "1" "$(printf '%s' "$HUM" | python3 -c 'import json,sys; json.load(sys.stdin); print(1)' 2>/dev/null || echo 0)"

echo "== el .gitignore se publica exclusivo Y entero, con concurrencia DE VERDAD =="
# La version anterior de esta prueba lanzaba 6 compactadores. No probaba nada: la escritura esta
# DENTRO del lock del journal, asi que los seis SERIALIZAN y nunca compiten. Un aserto que no
# puede fallar por la razon que dice medir es no-evidencia, y lo marco el adversario. Aqui se
# llama a la funcion DIRECTAMENTE desde 12 procesos a la vez, sin lock, que es la unica forma de
# que compitan de verdad.
MEMR="$T/race"; mkdir -p "$MEMR/.journal"
# 12 procesos INDEPENDIENTES, no un Pool: multiprocessing usa `spawn` en macOS y reimporta
# __main__, que aqui es stdin — se colgaba. Cada uno llama a la funcion y escribe su veredicto en
# un fichero; se cuentan despues.
mkdir -p "$T/race_votos"
llama='import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("jc", os.path.join(sys.argv[1], "journal-compact.py"))
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
print(1 if jc.escribir_gitignore_journal(sys.argv[2]) else 0)'
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  python3 -c "$llama" "$BIN" "$MEMR/.journal" > "$T/race_votos/$i" 2>/dev/null &
done
wait
GANADORES=$(cat "$T/race_votos"/* 2>/dev/null | grep -c '^1$')
ENTERO=$(python3 -c '
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("jc", os.path.join(sys.argv[1], "journal-compact.py"))
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
print(1 if open(os.path.join(sys.argv[2], ".gitignore"), encoding="utf-8").read() == jc.GITIGNORE_JOURNAL else 0)
' "$BIN" "$MEMR/.journal" 2>/dev/null)
SOBRAS=$(ls -1 "$MEMR/.journal"/.gitignore.*.tmp 2>/dev/null | wc -l | tr -d ' ')
chk "12 a la vez: gana EXACTAMENTE uno"        "1" "$GANADORES"
chk "el publicado es el fichero ENTERO"        "1" "$ENTERO"
chk "y no queda ningun temporal"               "0" "$SOBRAS"
# Un fichero a medias es lo que la ronda 2 encontro: O_EXCL sobre el destino publica ANTES de
# escribir, y si la escritura muere, el truncado se queda para siempre porque el siguiente ve que
# existe. Esta prueba fija la propiedad en la direccion contraria: existe => esta completo.
printf 'mio del usuario\n' > "$MEMR/.journal/.gitignore"
python3 -c "
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('jc', os.path.join('$BIN', 'journal-compact.py'))
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
jc.escribir_gitignore_journal('$MEMR/.journal')" 2>/dev/null
chk "no pisa el del usuario"                   "mio del usuario" "$(cat "$MEMR/.journal/.gitignore")"

echo "== una deriva vista sin nadie delante NO SE CONSUME: reaparece cuando hay quien la lea =="
# --check-drift RE-SELLA al detectar, para que el aviso salga una vez. Correcto cuando el aviso
# llega. En un `clear`/`compact` —o con un agente de Paperclip, o una corrida no atendida— el
# mensaje a la persona se descarta, asi que el re-sellado lo borraba PARA SIEMPRE: visto una vez,
# a nadie, y no vuelve.
#
# La solucion NO es guardar el aviso en un fichero (2.21.2 lo intento; costo tres rondas y cada
# capa traia un defecto). Es no MIRAR si no hay quien lea: la deriva ya es persistente —un hash
# que no coincide— y sigue ahi hasta que alguien re-selle.
#
# Todo lo de aqui pasa por session-start.sh de verdad. Un aserto que reimplementa en el test lo
# que dice medir no mide el producto: ya me lo encontro un adversario, dos veces.
MEMH="$T/defer"; mkdir -p "$MEMH/sessions"
cat > "$MEMH/_pendientes.md" <<'EOF'
---
type: index
---
# Pendientes

## Alta prioridad

## Media prioridad

## Baja prioridad
EOF
printf -- '---\ntype: session\n---\n# s\n' > "$MEMH/sessions/2026-01-01-x.md"
PR="$(cd "$BIN/.." && pwd)"
mkdir -p "$T/defer_proj"; cp -R "$MEMH" "$T/defer_proj/memory"
MEMD="$T/defer_proj/memory"
arranque(){ CLAUDE_PLUGIN_ROOT="$PR" CLAUDE_PROJECT_DIR="$T/defer_proj" \
  PAPERCLIP_RUN_ID="${2:-}" bash "$BIN/session-start.sh" 2>/dev/null <<J
{"hook_event_name":"SessionStart","source":"$1","cwd":"$T/defer_proj"}
J
}
dice(){ printf '%s' "$1" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(1 if "git pull" in d.get("systemMessage","") else 0)' 2>/dev/null || echo 0; }
# huella del sellado: si --check-drift corrio, la linea base cambia de bytes
sello(){ huella "$MEMD/.journal/fingerprints.json"; }

arranque startup >/dev/null 2>&1          # estabiliza (normalize re-sella en el primer arranque)
printf -- '- [ ] llego por git\n' >> "$MEMD/_pendientes.md"
H0=$(sello)
C1=$(arranque compact)
chk "en compact NO se le dice a nadie"         "0" "$(dice "$C1")"
chk "y la linea base NO se toca (no se consume)" "$H0" "$(sello)"
# lo mismo con un agente de Paperclip, que es la otra forma de no tener persona delante
C2=$(arranque startup "run-123")
chk "con agente de Paperclip tampoco"          "0" "$(dice "$C2")"
chk "y la linea base sigue intacta"            "$H0" "$(sello)"
# y ahora SI hay alguien
S1=$(arranque startup)
chk "el arranque con persona SI lo entrega"    "1" "$(dice "$S1")"
chk "y ahi si se re-sella"                     "1" "$([ "$(sello)" != "$H0" ] && echo 1 || echo 0)"
S2=$(arranque startup)
chk "y ya no se repite"                        "0" "$(dice "$S2")"
chk "no se crea ningun fichero de avisos"      "0" "$(ls -1 "$MEMD/.journal"/human-pending* 2>/dev/null | wc -l | tr -d ' ')"

# LOS DOS LLAMANTES, no solo uno. 2.21.4 puso la guarda en session-start.sh y el adversario la
# rompio en una frase: bash-journal-nudge.sh corre --check-drift en CADA PostToolUse de Bash y no
# sabia nada de quien mira. Por eso la guarda vive ahora en el compactador, y por eso esto lo
# comprueba por LOS DOS caminos.
printf -- '- [ ] otra deriva\n' >> "$MEMD/_pendientes.md"
H1=$(sello)
MEMORY_DIR="$MEMD" PAPERCLIP_RUN_ID=run-9 bash "$BIN/bash-journal-nudge.sh" >/dev/null 2>&1 <<'J'
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo x"}}
J
chk "el hook de Bash con Paperclip: no consume"  "$H1" "$(sello)"
MEMORY_DIR="$MEMD" CLAUDE_CODE_SESSION_ATTENDED=0 bash "$BIN/bash-journal-nudge.sh" >/dev/null 2>&1 <<'J'
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo x"}}
J
chk "el hook de Bash sin sesion atendida: tampoco" "$H1" "$(sello)"
# control positivo: con lector, ese mismo hook SI detecta y re-sella
NUD=$(MEMORY_DIR="$MEMD" bash "$BIN/bash-journal-nudge.sh" 2>&1 <<'J'
{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo x"}}
J
)
chk "con lector, el hook de Bash SI avisa"       "1" "$(printf '%s' "$NUD" | grep -c 'FUERA DEL JOURNAL')"
chk "y ahi si re-sella"                          "1" "$([ "$(sello)" != "$H1" ] && echo 1 || echo 0)"

echo "RESULT pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
