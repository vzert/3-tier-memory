#!/bin/bash
# Prueba de la fecha de la ficha y del sello de `session_id` (2.72.0, plan de hilos, hueco H7).
#
# El defecto medido (otro proyecto, 8 de 71 checkpoints hechos entre las 18:00 y las 24:00 hora
# local): el agente nombro la ficha con la fecha UTC, que a esa hora ya es la del dia siguiente, y
# `stamp-session-id.py` compara con la fecha LOCAL de la transcripcion con margen cero. La ficha
# quedo sin `session_id` y el cierre solo lo decia en prosa.
#
# Lo que cubre:
#   A. `fecha-ficha.py` da la fecha local, no la UTC, y separa la fecha que traiga el slug.
#   B. De punta a punta con LOS BLOQUES REALES de la plantilla (extraidos, no copiados): un cierre
#      a las 20:00 hora local nombra la ficha con la fecha local y el sello da `stamped=1`.
#   C. El sello acepta una ficha con la fecha UTC solo si la transcripcion la ESCRIBIO.
#   D. `checkpoint-audit.py` da SALTADO `ficha.session_id` cuando la ficha de la sesion queda sin
#      sello habiendo `CLAUDE_CODE_SESSION_ID`, y calla sin la variable o con una ficha ajena.
#
# El huso lo fija la prueba. Donde el sistema no lo aplica (Git Bash en Windows ignora `TZ`), los
# casos que dependen del desfase se SALTAN Y SE CUENTAN: nunca salen verdes sin haberse medido.
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUG="$(cd "$BIN/.." && pwd)"
TPL="$PLUG/templates/checkpoint-3t.md"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; SKIP=0
ok()    { PASS=$((PASS + 1)); echo "  ok   $1"; }
falla() { FAIL=$((FAIL + 1)); echo "  FALLA $1${2:+ :: $2}"; }
salta() { SKIP=$((SKIP + 1)); echo "  SKIP $1"; }
igual() { if [ "$2" = "$3" ]; then ok "$1"; else falla "$1" "esperaba '$2', salio '$3'"; fi; }

unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT THREET_AHORA
export TZ="CST6CDT,M3.2.0,M11.1.0"
HUSO=$(python3 -c "
import datetime
try:
    d = datetime.datetime(2026, 5, 10, 1, tzinfo=datetime.timezone.utc).astimezone()
    print('si' if d.date().isoformat() == '2026-05-09' else 'no')
except Exception:
    print('no')
" 2>/dev/null) || HUSO=no
[ "$HUSO" = "si" ] || HUSO=no

# El cierre de la prueba: 2026-05-09 a las 20:00 hora local, que en UTC ya es 2026-05-10 01:00.
AHORA="2026-05-10T01:00:00Z"
LOCAL="2026-05-09"
UTC="2026-05-10"
SID="aaaaaaaa-1111-4222-8333-444444444444"
OTRO="bbbbbbbb-1111-4222-8333-444444444444"

# Un proyecto de juguete con su memoria y su carpeta de transcripciones, como las arma Claude Code.
HOME_T="$T/home"; PROJ="$T/proj con espacio"; MEM="$PROJ/memory"   # el espacio: el comando del audit va entrecomillado
mkdir -p "$HOME_T" "$MEM/sessions" "$MEM/plans" "$MEM/learnings" "$MEM/pendientes" "$MEM/research"
cd "$PROJ" || exit 2
JD="$HOME_T/.claude/projects/$(echo "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$JD"
printf '# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$MEM/_pendientes.md"
printf '# Sesiones\n\n| Fecha | Sesion | Status | Resumen | Commit |\n|---|---|---|---|---|\n' > "$MEM/_session-index.md"
printf '# Planes\n\n| Plan | Status | Fecha | Sesion | Pendientes | Learnings |\n|---|---|---|---|---|---|\n' > "$MEM/_plans-index.md"
printf '# Learnings\n\n| Tema | Archivo | Cuando consultarlo |\n|---|---|---|\n' > "$MEM/_learnings.md"

ficha() {   # $1 nombre, $2 session_id opcional
  { echo '---'; echo 'type: session'; echo "date: ${1:0:10}"; echo 'status: completed'
    [ -n "${2:-}" ] && echo "session_id: $2"
    echo '---'; echo; echo "# ${1}"; } > "$MEM/sessions/$1"
}
# Transcripcion de 19:40 a 20:00 hora local del 2026-05-09 (UTC: 2026-05-10 00:40 a 01:00).
# $1 id, $2... nombres de ficha que la sesion escribio con Write.
transcripcion() {
  python3 - "$JD" "$PROJ" "$@" <<'PY'
import json, os, sys
jd, proj, sid, escritas = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
lineas = [{"type": "user", "timestamp": "2026-05-10T00:40:00Z",
           "message": {"role": "user", "content": "trabajo de la tarde"}}]
for n, nombre in enumerate(escritas):
    lineas.append({"type": "assistant", "timestamp": "2026-05-10T00:5%d:00Z" % n,
                   "message": {"role": "assistant", "content": [
                       {"type": "tool_use", "name": "Write", "id": "t%d" % n,
                        "input": {"file_path": os.path.join(proj, "memory", "sessions", nombre),
                                  "content": "x"}}]}})
lineas.append({"type": "assistant", "timestamp": "2026-05-10T01:00:00Z",
               "message": {"role": "assistant", "content": [{"type": "text", "text": "listo"}]}})
with open(os.path.join(jd, sid + ".jsonl"), "w", encoding="utf-8") as fh:
    for l in lineas:
        fh.write(json.dumps(l) + "\n")
PY
}
sello() {   # $1 ficha, $2 id, [extra...]  -> salida en $T/st, rc en RC
  local f="$1" id="$2"; shift 2
  HOME="$HOME_T" python3 "$BIN/stamp-session-id.py" "$MEM/sessions/$f" "$id" --jsonl-dir "$JD" "$@" > "$T/st" 2>&1
  RC=$?
}
sellada_con() { grep -q "^session_id: $2\$" "$MEM/sessions/$1"; }

# ---------------------------------------------------------------- A. fecha-ficha.py
echo "== A. fecha-ficha.py"
FF="$BIN/fecha-ficha.py"
if [ ! -f "$FF" ]; then
  falla "A0 fecha local: no existe bin/fecha-ficha.py"
else
  if [ "$HUSO" = "si" ]; then
    igual "A1 fecha local a las 20:00 (UTC ya es el dia siguiente)" "DATE=$LOCAL" \
      "$(python3 "$FF" --ahora "$AHORA" | sed -n 1p)"
    igual "A2 fecha local por THREET_AHORA" "DATE=$LOCAL" \
      "$(THREET_AHORA="$AHORA" python3 "$FF" | sed -n 1p)"
  else
    salta "A1 fecha local a las 20:00: el sistema no aplica TZ"
    salta "A2 fecha local por THREET_AHORA: el sistema no aplica TZ"
  fi
  igual "A3 sin --ahora da la fecha local de hoy" "DATE=$(python3 -c 'import datetime;print(datetime.datetime.now().astimezone().date().isoformat())')" \
    "$(python3 "$FF" | sed -n 1p)"
  S=$(python3 "$FF" --ahora "$AHORA" --slug "mi-slug")
  igual "A4 slug sin fecha: se devuelve igual" "SLUG=mi-slug" "$(printf '%s\n' "$S" | sed -n 2p)"
  igual "A4b slug sin fecha: sin aviso" "0" "$(printf '%s\n' "$S" | grep -c 'AVISO')"
  if [ "$HUSO" = "si" ]; then
    S=$(python3 "$FF" --ahora "$AHORA" --slug "$UTC-mi-slug")
    igual "A5 slug con la fecha UTC: se separa la fecha" "SLUG=mi-slug" "$(printf '%s\n' "$S" | sed -n 2p)"
    igual "A5b slug con la fecha UTC: dice que fecha traia" "SLUG_FECHA=$UTC" "$(printf '%s\n' "$S" | sed -n 3p)"
    igual "A5c slug con la fecha UTC: avisa" "1" "$(printf '%s\n' "$S" | grep -c 'AVISO')"
    S=$(python3 "$FF" --ahora "$AHORA" --slug "$LOCAL-mi-slug")
    igual "A6 slug con la fecha local: sin aviso" "0" "$(printf '%s\n' "$S" | grep -c 'AVISO')"
  else
    salta "A5 slug con la fecha UTC: el sistema no aplica TZ"
    salta "A6 slug con la fecha local: el sistema no aplica TZ"
  fi
  python3 "$FF" --ahora "2026-05-10T01:00:00" > "$T/ff" 2>&1; RC=$?
  if [ "$RC" != "0" ] && ! grep -q '^DATE=' "$T/ff"; then ok "A8 --ahora sin zona: se rechaza"
  else falla "A8 --ahora sin zona: se rechaza" "$(cat "$T/ff")"; fi
  igual "A9 slug con .md: se le quita" "SLUG=mi-slug" "$(python3 "$FF" --slug "mi-slug.md" | sed -n 2p)"
  python3 "$FF" --ahora "" > "$T/ff" 2>&1; RC=$?
  if [ "$RC" != "0" ] && ! grep -q '^DATE=' "$T/ff"; then ok "A10 --ahora vacio: no cae a la hora real"
  else falla "A10 --ahora vacio: no cae a la hora real" "$(cat "$T/ff")"; fi
  python3 "$FF" --slug "$(printf 'a\nDATE=1999-01-01')" > "$T/ff" 2>&1; RC=$?
  if [ "$RC" != "0" ] && [ "$(grep -c '^DATE=' "$T/ff")" = "0" ]; then ok "A11 slug con salto de linea: no imprime un segundo DATE"
  else falla "A11 slug con salto de linea: no imprime un segundo DATE" "$(cat "$T/ff")"; fi
  igual "A12 slug con una fecha imposible: no es una fecha" "SLUG=2026-99-99-x" "$(python3 "$FF" --slug "2026-99-99-x" | sed -n 2p)"
  python3 "$FF" --ahora "no-es-fecha" > "$T/ff" 2>&1; RC=$?
  if [ "$RC" != "0" ] && ! grep -q '^DATE=' "$T/ff"; then ok "A7 --ahora ilegible: no inventa fecha"
  else falla "A7 --ahora ilegible: no inventa fecha" "$(cat "$T/ff")"; fi
fi

# ---------------------------------------------------------------- B. los bloques de la plantilla
echo "== B. cierre a las 20:00 hora local con los bloques de la plantilla"
python3 - "$TPL" "$T" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
def bloque(ancla, destino):
    i = t.find(ancla)
    m = re.search(r"```bash\n(.*?)```", t[i:t.find("\n## ", i + 1) if ancla.startswith("## ") else len(t)], re.S) if i != -1 else None
    open(sys.argv[2] + "/" + destino, "w", encoding="utf-8").write(m.group(1) if m else "")
bloque("## Step 1: Session slug", "paso1.sh")
bloque("### 5c-bis: Sellar `session_id`", "sello.sh")
PY
if ! grep -q 'fecha-ficha.py' "$T/paso1.sh"; then
  falla "B0 cierre a las 20:00: el Step 1 de la plantilla no calcula DATE con un comando"
elif [ "$HUSO" != "si" ]; then
  salta "B1 cierre a las 20:00: el sistema no aplica TZ"
  salta "B2 cierre a las 20:00 stamped=1: el sistema no aplica TZ"
else
  D=$(env -i PATH="$PATH" TZ="$TZ" HOME="$HOME_T" CLAUDE_PLUGIN_ROOT="$PLUG" THREET_AHORA="$AHORA" \
        bash "$T/paso1.sh" 2>&1 | sed -n 's/^DATE=//p' | head -1)
  igual "B1 cierre a las 20:00: el bloque del Step 1 da la fecha local" "$LOCAL" "$D"
  F="$D-cierre-nocturno.md"
  ficha "$F"; transcripcion "$SID" "$F"
  OUT=$(env -i PATH="$PATH" TZ="$TZ" HOME="$HOME_T" CLAUDE_PLUGIN_ROOT="$PLUG" \
        CLAUDE_CODE_SESSION_ID="$SID" SESSION_FILE="$MEM/sessions/$F" bash "$T/sello.sh" 2>&1)
  if printf '%s' "$OUT" | grep -q '^stamped=1 reason=sellada$' && sellada_con "$F" "$SID"; then
    ok "B2 cierre a las 20:00 stamped=1"
  else falla "B2 cierre a las 20:00 stamped=1" "$OUT"; fi
  rm -f "$MEM/sessions/$F" "$JD/$SID.jsonl"
fi

# ---------------------------------------------------------------- C. el sello y la fecha UTC
echo "== C. el sello con una ficha fechada en UTC"
if [ "$HUSO" != "si" ]; then
  for c in C1 C2 C3 C4 C5 C6 C7; do salta "$c ficha con fecha UTC: el sistema no aplica TZ"; done
else
  # C1: la sesion escribio la ficha con la fecha UTC (el caso real). Se sella por evidencia.
  F="$UTC-fecha-utc.md"; ficha "$F"; transcripcion "$SID" "$F"
  sello "$F" "$SID"
  if [ "$RC" = "0" ] && grep -q '^stamped=1 reason=sellada-por-evidencia-de-escritura$' "$T/st" && sellada_con "$F" "$SID"; then
    ok "C1 ficha con fecha UTC escrita por la sesion: sellada"
  else falla "C1 ficha con fecha UTC escrita por la sesion: sellada" "rc=$RC $(cat "$T/st")"; fi

  # C2: la misma fecha UTC, pero la transcripcion NO escribio esa ficha (es de otra sesion).
  A="$UTC-ajena.md"; ficha "$A"
  sello "$A" "$SID"
  if [ "$RC" != "0" ] && grep -q '^stamped=0 reason=la-ficha-es-de-' "$T/st" && ! grep -q 'session_id' "$MEM/sessions/$A"; then
    ok "C2 ficha con fecha UTC que la sesion no escribio: no se sella"
  else falla "C2 ficha con fecha UTC que la sesion no escribio: no se sella" "rc=$RC $(cat "$T/st")"; fi

  # C3: la sesion solo LEYO la ficha ajena (la sesion que retoma lee la anterior).
  python3 - "$JD/$SID.jsonl" "$PROJ/memory/sessions/$A" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "assistant", "timestamp": "2026-05-10T00:59:00Z",
        "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Read", "id": "r1",
                    "input": {"file_path": sys.argv[2]}}]}}) + "\n")
