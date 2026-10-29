#!/bin/bash
# Prueba de migrar-tier2.py (p-206fd62e68, propuesta f): mueve a Tier 3 el texto largo YA escrito
# en _pendientes.md, _learnings.md y _research-index.md sin perder detalle.
#
#  1. Dry-run: lista cada linea larga con su estado y destino, y no escribe nada (huella de todo
#     memory/ igual antes y despues).
#  2. --apply con eventos sin compactar: se niega y no escribe.
#  3. --apply: los tres indices quedan sin lineas largas salvo las no-migrables listadas; cada texto
#     largo (normalizado) esta en su destino Tier 3; ids intactos; repair-dualwrite sin quejas.
#  4. Sub-vinetas (dos niveles) y prosa tras los metadatos van al detalle del pendiente padre.
#  5. Respaldo en .journal/migrar-tier2/; un segundo --apply no cambia nada.
#  6. El journal sigue funcionando: update conserva el detalle, resolve cierra la fila, learning.add
#     numera bien con la seccion movida al final del topic.
#  7. Un pendiente sin _id deja de ser no-migrable tras pendiente.adopt.
#  8. --aviso (2.68.0): cuenta lo movible sin escribir, calla tras migrar y con lo que no se podra
#     mover sin intervenir (sin _id, sin destino), sale 0 sin memoria; session-start.sh lleva la
#     linea MIGRAR-TIER2 a los dos canales y no en Paperclip.
#
# Uso: test-migrar-tier2.sh (exit 0 = todo verde). Resumen final: "pass=N fail=M".
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

