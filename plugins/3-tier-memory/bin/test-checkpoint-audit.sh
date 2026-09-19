#!/bin/bash
# Prueba de bin/checkpoint-audit.py — ver memory/plans/plan-cierre-auditado-checkpoint.md.
#
# Lo que cubre, y por que: cada caso corresponde a una categoria de hueco MEDIDA en 14 sesiones
# reales (2026-09-13..19) donde el usuario tuvo que preguntar "falto algo de tu checkpoint?".
# Los casos POR-DISENO son igual de importantes que los SALTADO: sin ellos el bloque se llena de
# falsos positivos (no hacer push y dejar el hash como referencia adelantada los ORDENA el skill,
# y aun asi el agente los confesaba como fallas cuando se le preguntaba).
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

AUD="python3 $BIN/checkpoint-audit.py"
HOY=2026-09-19

# ---------------------------------------------------------------- memoria minima y sana
nueva_memoria() {   # $1 = ruta
  local M="$1"
  rm -rf "$M"; mkdir -p "$M/sessions" "$M/plans" "$M/learnings" "$M/pendientes" "$M/research"
  cat > "$M/_pendientes.md" <<'EOF'
# Pendientes

## Alta prioridad

## Media prioridad

## Baja prioridad
EOF
  cat > "$M/_session-index.md" <<'EOF'
# Sesiones

| Fecha | Sesion | Status | Resumen | Commit |
|---|---|---|---|---|
| 2026-09-19 | [[sessions/2026-09-19-demo\|demo]] | completada | demo | `abc1234` |
EOF
  cat > "$M/_plans-index.md" <<'EOF'
# Planes

| Plan | Status | Fecha | Sesion | Pendientes | Learnings |
|---|---|---|---|---|---|
EOF
  cat > "$M/_learnings.md" <<'EOF'
# Learnings

| Tema | Archivo | Cuando consultarlo |
|---|---|---|
EOF
  cat > "$M/pendientes/2026-09.md" <<'EOF'
# Pendientes — Septiembre 2026

| # | Pendiente | Prioridad | Creado | Origen | Resuelto | Sesion resolucion |
|---|---|---|---|---|---|---|
EOF
}

ficha_completa() {   # $1 = ruta de la ficha; escribe las 10 secciones obligatorias
  cat > "$1" <<'EOF'
---
type: session
date: 2026-09-19
---
# Demo

## Contexto
algo

## Cambios realizados
algo

## Bugs fixed
- Ninguno

## Plans
- Ninguno

## Research
- Ninguno

## Learnings generados
- Ninguno

## Pendientes
- Ninguno

## Commits
- `abc1234`

## Como retomar
Ninguno — la sesion cerro sin continuidad.

## Related
- [[_pendientes]]
EOF
}

M="$T/memory"; S="$T/memory/sessions/2026-09-19-demo.md"
nueva_memoria "$M"; ficha_completa "$S"

echo "== checkpoint sano: cero SALTADO, cero PARCIAL =="
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
C=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY --count 2>&1)
chk "sin SALTADO" "0" "$(printf '%s' "$O" | grep -c 'SALTADO')"
chk "sin PARCIAL" "0" "$(printf '%s' "$O" | grep -c 'PARCIAL')"
chk "--count = 0" "0" "$C"
chk "imprime el resumen" "1" "$(printf '%s' "$O" | grep -c 'resumen: hecho=')"

echo "== ficha a la que le falta una seccion obligatoria: SALTADO =="
grep -v '^## Commits' "$S" | grep -v '^- `abc1234`' > "$S.tmp" && mv "$S.tmp" "$S"
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "avisa de la seccion" "1" "$(printf '%s' "$O" | grep -c 'ficha.secciones')"
chk "la nombra" "1" "$(printf '%s' "$O" | grep -c '## Commits')"
ficha_completa "$S"

echo "== Step 3a: pendientes abiertos sin reconciliar => PARCIAL, nunca HECHO =="
cat >> "$M/_pendientes.md" <<'EOF'
- [ ] uno sin tocar — _creado: 2026-09-01_ — _id: p-1111111111_
- [ ] dos sin tocar — _creado: 2026-09-01_ — _id: p-2222222222_
- [ ] tres tocado — _creado: 2026-09-01_ — _id: p-3333333333_
EOF
python3 - "$S" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Pendientes\n- Ninguno","## Pendientes\n- [ ] tres tocado — `p-3333333333` (Media)")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "PARCIAL en 3a" "1" "$(printf '%s' "$O" | grep -c 'PARCIAL .*pendientes.3a')"
chk "cuenta 1 de 3" "1" "$(printf '%s' "$O" | grep -c '1 de 3 revisados')"
chk "remite a /triage-3t" "1" "$(printf '%s' "$O" | grep -c 'pendientes.3a .*triage-3t')"

