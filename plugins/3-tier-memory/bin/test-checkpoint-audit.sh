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
# El corrige: impreso se EJECUTA tal cual (solo se sustituye <SESSION_FILE>): antes pasaba
# "$MEMORY_DIR" de mas y el script salia 2 con "uso: ..." — p-01a16467ad.
CMD=$(printf '%s' "$O" | grep -A3 'research.recomendaciones' | grep 'corrige:' | sed 's/.*corrige: //')
CMD=${CMD//<SESSION_FILE>/\"$S\"}
set +e; SAL=$(JBIN="$BIN" MEMORY_DIR="$M" bash -c "$CMD" 2>&1); RC=$?; set -e
chk "el corrige impreso corre con exit 0" "0" "$RC"
chk "el corrige impreso lista la recomendacion sin marcar" "1" "$(printf '%s' "$SAL" | grep -c 'otra sin decidir')"
chk "dice que le falta pendiente" "1" "$(printf '%s' "$O" | grep -c 'demo — sin pendiente que la lleve')"

echo "== 2.44.0: la recomendacion sin marcar que cita un pendiente abierto: HECHO (va por las capas del cierre) =="
sed -i.bak 's/^- \[ \] otra sin decidir$/- [ ] otra sin decidir — la lleva p-2222222222/' "$M/research/demo.md" && rm -f "$M/research/demo.md.bak"
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "HECHO con dueno abierto" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*research.recomendaciones')"
echo "== 2.44.0: si su pendiente ya no esta abierto: SALTADO =="
sed -i.bak 's/la lleva p-2222222222/la lleva p-7a7a7a7a7a/' "$M/research/demo.md" && rm -f "$M/research/demo.md.bak"
O=$($AUD "$M" --session-file "$S" --no-git --hoy $HOY 2>&1)
chk "SALTADO con dueno cerrado" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*research.recomendaciones')"
chk "lo dice" "1" "$(printf '%s' "$O" | grep -c 'su pendiente ya no esta abierto (p-7a7a7a7a7a)')"
sed -i.bak 's/ — la lleva p-7a7a7a7a7a$//' "$M/research/demo.md" && rm -f "$M/research/demo.md.bak"

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

echo "== el tope solo vale desde la linea 'Sigue abierto:', no desde otro renglon =="
# El marcador y los nombres se buscaban en TODO el bloque `## Como retomar`, asi que tres ids y un
# `+N mas` correcto escritos dentro de `No repitas:` daban POR-DISENO. Lo encontro un verificador
# externo.
python3 - "$S7" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("Sigue abierto: uno _id: p-bbbbbbbbb1_ · dos _id: p-bbbbbbbbb2_ · tres _id: p-bbbbbbbbb3_ · +9 mas en _pendientes.md.",
            "No repitas: uno _id: p-bbbbbbbbb1_ · dos _id: p-bbbbbbbbb2_ · tres _id: p-bbbbbbbbb3_ · +2 mas en _pendientes.md.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M5" --session-file "$S7" --no-git --hoy $HOY 2>&1)
chk "en otra linea no cuenta" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"

echo "== dos marcadores que se contradicen: no vale =="
python3 - "$S7" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("No repitas: uno _id: p-bbbbbbbbb1_ · dos _id: p-bbbbbbbbb2_ · tres _id: p-bbbbbbbbb3_ · +2 mas en _pendientes.md.",
            "Sigue abierto: uno _id: p-bbbbbbbbb1_ · dos _id: p-bbbbbbbbb2_ · tres _id: p-bbbbbbbbb3_ · +2 mas en _pendientes.md, o +7 mas si cuentas los viejos.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M5" --session-file "$S7" --no-git --hoy $HOY 2>&1)
chk "uno correcto y otro falso = SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"

echo "== y con el marcador unico y correcto en su linea: POR-DISENO =="
python3 - "$S7" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace(" +2 mas en _pendientes.md, o +7 mas si cuentas los viejos."," +2 mas en _pendientes.md.")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M5" --session-file "$S7" --no-git --hoy $HOY 2>&1)
chk "vuelve a valer" "1" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*snippet.sigue_abierto')"

echo "== un id repetido en dos lineas abiertas: SALTADO, y no infla el conteo =="
# Los dos salieron dogfoodeando el primer checkpoint real: _pendientes.md tenia 3 ids duplicados,
# el conteo por LINEA los contaba dos veces, y la linea RECONCILIACION correcta salia rechazada.
M7="$T/memory7"; nueva_memoria "$M7"
cat >> "$M7/_pendientes.md" <<'EOF'
- [ ] uno — _creado: 2026-09-01_ — _id: p-dddddddddd_
- [ ] uno otra vez, por error — _creado: 2026-09-01_ — _id: p-dddddddddd_
- [ ] dos — _creado: 2026-09-01_ — _id: p-eeeeeeeeee_
EOF
cat >> "$M7/pendientes/2026-09.md" <<'EOF'
| 1 | uno | Media | 2026-09-01 | | | |
| 2 | dos | Media | 2026-09-01 | | | |
EOF
S9="$M7/sessions/2026-09-19-demo.md"; ficha_completa "$S9"
python3 - "$S9" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Pendientes\n- Ninguno",
            "## Pendientes\nRECONCILIACION: 1 de 2 pendientes abiertos revisados — 1 sin revisar, barrido en /triage-3t\n- [ ] uno — `p-dddddddddd`")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M7" --session-file "$S9" --no-git --hoy $HOY 2>&1)
chk "avisa del duplicado" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*pendientes.duplicados')"
chk "lo nombra" "1" "$(printf '%s' "$O" | grep -A2 'pendientes.duplicados' | grep -c '  - p-dddddddddd')"
chk "cuenta 2 distintos, no 3 lineas" "1" "$(printf '%s' "$O" | grep -c '1 de 2 revisados')"
chk "y la linea RECONCILIACION cuadra" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.reconciliacion_linea')"

echo "== sin duplicados: HECHO =="
python3 - "$M7/_pendientes.md" <<'PYFIN'
import sys
p=sys.argv[1]
ls=[l for l in open(p,encoding='utf-8') if 'uno otra vez' not in l]
open(p,'w',encoding='utf-8').writelines(ls)
PYFIN
O=$($AUD "$M7" --session-file "$S9" --no-git --hoy $HOY 2>&1)
chk "sin duplicados" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.duplicados')"

echo "== el placeholder de Step 8 no es una omision: POR-DISENO =="
# Step 7a corre ANTES de Step 8 en el template, asi que el audit ve `<filled in Step 8>`. Marcarlo
# SALTADO ponia un falso positivo en CADA checkpoint. Salio en el primer uso real.
python3 - "$S9" <<'PYFIN'
import sys, re
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=re.sub(r"## Como retomar\n.*?\n\n## Related",
         "## Como retomar\n<filled in Step 8>\n\n## Related", t, flags=re.S)
t=t.replace("- [ ] uno — `p-dddddddddd`","- [ ] uno — `p-dddddddddd`\n- [ ] dos — `p-eeeeeeeeee`")
t=t.replace("RECONCILIACION: 1 de 2","RECONCILIACION: 2 de 2").replace("— 1 sin revisar","— 0 sin revisar")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M7" --session-file "$S9" --no-git --hoy $HOY 2>&1)
chk "el placeholder no es falla" "1" "$(printf '%s' "$O" | grep -c 'POR-DISEÑO .*snippet.sigue_abierto')"
chk "y NO sale como SALTADO" "0" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.sigue_abierto')"

echo "== un pendiente que CITA el id de otro no se roba su identidad =="
# El fallo que destapo el primer checkpoint real: el id de una linea se tomaba del primer `p-…`
# que apareciera, asi que un pendiente cuyo texto cita otros ids perdia el suyo y le sumaba una
# repeticion falsa al citado. Los 3 "duplicados" que reporto el audit en datos reales eran los
# tres este mismo fallo.
M8="$T/memory8"; nueva_memoria "$M8"
cat >> "$M8/_pendientes.md" <<'EOF'
- [ ] arreglar el parser — _creado: 2026-09-01_ — _id: p-1010101010_
- [ ] el fix de p-1010101010 sigue sin verificarse en produccion — _creado: 2026-09-01_ — _id: p-2020202020_
EOF
cat >> "$M8/pendientes/2026-09.md" <<'EOF'
| 1 | arreglar el parser | Media | 2026-09-01 | | | |
| 2 | verificar el fix | Media | 2026-09-01 | | | |
EOF
SA="$M8/sessions/2026-09-19-demo.md"; ficha_completa "$SA"
python3 - "$SA" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Pendientes\n- Ninguno",
            "## Pendientes\nRECONCILIACION: 0 de 2 pendientes abiertos revisados — 2 sin revisar, barrido en /triage-3t\n- Ninguno")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M8" --session-file "$SA" --no-git --hoy $HOY 2>&1)
chk "no inventa duplicados" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.duplicados')"
chk "cuenta los 2 distintos" "1" "$(printf '%s' "$O" | grep -c '0 de 2 revisados')"

echo "== y reconciliar el que cita se le atribuye a EL, no al citado =="
python3 - "$SA" <<'PYFIN'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("RECONCILIACION: 0 de 2 pendientes abiertos revisados — 2 sin revisar",
            "RECONCILIACION: 1 de 2 pendientes abiertos revisados — 1 sin revisar")
t=t.replace("- Ninguno\n\n## Commits","- [ ] verificar el fix — `p-2020202020`\n\n## Commits")
open(p,'w',encoding='utf-8').write(t)
PYFIN
O=$($AUD "$M8" --session-file "$SA" --no-git --hoy $HOY 2>&1)
chk "cuenta 1 de 2" "1" "$(printf '%s' "$O" | grep -c '1 de 2 revisados')"
chk "la linea cuadra" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.reconciliacion_linea')"

echo "== header_unrecognized de repair-research-index.py NO se pierde en el cierre (p-ccc013b53d) =="
# Mismo patron que motivo este archivo (header_issues=1 de repair-dualwrite, tres veces sin
# reportar): una tabla de research con una columna que el reparador no puede leer sin adivinar
# (aqui, "Session" sosteniendo el wikilink real en vez de ser metadata) se queda de solo lectura
# para siempre si nadie la mide en cada cierre.
M9="$T/memory9"; nueva_memoria "$M9"
cat > "$M9/_research-index.md" <<'EOF'
# Research

## Active Research

| Tema | Next step | Origen | Archivo |
|---|---|---|---|

## Completed Research

| Topic | Result | Session |
|-------|--------|---------|
| Tema de prueba | Resultado de prueba | [[research/tema-de-prueba]] |
EOF
S9="$M9/sessions/2026-09-19-demo.md"; ficha_completa "$S9"
O=$($AUD "$M9" --session-file "$S9" --no-git --hoy $HOY 2>&1)
chk "sale SALTADO, no se calla" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*avisos.scripts.research-index')"
chk "nombra la clave exacta" "1" "$(printf '%s' "$O" | grep -c 'completed_header_unrecognized=1')"
chk "no trae arreglo automatico" "1" "$(printf '%s' "$O" | grep -c 'ninguno automatico: son migraciones o ambiguedades')"

