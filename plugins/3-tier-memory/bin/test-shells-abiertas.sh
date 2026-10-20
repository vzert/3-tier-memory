#!/bin/bash
# Prueba de shells-abiertas.py (2.63.25): lista las shells en segundo plano que la sesion dejo vivas.
#
# El transcript se arma aqui con las formas reales medidas el 2026-10-20 en ~1500 JSONL: el
# tool_result "Command running in background with ID", "Monitor started (task", la
# <task-notification> con <status>, el evento "[Monitor expired", y los resultados de TaskStop
# "Successfully stopped task" y "No task found with ID". Casos:
#  1. un Bash en segundo plano sin fin sale ABIERTA, con su salida y sus ultimas lineas;
#  2. uno con notificacion completed (content texto) y otro con failed (content en bloques) no salen;
#  3. un Monitor con "[Monitor expired" en una queue-operation no sale; uno sin fin si;
#  4. TaskStop con exito y TaskStop "No task found" cierran;
#  5. un mensaje del agente que CITA una notificacion no cierra nada, ni la salida de un Bash que la
#     imprime;
#  6. un Bash normal (sin run_in_background) no cuenta, salvo que pase solo a segundo plano al vencer
#     su timeout ("moved to the background (ID: ...)"): ese sale ABIERTA; y un Bash cuya salida
#     contiene la frase de lanzamiento como dato no abre nada, ni en medio ni AL INICIO de su salida:
#     el id sale de toolUseResult.backgroundTaskId / taskId. Una linea sin toolUseResult (transcript
#     viejo) se lee por el texto anclado;
#  7. --session-id busca en --projects-root; sin id sale 2 con abiertas=?.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset CLAUDE_CODE_SESSION_ID
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

SID=11111111-2222-3333-4444-555555555555
mkdir -p "$T/projects/-tmp-proyecto" "$T/tasks"
printf 'muestra 1 ok\n\nTimeout expired\nTimeout expired\n' > "$T/tasks/bvivo0001.output"
J="$T/projects/-tmp-proyecto/$SID.jsonl"
python3 - "$J" "$T/tasks" <<'EOF'
import json, sys
ruta, tasks = sys.argv[1], sys.argv[2]
L = []
def use(uid, name, inp):
    L.append({"type": "assistant", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": uid, "name": name, "input": inp}]}})
def res(uid, content, tur=None):
    o = {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": uid, "content": content}]}}
    if tur is not None:
        o["toolUseResult"] = tur
    L.append(o)
def bg(uid, tid, desc, cmd):
    use(uid, "Bash", {"command": cmd, "description": desc, "run_in_background": True})
    res(uid, "Command running in background with ID: %s. Output is being written to: %s/%s.output. You will be notified when it completes." % (tid, tasks, tid),
        {"stdout": "", "stderr": "", "interrupted": False, "backgroundTaskId": tid})
def notif(tid, status, como="texto"):
    t = "<task-notification>\n<task-id>%s</task-id>\n<status>%s</status>\n<summary>x</summary>\n</task-notification>" % (tid, status)
    if como == "texto":
        L.append({"type": "user", "message": {"role": "user", "content": t}})
    else:
        L.append({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "<system-reminder>aviso</system-reminder>\n" + t}]}})

bg("u1", "bvivo0001", "Muestreo de prueba", "while true; do sample; sleep 900; done")       # 1: abierta
bg("u2", "bfin00002", "Termina bien", "echo listo"); notif("bfin00002", "completed")         # 2: cerrada
bg("u3", "bfalla003", "Termina mal", "false"); notif("bfalla003", "failed", como="bloques")   # 2: cerrada
use("u4", "Monitor", {"description": "watch que expira", "command": "tail -f x", "timeout_ms": 1000})
res("u4", "Monitor started (task bmon00004, expires in 30m unless the source ends first).", {"taskId": "bmon00004", "timeoutMs": 1000})
L.append({"type": "queue-operation", "operation": "enqueue", "content":
          "<task-notification>\n<task-id>bmon00004</task-id>\n<summary>Monitor event</summary>\n<event>[Monitor expired after 30m with 2 events delivered.]</event>\n</task-notification>"})  # 3: cerrada
use("u5", "Monitor", {"description": "watch vivo", "command": "tail -f y"})
res("u5", [{"type": "text", "text": "Monitor started (task bmon00005, expires in 30m)."}], {"taskId": "bmon00005"})  # 3: abierta
bg("u6", "bstop0006", "Se para", "sleep 999")
use("s6", "TaskStop", {"task_id": "bstop0006"}); res("s6", '{"message":"Successfully stopped task: bstop0006 (sleep 999)"}')  # 4
bg("u7", "bnone0007", "Ya no existe", "sleep 999")
use("s7", "TaskStop", {"task_id": "bnone0007"}); res("s7", "<tool_use_error>No task found with ID: bnone0007</tool_use_error>")  # 4
bg("u8", "bcita0008", "Citada", "sleep 999")
L.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text":
          "Llego <task-notification><task-id>bcita0008</task-id><status>completed</status></task-notification>"}]}})  # 5: sigue abierta
use("u9", "Bash", {"command": "ls", "description": "normal"}); res("u9", "a\nb")              # 6
use("u11", "Bash", {"command": "grep -h ID otro.jsonl", "description": "Imprime la frase como dato"})
res("u11", "linea 203: Command running in background with ID: bdato0011. Output is being written to: /x",
    {"stdout": "linea 203: ...", "stderr": ""})  # 6c: no cuenta