PY
  sello "$A" "$SID"
  if [ "$RC" != "0" ] && ! grep -q 'session_id' "$MEM/sessions/$A"; then ok "C3 ficha con fecha UTC solo leida: no se sella"
  else falla "C3 ficha con fecha UTC solo leida: no se sella" "rc=$RC $(cat "$T/st")"; fi

  # C4: escrita por la sesion, pero ya sellada por otra: no se pisa.
  P="$UTC-de-otra.md"; ficha "$P" "$OTRO"; transcripcion "$SID" "$P"
  sello "$P" "$SID"
  if [ "$RC" != "0" ] && sellada_con "$P" "$OTRO" && ! sellada_con "$P" "$SID"; then ok "C4 ficha con fecha UTC ya sellada por otra sesion: no se pisa"
  else falla "C4 ficha con fecha UTC ya sellada por otra sesion: no se pisa" "rc=$RC $(cat "$T/st")"; fi

  # C5: escrita por la sesion, con una fecha a tres dias: la evidencia no arregla una fecha lejana.
  L="2026-05-13-lejana.md"; ficha "$L"; transcripcion "$SID" "$L"
  sello "$L" "$SID"
  if [ "$RC" != "0" ] && ! grep -q 'session_id' "$MEM/sessions/$L"; then ok "C5 ficha a tres dias aunque la sesion la escribio: no se sella"
  else falla "C5 ficha a tres dias aunque la sesion la escribio: no se sella" "rc=$RC $(cat "$T/st")"; fi

  # C8: escrita por la sesion, a UN dia de su fecha UTC (por arriba y por abajo): no. La segunda
  # oportunidad es para la fecha UTC de la transcripcion, sin margen (revisor independiente: con un
  # dia de margen un Edit sellaba la ficha de ayer de otra sesion).
  for X in 2026-05-11 2026-05-08; do
    Y="$X-a-un-dia.md"; ficha "$Y"; transcripcion "$SID" "$Y"
    sello "$Y" "$SID"
    if [ "$RC" != "0" ] && ! grep -q 'session_id' "$MEM/sessions/$Y"; then ok "C8 ficha a un dia de la fecha UTC ($X): no se sella"
    else falla "C8 ficha a un dia de la fecha UTC ($X): no se sella" "rc=$RC $(cat "$T/st")"; fi
  done

  # C9: la fecha UTC y solo un Edit (o una redireccion de Bash): no. Al este de Greenwich el dia
  # UTC de una sesion de manana es ayer, y editar la ficha de ayer de otra sesion la sellaba
  # (revisor independiente, ronda 2). Hace falta el Write que la creo.
  E="$UTC-solo-editada.md"; ficha "$E"; transcripcion "$SID" "$E"
  sed -i.bak 's/"name": "Write"/"name": "Edit"/' "$JD/$SID.jsonl" && rm -f "$JD/$SID.jsonl.bak"
  sello "$E" "$SID"
  if [ "$RC" != "0" ] && grep -q '"name": "Edit"' "$JD/$SID.jsonl" && ! grep -q 'session_id' "$MEM/sessions/$E"; then ok "C9 ficha con fecha UTC solo editada: no se sella"
  else falla "C9 ficha con fecha UTC solo editada: no se sella" "rc=$RC $(cat "$T/st")"; fi

  # C6: --dry-run dice que sellaria y no escribe.
  G="$UTC-en-seco.md"; ficha "$G"; transcripcion "$SID" "$G"
  cp "$MEM/sessions/$G" "$T/antes"
  sello "$G" "$SID" --dry-run
  if [ "$RC" = "0" ] && grep -q '^stamped=0 reason=en-seco:' "$T/st" && cmp -s "$T/antes" "$MEM/sessions/$G"; then
    ok "C6 --dry-run: dice que sellaria y no escribe"
  else falla "C6 --dry-run: dice que sellaria y no escribe" "rc=$RC $(cat "$T/st")"; fi

  # C7: la ficha con fecha local sigue sellando por la regla de siempre, sin pedir evidencia.
  N="$LOCAL-normal.md"; ficha "$N"; transcripcion "$SID"
  sello "$N" "$SID"
  if [ "$RC" = "0" ] && grep -q '^stamped=1 reason=sellada$' "$T/st"; then ok "C7 ficha con fecha local: sellada como siempre"
  else falla "C7 ficha con fecha local: sellada como siempre" "rc=$RC $(cat "$T/st")"; fi
  rm -f "$MEM/sessions/"*.md "$JD/"*.jsonl
