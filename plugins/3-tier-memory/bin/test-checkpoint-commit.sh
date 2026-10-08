#!/usr/bin/env bash
# Pruebas de checkpoint-commit.py (2.52.0): el commit de un checkpoint lleva solo lo de su sesion.
#
# Por que existe: Step 6 hacia `git add memory/` y barria fichas, planes y colas de Step 8 de otras
# sesiones del mismo checkout (en una instalacion real, 19 archivos ajenos en un commit). Ver la cabecera del script.
#
# Uso: test-checkpoint-commit.sh   (exit 0 = todo verde)
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
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no aparece '$3' en: ${2:0:400})" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (aparece '$3')" ;; *) ok "$1" ;; esac; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
CC() { python3 "$BIN/checkpoint-commit.py" "$@"; }
files() { git -C "$1" show --name-only --format= HEAD | sort | tr '\n' ' '; }

nuevo_repo() {
  R="$1"; mkdir -p "$R/memory/sessions" "$R/memory/plans" "$R/memory/research" "$R/memory/learnings" \
    "$R/memory/pendientes"
  git -C "$R" init -q -b main
  printf '# p\n' > "$R/memory/_pendientes.md"; printf '# s\n' > "$R/memory/_session-index.md"
  printf '# l\n' > "$R/memory/learnings/comun.md"; printf '# vieja\n' > "$R/memory/sessions/2026-10-01-vieja.md"
  printf 'x\n' > "$R/README.md"
  git -C "$R" add -A && git -C "$R" commit -q -m base
}

echo "== dos sesiones en el mismo checkout"
R="$TMP/r"; nuevo_repo "$R"; M="$R/memory"
# Sesion A: ficha nueva que enlaza su plan y un research; Sesion B: ficha + plan, y B ya hizo
# `git add` de su ficha (plantilla vieja). Indices compartidos tocados por las dos.
printf '# A\n## Plans\n| [[plans/plan-a\\|Plan A]] | active |\n## Research\n- [[research/r-a]]\n' > "$M/sessions/2026-10-07-a.md"
printf '# plan A\n' > "$M/plans/plan-a.md"; printf '# r A\n' > "$M/research/r-a.md"
printf '# B a medias\n' > "$M/sessions/2026-10-07-b.md"; printf '# plan B\n' > "$M/plans/plan-b.md"
printf -- '- fila A\n- fila B\n' >> "$M/_pendientes.md"; printf -- '1. regla A\n' >> "$M/learnings/comun.md"
printf -- '## Como retomar\ncola vieja\n' >> "$M/sessions/2026-10-01-vieja.md"
git -C "$R" add "$M/sessions/2026-10-07-b.md"
out=$(CC --memory-dir "$M" --session-file "$M/sessions/2026-10-07-a.md" --mensaje "checkpoint: A")
has "commit hecho" "$out" "COMMIT hash="
eq "el commit lleva la ficha de A, su plan, su research y lo compartido" "$(files "$R")" \
  "memory/_pendientes.md memory/learnings/comun.md memory/plans/plan-a.md memory/research/r-a.md memory/sessions/2026-10-07-a.md "
has "cuenta propios y compartidos" "$out" "archivos=5 propios=3 compartidos=2"
st=$(git -C "$R" status --porcelain)
has "la ficha de B sigue en el indice, como B la dejo" "$st" "A  memory/sessions/2026-10-07-b.md"
has "el plan de B queda fuera" "$st" "?? memory/plans/plan-b.md"
has "la cola vieja de otra sesion queda fuera" "$st" " M memory/sessions/2026-10-01-vieja.md"

echo "== la cola (Step 8f)"
out=$(CC --memory-dir "$M" --session-file "$M/sessions/2026-10-07-a.md" --mensaje "cola: A")
has "sin cambios propios ni compartidos: no commitea" "$out" "COMMIT skip=sin-cambios"
printf -- '## Como retomar\nsnippet A\n' >> "$M/sessions/2026-10-07-a.md"
printf -- '| A | `abc1234` |\n' >> "$M/_session-index.md"
out=$(CC --memory-dir "$M" --session-file "$M/sessions/2026-10-07-a.md" --mensaje "cola: A")
eq "la cola entra con el indice de sesiones" "$(files "$R")" "memory/_session-index.md memory/sessions/2026-10-07-a.md "

