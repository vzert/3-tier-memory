#!/bin/bash
# Prueba de aceptacion del journal (v2.12.0): N agentes escriben pendientes (Fase 1) y
# sesiones, reglas, planes y research (Fase 2) a la vez y nada se pierde, nada se duplica,
# ningun numero de regla se repite, ningun lock queda huerfano.
#
# Cuerpo tomado tal cual de memory/plans/plan-journal-concurrencia-v2.12.0.md. Cada corrida
# lanza 2 workers (10 add + 5 resolve cada uno = 30 eventos concurrentes) contra 2
# compactadores simultaneos, y un barrido final. Se exige 5/5 corridas limpias, mas:
#   - un solo agente, 10 eventos secuenciales, sin lock residual, < 1 s
#   - lock huerfano (TTL vencido): 5 compactadores compiten, exactamente 1 lo roba
#
#   - Fase 2: 2 workers x (6 learning.add + 6 session.add + 2 plan.upsert + 2 research.upsert)
#     vs 2 compactadores, 5/5 corridas: reglas 1..12 contiguas sin texto repetido, Quick Ref
#     12 sin numero repetido, 12 sesiones podadas a 10 (las dos mas viejas fuera), 1 fila de
#     plan con el status final, research en Completed y fuera de Active; replay = noop.
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

