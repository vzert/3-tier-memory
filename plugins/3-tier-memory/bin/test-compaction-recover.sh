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
# Un checkpoint que TERMINO corre en su turno los scripts posteriores a Step 5: su Bash devuelve la
# salida del de 5c. Cuenta la salida, no el nombre en el comando.
fin()  { local id="f$RANDOM"
  printf '{"type":"assistant","promptId":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"python3 \\"$SEAL\\" \\"$MEMORY_DIR\\" --apply"}}]}}\n' "$1" "$id"
  printf '{"type":"user","promptId":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"== ensure-frontmatter: APPLY ==\\nSUMMARY frontmatter_sealed=0"}]}}\n' "$1" "$id"; }
# Un Bash que LEE el fuente del script: nombra el script y trae sus print, sin haberlo corrido.
lee()  { local id="l$RANDOM"
  printf '{"type":"assistant","promptId":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"cat plugins/3-tier-memory/bin/ensure-frontmatter.py"}}]}}\n' "$1" "$id"
  printf '{"type":"user","promptId":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"    print(f\\"SUMMARY frontmatter_sealed={sealed}\\")\\n    print(\\"stamped=%%d reason=%%s\\" %% (sellado, razon))"}]}}\n' "$1" "$id"; }
bound(){ printf '{"type":"system","subtype":"compact_boundary","timestamp":"2026-09-20T11:00:00Z","compactMetadata":{"trigger":"auto","preTokens":%s}}\n' "$1"; }
summ() { printf '{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"RESUMEN-LOSSY de la compactacion"}}\n'; }
side() { printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"TEXTO-DE-SUBAGENTE"}]}}\n'; }

run() { python3 "$BIN/compaction-recover.py" --jsonl "$1" --out-dir "$2" "${@:3}"; }

echo "A. checkpoint A -> trabajo X -> compactacion -> trabajo Y -> checkpoint B (actual): recupera X, ni A ni Y"
F="$TMP/a.jsonl"
{ ckcmd p1; ckskl p1; a p1 "EJECUCION-DEL-CHECKPOINT-A"; fin p1
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
python3 -c "import json,sys; m=json.load(open(sys.argv[1])); assert (m['previous_checkpoint_line'], m['from_line'], m['to_line'])==(5, 6, 10), m" "$TMP/oa/manifest.json" \
  && ok "manifest: el checkpoint anterior cierra en la linea 5 (salida de 5c), tramo 6-10 (primer prompt real hasta la compactacion)" || bad "manifest de lineas"

echo "B. checkpoint DESPUES de la compactacion: nada que recuperar"
F="$TMP/b.jsonl"
{ u p1 "trabajo"; bound 500000; summ; ckcmd p2; ckskl p2; fin p2; u p3 "mas trabajo"; ckcmd p4; ckskl p4; } > "$F"
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
OUT=$(python3 "$BIN/compaction-recover.py" --session-id no-existe --jsonl-dir "$TMP" --projects-root "$TMP" --out-dir "$TMP/oe2"); rc=$?
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
{ u p1 "TRABAJO-H"; bound 100000; summ; ckcmd p2; ckskl p2; fin p2; u p3 "mas"; ckcmd p4; } > "$F"
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

echo "J. sin prompt escrito: una notificacion de tarea abre el tramo; sin nada, empieza tras el checkpoint"
F="$TMP/j.jsonl"
{ ckcmd p1; ckskl p1; a p1 "EJECUCION-CHECKPOINT-J"; fin p1
  u p2 "<task-notification>\\n<task-id>b1</task-id>\\n<summary>TAREA-TERMINO</summary>\\n</task-notification>"
  edit p2 "src/loop.py" "CAMBIO-AUTONOMO-VIA-NOTIFICACION"
  bound 100000; summ; ckcmd p3; ckskl p3; } > "$F"
OUT=$(run "$F" "$TMP/oj")
case "$OUT" in "recover=1 "*) ok "recover=1 con el turno abierto por una notificacion";; *) bad "J1: $OUT";; esac
has   "recupera la edicion autonoma"          "CAMBIO-AUTONOMO-VIA-NOTIFICACION" "$TMP/oj/chunk-01.md"
hasnt "no mete la ejecucion del checkpoint"   "EJECUCION-CHECKPOINT-J" "$TMP/oj/chunk-01.md"
F="$TMP/j2.jsonl"
{ ckcmd p1; ckskl p1; fin p1; edit p1 "src/x.py" "EDICION-SIN-TURNO-NUEVO"; bound 100000; ckcmd p3; } > "$F"
OUT=$(run "$F" "$TMP/oj2")
case "$OUT" in "recover=1 "*) ok "sin ningun inicio de turno: recover=1 igual, nunca recover=0 con compactacion";; *) bad "J2: $OUT";; esac
has "recupera lo que hubo tras el checkpoint" "EDICION-SIN-TURNO-NUEVO" "$TMP/oj2/chunk-01.md"

