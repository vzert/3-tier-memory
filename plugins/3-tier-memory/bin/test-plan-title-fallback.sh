#!/bin/bash
# Fallback por titulo de `plan.upsert` (pendiente p-e79c16c7e0).
#
# El hueco, medido antes del arreglo: si un plan no tenia fila con su wikilink, apply_plan_upsert
# buscaba una fila con el mismo titulo (plain(), NFC) en TODA la tabla, tambien entre las filas
# enlazadas a OTRO plan. Un `plan.upsert --slug b --title X` sin --inline encontraba la fila de
# plan-a titulada X y le cambiaba el enlace a [[plans/plan-b|X]]: plan-a perdia su fila en silencio.
# El fallback existe para el plan --inline (su fila no lleva wikilink), y ahora solo casa filas
# `(inline)`. Una fila con ese titulo sin wikilink canonico ni (inline) manda el upsert a
# cuarentena (casos 5, 6 y 9). Un plan con archivo no toma una fila (inline) (casos 10 y 12); uno
# sin archivo si, aunque no repita --inline (caso 11). plan.reopen usa el mismo fallback (7 y 12).
#
# Limite, sin test a proposito: una fila (inline) solo guarda su titulo. Dos planes inline con el
# mismo titulo son indistinguibles y el primero del indice gana; no hay nada que asertar como seguro.
#
# Los fixtures usan titulos distintos salvo en los casos que prueban la colision a proposito.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

fixture() {
  M="$T/m$RANDOM$RANDOM/memory"; mkdir -p "$M"
  printf -- '---\ntype: index\nupdated: 2026-01-01\n---\n# Plans Index\n' > "$M/_plans-index.md"
}
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@" >/dev/null; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" --log "$M/../compact.log" --quiet >/dev/null; }
filas() { grep -cF -- "$1" "$M/_plans-index.md"; }
status() { grep -F -- "$1" "$M/_plans-index.md" | awk -F' \\| ' '{print $2}'; }
cuar() { ls "$M/.journal/quarantine/"*.json 2>/dev/null | wc -l | tr -d ' '; }

echo "== 1. upsert sin --inline con el titulo de la fila de OTRO plan no la reescribe =="
fixture
emit --type plan.upsert --slug alfa --title "Titulo compartido" --status active --date 2026-09-01
compact
emit --type plan.upsert --slug beta --title "Titulo compartido" --status draft --date 2026-09-02
compact
chk "la fila de plan-alfa sigue" "1" "$(filas '[[plans/plan-alfa\|')"
chk "plan-alfa conserva su status" "active" "$(status '[[plans/plan-alfa\|')"
chk "plan-beta tiene fila propia" "1" "$(filas '[[plans/plan-beta\|')"
chk "plan-beta con su status" "draft" "$(status '[[plans/plan-beta\|')"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 2. lo mismo con el titulo en otra forma Unicode (NFD contra NFC) =="
fixture
NFC=$(printf 'Migraci\303\263n')
NFD=$(printf 'Migracio\314\201n')
emit --type plan.upsert --slug gamma --title "$NFC" --status active --date 2026-09-01
compact
emit --type plan.upsert --slug delta --title "$NFD" --status draft --date 2026-09-02
compact
chk "la fila de plan-gamma sigue" "1" "$(filas '[[plans/plan-gamma\|')"
chk "plan-delta tiene fila propia" "1" "$(filas '[[plans/plan-delta\|')"

echo "== 3. un plan --inline sigue encontrando su fila por titulo =="
fixture
emit --type plan.upsert --slug epsilon --inline --title "Ajuste rapido" --status active --date 2026-09-01
compact
emit --type plan.upsert --slug epsilon --inline --title "Ajuste rapido" --status completed --date 2026-09-01
compact
chk "una sola fila inline" "1" "$(filas 'Ajuste rapido (inline)')"
chk "la fila inline paso a completed" "completed" "$(status 'Ajuste rapido (inline)')"

echo "== 4. --inline con el titulo de una fila enlazada a otro plan no la toma =="
fixture
emit --type plan.upsert --slug zeta --title "Limpieza" --status active --date 2026-09-01
compact
emit --type plan.upsert --slug eta --inline --title "Limpieza" --status completed --date 2026-09-02
compact
chk "la fila de plan-zeta sigue" "1" "$(filas '[[plans/plan-zeta\|')"
chk "plan-zeta conserva su status" "active" "$(status '[[plans/plan-zeta\|')"
chk "el inline tiene fila propia" "1" "$(filas 'Limpieza (inline)')"

