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
# 2.41.2: el checker es un CONTRATO de formas exactas, no un analizador de bash (ver su docstring).
# Lo que esta prueba defiende:
#   A. cada forma que el adversario encontro en 2.39.1 da rojo en la linea exacta;
#   B. R1: toda forma de CLAUDE_PROJECT_DIR distinta de ${CLAUDE_PROJECT_DIR:-$PWD} falla, tambien
#      las seguras ($(pwd), un literal, "$PWD" entre comillas): el contrato marca de mas;
#   C. un bloque anidado en un ````markdown, uno con sangria, uno dentro de una cita `>` y uno SIN
#      etiqueta cuentan (el adversario de 2.39.3 hallo un `git commit` ejecutable sin etiqueta);
#   D. el corpus de las tres rondas de Codex de 2.39.3 (if, funcion, heredoc, subshell, prefijo,
#      autorreferencia...) sigue en rojo: sin la linea canonica, toda linea que nombra PROJECT_DIR
#      falla;
#   E. R2 con la linea canonica: falla si no es la primera, si lleva comentario, si se repite, y
#      toda forma posterior que no sea $PROJECT_DIR o ${PROJECT_DIR} (reasignar, unset, read,
#      local, ${PROJECT_DIR:=x}, ${#PROJECT_DIR});
#      Y ejecuta en bash la linea canonica y la forma de R1, sin entorno: no dan vacio;
#      R4: IFS en un bloque que nombra la variable falla; un bloque aceptado se ejecuta de verdad;
#   F. R3: un comentario que nombra la variable con `$` o backtick falla, y una linea `#` tras una
#      continuacion `\` cuenta como codigo;
#   G. sin falso positivo: la forma canonica con sus usos, ${CLAUDE_PROJECT_DIR:-$PWD}, notas en
#      comentario sin `$`, prosa en ```text, $CLAUDE_PLUGIN_ROOT y $MY_PROJECT_DIR;
#   H. el arbol real (templates/ + commands/) esta en verde, y el recorrido ve TODOS los bloques
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
  check "$et: fallos" "$(printf '%s\n' "$out" | grep -v '^RESUMEN' | sed -E 's#^.*\.md:([0-9]+): (R[0-9]) .*#\1:\2#' | tr '\n' ' ' | sed 's/ $//')" "$esperado"
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
rojo otro-bloque "2:R2 6:R2" <<'EOF'
```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
```

```bash
ls "$PROJECT_DIR/memory"
```
EOF

echo "B. R1: solo \${CLAUDE_PROJECT_DIR:-\$PWD}"
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
rojo def-tardia "2:R2 3:R2" <<'EOF'
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
rojo continuacion "3:R1" <<'EOF'
```bash
python3 x.py \
  --dir "$CLAUDE_PROJECT_DIR"
```
EOF

echo "D. corpus de 2.39.3: sin linea canonica todo falla"
rojo def-en-if "3:R2 5:R2" <<'EOF'
```bash
if [ -d /x ]; then
  PROJECT_DIR=/x
fi
ls "$PROJECT_DIR"
```
EOF
rojo def-otra-rama "3:R2 5:R2" <<'EOF'
```bash
if [ -d /x ]; then
  PROJECT_DIR=/x
else
  ls "$PROJECT_DIR"
fi
```
EOF
rojo def-con-y "2:R2 3:R2" <<'EOF'
```bash
[ -d /x ] && PROJECT_DIR=/x
ls "$PROJECT_DIR"
```
EOF
rojo def-en-funcion "3:R2 5:R2" <<'EOF'
```bash
f() {
  PROJECT_DIR=/x
}
ls "$PROJECT_DIR"
```
EOF
rojo def-en-heredoc "4:R2 6:R2" <<'EOF'
```bash
cat > /tmp/s.sh <<'SH'
echo "script escrito para despues"
PROJECT_DIR=/x
SH
ls "$PROJECT_DIR"
```
EOF
rojo def-subshell "2:R2 3:R2 4:R2" <<'EOF'
```bash
PROJECT_DIR=/x | cat
PROJECT_DIR=/y &
ls "$PROJECT_DIR"
```
EOF
rojo def-en-function "3:R2 5:R2" <<'EOF'
```bash
function f {
  PROJECT_DIR=/x
}
ls "$PROJECT_DIR"
```
EOF
rojo def-heredoc-escapado "4:R2 6:R2" <<'EOF'
```bash
cat > /tmp/s.sh <<\SH
echo "script escrito para despues"
PROJECT_DIR=/x
SH
ls "$PROJECT_DIR"
```
EOF
rojo def-en-subst "3:R2 7:R2 8:R2" <<'EOF'
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
rojo def-heredoc-numero "4:R2 6:R2" <<'EOF'
```bash
cat > /tmp/s.sh <<"1"
echo "script escrito para despues"
PROJECT_DIR=/x
1
ls "$PROJECT_DIR"
```
EOF
rojo def-prefijo "2:R2 3:R2" <<'EOF'
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

