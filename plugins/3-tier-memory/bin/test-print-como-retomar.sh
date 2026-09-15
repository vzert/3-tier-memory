#!/usr/bin/env bash
# Pruebas de print-como-retomar.py (2.25.6, checkpoint-3t Step 8b): lee el bloque `## Como
# retomar` que Step 8a ya escribio en el session file y lo re-imprime en el formato de terminal
# correcto — para que el agente pegue su stdout en vez de redactar el bloque otra vez.
#
# Caso A es el que un adversario externo encontro roto en produccion (2026-09-15,
# memory/sessions/2026-09-15-repair-plans-index-fase2.md, archivo real de este repo): la forma de
# una linea del caso 5 ("Ninguno — ...") venia envuelta en dos renglones fisicos en el markdown de
# origen, y el script la imprimia partida en dos lineas en vez de colapsada a una.
#
# Uso: test-print-como-retomar.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

correr() { python3 "$BIN/print-como-retomar.py" "$1"; }

echo "A. forma de una linea ENVUELTA en varios renglones fisicos colapsa a una sola linea"
FA="$TMP/a.md"
cat > "$FA" <<'EOF'
## Como retomar

Ninguno — el plan `plan-x` cerro con sus 4 fases resueltas; no queda trabajo
abierto de este plan.

## Related
EOF
OUTA="$(correr "$FA")"
check "una sola linea de salida" "$(printf '%s\n' "$OUTA" | wc -l | tr -d ' ')" "1"
check "contenido completo, sin partir" "$OUTA" \
  "Como retomar: Ninguno — el plan \`plan-x\` cerro con sus 4 fases resueltas; no queda trabajo abierto de este plan."

echo "B. forma de una linea SIN envolver (caso comun) sale identica"
FB="$TMP/b.md"
cat > "$FB" <<'EOF'
## Como retomar

Ninguno — sesion de verificacion puntual, no dejo trabajo pendiente.

## Related
EOF
check "linea tal cual" "$(correr "$FB")" "Como retomar: Ninguno — sesion de verificacion puntual, no dejo trabajo pendiente."

echo "C. bloque fenced completo sale con separadores, contenido intacto"
FC="$TMP/c.md"
cat > "$FC" <<'EOF'
## Como retomar

```
Retomamos: contexto de prueba.

Lee memory/sessions/X.md para el contexto completo.

Proximo paso: hacer Y.

Antes de actuar, dime en 3 lineas donde quedamos.
```

## Related
EOF
OUTC="$(correr "$FC")"
check "empieza con el separador superior" "$(printf '%s\n' "$OUTC" | head -1)" "─── ¿Como retomar en la siguiente sesion? ───"
check "termina con el separador inferior" "$(printf '%s\n' "$OUTC" | tail -1)" "─────────────────────────────────────────────"
check "conserva el contenido del fence" "$(printf '%s\n' "$OUTC" | grep -c 'Retomamos: contexto de prueba.')" "1"

echo "D. placeholder sin llenar (Step 8a no corrio): exit 1, sin stdout"
FD="$TMP/d.md"
cat > "$FD" <<'EOF'
## Como retomar
<filled in Step 8>

## Related
EOF
python3 "$BIN/print-como-retomar.py" "$FD" >"$TMP/d.out" 2>"$TMP/d.err"; RCD=$?
check "sale con error" "$([ "$RCD" -ne 0 ] && echo si || echo no)" "si"
check "stdout vacio (no imprime el placeholder)" "$([ -s "$TMP/d.out" ] && echo tiene || echo vacio)" "vacio"
check "avisa por stderr" "$(grep -c 'todavia no lleno' "$TMP/d.err")" "1"

echo "E. sin seccion '## Como retomar': exit 1, avisa"
FE="$TMP/e.md"
cat > "$FE" <<'EOF'
## Contexto
algo

## Related
EOF
python3 "$BIN/print-como-retomar.py" "$FE" >"$TMP/e.out" 2>"$TMP/e.err"; RCE=$?
check "sale con error" "$([ "$RCE" -ne 0 ] && echo si || echo no)" "si"
check "avisa por stderr" "$(grep -c 'no tiene seccion' "$TMP/e.err")" "1"

echo "F. seccion es la ultima del archivo (sin '## ' siguiente, EOF corta la seccion)"
FF="$TMP/f.md"
cat > "$FF" <<'EOF'
## Como retomar

Ninguno — ultima seccion del archivo, sin encabezado despues.
EOF
check "lee hasta EOF sin fallar" "$(correr "$FF")" "Como retomar: Ninguno — ultima seccion del archivo, sin encabezado despues."

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
