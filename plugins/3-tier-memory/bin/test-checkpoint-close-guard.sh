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
- [ ] verificar si las reglas nuevas se siguen — _origen: [[sessions/2026-09-22-demo]]_ — _creado: 2026-09-22_ — _id: p-e685e9c92a_ — _revisar: 2099-09-27_
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
chk "nombra el recordatorio que falta" "1" "$(printf '%s' "$O" | grep -c 'recordatorios de calendario no estan')"
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
     {"type": "assistant", "message": {"content": [{"type": "text", "text": open(bien, encoding="utf-8").read()}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": "Listo."}]}}]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
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
p = sys.argv[1]; L = open(p, encoding="utf-8").read().splitlines()
tm = {"type": "user", "message": {"role": "user", "content": "Another Claude session sent a message: <teammate-message teammate_id=\"x\">hola</teammate-message>"}}
tn = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "<task-notification>\n<task-id>b1</task-id>\n</task-notification>"}]}}
L.insert(len(L) - 1, json.dumps(tm)); L.insert(len(L) - 1, json.dumps(tn))
open(p, "w", encoding="utf-8").write("\n".join(L) + "\n")
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
R.append({"type": "assistant", "message": {"content": [{"type": "text", "text": open(txt, encoding="utf-8").read()}]}})
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYT
O=$(corre "$T/t.jsonl" false -)
chk "bloquea por la primera ficha (su calendario falta)" "1" "$(printf '%s' "$O" | grep -c 'recordatorios de calendario no estan')"

echo "== ronda 2: las dos fichas en UNA sola llamada Bash — tambien se revisan las dos =="
python3 - "$T/t.jsonl" "$F" "$F2" "$T/solo2.txt" <<'PYT'
import json, sys
out, f1, f2, txt = sys.argv[1:5]
cmd = f'python3 x/print-como-retomar.py "{f2}"; python3 x/print-como-retomar.py "{f1}"'
R = [{"type": "user", "message": {"role": "user", "content": "cierra"}},
     {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "b", "name": "Bash", "input": {"command": cmd}}]}},
     {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "b", "content": "x"}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": open(txt, encoding="utf-8").read()}]}}]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYT
chk "bloquea por la segunda ficha del mismo comando" "1" "$(corre "$T/t.jsonl" false - | grep -c 'recordatorios de calendario no estan')"

echo "== 2.33.1 (p-c72a33ae7a), caso REAL: se cierra un pendiente que el snippet cita y el snippet no se rehace =="
# Fixture: bin/fixtures/cierre-9ce2e917/ — el snippet que Victor tenia (con p-477bb60303 en
# `Sigue abierto`), el comando real que lo resolvio y la respuesta real de ese turno.
FX2="$BIN/fixtures/cierre-9ce2e917"
viejo() {   # memoria con la ficha del checkpoint; p-477bb60303 ya NO esta abierto (se resolvio)
  armar "$M" "$FX2/snippet-antes-del-push.txt"
  python3 - "$M/_pendientes.md" <<'PYP'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
extra = "".join(f"- [ ] pendiente {i} — _origen: [[sessions/2026-09-22-demo]]_ — _creado: 2026-09-22_ — _id: {i}_\n"
                for i in ("p-272254efc5", "p-6071ea6987", "p-4d784c958f"))
open(p, "w", encoding="utf-8").write(t.replace("## Baja prioridad", "## Baja prioridad\n\n" + extra))
PYP
}
tx2() {   # $1 transcript  $2 comando del turno nuevo  $3 texto de la respuesta del turno nuevo
          # $4 (opcional) fichero con la salida REAL del comando, que va en su tool_result;
          # con `$4` = "bloques:<fichero>" va como lista de bloques `text` en vez de string
  python3 - "$1" "$F" "$FX2/snippet-antes-del-push.txt" "$2" "$3" "${4:-}" <<'PYT'
import json, sys
out, ficha, snip, cmd, txt, res = sys.argv[1:7]
if not res:
    res = "p-477bb60303"
elif res.startswith("bloques:"):
    res = [{"type": "text", "text": open(res[8:], encoding="utf-8").read()}]
else:
    res = open(res, encoding="utf-8").read()
R = [{"type": "user", "message": {"role": "user", "content": "guarda el checkpoint"}},
     {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "w", "name": "Write",
        "input": {"file_path": ficha, "content": "## Como retomar\n..."}}]}},
     {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "w", "content": "ok"}]}},
     {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "p", "name": "Bash",
        "input": {"command": f'python3 x/print-como-retomar.py "{ficha}"'}}]}},
     {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "p", "content": "x"}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": open(snip, encoding="utf-8").read()}]}},
     {"type": "user", "message": {"role": "user", "content": "<bash-input> git push origin main</bash-input>"}},
     {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "r", "name": "Bash",
        "input": {"command": open(cmd, encoding="utf-8").read()}}]}},
     {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "r", "content": res}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": open(txt, encoding="utf-8").read()}]}}]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r, ensure_ascii=False) for r in R) + "\n")
PYT
}
viejo
tx2 "$T/t.jsonl" "$FX2/comando-resolve.txt" "$FX2/respuesta-tras-el-push.txt"
O=$(corre "$T/t.jsonl" false -)
chk "bloquea el turno real" "1" "$(bloquea "$O")"
chk "nombra el id cerrado que sigue en el snippet" "1" "$(printf '%s' "$O" | grep -c 'snippet.ids_vivos.*p-477bb60303')"

echo "== control: el mismo turno, pero la ficha ya corregida y el snippet nuevo pegado =="
python3 - "$F" <<'PYX'
import sys, re
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = re.sub(r"(?m)^Sigue abierto: .*$", "Sigue abierto: verificar el hook _id: p-6071ea6987_ · medir _id: p-4d784c958f_.", t)
open(p, "w", encoding="utf-8").write(t)
PYX
python3 "$BIN/print-como-retomar.py" "$F" > "$T/nuevo.txt"
printf 'El push funciono.\n\n%s\n' "$(cat "$T/nuevo.txt")" > "$T/resp-bien.txt"
tx2 "$T/t.jsonl" "$FX2/comando-resolve.txt" "$T/resp-bien.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== control: se resuelve un pendiente que el snippet NO cita =="
viejo
printf 'python3 bin/journal-emit.py --type pendiente.resolve --id p-0000000001 --estado resolved\n' > "$T/cmd-otro.txt"
tx2 "$T/t.jsonl" "$T/cmd-otro.txt" "$FX2/respuesta-tras-el-push.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== control: un pendiente.update (no cambia si esta abierto) sobre un id citado no dispara =="
printf 'python3 bin/journal-emit.py --type pendiente.update --id p-6071ea6987 --prioridad Alta\n' > "$T/cmd-upd.txt"
printf 'Listo.\n' > "$T/listo.txt"; tx2 "$T/t.jsonl" "$T/cmd-upd.txt" "$T/listo.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== adversarial: pendiente.block de un id citado, con --id entre comillas =="
viejo
printf "python3 bin/journal-emit.py --type pendiente.block --id 'p-6071ea6987' --bloqueado-por 'x'\n" > "$T/cmd-blk.txt"
tx2 "$T/t.jsonl" "$T/cmd-blk.txt" "$T/listo.txt"
chk "dispara y exige el snippet en la respuesta" "1" "$(corre "$T/t.jsonl" false - | grep -c 'no esta en tu respuesta')"

echo "== ronda de 2.33.1: --id=p-… (argparse lo acepta) tambien dispara =="
viejo
printf 'python3 bin/journal-emit.py --type pendiente.resolve --id=p-477bb60303 --estado resolved\n' > "$T/cmd-eq.txt"
tx2 "$T/t.jsonl" "$T/cmd-eq.txt" "$FX2/respuesta-tras-el-push.txt"
chk "bloquea" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== ronda de 2.33.1: el id en una variable tambien dispara =="
printf 'ID=p-477bb60303\npython3 bin/journal-emit.py --type pendiente.resolve --id "$ID" --estado resolved\n' > "$T/cmd-var.txt"
tx2 "$T/t.jsonl" "$T/cmd-var.txt" "$FX2/respuesta-tras-el-push.txt"
chk "bloquea" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== ronda de 2.33.1: una ficha VIEJA solo impresa (triage) no cuenta como de esta sesion =="
# La ficha de la sesion vieja cita p-6071ea6987 en `Sigue abierto`; esta sesion solo la imprime y
# luego resuelve ese pendiente. No debe exigir re-pegar el snippet de una sesion cerrada.
viejo
python3 - "$T/t.jsonl" "$F" "$T/listo.txt" <<'PYT'
import json, sys
out, ficha, txt = sys.argv[1:4]
cmd = "python3 bin/journal-emit.py --type pendiente.resolve --id p-6071ea6987 --estado resolved"
R = [{"type": "user", "message": {"role": "user", "content": "haz triage"}},
     {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "p", "name": "Bash",
        "input": {"command": f'python3 x/print-como-retomar.py "{ficha}"'}}]}},
     {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "p", "content": "x"}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": "leida"}]}},
     {"type": "user", "message": {"role": "user", "content": "cierra ese pendiente"}},
     {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "r", "name": "Bash", "input": {"command": cmd}}]}},
     {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "r", "content": "ok"}]}},
     {"type": "assistant", "message": {"content": [{"type": "text", "text": open(txt, encoding="utf-8").read()}]}}]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYT
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"
echo "== ...pero si esa ficha impresa lleva el session_id de ESTA sesion, si cuenta =="
python3 - "$F" <<'PYX'
import sys; p=sys.argv[1]; t=open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("date: 2026-09-22\n", "date: 2026-09-22\nsession_id: sesion-actual\n", 1))
PYX
O=$(python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"stop_hook_active":False,"session_id":"sesion-actual","cwd":"/tmp"}))' "$T/t.jsonl" | bash "$HOOK" 2>/dev/null)
chk "bloquea" "1" "$(bloquea "$O")"

