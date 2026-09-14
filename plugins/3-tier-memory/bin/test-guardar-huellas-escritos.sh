#!/bin/bash
# Prueba de guardar_huellas(escritos=...) en journal-compact.py.
#
# Motivo (2026-09-14, reportado por otra sesion Claude via cross-session-message y verificado
# leyendo el codigo): scan-secrets.py --apply, enrich-memory.py --apply, normalize-pendientes.py
# --apply y repair-dualwrite.py --apply llaman guardar_huellas(mem, journal) SIN pasar `estado`,
# para re-sellar tras su propia escritura LEGITIMA a UN indice. Con `estado is None`,
# guardar_huellas releia TODO el estado de disco (leer_estado(mem)) para sellar la linea base
# nueva — no solo el indice que ese script toco. Si en la misma ventana habia una escritura fuera
# de banda a OTRO indice protegido, quedaba sellada en silencio como si fuera legitima, y
# --check-drift dejaba de verla para siempre.
#
# Este test reproduce el escenario exacto con scan-secrets.py (el llamante que lo reporto):
# sella la linea base -> edita a mano _pendientes.md (fuera de banda) -> corre
# scan-secrets.py --apply, que solo redacta un secreto en _session-index.md -> --check-drift
# DEBE marcar _pendientes.md como FUERA DEL JOURNAL. Antes del fix (kwarg `escritos`), no lo
# marcaba: el aviso salia vacio y exit 0.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

P="$T/proj"; mkdir -p "$P/memory/pendientes" "$P/memory/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Media prioridad\n\n- [ ] item original\n' > "$P/memory/_pendientes.md"
printf -- '---\ntype: index\n---\n# Sesiones\n\ntoken de prueba AKIAABCDEFGHIJKLMNOP en el registro\n' > "$P/memory/_session-index.md"

check_drift() {   # -> stdout completo de --check-drift
  python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --check-drift 2>&1
}

echo "== sella la linea base antes de empezar (primera pasada, sin aviso) =="
O1=$(check_drift)
chk "primera pasada no avisa" "" "$O1"

echo "== escritura fuera de banda a _pendientes.md, EN LA MISMA VENTANA que un --apply legitimo a otro indice =="
printf -- '- [ ] colado a mano, nadie lo emitio por journal-emit.py\n' >> "$P/memory/_pendientes.md"

echo "== scan-secrets.py --apply: escribe SOLO _session-index.md (redacta el secreto) =="
SC=$(python3 "$BIN/scan-secrets.py" "$P/memory" --apply 2>&1)
chk "scan-secrets encontro y redacto el secreto" "1" "$(printf '%s' "$SC" | grep -c 'findings: 1')"
chk "el secreto ya no esta en texto plano" "0" "$(grep -c 'AKIAABCDEFGHIJKLMNOP' "$P/memory/_session-index.md" || true)"

echo "== --check-drift DEBE ver la escritura fuera de banda de _pendientes.md =="
O2=$(check_drift)
chk "avisa FUERA DEL JOURNAL" "1" "$(printf '%s' "$O2" | grep -c 'FUERA DEL JOURNAL')"
chk "nombra _pendientes.md, no _session-index.md" "1" "$(printf '%s' "$O2" | grep -c '_pendientes.md')"
chk "NO acusa a _session-index.md (escritura legitima de scan-secrets)" "0" "$(printf '%s' "$O2" | grep -c '_session-index.md')"

echo "== el aviso se consume tras leerse una vez (mismo contrato que el resto del sistema) =="
O3=$(check_drift)
chk "segunda pasada calla" "" "$O3"

echo "== 'mem' RELATIVO (el caso real: templates/*.md usan MEMORY_DIR=\"memory\") =="
# Los 4 llamadores construyen `escritos` como os.path.join(mem, nombre) — NUNCA una ruta bare
# relativa a `mem` independiente del cwd. Un primer intento de este fix (ronda adversarial externa,
# codex/GPT-5) asumio ese segundo contrato y doblaba el prefijo cuando `mem` es relativo
# (os.path.join(mem, os.path.join(mem, nombre))), rompiendo el caso REAL de produccion: todas las
# plantillas de /checkpoint-3t corren `python3 scan-secrets.py "$MEMORY_DIR" --apply` con
# MEMORY_DIR="memory" (relativo al cwd del proyecto), nunca con una ruta absoluta. Encontrado por
# el adversario en Opus, re-verificando la ronda anterior.
Q="$T/proj2"; mkdir -p "$Q/memory"
printf -- '---\ntype: index\n---\n# Pendientes\n\n- [ ] original\n' > "$Q/memory/_pendientes.md"
printf -- '---\ntype: index\n---\n# Sesiones\n\ntoken de prueba AKIAABCDEFGHIJKLMNOP en el registro\n' > "$Q/memory/_session-index.md"
(cd "$Q" && python3 "$BIN/journal-compact.py" --memory-dir memory --check-drift) >/dev/null 2>&1