rojo seguros-no-permitidos "2:R1 3:R1 4:R1 5:R1" <<'EOF'
```bash
A="${CLAUDE_PROJECT_DIR:-$(pwd)}"
B="${CLAUDE_PROJECT_DIR:-/srv/proyecto}"
C="${CLAUDE_PROJECT_DIR:-"$PWD"}"
D="${!CLAUDE_PROJECT_DIR:-$PWD}"
```
EOF

echo "E. R2 con la linea canonica"
rojo canonica-no-primera "3:R2 4:R2" <<'EOF'
```bash
cd /tmp
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ls "$PROJECT_DIR"
```
EOF
rojo canonica-con-comentario "2:R2 3:R2" <<'EOF'
```bash
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"   # nota
ls "$PROJECT_DIR"
```
EOF
rojo canonica-casi "2:R2 3:R2" <<'EOF'
```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ls "$PROJECT_DIR"
```
EOF
rojo despues-de-canonica "4:R2 5:R2 6:R2 7:R2 8:R2 9:R2 10:R2 11:R2 12:R2" <<'EOF'
```bash
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ls "$PROJECT_DIR" "${PROJECT_DIR}"
PROJECT_DIR=""
unset PROJECT_DIR
read -r PROJECT_DIR < /tmp/ruta
f() { local PROJECT_DIR=; }
: "${PROJECT_DIR:=}"
n=${#PROJECT_DIR}
export PROJECT_DIR
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
echo "${PROJECT_DIR%/}"
```
EOF

# Tabulador vertical o NBSP delante: Python los toma por sangria, bash no, y la linea deja de ser
# una asignacion (Codex, ronda 1 de 2.41.4).
# Por redireccion y no por tuberia: `printf | rojo` correria rojo en un subshell y perderia N y FAIL.
rojo canonica-tab-vertical "2:R2 3:R2" < <(
  printf '```bash\n\vPROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"\nls "$PROJECT_DIR"\n```\n')
rojo canonica-nbsp "2:R2 3:R2" < <(
  printf '```bash\n\302\240PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"\nls "$PROJECT_DIR"\n```\n')
# Lo que el contrato da por bueno, ejecutado de verdad: sin entorno (CLAUDE_PROJECT_DIR vacia o sin
# definir, PROJECT_DIR sin definir), la linea canonica deja PROJECT_DIR no vacia, y la forma de R1
# tampoco da vacio. Se extraen del propio checker para medir el texto que exige.
CANON=$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("c",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.CANONICA)' "$CHK")
FORMA=$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("c",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.FORMA_R1)' "$CHK")
for envset in "" "CLAUDE_PROJECT_DIR="; do
  v=$(cd "$TMP" && env -i PATH="$PATH" $envset bash -c "$CANON"'; printf %s "$PROJECT_DIR"')
  check "canonica en bash (${envset:-sin entorno}): PROJECT_DIR = cwd" "$v" "$(cd "$TMP" && pwd -P)"
  v=$(cd "$TMP" && env -i PATH="$PATH" $envset bash -c 'printf %s "'"$FORMA"'"')
  check "forma R1 en bash (${envset:-sin entorno}): = cwd" "$v" "$(cd "$TMP" && pwd -P)"
done

