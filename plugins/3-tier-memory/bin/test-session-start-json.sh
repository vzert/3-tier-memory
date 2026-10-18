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
#   D. los avisos que solo puede resolver una persona (cuarentena, secretos, backfill) llegan a la persona;
#   E. desde 2.63.0 ningun pendiente sale en el arranque, por ninguno de los dos canales, y sin
#      ningun aviso para la persona no hay `systemMessage` (medido: el agente uso la lista en
#      1 de 40 sesiones; a la persona le tapaba los avisos de comandos por correr).
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

# Mismo proyecto con un aviso que solo resuelve la persona (cuarentena del journal): sirve para
# probar el canal de la persona ahora que los pendientes ya no lo llenan.
proyecto_con_aviso() {
  nuevo_proyecto "$1"
  mkdir -p "$1/memory/.journal/quarantine"
  echo '{"roto":true}' > "$1/memory/.journal/quarantine/ev.json"
  echo 'ancla borrada' > "$1/memory/.journal/quarantine/ev.reason"
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

echo "0. el primer arranque instala los comandos y se lo dice a la persona"
P="$TMP/p1"; nuevo_proyecto "$P"
correr "$P" startup > "$TMP/o0"
check "la persona ve los comandos instalados" \
  "$(python3 "$TMP/leer.py" "$TMP/o0" systemMessage | grep -c 'comandos nuevos del plugin instalados: /checkpoint-3t')" "1"
check "el agente tambien" "$(python3 "$TMP/leer.py" "$TMP/o0" additionalContext | grep -c '^INSTALADO:')" "1"
# Un comando local distinto del plugin se actualiza y tambien se avisa a la persona.
printf 'viejo\n' > "$P/.claude/commands/status-3t.md"
correr "$P" startup > "$TMP/o0b"
check "la persona ve el comando actualizado" \
  "$(python3 "$TMP/leer.py" "$TMP/o0b" systemMessage | grep -c 'comandos actualizados a la version nueva del plugin: /status-3t')" "1"

echo "0b. un comando viejo sin sufijo se renombra, el JSON sigue valido y la persona lo ve"
PM="$TMP/pm"; nuevo_proyecto "$PM"; mkdir -p "$PM/.claude/commands"
printf 'viejo\n' > "$PM/.claude/commands/checkpoint.md"
correr "$PM" startup > "$TMP/om"
check "sigue siendo JSON valido (la flecha no rompe el UTF-8)" \
  "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print('si')" "$TMP/om" 2>/dev/null)" "si"
check "la persona ve el renombre" \
  "$(python3 "$TMP/leer.py" "$TMP/om" systemMessage | grep -c 'renombrados con sufijo -3t: /checkpoint→/checkpoint-3t')" "1"

echo "1. source=startup sin avisos: JSON solo con el canal del agente"
# Tercer arranque del mismo proyecto: los comandos ya estan y no hay nada que avisar.
correr "$P" startup > "$TMP/o1"
check "parsea como JSON" "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print('si')" "$TMP/o1" 2>/dev/null)" "si"
check "sin systemMessage: no hay nada que la persona deba correr" "$(python3 "$TMP/leer.py" "$TMP/o1" claves)" "hookSpecificOutput"

echo "2. ningun pendiente sale en el arranque, por ningun canal"
AC=$(python3 "$TMP/leer.py" "$TMP/o1" additionalContext)
check "el agente no recibe la lista" "$(printf '%s' "$AC" | grep -c 'PENDIENTES ABIERTOS')" "0"
check "ni el texto de un ALTA" "$(grep -c 'Item de alta que lleva abierto' "$TMP/o1")" "0"
check "ni el de un MEDIA" "$(grep -c 'Item de media' "$TMP/o1")" "0"
check "ni el resumen viejo de la persona" "$(grep -c 'MEMORIA 3T\|Cierra o descarta\|Los mas antiguos' "$TMP/o1")" "0"
check "el agente sigue recibiendo el protocolo" "$(printf '%s' "$AC" | grep -c '^PROTOCOLO')" "1"

echo "3. con un aviso para la persona, systemMessage lleva el aviso y ningun pendiente"
PA="$TMP/pa"; proyecto_con_aviso "$PA"
correr "$PA" startup > "$TMP/oa"
SMA=$(python3 "$TMP/leer.py" "$TMP/oa" systemMessage)
check "systemMessage presente" "$(python3 "$TMP/leer.py" "$TMP/oa" claves)" "hookSpecificOutput,systemMessage"
check "lleva el aviso" "$(printf '%s' "$SMA" | grep -c 'cuarentena')" "1"
check "y ningun pendiente" "$(printf '%s' "$SMA" | grep -c 'pendientes abiertos\|Item de')" "0"