fi

# ---------------------------------------------------------------- D. checkpoint-audit.py
echo "== D. checkpoint-audit.py: ficha.session_id"
audita() {   # $1 ficha, $2 valor de CLAUDE_CODE_SESSION_ID ('' = sin la variable) -> estado o 'nada'
  local extra=()
  [ -n "$2" ] && extra=(CLAUDE_CODE_SESSION_ID="$2")
  env -i PATH="$PATH" TZ="$TZ" HOME="$HOME_T" "${extra[@]}" python3 "$BIN/checkpoint-audit.py" "$MEM" \
      --session-file "$MEM/sessions/$1" --no-git --hoy "$LOCAL" --json > "$T/aud.json" 2> "$T/aud.err"
  python3 - "$T/aud.json" <<'PY'
import json, sys
try:
    h = [x for x in json.load(open(sys.argv[1], encoding="utf-8")) if x["clave"] == "ficha.session_id"]
except Exception as e:
    print("error:%s" % e); sys.exit(0)
print(h[0]["estado"] if h else "nada")
PY
}
corrige() {   # el comando que el hallazgo propone, tal cual
  python3 -c "
import json, sys
h = [x for x in json.load(open(sys.argv[1], encoding='utf-8')) if x['clave'] == 'ficha.session_id']
print((h[0].get('corrige') or '') if h else '')" "$T/aud.json"
}
F="$LOCAL-auditada.md"; ficha "$F"; transcripcion "$SID" "$F"
igual "D1 ficha de la sesion sin sello y con la variable: SALTADO" "SALTADO" "$(audita "$F" "$SID")"
CMD="$(corrige)"
if grep -q 'session_id' "$MEM/sessions/$F"; then falla "D1b la auditoria no sella: solo mira"; else ok "D1b la auditoria no sella: solo mira"; fi
igual "D2 ficha de la sesion sin sello y sin la variable: calla" "nada" "$(audita "$F" "")"
# D3: el comando que propone el hallazgo sella, y la auditoria pasa a HECHO.
if [ -n "$CMD" ] && (cd "$PROJ" && HOME="$HOME_T" bash -c "$CMD" > "$T/cmd.out" 2>&1) && sellada_con "$F" "$SID"; then
  ok "D3 el comando del hallazgo sella la ficha"
