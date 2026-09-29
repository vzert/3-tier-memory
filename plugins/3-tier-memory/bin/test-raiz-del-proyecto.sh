#!/usr/bin/env bash
# Pruebas del bloque `raiz-del-proyecto` (2.41.3) en commands/ y templates/.
#
# Por que existe: 2.39.1 dio a los bloques bash el respaldo `${CLAUDE_PROJECT_DIR:-$PWD}`, porque
# CLAUDE_PROJECT_DIR llega vacia al Bash del agente. Pero $PWD es la carpeta donde esta el shell
# del agente, y el agente puede haber hecho cd (el harness conserva el cd dentro del proyecto). Un
# adversario externo (Codex, 2026-09-28) corrio setup-memory desde `a/src`: creo `a/src/memory/`, y
# 8b, backfill, consolidate y enrich buscaban el JSONL y el indice de recall bajo la codificacion
# de `a-src`. Ahora cada bloque calcula RAIZ = el primer "cwd" del JSONL de la sesion (la carpeta
# donde se lanzo; medido: el campo "cwd" de las lineas siguientes cambia con cada cd).
#
# Todo corre con un HOME falso y un JSONL sintetico. Cada bloque se extrae de la plantilla real,
# asi que la prueba mide el texto que el agente copia.
#
# Uso: test-raiz-del-proyecto.sh   (exit 0 = todo verde)
# sella-huellas: no (trabaja en un temporal propio)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(dirname "$BIN")"
TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=1; }

SID="11111111-1111-4111-8111-111111111111"
A="$TMP/a"; SUB="$A/src"
mkdir -p "$SUB" "$A/memory" "$TMP/home"
A=$(cd "$A" && pwd -P); SUB="$A/src"
ENC_A=$(echo "$A" | sed 's/[^A-Za-z0-9]/-/g')
ENC_SUB=$(echo "$SUB" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$TMP/home/.claude/projects/$ENC_A"
# Primera linea: cwd = la raiz. Una linea posterior: cwd = el subdirectorio (el agente hizo cd).
printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n{"type":"user","cwd":"%s","sessionId":"%s"}\n' \
  "$A" "$SID" "$SUB" "$SID" > "$TMP/home/.claude/projects/$ENC_A/$SID.jsonl"

# bloque FICHERO MARCA -> el cuerpo del primer ```bash que sigue a MARCA
bloque() {
  python3 - "$PLUGIN/$1" "$2" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read().split(sys.argv[2], 1)[1]
print(s.split("```bash\n", 1)[1].split("```", 1)[0])
PY
}
# corre CODIGO DESDE [SID] -> stdout+stderr; rc en RC
corre() {
  OUT=$(cd "$2" && env -u CLAUDE_PROJECT_DIR -u PROJECT_DIR HOME="$TMP/home" \
        CLAUDE_CODE_SESSION_ID="${3-$SID}" bash -c "$1" 2>&1); RC=$?
}

echo "1. todas las copias del bloque son el mismo texto"
python3 - "$PLUGIN" > "$TMP/copias" <<'PY'
import glob, sys
for f in sorted(glob.glob(sys.argv[1] + "/commands/*.md") + glob.glob(sys.argv[1] + "/templates/*.md")):
    s = open(f, encoding="utf-8").read()
    while "\n# raiz-del-proyecto:" in s:
        s = s.split("\n# raiz-del-proyecto:", 1)[1]
        print(repr(s.split('[ -n "$RAIZ" ] || RAIZ=', 1)[0]))
PY
N=$(sort -u "$TMP/copias" | wc -l | tr -d ' '); C=$(wc -l < "$TMP/copias" | tr -d ' ')
[ "$N" = 1 ] && ok "una sola variante" || bad "hay $N variantes del bloque RAIZ"
[ "$C" = 8 ] && ok "8 copias (setup-memory 3, migrate 2, backfill, consolidate, enrich)" || bad "esperaba 8 copias, hay $C"

echo "2. setup-memory desde un subdirectorio escribe en la raiz"
corre "$(bloque commands/setup-memory.md '## Step 2:')" "$SUB"
[ -d "$A/memory/sessions" ] && ok "Step 2: memory/sessions en la raiz" || bad "Step 2: no creo $A/memory/sessions ($OUT)"
[ ! -e "$SUB/memory" ] && ok "Step 2: nada en el subdirectorio" || bad "Step 2: creo $SUB/memory"
corre "$(bloque commands/setup-memory.md '## Step 3b:')" "$SUB"
[ -f "$A/memory/.memory-config" ] && ok "Step 3b: .memory-config en la raiz" || bad "Step 3b: rc=$RC $OUT"
corre "$(bloque commands/setup-memory.md '## Step 8b:')"'
echo "count=$JSONL_COUNT"' "$SUB"
[ "$OUT" = "count=1" ] && ok "Step 8b: cuenta el JSONL de la raiz" || bad "Step 8b: $OUT"

echo "3. migrate desde un subdirectorio"
rm -f "$A/memory/.memory-config"
corre "$(bloque commands/migrate.md '## Encender')" "$SUB"
[ -f "$A/memory/.memory-config" ] && [ $RC -eq 0 ] && ok "journal_strict en la raiz, rc=0" || bad "migrate: rc=$RC $OUT"
corre "$(bloque commands/migrate.md '## Step 8b:')"'
echo "count=$JSONL_COUNT"' "$SUB"
[ "$OUT" = "count=1" ] && ok "Step 8b: cuenta el JSONL de la raiz" || bad "migrate 8b: $OUT"
# Si la escritura falla, no anuncia exito y sale != 0.
rm -f "$A/memory/.memory-config"; chmod 555 "$A/memory"
corre "$(bloque commands/migrate.md '## Encender')" "$SUB"
chmod 755 "$A/memory"
if [ -f "$A/memory/.memory-config" ]; then
  ok "(el sistema ignora chmod 555 en directorios; caso de fallo no medible aqui)"
else
  [ $RC -ne 0 ] && ok "escritura fallida: rc=$RC" || bad "escritura fallida con rc=0"
  case "$OUT" in *"activado (no habia config)"*) bad "escritura fallida y aun asi dice 'activado'";; *) ok "no anuncia 'activado'";; esac