use("u12", "Bash", {"command": "echo 'Command running in background with ID: bfant0012'", "description": "Eco al inicio"})
res("u12", "Command running in background with ID: bfant0012. Output is being written to: /x",
    {"stdout": "Command running in background with ID: bfant0012", "stderr": ""})  # 6d: no cuenta (revisor externo, ronda 1)
use("u13", "Bash", {"command": "sleep 999", "description": "Transcript viejo", "run_in_background": True})
res("u13", "Command running in background with ID: bviej0013. Output is being written to: /x.")  # 6e: sin toolUseResult, por texto
bg("u14", "becho0014", "Su notificacion se imprime", "sleep 999")
use("u15", "Bash", {"command": "cat notif.txt", "description": "Imprime una notificacion"})
res("u15", "<task-notification><task-id>becho0014</task-id><status>completed</status></task-notification>",
    {"stdout": "...", "stderr": ""})  # 5b: el eco de un Bash no cierra
use("u10", "Bash", {"command": "make test", "description": "Suite larga", "timeout": 600000})
res("u10", "Command did not complete within its 600s timeout and was moved to the background (ID: bauto0010). Output is being written to: %s/bauto0010.output." % tasks,
    {"stdout": "", "stderr": "", "backgroundTaskId": "bauto0010", "timedOutAfterMs": 600000})  # 6b: abierta
L.append("no es un dict");
with open(ruta, "w") as fh:
    for o in L:
        fh.write(json.dumps(o) + "\n")
    fh.write("{linea rota\n")
EOF

S="python3 $BIN/shells-abiertas.py"
echo "== 1-6. por --transcript =="
OUT=$($S --transcript "$J"); RC=$?
chk "sale 0" "0" "$RC"
chk "resumen: 6 abiertas, 5 cerradas" "resumen: abiertas=6 cerradas=5" "$(printf '%s\n' "$OUT" | tail -1)"
chk "1: el Bash vivo sale ABIERTA" "1" "$(printf '%s\n' "$OUT" | grep -c '^ABIERTA  bvivo0001  Bash  Muestreo de prueba$')"
chk "1: muestra la salida con sus bytes" "1" "$(printf '%s\n' "$OUT" | grep -c "salida: $T/tasks/bvivo0001.output ($(wc -c < "$T/tasks/bvivo0001.output" | tr -d ' ') bytes")"
chk "1: muestra las 3 ultimas lineas no vacias" "muestra 1 ok|Timeout expired|Timeout expired" "$(printf '%s\n' "$OUT" | sed -n 's/^  ultimas lineas: //p' | paste -sd'|' -)"
chk "2: completed no sale" "0" "$(printf '%s\n' "$OUT" | grep -c bfin00002)"
chk "2: failed en bloques no sale" "0" "$(printf '%s\n' "$OUT" | grep -c bfalla003)"
chk "3: Monitor expirado no sale" "0" "$(printf '%s\n' "$OUT" | grep -c bmon00004)"
chk "3: Monitor vivo sale" "1" "$(printf '%s\n' "$OUT" | grep -c '^ABIERTA  bmon00005  Monitor  watch vivo$')"
chk "4: TaskStop con exito cierra" "0" "$(printf '%s\n' "$OUT" | grep -c bstop0006)"
chk "4: TaskStop sin tarea cierra" "0" "$(printf '%s\n' "$OUT" | grep -c bnone0007)"
chk "5: la cita del agente no cierra" "1" "$(printf '%s\n' "$OUT" | grep -c '^ABIERTA  bcita0008')"
chk "6: el Bash normal no cuenta" "0" "$(printf '%s\n' "$OUT" | grep -c 'normal')"
chk "6d: la frase al inicio de un Bash normal no abre tarea" "0" "$(printf '%s\n' "$OUT" | grep -c bfant0012)"
chk "6e: sin toolUseResult se lee el texto" "1" "$(printf '%s\n' "$OUT" | grep -c '^ABIERTA  bviej0013')"
chk "5b: el eco de una notificacion en un Bash no cierra" "1" "$(printf '%s\n' "$OUT" | grep -c '^ABIERTA  becho0014')"
chk "6c: la frase como dato no abre tarea" "0" "$(printf '%s\n' "$OUT" | grep -c bdato0011)"
chk "6b: el Bash que paso solo a segundo plano sale" "1" "$(printf '%s\n' "$OUT" | grep -c '^ABIERTA  bauto0010  Bash  Suite larga$')"

echo "== 7. por id =="
OUT=$($S --session-id "$SID" --projects-root "$T/projects"); RC=$?
chk "--session-id encuentra el JSONL" "0 resumen: abiertas=6 cerradas=5" "$RC $(printf '%s\n' "$OUT" | tail -1)"
OUT=$(CLAUDE_CODE_SESSION_ID="$SID" $S --projects-root "$T/projects"); RC=$?
chk "\$CLAUDE_CODE_SESSION_ID tambien" "0 resumen: abiertas=6 cerradas=5" "$RC $(printf '%s\n' "$OUT" | tail -1)"
OUT=$($S --projects-root "$T/projects"); RC=$?
chk "sin id: exit 2 y abiertas=?" "2 resumen: abiertas=? motivo=sin-session-id (pasa --session-id o --transcript)" "$RC $OUT"
OUT=$($S --session-id no-existe --projects-root "$T/projects"); RC=$?
chk "id sin JSONL: exit 2" "2 resumen: abiertas=? motivo=no-hay-jsonl" "$RC $OUT"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
