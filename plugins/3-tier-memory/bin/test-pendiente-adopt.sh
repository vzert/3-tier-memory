#!/bin/bash
# Prueba de 2.58.0: `pendiente.adopt` le pone su id a un pendiente que no lo tiene.
#
# Por que existe: update/resolve/expire/block/relate buscan `_id: p-…_` en la linea. Un pendiente
# escrito a mano, o anterior al journal, no lo lleva, y la unica forma de corregirlo o cerrarlo era
# editar `_pendientes.md` a mano y re-sellar las huellas (pasado dos veces en una instalacion real).
#
#  1. El id adoptado es el MISMO que pone enrich-memory --only creado,id (byte a byte la linea, en
#     los items sin sangria, que son los unicos que enrich toca),
#     y despues de adoptar, update y resolve funcionan sobre ese id, con su fila de Tier 3.
#  2. repair-dualwrite no lo cuenta como inventado y --fix-ids no lo renombra.
#  3. Replay idempotente; linea cambiada entre emision y compactado: aviso, ni cuarentena ni perdida.
#  4. Duplicados: se niegan sin --colapsar; con el queda una y la copia va entera al log.
#  5. Selectores: --text-prefix ambiguo se niega; --id sin-id-… (el de triage); `_id:` no canonico.
#  6. Un payload incoherente (id que no es el de su linea) va a cuarentena.
#
# Uso: test-pendiente-adopt.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
unset CLAUDE_CODE_SESSION_ID
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
linea() { grep -m1 "_id: $1_" "$M/_pendientes.md" || true; }
cuarentena() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }

fixture() {
  rm -rf "$1"; mkdir -p "$1/pendientes" "$1/sessions"
  printf -- '# vieja\n' > "$1/sessions/2026-09-01-vieja.md"
  cat > "$1/_pendientes.md" <<'EOF'
---
type: index
---
# Pendientes

## Alta prioridad

- [ ] arreglar foo legacy — _origen: [[sessions/2026-09-01-vieja]]_ — _creado: 2026-09-01_

## Media prioridad

- [ ] sin creado con origen — _origen: [[sessions/2026-09-01-vieja]]_
- [ ] a pelo sin nada
- [ ] slug imposible — _origen: [[sessions/2026-02-30-x]]_
- [ ] _origen: [[sessions/sin-fecha]]_ empieza por metadato
- [ ] texto repetido — _origen: [[sessions/2026-09-01-vieja]]_ — _creado: 2026-09-01_
- [ ] texto repetido — _origen: [[sessions/2026-09-02-otra]]_ — _creado: 2026-09-02_

## Baja prioridad

- [ ] gemelo exacto — _creado: 2026-09-02_
- [ ] gemelo exacto — _creado: 2026-09-02_
EOF
}

echo "== 1. adopt --todas da la misma linea que enrich-memory, salvo los gemelos =="
fixture "$M"; fixture "$T/enr"
# mtime viejo: el ultimo recurso de la fecha es el mtime de _pendientes.md, como en enrich. Con el
# fichero recien creado ese mtime es hoy y la prueba no distinguiria "mtime" de "hoy".
touch -t 202001150000 "$M/_pendientes.md" "$T/enr/_pendientes.md"
python3 "$BIN/enrich-memory.py" "$T/enr" --apply --only creado,id >/dev/null
ERR=$(emit --type pendiente.adopt --todas 2>&1 >"$T/ids")
chk "emite 7 ids (los gemelos se apartan)" "7" "$(wc -l < "$T/ids" | tr -d ' ')"
chk "avisa de los gemelos" "1" "$(printf '%s' "$ERR" | grep -c 'DUPLICADO (2 copias identicas): - \[ \] gemelo')"
compact --quiet >/dev/null
chk "sin cuarentena" "0" "$(cuarentena)"
chk "lineas identicas a las de enrich (sin gemelos)" "" \
  "$(diff <(grep '^- \[ \]' "$M/_pendientes.md" | grep -v gemelo) <(grep '^- \[ \]' "$T/enr/_pendientes.md" | grep -v gemelo))"
chk "los gemelos siguen sin id" "2" "$(grep -c '^- \[ \] gemelo exacto — _creado: 2026-09-02_$' "$M/_pendientes.md")"
chk "texto repetido con otro origen = dos ids distintos" "2" \
  "$(grep '^- \[ \] texto repetido' "$M/_pendientes.md" | grep -o '_id: p-[0-9a-f]*_' | sort -u | wc -l | tr -d ' ')"
