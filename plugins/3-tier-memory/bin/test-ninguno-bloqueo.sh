#!/bin/bash
# Prueba de 2.62.11: una decision del usuario no es un bloqueo. Caso real (claude-vzert,
# 2026-10-16): `p-341fdf5e59` nacio con `--bloqueado-por "decisiones de Victor"`, el bloqueo lo
# saco de `Proximo paso`, el snippet salio `Ninguno` y las decisiones quedaron escondidas.
#
#  1. checkpoint-audit.py avisa (`snippet.ninguno_bloqueo`, POR-DISEÑO) cuando el snippet dice
#     `ninguno` y la ficha lista un pendiente `_bloqueado`, aunque su `_origen` sea un research.
#  2. El paso que pone delante la decision ("decidir con Victor …") ya no sale como espera ajena en
#     `snippet.marco`: el aviso le decia al agente que lo bloqueara.
#  3. Fichas anteriores al corte (2026-10-16) no se miden.
#
# Contra 2.62.5 los casos 1 y 2 salen rojos. Uso: test-ninguno-bloqueo.sh (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

M="$T/memory"
SLUG=2026-10-16-canal

# memoria COLA [ORIGEN]: _pendientes.md con el pendiente del caso real; COLA va al final de su
# linea. ORIGEN por defecto es el del caso real (un research); `sesion` lo pone en esta ficha.
memoria() {
  local ORI="[[research/canal-2026-10]]"; [ "${2:-}" = sesion ] && ORI="[[sessions/$SLUG]]"
  mkdir -p "$M/sessions" "$M/pendientes" "$M/research"
  cat > "$M/_pendientes.md" <<EOF
---
type: index
---
# Pendientes

## Alta prioridad

- [ ] Fase 0 del plan bandeja (decisiones de Victor) — D4, D5 — _origen: ${ORI}_ — _creado: 2026-10-16_ — _id: p-341fdf5e59_$1

## Media prioridad

## Baja prioridad
EOF
}
# ficha FECHA RETOMAR: la ficha con ese `## Como retomar` y el pendiente listado en `## Pendientes`.
ficha() {
  python3 - "$M/sessions/$SLUG.md" "$1" "$2" <<'PY'
import sys
p, fecha, retomar = sys.argv[1], sys.argv[2], sys.argv[3].replace("\\n", "\n")
open(p, "w", encoding="utf-8").write(
    f"---\ntype: session\ndate: {fecha}\n---\n# Canal\n\n## Contexto\nalgo\n\n## Bugs fixed\n- Ninguno\n\n"
    "## Plans\n- Ninguno\n\n## Research\n- Ninguno\n\n## Learnings generados\n- Ninguno\n\n"
    "## Pendientes\n- [ ] Fase 0 del plan bandeja (decisiones de Victor) — `p-341fdf5e59`\n\n"
    f"## Commits\n- `abc1234`\n\n## Como retomar\n\n{retomar}\n\n## Related\n- [[_pendientes]]\n")
PY
}
audit() { python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$SLUG.md" --no-git --hoy 2026-10-16 --solo-snippet 2>&1; }
NINGUNO='Ninguno — el plan bandeja espera decisiones de Victor (`p-341fdf5e59`, bloqueado).'
BLOQUE='```\nRetomamos: bandeja.\n\nLee memory/sessions/2026-10-16-canal.md para el contexto completo.\n\nProximo paso: decidir con el usuario las decisiones abiertas de la Fase 0 (D4, D5), una pregunta por decision con su recomendacion (p-341fdf5e59).\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```'

echo "== 1. Ninguno con el pendiente bloqueado por decisiones del usuario: aviso =="
memoria " — _bloqueado: decisiones de Victor_"
ficha 2026-10-16 "$NINGUNO"
OUT=$(audit)
chk "POR-DISEÑO snippet.ninguno_bloqueo" "1" "$(printf '%s\n' "$OUT" | grep -c 'POR-DISEÑO .*snippet.ninguno_bloqueo')"
chk "nombra el pendiente y su bloqueo" "1" "$(printf '%s\n' "$OUT" | grep -c 'p-341fdf5e59 `_bloqueado: decisiones de Victor`')"
chk "no es SALTADO" "0" "$(printf '%s\n' "$OUT" | grep -c 'SALTADO .*snippet.ninguno_bloqueo')"
chk "en --json el estado es POR-DISEÑO (el que lee el hook de cierre)" "POR-DISEÑO" "$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$SLUG.md" --no-git --hoy 2026-10-16 --solo-snippet --json | python3 -c "import json,sys; print([x['estado'] for x in json.load(sys.stdin) if x['clave']=='snippet.ninguno_bloqueo'][0])")"

