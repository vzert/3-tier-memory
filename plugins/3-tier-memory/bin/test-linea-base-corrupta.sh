#!/bin/bash
# Prueba de deteccion de linea base CORRUPTA (fingerprints.json ilegible) en journal-compact.py.
#
# Motivo (2.24.7, hallazgo de codex/GPT-5 en la ronda 4 de verificacion adversarial de 2.24.6):
# `leer_huellas()` devolvia `{}` igual para "fingerprints.json no existe" (arranque en frio real,
# nada que proteger) que para "existe pero es JSON invalido o no es un dict" (corrupcion
# accidental — disco danado, escritura interrumpida a mano). Una copia de trabajo MADURA cuyo
# fingerprints.json se corrompiera perdia proteccion en silencio: cualquier escritura fuera de
# banda en la misma ventana se absorbia junto con el estado actual, sin ningun aviso.
#
# MODELO DE AMENAZA (ver estado_huellas() en journal-compact.py): esto detecta corrupcion
# ACCIDENTAL. NO detecta el borrado deliberado de fingerprints.json (indistinguible de un
# arranque en frio real) ni una manipulacion sofisticada por alguien con permiso de escritura en
# .journal/ (podria forjar un JSON valido-pero-falso). Los tests de aqui cubren exactamente lo
# que la funcion promete: JSON ilegible o mal formado.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

FP() { echo "$1/.journal/fingerprints.json"; }

echo "== corrupcion detectada: JSON ilegible + escritura legitima con 'escritos' NO la sobrescribe =="
P="$T/proj"; mkdir -p "$P/memory/pendientes"
printf -- '---\ntype: index\n---\n# Pendientes\n\n- [ ] original\n' > "$P/memory/_pendientes.md"
printf -- '---\ntype: index\n---\n# Sesiones\n\ntoken AKIAABCDEFGHIJKLMNOP\n' > "$P/memory/_session-index.md"
python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --check-drift >/dev/null 2>&1
printf -- 'esto no es json valido {{{' > "$(FP "$P/memory")"
CORRUPTO_ANTES=$(cat "$(FP "$P/memory")")

SC=$(cd "$P" && python3 "$BIN/scan-secrets.py" memory --apply 2>&1)
chk "scan-secrets (rama escritos) redacto el secreto igual" "1" "$(printf '%s' "$SC" | grep -c 'findings: 1')"
# guardar_huellas() es compartida por 4 llamadores (scan-secrets, enrich-memory,
# normalize-pendientes, repair-dualwrite) y AL MENOS UNO tiene contrato de --quiet propio que un
# print incondicional aqui rompia (hallazgo de Opus, ronda de verificacion de 2.24.7). El aviso
# humano vive SOLO en compact()/--check-drift; esta rama solo ANOTA en el log, sin imprimir nada.
chk "scan-secrets NO imprime el aviso (eso rompia --quiet de otros llamadores)" "0" \
  "$(printf '%s' "$SC" | grep -c 'ILEGIBLE')"
chk "pero queda anotado ya en out-of-band.log, antes de cualquier --check-drift" "1" \
  "$(grep -c 'LINEA_BASE_CORRUPTA' "$P/memory/.journal/out-of-band.log" 2>/dev/null || echo 0)"
CORRUPTO_DESPUES=$(cat "$(FP "$P/memory")")
chk "la rama 'escritos' NO escribio: fingerprints.json sigue siendo la misma basura" \
  "$CORRUPTO_ANTES" "$CORRUPTO_DESPUES"

echo "== --check-drift TAMBIEN avisa CORRUPTA (scan-secrets ya aviso, pero no resello) y resella =="
O1=$(python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --check-drift 2>&1)
chk "avisa LINEA BASE ILEGIBLE" "1" "$(printf '%s' "$O1" | grep -c 'ILEGIBLE')"
chk "2 lineas en out-of-band.log: la de scan-secrets + la de --check-drift" "2" \
  "$(grep -c 'LINEA_BASE_CORRUPTA' "$P/memory/.journal/out-of-band.log" 2>/dev/null || echo 0)"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$(FP "$P/memory")" \
  && chk "tras resellar, fingerprints.json vuelve a ser JSON valido" "1" "1" \
  || chk "tras resellar, fingerprints.json vuelve a ser JSON valido" "1" "0"
O2=$(python3 "$BIN/journal-compact.py" --memory-dir "$P/memory" --check-drift 2>&1)
chk "segunda pasada calla (one-shot)" "" "$O2"

echo "== control negativo: {} valido NO es corrupcion (scope-out deliberado) =="
Q="$T/proj2"; mkdir -p "$Q/memory"
printf -- '---\ntype: index\n---\n# Pendientes\n\n- [ ] x\n' > "$Q/memory/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$Q/memory" --check-drift >/dev/null 2>&1
printf -- '{}' > "$(FP "$Q/memory")"
O3=$(python3 "$BIN/journal-compact.py" --memory-dir "$Q/memory" --check-drift 2>&1)
chk "un {} valido NO dispara el aviso de corrupcion" "0" "$(printf '%s' "$O3" | grep -c 'ILEGIBLE')"

