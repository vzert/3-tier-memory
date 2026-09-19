#!/bin/bash
# Prueba de bin/checkpoint-audit-nudge.sh.
#
# Lo que mas importa aqui NO es que avise, es que se CALLE cuando toca y que NO se calle con
# no-evidencia. Un aviso que salta cuando no toca se aprende a ignorar y entonces deja de avisar
# de lo que importa; un aviso que se apaga con cualquier cosa no vigila nada (learning 12).
#
# Las formas de los registros estan copiadas de un JSONL real de Claude Code, no inventadas:
#   - un `tool_result` se graba DENTRO de un registro `type:"user"`, no en uno propio;
#   - un prompt del usuario es `message.content` string, o una lista con un bloque `text`;
#   - un fichero inyectado (CLAUDE.md, recall, una ficha) es `type:"attachment"` y no tiene
#     `message`.
# Por eso la clasificacion del hook mira el tipo del BLOQUE y no el `type` del registro: filtrar
# por `type:"user"` habria tirado el caso bueno junto con el malo.
#
# Para comprobar que estos casos FALLAN sin el arreglo:
#   NUDGE=/ruta/al/checkpoint-audit-nudge.sh.viejo bash test-checkpoint-audit-nudge.sh
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
NUDGE="${NUDGE:-$BIN/checkpoint-audit-nudge.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

RESUMEN='  resumen: hecho=9 parcial=1 saltado=2 por-diseno=1'

# --- constructores de registros, con las formas reales -----------------------------------------
reg() {   # $1 = clase, $2.. = argumentos; imprime una linea JSONL
  python3 - "$@" <<'PYREG'
import json, sys
clase = sys.argv[1]
a = sys.argv[2:]
if clase == "assistant-text":
    r = {"type": "assistant", "message": {"role": "assistant",
         "content": [{"type": "text", "text": a[0]}]}}
elif clase == "tool-use":            # id, comando
    r = {"type": "assistant", "message": {"role": "assistant",
         "content": [{"type": "tool_use", "id": a[0], "name": "Bash",
                      "input": {"command": a[1]}}]}}
elif clase == "tool-result":         # id, salida
    r = {"type": "user", "message": {"role": "user",
         "content": [{"tool_use_id": a[0], "type": "tool_result", "content": a[1]}]}}
elif clase == "prompt-str":          # texto pegado por el usuario
    r = {"type": "user", "message": {"role": "user", "content": a[0]}}
elif clase == "prompt-bloque":       # prompt como lista con un bloque text
    r = {"type": "user", "message": {"role": "user",
         "content": [{"type": "text", "text": a[0]}]}}
elif clase == "attachment":          # fichero inyectado (CLAUDE.md, recall, una ficha)
    r = {"type": "attachment", "attachment": {"type": "instructions",
         "files": [{"path": a[0], "type": "User", "content": a[1]}]}}
else:
    raise SystemExit("clase desconocida: " + clase)
print(json.dumps(r, ensure_ascii=False))
PYREG
}

correr() {   # $1 = comando bash, $2 = transcript
  python3 -c "
import json,sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'transcript_path':sys.argv[2],'cwd':'$T'}))
" "$1" "$2" | bash "$NUDGE" 2>/dev/null
}

avisa()   { printf '%s' "$(correr "$1" "$2")" | grep -c 'no corriste'; }

CMT='git commit -m "checkpoint: 2026-09-19-demo — resumen"'
ORDEN='python3 "$JBIN/checkpoint-audit.py" "$MEMORY_DIR" --session-file "$SESSION_FILE" --repo-root .'

# --- transcripts -------------------------------------------------------------------------------
# 1. Sin rastro del audit
TSIN="$T/sin-audit.jsonl"
reg assistant-text "escribo la ficha" > "$TSIN"

# 2. CORRIDA REAL: el comando que invoca, y el resultado de ESA llamada con la linea de resumen
TREAL="$T/corrida-real.jsonl"
cp "$TSIN" "$TREAL"
reg tool-use "toolu_AUDIT01" "$ORDEN"                     >> "$TREAL"
reg tool-result "toolu_AUDIT01" "AUDITORIA DEL CHECKPOINT
$RESUMEN"                                                  >> "$TREAL"

# 3. El bloque de auditoria PEGADO en un prompt del usuario (el defecto que se arregla aqui)
TPROMPT="$T/pegado-en-prompt.jsonl"
cp "$TSIN" "$TPROMPT"
reg prompt-str "te pego lo de la sesion anterior:
AUDITORIA DEL CHECKPOINT
$RESUMEN"                                                  >> "$TPROMPT"

