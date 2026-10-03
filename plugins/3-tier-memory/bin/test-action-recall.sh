#!/bin/bash
# Pruebas del recall en el momento de la accion (bin/action-recall.sh + bin/action_match.py, F5 del
# plan de ciclo de vida de learnings).
#
# Monta un proyecto con una memoria sintetica, construye el indice con build-recall-index.py (el
# mismo constructor que usa recall.sh) en un HOME temporal y llama al hook con el JSON de
# PreToolUse por stdin. Comprueba:
#   1. fallos en abierto (I6): stdin vacio, JSON roto, indice ausente o corrupto, directorio de
#      estado sin permiso de escritura -> salida 0, vacia, sin deny;
#   2. nivel aviso: `git commit` con la regla `cmd=git commit` inyecta; el JSON es valido y solo
#      lleva hookSpecificOutput.additionalContext; `git status` no inyecta;
#   3. nivel freno: regla `freno=si` -> deny con permissionDecisionReason y sin additionalContext;
#      repetido con `# regla-vista:<id>` pasa y no vuelve a frenar;
#   4. deduplicacion por sesion (30 llamadas), tope de 2 reglas y de 1.500 caracteres;
#   5. el comando se parte bien: sudo/env/X=Y/rtk/palabras de shell fuera, `&&` y `|` separan;
#   6. Edit/Write casan por `path` (fragmento o desde la raiz) y nunca frenan;
#   7. via rapida con el indice vacio, el indice excluye las retiradas, y journal-guard.sh conserva
#      su deny cuando los dos hooks corren sobre la misma llamada.
#
# Uso: bash bin/test-action-recall.sh   (sin dependencias; sale != 0 si algo falla)
# Alcance: prueba el HOOK, no que Claude Code honre el deny ni que el aviso llegue al modelo. Eso lo
# miden bin/verify-hook-delivery.sh y la prueba con claude -p de la ficha de F5.

set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
HOOK="$BIN/action-recall.sh"
TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
P="$TMP/proj"; H="$TMP/home"
mkdir -p "$P/memory/learnings" "$P/docs" "$H"
printf -- '---\ntype: index\n---\n# Pendientes\n' > "$P/memory/_pendientes.md"
LARGO=$(python3 -c "print('palabra ' * 400)")
{
  printf -- '---\nimportance: 7\n---\n# Git\n\n## Rules\n\n'
  printf '1. **No hagas git commit con el revisor vivo** — aborta la ronda. <!-- disparadores: frases=a | b | c; cmd=git commit -->\n'
  printf '2. **No hagas git push sin el veredicto** — el gate lo niega. <!-- disparadores: frases=a | b | c; cmd=git push; freno=si -->\n'
  printf '3. **Las notas de docs van en espanol** — sin mezclar. <!-- disparadores: frases=a | b | c; path=docs/*.md; freno=si -->\n'
  printf '4. **Regla general de git** — muchos comandos. <!-- disparadores: frases=a | b | c; cmd=git commit, git status, git diff -->\n'
  printf '5. **Una regla larga** — %s <!-- disparadores: frases=a | b | c; cmd=git commit, git log -->\n' "$LARGO"
  printf '6. **Regla retirada** — ya no aplica — ⊘ RETIRADA (2026-10-01, obsoleta): x <!-- disparadores: frases=a | b | c; cmd=git commit -->\n'
  printf '7. **Sin disparadores de accion** — solo frases. <!-- disparadores: frases=a | b | c -->\n'
  printf '8. **El timeout de coreutils no existe en macOS** — usa gtimeout. <!-- disparadores: frases=a | b | c; cmd=timeout -->\n'
  printf '9. **Los tests en bash usan set -u** — siempre. <!-- disparadores: frases=a | b | c; cmd=bash; path=bin/test-*.sh -->\n'
} > "$P/memory/learnings/git.md"
ENC=$(echo "$P" | sed 's/[^A-Za-z0-9]/-/g')
SD="$H/.claude/projects/$ENC"
mkdir -p "$SD"
build() { HOME="$H" python3 "$BIN/build-recall-index.py" "$P/memory" "$SD/.recall-index.jsonl" >/dev/null; }
build

