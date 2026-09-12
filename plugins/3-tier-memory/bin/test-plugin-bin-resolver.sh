#!/usr/bin/env bash
# Pruebas de resolve-plugin-bin.sh (2.18.1).
#
# Que cierra: los comandos localizaban sus scripts con
#   find "$HOME/.claude/plugins" -name "X.py" -path "*/3-tier-memory/*" | head -1
# y el orden de `find` no es por version. Medido 2026-09-11 en una instalacion con 14 versiones
# en el cache: devolvio la 2.13.2 con la 2.17.1 instalada, asi que un checkpoint habria escrito
# los indices con scripts cuatro versiones viejos, en silencio.
#
# Cada caso lleva su CONTROL con el patron viejo sobre el mismo arbol: sin eso, una prueba que
# pasa no dice si el resolutor discrimina o si el arbol era facil.
#
# Uso: test-plugin-bin-resolver.sh   (exit 0 = todo verde)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ [ "$2" = "$3" ] && ok "$1" || { bad "$1"; printf '       esperado: %s\n       real:     %s\n' "$3" "$2"; }; }

# Comparacion de RUTAS, no de cadenas. En Git Bash conviven dos dialectos para el MISMO directorio:
# la forma MSYS (/tmp/x) que construye el shell, y la nativa (C:/Users/.../Temp/x) que sale cuando
# esa ruta cruza hacia un .exe como argumento o variable de entorno. El resolutor devolvia la misma
# carpeta en la otra forma y el aserto la daba por distinta: 2 de 19 fallaban por la ortografia de
# la ruta, no por la eleccion. Medido en CI el 2026-09-12. `cygpath -m` lleva ambas a la forma
# nativa con barras normales; fuera de Windows no existe y esto no toca nada.
norm() { command -v cygpath >/dev/null 2>&1 && cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
check_ruta(){ check "$1" "$(norm "$2")" "$(norm "$3")"; }

# Arbol falso: dos versiones en el cache donde `sort` alfabetico se equivoca (2.9.0 > 2.10.0)
# y el clon del marketplace, que es el que `find` devolvia primero en la instalacion real.
H="$TMP/home"
for v in 2.9.0 2.10.0; do
  mkdir -p "$H/.claude/plugins/cache/mkt/3-tier-memory/$v/bin"
  : > "$H/.claude/plugins/cache/mkt/3-tier-memory/$v/bin/journal-emit.py"
  : > "$H/.claude/plugins/cache/mkt/3-tier-memory/$v/bin/resolve-plugin-bin.sh"
done
mkdir -p "$H/.claude/plugins/marketplaces/mkt/plugins/3-tier-memory/bin"
: > "$H/.claude/plugins/marketplaces/mkt/plugins/3-tier-memory/bin/journal-emit.py"

echo "1. con installed_plugins.json gana la version INSTALADA, no la mas alta del cache"
cat > "$H/.claude/plugins/installed_plugins.json" <<'EOF'
{"plugins": {"3-tier-memory@mkt": [{"scope": "user", "version": "2.9.0",
  "installPath": "PLACEHOLDER/.claude/plugins/cache/mkt/3-tier-memory/2.9.0"}]}}
EOF
python3 - "$H/.claude/plugins/installed_plugins.json" "$H" <<'PY'
import sys
p, h = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8").read().replace("PLACEHOLDER", h)
open(p, "w", encoding="utf-8").write(t)
PY
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H" bash "$BIN/resolve-plugin-bin.sh")
check_ruta "devuelve la instalada (2.9.0)" "$GOT" "$H/.claude/plugins/cache/mkt/3-tier-memory/2.9.0/bin"
# El patron viejo no es "siempre mal": es ARBITRARIO. Que su `head -1` coincida o no con la version
# instalada depende del orden del sistema de ficheros. La primera version de este CONTROL afirmaba
# "devuelve otra cosa" y paso en macOS por suerte: el CI lo puso en Linux el 2026-09-12 y ahi el
# find devolvio justo la instalada, asi que fallo. Lo comprobable de verdad no es el resultado sino
# la AUSENCIA DE CRITERIO: habiendo mas de una candidata, `head -1` elige sin mirar la version.
_N=$(find "$H/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | wc -l | tr -d " ")
check "CONTROL: el patron viejo elegia a ciegas entre >1 candidata" \
  "$([ "${_N:-0}" -ge 2 ] && echo si || echo no)" "si"

echo "1b. entre VARIAS entradas instaladas gana la version mas alta, y una prerelease pierde"
# Adversario ronda 2: `clave()` tomaba TODOS los digitos de cada parte, asi que "0-rc1" valia 1 y
# 2.18.0-rc1 salia por encima de 2.18.0. Ahora cuentan los digitos de cabecera y el sufijo baja.
for v in 2.18.0 2.18.0-rc1; do
  mkdir -p "$H/.claude/plugins/cache/mkt2/3-tier-memory/$v/bin"
  : > "$H/.claude/plugins/cache/mkt2/3-tier-memory/$v/bin/journal-emit.py"
done
python3 - "$H" <<'PY'
import json, sys, os
h = sys.argv[1]
base = h + "/.claude/plugins/cache/mkt2/3-tier-memory"
d = {"plugins": {"3-tier-memory@a": [{"version": "2.18.0-rc1",
                                      "installPath": base + "/2.18.0-rc1"}],
                 "3-tier-memory@b": [{"version": "2.18.0",
                                      "installPath": base + "/2.18.0"}]}}
json.dump(d, open(h + "/.claude/plugins/installed_plugins.json", "w"))
PY
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H" bash "$BIN/resolve-plugin-bin.sh")
check_ruta "la estable gana a la prerelease" "$GOT" "$H/.claude/plugins/cache/mkt2/3-tier-memory/2.18.0/bin"

echo "1c. una entrada scope=project de OTRO proyecto no puede estar activa aqui: se excluye"
# Adversario externo ronda 1, H6, reproducido 2026-09-12 con manifiesto. Sin el filtro, una
# entrada `project` de otro proyecto ganaba por version: el texto del comando venia de la version
# instalada aqui y los scripts que invocaba eran de otra instalacion.
H3="$TMP/ambitos"
mkdir -p "$H3/.claude/plugins/cache/mkt/3-tier-memory/1.0.0/bin" \
         "$H3/inst/2.18.0/bin" "$H3/inst/2.20.0/bin" \
         "$H3/ACTUAL" "$H3/OTRO/sub/dir" "$H3/OTRO-bis"
: > "$H3/.claude/plugins/cache/mkt/3-tier-memory/1.0.0/bin/journal-emit.py"
: > "$H3/inst/2.18.0/bin/journal-emit.py"
: > "$H3/inst/2.20.0/bin/journal-emit.py"
# El manifiesto lo lee un python NATIVO. En Git Bash el `cwd` que le pasamos como argumento llega
# ya convertido a la forma de Windows, asi que si el `projectPath` del JSON se queda en forma MSYS
# no hay contencion que cuadre y una entrada legitima se excluia. Se escriben en forma nativa, que
# ademas es la que tiene un `installed_plugins.json` de verdad en esa plataforma.
manifiesto() {   # $1 = json con PLACEHOLDER por $H3
  printf '%s' "$1" | sed "s#PLACEHOLDER#$(norm "$H3")#g" > "$H3/.claude/plugins/installed_plugins.json"
}
resolver() {     # $1 = cwd desde el que se resuelve
  ( cd "$1" && env -u CLAUDE_PLUGIN_ROOT HOME="$H3" bash "$BIN/resolve-plugin-bin.sh" )
}
DOS='{"plugins":{"3-tier-memory@mkt":[
 {"scope":"user","version":"2.18.0","installPath":"PLACEHOLDER/inst/2.18.0"},
 {"scope":"project","projectPath":"PLACEHOLDER/OTRO","version":"2.20.0","installPath":"PLACEHOLDER/inst/2.20.0"}]}}'
