#!/bin/bash
# Prueba de consolidate-aviso.py y de su linea en session-start.sh (F6, 2.50.0).
#
# Lo que defiende:
#   1. el aviso de crecimiento sale con 15 reglas o mas desde la ultima /consolidate-3t y se calla
#      con 14; sin estado cuenta desde 0 (decision de Victor, 2026-10-06);
#   2. el crecimiento se cuenta por el NUMERO mas alto: retirar reglas no lo esconde;
#   3. un estado roto (JSON invalido, tipos raros) vale como "sin estado": avisa, no se calla;
#   4. H11: una regla viva cuyo TITULO dice que corrige a otra avisa; la misma frase en el cuerpo
#      no; y el flujo correcto (learning.update de la original + learning.retire de la correctora
#      superada por la original) por el journal real la calla sin cuarentena;
#   5. --pares saca los pares fuertes de un topic y no cuenta una retirada;
#   6. session-start.sh lleva la linea a los dos canales, solo si hay algo, y no en Paperclip;
#   7. --aviso nunca rompe el arranque: sin memory/ o con un fallo, sale 0 y calla.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0; skip=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then fail=$((fail+1)); echo "  FALLA $1: no esperaba '$3' en '$2'"; else pass=$((pass+1)); echo "  ok  $1"; fi; }

M="$T/memory"
aviso() { python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --aviso | tr -d '\r'; }
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }

# topic con N reglas numeradas 1..N (texto distinto en cada una, para que no salgan pares)
topic() {  # $1 nombre, $2 N
  local f="$M/learnings/$1.md" i
  { printf -- '---\ntype: learnings\ntopic: %s\nupdated: 2026-01-01\n---\n# %s\n\n## Rules\n\n' "$1" "$1"
    for i in $(seq 1 "$2"); do printf '%s. **Regla %s de %s** — palabra%s distinta%s cosa%s\n' "$i" "$i" "$1" "$i" "$i" "$i"; done
    printf '\n## Related\n- [[_learnings|Learnings Index]]\n'; } > "$f"
}
# anade una linea al cuerpo del topic, antes de '## Related' (despues no es una regla: el
# compactador y el recall solo miran el cuerpo)
regla() {  # $1 topic, $2 linea
  python3 - "$M/learnings/$1.md" "$2" <<'PY'
import sys
p, linea = sys.argv[1], sys.argv[2]
with open(p, encoding="utf-8") as fh:
    ls = fh.read().split("\n")
i = ls.index("## Related")
while i > 0 and ls[i - 1] == "":
    i -= 1
ls.insert(i, linea)
with open(p, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(ls))
PY
}
fixture() {
  rm -rf "$M"; mkdir -p "$M/learnings"
  cat > "$M/_learnings.md" <<'IDX'
---
type: index
updated: 2026-01-01
---
# Learnings Index

## Topic Files

| Topic | File | When to consult |
|---|---|---|
| Uno | [[learnings/uno]] | siempre |

## Quick Reference

1. **Primera** — corta

## Related
IDX
}

echo "== 1. crecimiento: 14 calla, 15 avisa; sin estado cuenta desde 0 =="
fixture; topic uno 14
chk "14 reglas sin estado: calla" "" "$(aviso)"
topic uno 15
has "15 reglas sin estado: avisa" "$(aviso)" "learnings/uno.md crecio 15 reglas y nunca se consolido"
has "nombra el comando" "$(aviso)" "Corre /consolidate-3t."

echo "== 2. --guardar-estado calla; 14 mas calla; 15 mas avisa 'desde la ultima' =="
python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --guardar-estado >/dev/null
chk "estado guardado: numero mas alto de uno" "15" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["topics"]["uno"])' "$M/.consolidate-state.json")"
chk "tras guardar: calla" "" "$(aviso)"
topic uno 29
chk "+14: calla" "" "$(aviso)"
topic uno 30
has "+15: avisa desde la ultima" "$(aviso)" "crecio 15 reglas desde la ultima /consolidate-3t"

echo "== 3. retirar reglas no esconde el crecimiento (cuenta el numero mas alto) =="
for n in 20 21 22 23 24 25; do
  sed -i.bak "s/^$n\. \(.*\)$/$n. \1 — ⊘ RETIRADA (2026-10-06, obsoleta): prueba/" "$M/learnings/uno.md"
done
rm -f "$M/learnings/uno.md.bak"
has "6 retiradas, sigue avisando +15" "$(aviso)" "crecio 15 reglas"