# ================================================================================================
# 2.36.0 — p-2dc733a7c3: `expire-pendientes.py --apply` caduca un id que el snippet cita. El script
# llama a journal-emit.py POR DENTRO, asi que el texto del comando no trae ni `journal-emit.py` ni el
# id y el disparo por cambio de estado de 2.33.1 no lo veia. Aqui el script corre DE VERDAD sobre la
# memoria del test y su salida real va al tool_result: nada de ids escritos a mano.
echo "== 2.36.0 (p-2dc733a7c3): expire-pendientes.py --apply caduca un id citado en la ficha =="
vence() {   # $1.. ids que reciben `_revisar:` vencido (candidatos de --modo revisar)
  python3 - "$M/_pendientes.md" "$@" <<'PYV'
import sys, re
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
for i in sys.argv[2:]:
    t, n = re.subn(rf"(_id: {i}_)", r"\1 — _revisar: 2026-01-01_", t)
    assert n == 1, i
open(p, "w", encoding="utf-8").write(t)
PYV
}
EXP="python3 \"\$JBIN/expire-pendientes.py\" --apply"
printf '%s\n' "$EXP" > "$T/cmd-exp.txt"
viejo; vence p-6071ea6987
python3 "$BIN/expire-pendientes.py" --memory-dir "$M" --apply > "$T/exp-out.txt"
chk "el script caduco el id citado (evento en el journal)" "1" "$(grep -l 'p-6071ea6987' "$M"/.journal/pending/* 2>/dev/null | wc -l | tr -d ' ')"
tx2 "$T/t.jsonl" "$T/cmd-exp.txt" "$T/listo.txt" "$T/exp-out.txt"
O=$(corre "$T/t.jsonl" false -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "pide el snippet nuevo" "1" "$(printf '%s' "$O" | grep -c 'no esta en tu respuesta')"
chk "con la salida en bloques text tambien" "1" "$(tx2 "$T/t.jsonl" "$T/cmd-exp.txt" "$T/listo.txt" "bloques:$T/exp-out.txt"; bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== control: expire-pendientes.py --apply caduca un id que la ficha NO cita =="
viejo; vence p-014255373e
python3 "$BIN/expire-pendientes.py" --memory-dir "$M" --apply > "$T/exp-out.txt"
tx2 "$T/t.jsonl" "$T/cmd-exp.txt" "$T/listo.txt" "$T/exp-out.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== control: dry-run (sin --apply) sobre un id citado no dispara =="
viejo; vence p-6071ea6987
python3 "$BIN/expire-pendientes.py" --memory-dir "$M" > "$T/exp-out.txt"
printf 'python3 "$JBIN/expire-pendientes.py"\n' > "$T/cmd-dry.txt"
tx2 "$T/t.jsonl" "$T/cmd-dry.txt" "$T/listo.txt" "$T/exp-out.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== control: --revertir --apply (reabre, no cierra) no dispara =="
printf 'python3 "$JBIN/expire-pendientes.py" --revertir p-6071ea6987 --apply\n' > "$T/cmd-rev.txt"
printf 'REOPEN emitido para p-6071ea6987. Corre journal-compact.py para aplicarlo.\n' > "$T/rev-out.txt"
tx2 "$T/t.jsonl" "$T/cmd-rev.txt" "$T/listo.txt" "$T/rev-out.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== adversarial: la salida de --apply se corta (| tail -1, > /dev/null): dispara igual =="
viejo; vence p-014255373e
printf 'python3 "$JBIN/expire-pendientes.py" --apply > /dev/null\n' > "$T/cmd-null.txt"
: > "$T/vacio.txt"
tx2 "$T/t.jsonl" "$T/cmd-null.txt" "$T/listo.txt" "$T/vacio.txt"
chk "bloquea sin ids legibles (un aviso de mas, nunca uno de menos)" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== adversario de 2.36.0: un bucle corre --apply sobre DOS memorias; el id citado sale en la segunda =="
# Una sola invocacion en el texto, dos lineas `EXPIRE ids:` en la salida. Leer solo la primera
# dejaba fuera el id citado y el respaldo a ciegas no entraba (habia una linea).
viejo; vence p-6071ea6987
M2="$T/memory-otra"; mkdir -p "$M2/pendientes"
printf '# Pendientes\n\n## Media prioridad\n\n- [ ] otro — _origen: [[sessions/x]]_ — _creado: 2026-09-01_ — _id: p-0123456789_ — _revisar: 2026-01-01_\n' > "$M2/_pendientes.md"
for d in "$M2" "$M"; do python3 "$BIN/expire-pendientes.py" --memory-dir "$d" --apply; done > "$T/exp-out.txt"
chk "la salida trae dos lineas EXPIRE ids" "2" "$(grep -c '^EXPIRE ids:' "$T/exp-out.txt")"
printf 'for d in "$A" "$B"; do python3 "$JBIN/expire-pendientes.py" --memory-dir "$d" --apply; done\n' > "$T/cmd-loop.txt"
tx2 "$T/t.jsonl" "$T/cmd-loop.txt" "$T/listo.txt" "$T/exp-out.txt"
chk "bloquea" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== adversario de 2.36.0: --apply cortado y --revertir en el MISMO comando: el --revertir no tapa al --apply =="
viejo; vence p-6071ea6987
printf 'python3 "$JBIN/expire-pendientes.py" --apply > /dev/null; python3 "$JBIN/expire-pendientes.py" --revertir p-0000000001 --apply\n' > "$T/cmd-mix.txt"
printf 'REOPEN emitido para p-0000000001. Corre journal-compact.py para aplicarlo.\n' > "$T/mix-out.txt"
tx2 "$T/t.jsonl" "$T/cmd-mix.txt" "$T/listo.txt" "$T/mix-out.txt"
chk "bloquea" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== adversario de 2.36.0 (ronda 2): --apply en una linea de continuacion con barra invertida =="
viejo; vence p-6071ea6987
printf 'python3 "$JBIN/expire-pendientes.py" \\\n  --memory-dir memory \\\n  --apply > /dev/null\n' > "$T/cmd-cont.txt"
chk "el comando del caso lleva la barra y el salto" "2" "$(grep -c '\\$' "$T/cmd-cont.txt")"
tx2 "$T/t.jsonl" "$T/cmd-cont.txt" "$T/listo.txt" "$T/vacio.txt"
chk "bloquea" "1" "$(bloquea "$(corre "$T/t.jsonl" false -)")"

echo "== control: dos --apply en un comando, las dos lineas legibles y ninguna con un id citado =="
viejo; vence p-014255373e
for d in "$M2" "$M"; do python3 "$BIN/expire-pendientes.py" --memory-dir "$d" --apply; done > "$T/exp-out.txt"
tx2 "$T/t.jsonl" "$T/cmd-loop.txt" "$T/listo.txt" "$T/exp-out.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

# ================================================================================================
# 2.34.0 — p-272254efc5: `ninguno` con el ultimo veredicto del adversario en `break`. La ficha es el
# caso 5 colapsado; el veredicto va en un turno VIEJO (antes del cierre), como en 5790b9f2/3d0f8bc1.
# $1 = texto del bloque viejo del assistant ("-" = nada), $2 = donde va (text|tool_result),
# $3 = fichero de last_assistant_message ("-" = nada).
veredicto() {
  armar "$M" -
  python3 "$BIN/print-como-retomar.py" "$F" > "$T/v-salida.txt" 2>/dev/null || true
  printf 'Resumen.\n\n%s\n' "$(cat "$T/v-salida.txt")" > "$T/v-bien.txt"
  tx "$T/t.jsonl" skill "$F" "$T/v-bien.txt" "$T/v-salida.txt"
  python3 - "$T/t.jsonl" "$1" "$2" <<'PYV'
import json, sys
out, viejo, donde = sys.argv[1:4]
R = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
if viejo != "-":
    if donde == "text":
        extra = [{"type": "assistant", "message": {"content": [{"type": "text", "text": viejo}]}}]
    else:
        extra = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "adv", "name": "Bash", "input": {"command": "external-adversary.sh"}}]}},
                 {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "adv", "content": viejo}]}}]
    R = R[:2] + extra + R[2:]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYV
  corre "$T/t.jsonl" false "$3"
}
BRK='[ADVERSARY-VERDICT: break ungrounded=1 unfalsified=0 incomplete=1 autonomy-violations=0 unsafe=0]'
HLD='[ADVERSARY-VERDICT: hold ungrounded=0 unfalsified=0 incomplete=0 autonomy-violations=0 unsafe=0]'
echo "== control: caso 5 sin veredicto: silencio =="
chk "silencio" "" "$(veredicto - text -)"
echo "== break sin cerrar + ninguno: bloquea =="
O=$(veredicto "Ronda 2:
$BRK" text -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "por el veredicto" "1" "$(printf '%s' "$O" | grep -c 'ultimo veredicto del adversario es `break`')"
echo "== break y despues hold: silencio =="
chk "silencio" "" "$(veredicto "$BRK
arreglado.
$HLD" text -)"
echo "== break y despues GOAL-CLOSE-WAIVED: silencio =="
chk "silencio" "" "$(veredicto "$BRK
[GOAL-CLOSE-WAIVED reason=residuo del sandbox del verificador, no del producto]" text -)"
# 2.42.0: hasta 2.41 este caso callaba ("aun no lo cito el agente"). Medido el 2026-09-30: el agente
# nunca lo cito, el veredicto solo estaba en el tool_result y la ficha cerro sin el defecto.
echo "== 2.42.0: el break solo en un tool_result (el agente nunca lo cito): bloquea =="
chk "bloquea" "1" "$(bloquea "$(veredicto "$BRK" tool_result -)")"
echo "== 2.42.0: la PLANTILLA del veredicto en un tool_result (break|hold ...) no es un break: silencio =="
chk "silencio" "" "$(veredicto "Imprime al final:
[ADVERSARY-VERDICT: break|hold ungrounded=<n> unfalsified=<n> incomplete=<n> autonomy-violations=<n> unsafe=<n>]
[ADVERSARY-VERDICT: ...] lines VERBATIM" tool_result -)"
echo "== 2.42.0: break en un tool_result y despues hold en otro: silencio =="
chk "silencio" "" "$(veredicto "$BRK
arreglado, segunda ronda:
$HLD" tool_result -)"
echo "== adversarial: break citado a mitad de linea (no es el marcador): silencio =="
chk "silencio" "" "$(veredicto "la ronda 1 fue $BRK y la arregle" text -)"
echo "== ronda 1 del adversario: break citado como ejemplo dentro de un fence: silencio =="
chk "silencio" "" "$(veredicto "Formato de ejemplo:

\`\`\`
$BRK
\`\`\`

Eso fue solo un ejemplo." text -)"
echo "== ...pero un break real DESPUES del fence si cuenta: bloquea =="
chk "bloquea" "1" "$(bloquea "$(veredicto "\`\`\`
$HLD
\`\`\`
$BRK" text -)")"
echo "== adversarial: hold viejo y break solo en last_assistant_message: bloquea =="
printf 'Resumen.\n\n%s\n\n%s\n' "$(cat "$T/v-salida.txt" 2>/dev/null)" "$BRK" > "$T/v-lam.txt"
chk "bloquea" "1" "$(bloquea "$(veredicto "$HLD" text "$T/v-lam.txt")")"
echo "== break registrado: Bugs fixed cita un _pendiente: abierto (aunque bloqueado): silencio =="
armar "$M" -
python3 - "$F" <<'PYB'
import sys; p=sys.argv[1]; t=open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("## Plans\n", "## Bugs fixed\n- lo que rompio el adversario _pendiente: p-a4439fa8fd_\n\n## Plans\n", 1))
PYB
python3 "$BIN/print-como-retomar.py" "$F" > "$T/v-salida.txt" 2>/dev/null || true
printf 'Resumen.\n\n%s\n' "$(cat "$T/v-salida.txt")" > "$T/v-bien.txt"
tx "$T/t.jsonl" skill "$F" "$T/v-bien.txt" "$T/v-salida.txt"
python3 - "$T/t.jsonl" "$BRK" <<'PYV'
import json, sys
out, brk = sys.argv[1:3]
R = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
R = R[:2] + [{"type": "assistant", "message": {"content": [{"type": "text", "text": brk}]}}] + R[2:]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYV
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

# ================================================================================================
# 2.35.0 — Step 8e: en una ficha desde el 2026-09-23 el hook exige tambien el bloque de pendiente que
# print-pendiente-opcional.py imprime EN VIVO desde _pendientes.md. Desde 2.44.0 el candidato vence
# HOY: con el snippet completo de la ficha, un Alta suelto ya no sale (solo en el caso 5).
HOY=$(python3 -c 'import datetime; print(datetime.date.today().isoformat())')
opcional() {   # arma la ficha 2120 con fecha 2026-09-23 y un Alta candidato
  armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"
  sed -i.bak 's/^date: 2026-09-22$/date: 2026-09-23/' "$F" && rm -f "$F.bak"
  python3 - "$M/_pendientes.md" "$HOY" <<'PYO'
import sys; p=sys.argv[1]; t=open(p, encoding="utf-8").read()
t=t.replace("## Alta prioridad\n\n","## Alta prioridad\n\n- [ ] alta candidata del prompt opcional — _creado: 2026-09-23_ — _revisar: " + sys.argv[2] + "_ — _id: p-0a0a0a0a0a_\n",1)
open(p, "w", encoding="utf-8").write(t)
PYO
  python3 "$BIN/print-como-retomar.py" "$F" > "$T/o-snip.txt"
  python3 "$BIN/print-pendiente-opcional.py" "$F" > "$T/o-opc.txt"
}
echo "== 2.35.0: cierre sin el prompt opcional: bloquea =="
opcional
chk "el script propone la candidata" "1" "$(grep -c 'p-0a0a0a0a0a' "$T/o-opc.txt")"
printf 'Resumen.\n\n%s\n\n%s\n' "$(cat "$T/o-snip.txt")" "$(cat "$FX/calendario-2129.txt")" > "$T/o-sin.txt"
tx "$T/t.jsonl" skill "$F" "$T/o-sin.txt" -
O=$(corre "$T/t.jsonl" false -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "por el bloque de pendiente" "1" "$(printf '%s' "$O" | grep -c 'bloque de pendiente (Step 8e)')"
echo "== 2.35.0: con el prompt opcional pegado: silencio =="
printf 'Resumen.\n\n%s\n\n%s\n\n%s\n' "$(cat "$T/o-snip.txt")" "$(cat "$FX/calendario-2129.txt")" "$(cat "$T/o-opc.txt")" > "$T/o-con.txt"
tx "$T/t.jsonl" skill "$F" "$T/o-con.txt" -
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"
echo "== 2.35.0: la misma ficha con fecha 2026-09-22 (antes del corte) no lo exige =="
sed -i.bak 's/^date: 2026-09-23$/date: 2026-09-22/' "$F" && rm -f "$F.bak"
tx "$T/t.jsonl" skill "$F" "$T/o-sin.txt" -
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== transcript ilegible o ausente: silencio (falla abierto) =="
chk "sin transcript" "" "$(printf '{"stop_hook_active":false}' | bash "$HOOK" 2>/dev/null)"
chk "stdin basura" "" "$(printf 'no-json' | bash "$HOOK" 2>/dev/null)"

echo "== Step 7a (2.40.0): la salida del audit tiene que estar en la respuesta del turno del checkpoint =="
# Antes lo vigilaba checkpoint-audit-nudge.sh en el commit, que va ANTES del audit: avisaba en
# falso en casi todo checkpoint bien hecho (50 de 67 sesiones reales). Ahora lo mira este hook.
falta7a() { printf '%s' "$1" | grep -c 'La salida de Step 7a' || true; }
armar "$M" "$FX/snippet-1813.txt"
sed -i.bak 's/^date: 2026-09-22$/date: 2026-09-28/' "$F" && rm -f "$F.bak"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/snip.txt"
python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$F" --no-git > "$T/audit.txt" || true
SALT=$(grep -E '^  SALTADO' "$T/audit.txt" | grep -v ' snippet\.' | awk '{print $2}' | head -1)
chk "el fixture tiene al menos un SALTADO fuera del snippet (si no, el caso 3 no prueba nada)" "1" "$([ -n "$SALT" ] && echo 1 || echo 0)"
cat "$T/snip.txt" > "$T/r-sin.txt"
tx "$T/t.jsonl" skill "$F" "$T/r-sin.txt" -
chk "sin la salida del audit: lo reclama" "1" "$(falta7a "$(corre "$T/t.jsonl" false -)")"
cat "$T/snip.txt" "$T/audit.txt" > "$T/r-con.txt"
tx "$T/t.jsonl" skill "$F" "$T/r-con.txt" -
chk "con la salida literal del audit: calla" "0" "$(falta7a "$(corre "$T/t.jsonl" false -)")"
{ cat "$T/snip.txt"; grep 'resumen:' "$T/audit.txt"; } > "$T/r-solo-resumen.txt"
tx "$T/t.jsonl" skill "$F" "$T/r-solo-resumen.txt" -
O=$(corre "$T/t.jsonl" false -)
chk "solo la linea resumen, callando un SALTADO: lo reclama" "1" "$(falta7a "$O")"
chk "  y nombra la clave del SALTADO" "1" "$(printf '%s' "$O" | grep -c "$SALT")"
# La salida solo en el tool_result (el usuario no la ve) no cuenta.
python3 - "$T/t.jsonl" "$T/audit.txt" <<'PY'
import json, sys
t, audit = sys.argv[1], open(sys.argv[2], encoding="utf-8").read()
recs = [json.loads(l) for l in open(t, encoding="utf-8")]
recs.insert(len(recs) - 1, {"type": "assistant", "message": {"role": "assistant", "content": [
    {"type": "tool_use", "id": "t9", "name": "Bash", "input": {"command": "python3 checkpoint-audit.py memory"}}]}})
recs.insert(len(recs) - 1, {"type": "user", "message": {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": "t9", "content": audit}]}})
recs[-1]["message"]["content"] = [{"type": "text", "text": open(sys.argv[1].replace("t.jsonl", "snip.txt"), encoding="utf-8").read()}]
open(t, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in recs) + "\n")
PY
chk "la salida solo en un tool_result no cuenta" "1" "$(falta7a "$(corre "$T/t.jsonl" false -)")"
# Adversario de 2.41.0: un resumen inventado con saltado=0 y las claves citadas en prosa callaba.
{ cat "$T/snip.txt"; echo "resumen: hecho=999 parcial=0 saltado=0 por-diseno=0"; echo "Nota: revise $(grep -E '^  SALTADO' "$T/audit.txt" | grep -v ' snippet\.' | awk '{print $2}' | tr '\n' ' ')"; } > "$T/r-falso.txt"
tx "$T/t.jsonl" skill "$F" "$T/r-falso.txt" -
chk "resumen inventado con saltado=0 y claves en prosa: lo reclama" "1" "$(falta7a "$(corre "$T/t.jsonl" false -)")"
{ cat "$T/snip.txt"; echo '```'; cat "$T/audit.txt"; echo '```'; } > "$T/r-fence.txt"
tx "$T/t.jsonl" skill "$F" "$T/r-fence.txt" -
chk "la salida real dentro de un fence (la forma normal de pegarla): calla" "0" "$(falta7a "$(corre "$T/t.jsonl" false -)")"
tx "$T/t.jsonl" print "$F" "$T/r-sin.txt" -
chk "un turno que solo reimprime el snippet no lo exige" "0" "$(falta7a "$(corre "$T/t.jsonl" false -)")"
sed -i.bak 's/^date: 2026-09-28$/date: 2026-09-22/' "$F" && rm -f "$F.bak"
tx "$T/t.jsonl" skill "$F" "$T/r-sin.txt" -
chk "una ficha anterior al corte no lo exige" "0" "$(falta7a "$(corre "$T/t.jsonl" false -)")"

echo

# ================================================================================================
# 2.42.0 — la revision cerrada del cierre, el `break` con cualquier snippet, y los commits de la sesion.
# Medido en 66 cierres tras los que el usuario pregunto "¿falto algo?": en 62 el mismo agente
# encontro omisiones reales en cuanto se le pregunto. Este hook hace la pregunta, una vez. Las fichas
# de estos casos llevan fecha 2026-09-30 (el corte); las de arriba, 2026-09-22, no la reciben.
fecha30() { python3 -c 'import sys;p=sys.argv[1];t=open(p,encoding="utf-8").read();open(p,"w",encoding="utf-8").write(t.replace("date: 2026-09-22","date: 2026-09-30",1))' "$1"; }
corre_en() {   # $1 transcript, $2 reentrante, $3 fichero de last_assistant_message ("-"), $4 cwd
  local LAM=""; [ "$3" != "-" ] && LAM="$(cat "$3")"
  python3 -c 'import json,sys; print(json.dumps({"transcript_path":sys.argv[1],"stop_hook_active":sys.argv[2]=="true","last_assistant_message":sys.argv[3],"cwd":sys.argv[4]}))' "$1" "$2" "$LAM" "$4" \
    | bash "$HOOK" 2>/dev/null
}
razon() { printf '%s' "$1" | python3 -c 'import json,sys;d=sys.stdin.read();j=json.loads(d) if d.strip() else {};print(j.get("reason") or j.get("systemMessage") or "")'; }
REV_OK='REVISION DEL CIERRE:
1. ninguno
2. ninguno
3. ninguno
4. ninguno
5. ninguno
6. ninguno
7. ninguno
8. ninguno
9. ninguno'

echo "== 2.42.0: checkpoint del 30 sin nada mas que reclamar: bloquea UNA vez con la revision cerrada =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"; fecha30 "$F"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf 'Resumen.\n\n%s\n\n%s\n' "$(cat "$T/salida-script.txt")" "$(cat "$FX/calendario-2129.txt")" > "$T/r30.txt"
tx "$T/t.jsonl" skill "$F" "$T/r30.txt" "$T/salida-script.txt"
O=$(corre "$T/t.jsonl" false -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "con la cabecera de la revision" "1" "$(razon "$O" | grep -c '^REVISION DEL CIERRE:$')"
chk "con sus 9 lineas numeradas" "9" "$(razon "$O" | grep -cE '^[1-9]\. ')"
chk "dice que ninguno vale" "1" "$(razon "$O" | grep -c 'no inventes para llenar')"
chk "trae la lista de lo que no cuenta" "1" "$(razon "$O" | grep -c 'No cuenta como falta')"
echo "== 2.42.0: la vuelta siguiente (stop_hook_active) sin el bloque contestado: avisa al usuario, no bloquea =="
O=$(corre "$T/t.jsonl" true -)
chk "no bloquea" "0" "$(bloquea "$O")"
chk "avisa que no contesto la revision" "1" "$(razon "$O" | grep -c 'No contestaste la revision del cierre')"
echo "== 2.42.0: la vuelta siguiente con el bloque completo: no reclama la revision =="
printf '%s\n' "$REV_OK" > "$T/rev.txt"
O=$(corre "$T/t.jsonl" true "$T/rev.txt")
chk "no reclama la revision" "0" "$(razon "$O" | grep -c 'No contestaste la revision')"
echo "== 2.42.0: bloque con una linea de menos (sin la 9): la reclama =="
printf '%s\n' "$REV_OK" | sed '$d' > "$T/rev8.txt"
chk "la reclama" "1" "$(razon "$(corre "$T/t.jsonl" true "$T/rev8.txt")" | grep -c 'No contestaste la revision')"
echo "== 2.42.0: un turno que solo reimprime el snippet (no es /checkpoint-3t): sin revision =="
tx "$T/t.jsonl" print "$F" "$T/r30.txt" "$T/salida-script.txt"
chk "sin revision" "0" "$(razon "$(corre "$T/t.jsonl" false -)" | grep -c 'REVISION DEL CIERRE')"
echo "== 2.42.0: ficha anterior al corte (22): sin revision =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf 'Resumen.\n\n%s\n\n%s\n' "$(cat "$T/salida-script.txt")" "$(cat "$FX/calendario-2129.txt")" > "$T/r22.txt"
tx "$T/t.jsonl" skill "$F" "$T/r22.txt" "$T/salida-script.txt"
chk "silencio" "" "$(corre "$T/t.jsonl" false -)"

echo "== 2.42.0: break en un tool_result + Proximo paso REAL + Bugs fixed sin nombrarlo: lo reclama =="
armar "$M" "$FX/snippet-2120.txt"; fecha30 "$F"
python3 - "$F" <<'PYB'
import sys; p=sys.argv[1]; t=open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("## Plans\n", "## Bugs fixed\n- tres casos sin arnes _verificado: mutation-check verde_\n\n## Plans\n", 1))
PYB
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf 'Resumen.\n\n%s\n' "$(cat "$T/salida-script.txt")" > "$T/rb.txt"
tx "$T/t.jsonl" skill "$F" "$T/rb.txt" "$T/salida-script.txt"
python3 - "$T/t.jsonl" "$BRK" <<'PYV'
import json, sys
out, brk = sys.argv[1:3]
R = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
extra = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "adv", "name": "Agent", "input": {"subagent_type": "goalspec:goal-adversary"}}]}},
         {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "adv", "content": [{"type": "text", "text": "- autonomy: pregunto en prosa\n" + brk}]}]}}]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R[:2] + extra + R[2:]) + "\n")
PYV
O=$(corre "$T/t.jsonl" false -)
chk "lo reclama por bugs.veredicto_break" "1" "$(razon "$O" | grep -c 'bugs.veredicto_break')"
chk "no por el snippet ninguno (el snippet es real)" "0" "$(razon "$O" | grep -c 'snippet.ninguno_defecto')"
python3 - "$F" <<'PYB'
import sys; p=sys.argv[1]; t=open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("## Bugs fixed\n", "## Bugs fixed\n- pregunte el push en prosa: lo marco el adversario _verificado: se pregunto con AskUserQuestion_\n", 1))
PYB
chk "con el hallazgo nombrado en Bugs fixed: ya no" "0" "$(razon "$(corre "$T/t.jsonl" false -)" | grep -c 'bugs.veredicto_break')"

echo "== 2.42.0: commits de la sesion que la ficha no nombra =="
G="$T/git"; mkdir -p "$G"; git -C "$G" init -q; git -C "$G" config user.email t@t; git -C "$G" config user.name t
echo a > "$G/a"; git -C "$G" add a; git -C "$G" commit -qm "feat: la funcion nueva"
HA=$(git -C "$G" rev-parse --short=7 HEAD)
echo b > "$G/b"; git -C "$G" add b; git -C "$G" commit -qm "checkpoint: 2026-09-30-demo — resumen"
HC=$(git -C "$G" rev-parse --short=7 HEAD)
armar "$M" "$FX/snippet-2120.txt"; fecha30 "$F"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf 'Resumen.\n\n%s\n' "$(cat "$T/salida-script.txt")" > "$T/rc.txt"
tx "$T/t.jsonl" skill "$F" "$T/rc.txt" "$T/salida-script.txt"
# Commits del turno anterior al checkpoint: uno real ($HA), uno reescrito que ya no esta en HEAD
# (deadbee), y el commit de memoria de Step 6 ($HC, referencia adelantada por diseno).
python3 - "$T/t.jsonl" "$HA" "$HC" <<'PYC'
import json, sys
out, ha, hc = sys.argv[1:4]
R = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
def par(i, cmd, res):
    return [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": i, "name": "Bash", "input": {"command": cmd}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": i, "content": res}]}}]
antes = par("c1", 'git add a && git commit -m "feat: la funcion nueva"', f"[main {ha}] feat: la funcion nueva\n 1 file changed") \
      + par("c2", 'git commit --amend -m "viejo"', "[main deadbee] viejo reescrito")
despues = par("c3", 'git add memory/ && git commit -m "memoria: cierre de la sesion"', f"[main {hc}] memoria: cierre de la sesion")
R = R[:2] + antes + R[2:-1] + despues + R[-1:]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYC
O=$(corre_en "$T/t.jsonl" false - "$G")
chk "nombra el commit que falta" "1" "$(razon "$O" | grep -c "$HA")"
chk "no el commit de memoria de Step 6 (posterior a la invocacion, con otro mensaje)" "0" "$(razon "$O" | grep -c "$HC")"
chk "no el que ya no esta en HEAD" "0" "$(razon "$O" | grep -c 'deadbee')"
python3 - "$F" "$HA" <<'PYB'
import sys; p, h = sys.argv[1:3]; t=open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("## Plans\n", f"## Commits\n- `{h}` la funcion nueva\n\n## Plans\n", 1))
PYB
chk "con el hash en la ficha: ya no lo reclama" "0" "$(razon "$(corre_en "$T/t.jsonl" false - "$G")" | grep -c 'commit(s) de esta sesion')"
echo "== 2.42.0: un commit ANTERIOR al checkpoint previo de la sesion es de la ficha previa: no lo exige =="
python3 - "$T/t.jsonl" <<'PYP'
import json, sys
out = sys.argv[1]
R = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
prev = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "ck0", "name": "Skill", "input": {"skill": "checkpoint-3t"}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "ck0", "content": "Launching skill: checkpoint-3t"}]}}]
# el checkpoint previo va DESPUES de los commits c1/c2 y ANTES del turno actual
i = next(k for k, r in enumerate(R) if r.get("type") == "user" and r["message"]["content"] == "guarda el checkpoint")
R = R[:i] + prev + R[i:]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYP
python3 - "$F" "$HA" <<'PYB'
import sys; p, h = sys.argv[1:3]; t=open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace(f"- `{h}` la funcion nueva\n", "- nada\n", 1))
PYB
chk "no lo exige" "0" "$(razon "$(corre_en "$T/t.jsonl" false - "$G")" | grep -c 'commit(s) de esta sesion')"


echo "== ronda 1 de 2.42.0: la etiqueta con espacio de nombres (/<x>:checkpoint-3t) tambien es un checkpoint =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"; fecha30 "$F"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf 'Resumen.\n\n%s\n\n%s\n' "$(cat "$T/salida-script.txt")" "$(cat "$FX/calendario-2129.txt")" > "$T/r30.txt"
tx "$T/t.jsonl" print "$F" "$T/r30.txt" "$T/salida-script.txt"
python3 - "$T/t.jsonl" <<'PYN'
import json, sys
out = sys.argv[1]
R = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
i = next(k for k, r in enumerate(R) if r.get("type") == "user" and r["message"]["content"] == "guarda el checkpoint")
R[i]["message"]["content"] = "<command-message>checkpoint-3t</command-message>\n<command-name>/3-tier-memory:checkpoint-3t</command-name>"
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYN
chk "pide la revision" "1" "$(razon "$(corre "$T/t.jsonl" false -)" | grep -c '^REVISION DEL CIERRE:$')"
echo "== ronda 1 de 2.42.0: pegar las 9 lineas del propio aviso (solo etiquetas) no contesta la revision =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"; fecha30 "$F"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
tx "$T/t.jsonl" skill "$F" "$T/r30.txt" "$T/salida-script.txt"
razon "$(corre "$T/t.jsonl" false -)" | sed -n '/^REVISION DEL CIERRE:$/,/^9\./p' > "$T/eco.txt"
chk "el eco trae las 9 lineas" "9" "$(grep -cE '^[1-9]\. ' "$T/eco.txt")"
chk "la reclama" "1" "$(razon "$(corre "$T/t.jsonl" true "$T/eco.txt")" | grep -c 'No contestaste la revision')"
sed 's/:$/: ninguno/' "$T/eco.txt" > "$T/eco-ninguno.txt"
chk "etiqueta + ninguno si cuenta" "0" "$(razon "$(corre "$T/t.jsonl" true "$T/eco-ninguno.txt")" | grep -c 'No contestaste la revision')"
echo "== ronda 1 de 2.42.0: un break DENTRO de un fence en un tool_result es un ejemplo, no el veredicto =="
armar "$M" "$FX/snippet-2120.txt"; fecha30 "$F"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf 'Resumen.\n\n%s\n' "$(cat "$T/salida-script.txt")" > "$T/rb.txt"
tx "$T/t.jsonl" skill "$F" "$T/rb.txt" "$T/salida-script.txt"
python3 - "$T/t.jsonl" "$BRK" <<'PYF'
import json, sys
out, brk = sys.argv[1:3]
R = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
extra = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "cat", "name": "Bash", "input": {"command": "cat README.md"}}]}},
         {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "cat", "content": "Ejemplo:\n```\n" + brk + "\n```\n"}]}}]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R[:2] + extra + R[2:]) + "\n")
PYF
chk "no lo cuenta" "0" "$(razon "$(corre "$T/t.jsonl" false -)" | grep -c 'bugs.veredicto_break')"


echo "== ronda 2 de 2.42.0: comando tecleado (etiqueta) + llamada Skill en el mismo turno: el commit de antes SI se exige =="
armar "$M" "$FX/snippet-2120.txt"; fecha30 "$F"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
printf 'Resumen.\n\n%s\n' "$(cat "$T/salida-script.txt")" > "$T/rc.txt"
tx "$T/t.jsonl" skill "$F" "$T/rc.txt" "$T/salida-script.txt"
python3 - "$T/t.jsonl" "$HA" <<'PYD'
import json, sys
out, ha = sys.argv[1:3]
R = [json.loads(l) for l in open(out, encoding="utf-8") if l.strip()]
commit = [{"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "c1", "name": "Bash", "input": {"command": 'git commit -m "feat: la funcion nueva"'}}]}},
          {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "c1", "content": f"[main {ha}] feat: la funcion nueva"}]}}]
i = next(k for k, r in enumerate(R) if r.get("type") == "user" and r["message"]["content"] == "guarda el checkpoint")
R[i]["message"]["content"] = "<command-message>checkpoint-3t</command-message>\n<command-name>/checkpoint-3t</command-name>"
R = R[:i] + commit + R[i:]
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r) for r in R) + "\n")
PYD
chk "lo exige" "1" "$(razon "$(corre_en "$T/t.jsonl" false - "$G")" | grep -c "$HA")"

# 2.43.0: el cierre (snippet, calendario, 8d, 8e) va AL FINAL, despues de la revision. El cierre
# reentrante real trae el aviso del hook como un registro `user` con isMeta (medido en los
# transcripts reales): `vuelta` lo reproduce tal cual y anade la respuesta del agente.
vuelta() {   # $1 transcript base, $2 salida, $3 fichero con el texto de la respuesta a la revision
  python3 - "$1" "$2" "$3" <<'PYV'
import json, sys
base, out, resp = sys.argv[1:4]
R = [json.loads(l) for l in open(base, encoding="utf-8") if l.strip()]
R.append({"type": "user", "isMeta": True, "message": {"role": "user", "content": "Stop hook feedback:\nRevision del cierre de /checkpoint-3t (checkpoint-close-guard.sh). ..."}})
R.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": open(resp, encoding="utf-8").read()}]}})
open(out, "w", encoding="utf-8").write("\n".join(json.dumps(r, ensure_ascii=False) for r in R) + "\n")
PYV
}
echo "== 2.43.0: primer cierre de /checkpoint-3t SIN el snippet pegado: no lo reclama, pide el cierre al final =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"; fecha30 "$F"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/salida-script.txt"
python3 "$BIN/print-pendiente-opcional.py" "$F" > "$T/salida-8e.txt"
printf 'Resumen del checkpoint.\n' > "$T/sin-cierre.txt"
tx "$T/t.jsonl" skill "$F" "$T/sin-cierre.txt" "$T/salida-script.txt"
cp "$T/t.jsonl" "$T/t-primero.jsonl"
O=$(corre "$T/t.jsonl" false -)
chk "bloquea (la revision)" "1" "$(bloquea "$O")"
chk "no reclama el snippet como falta" "0" "$(razon "$O" | grep -c 'snippet `Como retomar` no esta')"
chk "no reclama el recordatorio como falta" "0" "$(razon "$O" | grep -c 'esta en la ficha pero no en')"
chk "pide el cierre al final de la respuesta" "1" "$(razon "$O" | grep -c 'termina tu respuesta con el cierre')"
# Solo el nombre de la ficha, no la ruta entera: en Windows el hook la escribe normalizada
# (C:\...\2026-09-22-demo.md) y la prueba la tiene como /tmp/... (CI de f795efc, rojo solo en windows).
chk "con el comando y la ruta literal de la ficha" "1" "$(razon "$O" | grep -E 'print-como-retomar\.py" "[^"]*2026-09-22-demo\.md"' | wc -l | tr -d ' ')"
chk "y los recordatorios de la ficha" "1" "$(razon "$O" | grep -c 'print-recordatorios\.py')"
echo "== 2.43.0: vuelta con la revision y DESPUES el cierre completo: silencio sobre el cierre =="
{ printf '%s\n\n' "$REV_OK"; cat "$T/salida-script.txt"; printf '\n'; cat "$T/salida-8e.txt"; printf '\n'; cat "$FX/calendario-2129.txt"; } > "$T/rev-y-cierre.txt"
vuelta "$T/t-primero.jsonl" "$T/t.jsonl" "$T/rev-y-cierre.txt"
O=$(corre "$T/t.jsonl" true -)
chk "no bloquea" "0" "$(bloquea "$O")"
chk "no reclama nada del cierre" "0" "$(razon "$O" | grep -c 'despues de tu revision')"
chk "no anexa el cierre" "0" "$(razon "$O" | grep -c 'El cierre no quedo al final')"
echo "== 2.43.0: el snippet salio en el primer cierre y la vuelta solo trae la revision: enterrado =="
{ printf 'Resumen.\n\n'; cat "$T/salida-script.txt"; printf '\n'; cat "$FX/calendario-2129.txt"; printf '\n'; cat "$T/salida-8e.txt"; } > "$T/cierre-antes.txt"
tx "$T/t-antes.jsonl" skill "$F" "$T/cierre-antes.txt" "$T/salida-script.txt"
printf '%s\n' "$REV_OK" > "$T/solo-rev.txt"
vuelta "$T/t-antes.jsonl" "$T/t.jsonl" "$T/solo-rev.txt"
O=$(corre "$T/t.jsonl" true -)
chk "no bloquea (sin bucle)" "0" "$(bloquea "$O")"
chk "avisa que el snippet no esta despues de la revision" "1" "$(razon "$O" | grep -c 'snippet `Como retomar` no esta despues de tu revision')"
chk "y le ensena el cierre al usuario" "1" "$(razon "$O" | grep -c 'El cierre no quedo al final')"
chk "con la linea Proximo paso del snippet" "1" "$(razon "$O" | grep -cF "$(grep -m1 'Proximo paso' "$T/salida-script.txt")")"
echo "== 2.43.0: snippet ANTES de la revision en la misma respuesta: tambien enterrado =="
{ cat "$T/salida-script.txt"; printf '\n%s\n' "$REV_OK"; } > "$T/snip-luego-rev.txt"
vuelta "$T/t-primero.jsonl" "$T/t.jsonl" "$T/snip-luego-rev.txt"
chk "lo reclama" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'snippet `Como retomar` no esta despues de tu revision')"
echo "== 2.43.0 ronda 1: el cierre duplicado y seguido de mas texto: lo reclama =="
{ cat "$T/rev-y-cierre.txt"; printf '\n'; cat "$T/salida-script.txt"; printf '\n'; cat "$T/salida-8e.txt"; printf '\n'; cat "$FX/calendario-2129.txt"
  printf '\nNOT LAST: %s\n' "$(printf 'texto de relleno que empuja el cierre hacia arriba %.0s' 1 2 3 4 5 6 7 8)"; } > "$T/dup-cola.txt"
vuelta "$T/t-primero.jsonl" "$T/t.jsonl" "$T/dup-cola.txt"
O=$(corre "$T/t.jsonl" true -)
chk "no bloquea" "0" "$(bloquea "$O")"
chk "dice que no quedo como lo ultimo" "1" "$(razon "$O" | grep -c 'no quedo como lo ultimo y una sola vez')"
chk "nombra la repeticion" "1" "$(razon "$O" | grep -c 'el snippet sale 2 veces')"
chk "y le ensena el cierre al usuario" "1" "$(razon "$O" | grep -c 'El cierre no quedo al final')"
echo "== 2.43.0 ronda 1: texto largo DESPUES del cierre, sin repetir: lo reclama =="
{ cat "$T/rev-y-cierre.txt"; printf '\nNOT LAST: %s\n' "$(printf 'texto de relleno que empuja el cierre hacia arriba %.0s' 1 2 3 4 5 6 7 8)"; } > "$T/cola.txt"
vuelta "$T/t-primero.jsonl" "$T/t.jsonl" "$T/cola.txt"
chk "reclama la cola" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'despues del ultimo bloque siguen')"
echo "== 2.43.0 ronda 1: una linea corta despues del cierre es tolerada =="
{ cat "$T/rev-y-cierre.txt"; printf '\nListo.\n'; } > "$T/cola-corta.txt"
vuelta "$T/t-primero.jsonl" "$T/t.jsonl" "$T/cola-corta.txt"
chk "silencio sobre el cierre" "0" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'no quedo como lo ultimo')"
echo "== 2.43.0 ronda 1: el calendario ANTES del snippet: lo reclama por el orden =="
{ printf '%s\n\n' "$REV_OK"; cat "$FX/calendario-2129.txt"; printf '\n'; cat "$T/salida-script.txt"; printf '\n'; cat "$T/salida-8e.txt"; } > "$T/orden.txt"
vuelta "$T/t-primero.jsonl" "$T/t.jsonl" "$T/orden.txt"
chk "reclama el orden" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'no van en el orden')"
echo "== 2.43.0 ronda 1: con un prompt opcional (8e) de verdad: falta tras la revision -> lo reclama; presente -> silencio =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"; fecha30 "$F"
python3 - "$M/_pendientes.md" "$HOY" <<'PYA'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = t.replace("## Media prioridad", "- [ ] otro Alta suelto — _origen: [[sessions/2026-09-01-x]]_ — _creado: 2026-09-29_ — _revisar: " + sys.argv[2] + "_ — _id: p-0a1b2c3d4e_\n\n## Media prioridad", 1)
open(p, "w", encoding="utf-8").write(t)
PYA
python3 "$BIN/print-como-retomar.py" "$F" > "$T/s8b.txt"
python3 "$BIN/print-pendiente-opcional.py" "$F" > "$T/s8e.txt"
chk "el fixture trae un 8e con contenido" "1" "$(grep -c 'p-0a1b2c3d4e' "$T/s8e.txt")"
tx "$T/t8.jsonl" skill "$F" "$T/sin-cierre.txt" "$T/s8b.txt"
{ printf '%s\n\n' "$REV_OK"; cat "$T/s8b.txt"; printf '\n'; cat "$FX/calendario-2129.txt"; } > "$T/sin8e.txt"
vuelta "$T/t8.jsonl" "$T/t.jsonl" "$T/sin8e.txt"
O=$(corre "$T/t.jsonl" true -)
chk "sin 8e: lo reclama" "1" "$(razon "$O" | grep -c 'bloque de pendiente (Step 8e) no esta despues de tu revision')"
chk "y lo anexa" "1" "$(razon "$O" | grep -c 'p-0a1b2c3d4e')"
{ printf '%s\n\n' "$REV_OK"; cat "$T/s8b.txt"; printf '\n'; cat "$T/s8e.txt"; printf '\n'; cat "$FX/calendario-2129.txt"; } > "$T/con8e.txt"
vuelta "$T/t8.jsonl" "$T/t.jsonl" "$T/con8e.txt"
chk "con 8e al final: silencio sobre el cierre" "0" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -cE 'despues de tu revision|no quedo como lo ultimo')"
echo "== 2.43.0 ronda 2: cola larga seguida de una linea del cierre repetida: sigue siendo cola =="
{ cat "$T/con8e.txt"; printf '\n%s\n' "$(printf 'texto de relleno que empuja el cierre hacia arriba %.0s' 1 2 3 4 5 6 7 8 9 10)"; grep -m1 'p-0a1b2c3d4e' "$T/s8e.txt"; } > "$T/cola-rep.txt"
vuelta "$T/t8.jsonl" "$T/t.jsonl" "$T/cola-rep.txt"
chk "reclama la cola" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'despues del ultimo bloque siguen')"
echo "== 2.43.0: un turno que solo reimprime el snippet (no es /checkpoint-3t) sigue exigiendolo en el acto =="
tx "$T/t.jsonl" print "$F" "$T/sin-cierre.txt" "$T/salida-script.txt"
O=$(corre "$T/t.jsonl" false -)
chk "bloquea" "1" "$(bloquea "$O")"
chk "por el snippet, como antes" "1" "$(razon "$O" | grep -c 'snippet `Como retomar` no esta en tu respuesta')"

# ================================================================================================
# 2.44.0 — capas y emojis del cierre (reglas de Victor del 2026-10-01). Desde la ficha del corte
# (2026-10-01) el hook exige las cabeceras: 🔁 snippet en fence, 🔔 vence hoy / ➕ opcional, 🗓️
# calendario sin fence; orden snippet, pendiente, calendario.
fecha01() { python3 -c 'import sys;p=sys.argv[1];t=open(p,encoding="utf-8").read();open(p,"w",encoding="utf-8").write(t.replace("date: 2026-09-22","date: 2026-10-01",1))' "$1"; }
vence_hoy() {   # $1 _pendientes.md, $2 id: un Media que vence hoy
  python3 - "$1" "$HOY" "$2" <<'PYH'
import sys
p, hoy, pid = sys.argv[1:4]; t = open(p, encoding="utf-8").read()
t = t.replace("## Baja prioridad", f"- [ ] media que vence hoy — _origen: [[sessions/2026-09-01-x]]_ — _creado: 2026-09-20_ — _revisar: {hoy}_ — _id: {pid}_\n\n## Baja prioridad", 1)
open(p, "w", encoding="utf-8").write(t)
PYH
}
echo "== 2.44.0: los tres scripts sobre una ficha del corte con un pendiente que vence hoy =="
armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"; fecha01 "$F"
vence_hoy "$M/_pendientes.md" p-0b0b0b0b0b
python3 "$BIN/print-como-retomar.py" "$F" > "$T/n8b.txt"
python3 "$BIN/print-pendiente-opcional.py" "$F" > "$T/n8e.txt"
python3 "$BIN/print-recordatorios.py" "$F" > "$T/n8c.txt"
chk "8b abre con 🔁" "1" "$(head -1 "$T/n8b.txt" | grep -c '^🔁 ')"
chk "8b: el snippet va dentro de un fence" "2" "$(grep -c '^```$' "$T/n8b.txt")"
chk "8e: 🔔 con el que vence hoy" "1" "$(grep -c '^🔔 ' "$T/n8e.txt")"
chk "8e: uno solo" "1" "$(grep -c '^Retomamos:.*p-0b0b0b0b0b' "$T/n8e.txt")"
chk "8e: sin ➕ (hay Retomamos y vence uno hoy)" "0" "$(grep -c '^➕' "$T/n8e.txt")"
chk "8c abre con 🗓️" "1" "$(head -1 "$T/n8c.txt" | grep -c '^🗓️ Recordatorio para el 2026-09-27')"
chk "8c: sin fence (sin color)" "0" "$(grep -c '^```' "$T/n8c.txt")"
chk "8c: conserva el prompt del evento" "1" "$(grep -c '^Retomamos: verificar si las dos reglas' "$T/n8c.txt")"
echo "== 2.44.0: primer cierre: pide los tres comandos, con print-recordatorios.py =="
tx "$T/t44.jsonl" skill "$F" "$T/sin-cierre.txt" "$T/n8b.txt"
O=$(corre "$T/t44.jsonl" false -)
chk "pide print-recordatorios.py" "1" "$(razon "$O" | grep -c 'print-recordatorios\.py')"
chk "pide print-pendiente-opcional.py" "1" "$(razon "$O" | grep -c 'print-pendiente-opcional\.py')"
chk "ya no pide 8d" "0" "$(razon "$O" | grep -c 'print-research-recomendaciones')"
echo "== 2.44.0: vuelta con el cierre nuevo en orden: silencio sobre el cierre =="
{ printf '%s\n\n' "$REV_OK"; cat "$T/n8b.txt"; printf '\n'; cat "$T/n8e.txt"; printf '\n'; cat "$T/n8c.txt"; } > "$T/r44.txt"
vuelta "$T/t44.jsonl" "$T/t.jsonl" "$T/r44.txt"
chk "silencio" "0" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -cE 'despues de tu revision|no quedo como lo ultimo')"
echo "== 2.44.0: el snippet sin su cabecera 🔁: lo reclama =="
{ printf '%s\n\n' "$REV_OK"; tail -n +2 "$T/n8b.txt"; printf '\n'; cat "$T/n8e.txt"; printf '\n'; cat "$T/n8c.txt"; } > "$T/r44-sin.txt"
vuelta "$T/t44.jsonl" "$T/t.jsonl" "$T/r44-sin.txt"
chk "reclama el snippet sin emoji" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'snippet `Como retomar` no esta despues de tu revision')"
echo "== 2.44.0: el bloque 🔔 sin su cabecera: lo reclama =="
{ printf '%s\n\n' "$REV_OK"; cat "$T/n8b.txt"; printf '\n'; tail -n +2 "$T/n8e.txt"; printf '\n'; cat "$T/n8c.txt"; } > "$T/r44-sin8e.txt"
vuelta "$T/t44.jsonl" "$T/t.jsonl" "$T/r44-sin8e.txt"
chk "reclama el bloque de pendiente sin emoji" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'bloque de pendiente (Step 8e) no esta despues de tu revision')"
echo "== 2.44.0: el calendario antes del pendiente: lo reclama por el orden =="
{ printf '%s\n\n' "$REV_OK"; cat "$T/n8b.txt"; printf '\n'; cat "$T/n8c.txt"; printf '\n'; cat "$T/n8e.txt"; } > "$T/r44-orden.txt"
vuelta "$T/t44.jsonl" "$T/t.jsonl" "$T/r44-orden.txt"
chk "reclama el orden" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'no van en el orden snippet, pendiente, calendario')"
echo "== 2.44.0: la misma respuesta sin emojis ni fences sobre una ficha anterior al corte: silencio =="
sed -i.bak 's/^date: 2026-10-01$/date: 2026-09-30/' "$F" && rm -f "$F.bak"
grep -v -e '^🔁 Siguiente' -e '^🔔 ' -e '^🗓️ ' -e '^```$' "$T/r44.txt" > "$T/r44-viejo.txt"
tx "$T/t44v.jsonl" skill "$F" "$T/sin-cierre.txt" "$T/n8b.txt"
vuelta "$T/t44v.jsonl" "$T/t.jsonl" "$T/r44-viejo.txt"
chk "silencio" "0" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -cE 'despues de tu revision|no quedo como lo ultimo')"
echo "== 2.44.0: caso 5 sin nada que venza hoy -> ➕; con uno que vence hoy -> 🔔 y no ➕ =="
armar "$M" -; fecha01 "$F"
python3 "$BIN/print-pendiente-opcional.py" "$F" > "$T/c5.txt"
chk "➕ con el Alta abierto" "1" "$(grep -c '^➕ ' "$T/c5.txt")"
chk "propone el Alta" "1" "$(grep -c 'p-daf3051915' "$T/c5.txt")"
chk "caso 5 en una linea con 🔁" "1" "$(python3 "$BIN/print-como-retomar.py" "$F" | grep -c '^🔁 Como retomar: Ninguno')"
vence_hoy "$M/_pendientes.md" p-0c0c0c0c0c
python3 "$BIN/print-pendiente-opcional.py" "$F" > "$T/c5h.txt"
chk "🔔 con el que vence hoy" "1" "$(grep -c '^🔔 ' "$T/c5h.txt")"
chk "y sin ➕" "0" "$(grep -c '^➕' "$T/c5h.txt")"

