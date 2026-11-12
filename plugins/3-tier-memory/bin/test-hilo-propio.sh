#!/bin/bash
# Prueba de 2.70.0: el hilo es solo el trabajo PROPIO de la sesion (decision de Victor del
# 2026-11-11, tras una auditoria de otro proyecto del 2026-11-10/11).
#
# Caso real (ids y textos inventados aqui; el repo es publico): una sesion de secretos de n8n
# arranco con un snippet cuyo paso era el pendiente de secretos y cuyos extras/`quedan N` traian
# otros 9 pendientes, todos "saltados 2 sesiones". La sesion solo trabajo el paso. Su hilo puso
# primero un Alta de rotar llaves IAM que nunca toco (por la prioridad del heredado saltado 2+), y
# lo dejo como `Proximo paso`; otra ventana acabo sobre el mismo pendiente.
#
#  1. hilo(): el extra heredado no tocado ya no entra, aunque lleve 2 saltos; el paso recibido si.
#  2. hilo(): lo trabajado (`hilo_trabajados`) entra; los pendientes de un plan editado
#     (`hilo_planes`) entran; los de otro plan no; el paso que la ficha escribe no se mete solo.
#  3. stamp-hilo.py escribe `hilo_trabajados` y `hilo_planes` desde la transcripcion: recibir un id
#     en los extras no cuenta; un comando fuera del cierre si; editar memory/plans/<plan>.md si. Y
#     los refresca en un re-checkpoint (con el sello ya puesto) y sin `Retomamos:`.
#  4. checkpoint-audit.py (fichas desde 2026-11-11): snippet.paso_no_trabajado es SALTADO con un
#     extra heredado no tocado de paso; HECHO con el paso recibido, con uno creado o con uno de un
#     plan editado. snippet.paso_otra_ventana es SALTADO. Una ficha anterior sigue en POR-DISEÑO.
#  5. print-pendiente-opcional.py: sin ➕ bajo un snippet `ninguno`; el 🔔 dice que no es paso del hilo.
#
# Uso: test-hilo-propio.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

M="$T/memory"
F=2026-11-11-hoy
P="$T/projects/-tmp-proyecto"
memoria() {
  rm -rf "$M" "$T/projects"; mkdir -p "$M/sessions" "$M/pendientes" "$M/plans" "$P"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
}
# pend PRIO ID TEXTO ORIGEN [COLA]
pend() {
  python3 - "$M/_pendientes.md" "$1" "- [ ] $3 — _origen: [[sessions/$4]]_ — _creado: 2026-10-01_ — _id: $2_${5:-}" <<'PY'
import sys
p, prio, l = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
h = f"## {prio} prioridad\n"
i = t.index(h) + len(h)
j = t.find("\n## ", i)
j = len(t) if j == -1 else j + 1
t = t[:j].rstrip("\n") + "\n" + l + "\n\n" + t[j:]
open(p, "w", encoding="utf-8").write(t)
PY
}
# ficha PASO [FRONTMATTER-EXTRA] [FECHA]
ficha() {
  python3 - "$M/sessions/$F.md" "$1" "${2:-}" "${3:-2026-11-11}" <<'PY'
import sys
p, paso, fm, fecha = sys.argv[1], sys.argv[2], sys.argv[3].replace("\\n", "\n"), sys.argv[4]
t = ("---\ntype: session\ndate: " + fecha + "\n" + (fm + "\n" if fm else "") + "---\n# Demo\n\n"
     "## Contexto\nalgo\n\n## Cambios realizados\nalgo\n\n## Bugs fixed\n- Ninguno\n\n## Plans\n- Ninguno\n\n"
     "## Research\n- Ninguno\n\n## Learnings generados\n- Ninguno\n\n## Pendientes\n- Ninguno\n\n"
     "## Commits\n- `abc1234`\n\n## Como retomar\n\n```\nRetomamos: demo.\n\n"
     "Lee memory/sessions/" + "2026-11-11-hoy.md para el contexto completo.\n\n" + paso +
     "\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```\n\n## Related\n- [[_pendientes]]\n")
open(p, "w", encoding="utf-8").write(t)
PY
}
# tx RUTA SNIPPET MODO...: transcripcion. El primer mensaje es el snippet (pegado); escribe la ficha
# con Write (como el Step 2). Modos: toca:<id> (pendiente.update fuera del cierre; un Bash que solo
# nombra el id no cuenta como trabajo, regla de paso_ajeno.trabajo_propio), accion:<id> (Bash con el
# id, para la otra ventana), plan:<plan>
# (Edit de memory/plans/<plan>.md), alta:<id> (pendiente.add que imprime el id), cierre-update:<id>
# (pendiente.update del id en el turno del /checkpoint-3t). TX_HACE = segundos atras.
tx() {
  python3 - "$@" <<'PY'
import datetime, json, os, sys
ruta, snip, modos = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3:]
TS = (datetime.datetime.now(datetime.timezone.utc)
      - datetime.timedelta(seconds=int(os.environ.get("TX_HACE", "0")))).isoformat().replace("+00:00", "Z")
