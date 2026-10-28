#!/bin/bash
# Prueba de `snippet-vigente.py` / `snippet-vigente.sh` (UserPromptSubmit, 2.63.22).
#
# Que tiene que cumplir, y por que:
# - Auditoria del 2026-10-20: 4 de 5 snippets pegados que el agente llamo "viejos" lo eran, y en
#   los 4 bastaban dos señales de memory/: (A) el `p-…` del paso ya no esta abierto, o (B) una
#   ficha mas nueva que la citada ya lo retoma (Como retomar, sello `hilo_paso` o marca
#   `_retomar`). El pegado vigente de control no dispara nada: el caso 1 lo mide.
# - Solo actua sobre un prompt que EMPIEZA por un snippet; una mencion suelta no avisa.
# - Es un aviso de una o dos lineas: nunca bloquea (sale 0 siempre).
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proyecto"; M="$P/memory"
mkdir -p "$M/sessions" "$M/pendientes"
VIVO=p-aaaaaaaaaa; CERRADO=p-bbbbbbbbbb; NUEVO=p-cccccccccc; SELLADO=p-dddddddddd; MARCADO=p-eeeeeeeeee
MARCA_VIEJA=p-1212121212

cat > "$M/_pendientes.md" <<EOF
# Pendientes

## Alta prioridad

- [ ] Paso vigente — _creado: 2026-10-18_ — _id: ${VIVO}_
- [ ] Paso con ficha nueva — _creado: 2026-10-18_ — _id: ${NUEVO}_
- [ ] Paso sellado — _creado: 2026-10-18_ — _id: ${SELLADO}_
- [ ] Paso con marca vieja — _creado: 2026-10-17_ — _id: ${MARCA_VIEJA}_ — _retomar: 2026-10-17 sessions/2026-10-17-vieja_
- [ ] Paso marcado — _creado: 2026-10-18_ — _id: ${MARCADO}_ — _retomar: 2026-10-19 sessions/2026-10-19-otra_
EOF
cat > "$M/pendientes/2026-10.md" <<EOF
| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |
|---|---|---|---|---|---|---|
| 1 | Paso que otra sesion ya hizo _id: ${CERRADO}_ | Alta | 2026-10-17 | [[sessions/2026-10-17-vieja]] | 2026-10-18 | [[sessions/2026-10-18-hizo]] — resolved — publicado en 0.13.16 |
| 2 | Menciona ${VIVO} en su texto pero es otro _id: p-ffffffffff_ | Baja | 2026-10-17 | | 2026-10-18 | x |
EOF

ficha() {  # ficha SLUG "texto del Como retomar" [frontmatter extra] [touch -t]
  { echo "---"; echo "type: session"; [ -n "$3" ] && echo "$3"; echo "---"; echo "# demo"; echo
    echo "## Como retomar"; echo; echo "$2"; echo; echo "## Otra"; echo "x"; } > "$M/sessions/$1.md"
  [ -n "$4" ] && touch -t "$4" "$M/sessions/$1.md"
  return 0
}
ficha 2026-10-18-pegada "Proximo paso: hacer cosas ($VIVO)" "" 202610181200
ficha 2026-10-19-otra "Proximo paso: seguir con $NUEVO" "" 202610191200
ficha 2026-10-18-tarde "Proximo paso: otra cosa (p-9999999999)" "hilo_paso: $SELLADO" 202610181500
ficha 2026-10-18-temprano "Proximo paso: otra cosa ($VIVO)" "" 202610180900
ficha 2026-10-17-vieja "Proximo paso: lo de antes ($VIVO)" "" 202610171200

snippet() {  # snippet "linea del paso" -> prompt de snippet de Step 8 que manda leer 2026-10-18-pegada
  printf 'Retomamos: demo.\n\nLee memory/sessions/2026-10-18-pegada.md para el contexto completo.\n\nProximo paso: %s\n\nAntes de actuar, dime en 3 lineas donde quedamos.' "$1"
}
hook() {  # hook "prompt" -> salida del script
  python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "session_id": "s"}))' "$1" \
    | python3 -I "$BIN/snippet-vigente.py" --memory-dir "$M"
}
n_lineas() { printf '%s' "$1" | grep -c . || true; }