else falla "D3 el comando del hallazgo sella la ficha" "cmd=[$CMD] $(cat "$T/cmd.out" 2>/dev/null)"; fi
igual "D4 ficha sellada con el id de la sesion: HECHO" "HECHO" "$(audita "$F" "$SID")"
# D5: ficha del mismo dia que esta sesion NO escribio (auditoria de una ficha ajena).
A="$LOCAL-ajena.md"; ficha "$A"
igual "D5 ficha ajena del mismo dia sin sello: calla" "nada" "$(audita "$A" "$SID")"
# D6: ficha sellada por otra sesion, aunque esta la haya editado: no es la suya.
P="$LOCAL-de-otra.md"; ficha "$P" "$OTRO"; transcripcion "$SID" "$F" "$P"
igual "D6 ficha sellada por otra sesion: calla" "nada" "$(audita "$P" "$SID")"
# D7: la sesion la escribio, esta a un dia de su fecha UTC, y el sello la rechaza (ni fecha local
# ni UTC): SALTADO sin comando.
L="2026-05-11-a-un-dia.md"; ficha "$L"; transcripcion "$SID" "$F" "$L"
igual "D7 ficha de la sesion que el sello rechaza: SALTADO" "SALTADO" "$(audita "$L" "$SID")"
if corrige | grep -q 'stamp-session-id.py'; then falla "D7b ficha que el sello rechaza: no propone un comando que no sirve" "$(corrige)"
else ok "D7b ficha que el sello rechaza: no propone un comando que no sirve"; fi
# D12: la misma ficha a un dia, pero esta sesion solo la EDITO: es de otra sesion, calla.
sed -i.bak 's/"name": "Write"/"name": "Edit"/' "$JD/$SID.jsonl" && rm -f "$JD/$SID.jsonl.bak"
igual "D12 ficha a un dia que la sesion solo edito: calla" "nada" "$(audita "$L" "$SID")"
transcripcion "$SID" "$F" "$L"
# D8: con --solo-snippet (lo que corre el hook de cierre) el hallazgo no sale.
env -i PATH="$PATH" TZ="$TZ" HOME="$HOME_T" CLAUDE_CODE_SESSION_ID="$SID" python3 "$BIN/checkpoint-audit.py" "$MEM" \
    --session-file "$MEM/sessions/$L" --no-git --hoy "$LOCAL" --json --solo-snippet > "$T/aud.json" 2>/dev/null