PASS=0; FAIL=0; ERR="$TMP/stderr"; SID=s1
ok()   { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/         /'; }
# llamada con un JSON ya armado -> OUT; falla si muere o escribe en stderr
raw() {
  : > "$ERR"
  OUT=$(printf '%s' "$1" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$HOOK" 2>"$ERR"); RC=$?
  [ "$RC" -eq 0 ] && [ ! -s "$ERR" ]
}
bash_() { raw "$(python3 -c 'import json,sys;print(json.dumps({"session_id":sys.argv[2],"cwd":sys.argv[3],"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" "$SID" "$P")"; }
edit_() { raw "$(python3 -c 'import json,sys;print(json.dumps({"session_id":sys.argv[3],"cwd":sys.argv[4],"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"content":"x"}}))' "$1" "$2" "$SID" "$P")"; }
# forma: aviso = JSON valido con SOLO hookEventName + additionalContext; freno = deny + motivo, sin aviso
forma() { printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read()); h = d["hookSpecificOutput"]
assert set(d) == {"hookSpecificOutput"}, d
if sys.argv[1] == "aviso":
    assert set(h) == {"hookEventName", "additionalContext"}, h
else:
    assert set(h) == {"hookEventName", "permissionDecision", "permissionDecisionReason"}, h
    assert h["permissionDecision"] == "deny"
assert h["hookEventName"] == "PreToolUse"
' "$1" 2>/dev/null; }
ids() { printf '%s' "$OUT" | grep -o '\[git#[0-9]*\]' | tr -d '[]' | tr '\n' ' '; }
nueva() { SID="$1"; }

echo "1. fallos en abierto (I6): salida 0, vacia, sin deny"
raw "" && [ -z "$OUT" ] && ok || fail "stdin vacio: '$OUT'" "$(cat "$ERR")"
raw '{"tool_name": "Bash", "tool_input": {"command": "git push"' && [ -z "$OUT" ] && ok || fail "JSON roto: '$OUT'"
raw '[1,2,3]' && [ -z "$OUT" ] && ok || fail "JSON que no es objeto: '$OUT'"
mv "$SD/.action-index.json" "$TMP/idx.bak"
nueva s-sin; bash_ "git push" && [ -z "$OUT" ] && ok || fail "indice ausente: '$OUT'"
printf '{"reglas": [ roto' > "$SD/.action-index.json"
bash_ "git push" && [ -z "$OUT" ] && ok || fail "indice corrupto: '$OUT'"
printf '{"reglas": "no es lista"}' > "$SD/.action-index.json"
bash_ "git push" && [ -z "$OUT" ] && ok || fail "indice con forma rara: '$OUT'"
mv "$TMP/idx.bak" "$SD/.action-index.json"
chmod a-w "$SD"
# En Git Bash (Windows) y como root, chmod no quita la escritura: ahi el caso no es evaluable.
if ( : > "$SD/.sonda" ) 2>/dev/null; then
  rm -f "$SD/.sonda"; echo "  SKIP estado sin permiso de escritura (chmod a-w no impide escribir aqui)"
else
  nueva s-ro; bash_ "git push" && [ -z "$OUT" ] && ok || fail "estado sin permiso de escritura: '$OUT'"
fi
chmod u+w "$SD"
raw '{"session_id":"x","tool_name":"Read","tool_input":{"file_path":"/x"}}' && [ -z "$OUT" ] && ok || fail "herramienta fuera del matcher: '$OUT'"

echo "2. nivel aviso"
nueva s2
bash_ "git commit -m 'x'" && forma aviso && ok || fail "git commit: no es un aviso valido: '$OUT'"
case "$(ids)" in "git#1 git#5 ") ok ;; *) fail "git commit: orden esperado git#1 (1 valor) git#5 (2 valores) antes que git#4 (3), salio '$(ids)'" ;; esac
printf '%s' "$OUT" | grep -q 'git#6' && fail "sirvio la regla retirada" || ok
printf '%s' "$OUT" | grep -q 'match-prefix' && printf '%s' "$OUT" | grep -q 'learning.retire' && ok || fail "sin pie de retirada (F2): '$OUT'"
printf '%s' "$OUT" | grep -q 'disparadores:' && fail "el texto servido lleva el comentario de disparadores" || ok
nueva s2b; bash_ "git status" && [ -z "$(ids | grep -v 'git#4')" ] && ok || fail "git status: solo puede casar git#4, salio '$(ids)'"
nueva s2c; bash_ "git stash" && [ -z "$OUT" ] && ok || fail "git stash no casa con nada: '$OUT'"
nueva s2d; bash_ "echo git commit" && [ -z "$OUT" ] && ok || fail "'echo git commit' no es un git commit: '$OUT'"