echo "== 1. snippet vigente (control): nada =="
O=$(hook "$(snippet "hacer cosas ($VIVO)")")
chk "sin salida" "" "$O"
echo "   (una ficha del mismo dia escrita ANTES y una de un dia anterior que citan el mismo id no cuentan)"

echo "== 2. A: el paso ya esta cerrado =="
O=$(hook "$(snippet "terminar lo de antes ($CERRADO)")")
chk "cabecera" "1" "$(printf '%s' "$O" | grep -c '^SNIPPET POSIBLEMENTE VIEJO')"
chk "dice cerrado con fecha" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado: resuelto 2026-10-18")"
chk "cita el motivo de la fila" "1" "$(printf '%s' "$O" | grep -c 'publicado en 0.13.16')"

echo "== 3. A: el paso no existe en ningun lado =="
O=$(hook "$(snippet "algo (p-0000000000)")")
chk "dice que no esta" "1" "$(printf '%s' "$O" | grep -c 'p-0000000000 no esta en _pendientes.md ni en ningun mensual')"

echo "== 4. B: ficha de un dia posterior cita el paso en su Como retomar =="
O=$(hook "$(snippet "seguir ($NUEVO)")")
chk "nombra la ficha nueva" "1" "$(printf '%s' "$O" | grep -c "$NUEVO sigue abierto, pero una ficha mas nueva ya lo retoma: memory/sessions/2026-10-19-otra.md")"

echo "== 5. B: ficha del mismo dia, escrita despues, con sello hilo_paso =="
O=$(hook "$(snippet "sellar ($SELLADO)")")
chk "nombra la ficha sellada" "1" "$(printf '%s' "$O" | grep -c "memory/sessions/2026-10-18-tarde.md")"

echo "== 6. B: la marca _retomar del pendiente apunta a otra ficha =="
O=$(hook "$(snippet "marcar ($MARCADO)")")
chk "nombra la ficha de la marca" "1" "$(printf '%s' "$O" | grep -c "$MARCADO sigue abierto, pero una ficha mas nueva ya lo retoma: memory/sessions/2026-10-19-otra.md")"

echo "== 7. tarjeta del mod (p-…: texto) con el paso cerrado =="
O=$(hook "$CERRADO: Paso que otra sesion ya hizo")
chk "avisa por el id de la tarjeta" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"

echo "== 8. tarjeta de 8e (Retomamos: … _id: p-…_ / Contexto: ficha) con ficha nueva =="
O=$(hook "$(printf 'Retomamos: Paso con ficha nueva _id: %s_\nContexto: memory/sessions/2026-10-18-pegada.md\nSi ya no aplica, cierralo con /checkpoint-3t.' "$NUEVO")")
chk "avisa con la ficha nueva" "1" "$(printf '%s' "$O" | grep -c "memory/sessions/2026-10-19-otra.md")"

echo "== 9. snippet dentro de <pasted_content> =="
O=$(hook "<pasted_content id=\"x\">$(snippet "terminar ($CERRADO)")</pasted_content>")
chk "lo ve igual" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"

echo "== 10. no es un snippet: nada =="
chk "mencion suelta de un id cerrado" "" "$(hook "revisa $CERRADO por favor")"
chk "Retomamos a mitad del prompt" "" "$(hook "mira esto: $(snippet "x ($CERRADO)")")"
chk "prompt no-string" "" "$(printf '{"prompt": 3}' | python3 -I "$BIN/snippet-vigente.py" --memory-dir "$M")"
chk "stdin no-JSON sale 0" "0" "$(printf 'basura' | python3 -I "$BIN/snippet-vigente.py" --memory-dir "$M" >/dev/null; echo $?)"

echo "== 11. varios avisos: una linea por id, maximo una cabecera =="
O=$(hook "$(snippet "dos cosas ($CERRADO y $NUEVO)")")
chk "cabecera + 2 lineas" "3" "$(n_lineas "$O")"

