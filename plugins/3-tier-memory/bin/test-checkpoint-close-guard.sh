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
chk "bloquea por la primera ficha (su calendario falta)" "1" "$(printf '%s' "$O" | grep -c 'recordatorio de calendario')"

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
chk "bloquea por la segunda ficha del mismo comando" "1" "$(corre "$T/t.jsonl" false - | grep -c 'recordatorio de calendario')"

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
echo "== adversarial: el break solo en un tool_result (aun no lo cito el agente): silencio =="
chk "silencio" "" "$(veredicto "$BRK" tool_result -)"
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
# 2.35.0 — Step 8e: en una ficha desde el 2026-09-23 el hook exige tambien el prompt opcional que
# print-pendiente-opcional.py imprime EN VIVO desde _pendientes.md.
opcional() {   # arma la ficha 2120 con fecha 2026-09-23 y un Alta candidato
  armar "$M" "$FX/snippet-2120.txt" "$FX/calendario-2129.txt"
  sed -i.bak 's/^date: 2026-09-22$/date: 2026-09-23/' "$F" && rm -f "$F.bak"
  python3 - "$M/_pendientes.md" <<'PYO'
import sys; p=sys.argv[1]; t=open(p, encoding="utf-8").read()
t=t.replace("## Alta prioridad\n\n","## Alta prioridad\n\n- [ ] alta candidata del prompt opcional — _creado: 2026-09-23_ — _id: p-0a0a0a0a0a_\n",1)
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
chk "por el prompt opcional" "1" "$(printf '%s' "$O" | grep -c 'prompt opcional (Step 8e)')"
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

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
