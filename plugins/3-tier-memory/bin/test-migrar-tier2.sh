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
huella() { (cd "$M" && find . -type f ! -path './.journal/*' -print0 | sort -z | xargs -0 shasum) | shasum; }
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
chk "research: el \\| escapado no parte la fila" "4" "$(python3 -c "
import sys,importlib.util as u;s=u.spec_from_file_location('jc','$BIN/journal-compact.py');jc=u.module_from_spec(s);s.loader.exec_module(jc)
print(len(jc.split_cells([l for l in open('$M/_research-index.md') if 'research/r1' in l][0])))")"
R=$(python3 "$BIN/repair-dualwrite.py" "$M" 2>&1)
chk "repair-dualwrite: sin filas que anadir ni ids inventados ni barras rotas" "1" "$(echo "$R" | grep -c 'rows_added=0 pipes_broken=0.* ids_invented=0')"

echo "== 5. respaldo e idempotencia =="
chk "respaldo de _pendientes.md antes de escribir" "1" "$(ls "$M"/.journal/migrar-tier2/*/_pendientes.md 2>/dev/null | wc -l | tr -d ' ')"
chk "el respaldo es el original (P1 entero)" "1" "$(grep -c 'FIN-P1' "$M"/.journal/migrar-tier2/*/_pendientes.md)"
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

echo "== 7. tras adoptar, P3 ya se migra =="
P3=$(emit --type pendiente.adopt --text-prefix "P3 palabra0" 2>/dev/null); compact
OUT=$(migrar --apply 2>&1)
chk "P3 adoptado se aplica" "1" "$(echo "$OUT" | grep -c 'aplicados=1 errores=0')"
chk "_pendientes.md: sin lineas largas" "0" "$(largas _pendientes.md)"
chk "P3: detalle en Tier 3" "1" "$(fila "$P3" | grep -c 'detalle: P3 palabra0 .*FIN-P3')"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