TPROMPTB="$T/pegado-en-prompt-bloque.jsonl"
cp "$TSIN" "$TPROMPTB"
reg prompt-bloque "AUDITORIA DEL CHECKPOINT
$RESUMEN"                                                  >> "$TPROMPTB"

# 4. La cadena dentro de un fichero INYECTADO (attachment): recall, CLAUDE.md, una ficha
TATTACH="$T/attachment.jsonl"
cp "$TSIN" "$TATTACH"
reg attachment "memory/sessions/2026-09-18-vieja.md" "## Reporte de cierre
$RESUMEN"                                                  >> "$TATTACH"

# 5. Un `cat` de una FICHA ANTERIOR. Step 7a manda pegar la salida LITERAL del audit en la ficha,
#    asi que toda ficha vieja lleva la cadena: leer una no es haber auditado esta sesion.
TCAT="$T/cat-ficha-vieja.jsonl"
cp "$TSIN" "$TCAT"
reg tool-use "toolu_CAT01" 'cat memory/sessions/2026-09-18-vieja.md'  >> "$TCAT"
reg tool-result "toolu_CAT01" "## Reporte de cierre
$RESUMEN"                                                  >> "$TCAT"

# 6. Solo la mitad del comando: se invoco el audit pero su salida no trae el resumen (fallo, ^C)
TMEDIO="$T/solo-comando.jsonl"
cp "$TSIN" "$TMEDIO"
reg tool-use "toolu_AUDIT02" "$ORDEN"                      >> "$TMEDIO"
reg tool-result "toolu_AUDIT02" "Traceback (most recent call last): FileNotFoundError" >> "$TMEDIO"

# 7. Solo la mitad de la salida: la linea existe pero su id no casa con ninguna invocacion
THUERFANA="$T/salida-huerfana.jsonl"
cp "$TSIN" "$THUERFANA"
reg tool-result "toolu_OTRA99" "$RESUMEN"                  >> "$THUERFANA"

# 8. Nombrar no es correr: un grep sobre el propio script cuya salida arrastra la linea
TGREP="$T/grep-al-script.jsonl"
cp "$TSIN" "$TGREP"
reg tool-use "toolu_GREP01" 'grep -rn "resumen" plugins/3-tier-memory/bin/checkpoint-audit.py' >> "$TGREP"
reg tool-result "toolu_GREP01" "694:$RESUMEN"              >> "$TGREP"

# 9. El script SOLO nombrado por el assistant, sin resultado ninguno
TSOLO="$T/solo-mencion.jsonl"
cp "$TSIN" "$TSOLO"
reg tool-use "toolu_SOLO01" "$ORDEN"                       >> "$TSOLO"

echo "== commit de checkpoint SIN audit en el transcript: avisa =="
O=$(correr "$CMT" "$TSIN")
chk "avisa" "1" "$(printf '%s' "$O" | grep -c 'no corriste')"
chk "dice que no bloquea" "1" "$(printf '%s' "$O" | grep -c 'un aviso, no un bloqueo')"
chk "nombra el paso" "1" "$(printf '%s' "$O" | grep -c 'Step 7a')"
chk "da el comando" "1" "$(printf '%s' "$O" | grep -c 'checkpoint-audit.py')"

echo "== CORRIDA REAL (comando + salida de ESA llamada): silencio =="
chk "silencio" "" "$(correr "$CMT" "$TREAL")"

echo "== NO-EVIDENCIA: la cadena que no viene de una corrida no silencia =="
# Estos cinco son el pendiente p-923368e616. Contra el script anterior todos FALLAN: buscaba
# `resumen: hecho=<n>` en la cola en crudo, sin mirar de donde venia.
chk "pegada en un prompt (content string)" "1" "$(avisa "$CMT" "$TPROMPT")"
chk "pegada en un prompt (bloque text)"     "1" "$(avisa "$CMT" "$TPROMPTB")"
chk "dentro de un fichero inyectado"        "1" "$(avisa "$CMT" "$TATTACH")"
chk "leida de una ficha anterior con cat"   "1" "$(avisa "$CMT" "$TCAT")"
chk "grep al propio script (nombrar!=correr)" "1" "$(avisa "$CMT" "$TGREP")"

