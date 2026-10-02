#!/bin/bash
# Prueba del dedup al emitir de `learning.add` (2.46.0, F3 del plan de ciclo de vida de learnings).
#
# Por que existe: un duplicado escrito con otras palabras entraba sin que nadie lo viera (medido:
# la 135 de un corpus real repetia la 99 y solo la encontro una persona). Desde 2.46.0
# `journal-emit.py learning.add` imprime las 8 reglas vivas del topic mas parecidas y se niega a
# escribir si una se parece mucho y el agente no decidio. Lo que este fichero vigila:
#
# 1. STDOUT NO CAMBIA: sigue siendo solo el id (las plantillas lo capturan); los vecinos van por
#    stderr, y --solo-vecinos no escribe ningun evento.
# 2. EL BLOQUEO: sin --decision y con un vecino >= 0,5 sale 1 sin escribir; con --decision nueva
#    escribe y la decision viaja en el payload; reemplaza:N es --supersedes N (F2).
# 3. LO QUE NO BLOQUEA: el mismo texto exacto (la identidad topic + texto: se escribe una vez) y
#    una regla retirada, que no es vecina.
# 4. LA MEDIDA: una regla enorme del topic no tapa al duplicado de verdad (Dice, no "comunes /
#    palabras de la nueva").
# 5. LA FORMA: `**Titulo** — cuerpo`, `**` y comillas invertidas pares, titulo <= 200; un final
#    "sobre el" (truncado aparente) se acepta.
# 6. checkpoint-audit `learnings.decision`: cada learning de la ficha lleva su decision.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }
hasnt() { if printf '%s' "$2" | grep -q -- "$3"; then fail=$((fail+1)); echo "  FALLA $1: no esperaba '$3' en '$2'"; else pass=$((pass+1)); echo "  ok  $1"; fi; }

M="$T/memory"
# stdout y stderr a ficheros, sin CR (Git Bash: Python escribe CRLF en Windows)
emit() { set +e; python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@" >"$T/out" 2>"$T/err"; RC=$?; set -e
         OUT=$(tr -d '\r' <"$T/out"); ERR=$(tr -d '\r' <"$T/err"); }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" >/dev/null 2>&1; }