echo "K. --jsonl-dir equivocado (CLAUDE_PROJECT_DIR vacia): encuentra <session-id>.jsonl bajo --projects-root"
mkdir -p "$TMP/projects/-proyecto-real"
{ u p1 "TRABAJO-K"; bound 100000; ckcmd p2; } > "$TMP/projects/-proyecto-real/sesion-uuid-k.jsonl"
OUT=$(python3 "$BIN/compaction-recover.py" --session-id sesion-uuid-k --jsonl-dir "$TMP/projects/" \
      --projects-root "$TMP/projects" --out-dir "$TMP/ok")
case "$OUT" in "recover=1 "*) ok "recover=1 buscando el id bajo todos los proyectos";; *) bad "K: $OUT";; esac
has "recupera el trabajo" "TRABAJO-K" "$TMP/ok/chunk-01.md"

echo "L. un checkpoint interrumpido antes de escribir no cuenta como checkpoint anterior (adversario externo, 2026-09-28)"
F="$TMP/l.jsonl"
{ u p1 "PENDIENTE-DEL-TRAMO verificar la migracion"; bound 300000; summ
  ckcmd p2; ckskl p2; a p2 "Step 0: localizo memory/"
  u p3 "se interrumpio el checkpoint, reintenta"; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/ol")
case "$OUT" in "recover=1 "*) ok "recover=1: la invocacion p2 no corrio ningun script posterior a Step 5";; *) bad "L1: $OUT";; esac
has "recupera lo que p2 nunca guardo" "PENDIENTE-DEL-TRAMO" "$TMP/ol/chunk-01.md"
# Control: el mismo archivo con p2 TERMINADO (fin) vuelve a recover=0.
F="$TMP/l2.jsonl"
{ u p1 "PENDIENTE-DEL-TRAMO"; bound 300000; summ
  ckcmd p2; ckskl p2; fin p2; u p3 "otra cosa"; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/ol2")
[ "$OUT" = "recover=0 reason=checkpoint-posterior-a-la-compactacion" ] && ok "control: con el checkpoint terminado, recover=0" || bad "L2: $OUT"
# Un script de CKPT_DONE que corre en OTRO turno (tras un prompt nuevo) no convierte en terminado al checkpoint.
F="$TMP/l3.jsonl"
{ u p1 "PENDIENTE-DEL-TRAMO"; bound 300000; summ
  ckcmd p2; ckskl p2; u p3 "corre el audit a mano"; fin p3; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/ol3")
case "$OUT" in "recover=1 "*) ok "el script en un turno posterior no cuenta como cierre del checkpoint";; *) bad "L3: $OUT";; esac

echo "N. ronda 2 del adversario: leer el fuente no cierra; una notificacion en medio no corta el turno"
F="$TMP/n1.jsonl"
{ u p1 "PENDIENTE-N1"; bound 300000; summ; ckcmd p2; ckskl p2; lee p2
  u p3 "se corto, reintenta"; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/on1")
case "$OUT" in "recover=1 "*) ok "cat del fuente: el checkpoint no cuenta como terminado";; *) bad "N1: $OUT";; esac
F="$TMP/n2.jsonl"
{ u p1 "PENDIENTE-N2"; bound 300000; summ; ckcmd p2; ckskl p2
  u p2b "<task-notification>\\n<task-id>b9</task-id>\\n<summary>TERMINO</summary>\\n</task-notification>"
  fin p2; u p3 "otra cosa"; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/on2")
[ "$OUT" = "recover=0 reason=checkpoint-posterior-a-la-compactacion" ] && ok "notificacion en medio y luego 5c: terminado, recover=0" || bad "N2: $OUT"

echo "O. ronda 3 del adversario: log viejo, DRY-RUN, prompt que pega una notificacion, Edit tras el cierre"
# Un Bash sin python3 que imprime una salida de cierre (cat de un log viejo): no cierra.
catlog(){ local id="c$RANDOM"
  printf '{"type":"assistant","promptId":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"cat /tmp/checkpoint-viejo.log"}}]}}\n' "$1" "$id"
  printf '{"type":"user","promptId":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"SUMMARY frontmatter_sealed=0"}]}}\n' "$1" "$id"; }
# ensure-frontmatter.py sin --apply: salida real, pero DRY-RUN.
dry()  { local id="d$RANDOM"
  printf '{"type":"assistant","promptId":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"python3 \\"$SEAL\\" \\"$MEMORY_DIR\\""}}]}}\n' "$1" "$id"
  printf '{"type":"user","promptId":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"== ensure-frontmatter: DRY-RUN ==\\nDRY-RUN only\\nSUMMARY frontmatter_sealed=0"}]}}\n' "$1" "$id"; }
for c in catlog dry; do
  F="$TMP/o-$c.jsonl"
  { u p1 "PENDIENTE-O"; bound 300000; summ; ckcmd p2; ckskl p2; $c p2; u p3 "se corto, reintenta"; ckcmd p4; ckskl p4; } > "$F"
  OUT=$(run "$F" "$TMP/oo-$c")
  case "$OUT" in "recover=1 "*) ok "$c: no cuenta como cierre";; *) bad "O $c: $OUT";; esac