echo "== 4. estado roto vale como sin estado: avisa =="
for roto in 'no es json' '[]' '{"topics": []}' '{"topics": {"uno": "15"}}' '{"topics": {"uno": true}}' '{"topics": {"uno": -3}}'; do
  printf '%s' "$roto" > "$M/.consolidate-state.json"
  has "estado '$roto': avisa desde 0" "$(aviso)" "crecio 30 reglas y nunca se consolido"
done
rm -f "$M/.consolidate-state.json"

echo "== 5. archivados fuera; topic de vinetas cuenta vinetas =="
fixture
topic uno 3
cp "$M/learnings/uno.md" "$M/learnings/viejo.archived.md"; topic viejo.archived 40
{ printf -- '---\ntype: learnings\n---\n# Vinetas\n\n'; for i in $(seq 1 16); do printf -- '- **Vineta %s** — cosa%s\n' "$i" "$i"; done; } > "$M/learnings/vinetas.md"
A=$(aviso)
hasnt "un .archived.md no cuenta" "$A" "viejo"
has "16 vinetas sin numerar avisan" "$A" "learnings/vinetas.md crecio 16"
# Las vinetas de '## Related' son enlaces, no reglas (adversario, ronda 1: 15 reglas contaban 16)
{ printf -- '---\ntype: learnings\n---\n# Vinetas\n\n## Rules\n\n'; for i in $(seq 1 15); do printf -- '- **Vineta %s** — cosa%s\n' "$i" "$i"; done
  printf -- '\n## Related\n- [[_learnings|Learnings Index]]\n'; } > "$M/learnings/vinetas.md"
has "15 vinetas + 1 de Related: cuenta 15" "$(aviso)" "learnings/vinetas.md crecio 15"
regla vinetas '- **Compactar antes de leer los indices** — corre journal-compact antes de leer _pendientes'
regla vinetas '- **Compactar antes de leer los indices** — corre journal-compact antes de leer _learnings'
P=$(python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --pares)
has "un par de vinetas se nombra por su orden" "$P" '"a": "vinetas#v16"'
has "y la otra con el suyo" "$P" '"b": "vinetas#v17"'

echo "== 6. H11: titulo avisa, cuerpo no, retirada no =="
fixture; topic uno 3
regla uno '4. **Corrige regla 2: la cosa dos era al reves** — detalle'
regla uno '5. **Otra regla** — esta corrige regla 3 en el cuerpo, no en el titulo'
regla uno '6. **CORREGIDO el 2026-09-21: la tres tambien** — detalle'
regla uno '7. **Correccion de la regla 1: otra forma** — detalle'
regla uno '8. **Corregido a medias** — minusculas: no es la forma'
regla uno '9. **Corrige regla 1: retirada ya** — x — ⊘ RETIRADA (2026-10-06, superada por #1): ya'
# La lista completa sale del --json: la linea del aviso recorta a 3 ("…"), y un "no avisa X"
# mirado sobre una lista recortada pasaria sin mirar nada (lo destapo mutation-check).
H=$(python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --json | python3 -c 'import json,sys; print(" ".join(f"{x["topic"]}#{x["regla"]}" for x in json.load(sys.stdin)["h11"]))')
chk "h11 exactamente 4, 6 y 7" "uno#4 uno#6 uno#7" "$H"
has "titulo 'Corrige regla N' avisa" " $H " " uno#4 "
has "titulo 'CORREGIDO el' avisa" " $H " " uno#6 "
has "titulo 'Correccion de la regla N' avisa" " $H " " uno#7 "
hasnt "la frase en el cuerpo no avisa" " $H " " uno#5 "
hasnt "'Corregido' en minusculas no avisa" " $H " " uno#8 "
hasnt "una correctora ya retirada no avisa" " $H " " uno#9 "
A=$(aviso)
has "el aviso cuenta 3" "$A" "3 reglas que corrigen a otra siguen vivas (uno#4, uno#6, uno#7)"

echo "== 7. H11 de punta a punta por el journal: update de la original + retire de la correctora =="
fixture; topic uno 3
regla uno '4. **Corrige regla 2: la cosa dos era al reves** — la regla 2 decia lo contrario'
has "antes: avisa uno#4" "$(aviso)" "uno#4"
emit --type learning.update --topic uno --match-prefix "**Regla 2 de uno**" \
  --text "**Regla 2 de uno, corregida** — palabra2 al reves (corregida por el journal)" >/dev/null
emit --type learning.retire --topic uno --match-prefix "**Corrige regla 2" \
  --motivo superada --por 2 --nota "correccion incorporada a #2" >/dev/null
