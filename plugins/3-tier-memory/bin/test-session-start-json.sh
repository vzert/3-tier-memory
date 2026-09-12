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

echo "6. si falla SOLO la serializacion, el bloque del agente sale INTACTO en texto plano"
# El stub falla unicamente en la llamada que construye el JSON (la reconoce por
# `hookSpecificOutput`) y deja pasar todas las demas. Un stub que tumbe python3 entero
# tampoco construye el bloque de pendientes: probaria que sobrevive el PROTOCOLO, no que
# sobrevive lo que el fallback existe para salvar. (Hallazgo del adversario, 2026-09-11.)
REAL_PY="$(command -v python3)"
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/python3" <<'STUBEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in *hookSpecificOutput*) exit 1 ;; esac
done
exec "$REAL_PYTHON3" "$@"
STUBEOF
chmod +x "$STUB/python3"
REAL_PYTHON3="$REAL_PY" PATH="$STUB:$PATH" CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$BIN/session-start.sh" </dev/null > "$TMP/o4" 2>/dev/null
check "exit 0" "$?" "0"
check "NO es JSON" "$(python3 -c "import json;json.load(open('$TMP/o4'));print('si')" 2>/dev/null || echo no)" "no"
check "los pendientes siguen ahi" "$(grep -c 'PENDIENTES ABIERTOS (3)' "$TMP/o4")" "1"
check "la ALTA sigue inline" "$(grep -c 'Item de alta que lleva abierto' "$TMP/o4")" "1"
check "y el protocolo tambien" "$(grep -c 'PROTOCOLO' "$TMP/o4")" "1"

echo "6b. sin python3 en absoluto tampoco se emite JSON roto"
STUB2="$TMP/stub2"; mkdir -p "$STUB2"; printf '#!/bin/sh\nexit 1\n' > "$STUB2/python3"; chmod +x "$STUB2/python3"
PATH="$STUB2:$PATH" CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$BIN/session-start.sh" </dev/null > "$TMP/o4b" 2>/dev/null
check "exit 0" "$?" "0"
check "NO es JSON" "$(python3 -c "import json;json.load(open('$TMP/o4b'));print('si')" 2>/dev/null || echo no)" "no"

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

echo "9. un pendiente con la vieja sentinela en su texto no contamina el canal de la persona"
# La primera version separaba los dos bloques con `---3T-HUMANO---` dentro de la misma
# salida: un pendiente que la llevara en el texto partia el mensaje por ahi. Ahora el
# resumen de la persona se escribe en otro fichero, asi que la cadena es texto y ya esta.
P4="$TMP/p4"; nuevo_proyecto "$P4"
# Va bajo Alta prioridad, no al final del fichero: despues de `## Related` el parser lo
# saltaria por seccion cerrada y la prueba no probaria nada.
python3 - "$P4/memory/_pendientes.md" <<'INYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
item = "- [ ] Item con ---3T-HUMANO--- dentro del texto — _origen: [[sessions/x]]_ — _creado: 2026-02-01_\n"
s = s.replace("## Alta prioridad\n\n", "## Alta prioridad\n\n" + item, 1)
open(p, "w", encoding="utf-8").write(s)
INYEOF
correr "$P4" startup > "$TMP/o7"
check "sigue siendo JSON valido" "$(python3 -c "import json;json.load(open('$TMP/o7'));print('si')" 2>/dev/null)" "si"
check "el item con la cadena SI se parseo" \
  "$(python3 "$TMP/leer.py" "$TMP/o7" additionalContext | grep -c 'PENDIENTES ABIERTOS (4)')" "1"
check "y aparece entero en el bloque del agente" \
  "$(python3 "$TMP/leer.py" "$TMP/o7" additionalContext | grep -c 'Item con ---3T-HUMANO--- dentro del texto')" "1"
check "el mensaje de la persona empieza donde debe" \
  "$(python3 "$TMP/leer.py" "$TMP/o7" systemMessage | head -1 | grep -c '^MEMORIA 3T —')" "1"
check "el texto del pendiente no se cuela en el canal de la persona" \
  "$(python3 "$TMP/leer.py" "$TMP/o7" systemMessage | grep -c 'dentro del texto —$')" "0"

echo "10. un agente de Paperclip no recibe systemMessage aunque haya avisos"
P5="$TMP/p5"; nuevo_proyecto "$P5"
mkdir -p "$P5/memory/.journal/quarantine"
echo '{"roto":true}' > "$P5/memory/.journal/quarantine/ev.json"
OUT5=$(printf '%s' "{\"cwd\":\"$P5\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | PAPERCLIP_RUN_ID=run-123 CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null)
printf '%s' "$OUT5" > "$TMP/o8"
check "sin systemMessage" "$(python3 "$TMP/leer.py" "$TMP/o8" claves)" "hookSpecificOutput"
check "el aviso si llega al agente" \
  "$(python3 "$TMP/leer.py" "$TMP/o8" additionalContext | grep -c 'cuarentena')" "1"

echo "11. una corrida no interactiva no recibe systemMessage"
# Medido el 2026-09-11 con un hook de registro: `claude -p` deja
# CLAUDE_CODE_SESSION_ATTENDED=0 y CLAUDE_CODE_ENTRYPOINT=sdk-cli; la sesion interactiva
# deja 1 y cli. El canal se apaga solo con el "0" explicito.
OUT6=$(printf '%s' "{\"cwd\":\"$P\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null)
printf '%s' "$OUT6" > "$TMP/o9"
check "sin systemMessage" "$(python3 "$TMP/leer.py" "$TMP/o9" claves)" "hookSpecificOutput"
check "el agente si recibe lo suyo" \
  "$(python3 "$TMP/leer.py" "$TMP/o9" additionalContext | grep -c 'PENDIENTES ABIERTOS (3)')" "1"

echo "11b. sin la variable (CLI viejo) el canal sigue abierto"
OUT7=$(printf '%s' "{\"cwd\":\"$P\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | env -u CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null)
printf '%s' "$OUT7" > "$TMP/o10"
check "systemMessage presente" "$(python3 "$TMP/leer.py" "$TMP/o10" claves)" "hookSpecificOutput,systemMessage"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