igual "D8 --solo-snippet no trae ficha.session_id" "0" "$(grep -c 'ficha.session_id' "$T/aud.json")"

# D9: una ficha vieja que esta sesion edito (auditoria retroactiva): calla.
V="2025-01-15-vieja.md"; ficha "$V"; transcripcion "$SID" "$F" "$V"
igual "D9 ficha vieja que la sesion edito: calla" "nada" "$(audita "$V" "$SID")"
# D10: la variable trae un id sin transcripcion. Ficha de hoy: PARCIAL (no se pudo comprobar). Vieja: calla.
SINT="dddddddd-1111-4222-8333-444444444444"
N="$LOCAL-sin-transcripcion.md"; ficha "$N"
igual "D10 id sin transcripcion, ficha de hoy: PARCIAL" "PARCIAL" "$(audita "$N" "$SINT")"
igual "D10b id sin transcripcion, ficha vieja: calla" "nada" "$(audita "$V" "$SINT")"
# D11: el sello sangrado se lee igual que en stamp-session-id.py.
G="$LOCAL-sangrada.md"; printf -- '---\ntype: session\ndate: %s\n  session_id: %s\n---\n\n# x\n' "$LOCAL" "$SID" > "$MEM/sessions/$G"
igual "D11 sello sangrado con el id de la sesion: HECHO" "HECHO" "$(audita "$G" "$SID")"

echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" = "0" ]
