#!/bin/bash
# Prueba de `learning.retire` y `learning.add --supersedes` (2.45.0, F2 del plan de ciclo de vida
# de learnings), y de los lectores que respetan el marcador.
#
# Por que existe: hasta 2.45.0 una regla vencida no tenia salida. `learning.update` la podia
# reescribir, pero ningun lector distinguia una regla marcada: el recall devolvia la retirada junto
# a la vigente (medido: la 135 de un corpus real salia con la 99 que la duplicaba, y con frases del
# incidente salia SOLA). Lo que este fichero vigila:
#
# 1. EL NUMERO SE CONSERVA (I1). Retirar es marcar la linea, nunca borrarla ni renumerar.
# 2. REPLAY = NOOP (I3), tambien el de un learning.update sobre una regla ya retirada, cuya linea
#    termina en el marcador y no en el texto que trae el evento.
# 3. NADA A MEDIAS. `--supersedes` escribe la nueva y marca la vieja en el MISMO escrito; una
#    cuarentena (por --por, por el Quick Reference o por una regla de varias lineas) no deja nada
#    escrito.
# 4. LOS LECTORES. El indice de recall (y por el find-dup-candidates) no sirve una regla retirada,
#    ni con el marcador nuevo ni con las dos formas viejas del corpus real, y un topic con la
#    cabecera retirada no entra. Una regla que solo CITA el marcador (entre comillas invertidas o
#    sin el `—` delante) sigue viva: es el control.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }

M="$T/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" "$@"; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
motivo() { cat "$M/.journal/quarantine"/*.reason 2>/dev/null | tr '\n' ' '; }
replay() { cp "$M"/.journal/applied/*/*.json "$M"/.journal/pending/; }
regla() { grep -E "^$1\. " "$M/learnings/gate.md" || true; }
qr() { sed -n '/## Quick Reference/,/## Related/p' "$M/_learnings.md"; }
huella() { cat "$M/learnings/gate.md" "$M/_learnings.md" | cksum; }
indice() { python3 "$BIN/build-recall-index.py" "$M" "$T/idx.jsonl" >/dev/null; }
en_indice() { grep -c -- "$1" "$T/idx.jsonl" | tr -d ' '; }

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
| Gate | [[learnings/gate]] | antes de empujar |

## Quick Reference

1. **Uno corto** — a
2. **Dos corto** — b
3. **Tres corto** — c

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
2. **Empujar exige la fila del ledger en main** — mismo motivo, otra redaccion
3. **El clon se limpia con reset** — antiguo
4. **Marcar una regla vieja** — se hace con `— ⊘ RETIRADA (FECHA, motivo)` en su linea
5. **Consolidar es marcar con ⊘ SUPERSEDED by, no borrar** — preserva el historico
6. **Regla multilinea** — arrastra
   una continuacion
7. **Ultima** — cierra

## Related
- [[_learnings|Learnings Index]]
TOP
}

echo "== 1. retire conserva el numero y escribe el marcador canonico =="
fixture
emit --type learning.retire --topic gate --match-prefix "Empujar exige la fila" \
  --motivo duplicada --por 1 --nota "misma leccion que la 1" >/dev/null
compact --quiet >/dev/null
HOY=$(python3 -c 'import datetime;print(datetime.date.today().isoformat())')
chk "la linea 2 sigue siendo la 2, con su texto y el marcador" \
  "2. **Empujar exige la fila del ledger en main** — mismo motivo, otra redaccion — ⊘ RETIRADA ($HOY, duplicada por #1): misma leccion que la 1" "$(regla 2)"
chk "la 1 y la 3 no se tocan" "1. **Nunca empujar sin la fila del ledger** — el required check la lee desde main|3. **El clon se limpia con reset** — antiguo" "$(regla 1)|$(regla 3)"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 2. replay = noop (I3) =="
H=$(huella); replay; OUT=$(compact)
chk "el replay no cambia nada" "$H" "$(huella)"
chk "el replay no va a cuarentena" "0" "$(cuar)"
has "el replay cuenta como noop" "$OUT" "applied=0"