echo "== 5. una fila legacy sin wikilink ni (inline) con el mismo titulo: cuarentena =="
# Esa fila puede ser de otro plan (tomarla se la roba) o del mismo (una fila nueva lo duplica:
# check-active-plans.py lo contaba dos veces). Ninguna salida es segura sin una persona.
fixture
emit --type plan.upsert --slug theta --title "Otro plan" --status active --date 2026-09-01
compact
printf '| Plan legacy | active | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
emit --type plan.upsert --slug iota --title "Plan legacy" --status completed --date 2026-08-01
compact
chk "la fila legacy sigue intacta" "1" "$(grep -cxF '| Plan legacy | active | 2026-08-01 |  |  |  |' "$M/_plans-index.md")"
chk "no se inserta otra fila con ese titulo" "1" "$(grep -c 'Plan legacy' "$M/_plans-index.md")"
chk "el evento va a cuarentena" "1" "$(cuar)"
chk "motivo titulo-ambiguo" "1" "$(grep -l 'titulo-ambiguo' "$M/.journal/quarantine/"*.reason 2>/dev/null | wc -l | tr -d ' ')"
chk "plan-theta no se toca" "active" "$(status '[[plans/plan-theta\|')"

echo "== 6. enlaces a mano en otra forma con el mismo titulo: cuarentena, sin tocarlos =="
fixture
emit --type plan.upsert --slug kappa --title "Ancla" --status active --date 2026-09-01
compact
printf '| [[Plans/plan-mayus\\|Mayusculas]] | active | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
printf '| [[ plans/plan-espacio\\|Con espacio]] | active | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
emit --type plan.upsert --slug lambda --title "Mayusculas" --status draft --date 2026-09-02
emit --type plan.upsert --slug mu --title "Con espacio" --status draft --date 2026-09-02
compact
chk "la fila [[Plans/ sigue" "1" "$(filas '[[Plans/plan-mayus\|')"
chk "la fila [[ plans/ sigue" "1" "$(filas '[[ plans/plan-espacio\|')"
chk "plan-lambda sin fila (cuarentena)" "0" "$(filas '[[plans/plan-lambda\|')"
chk "plan-mu sin fila (cuarentena)" "0" "$(filas '[[plans/plan-mu\|')"
chk "dos eventos en cuarentena" "2" "$(cuar)"

echo "== 7. plan.reopen por titulo: toma su fila (inline), nunca la de otro plan =="
fixture
emit --type plan.upsert --slug nu --title "Cerrado ajeno" --status completed --date 2026-09-01
emit --type plan.upsert --slug xi --inline --title "Inline cerrado" --status completed --date 2026-09-01
compact
emit --type plan.reopen --slug omicron --title "Cerrado ajeno"
emit --type plan.reopen --slug xi --title "Inline cerrado"
compact
chk "plan-nu sigue completed" "completed" "$(status '[[plans/plan-nu\|')"
chk "el reopen ajeno va a cuarentena" "1" "$(cuar)"
chk "el inline se reabre" "active" "$(status 'Inline cerrado (inline)')"

echo "== 8. (inline) cuenta solo al final de la celda del plan, no en otra columna =="
fixture
emit --type plan.upsert --slug pi --title "Base" --status active --date 2026-09-01
compact
printf '| [[plans/plan-rho\\|Rho]] | active | 2026-08-01 | (inline) |  |  |\n' >> "$M/_plans-index.md"
emit --type plan.upsert --slug sigma --title "Rho" --status draft --date 2026-09-02
compact
chk "la fila de plan-rho sigue" "1" "$(filas '[[plans/plan-rho\|')"
chk "plan-sigma tiene fila propia" "1" "$(filas '[[plans/plan-sigma\|')"

echo "== 9. enlace con espacio antes de la barra: find_plan_rows no lo ve, asi que no tiene dueno =="
fixture
emit --type plan.upsert --slug tau --title "Base" --status active --date 2026-09-01
compact
printf '| [[plans/plan-upsilon \\|Espacio]] | active | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
emit --type plan.upsert --slug phi --title "Espacio" --status draft --date 2026-09-02
compact
chk "la fila con espacio sigue" "1" "$(filas '[[plans/plan-upsilon \|')"
chk "plan-phi sin fila (cuarentena)" "0" "$(filas '[[plans/plan-phi\|')"
chk "un evento en cuarentena" "1" "$(cuar)"

