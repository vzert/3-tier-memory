#!/usr/bin/env bash
# Pruebas de compaction-recover.py (2.39.0, checkpoint-3t Step 0b): detecta que la sesion se
# compacto despues del ultimo checkpoint y saca del JSONL el tramo que el agente ya no tiene en
# contexto, en bloques limpios para que subagentes extraigan learnings/pendientes/planes/research.
#
# Todo el JSONL es sintetico (heredoc), con la forma medida en sesiones reales: la compactacion es
# una linea `{"type":"system","subtype":"compact_boundary"}`, el checkpoint deja
# `<command-name>/checkpoint-3t` y/o el tool_result `Launching skill: checkpoint-3t` (mismo promptId
# si es la misma invocacion), y un `cross-session-message` llega como isMeta.
#
# Uso: test-compaction-recover.sh   (exit 0 = todo verde)
# sella-huellas: no (trabaja en un temporal propio)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
has()  { grep -qF -- "$2" "$3" 2>/dev/null && ok "$1" || { bad "$1"; printf '       falta: %s\n' "$2"; }; }
hasnt(){ grep -qF -- "$2" "$3" 2>/dev/null && { bad "$1"; printf '       sobra: %s\n' "$2"; } || ok "$1"; }
first(){ printf '%s' "$1" | cut -d' ' -f1-2; }

# Lineas JSONL de ayuda. $1 = promptId
u()    { printf '{"type":"user","promptId":"%s","timestamp":"2026-09-20T10:00:00Z","message":{"role":"user","content":"%s"}}\n' "$1" "$2"; }
umeta(){ printf '{"type":"user","isMeta":true,"promptId":"%s","message":{"role":"user","content":"%s"}}\n' "$1" "$2"; }
a()    { printf '{"type":"assistant","promptId":"%s","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" "$2"; }
edit() { printf '{"type":"assistant","promptId":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"t%s","name":"Edit","input":{"file_path":"%s","old_string":"viejo","new_string":"%s"}}]}}\n' "$1" "$RANDOM" "$2" "$3"; }
tres() { printf '{"type":"user","promptId":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"%s"}]}}\n' "$1" "$2"; }
ckcmd(){ u "$1" "<command-message>checkpoint-3t</command-message>\\n<command-name>/checkpoint-3t</command-name>"; }
ckskl(){ tres "$1" "Launching skill: checkpoint-3t"; }
bound(){ printf '{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-20T11:00:00Z","compactMetadata":{"trigger":"auto","preTokens":%s}}\n' "$1"; }
summ() { printf '{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"RESUMEN-LOSSY de la compactacion"}}\n'; }
side() { printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"TEXTO-DE-SUBAGENTE"}]}}\n'; }

run() { python3 "$BIN/compaction-recover.py" --jsonl "$1" --out-dir "$2" "${@:3}"; }

echo "A. checkpoint A -> trabajo X -> compactacion -> trabajo Y -> checkpoint B (actual): recupera X, ni A ni Y"
F="$TMP/a.jsonl"
{ ckcmd p1; ckskl p1; a p1 "EJECUCION-DEL-CHECKPOINT-A"
  u p2 "PETICION-X arregla el parser"; a p2 "RESPUESTA-X"; edit p2 "src/parser.py" "NUEVO-X"
  side; bound 900000; summ
  u p3 "PETICION-Y posterior"; a p3 "RESPUESTA-Y"
  ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/oa"); echo "       $OUT"
case "$OUT" in "recover=1 compactions=1 pre_tokens=900000 chunks=1 "*) ok "recover=1 con 1 compactacion y sus preTokens";; *) bad "linea de salida";; esac
C="$TMP/oa/chunk-01.md"
has   "incluye la peticion de X"            "PETICION-X arregla el parser" "$C"
has   "incluye la respuesta de X"           "RESPUESTA-X" "$C"
has   "incluye la edicion con su ruta"      "TOOL Edit src/parser.py" "$C"
has   "incluye el texto nuevo de la edicion" "NUEVO-X" "$C"
hasnt "no incluye la ejecucion del checkpoint anterior" "EJECUCION-DEL-CHECKPOINT-A" "$C"
hasnt "no incluye lo posterior a la compactacion"       "PETICION-Y" "$C"
hasnt "no incluye el resumen lossy"         "RESUMEN-LOSSY" "$C"
hasnt "no incluye texto de subagentes"      "TEXTO-DE-SUBAGENTE" "$C"
python3 -c "import json,sys; m=json.load(open(sys.argv[1])); assert (m['previous_checkpoint_line'], m['from_line'], m['to_line'])==(2, 4, 8), m" "$TMP/oa/manifest.json" \
  && ok "manifest: marcas del checkpoint anterior hasta la linea 2, tramo 4-8 (primer prompt real hasta la compactacion)" || bad "manifest de lineas"