echo "== 3. --por inexistente -> cuarentena no-anchor, nada escrito =="
fixture; H=$(huella)
emit --type learning.retire --topic gate --match-prefix "El clon se limpia" --motivo superada --por 99 >/dev/null
compact --quiet >/dev/null
chk "una cuarentena" "1" "$(cuar)"
has "motivo no-anchor que nombra #99" "$(motivo)" "no-anchor: en learnings/gate.md no hay regla #99"
chk "nada escrito" "$H" "$(huella)"

echo "== 4. --por a una regla retirada -> cuarentena =="
fixture
emit --type learning.retire --topic gate --match-prefix "El clon se limpia" --motivo obsoleta >/dev/null
compact --quiet >/dev/null
H=$(huella)
emit --type learning.retire --topic gate --match-prefix "Empujar exige" --motivo superada --por 3 >/dev/null
compact --quiet >/dev/null
chk "una cuarentena" "1" "$(cuar)"
has "motivo: #3 ya esta retirada" "$(motivo)" "#3 ya esta retirada"
chk "nada escrito" "$H" "$(huella)"

echo "== 5. ciclo -> cuarentena ciclo (A por B y B por A; y una regla por si misma) =="
fixture
emit --type learning.retire --topic gate --match-prefix "Empujar exige" --motivo duplicada --por 1 >/dev/null
compact --quiet >/dev/null
H=$(huella)
emit --type learning.retire --topic gate --match-prefix "Nunca empujar" --motivo duplicada --por 2 >/dev/null
compact --quiet >/dev/null
has "A por B con B retirada por A: ciclo" "$(motivo)" "^ciclo: "
chk "nada escrito" "$H" "$(huella)"
fixture
emit --type learning.retire --topic gate --match-prefix "Nunca empujar" --motivo duplicada --por 1 >/dev/null
compact --quiet >/dev/null
has "una regla por si misma: ciclo" "$(motivo)" "no puede retirarse en favor de si misma"

echo "== 6. --quickref-prefix quita la linea y no renumera =="
fixture
emit --type learning.retire --topic gate --match-prefix "Empujar exige" --motivo duplicada --por 1 \
  --quickref-prefix "Dos corto" >/dev/null
compact --quiet >/dev/null
chk "el Quick Reference queda 1 y 3, sin renumerar" "1. **Uno corto** — a|3. **Tres corto** — c" \
  "$(qr | grep -E '^[0-9]+\. ' | paste -sd'|' -)"
H=$(huella); replay; compact --quiet >/dev/null
chk "replay con la linea ya quitada: noop, sin cuarentena" "$H|0" "$(huella)|$(cuar)"
fixture; H=$(huella)
emit --type learning.retire --topic gate --match-prefix "Empujar exige" --motivo duplicada --por 1 \
  --quickref-prefix "No existe esta linea" >/dev/null
compact --quiet >/dev/null
chk "prefijo del Quick Reference que no casa: cuarentena y NI el topic se marca" "1|$H" "$(cuar)|$(huella)"

echo "== 7. --supersedes: nueva + vieja marcada en el mismo escrito; atomico si falla =="
fixture
OUT=$(emit --type learning.add --topic gate --text "**El clon se limpia con git clean -fdx**" --supersedes 3 \
  --nota "reset no quita lo no versionado" --quickref "**Clon: git clean -fdx**" --quickref-prefix "Tres corto")
compact --quiet >/dev/null
chk "la regla nueva es la 8" "8. **El clon se limpia con git clean -fdx**" "$(regla 8)"
chk "la 3 queda superada por #8" "3. **El clon se limpia con reset** — antiguo — ⊘ RETIRADA ($HOY, superada por #8): reset no quita lo no versionado" "$(regla 3)"
chk "Quick Reference: la 3 fuera, la nueva es la 4 (el numero 3 no se reutiliza)" \
  "1. **Uno corto** — a|2. **Dos corto** — b|4. **Clon: git clean -fdx**" "$(qr | grep -E '^[0-9]+\. ' | paste -sd'|' -)"
