#!/bin/bash
# Prueba de `snippet.titulo_paso`, `snippet.paso_no_trabajado` y `snippet.paso_otra_ventana` en
# checkpoint-audit.py + paso_ajeno.py (2.63.43).
#
# Que tiene que cumplir, y por que:
# - Caso real (otro proyecto, 2026-10-22): la ficha se titulo con un pendiente y dejo de paso
#   otro, que la sesion solo desbloqueo, ligo y corrigio en el cierre, mientras otra
#   ventana corria comandos con ese id. bin/fixtures/paso-ajeno/ tiene esa forma con texto
#   inventado (el repo es publico); los transcripts se arman aqui.
# - Los tres son POR-DISEÑO, nunca SALTADO: viajan en la revision del cierre (d414).
# - "Trabajado" = lo recibio o lo pidio el usuario, lo creo, o fuera del turno del checkpoint lo
#   corrigio/cerro o edito fuera de memory/. Ligar, desbloquear, fechar o marcar no cuenta.
# - Otra ventana = otro transcript del mismo directorio (o de uno que empieza por su nombre) de
#   las ultimas 2 h con una herramienta de accion cuyo input nombra el id, sin un /checkpoint-3t
#   despues (esa sesion ya cerro; su turno de cierre y sus ediciones a memory/ tampoco cuentan,
#   adversario de 2.63.43, ronda 2). SendMessage no cuenta, ni un subagente (subcarpeta), ni un
#   comando de hace mas de 2 h (con 24 h avisaba en 12 de 21 cierres reales; adversario de 2.63.43).
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
S=2026-10-22-demo-borrar-repos
P="$T/projects/-Users-demo-proyecto"
armar() {
  rm -rf "$M" "$T/projects"; cp -R "$BIN/fixtures/paso-ajeno" "$M"; rm -rf "$M/transcripts"; mkdir -p "$P"
}
# tx ARCHIVO MODO...: arma un transcript. Modos: checkpoint-relate (forma del caso real: el id solo
# aparece en el turno del /checkpoint-3t con relate, block --desbloquear y update), update-fuera
# (update del id en un turno normal), prompt (el usuario nombra el id), alta (pendiente.add que
# imprime el id), edita (Edit fuera de memory/ que nombra el id), mensaje (solo SendMessage),
# accion (Bash con el id), cerro (un /checkpoint-3t al final). Cada registro lleva `timestamp`:
# ahora, o TX_HACE segundos antes.
tx() {
  python3 - "$@" <<'PY'
import datetime, json, os, sys
ruta, modos = sys.argv[1], sys.argv[2:]
TS = (datetime.datetime.now(datetime.timezone.utc)
      - datetime.timedelta(seconds=int(os.environ.get("TX_HACE", "0")))).isoformat().replace("+00:00", "Z")
ID = "p-1c1c1c1c1c"
r = []
def u(texto, meta=False):
    r.append({"type": "user", "isMeta": meta, "message": {"role": "user", "content": texto}})
def bash(cmd, tid="t0", salida=""):
    r.append({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": cmd}}]}})
    r.append({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": tid, "content": salida}]}})
u("revisa la bandeja de los repos viejos")
for m in modos:
    if m == "prompt":
        u("y mira tambien " + ID)
    if m == "update-fuera":
        bash("python3 journal-emit.py --type pendiente.update --id " + ID + " --text x", "t1")
    if m == "alta":
        bash("python3 journal-emit.py --type pendiente.add --text demo", "t2", "evento ok: id " + ID)
    if m == "edita":
        r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t3",
                  "name": "Edit", "input": {"file_path": "/x/src/app.py", "old_string": "a",
                                            "new_string": "# " + ID}}]}})
    if m == "mensaje":
        r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t4",
                  "name": "SendMessage", "input": {"to": "x", "message": "lleva " + ID}}]}})
    if m == "accion":
        bash("ssh host 'grep db " + ID + "'", "t5")
if "cerro" in modos:
    u("<command-name>/checkpoint-3t</command-name>")
if "cierre-escribe" in modos:  # su cierre escribe la ficha y corre un evento con el id
    u("<command-name>/checkpoint-3t</command-name>")
    r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "k1",
              "name": "Write", "input": {"file_path": "/x/memory/sessions/f.md", "content": ID}}]}})
    bash("python3 journal-emit.py --type pendiente.retomar --id " + ID, "k2")
if "trabajo-tras-cierre" in modos:  # cerro y luego, en un turno nuevo, volvio a trabajarlo
    u("<command-name>/checkpoint-3t</command-name>")
    u("sigue con lo de la base")
    bash("ssh host 'grep db " + ID + "'", "k3")