echo "== 2. el arreglo: desbloqueado y en el Proximo paso como decision con el usuario =="
memoria ""
ficha 2026-10-16 "$BLOQUE"
OUT=$(audit)
chk "snippet.ninguno_bloqueo HECHO" "1" "$(printf '%s\n' "$OUT" | grep -c 'HECHO .*snippet.ninguno_bloqueo')"
chk "decidir con el usuario no es espera ajena en snippet.marco" "1" "$(printf '%s\n' "$OUT" | grep -c 'HECHO .*snippet.marco')"
chk "y el paso pasa snippet.proximo_paso" "1" "$(printf '%s\n' "$OUT" | grep -c 'HECHO .*snippet.proximo_paso')"
senales() { python3 -c "import importlib.util,sys;s=importlib.util.spec_from_file_location('a','$BIN/pendientes_afines.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(len(m.senales_marco(sys.argv[1])))" "$1"; }
chk "el marco sigue avisando una espera condicional" "1" "$(senales 'publicar si Victor lo decide (p-341fdf5e59).')"
chk "y decidir con un tercero (un proveedor externo)" "1" "$(senales 'decidir con el proveedor externo el formato (p-341fdf5e59).')"
chk "decidir con el usuario (con o sin articulo) no es senal" "0 0" "$(senales 'decidir con el usuario D4 (p-341fdf5e59).') $(senales 'decidir con usuario D4 (p-341fdf5e59).')"

echo "== 2a. bloque completo con un pendiente bloqueado en la ficha: no es ninguno, no avisa =="
memoria " — _bloqueado: que otra instalacion actualice_"
ficha 2026-10-16 "$(printf '%s' "$BLOQUE" | sed 's/decidir con el usuario las decisiones abiertas de la Fase 0 (D4, D5), una pregunta por decision con su recomendacion (p-341fdf5e59)/arreglar el parser/')"
chk "snippet con paso y pendiente bloqueado: HECHO" "1" "$(audit | grep -c 'HECHO .*snippet.ninguno_bloqueo')"

echo "== 2b. el pendiente bloqueado nacio en esta sesion (no en un research) =="
memoria " — _bloqueado: decisiones de Victor_" sesion
ficha 2026-10-16 "$NINGUNO"
chk "tambien avisa: POR-DISEÑO snippet.ninguno_bloqueo" "1" "$(audit | grep -c 'POR-DISEÑO .*snippet.ninguno_bloqueo')"

echo "== 3. Ninguno sin pendiente bloqueado, y fichas viejas =="
memoria ""
ficha 2026-10-16 'Ninguno — la sesion cerro sola.'
chk "sin bloqueado: HECHO" "1" "$(audit | grep -c 'HECHO .*snippet.ninguno_bloqueo')"
memoria " — _bloqueado: decisiones de Victor_"
ficha 2026-10-15 "$NINGUNO"
chk "ficha anterior al corte: no se mide" "0" "$(audit | grep -c 'snippet.ninguno_bloqueo')"

echo "== 4. la regla en sus textos: una decision del usuario no es bloqueo =="
TPL="$BIN/../templates"
chk "Step 3b (--bloqueado-por) lo dice" "1" "$(grep -c 'Una decision del usuario NUNCA es bloqueo' "$TPL/checkpoint-3t.md")"
chk "Step 3b ya no pone 'una decision de otra persona' como bloqueo" "0" "$(grep -c 'una decision de otra$' "$TPL/checkpoint-3t.md")"
chk "Step 3a lo dice" "1" "$(grep -c 'never a decision of the user' "$TPL/checkpoint-3t.md")"
chk "Step 8 lo dice" "1" "$(grep -c 'El usuario no esta FUERA de la sesion' "$TPL/checkpoint-3t-step8.md")"
chk "el punto 5 del marco de Step 8 ya no manda bloquear una espera del usuario" "1 0" "$(grep -c 'decision \*\*del usuario\*\*, el paso es esa decision' "$TPL/checkpoint-3t-step8.md") $(grep -c 'una accion de fuera de la sesion, no es paso. Ponle' "$TPL/checkpoint-3t-step8.md")"
chk "la cabecera de uso de journal-emit.py lo dice" "1" "$(sed -n '1,60p' "$BIN/journal-emit.py" | grep -c 'nunca una decision del usuario')"
chk "y su --help de --bloqueado-por" "1" "$(python3 "$BIN/journal-emit.py" --help 2>&1 | tr -s ' \n' ' ' | grep -c 'nunca una decision del usuario')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