# R4: con IFS=/ un uso sin comillas se parte y su primer trozo es vacio: `cd ''` (Codex, ronda 2).
rojo ifs "3:R4 4:R4 6:R4" <<'EOF'
```bash
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
IFS=/
local IFS=:
# IFS en un comentario no cuenta
read -r x <<< "$IFS"
cd $PROJECT_DIR
```
EOF
rojo ifs-r1 "3:R4" <<'EOF'
```bash
ENCODED=$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[^A-Za-z0-9]/-/g')
IFS=/ read -r a b <<< "$ENCODED"
```
EOF
verde ifs-sin-variable <<'EOF'
```bash
IFS=, read -r a b <<< "x,y"
```
EOF
# Lo que el contrato acepta despues de la canonica, ejecutado: el bloque de abajo pasa el checker,
# corre en bash sin entorno desde un directorio temporal y escribe en SU memory/, no en /memory.
mkdir -p "$TMP/run/memory"
cat > "$TMP/run.md" <<'EOF'
```bash
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ENCODED=$(echo "$PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
if [ -d "${PROJECT_DIR}/memory" ]; then
  for f in "$PROJECT_DIR"/memory/*.md; do [ -e "$f" ] && wc -l "$f"; done
fi
cat > "$PROJECT_DIR/memory/.memory-config" <<'CFG'
journal_strict=1
CFG
printf '%s\n' "$ENCODED" > "$PROJECT_DIR/memory/encoded"
```
EOF
python3 "$CHK" "$TMP/run.md" >/dev/null 2>&1; rc=$?
check "bloque ejecutable: el checker lo acepta" "$rc" "0"
sed '1d;$d' "$TMP/run.md" > "$TMP/run.sh"
(cd "$TMP/run" && env -i PATH="$PATH" CLAUDE_PROJECT_DIR= bash "$TMP/run.sh") >/dev/null 2>&1
check "bloque ejecutable: escribio la config en el memory/ del cwd" "$(cat "$TMP/run/memory/.memory-config" 2>/dev/null)" "journal_strict=1"
check "bloque ejecutable: ENCODED sale de la ruta del cwd" "$(cat "$TMP/run/memory/encoded" 2>/dev/null)" "$(cd "$TMP/run" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"

echo "F. R3: comentarios"
rojo comentario-con-dolar "2:R1 3:R2 4:R1 5:R1" <<'EOF'
```bash
# usa $CLAUDE_PROJECT_DIR
# y ${PROJECT_DIR}
# o $(( CLAUDE_PROJECT_DIR + 1 ))
# o `printenv CLAUDE_PROJECT_DIR`
```
EOF
rojo comentario-tras-continuacion "3:R1" <<'EOF'
```bash
echo a \
# CLAUDE_PROJECT_DIR
```
EOF
rojo comentario-en-heredoc "4:R2" <<'EOF'
```bash
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
cat > "$PROJECT_DIR/x.sh" <<SH
# ruta: ${PROJECT_DIR:-}
SH
```
EOF

echo "G. sin falso positivo"
verde canonica <<'EOF'
```bash
# el shell no conserva variables; CLAUDE_PROJECT_DIR llega vacia y PROJECT_DIR no existe
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ENCODED=$(echo "$PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
if [ -d "${PROJECT_DIR}/memory" ]; then
  for f in "$PROJECT_DIR"/memory/*.md; do wc -l "$f"; done
fi
cat > "$PROJECT_DIR/memory/.memory-config" <<'CFG'
journal_strict=1
CFG
echo "$FOO$PROJECT_DIR"
```

1. Con sangria:
   ```bash
   PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
   ls "$PROJECT_DIR"
   ```
EOF
verde respaldo <<'EOF'
```bash
# CLAUDE_PROJECT_DIR llega vacia al Bash del agente
ENCODED=$(echo "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[^A-Za-z0-9]/-/g')
X="${Y:-${CLAUDE_PROJECT_DIR:-$PWD}}"
python3 "${CLAUDE_PLUGIN_ROOT}/bin/x.py" "$MY_PROJECT_DIR" "$PROJECT_DIRS"
ls x   # comentario final sin nombrar la variable
```
EOF
verde prosa <<'EOF'
```text
[MISSING] SessionStart → bash $CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh
1. Read: <$CLAUDE_PROJECT_DIR>/CLAUDE.md
```
Prosa fuera de bloque: `$CLAUDE_PROJECT_DIR` y $PROJECT_DIR.
EOF

echo "H. arbol real"
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
ESPERADOS=92
check "corrieron los $ESPERADOS asertos anteriores (este es el siguiente)" "$N" "$ESPERADOS"
[ "$FAIL" -eq 0 ] && echo "PASS $N/$N" || echo "FAIL (ver arriba)"
exit $FAIL
