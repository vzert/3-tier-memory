#!/usr/bin/env bash
# Pruebas de repair-research-index.py (p-cd33654290, continuacion de 2.31.5): migra por NOMBRE de
# columna las tablas de memory/_research-index.md anteriores a 2.31.5 (cuya ultima columna no se
# llama Archivo ni File, asi que `research_table_is_canonical`/`apply_research_upsert` en
# journal-compact.py las deja de SOLO LECTURA y cualquier research nuevo entra en cuarentena).
# Medido en 5 instalaciones reales (omniroute, scalar-api-docs, seedance-generator, time-tracker,
# unifi-expert): 10 formas de cabecera distintas entre las dos tablas, ninguna igual a otra.
#
# Lo que estas pruebas defienden:
#   A. `Topic | File | Resultado` (medido: unifi-expert) migra y re-cabecea, sin columna de fecha;
#   B. `Topic | Result | File | Fecha` (medido: omniroute) migra con Fecha en la celda 3 -> se
#      anexa como texto DESPUES del enlace, en Archivo — nunca a Resultado/Origen (ver P2 y el
#      hallazgo F1 de la tercera ronda de adversario: anexar ahi solo trasladaba el riesgo a
#      cualquier `research.upsert` normal que trajera esa misma columna) — y NUNCA se le anexa una
#      marca de completado (ver O, y el hallazgo F3 de la segunda ronda, subagente en Opus,
#      2.31.6: marcarla volveria podable de golpe una fila que antes no competia en la poda);
#   C. `Slug | Topic | Fecha | Sesion` para Active (medido: seedance-generator/time-tracker): el
#      Archivo sale del Slug (el wikilink vive ahi, no en una columna "File"), el Tema del Topic,
#      Next step y Origen quedan vacios (nunca reciben extras), y Fecha+Sesion se anexan como
#      texto DESPUES del enlace, en Archivo, sin perderse;
#   D. es idempotente: la segunda corrida sobre el resultado no encuentra nada;
#   E. una cabecera YA canonica no se toca, aunque tenga una fila de ancho distinto al canonico;
#   F. una fila cuyo ancho no coincide con el de SU propia cabecera se reporta GRAVE, TODO O NADA:
#      no se toca ni esa fila ni ninguna otra de la misma tabla, ni se reescribe la cabecera
#      (dejarla "canonica" con esa fila sin migrar le quitaria su proteccion de solo lectura);
#   G. una cabecera con un nombre de columna fuera de ROLE_ALIAS se reporta header_unrecognized y
#      no se toca (ni la cabecera ni sus filas);
#   H. una cabecera cuyos nombres SI estan en ROLE_ALIAS pero no tiene exactamente una columna Tema
#      y una Archivo (ninguna, o dos) tambien se reporta header_unrecognized;
#   I. dos filas que migrarian al mismo Tema: TODO O NADA igual que F — se reporta posible
#      duplicado y NINGUNA de las dos se migra (ni la que no colisiona), ni se reescribe la cabecera;
#   J. sin _research-index.md no falla (proyecto nuevo);
#   K. _research-index.md sin '## Active Research'/'## Completed Research' reporta
#      no_active_table=1/no_completed_table=1 y no rompe;
#   L. solo toca la tabla ANCLADA (la primera) bajo cada header — otra tabla del archivo, aunque
#      tenga el mismo ancho y nombres reconocidos, no se toca;
#   M. un `\|` escapado dentro de una celda no desalinea la fila ni se pierde al migrar;
#   N. tras migrar, un research.upsert real (via journal-compact.py) entra sin cuarentena;
#   O. un Archivo que YA trae `_completado: <fecha vieja>_` de antes (escrito a mano, o por una
#      version previa de este script) se conserva intacto, y la fecha de una columna `fecha`
#      separada se anexa DESPUES, en el mismo Archivo (nunca en Resultado) — sin generar una
#      segunda marca `_completado:` y sin perder ninguna de las dos fechas;
#   P. una cabecera cuya ULTIMA columna ya se llama File/Archivo pero el resto NO esta en el orden
#      canonico (`Topic|Started|Sesion|File`) YA NO se reporta sana sin tocarla: `research_table_
#      is_canonical` en journal-compact.py solo mira esa ultima celda y esa forma ya escribe hoy
#      por posicion en produccion, mal — se reconoce como legacy (por nombre, igual que cualquier
#      otra) y se migra al orden canonico real (hallazgo F1 de la segunda ronda de adversario,
#      subagente en Opus, 2.31.6: reproducido sobre copia de una instalacion real, un hallazgo
#      curado se pisaba en la siguiente escritura);
#   P2. tras migrar la forma de P, un `research.upsert --origen` REAL (no una simulacion) no borra
#      lo anexado al Archivo — la primera correccion de F1 anexaba a Origen, que
#      `apply_research_upsert` REEMPLAZA entero en cualquier evento que traiga `--origen`, y solo
#      trasladaba el riesgo (hallazgo F1 de la TERCERA ronda, adversario externo, 2.31.6, sobre la
#      correccion de la segunda ronda);
#   Q. una cabecera YA exactamente canonica (nombre Y orden) con una fila de ancho distinto se
#      reporta GRAVE y no se toca — el chequeo de "ya canonica" no se salta las filas;
#   R. un valor de columna que por casualidad TIENE la forma exacta de la marca
#      (`_completado: 2020-01-01_`) no se cuela como marca real al anexarse al Archivo — se
#      neutraliza (hallazgo de la cuarta ronda de adversario externo, 2.31.6: la exclusion de la
#      marca estaba declarada pero no implementada para texto anexado, solo para el Archivo
#      original);
#   S. una tabla YA lenient-canonica (ultima columna File/Archivo) con una fila mal anchada SI
#      migra el resto y reescribe la cabecera — el todo-o-nada de F/I NO aplica aqui, porque esa
#      tabla ya se escribe por posicion en produccion hoy y bloquearla entera no protege nada
#      (hallazgo de la quinta ronda de adversario, subagente en Opus, 2.31.6: reproducido sobre
#      copia de una instalacion real donde el todo-o-nada dejaba TODA la tabla, incluidas las
#      filas migrables, expuesta bajo la cabecera lenient vieja);
#   T. un dato con forma de marca en RESULTADO (no solo en un extra) tambien se neutraliza —
#      `COMPLETADO_RE` en journal-compact.py escanea la FILA COMPLETA, no solo el Archivo (mismo
#      hallazgo de la quinta ronda: la neutralizacion de R solo cubria los extras);
#   U. lo mismo que T pero en TEMA, con las 10 filas historicas que de verdad ejercitan el tope de
#      poda (MAX_RESEARCH_DONE=5) tras un research.upsert real — T por si sola solo tenia una fila
#      y nunca probaba a Tema, asi que su titulo prometia mas cobertura de la que media (hallazgo
#      de la sexta ronda de adversario externo, 2.31.6);
#   V. neutralizar un Tema con forma de marca NO le rompe su identidad: una fila (inline), sin
#      wikilink, se encuentra por `plain(Tema)` cuando un evento la actualiza, y `_defuse_completado`
#      quita el guion bajo inicial (no mete un espacio) precisamente para que `plain()` -que ya
#      quita guiones bajos- de el MISMO resultado antes y despues — de lo contrario la fila
#      migrada queda huerfana y el evento le inserta una fila NUEVA al lado, duplicando en
#      silencio (hallazgo de la sexta ronda, subagente en Opus, 2.31.6);
#   W. guiones bajos APILADOS antes de la marca (`__completado: ..._`) no sobreviven a la
#      neutralizacion: quitar solo el guion bajo que el match consumio deja el de al lado todavia
#      pegado a "completado:", reconstruyendo la marca — `_defuse_completado` retrocede sobre
#      TODOS los guiones bajos contiguos, no solo uno (hallazgo de la septima ronda de adversario
#      externo, 2.31.6).
#   X. p-5457992187 (v2.31.8): nombres de columna nuevos en ROLE_ALIAS (Iniciado, Outcome, Summary,
#      Resumen, Hallazgo clave, Goal, Context, Notas, Finding) migran cada uno a su rol — medido
#      contra 11 instalaciones reales fuera de las 5 originales, con nombres genericos aqui (no se
#      publican rutas ni nombres de proyectos privados del usuario);
#  X2. una tabla YA lenient-canonica (ultima columna File) con filas REALES y 'Outcome' fuera de
#      ROLE_ALIAS: HOY (antes de este ciclo) ya escribe por posicion en produccion — un
#      research.upsert real la habria corrompido (Resultado sobre la columna Completed, marca de
#      completado sobre el texto de Outcome, Archivo real nunca leido). Prioridad de reparacion
#      real que el pendiente original no habia medido (adversario en Opus la encontro, no nombrada
#      aqui por privacidad); las 2 filas reales migran sin perder nada;
#   Y. "Research" NO se agrega a ROLE_ALIAS a proposito: significa tema en una instalacion medida
#      (columna Slug aparte sostiene el enlace) y significa archivo en otra (el wikilink vive
#      directo ahi) — decision explicita, no un hueco sin cerrar; el archivo queda BYTE IGUAL
#      (no solo la cabecera: la fila de datos tambien, chequeado con `cmp`, adversario en Opus
#      encontro que el chequeo anterior solo contaba lineas de cabecera).
#  Y2. "Session"/"Sesion" TAMPOCO se toca (ya mapeaba a extra) por el mismo motivo: es metadata en
#      varias instalaciones medidas (Topic|File|Session sigue reconocida, correcto) pero en otra
#      sostiene el wikilink — esa forma se queda `header_unrecognized`, la fila con el enlace en
#      Session queda intacta.
#   Z. una tabla lenient-canonica (ultima columna File) pero VACIA (sin filas) y con un nombre de
#      columna antes fuera de ROLE_ALIAS ("Finding") se reconoce y re-cabecea sin filas que migrar
#      — el caso que motivo esta ronda: una tabla vacia hoy expuesta a que un evento futuro le
#      inserte una fila con mas celdas que su cabecera (Topic|Finding|File, 3 columnas, contra las
#      4 de la fila que `apply_research_upsert` insertaria por su cabecera lenient).
#
# Uso: test-repair-research-index.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