echo "== 12. el hook de verdad (snippet-vigente.sh) desde el proyecto =="
entrada() { python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "cwd": sys.argv[2], "session_id": "s"}))' "$1" "$P"; }
O=$(entrada "$(snippet "x ($CERRADO)")" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/snippet-vigente.sh"; echo "rc=$?")
chk "avisa" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"
chk "rc 0" "1" "$(printf '%s' "$O" | grep -c '^rc=0$')"
O=$(entrada "hola" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/snippet-vigente.sh"; echo "rc=$?")
chk "prompt normal: nada, rc 0" "rc=0" "$O"
O=$(entrada "$(snippet "x ($CERRADO)")" | CLAUDE_PROJECT_DIR="$T/sin-memoria" bash "$BIN/snippet-vigente.sh"; echo "rc=$?")
chk "proyecto sin memoria: nada, rc 0" "rc=0" "$O"

echo "== 13. snippet como argumento de un comando (p-8a21c08256) =="
O=$(hook "/goalspec:interview $(snippet "terminar ($CERRADO)")")
chk "tecleado: /cmd Retomamos" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"
O=$(hook "<command-message>goalspec:interview</command-message>
<command-name>/goalspec:interview</command-name>
<command-args>$(snippet "terminar ($CERRADO)")</command-args>")
chk "envuelto: <command-args>Retomamos" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"
O=$(hook "/goalspec:interview <pasted_content id=\"x\">$(snippet "terminar ($CERRADO)")</pasted_content>")
chk "comando con el snippet pegado como bloque" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"
chk "comando con otro argumento: nada" "" "$(hook "/goalspec:interview revisa $CERRADO")"
chk "<command-args> con otro argumento: nada" "" "$(hook "<command-name>/x</command-name><command-args>mira $(snippet "x ($CERRADO)")</command-args>")"
chk "comando sin argumento: nada" "" "$(hook "/checkpoint-3t")"
chk "ruta absoluta no es comando: nada" "" "$(hook "/opt/x/y $(snippet "x ($CERRADO)")")"
O=$(hook "$(printf 'Retomamos: el hook ve <command-args>foo</command-args> en el prompt.\n\nProximo paso: cerrar (%s)' "$CERRADO")")
chk "Retomamos que cita las etiquetas <command-args> se lee entero" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"
O=$(entrada "/goalspec:interview $(snippet "x ($CERRADO)")" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/snippet-vigente.sh")
chk "por el hook de verdad (snippet-vigente.sh)" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"

echo "== 13b. la marca _retomar y la tilde (p-c711eabb05) =="
chk "marca a una ficha mas vieja que la pegada: nada" "" "$(hook "$(snippet "seguir ($MARCA_VIEJA)")")"
# La tilde se escribe dentro de python, no por argv: en Git Bash el argv no ASCII puede llegar
# convertido (25423b1).
tilde() {  # tilde ensure_ascii -> JSON del hook con `Próximo paso:`
  python3 -c 'import json,sys; print(json.dumps({"prompt": "Próximo paso: terminar (" + sys.argv[1] + ")", "cwd": sys.argv[2]}, ensure_ascii=(sys.argv[3] == "1")))' "$CERRADO" "$P" "$1"
}
O=$(tilde 0 | CLAUDE_PROJECT_DIR="$P" bash "$BIN/snippet-vigente.sh")
chk "Próximo paso con tilde tal cual pasa el filtro rapido" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"
O=$(tilde 1 | CLAUDE_PROJECT_DIR="$P" bash "$BIN/snippet-vigente.sh")
chk "tilde escapada como \\u00f3 tambien" "1" "$(printf '%s' "$O" | grep -c "$CERRADO ya esta cerrado")"

echo "== 14. hooks.json lo registra en UserPromptSubmit =="
if [ ! -f "$BIN/../hooks/hooks.json" ]; then
  echo "  SKIP (no hay hooks/ junto a bin/)"
else
  R=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
hs=[h.get('command','') for g in d['hooks'].get('UserPromptSubmit',[]) for h in g.get('hooks',[])]
print(1 if any('snippet-vigente.sh' in c for c in hs) else 0)" "$BIN/../hooks/hooks.json")
  chk "registrado" "1" "$R"
fi

echo "RESULT: pass=$pass fail=$fail"
[ "$fail" = 0 ]