r = [{"type": "user", "message": {"role": "user", "content":
      "<pasted_content id=\"ab12\">\n" + snip + "\n</pasted_content id=\"ab12\">"}}]
def bash(cmd, tid, salida=""):
    r.append({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": cmd}}]}})
    r.append({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": tid, "content": salida}]}})
r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "w0", "name": "Write",
          "input": {"file_path": "/p/memory/sessions/2026-11-11-hoy.md", "content": "x"}}]}})
cierre = []
for n, m in enumerate(modos):
    k, _, v = m.partition(":")
    if k == "toca":
        bash("python3 journal-emit.py --type pendiente.update --id " + v + " --text z", f"t{n}")
    elif k == "accion":
        bash("ssh host 'rotar " + v + "'", f"x{n}")
    elif k == "plan":
        r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": f"e{n}",
                  "name": "Edit", "input": {"file_path": "/p/memory/plans/" + v + ".md",
                                            "old_string": "a", "new_string": "b"}}]}})
    elif k == "alta":
        bash("python3 journal-emit.py --type pendiente.add --text demo", f"a{n}", "evento ok: id " + v)
    elif k == "cierre-update":
        cierre.append(v)
if cierre:
    r.append({"type": "user", "message": {"role": "user", "content": "<command-name>/checkpoint-3t</command-name>"}})
    for n, v in enumerate(cierre):
        bash("python3 journal-emit.py --type pendiente.update --id " + v + " --text y", f"c{n}")
with open(ruta, "w", encoding="utf-8") as f:
    for x in r:
        x["timestamp"] = TS
        f.write(json.dumps(x) + "\n")
