#!/bin/bash
# Prueba de 2.57.0 (p-b282a8cfc4): la regla del hilo de pendientes que Victor decidio el
# 2026-10-13 (memory/research/hilo-pendientes-relacionados-medicion). Una seccion por pieza, y cada
# una entra por un script que ya existia antes de 2.57.0 (journal-emit, print-como-retomar,
# checkpoint-audit): contra 2.56.1 todas salen rojas por la regla, no porque falte un script.
#
#  1. Liga al nacer: `pendiente.add` en una sesion que arranco con `Retomamos:` queda con
#     `_relacionado` a los ids del `Proximo paso` recibido, sin que el agente lo pida.
#  2. Hilo de un salto (2.62.0; en 2.57.0 era recursivo): el vecino directo sale, el de 2 no.
#  3. Orden: en empate de prioridad el nuevo va antes que el heredado; un heredado saltado 2
#     sesiones seguidas va antes que el nuevo (checkpoint-audit `snippet.hilo` y stamp-hilo.py).
#  4. El paso recibido que no se cerro sigue en el hilo aunque nada lo ligue.
#  5. Hasta 2 extras (la Baja solo sin Alta ni Media) y `quedan N en el hilo: <ids>`.
#  8. (2.62.0) El hilo no cruza por ids cerrados ni a otro tema: caso real de otro proyecto.
#  9. (2.62.0) El sello lee el id de `Retomamos:` en el prompt de un recordatorio de calendario.
# 10. (2.63.45) El evento lleva el session_id de CLAUDE_CODE_SESSION_ID; THREET_SESSION_ID y
#     --session siguen ganando.
#
# Uso: test-hilo-pendientes.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
# Nada de la sesion de Claude Code donde corra la prueba: cada caso pone lo suyo.
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR
# El home de mentira va en HOME y en USERPROFILE: en Windows, os.path.expanduser de Python lee
# USERPROFILE y no HOME, y sin el buscaria la transcripcion en el perfil real del runner.

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
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "nuevo de hoy" --prioridad Media --origen "[[sessions/2026-10-14-hoy]]" >/dev/null 2>"$T/err1"
chk "el evento trae _relacionado al paso recibido, campo en 2 lineas" "p-aaaaaaaaaa" "$(evento_rel)"
chk "lo avisa por stderr" "1" "$(grep -c 'ligado al paso recibido: p-aaaaaaaaaa' "$T/err1")"
rm -rf "$M/.journal"
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "otro" --prioridad Alta --origen "[[sessions/2026-10-14-hoy]]" --relacionado plan-foo >/dev/null 2>&1
chk "suma el paso recibido a un --relacionado explicito" "plan-foo,p-aaaaaaaaaa" "$(evento_rel)"
rm -rf "$M/.journal"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" 'hola, arreglemos el parser (p-aaaaaaaaaa)'
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "nuevo" --prioridad Media --origen "[[sessions/2026-10-14-hoy]]" >/dev/null 2>&1
chk "sesion que no arranco con Retomamos: sin liga" "-" "$(evento_rel)"
rm -rf "$M/.journal"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP"
ficha 2026-09-01-vieja "Proximo paso: x."
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "de backfill" --prioridad Media --origen "[[sessions/2026-09-01-vieja]]" >/dev/null 2>&1
chk "ficha de otra fecha, backfill: no hereda el snippet de la sesion en curso" "-" "$(evento_rel)"
rm -rf "$M/.journal"
ficha 2026-10-14-otra "Proximo paso: x." "session_id: 99999999-2222-3333-4444-555555555555"
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "de otra sesion" --prioridad Media --origen "[[sessions/2026-10-14-otra]]" >/dev/null 2>&1
chk "ficha sellada con otro session_id: sin liga" "-" "$(evento_rel)"
rm -rf "$M/.journal"
python3 "$BIN/journal-emit.py" --memory-dir "$M" --transcript "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" \
  --type pendiente.add --text "de backfill con ruta" --prioridad Media --origen "[[sessions/2026-09-01-vieja]]" >/dev/null 2>&1