done
# Un prompt ESCRITO (origin.kind=human) que empieza pegando una notificacion cierra el turno.
F="$TMP/o-pegado.jsonl"
{ u p1 "PENDIENTE-O"; bound 300000; summ; ckcmd p2; ckskl p2
  printf '{"type":"user","promptId":"p3","origin":{"kind":"human"},"message":{"role":"user","content":"<task-notification>pegada</task-notification> olvida el checkpoint, haz otra cosa"}}\n'
  fin p3; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/oo-pegado")
case "$OUT" in "recover=1 "*) ok "prompt escrito con notificacion pegada: cierra el turno del checkpoint";; *) bad "O pegado: $OUT";; esac
# Y una notificacion real (origin.kind=task-notification) no lo cierra.
F="$TMP/o-real.jsonl"
{ u p1 "PENDIENTE-O"; bound 300000; summ; ckcmd p2; ckskl p2
  printf '{"type":"user","promptId":"p2b","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>real</task-notification>"}}\n'
  fin p2; u p3 "otra"; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/oo-real")
[ "$OUT" = "recover=0 reason=checkpoint-posterior-a-la-compactacion" ] && ok "notificacion real (origin): no corta el turno" || bad "O real: $OUT"
# Checkpoint terminado -> Edit autonomo -> prompt -> compactacion: el Edit se recupera.
F="$TMP/o-edit.jsonl"
{ ckcmd p1; ckskl p1; fin p1; edit p1 "src/auto.py" "CAMBIO-AUTONOMO-TRAS-CIERRE"
  u p2 "PETICION-POSTERIOR"; bound 200000; summ; ckcmd p3; ckskl p3; } > "$F"
OUT=$(run "$F" "$TMP/oo-edit")
case "$OUT" in "recover=1 "*) ok "recover=1";; *) bad "O edit: $OUT";; esac
has "recupera el Edit hecho tras el cierre y antes del prompt" "CAMBIO-AUTONOMO-TRAS-CIERRE" "$TMP/oo-edit/chunk-01.md"

echo "P. ronda 4 del adversario: stamped=0 (ficha inexistente) no cierra el checkpoint"
stamp0(){ local id="s$RANDOM"
  printf '{"type":"assistant","promptId":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"python3 \\"$STAMP\\" \\"$SESSION_FILE\\" x"}}]}}\n' "$1" "$id"
  printf '{"type":"user","promptId":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":true,"content":"stamped=0 reason=no-existe-la-ficha"}]}}\n' "$1" "$id"; }
F="$TMP/p.jsonl"
{ u p1 "PENDIENTE-P"; bound 300000; summ; ckcmd p2; ckskl p2; stamp0 p2; u p3 "reintenta"; ckcmd p4; ckskl p4; } > "$F"
OUT=$(run "$F" "$TMP/op")
case "$OUT" in "recover=1 "*) ok "stamped=0 no cuenta como cierre";; *) bad "P: $OUT";; esac

echo "Q. ronda 5 del adversario: el audit como diagnostico y un DRY-RUN filtrado no cierran"
salida(){ local id="q$RANDOM"   # $1 promptId  $2 comando  $3 salida
  printf '{"type":"assistant","promptId":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"%s"}}]}}\n' "$1" "$id" "$2"
  printf '{"type":"user","promptId":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","content":"%s"}]}}\n' "$1" "$id" "$3"; }
for c in audit dry; do
  F="$TMP/q-$c.jsonl"
  { u p1 "PENDIENTE-Q"; bound 300000; summ; ckcmd p2; ckskl p2
    if [ $c = audit ]; then salida p2 'python3 \"$JBIN/checkpoint-audit.py\" memory' '  resumen: hecho=7 parcial=0 saltado=3'
    else salida p2 'python3 \"$SEAL\" memory | tail -n 1' 'SUMMARY frontmatter_sealed=1'; fi
    u p3 "reintenta"; ckcmd p4; ckskl p4; } > "$F"
  OUT=$(run "$F" "$TMP/oq-$c")
  case "$OUT" in "recover=1 "*) ok "$c: no cuenta como cierre";; *) bad "Q $c: $OUT";; esac
done

echo "R. un fallo de escritura sale 0 con motivo y no deja bloques con texto crudo (Codex, ronda 1 sobre 2.39.x)"
# Tres puntos de fallo: el manifest y el segundo bloque (con bloques ya escritos) y el directorio.
# No se mira el nombre de la excepcion: abrir un directorio da IsADirectoryError en POSIX y
# PermissionError en Windows.
for c in manifest chunk dir; do
  F="$TMP/r-$c.jsonl"; O="$TMP/or-$c"
  { u p1 "SECRETO-EN-TRAMO"; u p1 "OTRA-ENTRADA-DEL-TRAMO"; bound 300000; summ; ckcmd p2; ckskl p2; } > "$F"
  case $c in
    manifest) mkdir -p "$O/manifest.json";;
    chunk)    mkdir -p "$O/chunk-02.md";;
    dir)      : > "$O";;
  esac
  OUT=$(run "$F" "$O" --chunk-chars 60 2>/dev/null); RC=$?
  [ $RC -eq 0 ] && ok "$c: sale 0" || bad "R $c: exit=$RC"
  case "$OUT" in "recover=0 reason=fallo-escritura"*) ok "$c: recover=0 reason=fallo-escritura";; *) bad "R $c: $OUT";; esac
  if [ -d "$O" ]; then
    grep -rqF "SECRETO-EN-TRAMO" "$O" && bad "R $c: queda texto crudo del tramo" || ok "$c: no queda texto crudo"
    [ -z "$(find "$O" -name 'chunk-*.md' -type f)" ] && ok "$c: no quedan bloques" || bad "R $c: quedan bloques"
  fi