echo "== un reparador que CRASHEA (exit!=0, solo stderr) no se confunde con 'sin avisos' =="
# Confirmado por el adversario externo (ronda de p-ccc013b53d): repair-research-index.py sale con
# codigo 1 y solo stderr cuando no puede LEER _research-index.md (bytes invalidos, permisos). Sin
# chequear returncode, avisos_script_en_seco no encontraba ninguna clave conocida en ese stderr y
# reportaba HECHO "sin avisos" — el mismo falso negativo silencioso que este archivo entero existe
# para cerrar, solo que en la propia auditoria.
M11="$T/memory11"; nueva_memoria "$M11"
printf '# Research\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n\xff\xfe bytes invalidos\n' > "$M11/_research-index.md"
S11="$M11/sessions/2026-09-19-demo.md"; ficha_completa "$S11"
O=$($AUD "$M11" --session-file "$S11" --no-git --hoy $HOY 2>&1)
chk "sale SALTADO, no HECHO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*avisos.scripts.research-index')"
chk "nombra el codigo de salida" "1" "$(printf '%s' "$O" | grep -c 'codigo 1')"
chk "NO sale como HECHO" "0" "$(printf '%s' "$O" | grep -c 'HECHO .*avisos.scripts.research-index')"

echo "== y una tabla de research canonica no dispara nada =="
M10="$T/memory10"; nueva_memoria "$M10"
cat > "$M10/_research-index.md" <<'EOF'
# Research

## Active Research

| Tema | Next step | Origen | Archivo |
|---|---|---|---|

## Completed Research

| Tema | Resultado | Archivo |
|---|---|---|
| Tema de prueba | Resultado de prueba | [[research/tema-de-prueba]] |
EOF
S10="$M10/sessions/2026-09-19-demo.md"; ficha_completa "$S10"
O=$($AUD "$M10" --session-file "$S10" --no-git --hoy $HOY 2>&1)
chk "HECHO, sin avisos" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*avisos.scripts.research-index')"

echo "== plan.mencionado_no_enlazado: nombrado por ruta en el snippet, ## Plans dice Ninguno =="
# Caso real: claude-vzert, 2026-09-22-verificacion-cierre-pr238.md. `## Plans` decia "Ninguno —
# sin cambios al plan desde el checkpoint anterior" y el snippet nombraba el plan por ruta en
# prosa suelta en vez de enlazarlo y dejar que el caso 1 de <next-step> leyera su ## Estado.
M12="$T/memory12"; nueva_memoria "$M12"
S12="$M12/sessions/2026-09-19-demo.md"; ficha_completa "$S12"
cat > "$M12/plans/plan-demo.md" <<'EOF'
---
type: plan
---
# Plan demo

## Estado
- Fase actual: 7
- Proxima accion: pieza 3
EOF
python3 - "$S12" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: verificacion puntual.\n\n"
            "Proximo paso: revisar pendientes; el trabajo activo real es la Fase 7, "
            "ver memory/plans/plan-demo.md.\n```")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M12" --session-file "$S12" --no-git --hoy $HOY 2>&1)
chk "avisa del plan sin enlazar" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.mencionado_no_enlazado')"
chk "lo nombra por ruta" "1" "$(printf '%s' "$O" | grep -c 'plans/plan-demo.md')"

echo "== el mismo caso, pero ## Plans SI lo enlaza: HECHO =="
python3 - "$S12" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Plans\n- Ninguno", "## Plans\n- [[plans/plan-demo]] — sin cambios de contenido")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M12" --session-file "$S12" --no-git --hoy $HOY 2>&1)
chk "ya no avisa" "0" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.mencionado_no_enlazado')"
chk "sale HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*plan.mencionado_no_enlazado')"

echo "== wikilink con ruta relativa ../plans/x tambien cuenta como enlazado (no es falso positivo) =="
# Encontrado en el barrido de sombra contra claude-vzert (pr199-rescate-bloque-b,
# candidatos-upstream-2195-2315): [[../plans/x]] es un wikilink valido, WIKILINK_PLAN no lo casa
# por el prefijo `../`, y comparar solo contra el regex estricto marcaba un plan ya enlazado como
# si no lo estuviera.
python3 - "$S12" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("- [[plans/plan-demo]] — sin cambios de contenido",
            "- [[../plans/plan-demo]] — sin cambios de contenido")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M12" --session-file "$S12" --no-git --hoy $HOY 2>&1)
chk "sigue HECHO con ../plans/" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*plan.mencionado_no_enlazado')"

echo "== snippet.futuro_duplicado: un id reservado por el calendario reaparece en Sigue abierto =="
# Casos reales: claude-vzert, 2026-09-18-verificar-avance-pr192-censo-grep.md y
# 2026-09-19-restos-213-pr220.md. El mismo id vencia en ## Recordatorios de calendario Y volvia a
# aparecer en la linea `Sigue abierto:` del bloque de hoy.
M13="$T/memory13"; nueva_memoria "$M13"
S13="$M13/sessions/2026-09-19-demo.md"; ficha_completa "$S13"
python3 - "$S13" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace(
    "## Como retomar\nNinguno — la sesion cerro sin continuidad.",
    "## Como retomar\n\n```\nRetomamos: demo.\n\n"
    "Sigue abierto: disco al 97% _id: p-b25ac1ef68_.\n```\n\n"
    "## Recordatorios de calendario\n\n"
    "### 2026-09-25 — [demo] revisar disco otra vez\n\n"
    "```\n"
    "Retomamos: medir disco del VPS otra vez _id: p-b25ac1ef68_\n"
    "```")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M13" --session-file "$S13" --no-git --hoy $HOY 2>&1)
chk "avisa del duplicado" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.futuro_duplicado')"
chk "nombra el id" "1" "$(printf '%s' "$O" | grep -A1 'snippet.futuro_duplicado' | grep -c 'p-b25ac1ef68')"

echo "== el mismo id, pero solo citado en Proximo paso como motivo del caso 5: NO es duplicado =="
# Dos falsos positivos reales de esta forma (remedicion-goalspec-precondicion-no-cumplida,
# nudge-devs-encendido) antes de acotar el check a la linea Sigue abierto: unicamente. Citar el id
# para explicar por que no hay nada accionable hoy no es lo mismo que listarlo como pendiente.
M14="$T/memory14"; nueva_memoria "$M14"
S14="$M14/sessions/2026-09-19-demo.md"; ficha_completa "$S14"
python3 - "$S14" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace(
    "## Como retomar\nNinguno — la sesion cerro sin continuidad.",
    "## Como retomar\n\n```\nRetomamos: demo.\n\n"
    "Proximo paso: ninguno -- el pendiente de esta sesion queda con fecha futura "
    "_id: p-b25ac1ef68_, ver Recordatorios de calendario.\n\n"
    "Sigue abierto: otro pendiente sin relacion _id: p-1111111111_.\n```\n\n"
    "## Recordatorios de calendario\n\n"
    "### 2026-09-25 — [demo] revisar disco otra vez\n\n"
    "```\n"
    "Retomamos: medir disco del VPS otra vez _id: p-b25ac1ef68_\n"
    "```")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M14" --session-file "$S14" --no-git --hoy $HOY 2>&1)
chk "no lo marca como duplicado" "0" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.futuro_duplicado')"
chk "sale HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*snippet.futuro_duplicado')"

echo "== sin bloque de calendario: no aplica =="
O=$($AUD "$M9" --session-file "$S9" --no-git --hoy $HOY 2>&1)
chk "HECHO, no aplica" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*snippet.futuro_duplicado.*no aplica')"

echo "== plan.mencionado_no_enlazado: 'sin cambios en plans/x' en prosa NO es un enlace =="
# Hallazgo del adversario (ronda 1, 2.32.0): el respaldo anterior por substring `plans/{p} in
# sec_plans` aceptaba CUALQUIER texto que contuviera la subcadena, no solo un wikilink real. Con
# "Ninguno — sin cambios en plans/plan-demo (sigue igual)." el plan seguia sin estar enlazado de
# verdad y el check debe seguir avisando.
M15="$T/memory15"; nueva_memoria "$M15"
S15="$M15/sessions/2026-09-19-demo.md"; ficha_completa "$S15"
python3 - "$S15" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Plans\n- Ninguno",
            "## Plans\n- Ninguno — sin cambios en plans/plan-demo (sigue igual).")
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\n"
            "Proximo paso: revisar pendientes; ver memory/plans/plan-demo.md.\n```")
open(p,'w',encoding='utf-8').write(t)
PY
cat > "$M15/plans/plan-demo.md" <<'EOF'
---
type: plan
---
# Plan demo

## Estado
- Fase actual: 1
EOF
O=$($AUD "$M15" --session-file "$S15" --no-git --hoy $HOY 2>&1)
chk "prosa que solo MENCIONA la ruta no cuenta como enlace" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.mencionado_no_enlazado')"

echo "== plan.mencionado_no_enlazado: prefijo de slug no confunde plan-x con plan-x-v2 =="
# Hallazgo del adversario: comparar por substring dejaba pasar la mencion de `plan-x` cuando lo
# enlazado era `plan-x-v2` (mismo prefijo). Con WIKILINK_PLAN_LAXO + comparacion por slug exacto,
# ambos siguen siendo planes DISTINTOS y el mencionado sin enlazar debe seguir avisando.
M16="$T/memory16"; nueva_memoria "$M16"
S16="$M16/sessions/2026-09-19-demo.md"; ficha_completa "$S16"
python3 - "$S16" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Plans\n- Ninguno", "## Plans\n- [[plans/plan-demo-v2]] — otro plan, mismo prefijo")
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\n"
            "Proximo paso: revisar pendientes; ver memory/plans/plan-demo.md.\n```")
open(p,'w',encoding='utf-8').write(t)
PY
cat > "$M16/plans/plan-demo.md" <<'EOF'
---
type: plan
---
# Plan demo

## Estado
- Fase actual: 1
EOF
cat > "$M16/plans/plan-demo-v2.md" <<'EOF'
---
type: plan
---
# Plan demo v2

## Estado
- Fase actual: 1
EOF
O=$($AUD "$M16" --session-file "$S16" --no-git --hoy $HOY 2>&1)
chk "plan-demo distinto de plan-demo-v2, sigue avisando" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.mencionado_no_enlazado')"

echo "== plan.mencionado_no_enlazado: mencion en 'No repitas' no es 'proximo paso' =="
# Hallazgo del adversario: "No repitas: el enfoque de memory/plans/plan-demo.md ya se descarto"
# citaba la ruta de un plan sin afirmar que sea el proximo paso. Contarlo ahi era un falso
# positivo real. El check ahora solo mira las lineas `Proximo paso:` y `Lee `.
M17="$T/memory17"; nueva_memoria "$M17"
S17="$M17/sessions/2026-09-19-demo.md"; ficha_completa "$S17"
python3 - "$S17" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\n"
            "Proximo paso: revisar _pendientes.md y proponer siguiente prioridad.\n\n"
            "No repitas: el enfoque de memory/plans/plan-demo.md ya se descarto.\n```")
open(p,'w',encoding='utf-8').write(t)
PY
cat > "$M17/plans/plan-demo.md" <<'EOF'
---
type: plan
---
# Plan demo

