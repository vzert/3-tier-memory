#!/bin/bash
# Prueba de la separacion de Step 8 de /checkpoint-3t en templates/checkpoint-3t-step8.md (2.42.0).
#
# El checkpoint imprime ese fichero con un bloque bash que lo busca en tres sitios: junto a $JBIN
# (el repo del plugin, o el plugin instalado), en $CLAUDE_PLUGIN_ROOT, y en el cache de
# ~/.claude/plugins. Si no esta en ninguno imprime STEP8=NONE y el template manda no inventar el
# snippet. Aqui se corre EL BLOQUE REAL del template (extraido, no copiado) en cada forma.
# Ademas: el contenido de Step 8 vive solo en el fichero nuevo, session-start.sh no lo instala como
# comando, y la frase que empujaba a inventar un callejon no queda en ningun portador.
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUG="$(cd "$BIN/.." && pwd)"
TPL="$PLUG/templates/checkpoint-3t.md"
S8="$PLUG/templates/checkpoint-3t-step8.md"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

# El bloque bash de Step 8 del template, tal cual.
python3 - "$TPL" > "$T/bloque.sh" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.index("## Step 8: Como retomar")
m = re.search(r"```bash\n(.*?)```", t[i:], re.S)
print(m.group(1))
PY
chk "el template trae el bloque que busca el fichero" "1" "$(grep -c 'checkpoint-3t-step8.md' "$T/bloque.sh" | awk '{print ($1>0)}')"
MARCA="$(sed -n 1p "$S8")"
corre() {   # $1 JBIN, $2 CLAUDE_PLUGIN_ROOT, $3 HOME
  env -i PATH="$PATH" HOME="$3" JBIN="$1" CLAUDE_PLUGIN_ROOT="$2" bash "$T/bloque.sh" 2>/dev/null | sed -n 1p
}
mkdir -p "$T/home-vacio"
echo "== JBIN del repo del plugin (\$PWD/plugins/3-tier-memory/bin) =="
chk "imprime el fichero" "$MARCA" "$(corre "$BIN" "" "$T/home-vacio")"
echo "== sin JBIN, con CLAUDE_PLUGIN_ROOT =="
chk "imprime el fichero" "$MARCA" "$(corre "" "$PLUG" "$T/home-vacio")"
echo "== sin JBIN ni CLAUDE_PLUGIN_ROOT (vacia en el Bash del agente): lo busca en el cache =="
C="$T/home/.claude/plugins/cache/mk/3-tier-memory/2.42.0/templates"; mkdir -p "$C"
printf 'COPIA-DEL-CACHE\n' > "$C/checkpoint-3t-step8.md"
chk "imprime la copia del cache" "COPIA-DEL-CACHE" "$(corre "" "" "$T/home")"
echo "== en ningun sitio: STEP8=NONE, nunca vacio =="
chk "STEP8=NONE" "STEP8=NONE" "$(corre "$T/no-existe/bin" "" "$T/home-vacio")"

echo "== el contenido de Step 8 vive solo en el fichero nuevo =="
chk "8a esta en el fichero nuevo" "1" "$(grep -c '^\*\*8a\. Persistir' "$S8")"
chk "8a ya no esta en el template" "0" "$(grep -c '^\*\*8a\. Persistir' "$TPL")"
chk "8e esta en el fichero nuevo" "1" "$(grep -c '^\*\*8e\. ' "$S8")"
chk "el template no pega el bloque de 7b en el reporte" "0" "$(grep -c 'el bloque de Step 7b' "$TPL")"
echo "== session-start.sh no lo instala como comando =="
chk "no esta en la lista de comandos" "0" "$(grep -E '^for cmd in ' "$BIN/session-start.sh" | grep -c 'step8')"
echo "== la frase que empujaba a inventar un callejon no queda en ningun portador del plugin =="
chk "ningun portador" "0" "$(grep -rl 'suele significar que no se exploro' "$PLUG/templates" "$PLUG/commands" "$BIN"/*.py "$BIN"/*.sh 2>/dev/null | grep -v "test-checkpoint-step8-split.sh" | wc -l | tr -d ' ')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