M="$T/m"; mkdir -p "$M/pendientes" "$M/learnings" "$M/research"
emit() { python3 "$BIN/journal-emit.py" --memory-dir "$M" "$@"; }
compact() { python3 "$BIN/journal-compact.py" --memory-dir "$M" --quiet >/dev/null 2>&1; }
migrar() { python3 "$BIN/migrar-tier2.py" "$M" "$@"; }
# sha256 por Python: el Git Bash del runner windows-latest no trae `shasum` (corrida
# 40520030467), y ahi las dos llamadas daban "" y un
# "no escribe nada" pasaba comparando vacio con vacio.
huella() { python3 - "$M" <<'EOF'
import hashlib, os, sys
h = hashlib.sha256()
for raiz, dirs, ficheros in os.walk(sys.argv[1]):
    dirs[:] = sorted(d for d in dirs if d != ".journal")
    for f in sorted(ficheros):
        p = os.path.join(raiz, f)
        h.update(os.path.relpath(p, sys.argv[1]).replace(os.sep, "/").encode() + b"\0")
        h.update(open(p, "rb").read())
print(h.hexdigest())
EOF
}
largas() { python3 "$BIN/print-tier2-tamano.py" "$M" | grep "^$1 " | sed 's/.*largas=\([0-9]*\).*/\1/'; }
fila() { cat "$M"/pendientes/*.md | grep -- "_id: $1_"; }
linea() { grep -- "_id: $1_" "$M/_pendientes.md"; }
largo() { python3 -c "import sys; print(sys.argv[1] + ' ' + ' '.join('palabra%d' % i for i in range(int(sys.argv[2]))) + ' FIN-' + sys.argv[1])" "$@"; }
ORI="[[sessions/2026-10-27-x]]"

printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$M/_pendientes.md"
# P1: nacio por journal sin --titulo (como todo lo anterior a 2.63.47): linea larga y fila mensual.
P1_TXT="Pendiente uno con | barra y — raya $(largo P1 140)"
P1=$(emit --type pendiente.add --text "$P1_TXT" --prioridad Alta --origen "$ORI" 2>/dev/null)
P_CORTO=$(emit --type pendiente.add --text "Pendiente corto" --prioridad Alta --origen "$ORI" 2>/dev/null)
compact
# Sub-vinetas de P1 (primer y segundo nivel), escritas a mano como en los proyectos medidos.
SUB1=$(largo SUB1 130); SUB2=$(largo SUB2 130)
python3 - "$M/_pendientes.md" "$P1" "$SUB1" "$SUB2" <<'EOF'
import sys
p, pid, s1, s2 = sys.argv[1:]
L = open(p, encoding="utf-8").read().split("\n")
i = next(k for k, l in enumerate(L) if f"_id: {pid}_" in l)
L[i + 1:i + 1] = [f"  - {s1}", f"    - {s2}"]
open(p, "w", encoding="utf-8").write("\n".join(L))
EOF
# P2: a mano, con id y _creado pero SIN fila mensual, y con prosa DESPUES de los metadatos.
P2=p-00000000a2; PROSA=$(largo PROSA 120)
P2_TXT=$(largo P2 60)
# P3: sin _id (no-migrable hasta pendiente.adopt).
P3_TXT=$(largo P3 140)
python3 - "$M/_pendientes.md" "$P2" "$P2_TXT" "$PROSA" "$P3_TXT" <<'EOF'
import sys
p, pid, t2, prosa, t3 = sys.argv[1:]
s = open(p, encoding="utf-8").read().replace(
    "## Media prioridad\n",
    f"## Media prioridad\n\n- [ ] {t2} — _origen: [[sessions/2026-09-01-y]]_ — _creado: 2026-09-01_"
    f" — _id: {pid}_ **Nota suelta** {prosa} — _revisar: 2026-12-01_\n"
    f"- [ ] {t3} — _origen: [[sessions/2026-09-01-y]]_ — _creado: 2026-09-01_\n")
open(p, "w", encoding="utf-8").write(s)
EOF

# Learnings: fila de Topic Files cuyo fichero YA tiene el texto; QR enlazado a una regla que NO lo
# tiene; QR sin enlace (no-migrable).
TOPIC_TXT="**Regla larga del topic** — $(largo TOPIC 130)"
QR_TXT="**Quick ref larga** — $(largo QR 130)"
QR_SIN=$(largo QRSIN 130)
printf -- '---\ntype: learning\n---\n# Regla A\n\n%s\n' "$TOPIC_TXT" > "$M/learnings/regla-a.md"
printf -- '---\ntype: learning\n---\n# Topic\n\n## Reglas\n\n1. **Regla uno** — corta.\n\n## Related\n\n- [[_learnings]]\n' > "$M/learnings/topic.md"
cat > "$M/_learnings.md" <<EOF
---
type: index
---
# Learnings Index

## Topic Files

| Topic | File | When to consult |
|---|---|---|
| $TOPIC_TXT | [[learnings/regla-a]] | antes de X |
| Topic | [[learnings/topic]] | siempre |

## Quick Reference

1. $QR_TXT <!-- regla: topic#1 -->
2. $QR_SIN
3. **Corta** — nada que mover <!-- regla: topic#1 -->
EOF

# Research: fila con dos celdas largas (una con \| escapado) y fila sin enlace (no-migrable).
RT=$(largo RTEMA 40); RN="paso \| con barra $(largo RNEXT 120)"; RSIN=$(largo RSIN 140)
printf -- '---\ntype: research\n---\n# R1\n\nCuerpo.\n' > "$M/research/r1.md"
cat > "$M/_research-index.md" <<EOF
---
type: index
---
# Research Index

## Active Research

| Tema | Next step | Origen | Archivo |
|---|---|---|---|
| $RT | $RN | [[sessions/2026-10-27-x]] | [[research/r1]] |
| $RSIN | algo | - | (inline) |

## Completed Research

| Tema | Resultado | Archivo |
|---|---|---|
EOF
compact

echo "== 1. dry-run =="
H0=$(huella)
OUT=$(migrar)
echo "$OUT" | sed 's/^/     /' | cut -c1-150
chk "dry-run: no escribe nada" "$H0" "$(huella)"
chk "dry-run: 10 candidatos, 7 migrables" "1" "$(echo "$OUT" | grep -c 'candidatos=10 migrables=7 no_migrables=3 \[dry-run')"
chk "dry-run: P1 se mueve a su mensual" "1" "$(echo "$OUT" | grep -c "_pendientes.md:.* mueve -> pendientes/$(date +%Y-%m).md")"
chk "dry-run: P2 sin fila mensual crea una" "1" "$(echo "$OUT" | grep -c 'mueve -> pendientes/2026-09.md (fila nueva)')"
chk "dry-run: las dos sub-vinetas van a P1" "2" "$(echo "$OUT" | grep -c "vineta de $P1")"
chk "dry-run: P3 sin _id es no-migrable" "1" "$(echo "$OUT" | grep -c 'no-migrable: sin _id')"
chk "dry-run: la fila de Topic Files solo se acorta" "1" "$(echo "$OUT" | grep -c 'acorta (Tier 3 ya lo tiene) -> learnings/regla-a.md')"
chk "dry-run: el QR enlazado se mueve a su topic" "1" "$(echo "$OUT" | grep -c 'mueve -> learnings/topic.md')"
chk "dry-run: QR y research sin enlace son no-migrables" "2" "$(echo "$OUT" | grep -c 'no-migrable: no apunta')"
A=$(migrar --aviso); rc=$?
chk "aviso: rc=0" "0" "$rc"
chk "aviso: cuenta los 7 movibles (no P3 sin _id ni las lineas sin enlace)" "1" "$(echo "$A" | grep -c '^MIGRAR-TIER2: 7 linea(s) de mas de 800 caracteres.*/migrar-tier2-3t')"
chk "aviso: no escribe nada" "$H0" "$(huella)"
chk "aviso: el umbral del texto sigue a --largas" "1" "$(migrar --aviso --largas 900 | grep -c '^MIGRAR-TIER2: .* de mas de 900 caracteres')"

echo "== 2. --apply con eventos sin compactar =="
emit --type pendiente.window --id "$P_CORTO" --revisar 2026-12-31 >/dev/null 2>&1
migrar --apply >/dev/null 2>"$T/err"; rc=$?
chk "se niega (rc=1)" "1" "$rc"
chk "dice que compacte antes" "1" "$(grep -c 'sin compactar' "$T/err")"
chk "no escribe nada" "$H0" "$(huella)"
compact

echo "== 3. --apply =="
OUT=$(migrar --apply 2>&1); rc=$?
echo "$OUT" | tail -1 | sed 's/^/     /'
chk "--apply: rc=0" "0" "$rc"
chk "--apply: 7 aplicados, 0 errores" "1" "$(echo "$OUT" | grep -c 'aplicados=7 errores=0')"
chk "aviso tras --apply: calla (lo que queda no es movible)" "" "$(migrar --aviso)"
chk "_pendientes.md: queda solo la linea larga de P3 (sin _id)" "1" "$(largas _pendientes.md)"
chk "_learnings.md: queda solo el QR sin enlace" "1" "$(largas _learnings.md)"
chk "_research-index.md: queda solo la fila sin enlace" "1" "$(largas _research-index.md)"
chk "P1: mismo id, titulo y _actualizado en Tier 2" "1" "$(linea "$P1" | grep -c "^- \[ \] Pendiente uno .*…  *— _origen: .*_id: ${P1}_ — _actualizado: $(date +%F)_$")"
chk "P1: la fila mensual lleva el detalle entero" "1" "$(fila "$P1" | grep -c "— detalle: Pendiente uno con \\\\| barra y — raya .*FIN-P1 — .*FIN-SUB1 — .*FIN-SUB2 _id: ${P1}_")"
chk "sub-vinetas: quedan con su titulo y sangria" "2" "$(grep -cE '^  (  )?- (SUB1|SUB2) palabra0 .*…$' "$M/_pendientes.md")"
chk "P2: Tier 2 sin la prosa suelta, con todos sus metadatos" "1" "$(linea "$P2" | grep -v PROSA | grep -c "_creado: 2026-09-01_ — _id: ${P2}_ — _revisar: 2026-12-01_ — _actualizado:")"
chk "P2: fila nueva en 2026-09 con texto y prosa" "1" "$(grep -c "FIN-P2 \*\*Nota suelta\*\* PROSA .*FIN-PROSA _id: ${P2}_ | Media | 2026-09-01 | \[\[sessions/2026-09-01-y\]\]" "$M/pendientes/2026-09.md")"
python3 - "$BIN" "$M" "$P1_TXT" "$SUB1" "$SUB2" "$P2_TXT" "$PROSA" "$TOPIC_TXT" "$QR_TXT" "$RT" "$RN" > "$T/v" <<'EOF'
import sys, glob, importlib.util as u
b, m = sys.argv[1:3]
s = u.spec_from_file_location("mt", b + "/migrar-tier2.py"); mt = u.module_from_spec(s); s.loader.exec_module(mt)
n = lambda ps: mt.normalizar(" ".join(open(p, encoding="utf-8").read() for p in ps))
mens = n(glob.glob(m + "/pendientes/*.md"))
t = sys.argv[3:]
casos = [(x, mens) for x in t[:5]] + [(t[5], n([m + "/learnings/regla-a.md"])),
         (t[6], n([m + "/learnings/topic.md"]))] + [(x, n([m + "/research/r1.md"])) for x in t[7:]]
print(sum(mt.normalizar(x) in d for x, d in casos), len(casos))
EOF
chk "sin perder detalle: los 9 textos largos estan en Tier 3" "9 9" "$(cat "$T/v")"
chk "regla-a.md (ya lo tenia): no se toca" "0" "$(grep -c 'Texto movido' "$M/learnings/regla-a.md")"
chk "topic.md: el QR va como cita al final, tras Related" "1" "$(awk '/^## Related/{r=1} r && /^> \*\*Quick ref larga/' "$M/learnings/topic.md" | wc -l | tr -d ' ')"
chk "research: las dos celdas se acortan y van etiquetadas" "2" "$(grep -cE '^> \*\*(Tema|Next step):\*\* ' "$M/research/r1.md")"
# Las rutas van por argv: dentro del codigo de -c MSYS no las convierte y Windows no las abre.
chk "research: el \\| escapado no parte la fila" "4" "$(python3 -c "
import sys,importlib.util as u;s=u.spec_from_file_location('jc',sys.argv[1]);jc=u.module_from_spec(s);s.loader.exec_module(jc)
print(len(jc.split_cells([l for l in open(sys.argv[2]) if 'research/r1' in l][0])))" "$BIN/journal-compact.py" "$M/_research-index.md")"
R=$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1)
chk "repair-dualwrite: sin filas que anadir ni ids inventados ni barras rotas" "1" "$(echo "$R" | grep -c 'rows_added=0 pipes_broken=0.* ids_invented=0')"