echo "== 10. plan CON archivo y el titulo de una fila (inline): cuarentena, la fila inline intacta =="
fixture
emit --type plan.upsert --slug chi --inline --title "Compartido inline" --status active --date 2026-09-01
compact
mkdir -p "$M/plans"; printf '# Compartido inline\n' > "$M/plans/plan-psi.md"
emit --type plan.upsert --slug psi --title "Compartido inline" --status completed --date 2026-09-02
compact
chk "la fila inline sigue active" "active" "$(status 'Compartido inline (inline)')"
chk "plan-psi sin fila (cuarentena)" "0" "$(filas '[[plans/plan-psi\|')"
chk "un evento en cuarentena" "1" "$(cuar)"

echo "== 11. plan inline SIN archivo y sin repetir --inline: sigue encontrando su fila =="
fixture
emit --type plan.upsert --slug omega --inline --title "Inline sin flag" --status active --date 2026-09-01
compact
emit --type plan.upsert --slug omega --title "Inline sin flag" --status completed --date 2026-09-01
compact
chk "una sola fila" "1" "$(grep -c 'Inline sin flag' "$M/_plans-index.md")"
chk "la fila inline paso a completed" "completed" "$(status 'Inline sin flag (inline)')"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 12. plan.reopen de un plan CON archivo no reabre la fila (inline) de otro =="
fixture
emit --type plan.upsert --slug ab --inline --title "Inline cerrado ajeno" --status completed --date 2026-09-01
compact
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-cd.md"
emit --type plan.reopen --slug cd --title "Inline cerrado ajeno"
compact
chk "la fila inline sigue completed" "completed" "$(status 'Inline cerrado ajeno (inline)')"
chk "el reopen va a cuarentena" "1" "$(cuar)"

echo "== 13. enlace con un slug mas largo que SLUG_RE (121): find_plan_rows nunca lo vera, sin dueno =="
fixture
emit --type plan.upsert --slug base13 --title "Base" --status active --date 2026-09-01
compact
LARGO=$(printf 'x%.0s' $(seq 1 130))
printf '| [[plans/plan-%s\\|Largo]] | active | 2026-08-01 |  |  |  |\n' "$LARGO" >> "$M/_plans-index.md"
emit --type plan.upsert --slug corto --title "Largo" --status draft --date 2026-09-02
compact
chk "una sola fila con ese titulo" "1" "$(grep -c '|Largo]]' "$M/_plans-index.md")"
chk "un evento en cuarentena" "1" "$(cuar)"

echo "== 14. fila con wikilink canonico que ademas termina en (inline): tiene dueno, no se toma =="
fixture
emit --type plan.upsert --slug base14 --title "Base" --status active --date 2026-09-01
compact
printf '| [[plans/plan-owner\\|Mixta]] (inline) | completed | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
emit --type plan.upsert --slug intruso --inline --title "Mixta" --status active --date 2026-09-02
compact
chk "la fila mixta sigue completed" "completed" "$(status '[[plans/plan-owner\|Mixta]] (inline)')"
chk "el upsert --inline crea su propia fila" "1" "$(grep -cxF '| Mixta (inline) | active | 2026-09-02 |  |  |  |' "$M/_plans-index.md")"
# El reopen, en un indice aparte: con la fila inline de arriba, el reopen la encontraria a ella
# (choque inline-inline, limite declarado) y no probaria la fila mixta.
fixture
emit --type plan.upsert --slug base14b --title "Base" --status active --date 2026-09-01
compact
printf '| [[plans/plan-owner\\|Mixta]] (inline) | completed | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
emit --type plan.reopen --slug intruso2 --title "Mixta"
compact
chk "el reopen no reabre la fila mixta" "completed" "$(status '[[plans/plan-owner\|Mixta]] (inline)')"
chk "el reopen va a cuarentena" "1" "$(cuar)"

