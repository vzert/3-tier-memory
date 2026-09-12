#!/usr/bin/env bash
# Pruebas del lector de filas mensuales (2.18.0) y de los tres informes que lo acompanan.
#
# Que cierra, medido el 2026-09-11 sobre el corpus real de una instalacion (39 filas sin la
# columna `#`, cabeceras de 5 y 6 columnas):
#   D1. `table_rows`/`numbered_rows` filtraban por `^\|\s*\d+\s*\|`, asi que una fila sin numero
#       no existia: `apply_add_monthly` escribia una SEGUNDA fila para el mismo pendiente y
#       `apply_resolve_monthly` dejaba un WARN y perdia la fecha de cierre. Con el codigo de
#       2.17.1, el caso 1 de aqui daba `rows_added=1` y DOS filas para el mismo id.
#   D2. El informe GRAVE afirmaba "el dato original se perdio" sobre una senal que tambien
#       produce un valor escrito a mano, donde no se perdio nada (`Media->Alta`), y a la vez NO
#       veia una fila a la que le faltaban columnas de verdad.
#   D3. `ensure_monthly` escribia la cabecera canonica solo al CREAR el fichero: nadie validaba
#       despues, y un mensual de 5 columnas convivia con filas de 7 sin un aviso.
#
# La prueba de conservacion de contenido (caso 6) usa un parser PROPIO, escrito aqui, que no
# importa journal-compact: un verificador que comparta el reparto de celdas del codigo que
# verifica no puede ver un error en ese reparto.
#
# Uso: test-monthly-rows.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
# `export`, y en el codigo python se lee de os.environ en vez de interpolar "$BIN" en el literal.
# En Git Bash una ruta MSYS como /d/a/... solo se convierte a la forma nativa cuando viaja como
# ARGUMENTO o como VARIABLE DE ENTORNO hacia un .exe nativo. Interpolada dentro del fuente de
# python no la ve nadie: el interprete de Windows la resolvia contra la unidad actual y salia
# `D:\d/a/...`, que no existe. Medido en CI el 2026-09-12.
export BIN
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

# Mensual con cabecera de 5 columnas (sin `#` ni `Sesion resolucion`) y una fila sin numero,
# exactamente la forma medida en `2026-08.md` de la instalacion real.
mem_corto() {
  local d="$1"; mkdir -p "$d/pendientes" "$d/.journal/pending"
  cat > "$d/pendientes/2026-08.md" <<'EOF'
---
type: pendientes-archive
month: 2026-08
---
# Pendientes — Agosto 2026

| Pendiente | Prioridad | Creado | Origen | Resuelto |
|---|---|---|---|---|
| Fila sin numero _id: p-1111111111_ | Alta | 2026-08-05 | [[sessions/x]] |  |
| 1 | Fila canonica de 7 celdas _id: p-2222222222_ | Media | 2026-08-06 | [[sessions/y]] | | |

## Related
- [[_pendientes]]
EOF
  cat > "$d/_pendientes.md" <<'EOF'
# Pendientes

## Alta prioridad

- [ ] Fila sin numero — _origen: [[sessions/x]]_ — _creado: 2026-08-05_ — _id: p-1111111111_

## Media prioridad

- [ ] Fila canonica de 7 celdas — _origen: [[sessions/y]]_ — _creado: 2026-08-06_ — _id: p-2222222222_

## Related
EOF
}

echo "1. repair-dualwrite NO duplica la fila sin numero (con 2.17.1: rows_added=1 y dos filas)"
M="$TMP/m1"; mem_corto "$M"
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M" --apply)
check "no anade nada" "$(echo "$OUT" | grep -o 'rows_added=[0-9]*')" "rows_added=0"
check "sigue habiendo UNA fila del id" "$(grep -c 'p-1111111111' "$M/pendientes/2026-08.md")" "1"
check "cabecera corta reportada" "$(echo "$OUT" | grep -o 'header_issues=[0-9]*')" "header_issues=1"
check "y dice que columnas faltan" \
  "$(echo "$OUT" | grep -c 'falta(n): #, Sesion resolucion')" "1"