if "memoria" in modos:  # en un turno normal solo edita un archivo de memory/ con el id
    r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "k4",
              "name": "Edit", "input": {"file_path": "/x/memory/_pendientes.md", "old_string": "a",
                                        "new_string": ID}}]}})
if "checkpoint-relate" in modos:
    u("<command-name>/checkpoint-3t</command-name>")
    bash("python3 journal-emit.py --type pendiente.block --id " + ID + " --desbloquear", "c1")
    bash("python3 journal-emit.py --type pendiente.relate --id " + ID + " --relacionado p-6b6b6b6b6b", "c2")
    bash("python3 journal-emit.py --type pendiente.update --id " + ID + " --text y", "c3")
with open(ruta, "w") as f:
    for x in r:
        x["timestamp"] = TS
        f.write(json.dumps(x) + "\n")
PY
}
# detalle CLAVE [--transcript RUTA] -> el texto `detalle` del hallazgo
detalle() {
  local k="$1"; shift
  python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$S.md" --no-git --hoy 2026-10-22 \
    --solo-snippet --json "$@" | python3 -c '
import json, sys
x = [h for h in json.load(sys.stdin) if h["clave"] == sys.argv[1]]
print(x[0]["detalle"] if x else "ausente")' "$k"
}
# estado CLAVE [--transcript RUTA] -> "ESTADO|lineas" o "ausente"
estado() {
  local k="$1"; shift
  python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$S.md" --no-git --hoy 2026-10-22 \
    --solo-snippet --json "$@" | python3 -c '
import json, sys
x = [h for h in json.load(sys.stdin) if h["clave"] == sys.argv[1]]
print(x[0]["estado"] + "|" + " / ".join(x[0].get("lineas") or []) if x else "ausente")' "$k"
}

echo "== 1. forma del caso real: los tres avisos =="
armar
tx "$P/propia.jsonl" checkpoint-relate
tx "$P/otra.jsonl" accion
chk "titulo y paso de pendientes distintos" \
  "POR-DISEÑO|Retomamos: p-7a7a7a7a7a — Proximo paso: p-1c1c1c1c1c" "$(estado snippet.titulo_paso)"
chk "paso no trabajado: solo lo ordeno en el cierre" \
  "POR-DISEÑO|p-1c1c1c1c1c: solo block, solo relate, solo update en el cierre" \
  "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
chk "otra ventana corre comandos con el paso" \
  "POR-DISEÑO|p-1c1c1c1c1c: otra.jsonl" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
chk "el texto humano lo marca como aviso" "1" "$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$S.md" --no-git --hoy 2026-10-22 --solo-snippet --transcript "$P/propia.jsonl" | grep -c 'snippet.paso_no_trabajado.*aviso, no bloquea')"

echo "== 1b. el fixture guardado (memoria + transcripts) da los tres avisos =="
# bin/fixtures/paso-ajeno/transcripts/: propia.jsonl con la forma del caso real y otra.jsonl, otra
# ventana sin cerrar. cp les pone la hora de ahora (otra.jsonl no trae `timestamp`).
armar; cp "$BIN/fixtures/paso-ajeno/transcripts/"*.jsonl "$P/"
for k in titulo_paso paso_no_trabajado paso_otra_ventana; do
  chk "fixture guardado: $k" "POR-DISEÑO" "$(estado snippet.$k --transcript "$P/propia.jsonl" | cut -d'|' -f1)"
done

echo "== 2. trabajado: cada forma de trabajo lo vuelve HECHO =="
for modo in update-fuera prompt alta edita; do
  armar; tx "$P/propia.jsonl" "$modo" checkpoint-relate
  chk "$modo" "HECHO|" "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
done
armar; tx "$P/propia.jsonl"
chk "el id no aparece en la sesion" "POR-DISEÑO|p-1c1c1c1c1c: no aparece en ningun comando de la sesion" \
  "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"