echo "== 15. fila PROPIA mixta (enlace + (inline)): conserva su enlace al cambiar de titulo =="
fixture
emit --type plan.upsert --slug base15 --title "Base" --status active --date 2026-09-01
compact
printf '| [[plans/plan-propia\\|Mixta propia]] (inline) | active | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
emit --type plan.upsert --slug propia --title "Mixta renombrada" --status active
compact
chk "la fila conserva el enlace a plan-propia" "1" "$(filas '[[plans/plan-propia\|Mixta renombrada]]')"
chk "no queda como inline sin dueno" "0" "$(grep -cxF '| Mixta renombrada (inline) | active | 2026-08-01 |  |  |  |' "$M/_plans-index.md")"
chk "sin cuarentena" "0" "$(cuar)"

# Promocion (p-236102b948). Un plan --inline que despues recibe plans/plan-<slug>.md no se puede
# promover por regla: el indice queda igual que en el caso 10 (fila (inline) de OTRO plan + plan
# con archivo), y la fila inline no guarda el slug. La identidad la pone el evento: --promote dice
# "la UNICA fila (inline) con este titulo es de este plan". Sin --promote sigue el caso 10.
echo "== 16. --promote: la fila (inline) del plan pasa a [[plans/plan-<slug>|T]], sin duplicar =="
fixture
mkdir -p "$M/sessions"; printf "# s1\n" > "$M/sessions/s1.md"
emit --type plan.upsert --slug prom --inline --title "Plan promovido" --status active --date 2026-09-01 --sesion "[[sessions/s1]]"
compact
mkdir -p "$M/plans"; printf '# Plan promovido\n' > "$M/plans/plan-prom.md"
emit --type plan.upsert --slug prom --promote --title "Plan promovido" --status completed --date 2026-09-05
compact
chk "la fila lleva el enlace del plan" "1" "$(filas '[[plans/plan-prom\|Plan promovido]]')"
chk "no queda fila (inline)" "0" "$(filas 'Plan promovido (inline)')"
chk "una sola fila con ese titulo" "1" "$(grep -c 'Plan promovido' "$M/_plans-index.md")"
chk "status nuevo" "completed" "$(status '[[plans/plan-prom\|')"
chk "conserva la fecha de creacion" "2026-09-01" "$(grep -F '[[plans/plan-prom\|' "$M/_plans-index.md" | awk -F' \\| ' '{print $3}')"
chk "conserva la sesion" "1" "$(grep -F '[[plans/plan-prom\|' "$M/_plans-index.md" | grep -cF '[[sessions/s1]]')"
chk "sin cuarentena" "0" "$(cuar)"
# Replay del mismo evento: ya hay fila propia, --promote no hace nada mas.
emit --type plan.upsert --slug prom --promote --title "Plan promovido" --status completed --date 2026-09-05
compact
chk "replay: sigue una sola fila" "1" "$(grep -c 'Plan promovido' "$M/_plans-index.md")"
chk "replay: sin cuarentena" "0" "$(cuar)"

echo "== 17. --promote con DOS filas (inline) del mismo titulo: cuarentena, no toma ninguna =="
fixture
emit --type plan.upsert --slug base17 --title "Base" --status active --date 2026-09-01
compact
printf '| Gemelo (inline) | active | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
printf '| Gemelo (inline) | completed | 2026-08-02 |  |  |  |\n' >> "$M/_plans-index.md"
mkdir -p "$M/plans"; printf '# Gemelo\n' > "$M/plans/plan-gem.md"
emit --type plan.upsert --slug gem --promote --title "Gemelo" --status active --date 2026-09-02
compact
chk "la primera fila inline intacta" "1" "$(grep -cxF '| Gemelo (inline) | active | 2026-08-01 |  |  |  |' "$M/_plans-index.md")"
chk "la segunda fila inline intacta" "1" "$(grep -cxF '| Gemelo (inline) | completed | 2026-08-02 |  |  |  |' "$M/_plans-index.md")"
chk "plan-gem sin fila" "0" "$(filas '[[plans/plan-gem\|')"
chk "el evento va a cuarentena" "1" "$(cuar)"
chk "motivo titulo-ambiguo" "1" "$(grep -l 'titulo-ambiguo' "$M/.journal/quarantine/"*.reason 2>/dev/null | wc -l | tr -d ' ')"

