#!/bin/bash
# Prueba de `snippet.paso_compartido` en checkpoint-audit.py (2.63.22).
#
# Que tiene que cumplir, y por que:
# - Caso real (2026-10-20): dos sesiones de un mismo proyecto cerraron con 23 s de diferencia y
#   las dos dejaron el mismo `p-…` como `Proximo paso`. bin/fixtures/paso-compartido/ tiene dos
#   cierres con esa forma y texto inventado (el repo es publico). El audit avisa en cada una,
#   nombrando la otra.
# - Es POR-DISEÑO, nunca SALTADO: viaja en la revision del cierre y no suma un rechazo (decision
#   de Victor, d267). Lo que lee el hook de cierre es el estado del --json.
# - Solo cuenta el mismo dia y el campo `Proximo paso`; un `ninguno` no es un paso.
set -e
BIN="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok  $1"; else fail=$((fail+1)); echo "  FALLA $1: esperaba '$2', salio '$3'"; fi; }

M="$T/memory"
A=2026-10-20-demo-banco-retomar
B=2026-10-20-demo-id-modal
armar() { rm -rf "$M"; cp -R "$BIN/fixtures/paso-compartido" "$M"; }
estado() {  # estado SLUG -> "ESTADO|lineas" de snippet.paso_compartido, o "ausente"
  python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$1.md" --no-git --hoy 2026-10-20 \
    --solo-snippet --json | python3 -c '
import json, sys
x = [h for h in json.load(sys.stdin) if h["clave"] == "snippet.paso_compartido"]
print(x[0]["estado"] + "|" + " / ".join(x[0].get("lineas") or []) if x else "ausente")'
}

echo "== 1. los dos cierres del mismo dia: cada uno avisa y nombra al otro =="
armar
chk "la segunda ficha avisa por la primera" \
  "POR-DISEÑO|p-5e5e5e5e5e ya es el \`Proximo paso\` de memory/sessions/$A.md" "$(estado "$B")"
chk "la primera avisa por la segunda" \
  "POR-DISEÑO|p-5e5e5e5e5e ya es el \`Proximo paso\` de memory/sessions/$B.md" "$(estado "$A")"
chk "el texto humano lo marca como aviso" "1" "$(python3 "$BIN/checkpoint-audit.py" "$M" --session-file "$M/sessions/$B.md" --no-git --hoy 2026-10-20 --solo-snippet | grep -c 'snippet.paso_compartido.*aviso, no bloquea')"

echo "== 2. sin la otra ficha: HECHO =="
armar; rm "$M/sessions/$A.md"
chk "solo una" "HECHO|" "$(estado "$B")"

echo "== 3. la otra es de otro dia: HECHO =="
armar; mv "$M/sessions/$A.md" "$M/sessions/2026-10-19-demo-vieja.md"
chk "otro dia" "HECHO|" "$(estado "$B")"

echo "== 4. la otra deja otro paso: HECHO =="
armar
python3 -c 'import sys;p=sys.argv[1];t=open(p,encoding="utf-8").read();open(p,"w",encoding="utf-8").write(t.replace("p-5e5e5e5e5e","p-0000000000"))' "$M/sessions/$A.md"
chk "otro id" "HECHO|" "$(estado "$B")"

echo "== 5. el id solo en la linea de extras de la otra: no cuenta =="
armar
python3 - "$M/sessions/$A.md" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = re.sub(r"^Proximo paso: .*$", "Proximo paso: otra cosa (p-0000000000).\n\n"
           "Si ese paso es corto, suma en la misma sesion: p-5e5e5e5e5e (Media).", t, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(t)
PY
chk "el id sigue en la otra ficha (el caso discrimina)" "1" "$(grep -c '^Si ese paso es corto, suma en la misma sesion: p-5e5e5e5e5e' "$M/sessions/$A.md")"
chk "solo en extras" "HECHO|" "$(estado "$B")"

echo "== 6. esta ficha cierra con ninguno: no aplica =="
armar
python3 - "$M/sessions/$B.md" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = re.sub(r"^Proximo paso: .*$", "Proximo paso: ninguno — lo lleva la otra sesion (p-5e5e5e5e5e).", t, count=1, flags=re.M)
open(p, "w", encoding="utf-8").write(t)
PY
chk "ninguno" "ausente" "$(estado "$B")"

echo "== 7. ficha anterior al corte (2026-10-19): no aplica =="
armar
for s in "$A" "$B"; do sed -i.bak 's/^date: 2026-10-20$/date: 2026-10-19/' "$M/sessions/$s.md"; rm -f "$M/sessions/$s.md.bak"; done
chk "antes de 2.63.22" "ausente" "$(estado "$B")"

echo "RESULT: pass=$pass fail=$fail"
[ "$fail" = 0 ]