## Estado
- Fase actual: 1
EOF
O=$($AUD "$M17" --session-file "$S17" --no-git --hoy $HOY 2>&1)
chk "mencion en No repitas no dispara" "0" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.mencionado_no_enlazado')"
chk "sale HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*plan.mencionado_no_enlazado')"

echo "== plan.mencionado_no_enlazado: ruta de otra convencion (docs/plans/) no dispara =="
# Hallazgo del adversario: \bplans/ casaba con CUALQUIER `*/plans/*.md`, no solo `memory/plans/`.
# En un repo con la convencion docs/plans/ eso era un SALTADO garantizado sobre algo que no es
# "un plan de este proyecto sin enlazar".
M18="$T/memory18"; nueva_memoria "$M18"
S18="$M18/sessions/2026-09-19-demo.md"; ficha_completa "$S18"
python3 - "$S18" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\n"
            "Proximo paso: implementar la tarea 3 de docs/plans/2026-09-rollout.md en el repo de workspace.\n```")
open(p,'w',encoding='utf-8').write(t)
PY
O=$($AUD "$M18" --session-file "$S18" --no-git --hoy $HOY 2>&1)
chk "ruta docs/plans/ no dispara" "0" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.mencionado_no_enlazado')"

echo "== plan.mencionado_no_enlazado: wikilink con .md o #ancla sigue siendo el mismo plan =="
# Hallazgo del adversario (ronda 3): [[plans/x.md]] y [[plans/x#Estado]] son wikilinks reales al
# mismo plan `x`, pero la comparacion por slug exacto los perdia por la extension/ancla de mas.
M19="$T/memory19"; nueva_memoria "$M19"
S19="$M19/sessions/2026-09-19-demo.md"; ficha_completa "$S19"
python3 - "$S19" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Plans\n- Ninguno", "## Plans\n- [[plans/plan-demo.md#Estado]] — enlazado con ancla")
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\n"
            "Proximo paso: revisar pendientes; ver memory/plans/plan-demo.md.\n```")
open(p,'w',encoding='utf-8').write(t)
PY
cat > "$M19/plans/plan-demo.md" <<'EOF'
---
type: plan
---
# Plan demo

## Estado
- Fase actual: 1
EOF
O=$($AUD "$M19" --session-file "$S19" --no-git --hoy $HOY 2>&1)
chk "wikilink con .md y #ancla sigue contando como enlazado" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*plan.mencionado_no_enlazado')"

echo "== plan.mencionado_no_enlazado: 'Próximo paso:' con tilde y '**negrita**' tambien se revisan =="
# Hallazgo del adversario (ronda 3): el filtro de linea solo reconocia 'proximo paso:' sin tilde
# y sin markdown — dos formas reales del corpus que antes se saltaban sin aviso.
M20="$T/memory20"; nueva_memoria "$M20"
S20="$M20/sessions/2026-09-19-demo.md"; ficha_completa "$S20"
python3 - "$S20" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
            "## Como retomar\n\n```\nRetomamos: demo.\n\n"
            "**Próximo paso:** revisar pendientes; ver memory/plans/plan-demo.md.\n```")
open(p,'w',encoding='utf-8').write(t)
PY
cat > "$M20/plans/plan-demo.md" <<'EOF'
---
type: plan
---
# Plan demo

## Estado
- Fase actual: 1
EOF
O=$($AUD "$M20" --session-file "$S20" --no-git --hoy $HOY 2>&1)
chk "tilde + negrita en Proximo paso tambien se revisan" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*plan.mencionado_no_enlazado')"

# ================================================================================================
# 2.33.0 — p-daf3051915: `Proximo paso:` (snippet.proximo_paso). Fixtures REALES de la sesion
# 5790b9f2 de este repo (bin/fixtures/cierre-5790b9f2/, extraidos del JSONL) mas el borrador de
# claude-vzert pr238, y casos adversariales construidos (regla 270: no basta el corpus real).
FX="$BIN/fixtures/cierre-5790b9f2"

ficha_pp() {   # $1 memoria  $2 fichero-snippet|"-" (usa $3 como linea Proximo paso)  $3 texto  $4 lineas `## Pendientes`
  local M="$1"; nueva_memoria "$M"; local S="$M/sessions/2026-09-19-demo.md"; ficha_completa "$S"
  python3 - "$S" "$2" "$3" "$4" <<'PYF'
import sys
p, fx, pp, pend = sys.argv[1:5]
pp = pp.replace("\\n", "\n")
snip = open(fx, encoding="utf-8").read().strip("\n") if fx != "-" else \
    "Retomamos: demo.\n\nLee memory/sessions/2026-09-19-demo.md para el contexto completo.\n\n" + pp + \
    "\n\nAntes de actuar, dime en 3 lineas donde quedamos."
t = open(p, encoding="utf-8").read()
t = t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.", "## Como retomar\n\n```\n" + snip + "\n```")
if pend:
    t = t.replace("## Pendientes\n- Ninguno", "## Pendientes\n" + pend.replace("\\n", "\n"))
open(p, "w", encoding="utf-8").write(t)
PYF
}
pend_linea() {   # $1 memoria, $2 id, $3 texto, $4 cola extra de metadatos
  printf -- '- [ ] %s — _origen: [[sessions/2026-09-19-demo]]_ — _creado: 2026-09-19_ — _id: %s_%s\n' "$3" "$2" "$4" > "$1/.linea"
  python3 - "$1/_pendientes.md" "$1/.linea" <<'PYP'
import sys
p, l = sys.argv[1:3]; t = open(p, encoding="utf-8").read(); ln = open(l, encoding="utf-8").read()
t = t.replace("## Media prioridad\n", "## Media prioridad\n\n" + ln, 1); open(p, "w", encoding="utf-8").write(t)
PYP
}
pp_out() { $AUD "$1" --session-file "$1/sessions/2026-09-19-demo.md" --no-git --hoy 2026-09-22 --solo-snippet 2>&1; }

echo "== F1 real (turno 1813): Proximo paso cita p-a4439fa8fd, que espera a OTRA instalacion =="
M="$T/mF1"; ficha_pp "$M" "$FX/snippet-1813.txt" "" '- [ ] verificar en instalacion real — `p-a4439fa8fd`\n- [ ] reglas nuevas — `p-e685e9c92a`'
pend_linea "$M" p-a4439fa8fd "verificar en instalacion real los dos checks" " — _bloqueado: que otra instalacion actualice el plugin_"
pend_linea "$M" p-e685e9c92a "verificar si las reglas nuevas se siguen" " — _revisar: 2026-09-27_"
O=$(pp_out "$M")
chk "F1: SALTADO snippet.proximo_paso" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.proximo_paso')"
chk "F1: nombra el bloqueo" "1" "$(printf '%s' "$O" | grep -c 'p-a4439fa8fd esta bloqueado')"
echo "== F1 limite conocido: SIN el campo _bloqueado (Step 3b no lo puso) el check no lo ve =="
# Regla 216: la deteccion es solo por el campo estructurado, nunca por el texto ("una vez que
# esa instalacion actualice"). Este aserto documenta el limite, no lo celebra.
M="$T/mF1b"; ficha_pp "$M" "$FX/snippet-1813.txt" "" '- [ ] verificar en instalacion real — `p-a4439fa8fd`'
pend_linea "$M" p-a4439fa8fd "verificar en instalacion real los dos checks" ""
chk "F1 sin campo: HECHO (limite documentado)" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"

echo "== F2 real (turno 2071): caso 4 generico con p-a4439fa8fd propio abierto =="
M="$T/mF2"; ficha_pp "$M" "$FX/snippet-2071.txt" "" '- [ ] verificar en instalacion real — `p-a4439fa8fd`'
pend_linea "$M" p-a4439fa8fd "verificar en instalacion real los dos checks" " — _bloqueado: que otra instalacion actualice el plugin_"
O=$(pp_out "$M")
chk "F2: SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.proximo_paso')"
chk "F2: dice caso 4" "1" "$(printf '%s' "$O" | grep -c 'caso 4 generico')"

echo "== pr238 real (claude-vzert): 'revisar _pendientes.md y proponer...' sin pendientes propios =="
M="$T/mP238"; ficha_pp "$M" - "Proximo paso: revisar _pendientes.md y proponer siguiente prioridad — esta sesión no tuvo próximo paso propio; el trabajo activo real es la Fase 7 pieza 3 del port 3-tier, ver memory/plans/plan-port-3tier-cronologia.md." ""
chk "pr238: SALTADO caso 4" "1" "$(pp_out "$M" | grep -c 'caso 4 generico')"

echo "== snippet BUENO real (turno 2120): cita el caso 4 entre comillas a mitad de linea =="
M="$T/mOK"; ficha_pp "$M" "$FX/snippet-2120.txt" "" '- [ ] resolver de raiz — `p-daf3051915`'
pend_linea "$M" p-daf3051915 "Resolver de raiz los 4 defectos" ""
pend_linea "$M" p-a4439fa8fd "verificar en instalacion real" " — _bloqueado: otra instalacion_"
pend_linea "$M" p-014255373e "plan.upsert sin guardian" ""
pend_linea "$M" p-49996efc69 "estado final 2.30.0" ""
chk "2120: HECHO (la cita no es el caso 4)" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"

