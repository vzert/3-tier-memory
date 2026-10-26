#!/bin/bash
# Prueba de `pendientes.hilo_sin_reconciliar` en checkpoint-audit.py + paso_ajeno.py (2.64.0).
#
# Motivo (otro proyecto, 2026-10-24; hasta 2.64.2 B no disparaba alli, ver B3 y 2.65.0): el hecho que volvia falso un pendiente (un servidor ya
# parchado) vivio en un plan y en otra ventana; el pendiente siguio diciendo lo viejo hasta que el 🔔
# del cierre lo destapo. El aviso (POR-DISEÑO, no bloquea) sale cuando la sesion edito un plan, un
# handoff o una ficha ajena que liga pendientes abiertos y no actualizo, cerro ni creo NINGUNO. Cruza
# solo por ids y campos (`_relacionado`, `_origen`, la ruta del handoff en el texto), nunca palabras.
# Ids y textos inventados: el repo es publico.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"; S=2026-10-24-demo
armar() {
  rm -rf "$M"; mkdir -p "$M/sessions" "$M/plans"
  printf -- '---\ntype: session\ndate: 2026-10-24\n---\n# Demo\n\n## Como retomar\n\nNinguno — la sesion cerro sola.\n\n## Related\n' > "$M/sessions/$S.md"
  printf -- '---\ntype: session\ndate: 2026-10-20\n---\n# Origen\n' > "$M/sessions/2026-10-20-origen.md"
  printf '# Pendientes\n\n## Alta prioridad\n\n- [ ] Dar por estable el servidor — _origen: [[sessions/2026-10-20-origen]]_ — _creado: 2026-10-20_ — _id: p-6f6f6f6f6f_ — _relacionado: plan-demo-fusion_\n- [ ] Auditar el modulo del handoff handoffs/infra/PROMPT_demo_2026-10-21.md — _origen: [[sessions/2026-10-20-origen]]_ — _creado: 2026-10-21_ — _id: p-7a7a7a7a7a_\n\n- [ ] Cerrar lo de esta ficha — _origen: [[sessions/2026-10-24-demo]]_ — _creado: 2026-10-24_ — _id: p-8b8b8b8b8b_\n- [ ] Migrar el resto, ver handoffs/infra/PROMPT_demo_2026-10-21.md — _origen: [[sessions/2026-10-20-origen]]_ — _creado: 2026-10-20_ — _id: p-9c9c9c9c9c_ — _relacionado: plan-demo-fusion_\n\n## Media prioridad\n## Baja prioridad\n' > "$M/_pendientes.md"
}
# tx ARCHIVO MODO...: edita (plan|handoff|ficha-ajena|ficha-propia|codigo), update (pendiente.update del
# id), alta (pendiente.add)
tx() {
  python3 - "$@" <<'PY'
import json, sys
ruta, modos = sys.argv[1], sys.argv[2:]
r = [{"type": "user", "message": {"role": "user", "content": "trabaja el plan"}}]
def edit(path, n, nuevo="b"):
    r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "e" + n, "name": "Edit",
              "input": {"file_path": path, "old_string": "a", "new_string": nuevo}}]}})
def bash(cmd, n):
    r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "b" + n, "name": "Bash",
              "input": {"command": cmd}}]}})