printf -- '- [ ] colado a mano en Q\n' >> "$Q/memory/_pendientes.md"
SC2=$(cd "$Q" && python3 "$BIN/scan-secrets.py" memory --apply 2>&1)
chk "scan-secrets (mem relativo) redacto el secreto" "1" "$(printf '%s' "$SC2" | grep -c 'findings: 1')"
O4=$(cd "$Q" && python3 "$BIN/journal-compact.py" --memory-dir memory --check-drift 2>&1)
chk "con mem relativo: SI avisa de _pendientes.md" "1" "$(printf '%s' "$O4" | grep -c '_pendientes.md')"
chk "con mem relativo: NO acusa a _session-index.md (su propia escritura legitima)" "0" \
  "$(printf '%s' "$O4" | grep -c '_session-index.md')"

echo "== indice protegido NUNCA sellado antes, creado fuera de banda EN LA MISMA VENTANA que un --apply legitimo a otro indice =="
# Hueco preexistente (no introducido por este fix, tampoco cerrado por el primer intento):
# detectar_fuera_de_banda() distingue "indice nuevo, no lo creo el compactador" como su propia
# clase de deriva (ronda 6). Un `escritos` que solo cubre lo que ESTE llamante escribio no debe
# sellar en silencio un indice protegido que aparecio de la nada y que NADIE declaro haber
# escrito — debe seguir viéndose como "nuevo" en la siguiente pasada.
R="$T/proj3"; mkdir -p "$R/memory"
printf -- '---\ntype: index\n---\n# Sesiones\n\ntoken AKIAABCDEFGHIJKLMNOP\n' > "$R/memory/_session-index.md"
(cd "$R" && python3 "$BIN/journal-compact.py" --memory-dir memory --check-drift) >/dev/null 2>&1
printf -- '---\ntype: index\n---\n# Learnings\n\n1. colado fuera de banda, indice que nunca existio\n' \
  > "$R/memory/_learnings.md"
(cd "$R" && python3 "$BIN/scan-secrets.py" memory --apply) >/dev/null 2>&1
O5=$(cd "$R" && python3 "$BIN/journal-compact.py" --memory-dir memory --check-drift 2>&1)
chk "el indice nuevo fuera de banda SI se ve (no absorbido en silencio)" "1" \
  "$(printf '%s' "$O5" | grep -c '_learnings.md')"

echo "== SIN linea base previa (clon nuevo: fingerprints.json no existe) =="
# El arreglo del caso anterior (indice nunca sellado -> se queda fuera de `d`) tenia un efecto
# lateral real en un clon nuevo: `fingerprints.json` esta gitignored (por-copia-de-trabajo), asi
# que TODO indice preexistente pero nunca sellado por ESTA maquina se veia como "nuevo" en el
# primer --check-drift tras una herramienta legitima — camino real: /checkpoint-3t Step 3-pre
# corre normalize-pendientes/enrich-memory/repair-dualwrite ANTES de que el compactador mismo
# establezca linea base. Encontrado por el adversario (Opus, ronda delta-scoped) reproduciendolo
# con los binarios reales.
S="$T/proj4"; mkdir -p "$S/memory"
printf -- '---\ntype: index\n---\n# Pendientes\n\n- [ ] item preexistente, nunca sellado\n' > "$S/memory/_pendientes.md"
printf -- '---\ntype: index\n---\n# Learnings\n\n1. regla preexistente, nunca sellada\n' > "$S/memory/_learnings.md"
printf -- '---\ntype: index\n---\n# Sesiones\n\ntoken AKIAABCDEFGHIJKLMNOP\n' > "$S/memory/_session-index.md"
# SIN --check-drift previo: no hay .journal/fingerprints.json en absoluto todavia.
SC3=$(cd "$S" && python3 "$BIN/scan-secrets.py" memory --apply 2>&1)
chk "scan-secrets (clon nuevo) redacto el secreto" "1" "$(printf '%s' "$SC3" | grep -c 'findings: 1')"
O6=$(cd "$S" && python3 "$BIN/journal-compact.py" --memory-dir memory --check-drift 2>&1)
chk "clon nuevo: NO falso positivo sobre indices preexistentes intocados" "" "$O6"

echo
echo "== resumen: $pass ok, $fail fallas =="
[ "$fail" -eq 0 ]