echo "== 18. --promote nunca toma la fila ENLAZADA de otro plan con el mismo titulo =="
fixture
emit --type plan.upsert --slug dueno --title "Enlazado" --status active --date 2026-09-01
compact
mkdir -p "$M/plans"; printf '# Enlazado\n' > "$M/plans/plan-ladron.md"
emit --type plan.upsert --slug ladron --promote --title "Enlazado" --status completed --date 2026-09-02
compact
chk "plan-dueno conserva su fila" "active" "$(status '[[plans/plan-dueno\|')"
chk "plan-ladron sin fila" "0" "$(filas '[[plans/plan-ladron\|')"
chk "el evento va a cuarentena" "1" "$(cuar)"

echo "== 19. --promote sin plans/plan-<slug>.md: cuarentena, la fila (inline) intacta =="
fixture
emit --type plan.upsert --slug sinarch --inline --title "Sin archivo" --status active --date 2026-09-01
compact
emit --type plan.upsert --slug sinarch --promote --title "Sin archivo" --status completed --date 2026-09-02
compact
chk "la fila inline sigue active" "active" "$(status 'Sin archivo (inline)')"
chk "el evento va a cuarentena" "1" "$(cuar)"

echo "== 20. --promote sin fila (inline) con ese titulo: cuarentena, no inserta fila =="
fixture
emit --type plan.upsert --slug base20 --title "Base" --status active --date 2026-09-01
compact
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-huerfano.md"
emit --type plan.upsert --slug huerfano --promote --title "No existe" --status active --date 2026-09-02
compact
chk "plan-huerfano sin fila" "0" "$(filas '[[plans/plan-huerfano\|')"
chk "el evento va a cuarentena" "1" "$(cuar)"

echo "== 21. el emisor rechaza --promote junto a --inline =="
fixture
python3 "$BIN/journal-emit.py" --memory-dir "$M" --type plan.upsert --slug x21 --promote --inline \
  --title "X" --status active >/dev/null 2>&1
chk "sale con error" "1" "$([ $? -ne 0 ] && echo 1 || echo 0)"
chk "no escribe evento" "0" "$(ls "$M/.journal/pending/" 2>/dev/null | wc -l | tr -d ' ')"

echo "== 22. --promote de un plan inline CERRADO con --status active: noop y el aviso da el orden =="
# El guardian de reversa (2.37.0) descarta el evento entero, asi que la fila sigue (inline). El
# aviso no puede mandar solo a plan.reopen: con archivo, reopen no encuentra una fila (inline).
fixture
emit --type plan.upsert --slug cerr --inline --title "Inline cerrado prom" --status completed --date 2026-09-01
compact
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-cerr.md"
emit --type plan.upsert --slug cerr --promote --title "Inline cerrado prom" --status active
compact
chk "la fila sigue (inline) y completed" "completed" "$(status 'Inline cerrado prom (inline)')"
chk "el aviso pide promover con el status cerrado" "1" "$(grep -c 'promueve primero con --promote --status completed' "$M/../compact.log")"
emit --type plan.upsert --slug cerr --promote --title "Inline cerrado prom" --status completed
emit --type plan.reopen --slug cerr
compact
chk "promovido y reabierto" "active" "$(status '[[plans/plan-cerr\|')"
chk "sin cuarentena" "0" "$(cuar)"