echo "2. segunda corrida: idempotente y byte a byte igual"
B1="$TMP/b1"; cp "$M/pendientes/2026-08.md" "$B1"
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M" --apply)
check "sigue en cero" "$(echo "$OUT" | grep -o 'rows_added=[0-9]*')" "rows_added=0"
check "fichero identico" "$(cmp -s "$B1" "$M/pendientes/2026-08.md" && echo igual || echo distinto)" "igual"

echo "3. cerrar un pendiente rellena la fila SIN numero, en su columna, sin cambiar la forma"
M2="$TMP/m2"; mem_corto "$M2"
python3 "$BIN/journal-emit.py" --memory-dir "$M2" --type pendiente.resolve --id p-1111111111 \
  --estado resolved --sesion "[[sessions/prueba]]" --nota "cerrado aqui" >/dev/null
OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$M2" 2>&1)
check "el evento se aplico" "$(echo "$OUT" | grep -o 'applied=[0-9]*')" "applied=1"
FILA=$(grep 'p-1111111111' "$M2/pendientes/2026-08.md")
check "la fila conserva sus 5 celdas" "$(printf '%s' "$FILA" | awk -F'|' '{print NF-2}')" "5"
check "la fecha cae en Resuelto, no en Origen" \
  "$(printf '%s' "$FILA" | awk -F'|' '{gsub(/ /,"",$6); print $6}')" "$(date +%Y-%m-%d)"
check "el origen sigue en su sitio" "$(printf '%s' "$FILA" | grep -c 'sessions/x')" "1"
check "la nota que no cabe se avisa con su id" \
  "$(echo "$OUT" | grep -c 'WARN monthly:.*no tiene columna .Sesion resolucion.; p-1111111111')" "1"

echo "4. cerrar un pendiente de la fila canonica sigue usando las 7 columnas"
python3 "$BIN/journal-emit.py" --memory-dir "$M2" --type pendiente.resolve --id p-2222222222 \
  --estado resolved --sesion "[[sessions/prueba]]" --nota "cierre normal" >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$M2" >/dev/null 2>&1
FILA=$(grep 'p-2222222222' "$M2/pendientes/2026-08.md")
check "conserva sus 7 celdas" "$(printf '%s' "$FILA" | awk -F'|' '{print NF-2}')" "7"
check "la sesion se guardo" "$(printf '%s' "$FILA" | grep -c 'cierre normal')" "1"

echo "5. un pendiente SIN fila sigue recibiendola (el arreglo no apaga la reparacion)"
M3="$TMP/m3"; mem_corto "$M3"
# Bajo un header de prioridad: una linea fuera de los tres headers se reporta como no reparable,
# que es otra cosa y la cubre test-repair-dualwrite.sh.
python3 - "$M3/_pendientes.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
linea = ("- [ ] Huerfano de verdad — _origen: [[sessions/z]]_ — _creado: 2026-08-09_ "
         "— _id: p-9999999999_\n")
open(p, "w", encoding="utf-8").write(t.replace("## Media prioridad\n\n", "## Media prioridad\n\n" + linea, 1))
PY
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M3" --apply)
check "le escribe su fila" "$(echo "$OUT" | grep -o 'rows_added=[0-9]*')" "rows_added=1"
check "y esta en el mes de su _creado_" "$(grep -c 'p-9999999999' "$M3/pendientes/2026-08.md")" "1"

echo "6. conservacion de contenido, con un parser independiente de journal-compact"
python3 - "$M2/pendientes/2026-08.md" <<'PY'
import re, sys
# Parser PROPIO: parte por `|` que no venga precedido de `\`, sin importar nada del plugin.
txt = open(sys.argv[1], encoding="utf-8").read().split("\n")
filas = {}
for ln in txt:
    s = ln.strip()
    if not s.startswith("|") or set(s) <= set("|-: "):
        continue
    celdas = [c.strip() for c in re.split(r"(?<!\\)\|", s.strip("|"))]
    m = re.findall(r"_id:\s*(p-[0-9a-f]{10})_", " ".join(celdas))
    if m:
        filas[m[-1]] = celdas
