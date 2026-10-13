#!/bin/bash
# Prueba de 2.57.0 (p-b282a8cfc4): la regla del hilo de pendientes que Victor decidio el
# 2026-10-13 (memory/research/hilo-pendientes-relacionados-medicion). Una seccion por pieza, y cada
# una entra por un script que ya existia antes de 2.57.0 (journal-emit, print-como-retomar,
# checkpoint-audit): contra 2.56.1 todas salen rojas por la regla, no porque falte un script.
#
#  1. Liga al nacer: `pendiente.add` en una sesion que arranco con `Retomamos:` queda con
#     `_relacionado` a los ids del `Proximo paso` recibido, sin que el agente lo pida.
#  2. Hilo recursivo: un pendiente a 2 saltos de `_relacionado` sale en el snippet.
#  3. Orden: en empate de prioridad el nuevo va antes que el heredado; un heredado saltado 2
#     sesiones seguidas va antes que el nuevo (checkpoint-audit `snippet.hilo` y stamp-hilo.py).
#  4. El paso recibido que no se cerro sigue en el hilo aunque nada lo ligue.
#  5. Hasta 2 extras (la Baja solo sin Alta ni Media) y `quedan N en el hilo: <ids>`.
#
# Uso: test-hilo-pendientes.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
# Nada de la sesion de Claude Code donde corra la prueba: cada caso pone lo suyo.
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

M="$T/memory"
SID=11111111-2222-3333-4444-555555555555

memoria() {
  rm -rf "$M" "$T/home"; mkdir -p "$M/sessions" "$M/pendientes" "$M/plans"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
}
# pend PRIO ID TEXTO ORIGEN [COLA]: una linea abierta bajo su encabezado.
pend() {
  python3 - "$M/_pendientes.md" "$1" "- [ ] $3 — _origen: [[sessions/$4]]_ — _creado: 2026-10-01_ — _id: $2_${5:-}" <<'PY'
import sys
p, prio, l = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
# Al final de su seccion: el orden de las filas es el orden en que se agregan.
h = f"## {prio} prioridad\n"
i = t.index(h) + len(h)
j = t.find("\n## ", i)
j = len(t) if j == -1 else j + 1
t = t[:j].rstrip("\n") + "\n" + l + "\n\n" + t[j:]
open(p, "w", encoding="utf-8").write(t)
PY
}
# transcripcion RUTA SNIPPET [FICHA]: un .jsonl cuyo primer mensaje de usuario es el snippet (pegado)
# y que despues ESCRIBE la ficha FICHA (por defecto 2026-10-14-hoy.md) con Write, como el Step 2.
transcripcion() {
  mkdir -p "$(dirname "$1")"
  python3 - "$1" "$2" "${3:-2026-10-14-hoy.md}" <<'PY'
import json, sys
ruta, snip, escrita = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3]
with open(ruta, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "permission-mode", "permissionMode": "auto"}) + "\n")
    fh.write(json.dumps({"type": "user", "isMeta": True, "message": {"content": "<local-command-caveat>x</local-command-caveat>"}}) + "\n")
    fh.write(json.dumps({"type": "user", "message": {"role": "user", "content": "\n\n<pasted_content id=\"ab12\">\n" + snip + "\n</pasted_content id=\"ab12\">"}, "timestamp": "2026-10-14T15:00:00Z"}) + "\n")
    fh.write(json.dumps({"type": "assistant", "timestamp": "2026-10-14T15:10:00Z", "message": {"content": [
        {"type": "tool_use", "name": "Read", "input": {"file_path": "/p/memory/sessions/2026-10-14-leida.md"}},
        {"type": "tool_use", "name": "Write", "input": {"file_path": "/p/memory/sessions/" + escrita, "content": "x"}}]}}) + "\n")