echo "== 5. respaldo e idempotencia =="
chk "respaldo de _pendientes.md antes de escribir" "1" "$(ls "$M"/.journal/migrar-tier2/*/_pendientes.md.pre-migrar 2>/dev/null | wc -l | tr -d ' ')"
chk "el respaldo es el original (P1 entero)" "1" "$(grep -c 'FIN-P1' "$M"/.journal/migrar-tier2/*/_pendientes.md.pre-migrar)"
chk "el respaldo no deja ningun .md" "0" "$(find "$M/.journal/migrar-tier2" -name '*.md' | wc -l | tr -d ' ')"
git -C "$T" init -q 2>/dev/null
chk "el respaldo queda fuera de git" "0" "$(git -C "$T" status --porcelain --untracked-files=all 2>/dev/null | grep -c 'migrar-tier2/')"
H1=$(huella)
chk "segundo --apply: nada que aplicar" "1" "$(migrar --apply | grep -c 'migrables=0 .*nada que aplicar')"
chk "segundo --apply: no cambia nada" "$H1" "$(huella)"

echo "== 6. el journal sigue funcionando =="
emit --type pendiente.update --id "$P1" --text "Titulo nuevo de P1" >/dev/null 2>&1; compact
chk "update: Tier 3 conserva el detalle" "1" "$(fila "$P1" | grep -c 'Titulo nuevo de P1 — detalle: .*FIN-SUB2')"
emit --type pendiente.resolve --id "$P2" --estado resolved >/dev/null 2>&1; compact
chk "resolve: P2 sale de Tier 2" "0" "$(grep -c "_id: ${P2}_" "$M/_pendientes.md")"
chk "resolve: su fila mensual queda cerrada" "1" "$(grep "_id: ${P2}_" "$M/pendientes/2026-09.md" | grep -c "| $(date +%F) |")"
emit --type learning.add --topic topic --text "**Regla dos** — nueva tras migrar" --decision nueva >/dev/null 2>&1; compact
chk "learning.add: numera 2 antes de Related" "1" "$(awk '/^## Related/{exit} /^2\. \*\*Regla dos/' "$M/learnings/topic.md" | wc -l | tr -d ' ')"
emit --type research.upsert --slug r1 --tema "$RT" --status active --next-step "paso nuevo" >/dev/null 2>&1; compact
chk "research.upsert: encuentra la fila acortada por su enlace (una sola)" "1" "$(grep -c 'research/r1' "$M/_research-index.md")"
chk "research.upsert: actualiza su Next step" "1" "$(grep 'research/r1' "$M/_research-index.md" | grep -c '| paso nuevo |')"
emit --type research.upsert --slug r1 --tema "$RT" --status completed --resultado "hecho" >/dev/null 2>&1; compact
chk "research completed: una fila, en Completed, con el tema corto" "1" "$(awk '/^## Completed/{c=1} c && /research\/r1/' "$M/_research-index.md" | grep -c '^| RTEMA palabra0 .*… | hecho |')"
chk "research completed: ninguna fila queda en Active" "1" "$(grep -c 'research/r1' "$M/_research-index.md")"
emit --type learning.add --topic regla-a --text "**Regla x** — tras migrar" --decision nueva >/dev/null 2>&1; compact
chk "learning.add en un topic con fila acortada: no duplica la fila" "1" "$(grep -c '\[\[learnings/regla-a\]\]' "$M/_learnings.md")"

