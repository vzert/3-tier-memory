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