H=$(huella); replay; compact --quiet >/dev/null
chk "replay del supersedes: noop, sin cuarentena" "$H|0" "$(huella)|$(cuar)"
fixture; H=$(huella)
emit --type learning.add --topic gate --text "**Otra multilinea mejor**" --supersedes 6 >/dev/null
compact --quiet >/dev/null
chk "N de varias lineas: cuarentena y la nueva NO se escribe" "1|$H" "$(cuar)|$(huella)"
has "con el motivo de rewrite_rule" "$(motivo)" "bloque-multilinea"
fixture; H=$(huella)
emit --type learning.add --topic gate --text "**Nueva con Quick Reference mal citado**" --supersedes 3 \
  --quickref-prefix "No existe esta linea" >/dev/null
compact --quiet >/dev/null
chk "Quick Reference que no casa: cuarentena y ni la nueva ni la marca se escriben" "1|$H" "$(cuar)|$(huella)"
fixture; H=$(huella)
emit --type learning.add --topic gate --text "**Reemplaza a una que no existe**" --supersedes 42 >/dev/null
compact --quiet >/dev/null
chk "N inexistente: cuarentena y la nueva NO se escribe" "1|$H" "$(cuar)|$(huella)"
fixture; H=$(huella)
emit --type learning.add --topic otro --text "**En un topic que no existe**" --supersedes 1 >/dev/null
compact --quiet >/dev/null
chk "topic inexistente: cuarentena y no se crea el topic" "1|no" "$(cuar)|$([ -f "$M/learnings/otro.md" ] && echo si || echo no)"

echo "== 7b. --supersedes: replays y escrituras a medias (adversario, ronda 1) =="
# Topic limpio (lo crean los add): en gate.md la regla nueva seguiria a la multilinea 6 y el update
# iria a cuarentena por `anterior`, que no es lo que este caso mide.
fixture
emit --type learning.add --topic limpio --text "**El clon se limpia con reset** — antiguo" >/dev/null
compact --quiet >/dev/null
emit --type learning.add --topic limpio --text "**El clon se limpia con git clean -fdx**" --supersedes 1 >/dev/null
compact --quiet >/dev/null
# La regla nueva (#2) se corrige despues y su texto deja de ser el del evento.
emit --type learning.update --topic limpio --match-prefix "El clon se limpia con git clean" \
  --text "**Limpiar el clon: git clean -fdx y luego reset**" >/dev/null
compact --quiet >/dev/null
chk "estado previo: la 1 superada por #2, la 2 corregida, sin cuarentena" "1|1|0" \
  "$(grep -c '^1\. .*superada por #2' "$M/learnings/limpio.md" | tr -d ' ')|$(grep -c '^2\. \*\*Limpiar el clon' "$M/learnings/limpio.md" | tr -d ' ')|$(cuar)"
H=$(cat "$M/learnings/limpio.md" "$M/_learnings.md" | cksum); replay; compact --quiet >/dev/null
chk "replay del supersedes tras corregir la nueva: noop, sin cuarentena ni regla duplicada" "$H|0|0" \
  "$(cat "$M/learnings/limpio.md" "$M/_learnings.md" | cksum)|$(cuar)|$(grep -c 'El clon se limpia con git clean' "$M/learnings/limpio.md" | tr -d ' ')"
fixture
python3 - "$M/_learnings.md" <<'PY'
import sys; p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("| Gate | [[learnings/gate]] | antes de empujar |\n", ""))
PY
H=$(huella)
emit --type learning.add --topic gate --text "**Reemplaza a una que no existe**" --supersedes 42 >/dev/null
compact --quiet >/dev/null
chk "supersedes invalido con la fila de Topic Files ausente: cuarentena y _learnings.md intacto" "1|$H" "$(cuar)|$(huella)"
fixture
# Estado de una escritura a medias: el topic ya marco la 2 pero el Quick Reference no se toco.
python3 - "$M/learnings/gate.md" <<'PY'
import sys; p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("otra redaccion\n", "otra redaccion — ⊘ RETIRADA (2026-10-01, duplicada por #1)\n"))
PY
emit --type learning.retire --topic gate --match-prefix "Empujar exige" --motivo duplicada --por 1 \
  --quickref-prefix "Dos corto" >/dev/null