OUT=$(compact 2>&1)
has "compacta sin cuarentena" "$OUT" "quarantined=0"
chk "cuarentena vacia" "0" "$(cuar)"
has "la 2 lleva el texto nuevo y su numero" "$(cat "$M/learnings/uno.md")" "2. **Regla 2 de uno, corregida**"
has "la 4 retirada superada por #2" "$(grep '^4\. ' "$M/learnings/uno.md")" "⊘ RETIRADA ("
has "la 4 dice por #2" "$(grep '^4\. ' "$M/learnings/uno.md")" "superada por #2)"
chk "despues: el aviso calla" "" "$(aviso)"

echo "== 8. --pares: un par casi literal sale; con una retirada, no =="
fixture; topic uno 3
regla uno '4. **Compactar antes de leer los indices** — corre journal-compact antes de leer _pendientes'
regla uno '5. **Compactar antes de leer los indices** — corre journal-compact antes de leer _learnings'
P=$(python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --pares)
has "par 4/5 sale" "$P" '"b": "uno#5"'
chk "solo ese par" "1" "$(printf '%s' "$P" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["pares"]))')"
sed -i.bak 's/^5\. \(.*\)$/5. \1 — ⊘ RETIRADA (2026-10-06, duplicada por #4): x/' "$M/learnings/uno.md"; rm -f "$M/learnings/uno.md.bak"
P=$(python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --pares)
chk "con la 5 retirada: 0 pares" "0" "$(printf '%s' "$P" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["pares"]))')"
J=$(python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --json)
has "--json trae las tres senales" "$J" '"crecimiento"'
has "--json trae h11" "$J" '"h11"'

echo "== 9. --aviso no rompe nunca: sin memory/, sin learnings/, con un topic ilegible =="
chk "memory inexistente: sale 0" "0" "$(python3 "$BIN/consolidate-aviso.py" --memory-dir "$T/no-existe" --aviso >/dev/null 2>&1; echo $?)"
chk "memory inexistente: calla" "" "$(python3 "$BIN/consolidate-aviso.py" --memory-dir "$T/no-existe" --aviso 2>/dev/null)"
fixture; rmdir "$M/learnings"
chk "sin learnings/: calla" "" "$(aviso)"
fixture; topic uno 20; printf '\xff\xfe binario' >> "$M/learnings/uno.md"
has "bytes no UTF-8: avisa igual (errors=replace)" "$(aviso)" "crecio 20"
fixture; topic uno 20; chmod 000 "$M/learnings/uno.md"
if [ -r "$M/learnings/uno.md" ]; then
  # Windows (o root): chmod no quita la lectura, no hay fallo que provocar
  skip=$((skip+1)); echo "  SKIP aviso con un topic ilegible: chmod 000 no quita la lectura aqui"
else
  E=$(python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --aviso 2>&1); rc=$?
  chk "aviso con un topic ilegible: sale 0" "0" "$rc"
  hasnt "aviso con un topic ilegible: sin traceback" "$E" "Traceback"
fi
chmod 644 "$M/learnings/uno.md"

echo "== 10. session-start.sh: la linea va a los dos canales, solo si hay algo, no en Paperclip =="
P="$T/proj"; rm -rf "$P"; mkdir -p "$P"; M="$P/memory"; fixture; topic uno 20
# session-start.sh reconoce la memoria (Model B) por _pendientes.md
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Related\n' > "$M/_pendientes.md"
correr() { printf '%s' "{\"cwd\":\"$P\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | env "$@" CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" SKIP_CMD_INSTALL=1 bash "$BIN/session-start.sh" 2>/dev/null; }
campo() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hookSpecificOutput",{}).get("additionalContext","") if sys.argv[1]=="a" else d.get("systemMessage",""))' "$1"; }
S=$(correr X=1)
has "agente: la linea" "$(printf '%s' "$S" | campo a)" "CONSOLIDAR: learnings/uno.md crecio 20"
has "persona: la linea" "$(printf '%s' "$S" | campo h)" "CONSOLIDAR: learnings/uno.md crecio 20"
python3 "$BIN/consolidate-aviso.py" --memory-dir "$M" --guardar-estado >/dev/null
S=$(correr X=1)
hasnt "con estado al dia: no hay linea" "$(printf '%s' "$S" | campo a)" "CONSOLIDAR"
rm -f "$M/.consolidate-state.json"
S=$(correr PAPERCLIP_RUN_ID=run-1)
hasnt "Paperclip: no hay linea" "$S" "CONSOLIDAR"

echo
echo "RESULT: pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
