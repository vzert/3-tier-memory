#!/bin/bash
# Prueba del aviso ⚠ del 🔔 de print-pendiente-opcional.py (2.64.0).
#
# Caso real (otro proyecto, 2026-10-24): el 🔔 del cierre mostro el texto viejo de un pendiente
# que otra sesion ya habia resuelto. El aviso sale cuando OTRA ventana viva del mismo proyecto
# corrio una herramienta de accion con el id en las ultimas 2 h, sin /checkpoint-3t despues
# (paso_ajeno.otras_ventanas). Ids y textos inventados: el repo es publico.
# Lo que tiene que cumplir:
# - positivo: otra ventana viva con el id -> el 🔔 sigue y lleva la linea ⚠;
# - negativo: otra ventana que ya cerro, un comando de hace 3 h, sin transcript, o ➕ -> sin ⚠;
# - el 🔔 nunca se suprime ni cambia de pendiente por el aviso.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proyecto"; M="$P/memory"; F="$M/sessions/2026-10-24-demo.md"
TP="$T/projects/-Users-demo-proyecto"
ID=p-2a2a2a2a2a
armar() {
  rm -rf "$P" "$T/projects"; mkdir -p "$M/sessions" "$TP"
  printf '# Pendientes\n\n## Alta prioridad\n\n- [ ] Parchar el servidor demo — _origen: [[sessions/2026-10-20-origen]]_ — _creado: 2026-10-20_ — _revisar: 2026-10-24_ — _id: %s_\n\n## Media prioridad\n## Baja prioridad\n' "$ID" > "$M/_pendientes.md"
  printf -- '---\ntype: session\ndate: 2026-10-24\n---\n# Demo\n\n## Como retomar\n\n```\nRetomamos: demo.\n\nProximo paso: otra cosa _id: p-9999999999_.\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```\n\n## Related\n' > "$F"
  printf -- '---\ntype: session\n---\n# Origen\n' > "$M/sessions/2026-10-20-origen.md"
  echo '{"type":"user","message":{"role":"user","content":"hola"}}' > "$TP/propia.jsonl"
}
# otra ARCHIVO MODO: arma el transcript de otra ventana. TX_HACE = segundos de antiguedad.
otra() {
  python3 - "$1" "$2" <<'PY'
import datetime, json, os, sys
ruta, modo = sys.argv[1:3]
ts = (datetime.datetime.now(datetime.timezone.utc)
      - datetime.timedelta(seconds=int(os.environ.get("TX_HACE", "0")))).isoformat().replace("+00:00", "Z")
ID = "p-2a2a2a2a2a"
r = [{"type": "user", "timestamp": ts, "message": {"role": "user", "content": "trabaja el servidor"}},
     {"type": "assistant", "timestamp": ts, "message": {"content": [
         {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ssh demo 'grep node " + ID + "'"}}]}}]
if modo == "cerro":
    r.append({"type": "user", "timestamp": ts, "message": {"role": "user",
              "content": "<command-name>/checkpoint-3t</command-name>"}})
with open(ruta, "w", encoding="utf-8") as fh:
    for x in r:
        fh.write(json.dumps(x, ensure_ascii=False) + "\n")
PY
}
out() { python3 "$BIN/print-pendiente-opcional.py" "$F" --hoy 2026-10-24 "$@" 2>&1; }
n_alerta() { printf '%s' "$1" | grep -c '^⚠' || true; }

echo "== A1. otra ventana viva con el id: el 🔔 sale con ⚠ =="
armar; otra "$TP/otra.jsonl" viva
O=$(out --transcript "$TP/propia.jsonl")
chk "sigue el 🔔" "1" "$(printf '%s' "$O" | grep -c '^🔔')"
chk "es el mismo pendiente" "1" "$(printf '%s' "$O" | grep -c "_id: ${ID}_")"
chk "lleva el aviso ⚠" "1" "$(n_alerta "$O")"

echo "== A2. sin huellas: sin ⚠ =="
armar; otra "$TP/otra.jsonl" cerro
chk "la otra sesion ya cerro" "0" "$(n_alerta "$(out --transcript "$TP/propia.jsonl")")"
armar; TX_HACE=10800 otra "$TP/otra.jsonl" viva
chk "un comando de hace 3 h" "0" "$(n_alerta "$(out --transcript "$TP/propia.jsonl")")"
armar
chk "sin otras ventanas" "0" "$(n_alerta "$(out --transcript "$TP/propia.jsonl")")"
armar; otra "$TP/otra.jsonl" viva
chk "sin transcript no avisa (falla abierto)" "0" "$(n_alerta "$(CLAUDE_CODE_SESSION_ID= out)")"
chk "transcript inexistente" "0" "$(n_alerta "$(out --transcript "$TP/no-existe.jsonl")")"
armar; otra "$TP/otra.jsonl" viva
printf '# Pendientes\n\n## Alta prioridad\n\n- [ ] Vencido sin huellas — _creado: 2026-10-01_ — _revisar: 2026-10-20_ — _id: p-2a2a2a2a2a_\n' > "$M/_pendientes.md"
printf -- '---\ntype: session\ndate: 2026-10-24\n---\n# Demo\n\n## Como retomar\n\nNinguno — la sesion cerro sola.\n\n## Related\n' > "$F"
O=$(out --transcript "$TP/propia.jsonl")
chk "el ➕ opcional no lleva ⚠" "0" "$(n_alerta "$O")"
chk "el ➕ sale" "1" "$(printf '%s' "$O" | grep -c '^➕')"

echo
echo "RESULTADO: $pass ok, $fail fallas"
[ "$fail" -eq 0 ]