chk "--transcript a mano pasa por la misma guardia de fecha" "-" "$(evento_rel)"
rm -rf "$M/.journal"
ficha 2026-10-14-leida "Proximo paso: x."
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "de la ficha leida" --prioridad Media --origen "[[sessions/2026-10-14-leida]]" >/dev/null 2>&1
chk "ficha del mismo dia, sin sello, que la sesion solo leyo: sin liga" "-" "$(evento_rel)"
rm -rf "$M/.journal"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP" 2026-10-14-leida.md
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "de la ficha escrita" --prioridad Media --origen "[[sessions/2026-10-14-leida]]" >/dev/null 2>&1
chk "la misma ficha, si la sesion la escribio: liga" "p-aaaaaaaaaa" "$(evento_rel)"
rm -rf "$M/.journal"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP" "../not-sessions/2026-10-14-leida.md"
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
  --type pendiente.add --text "casi la ruta" --prioridad Media --origen "[[sessions/2026-10-14-leida]]" >/dev/null 2>&1
chk "escribir not-sessions/<ficha> no es escribir la ficha" "-" "$(evento_rel)"
transcripcion "$T/home/.claude/projects/-tmp-proyecto/$SID.jsonl" "$SNIP"
rm -rf "$M/.journal"
ficha 2026-10-14-hoy "Proximo paso: x." "hilo_paso: p-dddddddddd"
HOME="$T/home" USERPROFILE="$T/home" CLAUDE_CODE_SESSION_ID=$SID python3 "$BIN/journal-emit.py" --memory-dir "$M" \
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
chk "hilo_retoma: la ficha que el snippet mandaba leer (2.63.42)" "1" "$(printf '%s' "$FM" | grep -c '^hilo_retoma: 2026-10-13-ayer$')"
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
  # `_revisar` lejano: retomar() usa la fecha real, y con 2026-10-20 este pendiente dejaba de ser
  # futuro el 21-oct y tres asertos de las secciones 2 y 5 caian en main (2.62.x).
  pend Media p-6666666666 "con fecha" 2026-10-14-hoy " — _revisar: 9999-12-31_"
  pend Baja p-4444444444 "la baja de hoy" 2026-10-14-hoy
}

echo "== 2. hilo de un salto (2.62.0): el vecino directo sale, el de 2 saltos no =="
hilo_base; OUT=$(retomar)
chk "p-2222222222, vecino directo del paso, esta en el snippet" "1" "$(printf '%s\n' "$OUT" | grep -c 'p-2222222222')"
chk "p-3333333333, el nieto (2 saltos), no esta" "0" "$(printf '%s\n' "$OUT" | grep -c 'p-3333333333')"
chk "el suelto sin relacion no" "0" "$(printf '%s\n' "$OUT" | grep -c 'p-9999999999')"
chk "ni el bloqueado ni el de _revisar futuro" "0" "$(printf '%s\n' "$OUT" | grep -c 'p-5555555555\|p-6666666666')"

echo "== 4. el paso recibido que no se cerro sigue en el hilo =="
chk "p-aaaaaaaaaa vuelve como extra" "1" "$(printf '%s\n' "$OUT" | grep '^Si ese paso es corto' | grep -c 'p-aaaaaaaaaa (Alta)')"

echo "== 5. hasta 2 extras (Alta > Media; la Baja no) y quedan N =="
chk "extras: el recibido Alta y el hermano Media, en ese orden" "1" "$(printf '%s\n' "$OUT" | grep -c '^Si ese paso es corto, suma en la misma sesion: p-aaaaaaaaaa (Alta) — el paso que recibio y no cerro; p-2222222222 (Media) — hermano\.$')"
chk "quedan N con el resto, solo ids" "1" "$(printf '%s\n' "$OUT" | grep -c '^quedan 1 en el hilo: p-4444444444\.$')"
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