echo "3. nivel freno"
nueva s3
bash_ "git push origin main" && forma freno && ok || fail "git push: no es un deny valido: '$OUT'"
printf '%s' "$OUT" | grep -q 'regla-vista:git#2' && ok || fail "el motivo no dice como seguir: '$OUT'"
bash_ "git push origin main # regla-vista:git#2" && ! printf '%s' "$OUT" | grep -q deny && ok || fail "con regla-vista sigue frenando: '$OUT'"
bash_ "git push origin main" && ! printf '%s' "$OUT" | grep -q deny && ok || fail "despues de verla, vuelve a frenar: '$OUT'"
nueva s3b; bash_ "git push # regla-vista:git#2" && ! printf '%s' "$OUT" | grep -q deny && ok || fail "regla-vista en la primera llamada frena: '$OUT'"
nueva s3c; bash_ "git push" >/dev/null; bash_ "git push" && ! printf '%s' "$OUT" | grep -q deny && ok || fail "el freno se repite sin regla-vista (debe frenar una sola vez por sesion): '$OUT'"

echo "4. deduplicacion, tope de reglas y de caracteres"
nueva s4
bash_ "git commit" >/dev/null
bash_ "git commit" && [ "$(ids)" = "git#4 " ] && ok || fail "2.a llamada: esperaba solo git#4 (git#1 y git#5 ya se vieron), salio '$(ids)'"
bash_ "git commit" && [ -z "$OUT" ] && ok || fail "3.a llamada: todas vistas, esperaba silencio: '$OUT'"
for i in $(seq 1 26); do bash_ "ls" >/dev/null; done   # llamadas 4..29
bash_ "git commit" && [ -z "$OUT" ] && ok || fail "llamada 30 desde la primera: aun dentro de la ventana: '$OUT'"
bash_ "git commit" && [ -n "$(ids)" ] && ok || fail "llamada 31: la ventana paso, esperaba repetir: '$OUT'"
# El constructor recorta cada texto a 240 caracteres, asi que con su indice el tope no muerde: se
# prueba con un indice escrito a mano, dos reglas de 1.000 caracteres (el tope protege del indice,
# no del constructor).
cp "$SD/.action-index.json" "$TMP/idx.bak"
python3 -c "
import json, sys
t = 'x' * 1000
json.dump({'reglas': [{'id': 'l#1', 'topic': 'l', 'n': 1, 'texto': t, 'cmd': ['git log'], 'path': [], 'freno': False, 'ancla': 'x'},
                      {'id': 'l#2', 'topic': 'l', 'n': 2, 'texto': t, 'cmd': ['git log'], 'path': [], 'freno': False, 'ancla': 'x'}]},
          open(sys.argv[1], 'w'))" "$SD/.action-index.json"
nueva s4b; bash_ "git log" && N=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]))') && [ "$N" -le 1500 ] && [ "$N" -gt 1000 ] && ok || fail "tope de 1.500 caracteres: $N"
cp "$TMP/idx.bak" "$SD/.action-index.json"
nueva s4c; bash_ "git commit" && [ "$(ids | wc -w | tr -d ' ')" -le 2 ] && ok || fail "mas de 2 reglas: '$(ids)'"

echo "5. el comando se parte bien"
for c in "sudo git push" "sudo -u root git push" "env A=1 git push" "A=1 B=2 git push" "rtk git push" \
         "rtk proxy git push" "cd x && git push" "git add . ; git push" "true || git push" \
         "while true; do git push; done" "time git push" "/usr/bin/git push" "(git push)"; do
  nueva "s5-$c"; bash_ "$c" && printf '%s' "$OUT" | grep -q deny && ok || fail "'$c' deberia casar git push: '$OUT'"
