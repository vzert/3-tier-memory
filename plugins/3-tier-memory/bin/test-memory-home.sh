#!/usr/bin/env bash
# Pruebas de memory-home.sh y de MEMORY_PROJECT_DIR en resolve-project-dir.sh (2.52.0).
#
# Por que existe: con worktrees de git la memoria quedaba partida. Una sesion que entra con
# EnterWorktree recibe CLAUDE_PROJECT_DIR = principal y cwd = worktree; una lanzada dentro del
# worktree recibe CLAUDE_PROJECT_DIR = worktree, y con memory/ ignorada el worktree no tiene memoria.
# Regla: una memoria por repo, la del worktree principal (ver memory-home.sh).
#
# Uso: test-memory-home.sh   (exit 0 = todo verde)
# sella-huellas: no (trabaja en un temporal propio)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado '$3', salio '$2')"; fi; }
g()   { git -c user.name=t -c user.email=t@t.invalid "$@"; }
mh()  { bash "$BIN/memory-home.sh" "$@"; }

echo "== memory-home.sh"
mkdir -p "$TMP/nogit/memory"
eq "carpeta fuera de git: sin cambios" "$(mh "$TMP/nogit")" "$TMP/nogit"
eq "carpeta que no existe: sin cambios" "$(mh "$TMP/no-existe")" "$TMP/no-existe"

M="$TMP/m"; W="$TMP/w"
mkdir -p "$M" && g -C "$M" init -q -b main && printf 'memory/\n' > "$M/.gitignore" \
  && g -C "$M" add .gitignore && g -C "$M" commit -q -m base
mkdir -p "$M/memory" && touch "$M/memory/_pendientes.md"
eq "principal sin worktrees: sin cambios" "$(mh "$M")" "$M"
g -C "$M" worktree add -q "$W" -b w
eq "worktree con memory/ ignorada -> principal" "$(mh "$W")" "$M"
eq "--memory-dir" "$(mh --memory-dir "$W")" "$M/memory"
mkdir -p "$W/a/b"
eq "subcarpeta del worktree sin memoria propia -> raiz del principal" "$(mh "$W/a/b")" "$M"

# Proyecto en subcarpeta (monorepo): la memoria vive en m/sub/memory.
mkdir -p "$M/sub/memory" "$W/sub/deep"
eq "proyecto en subcarpeta -> misma subcarpeta del principal" "$(mh "$W/sub")" "$M/sub"
eq "mas hondo que el proyecto -> sube hasta la que tiene memory/" "$(mh "$W/sub/deep")" "$M/sub"

# Memoria versionada: el worktree tiene su copia, igual gana la del principal.
mkdir -p "$W/memory"
eq "worktree con su propia copia de memory/ -> principal" "$(mh "$W")" "$M"

# Opt-out.
printf 'memoria_worktree=propia\n' > "$M/memory/.memory-config"
eq "opt-out memoria_worktree=propia -> el worktree" "$(mh "$W")" "$W"
rm "$M/memory/.memory-config"
printf 'memoria_worktree=propia_no\n' > "$M/memory/.memory-config"
eq "opt-out exige el valor exacto" "$(mh "$W")" "$M"
rm "$M/memory/.memory-config"

# El principal no tiene memoria: nada cambia.
M2="$TMP/m2"; W2="$TMP/w2"
mkdir -p "$M2" && g -C "$M2" init -q -b main && g -C "$M2" commit -q --allow-empty -m base
g -C "$M2" worktree add -q "$W2" -b w
eq "principal sin memory/ -> el worktree" "$(mh "$W2")" "$W2"

# Repo bare con worktree: no hay principal con arbol.
B="$TMP/b.git"; WB="$TMP/wb"
g init -q --bare "$B" && g -C "$M" push -q "$B" main 2>/dev/null
g -C "$B" worktree add -q "$WB" main 2>/dev/null
mkdir -p "$WB/memory"
eq "worktree de repo bare -> el mismo worktree" "$(mh "$WB")" "$WB"

# sourceado bajo set -u, la funcion no rompe al llamante
out=$(bash -c 'set -u; source "$1"; memory_home "$2"; echo "|fin"' _ "$BIN/memory-home.sh" "$W")
eq "source bajo set -u" "$out" "$M|fin"

echo "== resolve-project-dir.sh -> MEMORY_PROJECT_DIR"
r() { CLAUDE_PROJECT_DIR="$1" bash -c 'set -u; source "$1/resolve-project-dir.sh" </dev/null; printf "%s|%s" "$CLAUDE_PROJECT_DIR" "$MEMORY_PROJECT_DIR"' _ "$BIN"; }
eq "sesion lanzada en el worktree" "$(r "$W")" "$W|$M"
eq "EnterWorktree (CLAUDE_PROJECT_DIR = principal)" "$(r "$M")" "$M|$M"
eq "fuera de git" "$(r "$TMP/nogit")" "$TMP/nogit|$TMP/nogit"
out=$(printf '{"cwd":"%s"}' "$W" | env -u CLAUDE_PROJECT_DIR bash -c 'set -u; source "$1/resolve-project-dir.sh"; printf "%s|%s" "$CLAUDE_PROJECT_DIR" "$MEMORY_PROJECT_DIR"' _ "$BIN")
eq "sin CLAUDE_PROJECT_DIR, cwd del stdin = worktree" "$out" "$W|$M"
out=$(env -u CLAUDE_PROJECT_DIR bash -c 'set -u; source "$1/resolve-project-dir.sh" </dev/null; printf "[%s]" "$MEMORY_PROJECT_DIR"' _ "$BIN")
eq "sin nada que resolver: asignada y vacia" "$out" "[]"