done

echo "R2. ronda 2 de Codex sobre 2.41.7: sustituto suelto, stdout que falla, archivo o enlace previo"
# Un \ud800 suelto es JSON valido, pero no se codifica en UTF-8: el bloque sale con reemplazo.
F="$TMP/r-sur.jsonl"
{ u p1 "SECRETO-EN-TRAMO"; u p1 'MALO\ud800FIN'; bound 300000; summ; ckcmd p2; ckskl p2; } > "$F"
OUT=$(run "$F" "$TMP/or-sur" 2>/dev/null); RC=$?
[ $RC -eq 0 ] && ok "sustituto: sale 0" || bad "R2 sustituto: exit=$RC"
case "$OUT" in "recover=1 "*) ok "sustituto: recupera el tramo igual";; *) bad "R2 sustituto: $OUT";; esac
has "sustituto: el bloque lleva el texto de alrededor" "FIN" "$TMP/or-sur/chunk-01.md"
# stdout se cierra a mitad de la corrida (como una tuberia que se cierra): la linea de salida no
# llega, asi que no deben quedar bloques que nadie sabe que existen.
F="$TMP/r-out.jsonl"
{ u p1 "SECRETO-EN-TRAMO"; bound 300000; summ; ckcmd p2; ckskl p2; } > "$F"
# Las dos formas de stdout, fijadas: con un archivo (se puede posicionar) reconfigure() pide tell()
# al fd 1 ya cerrado y daba OSError al cargar el modulo (ronda 7: el caso solo fallaba si el test
# corria con la salida a un archivo; con tuberia o terminal pasaba).
for s in archivo tuberia; do
  O="$TMP/or-out-$s"
  if [ $s = archivo ]; then
    python3 -c 'import os, runpy, sys; os.close(1); sys.argv[0] = sys.argv.pop(1); runpy.run_path(sys.argv[0], run_name="__main__")' \
      "$BIN/compaction-recover.py" --jsonl "$F" --out-dir "$O" > "$TMP/stdout-$s.txt" 2>/dev/null; RC=$?
  else
    python3 -c 'import os, runpy, sys; os.close(1); sys.argv[0] = sys.argv.pop(1); runpy.run_path(sys.argv[0], run_name="__main__")' \
      "$BIN/compaction-recover.py" --jsonl "$F" --out-dir "$O" 2>/dev/null | cat >/dev/null; RC=${PIPESTATUS[0]}
  fi
  [ "$RC" = 0 ] && ok "stdout cerrado ($s): sale 0" || bad "R2 stdout cerrado ($s): exit=$RC"
  grep -rqF "SECRETO-EN-TRAMO" "$O" 2>/dev/null && bad "R2 stdout cerrado ($s): queda texto crudo" || ok "stdout cerrado ($s): no queda texto crudo"
done
# Un chunk-01.md que ya existia (archivo, o enlace a otro archivo) no se pisa ni se borra. En Git
# Bash sin modo desarrollador `ln -s` copia el archivo: los asertos valen para las dos formas.
for c in archivo enlace; do
  O="$TMP/or-$c"; mkdir -p "$O"; printf 'CONSERVAR\n' > "$TMP/destino-$c.txt"
  if [ $c = archivo ]; then printf 'CONSERVAR\n' > "$O/chunk-01.md"; else ln -s "$TMP/destino-$c.txt" "$O/chunk-01.md"; fi
  OUT=$(run "$F" "$O" 2>/dev/null); RC=$?
  [ $RC -eq 0 ] && ok "$c previo: sale 0" || bad "R2 $c previo: exit=$RC"
  case "$OUT" in "recover=0 reason=fallo-escritura"*) ok "$c previo: recover=0 reason=fallo-escritura";; *) bad "R2 $c previo: $OUT";; esac
  [ -e "$O/chunk-01.md" ] || [ -L "$O/chunk-01.md" ] && ok "$c previo: no lo borra" || bad "R2 $c previo: lo borro"
  has   "$c previo: el destino no cambia" "CONSERVAR" "$TMP/destino-$c.txt"
  hasnt "$c previo: no escribe texto crudo en el destino" "SECRETO-EN-TRAMO" "$TMP/destino-$c.txt"
  grep -rqF "SECRETO-EN-TRAMO" "$O" && bad "R2 $c previo: queda texto crudo" || ok "$c previo: no queda texto crudo"
done

echo "R3. ronda 3 de Codex sobre 2.41.7: stdout que da ValueError, error con sustituto, borrado que falla"
F="$TMP/r3.jsonl"
{ u p1 "SECRETO-EN-TRAMO"; bound 300000; summ; ckcmd p2; ckskl p2; } > "$F"
# $1 = codigo que se corre antes del script (parchea el proceso); $2 = --out-dir
# El parche va en su propia linea: con "; class" en una sola, python3 -c sale 1 por SyntaxError y el
# caso pasa sin probar nada. Se exige que el envoltorio haya llegado a correr el script (ENVUELTO-OK).
envuelto(){ python3 -c "import io, os, runpy, sys
$1
sys.argv[0] = sys.argv.pop(1)
sys.stderr.write('ENVUELTO-OK\\n')
runpy.run_path(sys.argv[0], run_name='__main__')" "$BIN/compaction-recover.py" --jsonl "$F" --out-dir "$2" 2>"$TMP/envuelto.err"
  local rc=$?; grep -q ENVUELTO-OK "$TMP/envuelto.err" || bad "el envoltorio no llego a correr el script: $(tail -1 "$TMP/envuelto.err")"
  return $rc; }