echo "== 7. tras adoptar, P3 ya se migra =="
P3=$(emit --type pendiente.adopt --text-prefix "P3 palabra0" 2>/dev/null); compact
OUT=$(migrar --apply 2>&1)
chk "P3 adoptado se aplica" "1" "$(echo "$OUT" | grep -c 'aplicados=1 errores=0')"
chk "_pendientes.md: sin lineas largas" "0" "$(largas _pendientes.md)"
chk "P3: detalle en Tier 3" "1" "$(fila "$P3" | grep -c 'detalle: P3 palabra0 .*FIN-P3')"

chk "aviso tras adoptar y migrar P3: calla" "" "$(migrar --aviso)"

echo "== 8. --aviso sin memoria y en session-start.sh =="
E=$(python3 "$BIN/migrar-tier2.py" "$T/no-existe" --aviso 2>&1); rc=$?
chk "aviso sin memoria: exit 0 y nada" "0 " "$rc $E"
E=$(python3 "$BIN/migrar-tier2.py" "$M" --aviso --apply 2>&1); rc=$?
chk "--aviso con --apply: error de uso (rc=2)" "2" "$rc"
# Lo que el plan descarta y el aviso no debe contar (medido en copias de 3 proyectos reales: el aviso
# seguia encendido tras migrar): mes sin tabla, sin fila y sin _creado, learning que no es fila ni lista.
MQ="$T/mq"; mkdir -p "$MQ/pendientes" "$MQ/learnings"
printf '# 2026-08\n\nsin tabla\n' > "$MQ/pendientes/2026-08.md"
printf '# t\n' > "$MQ/learnings/t.md"
printf -- '# P\n\n## Alta prioridad\n\n- [ ] %s — _creado: 2026-08-01_ — _id: p-00000000c1_\n- [ ] %s — _id: p-00000000c2_\n' "$(largo MS 140)" "$(largo SF 140)" > "$MQ/_pendientes.md"
printf -- '# L\n\n%s [[learnings/t]]\n' "$(largo NL 140)" > "$MQ/_learnings.md"
chk "dry-run de ese corpus: 0 migrables" "1" "$(python3 "$BIN/migrar-tier2.py" "$MQ" | grep -c 'candidatos=3 migrables=0')"
chk "aviso: calla con mes sin tabla, sin fila ni _creado, y learning que no es fila ni lista" "" "$(python3 "$BIN/migrar-tier2.py" "$MQ" --aviso)"
# Un U+2028 dentro de una linea larga: el plan no parte ahi, el aviso tampoco debe.
python3 - "$MQ/_pendientes.md" "$(largo LS 140)" <<'PYEOF'
import sys
open(sys.argv[1], "a", encoding="utf-8").write(f"- [ ] {sys.argv[2][:400]}\u2028{sys.argv[2][400:]} — _creado: 2026-10-01_ — _id: p-00000000c3_\n")
PYEOF
chk "U+2028 en una linea larga: el plan la cuenta movible" "1" "$(python3 "$BIN/migrar-tier2.py" "$MQ" | grep -c 'candidatos=4 migrables=1')"
chk "U+2028 en una linea larga: el aviso tambien" "1" "$(python3 "$BIN/migrar-tier2.py" "$MQ" --aviso | grep -c '^MIGRAR-TIER2: 1 linea')"
P="$T/proj"; MP="$P/memory"; mkdir -p "$MP"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n- [ ] %s — _creado: 2026-09-01_ — _id: p-00000000b1_\n' "$(largo SS 140)" > "$MP/_pendientes.md"
correr() { printf '%s' "{\"cwd\":\"$P\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | env "$@" CLAUDE_PROJECT_DIR="$P" CLAUDE_PLUGIN_ROOT="$(cd "$BIN/.." && pwd)" SKIP_CMD_INSTALL=1 HOME="$T/home" bash "$BIN/session-start.sh" 2>/dev/null; }
campo() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hookSpecificOutput",{}).get("additionalContext","") if sys.argv[1]=="a" else d.get("systemMessage",""))' "$1"; }
S=$(correr X=1)
chk "session-start: la linea al agente" "1" "$(printf '%s' "$S" | campo a | grep -c '^MIGRAR-TIER2: 1 linea(s)')"
chk "session-start: la linea a la persona" "1" "$(printf '%s' "$S" | campo h | grep -c '^MIGRAR-TIER2: 1 linea(s)')"
S=$(correr PAPERCLIP_RUN_ID=run-1)
chk "session-start en Paperclip: sin linea" "0" "$(printf '%s' "$S" | grep -c 'MIGRAR-TIER2')"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