# Ronda 1 de adversario de bd440b2. Un replay de verdad es el MISMO JSON: se devuelve de applied/
# a pending/ (el caso 16 emitia un evento nuevo, que tiene otro ts).
replay() { f=$(grep -l "$1" "$M/.journal/applied/"*/*.json | head -1); cp "$f" "$M/.journal/pending/"; }

echo "== 23. celda mixta con el enlace en otra forma ([[Plans/...]] (inline)): no es inline, no se toma =="
fixture
emit --type plan.upsert --slug base23 --title "Base" --status active --date 2026-09-01
compact
printf '| [[Plans/plan-otro\\|Forma rara]] (inline) | active | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-rara.md"
emit --type plan.upsert --slug rara --promote --title "Forma rara" --status completed --date 2026-09-02
emit --type plan.upsert --slug rarainl --inline --title "Forma rara" --status completed --date 2026-09-02
compact
chk "la fila de plan-otro intacta" "1" "$(grep -cxF '| [[Plans/plan-otro\|Forma rara]] (inline) | active | 2026-08-01 |  |  |  |' "$M/_plans-index.md")"
chk "plan-rara sin fila" "0" "$(filas '[[plans/plan-rara\|')"
chk "los dos eventos en cuarentena" "2" "$(cuar)"

echo "== 24. un DIRECTORIO plans/plan-<slug>.md no es el archivo del plan: --promote va a cuarentena =="
fixture
emit --type plan.upsert --slug dir24 --inline --title "Con directorio" --status active --date 2026-09-01
compact
mkdir -p "$M/plans/plan-dir24.md"
emit --type plan.upsert --slug dir24 --promote --title "Con directorio" --status completed --date 2026-09-02
compact
chk "la fila sigue (inline)" "active" "$(status 'Con directorio (inline)')"
chk "cuarentena sin-archivo" "1" "$(grep -l '^sin-archivo' "$M/.journal/quarantine/"*.reason 2>/dev/null | wc -l | tr -d ' ')"

echo "== 25. replay del MISMO evento --promote: con la fila presente y despues de que la poda se la lleva =="
fixture
emit --type plan.upsert --slug rep --inline --title "Promovido y podado" --status active --date 2026-08-01
compact
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-rep.md"
emit --type plan.upsert --slug rep --promote --title "Promovido y podado" --status completed --date 2026-08-01
compact
replay '"promote": true'
compact
chk "replay con la fila: una sola fila" "1" "$(grep -c 'Promovido y podado' "$M/_plans-index.md")"
chk "replay con la fila: sin cuarentena" "0" "$(cuar)"
for n in 1 2 3 4 5; do
  emit --type plan.upsert --slug nuevo$n --title "Nuevo $n" --status completed --date 2026-09-0$n
done
compact
chk "la poda se llevo la fila promovida" "0" "$(grep -c 'Promovido y podado' "$M/_plans-index.md")"
replay '"promote": true'
compact
chk "replay tras la poda: sin cuarentena" "0" "$(cuar)"
chk "replay tras la poda: no deja fila" "0" "$(grep -c 'Promovido y podado' "$M/_plans-index.md")"
chk "replay tras la poda: nada pendiente" "0" "$(ls "$M/.journal/pending/" | wc -l | tr -d ' ')"
# Sin el registro (un --promote nuevo, otro ts) la misma situacion sigue siendo cuarentena.
emit --type plan.upsert --slug rep --promote --title "Promovido y podado" --status completed --date 2026-08-01
compact
chk "un --promote NUEVO sin fila inline sigue en cuarentena" "1" "$(cuar)"

echo "== 26. --promote no toma una celda mixta CANONICA de otro plan con el mismo titulo =="
fixture
emit --type plan.upsert --slug base26 --title "Base" --status active --date 2026-09-01
compact
printf '| [[plans/plan-owner\\|Mixta26]] (inline) | active | 2026-08-01 |  |  |  |\n' >> "$M/_plans-index.md"
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-intr26.md"
emit --type plan.upsert --slug intr26 --promote --title "Mixta26" --status completed --date 2026-09-02
compact
chk "la fila mixta de plan-owner intacta" "1" "$(grep -cxF '| [[plans/plan-owner\|Mixta26]] (inline) | active | 2026-08-01 |  |  |  |' "$M/_plans-index.md")"
chk "plan-intr26 sin fila" "0" "$(filas '[[plans/plan-intr26\|')"
chk "el evento va a cuarentena" "1" "$(cuar)"

echo "== 27. --promote con --parent: la fila promovida ya lleva enlace y acepta el padre =="
fixture
emit --type plan.upsert --slug padre27 --title "Padre" --status active --date 2026-09-01
emit --type plan.upsert --slug hijo27 --inline --title "Hijo inline" --status active --date 2026-09-01
compact
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-hijo27.md"
emit --type plan.upsert --slug hijo27 --promote --parent padre27 --title "Hijo inline" --status active --date 2026-09-02
compact
chk "promovida con su padre" "active (fase de plan-padre27)" "$(status '[[plans/plan-hijo27\|')"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 28. replay de una promocion que CERRO el plan, despues de un plan.reopen: no lo vuelve a cerrar =="
fixture
emit --type plan.upsert --slug cierre28 --inline --title "Cerrar y reabrir" --status active --date 2026-09-01
compact
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-cierre28.md"
emit --type plan.upsert --slug cierre28 --promote --title "Cerrar y reabrir" --status completed --date 2026-09-01
compact
emit --type plan.reopen --slug cierre28
compact
replay '"promote": true'
compact
chk "sigue abierto tras el replay" "active" "$(status '[[plans/plan-cierre28\|')"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 29. una promocion VIEJA que cierra, aplicada despues de un plan.reopen del inline: noop =="
# El evento --promote (ts viejo) llega tarde: el plan inline ya se reabrio con plan.reopen --title.
# El guardian de reversa tiene que frenarlo aunque este evento sea el que promueve.
fixture
emit --type plan.upsert --slug tarde29 --inline --title "Promocion tardia" --status completed --date 2026-09-01
compact
mkdir -p "$M/plans" "$M/../hold"; printf '# x\n' > "$M/plans/plan-tarde29.md"
emit --type plan.upsert --slug tarde29 --promote --title "Promocion tardia" --status completed --date 2026-09-01
mv "$M/.journal/pending/"*.json "$M/../hold/"
rm "$M/plans/plan-tarde29.md"
emit --type plan.reopen --slug tarde29 --title "Promocion tardia"
compact
printf '# x\n' > "$M/plans/plan-tarde29.md"
mv "$M/../hold/"*.json "$M/.journal/pending/"
compact
chk "el inline sigue abierto" "active" "$(status 'Promocion tardia (inline)')"
chk "el cierre viejo no promueve ni cierra" "0" "$(filas '[[plans/plan-tarde29\|')"
chk "sin cuarentena" "0" "$(cuar)"

echo "== 30. un DIRECTORIO plans/plan-<slug>.md tambien bloquea el fallback por titulo de upsert y reopen =="
# Ronda 2 de adversario de bd440b2: con isfile, el directorio volvia "sin archivo" al plan y su
# upsert o reopen sin --promote tomaba por titulo la fila (inline) de OTRO plan.
fixture
emit --type plan.upsert --slug ajeno30 --inline --title "Inline ajeno" --status completed --date 2026-09-01
compact
mkdir -p "$M/plans/plan-dir30.md"
emit --type plan.upsert --slug dir30 --title "Inline ajeno" --status active --date 2026-09-02
emit --type plan.reopen --slug dir30 --title "Inline ajeno"
compact
chk "la fila inline ajena sigue completed" "completed" "$(status 'Inline ajeno (inline)')"
chk "plan-dir30 sin fila" "0" "$(filas '[[plans/plan-dir30\|')"
chk "los dos eventos en cuarentena" "2" "$(cuar)"

echo "== 31. ts del evento: --promote sin ts y cualquier ts no numerico van a cuarentena, sin romper el compactador =="
fixture
emit --type plan.upsert --slug sints --inline --title "Sin ts" --status active --date 2026-09-01
compact
mkdir -p "$M/plans"; printf '# x\n' > "$M/plans/plan-sints.md"
emit --type plan.upsert --slug sints --promote --title "Sin ts" --status completed --date 2026-09-02
f=$(ls "$M/.journal/pending/"*.json); python3 -c "import json,sys;d=json.load(open(sys.argv[1]));d.pop('ts',None);json.dump(d,open(sys.argv[1],'w'))" "$f"
compact
chk "--promote sin ts: la fila sigue (inline)" "active" "$(status 'Sin ts (inline)')"
chk "--promote sin ts: cuarentena malformed" "1" "$(grep -l '^malformed' "$M/.journal/quarantine/"*.reason 2>/dev/null | wc -l | tr -d ' ')"
emit --type plan.upsert --slug tsraro --title "Ts raro" --status active --date 2026-09-02
f=$(ls "$M/.journal/pending/"*.json); python3 -c "import json,sys;d=json.load(open(sys.argv[1]));d['ts']='abc';json.dump(d,open(sys.argv[1],'w'))" "$f"
python3 "$BIN/journal-compact.py" --memory-dir "$M" --log "$M/../compact.log" --quiet >/dev/null 2>&1
chk "ts no numerico: el compactador no se cae" "0" "$?"
chk "ts no numerico: cuarentena malformed, sin fila" "0" "$(filas '[[plans/plan-tsraro\|')"
chk "ts no numerico: nada atascado en pending" "0" "$(ls "$M/.journal/pending/" | wc -l | tr -d ' ')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