# stdout cerrado como objeto de Python: write y flush dan ValueError, no OSError.
OUT=$(envuelto "class C(io.TextIOBase):
    def reconfigure(self, **k): pass
    def write(self, s): raise ValueError('I/O operation on closed file')
    def flush(self): raise ValueError('I/O operation on closed file')
sys.stdout = C()" "$TMP/or3-val"); RC=$?
[ $RC -eq 0 ] && ok "ValueError en stdout: sale 0" || bad "R3 ValueError: exit=$RC"
grep -rqF "SECRETO-EN-TRAMO" "$TMP/or3-val" 2>/dev/null && bad "R3 ValueError: queda texto crudo" || ok "ValueError en stdout: no queda texto crudo"
# Un OSError cuyo mensaje trae un sustituto: la linea recover=0 sale igual.
OUT=$(envuelto "os.makedirs = lambda *a, **k: (_ for _ in ()).throw(OSError('malo \\ud800'))" "$TMP/or3-sur"); RC=$?
[ $RC -eq 0 ] && ok "error con sustituto: sale 0" || bad "R3 sustituto: exit=$RC"
case "$OUT" in "recover=0 reason=fallo-escritura"*) ok "error con sustituto: recover=0 reason=fallo-escritura";; *) bad "R3 sustituto: '$OUT'";; esac
# El borrado falla (el directorio perdio el permiso): el bloque se vacia en vez de quedar con texto.
mkdir -p "$TMP/or3-rm/manifest.json"
OUT=$(envuelto "os.remove = lambda p: (_ for _ in ()).throw(PermissionError(13, 'sin permiso', p))" "$TMP/or3-rm"); RC=$?
[ $RC -eq 0 ] && ok "borrado falla: sale 0" || bad "R3 borrado: exit=$RC"
case "$OUT" in "recover=0 reason=fallo-escritura"*) ok "borrado falla: recover=0 reason=fallo-escritura";; *) bad "R3 borrado: $OUT";; esac
grep -rqF "SECRETO-EN-TRAMO" "$TMP/or3-rm" && bad "R3 borrado: queda texto crudo" || ok "borrado falla: el bloque queda vacio"
# Ni borrar ni vaciar: el texto queda, pero la linea lo dice para que Step 0b avise.
mkdir -p "$TMP/or3-resto/manifest.json"
# Desde la ronda 4 el vaciado usa os.ftruncate sobre un descriptor: se parchean las dos formas.
OUT=$(envuelto "os.remove = os.truncate = os.ftruncate = lambda p, *a: (_ for _ in ()).throw(PermissionError(13, 'sin permiso', p))" "$TMP/or3-resto"); RC=$?
[ $RC -eq 0 ] && ok "ni borrar ni vaciar: sale 0" || bad "R3 resto: exit=$RC"
case "$OUT" in "recover=0 reason=fallo-escritura "*" restos=1"*) ok "ni borrar ni vaciar: avisa restos=1";; *) bad "R3 resto: $OUT";; esac

