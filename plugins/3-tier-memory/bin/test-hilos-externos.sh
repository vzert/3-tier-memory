#!/bin/bash
# Prueba de 2.67.0: un cierre no puede decir `ninguno` sobre un hilo externo (una bandeja entre
# agentes, un PR, un correo) que la sesion toco sin haberlo leido completo y sin dueno para lo que
# sigue abierto. Caso real (2026-10-26): la ficha citaba 4 mensajes de un hilo de 14, la vista que
# uso la sesion filtraba por destinatario, y un mensaje nuevo que pedia una decision antes del corte
# quedo fuera del snippet `Ninguno` y del recordatorio de calendario.
#
#  1. Sin `.hilos-externos.json` y sin `## Hilos externos`: el chequeo no aparece (inerte).
#  2. Con config, la ficha cita mensajes y no tiene la seccion: SALTADO (lo que bloquea el cierre).
#  3. La seccion no lista un mensaje citado: SALTADO.
#  4. Un hilo sin `leido completo`: SALTADO.
#  5. Un `abierto:` sin dueno, o con un pendiente cerrado: SALTADO.
#  6. Lo abierto con `p-…` vivo, `espera a <quien>` o `_descartado: …_`: HECHO.
#  7. `abiertos: ninguno`: HECHO. Config ilegible: SALTADO. Ficha anterior al corte: no se mide.
#  8. La regla en sus textos (Step 3-hilos, plantilla de la ficha, Step 8 caso 5).
#
# Contra 2.65.0 los casos 2-5 salen rojos. Uso: test-hilos-externos.sh (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

M="$T/memory"
SLUG=2026-10-26-corte
mkdir -p "$M/sessions" "$M/pendientes"
cat > "$M/_pendientes.md" <<'EOF'
---
type: index
---
# Pendientes

## Alta prioridad

- [ ] Decidir si el tercer cliente migra antes del corte — _origen: [[sessions/2026-10-26-corte]]_ — _creado: 2026-10-26_ — _id: p-aaaaaaaaaa_

## Media prioridad

- [x] Mandar la fecha del corte — _origen: [[sessions/2026-10-25-x]]_ — _creado: 2026-10-25_ — _id: p-bbbbbbbbbb_ — _cerrado: 2026-10-26_

## Baja prioridad
EOF

CONFIG='{"fuentes": [{"nombre": "bandeja", "patron": "comms/(\\d{4}-\\d\\d-\\d\\d-[a-z0-9]+-[0-9a-f]{8})", "leer": "leer-hilo {id}"}]}'
config() { printf '%s' "$1" > "$M/.hilos-externos.json"; }
sin_config() { rm -f "$M/.hilos-externos.json"; }

# ficha FECHA HILOS RETOMAR: HILOS es el cuerpo de `## Hilos externos` ("" = sin la seccion).
ficha() {
  python3 - "$M/sessions/$SLUG.md" "$1" "$2" "$3" <<'PY'
import sys
p, fecha, hilos, retomar = sys.argv[1], sys.argv[2], sys.argv[3].replace("\\n", "\n"), sys.argv[4]
sec = f"## Hilos externos\n{hilos}\n\n" if hilos else ""
open(p, "w", encoding="utf-8").write(
    f"---\ntype: session\ndate: {fecha}\n---\n# Corte\n\n## Contexto\nRevise la bandeja: "
    "[[comms/2026-10-26-cuenta-1a2b3c4d]] y respondi en [[comms/2026-10-26-otra-5e6f7a8b]].\n\n"
    "## Bugs fixed\n- Ninguno\n\n## Plans\n- Ninguno\n\n## Research\n- Ninguno\n\n"
    "## Learnings generados\n- Ninguno\n\n" + sec +
    "## Pendientes\n- [ ] Decidir si el tercer cliente migra antes del corte — `p-aaaaaaaaaa`\n\n"
    f"## Commits\n- `abc1234`\n\n## Como retomar\n\n{retomar}\n\n## Related\n- [[_pendientes]]\n")
PY
}
audit() { python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$SLUG.md" --no-git --hoy 2026-10-26 --solo-snippet 2>&1; }
cuenta() { printf '%s\n' "$OUT" | grep -c "$1"; }
NINGUNO='Ninguno — lo unico abierto espera al otro equipo y ya tiene fecha.'
CABEZA='- bandeja `corte-del-servidor` — leido completo 2026-10-26 22:10 (todos los destinatarios); mensajes: 2026-10-25-cuenta-0a0b0c0d, 2026-10-26-cuenta-1a2b3c4d, 2026-10-26-otra-5e6f7a8b, 2026-10-27-tercero-9c8d7e6f'

echo "== 1. sin config y sin seccion: inerte =="
sin_config; ficha 2026-10-26 "" "$NINGUNO"; OUT=$(audit)
chk "no aparece snippet.hilo_externo" "0" "$(cuenta 'snippet.hilo_externo')"

echo "== 2. config + cita + sin seccion: SALTADO =="
config "$CONFIG"; ficha 2026-10-26 "" "$NINGUNO"; OUT=$(audit)
chk "SALTADO snippet.hilo_externo" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
chk "nombra los dos mensajes citados" "1" "$(cuenta 'no tiene `## Hilos externos`: bandeja `2026-10-26-cuenta-1a2b3c4d`, bandeja `2026-10-26-otra-5e6f7a8b`')"
chk "en --json sale SALTADO (lo que lee el hook de cierre para bloquear)" "SALTADO" "$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$SLUG.md" --no-git --hoy 2026-10-26 --solo-snippet --json | python3 -c "import json,sys; print([x['estado'] for x in json.load(sys.stdin) if x['clave']=='snippet.hilo_externo'][0])")"

