#!/bin/bash
# El hueco entre crear un evento y escribirlo (p-4c4f8274a6, 2.63.34).
#
# journal-emit.py creaba pending/<evento>.json con O_EXCL y escribia el contenido despues. Un
# compactador que listaba pending/ en ese hueco leia un archivo vacio, lo mandaba a cuarentena
# `malformed: Expecting value: line 1 column 1 (char 0)` y el evento se perdia: 2 de 1000 trials de
# test-journal-race.sh en macOS con 4 corridas en paralelo, y una vez en macos-latest (CI
# 38756506567). Esa prueba solo lo ve por azar; esta abre el hueco a proposito.
#
#   A) emit nuevo: en el instante entre crear y escribir, pending/ no tiene ningun .json, y un
#      compactador que corre justo ahi no aparta nada. Al final el pendiente esta en _pendientes.md.
#   B) emisor viejo (escribe directo el .json): un .json vacio y reciente se queda en pending/;
#      con mtime de hace 120 s va a cuarentena malformed; con mtime una hora en el futuro, tambien
#      (nada se queda en pending/ para siempre).
#   C) temporal huerfano de un emit que murio: reciente se respeta; con mas de 60 s se borra.
#   D) un emit que solo estaba parado (> 60 s) y al que C) le borro el temporal: el rename falla
#      y el evento se reescribe; no se pierde (revisor externo, ronda 1 de 2.63.34).
#
# Uso: bash bin/test-journal-hueco.sh    (sale != 0 si algo falla)

set -u
cd "$(dirname "$0")" || exit 1
PASS=0; FAIL=0
ok()   { echo "  PASS $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
nuevo_mem() {
  local d; d=$(mktemp -d) && [ -d "$d" ] || { echo "mktemp fallo"; exit 1; }
  printf -- '---\ntype: index\n---\n# Pendientes\n\n## Alta prioridad\n\n## Media prioridad\n\n## Baja prioridad\n\n' > "$d/_pendientes.md"
  echo "$d"
}
TMPS=""
trap 'for d in $TMPS; do rm -rf "$d"; done' EXIT
mtime() { python3 -c 'import os,sys,time; p=sys.argv[1]; t=time.time()+float(sys.argv[2]); os.utime(p,(t,t))' "$1" "$2"; }
nq() { ls "$1/.journal/quarantine" 2>/dev/null | grep -c '\.json$'; }

echo "A) emit nuevo, compactador en el hueco"
M=$(nuevo_mem); TMPS="$TMPS $M"
OUT=$(python3 - "$(pwd)/journal-emit.py" "$(pwd)/journal-compact.py" "$M" <<'PYEOF' 2>/dev/null
import importlib.util, io, os, subprocess, sys
emit, compact, mem = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("je", emit); je = importlib.util.module_from_spec(spec)
spec.loader.exec_module(je)
pending = os.path.join(mem, ".journal", "pending")
visto = {}
real_fdopen = os.fdopen
def fdopen_con_hueco(fd, *a, **k):
    fh = real_fdopen(fd, *a, **k)
    real_write = fh.write
    def write(data):
        if "json" not in visto:   # solo la primera escritura: el hueco del evento
            visto["json"] = sorted(n for n in os.listdir(pending) if n.endswith(".json"))
            r = subprocess.run([sys.executable, compact, "--memory-dir", mem, "--quiet"],
                               capture_output=True, text=True)
            visto["rc"] = r.returncode
        return real_write(data)
    fh.write = write
    return fh
je.os.fdopen = fdopen_con_hueco
sys.argv = ["journal-emit.py", "--memory-dir", mem, "--type", "pendiente.add", "--text",
            "item del hueco", "--prioridad", "Media", "--origen", "[[sessions/test]]"]
buf = io.StringIO(); real_out = sys.stdout; sys.stdout = buf
try:
    je.main()
except SystemExit:
    pass
sys.stdout = real_out
print(f"visibles_en_el_hueco={len(visto.get('json', ['?']))} rc={visto.get('rc')} id={buf.getvalue().strip()}")
PYEOF
)
echo "    $OUT"
python3 journal-compact.py --memory-dir "$M" --quiet >/dev/null
case "$OUT" in *"visibles_en_el_hueco=0 rc=0 id=p-"*) ok "en el hueco no hay ningun .json visible";;
  *) fail "en el hueco el evento ya era visible para el compactador ($OUT)";; esac
[ "$(nq "$M")" = 0 ] && ok "nada en cuarentena" || fail "evento en cuarentena: $(cat "$M"/.journal/quarantine/*.reason 2>/dev/null)"
[ "$(grep -c '^- \[ \] item del hueco' "$M/_pendientes.md")" = 1 ] && ok "el pendiente quedo aplicado" \
  || fail "el pendiente se perdio"