esperado = {
    "p-1111111111": ["Fila sin numero _id: p-1111111111_", "Alta", "2026-08-05", "[[sessions/x]]"],
    "p-2222222222": ["1", "Fila canonica de 7 celdas _id: p-2222222222_", "Media", "2026-08-06",
                     "[[sessions/y]]"],
}
malo = 0
for pid, pref in esperado.items():
    got = filas.get(pid)
    if got is None:
        print(f"  FAIL se perdio la fila de {pid}"); malo = 1; continue
    if got[:len(pref)] != pref:
        print(f"  FAIL {pid} cambio de contenido:\n       esperado {pref}\n       real     {got[:len(pref)]}")
        malo = 1
    else:
        print(f"  ok   {pid} conserva texto, prioridad, creado y origen")
sys.exit(malo)
PY
[ $? -eq 0 ] || FAIL=1

echo "7. D2: un valor no canonico NO se reporta como dato perdido, y una fila corta SI se ve"
M4="$TMP/m4"; mkdir -p "$M4/pendientes" "$M4/.journal/pending"
cat > "$M4/pendientes/2026-07.md" <<'EOF'
---
type: pendientes-archive
month: 2026-07
---
# Pendientes — Julio 2026

| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |
|---|---|---|---|---|---|---|
| 56 | Prioridad escrita a mano _id: p-3333333333_ | Media→Alta | 2026-07-20 | [[sessions/a]] | | |
| 57 | Le faltan columnas de en medio _id: p-4444444444_ | [[sessions/b]] | | |

## Related
- [[_pendientes]]
EOF
printf '# Pendientes\n\n## Alta prioridad\n\n## Related\n' > "$M4/_pendientes.md"
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M4")
check "el valor raro va a odd_values" "$(echo "$OUT" | grep -o 'odd_values=[0-9]*')" "odd_values=1"
check "y dice que no falta nada" "$(echo "$OUT" | grep -c 'No falta ni se movio nada')" "1"
check "la fila corta si se ve" "$(echo "$OUT" | grep -o 'unaligned_rows=[0-9]*')" "unaligned_rows=1"
check "el informe da las medidas" "$(echo "$OUT" | grep -c 'Medido: 5 celdas')" "1"
check "ya no afirma una sola causa" "$(echo "$OUT" | grep -c 'El dato original se perdio')" "0"
check "la fila del valor raro SI se localiza por id" \
  "$(python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('jc', os.path.join(os.environ['BIN'], 'journal-compact.py'))
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
print('si' if jc.find_monthly_row('$M4', 'p-3333333333') else 'no')")" "si"

echo "8. una fila corta SIN cabecera que la explique no se adivina (adversario ronda 1, H1)"
M5="$TMP/m5"; mkdir -p "$M5/pendientes" "$M5/.journal/pending"
# Sin cabecera: `| 56 | texto | Alta | fecha | a | b |` puede ser "le falta Sesion resolucion" o
# "le falta Origen", y la fecha de Creado esta en su sitio en las dos. Elegir mal hace que un
# cierre escriba sobre la celda equivocada, o sea que el lector tolerante introduciria la perdida
# de datos que venia a cerrar.
cat > "$M5/pendientes/2026-06.md" <<'EOF'
---
type: pendientes-archive
month: 2026-06
---
# Pendientes — Junio 2026

| 56 | Fila ambigua sin cabecera _id: p-6666666666_ | Alta | 2026-06-10 | dato | otro dato |
| 57 | Fila canonica de 7 _id: p-7777777777_ | Alta | 2026-06-11 | [[sessions/q]] | | |
EOF
printf '# Pendientes\n\n## Alta prioridad\n\n## Related\n' > "$M5/_pendientes.md"
OUT=$(python3 "$BIN/repair-dualwrite.py" "$M5")
check "la ambigua NO se alinea" "$(echo "$OUT" | grep -o 'unaligned_rows=[0-9]*')" "unaligned_rows=1"
check "y el motivo dice que no se adivina" \
  "$(echo "$OUT" | grep -c 'la cabecera del fichero no dice que columnas son')" "1"