echo "== git anterior a 2.31: --path-format vuelve como texto, no como error"
FB="$TMP/fakebin"; mkdir -p "$FB"
REALGIT=$(command -v git)
cat > "$FB/git" <<FAKE
#!/bin/bash
a=(); for x in "\$@"; do [ "\$x" = "--path-format=absolute" ] && x="--opcion-que-no-existe"; a+=("\$x"); done
exec "$REALGIT" "\${a[@]}"
FAKE
chmod +x "$FB/git"
MO="$TMP/mono"; mkdir -p "$MO/memory" "$MO/proj/memory"; g -C "$MO" init -q -b main; g -C "$MO" commit -q --allow-empty -m b
eq "monorepo con git viejo: el proyecto, no la raiz" "$(PATH="$FB:$PATH" mh "$MO/proj")" "$MO/proj"

echo "== cada MEMORY_DIR=\"memory\" de las plantillas resuelve el worktree (por construccion)"
PLUG="$(dirname "$BIN")"
falta=0; total=0
for f in "$PLUG"/templates/*.md "$PLUG"/commands/*.md; do
  while IFS= read -r n; do
    total=$((total+1))
    sig=$(sed -n "$((n+1))p" "$f")
    case "$sig" in *memory-home.sh*) ;; *) bad "$(basename "$f"):$n sin resolucion de worktree"; falta=1 ;; esac
  done < <(grep -n '^MEMORY_DIR="memory"' "$f" | cut -d: -f1)
done
[ "$falta" = 0 ] && ok "las $total asignaciones llevan la linea de memory-home.sh detras"
# La linea, ejecutada tal cual, desde el worktree y desde el principal.
CANON=$(grep -h -A1 '^MEMORY_DIR="memory"   # Model B; use the auto-memory path for Model A' "$PLUG/templates/backfill-3t.md" | sed -n 2p)
# Saltos de linea, no `;`: la linea acaba en un comentario que se tragaria lo que venga detras.
run_canon() { (cd "$1" && CLAUDE_PLUGIN_ROOT="$PLUG" bash -c "MEMORY_DIR=memory
$CANON
printf %s \"\$MEMORY_DIR\""); }
eq "linea canonica desde el worktree" "$(run_canon "$W")" "$M/memory"
eq "linea canonica desde el principal" "$(run_canon "$M")" "memory"

echo "== cada comando que toca la memoria trae el bloque de worktree (por construccion)"
falta=0; n=0
for f in "$PLUG"/templates/*.md "$PLUG"/commands/*.md; do
  case "$(basename "$f")" in checkpoint-3t.md|checkpoint-3t-step8.md|guia-disparadores.md) continue ;; esac
  n=$((n+1))
  grep -q 'worktree-memoria (2.52.0)' "$f" || { bad "$(basename "$f") sin el bloque de worktree"; falta=1; }
done
[ "$falta" = 0 ] && ok "los $n comandos lo traen (checkpoint lo tiene en su Step 0)"
grep -q '^J="memory/' "$PLUG/templates/status-3t.md" && bad "status-3t sigue leyendo memory/.journal relativo" || ok "status-3t lee el journal de MEMORY_DIR"

echo "== journal-emit sin --memory-dir, desde el worktree, escribe en la memoria del principal"
rm -rf "$W/memory"
out=$(cd "$W" && env -u CLAUDE_PROJECT_DIR -u MEMORY_DIR python3 "$BIN/journal-emit.py" --type session.add --slug 2026-10-07-x --date 2026-10-07 --commit '`abc1234`' 2>&1); rc=$?
eq "sale 0" "$rc" "0"
n=$(ls "$M/memory/.journal/pending" 2>/dev/null | wc -l | tr -d ' ')
eq "el evento esta en el journal del principal" "$n" "1"
[ -e "$W/memory" ] && bad "creo memory/ en el worktree" || ok "no creo memory/ en el worktree"
mkdir -p "$W/memory"   # memoria versionada: la copia del worktree existe
out=$(cd "$W" && env -u CLAUDE_PROJECT_DIR python3 "$BIN/journal-emit.py" --memory-dir memory --type session.add --slug 2026-10-07-y --date 2026-10-07 --commit '`abc1235`' 2>&1)
n=$(ls "$M/memory/.journal/pending" 2>/dev/null | wc -l | tr -d ' ')
eq "con --memory-dir memory relativo, tambien el principal" "$n" "2"
[ -d "$W/memory/.journal" ] && bad "escribio en la copia del worktree" || ok "la copia del worktree no recibe eventos"

echo "== un hook real lee la memoria del principal desde el worktree"
printf -- '- [ ] item visible desde el worktree — _creado: 2026-10-07_\n' > "$M/memory/_pendientes.md"
printf '# idx\n' > "$M/memory/_learnings.md"
H="$TMP/home"; mkdir -p "$H"
out=$(printf '{"cwd":"%s","session_id":"x","hook_event_name":"SessionStart","source":"startup"}' "$W" \
  | HOME="$H" CLAUDE_PROJECT_DIR="$W" CLAUDE_PLUGIN_ROOT="$(dirname "$BIN")" bash "$BIN/session-start.sh" 2>/dev/null)
case "$out" in *"item visible desde el worktree"*) ok "session-start lanzado en el worktree ve los pendientes del principal" ;;
  *) bad "session-start lanzado en el worktree no ve los pendientes del principal: ${out:0:300}" ;; esac
if [ -e "$W/memory/_pendientes.md" ] || [ -d "$W/memory/.journal" ]; then
  bad "session-start escribio memoria en el worktree"
else ok "session-start no escribio memoria en el worktree"; fi

[ "$FAIL" = 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit "$FAIL"
