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
  printf '1. **Nunca hagas git commit en el clon mientras corre review-team** — el gate lee el sha.\n'
  printf '2. **El cron del backup corre cada 5 minutos** — no lo bajes a 1 minuto.\n'
  printf '3. **Rotar la llave SSH del VPS cada trimestre** — con ssh-keygen y authorized_keys.\n'
  printf '4. **Postgres necesita vacuum semanal** — si no, la tabla de eventos crece sin freno.\n'
  printf '5. **Cloudflare cachea el HTML 4 horas** — purga tras cada deploy de la landing.\n'
  printf '6. **No hagas git commit en el clon con review-team corriendo: aborta sin veredicto** — duplicado de la 1.\n'
  printf '7. **Los logs de nginx rotan a diario** — logrotate con compress.\n'
  printf '8. **El token de la API caduca en 30 dias** — renuevalo antes del dia 25.\n'
  printf '9. **Docker compose pull antes de up** — si no, corre la imagen vieja.\n'
  printf '10. **La cola de correos reintenta 3 veces** — despues va a la cola muerta.\n'
  printf '11. **Los tests de integracion necesitan la base de datos de pruebas** — nunca la de produccion.\n'
  printf '12. **El dominio renueva en marzo** — la tarjeta del registrador caduca antes.\n'
} > "$M/learnings/deploy.md"
F="$TMP/ficha.md"
printf 'El agente hizo git commit en el clon mientras corria review-team y el gate aborto.\n' > "$F"
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
    caso "p$i" prompt '"voy a hacer git commit en el clon mientras corre review-team"' '["deploy#1"]' "$FN" >> "$1"
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
sed 's/voy a hacer git commit en el clon mientras corre review-team/receta de tamales oaxaquenos/' "$TMP/bueno.jsonl" > "$TMP/fallo.jsonl"
OUT=$(correr "$TMP/fallo.jsonl")
printf '%s' "$OUT" | grep -q "prompt@4=0/14" && ok "sin vocabulario comun: $OUT" || mal "$OUT"

echo "6. compare-motores: viejo == recall_rank.py sobre el corpus sintetico"
printf '%s\n' '"git commit en el clon con review-team"' '"cron del backup cada 5 minutos"' \
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

echo
if [ "$FALLOS" -eq 0 ]; then echo "test-bench: TODO VERDE"; else echo "test-bench: $FALLOS FALLOS"; exit 1; fi