echo "== 3. la seccion no lista un mensaje citado =="
ficha 2026-10-26 '- bandeja `corte-del-servidor` — leido completo 2026-10-26; mensajes: 2026-10-26-cuenta-1a2b3c4d\n  - abiertos: ninguno' "$NINGUNO"; OUT=$(audit)
chk "SALTADO por el mensaje que falta" "1" "$(cuenta 'lista lo que la ficha cita: bandeja `2026-10-26-otra-5e6f7a8b`')"

echo "== 4. hilo sin leido completo =="
ficha 2026-10-26 '- bandeja `corte-del-servidor` — mensajes: 2026-10-26-cuenta-1a2b3c4d, 2026-10-26-otra-5e6f7a8b\n  - abiertos: ninguno' "$NINGUNO"; OUT=$(audit)
chk "SALTADO por hilo sin leido completo" "1" "$(cuenta 'hilo sin `leido completo')"

echo "== 5. abierto sin dueno, y abierto con pendiente cerrado =="
ficha 2026-10-26 "$CABEZA"'\n  - abierto: 2026-10-27-tercero-9c8d7e6f un tercer cliente llama al servidor viejo; decidir antes del corte' "$NINGUNO"; OUT=$(audit)
chk "SALTADO por abierto sin dueno" "1" "$(cuenta 'abierto sin dueno (ni')"
ficha 2026-10-26 "$CABEZA"'\n  - abierto: 2026-10-25-cuenta-0a0b0c0d mandar la fecha — p-bbbbbbbbbb' "$NINGUNO"; OUT=$(audit)
chk "SALTADO por abierto con pendiente cerrado" "1" "$(cuenta 'abierto con pendiente cerrado o inexistente')"

echo "== 6. lo abierto con dueno: HECHO =="
ficha 2026-10-26 "$CABEZA"'\n  - abierto: 2026-10-27-tercero-9c8d7e6f decidir si el tercer cliente migra — p-aaaaaaaaaa\n  - abierto: 2026-10-25-cuenta-0a0b0c0d no apagar antes de la fecha — espera a infra\n  - abierto: 2026-10-26-otra-5e6f7a8b acentos — _descartado: el usuario lo dejo asi_' "$NINGUNO"; OUT=$(audit)
chk "HECHO snippet.hilo_externo" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
chk "sin SALTADO" "0" "$(cuenta 'SALTADO .*snippet.hilo_externo')"

echo "== 7. abiertos ninguno, config ilegible, ficha vieja, seccion sin config =="
ficha 2026-10-26 "$CABEZA"'\n  - abiertos: ninguno' "$NINGUNO"; OUT=$(audit)
chk "abiertos ninguno: HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
config '{"fuentes": [{"nombre": "x", "patron": "("}]}'; OUT=$(audit)
chk "regex invalida: SALTADO (el hook de cierre solo bloquea SALTADO)" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
config "$CONFIG"; ficha 2026-10-25 "" "$NINGUNO"; OUT=$(audit)
chk "ficha anterior al corte: no se mide" "0" "$(cuenta 'snippet.hilo_externo')"
sin_config; ficha 2026-10-26 "$CABEZA"'\n  - abierto: 2026-10-27-tercero-9c8d7e6f decidir antes del corte' "$NINGUNO"; OUT=$(audit)
chk "seccion escrita sin config: tambien mide lo abierto" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"