echo "== 2.44.0 adversario externo: un recordatorio que CITA 'REVISION DEL CIERRE:' a mitad de linea no es la cabecera =="
sed 's/^Comprueba: busca/Comprueba: que tras REVISION DEL CIERRE: vienen los bloques; busca/' "$FX/calendario-2129.txt" > "$T/cal-cita.txt"
chk "el fixture cita la frase" "1" "$(grep -c 'tras REVISION DEL CIERRE: vienen' "$T/cal-cita.txt")"
armar "$M" "$FX/snippet-2120.txt" "$T/cal-cita.txt"; fecha01 "$F"
python3 "$BIN/print-como-retomar.py" "$F" > "$T/k8b.txt"
python3 "$BIN/print-pendiente-opcional.py" "$F" > "$T/k8e.txt"
python3 "$BIN/print-recordatorios.py" "$F" > "$T/k8c.txt"
tx "$T/tk.jsonl" skill "$F" "$T/sin-cierre.txt" "$T/k8b.txt"
{ printf '%s\n\n' "$REV_OK"; cat "$T/k8b.txt"; printf '\n'; cat "$T/k8e.txt"; printf '\n'; cat "$T/k8c.txt"; } > "$T/rk.txt"
vuelta "$T/tk.jsonl" "$T/t.jsonl" "$T/rk.txt"
O=$(corre "$T/t.jsonl" true -)
chk "la cita no tapa la cabecera: silencio sobre el cierre" "0" "$(razon "$O" | grep -cE 'despues de tu revision|no quedo como lo ultimo')"
chk "y la revision cuenta como contestada" "0" "$(razon "$O" | grep -c 'No contestaste la revision')"
echo "== 2.44.0 adversario externo: el calendario envuelto en un fence (en color): lo reclama =="
{ printf '%s\n\n' "$REV_OK"; cat "$T/k8b.txt"; printf '\n'; cat "$T/k8e.txt"; printf '\n```\n'; cat "$T/k8c.txt"; printf '```\n'; } > "$T/rk-fence.txt"
vuelta "$T/tk.jsonl" "$T/t.jsonl" "$T/rk-fence.txt"
chk "reclama el fence fuera del snippet" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'fence fuera del snippet')"
echo "== 2.44.0 ronda 2: el pendiente envuelto en un fence dentro de una cita markdown: tambien lo reclama =="
{ printf '%s\n\n' "$REV_OK"; cat "$T/k8b.txt"; printf '\n> ```\n'; sed 's/^/> /' "$T/k8c.txt"; printf '> ```\n'; } > "$T/rk-cita.txt"
vuelta "$T/tk.jsonl" "$T/t.jsonl" "$T/rk-cita.txt"
chk "reclama el fence en la cita" "1" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'fence fuera del snippet')"
echo "== 2.44.0: la misma respuesta con fences sobre una ficha anterior al corte: no lo reclama =="
sed -i.bak 's/^date: 2026-10-01$/date: 2026-09-30/' "$F" && rm -f "$F.bak"
chk "sin reclamo de fences" "0" "$(razon "$(corre "$T/t.jsonl" true -)" | grep -c 'fence fuera del snippet')"