echo "R4. ronda 4 de Codex sobre 2.41.7: otras excepciones, vaciado al salir, ruta con sustituto,"
echo "    restos de mas, --out-dir enlace, enlace puesto en lugar del bloque, manifest como marca"
# Enlaces reales: en Git Bash sin modo desarrollador `ln -s` copia, y los casos de enlace no prueban nada.
ln -s "$F" "$TMP/prueba-enlace" 2>/dev/null; [ -L "$TMP/prueba-enlace" ] && ENLACES=1 || ENLACES=0
# Un preTokens que no es numero no es un fallo de escritura: recupera el tramo con pre_tokens=0.
F4="$TMP/r4-pre.jsonl"
{ u p1 "SECRETO-EN-TRAMO"; bound '"no-es-numero"'; summ; ckcmd p2; ckskl p2; } > "$F4"
OUT=$(run "$F4" "$TMP/or4-pre" 2>/dev/null); RC=$?
[ $RC -eq 0 ] && ok "preTokens no numerico: sale 0" || bad "R4 preTokens: exit=$RC"
case "$OUT" in "recover=1 compactions=1 pre_tokens=0 "*) ok "preTokens no numerico: recover=1 pre_tokens=0";; *) bad "R4 preTokens: $OUT";; esac
# Una excepcion que no es OSError a media escritura (MemoryError en el manifest): no queda el bloque.
OUT=$(envuelto "import json
json.dump = lambda *a, **k: (_ for _ in ()).throw(MemoryError())" "$TMP/or4-mem"); RC=$?
[ $RC -eq 0 ] && ok "MemoryError: sale 0" || bad "R4 MemoryError: exit=$RC"
case "$OUT" in "recover=0 reason=fallo-escritura error=MemoryError"*) ok "MemoryError: recover=0 reason=fallo-escritura";; *) bad "R4 MemoryError: $OUT";; esac
grep -rqF "SECRETO-EN-TRAMO" "$TMP/or4-mem" 2>/dev/null && bad "R4 MemoryError: queda texto crudo" || ok "MemoryError: no queda texto crudo"
# stdout cuyo segundo flush falla (el de la salida del interprete): la linea ya llego, sale 0.
OUT=$(envuelto "class C(io.TextIOBase):
    n = 0
    def reconfigure(self, **k): pass
    def write(self, s): return sys.__stdout__.write(s)
    def flush(self):
        C.n += 1
        if C.n >= 2: raise BrokenPipeError(32, 'tuberia rota al salir')
        sys.__stdout__.flush()
sys.stdout = C()" "$TMP/or4-late"); RC=$?
[ $RC -eq 0 ] && ok "vaciado al salir falla: sale 0" || bad "R4 vaciado al salir: exit=$RC"
case "$OUT" in "recover=1 "*) ok "vaciado al salir falla: la linea recover=1 llego";; *) bad "R4 vaciado al salir: $OUT";; esac
# recover=0 reason=sin-jsonl con un sustituto en la ruta (argv con bytes que no son UTF-8).
OUT=$(envuelto "sys.argv[sys.argv.index('--jsonl') + 1] = 'no-existe-\\udcff'" "$TMP/or4-ruta"); RC=$?
[ $RC -eq 0 ] && ok "ruta con sustituto: sale 0" || bad "R4 ruta con sustituto: exit=$RC"
case "$OUT" in "recover=0 reason=sin-jsonl "*) ok "ruta con sustituto: recover=0 reason=sin-jsonl";; *) bad "R4 ruta con sustituto: '$OUT'";; esac
# os.remove borra y luego falla: el archivo ya no esta, no es un resto.
mkdir -p "$TMP/or4-ido/manifest.json"
OUT=$(envuelto "_rm = os.remove
def rm(p):
    _rm(p)
    raise PermissionError(13, 'sin permiso', p)
os.remove = rm" "$TMP/or4-ido"); RC=$?
case "$OUT" in *restos=*) bad "R4 archivo ido: cuenta un resto que no existe: $OUT";; "recover=0 reason=fallo-escritura"*) ok "archivo ido: no lo cuenta como resto";; *) bad "R4 archivo ido: $OUT";; esac
if [ $ENLACES -eq 1 ]; then
  # --out-dir es un enlace a otro directorio: no se sigue.
  mkdir -p "$TMP/destino-dir"; ln -s "$TMP/destino-dir" "$TMP/or4-enlace"
  OUT=$(run "$F" "$TMP/or4-enlace" 2>/dev/null); RC=$?
  [ $RC -eq 0 ] && ok "--out-dir enlace: sale 0" || bad "R4 --out-dir enlace: exit=$RC"
  case "$OUT" in "recover=0 reason=fallo-escritura"*) ok "--out-dir enlace: recover=0 reason=fallo-escritura";; *) bad "R4 --out-dir enlace: $OUT";; esac
  [ -z "$(ls -A "$TMP/destino-dir")" ] && ok "--out-dir enlace: no escribe en el destino" || bad "R4 --out-dir enlace: escribio en el destino"
  # Otro pone un enlace en lugar del bloque antes de la limpieza: ni se vacia su destino ni se borra.
  printf 'CONSERVAR\n' > "$TMP/destino-carrera.txt"; mkdir -p "$TMP/or4-carrera/manifest.json"
  OUT=$(envuelto "_rm = os.remove
def rm(p):
    if p.endswith('chunk-01.md'):
        _rm(p)
        os.symlink('$TMP/destino-carrera.txt', p)
    raise PermissionError(13, 'sin permiso', p)
os.remove = rm" "$TMP/or4-carrera"); RC=$?
  [ $RC -eq 0 ] && ok "enlace en lugar del bloque: sale 0" || bad "R4 carrera: exit=$RC"
  has "enlace en lugar del bloque: no vacia el destino" "CONSERVAR" "$TMP/destino-carrera.txt"
  [ -L "$TMP/or4-carrera/chunk-01.md" ] && ok "enlace en lugar del bloque: no lo borra" || bad "R4 carrera: borro el enlace ajeno"
else
  ok "--out-dir enlace y carrera: sin enlaces reales en esta plataforma, no se prueban"
fi
# Si el manifest no se puede borrar pero el bloque si, el manifest se vacia (se limpia al reves):
# Step 0b solo usa recover=1 si manifest.json existe y no esta vacio.
mkdir -p "$TMP/or4-orden"
OUT=$(envuelto "_rm = os.remove
def rm(p):
    if p.endswith('manifest.json'): raise PermissionError(13, 'sin permiso', p)
    _rm(p)
os.remove = rm
_p = print
def pr(*a, **k):
    if a and str(a[0]).startswith('recover=1'): raise OSError('stdout fallo tras el manifest')
    return _p(*a, **k)
import builtins
builtins.print = pr" "$TMP/or4-orden"); RC=$?
case "$OUT" in "recover=0 reason=fallo-escritura"*) ok "print de recover=1 falla: recover=0";; *) bad "R4 orden: $OUT";; esac
[ -s "$TMP/or4-orden/manifest.json" ] && bad "R4 orden: el manifest quedo lleno" || ok "print de recover=1 falla: el manifest queda vacio o no esta"
grep -rqF "SECRETO-EN-TRAMO" "$TMP/or4-orden" && bad "R4 orden: queda texto crudo" || ok "print de recover=1 falla: no queda texto crudo"
# La regla de Step 0b que usaba el manifest como marca la reemplazo --verificar (ronda 6): su aserto
# esta en R6.