echo "== 7b. adversario, ronda 1: grafias del abierto, ids numericos, grupo opcional, placeholder =="
config "$CONFIG"
for g in '  - Abierto: 2026-10-27-tercero-9c8d7e6f decidir' '  * abierto: 2026-10-27-tercero-9c8d7e6f decidir' '  - **abierto**: 2026-10-27-tercero-9c8d7e6f decidir' '  - abierto 2026-10-27-tercero-9c8d7e6f decidir' '- abierto: 2026-10-27-tercero-9c8d7e6f decidir'; do
  ficha 2026-10-26 "$CABEZA\n$g" "$NINGUNO"; OUT=$(audit)
  chk "grafia '$g' sin dueno: SALTADO" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
done
ficha 2026-10-26 "$CABEZA"'\n  - pendiente: revisar algo' "$NINGUNO"; OUT=$(audit)
chk "item que no es abierto ni abiertos ninguno: SALTADO" "1" "$(cuenta 'que no se reconoce')"
ficha 2026-10-26 "$CABEZA"'\n  - **Abiertos**: ninguno' "$NINGUNO"; OUT=$(audit)
chk "Abiertos: ninguno con enfasis: HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
config '{"fuentes": [{"nombre": "pr", "patron": "pull/(\\d+)", "leer": "gh pr view {id} --comments"}]}'
python3 - "$M/sessions/$SLUG.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("## Contexto\n", "## Contexto\nVi pull/5 y pull/4.\n", 1))
PY
ficha_pr() { python3 - "$M/sessions/$SLUG.md" "$1" <<'PY'
import re, sys
p, cuerpo = sys.argv[1], sys.argv[2].replace("\\n", "\n")
s = open(p, encoding="utf-8").read()
s = re.sub(r"## Hilos externos\n.*?\n\n", "## Hilos externos\n" + cuerpo + "\n\n", s, flags=re.S)
open(p, "w", encoding="utf-8").write(s)
PY
}
ficha_pr '- pr `PR 15 y 41` — leido completo 2026-10-05 22:10\n  - abiertos: ninguno'; OUT=$(audit)
chk "id numerico: 5 y 4 no estan en 'PR 15 y 41' ni en la fecha: SALTADO" "1" "$(cuenta 'lista lo que la ficha cita: pr `5`, pr `4`')"
ficha_pr '- pr `5` y `4` — leido completo 2026-10-26\n  - abiertos: ninguno'; OUT=$(audit)
chk "id numerico listado entero: HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
config '{"fuentes": [{"nombre": "x", "patron": "comms/(zz)?"}]}'; OUT=$(audit)
chk "grupo opcional sin casar: el audit no se cae" "1" "$(cuenta 'resumen:')"
sin_config; ficha 2026-10-26 '<filled in Step 3-hilos — borra esta seccion si la sesion no toco ningun hilo externo>' "$NINGUNO"; OUT=$(audit)
chk "sin config y solo el placeholder: inerte" "0" "$(cuenta 'snippet.hilo_externo')"

echo "== 7c. adversario, ronda 2: abierto fuera de una vineta =="
config "$CONFIG"
for g in 'Abierto: decidir cliente antes del corte' '    Abierto: decidir cliente antes del corte' '> abierto: decidir cliente' '| abierto | decidir cliente |' '  • abierto: decidir cliente' '  – abierto: decidir cliente'; do
  ficha 2026-10-26 "$CABEZA\n$g" "$NINGUNO"; OUT=$(audit)
  chk "'$g': SALTADO" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
done
ficha 2026-10-26 "$CABEZA"'; abierto: decidir el cliente\n  - abiertos: ninguno' "$NINGUNO"; OUT=$(audit)
chk "abierto pegado a la linea del hilo: SALTADO" "1" "$(cuenta 'en la linea del hilo')"
ficha 2026-10-26 "$CABEZA"'\nNota: lo revise con el comando de la config.\n  - abiertos: ninguno' "$NINGUNO"; OUT=$(audit)
chk "una nota sin la palabra abierto no bloquea" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"

