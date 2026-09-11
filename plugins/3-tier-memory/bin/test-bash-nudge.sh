#!/bin/bash
# Prueba del aviso de Bash (bash-journal-nudge.sh). No prueba que Claude Code honre el hook: eso
# es del harness. Prueba que el script decide bien y que NO depende de .memory-config.
#
# OJO con el arnes: `echo "$JSON"` en zsh interpreta los `\n` del JSON y lo corrompe antes de que
# llegue al script, y entonces TODOS los casos salen "callado" — que parece un pase limpio. Usar
# `printf '%s'`. (Me mordio al escribir esto, 2026-09-11.)
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"; rm -f "$BIN/tmp-test-escritor.py"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proj"; mkdir -p "$P/memory/pendientes" "$P/memory/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$P/memory/_pendientes.md"

pre() {   # $1 = comando -> imprime AVISA|callado
  J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PreToolUse','tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':sys.argv[2]}}))" "$P" "$1")
  O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/bash-journal-nudge.sh" 2>/dev/null)
  [ -n "$O" ] && echo AVISA || echo callado
}

echo "== PreToolUse: formas de escritura que se han visto de verdad en el historial =="
chk "redireccion >>"          AVISA "$(pre 'echo x >> memory/_pendientes.md')"
chk "redireccion >"           AVISA "$(pre 'printf x > memory/_session-index.md')"
chk "sed -i"                  AVISA "$(pre 'sed -i "" s/a/b/ memory/_learnings.md')"
chk "tee"                     AVISA "$(pre 'tee -a memory/pendientes/2026-09.md < /tmp/x')"
chk "cp"                      AVISA "$(pre 'cp /tmp/x memory/_plans-index.md')"
chk "heredoc python open(w)"  AVISA "$(pre 'python3 - <<PY
open("memory/pendientes/2026-09.md","w")
PY')"

echo "== y lo que NO debe disparar (un aviso que grita en falso deja de leerse) =="
chk "lectura con cat"                  callado "$(pre 'cat memory/_pendientes.md')"
chk "grep"                             callado "$(pre 'grep -c foo memory/_learnings.md')"
chk "redireccion de stderr (2>)"       callado "$(pre 'wc -l memory/_pendientes.md 2> /tmp/err')"
chk "escritura fuera de memory/"       callado "$(pre 'echo hola > /tmp/otro.md')"
chk "comando sin relacion"             callado "$(pre 'git status')"
for h in journal-compact repair-dualwrite normalize-pendientes enrich-memory; do
  chk "herramienta del plugin: $h"     callado "$(pre "python3 bin/$h.py memory --apply")"
done

echo "== no depende de .memory-config: es el punto entero =="
# 64 de 65 proyectos no tienen config. Si el aviso dependiera de journal_strict estaria inerte
# justo donde mas falta hace.
chk "sin .memory-config -> AVISA igual" AVISA "$(pre 'echo x >> memory/_pendientes.md')"
printf 'journal_strict=0\n' > "$P/memory/.memory-config"
chk "con journal_strict=0 -> AVISA igual" AVISA "$(pre 'echo x >> memory/_pendientes.md')"
rm -f "$P/memory/.memory-config"

echo "== un proyecto sin journal no ve nada =="
Q="$T/sinjournal"; mkdir -p "$Q/memory"
printf -- '# Pendientes\n' > "$Q/memory/_pendientes.md"
J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PreToolUse','tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':'echo x >> memory/_pendientes.md'}}))" "$Q")
O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$Q" bash "$BIN/bash-journal-nudge.sh" 2>/dev/null)
chk "sin .journal/ -> callado" callado "$([ -n "$O" ] && echo AVISA || echo callado)"

echo "== PostToolUse: exacto, por bytes, no por texto del comando =="
python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --check-drift >/dev/null 2>&1
post() {
  J=$(python3 -c "import json,sys;print(json.dumps({'hook_event_name':'PostToolUse','tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':'x'}}))" "$P")
  O=$(printf '%s' "$J" | CLAUDE_PROJECT_DIR="$P" bash "$BIN/bash-journal-nudge.sh" 2>/dev/null)
  [ -n "$O" ] && echo AVISA || echo callado
}
chk "sin cambios -> callado"                callado "$(post)"
printf -- '- [ ] a mano\n' >> "$P/memory/_pendientes.md"
chk "tras escritura a mano -> AVISA"        AVISA   "$(post)"
chk "y no se repite (se re-sello)"          callado "$(post)"

