#!/bin/bash
# Prueba del enlace Quick Reference -> regla y de learnings-migracion.py (2.51.0, F7 del plan de
# ciclo de vida de learnings).
#
# Por que existe: la F7 se hizo a mano en el repo del plugin y paso a ser una capacidad del plugin
# (/migrate-learnings-3t). Su pieza nueva es la marca `<!-- regla: <topic>#<N> -->` al final de una
# linea del Quick Reference. Antes de escribirla se midio, con eventos reales sobre una copia, que
# el journal la rompia de dos formas: learning.update --quickref la borraba y un replay de
# learning.add --quickref insertaba una linea duplicada. Lo que este fichero vigila:
#  1. learning.add --quickref escribe la marca (topic#N; el topic si la regla es vineta o su numero
#     se repite) y su replay no duplica la linea.
#  2. learning.update --quickref conserva la marca; --quickref-regla la escribe y la cambia; un
#     destino que no existe, retirado o ambiguo va a cuarentena; el emisor y el compactador
#     rechazan valores malos; learning.retire --quickref-prefix sigue quitando la linea marcada.
#  3. Nadie se la ensena al agente: ni el indice de recall (texto y palabras) ni el recordatorio
#     periodico.
#  4. learnings-migracion.py: estado, aviso (habla con lineas sin enlace, calla migrado, calla con lo
#     que el journal no puede arreglar), candidatos (entre topics, prefijo unico), lote por nivel,
#     aplicar (rechaza sin emitir lo que el journal no puede reescribir), decidir.
#  5. session-start.sh lleva la linea MIGRAR-LEARNINGS a los dos canales y no en Paperclip.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: no encontre '$3' en '$2'"; fi; }
hasnt() { if printf '%s' "$2" | grep -q -- "$3"; then fail=$((fail+1)); echo "  FALLA $1: no esperaba '$3' en '$2'"; else pass=$((pass+1)); echo "  ok  $1"; fi; }