echo "== 7d. adversario externo, ronda 1: lo citado tiene que salir en una linea de hilo =="
ficha 2026-10-26 '  - abierto: 2026-10-26-cuenta-1a2b3c4d 2026-10-26-otra-5e6f7a8b decidir — p-aaaaaaaaaa' "$NINGUNO"; OUT=$(audit)
chk "solo items, sin linea de hilo: SALTADO" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
chk "y lo dice" "1" "$(cuenta 'tiene items y ninguna linea de hilo')"
ficha 2026-10-26 'comms 2026-10-26-cuenta-1a2b3c4d 2026-10-26-otra-5e6f7a8b — leido completo 2026-10-26' "$NINGUNO"; OUT=$(audit)
chk "linea de hilo sin vineta: lo citado no cuenta como listado" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
ficha 2026-10-26 '- bandeja `corte-del-servidor` — leido completo 2026-10-26; mensajes: 2026-10-26-cuenta-1a2b3c4d\n  - abierto: 2026-10-26-otra-5e6f7a8b acentos — espera a infra' "$NINGUNO"; OUT=$(audit)
chk "citado solo en un abierto, no en la linea del hilo: SALTADO" "1" "$(cuenta 'lista lo que la ficha cita: bandeja `2026-10-26-otra-5e6f7a8b`')"

echo "== 7e. adversario externo, ronda 2: estado de lo abierto, duenos vacios o negados, secciones dobles =="
config "$CONFIG"
ficha 2026-10-26 "$CABEZA" "$NINGUNO"; OUT=$(audit)
chk "hilo sin abierto ni abiertos ninguno: SALTADO" "1" "$(cuenta 'hilo sin estado de lo abierto')"
for g in '  - abierto: 2026-10-27-tercero-9c8d7e6f decidir — espera a' '  - abierto: 2026-10-27-tercero-9c8d7e6f decidir; no espera a nadie' '  - abierto: 2026-10-27-tercero-9c8d7e6f decidir — espera a nadie' '  - abierto: 2026-10-27-tercero-9c8d7e6f decidir — _descartado: _'; do
  ficha 2026-10-26 "$CABEZA\n$g" "$NINGUNO"; OUT=$(audit)
  chk "dueno vacio o negado '$g': SALTADO" "1" "$(cuenta 'abierto sin dueno (ni')"
done
for c in 'no leido completo 2026-10-26' '"leido completo" es falso' 'leido completo'; do
  ficha 2026-10-26 "- bandeja \`corte\` — $c; mensajes: 2026-10-26-cuenta-1a2b3c4d, 2026-10-26-otra-5e6f7a8b\n  - abiertos: ninguno" "$NINGUNO"; OUT=$(audit)
  chk "lectura negada o sin fecha '$c': SALTADO" "1" "$(cuenta 'hilo sin `leido completo <fecha>`')"
done
python3 - "$M/sessions/$SLUG.md" "$CABEZA" <<'PY'
import sys
p, cab = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
doble = (f"## Hilos externos\n{cab}\n  - abierto: 2026-10-27-tercero-9c8d7e6f decidir antes del corte\n\n"
         f"## Hilos externos\n{cab}\n  - abiertos: ninguno\n\n")
import re
s = re.sub(r"## Hilos externos\n.*?\n\n", "", s, flags=re.S).replace("## Pendientes", doble + "## Pendientes", 1)
open(p, "w", encoding="utf-8").write(s)
PY
OUT=$(audit)
chk "dos secciones: el abierto sin dueno de la primera no se pierde" "1" "$(cuenta 'abierto sin dueno (ni')"

echo "== 7f. adversario externo, ronda 3: leer obligatorio, fecha con palabras, una sola clave =="
config '{"fuentes": [{"nombre": "bandeja", "patron": "comms/(\\d{4}-\\d\\d-\\d\\d-[a-z0-9]+-[0-9a-f]{8})"}]}'
ficha 2026-10-26 "$CABEZA"'\n  - abiertos: ninguno' "$NINGUNO"; OUT=$(audit)
chk "fuente sin leer: SALTADO" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
chk "y dice por que" "1" "$(cuenta 'sin `leer` con `{id}`')"
config '{"fuentes": [{"nombre": "bandeja", "patron": "comms/(x)", "leer": "leer-hilo"}]}'; OUT=$(audit)
chk "leer sin {id}: SALTADO" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
config '{roto'; OUT=$(audit)
chk "config rota con seccion: una sola linea snippet.hilo_externo" "1" "$(cuenta 'snippet.hilo_externo')"
sin_config; ficha 2026-10-26 '<placeholder>' "$NINGUNO"; config '{roto'; OUT=$(audit)
chk "config rota con seccion solo placeholder: tambien SALTADO" "1" "$(cuenta 'SALTADO .*snippet.hilo_externo')"
config "$CONFIG"
for c in 'leído completo el 2026-10-26' 'leido completo el dia 2026-10-26 22:10' 'leido completo (2026-10-26)'; do
  ficha 2026-10-26 "- bandeja \`corte\` — $c; mensajes: 2026-10-26-cuenta-1a2b3c4d, 2026-10-26-otra-5e6f7a8b\n  - abiertos: ninguno" "$NINGUNO"; OUT=$(audit)
  chk "'$c': HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