PY
}
hilo() { python3 "$BIN/pendientes_afines.py" "$M/sessions/$F.md" --hilo --hoy 2026-11-11 | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//'; }
estado() {   # estado CLAVE [--transcript RUTA] [--hoy D] -> "ESTADO"
  local k="$1"; shift
  python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$F.md" --no-git --hoy 2026-11-11 \
    --solo-snippet --json "$@" | python3 -c '
import json, sys
x = [h for h in json.load(sys.stdin) if h["clave"] == sys.argv[1]]
print(x[0]["estado"] if x else "ausente")' "$k"
}

# El caso real: paso recibido p-a000000001 (secretos, Alta), extras/quedan con p-a000000002 (llaves
# IAM, Alta) y p-a000000003 (Media), los dos saltados 2 sesiones.
SNIP='Retomamos: secretos de n8n.\n\nLee memory/sessions/2026-11-10-ayer.md para el contexto completo.\n\nProximo paso: migrar el siguiente grupo de secretos (p-a000000001).\n\nSi ese paso es corto, suma en la misma sesion: p-a000000002 (Alta) — rotar llaves IAM.\n\nquedan 1 en el hilo: p-a000000003.\n\nAntes de actuar, dime en 3 lineas donde quedamos.'
SELLO='hilo_paso: p-a000000001\nhilo_heredados: p-a000000001, p-a000000002, p-a000000003\nhilo_saltos: p-a000000002=2, p-a000000003=2'
caso() {
  memoria
  pend Alta p-a000000001 "migrar secretos de n8n a credenciales" 2026-10-29-origen " — _relacionado: plan-consolidacion_"
  pend Alta p-a000000002 "rotar llaves IAM" 2026-10-23-otro
  pend Media p-a000000003 "rotar el secreto de cron" 2026-10-23-otro
  pend Media p-a000000004 "otra pieza del plan de consolidacion" 2026-10-20-otra " — _relacionado: plan-consolidacion_"
  pend Media p-a000000005 "pieza de otro plan" 2026-10-20-otra " — _relacionado: plan-otro_"
}

echo "== 1. hilo(): el extra heredado no tocado no entra, aunque lleve 2 saltos =="
caso; ficha "Proximo paso: rotar llaves IAM (p-a000000002)." "$SELLO"
chk "el hilo es solo el paso recibido, sin el extra heredado saltado 2" "p-a000000001" "$(hilo)"

echo "== 2. hilo(): lo trabajado entra, el plan editado trae sus pendientes, otro plan no =="
caso; ficha "Proximo paso: x." "$SELLO\nhilo_trabajados: p-a000000003\nhilo_planes: plan-consolidacion"
chk "paso recibido, plan editado y trabajado, en orden de prioridad" "p-a000000001 p-a000000003 p-a000000004" "$(hilo)"
caso; ficha "Proximo paso: la pieza de otro plan (p-a000000005)."
chk "sin sello ni trabajo: el paso que la ficha escribe no se mete solo" "" "$(hilo)"
pend Baja p-a000000006 "nacido hoy" 2026-11-11-hoy
chk "lo que nacio en la sesion si" "p-a000000006" "$(hilo)"

echo "== 3. stamp-hilo.py: hilo_trabajados y hilo_planes desde la transcripcion =="
caso; ficha "Proximo paso: x."
tx "$T/t.jsonl" "$SNIP" toca:p-a000000003 plan:plan-consolidacion cierre-update:p-a000000002
chk "sella" "sellado=1 motivo=sellada" "$(python3 "$BIN/stamp-hilo.py" "$M/sessions/$F.md" --transcript "$T/t.jsonl" 2>/dev/null)"
FM=$(sed -n '1,/^---$/p' "$M/sessions/$F.md" | sed -n '2,$p')
chk "trabajados: el tocado y el paso recibido; no el extra solo recibido ni el del cierre" "1" "$(printf '%s\n' "$FM" | grep -c '^hilo_trabajados: p-a000000001, p-a000000003$')"
chk "planes: el editado" "1" "$(printf '%s\n' "$FM" | grep -c '^hilo_planes: plan-consolidacion$')"
tx "$T/t.jsonl" "$SNIP" toca:p-a000000003 toca:p-a000000005
chk "re-checkpoint con sello puesto: no pisa el sello" "sellado=0 motivo=ya-sellada" "$(python3 "$BIN/stamp-hilo.py" "$M/sessions/$F.md" --transcript "$T/t.jsonl" 2>/dev/null)"
FM=$(sed -n '1,/^---$/p' "$M/sessions/$F.md" | sed -n '2,$p')
chk "pero refresca lo trabajado (una sola linea)" "1|1" "$(printf '%s\n' "$FM" | grep -c '^hilo_trabajados: p-a000000001, p-a000000003, p-a000000005$')|$(printf '%s\n' "$FM" | grep -c '^hilo_trabajados:')"
chk "y los planes (ya no edito ninguno)" "1" "$(printf '%s\n' "$FM" | grep -c '^hilo_planes: *$')"
chk "el sello del arranque sigue" "1" "$(printf '%s\n' "$FM" | grep -c '^hilo_paso: p-a000000001$')"
caso; ficha "Proximo paso: x."
tx "$T/n.jsonl" 'arreglemos la pieza p-a000000004' plan:plan-otro
chk "sin Retomamos: no sella el arranque" "sellado=0 motivo=la-sesion-no-arranco-con-Retomamos" "$(python3 "$BIN/stamp-hilo.py" "$M/sessions/$F.md" --transcript "$T/n.jsonl" 2>/dev/null)"
FM=$(sed -n '1,/^---$/p' "$M/sessions/$F.md" | sed -n '2,$p')
chk "pero escribe lo que el usuario pidio y el plan editado" "1|1" "$(printf '%s\n' "$FM" | grep -c '^hilo_trabajados: p-a000000004$')|$(printf '%s\n' "$FM" | grep -c '^hilo_planes: plan-otro$')"

echo "== 4. checkpoint-audit.py: el paso ajeno bloquea desde 2026-11-11 =="
caso; ficha "Proximo paso: rotar llaves IAM (p-a000000002)." "$SELLO"
tx "$P/propia.jsonl" "$SNIP" toca:p-a000000001
chk "extra heredado no tocado de paso: SALTADO" "SALTADO" "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
caso; ficha "Proximo paso: migrar el siguiente grupo (p-a000000001)." "$SELLO"
tx "$P/propia.jsonl" "$SNIP"
chk "el paso recibido, aunque ningun comando lo nombre: HECHO" "HECHO" "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
caso; ficha "Proximo paso: hacer el nuevo (p-a000000009)." "$SELLO"
tx "$P/propia.jsonl" "$SNIP" alta:p-a000000009
chk "uno que la sesion creo: HECHO" "HECHO" "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
caso; ficha "Proximo paso: otra pieza (p-a000000004)." "$SELLO\nhilo_planes: plan-consolidacion"
tx "$P/propia.jsonl" "$SNIP" plan:plan-consolidacion
chk "uno de un plan que la sesion edito: HECHO" "HECHO" "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
caso; ficha "Proximo paso: rotar llaves IAM (p-a000000002)." "$SELLO" 2026-11-10
tx "$P/propia.jsonl" "$SNIP" toca:p-a000000001
chk "ficha anterior al corte: sigue de aviso (POR-DISEÑO) y como antes (lo recibio)" "HECHO" "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl" --hoy 2026-11-10)"
caso; ficha "Proximo paso: migrar el siguiente grupo (p-a000000001)." "$SELLO"
tx "$P/propia.jsonl" "$SNIP"
tx "$P/otra.jsonl" 'sigue con los secretos' accion:p-a000000001
chk "otra ventana viva corrio comandos con el paso: SALTADO" "SALTADO" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
ficha "Proximo paso: ninguno — lo lleva otra sesion." "$SELLO"
chk "y la salida que pide, ninguno — lo lleva otra sesion, la acepta snippet.hilo (ronda 1 del adversario)" "HECHO" "$(estado snippet.hilo --transcript "$P/propia.jsonl")"
ficha "Proximo paso: ninguno — no queda trabajo de este hilo." "$SELLO"
rm -f "$P/otra.jsonl"
chk "sin la otra ventana, ese ninguno sigue tapando el paso recibido: SALTADO" "SALTADO" "$(estado snippet.hilo --transcript "$P/propia.jsonl")"
caso; ficha "Proximo paso: migrar el siguiente grupo (p-a000000001)." "$SELLO" 2026-11-10
tx "$P/propia.jsonl" "$SNIP"
tx "$P/otra.jsonl" 'sigue con los secretos' accion:p-a000000001
chk "ficha anterior al corte: otra ventana sigue de aviso" "POR-DISEÑO" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl" --hoy 2026-11-10)"