echo "== el id entre guiones bajos de cursiva SI se reconoce (el fallo real de \\b) =="
# Con `\b` de cierre, `_id: p-1111111111_` no casaba y el conteo mentia por defecto: 24 de 189
# en la memoria real que lo destapo. Este aserto es el que impide que vuelva.
chk "los 3 abiertos se ven (no 0)" "1" "$(printf '%s' "$O" | grep -c 'de 3 revisados')"

echo "== pendientes vencidos que la ficha no menciona: SALTADO =="
cat >> "$M/_pendientes.md" <<'EOF'
- [ ] vence hoy y nadie lo mira — _creado: 2026-09-01_ — _id: p-4444444444_ — _revisar: 2026-09-19_
- [ ] vence dentro de un mes — _creado: 2026-09-01_ — _id: p-5555555555_ — _revisar: 2026-10-19_
EOF
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "avisa del vencido" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.vencidos')"
chk "nombra el que vence hoy" "1" "$(printf '%s' "$O" | grep -c 'p-4444444444')"
chk "NO nombra el de octubre" "0" "$(printf '%s' "$O" | grep -c 'p-5555555555')"

echo "== plan enlazado sin bloque ## Estado y sin fila que apunte a la sesion: dos SALTADO =="
cat > "$M/plans/plan-demo.md" <<'EOF'
---
type: plan
---
# Plan demo

## Fases
- una
EOF
python3 - "$S" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Plans\n- Ninguno","## Plans\n- [[plans/plan-demo]] — tocado en esta sesion")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "plan sin ## Estado" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.estado')"
chk "fila del indice stale" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.indice')"
chk "da el comando de plan.upsert" "1" "$(printf '%s' "$O" | grep -c 'type plan.upsert')"

echo "== el mismo plan, ya con ## Estado y con su fila apuntando aqui: HECHO =="
cat > "$M/plans/plan-demo.md" <<'EOF'
---
type: plan
---
# Plan demo

## Estado
- Fase actual: 2
- Proxima accion: nada
- Bloqueo: ninguno
- Fecha: 2026-09-19

## Fases
- una
EOF
cat >> "$M/_plans-index.md" <<'EOF'
| [[plans/plan-demo\|Plan demo]] | active | 2026-09-19 | [[sessions/2026-09-19-demo]] | 0 | 0 |
EOF
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "plan.estado HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*plan.estado')"
chk "plan.indice HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*plan.indice')"