echo "== 2.53.0: candidatos a pendiente decididos sin ninguna pregunta al usuario =="
MC="$T/mcand"; mkdir -p "$MC/sessions" "$MC/pendientes"
printf '# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$MC/_pendientes.md"
FC="$MC/sessions/2026-10-09-demo.md"
cat > "$FC" <<'EOF'
---
type: session
date: 2026-10-09
---
# Demo

## Contexto
algo

## Bugs fixed
- Ninguno

## Candidatos a pendiente
- revisar algo — pregunta: Uno — recomendacion: descartar — decision: descartado

## Pendientes
- Ninguno

## Como retomar
Ninguno — la sesion cerro sin continuidad.
EOF
# $1 salida, $2 con|sin|error|invalido|cortado|reimprime (respondido, ausente, rechazado por el
# usuario, error que no llego a nadie, sin tool_result, o un turno que solo reimprime el snippet)
txc() {
  python3 - "$1" "$2" "$FC" <<'PY'
import json, sys
out, preg, ficha = sys.argv[1:4]
R = []
def a(b): R.append({"type": "assistant", "message": {"role": "assistant", "content": b}})
def u(c): R.append({"type": "user", "message": {"role": "user", "content": c}})
u("guarda el checkpoint")
if preg != "reimprime":
    a([{"type": "tool_use", "id": "t1", "name": "Skill", "input": {"skill": "checkpoint-3t"}}])
    u([{"type": "tool_result", "tool_use_id": "t1", "content": "Launching skill: checkpoint-3t"}])
if preg not in ("sin", "reimprime"):
    qs = {"dos": [{"question": "a", "header": "Uno"}, {"question": "b", "header": "Dos"}],
          "ajena": [{"question": "otra cosa", "header": "Otra"}]}.get(preg, [{"question": "a", "header": "Uno"}])
    a([{"type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": {"questions": qs}}])
    r = {"type": "tool_result", "tool_use_id": "q1", "content": "Your questions have been answered"}
    if preg == "error":
        # El texto real de un rechazo del usuario (mas de 200 casos medidos en transcripts locales, 2026-10-09).
        r = {"type": "tool_result", "tool_use_id": "q1", "is_error": True,
             "content": "The user doesn't want to proceed with this tool use. The tool use was rejected."}
    if preg == "invalido":
        r = {"type": "tool_result", "tool_use_id": "q1", "is_error": True,
             "content": "<tool_use_error>InputValidationError: AskUserQuestion failed</tool_use_error>"}
    if preg != "cortado":
        u([r])
a([{"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": f'python3 "$JBIN/print-como-retomar.py" "{ficha}"'}}])
u([{"type": "tool_result", "tool_use_id": "t2", "content": "ok"}])
a([{"type": "text", "text": "listo"}])
with open(out, "w", encoding="utf-8") as fh:
    for x in R: fh.write(json.dumps(x, ensure_ascii=False) + "\n")