echo "== 6. marco del Proximo paso (2.60.0): avisos POR-DISENO, nunca SALTADO =="
marco() {   # $1 = paso; imprime el audit
  memoria
  ficha 2026-10-14-hoy "$1"
  pend Alta p-1111111111 "el nuevo" 2026-10-14-hoy
  pend Media p-2222222222 "otro" 2026-10-14-hoy
  audit
}
OUT=$(marco "Proximo paso: arreglar el parser (p-1111111111).")
chk "paso limpio: HECHO" "1" "$(printf '%s\n' "$OUT" | grep -c 'HECHO .*snippet.marco')"
OUT=$(marco "Proximo paso: publicar el parser si Victor lo decide (p-1111111111).")
chk "espera de Victor sin _bloqueado: POR-DISENO" "1" "$(printf '%s\n' "$OUT" | grep -c 'POR-DISEÑO .*snippet.marco')"
chk "y no lo vuelve SALTADO" "0" "$(printf '%s\n' "$OUT" | grep -c 'SALTADO .*snippet.marco')"
chk "nombra la espera" "1" "$(printf '%s\n' "$OUT" | grep -c 'si Victor lo decide')"
OUT=$(marco "Proximo paso: pedir permiso al usuario para el merge (p-1111111111).")
chk "pedir permiso: POR-DISENO" "1" "$(printf '%s\n' "$OUT" | grep -c 'POR-DISEÑO .*snippet.marco')"
OUT=$(marco "Proximo paso: revisar si proyecto-spec respondió al mensaje (p-1111111111).")
chk "revisar si X respondio (con tilde): POR-DISENO" "1" "$(printf '%s\n' "$OUT" | grep -c 'POR-DISEÑO .*snippet.marco')"
OUT=$(marco "Proximo paso: arreglar el parser (p-1111111111) y de paso"$'\n'"el lector (p-2222222222).")
chk "dos pendientes, el segundo en otra linea del campo: POR-DISENO" "1" "$(printf '%s\n' "$OUT" | grep -c 'junta 2 pendientes')"
OUT=$(marco "Proximo paso: arreglar el parser (p-1111111111); ver tambien p-2222222222.")
chk "ver tambien no cuenta como segundo objetivo: HECHO" "1" "$(printf '%s\n' "$OUT" | grep -c 'HECHO .*snippet.marco')"
OUT=$(marco "Proximo paso: arreglar el parser (p-1111111111). Antes: (1) leer el log, (2) correr la suite.")
chk "lista (1)… (2)…: POR-DISENO" "1" "$(printf '%s\n' "$OUT" | grep -c 'trae una lista')"
LARGO=$(python3 -c "print('x ' * 320)")
OUT=$(marco "Proximo paso: arreglar el parser (p-1111111111) $LARGO.")
chk "mas de 600 caracteres: POR-DISENO" "1" "$(printf '%s\n' "$OUT" | grep -c 'caracteres (guia: unos 300)')"
OUT=$(marco "Proximo paso: ninguno — lo unico propio espera a que Victor decida, p-1111111111.")
chk "caso 5 (ninguno): el marco no aplica" "0" "$(printf '%s\n' "$OUT" | grep -c 'snippet.marco')"
marco "Proximo paso: x si Victor lo decide (p-1111111111)." >/dev/null
chk "en --json el estado es POR-DISEÑO (el que lee el hook de cierre)" "POR-DISEÑO" "$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/2026-10-14-hoy.md" --no-git --hoy 2026-10-14 --solo-snippet --json | python3 -c "import json,sys; print([x['estado'] for x in json.load(sys.stdin) if x['clave']=='snippet.marco'][0])")"

