#!/bin/bash
# Prueba de bin/print-research-recomendaciones.py -- checkpoint-3t Step 8d.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"; mkdir -p "$M/sessions" "$M/research"

echo "== session sin seccion Research: silencio, exit 0 =="
cat > "$M/sessions/sin-research.md" <<'EOF'
---
type: session
---
# Sin research

## Contexto
nada

## Research
Ninguno
EOF
set +e
O=$(python3 "$BIN/print-research-recomendaciones.py" "$M/sessions/sin-research.md" 2>&1); RC=$?
set -e
chk "exit 0" "0" "$RC"
chk "silencio" "" "$O"

echo "== session enlaza research SIN Recomendaciones sin marcar: silencio =="
cat > "$M/research/limpio.md" <<'EOF'
---
type: research
---
# Limpio

## Recomendaciones
- [x] idea uno -- implementada en [[plans/plan-x]]
EOF
cat > "$M/sessions/con-research-limpio.md" <<'EOF'
---
type: session
---
# Con research limpio

## Research
- [[research/limpio]]
EOF
O=$(python3 "$BIN/print-research-recomendaciones.py" "$M/sessions/con-research-limpio.md" 2>&1)
chk "silencio" "" "$O"

echo "== session enlaza research CON items sin marcar: imprime el bloque =="
cat > "$M/research/con-pendientes.md" <<'EOF'
---
type: research
---
# Con pendientes

## Recomendaciones
- [x] ya implementada -- ver [[plans/plan-a]]
- [ ] evaluar esquema de bugs con contador de recurrencia
- [ ] evaluar gate de integridad antes de auto-inyectar memory/
EOF
cat > "$M/sessions/con-research-pendiente.md" <<'EOF'
---
type: session
---
# Con research pendiente

## Research
- [[research/con-pendientes]]
EOF
O=$(python3 "$BIN/print-research-recomendaciones.py" "$M/sessions/con-research-pendiente.md" 2>&1)
chk "trae el encabezado del research (aparece 2x: separador + linea de retomamos)" "2" "$(printf '%s' "$O" | grep -c 'research/con-pendientes')"
chk "trae el item 1 sin marcar" "1" "$(printf '%s' "$O" | grep -c 'contador de recurrencia')"
chk "trae el item 2 sin marcar" "1" "$(printf '%s' "$O" | grep -c 'gate de integridad')"
chk "NO trae el item ya marcado" "0" "$(printf '%s' "$O" | grep -c 'ya implementada')"
chk "trae el separador de cierre" "1" "$(printf '%s' "$O" | grep -c '────')"

echo "== dos research enlazados, uno con pendientes y otro limpio: solo imprime el que tiene =="
cat > "$M/sessions/con-dos.md" <<'EOF'
---
type: session
---
# Con dos research

## Research
- [[research/limpio]]
- [[research/con-pendientes]]
EOF
O=$(python3 "$BIN/print-research-recomendaciones.py" "$M/sessions/con-dos.md" 2>&1)
chk "un solo bloque (solo con-pendientes)" "1" "$(printf '%s' "$O" | grep -c '─── Recomendaciones')"

echo "== research enlazado que no existe en disco: NO calla, avisa por stderr (hallazgo del adversario, ronda 1) =="
cat > "$M/sessions/enlace-roto.md" <<'EOF'
---
type: session
---
# Enlace roto

## Research
- [[research/no-existe]]
EOF
set +e
O=$(python3 "$BIN/print-research-recomendaciones.py" "$M/sessions/enlace-roto.md" 2>&1); RC=$?
STDOUT_ONLY=$(python3 "$BIN/print-research-recomendaciones.py" "$M/sessions/enlace-roto.md" 2>/dev/null)
set -e
chk "exit 0 (no es fatal)" "0" "$RC"
chk "avisa por stderr en vez de callar" "1" "$(printf '%s' "$O" | grep -c 'no se pudo leer')"
chk "menciona el slug roto" "1" "$(printf '%s' "$O" | grep -c 'research/no-existe')"
chk "stdout (lo que se pega) sigue vacio -- no hay bloque de retomar que armar sin poder leer el archivo" "" "$STDOUT_ONLY"

echo "== SESSION_FILE inexistente: exit 1, aviso por stderr =="
set +e
O=$(python3 "$BIN/print-research-recomendaciones.py" "$M/sessions/no-existe.md" 2>&1); RC=$?
set -e
chk "exit 1" "1" "$RC"
chk "avisa" "1" "$(printf '%s' "$O" | grep -c 'no se pudo leer')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