campo() { echo "$1" | grep -o "$2=[^ ]*"; }

echo "A. Topic|File|Resultado (unifi-expert): migra y re-cabecea, sin fecha -> sin marca de completado"
MA="$TMP/ma/memory"; mkdir -p "$MA"
cat > "$MA/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Resultado |
|---|---|---|
| Ecosistema MCP | [[research/mcp-ecosistema]] | sirkirby/unifi-mcp elegido |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MA" --apply)
check "completed_header_rewritten=si" "$(campo "$OUT" completed_header_rewritten)" "completed_header_rewritten=si"
check "completed_rows_migrated=1" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=1"
check "cabecera canonica de Completed" "$(grep -c '^| Tema | Resultado | Archivo |$' "$MA/_research-index.md")" "1"
check "fila migrada sin marca de completado (no habia fecha)" \
  "$(grep -c '^| Ecosistema MCP | sirkirby/unifi-mcp elegido | \[\[research/mcp-ecosistema\]\] |$' "$MA/_research-index.md")" "1"
check "sin _completado en la fila migrada" "$(grep -c '_completado:' "$MA/_research-index.md")" "0"

echo "B. Topic|Result|File|Fecha (omniroute): Fecha en celda 3 -> se anexa AL ARCHIVO, despues del enlace"
MB="$TMP/mb/memory"; mkdir -p "$MB"
cat > "$MB/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Fecha | Sesion |
|---|---|---|---|