echo "== --solo-compartidos"
printf -- '2. regla C\n' >> "$M/learnings/comun.md"; printf 'otra\n' >> "$M/sessions/2026-10-07-a.md"
out=$(CC --memory-dir "$M" --solo-compartidos --mensaje "consolidate")
eq "solo lo compartido" "$(files "$R")" "memory/learnings/comun.md "
has "la ficha queda fuera" "$(git -C "$R" status --porcelain)" " M memory/sessions/2026-10-07-a.md"

echo "== --listar no toca git"
before=$(git -C "$R" rev-parse HEAD)
out=$(CC --memory-dir "$M" --session-file "$M/sessions/2026-10-07-a.md" --listar)
has "lista la ficha como propia" "$out" "propia sessions/2026-10-07-a.md"
has "lista plans/plan-a.md como propia" "$out" "propia plans/plan-a.md"
hasnt "no lista plans/ entero" "$out" "compartida plans"
eq "HEAD no se movio" "$(git -C "$R" rev-parse HEAD)" "$before"

echo "== rutas ignoradas no rompen el add"
printf 'pendientes/\n' > "$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -q -m ign
printf 'z\n' > "$M/pendientes/2026-10.md"; printf -- '- fila Z\n' >> "$M/_pendientes.md"
out=$(CC --memory-dir "$M" --solo-compartidos --mensaje "ign")
eq "entra lo no ignorado" "$(files "$R")" "memory/_pendientes.md "
rm "$R/.gitignore"; git -C "$R" add -A .gitignore; git -C "$R" commit -q -m unign

echo "== index.lock de otro proceso"
printf -- '- fila L\n' >> "$M/_pendientes.md"
touch "$R/.git/index.lock"; ( sleep 1; rm -f "$R/.git/index.lock" ) &
out=$(CC --memory-dir "$M" --solo-compartidos --mensaje "lock")
wait
has "espera al candado de git y commitea" "$out" "COMMIT hash="

echo "== casos en que no commitea"
out=$(CC --memory-dir "$TMP/no-hay" --solo-compartidos --mensaje x); has "sin memoria" "$out" "COMMIT skip=sin-memoria"
mkdir -p "$TMP/nogit/memory"; printf 'a\n' > "$TMP/nogit/memory/_p.md"
out=$(CC --memory-dir "$TMP/nogit/memory" --solo-compartidos --mensaje x); has "fuera de git" "$out" "COMMIT skip=sin-repo"
R2="$TMP/r2"; mkdir -p "$R2/memory"; git -C "$R2" init -q -b main; printf 'memory/\n' > "$R2/.gitignore"
git -C "$R2" add .gitignore; git -C "$R2" commit -q -m base; printf 'a\n' > "$R2/memory/_p.md"
out=$(CC --memory-dir "$R2/memory" --solo-compartidos --mensaje x); has "memory/ ignorada" "$out" "COMMIT skip=memoria-ignorada"
R3="$TMP/r3"; nuevo_repo "$R3"; git -C "$R3" checkout -q --detach; printf 'a\n' >> "$R3/memory/_pendientes.md"
out=$(CC --memory-dir "$R3/memory" --solo-compartidos --mensaje x); has "HEAD suelto" "$out" "COMMIT skip=head-suelto"
out=$(CC --memory-dir "$M" --session-file "$M/sessions/no-existe.md" --mensaje x); has "ficha inexistente" "$out" "COMMIT skip=sin-ficha"

echo "== worktree: la memoria del principal se commitea en el principal"
R4="$TMP/r4"; W4="$TMP/w4"; nuevo_repo "$R4"
git -C "$R4" worktree add -q "$W4" -b trabajo
MEM=$(bash "$BIN/memory-home.sh" --memory-dir "$W4")
eq "memory-home da la memoria del principal" "$MEM" "$R4/memory"
printf '# W\n' > "$MEM/sessions/2026-10-07-w.md"
out=$(cd "$W4" && CC --memory-dir "$MEM" --session-file "$MEM/sessions/2026-10-07-w.md" --mensaje "checkpoint: W")
has "commit en la rama del principal" "$out" "rama=main"
eq "la rama del worktree no recibe memoria" "$(git -C "$W4" log -1 --format=%s trabajo)" "base"

