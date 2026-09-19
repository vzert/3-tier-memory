#!/bin/bash
# Prueba de bin/checkpoint-audit-nudge.sh.
#
# Lo que mas importa aqui NO es que avise, es que se CALLE: un aviso que salta cuando no toca se
# aprende a ignorar, y entonces deja de avisar de lo que importa. Por eso hay mas casos de
# silencio que de aviso.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

# Transcript sin rastro del audit
TSIN="$T/sin-audit.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"escribo la ficha"}]}}' > "$TSIN"
# Transcript con una CORRIDA REAL del audit (su ultima linea)
TCON="$T/con-audit.jsonl"
cp "$TSIN" "$TCON"
printf '%s\n' '{"type":"user","message":{"content":"AUDITORIA DEL CHECKPOINT ... resumen: hecho=9 parcial=1 saltado=2 por-diseno=1"}}' >> "$TCON"
# Transcript donde el script SOLO se NOMBRA (comando que pudo fallar, prompt, trozo del template)
TSOLO="$T/solo-mencion.jsonl"
cp "$TSIN" "$TSOLO"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"python3 bin/checkpoint-audit.py memory --session-file x.md"}}]}}' >> "$TSOLO"
# Transcript que contiene el AVISO DE ESTE MISMO HOOK (el caso auto-infligido)
TAVISO="$T/con-aviso.jsonl"
cp "$TSIN" "$TAVISO"

correr() {   # $1 = comando bash, $2 = transcript
  python3 -c "
import json,sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':sys.argv[1]},'transcript_path':sys.argv[2],'cwd':'$T'}))
" "$1" "$2" | bash "$BIN/checkpoint-audit-nudge.sh" 2>/dev/null
}

CMT='git commit -m "checkpoint: 2026-09-19-demo — resumen"'

echo "== commit de checkpoint SIN audit en el transcript: avisa =="
O=$(correr "$CMT" "$TSIN")
chk "avisa" "1" "$(printf '%s' "$O" | grep -c 'no corriste')"
chk "dice que no bloquea" "1" "$(printf '%s' "$O" | grep -c 'un aviso, no un bloqueo')"
chk "da el comando" "1" "$(printf '%s' "$O" | grep -c 'checkpoint-audit.py')"

echo "== el MISMO commit con el audit ya corrido: silencio =="
chk "silencio" "" "$(correr "$CMT" "$TCON")"

echo "== el script solo NOMBRADO (no corrido) NO silencia =="
# Un comando que pudo fallar, un prompt o un trozo del template mencionan el nombre sin que la
# auditoria se haya hecho. Silenciar con eso era aceptar no-evidencia.
chk "avisa igual" "1" "$(printf '%s' "$(correr "$CMT" "$TSOLO")" | grep -c 'no corriste')"

echo "== EL BUG AUTO-INFLIGIDO: su propio aviso no puede silenciarlo =="
# El texto del aviso contiene `checkpoint-audit.py`. Con la condicion vieja, el hook avisaba una
# vez, veia su propio aviso en el transcript y se callaba para siempre: se desactivaba solo tras
# el primer uso. Lo encontro un verificador externo.
AVISO=$(correr "$CMT" "$TSIN")
python3 - "$TAVISO" "$AVISO" <<'PYFIN'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "message": {"content": sys.argv[2]}}) + "\n")
PYFIN
chk "sigue avisando tras haber avisado" "1" "$(printf '%s' "$(correr "$CMT" "$TAVISO")" | grep -c 'no corriste')"

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
O=$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"x"},"transcript_path":"'"$TSIN"'"}' | bash "$BIN/checkpoint-audit-nudge.sh" 2>/dev/null)
chk "silencio" "" "$O"

echo "== entrada rota: silencio y salida 0, nunca romper el commit =="
rc=0; O=$(printf '%s' 'esto no es json' | bash "$BIN/checkpoint-audit-nudge.sh" 2>/dev/null) || rc=$?
chk "silencio" "" "$O"
chk "sale 0" "0" "$rc"

echo "== el aviso nunca bloquea: salida 0 tambien cuando avisa =="
rc=0
python3 -c "
import json
print(json.dumps({'tool_name':'Bash','tool_input':{'command':'''$CMT'''},'transcript_path':'$TSIN'}))
" | bash "$BIN/checkpoint-audit-nudge.sh" >/dev/null 2>&1 || rc=$?
chk "sale 0 avisando" "0" "$rc"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