chk "creado sacado del slug de _origen" "1" \
  "$(grep -c '^- \[ \] sin creado con origen — _origen: \[\[sessions/2026-09-01-vieja\]\]_ — _creado: 2026-09-01_ — _id: p-' "$M/_pendientes.md")"
chk "sin origen ni creado: creado = mtime de _pendientes.md" "1" "$(grep -c "^- \[ \] a pelo sin nada — _creado: 2020-01-15_ — _id: p-" "$M/_pendientes.md")"
chk "fecha imposible en el slug: no se escribe, va al mtime (enrich igual)" "1" "$(grep -c "^- \[ \] slug imposible — _origen: \[\[sessions/2026-02-30-x\]\]_ — _creado: 2020-01-15_ — _id: p-" "$M/_pendientes.md")"
ID1=$(grep '^- \[ \] arreglar foo' "$M/_pendientes.md" | grep -o 'p-[0-9a-f]\{10\}')
chk "fila de Tier 3 de cada adoptado" "7" "$(cat "$M"/pendientes/*.md | grep -c '_id: p-')"
chk "Tier 3 lleva la prioridad de su seccion" "1" "$(grep "_id: ${ID1}_" "$M/pendientes/2026-09.md" | grep -c '| Alta |')"

echo "== 2. repair-dualwrite: nada inventado, nada que renombrar =="
RD=$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1)
chk "ids_invented=0" "1" "$(printf '%s' "$RD" | grep -c 'ids_invented=0')"
chk "rows_added=0 (las filas ya estan)" "1" "$(printf '%s' "$RD" | grep -c 'rows_added=0')"
ANTES=$(cat "$M/_pendientes.md")
python3 "$BIN/repair-dualwrite.py" "$M" --apply --fix-ids >/dev/null 2>&1
chk "--fix-ids --apply no toca _pendientes.md" "$ANTES" "$(cat "$M/_pendientes.md")"

echo "== 3. despues de adoptar, update y resolve funcionan =="
emit --type pendiente.update --id "$ID1" --text "arreglar foo legacy (corregido)" >/dev/null
compact --quiet >/dev/null
chk "update cambia el texto y conserva el id" "1" "$(linea "$ID1" | grep -c '^- \[ \] arreglar foo legacy (corregido) — ')"
emit --type pendiente.resolve --id "$ID1" --estado resolved --nota "cerrado tras adoptar" >/dev/null
compact --quiet >/dev/null
chk "resolve lo saca de Tier 2" "0" "$(grep -c "_id: ${ID1}_" "$M/_pendientes.md")"
chk "resolve lo archiva en _resueltos.md" "1" "$(grep -c "_id: ${ID1}_" "$M/pendientes/_resueltos.md")"
chk "la fila de Tier 3 queda resuelta" "1" "$(grep "_id: ${ID1}_" "$M/pendientes/2026-09.md" | grep -c 'cerrado tras adoptar')"
chk "sin cuarentena" "0" "$(cuarentena)"

echo "== 4. adopt + update emitidos antes de un mismo compactado =="
fixture "$M"
IDA=$(emit --type pendiente.adopt --text-prefix "a pelo")
emit --type pendiente.update --id "$IDA" --prioridad Alta >/dev/null
compact --quiet >/dev/null
chk "el update encuentra la linea recien adoptada" "alta" \
  "$(python3 - "$M/_pendientes.md" "$IDA" <<'EOF'
import sys
sec = None
for l in open(sys.argv[1], encoding="utf-8"):
    if l.startswith("## "):
        sec = l.split()[1].lower()
    if f"_id: {sys.argv[2]}_" in l:
        print(sec)
EOF
)"

