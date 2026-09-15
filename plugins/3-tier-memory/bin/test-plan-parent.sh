#!/bin/bash
# --parent de plan.upsert: anota la celda Status como "<status> (fase de plan-<parent>)" sin
# ampliar la tabla de _plans-index.md, y "superseded" pasa a contar como cerrado para la poda
# (igual que completed/abandoned). Ver checkpoint-3t.md Step 5 "Plan padre/hijo".
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MEM="$T/memory"; mkdir -p "$MEM"
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FAIL $1"; echo "    esperado: $2"; echo "    obtenido: $3"; fi; }

cat > "$MEM/_plans-index.md" <<'EOF'
---
type: index
---
# Plans Index
EOF

echo "== plan padre =="
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug puerto-vps --title "Port al VPS" \
  --status active --date 2026-09-12 --sesion "[[sessions/x]]" >/dev/null 2>/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null

echo "== plan hijo con --parent =="
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug bloque-a --title "Bloque A" \
  --status active --date 2026-09-12 --sesion "[[sessions/x]]" --parent puerto-vps >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null

chk "el hijo lleva la anotacion de fase" \
  "1" "$(grep -c 'active (fase de plan-puerto-vps)' "$MEM/_plans-index.md")"
chk "el padre NO lleva anotacion (no tiene --parent)" \
  "0" "$(grep -c 'fase de plan-puerto-vps).*puerto-vps\|puerto-vps.*fase de plan' "$MEM/_plans-index.md" | grep -v bloque-a || true)"
chk "la tabla sigue en 6 columnas (sin migracion)" \
  "6" "$(grep 'bloque-a' "$MEM/_plans-index.md" | sed 's/\\|//g' | awk -F'|' '{print NF-2}')"

echo "== --parent invalido: no puede ser el propio slug =="
OUT=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug self-parent --title "X" \
  --status active --date 2026-09-12 --parent self-parent 2>&1)
chk "rechaza --parent == --slug" "1" "$(printf '%s' "$OUT" | grep -qc 'no puede ser el propio plan' && echo 1 || echo 0)"

echo "== ciclo transitivo: puerto-vps no puede ser hijo de su propio nieto =="
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug sub-a --title "Sub de Bloque A" \
  --status active --date 2026-09-13 --parent bloque-a >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug puerto-vps --title "Port al VPS" \
  --status active --date 2026-09-12 --parent sub-a >/dev/null
CYCLE_OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet)
chk "el evento del ciclo se cuarentena" "1" "$(printf '%s' "$CYCLE_OUT" | grep -oE 'quarantined=[0-9]+' | grep -oE '[0-9]+')"
QREASON=$(grep -rl "parent-cycle" "$MEM/.journal/quarantine/"*.reason 2>/dev/null | head -1)
chk "la razon en cuarentena nombra el ciclo" "1" "$([ -n "$QREASON" ] && echo 1 || echo 0)"
chk "puerto-vps sigue sin anotacion de padre (el ciclo no se aplico)" \
  "0" "$(grep 'puerto-vps' "$MEM/_plans-index.md" | grep -c 'fase de plan-sub-a')"
rm -f "$MEM/.journal/quarantine/"*.json "$MEM/.journal/quarantine/"*.reason 2>/dev/null

echo "== regresion adversarial: cerrar un hijo SIN --parent no debe borrar su anotacion =="
echo "   (si se borra, el guardian de ciclos se queda ciego para el siguiente intento)"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug bloque-a --title "Bloque A" \
  --status completed --date 2026-09-14 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null
chk "bloque-a cerrado conserva la anotacion de padre" \
  "1" "$(grep -c 'completed (fase de plan-puerto-vps)' "$MEM/_plans-index.md")"

echo "== ... y el guardian sigue viendo el ciclo tras ese cierre =="
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug puerto-vps --title "Port al VPS" \
  --status active --date 2026-09-12 --parent sub-a >/dev/null
RETRY_OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet)
chk "el reintento del mismo ciclo se sigue cuarentenando" \
  "1" "$(printf '%s' "$RETRY_OUT" | grep -oE 'quarantined=[0-9]+' | grep -oE '[0-9]+')"
