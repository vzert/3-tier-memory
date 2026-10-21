#!/bin/bash
# Prueba de `snippet.ninguno_plan_activo` en checkpoint-audit.py (2.63.31, p-7fd6a82eaa).
#
# Que tiene que cumplir, y por que:
# - Medido el 2026-10-20 en 54 planes de 4 proyectos: las fases de un plan vivian solo en su prosa,
#   y un cierre `ninguno` con un plan `active` enlazado dejaba a la siguiente sesion sin hilo.
# - SALTADO (rechazo del cierre) cuando el snippet es `ninguno`, `## Plans` enlaza un plan `active`
#   y ningun pendiente ABIERTO de _pendientes.md lo cita en `_relacionado:`. Se lee el campo, no la
#   prosa (regla 216): un pendiente que nombra el plan en su texto no lo liga.
# - HECHO con el pendiente ligado, con el plan cerrado, con un `Proximo paso` real, y en fichas
#   anteriores al corte (2026-10-21, d284).
# - El hook de cierre lo lee del modo --solo-snippet: ahi tiene que salir tambien.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
S=2026-10-21-demo-cierre
F="$M/sessions/$S.md"
armar() {  # armar [estado-del-plan] -> memoria minima: un plan enlazado y un snippet `ninguno`
  rm -rf "$M"; mkdir -p "$M/sessions" "$M/plans"
  cat > "$M/_plans-index.md" <<EOF
# Plans Index

## Plans

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
| [[plans/plan-demo-fases\|Demo con fases]] | ${1:-active} | 2026-10-21 | [[sessions/$S]] |  |  |
EOF
  printf -- '---\ntype: plan\nstatus: %s\n---\n# Demo con fases\n\n## Estado\nFase 2 de 3.\n' \
    "${1:-active}" > "$M/plans/plan-demo-fases.md"
  cat > "$M/_pendientes.md" <<'EOF'
# Pendientes

## Alta prioridad

## Media prioridad

- [ ] demo: otra cosa sin plan — _creado: 2026-10-21_ — _id: p-1a1a1a1a1a_
EOF
  cat > "$F" <<EOF
---
type: session
date: 2026-10-21
status: completed
---
# Cierre inventado

## Contexto
Demo.

## Cambios realizados
- Fase 1 del plan.

## Bugs fixed
- Ninguno

## Plans
- [[plans/plan-demo-fases]] — fase 1 hecha

## Research
- Ninguno

## Learnings generados
- Ninguno

## Pendientes
- [ ] demo: otra cosa sin plan — \`p-1a1a1a1a1a\`

## Como retomar

\`\`\`
Retomamos: demo.

Proximo paso: ninguno — el plan sigue en su fase 2.

Antes de actuar, dime en 3 lineas donde quedamos.
\`\`\`
EOF
}
anade_pend() {  # anade_pend "<linea completa>" al final de _pendientes.md
  printf '%s\n' "$1" >> "$M/_pendientes.md"
}
estado() {  # estado [--completo] -> "ESTADO|lineas" de snippet.ninguno_plan_activo, o "ausente"
  modo="--solo-snippet"; [ "${1:-}" = "--completo" ] && modo=""
  python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$F" --no-git --hoy 2026-10-21 \
    $modo --json | python3 -c '
import json, sys
x = [h for h in json.load(sys.stdin) if h["clave"] == "snippet.ninguno_plan_activo"]
print(x[0]["estado"] + "|" + " / ".join(x[0].get("lineas") or []) if x else "ausente")'
}

echo "== 1. ninguno + plan active + sin pendiente ligado: SALTADO =="
armar
chk "rechaza y nombra el plan" "SALTADO|plans/plan-demo-fases.md" "$(estado)"
chk "tambien en el modo completo" "SALTADO|plans/plan-demo-fases.md" "$(estado --completo)"
chk "el texto humano lo lista como SALTADO" "1" "$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$F" --no-git --hoy 2026-10-21 --solo-snippet | grep -c 'SALTADO.*snippet.ninguno_plan_activo')"

echo "== 2. un pendiente abierto _relacionado al plan: HECHO =="
armar
anade_pend "- [ ] demo: fase 2 del plan — _creado: 2026-10-21_ — _id: p-2b2b2b2b2b_ — _relacionado: plan-demo-fases_"
chk "ligado" "HECHO|" "$(estado)"

echo "== 3. ligado junto a otro valor en _relacionado: HECHO =="
armar
anade_pend "- [ ] demo: fase 2 — _creado: 2026-10-21_ — _id: p-2b2b2b2b2b_ — _relacionado: p-1a1a1a1a1a, plan-demo-fases_"
chk "lista de dos" "HECHO|" "$(estado)"

echo "== 4. el pendiente ligado ya esta cerrado: SALTADO =="
armar
anade_pend "- [x] demo: fase 1 — _creado: 2026-10-21_ — _id: p-2b2b2b2b2b_ — _relacionado: plan-demo-fases_"
chk "cerrado no liga" "SALTADO|plans/plan-demo-fases.md" "$(estado)"

echo "== 5. el plan solo nombrado en el TEXTO de un pendiente: SALTADO =="
armar
anade_pend "- [ ] demo: seguir con plan-demo-fases — _creado: 2026-10-21_ — _id: p-2b2b2b2b2b_"
chk "la prosa no liga" "SALTADO|plans/plan-demo-fases.md" "$(estado)"

echo "== 6. ligado a OTRO plan: SALTADO =="
armar
anade_pend "- [ ] demo: fase de otro plan — _creado: 2026-10-21_ — _id: p-2b2b2b2b2b_ — _relacionado: plan-demo-fases-viejo_"
chk "otro slug" "SALTADO|plans/plan-demo-fases.md" "$(estado)"

echo "== 7. el plan esta completed: HECHO =="
armar completed
chk "plan cerrado" "HECHO|" "$(estado)"

echo "== 8. sin fila en el indice, status active en el frontmatter: SALTADO =="
armar
python3 - "$M/_plans-index.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write("\n".join(l for l in t.splitlines() if "plan-demo-fases" not in l) + "\n")
PY
chk "frontmatter" "SALTADO|plans/plan-demo-fases.md" "$(estado)"

echo "== 9. snippet colapsado a Ninguno (caso 5, sin bloque): SALTADO =="
armar
python3 - "$F" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = re.sub(r"## Como retomar\n.*", "## Como retomar\nNinguno\n", t, flags=re.S)
open(p, "w", encoding="utf-8").write(t)
PY
chk "colapsado" "SALTADO|plans/plan-demo-fases.md" "$(estado)"

echo "== 10. un Proximo paso real: no aplica =="
armar
python3 - "$F" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = re.sub(r"^Proximo paso: .*$", "Proximo paso: hacer la fase 2 (p-1a1a1a1a1a).", t, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(t)
PY
chk "paso real" "HECHO|" "$(estado)"

echo "== 11. ## Plans sin enlace: HECHO =="
armar
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("- [[plans/plan-demo-fases]] — fase 1 hecha", "- Ninguno"))
PY
chk "sin plan" "HECHO|" "$(estado)"

echo "== 12. ficha anterior al corte (2026-10-20): no aplica =="
armar
sed -i.bak 's/^date: 2026-10-21$/date: 2026-10-20/' "$F"; rm -f "$F.bak"
chk "antes de 2.63.31" "HECHO|" "$(estado)"

echo "RESULT: pass=$pass fail=$fail"
[ "$fail" = 0 ]