for m in modos:
    if m == "plan": edit("/p/memory/plans/plan-demo-fusion.md", "1")
    if m == "handoff": edit("/p/handoffs/infra/PROMPT_demo_2026-10-21.md", "2")
    if m == "ficha-ajena": edit("/p/memory/sessions/2026-10-20-origen.md", "3")
    if m == "ficha-propia": edit("/p/memory/sessions/2026-10-24-demo.md", "4")
    if m == "codigo": edit("/p/src/app.py", "5")
    if m == "update": bash("python3 journal-emit.py --type pendiente.update --id p-6f6f6f6f6f --text x", "6")
    if m == "otro-update": bash("python3 journal-emit.py --type pendiente.update --id p-7a7a7a7a7a --text x", "7")
    if m == "alta": bash("python3 journal-emit.py --type pendiente.add --text demo --relacionado plan-demo-fusion", "8")
    if m == "alta-suelta": bash("python3 journal-emit.py --type pendiente.add --text demo", "9")
    if m == "bash-plan": bash("python3 - <<EOF\nopen('/p/memory/plans/plan-demo-fusion.md','w').write('x')\nEOF", "10")
    if m == "bash-lee": bash("cat /p/memory/plans/plan-demo-fusion.md | head", "11")
    # 2.65.0, par real: la edicion nombra un pendiente del grupo y la sesion toca OTRO del mismo grupo
    if m == "plan-nombra": edit("/p/memory/plans/plan-demo-fusion.md", "12", "Ya se hizo; falta darlo por estable (`p-6f6f6f6f6f`)")
    if m == "handoff-nombra": edit("/p/handoffs/infra/PROMPT_demo_2026-10-21.md", "13", "Auditado a medias (`p-7a7a7a7a7a`)")
    if m == "ficha-ajena-nombra": edit("/p/memory/sessions/2026-10-20-origen.md", "14", "Hecho lo de `p-6f6f6f6f6f`")
    if m == "ficha-write": r.append({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "e19", "name": "Write",
              "input": {"file_path": "/p/memory/sessions/2026-10-20-origen.md", "content": "# Origen\n- `p-6f6f6f6f6f`\n"}}]}})
    if m == "update-hermano": bash("python3 journal-emit.py --type pendiente.update --id p-9c9c9c9c9c --text x", "15")
    if m == "block": bash("python3 journal-emit.py --type pendiente.block --id p-6f6f6f6f6f --bloqueado-por y", "16")
    if m == "bash-plan-nombra": bash("python3 - <<EOF\np='/p/memory/plans/plan-demo-fusion.md'\nopen(p,'w').write('ya parchado, p-6f6f6f6f6f')\nEOF", "17")
    if m == "bash-plan-y-ficha": bash("python3 - <<EOF\nopen('/p/memory/sessions/2026-10-24-demo.md','w').write('ver memory/plans/plan-demo-fusion.md y p-6f6f6f6f6f')\nEOF", "18")
with open(ruta, "w", encoding="utf-8") as fh:
    for x in r:
        fh.write(json.dumps(x, ensure_ascii=False) + "\n")
PY
}
estado() {
  python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$S.md" --no-git --hoy 2026-10-24 \
    --solo-snippet --json "$@" | python3 -c '
import json, sys
x = [h for h in json.load(sys.stdin) if h["clave"] == "pendientes.hilo_sin_reconciliar"]
print(x[0]["estado"] + "|" + " / ".join(x[0].get("lineas") or []) if x else "ausente")'
}

echo "== B1. se edita un plan, handoff o ficha ajena y no se toca ningun pendiente ligado: avisa =="
armar; tx "$T/t.jsonl" plan
R=$(estado --transcript "$T/t.jsonl")
chk "plan editado: aviso" "1" "$(printf '%s' "$R" | grep -c '^POR-DISEÑO\|^DISEÑO\|^AVISO')"
chk "nombra el plan y el pendiente" "1" "$(printf '%s' "$R" | grep -c 'plan plan-demo-fusion: p-6f6f6f6f6f')"
armar; tx "$T/t.jsonl" handoff
chk "handoff editado: nombra el pendiente que lo cita" "1" "$(estado --transcript "$T/t.jsonl" | grep -c 'handoff PROMPT_demo_2026-10-21.md: p-7a7a7a7a7a')"
armar; tx "$T/t.jsonl" ficha-ajena
chk "ficha ajena editada: nombra los pendientes de su origen" "1" "$(estado --transcript "$T/t.jsonl" | grep -c 'ficha 2026-10-20-origen: p-6f6f6f6f6f, p-7a7a7a7a7a')"

