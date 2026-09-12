#!/usr/bin/env bash
# Imprime el directorio `bin/` del plugin 3-tier-memory INSTALADO.
#
# Lo que SI garantiza: nunca una version arbitraria del cache. Lo que NO: si el plugin llega
# por varios marketplaces o con varios ambitos, cual de ellos es el activo no se deduce de
# `installed_plugins.json` —no se ha verificado que ese fichero lo diga— asi que entre varias
# entradas se elige la de version mas alta. Esa es una eleccion declarada. Con
# `$CLAUDE_PLUGIN_ROOT` puesto (un hook) si es exactamente el que corre.
#
# Por que existe: los comandos usaban
#   find "$HOME/.claude/plugins" -name "journal-emit.py" -path "*/3-tier-memory/*" | head -1
# y el orden de `find` NO es por version. Medido 2026-09-11 en una instalacion con 14 versiones
# en el cache: devolvio la 2.13.2 con la 2.17.1 instalada. Un checkpoint habria escrito los
# indices con scripts cuatro versiones viejos, en silencio — y lo unico que lo delato fue que
# `/plugin` acababa de imprimir la version instalada.
#
# Orden de resolucion, de mas autoritativo a menos:
#   1. $CLAUDE_PLUGIN_ROOT/bin — el plugin que esta corriendo. Lo tienen los hooks.
#   2. installed_plugins.json  — `installPath` de las entradas `3-tier-memory@...`. Dice que
#      versiones estan INSTALADAS, que no es lo mismo que lo que hay en el cache: el cache puede
#      guardar una descarga que no es la activa. Aqui se hacen DOS cosas distintas:
#      a) Se EXCLUYE toda entrada `scope=project` cuyo `projectPath` no contenga el directorio
#         de trabajo. Esa entrada no puede estar activa aqui, sea cual sea la precedencia entre
#         ambitos, asi que excluirla no infiere nada. Sin `projectPath` no se puede probar que
#         sea ajena: se conserva. (Adversario externo ronda 1 H6, reproducido 2026-09-12 con
#         manifiesto: una entrada `project` de OTRO proyecto ganaba por version.)
#      b) Entre las que QUEDAN se toma la de VERSION MAS ALTA. Cual de ellas manda de verdad si
#         el plugin llega por mas de un marketplace no lo resuelve este fichero —no se ha
#         verificado su esquema ni si hay precedencia documentada—, asi que esto sigue siendo
#         una eleccion declarada, no un conocimiento del que esta activo.
#   3. la version mas alta del cache, ordenada por version (`sort -V`), no por orden de `find`.
#   4. el directorio de este propio script.
# Sin nada que resolver: no imprime nada y sale 1.
#
# sella-huellas: no (no escribe: solo imprime una ruta en stdout; no toca ningun indice)
set -u

emit() { [ -d "$1" ] && [ -f "$1/journal-emit.py" ] && { printf '%s\n' "$1"; exit 0; }; }

emit "${CLAUDE_PLUGIN_ROOT:-}/bin"

INSTALLED="${HOME}/.claude/plugins/installed_plugins.json"
if [ -f "$INSTALLED" ]; then
  P=$(python3 -c '
import json, os, sys

def clave(ver):
    # "2.10.0" > "2.9.0": se compara por numeros, no por texto. Y una prerelease va por DEBAJO de
    # su version estable ("2.18.0-rc1" < "2.18.0"): se toman los digitos de CABECERA de cada parte
    # —no todos, que convertia "0-rc1" en 1 y la ponia por encima— y el sufijo baja el empate.
    nums, estable = [], 1
    for parte in str(ver or "0").split("."):
        cab = ""
        for c in parte:
            if not c.isdigit():
                break
            cab += c
        nums.append(int(cab) if cab else 0)
        if cab != parte:
            estable = 0
    return (nums, estable)

def real(ruta):
    try:
        return os.path.realpath(str(ruta))
    except Exception:
        return ""

def aqui(e, cwd):
    # Una entrada `scope=project` cuyo `projectPath` no CONTIENE el directorio de trabajo no
    # puede estar activa aqui: se excluye. Sin `projectPath` —o sin cwd— no se puede probar que
    # sea ajena, asi que se conserva. Se comparan componentes de ruta, no prefijos de texto:
    # startswith a secas haria que /foo-bar casara con /foo.
    if str(e.get("scope") or "") != "project":
        return True
    pp = real(e.get("projectPath") or "")
    if not pp or not cwd:
        return True
    return cwd == pp or cwd.startswith(pp + os.sep)

try:
    d = json.load(open(sys.argv[1], encoding="utf-8")).get("plugins") or {}
except Exception:
    sys.exit(0)
cwd = real(sys.argv[2]) if len(sys.argv) > 2 else ""
cands = []
for k, v in (d.items() if isinstance(d, dict) else []):
    if str(k).split("@")[0] != "3-tier-memory":
        continue
    for e in (v if isinstance(v, list) else [v]):
        if isinstance(e, dict) and e.get("installPath") and aqui(e, cwd):
            cands.append((clave(e.get("version")), e["installPath"]))
if cands:
    print(max(cands)[1])
' "$INSTALLED" "$PWD" 2>/dev/null) || P=""
  [ -n "$P" ] && emit "$P/bin"
fi

CACHE="${HOME}/.claude/plugins/cache"
if [ -d "$CACHE" ]; then
  # sort -V ordena 2.9.0 < 2.10.0, que es justo donde `sort` normal se equivoca.
  while IFS= read -r d; do emit "$d"; done < <(
    find "$CACHE" -type d -path '*/3-tier-memory/*/bin' 2>/dev/null | sort -V -r)
fi

emit "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
exit 1