PY
}
txc "$T/tc.jsonl" sin
chk "sin AskUserQuestion: reclama la decision tomada por el agente" "1" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"
txc "$T/tc.jsonl" con
chk "con AskUserQuestion respondido: no lo reclama" "0" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"
txc "$T/tc.jsonl" error
chk "un modal cerrado por el usuario SI es una pregunta hecha (Step 3b descarta)" "0" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"
txc "$T/tc.jsonl" invalido
chk "un error que no llego al usuario (InputValidationError) no cuenta como pregunta" "1" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"
txc "$T/tc.jsonl" cortado
chk "un AskUserQuestion sin resultado (turno cortado) no cuenta" "1" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"
# 2.54.0: se cuentan las preguntas de cada modal, no los modales.
cp "$FC" "$FC.bak"
python3 - "$FC" <<'PY'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("- revisar algo — pregunta: Uno — recomendacion: descartar — decision: descartado\n",
            "- revisar algo — pregunta: Uno — recomendacion: descartar — decision: descartado\n- otra cosa — pregunta: Dos — decision: descartado\n",1)
open(p,"w",encoding="utf-8").write(t)
PY
txc "$T/tc.jsonl" con
chk "dos decisiones y un modal con una pregunta: lo reclama" "1" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"
txc "$T/tc.jsonl" dos
chk "dos decisiones y un modal con dos preguntas: no lo reclama" "0" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"
mv "$FC.bak" "$FC"
# 2.54.0, ronda 4: cada decision cita el encabezado de SU pregunta. Una pregunta ajena (encabezado
# que ninguna linea cita) ya no cuenta por la decision.
txc "$T/tc.jsonl" ajena
chk "una pregunta ajena a los candidatos no cubre la decision: lo reclama" "1" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"
txc "$T/tc.jsonl" reimprime
chk "un turno que solo reimprime el snippet no mide candidatos" "0" "$(corre "$T/tc.jsonl" false - | grep -c 'candidatos_pregunta')"