echo "== snippet que no nombra un pendiente que la sesion deja abierto: SALTADO =="
python3 - "$S" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Pendientes\n- [ ] tres tocado — `p-3333333333` (Media)",
            "## Pendientes\n- [ ] tres tocado — `p-3333333333` (Media)\n- [ ] nuevo de hoy — `p-6666666666` (Alta)")
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\nSigue abierto: tres tocado _id: p-3333333333_.\n```")
open(p,'w',encoding='utf-8').write(t)
PY
cat >> "$M/pendientes/2026-09.md" <<'EOF'
| 1 | tres tocado | Media | 2026-09-01 | | | |
EOF
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "avisa del que falta" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"
chk "lo nombra por id" "1" "$(printf '%s' "$O" | grep -c 'snippet.sigue_abierto' )"
chk "el id sale en el detalle" "1" "$(printf '%s' "$O" | grep -A2 'snippet.sigue_abierto' | grep -c '  - p-6666666666')"
chk "dual write: la fila mensual falta" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.dualwrite')"

echo "== bloque colapsado CON pendientes propios abiertos: SALTADO, no POR-DISENO =="
# El caso 5 de Step 8 colapsa el bloque cuando NO hay continuidad propia. Colapsarlo teniendo
# pendientes propios abiertos es la omision, no el caso permitido: bendecirlo como POR-DISENO
# convertiria al auditor en el que tapa el hueco. Lo encontro el adversario.
python3 - "$S" <<'PYFIN'
import sys, re
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=re.sub(r"## Como retomar\n.*?\n\n## Related", "## Como retomar\nNinguno.\n\n## Related", t, flags=re.S)
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "colapsado con continuidad propia = falla" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"
chk "y NO se bendice" "0" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*snippet.sigue_abierto')"

echo "== bloque colapsado SIN pendientes propios abiertos: POR-DISENO =="
python3 - "$S" <<'PYFIN'
import sys, re
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=re.sub(r"## Pendientes\n.*?\n\n## Commits", "## Pendientes\n- Ninguno\n\n## Commits", t, flags=re.S)
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "ese si es el caso 5" "1" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*snippet.sigue_abierto')"

echo "== linea RECONCILIACION: ausente, con numeros falsos, y correcta =="
# El contrato nuevo dice que recortar el conteo en silencio ya no es posible. Sin este chequeo esa
# frase seria falsa: era la unica afirmacion del cambio sin nada que la sostuviera.
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "ausente = SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.reconciliacion_linea')"
python3 - "$S" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Pendientes\n- Ninguno",
            "## Pendientes\nRECONCILIACION: 99 de 99 pendientes abiertos revisados — 0 sin revisar, barrido en /triage-3t\n- Ninguno")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "numeros falsos = SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.reconciliacion_linea')"
chk "dice lo medido" "1" "$(printf '%s' "$O" | grep -c 'declara 99 de 99')"
python3 - "$S" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("RECONCILIACION: 99 de 99 pendientes abiertos revisados — 0 sin revisar",
            "RECONCILIACION: 0 de 5 pendientes abiertos revisados — 5 sin revisar")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "numeros correctos = HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.reconciliacion_linea')"

echo "== research enlazado con recomendaciones sin marcar: SALTADO con el comando de Step 8d =="
cat > "$M/research/demo.md" <<'EOF'
---
type: research
---
# Research demo

## Recomendaciones
- [x] una hecha — implementada
- [ ] otra sin decidir
EOF
python3 - "$S" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Research\n- Ninguno","## Research\n- [[research/demo]] — parcialmente resuelto")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "avisa del research" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*research.recomendaciones')"
chk "remite a Step 8d" "1" "$(printf '%s' "$O" | grep -A3 'research.recomendaciones' | grep -c 'corrige:.*print-research-recomendaciones.py')"

echo "== wikilink de research ROTO: SALTADO, nunca un HECHO por no poder mirar =="
# Un enlace roto no es "sin recomendaciones": es que no se pudo mirar. La version anterior lo
# saltaba en silencio y devolvia HECHO. Lo encontro el adversario.
python3 - "$S" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("- [[research/demo]] — parcialmente resuelto","- [[research/no-existe]] — enlace roto")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "enlace roto = SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*research.recomendaciones')"
chk "lo dice" "1" "$(printf '%s' "$O" | grep -c '  - no-existe .* el archivo del research no existe')"
python3 - "$S" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("- [[research/no-existe]] — enlace roto","- [[research/demo]] — parcialmente resuelto")
open(p,'w',encoding='utf-8').write(t)
PYFIN

echo "== learning declarado cuyo topico no existe: SALTADO =="
python3 - "$S" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Learnings generados\n- Ninguno",
            "## Learnings generados\n- [[learnings/inexistente]] — regla nueva")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "avisa del topico roto" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*learnings.dualwrite')"

echo "== linea [x] rezagada en _pendientes.md: SALTADO =="
echo '- [x] esta ya se resolvio y nadie la saco — _id: p-7777777777_' >> "$M/_pendientes.md"
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "avisa de la rezagada" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.marcados')"

echo "== journal con evento sin aplicar: SALTADO con el comando de compactar =="
mkdir -p "$M/.journal/pending"; echo '{}' > "$M/.journal/pending/x.json"
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "avisa del journal" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*journal.limpio')"
chk "da el comando" "1" "$(printf '%s' "$O" | grep -A2 'journal.limpio' | grep -c 'corrige:.*journal-compact.py')"
rm -rf "$M/.journal"

echo "== ficha vieja sin fila en el indice: POR-DISENO (la podo Step 5b), no SALTADO =="
M2="$T/memory2"; nueva_memoria "$M2"
for n in 1 2 3; do ficha_completa "$M2/sessions/2026-09-2$n-nueva.md"; done
S2="$M2/sessions/2026-01-01-vieja.md"; ficha_completa "$S2"
O=$($AUD "$M2" --session-file "$S2" --no-git --hoy $HOY 2>&1)
chk "poda, no falla" "1" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*indice.sesion')"

echo "== ficha reciente que de verdad falta del indice: SALTADO =="
S3="$M2/sessions/2026-09-24-recentisima.md"; ficha_completa "$S3"
O=$($AUD "$M2" --session-file "$S3" --no-git --hoy $HOY 2>&1)
chk "esa si es falla" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*indice.sesion')"

echo "== ficha ilegible: error explicito, NUNCA un checkpoint limpio disfrazado =="
# Un DIRECTORIO donde va el fichero dispara el error en cualquier plataforma; chmod 000 no es
# Windows-safe (mismo hallazgo que test-check-active-research.sh).
mkdir -p "$M/sessions/rota.md"
rc=0; O=$($AUD "$M" --session-file "$M/sessions/rota.md" --no-git --hoy $HOY 2>&1) || rc=$?
chk "sale con error" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
chk "lo dice" "1" "$(printf '%s' "$O" | grep -c 'no se pudo leer')"

echo "== directorio de memoria inexistente: error, no silencio =="
rc=0; O=$($AUD "$T/no-existe" --session-file "$S" --no-git 2>&1) || rc=$?
chk "sale con error" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

echo "== un id NOMBRADO DE PASO fuera de ## Pendientes no cuenta como revisado =="
# El hueco decisivo que encontro el adversario: buscar el id en TODO el texto mide MENCION, no
# reconciliacion. Una ficha que nombra de pasada un pendiente vencido hoy y dice explicitamente que
# no lo reviso salia HECHO en 3a y en vencidos -- el instrumento blanqueaba el hueco que existe
# para romper.
M3="$T/memory3"; nueva_memoria "$M3"
cat >> "$M3/_pendientes.md" <<'EOF'
- [ ] vence hoy y solo se cita de paso — _creado: 2026-09-01_ — _id: p-8888888888_ — _revisar: 2026-09-19_
EOF
S4="$M3/sessions/2026-09-19-demo.md"; ficha_completa "$S4"
python3 - "$S4" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Contexto\nalgo",
            "## Contexto\nDe paso: p-8888888888 se menciona aqui. No se reviso su vencimiento hoy.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M3" --session-file "$S4" --no-git --hoy $HOY 2>&1)
chk "la mencion NO lo da por revisado" "1" "$(printf '%s' "$O" | grep -c 'PARCIAL .*pendientes.3a')"
chk "y sigue saliendo como vencido" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.vencidos')"
chk "lo nombra" "1" "$(printf '%s' "$O" | grep -c '  - p-8888888888 (revisar 2026-09-19)')"

echo "== la linea RECONCILIACION: fuera de ## Pendientes no vale =="
python3 - "$S4" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Contexto\nDe paso:",
            "## Contexto\nRECONCILIACION: 1 de 1 pendientes abiertos revisados — 0 sin revisar, barrido en /triage-3t\nDe paso:")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M3" --session-file "$S4" --no-git --hoy $HOY 2>&1)
chk "en otra seccion no cuenta" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.reconciliacion_linea')"

echo "== ficha anterior a 2.28.0 sin la linea: POR-DISENO, no SALTADO =="
S5="$M3/sessions/2026-09-10-vieja.md"; ficha_completa "$S5"
python3 - "$S5" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
open(p,'w',encoding='utf-8').write(t.replace("date: 2026-09-19","date: 2026-09-10"))
PYFIN
O=$($AUD "$M3" --session-file "$S5" --no-git --hoy $HOY 2>&1)
chk "no se le exige lo que no existia" "1" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*pendientes.reconciliacion_linea')"

echo "== Sigue abierto: un pendiente con _revisar FUTURO no es omision (regla de Step 8) =="
M4="$T/memory4"; nueva_memoria "$M4"
cat >> "$M4/_pendientes.md" <<'EOF'
- [ ] este va al calendario, no al snippet — _creado: 2026-09-19_ — _id: p-9999999999_ — _revisar: 2026-09-25_
EOF
cat >> "$M4/pendientes/2026-09.md" <<'EOF'
| 1 | este va al calendario, no al snippet | Media | 2026-09-19 | | | |
EOF
S6="$M4/sessions/2026-09-19-demo.md"; ficha_completa "$S6"
python3 - "$S6" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Pendientes\n- Ninguno",
            "## Pendientes\nRECONCILIACION: 1 de 1 pendientes abiertos revisados — 0 sin revisar, barrido en /triage-3t\n- [ ] este va al calendario — `p-9999999999` (Media)")
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\nProximo paso: otra cosa.\n```")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M4" --session-file "$S6" --no-git --hoy $HOY 2>&1)
chk "no lo marca como omision" "0" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"
chk "y lo dice" "1" "$(printf '%s' "$O" | grep -c 'revisar` futuro van al bloque de calendario')"

