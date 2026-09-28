#!/usr/bin/env bash
# Prueba de check-project-dir-fallback.py (p-9d5e07e233): ningun bloque de shell de templates/ ni
# de commands/ usa $CLAUDE_PROJECT_DIR sin respaldo no vacio, ni $PROJECT_DIR sin definirla antes
# en el mismo bloque.
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
#   B. tambien ${CLAUDE_PROJECT_DIR} con llaves y sin ':-', los respaldos vacios (:-}, :-""}, :-''}),
#      ${#...}, el nombre en aritmetica y una definicion DESPUES del uso;
#   C. un bloque anidado en un ````markdown, uno con sangria, uno dentro de una cita `>` y uno SIN
#      etiqueta cuentan (el adversario de 2.39.3 hallo un `git commit` ejecutable sin etiqueta);
#   D. no cuentan como definicion: la asignacion dentro de un if, con && delante, dentro de una
#      funcion, en un heredoc, como prefijo de un comando, ni la que se usa a si misma sin respaldo;
#      tampoco se escapa $FOO$PROJECT_DIR;
#   E. sin falso positivo: ${CLAUDE_PROJECT_DIR:-$PWD}, definicion arriba (tambien con export,
#      local, declare, read), comentarios, prosa en un bloque ```text y $CLAUDE_PLUGIN_ROOT;
#   F. el arbol real (templates/ + commands/) esta en verde, y el recorrido ve TODOS los bloques
#      de shell: su cuenta coincide con una cuenta independiente de las fences de apertura.
#
# Uso: test-project-dir-fallback.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN/.." && pwd)"
CHK="$BIN/check-project-dir-fallback.py"
TMP="$(mktemp -d)" && [ -d "$TMP" ] && [ -w "$TMP" ] || {
  echo "FAIL no se pudo crear el directorio temporal: sin el, ningun caso corre"; exit 1; }
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
rojo llaves "2:R1 3:R1 4:R1" <<'EOF'
```bash
D="${CLAUDE_PROJECT_DIR}/memory"
E="${CLAUDE_PROJECT_DIR-$PWD}"
F="${CLAUDE_PROJECT_DIR:-}/memory"
```
EOF
rojo vacios "2:R1 3:R1 4:R1 5:R1" <<'EOF'
```bash
A="${CLAUDE_PROJECT_DIR:-""}"
B="${CLAUDE_PROJECT_DIR:-''}"
n=${#CLAUDE_PROJECT_DIR}
echo $(( CLAUDE_PROJECT_DIR + 1 ))
```
EOF
rojo respaldo-variable "2:R1 3:R1" <<'EOF'
```bash
A="${CLAUDE_PROJECT_DIR:-${EMPTY}}"
B="${CLAUDE_PROJECT_DIR:-$HOME}"
```
EOF
rojo usos-raros "3:R2 4:R2 5:R2" <<'EOF'
```bash
FOO=/x
echo "$FOO$PROJECT_DIR"
n=${#PROJECT_DIR}
D="${PROJECT_DIR:-""}/m"
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

rojo cita "3:R1" <<'EOF'
> Ejemplo:
> ```bash
> cd "$CLAUDE_PROJECT_DIR"
> ```
EOF
rojo sin-etiqueta "2:R2" <<'EOF'
```
git -C "$PROJECT_DIR" commit -m x
```
EOF
rojo continuacion "2:R1" <<'EOF'
```bash
python3 x.py \
  --dir "$CLAUDE_PROJECT_DIR"
```
EOF

echo "D. lo que NO define la variable"
rojo def-en-if "5:R2" <<'EOF'
```bash
if [ -d /x ]; then
  PROJECT_DIR=/x
fi
ls "$PROJECT_DIR"
```
EOF
rojo def-otra-rama "5:R2" <<'EOF'
```bash
if [ -d /x ]; then
  PROJECT_DIR=/x
else
  ls "$PROJECT_DIR"
fi
```
EOF
rojo def-con-y "3:R2" <<'EOF'
```bash
[ -d /x ] && PROJECT_DIR=/x
ls "$PROJECT_DIR"
```
EOF
rojo def-en-funcion "5:R2" <<'EOF'
```bash
f() {
  PROJECT_DIR=/x
}
ls "$PROJECT_DIR"
```
EOF
rojo def-en-heredoc "6:R2" <<'EOF'
```bash
cat > /tmp/s.sh <<'SH'
echo "script escrito para despues"
PROJECT_DIR=/x
SH
ls "$PROJECT_DIR"
```
EOF
rojo def-subshell "4:R2" <<'EOF'
```bash
PROJECT_DIR=/x | cat
PROJECT_DIR=/y &
ls "$PROJECT_DIR"
```
EOF
rojo def-en-function "5:R2" <<'EOF'
```bash
function f {
  PROJECT_DIR=/x
}
ls "$PROJECT_DIR"
```
EOF
rojo def-heredoc-escapado "6:R2" <<'EOF'
```bash
cat > /tmp/s.sh <<\SH
echo "script escrito para despues"
PROJECT_DIR=/x
SH
ls "$PROJECT_DIR"
```
EOF
rojo def-en-subst "8:R2" <<'EOF'
```bash
x=$(
  PROJECT_DIR=/x
  echo hola
)
diff <(
  PROJECT_DIR=/y; echo) /dev/null
