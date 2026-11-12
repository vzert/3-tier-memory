#!/bin/bash
# Prueba de 2.71.0: un `Proximo paso` que espera uso real o tiempo, sin fecha ISO, es SALTADO
# (decision de Victor del 2026-11-12).
#
# Caso real (este repo, cierre de 2.70.0 del 2026-11-11): el paso fue "medir con las fichas y
# transcripciones de los proximos dias cuantos choques quedan con 2.70.0", el pendiente nacio sin
# `--revisar` y la auditoria dio HECHO. La sesion siguiente no tenia ni un cierre con 2.70.0.
#
#  1. pendientes_afines.espera_uso: tiempo ("los proximos dias", "cuando haya cierres") y version
#     que la ficha publico; no un banco, no "tras /reload-plugins", no "en 30 dias" (rango de
#     datos), no un verbo y una version de clausulas distintas.
#  2. checkpoint-audit.py snippet.proximo_paso: SALTADO desde 2026-11-12; una ficha anterior no.
#  3. La salida que el aviso recomienda (`_revisar` futuro + `ninguno — <p-…> se mide desde
#     <fecha>`) pasa snippet.proximo_paso, snippet.hilo y las guardias de `ninguno`.
#  4. journal-emit.py pendiente.add avisa si el texto espera uso real y no trae `--revisar`.
#
# Uso: test-espera-uso.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

echo "== 1. espera_uso =="
eu() {   # eu PASO [TITULO] -> "si" | "no"
  python3 - "$BIN" "$1" "${2:-Demo}" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("af", sys.argv[1] + "/pendientes_afines.py")
af = importlib.util.module_from_spec(spec); spec.loader.exec_module(af)
ficha = "# " + sys.argv[3] + "\n\n## Cambios realizados\n- Version 2.71.0 + CHANGELOG.\n\n## Commits\n- x\n"
print("si" if af.espera_uso(sys.argv[2], ficha) else "no")
PY
}
chk "caso real: 'de los proximos dias'" "si" "$(eu 'Proximo paso: medir con las fichas y transcripciones de los próximos días cuántos choques quedan con 2.70.0 (p-b000000001).')"
chk "'cuando haya cierres'" "si" "$(eu 'medir cuando haya cierres reales con la version nueva (p-b000000001)')"
chk "'tras unos dias'" "si" "$(eu 'contar los avisos tras unos dias de uso (p-b000000001)')"
chk "version que la ficha publico (Cambios realizados)" "si" "$(eu 'observar 2.71.0 en una sesion real (p-b000000001)')"
chk "version que la ficha publico (titulo)" "si" "$(eu 'medir en la siguiente supervision real con 0.13.5 (p-b000000001)' 'lookout 0.13.5 publicado')"
chk "version que NO publico la ficha" "no" "$(eu 'medir en el VPS el inventario de upstream 2.63.47 (p-b000000001)')"
chk "prueba montada (banco)" "no" "$(eu 'medir en un banco 2.71.0 con un agente en bypass (p-b000000001)')"
chk "tras /reload-plugins" "no" "$(eu 'medir 2.71.0 tras /reload-plugins en esta misma maquina (p-b000000001)')"
chk "'en 30 dias' es rango de datos" "no" "$(eu 'medir cuantas compras no llegaron en 30 dias (p-b000000001)')"
chk "verbo y version en clausulas distintas" "no" "$(eu 'medir con datos del VPS; en paralelo, adaptar a 2.71.0 (p-b000000001)')"
chk "paso inmediato sin espera" "no" "$(eu 'quitar la liga de hermanos de marcar-retomar.py (p-b000000001)')"

echo "== 2. checkpoint-audit.py snippet.proximo_paso =="
M="$T/memory"; F=2026-11-12-hoy
memoria() {
  rm -rf "$M"; mkdir -p "$M/sessions" "$M/pendientes" "$M/plans"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
}
pend() {   # pend ID TEXTO [COLA]
  python3 - "$M/_pendientes.md" "- [ ] $2 — _origen: [[sessions/$F]]_ — _creado: 2026-11-12_ — _id: $1_${3:-}" <<'PY'
import sys
p, l = sys.argv[1:3]
t = open(p, encoding="utf-8").read().replace("## Media prioridad\n", "## Media prioridad\n\n" + l + "\n", 1)
open(p, "w", encoding="utf-8").write(t)
PY
}
ficha() {   # ficha PASO [FECHA] [CALENDARIO]
  python3 - "$M/sessions/$F.md" "$1" "${2:-2026-11-12}" "${3:-}" <<'PY'
import sys
p, paso, fecha, cal = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].replace("\\n", "\n")
t = ("---\ntype: session\ndate: " + fecha + "\n---\n# 2.71.0: demo\n\n"
     "## Contexto\nalgo\n\n## Cambios realizados\n- Version 2.71.0 + CHANGELOG.\n\n## Bugs fixed\n- Ninguno\n\n"
     "## Plans\n- Ninguno\n\n## Research\n- Ninguno\n\n## Learnings generados\n- Ninguno\n\n"
     "## Candidatos a pendiente\n- medir los choques — pregunta: Medir — recomendacion: guardar — decision: guardado `p-b000000001`\n\n"
     "## Pendientes\n- [ ] medir los choques — `p-b000000001`\n\n## Commits\n- `abc1234`\n\n"
     "## Como retomar\n\n```\nRetomamos: demo.\n\nLee memory/sessions/2026-11-12-hoy.md para el contexto "
     "completo.\n\n" + paso + "\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```\n\n"
     + (cal + "\n\n" if cal else "") + "## Related\n- [[_pendientes]]\n")