compact --quiet >/dev/null
chk "el replay completa el Quick Reference que faltaba, sin cuarentena" "1. **Uno corto** — a|3. **Tres corto** — c|0" \
  "$(qr | grep -E '^[0-9]+\. ' | paste -sd'|' -)|$(cuar)"

echo "== 8. regla multilinea -> cuarentena con el motivo de rewrite_rule =="
fixture; H=$(huella)
emit --type learning.retire --topic gate --match-prefix "Regla multilinea" --motivo obsoleta >/dev/null
compact --quiet >/dev/null
chk "cuarentena, nada escrito" "1|$H" "$(cuar)|$(huella)"
has "motivo bloque-multilinea" "$(motivo)" "^bloque-multilinea: "

echo "== 9. el recall no sirve una regla retirada (marcador nuevo y las dos formas viejas) =="
fixture
emit --type learning.retire --topic gate --match-prefix "Empujar exige" --motivo duplicada --por 1 >/dev/null
compact --quiet >/dev/null
# Formas viejas del corpus real, copiadas tal cual: la de /consolidate-3t antiguo (sin "by") y la de
# un topic de otra instalacion (`~~…~~ — ⊘ SUPERSEDED by [[…]]`)
cat > "$M/learnings/viejas.md" <<'VIE'
---
type: learnings
topic: viejas
---
# Viejas