echo "== checkpoint-audit.py: git.commit_solo_propio y git.ficha_sin_commitear"
aud() { python3 - "$BIN" "$1" "$2" <<'PY'
import importlib.util, os, sys
BIN, M, F = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("ca", os.path.join(BIN, "checkpoint-audit.py"))
ca = importlib.util.module_from_spec(spec); spec.loader.exec_module(ca)
h = []
ca.git_memoria(h, M, F)
for x in h:
    print(x.estado, x.clave, x.detalle)
PY
}
R6="$TMP/r6"; nuevo_repo "$R6"; M6="$R6/memory"
printf '# A\n' > "$M6/sessions/a.md"
out=$(aud "$M6" "$M6/sessions/a.md")
has "ficha nunca commiteada: SALTADO" "$out" "SALTADO git.ficha_sin_commitear"
printf '# B a medias\n' > "$M6/sessions/b.md"
git -C "$R6" add -A memory && git -C "$R6" commit -q -m "barrido viejo"
out=$(aud "$M6" "$M6/sessions/a.md")
has "commit con la ficha de otra sesion: SALTADO" "$out" "SALTADO git.commit_solo_propio"
has "nombra cuantos" "$out" "1 archivo(s) de otras sesiones"
printf 'mas\n' >> "$M6/sessions/a.md"; printf 'mas\n' >> "$M6/sessions/b.md"; printf -- '- x\n' >> "$M6/_pendientes.md"
CC --memory-dir "$M6" --session-file "$M6/sessions/a.md" --mensaje ok >/dev/null
out=$(aud "$M6" "$M6/sessions/a.md")
has "commit por rutas: HECHO" "$out" "HECHO git.commit_solo_propio"
has "lo de otra sesion sucio: POR-DISEÑO, no se barre" "$out" "1 de otras sesiones"
printf 'hash\n' >> "$M6/sessions/a.md"
out=$(aud "$M6" "$M6/sessions/a.md")
has "el hash de 6c en la ficha: POR-DISEÑO" "$out" "1 propio(s) con cambios posteriores"

echo "== rutas con acentos (core.quotePath)"
R7="$TMP/r7"; mkdir -p "$R7/Migración/memory/sessions" "$R7/Migración/memory/plans"; git -C "$R7" init -q -b main
printf '# p\n' > "$R7/Migración/memory/_pendientes.md"; git -C "$R7" add -A; git -C "$R7" commit -q -m base
M7="$R7/Migración/memory"
printf '# A\n## Plans\n[[plans/plan-año]]\n' > "$M7/sessions/2026-10-07-diseño x.md"; printf 'p\n' > "$M7/plans/plan-año.md"
printf -- '- x\n' >> "$M7/_pendientes.md"
out=$(CC --memory-dir "$M7" --session-file "$M7/sessions/2026-10-07-diseño x.md" --mensaje acentos)
has "commitea" "$out" "archivos=3 propios=2 compartidos=1"
eq "nada queda en el indice ni sin commit" "$(git -C "$R7" status --porcelain)" ""

echo "== enlaces ../plans y markdown"
R8="$TMP/r8"; nuevo_repo "$R8"; M8="$R8/memory"
printf '# A\n## Plans\n- [[../plans/plan-x]]\n- [Z](../plans/plan-z.md)\n## Research\n- [[research/r-y|Y]]\n## Related\n- [[plans/plan-ajeno]]\n' > "$M8/sessions/a.md"
printf 'aj\n' > "$M8/plans/plan-ajeno.md"
printf 'x\n' > "$M8/plans/plan-x.md"; printf 'z\n' > "$M8/plans/plan-z.md"; printf 'y\n' > "$M8/research/r-y.md"
out=$(CC --memory-dir "$M8" --session-file "$M8/sessions/a.md" --listar)
has "[[../plans/plan-x]]" "$out" "propia plans/plan-x.md"
has "(../plans/plan-z.md)" "$out" "propia plans/plan-z.md"
has "[[research/r-y|Y]]" "$out" "propia research/r-y.md"
hasnt "un enlace fuera de ## Plans/## Research no hace propio el plan" "$out" "plan-ajeno"

echo "== otra ficha que CITA el plan de otra sesion no se lo lleva"
R10="$TMP/r10"; nuevo_repo "$R10"; M10="$R10/memory"
printf '# A\n## Plans\n- [[plans/plan-a]]\n' > "$M10/sessions/a.md"; printf 'a medias\n' > "$M10/plans/plan-a.md"
printf '# B\n## Cambios\n- ver tambien [[plans/plan-a]]\n' > "$M10/sessions/b.md"
out=$(CC --memory-dir "$M10" --session-file "$M10/sessions/b.md" --mensaje B)
hasnt "B no commitea el plan de A" "$(files "$R10")" "plan-a.md"

