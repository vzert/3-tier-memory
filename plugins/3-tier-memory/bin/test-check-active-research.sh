#!/bin/bash
# Prueba de bin/check-active-research.py -- ver memory/plans/plan-research-recomendaciones.md.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"; mkdir -p "$M/research"

echo "== sin memory/research/: silencio, count=0 =="
rm -rf "$M/research"
O=$(python3 "$BIN/check-active-research.py" "$M" 2>&1)
C=$(python3 "$BIN/check-active-research.py" "$M" --count 2>&1)
chk "silencio" "" "$O"
chk "count 0" "0" "$C"
mkdir -p "$M/research"

echo "== research sin seccion Recomendaciones: silencio =="
cat > "$M/research/sin-seccion.md" <<'EOF'
---
type: research
status: completed
---
# Sin seccion

Nada que ver aqui.
EOF
O=$(python3 "$BIN/check-active-research.py" "$M" 2>&1)
chk "silencio" "" "$O"

echo "== research con TODO marcado: silencio =="
cat > "$M/research/todo-marcado.md" <<'EOF'
---
type: research
---
# Todo marcado

## Recomendaciones
- [x] idea uno -- implementada en [[plans/plan-x]]
- [x] idea dos -- declinado: no aplica

## Related
EOF
O=$(python3 "$BIN/check-active-research.py" "$M" 2>&1)
chk "silencio (nada sin marcar)" "" "$O"

echo "== research con items sin marcar: avisa =="
cat > "$M/research/con-pendientes.md" <<'EOF'
---
type: research
---
# Con pendientes

## Recomendaciones
- [x] idea implementada -- ver [[plans/plan-y]]
- [ ] idea dos sin decidir
- [ ] idea tres sin decidir

## Related
EOF
O=$(python3 "$BIN/check-active-research.py" "$M" 2>&1)
C=$(python3 "$BIN/check-active-research.py" "$M" --count 2>&1)
chk "avisa" "1" "$(printf '%s' "$O" | grep -c 'con-pendientes')"
chk "cuenta las 2 sin marcar" "1" "$(printf '%s' "$O" | grep -c '2 de 3 sin decidir')"
chk "lista el texto de cada una" "1" "$(printf '%s' "$O" | grep -c 'idea dos sin decidir')"
chk "no lista la ya marcada" "0" "$(printf '%s' "$O" | grep -c 'idea implementada')"
chk "count = 1 (un research con pendientes)" "1" "$C"

echo "== fichero illegible: avisa por stderr, no lo confunde con 'sin recomendaciones' =="
chmod 000 "$M/research/con-pendientes.md" 2>/dev/null
if [ "$(id -u)" != "0" ]; then
  ERR=$(python3 "$BIN/check-active-research.py" "$M" 2>&1 >/dev/null)
  chk "stderr avisa" "1" "$(printf '%s' "$ERR" | grep -c 'no se pudo leer')"
fi
chmod 644 "$M/research/con-pendientes.md" 2>/dev/null

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