ls "$PROJECT_DIR"
```
EOF
rojo def-heredoc-numero "6:R2" <<'EOF'
```bash
cat > /tmp/s.sh <<"1"
echo "script escrito para despues"
PROJECT_DIR=/x
1
ls "$PROJECT_DIR"
```
EOF
rojo def-prefijo "3:R2" <<'EOF'
```bash
PROJECT_DIR=/x make build
ls "$PROJECT_DIR"
```
EOF
rojo def-autorref "2:R2 3:R2" <<'EOF'
```bash
PROJECT_DIR="$PROJECT_DIR/sub"
ls "$PROJECT_DIR"
```
EOF

echo "E. sin falso positivo"
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
```text
[MISSING] SessionStart → bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh
1. Read: <$CLAUDE_PROJECT_DIR>/CLAUDE.md
```
Prosa fuera de bloque: `$CLAUDE_PROJECT_DIR` y $PROJECT_DIR.
EOF

verde here-string <<'EOF'
```bash
grep -c x <<<"hola"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
n=$(ls "$PROJECT_DIR" | wc -l)
ls "$PROJECT_DIR"
```
EOF
verde respaldos-validos <<'EOF'
```bash
A="${CLAUDE_PROJECT_DIR:-$(pwd)}"
B="${CLAUDE_PROJECT_DIR:-/srv/proyecto}"
C="${CLAUDE_PROJECT_DIR:-"$PWD"}"
PROJECT_DIR=/x && ls "$PROJECT_DIR"
```
EOF
verde definiciones <<'EOF'
```bash
cat > /tmp/cfg <<'CFG'
journal_strict=1
CFG
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-\
$PWD}"
ls "$PROJECT_DIR"
```

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -d "$PROJECT_DIR/memory" ]; then
  for f in "$PROJECT_DIR"/memory/*.md; do wc -l "$f"; done
fi
```

```bash
export PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"; ls "$PROJECT_DIR"
```

```bash
declare -r PROJECT_DIR=/x
ls "$PROJECT_DIR"
```

```bash
read -r PROJECT_DIR < /tmp/ruta
ls "$PROJECT_DIR"
```

```bash
PROJECT_DIR=/x   # comentario con $CLAUDE_PROJECT_DIR y $PROJECT_DIR
if [ -d "$PROJECT_DIR" ]; then echo "$PROJECT_DIR"; fi
cat <<EOF2
dentro de un heredoc tambien: $PROJECT_DIR
EOF2
```

```bash
# CLAUDE_PROJECT_DIR llega vacia: por eso el respaldo
f() { local PROJECT_DIR="${PROJECT_DIR:-$PWD}"; ls "$PROJECT_DIR"; }
```
EOF

echo "F. arbol real"
out=$(python3 "$CHK" "$PLUGIN_ROOT/templates" "$PLUGIN_ROOT/commands" 2>&1); rc=$?
check "templates/ + commands/: exit 0" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed 's/^/       /'
# Que el recorrido vea algo: 0 bloques tambien daria 0 fallos.
nb=$(printf '%s\n' "$out" | sed -nE 's/^RESUMEN .* ([0-9]+) bloques shell.*/\1/p')
[ "${nb:-0}" -ge 50 ] && ok "recorre $nb bloques shell (>= 50)" || bad "recorre ${nb:-0} bloques shell (esperado >= 50)"
# Cuenta independiente, en awk y no en Python: fences de apertura de shell (sin etiqueta o
# bash/sh/shell/zsh/console), con una pila para los bloques anidados en otro no-shell (asi estan
# los de "Como retomar" dentro de ````markdown en checkpoint-3t). Si difiere del recorrido, un
# bloque se trago a otro o el recorrido salto uno.
indep=0
for f in "$PLUGIN_ROOT"/templates/*.md "$PLUGIN_ROOT"/commands/*.md; do
  c=$(awk '
    { l=$0; sub(/^[ \t]*(>[ \t]?)*[ \t]*/, "", l) }
    !match(l, /^(```+|~~~+)/) { next }
    {
      marca=substr(l, 1, RLENGTH); info=substr(l, RLENGTH+1); gsub(/^[ \t]+|[ \t]+$/, "", info)
      if (d > 0 && info == "" && substr(marca,1,1) == substr(pila[d],1,1) && length(marca) >= length(pila[d])) { d--; next }
      if (d > 0 && esshell[d]) next
      if (substr(marca,1,1) == "`" && index(info, "`")) next
      split(info, w, /[ \t]/); p=tolower(w[1])
      d++; pila[d]=marca
      esshell[d]=(p=="" || p=="bash" || p=="sh" || p=="shell" || p=="zsh" || p=="console")
      n+=esshell[d]
    }
    END { print n+0 }' "$f")
  indep=$(( indep + c ))
done
check "cuenta independiente de fences de shell = la del recorrido" "$indep" "${nb:-0}"

echo
# Si un cambio salta casos en silencio, el total baja: se fija aqui.
ESPERADOS=62
check "corrieron los $ESPERADOS asertos" "$N" "$ESPERADOS"
[ "$FAIL" -eq 0 ] && echo "PASS $N/$N" || echo "FAIL (ver arriba)"
exit $FAIL