echo "== adversariales construidos =="
M="$T/mA1"; ficha_pp "$M" - "Proximo paso: implementar el hook de cierre y probarlo contra los fixtures." ""
chk "trabajo concreto sin _id: SALTADO" "1" "$(pp_out "$M" | grep -c 'no cita el `_id`')"
M="$T/mA2"; ficha_pp "$M" - "Proximo paso: seguir con p-9999999999." ""
chk "id inventado (no abierto): SALTADO" "1" "$(pp_out "$M" | grep -c 'p-9999999999 no esta abierto')"
M="$T/mA3"; ficha_pp "$M" - "Proximo paso: ninguno — lo unico propio (p-a4439fa8fd) espera a otra instalacion." '- [ ] verificar — `p-a4439fa8fd`'
pend_linea "$M" p-a4439fa8fd "verificar en instalacion real" " — _bloqueado: otra instalacion_"
chk "ninguno citando un bloqueado como motivo: HECHO" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"
M="$T/mA4"; ficha_pp "$M" - "Proximo paso: ninguno — nada que hacer hoy." '- [ ] arreglar el bug — `p-1234567890`'
pend_linea "$M" p-1234567890 "arreglar el bug visto en vivo" ""
chk "ninguno con trabajo propio accionable: SALTADO" "1" "$(pp_out "$M" | grep -c 'dice `ninguno` pero')"
M="$T/mA5"; ficha_pp "$M" - "Proximo paso: confirmar el 2026-09-27 que el cron corrio _id: p-1234567890_." ""
pend_linea "$M" p-1234567890 "confirmar el cron" " — _revisar: 2026-09-27_"
chk "id con _revisar futuro: SALTADO" "1" "$(pp_out "$M" | grep -c '_revisar: 2026-09-27` futuro')"
M="$T/mA6"; ficha_pp "$M" - "Proximo paso: nada accionable hoy — p-1234567890 ya tiene su recordatorio (2026-09-27)." ""
pend_linea "$M" p-1234567890 "confirmar el cron" " — _revisar: 2026-09-27_"
chk "'nada accionable hoy' citando un futuro como motivo: HECHO" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"
M="$T/mA7"; ficha_pp "$M" - "Proximo paso: Fase actual: 2 — medir. Correr el script de medicion." ""
chk "Fase actual SIN plan enlazado: SALTADO (no es caso 1)" "1" "$(pp_out "$M" | grep -c 'SALTADO .*snippet.proximo_paso')"
python3 - "$M/sessions/2026-09-19-demo.md" <<'PYX'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
open(p,"w",encoding="utf-8").write(t.replace("## Plans\n- Ninguno","## Plans\n- [[plans/plan-demo]]"))
PYX
chk "Fase actual CON plan enlazado: HECHO (caso 1)" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"
M="$T/mA8"; ficha_pp "$M" - "Proximo paso: arreglar el parser _id: p-1234567890_.\n\nNo repitas: revisar _pendientes.md y proponer siguiente prioridad no sirve." ""
pend_linea "$M" p-1234567890 "arreglar el parser" ""
chk "caso 4 dentro de 'No repitas:' no cuenta: HECHO" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"
M="$T/mA9"; ficha_pp "$M" - "**Próximo paso:** revisar \`_pendientes.md\` y proponer la siguiente prioridad." ""
chk "caso 4 con tilde, negrita y backticks: SALTADO" "1" "$(pp_out "$M" | grep -c 'caso 4 generico')"
M="$T/mA10"; ficha_pp "$M" - "Retomamos solo, sin linea de paso." ""
chk "bloque sin linea Proximo paso: SALTADO" "1" "$(pp_out "$M" | grep -c 'no tiene linea `Proximo paso:`')"
M="$T/mA11"; nueva_memoria "$M"; ficha_completa "$M/sessions/2026-09-19-demo.md"
chk "caso 5 colapsado a una linea: HECHO" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"

echo "== ronda 1 del adversario: caso 4 SIN fence (quitar las comillas triples no lo esconde) =="
M="$T/mR1"; nueva_memoria "$M"; S="$M/sessions/2026-09-19-demo.md"; ficha_completa "$S"
python3 - "$S" <<'PYX'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
  "## Como retomar\n\nRetomamos: demo.\n\nProximo paso: revisar _pendientes.md y proponer siguiente prioridad.")
open(p,"w",encoding="utf-8").write(t)
PYX
chk "sin fence y no es 'Ninguno': SALTADO" "1" "$(pp_out "$M" | grep -c 'no tiene bloque de codigo')"
echo "== ronda 1: 'ninguno' con un still-open de OTRA sesion reconciliado en ## Pendientes: HECHO =="
M="$T/mR2"; ficha_pp "$M" - "Proximo paso: ninguno — la sesion cerro sola." '- [ ] rotar una key — `p-5e75762256` (still-open, de otra sesion)'
printf -- '- [ ] rotar una key — _origen: [[sessions/2026-09-01-otra]]_ — _creado: 2026-09-01_ — _id: p-5e75762256_\n' > "$M/.l"
python3 -c 'import sys;p=sys.argv[1];t=open(p, encoding="utf-8").read();open(p, "w", encoding="utf-8").write(t.replace("## Media prioridad\n","## Media prioridad\n\n"+open(sys.argv[2], encoding="utf-8").read(),1))' "$M/_pendientes.md" "$M/.l"
chk "ajeno no cuenta como trabajo propio" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"

echo "== 2.33.1: un id de 'Sigue abierto:' que ya se cerro es SALTADO (snippet.ids_vivos) =="
M="$T/mV1"; ficha_pp "$M" - "Proximo paso: arreglar el parser _id: p-1234567890_.\n\nSigue abierto: push a origin _id: p-477bb60303_ · medir algo _id: p-2222222222_." ""
pend_linea "$M" p-1234567890 "arreglar el parser" ""
pend_linea "$M" p-2222222222 "medir algo" ""
O=$(pp_out "$M")
chk "SALTADO por el id cerrado" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.ids_vivos')"
chk "lo nombra" "1" "$(printf '%s' "$O" | grep -A1 'snippet.ids_vivos' | grep -c 'p-477bb60303')"
pend_linea "$M" p-477bb60303 "push a origin" ""
chk "con el id abierto: HECHO" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.ids_vivos')"

# ================================================================================================
# 2.34.0 — p-272254efc5: `## Bugs fixed` declara el cierre de cada defecto (bugs.cierre) y `ninguno`
# no tapa un defecto abierto (snippet.ninguno_defecto). C1 es la ficha REAL de 5790b9f2 convertida
# en el cierre que 2.33.0 dejaba pasar: sin p-daf3051915 y con `Proximo paso: ninguno`.
bugs_ficha() {   # $1 memoria, $2 fecha, $3 contenido de `## Bugs fixed` (\n = salto)
  python3 - "$1/sessions/2026-09-19-demo.md" "$2" "$3" <<'PYB'
import sys; p, fecha, bugs = sys.argv[1:4]; t = open(p, encoding="utf-8").read()
t = t.replace("date: 2026-09-19", "date: " + fecha, 1)
t = t.replace("## Bugs fixed\n- Ninguno", "## Bugs fixed\n" + bugs.replace("\\n", "\n"), 1)
open(p, "w", encoding="utf-8").write(t)
PYB
}
bc() { pp_out "$1" | grep -E "^\s+(HECHO|SALTADO|POR-DISEÑO)\s+bugs\.cierre" | awk '{print $1}'; }
nd() { pp_out "$1" | grep -E "^\s+(HECHO|SALTADO)\s+snippet\.ninguno_defecto" | awk '{print $1}'; }
OK_PP="Proximo paso: arreglar el parser _id: p-1234567890_."

echo "== C1 real (5790b9f2 contrafactual): ninguno + defecto arreglado solo con prosa, sin campo =="
M="$T/mC1"; nueva_memoria "$M"; S="$M/sessions/2026-09-22-snippet-cierre-regresion-claude-vzert.md"
cp "$FX/ficha-contrafactual.md" "$S"
printf -- '- [ ] verificar instalacion real — _origen: [[sessions/2026-09-22-snippet-cierre-regresion-claude-vzert]]_ — _creado: 2026-09-22_ — _id: p-a4439fa8fd_ — _bloqueado: otra instalacion_\n- [ ] reglas nuevas — _origen: [[sessions/2026-09-22-snippet-cierre-regresion-claude-vzert]]_ — _creado: 2026-09-22_ — _id: p-e685e9c92a_ — _revisar: 2026-09-27_\n' > "$M/.l"
python3 -c 'import sys;p=sys.argv[1];t=open(p, encoding="utf-8").read();open(p, "w", encoding="utf-8").write(t.replace("## Media prioridad\n","## Media prioridad\n\n"+open(sys.argv[2], encoding="utf-8").read(),1))' "$M/_pendientes.md" "$M/.l"
c1() { $AUD "$M" --session-file "$S" --no-git --hoy 2026-09-23 --solo-snippet 2>&1; }
O=$(c1)
chk "C1: proximo_paso sigue en HECHO (lo que 2.33.0 dejaba pasar)" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*snippet.proximo_paso')"
chk "C1: bugs.cierre lo marca SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*bugs.cierre')"
chk "C1: nombra el bullet del arreglo en prosa" "1" "$(printf '%s' "$O" | grep -c 'sin `_verificado.*Propio del cierre de ESTA ficha')"
chk "C1: los dos verificados no salen" "0" "$(printf '%s' "$O" | grep -c 'sin `_verificado.*Producto\|sin `_verificado.*Propios de esta')"
echo "== C1 con el defecto registrado y abierto: ahora lo marca snippet.ninguno_defecto =="
python3 - "$S" <<'PYX'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
open(p,"w",encoding="utf-8").write(t.replace("ver `## Cambios realizados`.", "ver `## Cambios realizados`. _pendiente: p-daf3051915_", 1))
PYX
printf -- '- [ ] resolver de raiz los 4 defectos — _origen: [[sessions/2026-09-22-snippet-cierre-regresion-claude-vzert]]_ — _creado: 2026-09-22_ — _id: p-daf3051915_\n' > "$M/.l"
python3 -c 'import sys;p=sys.argv[1];t=open(p, encoding="utf-8").read();open(p, "w", encoding="utf-8").write(t.replace("## Alta prioridad\n","## Alta prioridad\n\n"+open(sys.argv[2], encoding="utf-8").read(),1))' "$M/_pendientes.md" "$M/.l"
O=$(c1)
chk "C1+id: bugs.cierre HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*bugs.cierre')"
chk "C1+id: ninguno_defecto SALTADO con p-daf3051915" "1" "$(printf '%s' "$O" | grep -A1 'SALTADO .*snippet.ninguno_defecto' | grep -c 'p-daf3051915')"
echo "== C1 limite conocido: un _verificado: FALSO en el arreglo en prosa lo pasa (regla 216) =="
cp "$FX/ficha-contrafactual.md" "$S"
python3 - "$S" <<'PYX'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
open(p,"w",encoding="utf-8").write(t.replace("ver `## Cambios realizados`.", "ver `## Cambios realizados`. _verificado: regla reescrita_", 1))
PYX
chk "C1 limite: HECHO (el campo es auto-declarado, como _bloqueado)" "1" "$(c1 | grep -c 'HECHO .*bugs.cierre')"

echo "== bugs.cierre: adversariales construidos =="
M="$T/mB1"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia la ultima fila"
chk "bullet sin campo: SALTADO" "SALTADO" "$(bc "$M")"
M="$T/mB2"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia la ultima fila _verificado:_"
chk "_verificado: vacio: SALTADO" "SALTADO" "$(bc "$M")"
M="$T/mB3"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia la ultima fila _verificado: <evidencia>_"
chk "_verificado: con el placeholder del template: SALTADO" "SALTADO" "$(bc "$M")"
M="$T/mB4"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia la ultima fila _pendiente: p-9999999999_"
chk "_pendiente: inventado: SALTADO" "SALTADO" "$(bc "$M")"
M="$T/mB5"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
echo '| 1 | cerrado | Media | 2026-09-01 | x | 2026-09-10 | y — _id: p-5555555555_ |' >> "$M/pendientes/2026-09.md"
bugs_ficha "$M" 2026-09-23 "- el parser perdia la ultima fila _pendiente: p-5555555555_"
chk "_pendiente: ya cerrado en la historia: HECHO" "HECHO" "$(bc "$M")"
M="$T/mB6"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia la ultima fila\n  cuando no habia salto final. _verificado: test-parser.sh caso 7_\n  - sub-bullet: mismo arreglo"
chk "campo en la linea de continuacion, sub-bullet incluido: HECHO" "HECHO" "$(bc "$M")"
M="$T/mB7"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- uno _verificado: test_parser.sh corrio verde_\n- otro sin nada"
chk "evidencia con guiones bajos vale; el segundo sin campo: SALTADO" "1" "$(pp_out "$M" | grep -c 'sin `_verificado.*otro sin nada')"
chk "...y el primero no sale" "0" "$(pp_out "$M" | grep -c 'sin `_verificado.*- uno')"
M="$T/mB8"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- **Ninguno**"
chk "Ninguno en negrita: HECHO" "HECHO" "$(bc "$M")"
M="$T/mB9"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-22 "- el parser perdia la ultima fila"
chk "ficha anterior al corte: POR-DISEÑO" "POR-DISEÑO" "$(bc "$M")"
M="$T/mB10"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "* el parser perdia la ultima fila (bullet con asterisco)"
chk "bullet con asterisco sin campo: SALTADO" "SALTADO" "$(bc "$M")"