1. **Index pruning is automatic** — checkpoint Step 5b trims session indexes — ⊘ SUPERSEDED (2026-09-02, v2.12.0 Fase 2): la poda la hace el compactador
2. ~~El repo memoria NUNCA se pushea.~~ — ⊘ SUPERSEDED by [[repo-memoria-pushable]] (2026-07-10): desde entonces se pushea
3. **Regla viva de control** — sigue valiendo
4. **Span doble** — se cita asi: ``— ⊘ RETIRADA (F, ` m)``, y la regla sigue viva
VIE
cat > "$M/learnings/topic-entero.md" <<'TOT'
---
type: learning
status: superseded
---
# ⊘ SUPERSEDED (2026-07-12) → [[otro-topic]]

1. **Regla dentro de un topic retirado** — no debe servirse
TOT
indice
chk "la retirada con el marcador nuevo no esta en el indice" "0" "$(en_indice 'Empujar exige')"
chk "la vigente que la reemplaza si esta" "1" "$(en_indice 'Nunca empujar sin la fila')"
chk "forma vieja SUPERSEDED (FECHA…) fuera" "0" "$(en_indice 'Index pruning is automatic')"
chk "forma vieja SUPERSEDED by [[…]] fuera" "0" "$(en_indice 'NUNCA se pushea')"
chk "regla viva del mismo fichero dentro" "1" "$(en_indice 'Regla viva de control')"
chk "topic con cabecera retirada: fuera entero" "0" "$(en_indice 'dentro de un topic retirado')"
chk "control: la regla que CITA el marcador entre comillas invertidas sigue viva" "1" "$(en_indice 'Marcar una regla vieja')"
chk "control: la que dice '⊘ SUPERSEDED by' sin el — delante sigue viva" "1" "$(en_indice 'Consolidar es marcar')"
chk "control: la que cita el marcador en un span de doble comilla invertida sigue viva" "1" "$(en_indice 'Span doble')"
# el motor de produccion sobre ese indice
TOP=$(RECALL_INDEX="$T/idx.jsonl" RECALL_PROMPT="empujar fila ledger required check main" python3 "$BIN/recall_rank.py")
has "recall_rank devuelve la vigente" "$TOP" "Nunca empujar sin la fila"
chk "recall_rank no devuelve la retirada" "0" "$(printf '%s' "$TOP" | grep -c 'Empujar exige' | tr -d ' ')"

echo "== 10. find-dup-candidates no la devuelve =="
fixture
DUP=$(DUP_JACCARD_THRESHOLD=0.3 sh -c 'python3 "$0/build-recall-index.py" "$1" "$2" >/dev/null; python3 "$0/find-dup-candidates.py" "$2"' "$BIN" "$M" "$T/idx.jsonl")
has "control: sin retirar, el par 1/2 sale como candidato" "$DUP" "Empujar exige la fila"
emit --type learning.retire --topic gate --match-prefix "Empujar exige" --motivo duplicada --por 1 >/dev/null
compact --quiet >/dev/null
DUP=$(DUP_JACCARD_THRESHOLD=0.3 sh -c 'python3 "$0/build-recall-index.py" "$1" "$2" >/dev/null; python3 "$0/find-dup-candidates.py" "$2"' "$BIN" "$M" "$T/idx.jsonl")
chk "retirada la 2, el par ya no sale" "0" "$(printf '%s' "$DUP" | grep -c 'Empujar exige' | tr -d ' ')"

echo "== 11. learning.update conserva el marcador de una regla retirada =="
fixture
emit --type learning.retire --topic gate --match-prefix "El clon se limpia" --motivo obsoleta --nota "ya no hay clon" >/dev/null
compact --quiet >/dev/null
# El texto nuevo NO empieza por el prefijo viejo: en el replay el prefijo ya no casa y la unica
# forma de reconocerlo es "la regla, sin su marcador, ya es el texto nuevo". Con un texto que
# conservara el prefijo, el replay reescribiria la misma linea y este caso no probaria nada
# (lo destapo la mutacion replay-update-retirada).
emit --type learning.update --topic gate --match-prefix "El clon se limpia" \
  --text "**Limpiar el clon exige reset --hard** — antiguo, redaccion corregida" >/dev/null
compact --quiet >/dev/null
chk "texto nuevo + el mismo marcador" \
  "3. **Limpiar el clon exige reset --hard** — antiguo, redaccion corregida — ⊘ RETIRADA ($HOY, obsoleta): ya no hay clon" "$(regla 3)"
H=$(huella); replay; compact --quiet >/dev/null
chk "replay del retire y del update: noop, sin cuarentena" "$H|0" "$(huella)|$(cuar)"
chk "sigue fuera del indice" "0" "$(indice; en_indice 'reset --hard')"

echo "== 12. el emisor y el compactador rechazan un evento mal formado =="
fixture
set +e
emit --type learning.retire --topic gate --match-prefix "x" --motivo obsoleta --por 1 >/dev/null 2>&1; R1=$?
emit --type learning.retire --topic gate --match-prefix "x" --motivo duplicada >/dev/null 2>&1; R2=$?
emit --type learning.retire --topic gate --motivo obsoleta >/dev/null 2>&1; R3=$?
emit --type learning.retire --topic gate --match-prefix "x" --motivo borrada >/dev/null 2>&1; R4=$?
emit --type learning.add --topic gate --text "x" --quickref-prefix "Uno" >/dev/null 2>&1; R5=$?
set -e
chk "obsoleta con --por / duplicada sin --por / sin prefijo / motivo raro / quickref-prefix sin supersedes: los 5 salen !=0" \
  "1 1 1 1 1" "$([ $R1 -ne 0 ] && echo 1) $([ $R2 -ne 0 ] && echo 1) $([ $R3 -ne 0 ] && echo 1) $([ $R4 -ne 0 ] && echo 1) $([ $R5 -ne 0 ] && echo 1)"
mkdir -p "$M/.journal/pending"
printf '{"v":1,"type":"learning.retire","ts":1,"session_id":"t","payload":{"topic":"gate","match_prefix":"El clon","motivo":"superada"}}' \
  > "$M/.journal/pending/1-a-1-0.json"
H=$(huella); compact --quiet >/dev/null
has "a mano, superada sin por: malformed" "$(motivo)" "malformed: learning.retire 'superada' necesita 'por'"
chk "nada escrito" "$H" "$(huella)"

echo "== 13. el pie del recall: solo con RECALL_PIE, con topic y prefijo =="
fixture; indice
SIN=$(RECALL_INDEX="$T/idx.jsonl" RECALL_PROMPT="empujar fila ledger required check main" python3 "$BIN/recall_rank.py")
CON=$(RECALL_INDEX="$T/idx.jsonl" RECALL_PROMPT="empujar fila ledger required check main" RECALL_PIE="/x/journal-emit.py" python3 "$BIN/recall_rank.py")
chk "sin RECALL_PIE no hay pie (la salida del motor de F0)" "0" "$(printf '%s' "$SIN" | grep -c '↳' | tr -d ' ')"
has "con RECALL_PIE: topic y prefijo de la regla" "$CON" '--topic gate --match-prefix "Nunca empujar sin la fila del"'
has "con RECALL_PIE: la orden con la ruta del emisor" "$CON" 'python3 "/x/journal-emit.py" --type learning.retire'
chk "quitando el pie queda exactamente la salida sin pie" "$SIN" "$(printf '%s\n' "$CON" | grep -v '↳')"

echo "== 14. el replay de un learning.add cuya regla se retiro despues no la vuelve a escribir =="
# Topic propio (lo crea el add): en gate.md una regla anadida al final seguiria a la multilinea 6
# y su retire iria a cuarentena por `anterior`, que no es lo que este caso mide.
fixture
emit --type learning.add --topic limpio --text "**Regla que luego se retira** — por un rato" >/dev/null
compact --quiet >/dev/null
emit --type learning.retire --topic limpio --match-prefix "Regla que luego se retira" --motivo obsoleta >/dev/null
compact --quiet >/dev/null
chk "retirada sin cuarentena" "1|0" "$(grep -c '⊘ RETIRADA' "$M/learnings/limpio.md" | tr -d ' ')|$(cuar)"
H=$(cat "$M/learnings/limpio.md" | cksum); replay; compact --quiet >/dev/null
chk "replay: una sola regla con ese texto, nada cambia, sin cuarentena" "1|$H|0" \
  "$(grep -c 'Regla que luego se retira' "$M/learnings/limpio.md" | tr -d ' ')|$(cat "$M/learnings/limpio.md" | cksum)|$(cuar)"

echo "== 15. recall.sh de punta a punta: reconstruye un indice viejo y sirve el pie =="
fixture
emit --type learning.retire --topic gate --match-prefix "Empujar exige" --motivo duplicada --por 1 >/dev/null
compact --quiet >/dev/null
P="$T/plug"; mkdir -p "$P/bin" "$T/home"; cp "$BIN"/*.py "$BIN"/*.sh "$P/bin/"
ENC=$(echo "$T" | sed 's/[^A-Za-z0-9]/-/g'); IDX="$T/home/.claude/projects/$ENC/.recall-index.jsonl"
mkdir -p "$(dirname "$IDX")"
# Indice que construyo un constructor anterior a 2.45.0: trae la regla retirada y ninguna "regla".
printf '%s\n' '{"id": "learning:0", "tipo": "learning", "texto": "**Empujar exige la fila del ledger en main** — mismo motivo, otra redaccion", "path": "memory/learnings/gate.md", "fecha": "", "importance": 5, "keywords": ["empujar", "exige", "fila", "ledger", "main", "mismo", "motivo", "otra", "redaccion"]}' > "$IDX"
find "$M" -name '*.md' -exec touch -t 202001010000 {} +
touch -t 202101010000 "$IDX"          # mas nuevo que memory/, mas viejo que el constructor copiado
OUT=$(printf '{"prompt":"empujar fila ledger required check main"}' \
  | CLAUDE_PROJECT_DIR="$T" CLAUDE_PLUGIN_ROOT="$P" HOME="$T/home" bash "$P/bin/recall.sh" 2>/dev/null)
chk "el indice viejo se reconstruyo: la retirada no sale" "0" "$(printf '%s' "$OUT" | grep -c 'Empujar exige' | tr -d ' ')"
has "sale la vigente" "$OUT" "Nunca empujar sin la fila"
has "con su pie: topic y prefijo" "$OUT" '--topic gate --match-prefix "Nunca empujar sin la fila del"'
# Ruta del emisor y memory-dir por separado y sin la ruta exacta: en Git Bash resolve-project-dir.sh
# puede dar la ruta nativa (C:\...) y la de este test es POSIX.
has "y la orden con el emisor instalado" "$OUT" "/bin/journal-emit.py\" --memory-dir \""
has "que es learning.retire" "$OUT" "\" --type learning.retire <↳> --motivo"

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