[ -z "$(ls -A "$M/.journal/pending" 2>/dev/null)" ] && ok "pending/ queda vacio (sin temporal)" \
  || fail "pending/ no quedo vacio: $(ls -A "$M/.journal/pending")"

echo "B) emisor viejo: .json vacio en pending/"
M=$(nuevo_mem); TMPS="$TMPS $M"; P=$M/.journal/pending; mkdir -p "$P"
: > "$P/1000-viejo-1-0.json"
python3 journal-compact.py --memory-dir "$M" --quiet >/dev/null
[ -f "$P/1000-viejo-1-0.json" ] && [ "$(nq "$M")" = 0 ] && ok "reciente: sigue en pending/, no va a cuarentena" \
  || fail "reciente: el .json vacio fue a cuarentena (se pierde el evento de un emit en curso)"
mtime "$P/1000-viejo-1-0.json" -120
python3 journal-compact.py --memory-dir "$M" --quiet >/dev/null
[ ! -f "$P/1000-viejo-1-0.json" ] && grep -q '^malformed: ' "$M/.journal/quarantine/1000-viejo-1-0.json.reason" 2>/dev/null \
  && ok "120 s: va a cuarentena malformed" || fail "120 s: no fue a cuarentena (se quedaria para siempre)"
: > "$P/1001-futuro-1-0.json"; mtime "$P/1001-futuro-1-0.json" 3600
python3 journal-compact.py --memory-dir "$M" --quiet >/dev/null
[ ! -f "$P/1001-futuro-1-0.json" ] && [ "$(nq "$M")" = 2 ] && ok "mtime en el futuro lejano: va a cuarentena" \
  || fail "mtime en el futuro lejano: sigue en pending/"

echo "C) temporal huerfano"
M=$(nuevo_mem); TMPS="$TMPS $M"; P=$M/.journal/pending; mkdir -p "$P"
echo '{"a"' > "$P/.1002-x-1-0.json.tmp"; echo '{"a"' > "$P/.1003-x-1-0.json.tmp"; mtime "$P/.1003-x-1-0.json.tmp" -120
python3 journal-compact.py --memory-dir "$M" --quiet >/dev/null
[ -f "$P/.1002-x-1-0.json.tmp" ] && ok "temporal reciente: se respeta (emit en curso)" || fail "temporal reciente: se borro"
[ ! -f "$P/.1003-x-1-0.json.tmp" ] && ok "temporal de 120 s: se borra" || fail "temporal de 120 s: sigue ahi"
[ "$(nq "$M")" = 0 ] && ok "un temporal nunca va a cuarentena" || fail "un temporal fue a cuarentena"

echo "D) emit parado: el compactador borro su temporal antes del rename"
M=$(nuevo_mem); TMPS="$TMPS $M"
OUT=$(python3 - "$(pwd)/journal-emit.py" "$M" <<'PYEOF' 2>/dev/null
import importlib.util, io, os, sys
emit, mem = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("je", emit); je = importlib.util.module_from_spec(spec)
spec.loader.exec_module(je)
real_publicar = je.publicar; borrados = []
def publicar_tras_borrar(tmp, path):
    if not borrados:   # la primera vez: lo que haria limpiar_temporales con un emit parado > 60 s
        os.remove(tmp); borrados.append(tmp)
    return real_publicar(tmp, path)
je.publicar = publicar_tras_borrar
sys.argv = ["journal-emit.py", "--memory-dir", mem, "--type", "pendiente.add", "--text",
            "item del emit parado", "--prioridad", "Media", "--origen", "[[sessions/test]]"]
buf = io.StringIO(); real_out = sys.stdout; sys.stdout = buf; rc = 0
try:
    je.main()
except SystemExit as e:
    rc = e.code or 0
sys.stdout = real_out
print(f"borrados={len(borrados)} rc={rc} id={buf.getvalue().strip()}")
PYEOF
)
echo "    $OUT"
python3 journal-compact.py --memory-dir "$M" --quiet >/dev/null
case "$OUT" in *"borrados=1 rc=0 id=p-"*) ok "el emit no falla aunque le borraron el temporal";;
  *) fail "el emit fallo al perder su temporal ($OUT)";; esac
[ "$(grep -c '^- \[ \] item del emit parado' "$M/_pendientes.md")" = 1 ] && ok "el evento del emit parado quedo aplicado" \
  || fail "el evento del emit parado se perdio"

echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