done

echo "== 7g. 2.67.1: negacion en la clausula, abierto dentro de un nombre =="
config "$CONFIG"
MSGS='mensajes: 2026-10-26-cuenta-1a2b3c4d, 2026-10-26-otra-5e6f7a8b'
for c in 'no he leido completo 2026-10-26' 'nunca leido completo 2026-10-26' 'sin leido completo 2026-10-26' 'no fue leido completo el 2026-10-26' 'no  leido completo 2026-10-26' 'todavia No lo he leído completo el 2026-10-26' 'jamas leido completo 2026-10-26'; do
  ficha 2026-10-26 "- bandeja \`corte\` — $c; $MSGS\n  - abiertos: ninguno" "$NINGUNO"; OUT=$(audit)
  chk "negacion en la clausula '$c': SALTADO" "1" "$(cuenta 'hilo sin `leido completo <fecha>`')"
done
for c in 'leido completo el 26 de octubre' 'leido completo 26/10' 'leido completo el dia 26' 'leido completo hoy 22:10' 'leido completo 2026-10-26 (no hubo mensajes nuevos)'; do
  ficha 2026-10-26 "- bandeja \`corte\` — $c; $MSGS\n  - abiertos: ninguno" "$NINGUNO"; OUT=$(audit)
  chk "sin negacion '$c': HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
done
# La etiqueta va en la misma clausula que la frase (sin `—` entre medias): solo la quita la regla
# de las comillas invertidas, o la de la palabra entera.
for e in '`no tocar`' '`sin revisor`' 'no-tocar'; do
  ficha 2026-10-26 "- bandeja $e leido completo 2026-10-26; $MSGS\n  - abiertos: ninguno" "$NINGUNO"; OUT=$(audit)
  chk "negacion solo dentro de la etiqueta $e: HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
done
ficha 2026-10-26 "- bandeja \`corte\` — no leido completo 2026-10-25; leido completo 2026-10-26; $MSGS\n  - abiertos: ninguno" "$NINGUNO"; OUT=$(audit)
chk "una lectura negada y otra afirmada: HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
ficha 2026-10-26 "- bandeja \`pedido-abierto-x\` — leido completo 2026-10-26; $MSGS\n  - abiertos: ninguno" "$NINGUNO"; OUT=$(audit)
chk "abierto dentro de la etiqueta del hilo: HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
ficha 2026-10-26 "$CABEZA"'\nNota: ver plan-abierto-q4 y pr-abierto.\n  - abiertos: ninguno' "$NINGUNO"; OUT=$(audit)
chk "abierto dentro de un nombre en una linea suelta: HECHO" "1" "$(cuenta 'HECHO .*snippet.hilo_externo')"
ficha 2026-10-26 "$CABEZA"'\nNota: queda abierto el corte.\n  - abiertos: ninguno' "$NINGUNO"; OUT=$(audit)
chk "abierto suelto en una linea suelta: sigue SALTADO" "1" "$(cuenta 'fuera de un item')"
ficha 2026-10-26 "- bandeja \`corte\` (abierto) — leido completo 2026-10-26; $MSGS\n  - abiertos: ninguno" "$NINGUNO"; OUT=$(audit)
chk "abierto suelto en la linea del hilo: sigue SALTADO" "1" "$(cuenta 'en la linea del hilo')"

echo "== 8. la regla en sus textos =="
TPL="$BIN/../templates"
chk "Step 3-hilos existe en checkpoint-3t.md" "1" "$(grep -c '^### Step 3-hilos' "$TPL/checkpoint-3t.md")"
chk "la plantilla de la ficha trae ## Hilos externos" "1" "$(grep -c '^## Hilos externos$' "$TPL/checkpoint-3t.md")"
chk "Step 8 caso 5 lo nombra" "1" "$(grep -c 'snippet.hilo_externo' "$TPL/checkpoint-3t-step8.md")"
chk "el docstring del audit lo nombra" "1" "$(sed -n '1,80p' "$BIN/checkpoint-audit.py" | grep -c 'hilos-externos.json')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