rm -f "$MEM/.journal/quarantine/"*.json "$MEM/.journal/quarantine/"*.reason 2>/dev/null

echo "== --inline y --parent no se combinan: mismo evento se rechaza al emitir =="
OUT_INLINE=$(python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug hijo-inline --title "Hijo inline" \
  --status active --date 2026-09-14 --parent puerto-vps --inline 2>&1)
chk "rechaza --inline + --parent en el mismo evento" \
  "1" "$(printf '%s' "$OUT_INLINE" | grep -qc 'no se pueden combinar' && echo 1 || echo 0)"

echo "== --inline ya existente + --parent en un evento posterior: se cuarentena al compactar =="
echo "   (si no se cuarentenara, un eslabon inline rompe el guardian de ciclos: build_parent_map"
echo "   solo indexa filas con wikilink, y una fila inline con padre queda huerfana del mapa)"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug ya-inline --title "Ya inline" \
  --status active --date 2026-09-14 --inline >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug ya-inline --title "Ya inline" \
  --status active --date 2026-09-14 --parent puerto-vps >/dev/null
LATE_OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet)
chk "el intento tardio tambien se cuarentena" \
  "1" "$(printf '%s' "$LATE_OUT" | grep -oE 'quarantined=[0-9]+' | grep -oE '[0-9]+')"
chk "la fila inline sigue sin anotacion de fase" \
  "0" "$(grep 'Ya inline' "$MEM/_plans-index.md" | grep -c 'fase de plan-')"
rm -f "$MEM/.journal/quarantine/"*.json "$MEM/.journal/quarantine/"*.reason 2>/dev/null

echo "== --parent apuntando a un slug que no existe en el indice se cuarentena =="
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug huerfano-real --title "Huerfano real" \
  --status active --date 2026-09-14 --parent no-existe-para-nada >/dev/null
NOPARENT_OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet)
chk "se cuarentena por padre inexistente" \
  "1" "$(printf '%s' "$NOPARENT_OUT" | grep -oE 'quarantined=[0-9]+' | grep -oE '[0-9]+')"
rm -f "$MEM/.journal/quarantine/"*.json "$MEM/.journal/quarantine/"*.reason 2>/dev/null

echo "== padre real dentro de una tabla de header viejo (4 col) SI se encuentra pese al desajuste =="
MEM2="$T/memory2"; mkdir -p "$MEM2"
printf -- '---\ntype: index\n---\n# Plans Index\n\n## Plans\n\n| Fecha | Plan | Status | Resumen |\n|---|---|---|---|\n' > "$MEM2/_plans-index.md"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM2" --type plan.upsert --slug abuelo --title "Abuelo" --status active --date 2026-09-14 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM2" --quiet >/dev/null
python3 "$BIN/journal-emit.py" --memory-dir "$MEM2" --type plan.upsert --slug nieto-legit --title "Nieto legit" --status active --date 2026-09-14 --parent abuelo >/dev/null
LEGIT_OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEM2" --quiet)
chk "no se bloquea por el header desajustado (0 huerfanos, padre encontrado)" \
  "0" "$(printf '%s' "$LEGIT_OUT" | grep -oE 'quarantined=[0-9]+' | grep -oE '[0-9]+')"

echo "== fila con anotacion de padre pero sin wikilink propio (formato viejo/corrupto) bloquea NUEVOS --parent =="
MEM3="$T/memory3"; mkdir -p "$MEM3"
printf -- '---\ntype: index\n---\n# Plans Index\n\n## Plans\n\n| Fecha | Plan | Status | Resumen |\n|---|---|---|---|\n| 2026-01-01 | Legado corrupto | active (fase de plan-abuelo) | vieja |\n' > "$MEM3/_plans-index.md"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM3" --type plan.upsert --slug abuelo --title "Abuelo" --status active --date 2026-09-14 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM3" --quiet >/dev/null
python3 "$BIN/journal-emit.py" --memory-dir "$MEM3" --type plan.upsert --slug otro-nieto --title "Otro nieto" --status active --date 2026-09-14 --parent abuelo >/dev/null
CORRUPT_OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEM3" --quiet)
chk "un --parent nuevo se bloquea mientras haya una fila huerfana en el indice" \
  "1" "$(printf '%s' "$CORRUPT_OUT" | grep -oE 'quarantined=[0-9]+' | grep -oE '[0-9]+')"