P="$T/proj"; M="$P/memory"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" | tail -1 | tr -d '\r'; }
cuar() { ls "$M/.journal/quarantine" 2>/dev/null | grep -c '\.json$' | tr -d ' '; }
motivos() { cat "$M/.journal/quarantine"/*.reason 2>/dev/null | tr '\n' ' '; }
qr() { awk '/^## Quick Reference/{f=1;next} /^## /{f=0} f && NF' "$M/_learnings.md" | tr -d '\r'; }
mig() { python3 "$BIN/learnings-migracion.py" --memory-dir "$M" "$@"; }

fixture() {
  rm -rf "$P"; mkdir -p "$M/learnings"
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Related\n' > "$M/_pendientes.md"
  cat > "$M/_learnings.md" <<'IDX'
---
type: index
updated: 2026-01-01
---
# Learnings Index

## Topic Files
| Topic | File | When |
|---|---|---|
| Gate | [[learnings/gate]] | x |
| Shell | [[learnings/shell]] | x |
| Notas | [[learnings/notas]] | x |

## Quick Reference — Most Critical Rules

1. **Push con review abierto** — espera al review antes de subir
2. **Contar con grep** — el exit 1 de grep -c no es error

## Related
- [[_pendientes]]
IDX
  cat > "$M/learnings/gate.md" <<'TOP'
---
type: learnings
topic: gate
---
# Gate

## Rules

1. **No hagas push mientras corre el review del equipo** — el review lee el arbol y un push lo cambia a mitad.
2. **Un merge sin CI verde rompe main** — espera el check requerido antes de fusionar la rama.
3. **Numero repetido uno** — primera regla con el tres.
3. **Numero repetido dos** — segunda regla con el tres.

## Related
- [[_learnings]]
TOP
  cat > "$M/learnings/shell.md" <<'TOP'
---
type: learnings
topic: shell
---
# Shell

## Rules

1. **grep -c sale 1 cuando cuenta cero** — con set -e el script se muere en silencio al contar lineas.
2. **Una regla vieja retirada** — ya no vale — ⊘ RETIRADA (2026-01-01, obsoleta): prueba

## Related
- [[_learnings]]
TOP
  cat > "$M/learnings/notas.md" <<'TOP'
---
type: learnings
topic: notas
---
# Notas

- **Vineta sobre scp** — scp antes que heredoc para copiar markdown al servidor.
- **Vineta sobre rsync** — rsync con barra final copia el contenido, no la carpeta.

## Related
- [[_learnings]]
TOP
}

echo "== 1. learning.add --quickref escribe la marca; el replay no duplica =="
fixture
emit --type learning.add --topic gate --text "**Revisa el diff saliente antes de empujar** — nombres privados y rutas." \
  --quickref "**Diff saliente** — escanealo antes del push" >/dev/null 2>&1
chk "add aplicado" "JOURNAL applied=1 quarantined=0 pending_left=0" "$(compact)"
has "linea 3 del QR con la marca topic#N" "$(qr)" '^3\. \*\*Diff saliente\*\* — escanealo antes del push <!-- regla: gate#4 -->$'
emit --type learning.add --topic gate --text "**Revisa el diff saliente antes de empujar** — nombres privados y rutas." \
  --quickref "**Diff saliente** — escanealo antes del push" >/dev/null 2>&1
compact >/dev/null
chk "replay del add: una sola linea" "1" "$(qr | grep -c 'Diff saliente')"
emit --type learning.add --topic notas --text "**Vineta nueva** — sin numero." --quickref "**Vineta corta** — x" >/dev/null 2>&1
compact >/dev/null
has "regla en topic de vinetas: marca el topic" "$(qr)" 'Vineta corta\*\* — x <!-- regla: notas -->$'
emit --type learning.add --topic gate --text "**Numero repetido uno** — primera regla con el tres." --quickref "**Repetida** — y" >/dev/null 2>&1
compact >/dev/null
has "regla con numero repetido: marca el topic" "$(qr)" 'Repetida\*\* — y <!-- regla: gate -->$'
chk "sin cuarentenas" "0" "$(cuar)"

echo "== 2. learning.update: --quickref-regla escribe, --quickref conserva, destinos malos a cuarentena =="
fixture
emit --type learning.update --topic gate --quickref-prefix "**Push con review" --quickref-regla gate#1 >/dev/null
chk "marca sola aplicada" "JOURNAL applied=1 quarantined=0 pending_left=0" "$(compact)"
chk "linea 1 con marca" "1. **Push con review abierto** — espera al review antes de subir <!-- regla: gate#1 -->" "$(qr | sed -n 1p)"
emit --type learning.update --topic gate --quickref-prefix "**Push con review" --quickref "**Push con review abierto** — espera al review" >/dev/null
compact >/dev/null
chk "texto nuevo + misma marca" "1. **Push con review abierto** — espera al review <!-- regla: gate#1 -->" "$(qr | sed -n 1p)"
emit --type learning.update --topic gate --quickref-prefix "**Push con review" --quickref "**Push con review abierto** — espera al review" >/dev/null
has "replay del texto: noop" "$(compact)" "noop=1"
emit --type learning.update --topic gate --quickref-prefix "**Push con review" --quickref-regla gate#2 >/dev/null
compact >/dev/null
chk "cambiar la marca" "1. **Push con review abierto** — espera al review <!-- regla: gate#2 -->" "$(qr | sed -n 1p)"
emit --type learning.update --topic gate --quickref-prefix "**Contar con grep" --quickref-regla gate#9 >/dev/null
has "regla que no existe: cuarentena" "$(compact)" "quarantined=1"
has "  motivo no-anchor" "$(motivos)" "no-anchor: quickref_regla 'gate#9'"
emit --type learning.update --topic gate --quickref-prefix "**Contar con grep" --quickref-regla gate#3 >/dev/null
has "numero repetido: cuarentena ambiguous" "$(compact; motivos)" "ambiguous: quickref_regla 'gate#3'"
emit --type learning.update --topic shell --quickref-prefix "**Contar con grep" --quickref-regla shell#2 >/dev/null
has "regla retirada: cuarentena" "$(compact; motivos)" "la regla #2 esta retirada"
chk "linea 2 sigue sin marca" "2. **Contar con grep** — el exit 1 de grep -c no es error" "$(qr | sed -n 2p)"
E=$(emit --type learning.update --topic gate --quickref-prefix "**Contar" --quickref-regla shell#1 2>&1); rc=$?
chk "emisor: marca de otro topic -> exit 1" "1" "$rc"
E=$(emit --type learning.update --topic gate --quickref-prefix "**Contar" --quickref-regla "gate#1 -->" 2>&1); rc=$?
chk "emisor: valor con --> -> exit 1" "1" "$rc"
E=$(emit --type learning.update --topic gate --quickref-regla gate#1 2>&1); rc=$?
chk "emisor: sin --quickref-prefix -> exit 1" "1" "$rc"
# El compactador es su propia frontera: el mismo payload malo escrito a mano.
# Un evento valido del emisor, con el valor cambiado a mano en pending/.
emit --type learning.update --topic gate --quickref-prefix "**Contar" --quickref-regla gate#1 >/dev/null
for f in "$M"/.journal/pending/*.json; do
  python3 -c "import json,sys;p=sys.argv[1];e=json.load(open(p));e['payload']['quickref_regla']='gate#1 -->';json.dump(e,open(p,'w'))" "$f"
done
has "compactador: valor malo a mano -> cuarentena" "$(compact; motivos)" "malformed: learning.update quickref_regla"
emit --type learning.update --topic shell --quickref-prefix "**Contar con grep" --quickref-regla shell#1 >/dev/null
compact >/dev/null
emit --type learning.retire --topic shell --match-prefix "**grep -c sale 1" --motivo obsoleta --quickref-prefix "**Contar con grep" >/dev/null
compact >/dev/null
chk "retire --quickref-prefix quita la linea marcada" "0" "$(qr | grep -c 'Contar con grep')"

echo "== 3. Nadie ensena la marca al agente =="
fixture
emit --type learning.update --topic shell --quickref-prefix "**Contar con grep" --quickref-regla shell#1 >/dev/null
chk "marca aplicada" "JOURNAL applied=1 quarantined=0 pending_left=0" "$(compact)"
python3 "$BIN/build-recall-index.py" "$M" "$T/idx.jsonl" >/dev/null
IDX=$(cat "$T/idx.jsonl")
has "el indice tiene la linea del QR" "$IDX" "Contar con grep"
hasnt "el indice no lleva la marca" "$IDX" "regla: shell"
KW=$(python3 -c "import json,sys;[print(' '.join(json.loads(l).get('keywords') or [])) for l in open(sys.argv[1]) if 'Contar con grep' in json.loads(l)['texto']]" "$T/idx.jsonl")
has "  la unidad del QR esta" "$KW" "contar"
hasnt "  y sus palabras no traen la marca" "$KW" "regla\|shell"
STATE="$T/home"; mkdir -p "$STATE"
R=$(printf '%s' "{\"cwd\":\"$P\",\"session_id\":\"s1\",\"prompt\":\"x\"}" | HOME="$STATE" CLAUDE_PROJECT_DIR="$P" THREET_RULE_REINJECT_COUNT=6 THREET_RULE_REINJECT_INTERVAL=1 bash "$BIN/rule-reinject-nudge.sh" 2>/dev/null)
mkdir -p "$STATE/.claude/projects/$(echo "$P" | sed 's/[^A-Za-z0-9]/-/g')"
printf '5 0\n' > "$STATE/.claude/projects/$(echo "$P" | sed 's/[^A-Za-z0-9]/-/g')/.rule-reinject-s1"
R=$(printf '%s' "{\"cwd\":\"$P\",\"session_id\":\"s1\",\"prompt\":\"x\"}" | HOME="$STATE" CLAUDE_PROJECT_DIR="$P" THREET_RULE_REINJECT_COUNT=6 THREET_RULE_REINJECT_INTERVAL=1 bash "$BIN/rule-reinject-nudge.sh" 2>/dev/null)
has "el recordatorio trae la linea" "$R" "Contar con grep"
hasnt "el recordatorio no trae la marca" "$R" "regla: shell"

echo "== 4. learnings-migracion.py =="
fixture
A=$(mig --aviso)
has "aviso: lineas sin enlace" "$A" "^MIGRAR-LEARNINGS: 2 lineas del Quick Reference sin enlace a su regla"
mig --candidatos > "$T/cand.jsonl"
chk "candidatos: una fila por linea sin marca" "2" "$(wc -l < "$T/cand.jsonl" | tr -d ' ')"
C1=$(python3 -c "import json,sys;r=[json.loads(l) for l in open(sys.argv[1])];print(r[0]['candidatas'][0]['regla'], r[1]['candidatas'][0]['regla'])" "$T/cand.jsonl")
chk "candidato 1 entre topics (gate y shell)" "gate#1 shell#1" "$C1"
C2=$(python3 -c "import json,sys;r=[json.loads(l) for l in open(sys.argv[1])];print(sorted({c['regla'] for x in r for c in x['candidatas']}))" "$T/cand.jsonl")
hasnt "candidatos: la retirada no sale" "$C2" "shell#2"
hasnt "candidatos: el numero repetido no sale como topic#N" "$C2" "gate#3"
has "candidatos: vinetas y repetidos como topic" "$C2" "'notas'"
printf '%s\n' '{"prefijo":"**Push con review","regla":"gate#1"}' '{"prefijo":"**Contar con grep","regla":"shell#1"}' > "$T/enl.jsonl"
mig --aplicar-enlaces "$T/enl.jsonl" > "$T/res.json"; rc=$?
chk "aplicar enlaces: exit 0" "0" "$rc"
has "  dos emitidos" "$(cat "$T/res.json")" '"emitidos": 2'
E=$(mig --estado)
has "estado: dos enlazadas" "$E" '"numerada": 2'
has "estado: 0 % con disparadores" "$E" '"porcentaje": 0.0'
has "aviso: pide disparadores" "$(mig --aviso)" "2 reglas del Quick Reference sin disparadores"
mig --lote --nivel 1 --tam 0 > "$T/lote.jsonl"
chk "lote nivel 1: las dos enlazadas" "gate#1 shell#1" "$(python3 -c "import json,sys;print(' '.join(sorted(json.loads(l)['id'] for l in open(sys.argv[1]))))" "$T/lote.jsonl")"
chk "lote nivel 4: tambien gate#2 (no la repetida ni la retirada)" "gate#1 gate#2 shell#1" "$(mig --lote --nivel 4 --tam 0 | python3 -c "import json,sys;print(' '.join(sorted(json.loads(l)['id'] for l in sys.stdin)))")"
python3 - "$T/lote.jsonl" "$T/esc.jsonl" <<'EOF'
import json, sys
with open(sys.argv[2], "w") as f:
    for r in map(json.loads, open(sys.argv[1])):
        f.write(json.dumps({"id": r["id"], "match_prefix": r["match_prefix"],
                            "frases": ["voy a subir la rama ya", "estoy empujando con el review", "hice push y el review fallo"],
                            "cmd": ["git push"], "path": [], "tool": ["Bash"]}) + "\n")
EOF
mig --aplicar-disparadores "$T/esc.jsonl" > "$T/res.json"; rc=$?
chk "aplicar disparadores: exit 0" "0" "$rc"
has "  dos emitidos" "$(cat "$T/res.json")" '"emitidos": 2'
has "regla con su comentario" "$(cat "$M/learnings/gate.md")" "mitad. <!-- disparadores: frases=voy a subir la rama ya"
chk "aviso: calla migrado" "" "$(mig --aviso)"
has "estado: criterio c3" "$(mig --estado)" '"c3": true'
# Prefijo unico: dos reglas que empiezan igual sin enfasis.
fixture
cat >> "$M/learnings/gate.md.tmp" <<'EOF'
EOF
python3 - "$M/learnings/gate.md" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("## Related", "5. **Un fichero generado `write-if-absent` es INMUTABLE** — uno.\n6. **Un fichero generado write-if-absent es inmutable en todas** — dos.\n\n## Related")
open(p, "w").write(s)
EOF
rm -f "$M/learnings/gate.md.tmp"
P5=$(mig --lote --nivel 4 --tam 0 | python3 -c "import json,sys;[print(json.loads(l)['match_prefix']) for l in sys.stdin if json.loads(l)['id'] in ('gate#5','gate#6')]")
chk "prefijos de reglas que empiezan igual: distintos" "2" "$(printf '%s\n' "$P5" | sort -u | grep -c .)"
printf '%s\n' "$P5" | while read -r pf; do printf '{"id":"gate#%s","match_prefix":"%s","frases":["una frase de prueba aqui","otra frase de prueba aqui","tercera frase de prueba aqui"]}\n' "$([ -z "${pf##*INMUTABLE*}" ] && echo 5 || echo 6)" "$(printf '%s' "$pf" | sed 's/"/\\"/g')"; done > "$T/esc2.jsonl"
mig --aplicar-disparadores "$T/esc2.jsonl" >/dev/null
chk "  y se aplican sin cuarentena" "0" "$(cuar)"
# Lo que el journal no puede reescribir: rechazado sin emitir, y el aviso no insiste.
fixture
python3 - "$M/learnings/gate.md" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("## Rules\n", "## Rules\n\n```\nbloque\n```\n")
open(p, "w").write(s)
EOF
printf '%s\n' '{"id":"gate#1","match_prefix":"**No hagas push","frases":["una frase de prueba aqui","otra frase de prueba aqui","tercera frase de prueba aqui"]}' > "$T/esc3.jsonl"
mig --aplicar-disparadores "$T/esc3.jsonl" > "$T/res.json"; rc=$?
chk "regla tras un bloque de codigo: exit 1" "1" "$rc"
has "  motivo codigo-antes" "$(cat "$T/res.json")" "codigo-antes"
chk "  nada emitido ni en cuarentena" "0 0" "$(ls "$M/.journal/pending" 2>/dev/null | grep -c . | tr -d ' ') $(cuar)"
python3 - "$M/_learnings.md" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("## Quick Reference — Most Critical Rules\n", "## Quick Reference — Most Critical Rules\n\n<!-- nota a mano -->\n")
open(p, "w").write(s)
EOF
chk "QR tras un comentario HTML: el aviso calla" "" "$(mig --aviso)"
has "  y el estado las cuenta como bloqueadas" "$(mig --estado)" '"c3_lineas_que_el_journal_no_puede_marcar": 2'
# Regla enlazada que el journal no puede reescribir, y marca rota en una linea bloqueada: el aviso
# no pide lo que el comando no puede hacer (adversario, ronda 1 de 2.51.0).
fixture
printf '%s\n' '{"prefijo":"**Push con review","regla":"gate#1"}' > "$T/enl.jsonl"
mig --aplicar-enlaces "$T/enl.jsonl" >/dev/null
python3 - "$M/learnings/gate.md" "$M/_learnings.md" <<'EOF2'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("## Rules\n", "## Rules\n\n```\nbloque\n```\n"))
p = sys.argv[2]; s = open(p).read()
s = s.replace("2. **Contar con grep** — el exit 1 de grep -c no es error",
              "<!-- nota -->\n2. **Contar con grep** — el exit 1 de grep -c no es error <!-- regla: nada#9 -->")
open(p, "w").write(s)
EOF2
chk "regla enlazada no reescribible + marca rota bloqueada: el aviso calla" "" "$(mig --aviso)"
E=$(mig --estado)
has "  el estado lista la regla no reescribible" "$E" '"motivo": "codigo-antes"'
has "  y la marca rota" "$E" '"regla": "nada#9"' 
# --decidir silencia lo decidido
fixture
printf '%s\n' '{"prefijo":"**Push con review","regla":"gate#1"}' '{"prefijo":"**Contar con grep","regla":"shell#1"}' > "$T/enl.jsonl"
mig --aplicar-enlaces "$T/enl.jsonl" >/dev/null
mig --decidir gate#1 shell#1 >/dev/null
chk "decidir: el aviso calla" "" "$(mig --aviso)"
has "  y el estado lo dice" "$(mig --estado)" '"sin_disparadores_por_decision": \['
E=$(mig --decidir "gate#x" 2>&1); rc=$?
chk "decidir: id malo -> exit 1" "1" "$rc"
E=$(mig --aviso --memory-dir "$T/no-existe" 2>&1); rc=$?
chk "aviso sin memoria: exit 0 y nada" "0 " "$rc $E"

echo "== 5. session-start.sh: la linea va a los dos canales, no en Paperclip =="
fixture
correr() { printf '%s' "{\"cwd\":\"$P\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | env "$@" CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" SKIP_CMD_INSTALL=1 bash "$BIN/session-start.sh" 2>/dev/null; }
campo() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hookSpecificOutput",{}).get("additionalContext","") if sys.argv[1]=="a" else d.get("systemMessage",""))' "$1"; }
S=$(correr X=1)
has "agente: la linea" "$(printf '%s' "$S" | campo a)" "MIGRAR-LEARNINGS: 2 lineas"
has "persona: la linea" "$(printf '%s' "$S" | campo h)" "MIGRAR-LEARNINGS: 2 lineas"
S=$(correr PAPERCLIP_RUN_ID=run-1)
hasnt "Paperclip: no hay linea" "$S" "MIGRAR-LEARNINGS"

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