echo "== --reseal: el camino sancionado para una reparacion manual =="
printf -- '- [ ] reparacion manual deliberada\n' >> "$P/memory/_pendientes.md"
R=$(python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --reseal 2>&1)
chk "reseal acepta el cambio"  "1" "$(printf '%s' "$R" | grep -c 'aceptados como linea base')"
chk "y despues no hay deriva"  callado "$(post)"

echo "== y el comportamiento, no solo la forma: enrich-memory no dispara el aviso =="
E="$T/enr"; mkdir -p "$E/pendientes" "$E/sessions"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n- [ ] sin id ni creado\n' > "$E/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$E" --check-drift >/dev/null 2>&1
python3 "$BIN/enrich-memory.py" "$E" --apply >/dev/null 2>&1
O1=$(python3 "$BIN/journal-compact.py" --memory-dir "$E" --check-drift 2>&1)
chk "enrich-memory --apply NO dispara"  "0" "$(printf '%s' "$O1" | grep -c 'FUERA DEL JOURNAL')"
printf -- '- [ ] a mano\n' >> "$E/_pendientes.md"
O2=$(python3 "$BIN/journal-compact.py" --memory-dir "$E" --check-drift 2>&1)
chk "control negativo: a mano SI dispara" "1" "$(printf '%s' "$O2" | grep -c 'FUERA DEL JOURNAL')"

echo "== todo script que nombre un indice declara si re-sella (no lo adivinamos) =="
# Cuatro intentos de detectar la escritura por analisis de texto salieron cortos (el ultimo no
# veia normalize-pendientes, que hace `(jc.replace_with_retry if ... else os.replace)(tmp, path)`).
# El detector dejo de adivinar: cada script lo DECLARA, y uno nuevo que lo olvide falla.
#
# Todo esto corre sobre una COPIA de bin/ en el temporal. La primera version mutaba
# enrich-memory.py en su sitio y lo restauraba despues: al abortar `set -e` a mitad, dejo el
# fichero VERSIONADO roto. Un test no toca el arbol de trabajo.
CBIN="$T/bin"; cp -R "$BIN" "$CBIN"
rc=0; python3 "$BIN/check-index-writers.py" "$CBIN" >/dev/null 2>&1 || rc=$?
chk "ningun script sin declarar ni mal etiquetado" "0" "$rc"

cat > "$CBIN/nuevo-escritor.py" <<'TMPEOF'
#!/usr/bin/env python3
"""fixture: escribe _pendientes.md y no declara nada"""
def w(mem):
    atomic_write(mem + "/_pendientes.md", ["x"])
TMPEOF
rc=0; python3 "$BIN/check-index-writers.py" "$CBIN" >/dev/null 2>&1 || rc=$?
chk "escritor nuevo sin marcador -> falla"        "1" "$rc"
rm -f "$CBIN/nuevo-escritor.py"

python3 - "$CBIN/enrich-memory.py" <<'TMPEOF'
import io, re, sys
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
io.open(p, "w", encoding="utf-8").write(re.sub(r'guardar_huellas\s*\(', 'NADA(', s))
TMPEOF
OUT=$(python3 "$BIN/check-index-writers.py" "$CBIN" 2>&1 || true)
chk "marcador 'si' sin la llamada -> lo delata"   "1" "$(printf '%s' "$OUT" | grep -c 'MARCADOR FALSO')"