echo "== quinta ronda adversarial: re-emparentar un plan cuya fila vive en una tabla legacy =="
echo "   no debe crear una fila duplicada (la causa raiz que dejo escribir un ciclo real)."
echo "   Aqui se rechaza por el chequeo de existencia (el padre tambien es legacy) -- el punto"
echo "   es que NUNCA se duplica la fila, sea cual sea la razon del rechazo."
MEM4="$T/memory4"; mkdir -p "$MEM4"
printf -- '---\ntype: index\n---\n# Plans Index\n\n## Plans\n\n| Plan | Status | Fecha | Sesion | Pendientes | Learnings |\n|---|---|---|---|---|---|\n\n## Active Plans (legacy)\n\n| Fecha | Plan | Status | Resumen |\n|---|---|---|---|\n| 2026-01-01 | [[plans/plan-x\\|X]] | active (fase de plan-a) | vieja |\n| 2026-01-01 | [[plans/plan-a\\|A]] | active | vieja |\n' > "$MEM4/_plans-index.md"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM4" --type plan.upsert --slug x --title "X" \
  --status active --date 2026-09-14 --parent a >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM4" --quiet >/dev/null
chk "reafirmar el mismo padre (a) no duplica la fila de x" \
  "1" "$(grep -c '\[\[plans/plan-x' "$MEM4/_plans-index.md")"

echo "== ... y el guardian de ciclos sigue funcionando sobre esa tabla legacy tras esa escritura =="
python3 "$BIN/journal-emit.py" --memory-dir "$MEM4" --type plan.upsert --slug a --title "A" \
  --status active --date 2026-09-14 --parent x >/dev/null
CYCLE_LEGACY_OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEM4" --quiet)
chk "el ciclo a->x->a se cuarentena en vez de escribirse" \
  "1" "$(printf '%s' "$CYCLE_LEGACY_OUT" | grep -oE 'quarantined=[0-9]+' | grep -oE '[0-9]+')"

echo "== dos filas del mismo plan (duplicado preexistente) bloquean escribir sobre ese plan =="
MEM5="$T/memory5"; mkdir -p "$MEM5"
printf -- '---\ntype: index\n---\n# Plans Index\n\n## Plans\n\n| [[plans/plan-dup\\|Dup]] | active | 2026-01-01 |  |  |  |\n| [[plans/plan-dup\\|Dup]] | completed | 2026-02-01 |  |  |  |\n' > "$MEM5/_plans-index.md"
python3 "$BIN/journal-emit.py" --memory-dir "$MEM5" --type plan.upsert --slug dup --title "Dup" \
  --status active --date 2026-09-14 >/dev/null
DUP_OUT=$(python3 "$BIN/journal-compact.py" --memory-dir "$MEM5" --quiet)
chk "escribir sobre un plan con fila duplicada se cuarentena" \
  "1" "$(printf '%s' "$DUP_OUT" | grep -oE 'quarantined=[0-9]+' | grep -oE '[0-9]+')"

echo "== reemplazo, sin --parent: superseded cuenta como cerrado para la poda =="
for i in 1 2 3 4 5; do
  python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug viejo-$i --title "Viejo $i" \
    --status completed --date "2026-0$((i % 9 + 1))-01" >/dev/null
done
python3 "$BIN/journal-emit.py" --memory-dir "$MEM" --type plan.upsert --slug gaps-vps --title "Gaps VPS" \
  --status "superseded — reemplazado por plan-cronologia" --date 2026-09-12 >/dev/null
python3 "$BIN/journal-compact.py" --memory-dir "$MEM" --quiet >/dev/null

chk "superseded se escribio" "1" "$(grep -c 'superseded' "$MEM/_plans-index.md")"
DONE_ROWS=$(grep -Ec 'completed|abandoned|superseded' "$MEM/_plans-index.md")
chk "poda a 5 cerrados como maximo (completed+superseded)" "5" "$DONE_ROWS"

echo "RESULT pass=$pass fail=$fail skip=0"
[ "$fail" -eq 0 ]