echo "== ronda 1 del adversario: otros marcadores de lista de primer nivel =="
for mk in "+ " "1. " "2) " " - " "   * "; do
  M="$T/mBm"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
  bugs_ficha "$M" 2026-09-23 "${mk}el parser perdia la ultima fila"
  chk "bullet '${mk}' sin campo: SALTADO" "SALTADO" "$(bc "$M")"
done
M="$T/mBs"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "1. el parser _verificado: test-parser.sh caso 7_\n    - sub-bullet con 4 espacios, parte del de arriba"
chk "sub-bullet con 4 espacios bajo uno numerado verificado: HECHO" "HECHO" "$(bc "$M")"
M="$T/mBh"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- uno _verificado: test-parser.sh caso 7_\n - otro con 1 espacio, sin campo"
chk "segundo bullet con 1 espacio (no llega a la columna del contenido): SALTADO" "1" "$(pp_out "$M" | grep -c 'sin `_verificado.*otro con 1 espacio')"
echo "== ronda 2 del adversario: un hijo con campo no tapa a un padre sin campo =="
for sep in "  - " $'\t- ' "    * "; do
  M="$T/mBg"; ficha_pp "$M" - "Proximo paso: ninguno — nada que hacer hoy." ""
  bugs_ficha "$M" 2026-09-23 "- primer defecto sin evidencia\n${sep}segundo defecto _verificado: test-parser.sh caso 9_"
  chk "padre sin campo, hijo '${sep}' con campo: SALTADO" "1" "$(pp_out "$M" | grep -c 'sin `_verificado.*primer defecto sin evidencia')"
done
M="$T/mBc"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia filas\n  - detalle del arreglo\n  y el campo tras el hijo _verificado: test-parser.sh_"
chk "campo solo DESPUES de un hijo: cuenta como del hijo, SALTADO" "SALTADO" "$(bc "$M")"
M="$T/mBi"; ficha_pp "$M" - "Proximo paso: ninguno — nada que hacer hoy." ""
pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia filas _verificado: test-parser.sh_\n  - queda un caso sin cubrir _pendiente: p-1234567890_"
chk "_pendiente: abierto en un HIJO sigue contando para ninguno: SALTADO" "SALTADO" "$(nd "$M")"
M="$T/mBn"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- ninguno de los tests cubria la fila final"
chk "linea que EMPIEZA por 'ninguno' pero es un defecto: SALTADO" "SALTADO" "$(bc "$M")"

echo "== snippet.ninguno_defecto: adversariales construidos =="
M="$T/mN1"; ficha_pp "$M" - "Proximo paso: ninguno — nada que hacer hoy." ""
printf -- '- [ ] arreglar el parser — _origen: [[sessions/2026-09-01-otra]]_ — _creado: 2026-09-01_ — _id: p-1234567890_\n' > "$M/.l"
python3 -c 'import sys;p=sys.argv[1];t=open(p, encoding="utf-8").read();open(p, "w", encoding="utf-8").write(t.replace("## Media prioridad\n","## Media prioridad\n\n"+open(sys.argv[2], encoding="utf-8").read(),1))' "$M/_pendientes.md" "$M/.l"
bugs_ficha "$M" 2026-09-23 "- el parser perdia filas _pendiente: p-1234567890_"
chk "ninguno + _pendiente: abierto de OTRO origen: SALTADO" "SALTADO" "$(nd "$M")"
chk "...y proximo_paso no lo veia (el id no esta en ## Pendientes)" "1" "$(pp_out "$M" | grep -c 'HECHO .*snippet.proximo_paso')"
M="$T/mN2"; ficha_pp "$M" - "Proximo paso: ninguno — nada que hacer hoy." ""
pend_linea "$M" p-1234567890 "confirmar el cron" " — _revisar: 2026-09-27_"
bugs_ficha "$M" 2026-09-23 "- el cron no corria _pendiente: p-1234567890_"
chk "ninguno + _pendiente: con _revisar futuro: HECHO" "HECHO" "$(nd "$M")"
M="$T/mN3"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia filas _pendiente: p-1234567890_"
chk "Proximo paso cita el defecto: no aplica (HECHO)" "HECHO" "$(nd "$M")"
M="$T/mN4"; ficha_pp "$M" - "Proximo paso: ninguno — nada que hacer hoy." ""
nb() { $AUD "$1" --session-file "$1/sessions/2026-09-19-demo.md" --no-git --hoy 2026-09-22 --solo-snippet --veredicto-adversario "$2" 2>&1 | grep -E "^\s+(HECHO|SALTADO)\s+snippet\.ninguno_defecto" | awk '{print $1}'; }
chk "ninguno + veredicto break: SALTADO" "SALTADO" "$(nb "$M" break)"
chk "ninguno + veredicto hold: HECHO" "HECHO" "$(nb "$M" hold)"
M="$T/mN5"; nueva_memoria "$M"; ficha_completa "$M/sessions/2026-09-19-demo.md"
pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-23 "- el parser perdia filas _pendiente: p-1234567890_"
chk "caso 5 colapsado + _pendiente: abierto inmediato: SALTADO" "SALTADO" "$(nd "$M")"
chk "caso 5 colapsado + veredicto break: SALTADO" "SALTADO" "$(nb "$M" break)"

# ================================================================================================
# 2.35.0: el snippet ya no lleva `Sigue abierto:` (lo reemplaza el prompt opcional de Step 8e). Desde
# DESDE_SIN_SIGUE_ABIERTO, snippet.sigue_abierto solo guarda el colapso del caso 5.
sa() { pp_out "$1" | grep -E "^\s+(HECHO|SALTADO|POR-DISEÑO)\s+snippet\.sigue_abierto" | awk '{print $1}'; }
echo "== 2.35.0: caso 5 colapsado con un pendiente propio que se puede hacer ya: SALTADO =="
M="$T/mS1"; nueva_memoria "$M"; ficha_completa "$M/sessions/2026-09-19-demo.md"
python3 - "$M/sessions/2026-09-19-demo.md" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("date: 2026-09-19","date: 2026-09-23",1).replace("## Pendientes\n- Ninguno","## Pendientes\n- [ ] arreglar el parser — `p-1234567890`",1)
open(p,"w",encoding="utf-8").write(t)
PYS
pend_linea "$M" p-1234567890 "arreglar el parser" ""
chk "colapsado con propio accionable" "SALTADO" "$(sa "$M")"
echo "== 2.35.0: el mismo colapso con el propio bloqueado: HECHO =="
M="$T/mS2"; nueva_memoria "$M"; ficha_completa "$M/sessions/2026-09-19-demo.md"
python3 - "$M/sessions/2026-09-19-demo.md" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("date: 2026-09-19","date: 2026-09-23",1).replace("## Pendientes\n- Ninguno","## Pendientes\n- [ ] verificar en otra instalacion — `p-1234567890`",1)
open(p,"w",encoding="utf-8").write(t)
PYS
pend_linea "$M" p-1234567890 "verificar en otra instalacion" " — _bloqueado: otra instalacion_"
chk "colapsado con propio bloqueado" "HECHO" "$(sa "$M")"
echo "== 2.35.0: bloque completo sin Sigue abierto y con otro propio abierto: HECHO (antes SALTADO) =="
M="$T/mS3"; ficha_pp "$M" - "$OK_PP" '- [ ] arreglar el parser — `p-1234567890`\n- [ ] medir algo — `p-2222222222`'
pend_linea "$M" p-1234567890 "arreglar el parser" ""; pend_linea "$M" p-2222222222 "medir algo" ""
chk "ficha del 2026-09-19 (antes del corte): sigue exigiendo la linea" "SALTADO" "$(sa "$M")"
bugs_ficha "$M" 2026-09-23 "- Ninguno"
chk "ficha del 2026-09-23: ya no la exige" "HECHO" "$(sa "$M")"

echo "== indice.commit: la fila de la ficha tiene la celda Commit VACIA (2.39.2, p-d1a1ce615f) =="
# Caso real (2026-09-24 y 25, este repo): dos checkpoints seguidos con memory/ en .gitignore
# saltaron Step 6 y dejaron la celda vacia en vez de `N/A` (Step 6d); indice.sesion daba HECHO
# porque solo miraba que la fila existiera.
MC="$T/memorycommit"; nueva_memoria "$MC"
SC="$MC/sessions/2026-09-19-demo.md"; ficha_completa "$SC"
sed -i.bak 's/| `abc1234` |/|  |/' "$MC/_session-index.md"
O=$($AUD "$MC" --session-file "$SC" --no-git --hoy $HOY 2>&1)
chk "celda vacia: SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*indice.commit')"
chk "el corrige nombra N/A (Step 6d)" "1" "$(printf '%s' "$O" | grep -A3 'indice.commit' | grep -c 'corrige:.*N/A')"
sed -i.bak 's/| demo |  |/| demo | N\/A |/' "$MC/_session-index.md"
O=$($AUD "$MC" --session-file "$SC" --no-git --hoy $HOY 2>&1)
chk "celda N/A: HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*indice.commit')"
O=$($AUD "$M9" --session-file "$S9" --no-git --hoy $HOY 2>&1)
chk "celda con hash: HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*indice.commit')"

echo "== indice.commit: el relleno del Fallback (no JBIN) 'filled in Step 6' tampoco es un commit =="
# Adversario, ronda 1 de 2.39.2: con el control mirando solo celda vacia, el texto que Step 2
# manda escribir sin JBIN pasaba como HECHO para siempre si Step 6 no lo reemplazaba.
sed -i.bak 's/| demo | N\/A |/| demo | filled in Step 6 |/' "$MC/_session-index.md"
O=$($AUD "$MC" --session-file "$SC" --no-git --hoy $HOY 2>&1)
chk "'filled in Step 6': SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*indice.commit')"
sed -i.bak 's/| demo | filled in Step 6 |/| demo | `abc1234`, `def5678` |/' "$MC/_session-index.md"
O=$($AUD "$MC" --session-file "$SC" --no-git --hoy $HOY 2>&1)
chk "dos hashes (forma legitima de otra instalacion): HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*indice.commit')"

