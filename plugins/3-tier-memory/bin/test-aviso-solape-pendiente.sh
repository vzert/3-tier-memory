#!/bin/bash
# Prueba del aviso de solape de `journal-emit.py --type pendiente.add` (2.64.0).
#
# Caso real (otro proyecto, 2026-10-24): un pendiente nuevo ("auditar module.<x>.php") se guardo aunque
# el handoff de un plan activo ya encargaba ese trabajo. El aviso mira SOLO referencias explicitas
# (un `plan-<slug>`, un handoff/plan/research `.md`, un fichero de codigo) que comparte con un plan
# `active` o con un pendiente abierto; nunca palabras (regla 216). Va a stderr, no bloquea y el
# evento se escribe igual. Nombres inventados: el repo es publico.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
armar() {
  rm -rf "$M"; mkdir -p "$M/sessions" "$M/plans" "$M/journal"
  printf -- '---\ntype: session\n---\n# Demo\n' > "$M/sessions/2026-10-24-demo.md"
  printf '# Pendientes\n\n## Alta prioridad\n\n- [ ] Pasar los flujos 6 y 23 sin el intermediario, con el prompt handoffs/infra/PROMPT_demo-sin-iis_2026-10-21.md — _origen: [[sessions/2026-10-24-demo]]_ — _creado: 2026-10-21_ — _id: p-4d4d4d4d4d_\n- [ ] Subir la version en package.json — _origen: [[sessions/2026-10-24-demo]]_ — _creado: 2026-10-21_ — _id: p-9c9c9c9c9c_\n- [ ] Rotar la llave de module.factdemo.php — _origen: [[sessions/2026-10-24-demo]]_ — _creado: 2026-10-21_ — _id: p-5e5e5e5e5e_\n\n## Media prioridad\n## Baja prioridad\n' > "$M/_pendientes.md"
  printf -- '---\nstatus: active\n---\n# Plan demo\n' > "$M/plans/plan-demo-sin-iis.md"
  printf -- '---\nstatus: completed\n---\n# Plan viejo\n' > "$M/plans/plan-viejo.md"
  printf -- '---\nstatus: proposed\n---\n# Plan propuesto\n' > "$M/plans/plan-propuesto.md"
  printf '# Plans\n\n| Plan | Status |\n|---|---|\n| [[plans/plan-demo-sin-iis]] | active |\n| [[plans/plan-viejo]] | completed |\n| [[plans/plan-propuesto]] | proposed |\n' > "$M/_plans-index.md"
}
add() {   # $1 = texto; imprime stderr, deja el id en $T/id
  python3 "$BIN/journal-emit.py" --memory-dir "$M" --type pendiente.add --text "$1" --prioridad Alta \
    --origen "[[sessions/2026-10-24-demo]]" 2>&1 >"$T/id" || true
}
n_aviso() { printf '%s' "$1" | grep -c 'AVISO — este pendiente cita lo mismo' || true; }

echo "== C1. comparte una referencia explicita: avisa y guarda igual =="
armar
E=$(add "Auditar module.factdemo.php antes de rotar")
chk "mismo fichero que un pendiente abierto" "1" "$(n_aviso "$E")"
chk "nombra el pendiente" "1" "$(printf '%s' "$E" | grep -c 'p-5e5e5e5e5e')"
chk "el evento se escribio igual" "1" "$(grep -c '^p-' "$T/id")"
armar
E=$(add "Revisar el handoff handoffs/infra/PROMPT_demo-sin-iis_2026-10-21.md otra vez")
chk "mismo handoff que un pendiente abierto" "1" "$(n_aviso "$E")"
armar
E=$(add "Seguir el plan-demo-sin-iis fase 2")
chk "cita un plan activo" "1" "$(n_aviso "$E")"
chk "y lo nombra" "1" "$(printf '%s' "$E" | grep -c 'el plan abierto plan-demo-sin-iis')"
armar
chk "un plan propuesto (no cerrado) tambien avisa" "1" "$(n_aviso "$(add "Retomar el plan-propuesto")")"

echo "== C2. sin referencia compartida: sin aviso =="
armar
chk "texto parecido pero sin referencia" "0" "$(n_aviso "$(add "Auditar la rotacion de llaves del servidor")")"
chk "un plan completado no avisa" "0" "$(n_aviso "$(add "Cerrar cosas de plan-viejo")")"
chk "un fichero distinto" "0" "$(n_aviso "$(add "Revisar module.otro.php")")"
chk "un fichero generico (package.json) no cuenta" "0" "$(n_aviso "$(add "Revisar package.json y README.md")")"
armar; printf '# Pendientes\n' > "$M/_pendientes.md"; rm -rf "$M/plans" "$M/_plans-index.md"
chk "sin pendientes ni planes: sin aviso y sin error" "0" "$(n_aviso "$(add "Auditar module.factdemo.php")")"

echo
echo "RESULTADO: $pass ok, $fail fallas"
[ "$fail" -eq 0 ]