echo "== 3. otra ventana: lo que no cuenta =="
armar; tx "$P/propia.jsonl" checkpoint-relate; tx "$P/otra.jsonl" mensaje
chk "solo un SendMessage" "HECHO|" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; mkdir -p "$P/sub/subagents"; tx "$P/sub/subagents/agent-a.jsonl" accion
chk "un subagente (subcarpeta)" "HECHO|" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; tx "$P/otra.jsonl" accion; touch -t 202001010000 "$P/otra.jsonl"
chk "un transcript sin tocar en mas de 2 h" "HECHO|" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; TX_HACE=10800 tx "$P/otra.jsonl" accion
chk "un comando de hace 3 h en un transcript recien escrito" "HECHO|" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; TX_HACE=3600 tx "$P/otra.jsonl" accion
chk "un comando de hace 1 h si cuenta" "POR-DISEÑO|p-1c1c1c1c1c: otra.jsonl" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; tx "$P/otra.jsonl" accion cerro
chk "la otra sesion cerro despues del comando" "HECHO|" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; tx "$P/otra.jsonl" accion cierre-escribe
chk "su turno de cierre nombra el id: no cuenta" "HECHO|" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; tx "$P/otra.jsonl" memoria
chk "solo edita memory/: no cuenta" "HECHO|" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; tx "$P/otra.jsonl" trabajo-tras-cierre
chk "vuelve a trabajarlo tras cerrar: si cuenta" "POR-DISEÑO|p-1c1c1c1c1c: otra.jsonl" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; mkdir -p "$T/projects/-Users-demo-otro"; tx "$T/projects/-Users-demo-otro/x.jsonl" accion
chk "otro proyecto" "HECHO|" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate; mkdir -p "$P--claude-worktrees-a"; tx "$P--claude-worktrees-a/w.jsonl" accion
chk "un worktree dentro del proyecto si cuenta" "POR-DISEÑO|p-1c1c1c1c1c: w.jsonl" "$(estado snippet.paso_otra_ventana --transcript "$P/propia.jsonl")"

echo "== 4. titulo y paso ligados, o el mismo id: HECHO =="
armar
python3 -c 'import sys;p=sys.argv[1];t=open(p,encoding="utf-8").read();open(p,"w",encoding="utf-8").write(t.replace("_relacionado: p-6b6b6b6b6b_","_relacionado: p-6b6b6b6b6b, p-1c1c1c1c1c_",1))' "$M/_pendientes.md"
chk "ligados por _relacionado" "HECHO|" "$(estado snippet.titulo_paso)"
armar
python3 -c 'import sys;p=sys.argv[1];t=open(p,encoding="utf-8").read();open(p,"w",encoding="utf-8").write(t.replace("repos viejos (p-7a7a7a7a7a)","host (p-1c1c1c1c1c)",1))' "$M/sessions/$S.md"
chk "el titulo cita el del paso" "HECHO|" "$(estado snippet.titulo_paso)"

echo "== 5. no aplica =="
armar; tx "$P/propia.jsonl" checkpoint-relate
chk "sin --transcript no mira el trabajo" "ausente" "$(estado snippet.paso_no_trabajado)"
python3 -c 'import sys,re;p=sys.argv[1];t=open(p,encoding="utf-8").read();open(p,"w",encoding="utf-8").write(re.sub(r"^Proximo paso: .*$","Proximo paso: ninguno — espera la respuesta, ver Recordatorios de calendario.",t,count=1,flags=re.M))' "$M/sessions/$S.md"
chk "un snippet ninguno" "ausente" "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
armar; tx "$P/propia.jsonl" checkpoint-relate
python3 -c 'import sys;p=sys.argv[1];t=open(p,encoding="utf-8").read();open(p,"w",encoding="utf-8").write(t.replace("date: 2026-10-22","date: 2026-10-21",1))' "$M/sessions/$S.md"
cp "$M/sessions/$S.md" "$M/sessions/2026-10-21-demo-borrar-repos.md"
chk "una ficha anterior al corte" "ausente" "$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/2026-10-21-demo-borrar-repos.md" --no-git --hoy 2026-10-22 --solo-snippet --json --transcript "$P/propia.jsonl" | python3 -c 'import json,sys;print("ausente" if not [h for h in json.load(sys.stdin) if h["clave"].startswith("snippet.paso_no")] else "presente")')"

echo "== 6. un transcript ilegible falla abierto =="
armar; printf 'no es json\n' > "$P/propia.jsonl"
chk "transcript sin registros legibles: sin aviso" "HECHO|" \
  "$(estado snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
chk "y dice no aplica, no que lo trabajo" "no aplica: el transcript de la sesion no se pudo leer" \
  "$(detalle snippet.paso_no_trabajado --transcript "$P/propia.jsonl")"
chk "transcript inexistente: sin aviso" "HECHO|" \
  "$(estado snippet.paso_no_trabajado --transcript "$P/no-existe.jsonl")"

echo
echo "RESULTADO: $pass ok, $fail fallas"
[ "$fail" -eq 0 ]