echo "== IMPOSTOR: un comando que NOMBRA el script sin ejecutarlo no silencia =="
# Lo rompio un adversario externo contra la primera version de este arreglo: la expresion regular
# solo pedia que el nombre apareciera detras de un lanzador de python, no que fuera el programa
# ejecutado. Ahora el comando se tokeniza y se pregunta que fichero corre de verdad.
impostor() {   # $1 = etiqueta, $2 = comando impostor
  local TI="$T/impostor-$$-$RANDOM.jsonl"
  cp "$TSIN" "$TI"
  reg tool-use "toolu_IMP01" "$2"          >> "$TI"
  reg tool-result "toolu_IMP01" "$RESUMEN" >> "$TI"
  chk "$1" "1" "$(avisa "$CMT" "$TI")"
}
impostor "python3 -c que solo nombra el script"  'python3 -c '"'"'print("resumen: hecho=9")'"'"' checkpoint-audit.py'
impostor "python3 -m con el nombre detras"       'python3 -m json.tool checkpoint-audit.py'
impostor "echo del propio comando"               'echo python3 checkpoint-audit.py'
impostor "un .pyc, no el .py"                    'python3 plugins/3-tier-memory/bin/checkpoint-audit.pyc'
impostor "un .py.bak, no el .py"                 'python3 plugins/3-tier-memory/bin/checkpoint-audit.py.bak'
impostor "head del script"                       'head -50 plugins/3-tier-memory/bin/checkpoint-audit.py'
impostor "git show del script"                   'git show HEAD:plugins/3-tier-memory/bin/checkpoint-audit.py'
impostor "comillas sin cerrar (falla cerrado)"   'python3 "plugins/checkpoint-audit.py'

echo "== y las formas legitimas de invocarlo SI silencian =="
legitimo() {   # $1 = etiqueta, $2 = comando
  local TL="$T/legit-$$-$RANDOM.jsonl"
  cp "$TSIN" "$TL"
  reg tool-use "toolu_LEG01" "$2"          >> "$TL"
  reg tool-result "toolu_LEG01" "$RESUMEN" >> "$TL"
  chk "$1" "" "$(correr "$CMT" "$TL")"
}
legitimo "python3 con la ruta entre comillas" "$ORDEN"
legitimo "python sin el 3"                    'python plugins/3-tier-memory/bin/checkpoint-audit.py memory --session-file x.md'
legitimo "con -u delante"                     'python3 -u plugins/3-tier-memory/bin/checkpoint-audit.py memory --session-file x.md'
legitimo "con VAR=valor delante"              'PYTHONUTF8=1 python3 plugins/3-tier-memory/bin/checkpoint-audit.py memory --session-file x.md'
legitimo "detras de un cd y un &&"            'cd /tmp && python3 "$JBIN/checkpoint-audit.py" memory --session-file x.md'
legitimo "invocado directo (con permiso de ejecucion)" '"$JBIN/checkpoint-audit.py" memory --session-file x.md'

echo "== media prueba tampoco es prueba =="
chk "invocado pero sin linea de resumen"  "1" "$(avisa "$CMT" "$TMEDIO")"
chk "linea de resumen huerfana (id ajeno)" "1" "$(avisa "$CMT" "$THUERFANA")"
chk "invocado y sin resultado todavia"     "1" "$(avisa "$CMT" "$TSOLO")"

echo "== EL BUG AUTO-INFLIGIDO: su propio aviso no puede silenciarlo =="
# El texto del aviso menciona el script. Con la condicion mas vieja, el hook avisaba una vez,
# veia su propio aviso en el transcript y se callaba para siempre. Lo encontro un verificador
# externo. Se comprueba de dos formas: metiendo el aviso en el transcript, y midiendo el texto.
TAVISO="$T/con-aviso.jsonl"
cp "$TSIN" "$TAVISO"
AVISO=$(correr "$CMT" "$TSIN")
python3 - "$TAVISO" "$AVISO" <<'PYFIN'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": sys.argv[2]}}) + "\n")
PYFIN
chk "sigue avisando tras haber avisado" "1" "$(avisa "$CMT" "$TAVISO")"
# Y el aviso metido como salida de una herramienta, que es la via que SI silencia:
TAVISO2="$T/con-aviso-tool.jsonl"
cp "$TSIN" "$TAVISO2"
reg tool-use "toolu_AV01" 'echo hola'      >> "$TAVISO2"
reg tool-result "toolu_AV01" "$AVISO"      >> "$TAVISO2"
chk "su aviso como salida de herramienta tampoco silencia" "1" "$(avisa "$CMT" "$TAVISO2")"
# INVARIANTE medido sobre el texto, no sobre un caso: el aviso no puede contener la linea de
# resumen. Si alguien la mete algun dia, este aserto lo para antes de que el hook se autoapague.
chk "el aviso no contiene la linea de resumen" "0" "$(printf '%s' "$AVISO" | grep -cE 'resumen:[[:space:]]*hecho=[0-9]+')"