echo "== p-ea8992fa7e: un segundo /checkpoint-3t que EDITA la ficha conserva las decisiones del primero =="
# Turnos de la sesion: $2 = lista "ck:Encabezado" o "otro:Encabezado" (vacio tras ':' = sin
# pregunta). Cada turno `ck` corre el skill y cierra con print-como-retomar; el ultimo es el que mide.
txr() {
  python3 - "$1" "$2" "$FC" <<'PY'
import json, sys
out, turnos, ficha = sys.argv[1:4]
R = []
def a(b): R.append({"type": "assistant", "message": {"role": "assistant", "content": b}})
def u(c): R.append({"type": "user", "message": {"role": "user", "content": c}})
for k, t in enumerate(turnos.split(",")):
    tipo, enc = t.split(":")
    u(f"prompt {k}")
    if tipo == "ck":
        a([{"type": "tool_use", "id": f"s{k}", "name": "Skill", "input": {"skill": "checkpoint-3t"}}])
        u([{"type": "tool_result", "tool_use_id": f"s{k}", "content": "Launching skill: checkpoint-3t"}])
    if enc:
        a([{"type": "tool_use", "id": f"q{k}", "name": "AskUserQuestion",
            "input": {"questions": [{"question": "x", "header": enc}]}}])
        u([{"type": "tool_result", "tool_use_id": f"q{k}", "content": "Your questions have been answered"}])
    if tipo == "ck":
        a([{"type": "tool_use", "id": f"p{k}", "name": "Bash",
            "input": {"command": f'python3 "$JBIN/print-como-retomar.py" "{ficha}"'}}])
        u([{"type": "tool_result", "tool_use_id": f"p{k}", "content": "ok"}])
    a([{"type": "text", "text": "listo"}])
with open(out, "w", encoding="utf-8") as fh:
    for x in R: fh.write(json.dumps(x, ensure_ascii=False) + "\n")
PY
}
cp "$FC" "$FC.bak"
python3 - "$FC" <<'PY'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("- revisar algo — pregunta: Uno — recomendacion: descartar — decision: descartado\n",
            "- revisar algo — pregunta: Uno — recomendacion: descartar — decision: descartado\n- otra cosa — pregunta: Dos — decision: descartado\n",1)
open(p,"w",encoding="utf-8").write(t)
PY
txr "$T/tr.jsonl" "ck:Uno,ck:Dos"
chk "re-checkpoint editado: la decision del primero cita su pregunta de entonces y no lo reclama" "0" "$(corre "$T/tr.jsonl" false - | grep -c 'candidatos_pregunta')"
txr "$T/tr.jsonl" "ck:Uno,otro:Dos,ck:"
chk "una pregunta de un turno que no es checkpoint no cubre una decision: lo reclama" "1" "$(corre "$T/tr.jsonl" false - | grep -c 'candidatos_pregunta')"
sed -i.b2 's/pregunta: Dos/pregunta: Uno/' "$FC" && rm -f "$FC.b2"
txr "$T/tr.jsonl" "ck:Uno,ck:Uno"
chk "re-checkpoint con el mismo encabezado en los dos checkpoints: no lo reclama" "0" "$(corre "$T/tr.jsonl" false - | grep -c 'candidatos_pregunta')"
mv "$FC.bak" "$FC"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