## Completed Research

| Topic | Result | File | Fecha |
|---|---|---|---|
| OmniRoute ecosystem | Free stack validado | [[research/omniroute-ecosystem]] | 2026-04-26 |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MB" --apply)
check "completed_rows_migrated=1" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=1"
check "Archivo SIN marca de completado (la migracion ya no la anexa, ver hallazgo F3 2.31.6)" \
  "$(grep -c '\[\[research/omniroute-ecosystem\]\] _completado:' "$MB/_research-index.md")" "0"
check "Resultado es el Result original, SIN la fecha mezclada (ver hallazgo F1 ronda 3, 2.31.6)" \
  "$(grep -c '^| OmniRoute ecosystem | Free stack validado | ' "$MB/_research-index.md")" "1"
check "la fecha se anexo como texto DESPUES del enlace, en Archivo (la unica celda que un research.upsert normal nunca reescribe)" \
  "$(grep -c '^| OmniRoute ecosystem | Free stack validado | \[\[research/omniroute-ecosystem\]\] — Fecha: 2026-04-26 |$' "$MB/_research-index.md")" "1"

echo "C. Slug|Topic|Fecha|Sesion (seedance/time-tracker) en Active: Slug->Archivo, extras anexados AL ARCHIVO"
MC="$TMP/mc/memory"; mkdir -p "$MC"
cat > "$MC/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Slug | Topic | Fecha | Sesion |
|---|---|---|---|
| [[research/2026-04-20-prod-readiness]] | Production readiness | 2026-04-20 | sesion actual |

## Completed Research

| Topic | File | Resultado |
|---|---|---|

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MC" --apply)
check "active_rows_migrated=1" "$(campo "$OUT" active_rows_migrated)" "active_rows_migrated=1"
check "Tema=Topic, Archivo=Slug, Next step y Origen vacios (nunca reciben extras — ver F1 ronda 3), extras anexados al enlace" \
  "$(grep -c '^| Production readiness |  |  | \[\[research/2026-04-20-prod-readiness\]\] — Fecha: 2026-04-20; Sesion: sesion actual |$' "$MC/_research-index.md")" "1"

echo "D. idempotencia: segunda corrida no encuentra nada"
OUT=$(python3 "$BIN/repair-research-index.py" "$MB" --apply)
check "todo en cero" "$OUT" "active_header_rewritten=no active_rows_migrated=0 active_unrepairable=0 active_possible_duplicates=0 completed_header_rewritten=no completed_rows_migrated=0 completed_unrepairable=0 completed_possible_duplicates=0 no_active_table=0 no_completed_table=0 active_header_unrecognized=0 completed_header_unrecognized=0"

echo "E. cabecera YA canonica no se toca, aunque tenga una fila de ancho distinto"
ME="$TMP/me/memory"; mkdir -p "$ME"
cat > "$ME/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Tema | Next step | Origen | Archivo |
|---|---|---|---|

## Completed Research

| Tema | Resultado | Archivo |
|---|---|---|
| Tema raro con cuatro celdas | algo | mas | [[research/x]] |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$ME" --apply)
check "completed_header_rewritten=no (ya era canonica)" "$(campo "$OUT" completed_header_rewritten)" "completed_header_rewritten=no"
check "completed_rows_migrated=0" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=0"
check "la fila de 4 celdas no se toco" "$(grep -c '^| Tema raro con cuatro celdas | algo | mas | \[\[research/x\]\] |$' "$ME/_research-index.md")" "1"

echo "F. fila cuyo ancho no coincide con el de su propia cabecera: GRAVE, TODO O NADA en esa tabla"
MF="$TMP/mf/memory"; mkdir -p "$MF"
cat > "$MF/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Resultado |
|---|---|---|
| Fila corta | [[research/y]] |
| Fila normal | [[research/z]] | resultado normal |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MF" --apply)
check "completed_unrepairable=1" "$(campo "$OUT" completed_unrepairable)" "completed_unrepairable=1"
check "completed_rows_migrated=0 (todo o nada: la fila normal tampoco migra)" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=0"
check "completed_header_rewritten=no (una fila sin migrar bloquea la cabecera)" "$(campo "$OUT" completed_header_rewritten)" "completed_header_rewritten=no"
check "la fila corta no se toco" "$(grep -c '^| Fila corta | \[\[research/y\]\] |$' "$MF/_research-index.md")" "1"
check "la fila normal tampoco se toco (sigue con su cabecera vieja)" "$(grep -c '^| Fila normal | \[\[research/z\]\] | resultado normal |$' "$MF/_research-index.md")" "1"
check "cabecera vieja intacta" "$(grep -c '^| Topic | File | Resultado |$' "$MF/_research-index.md")" "1"