echo "== la linea 'ya agendado' de Step 8c cuenta para pendientes.3a y snippet.futuro_duplicado =="
# Adversario, ronda 1 de 2.39.2: los dos solo reconocian bloques `### FECHA`, asi que la forma
# nueva dejaba pasar un id repetido en `Sigue abierto:` y no contaba el pendiente como revisado.
MY="$T/memoryya"; nueva_memoria "$MY"
SY="$MY/sessions/2026-09-19-demo.md"; ficha_completa "$SY"
python3 - "$MY/_pendientes.md" "$SY" <<'PY'
import sys
pend, ficha = sys.argv[1:3]
open(pend, 'a', encoding='utf-8').write("\n## Alta prioridad\n- [ ] revisar algo — _origen: [[sessions/2026-09-18-x]]_ — _creado: 2026-09-18_ — _revisar: 2026-09-26_ — _id: p-3333333333_\n")
t = open(ficha, encoding='utf-8').read()
t = t.replace("## Como retomar\nNinguno — la sesion cerro sin continuidad.",
    "## Como retomar\n\n```\nRetomamos: demo.\n\nSigue abierto: revisar algo _id: p-3333333333_.\n```\n\n"
    "## Recordatorios de calendario\n\n- p-3333333333 ya agendado para 2026-09-26 en [[sessions/2026-09-18-x]]")
open(ficha, 'w', encoding='utf-8').write(t)
PY
O=$($AUD "$MY" --session-file "$SY" --no-git --hoy $HOY 2>&1)
chk "id 'ya agendado' repetido en Sigue abierto: SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*snippet.futuro_duplicado')"
chk "el pendiente 'ya agendado' cuenta como revisado" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*pendientes.3a')"
chk "una linea 'ya agendado' no es un bloque duplicado" "0" "$(printf '%s' "$O" | grep -c 'SALTADO .*calendario.duplicado_entre_fichas')"

echo "== calendario.duplicado_entre_fichas: el mismo pendiente con recordatorio vivo en OTRA ficha (2.39.2, p-c9410e7764) =="
# Caso real (2026-09-25, este repo): p-8472f7f4b7 quedo con un recordatorio para el 26 en la ficha
# del 24 (viejo, solo 2.39.0) y otro en la del 25. Solo se vio porque el usuario pregunto.
bloque_cal() {   # $1 = ficha, $2 = fecha, $3 = id
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, fecha, pid = sys.argv[1:4]; t = open(p, encoding='utf-8').read()
t = t.replace("\n## Related", f"\n## Recordatorios de calendario\n\n### {fecha} — [demo] revisar algo\n\n```\nRetomamos: revisar algo _id: {pid}_\n```\n\n## Related", 1)
open(p, 'w', encoding='utf-8').write(t)
PY
}
MD="$T/memorydup"; nueva_memoria "$MD"
SD="$MD/sessions/2026-09-19-demo.md"; ficha_completa "$SD"; bloque_cal "$SD" 2026-09-26 p-8472f7f4b7
VIEJA="$MD/sessions/2026-09-18-vieja.md"; ficha_completa "$VIEJA"; bloque_cal "$VIEJA" 2026-09-26 p-8472f7f4b7
O=$($AUD "$MD" --session-file "$SD" --no-git --hoy $HOY 2>&1)
chk "mismo id vivo en otra ficha: SALTADO" "1" "$(printf '%s' "$O" | grep -c 'SALTADO .*calendario.duplicado_entre_fichas')"
chk "nombra la otra ficha" "1" "$(printf '%s' "$O" | grep -A3 'calendario.duplicado_entre_fichas' | grep -c '2026-09-18-vieja')"
MD2="$T/memorydup2"; nueva_memoria "$MD2"
SD2="$MD2/sessions/2026-09-19-demo.md"; ficha_completa "$SD2"; bloque_cal "$SD2" 2026-09-26 p-8472f7f4b7
V2="$MD2/sessions/2026-09-10-pasada.md"; ficha_completa "$V2"; bloque_cal "$V2" 2026-09-12 p-8472f7f4b7
O=$($AUD "$MD2" --session-file "$SD2" --no-git --hoy $HOY 2>&1)
chk "el de la otra ficha ya paso: HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*calendario.duplicado_entre_fichas')"
V3="$MD2/sessions/2026-09-11-otro.md"; ficha_completa "$V3"; bloque_cal "$V3" 2026-09-26 p-1234567890
O=$($AUD "$MD2" --session-file "$SD2" --no-git --hoy $HOY 2>&1)
chk "otro id el mismo dia: HECHO" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*calendario.duplicado_entre_fichas')"
O=$($AUD "$M9" --session-file "$S9" --no-git --hoy $HOY 2>&1)
chk "sin recordatorios en la ficha: no aplica" "1" "$(printf '%s' "$O" | grep -c 'HECHO .*calendario.duplicado_entre_fichas.*no aplica')"

# ================================================================================================
# 2.42.0: un `break` del adversario tiene que salir en `## Bugs fixed` con CUALQUIER snippet, no solo
# con `Proximo paso: ninguno`. Caso real del 2026-09-30: snippet con un Proximo paso real, el
# adversario dio `break autonomy-violations=1`, el agente lo arreglo y la ficha no lo nombraba.
vb() { $AUD "$1" --session-file "$1/sessions/2026-09-19-demo.md" --no-git --hoy 2026-09-30 --solo-snippet ${2:+--veredicto-adversario "$2"} 2>&1 | grep -E "^\s+(HECHO|SALTADO)\s+bugs\.veredicto_break" | awk '{print $1}'; }
echo "== 2.42.0: break + Proximo paso real + Bugs fixed sin nombrar al adversario: SALTADO =="
M="$T/mVB1"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-30 "- tres casos sin arnes _verificado: mutation-check verde_"
chk "SALTADO" "SALTADO" "$(vb "$M" break)"
chk "el mismo, con hold: la clave no sale" "" "$(vb "$M" hold)"
chk "el mismo, sin veredicto (Step 7a): la clave no sale" "" "$(vb "$M" "")"
echo "== 2.42.0: Bugs fixed nombra el hallazgo del adversario: HECHO =="
M="$T/mVB2"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-30 "- pregunte en prosa el push: el adversario lo marco (autonomy) _verificado: se pregunto con AskUserQuestion_"
chk "HECHO" "HECHO" "$(vb "$M" break)"
echo "== 2.42.0: la mencion en un HIJO del item cuenta (el bloque entero), no solo en su primera linea =="
M="$T/mVB3"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-30 "- pregunte el push en prosa _verificado: corregido_\n  - lo marco el adversario"
chk "HECHO" "HECHO" "$(vb "$M" break)"
echo "== 2.42.0: ficha anterior al corte: la clave no sale =="
M="$T/mVB4"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-29 "- tres casos sin arnes _verificado: verde_"
chk "sin clave" "" "$(vb "$M" break)"

echo "== ronda 1 de 2.42.0: 'break' o 'veredicto' sueltos no nombran al adversario: SALTADO =="
M="$T/mVB5"; ficha_pp "$M" - "$OK_PP" ""; pend_linea "$M" p-1234567890 "arreglar el parser" ""
bugs_ficha "$M" 2026-09-30 "- un break que faltaba en el bucle; el veredicto del parser era falso _verificado: test verde_"
chk "SALTADO" "SALTADO" "$(vb "$M" break)"