echo "== 7. que puede ser extra (2.61.0): fuera lo citado en Terminas/No repitas, lo en vivo y lo que espera un OK =="
EXTRAS() { printf '%s\n' "$OUT" | grep '^Si ese paso es corto' || true; }
QUEDAN() { printf '%s\n' "$OUT" | grep '^quedan' || true; }
# Forma del caso real que lo disparo (2026-10-15): el Terminas cuando mandaba un pendiente a la
# siguiente sesion y la linea de extras lo sugeria para la misma sesion.
memoria
ficha 2026-10-14-hoy "Proximo paso: arreglar el presupuesto (p-1111111111)."$'\n\n'"Terminas cuando: 1.5.0 publicada; la prueba en vivo va en la siguiente supervision (p-2222222222)."
pend Alta p-1111111111 "el paso" 2026-10-14-hoy
pend Media p-2222222222 "repasar el lector de eventos" 2026-10-14-hoy
pend Media p-3333333333 "arreglar el parser" 2026-10-14-hoy
OUT=$(retomar)
chk "el citado en Terminas cuando no va de extra" "0" "$(EXTRAS | grep -c 'p-2222222222')"
chk "su lugar lo toma el siguiente del hilo" "1" "$(EXTRAS | grep -c 'p-3333333333 (Media) — arreglar el parser')"
chk "y el citado queda en quedan N" "1" "$(QUEDAN | grep -c '^quedan 1 en el hilo: p-2222222222\.$')"
memoria
ficha 2026-10-14-hoy "Proximo paso: arreglar el presupuesto (p-1111111111)."$'\n\n'"No repitas: tocar p-2222222222 mientras corre la suite."
pend Alta p-1111111111 "el paso" 2026-10-14-hoy
pend Media p-2222222222 "repasar el lector" 2026-10-14-hoy
OUT=$(retomar)
chk "el citado en No repitas no va de extra" "0" "$(EXTRAS | grep -c 'p-2222222222')"
chk "sin otro elegible no hay linea de extras, solo quedan" "1" "$(QUEDAN | grep -c 'p-2222222222')"
memoria
ficha 2026-10-14-hoy "Proximo paso: arreglar el presupuesto (p-1111111111)."
pend Alta p-1111111111 "el paso" 2026-10-14-hoy
pend Alta p-2222222222 "Confirmar en vivo la version 1.4 en una supervisión real tras /reload-plugins" 2026-10-14-hoy
pend Media p-3333333333 "Verificar en una instalacion real que el instalador deja el icono" 2026-10-14-hoy
pend Media p-4444444444 "Probar en una sesion nueva que el aviso sale una vez" 2026-10-14-hoy
pend Media p-5555555555 "Comprimir la tabla de pedidos — probado en la copia, falta OK de Víctor" 2026-10-14-hoy
pend Media p-6666666666 "Re-disparar el issue cuando Victor decida" 2026-10-14-hoy
pend Media p-7777777777 "arreglar el parser" 2026-10-14-hoy
pend Media p-8888888888 "Publicar la nota, a la espera de la aprobación del cliente" 2026-10-14-hoy
pend Media p-9999999999 "Subir el indice: depende de que Victor apruebe la ventana" 2026-10-14-hoy
OUT=$(retomar)
chk "pruebas en vivo y esperas de OK fuera: el unico extra es la tarea de codigo" "p-7777777777" "$(EXTRAS | grep -o 'p-[0-9a-f]\{10\}' | tr '\n' ' ' | sed 's/ $//')"
chk "las siete van a quedan" "1" "$(QUEDAN | grep -c '^quedan 7 en el hilo: ')"
HILO=$(python3 "$BIN/pendientes_afines.py" "$M/sessions/2026-10-14-hoy.md" --hilo)
chk "--hilo dice por que no va de extra (lo lee el Step 8)" "1" "$(printf '%s\n' "$HILO" | grep -c '^p-2222222222 (Alta, nuevo) \[no va de extra: prueba en uso real\]')"
chk "--hilo no marca la tarea de codigo" "0" "$(printf '%s\n' "$HILO" | grep '^p-7777777777' | grep -c 'no va de extra')"
# Lo que NO debe salir: texto que cuenta algo ya hecho en vivo, una decision que toma el agente, la
# cita de una decision ya tomada.
memoria
ficha 2026-10-14-hoy "Proximo paso: arreglar el presupuesto (p-1111111111)."
pend Alta p-1111111111 "el paso" 2026-10-14-hoy
pend Media p-2222222222 "sin verificar el contador (40 avisos en 30 dias) — verificado en vivo: arreglar el conteo" 2026-10-14-hoy
pend Media p-3333333333 "decidir con datos si las 3 colas siguen; va despues por decision de Victor del 2026-10-06" 2026-10-14-hoy
OUT=$(retomar)
chk "lo ya verificado y las decisiones del agente siguen siendo extra" "p-2222222222 p-3333333333" "$(EXTRAS | grep -o 'p-[0-9a-f]\{10\}' | tr '\n' ' ' | sed 's/ $//')"
chk "el audit snippet.hilo no cambia: sigue viendo el hilo entero" "1" "$(audit | grep -c 'HECHO .*snippet.hilo.*(3 hacibles)')"

