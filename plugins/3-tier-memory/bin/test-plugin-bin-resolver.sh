#!/usr/bin/env bash
# Pruebas de resolve-plugin-bin.sh (2.18.0).
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

viejo() {   # el patron que se retira, para el control
  dirname "$(find "$1/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" 2>/dev/null | head -1)"
}

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
check "devuelve la instalada (2.9.0)" "$GOT" "$H/.claude/plugins/cache/mkt/3-tier-memory/2.9.0/bin"
check "CONTROL: el patron viejo devolvia otra cosa" \
  "$([ "$(viejo "$H")" = "$GOT" ] && echo igual || echo distinto)" "distinto"

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
check "la estable gana a la prerelease" "$GOT" "$H/.claude/plugins/cache/mkt2/3-tier-memory/2.18.0/bin"

echo "2. sin installed_plugins.json, la mas alta POR VERSION (no alfabetica)"
mv "$H/.claude/plugins/installed_plugins.json" "$TMP/guardado.json"
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H" bash "$BIN/resolve-plugin-bin.sh")
check "2.10.0 gana a 2.9.0" "$GOT" "$H/.claude/plugins/cache/mkt/3-tier-memory/2.10.0/bin"

echo "3. un installed_plugins.json ilegible no rompe nada: cae al cache"
printf 'esto no es json' > "$H/.claude/plugins/installed_plugins.json"
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H" bash "$BIN/resolve-plugin-bin.sh")
check "sigue resolviendo" "$GOT" "$H/.claude/plugins/cache/mkt/3-tier-memory/2.10.0/bin"

echo "4. CLAUDE_PLUGIN_ROOT manda sobre todo lo demas (es el plugin que CORRE)"
mkdir -p "$TMP/corriendo/bin"; : > "$TMP/corriendo/bin/journal-emit.py"
GOT=$(CLAUDE_PLUGIN_ROOT="$TMP/corriendo" HOME="$H" bash "$BIN/resolve-plugin-bin.sh")
check "devuelve el que corre" "$GOT" "$TMP/corriendo/bin"

echo "5. corriendo desde el propio bin sin nada instalado: se devuelve a si mismo"
H2="$TMP/vacio"; mkdir -p "$H2"
GOT=$(env -u CLAUDE_PLUGIN_ROOT HOME="$H2" bash "$BIN/resolve-plugin-bin.sh" 2>/dev/null); RC=$?
check "codigo de salida 0" "$RC" "0"
check "devuelve su propio directorio" "$GOT" "$BIN"

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