echo "== Sigue abierto: tope de 3 + '+N mas' cubre a los que faltan =="
cat >> "$M4/_pendientes.md" <<'EOF'
- [ ] uno — _creado: 2026-09-19_ — _id: p-aaaaaaaaa1_
- [ ] dos — _creado: 2026-09-19_ — _id: p-aaaaaaaaa2_
- [ ] tres — _creado: 2026-09-19_ — _id: p-aaaaaaaaa3_
- [ ] cuatro — _creado: 2026-09-19_ — _id: p-aaaaaaaaa4_
EOF
python3 - "$S6" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("RECONCILIACION: 1 de 1 pendientes abiertos revisados — 0 sin revisar",
            "RECONCILIACION: 5 de 5 pendientes abiertos revisados — 0 sin revisar")
t=t.replace("- [ ] este va al calendario — `p-9999999999` (Media)",
            "- [ ] este va al calendario — `p-9999999999` (Media)\n- [ ] uno — `p-aaaaaaaaa1`\n- [ ] dos — `p-aaaaaaaaa2`\n- [ ] tres — `p-aaaaaaaaa3`\n- [ ] cuatro — `p-aaaaaaaaa4`")
t=t.replace("Proximo paso: otra cosa.",
            "Proximo paso: otra cosa.\n\nSigue abierto: uno _id: p-aaaaaaaaa1_ · dos _id: p-aaaaaaaaa2_ · tres _id: p-aaaaaaaaa3_ · +1 mas en _pendientes.md.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
cat >> "$M4/pendientes/2026-09.md" <<'EOF'
| 2 | uno | Media | 2026-09-19 | | | |
| 3 | dos | Media | 2026-09-19 | | | |
| 4 | tres | Media | 2026-09-19 | | | |
| 5 | cuatro | Media | 2026-09-19 | | | |
EOF
O=$($AUD "$M4" --session-file "$S6" --no-git --hoy $HOY 2>&1)
chk "el tope no es omision" "1" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*snippet.sigue_abierto')"
chk "y no sale como SALTADO" "0" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"

echo "== pero sin tope alcanzado ni '+N mas', el que falta SI es omision =="
python3 - "$S6" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("Sigue abierto: uno _id: p-aaaaaaaaa1_ · dos _id: p-aaaaaaaaa2_ · tres _id: p-aaaaaaaaa3_ · +1 mas en _pendientes.md.",
            "Sigue abierto: uno _id: p-aaaaaaaaa1_.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M4" --session-file "$S6" --no-git --hoy $HOY 2>&1)
chk "3 sin nombrar y sin tope = SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"

echo "== EXPLOIT 1: un '+N mas' inventado no tapa nada =="
# Construido por dos adversarios independientes: `Sigue abierto: +1 mas en _pendientes.md.` sin
# nombrar a NADIE daba POR-DISENO y escondia diez pendientes abiertos. Ahora se comprueba la
# aritmetica: 3 nombrados de verdad + N == omitidos reales.
M5="$T/memory5"; nueva_memoria "$M5"
for n in 1 2 3 4 5; do
  echo "- [ ] pend $n — _creado: 2026-09-19_ — _id: p-bbbbbbbbb$n_" >> "$M5/_pendientes.md"
  echo "| $n | pend $n | Media | 2026-09-19 | | | |" >> "$M5/pendientes/2026-09.md"
done
S7="$M5/sessions/2026-09-19-demo.md"; ficha_completa "$S7"
python3 - "$S7" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
filas="\n".join("- [ ] pend %d — `p-bbbbbbbbb%d`" % (n,n) for n in range(1,6))
t=t.replace("## Pendientes\n- Ninguno",
            "## Pendientes\nRECONCILIACION: 5 de 5 pendientes abiertos revisados — 0 sin revisar, barrido en /triage-3t\n"+filas)
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\nProximo paso: algo.\n\nSigue abierto: +1 mas en _pendientes.md.\n```")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M5" --session-file "$S7" --no-git --hoy $HOY 2>&1)
chk "cero nombrados + marcador falso = SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"
chk "y NO se bendice" "0" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*snippet.sigue_abierto')"

echo "== tope legitimo: 3 nombrados y la N correcta =="
python3 - "$S7" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("Sigue abierto: +1 mas en _pendientes.md.",
            "Sigue abierto: uno _id: p-bbbbbbbbb1_ · dos _id: p-bbbbbbbbb2_ · tres _id: p-bbbbbbbbb3_ · +2 mas en _pendientes.md.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M5" --session-file "$S7" --no-git --hoy $HOY 2>&1)
chk "3 nombrados + N correcta = POR-DISENO" "1" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*snippet.sigue_abierto')"

echo "== la N equivocada NO vale =="
python3 - "$S7" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("· +2 mas en _pendientes.md.","· +9 mas en _pendientes.md.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M5" --session-file "$S7" --no-git --hoy $HOY 2>&1)
chk "N falsa = SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"

echo "== EXPLOIT 2: prosa dentro de ## Pendientes no es reconciliacion =="
# El adversario metio en `## Pendientes` la frase "no llegamos a revisar p-xxx" junto a una linea
# RECONCILIACION calculada del mismo proxy, y el audit devolvia HECHO en las tres comprobaciones.
M6="$T/memory6"; nueva_memoria "$M6"
cat >> "$M6/_pendientes.md" <<'EOF'
- [ ] vence hoy y nadie lo reviso — _creado: 2026-09-01_ — _id: p-cccccccccc_ — _revisar: 2026-09-19_
EOF
S8="$M6/sessions/2026-09-19-demo.md"; ficha_completa "$S8"
python3 - "$S8" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Pendientes\n- Ninguno",
            "## Pendientes\nRECONCILIACION: 1 de 1 pendientes abiertos revisados — 0 sin revisar, barrido en /triage-3t\nNota aparte: no llegamos a revisar p-cccccccccc hoy, queda pendiente de verdad.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M6" --session-file "$S8" --no-git --hoy $HOY 2>&1)