echo "R5. ronda 5 de Codex sobre 2.41.8: excepcion durante la limpieza, stdout que falla con otra excepcion"
# Un MemoryError en os.remove durante la limpieza: el bloque se vacia igual y sale 0.
mkdir -p "$TMP/or5-mem/manifest.json"
OUT=$(envuelto "os.remove = lambda p: (_ for _ in ()).throw(MemoryError())" "$TMP/or5-mem"); RC=$?
[ $RC -eq 0 ] && ok "MemoryError en la limpieza: sale 0" || bad "R5 MemoryError limpieza: exit=$RC"
case "$OUT" in "recover=0 reason=fallo-escritura"*) ok "MemoryError en la limpieza: recover=0 reason=fallo-escritura";; *) bad "R5 MemoryError limpieza: $OUT";; esac
grep -rqF "SECRETO-EN-TRAMO" "$TMP/or5-mem" && bad "R5 MemoryError limpieza: queda texto crudo" || ok "MemoryError en la limpieza: no queda texto crudo"
# stdout cuyo write da RuntimeError: no es OSError/UnicodeError/ValueError, y falla tambien en la
# linea recover=0.
OUT=$(envuelto "class C(io.TextIOBase):
    def reconfigure(self, **k): pass
    def write(self, s): raise RuntimeError('stdout raro')
    def flush(self): pass
sys.stdout = C()" "$TMP/or5-run"); RC=$?
[ $RC -eq 0 ] && ok "RuntimeError en stdout: sale 0" || bad "R5 RuntimeError stdout: exit=$RC"
grep -rqF "SECRETO-EN-TRAMO" "$TMP/or5-run" 2>/dev/null && bad "R5 RuntimeError stdout: queda texto crudo" || ok "RuntimeError en stdout: no queda texto crudo"
# stdout cerrado y ademas no se puede abrir os.devnull (sin descriptores libres).
OUT=$(envuelto "import builtins
_op = builtins.open
def op(f, *a, **k):
    if f == os.devnull: raise OSError(24, 'demasiados archivos abiertos')
    return _op(f, *a, **k)
builtins.open = op
class C(io.TextIOBase):
    def reconfigure(self, **k): pass
    def write(self, s): raise ValueError('I/O operation on closed file')
    def flush(self): raise ValueError('I/O operation on closed file')
sys.stdout = C()" "$TMP/or5-null"); RC=$?
[ $RC -eq 0 ] && ok "stdout cerrado sin os.devnull: sale 0" || bad "R5 sin devnull: exit=$RC"
grep -rqF "SECRETO-EN-TRAMO" "$TMP/or5-null" 2>/dev/null && bad "R5 sin devnull: queda texto crudo" || ok "stdout cerrado sin os.devnull: no queda texto crudo"
# Y en la ruta de exito: la linea llega aunque os.devnull no se pueda abrir.
OUT=$(envuelto "import builtins
_op = builtins.open
def op(f, *a, **k):
    if f == os.devnull: raise OSError(24, 'demasiados archivos abiertos')
    return _op(f, *a, **k)
builtins.open = op" "$TMP/or5-exito"); RC=$?
[ $RC -eq 0 ] && ok "exito sin os.devnull: sale 0" || bad "R5 exito sin devnull: exit=$RC"
case "$OUT" in "recover=1 "*) ok "exito sin os.devnull: recover=1";; *) bad "R5 exito sin devnull: $OUT";; esac

echo "R6. ronda 6 de Codex sobre 2.41.9: close que falla tras vaciar, stdout roto en las salidas"
echo "    tempranas, y --verificar para que Step 0b no use un tramo incompleto"
# os.close falla despues de un ftruncate que si vacio el bloque: no es un resto.
mkdir -p "$TMP/or6-close/manifest.json"
OUT=$(envuelto "_cl = os.close
def cl(fd):
    _cl(fd)
    raise OSError(9, 'close fallo')
os.close = cl
os.remove = lambda p: (_ for _ in ()).throw(PermissionError(13, 'sin permiso', p))" "$TMP/or6-close"); RC=$?
case "$OUT" in *restos=*) bad "R6 close: cuenta un resto que ya se vacio: $OUT";; "recover=0 reason=fallo-escritura"*) ok "close falla tras vaciar: no es resto";; *) bad "R6 close: $OUT";; esac
grep -rqF "SECRETO-EN-TRAMO" "$TMP/or6-close" && bad "R6 close: queda texto crudo" || ok "close falla tras vaciar: el bloque queda vacio"
# stdout roto en las salidas tempranas (sin JSONL, sin compactacion): sale 0.
CERRADO="class C(io.TextIOBase):
    def reconfigure(self, **k): pass
    def write(self, s): raise ValueError('I/O operation on closed file')
    def flush(self): raise ValueError('I/O operation on closed file')