echo "G. cabecera con un nombre fuera de ROLE_ALIAS: header_unrecognized, no se toca"
MG="$TMP/mg/memory"; mkdir -p "$MG"
cat > "$MG/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | Archivo Raro | Resultado |
|---|---|---|
| Tema x | [[research/x]] | resultado x |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MG" --apply)
check "completed_header_unrecognized=1" "$(campo "$OUT" completed_header_unrecognized)" "completed_header_unrecognized=1"
check "completed_header_rewritten=no" "$(campo "$OUT" completed_header_rewritten)" "completed_header_rewritten=no"
check "completed_rows_migrated=0" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=0"
check "cabecera no reconocida sigue intacta" "$(grep -c '^| Topic | Archivo Raro | Resultado |$' "$MG/_research-index.md")" "1"

echo "H. nombres reconocidos pero sin exactamente un Tema y un Archivo: header_unrecognized"
MH="$TMP/mh/memory"; mkdir -p "$MH"
cat > "$MH/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| File | Resultado |
|---|---|
| [[research/x]] | resultado x |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MH" --apply)
check "completed_header_unrecognized=1 (sin columna Tema)" "$(campo "$OUT" completed_header_unrecognized)" "completed_header_unrecognized=1"
check "completed_rows_migrated=0" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=0"

echo "I. dos filas que migrarian al mismo Tema: TODO O NADA, ninguna de las dos se toca"
MI="$TMP/mi/memory"; mkdir -p "$MI"
cat > "$MI/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Resultado |
|---|---|---|
| Tema repetido | [[research/uno]] | primera version |
| Tema repetido | [[research/dos]] | segunda version |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MI" --apply)
check "completed_rows_migrated=0 (todo o nada: ni la que no colisiona se migra)" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=0"
check "completed_possible_duplicates=1" "$(campo "$OUT" completed_possible_duplicates)" "completed_possible_duplicates=1"
check "completed_header_rewritten=no" "$(campo "$OUT" completed_header_rewritten)" "completed_header_rewritten=no"
check "la primera no se toco (sigue con 3 celdas en su forma vieja)" \
  "$(grep -c '^| Tema repetido | \[\[research/uno\]\] | primera version |$' "$MI/_research-index.md")" "1"
check "la segunda no se toco (sigue con 3 celdas en su forma vieja)" \
  "$(grep -c '^| Tema repetido | \[\[research/dos\]\] | segunda version |$' "$MI/_research-index.md")" "1"

echo "J. sin _research-index.md no falla (proyecto nuevo)"
MJ="$TMP/mj/memory"; mkdir -p "$MJ"
OUT=$(python3 "$BIN/repair-research-index.py" "$MJ"); RCJ=$?
check "exit 0" "$RCJ" "0"
check "avisa sin _research-index.md" "$(echo "$OUT" | grep -c 'sin _research-index.md')" "1"

echo "K. sin '## Active Research'/'## Completed Research' reporta no_active_table/no_completed_table"
MK="$TMP/mk/memory"; mkdir -p "$MK"
cat > "$MK/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MK" --apply)
check "no_active_table=1" "$(campo "$OUT" no_active_table)" "no_active_table=1"
check "no_completed_table=1" "$(campo "$OUT" no_completed_table)" "no_completed_table=1"
check "archivo intacto" "$(grep -c '## Active Research' "$MK/_research-index.md")" "0"

echo "L. solo toca la tabla ANCLADA (la primera) bajo cada header"
ML="$TMP/ml/memory"; mkdir -p "$ML"
cat > "$ML/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Resultado |
|---|---|---|
| Tema ancla | [[research/ancla]] | resultado ancla |

## Otra tabla parecida

| Topic | File | Resultado |
|---|---|---|
| Tema ajeno | [[research/ajeno]] | no tocar |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$ML" --apply)
check "completed_rows_migrated=1 (solo la ancla)" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=1"
check "tabla ajena intacta" "$(grep -c '^| Topic | File | Resultado |$' "$ML/_research-index.md")" "1"
check "fila ajena intacta" "$(grep -c '^| Tema ajeno | \[\[research/ajeno\]\] | no tocar |$' "$ML/_research-index.md")" "1"

echo "M. un pipe escapado dentro de una celda no desalinea la fila ni se pierde"
MM="$TMP/mm/memory"; mkdir -p "$MM"
cat > "$MM/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Resultado |
|---|---|---|
| Tema con pipe | [[research/pipe\|alias]] | resultado con \| pipe crudo |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MM" --apply)
check "completed_rows_migrated=1" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=1"
check "pipe escapado intacto en Archivo y Resultado" \
  "$(grep -F -c '| Tema con pipe | resultado con \| pipe crudo | [[research/pipe\|alias]] |' "$MM/_research-index.md")" "1"

echo "N. tras migrar, un research.upsert real entra sin cuarentena"
MN="$TMP/mn/memory"; mkdir -p "$MN/.journal"
cat > "$MN/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Resultado |
|---|---|---|
| Tema viejo | [[research/viejo]] | resultado viejo |

## Related
EOF
python3 "$BIN/repair-research-index.py" "$MN" --apply >/dev/null
python3 "$BIN/journal-emit.py" --type research.upsert --memory-dir "$MN" --slug nuevo-tras-migracion \
  --tema "Nuevo tras migracion" --status active --next-step "verificar" --origen "prueba" >/dev/null
JOUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MN" 2>&1)
check "el evento se aplico, no se cuarenteno" "$JOUT" "JOURNAL applied=1 quarantined=0 pending_left=0"
check "la fila nueva quedo en Active, canonica" \
  "$(grep -c '^| Nuevo tras migracion | verificar | prueba | \[\[research/nuevo-tras-migracion\]\] |$' "$MN/_research-index.md")" "1"