echo "== compact(): avisa con lector, calla con --quiet + PAPERCLIP_RUN_ID (mismo gate que fuera-de-banda) =="
R="$T/proj3"; mkdir -p "$R/memory/.journal"
printf -- '---\ntype: index\n---\n# Pendientes\n\n- [ ] x\n' > "$R/memory/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$R/memory" --check-drift >/dev/null 2>&1
printf -- 'basura{{{' > "$(FP "$R/memory")"
O4=$(python3 "$BIN/journal-compact.py" --memory-dir "$R/memory" 2>&1)
chk "compact() con lector SI avisa" "1" "$(printf '%s' "$O4" | grep -c 'ILEGIBLE')"

printf -- 'basura{{{' > "$(FP "$R/memory")"
O5=$(PAPERCLIP_RUN_ID=run-1 python3 "$BIN/journal-compact.py" --memory-dir "$R/memory" --quiet 2>&1)
chk "compact() sin lector y --quiet: calla" "0" "$(printf '%s' "$O5" | grep -c 'ILEGIBLE')"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$(FP "$R/memory")" \
  && chk "pero SI resella (compact() siempre resella)" "1" "1" \
  || chk "pero SI resella (compact() siempre resella)" "1" "0"

echo "== --reseal reporta la corrupcion en su mensaje =="
S="$T/proj4"; mkdir -p "$S/memory"
printf -- '---\ntype: index\n---\n# Pendientes\n\n- [ ] x\n' > "$S/memory/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$S/memory" --check-drift >/dev/null 2>&1
printf -- 'basura{{{' > "$(FP "$S/memory")"
O6=$(python3 "$BIN/journal-compact.py" --memory-dir "$S/memory" --reseal 2>&1)
chk "--reseal menciona que la anterior era corrupta" "1" "$(printf '%s' "$O6" | grep -c 'corrupta')"

echo "== normalize-pendientes.py --apply --quiet con linea base corrupta: NO mezcla el aviso =="
# Otro de los 4 llamadores de guardar_huellas(escritos=...). --quiet solo calla el caso "nada que
# hacer" (headers_added=0); con plan real SIEMPRE imprime 'headers_added=N (...)', con o sin
# --quiet — eso es el contrato normal, no lo que rompia el hallazgo de Opus. Lo que NO puede pasar
# es que ESE 'headers_added=N' se mezcle con el aviso de corrupcion de una funcion compartida
# ajena a este contrato (asi se veia el bug: 'NORMALIZADO: ... — ⚠ LINEA BASE... ILEGIBLE...').
N="$T/proj5"; mkdir -p "$N/memory"
printf -- '# Pendientes\n\n## Media prioridad\n\n- [ ] b\n\n## Baja prioridad\n\n- [ ] c\n' \
  > "$N/memory/_pendientes.md"
python3 "$BIN/journal-compact.py" --memory-dir "$N/memory" --check-drift >/dev/null 2>&1
printf -- 'basura{{{' > "$(FP "$N/memory")"
NP=$(cd "$N" && python3 "$BIN/normalize-pendientes.py" memory --apply --quiet 2>&1)
chk "normalize-pendientes reporta su propio contrato tal cual" "1" \
  "$(printf '%s' "$NP" | grep -c '^headers_added=1 (Alta prioridad)$')"
chk "y NO le mezcla el aviso de corrupcion (funcion compartida, otro contrato)" "0" \
  "$(printf '%s' "$NP" | grep -c 'ILEGIBLE')"
chk "aun asi el header que faltaba se inserto (el --apply si corrio)" "1" \
  "$(grep -c '^## Alta prioridad$' "$N/memory/_pendientes.md")"
chk "y queda anotado en out-of-band.log" "1" \
  "$(grep -c 'LINEA_BASE_CORRUPTA' "$N/memory/.journal/out-of-band.log" 2>/dev/null || echo 0)"

echo "== session-start.sh entrega el aviso ILEGIBLE A LA PERSONA (systemMessage), no solo al agente =="
# Mismo canal que ya usa 'FUERA DEL JOURNAL' (test-expire-reopen.sh) — el aserto le pregunta al
# CANAL, no a si la salida trae algun texto.
H="$T/proj6"; mkdir -p "$H/memory/.journal" "$H/memory/sessions"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n\n- [ ] x\n' \
  > "$H/memory/_pendientes.md"
printf -- '---\ntype: session\n---\n# s\n' > "$H/memory/sessions/2026-01-01-x.md"
python3 "$BIN/journal-compact.py" --memory-dir "$H/memory" --check-drift >/dev/null 2>&1
printf -- 'basura{{{' > "$(FP "$H/memory")"
HOUT=$(CLAUDE_PLUGIN_ROOT="$(cd "$BIN/.." && pwd)" CLAUDE_PROJECT_DIR="$H" \
  bash "$BIN/session-start.sh" 2>/dev/null <<J
{"hook_event_name":"SessionStart","source":"startup","cwd":"$H"}
J
)
chk "el arranque con persona SI lo entrega (systemMessage nombra la corrupcion)" "1" \
  "$(printf '%s' "$HOUT" | python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read())
except Exception: print(0); raise SystemExit
print(1 if "corrupta" in d.get("systemMessage","") else 0)' 2>/dev/null || echo 0)"

echo
echo "== resumen: $pass ok, $fail fallas =="
[ "$fail" -eq 0 ]