echo "== todo corrige: que es un comando corre tal cual y deja su clave en HECHO (p-01a16467ad) =="
# Contrato: un corrige: que empieza por `python3` se ejecuta tal cual; solo se sustituyen los
# marcadores de lo que el audit no puede saber (<SESSION_FILE>, <hash>, <status>). Antes, dos
# llevaban un `…` literal (bash lo pasa como argumento: exit 2), uno dejaba el compactar dentro
# del comentario y otro compactaba cuando lo que faltaba era repair-dualwrite. Salir 0 no basta:
# el re-audit tiene que dar HECHO. Los corrige: en prosa siguen en prosa (decide el agente).
corrige_de() {   # $1 = salida del audit, $2 = clave -> su corrige:, sin el prefijo
  printf '%s\n' "$1" | awk -v k="$2" '
    $2 == k { on = 1; next }
    on && $1 ~ /^(HECHO|SALTADO|PARCIAL|POR-DISE|resumen:)/ { exit }
    on && /corrige: / { sub(/.*corrige: /, ""); print; exit }'
}
corre_corrige() {   # $1 = memoria, $2 = ficha, $3 = clave, $4 = valor de <status> -> rc
  local o c
  o=$($AUD "$1" --session-file "$2" --no-git --hoy $HOY 2>&1)
  c=$(corrige_de "$o" "$3")
  c=${c//<SESSION_FILE>/\"$2\"}; c=${c//<hash>/abc1234}; c=${c//<status>/${4:-active}}
  if [ -z "$c" ] || printf '%s' "$c" | grep -q '…\|<[A-Za-z_]*>'; then echo "SIN-COMANDO[$c]"; return; fi
  set +e; JBIN="$BIN" MEMORY_DIR="$1" bash -c "$c" >"$T/corrige.out" 2>&1; echo $?; set -e
}
clave_en() {   # $1 = memoria, $2 = ficha, $3 = clave -> estado
  $AUD "$1" --session-file "$2" --no-git --hoy $HOY 2>&1 | awk -v k="$3" '$2 == k { print $1; exit }'
}
estado_plan() { { printf -- '---\ntype: plan\n---\n# %s\n' "${2:-Plan demo}"; cat; } > "$1" <<'EOF'

## Estado
- Fase actual: 2
- Proxima accion: nada
- Bloqueo: ninguno
- Fecha: 2026-09-19
EOF
}
enlaza_planes() {   # $1 = ficha, $2.. = slugs de plan
  local f="$1"; shift
  python3 - "$f" "$@" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Plans\n- Ninguno","## Plans\n"+"\n".join(f"- [[plans/{s}]] — tocado" for s in sys.argv[2:]))
open(p,'w',encoding='utf-8').write(t)
PY
}

MX="$T/mX1"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
estado_plan "$MX/plans/plan-demo.md"; enlaza_planes "$SX" plan-demo
chk "plan.indice sin fila: el corrige corre" "0" "$(corre_corrige "$MX" "$SX" plan.indice active)"
chk "plan.indice sin fila: re-audit HECHO" "HECHO" "$(clave_en "$MX" "$SX" plan.indice)"

MX="$T/mX2"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
estado_plan "$MX/plans/plan-demo.md"; estado_plan "$MX/plans/plan-otro.md" "Plan otro"; enlaza_planes "$SX" plan-demo plan-otro
cat >> "$MX/_plans-index.md" <<'EOF'
| [[plans/plan-demo\|Plan demo]] | active (fase de plan-otro) | 2026-09-01 | [[sessions/2026-09-01-vieja]] | 0 | 0 |
EOF
chk "plan.indice fila vieja + plan sin fila: el corrige corre" "0" "$(corre_corrige "$MX" "$SX" plan.indice testing)"
chk "plan.indice dos planes: re-audit HECHO" "HECHO" "$(clave_en "$MX" "$SX" plan.indice)"
chk "la anotacion de fase no se duplica" "1" "$(grep -c 'plan-demo.*| active (fase de plan-otro) |' "$MX/_plans-index.md")"
chk "la Fecha de la fila vieja no cambia" "1" "$(grep -c 'plan-demo.*| 2026-09-01 |' "$MX/_plans-index.md")"

MX="$T/mX3"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
cat >> "$MX/_pendientes.md" <<'EOF'
- [ ] escrito a mano sin fila mensual — _creado: 2026-09-19_ — _id: p-abcdef0123_
EOF
python3 - "$SX" <<'PY'
import sys
p=sys.argv[1]; t=open(p,encoding='utf-8').read()
t=t.replace("## Pendientes\n- Ninguno","## Pendientes\n- [ ] escrito a mano — `p-abcdef0123`")
open(p,'w',encoding='utf-8').write(t)
PY
chk "pendientes.dualwrite: SALTADO antes" "SALTADO" "$(clave_en "$MX" "$SX" pendientes.dualwrite)"
chk "pendientes.dualwrite: el corrige corre" "0" "$(corre_corrige "$MX" "$SX" pendientes.dualwrite)"
chk "pendientes.dualwrite: re-audit HECHO" "HECHO" "$(clave_en "$MX" "$SX" pendientes.dualwrite)"

MX="$T/mX4"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
python3 "$BIN/journal-emit.py" --memory-dir "$MX" --type session.add --slug 2026-09-19-demo --status completada >/dev/null
chk "journal.limpio: SALTADO antes" "SALTADO" "$(clave_en "$MX" "$SX" journal.limpio)"
chk "journal.limpio: el corrige corre" "0" "$(corre_corrige "$MX" "$SX" journal.limpio)"
chk "journal.limpio: re-audit HECHO" "HECHO" "$(clave_en "$MX" "$SX" journal.limpio)"

MX="$T/mX5"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-24-recien.md"; ficha_completa "$SX"
chk "indice.sesion: SALTADO antes" "SALTADO" "$(clave_en "$MX" "$SX" indice.sesion)"
chk "indice.sesion: el corrige corre" "0" "$(corre_corrige "$MX" "$SX" indice.sesion)"
chk "indice.sesion: re-audit HECHO" "HECHO" "$(clave_en "$MX" "$SX" indice.sesion)"
chk "indice.commit: SALTADO (celda vacia) antes" "SALTADO" "$(clave_en "$MX" "$SX" indice.commit)"
chk "indice.commit: el corrige corre" "0" "$(corre_corrige "$MX" "$SX" indice.commit)"
chk "indice.commit: re-audit HECHO" "HECHO" "$(clave_en "$MX" "$SX" indice.commit)"

echo "== ronda 1 del adversario (p-01a16467ad): plan.indice no toca la fila de otro plan =="
MX="$T/mX6"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
estado_plan "$MX/plans/plan-demo.md"; enlaza_planes "$SX" plan-demo
cat >> "$MX/_plans-index.md" <<'EOF'
| [[plans/plan-demo-v2\|Otra cosa]] | active | 2026-09-01 | [[sessions/2026-09-01-vieja]] | 0 | 0 |
EOF
chk "subcadena plan-demo-v2: SALTADO sin fila propia" "1" "$($AUD "$MX" --session-file "$SX" --no-git --hoy $HOY 2>&1 | grep -c 'plan-demo — sin fila')"
chk "subcadena: el corrige corre" "0" "$(corre_corrige "$MX" "$SX" plan.indice active)"
chk "subcadena: re-audit HECHO" "HECHO" "$(clave_en "$MX" "$SX" plan.indice)"
# grep -F: en un patron basico, `\|` es alternancia y el aserto pasaba con la fila corrupta
# (adversario, ronda 2).
chk "la fila de plan-demo-v2 queda intacta" "1" "$(grep -cxF '| [[plans/plan-demo-v2\|Otra cosa]] | active | 2026-09-01 | [[sessions/2026-09-01-vieja]] | 0 | 0 |' "$MX/_plans-index.md")"

MX="$T/mX7"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
estado_plan "$MX/plans/plan-demo.md"; enlaza_planes "$SX" plan-demo
chk "<status> con espacios y metacaracteres: el corrige corre" "0" "$(corre_corrige "$MX" "$SX" plan.indice 'en pausa; $(false) `x`')"
chk "<status> con espacios: re-audit HECHO" "HECHO" "$(clave_en "$MX" "$SX" plan.indice)"
chk "<status> llega literal al indice, sin expandirse" "1" "$(grep -cF '| en pausa; $(false) `x` |' "$MX/_plans-index.md")"

MX="$T/mX8"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
estado_plan "$MX/plans/plan-demo.md"; enlaza_planes "$SX" plan-demo
cat >> "$MX/_plans-index.md" <<'EOF'
| [[plans/plan-demo\|Plan demo]] | active | 2026-09-01 | [[sessions/2026-09-01-vieja]] | 0 | 0 |
| [[plans/plan-demo\|Plan demo]] | draft | 2026-08-01 | [[sessions/2026-08-01-mas-vieja]] | 0 | 0 |
EOF
O=$($AUD "$MX" --session-file "$SX" --no-git --hoy $HOY 2>&1)
chk "filas duplicadas: SALTADO" "SALTADO" "$(clave_en "$MX" "$SX" plan.indice)"
chk "filas duplicadas: el corrige no es un comando para pegar" "0" "$(corrige_de "$O" plan.indice | grep -c '^python3')"
chk "filas duplicadas: el corrige lo dice" "1" "$(corrige_de "$O" plan.indice | grep -c 'tiene 2 filas')"

MX="$T/mX9"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
estado_plan "$MX/plans/plan-demo.md" "Titulo compartido"; enlaza_planes "$SX" plan-demo
cat >> "$MX/_plans-index.md" <<'EOF'
| [[plans/plan-ajeno\|Titulo compartido]] | active | 2026-09-01 | [[sessions/2026-09-01-vieja]] | 0 | 0 |
EOF
O=$($AUD "$MX" --session-file "$SX" --no-git --hoy $HOY 2>&1)
chk "titulo de otra fila: el corrige no es un comando para pegar" "0" "$(corrige_de "$O" plan.indice | grep -c '^python3')"
chk "titulo de otra fila: el corrige lo dice" "1" "$(corrige_de "$O" plan.indice | grep -c 'mismo titulo')"

MX="$T/mXu"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
estado_plan "$MX/plans/plan-demo.md" "$(printf 'Revisio\xcc\x81n')"; enlaza_planes "$SX" plan-demo
printf '| [[plans/plan-ajeno\\|Revisi\xc3\xb3n]] | active | 2026-09-01 | [[sessions/2026-09-01-vieja]] | 0 | 0 |\n' >> "$MX/_plans-index.md"
O=$($AUD "$MX" --session-file "$SX" --no-git --hoy $HOY 2>&1)
chk "titulo igual en otra forma Unicode (NFD/NFC): no es un comando para pegar" "0" "$(corrige_de "$O" plan.indice | grep -c '^python3')"

MX="$T/mXa"; nueva_memoria "$MX"; SX="$MX/sessions/2026-09-19-demo.md"; ficha_completa "$SX"
estado_plan "$MX/plans/plan-demo.md"; enlaza_planes "$SX" plan-demo
cat >> "$MX/_plans-index.md" <<'EOF'
| [[plans/plan-demo\|Plan demo]] | active | 2026-09-01 | [[sessions/2026-09-19-demo-2]] | 0 | 0 |
EOF
chk "celda Sesion de otra ficha con el slug como prefijo: SALTADO" "SALTADO" "$(clave_en "$MX" "$SX" plan.indice)"

echo "== ningun corrige= de checkpoint-audit.py que empieza por python3 lleva un '…' literal =="
chk "sin '…' en los corrige de comando" "0" "$(python3 - "$BIN/checkpoint-audit.py" <<'PY'
import ast, sys
arbol = ast.parse(open(sys.argv[1], encoding="utf-8").read())
def texto(n):
    if isinstance(n, ast.Constant) and isinstance(n.value, str): return n.value
    if isinstance(n, ast.JoinedStr): return "".join(texto(v) if not isinstance(v, ast.FormattedValue) else "{}" for v in n.values)
    if isinstance(n, ast.BinOp): return texto(n.left) + texto(n.right)
    if isinstance(n, ast.IfExp): return texto(n.body) + "\n" + texto(n.orelse)
    return ""
malos = [n.lineno for n in ast.walk(arbol) if isinstance(n, ast.keyword) and n.arg == "corrige"
         and any(l.startswith("python3") and "…" in l for l in texto(n.value).split("\n"))]
print(len(malos))
PY
)"

echo "== p-a9f0514be0: colapso 'Ninguno' con un vencido de OTRA sesion listado como '- [ ]' (2.35.0+) =="
# Caso real: ficha 2026-10-01-enlaces-reales-windows-r4. pendientes.vencidos exige mencionar el
# vencido ajeno y reconciliacion_linea lo cuenta solo con casilla; con casilla, sigue_abierto lo
# contaba como propio y rechazaba el colapso. snippet.proximo_paso ya filtraba por `_origen`.
sa_ficha() {   # $1 memoria, $2 origen del pendiente listado
  local M="$1"; nueva_memoria "$M"; local S="$M/sessions/2026-10-01-demo.md"; ficha_completa "$S"
  python3 - "$S" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("date: 2026-09-19","date: 2026-10-01",1)
t=t.replace("## Pendientes\n- Ninguno","## Pendientes\n- [ ] (otra sesion, vencido) medir algo — `p-0a0a0a0a0a` (still-open)",1)
open(p,"w",encoding="utf-8").write(t)
PYS
  printf -- '- [ ] medir algo — _origen: [[sessions/%s]]_ — _creado: 2026-09-20_ — _id: p-0a0a0a0a0a_ — _revisar: 2026-09-26_\n' "$2" > "$M/.l"
  python3 -c 'import sys;p=sys.argv[1];t=open(p, encoding="utf-8").read();open(p, "w", encoding="utf-8").write(t.replace("## Media prioridad\n","## Media prioridad\n\n"+open(sys.argv[2], encoding="utf-8").read(),1))' "$M/_pendientes.md" "$M/.l"
}
sa_out() { $AUD "$1" --session-file "$1/sessions/2026-10-01-demo.md" --no-git --hoy 2026-10-01 --solo-snippet 2>&1; }
M="$T/mSA1"; sa_ficha "$M" 2026-09-20-otra
chk "vencido ajeno con casilla: el colapso vale (HECHO)" "1" "$(sa_out "$M" | grep -c 'HECHO .*snippet.sigue_abierto')"
M="$T/mSA2"; sa_ficha "$M" 2026-10-01-demo
chk "control: el mismo pendiente nacido en esta ficha sigue siendo SALTADO" "1" "$(sa_out "$M" | grep -c 'SALTADO .*snippet.sigue_abierto')"