echo "== 5. print-pendiente-opcional.py: sin ➕; el 🔔 no es paso del hilo =="
caso
pend Media p-a00000000a "vencido de otro plan" 2026-10-01-otra " — _revisar: 2026-10-01_"
python3 - "$M/sessions/$F.md" <<'PY'
import re, sys
p = sys.argv[1]
ficha = ("---\ntype: session\ndate: 2026-11-11\n---\n# Demo\n\n## Pendientes\n- Ninguno\n\n"
         "## Como retomar\n\nNinguno — no queda trabajo de este hilo.\n\n## Related\n- [[_pendientes]]\n")
open(p, "w", encoding="utf-8").write(ficha)
PY
chk "snippet ninguno con un vencido de otro plan: no imprime nada" "" "$(python3 "$BIN/print-pendiente-opcional.py" "$M/sessions/$F.md" --hoy 2026-11-11)"
pend Media p-a00000000b "vence hoy" 2026-10-01-otra " — _revisar: 2026-11-11_"
chk "el 🔔 dice que es recordatorio del proyecto, no paso de este hilo" "1" "$(python3 "$BIN/print-pendiente-opcional.py" "$M/sessions/$F.md" --hoy 2026-11-11 | grep -c '^🔔 Vence hoy — recordatorio del proyecto, no es paso de este hilo')"

echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
