#!/bin/bash
# Prueba de `learning.patch`, de `learning.retire` sobre reglas que rewrite_rule no puede reescribir y
# de la linea en blanco de insert_at_section_end (2.68.0).
#
# Por que existe: hasta 2.67 una regla que rewrite_rule ponia en cuarentena (anterior,
# bloque-multilinea, codigo-antes) no tenia via por el journal: ni corregirla ni retirarla. En los
# learnings de 25 proyectos (2026-10-28) eran 2419 de 9183 reglas numeradas. Y learning.add fabricaba
# la forma `anterior` al pegar la regla nueva a un parrafo. Lo que este fichero vigila:
#
# 1. LA VIA EXISTE para los tres motivos: el fichero cambia SOLO en el trozo, byte a byte.
# 2. REPLAY = NOOP (I3), tambien cuando --nuevo contiene a --viejo o cambia el propio prefijo.
# 3. LAS GUARDIAS, al emitir y al compactar (un evento escrito a mano): saltos de linea, vallas,
#    comentarios HTML, la marca, --nuevo dentro de --viejo, trozo ausente o repetido, trozo dentro de
#    la marca o de los disparadores, comillas invertidas sueltas. Una cuarentena no escribe nada.
# 4. RETIRE en una regla bloqueada: marca solo la primera linea; el recall deja de servirla.
# 5. insert_at_section_end deja la regla nueva como item, no como continuacion de un parrafo.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }

M="$T/memory"
G="$M/learnings/gate.md"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" --quiet >/dev/null 2>&1 || true; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
pend() { ls "$M/.journal/pending" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
motivo() { cat "$M/.journal/quarantine"/*.reason 2>/dev/null | tr '\n' ' '; }
replay() { cp "$M"/.journal/applied/*/*.json "$M/.journal/pending/"; }
huella() { cat "$G" "$M/_learnings.md" | cksum; }
linea() { grep -E "^$1\. " "$G" || true; }
# Motivo de rewrite_rule para la regla N del topic (o "ok").
bloqueo() {
  python3 - "$BIN" "$G" "$1" <<'PY'
import sys, importlib.util, re
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("jc", sys.argv[1] + "/journal-compact.py")
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
lines = jc.read_lines(sys.argv[2]); s, e = jc.body_region(lines)
i = next(i for i in range(s, e) if lines[i].startswith(sys.argv[3] + ". "))
print(jc.regla_reescribible(lines, i, e) or "ok")
PY
}
# Diferencia entre dos ficheros: "linea N: <vieja> => <nueva>" si solo cambia una linea, si no "otra".
difiere() {
  python3 - "$1" "$2" <<'PY'
import sys
a = open(sys.argv[1], encoding="utf-8").read().split("\n")
b = open(sys.argv[2], encoding="utf-8").read().split("\n")
d = [i for i in range(max(len(a), len(b))) if i >= len(a) or i >= len(b) or a[i] != b[i]]
print(f"{a[d[0]]} => {b[d[0]]}" if len(a) == len(b) and len(d) == 1 else f"otra ({len(d)} lineas, {len(a)} vs {len(b)})")
PY
}
# Sin `updated:` en el frontmatter: bump_updated no cambia nada que la comparacion tenga que excluir.
fixture() {
  rm -rf "$M"; mkdir -p "$M/learnings"
  : > "$M/_pendientes.md"
  cat > "$M/_learnings.md" <<'IDX'
# Learnings Index

## Topic Files

| Topic | File | When to consult |
|---|---|---|
| Gate | [[learnings/gate]] | antes de empujar |

## Quick Reference

1. **Uno corto** — a
2. **Dos corto** — cita #8505 <!-- regla: gate#2 -->

## Related
IDX
  cat > "$G" <<'TOP'
# Gate

## Reglas

1. **Uno multilinea** — cita #8505 aqui
   sigue el item con #8505
Origen: un parrafo
2. **Dos anterior** — cita #8505 tambien
3. **Tres anterior** — con `codigo` y #8505 y #8505
6. **Seis anterior** — con `codigo` y #8505

## Codigo

```bash
echo "#8505"
```

4. **Cuatro tras valla** — cita #8505 al final <!-- disparadores: frases=uno dos | tres cuatro | cinco seis -->
5. **Cinco retirada** — vieja #8505 — ⊘ RETIRADA (2026-01-01, obsoleta)

## Related
TOP
}

echo "== 0. linea base: los tres motivos, y learning.update va a cuarentena =="
fixture
chk "regla 1: bloque-multilinea" "bloque-multilinea" "$(bloqueo 1)"
chk "regla 2: anterior" "anterior" "$(bloqueo 2)"
chk "regla 4: codigo-antes" "codigo-antes" "$(bloqueo 4)"
H=$(huella)
emit --type learning.update --topic gate --match-prefix "Dos anterior" --text "**Dos anterior** — cita #6740 tambien" >/dev/null
compact
chk "update de la 2: cuarentena y nada escrito" "1|$H" "$(cuar)|$(huella)"
has "el motivo nombra learning.patch" "$(motivo)" "learning.patch --viejo/--nuevo"

echo "== 1. learning.patch en los tres motivos: solo cambia el trozo =="
for caso in "1|Uno multilinea|1. **Uno multilinea** — cita #6740 aqui" \
            "2|Dos anterior|2. **Dos anterior** — cita #6740 tambien" \
            "4|Cuatro tras valla|4. **Cuatro tras valla** — cita #6740 al final <!-- disparadores: frases=uno dos | tres cuatro | cinco seis -->"; do
  n=${caso%%|*}; r=${caso#*|}; pre=${r%%|*}; esperada=${r#*|}
  fixture; cp "$G" "$T/antes.md"
  emit --type learning.patch --topic gate --match-prefix "$pre" --viejo "#8505" --nuevo "#6740" >/dev/null
  compact
  chk "regla $n: sin cuarentena" "0" "$(cuar)"
  chk "regla $n: el fichero difiere solo en esa linea y solo en el trozo" \
    "$(grep -E "^$n\. " "$T/antes.md") => $esperada" "$(difiere "$T/antes.md" "$G")"
  H=$(huella); replay; compact
  chk "regla $n: replay noop, sin cuarentena" "$H|0" "$(huella)|$(cuar)"
done
fixture; cp "$G" "$T/antes.md"
emit --type learning.patch --topic gate --match-prefix "Uno multilinea" --viejo "#8505" --nuevo "#6740" >/dev/null
compact
chk "regla 1: la continuacion (que tambien dice #8505) no se toca" "   sigue el item con #8505" "$(sed -n '6p' "$G")"

echo "== 2. replay cuando --nuevo contiene a --viejo, y cuando el parche cambia el prefijo =="
fixture
emit --type learning.patch --topic gate --match-prefix "Dos anterior" --viejo "#8505" --nuevo "#8505 y #6740" >/dev/null
compact
chk "la 2 dice los dos numeros" "2. **Dos anterior** — cita #8505 y #6740 tambien|0" "$(linea 2)|$(cuar)"
H=$(huella); replay; compact
chk "replay: noop (no escribe '#8505 y #6740 y #6740')" "$H|0" "$(huella)|$(cuar)"
fixture
emit --type learning.patch --topic gate --match-prefix "Dos anterior" --viejo "Dos anterior" --nuevo "Dos ya no anterior" >/dev/null
compact
chk "el parche cambia el prefijo del ancla" "2. **Dos ya no anterior** — cita #8505 tambien|0" "$(linea 2)|$(cuar)"
H=$(huella); replay; compact
chk "replay con el prefijo ya cambiado: noop, sin cuarentena" "$H|0" "$(huella)|$(cuar)"

echo "== 3. guardias al emitir: sale 1 y no escribe evento =="
fixture
nok() {  # nok <descripcion> <args...>: el emisor tiene que negarse
  local d=$1; shift
  if emit "$@" >/dev/null 2>"$T/err"; then fail=$((fail+1)); echo "  FALLA $d: el emisor acepto"; else pass=$((pass+1)); echo "  ok  $d"; fi
}
P=(--type learning.patch --topic gate --match-prefix "Dos anterior")
nok "salto de linea en --nuevo" "${P[@]}" --viejo "#8505" --nuevo $'#67\n40'
nok "retorno de carro en --viejo" "${P[@]}" --viejo $'#8505\r' --nuevo "#6740"
nok "valla de comillas en --nuevo" "${P[@]}" --viejo "#8505" --nuevo '```x'
nok "valla de virgulillas en --nuevo" "${P[@]}" --viejo "#8505" --nuevo "~~~x"
nok "comentario HTML en --nuevo" "${P[@]}" --viejo "#8505" --nuevo "<!-- x"
nok "cierre de comentario en --viejo" "${P[@]}" --viejo "-->" --nuevo "#6740"
nok "simbolo de la marca en --nuevo" "${P[@]}" --viejo "#8505" --nuevo "⊘ #6740"
nok "--nuevo dentro de --viejo" "${P[@]}" --viejo "#8505 tambien" --nuevo "#8505"
nok "--nuevo vacio" "${P[@]}" --viejo "#8505" --nuevo ""
nok "sin --nuevo" "${P[@]}" --viejo "#8505"
nok "trozo ausente" "${P[@]}" --viejo "#9999" --nuevo "#6740"
nok "trozo repetido en la primera linea" --type learning.patch --topic gate --match-prefix "Tres anterior" --viejo "#8505" --nuevo "#6740"
nok "trozo dentro de la marca de retirada" --type learning.patch --topic gate --match-prefix "Cinco retirada" --viejo "obsoleta" --nuevo "duplicada"
nok "trozo dentro de los disparadores" --type learning.patch --topic gate --match-prefix "Cuatro tras valla" --viejo "frases=uno" --nuevo "frases=otro"
nok "comilla invertida suelta en --nuevo" "${P[@]}" --viejo "#8505" --nuevo '`#6740'
nok "comilla que deja suelta la de \`codigo\`" --type learning.patch --topic gate --match-prefix "Seis anterior" --viejo "con \`codigo\`" --nuevo "con codigo\` x"
nok "prefijo que no casa" --type learning.patch --topic gate --match-prefix "No existe" --viejo "#8505" --nuevo "#6740"
nok "--match-prefix y --quickref-prefix a la vez" "${P[@]}" --quickref-prefix "Dos corto" --viejo "#8505" --nuevo "#6740"
nok "--match-prefix sin --topic" --type learning.patch --match-prefix "Dos anterior" --viejo "#8505" --nuevo "#6740"
chk "ningun evento escrito" "0" "$(pend)"

echo "== 4. guardias al compactar (evento escrito a mano): cuarentena y nada escrito =="
amano() {  # amano <descripcion> <motivo esperado> <python que cambia el payload p>
  fixture; H=$(huella)
  emit --type learning.patch --topic gate --match-prefix "Dos anterior" --viejo "#8505" --nuevo "#6740" >/dev/null
  python3 - "$M/.journal/pending" "$3" <<'PY'
import sys, json, glob
f = glob.glob(sys.argv[1] + "/*.json")[0]
ev = json.load(open(f, encoding="utf-8")); p = ev["payload"]
exec(sys.argv[2])
json.dump(ev, open(f, "w", encoding="utf-8"), ensure_ascii=False)
PY
  compact
  chk "$1: cuarentena y nada escrito" "1|$H" "$(cuar)|$(huella)"
  has "$1: motivo" "$(motivo)" "$2"
}
amano "salto de linea" "malformed: learning.patch" 'p["nuevo"] = "#67\n40"'
amano "valla" "malformed: learning.patch" 'p["nuevo"] = "```"'
amano "comentario HTML" "malformed: learning.patch" 'p["viejo"] = "<!-- x"'
amano "marca" "malformed: learning.patch" 'p["nuevo"] = "⊘"'
amano "--nuevo dentro de --viejo" "malformed: learning.patch con 'nuevo' dentro" 'p["viejo"] = "#8505 tambien"; p["nuevo"] = "#8505"'
amano "sin ancla" "malformed: learning.patch necesita" 'p["match_prefix"] = ""'
amano "trozo ausente" "no-anchor" 'p["viejo"] = "#9999"'
amano "trozo repetido" "no-anchor" 'p["match_prefix"] = "Tres anterior"'
amano "trozo en la marca" "no-anchor" 'p["match_prefix"] = "Cinco retirada"; p["viejo"] = "obsoleta"; p["nuevo"] = "duplicada"'
amano "comilla suelta" "primera-linea" 'p["nuevo"] = "`#6740"'
amano "texto que empezaria por espacio" "primera-linea" 'p["viejo"] = "**Dos"; p["nuevo"] = " **Dos"'

echo "== 5. learning.patch en el Quick Reference =="
fixture
emit --type learning.patch --quickref-prefix "Dos corto" --viejo "#8505" --nuevo "#6740" >/dev/null
compact
chk "la linea cambia y conserva la marca de enlace" "2. **Dos corto** — cita #6740 <!-- regla: gate#2 -->|0" \
  "$(grep -E '^2\. ' "$M/_learnings.md")|$(cuar)"
H=$(huella); replay; compact
chk "replay: noop" "$H|0" "$(huella)|$(cuar)"
fixture
nok "trozo dentro de la marca de enlace" --type learning.patch --quickref-prefix "Dos corto" --viejo "gate#2" --nuevo "gate#3"

echo "== 6. learning.retire en reglas bloqueadas: marca solo la primera linea =="
for caso in "1|Uno multilinea" "2|Dos anterior" "4|Cuatro tras valla"; do
  n=${caso%%|*}; pre=${caso#*|}
  fixture; cp "$G" "$T/antes.md"
  emit --type learning.retire --topic gate --match-prefix "$pre" --motivo obsoleta --nota "ya no aplica" >/dev/null
  compact
  chk "regla $n: sin cuarentena" "0" "$(cuar)"
  python3 "$BIN/build-recall-index.py" "$M" "$T/idx.jsonl" >/dev/null
  chk "regla $n: el recall no la sirve" "0" "$(grep -c -- "$pre" "$T/idx.jsonl" | tr -d ' ')"
  H=$(huella); replay; compact
  chk "regla $n: replay noop" "$H|0" "$(huella)|$(cuar)"
done
fixture; cp "$G" "$T/antes.md"
emit --type learning.retire --topic gate --match-prefix "Cuatro tras valla" --motivo obsoleta >/dev/null
compact
HOY=$(date +%F)
chk "la marca va delante de los disparadores; el resto del fichero igual" \
  "4. **Cuatro tras valla** — cita #8505 al final <!-- disparadores: frases=uno dos | tres cuatro | cinco seis --> => 4. **Cuatro tras valla** — cita #8505 al final — ⊘ RETIRADA ($HOY, obsoleta) <!-- disparadores: frases=uno dos | tres cuatro | cinco seis -->" \
  "$(difiere "$T/antes.md" "$G")"
fixture; cp "$G" "$T/antes.md"
emit --type learning.retire --topic gate --match-prefix "Uno multilinea" --motivo obsoleta >/dev/null
compact
chk "multilinea: cambia solo la primera linea" \
  "1. **Uno multilinea** — cita #8505 aqui => 1. **Uno multilinea** — cita #8505 aqui — ⊘ RETIRADA ($HOY, obsoleta)" \
  "$(difiere "$T/antes.md" "$G")"
fixture; H=$(huella)
emit --type learning.retire --topic gate --match-prefix "Dos anterior" --motivo obsoleta --nota 'por `x' >/dev/null
compact
chk "nota con una comilla suelta en regla bloqueada: cuarentena, nada escrito" "1|$H" "$(cuar)|$(huella)"
has "motivo primera-linea" "$(motivo)" "primera-linea"
fixture; H=$(huella)
emit --type learning.retire --topic gate --match-prefix "Dos anterior" --motivo obsoleta --nota 'ver ```' >/dev/null
compact
chk "nota con valla en regla bloqueada: cuarentena, nada escrito" "1|$H" "$(cuar)|$(huella)"
fixture; H=$(huella)
emit --type learning.retire --topic gate --match-prefix "Dos anterior" --motivo obsoleta \
  --nota '<!-- disparadores: frases=a b | c d | e f -->' >/dev/null
compact
chk "nota que inyectaria disparadores: cuarentena, nada escrito" "1|$H" "$(cuar)|$(huella)"
has "motivo: la nota" "$(motivo)" "primera-linea: en learnings/gate.md, la nota lleva"

echo "== 6b. comprobar_primera_linea, la segunda capa (las guardias del trozo ya filtran antes) =="
# El programa va a un fichero: dentro de $( ) bash no deja pasar las comillas invertidas del heredoc.
cat > "$T/capa.py" <<'PY'
import sys, importlib.util
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("jc", sys.argv[1] + "/journal-compact.py")
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
D = " <!-- disparadores: frases=a b | c d | e f -->"
M = " — ⊘ RETIRADA (2026-01-01, obsoleta)"
casos = [
    ("disparadores perdidos", "2. **R** — x" + D, "2. **R** — y", False),
    ("disparadores metidos en codigo", "2. **R** — `x` y" + D, "2. **R** — `x y" + D + "`", False),
    ("marca cambiada", "2. **R** — x" + M, "2. **R** — x — ⊘ RETIRADA (2026-01-02, obsoleta)", False),
    ("marca escondida en codigo", "2. **R** — `x", "2. **R** — `x" + M + "`", True),
    ("retira sin marca", "2. **R** — x", "2. **R** — x y", True),
    ("numero cambiado", "2. **R** — x", "3. **R** — x", False),
]
for nombre, a, b, retira in casos:
    try:
        jc.comprobar_primera_linea(a, b, "t", retira)
        print(f"{nombre}=paso")
    except jc.Quarantine:
        print(f"{nombre}=cuarentena")
try:
    jc.comprobar_primera_linea("2. **R** — x" + D, "2. **R** — y" + D, "t", False)
    print("control=paso")
except jc.Quarantine as e:
    print(f"control=cuarentena {e}")
PY
R=$(python3 "$T/capa.py" "$BIN")
for c in "disparadores perdidos" "disparadores metidos en codigo" "marca cambiada" "marca escondida en codigo" \
         "retira sin marca" "numero cambiado"; do
  has "$c: cuarentena" "$R" "$c=cuarentena"
done
has "control (solo cambia el texto): pasa" "$R" "control=paso"

echo "== 7. insert_at_section_end: la regla nueva no queda pegada a un parrafo =="
fixture
cat > "$G" <<'TOP'
# Gate

## Reglas

1. **Uno** — a
Origen: un parrafo pegado

## Related
TOP
emit --type learning.add --topic gate --text "**Nueva tras parrafo** — b" >/dev/null
compact
chk "la 2 entra, y es reescribible (no anterior)" "2. **Nueva tras parrafo** — b|ok|0" "$(linea 2)|$(bloqueo 2)|$(cuar)"
chk "con una linea en blanco antes" "" "$(sed -n "$(( $(grep -n '^2\. ' "$G" | cut -d: -f1) - 1 ))p" "$G")"
cat > "$G" <<'TOP'
# Gate

## Reglas

1. **Uno** — a

## Related
TOP
emit --type learning.add --topic gate --text "**Nueva tras regla** — b" >/dev/null
compact
chk "tras otra regla de la misma familia: pegada, sin linea en blanco" "1. **Uno** — a|2. **Nueva tras regla** — b" \
  "$(sed -n '5,6p' "$G" | paste -sd'|' -)"
cat > "$G" <<'TOP'
# Gate

## Reglas

- vineta suelta

## Related
TOP
emit --type learning.add --topic gate --section "## Reglas" --text "**Tras vineta** — c" >/dev/null
compact
chk "tras una vineta de otra familia: tampoco queda como continuacion" "0" "$(cuar)"
N=$(grep -n 'Tras vineta' "$G" | cut -d: -f1)
chk "y su regla es reescribible" "ok" "$(python3 - "$BIN" "$G" "$N" <<'PY'
import sys, importlib.util
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("jc", sys.argv[1] + "/journal-compact.py")
jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
lines = jc.read_lines(sys.argv[2]); s, e = jc.body_region(lines)
print(jc.regla_reescribible(lines, int(sys.argv[3]) - 1, e) or "ok")
PY
)"

echo
echo "test-learning-patch: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