echo "B. checkpoint DESPUES de la compactacion: nada que recuperar"
F="$TMP/b.jsonl"
{ u p1 "trabajo"; bound 500000; summ; ckcmd p2; ckskl p2; u p3 "mas trabajo"; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/ob")
[ "$OUT" = "recover=0 reason=checkpoint-posterior-a-la-compactacion" ] && ok "recover=0 checkpoint-posterior" || bad "B: $OUT"
[ ! -e "$TMP/ob" ] && ok "no crea el directorio de salida" || bad "B creo salida"

echo "C. dos compactaciones sin checkpoint previo: tramo desde la linea 1 hasta la segunda"
F="$TMP/c.jsonl"
{ u p1 "ANTES-DE-LA-PRIMERA"; bound 400000; summ; u p2 "ENTRE-COMPACTACIONES"; bound 300000; summ
  u p3 "DESPUES-DE-LA-SEGUNDA"; ckcmd p4; } > "$F"
OUT=$(run "$F" "$TMP/oc"); echo "       $OUT"
case "$OUT" in "recover=1 compactions=2 pre_tokens=700000 "*) ok "cuenta 2 compactaciones y suma preTokens";; *) bad "C: $OUT";; esac
has   "incluye lo previo a la primera"  "ANTES-DE-LA-PRIMERA"  "$TMP/oc/chunk-01.md"
has   "incluye lo que hubo entre ambas" "ENTRE-COMPACTACIONES" "$TMP/oc/chunk-01.md"
hasnt "no incluye lo vivo tras la segunda" "DESPUES-DE-LA-SEGUNDA" "$TMP/oc/chunk-01.md"

echo "D. la invocacion en curso deja DOS marcas (mismo promptId): cuenta como un solo checkpoint"
F="$TMP/d.jsonl"
{ u p1 "TRABAJO-SIN-CHECKPOINT-PREVIO"; bound 200000; summ; u p2 "vivo"; ckcmd p3; ckskl p3; umeta p3 "Skill /checkpoint-3t is already loaded above"; } > "$F"
OUT=$(run "$F" "$TMP/od")
case "$OUT" in "recover=1 "*) ok "recover=1 (las marcas de la invocacion actual no hacen de checkpoint anterior)";; *) bad "D: $OUT";; esac
has "recupera el trabajo previo" "TRABAJO-SIN-CHECKPOINT-PREVIO" "$TMP/od/chunk-01.md"

echo "E. sin compactacion / sin JSONL / sin session id: recover=0 y exit 0"
F="$TMP/e.jsonl"; { u p1 "hola"; ckcmd p2; } > "$F"
OUT=$(run "$F" "$TMP/oe"); rc=$?
[ "$OUT" = "recover=0 reason=sin-compactacion" ] && [ $rc -eq 0 ] && ok "sin-compactacion, exit 0" || bad "E1: $OUT rc=$rc"
OUT=$(python3 "$BIN/compaction-recover.py" --session-id no-existe --jsonl-dir "$TMP" --out-dir "$TMP/oe2"); rc=$?
case "$OUT" in "recover=0 reason=sin-jsonl "*) [ $rc -eq 0 ] && ok "sin-jsonl, exit 0" || bad "E2 rc=$rc";; *) bad "E2: $OUT";; esac
OUT=$(python3 "$BIN/compaction-recover.py" --out-dir "$TMP/oe3"); rc=$?
[ "$OUT" = "recover=0 reason=sin-session-id" ] && [ $rc -eq 0 ] && ok "sin-session-id, exit 0" || bad "E3: $OUT rc=$rc"