echo "3b. BACKFILL PENDIENTE llega a los dos canales (antes solo al agente)"
# HOME falso: el contador lee $HOME/.claude/projects/<cwd codificado>/*.jsonl. Dos sesiones sin
# procesar y ningun progreso = 2. Sin payload de transcript_path no se descuenta la actual.
FH="$TMP/fakehome"; PB="$TMP/pb"; nuevo_proyecto "$PB"
ENC=$(echo "$PB" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$FH/.claude/projects/$ENC"
: > "$FH/.claude/projects/$ENC/s1.jsonl"; : > "$FH/.claude/projects/$ENC/s2.jsonl"
printf '%s' "{\"cwd\":\"$PB\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | HOME="$FH" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null > "$TMP/ob"
check "la persona ve el backfill con su comando" \
  "$(python3 "$TMP/leer.py" "$TMP/ob" systemMessage | grep -c 'BACKFILL PENDIENTE: 2 sesiones.*/backfill-3t')" "1"
check "el agente tambien" \
  "$(python3 "$TMP/leer.py" "$TMP/ob" additionalContext | grep -c 'BACKFILL PENDIENTE: 2')" "1"

echo "4. source=clear: la persona no recibe nada, el AGENTE SI (regresion del matcher)"
correr "$PA" clear > "$TMP/o2"
check "sin systemMessage" "$(python3 "$TMP/leer.py" "$TMP/o2" claves)" "hookSpecificOutput"
check "con additionalContext" \
  "$(python3 "$TMP/leer.py" "$TMP/o2" additionalContext | grep -c '^PROTOCOLO')" "1"

echo "5. source=resume si habla con la persona"
correr "$PA" resume > "$TMP/o3"
check "systemMessage presente" "$(python3 "$TMP/leer.py" "$TMP/o3" claves)" "hookSpecificOutput,systemMessage"

echo "6. si falla SOLO la serializacion, el bloque del agente sale INTACTO en texto plano"
# El stub falla unicamente en la llamada que construye el JSON (la reconoce por
# `hookSpecificOutput`) y deja pasar todas las demas. Un stub que tumbe python3 entero
# tampoco construye los bloques que salen de python. (Hallazgo del adversario, 2026-09-11.)
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
check "NO es JSON" "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print('si')" "$TMP/o4" 2>/dev/null || echo no)" "no"
check "el bloque del agente sigue ahi" "$(grep -c 'PROTOCOLO' "$TMP/o4")" "1"
check "y tampoco aqui salen pendientes" "$(grep -c 'PENDIENTES ABIERTOS\|Item de alta' "$TMP/o4")" "0"

echo "6b. sin python3 en absoluto tampoco se emite JSON roto"
STUB2="$TMP/stub2"; mkdir -p "$STUB2"; printf '#!/bin/sh\nexit 1\n' > "$STUB2/python3"; chmod +x "$STUB2/python3"
PATH="$STUB2:$PATH" CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash "$BIN/session-start.sh" </dev/null > "$TMP/o4b" 2>/dev/null
check "exit 0" "$?" "0"
check "NO es JSON" "$(python3 -c "import json,sys;json.load(open(sys.argv[1]));print('si')" "$TMP/o4b" 2>/dev/null || echo no)" "no"

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
  "$([ ! -s "$TMP/o6" ] && echo vacio || (python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$TMP/o6" 2>/dev/null && echo json || echo basura))" \
  "vacio"

# (El caso 9, la sentinela ---3T-HUMANO--- en el texto de un pendiente, se fue con el resumen de
# pendientes de la persona en 2.63.0: ningun texto de pendiente llega ya a ningun canal.)

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
OUT6=$(printf '%s' "{\"cwd\":\"$PA\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null)
printf '%s' "$OUT6" > "$TMP/o9"
check "sin systemMessage" "$(python3 "$TMP/leer.py" "$TMP/o9" claves)" "hookSpecificOutput"
check "el agente si recibe lo suyo" \
  "$(python3 "$TMP/leer.py" "$TMP/o9" additionalContext | grep -c 'cuarentena')" "1"

echo "11b. sin la variable (CLI viejo) el canal sigue abierto"
OUT7=$(printf '%s' "{\"cwd\":\"$PA\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | env -u CLAUDE_CODE_SESSION_ATTENDED CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null)
printf '%s' "$OUT7" > "$TMP/o10"
check "systemMessage presente" "$(python3 "$TMP/leer.py" "$TMP/o10" claves)" "hookSpecificOutput,systemMessage"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
