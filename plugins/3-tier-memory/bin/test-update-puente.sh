#!/bin/bash
# Prueba de 2.64.2 (p-6ba77d2ea4): el puente YA instalado deja de mandar leer los indices Tier 2.
#
#  1. update-puente.py: el par de lineas exacto de la plantilla vieja pasa al texto nuevo
#     (`/status-3t` + `grep`); el resto del puente queda byte a byte igual; deja copia.
#  2. Un puente editado a mano (linea 2 propia, otro idioma, par separado, una sola linea, CRLF)
#     NO se toca: mismo hash, sin copia, sin salida.
#  3. Idempotente (segunda corrida no escribe) y --dry-run no escribe. Fichero que falta: sale 0.
#  4. Extremo a extremo con session-start.sh en una COPIA con HOME falso: el puente viejo del
#     proyecto queda con el texto nuevo y el aviso sale; uno editado a mano no cambia.
#
# Uso: test-update-puente.sh (exit 0 = todo verde). Resumen final: "pass=N fail=M".
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$BIN/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }
# sha256 por Python: el Git Bash del runner windows-latest no trae `shasum` (corrida
# 40520030467), y ahi las dos llamadas daban "" y un
# "no cambia nada" pasaba comparando vacio con vacio.
hash_() { python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
hash() { hash_ < "$1"; }
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR

VIEJO_1='1. Read `memory/_pendientes.md` — open action items'
VIEJO_2='2. Read `memory/_learnings.md` — consult before making changes'
puente() { # $1 = ruta, $2.. = lineas bajo "At session start"
  local p="$1"; shift
  { printf '# Demo — Memory Bridge\n\nThis project uses project-local memory.\n\n## At session start\n'
    printf '%s\n' "$@"
    printf '\n## During execution\n- New learning → `learning.add` event\n\n## Index\n- `memory/_pendientes.md` — open action items\n'
  } > "$p"
}

echo "== 1. puente viejo exacto =="
B="$T/b1.md"; puente "$B" "$VIEJO_1" "$VIEJO_2"
cp "$B" "$T/b1.orig"
O=$(python3 "$BIN/update-puente.py" "$B")
chk "imprime ACTUALIZADO" "ACTUALIZADO" "$O"
chk "ya no manda hacer Read de _pendientes.md" "0" "$(grep -c '^1\. Read `memory/_pendientes.md`' "$B")"
chk "ya no manda hacer Read de _learnings.md" "0" "$(grep -c '^2\. Read `memory/_learnings.md`' "$B")"
chk "manda /status-3t" "1" "$(grep -c '^1\. Run `/status-3t`.*Do NOT read' "$B")"
chk "manda grep" "1" "$(grep -c '^2\. Look things up with `grep -i' "$B")"
chk "el resto queda igual (lineas de fuera del par)" "$(grep -v '^[12]\. ' "$T/b1.orig" | hash_)" "$(grep -v '^[12]\. ' "$B" | hash_)"
chk "la linea de Index con _pendientes.md sigue" "1" "$(grep -c '^- `memory/_pendientes.md` — open action items$' "$B")"
chk "deja copia identica al original" "$(hash "$T/b1.orig")" "$(hash "$T/MEMORY.md.pre-2.64.2")"
chk "sin ficheros temporales" "0" "$(ls "$T" | grep -c 'tmp-')"

echo "== 3. idempotencia, dry-run, fichero que falta =="
H=$(hash "$B")
O=$(python3 "$BIN/update-puente.py" "$B")
chk "segunda corrida: sin salida" "" "$O"
chk "segunda corrida: mismo hash" "$H" "$(hash "$B")"
D="$T/b3.md"; puente "$D" "$VIEJO_1" "$VIEJO_2"; H=$(hash "$D")
O=$(python3 "$BIN/update-puente.py" "$D" --dry-run)
chk "dry-run: dice ACTUALIZARIA" "ACTUALIZARIA" "$O"
chk "dry-run: no escribe" "$H" "$(hash "$D")"
python3 "$BIN/update-puente.py" "$T/no-existe.md" >/dev/null 2>&1; chk "fichero que falta: sale 0" "0" "$?"
python3 "$BIN/update-puente.py" >/dev/null 2>&1; chk "sin argumento: sale 2" "2" "$?"

echo "== 2. puentes editados a mano: no se tocan =="
caso() { # $1 = nombre, $2.. = lineas
  local n="$1"; shift
  local f="$T/e-$n.md"; puente "$f" "$@"; local h; h=$(hash "$f")
  local o; o=$(python3 "$BIN/update-puente.py" "$f")
  chk "$n: sin salida" "" "$o"
  chk "$n: mismo contenido" "$h" "$(hash "$f")"
}
caso linea2-propia "$VIEJO_1" '2. Read `memory/_learnings.md` — consult before modifying plugin structure'
caso otro-idioma '1. Read `memory/_pendientes.md` — pendientes abiertos' "$VIEJO_2"
caso par-separado "$VIEJO_1" 'Nota mia.' "$VIEJO_2"
caso una-sola-linea "$VIEJO_1"
caso orden-invertido "$VIEJO_2" "$VIEJO_1"
caso ya-nuevo '1. Run `/status-3t` — counts' '2. Look things up with `grep -i "<term>" memory/_pendientes.md`'
CR="$T/e-crlf.md"; puente "$CR" "$VIEJO_1" "$VIEJO_2"; sed -i.bak 's/$/\r/' "$CR"; rm -f "$CR.bak"; H=$(hash "$CR")
O=$(python3 "$BIN/update-puente.py" "$CR")
chk "crlf: sin salida" "" "$O"
chk "crlf: mismo contenido" "$H" "$(hash "$CR")"

echo "== 4. extremo a extremo con session-start.sh (copia, HOME falso) =="
HOME_F="$T/home"; P="$T/proyecto"; mkdir -p "$P/memory/sessions" "$P/memory/.journal/pending"
printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n' > "$P/memory/_pendientes.md"
ENC=$(echo "$P" | sed 's/[^A-Za-z0-9]/-/g')
AUTO="$HOME_F/.claude/projects/$ENC/memory"; mkdir -p "$AUTO"
puente "$AUTO/MEMORY.md" "$VIEJO_1" "$VIEJO_2"
arranque() { printf '%s' "{\"cwd\":\"$P\",\"source\":\"startup\",\"hook_event_name\":\"SessionStart\"}" \
  | HOME="$HOME_F" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$BIN/session-start.sh" 2>/dev/null; }
arranque > "$T/o1"
chk "el aviso sale" "1" "$(grep -c 'PUENTE ACTUALIZADO' "$T/o1")"
chk "grep: el puente tiene /status-3t" "1" "$(grep -c 'Run `/status-3t`' "$AUTO/MEMORY.md")"
chk "grep: el puente ya no manda Read de los indices" "0" "$(grep -c '^[12]\. Read `memory/_' "$AUTO/MEMORY.md")"
arranque > "$T/o2"
chk "segundo arranque: sin aviso" "0" "$(grep -c 'PUENTE ACTUALIZADO' "$T/o2")"
puente "$AUTO/MEMORY.md" "$VIEJO_1" '2. Read `memory/_learnings.md` — mi linea propia'; H=$(hash "$AUTO/MEMORY.md")
arranque > "$T/o3"
chk "editado a mano: sin aviso" "0" "$(grep -c 'PUENTE ACTUALIZADO' "$T/o3")"
chk "editado a mano: mismo contenido" "$H" "$(hash "$AUTO/MEMORY.md")"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