sys.stdout = C()"
OUT=$(envuelto "$CERRADO
sys.argv[sys.argv.index('--jsonl') + 1] = 'no-existe.jsonl'" "$TMP/or6-t1"); RC=$?
[ $RC -eq 0 ] && ok "stdout roto en sin-jsonl: sale 0" || bad "R6 sin-jsonl: exit=$RC"
F6="$TMP/r6-sin.jsonl"; { u p1 "nada"; ckcmd p2; ckskl p2; } > "$F6"
OUT=$(envuelto "$CERRADO
sys.argv[sys.argv.index('--jsonl') + 1] = '$F6'" "$TMP/or6-t2"); RC=$?
[ $RC -eq 0 ] && ok "stdout roto en sin-compactacion: sale 0" || bad "R6 sin-compactacion: exit=$RC"
# --verificar DIR: solo verificado=1 si el manifest es JSON, cada bloque esta en DIR y los
# caracteres cuadran. Un tramo sano, y cinco formas de tramo incompleto.
ver(){ python3 "$BIN/compaction-recover.py" --verificar "$1" 2>/dev/null; }
OUT=$(run "$F" "$TMP/or6-sano" --chunk-chars 60 2>/dev/null)
case "$(ver "$TMP/or6-sano")" in "verificado=1 "*) ok "verificar: tramo sano da verificado=1";; *) bad "R6 verificar sano: $(ver "$TMP/or6-sano")";; esac
for c in sin-bloque bloque-vacio bloque-corto manifest-vacio sin-manifest manifest-roto; do
  O="$TMP/or6-$c"; run "$F" "$O" >/dev/null 2>&1
  case $c in
    sin-bloque)     rm -f "$O/chunk-01.md";;
    bloque-vacio)   : > "$O/chunk-01.md";;
    bloque-corto)   printf '# corto\n' > "$O/chunk-01.md";;
    manifest-vacio) : > "$O/manifest.json";;
    sin-manifest)   rm -f "$O/manifest.json";;
    manifest-roto)  printf '{"chunks": [' > "$O/manifest.json";;
  esac
  case "$(ver "$O")" in "verificado=0 "*) ok "verificar: $c da verificado=0";; *) bad "R6 verificar $c: '$(ver "$O")'";; esac
done
# Un manifest que apunta a un archivo fuera de DIR no se da por bueno.
O="$TMP/or6-fuera"; run "$F" "$O" >/dev/null 2>&1
python3 -c "import json,sys; m=json.load(open(sys.argv[1])); m['chunks']=[sys.argv[2]]; json.dump(m, open(sys.argv[1],'w'))" "$O/manifest.json" "$F"
case "$(ver "$O")" in "verificado=0 "*) ok "verificar: bloque fuera de DIR da verificado=0";; *) bad "R6 verificar fuera: '$(ver "$O")'";; esac
for T in "$BIN/../templates/checkpoint-3t.md"; do
  has "Step 0b corre --verificar antes de usar el tramo" 'compaction-recover.py" --verificar "$RECOVER_DIR"' "$T"
done

echo "M. compactacion entre la marca del checkpoint actual y Step 0b: se recupera (adversario externo, 2026-09-28)"
F="$TMP/m.jsonl"
{ u p1 "TRABAJO-M previo"; ckcmd p2; ckskl p2; bound 400000; summ; } > "$F"
OUT=$(run "$F" "$TMP/om")
case "$OUT" in "recover=1 compactions=1 pre_tokens=400000 "*) ok "recover=1 con la compactacion posterior a la marca";; *) bad "M: $OUT";; esac
has   "recupera el trabajo previo"  "TRABAJO-M previo" "$TMP/om/chunk-01.md"
hasnt "no incluye el resumen lossy" "RESUMEN-LOSSY" "$TMP/om/chunk-01.md"

echo "Z. todo JSONL de estas pruebas es JSON valido: load() salta en silencio una linea rota, y un caso"
echo "   cuya linea clave no parsea pasa sin probar nada (paso con Q, ronda 5)"
python3 - "$TMP" <<'PY' && ok "todas las lineas de los fixtures parsean" || bad "hay fixtures con lineas que no parsean"
import glob, json, sys
malas = []
for f in glob.glob(sys.argv[1] + "/**/*.jsonl", recursive=True):
    for n, l in enumerate(open(f, encoding="utf-8"), 1):
        try:
            json.loads(l)
        except ValueError:
            malas.append(f"{f}:{n}")
print("\n".join("       " + m for m in malas))
sys.exit(1 if malas else 0)
PY

echo
# La ultima linea dice si hubo enlaces reales: sin ellos, los casos de enlace de R4 no corrieron y el
# resumen de tools/run-tests.sh lo marca como salto (ronda 6: el CI no dejaba constancia).
if [ $FAIL -ne 0 ]; then echo "HAY FALLOS"
elif [ $ENLACES -eq 1 ]; then echo "TODO VERDE (enlaces reales: si)"
else echo "TODO VERDE, 2 saltados (sin enlaces reales)"; fi
exit $FAIL