echo "O. Archivo que YA trae _completado: se conserva intacto; la fecha de otra columna se anexa AL ARCHIVO tambien"
MO="$TMP/mo/memory"; mkdir -p "$MO"
cat > "$MO/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Fecha | Resultado |
|---|---|---|---|
| Tema con doble fecha | [[research/t]] _completado: 2020-01-01_ | 2021-02-03 | resultado t |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MO" --apply)
check "completed_rows_migrated=1" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=1"
check "la marca vieja se conserva, sin una segunda marca" \
  "$(grep -c '_completado: 2020-01-01_' "$MO/_research-index.md")" "1"
check "no aparece una segunda marca con la fecha de la columna Fecha" \
  "$(grep -c '_completado: 2021-02-03_' "$MO/_research-index.md")" "0"
check "Resultado sin tocar (la fecha ya no se mezcla ahi, ver F1 ronda 3)" \
  "$(grep -c '^| Tema con doble fecha | resultado t | ' "$MO/_research-index.md")" "1"
check "la fecha de la columna Fecha se anexo como texto AL FINAL del Archivo, despues de la marca vieja" \
  "$(grep -c '^| Tema con doble fecha | resultado t | \[\[research/t\]\] _completado: 2020-01-01_ — Fecha: 2021-02-03 |$' "$MO/_research-index.md")" "1"

echo "P. cabecera con la ULTIMA columna canonica pero el resto NO (Topic|Started|Sesion|File): migra igual"
MP="$TMP/mp/memory"; mkdir -p "$MP"
cat > "$MP/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | Started | Sesion | File |
|---|---|---|---|
| Hallazgo real | 2026-08-14 | sesion x | [[research/hallazgo-real]] |

## Completed Research

| Tema | Resultado | Archivo |
|---|---|---|

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MP" --apply)
check "active_header_rewritten=si (ya NO se queda escondida detras de la ultima columna)" \
  "$(campo "$OUT" active_header_rewritten)" "active_header_rewritten=si"
check "active_rows_migrated=1" "$(campo "$OUT" active_rows_migrated)" "active_rows_migrated=1"
check "cabecera realmente canonica (Tema|Next step|Origen|Archivo)" \
  "$(grep -c '^| Tema | Next step | Origen | Archivo |$' "$MP/_research-index.md")" "1"
check "el hallazgo no se piso: Next step/Origen vacios, Started/Sesion anexados AL ARCHIVO (no a Origen)" \
  "$(grep -c '^| Hallazgo real |  |  | \[\[research/hallazgo-real\]\] — Started: 2026-08-14; Sesion: sesion x |$' "$MP/_research-index.md")" "1"

echo "P2. tras migrar la forma P, un research.upsert --origen real NO borra lo anexado (hallazgo F1, ronda 3, 2.31.6)"
mkdir -p "$MP/.journal"
python3 "$BIN/journal-emit.py" --type research.upsert --memory-dir "$MP" --slug hallazgo-real \
  --tema "Hallazgo real" --status active --origen "sesion nueva" >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MP" >/dev/null
check "el Origen SI se actualizo (el evento lo pidio)" \
  "$(grep -c '^| Hallazgo real |  | sesion nueva | ' "$MP/_research-index.md")" "1"
check "lo anexado al Archivo (Started/Sesion originales) SOBREVIVIO al research.upsert normal" \
  "$(grep -c '^| Hallazgo real |  | sesion nueva | \[\[research/hallazgo-real\]\] — Started: 2026-08-14; Sesion: sesion x |$' "$MP/_research-index.md")" "1"

echo "Q. cabecera YA exactamente canonica con una fila de ancho distinto: se reporta, no se toca"
MQ="$TMP/mq/memory"; mkdir -p "$MQ"
cat > "$MQ/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Tema | Next step | Origen | Archivo |
|---|---|---|---|
| Fila de mas celdas | paso siguiente | origen x | extra | [[research/mal-anchada]] |

## Completed Research

| Tema | Resultado | Archivo |
|---|---|---|

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MQ" --apply)
check "active_header_rewritten=no (ya era exactamente canonica)" \
  "$(campo "$OUT" active_header_rewritten)" "active_header_rewritten=no"
check "active_unrepairable=1 (no se ignora en silencio)" "$(campo "$OUT" active_unrepairable)" "active_unrepairable=1"
check "la fila mal anchada no se toco" \
  "$(grep -c '^| Fila de mas celdas | paso siguiente | origen x | extra | \[\[research/mal-anchada\]\] |$' "$MQ/_research-index.md")" "1"

echo "R. un valor de columna que por casualidad TIENE la forma de la marca no se cuela como marca real"
MR="$TMP/mr/memory"; mkdir -p "$MR"
cat > "$MR/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Sesion | Resultado |
|---|---|---|---|
| Tema con dato peligroso | [[research/peligroso]] | _completado: 2020-01-01_ | resultado normal |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MR" --apply)
check "completed_rows_migrated=1" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=1"
check "la marca falsa quedo neutralizada (sin el guion bajo inicial), no matchea COMPLETADO_RE" \
  "$(grep -c 'completado: 2020-01-01_' "$MR/_research-index.md")" "1"
check "no aparece ninguna marca real _completado: (con el guion bajo) en la fila" \
  "$(grep -c '_completado: 2020-01-01_' "$MR/_research-index.md")" "0"

