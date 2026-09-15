#!/usr/bin/env bash
# Prueba del check de p-d72c123065: cuando CLAUDE_PROJECT_DIR ES el repo del propio plugin
# 3-tier-memory (tiene plugins/3-tier-memory/templates/), session-start.sh tiene que comparar
# .claude/commands/*.md contra ESE arbol de trabajo — no solo contra el plugin INSTALADO
# ($CLAUDE_PLUGIN_ROOT/templates), que es lo unico que el auto-update de mas arriba mira.
#
# El bloque de auto-update EXISTENTE (mas arriba en session-start.sh) sincroniza
# .claude/commands/<cmd>.md con $CLAUDE_PLUGIN_ROOT/templates/<cmd>.md ANTES de que corra el check
# de este fichero — y en estas pruebas CLAUDE_PLUGIN_ROOT apunta al plugin REAL de este repo (hace
# falta para que journal-compact.py y compania funcionen). Por eso el contenido "instalado" con el
# que termina .claude/commands/checkpoint-3t.md en cada prueba es el contenido REAL del plugin, no
# un texto inventado — las pruebas de mas abajo se apoyan en eso a proposito, no lo evitan.
#
# Lo que esta prueba defiende:
#   A. sin plugins/3-tier-memory/templates/ en el proyecto (instalacion normal), el check nuevo
#      no dispara nunca — eso ya lo cubre (o no) el auto-update viejo, no este;
#   B. CON ese marcador, un comando local que termina desincronizado del arbol de trabajo (tras el
#      auto-update contra el plugin instalado) dispara un aviso nombrando el comando, en
#      additionalContext Y en systemMessage;
#   C. cuando el arbol de trabajo lleva el MISMO contenido que el plugin instalado, no hay aviso
#      (sin falso positivo);
#   D. un comando que no existia localmente y se instala desde un plugin instalado desactualizado
#      SI cuenta como desincronizado si el resultado no coincide con el arbol — es exactamente el
#      caso real (checkpoint-3t se instalo/sincronizo desde el plugin en 2.24.7 mientras el arbol
#      ya iba en 2.25.1) y es el que este check existe para atrapar.
#
# Uso: test-self-repo-command-sync.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN/.." && pwd)"
REAL_TEMPLATE="$PLUGIN_ROOT/templates/checkpoint-3t.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

# Proyecto de prueba con memoria propia minima: sin esto el script sale en la linea
# "[ -z "$MEMORY_DIR" ] && { emit_output; exit 0; }" antes de llegar al bloque que se prueba aqui.
nuevo_proyecto() {
  local d="$1"
  mkdir -p "$d/memory/sessions" "$d/memory/.journal/pending" "$d/.claude/commands"
  cat > "$d/memory/_pendientes.md" <<'EOF'
---
type: index
---
# Pendientes

## Alta prioridad

## Media prioridad

## Related
EOF
}

correr() {
  local proj="$1"
  printf '%s' "{\"cwd\":\"$proj\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null
}

cat > "$TMP/leer.py" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
campo = sys.argv[2]
if campo == "systemMessage":
    print(d.get("systemMessage", ""))
else:
    print(d.get("hookSpecificOutput", {}).get("additionalContext", ""))
PYEOF

echo "1. sin plugins/3-tier-memory/templates/ (instalacion normal), no dispara el check nuevo"
P1="$TMP/p1"; nuevo_proyecto "$P1"
echo "version vieja local" > "$P1/.claude/commands/checkpoint-3t.md"
correr "$P1" > "$TMP/o1"
AC1=$(python3 "$TMP/leer.py" "$TMP/o1" additionalContext)
check "sin aviso DESINCRONIZADO (repo del propio plugin)" "$(printf '%s' "$AC1" | grep -c '⚠ DESINCRONIZADO')" "0"

echo "2. CON el marcador propio del repo, un comando que termina desincronizado del arbol dispara aviso"
P2="$TMP/p2"; nuevo_proyecto "$P2"
mkdir -p "$P2/plugins/3-tier-memory/templates"
# El arbol de trabajo va MAS ADELANTE que el plugin instalado: el auto-update de arriba deja el
# comando local con el contenido REAL del plugin instalado, que no es este texto.
echo "contenido version 2.25.1 (arbol de trabajo, mas nuevo que el plugin instalado)" \
  > "$P2/plugins/3-tier-memory/templates/checkpoint-3t.md"
echo "lo que sea, el auto-update lo va a pisar de todos modos" > "$P2/.claude/commands/checkpoint-3t.md"
correr "$P2" > "$TMP/o2"
AC2=$(python3 "$TMP/leer.py" "$TMP/o2" additionalContext)
SM2=$(python3 "$TMP/leer.py" "$TMP/o2" systemMessage)
check "additionalContext dice DESINCRONIZADO" "$(printf '%s' "$AC2" | grep -c '⚠ DESINCRONIZADO')" "1"
check "la linea del aviso nombra el comando" \
  "$(printf '%s' "$AC2" | grep '⚠ DESINCRONIZADO' | grep -c '/checkpoint-3t')" "1"
check "systemMessage tambien avisa a la persona" \
  "$(printf '%s' "$SM2" | grep -c 'no coincide con plugins/3-tier-memory/templates')" "1"

echo "3. cuando el arbol de trabajo lleva el MISMO contenido que el plugin instalado, no hay aviso"
P3="$TMP/p3"; nuevo_proyecto "$P3"
mkdir -p "$P3/plugins/3-tier-memory/templates"
cp "$REAL_TEMPLATE" "$P3/plugins/3-tier-memory/templates/checkpoint-3t.md"
# El local arranca vacio a proposito: el auto-update lo instala desde el plugin real (que es
# BYTE A BYTE el mismo contenido que acabamos de copiar al arbol), asi que al terminar coinciden.
correr "$P3" > "$TMP/o3"
AC3=$(python3 "$TMP/leer.py" "$TMP/o3" additionalContext)
check "sin aviso DESINCRONIZADO" "$(printf '%s' "$AC3" | grep -c '⚠ DESINCRONIZADO')" "0"
check "el comando SI se instalo (confirma que de verdad se comparo, no que el check no corrio)" \
  "$(printf '%s' "$AC3" | grep -c 'INSTALADO:.*checkpoint-3t')" "1"

echo "4. un comando recien instalado desde un plugin instalado desactualizado SI cuenta como desincronizado"
P4="$TMP/p4"; nuevo_proyecto "$P4"
mkdir -p "$P4/plugins/3-tier-memory/templates"
echo "contenido del arbol, mas nuevo que lo que trae el plugin instalado" \
  > "$P4/plugins/3-tier-memory/templates/checkpoint-3t.md"
# checkpoint-3t.md NO existe en .claude/commands/: el bloque de auto-update lo instala desde el
# plugin INSTALADO (el real de este repo, via CLAUDE_PLUGIN_ROOT) — que no coincide con el arbol
# sintetico de arriba. Es el caso real del incidente: un comando "recien sincronizado" que queda
# atras del arbol sin que nada lo dijera hasta ahora.
correr "$P4" > "$TMP/o4"
AC4=$(python3 "$TMP/leer.py" "$TMP/o4" additionalContext)
check "SI avisa aunque el comando se acabe de instalar" "$(printf '%s' "$AC4" | grep -c '⚠ DESINCRONIZADO')" "1"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