echo "F. isMeta: un cross-session-message SE conserva; el cuerpo de una skill no"
F="$TMP/f.jsonl"
{ umeta p1 "Another Claude session sent a message:\\n<cross-session-message from=\\\"x\\\">ENCARGO-DE-OTRA-SESION</cross-session-message>"
  umeta p1 "Base directory for this skill: /x\\n\\nCUERPO-DE-SKILL"
  u p2 "<command-message>goalspec:interview</command-message>\\n<command-name>/goalspec:interview</command-name>\\n<command-args>ARGUMENTOS-DEL-COMANDO</command-args>"
  bound 100000; ckcmd p3; } > "$F"
run "$F" "$TMP/of" >/dev/null
has   "conserva el encargo de otra sesion" "ENCARGO-DE-OTRA-SESION" "$TMP/of/chunk-01.md"
hasnt "descarta el cuerpo de la skill"     "CUERPO-DE-SKILL" "$TMP/of/chunk-01.md"
has   "conserva los argumentos de un comando" "ARGUMENTOS-DEL-COMANDO" "$TMP/of/chunk-01.md"

echo "G. bloques: se cortan entre entradas, balanceados, y la pregunta con su respuesta sobreviven"
F="$TMP/g.jsonl"
{ for i in $(seq 1 40); do a "p$i" "ENTRADA-$i $(printf 'x%.0s' $(seq 1 200))"; done
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"ask1","name":"AskUserQuestion","input":{"questions":[{"question":"PREGUNTA-CLAVE?","options":[{"label":"Si"},{"label":"No"}]}]}}]}}\n'
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"ask1","content":"RESPUESTA-ELEGIDA=Si"}]}}\n'
  bound 100000; ckcmd pz; } > "$F"
OUT=$(run "$F" "$TMP/og" --chunk-chars 3000); echo "       $OUT"
N=$(ls "$TMP/og"/chunk-*.md | wc -l | tr -d ' ')
[ "$N" -ge 3 ] && ok "varios bloques ($N)" || bad "G: esperaba >=3 bloques, hay $N"
T=$(cat "$TMP/og"/chunk-*.md | grep -c '^\[\?.*ENTRADA-[0-9]* x')
[ "$T" -eq 40 ] && ok "las 40 entradas aparecen enteras, ninguna partida" || bad "G: $T de 40 entradas enteras"
python3 - "$TMP/og" <<'PY' && ok "bloques balanceados (el menor >= 50% del mayor)" || bad "G: bloques desbalanceados"
import glob, os, sys
s = [os.path.getsize(p) for p in glob.glob(sys.argv[1] + "/chunk-*.md")]
sys.exit(0 if min(s) >= 0.5 * max(s) else 1)
PY
cat "$TMP/og"/chunk-*.md > "$TMP/og.all"
has "la pregunta al usuario aparece"   "PREGUNTA-CLAVE?" "$TMP/og.all"
has "la respuesta del usuario aparece" "RESPUESTA-ELEGIDA=Si" "$TMP/og.all"

echo "H. --until-line evalua el archivo como si terminara ahi (checkpoint A como el actual)"
F="$TMP/h.jsonl"
{ u p1 "TRABAJO-H"; bound 100000; summ; ckcmd p2; ckskl p2; u p3 "mas"; ckcmd p4; } > "$F"
OUT=$(run "$F" "$TMP/oh1"); [ "$OUT" = "recover=0 reason=checkpoint-posterior-a-la-compactacion" ] && ok "archivo entero: recover=0" || bad "H1: $OUT"
OUT=$(run "$F" "$TMP/oh2" --until-line 5); case "$OUT" in "recover=1 "*) ok "hasta la linea 5: recover=1";; *) bad "H2: $OUT";; esac

echo "I. la cadena de una marca DENTRO de otra cosa no es un checkpoint (lectura de la plantilla, prosa)"
F="$TMP/i.jsonl"
{ u p1 "TRABAJO-I antes de todo"
  tres p2 "12  ckskl(){ tres \\\"\$1\\\" \\\"Launching skill: checkpoint-3t\\\"; }  <- linea de un Read"
  u p3 "recuerda correr /checkpoint-3t y <command-name>/checkpoint-3t</command-name> al final"
  bound 100000; summ; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/oi")
case "$OUT" in "recover=1 "*) ok "recover=1: ni el Read ni la prosa cuentan como checkpoint anterior";; *) bad "I: $OUT";; esac
has "recupera el trabajo previo a esas menciones" "TRABAJO-I antes de todo" "$TMP/oi/chunk-01.md"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
