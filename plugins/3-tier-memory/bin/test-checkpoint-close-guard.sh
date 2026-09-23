#!/bin/bash
# Prueba de bin/checkpoint-close-guard.sh (hook Stop, 2.33.0, p-daf3051915).
#
# Fixtures REALES: las respuestas y snippets de los cierres de la sesion 5790b9f2 de este repo
# (bin/fixtures/cierre-5790b9f2/, extraidos de su JSONL). Los registros del transcript se arman con
# las formas reales de Claude Code (tool_use dentro de `assistant`, tool_result dentro de `user`,
# la expansion de un skill como `user` con isMeta). Lo que mas importa: que BLOQUEE las formas
# reales (3) y (4), y que se CALLE en un turno sin checkpoint o en un cierre bien pegado — un Stop
# que habla de mas se aprende a ignorar.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK:-$BIN/checkpoint-close-guard.sh}"
FX="$BIN/fixtures/cierre-5790b9f2"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

# memoria + ficha: $1 memoria, $2 fichero snippet ("-" = caso 5 de una linea, "PH" = placeholder),
# $3.. ficheros de calendario (cada uno un bloque impreso tal cual)
armar() {
  local M="$1"; shift; local SN="$1"; shift
  rm -rf "$M"; mkdir -p "$M/sessions" "$M/pendientes"
  cat > "$M/_pendientes.md" <<'EOF'
# Pendientes

## Alta prioridad

- [ ] Resolver de raiz los 4 defectos — _origen: [[sessions/2026-09-22-demo]]_ — _creado: 2026-09-22_ — _id: p-daf3051915_

## Media prioridad

- [ ] verificar en instalacion real — _origen: [[sessions/2026-09-22-demo]]_ — _creado: 2026-09-22_ — _id: p-a4439fa8fd_ — _bloqueado: que otra instalacion actualice el plugin_
- [ ] verificar si las reglas nuevas se siguen — _origen: [[sessions/2026-09-22-demo]]_ — _creado: 2026-09-22_ — _id: p-e685e9c92a_ — _revisar: 2026-09-27_
- [ ] plan.upsert sin guardian — _origen: [[sessions/2026-09-01-x]]_ — _creado: 2026-09-01_ — _id: p-014255373e_
- [ ] estado final 2.30.0 — _origen: [[sessions/2026-09-01-x]]_ — _creado: 2026-09-01_ — _id: p-49996efc69_

## Baja prioridad
EOF
  python3 - "$M/sessions/2026-09-22-demo.md" "$SN" "$@" <<'PY'
import sys, re
p, sn, cals = sys.argv[1], sys.argv[2], sys.argv[3:]
if sn == "-":
    retomar = "Ninguno — la sesion cerro sin continuidad."
elif sn == "PH":
    retomar = "<filled in Step 8>"
else:
    retomar = "```\n" + open(sn, encoding="utf-8").read().strip("\n") + "\n```"
# El caso 5 solo vale sin pendientes propios abiertos (lo exige checkpoint-audit.py).
pend = "- Ninguno" if sn == "-" else "- [ ] resolver de raiz — `p-daf3051915` (Alta)"
cal = ""
if cals:
    cal = "\n## Recordatorios de calendario\n"
    for c in cals:
        b = open(c, encoding="utf-8").read().strip("\n")
        tit = re.search(r"^Título: (.*)$", b, re.M).group(1)
        fecha = re.search(r"Recordatorio para el (\d{4}-\d{2}-\d{2})", b).group(1)
        cal += f"\n### {fecha} — {tit}\n\n````\n{b}\n````\n"
open(p, "w", encoding="utf-8").write(f"""---
type: session
date: 2026-09-22
---
# Demo

## Contexto
algo

## Plans
Ninguno.

## Pendientes
{pend}

## Como retomar

{retomar}
{cal}
## Related
- [[_pendientes]]
""")
PY
}