echo "S. tabla YA lenient-canonica (ultima columna File) con una fila mal anchada: SI migra el resto"
MS="$TMP/ms/memory"; mkdir -p "$MS"
cat > "$MS/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | Started | Sesion | File |
|---|---|---|---|
| Hallazgo bueno uno | 2026-08-14 | sesion x | [[research/hallazgo-bueno-uno]] |
| Fila mal anchada | 2026-08-15 | sesion y |
| Hallazgo bueno dos | 2026-08-16 | sesion z | [[research/hallazgo-bueno-dos]] |

## Completed Research

| Tema | Resultado | Archivo |
|---|---|---|

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MS" --apply)
check "active_header_rewritten=si (la cabecera YA era lenient-canonica: no hay proteccion que preservar bloqueando)" \
  "$(campo "$OUT" active_header_rewritten)" "active_header_rewritten=si"
check "active_rows_migrated=2 (las dos filas buenas SI migran, aunque una tercera no pueda)" \
  "$(campo "$OUT" active_rows_migrated)" "active_rows_migrated=2"
check "active_unrepairable=1" "$(campo "$OUT" active_unrepairable)" "active_unrepairable=1"
check "cabecera realmente canonica" "$(grep -c '^| Tema | Next step | Origen | Archivo |$' "$MS/_research-index.md")" "1"
check "hallazgo bueno uno migrado limpio (extras al Archivo, no a Origen)" \
  "$(grep -c '^| Hallazgo bueno uno |  |  | \[\[research/hallazgo-bueno-uno\]\] — Started: 2026-08-14; Sesion: sesion x |$' "$MS/_research-index.md")" "1"
check "hallazgo bueno dos migrado limpio (extras al Archivo, no a Origen)" \
  "$(grep -c '^| Hallazgo bueno dos |  |  | \[\[research/hallazgo-bueno-dos\]\] — Started: 2026-08-16; Sesion: sesion z |$' "$MS/_research-index.md")" "1"
check "la fila mal anchada quedo intacta, sin tocar" \
  "$(grep -c '^| Fila mal anchada | 2026-08-15 | sesion y |$' "$MS/_research-index.md")" "1"

echo "T. un dato en la celda RESULTADO con forma de marca tambien se neutraliza, no solo en un extra"
MT="$TMP/mt/memory"; mkdir -p "$MT/.journal"
cat > "$MT/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Completed | Key Findings |
|---|---|---|---|
| Research peligroso | [[research/peligroso-2]] | 2026-05-01 | la nota decia _completado: 2020-09-09_ literal |

## Related
EOF
python3 "$BIN/repair-research-index.py" "$MT" --apply >/dev/null
check "sin marca real (sin espacio) tras migrar: el Key Findings ya defusado" \
  "$(grep -c '_completado: 2020-09-09_' "$MT/_research-index.md")" "0"
python3 "$BIN/journal-emit.py" --type research.upsert --memory-dir "$MT" --slug otro-nuevo \
  --tema "Otro nuevo" --status completed --resultado "r" >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MT" >/dev/null
check "la fila peligrosa sigue ahi tras un research.upsert --status completed normal (no la podo)" \
  "$(grep -c '^| Research peligroso |' "$MT/_research-index.md")" "1"

echo "U. lo mismo que T pero en TEMA, y con las 10 filas que de verdad ejercitan el tope de poda"
MU="$TMP/mu/memory"; mkdir -p "$MU/.journal"
{
  printf '%s\n' '---' 'type: index' '---' '# Research Index' ''
  printf '%s\n' '## Active Research' '' '| Topic | File | Estado |' '|---|---|---|' ''
  printf '%s\n' '## Completed Research' '' '| Topic | File | Completed | Key Findings |' '|---|---|---|---|'
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '| Research %d _completado: 2020-01-%02d_ en el titulo | [[research/hist-%d]] | 2026-0%d-0%d | hallazgo %d |\n' \
      "$i" "$i" "$i" "$((i % 9 + 1))" "$((i % 9 + 1))" "$i"
  done
  printf '\n%s\n' '## Related'
} > "$MU/_research-index.md"
OUT=$(python3 "$BIN/repair-research-index.py" "$MU" --apply)
check "completed_rows_migrated=10" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=10"
check "un Tema con forma de marca se neutraliza (AVISO impreso por fila)" \
  "$(echo "$OUT" | grep -c 'AVISO: un valor de esta fila tenia la forma literal')" "10"
check "sin marcas reales (con guion bajo) en ningun Tema tras migrar" \
  "$(grep -c '_completado: 2020-01-[0-9][0-9]_ en el titulo' "$MU/_research-index.md")" "0"
check "el Tema sigue siendo identificable (plain() intacto: sin guion bajo, resto igual)" \
  "$(grep -c '^| Research [0-9]* completado: 2020-01-[0-9][0-9]_ en el titulo |' "$MU/_research-index.md")" "10"
python3 "$BIN/journal-emit.py" --type research.upsert --memory-dir "$MU" --slug otro-mas \
  --tema "Otro mas" --status completed --resultado "r" >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MU" >/dev/null
check "las 10 filas historicas sobreviven a UN research.upsert --status completed normal (el tope de poda no las alcanza)" \
  "$(grep -c '^| Research [0-9]* completado' "$MU/_research-index.md")" "10"

echo "V. neutralizar el Tema no rompe la identidad de una fila (inline): no se duplica al actualizarla"
MV="$TMP/mv/memory"; mkdir -p "$MV/.journal"
cat > "$MV/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Resultado |
|---|---|---|
| Cierre _completado: 2020-01-01_ del piloto | (inline) | en curso |

## Related
EOF
python3 "$BIN/repair-research-index.py" "$MV" --apply >/dev/null
python3 "$BIN/journal-emit.py" --type research.upsert --memory-dir "$MV" --inline --slug cierre-piloto \
  --tema "Cierre _completado: 2020-01-01_ del piloto" --status completed --resultado "actualizado" >/dev/null
JOUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MV" 2>&1)
check "el evento se aplico (encontro la fila migrada por plain(), no la duplico)" "$JOUT" "JOURNAL applied=1 quarantined=0 pending_left=0"
check "solo UNA fila con ese Tema (no se duplico)" \
  "$(grep -c 'Cierre completado: 2020-01-01_ del piloto' "$MV/_research-index.md")" "1"
check "el Resultado SI se actualizo sobre la fila que ya existia (y el evento completed anexo su propia marca legitima)" \
  "$(grep -c '^| Cierre completado: 2020-01-01_ del piloto | actualizado | (inline) _completado: [0-9-]*_ |$' "$MV/_research-index.md")" "1"

echo "W. guiones bajos APILADOS antes de la marca no sobreviven a un solo pase de neutralizacion"
MW="$TMP/mw/memory"; mkdir -p "$MW/.journal"
cat > "$MW/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Estado |
|---|---|---|

## Completed Research

| Topic | File | Completed | Key Findings |
|---|---|---|---|
| Tema con guiones apilados | [[research/apilado]] | 2026-05-01 | __completado: 2020-01-01__ literal |

## Related
EOF
python3 "$BIN/repair-research-index.py" "$MW" --apply >/dev/null
check "sin marca real tras migrar (mismo patron que COMPLETADO_RE en journal-compact.py)" \
  "$(grep -Ec '_completado: [0-9]{4}-[0-9]{2}-[0-9]{2}_' "$MW/_research-index.md")" "0"
python3 "$BIN/journal-emit.py" --type research.upsert --memory-dir "$MW" --slug otro-w \
  --tema "Otro W" --status completed --resultado "r" >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MW" >/dev/null
check "la fila con guiones apilados sigue ahi tras un research.upsert normal (no la podo)" \
  "$(grep -c '^| Tema con guiones apilados |' "$MW/_research-index.md")" "1"

echo "X. p-5457992187: Iniciado/Context/Notas (Active) y Hallazgo clave/Outcome (Completed) migran a sus roles"
MX="$TMP/mx/memory"; mkdir -p "$MX"
cat > "$MX/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Slug | Topic | Iniciado | Goal | Context | Notas |
|---|---|---|---|---|---|
| [[research/x-activo]] | Tema Activo X | 2026-05-01 | meta del research | dato de contexto | nota libre |

## Completed Research

| Slug | Topic | Hallazgo clave |
|---|---|---|
| [[research/x-completo]] | Tema Completo X | hallazgo final X |

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MX" --apply)
check "X active_header_rewritten=si" "$(campo "$OUT" active_header_rewritten)" "active_header_rewritten=si"
check "X active_rows_migrated=1" "$(campo "$OUT" active_rows_migrated)" "active_rows_migrated=1"
check "X completed_header_rewritten=si" "$(campo "$OUT" completed_header_rewritten)" "completed_header_rewritten=si"
check "X completed_rows_migrated=1" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=1"
check "X: Iniciado/Goal/Context/Notas anexados al Archivo, Next step/Origen vacios" \
  "$(grep -c '^| Tema Activo X |  |  | \[\[research/x-activo\]\] — Iniciado: 2026-05-01; Goal: meta del research; Context: dato de contexto; Notas: nota libre |$' "$MX/_research-index.md")" "1"
check "X: Hallazgo clave migro a Resultado" \
  "$(grep -c '^| Tema Completo X | hallazgo final X | \[\[research/x-completo\]\] |$' "$MX/_research-index.md")" "1"
OUT2=$(python3 "$BIN/journal-emit.py" --type research.upsert --memory-dir "$MX" --slug x-nuevo \
  --tema "X nuevo" --status completed --resultado "r" 2>&1 && python3 "$BIN/journal-compact.py" --memory-dir "$MX" 2>&1)
check "X: tras migrar, un research.upsert real entra sin cuarentena" "$(echo "$OUT2" | grep -c 'quarantined=0')" "1"

echo "X2. tabla lenient-canonica (ultima columna File) con 'Outcome' fuera de ROLE_ALIAS y filas REALES (adversario en Opus encontro una asi, no nombrada en el pendiente original): expuesta HOY a escritura por posicion, cerrada por este ciclo"
MX2="$TMP/mx2/memory"; mkdir -p "$MX2"
cat > "$MX2/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Completed Research

| Topic | Completed | Outcome | File |
|---|---|---|---|
| Hallazgo uno | 2026-06-13 | primer hallazgo real, con detalle tecnico | [[research/x2-uno]] |
| Hallazgo dos | 2026-06-09 | segundo hallazgo, causa raiz distinta | [[research/x2-dos]] |

## Active Research

| Topic | Started | Status | File |
|---|---|---|---|

## Related
EOF
check "X2: ANTES de migrar, ya era lenient-canonica (research_table_is_canonical vía journal-compact.py)" \
  "$(python3 -c "