chk "3a no lo da por revisado" "1" "$(printf '%s' "$O" | grep -c 'PARCIAL .*pendientes.3a')"
chk "sigue saliendo vencido" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.vencidos')"
chk "y la linea RECONCILIACION ya no cuadra" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.reconciliacion_linea')"

echo "== la MISMA ficha, con la linea de lista de verdad: HECHO =="
python3 - "$S8" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("Nota aparte: no llegamos a revisar p-cccccccccc hoy, queda pendiente de verdad.",
            "- [ ] vence hoy y nadie lo reviso — `p-cccccccccc` (still-open)")
open(p,'w',encoding='utf-8').write(t)
PYFIN
cat >> "$M6/pendientes/2026-09.md" <<'EOF'
| 1 | vence hoy y nadie lo reviso | Media | 2026-09-01 | | | |
EOF
O=$($AUD "$M6" --session-file "$S8" --no-git --hoy $HOY 2>&1)
chk "la linea de lista si cuenta" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.3a')"
chk "y ya no sale vencido" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.vencidos')"

echo "== un id aparcado en Recordatorios SIN bloque real no cuenta =="
python3 - "$S8" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("- [ ] vence hoy y nadie lo reviso — `p-cccccccccc` (still-open)","- Ninguno")
t=t.replace("## Commits","## Recordatorios de calendario\nAparcado aqui sin bloque: p-cccccccccc\n\n## Commits")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M6" --session-file "$S8" --no-git --hoy $HOY 2>&1)
chk "sin bloque ### fecha no cuenta" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.vencidos')"

echo "== con el bloque ### fecha de Step 8c-2, si cuenta =="
python3 - "$S8" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("Aparcado aqui sin bloque: p-cccccccccc",
            "### 2026-09-19 — [demo] Revisar el pendiente\nTítulo: [demo] Revisar el pendiente\nDescripción: p-cccccccccc")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M6" --session-file "$S8" --no-git --hoy $HOY 2>&1)
chk "con bloque real si cuenta" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.vencidos')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