manifiesto "$DOS"
check_ruta "gana la entrada user, no la project ajena" "$(resolver "$H3/ACTUAL")" "$H3/inst/2.18.0/bin"
# CONTROL: la regla vieja era "la mas alta gana" sin mirar el ambito.
VIEJO=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["plugins"]
c = [e for v in d.values() for e in v]
print(max(c, key=lambda e: e["version"])["installPath"] + "/bin")
' "$H3/.claude/plugins/installed_plugins.json")
check_ruta "CONTROL: sin el filtro ganaba la ajena" "$VIEJO" "$H3/inst/2.20.0/bin"

echo "1d. la misma entrada project SI vale desde su proyecto, y desde un subdirectorio suyo"
# Se comparan componentes de ruta: el cwd puede ser un subdirectorio del projectPath (un comando
# no siempre corre en la raiz), pero /OTRO-bis NO esta dentro de /OTRO aunque lo tenga de prefijo.
check_ruta "desde su propio proyecto" "$(resolver "$H3/OTRO")" "$H3/inst/2.20.0/bin"
check_ruta "desde un subdirectorio del proyecto" "$(resolver "$H3/OTRO/sub/dir")" "$H3/inst/2.20.0/bin"
check_ruta "un prefijo de texto no es estar dentro" "$(resolver "$H3/OTRO-bis")" "$H3/inst/2.18.0/bin"