echo "== un commit que falla deja el indice como estaba"
R11="$TMP/r11"; nuevo_repo "$R11"; M11="$R11/memory"
printf '# S\n## Plans\n[[plans/plan-s]]\n' > "$M11/sessions/s.md"; printf 's\n' > "$M11/plans/plan-s.md"
printf 'ajena\n' > "$M11/sessions/otra.md"; git -C "$R11" add "$M11/sessions/otra.md"
printf '#!/bin/sh\nexit 1\n' > "$R11/.git/hooks/pre-commit"; chmod +x "$R11/.git/hooks/pre-commit"
out=$(CC --memory-dir "$M11" --session-file "$M11/sessions/s.md" --mensaje x)
has "pre-commit que rechaza: skip" "$out" "COMMIT skip=commit-fallo"
eq "solo queda en el indice lo que ya estaba (la de otra sesion)" "$(git -C "$R11" diff --cached --name-only)" "memory/sessions/otra.md"
rm "$R11/.git/hooks/pre-commit"
git -C "$R11" config commit.gpgsign true; git -C "$R11" config gpg.program false
out=$(CC --memory-dir "$M11" --session-file "$M11/sessions/s.md" --mensaje x)
has "firma que falla: skip" "$out" "COMMIT skip=commit-fallo"
eq "firma: el indice como estaba" "$(git -C "$R11" diff --cached --name-only)" "memory/sessions/otra.md"

echo "== merge a medias: no toca el indice"
R9="$TMP/r9"; nuevo_repo "$R9"; M9="$R9/memory"
git -C "$R9" checkout -q -b otra; printf 'o\n' >> "$R9/README.md"; git -C "$R9" commit -qam o
git -C "$R9" checkout -q main; printf 'm\n' >> "$R9/README.md"; git -C "$R9" commit -qam m
git -C "$R9" merge -q otra >/dev/null 2>&1
printf '# A\n' > "$M9/sessions/a.md"
out=$(CC --memory-dir "$M9" --session-file "$M9/sessions/a.md" --mensaje x)
has "se para" "$out" "COMMIT skip=operacion-en-curso"
hasnt "la ficha no entro al indice del merge" "$(git -C "$R9" status --porcelain)" "A  memory/sessions/a.md"

echo "== al fallar, el indice conserva el contenido que ya tenia (no el nuevo)"
R12="$TMP/r12"; nuevo_repo "$R12"; M12="$R12/memory"
printf -- '- preparado por otro\n' >> "$M12/_pendientes.md"; git -C "$R12" add "$M12/_pendientes.md"
blob_antes=$(git -C "$R12" ls-files -s memory/_pendientes.md | cut -d' ' -f2)
printf -- '- nuevo de este checkpoint\n' >> "$M12/_pendientes.md"; printf '# S\n' > "$M12/sessions/s.md"
printf '#!/bin/sh\nexit 1\n' > "$R12/.git/hooks/pre-commit"; chmod +x "$R12/.git/hooks/pre-commit"
out=$(CC --memory-dir "$M12" --session-file "$M12/sessions/s.md" --mensaje x)
eq "el blob preparado de _pendientes.md es el de antes" "$(git -C "$R12" ls-files -s memory/_pendientes.md | cut -d' ' -f2)" "$blob_antes"
eq "la ficha nueva no quedo en el indice" "$(git -C "$R12" ls-files memory/sessions/s.md)" ""

echo "== al fallar, no pisa lo que otro preparo DESPUES de nuestro add"
R14="$TMP/r14"; nuevo_repo "$R14"; M14="$R14/memory"
printf -- '- mio\n' >> "$M14/_pendientes.md"; printf '# S\n' > "$M14/sessions/s.md"
printf 'ajeno\n' > "$TMP/ajeno.md"
# El hook rechaza el commit; "otro proceso" prepara un cambio ajeno en el indice justo en el hueco
# entre el fallo y la restauracion (gancho de prueba _CHECKPOINT_COMMIT_ANTES_DE_DESHACER: una
# carrera real con un proceso de fondo pasaba en local y no se reproducia en CI).
printf '#!/bin/sh\nexit 1\n' > "$R14/.git/hooks/pre-commit"
chmod +x "$R14/.git/hooks/pre-commit"
b=$(git -C "$R14" hash-object -w "$TMP/ajeno.md")
out=$(_CHECKPOINT_COMMIT_ANTES_DE_DESHACER="git update-index --cacheinfo 100644,$b,memory/_pendientes.md" \
  CC --memory-dir "$M14" --session-file "$M14/sessions/s.md" --mensaje x)