check "la de 7 celdas SI se localiza (no se tira el bebe con el agua)" \
  "$(python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('jc', os.path.join(os.environ['BIN'], 'journal-compact.py'))
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
print('si' if jc.find_monthly_row('$M5', 'p-7777777777') else 'no')")" "si"
check "la ambigua NO se localiza por id (no se escribe a ciegas)" \
  "$(python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('jc', os.path.join(os.environ['BIN'], 'journal-compact.py'))
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
print('si' if jc.find_monthly_row('$M5', 'p-6666666666') else 'no')")" "no"
check "con cabecera de 7, la fila de 6 SI se lee (faltan las finales)" \
  "$(python3 -c "
import importlib.util, os
spec = importlib.util.spec_from_file_location('jc', os.path.join(os.environ['BIN'], 'journal-compact.py'))
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
cab = '| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |'
h = jc.header_map([cab, '|---|---|---|---|---|---|---|'])
c, m = jc.align_row('| 90 | texto _id: p-8888888888_ | Alta | 2026-06-01 | [[sessions/w]] | 2026-06-09 |', h)
print('ok' if c and c[jc.COL_ORIGEN] == '[[sessions/w]]' and c[jc.COL_RESUELTO] == '2026-06-09' else 'mal')")" "ok"

echo "9. la nota que no cabe queda EN DISCO, no solo en un WARN (adversario ronda 1, H4)"
M6="$TMP/m6"; mem_corto "$M6"
python3 "$BIN/journal-emit.py" --memory-dir "$M6" --type pendiente.resolve --id p-1111111111 \
  --estado resolved --sesion "[[sessions/prueba]]" --nota "nota que no cabe" >/dev/null
# --quiet >/dev/null 2>&1 es como lo corre recall.sh: por ese camino el WARN se descarta.
python3 "$BIN/journal-compact.py" --memory-dir "$M6" --quiet >/dev/null 2>&1
check "existe el log" "$([ -f "$M6/.journal/notas-sin-columna.log" ] && echo si || echo no)" "si"
check "lleva el id y la nota" \
  "$(grep -c 'p-1111111111.*nota que no cabe' "$M6/.journal/notas-sin-columna.log" 2>/dev/null)" "1"

echo "10. CRLF: un fichero con saltos de Windows no se convierte al cerrar un pendiente"
M7="$TMP/m7"; mem_corto "$M7"
python3 - "$M7/pendientes/2026-08.md" <<'PY'
import sys
p = sys.argv[1]
b = open(p, "rb").read().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
open(p, "wb").write(b)
PY
ANTES_LF=$(grep -c $'\r' "$M7/pendientes/2026-08.md" || true)
python3 "$BIN/journal-emit.py" --memory-dir "$M7" --type pendiente.resolve --id p-1111111111 \
  --estado resolved --sesion "[[sessions/prueba]]" --nota "cierre crlf" >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$M7" >/dev/null 2>&1
DESPUES_LF=$(grep -c $'\r' "$M7/pendientes/2026-08.md" || true)
check "el numero de lineas CRLF no cambia" "$DESPUES_LF" "$ANTES_LF"
check "no quedo ningun salto suelto" \
  "$(python3 -c "
b = open('$M7/pendientes/2026-08.md','rb').read()
print(b.count(b'\n') - b.count(b'\r\n'))")" "0"
check "y la fecha si se escribio" \
  "$(grep -c "$(date +%Y-%m-%d)" "$M7/pendientes/2026-08.md")" "1"

echo
if [ "$FAIL" -eq 0 ]; then echo "TODO VERDE"; else echo "HAY FALLOS"; fi
exit "$FAIL"