open(p, "w", encoding="utf-8").write(t)
PY
}
salida() { python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$F.md" --no-git --hoy 2026-11-12 --solo-snippet --json 2>/dev/null; }
estado() { salida | python3 -c '
import json, sys
x = [h for h in json.load(sys.stdin) if h["clave"] == sys.argv[1]]
print(x[0]["estado"] if x else "ausente")' "$1"; }
saltados() { salida | python3 -c '
import json, sys
print(" ".join(sorted(h["clave"] for h in json.load(sys.stdin) if h["estado"] == "SALTADO")) or "ninguno")'; }

memoria; pend p-b000000001 "medir los choques con 2.71.0"
ficha "Proximo paso: medir con las fichas de los proximos dias cuantos choques quedan (p-b000000001)."
chk "caso real: SALTADO" "SALTADO" "$(estado snippet.proximo_paso)"
chk "el motivo nombra la espera" "1" "$(salida | grep -c 'espera que pase el tiempo')"
ficha "Proximo paso: observar 2.71.0 en una sesion real (p-b000000001)."
chk "version recien publicada: SALTADO" "SALTADO" "$(estado snippet.proximo_paso)"
ficha "Proximo paso: medir 2.71.0 en un banco con un agente en bypass (p-b000000001)."
chk "banco: HECHO" "HECHO" "$(estado snippet.proximo_paso)"
ficha "Proximo paso: medir con las fichas de los proximos dias cuantos choques quedan (p-b000000001)." 2026-11-11
chk "ficha anterior al corte: HECHO como antes" "HECHO" "$(estado snippet.proximo_paso)"

echo "== 3. la salida recomendada pasa los demas chequeos =="
memoria; pend p-b000000001 "medir los choques con 2.71.0" " — _revisar: 2026-11-17_"
ficha "Proximo paso: ninguno — p-b000000001 se mide desde 2026-11-17, ver Recordatorios de calendario." 2026-11-12 \
  "## Recordatorios de calendario\n\n### 2026-11-17\n\`\`\`\nRetomamos: medir los choques (_id: p-b000000001_).\n\`\`\`"
chk "snippet.proximo_paso HECHO" "HECHO" "$(estado snippet.proximo_paso)"
chk "snippet.hilo no SALTADO" "no" "$( [ "$(estado snippet.hilo)" = SALTADO ] && echo si || echo no)"
chk "ningun chequeo SALTADO" "ninguno" "$(saltados)"
echo "   (y el paso inmediato que deja ese pendiente con _revisar futuro tampoco pasa: es lo que ya hacia)"
ficha "Proximo paso: medir los choques (p-b000000001)."
chk "citar el pendiente con _revisar futuro sigue SALTADO" "SALTADO" "$(estado snippet.proximo_paso)"

echo "== 4. journal-emit.py pendiente.add avisa sin --revisar =="
memoria
O=$(python3 "$BIN/journal-emit.py" --memory-dir "$M" --type pendiente.add --prioridad Media \
  --text "Medir en los proximos dias cuantos choques quedan con 2.71.0" --origen "[[sessions/$F]]" 2>&1)
chk "aviso al nacer sin --revisar" "1" "$(printf '%s' "$O" | grep -c 'espera uso real o tiempo')"
O=$(python3 "$BIN/journal-emit.py" --memory-dir "$M" --type pendiente.add --prioridad Media \
  --text "Medir en los proximos dias cuantos choques quedan con 2.71.1" --origen "[[sessions/$F]]" --revisar 2026-11-17 2>&1)
chk "sin aviso con --revisar" "0" "$(printf '%s' "$O" | grep -c 'espera uso real o tiempo')"
O=$(python3 "$BIN/journal-emit.py" --memory-dir "$M" --type pendiente.add --prioridad Media \
  --text "Quitar la liga de hermanos de marcar-retomar.py" --origen "[[sessions/$F]]" 2>&1)
chk "sin aviso en un pendiente inmediato" "0" "$(printf '%s' "$O" | grep -c 'espera uso real o tiempo')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