# transcript: $1 salida .jsonl, $2 modo de disparo (skill|print|nada|write), $3 ficha,
# $4 fichero con el texto que el assistant ESCRIBIO en el turno ("-" = ninguno),
# $5 fichero cuyo contenido va SOLO en el tool_result de print-como-retomar ("-" = ninguno)
tx() {
  python3 - "$@" <<'PY'
import json, sys
out, modo, ficha, texto, tr = sys.argv[1:6]
R = []
def a(blocks): R.append({"type": "assistant", "message": {"role": "assistant", "content": blocks}})
def u(content, meta=False):
    r = {"type": "user", "message": {"role": "user", "content": content}}
    if meta: r["isMeta"] = True
    R.append(r)
u("hola, turno viejo")
a([{"type": "text", "text": "respuesta vieja"}])
u("guarda el checkpoint")
if modo == "skill":
    a([{"type": "tool_use", "id": "t1", "name": "Skill", "input": {"skill": "checkpoint-3t"}}])
    u([{"type": "tool_result", "tool_use_id": "t1", "content": "Launching skill: checkpoint-3t"}])
    u([{"type": "text", "text": "# Memory Checkpoint\n..."}], meta=True)
if modo in ("skill", "print"):
    cmd = f'cd /tmp && JBIN=/x/bin\npython3 "$JBIN/print-como-retomar.py" "{ficha}"'
    a([{"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": cmd}}])
    salida = open(tr, encoding="utf-8").read() if tr != "-" else "ok"
    u([{"type": "tool_result", "tool_use_id": "t2", "content": salida}])
if modo == "write":
    a([{"type": "tool_use", "id": "t3", "name": "Write", "input": {"file_path": ficha, "content": "## Como retomar\nProximo paso: x"}}])
    u([{"type": "tool_result", "tool_use_id": "t3", "content": "ok"}])
if texto != "-":
    a([{"type": "text", "text": open(texto, encoding="utf-8").read()}])
with open(out, "w", encoding="utf-8") as fh:
    for r in R: fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
}

corre() {   # $1 transcript, $2 reentrante (true|false), $3 last_assistant_message (fichero o "-")
  local LAM=""; [ "$3" != "-" ] && [ -n "$3" ] && LAM="$(cat "$3")"
  python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"stop_hook_active":sys.argv[2]=="true","last_assistant_message":sys.argv[3],"cwd":"/tmp"}))' "$1" "$2" "$LAM" \
    | bash "$HOOK" 2>/dev/null
}
bloquea() { printf '%s' "$1" | grep -c '"decision": "block"' || true; }

M="$T/memory"; F="$M/sessions/2026-09-22-demo.md"

echo "== F3 real (turno 1813): snippet pegado, recordatorio de calendario solo 'persistido' =="
armar "$M" "$FX/snippet-1813.txt" "$FX/calendario-1880.txt"
tx "$T/t.jsonl" skill "$F" "$FX/respuesta-turno-1813.txt" -
O=$(corre "$T/t.jsonl" false -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "nombra el recordatorio que falta" "1" "$(printf '%s' "$O" | grep -c 'recordatorio de calendario')"
chk "el snippet SI estaba pegado: no lo reclama" "0" "$(printf '%s' "$O" | grep -c 'snippet `Como retomar` no esta')"
chk "y de paso F1: Proximo paso bloqueado por un tercero" "1" "$(printf '%s' "$O" | grep -c 'p-a4439fa8fd esta bloqueado')"

echo "== F4 real (turno 2129): snippet solo en el tool_result, calendario pegado =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
tx "$T/t.jsonl" print "$F" "$FX/respuesta-turno-2129.txt" "$T/salida-script.txt"
O=$(corre "$T/t.jsonl" false -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "dice que el snippet no esta en la respuesta" "1" "$(printf '%s' "$O" | grep -c 'snippet `Como retomar` no esta')"
chk "el calendario SI estaba: no lo reclama" "0" "$(printf '%s' "$O" | grep -c 'recordatorio de calendario')"

echo "== F2 real (turno 2071): todo pegado, pero Proximo paso es el caso 4 generico =="
armar "$M" "$FX/snippet-2071.txt" "$FX/calendario-2129.txt"
printf '%s\n\n%s\n' "$(cat "$FX/snippet-2071.txt")" "$(cat "$FX/calendario-2129.txt")" > "$T/r2071.txt"
tx "$T/t.jsonl" print "$F" "$T/r2071.txt" -
O=$(corre "$T/t.jsonl" false -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "por el caso 4" "1" "$(printf '%s' "$O" | grep -c 'caso 4 generico')"
chk "no reclama pegado" "0" "$(printf '%s' "$O" | grep -c 'no esta en tu respuesta')"

echo "== control: cierre correcto (snippet 2120 + calendario, ambos pegados) =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf 'Resumen.\n\n%s\n\n%s\n' "$(cat "$T/salida-script.txt")" "$(cat "$FX/calendario-2129.txt")" > "$T/bien.txt"
tx "$T/t.jsonl" skill "$F" "$T/bien.txt" "$T/salida-script.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== control: pegado dentro de un fence \`\`\`markdown y con espacios de mas =="
printf 'Resumen.\n\n```markdown\n%s\n```\n\n%s\n' "$(sed 's/$/   /' "$T/salida-script.txt")" "$(cat "$FX/calendario-2129.txt")" > "$T/bien2.txt"
tx "$T/t.jsonl" skill "$F" "$T/bien2.txt" -
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== control: el texto final solo llega por last_assistant_message (transcript atrasado) =="
tx "$T/t.jsonl" skill "$F" - -
chk "silencio" "" "$(corre "$T/t.jsonl" false "$T/bien.txt")"

echo "== control: el pegado esta en un bloque intermedio y el ultimo dice 'Listo' =="
python3 - "$T/t.jsonl" "$F" "$T/bien.txt" <<'PY'
import json, sys
out, ficha, bien = sys.argv[1:4]
R = [{"type": "user", "message": {"role": "user", "content": "cierra"}},
     {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "a", "name": "Bash",
       "input": {"command": f'python3 bin/print-como-retomar.py "{ficha}"'}}]}},
     {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "a", "content": "x"}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": open(bien).read()}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": "Listo."}]}}]