done
nueva s5x; bash_ "timeout 60 ls" && [ "$(ids)" = "git#8 " ] && ok || fail "timeout: '$(ids)'"
nueva s5y; bash_ "bash bin/test-x.sh" && [ "$(ids)" = "git#9 " ] && ok || fail "bash: '$(ids)'"
nueva s5z; bash_ "python3 /x/y/timeout --help" && [ "$(ids)" = "git#8 " ] && ok || fail "interprete->script: '$(ids)'"
nueva s5w; bash_ "grep -n 'git push' x.txt" && [ -z "$OUT" ] && ok || fail "'git push' como argumento de grep no casa: '$OUT'"

echo "6. Edit/Write por path, nunca frenan"
nueva s6; edit_ Write "$P/docs/guia.md" && forma aviso && [ "$(ids)" = "git#3 " ] && ok || fail "docs/*.md (freno=si) en Write: aviso, no deny: '$OUT'"
nueva s6b; edit_ Edit "$P/plugins/x/bin/test-y.sh" && [ "$(ids)" = "git#9 " ] && ok || fail "fragmento bin/test-*.sh bajo una subcarpeta: '$(ids)'"
nueva s6c; edit_ Edit "/otro/sitio/docs/a.md" && [ "$(ids)" = "git#3 " ] && ok || fail "ruta fuera del proyecto, por sufijo: '$(ids)'"
nueva s6d; edit_ Edit "$P/src/a.md" && [ -z "$OUT" ] && ok || fail "src/a.md no casa: '$OUT'"
nueva s6e; edit_ MultiEdit "$P/docs/b.md" && [ "$(ids)" = "git#3 " ] && ok || fail "MultiEdit: '$(ids)'"

echo "7. indice: via rapida, retiradas fuera, convivencia con journal-guard"
python3 -c "import json,sys;d=json.load(open(sys.argv[1]));ids=[r['id'] for r in d['reglas']];sys.exit(0 if 'git#6' not in ids and 'git#7' not in ids and 'git#1' in ids else 1)" "$SD/.action-index.json" && ok || fail "el indice incluye la retirada o la regla sin cmd/path"
cp "$SD/.action-index.json" "$TMP/idx.bak"; printf '{"reglas": []}\n' > "$SD/.action-index.json"
nueva s7; bash_ "git push" && [ -z "$OUT" ] && ok || fail "indice vacio: '$OUT'"
cp "$TMP/idx.bak" "$SD/.action-index.json"
printf 'journal_strict=1\n' > "$P/memory/.memory-config"
J='{"session_id":"g","cwd":"'"$P"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$P"'/memory/_pendientes.md","content":"x"}}'
SOLO=$(printf '%s' "$J" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$BIN/journal-guard.sh" 2>/dev/null)
raw "$J"; JUNTOS=$(printf '%s' "$J" | HOME="$H" CLAUDE_PROJECT_DIR="$P" bash "$BIN/journal-guard.sh" 2>/dev/null)
printf '%s' "$SOLO" | grep -q '"permissionDecision": "deny"' && [ "$SOLO" = "$JUNTOS" ] && ! printf '%s' "$OUT" | grep -q deny && ok \
  || fail "journal-guard pierde o cambia su deny junto a action-recall: guard='$SOLO' action='$OUT'"
rm -f "$P/memory/.memory-config"
# hooks.json no esta en la copia de bin/ que usa tools/mutation-check.sh: ahi no es evaluable.
if [ ! -f "$BIN/../hooks/hooks.json" ]; then
  echo "  SKIP hooks.json registra action-recall.sh (no hay hooks/ junto a bin/)"
else python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
hs=[h['command'] for e in d['hooks']['PreToolUse'] if e['matcher']=='Bash|Edit|Write|MultiEdit' for h in e['hooks']]
sys.exit(0 if any('action-recall.sh' in c for c in hs) else 1)" "$BIN/../hooks/hooks.json" && ok || fail "hooks.json no registra action-recall.sh en PreToolUse Bash|Edit|Write|MultiEdit"
fi

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