# ---------------------------------------------------------------------------- Fase 2
# Sesiones, reglas, planes y research: 2 workers concurrentes contra 2 compactadores.
seed_f2() {
  printf -- '---\ntype: index\nupdated: 2020-01-01\n---\n# Session Index\n\n## Sessions\n\n| Fecha | Sesion | Status | Resumen | Commit |\n|---|---|---|---|---|\n\n## Related\n- [[_pendientes]]\n' > $M/_session-index.md
  printf -- '---\ntype: index\nupdated: 2020-01-01\n---\n# Learnings Index\n\n## Topic Files\n\n| Topic | File | When to consult |\n|---|---|---|\n\n## Quick Reference — Most Critical Rules\n\n## Related\n- [[_pendientes]]\n' > $M/_learnings.md
  printf -- '---\ntype: index\nupdated: 2020-01-01\n---\n# Plans Index\n\n## Plans\n\n| Plan | Status | Fecha | Sesion | Pendientes | Learnings |\n|---|---|---|---|---|---|\n\n## Related\n- [[_pendientes]]\n' > $M/_plans-index.md
  printf -- '---\ntype: index\nupdated: 2020-01-01\n---\n# Research Index\n\n## Active Research\n\n| Tema | Next step | Origen | Archivo |\n|---|---|---|---|\n<!-- Sin research activo -->\n\n## Completed Research\n\n| Tema | Resultado | Archivo |\n|---|---|---|\n\n## Related\n- [[_plans-index]]\n' > $M/_research-index.md
  rm -r $M/learnings 2>/dev/null; mkdir -p $M/learnings
}
for t in 1 2 3 4 5; do
  rm -r $M/.journal 2>/dev/null; seed_f2
  worker2() { W=$1; for i in 1 2 3 4 5 6; do
      python3 bin/journal-emit.py --type learning.add --topic race-topic --title "Race Topic" --when "al probar" \
        --text "**w$W regla $i trial $t** — detalle con | pipe" --quickref "w$W qr $i trial $t" >/dev/null || exit 2
      python3 bin/journal-emit.py --type session.add --slug "2026-01-0$i-w$W-trial$t" --date "2026-01-0$i" \
        --status completada --summary "w$W sesion $i \| con pipe" >/dev/null || exit 2
    done
    python3 bin/journal-emit.py --type plan.upsert --slug race-plan --title "Race plan" --status draft --date 2026-01-01 --sesion "[[sessions/x]]" >/dev/null || exit 2
    python3 bin/journal-emit.py --type plan.upsert --slug race-plan --title "Race plan" --status "active w$W" >/dev/null || exit 2
    python3 bin/journal-emit.py --type research.upsert --slug race-research --tema "Race research" --status active --next-step "paso w$W" --origen "[[sessions/x]]" >/dev/null || exit 2
    python3 bin/journal-emit.py --type research.upsert --slug race-research --tema "Race research" --status completed --resultado "listo w$W" >/dev/null || exit 2
  }
  worker2 A & worker2 B &
  python3 bin/journal-compact.py --quiet & python3 bin/journal-compact.py --quiet & wait
  python3 bin/journal-compact.py --quiet
  RULES=$(grep -c '^[0-9]*\. \*\*w[AB] regla' $M/learnings/race-topic.md)                                  # esperado: 12
  RMAX=$(grep -o '^[0-9]*\. ' $M/learnings/race-topic.md | sort -n | tail -1 | tr -d '. ')                # esperado: 12 (contiguas)
  RDUPN=$(grep -o '^[0-9]*\. ' $M/learnings/race-topic.md | sort | uniq -d | wc -l | tr -d ' ')           # esperado: 0
  RDUPT=$(grep '^[0-9]*\. ' $M/learnings/race-topic.md | sed 's/^[0-9]*\. //' | sort | uniq -d | wc -l | tr -d ' ')  # esperado: 0
  QR=$(sed -n '/## Quick Reference/,/## Related/p' $M/_learnings.md | grep -c '^[0-9]*\. w[AB] qr')       # esperado: 12
  QRDUP=$(sed -n '/## Quick Reference/,/## Related/p' $M/_learnings.md | grep -o '^[0-9]*\. ' | sort | uniq -d | wc -l | tr -d ' ')  # esperado: 0
  TOPIC=$(grep -c '\[\[learnings/race-topic\]\]' $M/_learnings.md)                                        # esperado: 1
  SESS=$(grep -c '^| 2026-01-0[0-9] | \[\[sessions/' $M/_session-index.md)                                # esperado: 10 (12 podadas a 10)
  SOLD=$(grep -c '^| 2026-01-01 |' $M/_session-index.md)                                                  # esperado: 0 (las mas viejas fuera)
  SDUP=$(grep -o '\[\[sessions/[^]\\]*' $M/_session-index.md | sort | uniq -d | wc -l | tr -d ' ')       # esperado: 0
  SPIPE=$(grep -c 'sesion [0-9] \\| con pipe | completada\|con pipe |' $M/_session-index.md)             # esperado: 10 (el \| no partio la celda)
  PLAN=$(grep -c 'plans/plan-race-plan' $M/_plans-index.md)                                               # esperado: 1
  PSTAT=$(grep 'plans/plan-race-plan' $M/_plans-index.md | grep -c '| active w[AB] | 2026-01-01 |')       # esperado: 1 (ultimo status; Fecha intacta)
  RACT=$(sed -n '/## Active Research/,/## Completed/p' $M/_research-index.md | grep -c 'research/race-research')   # esperado: 0
  RDONE=$(sed -n '/## Completed Research/,/## Related/p' $M/_research-index.md | grep -c 'research/race-research') # esperado: 1
  PEND=$(ls $M/.journal/pending 2>/dev/null | wc -l | tr -d ' '); QUAR=$(ls $M/.journal/quarantine 2>/dev/null | wc -l | tr -d ' ')
  FAILED=$(ls $M/.journal/failed 2>/dev/null | wc -l | tr -d ' '); LOCK=$(ls -d $M/.journal/.lock 2>/dev/null | wc -l | tr -d ' ')
  echo "f2 trial $t: rules=$RULES max=$RMAX dupnums=$RDUPN duptext=$RDUPT qr=$QR qrdup=$QRDUP topic=$TOPIC sessions=$SESS oldest_left=$SOLD dupslugs=$SDUP pipe_ok=$SPIPE plan=$PLAN plan_status=$PSTAT r_active=$RACT r_done=$RDONE pending=$PEND quarantine=$QUAR failed=$FAILED lock=$LOCK"
  [ "$RULES" = 12 ] && [ "$RMAX" = 12 ] && [ "$RDUPN" = 0 ] && [ "$RDUPT" = 0 ] && [ "$QR" = 12 ] && [ "$QRDUP" = 0 ] && [ "$TOPIC" = 1 ] \
    && [ "$SESS" = 10 ] && [ "$SOLD" = 0 ] && [ "$SDUP" = 0 ] && [ "$SPIPE" = 10 ] && [ "$PLAN" = 1 ] && [ "$PSTAT" = 1 ] \
    && [ "$RACT" = 0 ] && [ "$RDONE" = 1 ] && [ "$PEND" = 0 ] && [ "$QUAR" = 0 ] && [ "$FAILED" = 0 ] && [ "$LOCK" = 0 ] || FAIL=1
done

