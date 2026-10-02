#!/usr/bin/env bash
# Pruebas del banco de recall (Fase F0 del plan de ciclo de vida de learnings).
#
# Corre sobre un corpus SINTETICO en un temporal, asi que no depende de los memory/ de la maquina
# ni de casos.jsonl (que no se publica: cita fichas de sesion de otros proyectos).
#
#   1-3. Los tres sabotajes del criterio de aceptacion: 19 casos, 4 de accion, una fuente que no
#        existe. Cada uno debe salir 2 con su motivo. El control (20 casos validos) sale 0.
#   4.   Una cita que no esta en su fuente tambien se rechaza (el caso inventado).
#   5.   Las metricas salen de lo que devuelve el motor: prompt@4 y dedup@8 esperados a mano.
#   6-7. compare-motores.py: el motor viejo y recall_rank.py coinciden, y una copia saboteada de
#        recall_rank.py (orden invertido) se detecta.
#
# sella-huellas: no (trabaja en un temporal propio)
set -u
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
BENCH=tools/recall-bench/recall-bench.py
CMP=tools/recall-bench/compare-motores.py
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FALLOS=0
ok()   { printf '  ok   %s\n' "$1"; }
mal()  { printf '  MAL  %s\n' "$1"; FALLOS=$((FALLOS + 1)); }

# --- corpus sintetico: un proyecto "demo" con un topic de 12 reglas --------------------------
M="$TMP/raiz/demo/memory"
mkdir -p "$M/learnings" "$M/sessions"
printf '# Pendientes\n' > "$M/_pendientes.md"
{
  printf -- '---\nimportance: 8\n---\n# Deploy\n\n'
  printf '1. **Nunca hagas git commit en el clon mientras corre el revisor** — el gate lee el sha.\n'
  printf '2. **El cron del backup corre cada 5 minutos** — no lo bajes a 1 minuto.\n'
  printf '3. **Rotar la llave SSH del VPS cada trimestre** — con ssh-keygen y authorized_keys.\n'
  printf '4. **Postgres necesita vacuum semanal** — si no, la tabla de eventos crece sin freno.\n'
  printf '5. **Cloudflare cachea el HTML 4 horas** — purga tras cada deploy de la landing.\n'
  printf '6. **No hagas git commit en el clon con el revisor corriendo: aborta sin veredicto** — duplicado de la 1.\n'
  printf '7. **Los logs de nginx rotan a diario** — logrotate con compress.\n'
  printf '8. **El token de la API caduca en 30 dias** — renuevalo antes del dia 25.\n'
  printf '9. **Docker compose pull antes de up** — si no, corre la imagen vieja.\n'
  printf '10. **La cola de correos reintenta 3 veces** — despues va a la cola muerta.\n'
  printf '11. **Los tests de integracion necesitan la base de datos de pruebas** — nunca la de produccion.\n'
  printf '12. **El dominio renueva en marzo** — la tarjeta del registrador caduca antes.\n'
} > "$M/learnings/deploy.md"
F="$TMP/ficha.md"
printf 'El agente hizo git commit en el clon mientras corria el revisor y el gate aborto.\n' > "$F"
# La ruta de `fuente` viaja DENTRO del JSON: en Git Bash nadie la convierte a la forma nativa
# (regla 169), y el python de Windows no encontraria /tmp/... Como argumento si se convierte sola.
nativa() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" || printf '%s' "$1"; }
FN=$(nativa "$F")

caso() {  # $1 id, $2 canal, $3 entrada(JSON), $4 esperadas(JSON), $5 fuente
  printf '{"id":"%s","corpus":"demo","canal":"%s","entrada":%s,"esperadas":%s,"prohibidas":[],"fuente":"%s","cita":"git commit en el clon","nota":"sintetico"}\n' \
    "$1" "$2" "$3" "$4" "$5"
}
generar() {  # $1 fichero, $2 n_prompt, $3 n_accion, $4 fuente del ultimo caso
  : > "$1"
  local i
  for i in $(seq 1 "$2"); do
    caso "p$i" prompt '"voy a hacer git commit en el clon mientras corre el revisor"' '["deploy#1"]' "$FN" >> "$1"
  done
  for i in $(seq 1 "$3"); do
    caso "a$i" accion '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' '["deploy#1"]' "$FN" >> "$1"
  done
  caso "d1" dedup '"deploy#6"' '["deploy#1"]' "$4" >> "$1"
}
correr() { python3 "$BENCH" --corpus-raiz "$TMP/raiz" --hoy 2026-09-30 --casos "$1" 2>&1; }