open(out, "w").write("\n".join(json.dumps(r) for r in R) + "\n")
PY
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== adversarial: snippet pegado con Proximo paso ALTERADO =="
sed 's/^Proximo paso: .*/Proximo paso: otra cosa inventada _id: p-daf3051915_./' "$T/bien.txt" > "$T/alterado.txt"
tx "$T/t.jsonl" skill "$F" "$T/alterado.txt" -
chk "bloquea" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== adversarial: el turno NO fue un checkpoint (solo texto) =="
tx "$T/t.jsonl" nada "$F" "$FX/respuesta-turno-2129.txt" -
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== adversarial: un Write de ficha a secas (asi escribe /backfill-3t) no dispara =="
tx "$T/t.jsonl" write "$F" "$FX/respuesta-turno-2129.txt" -
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== adversarial: Stop reentrante con el mismo defecto: avisa al usuario, no bloquea =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"
tx "$T/t.jsonl" print "$F" "$FX/respuesta-turno-2129.txt" -
O=$(corre "$T/t.jsonl" true -)
chk "no bloquea (sin bucle)" "0" "$(bloquea "$O")"
chk "pero avisa con systemMessage" "1" "$(printf '%s' "$O" | grep -c '"systemMessage"')"

echo "== caso 5 colapsado: la linea unica tambien tiene que estar en la respuesta =="
armar "$M" -
printf 'Hecho.\n' > "$T/sin.txt"
tx "$T/t.jsonl" skill "$F" "$T/sin.txt" -
chk "sin la linea: bloquea" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"
printf 'Hecho.\n\nComo retomar: Ninguno — la sesion cerro sin continuidad.\n' > "$T/con.txt"
tx "$T/t.jsonl" skill "$F" "$T/con.txt" -
chk "con la linea: silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== placeholder de Step 8 en la ficha al terminar un turno de checkpoint: bloquea =="
armar "$M" PH
tx "$T/t.jsonl" skill "$F" "$T/con.txt" -
O=$(corre "$T/t.jsonl" false -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "dice que Step 8 no corrio" "1" "$(printf '%s' "$O" | grep -c 'Step 8 no corrio')"

echo "== tres recordatorios: dos pegados + '+1 con fecha futura' pasa; '+2' no =="
sed -e 's/2026-09-27/2026-10-05/' -e 's/¿Se siguen/¿Tercero: se siguen/' "$FX/calendario-2129.txt" > "$T/cal3.txt"
sed -e 's/2026-09-27/2026-10-01/' -e 's/¿Se siguen/¿Segundo: se siguen/' "$FX/calendario-2129.txt" > "$T/cal2.txt"
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt" "$T/cal2.txt" "$T/cal3.txt"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf '%s\n\n%s\n\n%s\n\n+1 con fecha futura en _pendientes.md\n' "$(cat "$T/salida-script.txt")" "$(cat "$FX/calendario-2129.txt")" "$(cat "$T/cal2.txt")" > "$T/tres.txt"
tx "$T/t.jsonl" skill "$F" "$T/tres.txt" -
chk "+1 correcto: silencio" "" "$(corre "$T/t.jsonl" false -)"
sed 's/+1 con fecha/+2 con fecha/' "$T/tres.txt" > "$T/tres-mal.txt"
tx "$T/t.jsonl" skill "$F" "$T/tres-mal.txt" -
chk "+N equivocado: bloquea" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== ronda 1 del adversario: un mensaje de teammate a mitad del turno NO abre turno nuevo =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"
tx "$T/t.jsonl" print "$F" "$FX/respuesta-turno-2129.txt" -
python3 - "$T/t.jsonl" <<'PYT'
import json, sys
p = sys.argv[1]; L = open(p).read().splitlines()
tm = {"type": "user", "message": {"role": "user", "content": "Another Claude session sent a message: <teammate-message teammate_id=\"x\">hola</teammate-message>"}}
tn = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "<task-notification>\n<task-id>b1</task-id>\n</task-notification>"}]}}
L.insert(len(L) - 1, json.dumps(tm)); L.insert(len(L) - 1, json.dumps(tn))
open(p, "w").write("\n".join(L) + "\n")
PYT
chk "sigue bloqueando" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== ronda 1: dos fichas cerradas en el turno — la segunda no tapa a la primera =="
M2="$T/memory2"; armar "$M2" "$FX/snippet-2120.txt"
F2="$M2/sessions/2026-09-22-demo.md"
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"
python3 "$BIN/print-como-retomar.py" "$F2" > "$T/solo2.txt"
python3 - "$T/t.jsonl" "$F" "$F2" "$T/solo2.txt" <<'PYT'
import json, sys
out, f1, f2, txt = sys.argv[1:5]
R = [{"type": "user", "message": {"role": "user", "content": "cierra"}}]
for i, f in enumerate((f1, f2)):
    R.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": f"b{i}", "name": "Bash", "input": {"command": f'python3 x/print-como-retomar.py "{f}"'}}]}})
    R.append({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": f"b{i}", "content": "x"}]}})
R.append({"type": "assistant", "message": {"content": [{"type": "text", "text": open(txt).read()}]}})
open(out, "w").write("\n".join(json.dumps(r) for r in R) + "\n")
PYT
O=$(corre "$T/t.jsonl" false -)
chk "bloquea por la primera ficha (su calendario falta)" "1" "$(printf '%s' "$O" | grep -c 'recordatorio de calendario')"

echo "== ronda 2: las dos fichas en UNA sola llamada Bash — tambien se revisan las dos =="
python3 - "$T/t.jsonl" "$F" "$F2" "$T/solo2.txt" <<'PYT'
import json, sys
out, f1, f2, txt = sys.argv[1:5]
cmd = f'python3 x/print-como-retomar.py "{f2}"; python3 x/print-como-retomar.py "{f1}"'
R = [{"type": "user", "message": {"role": "user", "content": "cierra"}},
     {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "b", "name": "Bash", "input": {"command": cmd}}]}},
     {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "b", "content": "x"}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": open(txt).read()}]}}]
open(out, "w").write("\n".join(json.dumps(r) for r in R) + "\n")
PYT
chk "bloquea por la segunda ficha del mismo comando" "1" "$(corre "$T/t.jsonl" false - | grep -c 'recordatorio de calendario')"

echo "== transcript ilegible o ausente: silencio (falla abierto) =="
chk "sin transcript" "" "$(printf '{"stop_hook_active":false}' | bash "$HOOK" 2>/dev/null)"
chk "stdin basura" "" "$(printf 'no-json' | bash "$HOOK" 2>/dev/null)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
