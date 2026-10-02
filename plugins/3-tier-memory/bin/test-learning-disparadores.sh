#!/bin/bash
# Prueba de los disparadores de una regla (2.48.0, F4 del plan de ciclo de vida de learnings).
#
# Por que existe: el recall es lexico y sin dependencias (H13), asi que una parafrasis del momento
# del error solo encuentra la regla si sus palabras estan en ella. F4 deja que quien escribe la
# regla anada, una vez, frases de como describiria ese momento alguien que NO la conoce, en la
# MISMA linea (I2), como comentario HTML al final:
#
#   N. **Regla** — cuerpo[ — ⊘ RETIRADA (...)] <!-- disparadores: frases=a | b | c; cmd=x; tool=Bash -->
#
# Lo que este fichero vigila:
# 1. IDA Y VUELTA. add --disparadores -> update --text (los conserva) -> update --disparadores
#    (los cambia, sin tocar el texto) -> retire (el marcador va DELANTE del comentario) -> update
#    del texto de la retirada (conserva marcador y comentario, en ese orden). Cada replay: nada.
# 2. NADA ROTO EN LA LINEA. El emisor rechaza disparadores que cortarian el comentario HTML (`--`,
#    `<`, `>`), frases fuera de 3-6 y un comentario pegado a --text; el compactador, que es su
#    propia frontera de confianza, manda a cuarentena el mismo payload escrito a mano.
# 3. EL RECALL. El indice indexa las frases (kw_disparadores) y no muestra el comentario; una
#    consulta con palabras que solo estan en las frases encuentra la regla, y el peso de esas
#    palabras (recall_rank.PESO_DISPARADORES) decide un empate que sin el lo gana otra regla.
# 4. LOS VECINOS Y LA IDENTIDAD. El comentario no cuenta para el parecido (learning_vecinos) ni para
#    "es la misma regla" (un add con el mismo texto no la escribe dos veces).
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }
hasnt() { if printf '%s' "$2" | grep -q -- "$3"; then fail=$((fail+1)); echo "  FALLA $1: no esperaba '$3' en '$2'"; else pass=$((pass+1)); echo "  ok  $1"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@" >/dev/null; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
motivo() { cat "$M/.journal/quarantine"/*.reason 2>/dev/null | tr '\n' ' '; }
# Replay = el compactador vuelve a ver los eventos del ULTIMO paso (los que estaban en vuelo). No se
# reinyecta toda la historia: un learning.add viejo cuyo texto corrigio despues un learning.update
# se volveria a insertar, con o sin disparadores (es la semantica del add, no de F4).
paso() { ls "$M"/.journal/applied/*/*.json 2>/dev/null | sort > "$T/antes"; }
replay() { ls "$M"/.journal/applied/*/*.json | sort | comm -13 "$T/antes" - | while read -r f; do cp "$f" "$M/.journal/pending/"; done; }
regla() { grep -E "^$1\. " "$M/learnings/gate.md" || true; }
huella() { cat "$M/learnings/gate.md" "$M/_learnings.md" | cksum; }
indice() { python3 "$BIN/build-recall-index.py" "$M" "$T/idx.jsonl" >/dev/null; }
recall() { RECALL_INDEX="$T/idx.jsonl" RECALL_PROMPT="$1" python3 "$BIN/recall_rank.py"; }

D1="frases=ya termine la rama y limpio el worktree | git worktree remove se queja de cambios | cleanup de carpetas viejas antes de seguir; cmd=git worktree remove; tool=Bash"
D2="frases=borro la carpeta del worktree a mano | el worktree tiene commits sin publicar | limpieza de ramas temporales; cmd=git worktree remove, git branch; path=.claude/worktrees/*; tool=Bash, Edit"
C1=' <!-- disparadores: frases=ya termine la rama y limpio el worktree | git worktree remove se queja de cambios | cleanup de carpetas viejas antes de seguir; cmd=git worktree remove; tool=Bash -->'
C2=' <!-- disparadores: frases=borro la carpeta del worktree a mano | el worktree tiene commits sin publicar | limpieza de ramas temporales; cmd=git worktree remove, git branch; path=.claude/worktrees/*; tool=Bash, Edit -->'

fixture() {
  rm -rf "$M"; mkdir -p "$M/learnings"
  : > "$M/_pendientes.md"
  cat > "$M/_learnings.md" <<'IDX'
---
type: index
updated: 2026-01-01
---
# Learnings Index

## Topic Files

| Topic | File | When to consult |
|---|---|---|
| Gate | [[learnings/gate]] | siempre |

## Quick Reference

1. **Uno corto** — a

## Related
IDX
  cat > "$M/learnings/gate.md" <<'TOP'
---
type: learnings
topic: gate
updated: 2026-01-01
---
# Gate

## Rules

1. **Nunca empujar sin la fila del ledger** — el required check la lee desde main
2. **El clon se limpia con reset** — antiguo

## Related
- [[_learnings|Learnings Index]]
TOP
}

paso 2>/dev/null || true
echo "== 1. add --disparadores: comentario canonico al final; stdout solo el id; replay = nada =="
fixture
out=$(emit --type learning.add --topic gate --text "**No borres un worktree con cambios sin publicar** — remove --force tira commits" \
  --disparadores "frases=ya termine la rama y limpio el worktree|git worktree remove se queja de cambios |  cleanup de carpetas viejas antes de seguir ;cmd=git worktree remove;tool=Bash" --decision nueva 2>"$T/err")
has "stdout es el id" "$out" "^l-"
hasnt "sin aviso de disparadores" "$(cat "$T/err")" "AVISO"
compact
chk "regla 3 = texto + comentario canonico" "3. **No borres un worktree con cambios sin publicar** — remove --force tira commits$C1" "$(regla 3)"
h=$(huella); replay; compact
chk "replay del add: no escribe" "$h" "$(huella)"
chk "replay del add: sin cuarentena" "0" "$(cuar)"

echo "== 2. add sin --disparadores: escribe y no avisa (opcionales desde el cierre de F4) =="
out=$(emit --type learning.add --topic gate --text "**Otra leccion sin frases** — cuerpo" --decision nueva 2>"$T/err")
has "stdout es el id" "$out" "^l-"
hasnt "sin aviso por stderr" "$(cat "$T/err")" "disparadores"
compact
chk "regla 4 sin comentario" "4. **Otra leccion sin frases** — cuerpo" "$(regla 4)"

echo "== 3. el emisor rechaza disparadores que romperian la linea =="
for malo in "frases=a b c | d e f" "frases=uno | dos | tres; cmd=git commit --amend" "frases=uno | dos | tres; cmd=a<b" \
            "frases=uno | dos | tres; otra=x" "cmd=git push" "frases=a | b | c | d | e | f | g" "frases=uno || dos | tres"; do
  set +e; emit --type learning.add --topic gate --text "**Rechazo** — x" --decision nueva --disparadores "$malo" >/dev/null 2>"$T/err"; rc=$?; set -e
  chk "rechaza '$malo' (rc)" "1" "$rc"
done
set +e; emit --type learning.add --topic gate --text "**Pegado** — x$C1" --decision nueva >/dev/null 2>"$T/err"; rc=$?; set -e
chk "rechaza el comentario pegado a --text" "1" "$rc"
set +e; emit --type learning.add --topic gate --disparadores "$D1" >/dev/null 2>"$T/err"; rc=$?; set -e
chk "rechaza --disparadores sin --text" "1" "$rc"
chk "nada quedo pendiente" "0" "$(ls "$M/.journal/pending" | wc -l | tr -d ' ')"

paso 2>/dev/null || true
echo "== 4. update --text sin disparadores: conserva los que tenia; replay = nada =="
emit --type learning.update --topic gate --match-prefix "No borres un worktree" \
  --text "**No borres un worktree con commits sin publicar** — remove --force tira commits que no estan en ningun remoto" >/dev/null
compact
chk "texto nuevo + mismo comentario" "3. **No borres un worktree con commits sin publicar** — remove --force tira commits que no estan en ningun remoto$C1" "$(regla 3)"
h=$(huella); replay; compact
chk "replay: no escribe" "$h" "$(huella)"; chk "replay: sin cuarentena" "0" "$(cuar)"
paso 2>/dev/null || true
echo "== 5. update --disparadores sin --text: cambia solo el comentario; replay = nada =="
emit --type learning.update --topic gate --match-prefix "No borres un worktree" --disparadores "$D2" >/dev/null
compact
chk "mismo texto + comentario nuevo" "3. **No borres un worktree con commits sin publicar** — remove --force tira commits que no estan en ningun remoto$C2" "$(regla 3)"
emit --type learning.update --topic gate --match-prefix "El clon se limpia" --disparadores "$D1" >/dev/null
compact
chk "enriquece una regla vieja sin comentario" "2. **El clon se limpia con reset** — antiguo$C1" "$(regla 2)"
h=$(huella); replay; compact
chk "replay: no escribe" "$h" "$(huella)"; chk "replay: sin cuarentena" "0" "$(cuar)"
set +e; emit --type learning.update --topic gate --match-prefix "El clon" >/dev/null 2>&1; rc=$?; set -e
chk "--match-prefix solo: rechazado" "1" "$rc"

paso 2>/dev/null || true
echo "== 6. retire de una regla enriquecida: el marcador va DELANTE del comentario =="
emit --type learning.retire --topic gate --match-prefix "El clon se limpia" --motivo obsoleta --nota "ya no aplica" >/dev/null
compact
chk "cuerpo + marcador + comentario" "2. **El clon se limpia con reset** — antiguo — ⊘ RETIRADA ($(date +%F), obsoleta): ya no aplica$C1" "$(regla 2)"
emit --type learning.update --topic gate --match-prefix "El clon se limpia" --text "**El clon se limpia con git reset --hard** — antiguo" >/dev/null
compact
chk "update de la retirada: texto + marcador + comentario" "2. **El clon se limpia con git reset --hard** — antiguo — ⊘ RETIRADA ($(date +%F), obsoleta): ya no aplica$C1" "$(regla 2)"
h=$(huella); replay; compact
chk "replay de todo: no escribe" "$h" "$(huella)"; chk "replay: sin cuarentena" "0" "$(cuar)"
indice
chk "la retirada enriquecida no entra al indice" "0" "$(grep -c 'El clon se limpia' "$T/idx.jsonl" | tr -d ' ')"

echo "== 7. add --supersedes sobre una regla enriquecida: marca delante del comentario =="
emit --type learning.add --topic gate --text "**Un worktree solo se borra tras publicar su rama** — git worktree remove sin --force" \
  --supersedes 3 --disparadores "$D1" >/dev/null 2>&1
compact
chk "la 3 queda marcada, comentario al final" "3. **No borres un worktree con commits sin publicar** — remove --force tira commits que no estan en ningun remoto — ⊘ RETIRADA ($(date +%F), superada por #5)$C2" "$(regla 3)"
chk "la 5 nueva con su comentario" "5. **Un worktree solo se borra tras publicar su rama** — git worktree remove sin --force$C1" "$(regla 5)"

echo "== 8. el compactador es su propia frontera: payload a mano invalido -> cuarentena =="
for payload in '{"topic":"gate","text":"**X** — y","disparadores":"frases=a | b"}' \
               '{"topic":"gate","match_prefix":"Nunca empujar","disparadores":"frases=uno | dos | tres; cmd=a --b"}' \
               '{"topic":"gate","disparadores":"frases=uno | dos | tres"}'; do
  fixture
  tipo=learning.add; case "$payload" in *match_prefix*|'{"topic":"gate","disparadores"'*) tipo=learning.update;; esac
  mkdir -p "$M/.journal/pending"
  printf '{"v":1,"type":"%s","ts":1,"session":"t","payload":%s}\n' "$tipo" "$payload" > "$M/.journal/pending/1-a-1-0.json"
  h=$(huella); compact
  chk "$tipo invalido: cuarentena" "1" "$(cuar)"; has "$tipo invalido: motivo malformed" "$(motivo)" "malformed"
  chk "$tipo invalido: nada escrito" "$h" "$(huella)"
done

echo "== 9. recall: frases indexadas con peso, comentario fuera de la salida =="
fixture
cat > "$M/learnings/gate.md" <<'TOP'
---
type: learnings
topic: gate
---
# Gate

## Rules

1. **Regla del cuerpo** — el despliegue nocturno falla con zapatilla
2. **Regla de frases** — otra cosa distinta <!-- disparadores: frases=el despliegue nocturno con zapatilla | aaa bbb ccc | ddd eee fff; tool=Bash -->
3. **Regla con comentario roto** — algo <!-- disparadores: frases=solo dos | frases -->

## Related
TOP
indice
python3 - "$T/idx.jsonl" > "$T/u.txt" <<'EOF'
import json, sys
for l in open(sys.argv[1], encoding="utf-8"):
    u = json.loads(l)
    if u.get("regla"):
        print(u["texto"], "|", " ".join(u.get("kw_disparadores", [])))
EOF
u=$(cat "$T/u.txt")
hasnt "el texto de la unidad no lleva el comentario" "$u" "disparadores:"
has "kw_disparadores con las palabras nuevas de las frases" "$u" "Regla de frases.*aaa bbb ccc ddd eee fff"
hasnt "comentario invalido: sin kw_disparadores" "$(grep 'comentario roto' "$T/u.txt")" "| [a-z]"
out=$(recall "despliegue nocturno zapatilla")
hasnt "la salida del recall no muestra el comentario" "$out" "disparadores"
primera=$(printf '%s\n' "$out" | sed -n 2p)
has "con peso, la regla de las frases gana el empate" "$primera" "Regla de frases"
out=$(recall "aaa bbb ccc")
has "palabras solo de las frases encuentran la regla" "$out" "Regla de frases"
out=$(recall "zapatílla nocturnó")
has "acentos plegados: una consulta con acento encuentra la regla sin el" "$out" "Regla del cuerpo"

echo "== 10. vecinos e identidad ignoran el comentario =="
fixture
emit --type learning.add --topic gate --text "**Nunca empujar sin la fila del ledger** — el required check la lee desde main" \
  --disparadores "$D1" --decision nueva >/dev/null 2>"$T/err"
compact
chk "mismo texto que la 1: no se escribe otra regla" "" "$(regla 3)"
python3 - "$BIN" > "$T/v.txt" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1]); sys.dont_write_bytecode = True
import learning_vecinos as lv
c = " <!-- disparadores: frases=zzz yyy xxx | www vvv uuu | ttt sss rrr -->"
a = lv.vecinos("**Regla** — texto comun", [("#1", "**Regla** — texto comun" + c)], k=1)
print(f"{a[0][0]:.3f}")
EOF
chk "parecido 1.0 con y sin comentario" "1.000" "$(cat "$T/v.txt")"

echo "== 11. indice: Quick Reference numerado (H5) =="
fixture
cat > "$M/learnings/gate.md" <<'TOP'
---
type: learnings
topic: gate
---
# Gate

## Rules

1. **Regla numerada** — alfa
- **Vineta de la region** — bravo charlie
  - subvineta sangrada delta
```
- vineta dentro de codigo echo
```
- **Vineta retirada** — foxtrot — ⊘ RETIRADA (2026-01-01, obsoleta)

## Related
- [[_learnings|Learnings Index]] golf
TOP
cat > "$M/_learnings.md" <<'IDX'
# Learnings Index

## Quick Reference

1. **Regla numerada** — version corta hotel
2. **Solo en el Quick Reference** — india juliet
- **Vineta del Quick Reference** — kilo

## Related
IDX
indice
textos=$(python3 -c "import json,sys;[print(json.loads(l)['texto']) for l in open(sys.argv[1],encoding='utf-8') if json.loads(l)['tipo']=='learning']" "$T/idx.jsonl")
has "Quick Reference N. con titulo propio: entra" "$textos" "Solo en el Quick Reference"
hasnt "Quick Reference N. con el titulo de una regla: se salta" "$textos" "version corta hotel"
has "Quick Reference con vineta: entra (como antes)" "$textos" "Vineta del Quick Reference"

echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
