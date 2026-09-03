#!/bin/bash
# Prueba de aceptacion de Fase 1 del journal (v2.12.0): N agentes escriben pendientes a la
# vez y nada se pierde, nada se duplica, ningun lock queda huerfano.
#
# Cuerpo tomado tal cual de memory/plans/plan-journal-concurrencia-v2.12.0.md. Cada corrida
# lanza 2 workers (10 add + 5 resolve cada uno = 30 eventos concurrentes) contra 2
# compactadores simultaneos, y un barrido final. Se exige 5/5 corridas limpias, mas:
#   - un solo agente, 10 eventos secuenciales, sin lock residual, < 1 s
#   - lock huerfano (TTL vencido): 5 compactadores compiten, exactamente 1 lo roba
#
# Uso: bash bin/test-journal-race.sh    (sin dependencias; sale != 0 si algo falla)
# Umbral: exit 0. Baseline medido 2026-09-02: `Write` con copia vieja perdio 2/2 lineas.

set -u
cd "$(dirname "$0")/.." || exit 1
M=$(mktemp -d) && [ -d "$M" ] || { echo "mktemp fallo: sin directorio temporal, no se ejecuta nada"; exit 1; }
export MEMORY_DIR=$M; FAIL=0
trap 'rm -rf "$M"' EXIT