eventos() { ls "$M/.journal/pending" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
ultimo() { ls "$M/.journal/pending"/*.json | sort | tail -1; }
regla() { grep -E "^$1\. " "$M/learnings/gate.md" || true; }

R1='**Revisar el diff completo antes de cerrar** — leer todos los archivos cambiados, no solo los que tocaste a mano'
R2='**Nunca hacer commit en el clon mientras corre la revision del equipo** — la revision aborta sin veredicto si el arbol de trabajo se mueve a mitad'
R4='**Esperar la integracion continua con gh run watch** — agota el limite de peticiones de la API de GitHub en minutos'
# La regla "iman": enorme, contiene TODAS las palabras de la parafrasis de la 2 y muchas mas.
IMAN="**Regla iman con muchisimas palabras** — $(for i in $(seq 1 60); do printf 'palabra%s relleno%s ' "$i" "$i"; done)comitear clon revision equipo corriendo arbol trabajo mueve mitad aborta veredicto"

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

## Related
IDX
  cat > "$M/learnings/gate.md" <<TOP
---
type: learnings
topic: gate
updated: 2026-01-01
---
# Gate

## Rules

1. $R1
2. $R2
3. $IMAN
4. $R4 — ⊘ RETIRADA (2026-01-01, obsoleta): ya no se espera asi
5. **Leer el CHANGELOG antes de publicar** — cada version lleva su entrada con lo que cambia
6. **No usar "git add -A" en un clon** — los hooks escriben bajo .claude y se cuela todo

## Related
- [[_learnings|Learnings Index]]
TOP
}

echo "== 1. stdout solo el id; vecinos por stderr"
fixture
emit --type learning.add --topic gate --text "**Etiquetar la release con su version** — el tag lleva el numero del plugin.json"
chk "regla poco parecida sin --decision: rc 0" "0" "$RC"
chk "stdout es solo el id" "1" "$(printf '%s\n' "$OUT" | grep -cE '^l-[0-9a-f]{10}$')"
chk "stdout tiene una sola linea" "1" "$(printf '%s\n' "$OUT" | grep -c .)"
has "stderr lista los vecinos" "$ERR" "vecinos de la regla nueva en learnings/gate.md"
hasnt "la lista no sale por stdout" "$OUT" "vecinos"

echo "== 2. --solo-vecinos no escribe nada"
fixture
emit --type learning.add --topic gate --text "**Etiquetar la release con su version** — el tag lleva el numero" --solo-vecinos
chk "solo-vecinos: rc 0" "0" "$RC"
chk "solo-vecinos: ningun evento" "0" "$(eventos)"
chk "solo-vecinos: stdout vacio" "" "$OUT"
has "solo-vecinos: imprime la lista" "$ERR" "#5"

echo "== 3. bloqueo: casi la misma regla sin --decision"
fixture
CASI=$(printf '%s' "$R2" | sed 's/clon/clone/')
emit --type learning.add --topic gate --text "$CASI"
chk "casi igual sin --decision: rc 1" "1" "$RC"
chk "casi igual sin --decision: ningun evento" "0" "$(eventos)"
has "el error nombra la vecina #2" "$ERR" "se parece mucho a #2"
has "el error dice como decidir" "$ERR" "--decision reemplaza:2"
emit --type learning.add --topic gate --text "$CASI" --decision nueva
chk "con --decision nueva: rc 0" "0" "$RC"
chk "con --decision nueva: un evento" "1" "$(eventos)"
has "la decision viaja en el payload" "$(tr -d '\r' <"$(ultimo)")" '"decision": "nueva"'

echo "== 4. reemplaza:N es --supersedes N"
fixture
emit --type learning.add --topic gate --text "$CASI" --decision reemplaza:2
chk "reemplaza:2: rc 0" "0" "$RC"
has "reemplaza:2 lleva supersedes 2" "$(tr -d '\r' <"$(ultimo)")" '"supersedes": 2'
compact
has "la 2 queda retirada por la 7" "$(regla 2)" "⊘ RETIRADA (.*superada por #7)"
emit --type learning.add --topic gate --text "$CASI" --decision reemplaza:1 --supersedes 2
chk "reemplaza:1 con --supersedes 2: rc 1" "1" "$RC"
fixture
emit --type learning.add --topic gate --text "$CASI" --decision corrige:2
chk "corrige:2: rc 1" "1" "$RC"
chk "corrige:2: ningun evento" "0" "$(eventos)"
has "corrige remite a learning.update de la #2" "$ERR" "--type learning.update --topic gate --match-prefix"
# El comando que imprime se ejecuta TAL CUAL (eval de la linea impresa; solo se cambia el marcador
# del texto). La #6 tiene comillas dobles en su principio: el prefijo tiene que ir bien citado.
NUEVO6='**No usar git add -A en un clon** — los hooks escriben bajo .claude y se cuela todo lo suyo'
emit --type learning.add --topic gate --text "$CASI" --decision corrige:6
chk "corrige:6: rc 1" "1" "$RC"
CMD=$(printf '%s\n' "$ERR" | grep -E '^ +python3 .* --type learning.update ' | head -1 | sed 's/^ *//')
CMD=${CMD/<texto corregido de la #6>/$NUEVO6}
set +e; eval "$CMD" >/dev/null 2>&1; RCU=$?; set -e
chk "el comando impreso (eval) sale 0" "0" "$RCU"
compact
chk "el comando impreso corrige la #6 en su sitio" "6. $NUEVO6" "$(regla 6)"

echo "== 5. lo que no bloquea: el mismo texto y una retirada"
fixture
emit --type learning.add --topic gate --text "$R1"
chk "mismo texto sin --decision: rc 0" "0" "$RC"
has "mismo texto: lo dice" "$ERR" "mismo texto (#1)"
compact
chk "mismo texto: una sola regla con ese texto" "1" "$(grep -cF -- "$R1" "$M/learnings/gate.md")"
fixture
emit --type learning.add --topic gate --text "$(printf '%s' "$R4" | sed 's/minutos/horas/')"
chk "casi igual a una RETIRADA sin --decision: rc 0" "0" "$RC"
hasnt "la retirada no es vecina" "$ERR" "#4 "

echo "== 6. la regla enorme no tapa al duplicado de verdad"
fixture
emit --type learning.add --topic gate --solo-vecinos \
  --text "**No comitear en el clon con la revision del equipo corriendo** — si el arbol de trabajo se mueve a mitad, la revision aborta sin veredicto"
chk "parafrasis de la 2: la primera vecina es #2" "#2" "$(printf '%s\n' "$ERR" | grep -E '^ +#[0-9]+ ' | head -1 | awk '{print $1}')"

echo "== 7. forma"
fixture
emit --type learning.add --topic gate --text "**Bien titulada** — cuerpo con **negrita sin cerrar" --decision nueva
chk "** impar: rc 1" "1" "$RC"
has "** impar: lo dice" "$ERR" "impar de \`\*\*\`"
emit --type learning.add --topic gate --text "**Code span** — usa \`git log sin cerrar" --decision nueva
chk "comilla invertida impar: rc 1" "1" "$RC"
emit --type learning.add --topic gate --text "Sin negrita — cuerpo" --decision nueva
chk "sin **Titulo** — : rc 1" "1" "$RC"
LARGO=$(printf 'x%.0s' $(seq 1 201))
emit --type learning.add --topic gate --text "**$LARGO** — cuerpo" --decision nueva
chk "titulo de 201: rc 1" "1" "$RC"
emit --type learning.add --topic gate --text "**Nunca publicar sin mirar el CI** — la regla que hablaba sobre el" --decision nueva
chk "final 'sobre el' se acepta: rc 0" "0" "$RC"
chk "ningun evento de los rechazados" "1" "$(eventos)"

echo "== 8. checkpoint-audit learnings.decision"
fixture
ficha() {  # $1 = lineas de ## Learnings generados
  cat > "$T/ficha.md" <<F
---
type: session
date: 2026-01-01
---
# x

## Contexto
x

## Cambios realizados
x

## Bugs fixed
- Ninguno

## Plans
- Ninguno

## Research
- Ninguno

## Learnings generados
$1

## Pendientes
- Ninguno

## Commits
x

## Como retomar
x

## Related
- [[_session-index]]
F
  set +e
  AUD=$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$T/ficha.md" --no-git 2>&1 | tr -d '\r')
  set -e
}
ficha "- [[learnings/gate]] — **Una** — decision: nueva
- [[learnings/gate]] — **Otra** — decision: ya existe #2 (no emitido)"
has "decisiones validas: HECHO" "$AUD" "HECHO .*learnings.decision"
ficha "- [[learnings/gate]] — **Una** — sin decidir"
has "sin decision: SALTADO" "$AUD" "SALTADO .*learnings.decision"
ficha "- [[learnings/gate]] — **Una** — decision: ya existe #99 (no emitido)"
has "#99 que no existe: SALTADO" "$AUD" "SALTADO .*learnings.decision"
ficha "- Ninguno"
hasnt "sin learnings: no se queja" "$AUD" "SALTADO .*learnings.decision"

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
