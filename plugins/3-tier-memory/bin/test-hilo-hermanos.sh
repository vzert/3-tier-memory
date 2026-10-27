#!/bin/bash
# Prueba de 2.65.2: los dos huecos por los que un pendiente nacido en una sesion quedaba en el hilo
# solo por coincidencia (caso real de otro proyecto, 2026-10-26: el paso y tres hermanos nacieron en una
# sesion que no recibio `Retomamos:`).
#
#  A. La liga al nacer solo apunta al paso RECIBIDO. Si el `Proximo paso` que la sesion escribe es
#     un pendiente nacido en ella, sus hermanos nacidos en ella quedaban sin `_relacionado` y solo
#     seguian en el hilo si el snippet siguiente se sellaba. Ahora marcar-retomar.py (Step 8a2) los
#     liga a ese paso por `pendiente.relate`; el que ya tiene `_relacionado` no se toca.
#  B. El sello (stamp-hilo.py) y la liga al nacer leen el snippet del PRIMER mensaje de usuario.
#     Si ese mensaje era un comando con el snippet de argumento (`/goalspec:interview Retomamos:…`),
#     el filtro quitaba `<command-args>` y la sesion quedaba sin sello.
#
# Uso: test-hilo-hermanos.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR THREET_SESSION_ID

M="$T/memory"
HOY=2026-10-26
S=2026-10-26-auditoria
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
marcar() { python3 "$BIN/marcar-retomar.py" "$@" --hoy "$HOY"; }
linea() { grep -m1 "_id: $1_" "$M/_pendientes.md" || true; }
rel() { linea "$1" | sed -n 's/.*_relacionado: \([^_]*\)_.*/\1/p' | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//'; }
relates() { grep -rl '"pendiente.relate"' "$M/.journal" 2>/dev/null | wc -l | tr -d ' '; }

ficha() {  # ficha SLUG "texto del Proximo paso"
  cat > "$M/sessions/$1.md" <<EOF
---
type: session
date: $HOY
---
# demo

## Como retomar

\`\`\`
Retomamos: demo de $1.

Lee memory/sessions/$1.md para el contexto completo.

Proximo paso: $2

Terminas cuando: la prueba pasa.
\`\`\`
EOF
}

fixture() {
  rm -rf "$M"; mkdir -p "$M/pendientes" "$M/sessions"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '# vieja\n' > "$M/sessions/2026-10-01-vieja.md"
  printf -- '# hoy\n' > "$M/sessions/$S.md"
  V=$(emit --type pendiente.add --text "un pendiente viejo de otro tema" --prioridad Media \
        --origen "[[sessions/2026-10-01-vieja]]" --creado 2026-10-01)
  X=$(emit --type pendiente.add --text "otro viejo al que ya apunta un hermano" --prioridad Baja \
        --origen "[[sessions/2026-10-01-vieja]]" --creado 2026-10-01)
  P=$(emit --type pendiente.add --text "ligar los planes a sus pendientes" --prioridad Alta \
        --origen "[[sessions/$S]]" --creado $HOY)
  H1=$(emit --type pendiente.add --text "barrer los planes abiertos sin sesiones" --prioridad Alta \
        --origen "[[sessions/$S]]" --creado $HOY)
  H2=$(emit --type pendiente.add --text "decidir si el hilo lee las sombrillas" --prioridad Media \
        --origen "[[sessions/$S]]" --creado $HOY --relacionado "$X")
  H3=$(emit --type pendiente.add --text "medir ventanas paralelas" --prioridad Baja \
        --origen "[[sessions/$S]]" --creado $HOY)
  compact --quiet >/dev/null
}

echo "== A1. el paso escrito es un pendiente nacido en la sesion: sus hermanos quedan ligados a el =="
fixture
ficha "$S" "arreglar la liga plan-pendiente ($P)."
marcar "$M/sessions/$S.md" >/dev/null
chk "hermano sin liga queda ligado al paso" "$P" "$(rel "$H1")"
chk "hermano sin liga (Baja) queda ligado al paso" "$P" "$(rel "$H3")"
chk "hermano con liga previa no se toca (ya tiene su ancla)" "$X" "$(rel "$H2")"
chk "el paso no se liga a si mismo" "" "$(rel "$P")"
chk "un pendiente de otra sesion no se toca" "" "$(rel "$V")"
N=$(relates)
marcar "$M/sessions/$S.md" >/dev/null
chk "idempotente: la segunda corrida no emite otro relate" "$N" "$(relates)"

echo "== A2. el hermano ligado sigue en el hilo de la sesion siguiente aunque el sello solo traiga el paso =="
cat > "$M/sessions/2026-10-27-sigue.md" <<EOF
---
type: session
date: 2026-10-27
hilo_paso: $P
hilo_heredados: $P
---
# sigue
EOF
HILO=$(python3 "$BIN/pendientes_afines.py" "$M/sessions/2026-10-27-sigue.md" --hilo --hoy 2026-10-27)
chk "H1 en el hilo" "1" "$(printf '%s\n' "$HILO" | grep -c "$H1")"
chk "H3 en el hilo" "1" "$(printf '%s\n' "$HILO" | grep -c "$H3")"

echo "== A3. el paso escrito es un pendiente viejo: no se liga nada =="
fixture
ficha "$S" "seguir con $V."
marcar "$M/sessions/$S.md" >/dev/null
chk "sin relate cuando el paso no nacio en la sesion" "0" "$(relates)"
chk "H1 sigue sin liga" "" "$(rel "$H1")"

echo "== A4. un hermano cerrado no se liga =="
fixture
emit --type pendiente.resolve --id "$H1" --estado resolved >/dev/null
compact --quiet >/dev/null
ficha "$S" "arreglar la liga plan-pendiente ($P)."
marcar "$M/sessions/$S.md" >/dev/null
chk "ningun relate para el cerrado" "0" "$(grep -rl '"pendiente.relate"' "$M/.journal" 2>/dev/null | xargs grep -l "$H1" 2>/dev/null | wc -l | tr -d ' ')"
chk "el abierto si" "$P" "$(rel "$H3")"

echo "== B. el snippet llega como argumento de un comando =="
mkt() {  # mkt RUTA ARGS
  python3 - "$1" "$2" <<'PY'
import json, sys
ruta, args = sys.argv[1], sys.argv[2].replace("\\n", "\n")
txt = ("<command-message>goalspec:interview</command-message>\n"
       "<command-name>/goalspec:interview</command-name>\n"
       f"<command-args>{args}</command-args>")
with open(ruta, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": txt}}) + "\n")
    fh.write(json.dumps({"type": "user", "isMeta": True, "message": {"role": "user",
             "content": [{"type": "text", "text": "Base directory for this skill: ..."}]}}) + "\n")
    fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": "sigue"}}) + "\n")
PY
}
snip() { python3 -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("pa",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.snippet_de_transcripcion(sys.argv[2]) or "NONE")' "$BIN/pendientes_afines.py" "$1"; }
mkt "$T/c1.jsonl" 'Retomamos: demo.\n\nProximo paso: arreglar p-0123456789 ya.'
chk "comando con Retomamos de argumento: devuelve el snippet" "Retomamos: demo." "$(snip "$T/c1.jsonl" | head -1)"
chk "y el paso trae su id" "1" "$(snip "$T/c1.jsonl" | grep -c 'p-0123456789')"
mkt "$T/c2.jsonl" '<pasted_content id="x">Retomamos: pegado.\n\nProximo paso: p-0123456789.</pasted_content>'
chk "comando con snippet pegado de argumento" "Retomamos: pegado." "$(snip "$T/c2.jsonl" | head -1)"
mkt "$T/c3.jsonl" 'el agente me dio esto Proximo paso: p-0123456789'
chk "comando cuyo argumento no empieza por Retomamos: no sella" "NONE" "$(snip "$T/c3.jsonl")"
mkt "$T/c4.jsonl" ''
chk "comando sin argumento: sigue sin snippet (el siguiente mensaje no es Retomamos)" "NONE" "$(snip "$T/c4.jsonl")"

echo "== B2. stamp-hilo.py sella de punta a punta con el snippet como argumento de un comando =="
# mkf RUTA ARGS: como mkt, mas la escritura de la ficha 2026-10-14-hoy.md (la guardia de stamp-hilo
# exige que la transcripcion la escriba, como el Step 2).
mkf() {
  python3 - "$1" "$2" <<'PY2'
import json, sys
ruta, args = sys.argv[1], sys.argv[2].replace("\\n", "\n")
txt = ("<command-message>goalspec:interview</command-message>\n"
       "<command-name>/goalspec:interview</command-name>\n"
       f"<command-args>{args}</command-args>")
with open(ruta, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "timestamp": "2026-10-14T15:00:00Z",
                         "message": {"role": "user", "content": txt}}) + "\n")
    fh.write(json.dumps({"type": "assistant", "timestamp": "2026-10-14T15:10:00Z", "message": {"content": [
        {"type": "tool_use", "name": "Write", "input": {"file_path": "/p/memory/sessions/2026-10-14-hoy.md",
                                                         "content": "x"}}]}}) + "\n")
PY2
}
sello() {  # sello ARGS: ficha nueva sin sello, transcripcion, stamp-hilo; imprime su linea
  printf -- '---\ntype: session\ndate: 2026-10-14\n---\n# hoy\n' > "$M/sessions/2026-10-14-hoy.md"
  mkf "$T/s.jsonl" "$1"
  python3 "$BIN/stamp-hilo.py" "$M/sessions/2026-10-14-hoy.md" --transcript "$T/s.jsonl"
}
chk "sella con Retomamos de argumento" "sellado=1 motivo=sellada" \
  "$(sello 'Retomamos: demo.\n\nProximo paso: arreglar p-0123456789 ya.\n\nquedan 1 en el hilo: p-9876543210.')"
FM=$(sed -n '1,/^---$/p' "$M/sessions/2026-10-14-hoy.md" | sed '1d')
chk "hilo_paso con el id del paso" "1" "$(printf '%s\n' "$FM" | grep -c '^hilo_paso: p-0123456789$')"
chk "hilo_heredados con paso y quedan" "1" "$(printf '%s\n' "$FM" | grep -c '^hilo_heredados: p-0123456789, p-9876543210$')"
chk "no sella si el argumento no empieza por Retomamos" "sellado=0 motivo=la-sesion-no-arranco-con-Retomamos" \
  "$(sello 'el agente me dio esto Proximo paso: p-0123456789')"

echo
echo "== resumen: $pass ok, $fail fallas =="
[ "$fail" -eq 0 ]