echo "== 8. el hilo no cruza a otro tema (2.62.0, caso real de otro proyecto) =="
# Un id cerrado no liga: p-cccccccccc cita a p-0000000000, que se cerro (no esta abierto); el paso
# recibido fue p-0000000000. Con el cierre transitivo p-cccccccccc entraba por el cerrado.
memoria
ficha 2026-10-14-hoy "Proximo paso: hacer el nuevo (p-1111111111)." "hilo_paso: p-0000000000\nhilo_heredados: p-0000000000\nhilo_saltos:"
pend Alta p-1111111111 "el nuevo" 2026-10-14-hoy " — _relacionado: p-0000000000_"
pend Alta p-cccccccccc "de otro agente, cita al cerrado" 2026-10-10-otra " — _relacionado: p-0000000000_"
chk "un pendiente que solo comparte un id cerrado no entra" "0" "$(python3 "$BIN/pendientes_afines.py" "$M/sessions/2026-10-14-hoy.md" --hilo --hoy 2026-10-14 | grep -c 'p-cccccccccc')"
# El caso real: forma del grafo de otro proyecto, con ids, fichas y textos inventados. Antes de
# escribir el snippet, 2.61.0 daba p-f000000009 (sombrilla del trabajo de otro agente) y 3 Bajas de
# otro tema, todos a 2+ saltos y uno por un id cerrado. Lo propio no era hacible: el hilo es vacio.
FX="$BIN/fixtures/hilo-ajeno"
FS=2026-10-15-sesion-de-indices
rm -rf "$M"; mkdir -p "$M/sessions"
cp "$FX/_pendientes.md" "$M/"; cp "$FX/sessions/$FS.md" "$M/sessions/"
chk "fixture: el hilo antes del snippet esta vacio" "" "$(python3 "$BIN/pendientes_afines.py" "$M/sessions/$FS.md" --hilo --hoy 2026-10-15)"
chk "fixture: la semilla (p-f000000001) si esta en el grafo" "1" "$(grep -c '_id: p-f000000001_' "$M/_pendientes.md")"
# El snippet que escribio el agente: con su propio paso (la sombrilla) como semilla, no arrastra
# extras de otro tema: las 3 Bajas a 2+ saltos (p-f00000000e, p-f000000012, p-f000000014) no salen ni
# de extra ni en quedan. print-como-retomar.py usa la fecha real, asi que los `_revisar` del fixture
# van en 9999-12-31 y la comprobacion es por id: con la fecha del caso real (2026-10-15) un vecino directo
# del paso salio de extra en CI del 2026-10-16 (es del hilo) y la prueba por linea entera fallo.
python3 - "$M/sessions/$FS.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read().replace("<filled in Step 8>", "```\nRetomamos: x.\n\nLee memory/sessions/2026-10-15-sesion-de-indices.md para el contexto completo.\n\nProximo paso: seguir el trabajo largo — `p-f000000009`.\n\nAntes de actuar, dime en 3 lineas donde quedamos.\n```")
open(p, "w", encoding="utf-8").write(t)
PY
OUT=$(python3 "$BIN/print-como-retomar.py" "$M/sessions/$FS.md")
chk "fixture: las Bajas de otro tema no van de extra" "0" "$(printf '%s\n' "$OUT" | grep '^Si ese paso es corto' | grep -c 'p-f00000000e\|p-f000000012\|p-f000000014')"
chk "fixture: ni en quedan" "0" "$(printf '%s\n' "$OUT" | grep '^quedan' | grep -c 'p-f00000000e\|p-f000000012\|p-f000000014')"
# Con `Proximo paso: ninguno — …` el audit ya no exige la sombrilla ajena.
python3 - "$M/sessions/$FS.md" <<'PY'
import re, sys
p = sys.argv[1]
t = re.sub(r"^Proximo paso:.*$", "Proximo paso: ninguno — la medicion propia tiene fecha (2026-10-20), ver Recordatorios de calendario.", open(p, encoding="utf-8").read(), flags=re.M)
open(p, "w", encoding="utf-8").write(t)
PY
OUT=$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$FS.md" --no-git --hoy 2026-10-15 --solo-snippet 2>&1)
chk "fixture: el audit no marca SALTADO snippet.hilo con ninguno" "0" "$(printf '%s\n' "$OUT" | grep -c 'SALTADO .*snippet.hilo')"
chk "fixture: snippet.hilo dice que no hay nada hacible" "1" "$(printf '%s\n' "$OUT" | grep -c 'HECHO .*snippet.hilo.*no tiene nada')"