PY
}
# ficha SLUG PASO [FRONTMATTER-EXTRA]: una ficha con snippet en fence.
ficha() {
  python3 - "$M/sessions/$1.md" "$2" "${3:-}" <<'PY'
import sys
p, paso, fm = sys.argv[1], sys.argv[2], sys.argv[3].replace("\\n", "\n")
t = ("---\ntype: session\ndate: 2026-10-14\n" + (fm + "\n" if fm else "") + "---\n# Demo\n\n"
     "## Contexto\nalgo\n\n## Cambios realizados\nalgo\n\n## Bugs fixed\n- Ninguno\n\n## Plans\n- Ninguno\n\n"
     "## Research\n- Ninguno\n\n## Learnings generados\n- Ninguno\n\n## Pendientes\n- Ninguno\n\n"
     "## Commits\n- `abc1234`\n\n## Como retomar\n\n```\nRetomamos: demo.\n\n"
     "Lee memory/sessions/2026-10-14-hoy.md para el contexto completo.\n\n" + paso +
     "\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```\n\n## Related\n- [[_pendientes]]\n")
open(p, "w", encoding="utf-8").write(t)
PY
}
evento_rel() {   # el campo relacionado del unico pendiente.add en pending/
  python3 - "$M/.journal/pending" <<'PY'
import json, os, sys
d = sys.argv[1]
for n in sorted(os.listdir(d)):
    e = json.load(open(os.path.join(d, n), encoding="utf-8"))
    if e.get("type") == "pendiente.add":
        print(",".join(e["payload"].get("relacionado", [])) or "-")
PY
}
retomar() { python3 "$BIN/print-como-retomar.py" "$M/sessions/2026-10-14-hoy.md"; }
audit() { python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/2026-10-14-hoy.md" --no-git --hoy 2026-10-14 --solo-snippet 2>&1; }

SNIP='Retomamos: demo.\n\nLee memory/sessions/2026-10-13-ayer.md para el contexto completo.\n\nProximo paso: arreglar el parser\n(p-aaaaaaaaaa), empezando por la linea larga.\n\nSi ese paso es corto, suma en la misma sesion: p-bbbbbbbbbb (Media) — otra cosa.\n\nquedan 1 en el hilo: p-cccccccccc.\n\nAntes de actuar, dime en 3 lineas donde quedamos.'

echo "== 1. liga al nacer: pendiente.add se liga solo al Proximo paso recibido =="
memoria; ficha 2026-10-14-hoy "Proximo paso: x."
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP"
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "nuevo de hoy" --prioridad Media --origen "[[sessions/2026-10-14-hoy]]" >/dev/null 2>"$T/err1"
chk "el evento trae _relacionado al paso recibido, campo en 2 lineas" "p-aaaaaaaaaa" "$(evento_rel)"
chk "lo avisa por stderr" "1" "$(grep -c 'ligado al paso recibido: p-aaaaaaaaaa' "$T/err1")"
rm -rf "$M/.journal"
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "otro" --prioridad Alta --origen "[[sessions/2026-10-14-hoy]]" --relacionado plan-foo >/dev/null 2>&1
chk "suma el paso recibido a un --relacionado explicito" "plan-foo,p-aaaaaaaaaa" "$(evento_rel)"
rm -rf "$M/.journal"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" 'hola, arreglemos el parser (p-aaaaaaaaaa)'
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "nuevo" --prioridad Media --origen "[[sessions/2026-10-14-hoy]]" >/dev/null 2>&1
chk "sesion que no arranco con Retomamos: sin liga" "-" "$(evento_rel)"
rm -rf "$M/.journal"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP"
ficha 2026-09-01-vieja "Proximo paso: x."
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "de backfill" --prioridad Media --origen "[[sessions/2026-09-01-vieja]]" >/dev/null 2>&1
chk "ficha de otra fecha, backfill: no hereda el snippet de la sesion en curso" "-" "$(evento_rel)"
rm -rf "$M/.journal"
ficha 2026-10-14-otra "Proximo paso: x." "session_id: 99999999-2222-3333-4444-555555555555"
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "de otra sesion" --prioridad Media --origen "[[sessions/2026-10-14-otra]]" >/dev/null 2>&1
chk "ficha sellada con otro session_id: sin liga" "-" "$(evento_rel)"
rm -rf "$M/.journal"
python3 "$BIN/journal-emit.py" --memory-dir "$M" --transcript "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" \
  --type pendiente.add --text "de backfill con ruta" --prioridad Media --origen "[[sessions/2026-09-01-vieja]]" >/dev/null 2>&1
chk "--transcript a mano pasa por la misma guardia de fecha" "-" "$(evento_rel)"
rm -rf "$M/.journal"
ficha 2026-10-14-leida "Proximo paso: x."
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "de la ficha leida" --prioridad Media --origen "[[sessions/2026-10-14-leida]]" >/dev/null 2>&1
chk "ficha del mismo dia, sin sello, que la sesion solo leyo: sin liga" "-" "$(evento_rel)"
rm -rf "$M/.journal"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP" 2026-10-14-leida.md
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "de la ficha escrita" --prioridad Media --origen "[[sessions/2026-10-14-leida]]" >/dev/null 2>&1
chk "la misma ficha, si la sesion la escribio: liga" "p-aaaaaaaaaa" "$(evento_rel)"
rm -rf "$M/.journal"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP" "../not-sessions/2026-10-14-leida.md"
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "casi la ruta" --prioridad Media --origen "[[sessions/2026-10-14-leida]]" >/dev/null 2>&1
chk "escribir not-sessions/<ficha> no es escribir la ficha" "-" "$(evento_rel)"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP"
rm -rf "$M/.journal"
ficha 2026-10-14-hoy "Proximo paso: x." "hilo_paso: p-dddddddddd"
HOME="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "nuevo" --prioridad Media --origen "[[sessions/2026-10-14-hoy]]" >/dev/null 2>&1
chk "el sello de la ficha gana a la transcripcion" "p-dddddddddd" "$(evento_rel)"

echo "== stamp-hilo.py: sella lo recibido y cuenta los saltos =="
memoria; ficha 2026-10-14-hoy "Proximo paso: x."
ficha 2026-10-13-ayer "Proximo paso: y." "hilo_saltos: p-bbbbbbbbbb=1, p-eeeeeeeeee=4"
transcripcion "$T/t.jsonl" "$SNIP"
OUT=$(python3 "$BIN/stamp-hilo.py" "$M/sessions/2026-10-14-hoy.md" --transcript "$T/t.jsonl")
chk "sella" "sellado=1 motivo=sellada" "$OUT"
FM=$(sed -n '1,/^---$/p' "$M/sessions/2026-10-14-hoy.md")
chk "hilo_paso" "1" "$(printf '%s' "$FM" | grep -c '^hilo_paso: p-aaaaaaaaaa$')"
chk "hilo_heredados: paso + extras + quedan" "1" "$(printf '%s' "$FM" | grep -c '^hilo_heredados: p-aaaaaaaaaa, p-bbbbbbbbbb, p-cccccccccc$')"
chk "hilo_saltos: el de ayer mas 1; el paso no cuenta; uno que ya no vino se olvida" "1" "$(printf '%s' "$FM" | grep -c '^hilo_saltos: p-bbbbbbbbbb=2, p-cccccccccc=1$')"
chk "no pisa un sello ya puesto" "sellado=0 motivo=ya-sellada" "$(python3 "$BIN/stamp-hilo.py" "$M/sessions/2026-10-14-hoy.md" --transcript "$T/t.jsonl")"
ficha 2026-09-01-vieja "Proximo paso: z."
chk "no sella una ficha de otra fecha" "sellado=0 motivo=la-ficha-no-es-de-esa-transcripcion" "$(python3 "$BIN/stamp-hilo.py" "$M/sessions/2026-09-01-vieja.md" --transcript "$T/t.jsonl")"
ficha 2026-10-14-leida "Proximo paso: z."
chk "no sella una ficha del mismo dia que la sesion solo leyo" "sellado=0 motivo=la-ficha-no-es-de-esa-transcripcion" "$(python3 "$BIN/stamp-hilo.py" "$M/sessions/2026-10-14-leida.md" --transcript "$T/t.jsonl")"

# El hilo de las pruebas 2, 4 y 5: la ficha de hoy recibio p-aaaaaaaaaa (Alta, de ayer, sin cerrar y
# sin ninguna liga) y escribe como paso p-1111111111 (Alta, nuevo). p-2222222222 (Media) cita a
# p-1111111111; p-3333333333 (Media) cita a p-2222222222 (2 saltos); p-4444444444 (Baja) nace hoy;
# p-5555555555 (Alta) esta bloqueado y p-6666666666 (Media) tiene `_revisar` futuro: no son hacibles;
# p-9999999999 (Alta) no tiene relacion con nada.
hilo_base() {
  memoria
  ficha 2026-10-14-hoy "Proximo paso: hacer el nuevo (p-1111111111)." "hilo_paso: p-aaaaaaaaaa\nhilo_heredados: p-aaaaaaaaaa\nhilo_saltos:"
  pend Alta p-aaaaaaaaaa "el paso que recibio y no cerro" 2026-10-13-ayer
  pend Alta p-1111111111 "el nuevo" 2026-10-14-hoy
  pend Alta p-5555555555 "bloqueado" 2026-10-14-hoy " — _bloqueado: otra instalacion_"
  pend Alta p-9999999999 "suelto" 2026-09-01-vieja
  pend Media p-2222222222 "hermano" 2026-09-01-vieja " — _relacionado: p-1111111111_"
  pend Media p-3333333333 "nieto" 2026-09-01-vieja " — _relacionado: p-2222222222_"
  pend Media p-6666666666 "con fecha" 2026-10-14-hoy " — _revisar: 2026-10-20_"
  pend Baja p-4444444444 "la baja de hoy" 2026-10-14-hoy
}

echo "== 2. hilo recursivo: el de 2 saltos de _relacionado sale en el snippet =="
hilo_base; OUT=$(retomar)
chk "p-3333333333, el nieto, esta en el snippet" "1" "$(printf '%s\n' "$OUT" | grep -c 'p-3333333333')"
chk "el suelto sin relacion no" "0" "$(printf '%s\n' "$OUT" | grep -c 'p-9999999999')"
chk "ni el bloqueado ni el de _revisar futuro" "0" "$(printf '%s\n' "$OUT" | grep -c 'p-5555555555\|p-6666666666')"

echo "== 4. el paso recibido que no se cerro sigue en el hilo =="
chk "p-aaaaaaaaaa vuelve como extra" "1" "$(printf '%s\n' "$OUT" | grep '^Si ese paso es corto' | grep -c 'p-aaaaaaaaaa (Alta)')"

echo "== 5. hasta 2 extras (Alta > Media; la Baja no) y quedan N =="
chk "extras: el recibido Alta y el hermano Media, en ese orden" "1" "$(printf '%s\n' "$OUT" | grep -c '^Si ese paso es corto, suma en la misma sesion: p-aaaaaaaaaa (Alta) — el paso que recibio y no cerro; p-2222222222 (Media) — hermano\.$')"
chk "quedan N con el resto, solo ids" "1" "$(printf '%s\n' "$OUT" | grep -c '^quedan 2 en el hilo: p-3333333333, p-4444444444\.$')"
chk "la linea quedan va dentro del fence, tras los extras" "quedan" "$(printf '%s\n' "$OUT" | awk '/^Si ese paso/{f=1;next} f&&NF{print $1; exit}')"
memoria
ficha 2026-10-14-hoy "Proximo paso: hacer el nuevo (p-1111111111)."
pend Alta p-1111111111 "el nuevo" 2026-10-14-hoy
pend Media p-2222222222 "una media" 2026-10-14-hoy
pend Baja p-4444444444 "baja uno" 2026-10-14-hoy
OUT=$(retomar)
chk "con una Media fuera del paso, la Baja no entra como extra aunque sobre un hueco" "1" "$(printf '%s\n' "$OUT" | grep -c '^Si ese paso es corto, suma en la misma sesion: p-2222222222 (Media) — una media\.$')"
chk "y va a quedan" "1" "$(printf '%s\n' "$OUT" | grep -c '^quedan 1 en el hilo: p-4444444444\.$')"
memoria
ficha 2026-10-14-hoy "Proximo paso: hacer el nuevo (p-1111111111)."
pend Alta p-1111111111 "el nuevo" 2026-10-14-hoy
pend Baja p-4444444444 "baja uno" 2026-10-14-hoy
pend Baja p-7777777777 "baja dos" 2026-10-14-hoy
OUT=$(retomar)
chk "sin Alta ni Media fuera del paso, la Baja entra como extra" "1" "$(printf '%s\n' "$OUT" | grep '^Si ese paso es corto' | grep -c 'p-4444444444 (Baja).*p-7777777777 (Baja)')"
chk "y no hay linea quedan si no queda nada" "0" "$(printf '%s\n' "$OUT" | grep -c '^quedan')"

echo "== 3. orden: en empate el nuevo antes; el heredado saltado 2 sesiones, antes que el nuevo =="
empate() {   # $1 = cola de frontmatter con hilo_saltos, $2 = paso
  memoria
  ficha 2026-10-14-hoy "$2" "hilo_paso: p-0000000000\nhilo_heredados: p-0000000000\n$1"
  pend Alta p-0000000000 "el paso de ayer" 2026-10-13-ayer
  pend Alta p-1111111111 "el nuevo" 2026-10-14-hoy
}
empate "hilo_saltos: p-0000000000=1" "Proximo paso: seguir con lo de ayer (p-0000000000)."
chk "empate Alta/Alta, el paso cita al heredado: SALTADO" "1" "$(audit | grep -c 'SALTADO .*snippet.hilo')"
chk "y nombra al nuevo como el primero" "1" "$(audit | grep -c 'el primero es p-1111111111 (Alta, nacido en esta sesion)')"
empate "hilo_saltos: p-0000000000=1" "Proximo paso: hacer el nuevo (p-1111111111)."
chk "empate, el paso cita al nuevo: HECHO" "1" "$(audit | grep -c 'HECHO .*snippet.hilo')"
empate "hilo_saltos: p-0000000000=2" "Proximo paso: hacer el nuevo (p-1111111111)."
chk "heredado saltado 2 sesiones y el paso cita al nuevo: SALTADO" "1" "$(audit | grep -c 'el primero es p-0000000000 (Alta, heredado saltado 2 sesiones seguidas)')"
empate "hilo_saltos: p-0000000000=2" "Proximo paso: seguir con lo de ayer (p-0000000000)."
chk "heredado saltado 2 sesiones y el paso lo cita: HECHO" "1" "$(audit | grep -c 'HECHO .*snippet.hilo')"
memoria
ficha 2026-10-14-hoy "Proximo paso: la media (p-2222222222)."
pend Alta p-1111111111 "el alta nueva" 2026-10-14-hoy
pend Media p-2222222222 "la media nueva" 2026-10-14-hoy
chk "una Media nueva de paso con una Alta nueva abierta: SALTADO" "1" "$(audit | grep -c 'el primero es p-1111111111 (Alta')"
ficha 2026-10-14-hoy "Proximo paso: la media (p-2222222222), no la alta (p-1111111111)."
chk "nombrar al Alta de pasada no lo vuelve el paso: SALTADO" "1" "$(audit | grep -c 'el primero es p-1111111111 (Alta')"
chk "el orden lo imprime --hilo para el Step 8" "p-1111111111" "$(python3 "$BIN/pendientes_afines.py" "$M/sessions/2026-10-14-hoy.md" --hilo --hoy 2026-10-14 | head -1 | cut -d' ' -f1)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