echo "== 5. replay idempotente =="
H1=$(cat "$M/_pendientes.md" "$M"/pendientes/*.md | shasum | cut -c1-40)
cp "$M"/.journal/applied/*/*.json "$M/.journal/pending/"
compact --quiet >/dev/null
chk "un replay no cambia nada" "$H1" "$(cat "$M/_pendientes.md" "$M"/pendientes/*.md | shasum | cut -c1-40)"
chk "sin cuarentena" "0" "$(cuarentena)"

echo "== 6. la linea cambio entre la emision y el compactado =="
fixture "$M"
IDB=$(emit --type pendiente.adopt --text-prefix "sin creado")
python3 - "$M/_pendientes.md" <<'EOF'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("sin creado con origen", "sin creado con origen EDITADO"))
EOF
O=$(compact 2>&1)
chk "no va a cuarentena" "0" "$(cuarentena)"
chk "avisa" "1" "$(printf '%s' "$O" | grep -c "WARN adopt: la linea de $IDB ya no esta tal cual")"
chk "la linea editada queda intacta y sin id" "1" "$(grep -c '^- \[ \] sin creado con origen EDITADO — _origen: \[\[sessions/2026-09-01-vieja\]\]_$' "$M/_pendientes.md")"
IDC=$(emit --type pendiente.adopt --text-prefix "a pelo")
printf '%s\n' "$(cat "$M/_pendientes.md")" | sed 's/^- \[ \] a pelo sin nada$/- [ ] a pelo sin nada /' > "$T/p.md" && cat "$T/p.md" > "$M/_pendientes.md"
O=$(compact 2>&1)
chk "un espacio de mas tambien es un cambio" "1" "$(printf '%s' "$O" | grep -c "WARN adopt: la linea de $IDC ya no esta tal cual")"
chk "y la linea sigue sin id" "1" "$(grep -c '^- \[ \] a pelo sin nada $' "$M/_pendientes.md")"

echo "== 7. duplicados =="
fixture "$M"
emit --type pendiente.adopt --text-prefix "gemelo" >/dev/null 2>"$T/err"; RC=$?
chk "sin --colapsar sale 1" "1" "$RC"
chk "y dice por que" "1" "$(grep -c 'no adopta duplicados' "$T/err")"
IDG=$(emit --type pendiente.adopt --text-prefix "gemelo" --colapsar)
compact --quiet >/dev/null
chk "queda una sola linea, con id" "1" "$(grep -c '^- \[ \] gemelo exacto' "$M/_pendientes.md")"
chk "con el id emitido" "1" "$(grep -c "^- \[ \] gemelo exacto — _creado: 2026-09-02_ — _id: ${IDG}_$" "$M/_pendientes.md")"
chk "la copia esta entera en el log" "1" "$(grep -c "${IDG}	- \[ \] gemelo exacto — _creado: 2026-09-02_$" "$M/.journal/adopt-colapsados.log")"

echo "== 7b. una linea sin id que repite un pendiente que ya tiene id =="
fixture "$M"
IDX=$(emit --type pendiente.add --text "ya con id" --prioridad Media --origen "[[sessions/2026-09-01-vieja]]" --creado 2026-09-01)
compact --quiet >/dev/null
printf -- '- [ ] ya con id — _origen: [[sessions/2026-09-01-vieja]]_ — _creado: 2026-09-01_\n' >> "$M/_pendientes.md"
emit --type pendiente.adopt --text-prefix "ya con id" >/dev/null 2>"$T/err"; RC=$?
chk "sin --colapsar sale 1" "1" "$RC"
chk "dice con que id vive" "1" "$(grep -c "ya vive como $IDX" "$T/err")"
emit --type pendiente.adopt --text-prefix "ya con id" --colapsar >/dev/null
compact --quiet >/dev/null
chk "queda solo la linea con id" "1" "$(grep -c '^- \[ \] ya con id' "$M/_pendientes.md")"
chk "y es la del id original" "1" "$(grep -c "_id: ${IDX}_" "$M/_pendientes.md")"