echo "== carrera: --check-drift con el lock tomado no inventa deriva =="
# La ronda 6 rompio "exacto, cero falsos positivos": sin lock, --check-drift podia leer un indice
# que el compactador acababa de reescribir y aun no habia sellado.
MEMR="$T/memr"; mkdir -p "$MEMR/pendientes" "$MEMR/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMR/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMR" --check-drift >/dev/null 2>&1
# simular un compactador a mitad: lock tomado + indice ya reescrito, sin sellar todavia
mkdir -p "$MEMR/.journal/.lock"; date +%s > "$MEMR/.journal/.lock/acquired_at"; echo otro > "$MEMR/.journal/.lock/owner"
printf -- '- [ ] lo escribio el compactador, aun sin sellar\n' >> "$MEMR/_pendientes.md"
D=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMR" --check-drift --budget 1 2>&1)
chk "con el lock ajeno tomado -> NO inventa deriva" "0" "$(printf '%s' "$D" | grep -c 'FUERA DEL JOURNAL')"
chk "y no escribio nada en out-of-band.log"         "0" "$([ -f "$MEMR/.journal/out-of-band.log" ] && grep -c . "$MEMR/.journal/out-of-band.log" || echo 0)"
rm -rf "$MEMR/.journal/.lock"
D2=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMR" --check-drift 2>&1)
chk "liberado el lock, SI lo ve (control negativo)" "1" "$(printf '%s' "$D2" | grep -c 'FUERA DEL JOURNAL')"

echo "== indices borrados y mensuales creados a mano =="
MEMS="$T/mems"; mkdir -p "$MEMS/pendientes"
printf -- '# Pendientes\n' > "$MEMS/_pendientes.md"; printf -- '# L\n' > "$MEMS/_learnings.md"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMS" --check-drift >/dev/null 2>&1
rm "$MEMS/_learnings.md"
D3=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMS" --check-drift 2>&1)
chk "un indice BORRADO se delata"                   "1" "$(printf '%s' "$D3" | grep -c 'BORRADO')"
printf -- '# L\n' > "$MEMS/_learnings.md"; python3 "$BIN/journal-compact.py" --memory-dir "$MEMS" --reseal >/dev/null 2>&1
printf -- '# nuevo a mano\n' > "$MEMS/pendientes/2030-01.md"
D4=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMS" --check-drift 2>&1)
chk "un mensual creado a mano se delata"            "1" "$(printf '%s' "$D4" | grep -c 'nuevo, no lo creo el compactador')"

echo "== plan.upsert --title actualiza la celda 0 y respeta su forma (6912ce4) =="
# Commit de otra sesion que entro en main sin regresion propia; lo marco el adversario en la
# ronda 6. `--title` se aceptaba y se ignoraba al actualizar: el indice conservaba el titulo con
# el que nacio el plan. Un campo sin lector, que es lo que este repo lleva seis rondas cazando.
MEMP="$T/memp"; mkdir -p "$MEMP/plans" "$MEMP/pendientes"
printf -- '---\ntype: index\n---\n# Plans\n\n## Plans\n\n| Plan | Status | Fecha | Sesion | Pendientes | Learnings |\n|---|---|---|---|---|---|\n' > "$MEMP/_plans-index.md"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMP/_pendientes.md"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMP" --type plan.upsert --slug xy --title "Titulo viejo" --status active >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMP" --quiet >/dev/null 2>&1
chk "el titulo inicial entra"          "1" "$(grep -c 'Titulo viejo' "$MEMP/_plans-index.md")"
python3 "$BIN/journal-emit.py" --memory-dir "$MEMP" --type plan.upsert --slug xy --title "Titulo nuevo" --status completed >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMP" --quiet >/dev/null 2>&1
chk "al actualizar, el titulo CAMBIA"  "1" "$(grep -c 'Titulo nuevo' "$MEMP/_plans-index.md")"
chk "y el viejo desaparece"            "0" "$(grep -c 'Titulo viejo' "$MEMP/_plans-index.md")"
chk "conserva la forma de wikilink"    "1" "$(grep -c 'plans/plan-xy' "$MEMP/_plans-index.md")"
chk "y no duplica la fila"             "1" "$(grep -c '| xy\|plan-xy' "$MEMP/_plans-index.md")"
# la variante (inline) tiene que conservar SU forma, no convertirse en enlace
python3 "$BIN/journal-emit.py" --memory-dir "$MEMP" --type plan.upsert --slug zz --title "Inline viejo" --status active --inline >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMP" --quiet >/dev/null 2>&1
python3 "$BIN/journal-emit.py" --memory-dir "$MEMP" --type plan.upsert --slug zz --title "Inline nuevo" --status active --inline >/dev/null 2>&1
python3 "$BIN/journal-compact.py" --memory-dir "$MEMP" --quiet >/dev/null 2>&1
chk "inline: el titulo cambia"         "1" "$(grep -c 'Inline nuevo' "$MEMP/_plans-index.md")"
chk "inline: sigue siendo (inline), no un enlace" "1" "$(grep -c 'Inline nuevo (inline)' "$MEMP/_plans-index.md")"