# Fase 2, replay: volver a aplicar todos los eventos ya aplicados no cambia ningun archivo
# y cuenta como noop (los 4 indices + el topic file quedan byte a byte iguales).
R=$(mktemp -d) && [ -d "$R" ] || { echo "mktemp fallo en replay f2"; exit 1; }
cp $M/_session-index.md $M/_learnings.md $M/_plans-index.md $M/_research-index.md $R/; cp $M/learnings/race-topic.md $R/
cp $M/.journal/applied/*/*.json $M/.journal/pending/
F2OUT=$(python3 bin/journal-compact.py)
SAME=0; for f in _session-index.md _learnings.md _plans-index.md _research-index.md; do cmp -s $M/$f $R/$f && SAME=$((SAME+1)); done
cmp -s $M/learnings/race-topic.md $R/race-topic.md && SAME=$((SAME+1))
# Un upsert re-aplicado puede cambiar una celda que el siguiente evento restaura (ultimo escritor
# gana), asi que `applied` puede ser >0 en un replay; lo que se exige es que el estado final sea
# byte a byte el mismo, que los 32 eventos se archiven (applied+noop=32) y que nada quede en
# pending/ ni en quarantine/.
F2A=$(echo "$F2OUT" | sed -n 's/.*applied=\([0-9]*\).*/\1/p'); F2N=$(echo "$F2OUT" | sed -n 's/.*noop=\([0-9]*\).*/\1/p'); F2N=${F2N:-0}
echo "f2 replay: out='$F2OUT' files_unchanged=$SAME"     # esperado: quarantined=0 pending_left=0, applied+noop=32, files_unchanged=5
echo "$F2OUT" | grep -q 'quarantined=0 pending_left=0' && [ "$((F2A + F2N))" = 32 ] && [ "$SAME" = 5 ] || FAIL=1
rm -r "$R"

# Fase 2, poda de Completed Research por fecha (hallazgo adversarial): 6 filas con _completado
# sembradas + 1 sin fecha (a mano) + 1 evento nuevo de hoy → quedan las 5 mas nuevas por fecha y la
# fila sin fecha intacta; un `completed` viejo (2021) re-aplicado NO expulsa a una mas nueva.
seed_f2
printf -- '| viejo6 | r | [[research/viejo6]] _completado: 2022-06-01_ |\n| viejo5 | r | [[research/viejo5]] _completado: 2022-05-01_ |\n| viejo4 | r | [[research/viejo4]] _completado: 2022-04-01_ |\n| viejo3 | r | [[research/viejo3]] _completado: 2022-03-01_ |\n| viejo2 | r | [[research/viejo2]] _completado: 2022-02-01_ |\n| viejo1 | r | [[research/viejo1]] _completado: 2022-01-01_ |\n| a mano | r | [[research/mano]] |\n' > $M/rows.txt
python3 - "$M" <<'PY'
import sys; m=sys.argv[1]; p=m+"/_research-index.md"; s=open(p).read(); rows=open(m+"/rows.txt").read()
s=s.replace("| Tema | Resultado | Archivo |\n|---|---|---|\n", "| Tema | Resultado | Archivo |\n|---|---|---|\n"+rows); open(p,"w").write(s)
PY
rm -r $M/.journal 2>/dev/null
python3 bin/journal-emit.py --type research.upsert --slug nuevo --tema "Nuevo" --status completed --resultado ok >/dev/null || FAIL=1
python3 bin/journal-emit.py --type research.upsert --slug antiguo --tema "Antiguo" --status completed --resultado ok --date 2021-01-01 >/dev/null || FAIL=1
python3 bin/journal-compact.py --quiet || FAIL=1
RP=$(sed -n '/## Completed Research/,/## Related/p' $M/_research-index.md | grep -c '_completado:')     # esperado: 5
RPN=$(grep -c 'research/nuevo' $M/_research-index.md); RPO=$(grep -c 'research/antiguo' $M/_research-index.md)  # esperado: 1, 0
RP6=$(grep -c 'research/viejo6' $M/_research-index.md); RP1=$(grep -c 'research/viejo[12]' $M/_research-index.md)  # esperado: 1, 0
RPM=$(grep -c 'research/mano' $M/_research-index.md)                                                   # esperado: 1 (sin fecha: intacta)
echo "f2 research-prune: dated=$RP nuevo=$RPN antiguo=$RPO viejo6=$RP6 viejo1-2=$RP1 mano=$RPM"
[ "$RP" = 5 ] && [ "$RPN" = 1 ] && [ "$RPO" = 0 ] && [ "$RP6" = 1 ] && [ "$RP1" = 0 ] && [ "$RPM" = 1 ] || FAIL=1

[ "$FAIL" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $FAIL