fi

echo "4. plantillas: el JSONL y el indice de recall salen de la raiz"
corre "$(bloque templates/backfill-3t.md '2. Determine the JSONL directory:')"'
echo "$JSONL_DIR"' "$SUB"
[ "$OUT" = "$TMP/home/.claude/projects/$ENC_A" ] && ok "backfill: JSONL_DIR de la raiz" || bad "backfill: $OUT"
for t in "templates/consolidate-3t.md|1. Resolve paths" "templates/enrich-3t.md|## Step 3:"; do
  f=${t%%|*}; m=${t#*|}
  code=$(bloque "$f" "$m" | sed '/^python3 /d')
  corre "$code"'
echo "$INDEX"' "$SUB"
  [ "$OUT" = "$TMP/home/.claude/projects/$ENC_A/.recall-index.jsonl" ] && ok "$(basename "$f"): INDEX de la raiz" || bad "$f: $OUT"
done

echo "5. sin session id (o sin su JSONL): respaldo a PWD, nunca vacio"
corre "$(bloque templates/backfill-3t.md '2. Determine the JSONL directory:')"'
echo "$JSONL_DIR"' "$SUB" ""
[ "$OUT" = "$TMP/home/.claude/projects/$ENC_SUB" ] && ok "sin id: PWD" || bad "sin id: $OUT"
corre "$(bloque templates/backfill-3t.md '2. Determine the JSONL directory:')"'
echo "$JSONL_DIR"' "$SUB" "22222222-2222-4222-8222-222222222222"
[ "$OUT" = "$TMP/home/.claude/projects/$ENC_SUB" ] && ok "id sin JSONL: PWD" || bad "id sin JSONL: $OUT"

echo "6. ronda 2 del adversario (Codex, 2026-09-28): que JSONL y que cwd valen"
BK="$(bloque templates/backfill-3t.md '2. Determine the JSONL directory:')"'
echo "$RAIZ"'
B="$TMP/b"; mkdir -p "$B"; B=$(cd "$B" && pwd -P); ENC_B=$(echo "$B" | sed 's/[^A-Za-z0-9]/-/g')
J="$TMP/home/.claude/projects/$ENC_A/$SID.jsonl"; cp "$J" "$TMP/orig.jsonl"
# a) la primera linea con cwd es de un subagente en otra carpeta
{ printf '{"type":"assistant","isSidechain":true,"cwd":"%s"}\n' "$B"; cat "$TMP/orig.jsonl"; } > "$J"
corre "$BK" "$SUB"; [ "$OUT" = "$A" ] && ok "salta el cwd de un subagente" || bad "sidechain: $OUT"
# b) una linea rota antes del primer cwd
{ printf '{"type":"user","cwd":\n'; cat "$TMP/orig.jsonl"; } > "$J"
corre "$BK" "$SUB"; [ "$OUT" = "$A" ] && ok "salta una linea rota" || bad "linea rota: $OUT"
cp "$TMP/orig.jsonl" "$J"
# c) el mismo id en otro proyecto, mas reciente, que no contiene al shell
mkdir -p "$TMP/home/.claude/projects/$ENC_B"
printf '{"type":"user","cwd":"%s"}\n' "$B" > "$TMP/home/.claude/projects/$ENC_B/$SID.jsonl"
touch -t 203001010000 "$TMP/home/.claude/projects/$ENC_B/$SID.jsonl"
corre "$BK" "$SUB"; [ "$OUT" = "$A" ] && ok "id duplicado: gana el proyecto que contiene al shell, no el mas reciente" || bad "duplicado: $OUT"
rm -rf "$TMP/home/.claude/projects/$ENC_B"
# d) el shell fuera de la carpeta de lanzamiento: PWD, como antes
corre "$BK" "$B"; [ "$OUT" = "$B" ] && ok "shell fuera de la raiz: PWD" || bad "fuera: $OUT"
# e) CLAUDE_PROJECT_DIR puesta gana al JSONL
OUT=$(cd "$SUB" && env -u PROJECT_DIR HOME="$TMP/home" CLAUDE_PROJECT_DIR="$B" CLAUDE_CODE_SESSION_ID="$SID" bash -c "$BK" 2>&1)
[ "$OUT" = "$B" ] && ok "CLAUDE_PROJECT_DIR puesta manda" || bad "CLAUDE_PROJECT_DIR: $OUT"

echo "7. ronda 4 del adversario (Codex, 2026-09-29)"
# a) una PROJECT_DIR del perfil del usuario (o de un bloque anterior) no manda
OUT=$(cd "$SUB" && env -u CLAUDE_PROJECT_DIR HOME="$TMP/home" PROJECT_DIR="$B" CLAUDE_CODE_SESSION_ID="$SID" bash -c "$BK" 2>&1)
[ "$OUT" = "$A" ] && ok "PROJECT_DIR heredada se ignora" || bad "PROJECT_DIR heredada: $OUT"
# b) sesion reanudada: el JSONL vive en el proyecto a/src pero su historial empieza con cwd=a
ENC_SUB_DIR="$TMP/home/.claude/projects/$ENC_SUB"; mkdir -p "$ENC_SUB_DIR"
mv "$J" "$TMP/aparte.jsonl"
printf '{"type":"user","cwd":"%s"}\n{"type":"user","cwd":"%s"}\n' "$A" "$SUB" > "$ENC_SUB_DIR/$SID.jsonl"
corre "$BK" "$SUB"; [ "$OUT" = "$SUB" ] && ok "reanudada: RAIZ es la carpeta cuyo nombre codifica el JSONL" || bad "reanudada: $OUT"
rm -rf "$ENC_SUB_DIR"; mv "$TMP/aparte.jsonl" "$J"

echo
[ $FAIL -eq 0 ] && echo "TODO VERDE" || echo "HAY FALLOS"
exit $FAIL