echo "== un commit cualquiera que no es el del checkpoint: silencio =="
chk "silencio (fix normal)" "" "$(correr 'git commit -m "fix: arregla el parser"' "$TSIN")"
chk "silencio (git status)" "" "$(correr 'git status --short' "$TSIN")"
chk "silencio (grep que menciona checkpoint)" "" "$(correr 'grep -r checkpoint memory/' "$TSIN")"
# Un commit normal cuyo COMANDO menciona la ruta del script, con mensaje ajeno: no es el del
# checkpoint. La condicion vieja (la palabra en cualquier parte del comando) saltaba aqui.
chk "silencio (commit normal que toca el script)" "" "$(correr 'git commit -m "fix: tipo en el audit" plugins/3-tier-memory/bin/checkpoint-audit.py' "$TSIN")"
chk "silencio (mensaje ajeno, ruta con checkpoint)" "" "$(correr 'git add bin/checkpoint-audit.py && git commit -m "refactor del parser"' "$TSIN")"

echo "== la palabra checkpoint sin git commit: silencio =="
chk "silencio" "" "$(correr 'python3 bin/journal-compact.py --memory-dir memory  # tras el checkpoint' "$TSIN")"

echo "== sin transcript legible: silencio, nunca un aviso a ciegas =="
chk "ruta inexistente" "" "$(correr "$CMT" "$T/no-existe.jsonl")"
chk "ruta vacia" "" "$(correr "$CMT" "")"

echo "== otra herramienta que no es Bash: silencio =="
O=$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"x"},"transcript_path":"'"$TSIN"'"}' | bash "$NUDGE" 2>/dev/null)
chk "silencio" "" "$O"

echo "== entrada rota: silencio y salida 0, nunca romper el commit =="
rc=0; O=$(printf '%s' 'esto no es json' | bash "$NUDGE" 2>/dev/null) || rc=$?
chk "silencio" "" "$O"
chk "sale 0" "0" "$rc"

echo "== transcript corrupto o con lineas partidas: no rompe =="
TROTO="$T/roto.jsonl"
cp "$TREAL" "$TROTO"
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result"' >> "$TROTO"   # linea partida
printf '%s\n' 'esto no es json en absoluto' >> "$TROTO"
rc=0; O=$(correr "$CMT" "$TROTO") || rc=$?
chk "sigue callado con la corrida real dentro" "" "$O"
chk "sale 0" "0" "$rc"

echo "== el aviso nunca bloquea: salida 0 tambien cuando avisa =="
rc=0
python3 -c "
import json
print(json.dumps({'tool_name':'Bash','tool_input':{'command':'''$CMT'''},'transcript_path':'$TSIN'}))
" | bash "$NUDGE" >/dev/null 2>&1 || rc=$?
chk "sale 0 avisando" "0" "$rc"

echo "== la ventana de lectura no puede partir la prueba en dos =="
# La prueba son DOS registros. Con una ventana estrecha, actividad posterior los empuja fuera —
# o peor, deja medio dentro — y el aviso salta tras una corrida legitima. Lo senalo un adversario
# externo. La ventana es ahora de 64 MB: en la practica, el fichero entero.
TLEJOS="$T/pareja-lejos.jsonl"
cp "$TREAL" "$TLEJOS"
python3 - "$TLEJOS" <<'PYFAR'
import json, sys
relleno = "y" * 900
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    for i in range(6000):   # ~5,5 MB de actividad DESPUES de la corrida del audit
        fh.write(json.dumps({"type": "assistant", "message": {"role": "assistant",
                 "content": [{"type": "text", "text": f"{i} {relleno}"}]}}) + "\n")
PYFAR
chk "sigue callado con 5,5 MB de ruido detras" "" "$(correr "$CMT" "$TLEJOS")"

echo "== rendimiento: una cola grande no puede colgar el hook (timeout 10s) =="
TGORDO="$T/gordo.jsonl"
python3 - "$TGORDO" <<'PYBIG'
import json, sys
relleno = "x" * 900
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for i in range(5000):
        fh.write(json.dumps({"type": "assistant", "message": {"role": "assistant",
                 "content": [{"type": "text", "text": f"{i} {relleno}"}]}}) + "\n")
PYBIG
ini=$(python3 -c 'import time;print(time.time())')
O=$(correr "$CMT" "$TGORDO")
seg=$(python3 -c "import time,sys;print('1' if time.time()-float(sys.argv[1])<3 else '0')" "$ini")
chk "avisa igual sobre 4,5 MB" "1" "$(printf '%s' "$O" | grep -c 'no corriste')"
chk "tarda menos de 3s" "1" "$seg"

echo
echo "pass=$pass fail=$fail  (nudge: $NUDGE)"
[ "$fail" -eq 0 ]
