#!/usr/bin/env bash
# Pruebas de la salida de session-start.sh (v2.17.0): un solo objeto JSON con dos canales.
#
# Lo que estas pruebas defienden:
#   A. el JSON parsea y lleva `additionalContext` (agente) y `systemMessage` (persona);
#   B. `systemMessage` solo sale en source=startup|resume — y en `clear`/`compact` el bloque
#      del AGENTE SIGUE SALIENDO. Es la regresion que importa: filtrar con el `matcher` de
#      hooks.json apagaria el hook entero justo cuando el agente acaba de perder el contexto;
#   C. si la serializacion falla, sale texto plano con el bloque del agente y exit 0 — nunca
#      un JSON a medias, que para Claude Code es "el hook no hizo nada";
#   D. los avisos que solo puede resolver una persona (cuarentena, secretos) llegan a la persona.
#
# Uso: test-session-start-json.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

# Proyecto de prueba con memoria propia: los numeros tienen que ser deterministas.
nuevo_proyecto() {
  local d="$1"
  mkdir -p "$d/memory/sessions" "$d/memory/.journal/pending"
  cat > "$d/memory/_pendientes.md" <<'EOF'
---
type: index
---
# Pendientes

## Alta prioridad

- [ ] Item de alta que lleva abierto desde enero — _origen: [[sessions/x]]_ — _creado: 2026-01-05_

## Media prioridad

- [ ] Item de media mas reciente — _origen: [[sessions/x]]_ — _creado: 2026-09-01_
- [ ] Item de media viejisimo — _origen: [[sessions/x]]_ — _creado: 2026-01-02_

## Related
EOF
}

# Corre el hook con un payload de SessionStart y devuelve stdout crudo.
correr() {
  local proj="$1" src="$2"
  printf '%s' "{\"cwd\":\"$proj\",\"source\":\"$src\",\"hook_event_name\":\"SessionStart\"}" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null
}

cat > "$TMP/leer.py" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
campo = sys.argv[2]
if campo == "claves":
    print(",".join(sorted(d.keys())))
elif campo == "systemMessage":
    print(d.get("systemMessage", ""))
else:
    print(d.get("hookSpecificOutput", {}).get("additionalContext", ""))
PYEOF

echo "1. source=startup: un JSON con los dos canales"
P="$TMP/p1"; nuevo_proyecto "$P"
correr "$P" startup > "$TMP/o1"
check "parsea como JSON" "$(python3 -c "import json,sys;json.load(open('$TMP/o1'));print('si')" 2>/dev/null)" "si"
check "lleva los dos campos" "$(python3 "$TMP/leer.py" "$TMP/o1" claves)" "hookSpecificOutput,systemMessage"

echo "2. el mensaje a la persona trae conteo, los mas antiguos y que hacer"
SM=$(python3 "$TMP/leer.py" "$TMP/o1" systemMessage)
check "cuenta los 3 pendientes" "$(printf '%s' "$SM" | grep -c '3 pendientes abiertos')" "1"
check "nombra el mas antiguo" "$(printf '%s' "$SM" | grep -c 'Item de media viejisimo')" "1"
check "dice el comando" "$(printf '%s' "$SM" | grep -c '/triage-3t')" "1"

echo "3. el bloque del agente lleva ALTA inline y NO lista MEDIA"
AC=$(python3 "$TMP/leer.py" "$TMP/o1" additionalContext)
check "la ALTA va inline" "$(printf '%s' "$AC" | grep -c 'Item de alta que lleva abierto')" "1"
check "las MEDIA no se listan" "$(printf '%s' "$AC" | grep -c 'Item de media')" "0"
check "el total sigue estando" "$(printf '%s' "$AC" | grep -c 'PENDIENTES ABIERTOS (3)')" "1"

echo "4. source=clear: la persona no recibe nada, el AGENTE SI (regresion del matcher)"
correr "$P" clear > "$TMP/o2"
check "sin systemMessage" "$(python3 "$TMP/leer.py" "$TMP/o2" claves)" "hookSpecificOutput"
check "con additionalContext" \
  "$(python3 "$TMP/leer.py" "$TMP/o2" additionalContext | grep -c 'PENDIENTES ABIERTOS (3)')" "1"

echo "5. source=resume si habla con la persona"
correr "$P" resume > "$TMP/o3"
check "systemMessage presente" "$(python3 "$TMP/leer.py" "$TMP/o3" claves)" "hookSpecificOutput,systemMessage"

echo "6. si la serializacion falla, texto plano y exit 0 (nunca JSON a medias)"
STUB="$TMP/stub"; mkdir -p "$STUB"; printf '#!/bin/sh\nexit 1\n' > "$STUB/python3"; chmod +x "$STUB/python3"
PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$BIN/session-start.sh" </dev/null > "$TMP/o4" 2>/dev/null
check "exit 0" "$?" "0"
check "NO es JSON" "$(python3 -c "import json;json.load(open('$TMP/o4'));print('si')" 2>/dev/null || echo no)" "no"
check "el bloque del agente sobrevive" "$(grep -c 'PROTOCOLO' "$TMP/o4")" "1"

echo "7. la cuarentena del journal llega a la persona"
P2="$TMP/p2"; nuevo_proyecto "$P2"
mkdir -p "$P2/memory/.journal/quarantine"
echo '{"roto":true}' > "$P2/memory/.journal/quarantine/ev.json"
echo 'ancla borrada' > "$P2/memory/.journal/quarantine/ev.reason"
correr "$P2" startup > "$TMP/o5"
check "aviso de cuarentena en systemMessage" \
  "$(python3 "$TMP/leer.py" "$TMP/o5" systemMessage | grep -c 'cuarentena')" "1"
check "y tambien en el del agente" \
  "$(python3 "$TMP/leer.py" "$TMP/o5" additionalContext | grep -c 'cuarentena')" "1"

echo "8. sin sistema de memoria no revienta ni ensucia stdout"
P3="$TMP/p3"; mkdir -p "$P3"
correr "$P3" startup > "$TMP/o6"
check "exit 0" "$?" "0"
check "no deja basura en stdout" \
  "$([ ! -s "$TMP/o6" ] && echo vacio || (python3 -c "import json;json.load(open('$TMP/o6'))" 2>/dev/null && echo json || echo basura))" \
  "vacio"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