echo "1e. scope=project SIN projectPath se conserva: no se puede probar que sea ajena"
manifiesto '{"plugins":{"3-tier-memory@mkt":[
 {"scope":"user","version":"2.18.0","installPath":"PLACEHOLDER/inst/2.18.0"},
 {"scope":"project","version":"2.20.0","installPath":"PLACEHOLDER/inst/2.20.0"}]}}'
check_ruta "sigue ganando la mas alta" "$(resolver "$H3/ACTUAL")" "$H3/inst/2.20.0/bin"

echo "1f. si al filtrar no queda ninguna candidata, se cae al cache (no a la ajena)"
manifiesto '{"plugins":{"3-tier-memory@mkt":[
 {"scope":"project","projectPath":"PLACEHOLDER/OTRO","version":"2.20.0","installPath":"PLACEHOLDER/inst/2.20.0"}]}}'
check_ruta "cae al cache" "$(resolver "$H3/ACTUAL")" "$H3/.claude/plugins/cache/mkt/3-tier-memory/1.0.0/bin"

echo "2. sin installed_plugins.json, la mas alta POR VERSION (no alfabetica)"
mv "$H/.claude/plugins/installed_plugins.json" "$TMP/guardado.json"
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H" bash "$BIN/resolve-plugin-bin.sh")
check_ruta "2.10.0 gana a 2.9.0" "$GOT" "$H/.claude/plugins/cache/mkt/3-tier-memory/2.10.0/bin"

echo "3. un installed_plugins.json ilegible no rompe nada: cae al cache"
printf 'esto no es json' > "$H/.claude/plugins/installed_plugins.json"
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H" bash "$BIN/resolve-plugin-bin.sh")
check_ruta "sigue resolviendo" "$GOT" "$H/.claude/plugins/cache/mkt/3-tier-memory/2.10.0/bin"

echo "4. CLAUDE_PLUGIN_ROOT manda sobre todo lo demas (es el plugin que CORRE)"
mkdir -p "$TMP/corriendo/bin"; : > "$TMP/corriendo/bin/journal-emit.py"
GOT=$(CLAUDE_PLUGIN_ROOT="$TMP/corriendo" HOME="$H" bash "$BIN/resolve-plugin-bin.sh")
check_ruta "devuelve el que corre" "$GOT" "$TMP/corriendo/bin"

echo "5. corriendo desde el propio bin sin nada instalado: se devuelve a si mismo"
H2="$TMP/vacio"; mkdir -p "$H2"
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H2" bash "$BIN/resolve-plugin-bin.sh" 2>/dev/null); RC=$?
check "codigo de salida 0" "$RC" "0"
check_ruta "devuelve su propio directorio" "$GOT" "$BIN"

echo "6. sin plugin por ningun lado: no imprime ruta y sale 1"
SOLO="$TMP/solo"; mkdir -p "$SOLO"; cp "$BIN/resolve-plugin-bin.sh" "$SOLO/"
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H2" bash "$SOLO/resolve-plugin-bin.sh" 2>/dev/null); RC=$?
check "codigo de salida 1" "$RC" "1"
check "sin ruta en la salida" "$GOT" ""

echo "7. no queda ningun 'find ... | head -1' vivo en NINGUN comando"
# templates/ Y commands/: el barrido que solo miraba templates/ dejo vivo el de
# commands/migrate.md, y lo encontro el adversario externo (ronda 1, H8). La cobertura de esta
# prueba es la que fallaba, asi que la que se amplia es esta.
VIVOS=$(grep -h 'head -1' "$BIN/../templates/"*.md "$BIN/../commands/"*.md 2>/dev/null \
        | grep -c 'claude/plugins" -name "[a-z-]*\.py"' || true)
check "cero sitios" "${VIVOS:-0}" "0"
check "y hay al menos un comando que SI usa el resolutor" \
  "$([ "$(grep -l 'resolve-plugin-bin.sh' "$BIN/../templates/"*.md "$BIN/../commands/"*.md 2>/dev/null | wc -l | tr -d ' ')" -ge 7 ] && echo si || echo no)" "si"

echo
if [ "$FAIL" -eq 0 ]; then echo "TODO VERDE"; else echo "HAY FALLOS"; fi
exit "$FAIL"