for t in 1 2 3 4 5; do
  rm -r $M/.journal 2>/dev/null
  rm -r $M/pendientes 2>/dev/null
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n\n' > $M/_pendientes.md
  worker() { W=$1; for i in $(seq 1 10); do
      ID=$(python3 bin/journal-emit.py --type pendiente.add --text "w$W item $i trial $t" --prioridad Media --origen "[[sessions/test]]") || exit 2
      [ $((i % 2)) -eq 0 ] && { python3 bin/journal-emit.py --type pendiente.resolve --id "$ID" --estado resolved >/dev/null || exit 2; }
    done; }
  worker A & worker B &
  python3 bin/journal-compact.py --quiet & python3 bin/journal-compact.py --quiet & wait
  python3 bin/journal-compact.py --quiet   # barrido final: todo lo emitido debe quedar aplicado
  OPEN=$(grep -c '^- \[ \] w[AB] item' $M/_pendientes.md)              # esperado: 10 (5 por worker siguen abiertos)
  DUP=$(grep -o '_id: p-[0-9a-f]*_' $M/_pendientes.md | sort | uniq -d | wc -l | tr -d ' ')   # esperado: 0
  ROWS=$(cat $M/pendientes/*.md | grep -c '^| [0-9]* | w[AB] item')    # esperado: 20 (toda alta queda en el mensual)
  DUPM=$(grep -o 'p-[0-9a-f]\{10\}' $M/pendientes/*.md | sort | uniq -d | wc -l | tr -d ' ')   # esperado: 0 (ids unicos tambien en el mensual)
  DUPN=$(grep -o '^| [0-9]* |' $M/pendientes/*.md | sort | uniq -d | wc -l | tr -d ' ')        # esperado: 0 (numeros # unicos)
  PEND=$(ls $M/.journal/pending 2>/dev/null | wc -l | tr -d ' ')       # esperado: 0
  QUAR=$(ls $M/.journal/quarantine 2>/dev/null | wc -l | tr -d ' ')    # esperado: 0
  FAILED=$(ls $M/.journal/failed 2>/dev/null | wc -l | tr -d ' ')      # esperado: 0
  LOCK=$(ls -d $M/.journal/.lock 2>/dev/null | wc -l | tr -d ' ')      # esperado: 0
  RES=$(cat $M/pendientes/*.md | grep -c '| resolved |')               # esperado: 10 (5 por worker)
  echo "trial $t: open=$OPEN dupids=$DUP rows=$ROWS dupids_monthly=$DUPM dupnums=$DUPN pending=$PEND quarantine=$QUAR failed=$FAILED lock=$LOCK resolved=$RES"
  [ "$OPEN" = 10 ] && [ "$DUP" = 0 ] && [ "$ROWS" = 20 ] && [ "$DUPM" = 0 ] && [ "$DUPN" = 0 ] && [ "$PEND" = 0 ] && [ "$QUAR" = 0 ] && [ "$FAILED" = 0 ] && [ "$LOCK" = 0 ] && [ "$RES" = 10 ] || FAIL=1
done

# Complementaria 1: un solo agente, 10 eventos secuenciales, sin lock residual, < 1 s
rm -r $M/.journal 2>/dev/null; T0=$(python3 -c 'import time;print(time.time_ns())')
for i in $(seq 1 10); do python3 bin/journal-emit.py --type pendiente.add --text "solo item $i" --prioridad Baja --origen "[[sessions/test]]" >/dev/null || FAIL=1; done
python3 bin/journal-compact.py --quiet || FAIL=1
T1=$(python3 -c 'import time;print(time.time_ns())'); MS=$(( (T1 - T0) / 1000000 ))
SOLO=$(grep -c '^- \[ \] solo item' $M/_pendientes.md); SLOCK=$(ls -d $M/.journal/.lock 2>/dev/null | wc -l | tr -d ' ')
echo "solo: items=$SOLO lock=$SLOCK ms=$MS"           # esperado: items=10 lock=0 ms<1000
[ "$SOLO" = 10 ] && [ "$SLOCK" = 0 ] && [ "$MS" -lt 1000 ] || FAIL=1

# Complementaria 2: lock huerfano (TTL vencido), 5 compactadores compiten, exactamente 1 lo roba
mkdir -p $M/.journal/.lock; echo $(( $(date +%s) - 120 )) > $M/.journal/.lock/acquired_at
for k in 1 2 3 4 5; do python3 bin/journal-compact.py --quiet --log $M/compact-$k.log & done; wait
STOLEN=$(cat $M/compact-*.log | grep -c '^STOLEN'); ELOCK=$(ls -d $M/.journal/.lock 2>/dev/null | wc -l | tr -d ' ')
echo "steal: stolen=$STOLEN lock_left=$ELOCK"          # esperado: stolen=1 lock_left=0
[ "$STOLEN" = 1 ] && [ "$ELOCK" = 0 ] || FAIL=1

# Complementaria 3 (hallazgo adversarial): memory/ virgen, sin .journal/ — compactar antes del
# primer evento (Step 3-pre del checkpoint) no debe decir "busy" ni fallar; y un replay de un
# evento ya aplicado se archiva como noop, no como applied.
V=$(mktemp -d) && [ -d "$V" ] || { echo "mktemp fallo en complementaria 3"; exit 1; }
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n\n' > $V/_pendientes.md
VOUT=$(MEMORY_DIR=$V python3 bin/journal-compact.py); VRC=$?
RID=$(MEMORY_DIR=$V python3 bin/journal-emit.py --type pendiente.add --text "replay item" --prioridad Alta --origen "[[sessions/test]]")
MEMORY_DIR=$V python3 bin/journal-compact.py --quiet
cp $V/.journal/applied/*/*.json $V/.journal/pending/
ROUT=$(MEMORY_DIR=$V python3 bin/journal-compact.py)
RN=$(grep -c '^- \[ \] replay item' $V/_pendientes.md)
echo "virgin: rc=$VRC out='$VOUT' replay='$ROUT' lines=$RN"   # esperado: rc=0, applied=0 sin busy; replay noop=1 applied=0; lines=1
[ "$VRC" = 0 ] && echo "$VOUT" | grep -q '^JOURNAL applied=0 quarantined=0 pending_left=0$' \
  && echo "$ROUT" | grep -q '^JOURNAL applied=0 quarantined=0 pending_left=0 noop=1' && [ "$RN" = 1 ] || FAIL=1
rm -r "$V"

[ "$FAIL" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $FAIL