echo "== 9. sello desde un recordatorio de calendario (id en Retomamos:, sin Proximo paso:) =="
memoria; ficha 2026-10-14-hoy "Proximo paso: x."
# Forma real (un recordatorio pegado de otro proyecto): el pegado empieza en `Retomamos:` e `id:` va sin `_`.
transcripcion "$T/t.jsonl" 'Retomamos: medir el efecto del indice antes de las 14:00 UTC id: p-aaaaaaaaaa\nContexto: memory/sessions/2026-10-13-ayer.md\nComprueba: algo. Despues: lo otro (p-bbbbbbbbbb).\nSi ya no aplica, cierralo con /checkpoint-3t.'
python3 "$BIN/stamp-hilo.py" "$M/sessions/2026-10-14-hoy.md" --transcript "$T/t.jsonl" >/dev/null
FM=$(sed -n '1,/^---$/p' "$M/sessions/2026-10-14-hoy.md")
chk "hilo_paso toma el id de Retomamos:" "1" "$(printf '%s' "$FM" | grep -c '^hilo_paso: p-aaaaaaaaaa$')"
chk "y no el de la linea Comprueba:" "0" "$(printf '%s' "$FM" | grep -c 'p-bbbbbbbbbb')"

echo "== 10. notas de los revisores de 2.57.0 (p-3f22a1cba1) =="
# (1) Un Bash que escribe la ficha con barras invertidas (Windows) la escribio igual que con `/`.
memoria; ficha 2026-10-14-hoy "Proximo paso: x."
python3 - "$T/bs.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "user", "timestamp": "2026-10-14T15:00:00Z", "message": {"role": "user", "content": "Retomamos: demo.\n\nProximo paso: p-aaaaaaaaaa."}}) + "\n")
    fh.write(json.dumps({"type": "assistant", "timestamp": "2026-10-14T15:10:00Z", "message": {"content": [
        {"type": "tool_use", "name": "Bash", "input": {"command": "cat > memory\\sessions\\2026-10-14-hoy.md <<'X'\nx\nX"}}]}}) + "\n")
PY
chk "Bash con barras invertidas escribe la ficha" "True" "$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import pendientes_afines as a; print(a.escribio_la_ficha(sys.argv[2], '2026-10-14-hoy.md'))" "$BIN" "$T/bs.jsonl")"
# (2) Una linea con `message` que no es un objeto se salta; no tumba stamp-hilo.py.
python3 - "$T/bs.jsonl" <<'PY'
import json, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
raro = [{"type": "user", "timestamp": "2026-10-14T14:59:00Z", "message": "texto plano"},
        {"type": "assistant", "timestamp": "2026-10-14T14:59:30Z", "message": ["2026-10-14-hoy.md"]}]