echo "== ronda 7: detectar, anotar y sellar son UNA seccion critica =="
# La ronda 6 arreglo "sin lock" partiendolo en DOS locks, y el adversario local reprodujo la
# ventana: una edicion Y en el hueco entre ambos se absorbia en silencio — no salia en el aviso
# ni en out-of-band.log, pero el sellado la fijaba como linea base. Esta prueba mide sobre el
# MODULO, llamando a las funciones en el orden del codigo, que es como el adversario lo rompio.
MEMW="$T/memw"; mkdir -p "$MEMW/pendientes" "$MEMW/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMW/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMW" --check-drift >/dev/null 2>&1
ABS=$(MEMW="$MEMW" BIN="$BIN" python3 - <<'PY'
import importlib.util, os
sp = importlib.util.spec_from_file_location("jc", os.path.join(os.environ["BIN"], "journal-compact.py"))
jc = importlib.util.module_from_spec(sp); sp.loader.exec_module(jc)
mem = os.environ["MEMW"]; j = os.path.join(mem, ".journal")
p = os.path.join(mem, "_pendientes.md")
open(p, "a").write("- [ ] edicion X\n")
fuera = jc.detectar_fuera_de_banda(mem, j)          # X detectada
open(p, "a").write("- [ ] edicion Y\n")            # Y cae en el hueco
jc.anotar_fuera_de_banda(j, fuera)
jc.guardar_huellas(mem, j)                           # sella X+Y
log = open(os.path.join(j, "out-of-band.log")).read() if os.path.isfile(os.path.join(j, "out-of-band.log")) else ""
# Y quedo absorbida si: no hay rastro de ella y una comprobacion posterior no ve nada
print("1" if (not jc.detectar_fuera_de_banda(mem, j) and len(log.strip().splitlines()) == 1) else "0")
PY
)
chk "la secuencia partida SI absorbe una edicion (asi lo rompio)" "1" "$ABS"
# Y ahora el binario real, que hace las tres cosas bajo un solo lock: Y no se puede colar,
# porque no hay hueco donde meterla. Se comprueba que el aviso y el log cubren TODO lo que
# el sellado fija: tras avisar, una comprobacion inmediata queda limpia y el log tiene la linea.
MEMX="$T/memx"; mkdir -p "$MEMX/pendientes" "$MEMX/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n' > "$MEMX/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMX" --check-drift >/dev/null 2>&1
printf -- '- [ ] X\n- [ ] Y\n' >> "$MEMX/_pendientes.md"
D=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMX" --check-drift 2>&1)
chk "el binario avisa"                                 "1" "$(printf '%s' "$D" | grep -c 'FUERA DEL JOURNAL')"
chk "y lo anota"                                       "1" "$(grep -c '_pendientes.md' "$MEMX/.journal/out-of-band.log")"
chk "y lo sellado coincide con lo avisado (queda limpio)" "0" "$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMX" --check-drift 2>&1 | grep -c 'FUERA')"
chk "una sola adquisicion de lock en la rama check-drift" "1" "$(grep -c 'UNA sola adquisicion para detectar, anotar y re-sellar' "$BIN/journal-compact.py")"

echo "== ronda 7: scan-secrets re-sella (redactar es escritura legitima de un indice) =="
MEMY="$T/memy"; mkdir -p "$MEMY/pendientes"
printf -- '---\ntype: index\n---\n# Pendientes\n\n- [ ] rotar AKIAIOSFODNN7EXAMPLE\n' > "$MEMY/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$MEMY" --check-drift >/dev/null 2>&1
python3 "$BIN/scan-secrets.py" "$MEMY" --apply >/dev/null 2>&1
D2=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMY" --check-drift 2>&1)
chk "tras redactar un indice, NO acusa"       "0" "$(printf '%s' "$D2" | grep -c 'FUERA DEL JOURNAL')"
printf -- '- [ ] a mano\n' >> "$MEMY/_pendientes.md"
D3=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEMY" --check-drift 2>&1)
chk "control negativo: a mano SI acusa"       "1" "$(printf '%s' "$D3" | grep -c 'FUERA DEL JOURNAL')"

echo "RESULT pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