echo "== B2. sin aviso =="
armar; tx "$T/t.jsonl" plan update
chk "actualizo un pendiente del grupo" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" plan alta
chk "creo uno nuevo que nombra el plan" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" plan alta-suelta
chk "un pendiente.add suelto no apaga el aviso" "1" "$(estado --transcript "$T/t.jsonl" | grep -c 'plan plan-demo-fusion: p-6f6f6f6f6f')"
armar; tx "$T/t.jsonl" bash-plan
chk "un plan escrito por Bash tambien avisa" "1" "$(estado --transcript "$T/t.jsonl" | grep -c 'plan plan-demo-fusion: p-6f6f6f6f6f')"
armar; tx "$T/t.jsonl" bash-lee
chk "un plan solo leido por Bash no avisa" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" ficha-propia
chk "solo edito su propia ficha" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" codigo
chk "solo edito codigo" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" plan
chk "sin transcript: ausente (falla abierto)" "ausente" "$(estado)"
chk "transcript inexistente: ausente" "ausente" "$(estado --transcript "$T/no-existe.jsonl")"
armar; tx "$T/t.jsonl" plan
python3 - "$M/sessions/$S.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("date: 2026-10-24", "date: 2026-10-23", 1))
PY
chk "ficha anterior al corte: ausente" "ausente" "$(estado --transcript "$T/t.jsonl")"

echo "== B3. par real (2.65.0): se toca un hermano y el pendiente nombrado en la edicion queda sin tocar =="
solo() { printf '%s' "$1" | grep -c "$2" | tr -d ' '; }
armar; tx "$T/t.jsonl" plan-nombra update-hermano
R=$(estado --transcript "$T/t.jsonl")
chk "plan: el nombrado sale aunque se toco un hermano" "1" "$(solo "$R" 'plan plan-demo-fusion: p-6f6f6f6f6f')"
chk "plan: el hermano tocado no sale" "0" "$(solo "$R" 'p-9c9c9c9c9c')"
armar; tx "$T/t.jsonl" handoff-nombra update-hermano
R=$(estado --transcript "$T/t.jsonl")
chk "handoff: el nombrado sale aunque se toco un hermano" "1" "$(solo "$R" 'handoff PROMPT_demo_2026-10-21.md: p-7a7a7a7a7a')"
chk "handoff: el hermano tocado no sale" "0" "$(solo "$R" 'p-9c9c9c9c9c')"
armar; tx "$T/t.jsonl" ficha-ajena-nombra update-hermano
R=$(estado --transcript "$T/t.jsonl")
chk "ficha ajena: el nombrado sale aunque se toco un hermano" "1" "$(solo "$R" 'ficha 2026-10-20-origen: p-6f6f6f6f6f')"
chk "ficha ajena: el no nombrado no sale" "0" "$(solo "$R" 'p-7a7a7a7a7a')"
armar; tx "$T/t.jsonl" bash-plan-nombra update-hermano
chk "plan escrito por Bash: el nombrado sale" "1" "$(solo "$(estado --transcript "$T/t.jsonl")" 'plan plan-demo-fusion: p-6f6f6f6f6f')"
armar; tx "$T/t.jsonl" plan-nombra update
chk "el nombrado actualizado no sale" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" plan-nombra block update-hermano
chk "el nombrado bloqueado no sale" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" bash-plan-y-ficha update-hermano
chk "un Bash que escribe una ficha no nombra por el plan" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" plan update-hermano
chk "edicion sin id nombrado y hermano tocado: no sale" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"
armar; tx "$T/t.jsonl" ficha-write update-hermano
chk "un Write del archivo entero no nombra ids" "HECHO" "$(estado --transcript "$T/t.jsonl" | cut -d'|' -f1)"

echo
echo "RESULTADO: $pass ok, $fail fallas"
[ "$fail" -eq 0 ]