open(p, "w", encoding="utf-8").write("".join(json.dumps(x) + "\n" for x in raro) + t)
PY
chk "message no-objeto: stamp-hilo sella sin traceback" "sellado=1 motivo=sellada" "$(python3 "$BIN/stamp-hilo.py" "$M/sessions/2026-10-14-hoy.md" --transcript "$T/bs.jsonl" 2>&1 | tail -1)"
# (3) El docstring de print-como-retomar.py ya no describe la regla de 2.55.0 como vigente.
chk "docstring sin 'ligados por _relacionado'" "0" "$(grep -c 'ligados por `_relacionado' "$BIN/print-como-retomar.py")"
# (4) El caso 5 colapsado (`Ninguno — …` sin bloque) con un heredado hacible en el hilo es el mismo
# hueco que `Proximo paso: ninguno` dentro del bloque: snippet.hilo tambien lo mira.
colapsa() {
  python3 - "$M/sessions/2026-10-14-hoy.md" "$1" <<'PY'
import re, sys
p, linea = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8").read()
t = re.sub(r"## Como retomar\n\n```.*?```\n", lambda _: "## Como retomar\n\n" + linea + "\n", t, flags=re.S)
open(p, "w", encoding="utf-8").write(t)
PY
}
memoria
ficha 2026-10-14-hoy "Proximo paso: x." "hilo_paso: p-aaaaaaaaaa\nhilo_heredados: p-aaaaaaaaaa\nhilo_saltos:"
pend Alta p-aaaaaaaaaa "el paso que recibio y no cerro" 2026-10-13-ayer
colapsa "Ninguno — no queda nada."
chk "colapsado con un heredado hacible: SALTADO snippet.hilo" "1" "$(audit | grep -c 'SALTADO .*snippet.hilo')"
chk "y nombra al heredado como el primero" "1" "$(audit | grep -c 'el primero es p-aaaaaaaaaa (Alta, heredado)')"
memoria
ficha 2026-10-14-hoy "Proximo paso: x." "hilo_paso: p-aaaaaaaaaa\nhilo_heredados: p-aaaaaaaaaa\nhilo_saltos:"
pend Alta p-aaaaaaaaaa "el paso recibido, espera" 2026-10-13-ayer " — _bloqueado: otra instalacion_"
colapsa "Ninguno — lo recibido espera a otra instalacion."
chk "colapsado y el hilo sin nada hacible: HECHO" "1" "$(audit | grep -c 'HECHO .*snippet.hilo.*no tiene nada')"

echo "== 10. (2.63.45) el evento lleva el session_id de la sesion de Claude Code =="
evento_sid() {   # el session_id del unico evento en pending/
  python3 - "$M/.journal/pending" <<'PY'
import json, os, sys
d = sys.argv[1]
for n in sorted(os.listdir(d)):
    if n.endswith(".json"):
        print(json.load(open(os.path.join(d, n), encoding="utf-8"))["session_id"])
PY
}
emite() { python3 "$BIN/journal-emit.py" --memory-dir "$M" --type pendiente.window --id p-aaaaaaaaaa \
  --revisar 2026-10-20 "$@" >/dev/null 2>&1; }
memoria
CLAUDE_CODE_SESSION_ID=$SID emite
chk "solo CLAUDE_CODE_SESSION_ID: el evento lleva ese id" "$SID" "$(evento_sid)"
rm -rf "$M/.journal"
THREET_SESSION_ID=explicito CLAUDE_CODE_SESSION_ID=$SID emite
chk "THREET_SESSION_ID gana a CLAUDE_CODE_SESSION_ID" "explicito" "$(evento_sid)"
rm -rf "$M/.journal"
CLAUDE_CODE_SESSION_ID=$SID emite --session flag
chk "--session gana a CLAUDE_CODE_SESSION_ID" "flag" "$(evento_sid)"
rm -rf "$M/.journal"
emite
chk "sin ninguna: un uuid nuevo (32 hex)" "1" "$(evento_sid | grep -cE '^[0-9a-f]{32}$')"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