has "skip" "$out" "COMMIT skip=commit-fallo"
eq "el cambio ajeno preparado sigue en el indice" "$(git -C "$R14" show :memory/_pendientes.md 2>/dev/null)" "ajeno"
eq "la ficha nueva (solo nuestra) salio del indice" "$(git -C "$R14" ls-files memory/sessions/s.md)" ""

echo "== candado del compactador ocupado: commitea y lo dice"
R13="$TMP/r13"; nuevo_repo "$R13"; M13="$R13/memory"
mkdir -p "$M13/.journal/.lock"; date +%s > "$M13/.journal/.lock/acquired_at"; echo otro > "$M13/.journal/.lock/owner"
printf -- '- y\n' >> "$M13/_pendientes.md"
out=$(CC --memory-dir "$M13" --solo-compartidos --mensaje x)
has "avisa" "$out" "AVISO candado-ocupado"
has "y commitea" "$out" "COMMIT hash="
hasnt "el candado ajeno no entra al commit" "$(files "$R13")" ".lock"

echo "== ninguna plantilla barre memory/ (por construccion)"
PLUG="$(dirname "$BIN")"
barre=$(grep -nE '^[[:space:]]*git (add (-A|\.|memory/?)([[:space:]]|$)|commit( -[a-z]+)* -m)' "$PLUG"/templates/*.md "$PLUG"/commands/*.md | grep -v -- '--only' || true)
eq "sin git add memory/ ni git commit sin rutas" "$barre" ""

echo "== la ficha a medias de otra sesion, en 100 ordenes al azar"
# Tres sesiones intercalan: escribir ficha (a medias), terminarla, commitear. Ningun commit debe
# traer la ficha de otra.
R5="$TMP/r5"; nuevo_repo "$R5"; M5="$R5/memory"
python3 - "$BIN" "$M5" <<'PY' && ok "100 ordenes: ningun commit con fichas o planes ajenos" || bad "hubo ajenos"
import os, random, subprocess, sys
BIN, M = sys.argv[1], sys.argv[2]
R = os.path.dirname(M)
mal = 0
for semilla in range(100):
    rng = random.Random(semilla)
    pasos = []
    for n in "ABC":
        pasos += [(n, "plan"), (n, "ficha1"), (n, "ficha2"), (n, "commit"), (n, "cola")]
    # orden barajado respetando el orden de cada sesion
    colas = {n: [p for p in pasos if p[0] == n] for n in "ABC"}
    while any(colas.values()):
        n = rng.choice([k for k, v in colas.items() if v])
        _, p = colas[n].pop(0)
        ficha = os.path.join(M, "sessions", f"s{semilla}-{n}.md")
        if p == "plan":
            open(os.path.join(M, "plans", f"plan-{semilla}-{n}.md"), "w").write(f"plan {n}\n")
        elif p == "ficha1":
            open(ficha, "w").write(f"# {n}\n## Plans\n[[plans/plan-{semilla}-{n}]]\n## Cambios\n")
            with open(os.path.join(M, "_pendientes.md"), "a") as f:
                f.write(f"- {semilla} {n}\n")
        elif p == "ficha2":
            open(ficha, "a").write("resto\n")
        elif p in ("commit", "cola"):
            if p == "cola":
                open(ficha, "a").write("## Como retomar\n")
            out = subprocess.run([sys.executable, os.path.join(BIN, "checkpoint-commit.py"), "--memory-dir", M,
                                  "--session-file", ficha, "--mensaje", f"{p} {n}"],
                                 capture_output=True, text=True).stdout
            if "COMMIT hash=" in out:
                names = subprocess.run(["git", "-C", R, "show", "--name-only", "--format=", "HEAD"],
                                       capture_output=True, text=True).stdout.split()
                for x in names:
                    if (x.startswith("memory/sessions/") or x.startswith("memory/plans/")) and f"{semilla}-{n}" not in x:
                        mal += 1
                        print("AJENO", semilla, n, x)
    st = subprocess.run(["git", "-C", R, "status", "--porcelain", "--", "memory/sessions", "memory/plans"],
                        capture_output=True, text=True).stdout
    if st.strip():
        mal += 1
        print("VARADO", semilla, st)
sys.exit(1 if mal else 0)
PY

[ "$FAIL" = 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit "$FAIL"
