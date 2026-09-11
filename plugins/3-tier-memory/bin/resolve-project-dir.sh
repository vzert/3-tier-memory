#!/bin/bash
# sella-huellas: no (solo resuelve CLAUDE_PROJECT_DIR y bufferiza stdin)
# Resolve CLAUDE_PROJECT_DIR from hook stdin if not set in environment
# Sourced by: all hook scripts in bin/
# Buffers stdin into $_HOOK_INPUT for downstream use
#
# DOS PROPIEDADES QUE ESTE FICHERO DEBE MANTENER, porque las dos se rompieron (v2.14.3):
#
# 1. SE PUEDE SOURCEAR BAJO `set -u`. Antes referenciaba $CLAUDE_PLUGIN_ROOT y $CLAUDE_PROJECT_DIR
#    sin proteger: con -u, el hook moria en la primera linea util y se veia igual que "el hook no
#    hace nada". Mordio al escribir bash-journal-nudge.sh, que acabo sin `set -u` por eso. Todas
#    las lecturas usan ${VAR:-} y las dos variables quedan ASIGNADAS al salir (aunque sea vacias),
#    porque los ocho llamantes las usan despues del source y tambien pueden llevar -u.
#
# 2. NO SE CUELGA SIN STDIN. Antes hacia `_HOOK_INPUT=$(cat)`, que espera EOF para siempre. Claude
#    Code siempre manda el JSON y lo cierra, asi que en produccion no se vio; lo que colgaba era
#    toda prueba manual, y dos veces se diagnostico como "el script no imprime nada". Ahora:
#      - stdin es un terminal  -> no se lee nada, vuelve al instante;
#      - stdin es tuberia      -> se espera al PRIMER byte como mucho HOOK_STDIN_TIMEOUT (5 s), y
#                                 si llega se lee hasta EOF sin limite.
#    Dos cosas distintas, que la ronda 8 encontro mezcladas en esta frase:
#      - Lo que el tope CUBRE no se ha observado nunca: ningun productor real abre la tuberia y no
#        manda jamas el primer byte. El tope existe porque es lo unico que hace esta propiedad
#        falsable sin un pty (la prueba usa un fifo que nadie escribe).
#      - Lo que el tope PUEDE CAUSAR si se pone mal si esta medido: acotar la lectura entera trunca
#        (los 0 bytes de abajo). Por eso acota solo la ESPERA INICIAL, nunca un mensaje en camino.
#    En el camino normal el primer byte ya esta ahi y no cuesta nada.
#
# COMO: el tope cubre SOLO el primer byte; el resto lo lee `cat`, sin limite.
#   - `read -n 1` para en el primer byte. `-d ''` ademas quita al salto de linea su papel de
#     delimitador, asi que un primer byte que sea `\n` se guarda en vez de desaparecer.
#   - si ese byte llega, `$(cat)` vacia el resto: mismo rendimiento y mismo recorte de saltos
#     finales que el `$(cat)` de antes, o sea que el valor que reciben los llamantes no cambia.
#   - si NO llega, se sale con `_HOOK_INPUT` vacio. El `cat` tiene que quedar DENTRO del `if`:
#     llamarlo despues de un tope agotado se cuelga exactamente igual que el codigo viejo (medido).
# POR QUE NO SE ACOTA LA LECTURA ENTERA. La primera version de este arreglo lo hacia
# (`read -r -d '' -t 5`, que lee hasta NUL o sea hasta EOF). MEDIDO en el bash 3.2 de macOS con un
# productor que manda 300 bytes, para 4 s y manda el resto: con el tope en 2 s, `read -r -d ''`
# deja **0 bytes** — y rompe la tuberia del que escribe. O sea que TRUNCA un mensaje que si esta
# llegando, y un JSON a medias es otra vez "el hook no hizo nada", justo el fallo que este fichero
# existe para quitar. No es teorico: `journal-guard.sh` es PreToolUse de Write y `tool_input.content`
# trae el fichero entero, megabytes, que no llegan en un solo trozo. Con la forma de arriba, ese
# mismo productor entrega los 619 bytes completos, igual que el `$(cat)` de antes.

_HOOK_INPUT=""
if [ ! -t 0 ]; then
  if IFS= read -r -d '' -n 1 -t "${HOOK_STDIN_TIMEOUT:-5}" _first; then
    _HOOK_INPUT="$_first$(cat)"
  fi
  unset _first
fi

# Resolve CLAUDE_PLUGIN_ROOT from script path if not in environment
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
fi

if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  if [ -n "$_HOOK_INPUT" ]; then
    if command -v jq >/dev/null 2>&1; then
      CLAUDE_PROJECT_DIR=$(printf '%s' "$_HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null) || true
    else
      CLAUDE_PROJECT_DIR=$(printf '%s' "$_HOOK_INPUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null) || true
    fi
  fi
  # Sin stdin utilizable no hay ruta que resolver, pero la variable queda definida: un llamante
  # con `set -u` la referencia justo despues del source.
  CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
fi