# ---------------------------------------------------------------- 2.53.0: candidatos a pendiente
# Desde 2.53.0 Step 3b no crea pendientes: los propone en AskUserQuestion y escribe la decision en
# `## Candidatos a pendiente`. `pendientes.candidatos` mide que todo pendiente abierto nacido en la
# sesion salga como `guardado` con su id; `pendientes.candidatos_pregunta` (solo con el dato del
# hook) que una decision tomada tenga detras al menos una pregunta que volvio del usuario
# (respondida, o cerrada por el: Step 3b descarta en ese caso).
cand_ficha() {   # $1 memoria, $2 cuerpo de `## Candidatos a pendiente` (o "__SIN__" para omitirla), $3 fecha
  local M="$1"; nueva_memoria "$M"; local F="${3:-2026-10-09}"; local S="$M/sessions/$F-demo.md"; ficha_completa "$S"
  python3 - "$S" "$2" "$F" <<'PYS'
import sys; p, cuerpo, f = sys.argv[1:4]; t=open(p,encoding="utf-8").read()
t=t.replace("date: 2026-09-19","date: "+f,1)
if cuerpo != "__SIN__":
    t=t.replace("## Pendientes\n","## Candidatos a pendiente\n"+cuerpo+"\n\n## Pendientes\n",1)
open(p,"w",encoding="utf-8").write(t)
PYS
}
cand_pend() {   # $1 memoria, $2 id, $3 slug de origen: un pendiente abierto
  printf -- '- [ ] algo nuevo — _origen: [[sessions/%s]]_ — _creado: 2026-10-09_ — _id: %s_\n' "$3" "$2" > "$1/.l"
  python3 -c 'import sys;p=sys.argv[1];t=open(p, encoding="utf-8").read();open(p, "w", encoding="utf-8").write(t.replace("## Media prioridad\n","## Media prioridad\n\n"+open(sys.argv[2], encoding="utf-8").read(),1))' "$1/_pendientes.md" "$1/.l"
}
cand_out() { $AUD "$1" --session-file "$1/sessions/${3:-2026-10-09}-demo.md" --no-git --hoy 2026-10-09 $2 2>&1; }

M="$T/mCA1"; cand_ficha "$M" "- Ninguno"
chk "CA1: seccion con Ninguno y sin pendientes nuevos → HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*pendientes.candidatos ')"
M="$T/mCA2"; cand_ficha "$M" "__SIN__"; cand_pend "$M" p-c4c4c4c4c4 2026-10-09-demo
chk "CA2: ficha de 2.53.0 sin la seccion y con un pendiente nacido en ella → SALTADO" "1" "$(cand_out "$M" | grep -c 'SALTADO .*pendientes.candidatos ')"
M="$T/mCA3"; cand_ficha "$M" "- Ninguno"; cand_pend "$M" p-c1c1c1c1c1 2026-10-09-demo
chk "CA3: pendiente nacido en la sesion sin decision guardado → SALTADO" "1" "$(cand_out "$M" | grep -c 'SALTADO .*pendientes.candidatos ')"
chk "CA3: nombra el id creado sin el si del usuario" "1" "$(cand_out "$M" | grep -c 'p-c1c1c1c1c1 nacio en esta sesion')"
M="$T/mCA4"; cand_ficha "$M" '- algo nuevo — recomendacion: guardar — decision: guardado `p-c1c1c1c1c1`'; cand_pend "$M" p-c1c1c1c1c1 2026-10-09-demo
chk "CA4: el mismo pendiente con decision guardado → HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*pendientes.candidatos ')"
M="$T/mCA5"; cand_ficha "$M" "- Ninguno"; cand_pend "$M" p-c2c2c2c2c2 2026-10-01-otra
chk "CA5: pendiente abierto de OTRA sesion no cuenta → HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*pendientes.candidatos ')"
M="$T/mCA6"; cand_ficha "$M" '- algo — decision: guardado `p-dededede0d`'
chk "CA6: guardado con un id que no existe → SALTADO" "1" "$(cand_out "$M" | grep -c 'SALTADO .*pendientes.candidatos ')"
M="$T/mCA7"; cand_ficha "$M" '- algo sin decidir — recomendacion: descartar'
chk "CA7: linea sin decision → SALTADO" "1" "$(cand_out "$M" | grep -c 'SALTADO .*pendientes.candidatos ')"
M="$T/mCA8"; cand_ficha "$M" '- algo — decision: descartado
- otra cosa — decision: sin confirmar (sin pantalla)'
chk "CA8: descartado y sin confirmar sin pendiente → HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*pendientes.candidatos ')"
M="$T/mCA9"; cand_ficha "$M" "__SIN__" 2026-10-08; cand_pend "$M" p-c3c3c3c3c3 2026-10-08-demo
chk "CA9: ficha anterior a 2.53.0 → POR-DISENO" "1" "$(cand_out "$M" "" 2026-10-08 | grep -c 'POR-DISEÑO .*pendientes.candidatos ')"

# La pregunta de verdad: solo la mide el hook de cierre (pasa --preguntas-usuario).
M="$T/mCP1"; cand_ficha "$M" '- algo — decision: descartado'
chk "CP1: decision tomada con 0 preguntas al usuario → SALTADO" "1" "$(cand_out "$M" "--preguntas-usuario 0" | grep -c 'SALTADO .*pendientes.candidatos_pregunta')"
chk "CP2: con 1 pregunta al usuario → HECHO" "1" "$(cand_out "$M" "--preguntas-usuario 1" | grep -c 'HECHO .*pendientes.candidatos_pregunta')"
chk "CP3: sin el dato del hook (Step 7a) el chequeo no se emite" "0" "$(cand_out "$M" | grep -c 'pendientes.candidatos_pregunta')"
M="$T/mCP4"; cand_ficha "$M" '- algo — decision: sin confirmar (sin pantalla)'
chk "CP4: solo sin confirmar (sin pantalla) no necesita pregunta" "0" "$(cand_out "$M" "--preguntas-usuario 0" | grep -c 'SALTADO .*pendientes.candidatos_pregunta')"
chk "CP5: --solo-snippet (modo del hook) incluye el chequeo" "1" "$(cand_out "$M" "--solo-snippet --preguntas-usuario 0" | grep -c 'pendientes.candidatos ')"

# `_descartado:` es el tercer cierre de un defecto en `## Bugs fixed`.
M="$T/mCD1"; cand_ficha "$M" '- el defecto — decision: descartado'
python3 - "$M/sessions/2026-10-09-demo.md" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("## Bugs fixed\n- Ninguno","## Bugs fixed\n- el defecto que no se cerro _descartado: el usuario no lo quiso como pendiente_",1)
open(p,"w",encoding="utf-8").write(t)
PYS
chk "CD1: defecto con _descartado: declara su cierre → HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*bugs.cierre')"
python3 - "$M/sessions/2026-10-09-demo.md" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("_descartado: el usuario no lo quiso como pendiente_","sin campo",1)
open(p,"w",encoding="utf-8").write(t)
PYS
chk "CD2: control: sin campo sigue SALTADO" "1" "$(cand_out "$M" | grep -c 'SALTADO .*bugs.cierre')"

# Ronda 1 de los adversarios de 2.53.0.
# (a) Una ficha de otro flujo, sin pendientes nuevos ni descartes, no necesita la seccion.
M="$T/mCB1"; cand_ficha "$M" "__SIN__"
chk "CB1: sin seccion y sin nada que decidir → HECHO (no falso SALTADO)" "1" "$(cand_out "$M" | grep -c 'HECHO .*pendientes.candidatos ')"
# (b) `_descartado:` sin su candidato `descartado` no cierra el defecto en silencio.
M="$T/mCB2"; cand_ficha "$M" "- Ninguno"
python3 - "$M/sessions/2026-10-09-demo.md" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("## Bugs fixed\n- Ninguno","## Bugs fixed\n- un hueco real _descartado: no vale la pena_",1)
open(p,"w",encoding="utf-8").write(t)
PYS
chk "CB2: _descartado: sin candidato descartado → SALTADO" "1" "$(cand_out "$M" | grep -c 'SALTADO .*pendientes.candidatos ')"
chk "CB3: y lo dice" "1" "$(cand_out "$M" | grep -c 'con `_descartado:` y solo 0')"
python3 - "$M/sessions/2026-10-09-demo.md" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("## Candidatos a pendiente\n- Ninguno","## Candidatos a pendiente\n- un hueco real — decision: descartado",1)
open(p,"w",encoding="utf-8").write(t)
PYS
chk "CB4: con su candidato descartado → HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*pendientes.candidatos ')"
# (c) `snippet.ninguno_defecto`: un `break` del adversario con el defecto descartado por el usuario
# no exige pendiente; sin el `_descartado:` si.
python3 - "$M/sessions/2026-10-09-demo.md" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("- un hueco real _descartado:","- el adversario marco un hueco real _descartado:",1)
open(p,"w",encoding="utf-8").write(t)
PYS
chk "CB5: ninguno + break + defecto descartado por el usuario → no SALTADO" "0" "$(cand_out "$M" "--solo-snippet --veredicto-adversario break" | grep -c 'SALTADO .*snippet.ninguno_defecto')"

# ---------------------------------------------------------------- 2.54.0: `Hacerlo ahora`
# Una omision chica del agente (una rama sin borrar, una fila de plan sin actualizar) ya no tiene
# que ser pendiente ni perderse: el usuario elige `Hacerlo ahora`, el agente la hace dentro de Step
# 3b y la linea dice `decision: hecho _verificado: <evidencia>_`. Caso real: una sesion de otro
# proyecto propuso tres de estas con `No guardar` recomendado.
M="$T/mCH1"; cand_ficha "$M" '- la rama remota quedo sin borrar — recomendacion: hacer ahora — decision: hecho _verificado: gh api DELETE devolvio 204_'
chk "CH1: hecho con evidencia → HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*pendientes.candidatos ')"
M="$T/mCH2"; cand_ficha "$M" '- la rama remota quedo sin borrar — decision: hecho'
chk "CH2: hecho sin _verificado: → SALTADO" "1" "$(cand_out "$M" | grep -c 'SALTADO .*pendientes.candidatos ')"
chk "CH3: y lo dice" "1" "$(cand_out "$M" | grep -c '`hecho` sin `_verificado:')"
M="$T/mCH4"; cand_ficha "$M" '- la rama remota quedo sin borrar — decision: hecho _verificado: <evidencia>_'
chk "CH4: hecho con el placeholder de la plantilla → SALTADO" "1" "$(cand_out "$M" | grep -c 'SALTADO .*pendientes.candidatos ')"
M="$T/mCH5"; cand_ficha "$M" '- la rama remota quedo sin borrar — decision: hecho _verificado: gh api DELETE devolvio 204_'
chk "CH5: hecho sin ninguna pregunta al usuario → SALTADO (lo decidio el agente)" "1" "$(cand_out "$M" "--preguntas-usuario 0" | grep -c 'SALTADO .*pendientes.candidatos_pregunta')"
# Un defecto de `## Bugs fixed` hecho en Step 3b cierra con `_verificado:`: no es un descarte, y no
# cuenta para el par `_descartado:` ↔ candidato descartado.
python3 - "$M/sessions/2026-10-09-demo.md" <<'PYS'
import sys; p=sys.argv[1]; t=open(p,encoding="utf-8").read()
t=t.replace("## Bugs fixed\n- Ninguno","## Bugs fixed\n- deje la rama remota sin borrar _verificado: borrada en Step 3b, gh api DELETE devolvio 204_",1)
open(p,"w",encoding="utf-8").write(t)
PYS
chk "CH6: defecto hecho en Step 3b → bugs.cierre HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*bugs.cierre')"
chk "CH7: y pendientes.candidatos HECHO" "1" "$(cand_out "$M" | grep -c 'HECHO .*pendientes.candidatos ')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