echo "== 8. selectores =="
fixture "$M"
emit --type pendiente.adopt --text-prefix "texto repetido" >/dev/null 2>"$T/err"; RC=$?
chk "un prefijo que casa con dos lineas distintas sale 1" "1" "$RC"
SID=$(python3 - "$BIN" "$M/_pendientes.md" <<'EOF'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("t", sys.argv[1] + "/triage-scan.py")
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
for l in open(sys.argv[2], encoding="utf-8"):
    if l.startswith("- [ ] texto repetido") and "2026-09-02" in l:
        print(t.sintetico(re.sub(r"\s+", " ", t.META.sub("", l.strip()[5:].strip()))))
EOF
)
IDS=$(emit --type pendiente.adopt --id "${SID}-2")
compact --quiet >/dev/null
chk "--id sin-id-…-2 adopta la segunda de texto igual" "1" "$(linea "$IDS" | grep -c 'sessions/2026-09-02-otra')"
emit --type pendiente.adopt --id "p-0123456789" >/dev/null 2>&1; RC=$?
chk "--id p-… sale 1 (ya esta adoptado)" "1" "$RC"
LIN=$(linea "$IDS")
chk "--line de una linea ya adoptada imprime su id" "$IDS" "$(emit --type pendiente.adopt --line "$LIN")"
printf -- '- [ ] id raro — _id: p-1234abcd_ — _creado: 2026-09-03_\n' >> "$M/_pendientes.md"
printf -- '- [ ] revisar la tabla — _id: de usuario_ debe ser unico — _creado: 2026-09-03_\n' >> "$M/_pendientes.md"
printf -- '- [ ] mal espaciado — _creado: 2026-09-03_ — _id:p-0123456789_\n' >> "$M/_pendientes.md"
cp -R "$M" "$T/enr2"
python3 "$BIN/enrich-memory.py" "$T/enr2" --apply --only id >/dev/null
IDR=$(emit --type pendiente.adopt --text-prefix "id raro")
IDP=$(emit --type pendiente.adopt --text-prefix "revisar la tabla")
IDM=$(emit --type pendiente.adopt --text-prefix "mal espaciado")
compact --quiet >/dev/null
chk "un _id: de 8 hex se queda y el canonico va al final" "1" "$(grep -c "^- \[ \] id raro — _id: p-1234abcd_ — _creado: 2026-09-03_ — _id: ${IDR}_$" "$M/_pendientes.md")"
chk "un _id: en prosa no borra texto" "1" "$(grep -c "^- \[ \] revisar la tabla — _id: de usuario_ debe ser unico — _creado: 2026-09-03_ — _id: ${IDP}_$" "$M/_pendientes.md")"
chk "esas dos lineas, igual que enrich" "" "$(diff <(grep '^- \[ \] \(id raro\|revisar la tabla\)' "$M/_pendientes.md") <(grep '^- \[ \] \(id raro\|revisar la tabla\)' "$T/enr2/_pendientes.md"))"
chk "_id:p-…_ mal espaciado conserva su id" "p-0123456789" "$IDM"
chk "y queda bien espaciado, una sola vez" "1" "$(grep -c '^- \[ \] mal espaciado — _creado: 2026-09-03_ — _id: p-0123456789_$' "$M/_pendientes.md")"

echo "== 8b. una fila mensual a mano que lleva el id y despues cita otro: no se duplica =="
fixture "$M"
IDF=$(emit --type pendiente.adopt --text-prefix "arreglar foo")
printf -- '# 2026-09\n\n| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |\n|---|---|---|---|---|---|---|\n| 1 | arreglar foo legacy _id: %s_ ver tambien _id: p-9999999999_ | Alta | 2026-09-01 | x | | |\n' "$IDF" > "$M/pendientes/2026-09.md"
O=$(compact 2>&1)
chk "no anade una segunda fila" "1" "$(grep -c "_id: ${IDF}_" "$M/pendientes/2026-09.md")"
chk "y avisa" "1" "$(printf '%s' "$O" | grep -c "WARN adopt: $IDF ya sale en una fila de 2026-09.md")"
chk "la linea de Tier 2 si queda adoptada" "1" "$(grep -c "_id: ${IDF}_" "$M/_pendientes.md")"

echo "== 9. payload incoherente: cuarentena =="
fixture "$M"
mkdir -p "$M/.journal/pending"
cat > "$M/.journal/pending/1-x-1-0.json" <<'EOF'
{"v": 1, "type": "pendiente.adopt", "ts": 1, "session_id": "x", "agent_id": "x",
 "payload": {"lineas": [{"line": "- [ ] a pelo sin nada", "id": "p-0000000000", "creado_nuevo": "2026-09-01"}], "colapsar": false, "fecha": "2026-10-14"}}
EOF
compact --quiet >/dev/null
chk "id que no es el de su linea: cuarentena" "1" "$(cuarentena)"
chk "y la linea queda sin tocar" "1" "$(grep -c '^- \[ \] a pelo sin nada$' "$M/_pendientes.md")"

echo
echo "pendiente-adopt: $pass ok, $fail fallas"
[ "$fail" -eq 0 ]