echo "0. control: 20 casos validos (14 prompt, 5 accion, 1 dedup) corren"
generar "$TMP/bueno.jsonl" 14 5 "$FN"
OUT=$(correr "$TMP/bueno.jsonl"); RC=$?
[ "$RC" -eq 0 ] && ok "rc=0: $OUT" || mal "rc=$RC: $OUT"

echo "1. sabotaje: 19 casos"
generar "$TMP/s1.jsonl" 13 5 "$FN"
OUT=$(correr "$TMP/s1.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "hay 19 casos" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "2. sabotaje: 4 casos de accion (con 20 casos en total)"
generar "$TMP/s2.jsonl" 15 4 "$FN"
OUT=$(correr "$TMP/s2.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "4 casos del canal accion" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "3. sabotaje: una fuente que no existe"
generar "$TMP/s3.jsonl" 14 5 "$(nativa "$TMP")/no-existe.md"
OUT=$(correr "$TMP/s3.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "la fuente no existe" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "4. una cita que no aparece en su fuente"
sed 's/git commit en el clon/frase inventada/' "$TMP/bueno.jsonl" > "$TMP/s4.jsonl"
OUT=$(correr "$TMP/s4.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "cita no aparece" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "4b. un caso que cita un numero de regla repetido en su topic file (ambiguo)"
cp "$M/learnings/deploy.md" "$TMP/deploy.orig"
printf '\n## Otra lista\n\n1. **Regla repetida con el numero 1** — segunda lista numerada.\n' >> "$M/learnings/deploy.md"
OUT=$(correr "$TMP/bueno.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "deploy#1 es ambigua" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"
cp "$TMP/deploy.orig" "$M/learnings/deploy.md"

echo "4c. los casos de origen medida no completan el minimo (19 de incidente + 1 de medida)"
generar "$TMP/s4c.jsonl" 13 5 "$FN"
caso "m1" prompt '"una frase de medida"' '["deploy#1"]' "$FN" | sed 's/}$/,"origen":"medida"}/' >> "$TMP/s4c.jsonl"
OUT=$(correr "$TMP/s4c.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "hay 19 casos" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "4d. una regla esperada y prohibida a la vez"
sed '1s/"prohibidas":\[\]/"prohibidas":["deploy#1"]/' "$TMP/bueno.jsonl" > "$TMP/s4d.jsonl"
OUT=$(correr "$TMP/s4d.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "esperada y prohibida" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "5. las metricas salen del motor"
OUT=$(python3 "$BENCH" --corpus-raiz "$TMP/raiz" --hoy 2026-09-30 --casos "$TMP/bueno.jsonl" --salida "$TMP/r.json" 2>&1)
# la regla 1 comparte casi todo el vocabulario del prompt: debe salir en el top 4 de los 14;
# la 6 (duplicado de la 1) debe tener a la 1 como vecina mas parecida.
if printf '%s' "$OUT" | grep -q "prompt@4=14/14" && printf '%s' "$OUT" | grep -q "dedup@8=1/1" \
   && python3 -c "import json,sys;d=json.load(open(sys.argv[1]));x=[c for c in d['detalle'] if c['id']=='d1'][0];sys.exit(0 if x['puestos']=={'deploy#1':1} else 1)" "$TMP/r.json"; then
  ok "$OUT"
else
  mal "$OUT"
fi
# y el prompt que no comparte vocabulario no acierta (el acierto no es gratis)
sed 's/voy a hacer git commit en el clon mientras corre el revisor/receta de tamales oaxaquenos/' "$TMP/bueno.jsonl" > "$TMP/fallo.jsonl"
OUT=$(correr "$TMP/fallo.jsonl")
printf '%s' "$OUT" | grep -q "prompt@4=0/14" && ok "sin vocabulario comun: $OUT" || mal "$OUT"

echo "6. compare-motores: viejo == recall_rank.py sobre el corpus sintetico"
printf '%s\n' '"git commit en el clon con el revisor"' '"cron del backup cada 5 minutos"' \
  '"rotar la llave ssh del vps"' '"vacuum de postgres semanal"' '"purga de cloudflare tras deploy"' \
  > "$TMP/prompts.jsonl"
OUT=$(python3 "$CMP" --memorias "$M" --prompts "$TMP/prompts.jsonl" --n 5 --min-con-salida 5 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "$OUT" || mal "rc=$RC: $OUT"

echo "7. compare-motores detecta un recall_rank.py saboteado (orden invertido)"
sed 's/return scored\[:k\]/return scored[:k][::-1]/' plugins/3-tier-memory/bin/recall_rank.py > "$TMP/mut.py"
if ! grep -q '\[::-1\]' "$TMP/mut.py"; then
  mal "la mutacion no se aplico (cambio el fuente de recall_rank.py?)"
else
  OUT=$(python3 "$CMP" --memorias "$M" --prompts "$TMP/prompts.jsonl" --n 5 --min-con-salida 1 --nuevo "$TMP/mut.py" 2>&1); RC=$?
  [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "DISTINTO" && ok "lo detecta: $(printf '%s' "$OUT" | tail -1)" || mal "rc=$RC: $OUT"
fi

NEUTRO=tools/recall-bench/corpus-neutro/casos.jsonl

echo "8. corpus neutro publicado: corre y reproduce sus lineas base fijadas"
OUT=$(python3 "$BENCH" --casos "$NEUTRO" --hoy 2026-09-30 --comprobar-linea-base 2>&1); RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "procedencia_verificada=4/21" && printf '%s' "$OUT" | grep -q "linea base reproducida: 5 casos" && ok "$(printf '%s' "$OUT" | tr '\n' ' ')" || mal "rc=$RC: $OUT"

echo "8b. corpus neutro ENRIQUECIDO (F4): las mismas 68 reglas con disparadores; su linea base"
# Las frases las escribio un subagente que no veia los casos (2.a ronda de F4). Linea base propia:
# prompt@4 14/14 y fuga 0 (el neutro sin disparadores, caso 8, sigue siendo la guarda de las
# instalaciones sin disparadores). Si baja, el formato o el motor perdio algo.
OUT=$(python3 "$BENCH" --casos tools/recall-bench/corpus-neutro-enriquecido/casos.jsonl --hoy 2026-09-30 --comprobar-linea-base 2>&1); RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "prompt@4=14/14" && printf '%s' "$OUT" | grep -q "fuga=0" && ok "$(printf '%s' "$OUT" | head -1)" || mal "rc=$RC: $OUT"

echo "9. una linea base que no se reproduce sale 1"
# copia del corpus en el temporal con la misma forma que el repo: las rutas de los casos son
# relativas a su fichero, y la procedencia apunta al CHANGELOG de la raiz
R2="$TMP/repo/tools/recall-bench/corpus-neutro"
mkdir -p "$TMP/repo/tools/recall-bench" && cp -R tools/recall-bench/corpus-neutro "$R2" && cp CHANGELOG.md "$TMP/repo/"
sed 's/"contiene": \["git-y-ci#3", "git-y-ci#17"\]/"contiene": ["git-y-ci#3", "git-y-ci#9"]/' "$NEUTRO" > "$R2/casos.jsonl"
OUT=$(python3 "$BENCH" --casos "$R2/casos.jsonl" --hoy 2026-09-30 --comprobar-linea-base 2>&1); RC=$?
if ! grep -q 'git-y-ci#9' "$R2/casos.jsonl"; then
  mal "la mutacion de la linea base no se aplico"
else
  [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "NO SE REPRODUCE" && ok "lo detecta" || mal "rc=$RC: $OUT"
fi

echo "10. minar-casos propone los 22 candidatos del corpus neutro, todos para revisar"
OUT=$(python3 tools/recall-bench/minar-casos.py --proyecto tools/recall-bench/corpus-neutro --salida "$TMP/cand.jsonl" 2>&1)
N=$(grep -c '"revisar": true' "$TMP/cand.jsonl")
printf '%s' "$OUT" | grep -q "22 candidatos (22 con regla resuelta" && [ "$N" -eq 22 ] && ok "$OUT" || mal "revisar=$N: $OUT"

echo "11. el banco se niega a correr con un candidato sin revisar"
{ cat "$TMP/bueno.jsonl"; head -1 "$TMP/cand.jsonl"; } > "$TMP/s11.jsonl"
OUT=$(correr "$TMP/s11.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "candidato sin revisar" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "12. \"revisar\": false tambien se rechaza (el campo se quita al revisar)"
{ cat "$TMP/bueno.jsonl"; head -1 "$TMP/cand.jsonl" | sed 's/"revisar": true/"revisar": false/'; } > "$TMP/s12.jsonl"
OUT=$(correr "$TMP/s12.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "candidato sin revisar" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "13. una linea_base_esperada sin reglas no fija nada y se rechaza"
sed '1s/"nota":"sintetico"}/"nota":"sintetico","linea_base_esperada":{"excluye":[]}}/' "$TMP/bueno.jsonl" > "$TMP/s13.jsonl"
OUT=$(correr "$TMP/s13.jsonl"); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "sin ninguna regla" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "14. una procedencia cuya cita no esta en su fuente se rechaza"
sed 's/(coincidencia exacta) era fragil a CRLF donde/(coincidencia exacta) una frase que no esta/' "$NEUTRO" > "$R2/casos.jsonl"
OUT=$(python3 "$BENCH" --casos "$R2/casos.jsonl" --hoy 2026-09-30 2>&1); RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q "cita de la procedencia" && ok "se niega: $OUT" || mal "rc=$RC: $OUT"

echo "15. bloqueos-reales: una regla retirada DESPUES del evento era vecina al emitir; antes, no"
bloq() {  # $1 = fecha de la retirada de la #1; el learning.add de la #2 es del 2026-10-01
  rm -rf "$TMP/bm"; mkdir -p "$TMP/bm/learnings" "$TMP/bm/.journal/applied/2026-10"
  printf -- '---\ntopic: t\n---\n# T\n\n## Rules\n\n1. **No usar git add -A en el clon** — se cuela todo lo de los hooks — ⊘ RETIRADA (%s, obsoleta): x\n2. **No usar git add -A en un clon** — se cuela todo lo de los hooks\n' "$1" > "$TMP/bm/learnings/t.md"
  python3 - "$TMP/bm/.journal/applied/2026-10/e.json" <<'PY'
import json, sys
from datetime import datetime, timezone
ts = int(datetime(2026, 10, 1, 12, tzinfo=timezone.utc).timestamp()) * 10**9
json.dump({"type": "learning.add", "ts": ts, "payload": {"topic": "t", "decision": "nueva",
           "text": "**No usar git add -A en un clon** — se cuela todo lo de los hooks"}}, open(sys.argv[1], "w"))
PY
  python3 tools/recall-bench/bloqueos-reales.py "$TMP/bm" 2>&1 | tr -d '\r' | tail -1
}
OUT=$(bloq 2026-10-05)
printf '%s' "$OUT" | grep -q "bloquearian=1 .*con_decision=1 de 1" && ok "retirada despues: cuenta: $OUT" || mal "retirada despues: $OUT"
OUT=$(bloq 2026-09-01)
printf '%s' "$OUT" | grep -q "bloquearian=0 " && ok "retirada antes: no cuenta: $OUT" || mal "retirada antes: $OUT"

echo "16. bloqueos-reales: un learning.update DESPUES del evento se deshace; uno de ANTES, no"
bloqu() {  # $1 = dia del update de la #1 (el add de la #2 es del 2026-10-05)
  rm -rf "$TMP/bu"; mkdir -p "$TMP/bu/learnings" "$TMP/bu/.journal/applied/2026-10"
  printf -- '---\ntopic: t\n---\n# T\n\n## Rules\n\n1. **Otra cosa distinta** — nada que ver con nada\n2. **No usar git add -A en un clon** — se cuela todo lo de los hooks\n' > "$TMP/bu/learnings/t.md"
  python3 - "$TMP/bu/.journal/applied/2026-10" "$1" <<'PY'
import json, sys
from datetime import datetime, timezone
d, dia = sys.argv[1], int(sys.argv[2])
ns = lambda day: int(datetime(2026, 10, day, 12, tzinfo=timezone.utc).timestamp()) * 10**9
ev = [("a1", {"type": "learning.add", "ts": ns(1), "payload": {"topic": "t",
         "text": "**No usar git add -A en el clon** — se cuela todo lo de los hooks"}}),
      ("a2", {"type": "learning.add", "ts": ns(5), "payload": {"topic": "t",
         "text": "**No usar git add -A en un clon** — se cuela todo lo de los hooks"}}),
      ("u1", {"type": "learning.update", "ts": ns(dia), "payload": {"topic": "t",
         "match_prefix": "No usar git add -A en el clon", "text": "**Otra cosa distinta** — nada que ver con nada"}})]
for n, e in ev:
    json.dump(e, open(f"{d}/{n}.json", "w"))
PY
  python3 tools/recall-bench/bloqueos-reales.py "$TMP/bu" 2>&1 | tr -d '\r' | tail -1
}
OUT=$(bloqu 9)
printf '%s' "$OUT" | grep -q "medidos=2 de 2 bloquearian=1 .*texto_incierto=0" && ok "update despues: se deshace y bloquea: $OUT" || mal "update despues: $OUT"
OUT=$(bloqu 3)
printf '%s' "$OUT" | grep -q "medidos=2 de 2 bloquearian=0 " && ok "update antes: no se deshace: $OUT" || mal "update antes: $OUT"

echo
if [ "$FALLOS" -eq 0 ]; then echo "test-bench: TODO VERDE"; else echo "test-bench: $FALLOS FALLOS"; exit 1; fi
