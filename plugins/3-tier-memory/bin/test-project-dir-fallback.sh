#!/usr/bin/env bash
# Prueba de check-project-dir-fallback.py (p-9d5e07e233): ningun bloque bash de templates/ ni de
# commands/ usa $CLAUDE_PROJECT_DIR sin ':-', ni $PROJECT_DIR sin definirla en el mismo bloque.
#
# Por que existe: CLAUDE_PROJECT_DIR llega VACIA a las llamadas Bash del agente y el shell no
# conserva variables entre llamadas. 2.39.0 tenia 10 lineas asi (5c-bis de /checkpoint-3t nunca
# sellaba; /setup-memory hacia mkdir en /memory). 2.39.1 las limpio con un recorrido de un solo
# uso, y el primer barrido, por una sola grafia y solo en templates/, dejo cinco bloques en
# commands/. Sin esta suite, el siguiente bloque que se escriba puede volver a caer.
#
# Lo que esta prueba defiende:
#   A. cada forma que el adversario encontro en 2.39.1 da rojo en la linea exacta:
#      ENCODED=$(echo "$CLAUDE_PROJECT_DIR"), mkdir, cat >, if [ -f ] con $PROJECT_DIR sin definir;
#   B. tambien ${CLAUDE_PROJECT_DIR} con llaves y sin ':-', y una definicion DESPUES del uso;
#   C. un ```bash anidado en un ````markdown y un ```bash con sangria dentro de una lista cuentan;
#   D. sin falso positivo: ${CLAUDE_PROJECT_DIR:-$PWD}, definicion en la primera linea, prosa en
#      un bloque sin etiqueta y $CLAUDE_PLUGIN_ROOT quedan en verde;
#   E. el arbol real (templates/ + commands/) esta en verde.
#
# Uso: test-project-dir-fallback.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN/.." && pwd)"
CHK="$BIN/check-project-dir-fallback.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
N=0

ok()   { printf '  ok   %s\n' "$1"; N=$(( N + 1 )); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; N=$(( N + 1 )); }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

# rojo <etiqueta> <linea:regla esperadas, separadas por espacio>  (plantilla en stdin)
rojo() {
  local et="$1" esperado="$2" f="$TMP/$1.md" out rc
  cat > "$f"
  out=$(python3 "$CHK" "$f" 2>&1); rc=$?
  check "$et: exit 1" "$rc" "1"
  check "$et: fallos" "$(printf '%s\n' "$out" | grep -v '^RESUMEN' | sed -E 's#^.*\.md:([0-9]+): (R[12]) .*#\1:\2#' | tr '\n' ' ' | sed 's/ $//')" "$esperado"
}

# verde <etiqueta>  (plantilla en stdin)
verde() {
  local et="$1" f="$TMP/$1.md" out rc
  cat > "$f"
  out=$(python3 "$CHK" "$f" 2>&1); rc=$?
  check "$et: exit 0" "$rc" "0"
  [ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'
}

echo "A. formas de 2.39.0 y de la ronda del adversario"
rojo encoded "3:R1" <<'EOF'
## Step 1
```bash
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
```
EOF
rojo mkdir "3:R2" <<'EOF'
## Step 2
```bash
mkdir -p "$PROJECT_DIR/memory/"{learnings,sessions}
```
EOF
rojo cat "2:R2" <<'EOF'
```bash
cat > "$PROJECT_DIR/memory/.memory-config" <<'CFGEOF'
journal_strict=1
CFGEOF
```
EOF
rojo iff "4:R2" <<'EOF'
Texto.

```bash
if [ ! -f "${PROJECT_DIR}/memory/.memory-config" ]; then echo no; fi
```
EOF
# Definida en OTRO bloque: es otra llamada Bash, la variable ya no existe.
rojo otro-bloque "6:R2" <<'EOF'
```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
```

```bash
ls "$PROJECT_DIR/memory"
```
EOF

echo "B. llaves sin ':-' y definicion tardia"
rojo llaves "2:R1 3:R1" <<'EOF'
```bash
D="${CLAUDE_PROJECT_DIR}/memory"
E="${CLAUDE_PROJECT_DIR-$PWD}"
```
EOF
rojo def-tardia "2:R2" <<'EOF'
```sh
ls "$PROJECT_DIR"
PROJECT_DIR="$PWD"
```
EOF

echo "C. bloques anidados y con sangria"
rojo anidado "4:R1" <<'EOF'
````markdown
## Como retomar
```bash
cd "$CLAUDE_PROJECT_DIR"
```
````
EOF
rojo sangria "3:R2" <<'EOF'
1. Paso uno:
   ```bash
   wc -l "$PROJECT_DIR/memory/_pendientes.md"
   ```
EOF

echo "D. sin falso positivo"
verde respaldo <<'EOF'
```bash
ENCODED=$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[^A-Za-z0-9]/-/g')
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"   # definicion y uso en la misma linea
mkdir -p "$PROJECT_DIR/memory"
export PROJECT_DIR=/x; ls "$PROJECT_DIR"
python3 "${CLAUDE_PLUGIN_ROOT}/bin/x.py" "$MY_PROJECT_DIR"
```
EOF
verde prosa <<'EOF'
```
[MISSING] SessionStart → bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh
1. Read: <$CLAUDE_PROJECT_DIR>/CLAUDE.md
```
Prosa fuera de bloque: `$CLAUDE_PROJECT_DIR` y $PROJECT_DIR.
EOF

echo "E. arbol real"
out=$(python3 "$CHK" "$PLUGIN_ROOT/templates" "$PLUGIN_ROOT/commands" 2>&1); rc=$?
check "templates/ + commands/: exit 0" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'
# Que el recorrido vea algo: 0 bloques tambien daria 0 fallos.
nb=$(printf '%s\n' "$out" | sed -nE 's/^RESUMEN .* ([0-9]+) bloques shell.*/\1/p')
[ "${nb:-0}" -ge 50 ] && ok "recorre $nb bloques shell (>= 50)" || bad "recorre ${nb:-0} bloques shell (esperado >= 50)"

echo
[ "$FAIL" -eq 0 ] && echo "PASS $N/$N" || echo "FAIL (ver arriba)"
exit $FAIL