import importlib.util, sys
# La ruta va por argv, no dentro del codigo: en Git Bash (Windows) MSYS convierte los argumentos
# que parecen rutas, pero no el texto de un -c, y Python leia '/d/a/...' como 'D:\\d/a/...'.
spec = importlib.util.spec_from_file_location('jc', sys.argv[1])
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
print(jc.research_table_is_canonical('| Topic | Completed | Outcome | File |'))
" "$BIN/journal-compact.py")" "True"
OUT=$(python3 "$BIN/repair-research-index.py" "$MX2" --apply)
check "X2 completed_header_unrecognized=0 (Outcome ahora reconocido)" "$(campo "$OUT" completed_header_unrecognized)" "completed_header_unrecognized=0"
check "X2 completed_rows_migrated=2 (las 2 filas reales migran, ninguna se pierde)" "$(campo "$OUT" completed_rows_migrated)" "completed_rows_migrated=2"
check "X2: Outcome migro a Resultado sin perder texto, Completed se anexo al Archivo" \
  "$(grep -c '^| Hallazgo uno | primer hallazgo real, con detalle tecnico | \[\[research/x2-uno\]\] — Completed: 2026-06-13 |$' "$MX2/_research-index.md")" "1"
check "X2: la segunda fila tambien migro completa" \
  "$(grep -c '^| Hallazgo dos | segundo hallazgo, causa raiz distinta | \[\[research/x2-dos\]\] — Completed: 2026-06-09 |$' "$MX2/_research-index.md")" "1"

echo "Y. 'Research' NO se agrega a ROLE_ALIAS: significa tema en una instalacion y archivo en otra (ambiguo), se queda header_unrecognized en ambas formas"
MY="$TMP/my/memory"; mkdir -p "$MY"
cat > "$MY/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Research | Slug | Iniciado |
|---|---|---|
| Tema con Research=tema | [[research/y-a]] | 2026-05-01 |

## Completed Research

| Research | Fecha | Resultado |
|---|---|---|
| [[research/y-b]] | 2026-05-01 | Research=archivo aqui, texto libre |

## Related
EOF
cp "$MY/_research-index.md" "$MY/_research-index.md.antes"
OUT=$(python3 "$BIN/repair-research-index.py" "$MY" --apply)
check "Y active_header_unrecognized=1 (Research ambiguo, no se adivina)" "$(campo "$OUT" active_header_unrecognized)" "active_header_unrecognized=1"
check "Y completed_header_unrecognized=1 (Research ambiguo, no se adivina)" "$(campo "$OUT" completed_header_unrecognized)" "completed_header_unrecognized=1"
check "Y: el archivo quedo BYTE IGUAL (ninguna fila de datos se toco, no solo la cabecera)" \
  "$(cmp -s "$MY/_research-index.md" "$MY/_research-index.md.antes" && echo igual)" "igual"

echo "Y2. 'Session' NO se agrega a archivo por el mismo motivo: sostiene el wikilink en una instalacion, es metadata en otras — se queda header_unrecognized"
MY2="$TMP/my2/memory"; mkdir -p "$MY2"
cat > "$MY2/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | File | Session |
|---|---|---|
| Investigacion con Session=metadata | [[research/y2-a]] | sesion de origen |

## Completed Research

| Topic | Result | Session |
|---|---|---|
| Investigacion completada | hallazgo con Session=archivo aqui | [[research/y2-b]] |

## Related
EOF
cp "$MY2/_research-index.md" "$MY2/_research-index.md.antes"
OUT=$(python3 "$BIN/repair-research-index.py" "$MY2" --apply)
check "Y2 active_header_unrecognized=0 (Topic/File/Session YA reconocidos: Session=extra es correcto aqui)" "$(campo "$OUT" active_header_unrecognized)" "active_header_unrecognized=0"
check "Y2 completed_header_unrecognized=1 (Session sosteniendo el wikilink: sin columna archivo, no se adivina)" "$(campo "$OUT" completed_header_unrecognized)" "completed_header_unrecognized=1"
check "Y2: la fila Completed (donde Session=archivo) quedo intacta" \
  "$(grep -c '^| Investigacion completada | hallazgo con Session=archivo aqui | \[\[research/y2-b\]\] |$' "$MY2/_research-index.md")" "1"

echo "Z. Tabla lenient-canonica (ultima columna File) pero VACIA, con 'Finding' antes fuera de ROLE_ALIAS: se re-cabecea sin filas que migrar"
MZ="$TMP/mz/memory"; mkdir -p "$MZ"
cat > "$MZ/_research-index.md" <<'EOF'
---
type: index
---
# Research Index

## Active Research

| Topic | Finding | File |
|---|---|---|

## Completed Research

| Tema | Resultado | Archivo |
|---|---|---|

## Related
EOF
OUT=$(python3 "$BIN/repair-research-index.py" "$MZ" --apply)
check "Z active_header_rewritten=si (antes lenient pero fuera de orden, ahora canonica)" "$(campo "$OUT" active_header_rewritten)" "active_header_rewritten=si"
check "Z active_rows_migrated=0 (tabla vacia, nada que migrar)" "$(campo "$OUT" active_rows_migrated)" "active_rows_migrated=0"
check "Z: cabecera canonica de Active tras el re-cabeceo" \
  "$(grep -c '^| Tema | Next step | Origen | Archivo |$' "$MZ/_research-index.md")" "1"
OUT2=$(python3 "$BIN/journal-emit.py" --type research.upsert --memory-dir "$MZ" --slug z-nuevo \
  --tema "Z nuevo" --status active --next-step "paso" 2>&1 && python3 "$BIN/journal-compact.py" --memory-dir "$MZ" 2>&1)
check "Z: tras re-cabecear, un research.upsert activo entra sin cuarentena ni columnas cruzadas" "$(echo "$OUT2" | grep -c 'quarantined=0')" "1"
check "Z: la fila nueva entra con 4 celdas limpias (no 3 de la cabecera vieja)" \
  "$(grep -c '^| Z nuevo | paso |  | \[\[research/z-nuevo\]\] |$' "$MZ/_research-index.md")" "1"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
