#!/bin/bash
# sella-huellas: no (compuerta de solo lectura; el sellado real lo hace journal-compact.py
# --check-drift, invocado desde aqui, que ya declara el suyo)
# Compuerta barata + disparo de `journal-compact.py --check-drift`, compartida por
# bin/bash-journal-nudge.sh (PostToolUse) y bin/journal-drift-nudge.sh (UserPromptSubmit, v2.24.0).
#
# Un solo sitio para esta logica en vez de dos copias: antes vivia solo en bash-journal-nudge.sh,
# y una correccion ahi (como la de la ronda 6: exigir que `stat` devuelva un entero, ver el
# comentario historico en bash-journal-nudge.sh) no llegaba a ningun otro llamante. Se sourcea,
# no se ejecuta solo.
#
# Uso: `source drift-gate.sh` y luego `drift_gate_check "$MEMORY_DIR" "$(dirname "$0")"`.
# Imprime lo que `--check-drift` imprima (puede ser nada) y no hace nada mas — el llamador decide
# que hacer con la salida; los dos llamantes actuales simplemente la dejan pasar a stdout y
# `exit 0` despues.
drift_gate_check() {
  local MEMORY_DIR="$1" BINDIR="$2"
  local FP="$MEMORY_DIR/.journal/fingerprints.json"
  [ -f "$FP" ] || return 0
  # `find -newer` exige marca ESTRICTAMENTE posterior, asi que en un sistema con mtime de 1 s una
  # escritura en el mismo segundo que el sellado empata y no se ve. Se compara `>=` con stat.
  # GNU se prueba primero (BSD no tiene `-c`, asi que alli falla y cae a `-f`); se EXIGE que la
  # salida sea un entero, porque una utilidad que responde otra cosa vale lo mismo que no estar.
  # Historia completa de por que esto costo una ronda entera: bash-journal-nudge.sh, ronda 6.
  _entero() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
  _mt() {
    local m
    m=$(stat -c %Y "$1" 2>/dev/null); _entero "$m" && { printf '%s' "$m"; return 0; }
    m=$(stat -f %m "$1" 2>/dev/null); _entero "$m" && { printf '%s' "$m"; return 0; }
    return 1
  }
  local FPM NEWER f m NF NH
  FPM=$(_mt "$FP")
  if [ -n "$FPM" ]; then
    NEWER=""
    for f in "$MEMORY_DIR"/_*.md "$MEMORY_DIR"/pendientes/2*.md; do
      [ -f "$f" ] || continue
      m=$(_mt "$f"); [ -n "$m" ] || continue
      [ "$m" -ge "$FPM" ] && { NEWER=1; break; }
    done
    # Un indice BORRADO no tiene mtime que comparar: si el numero de ficheros no cuadra con el de
    # huellas selladas, hay que mirar igual.
    if [ -z "$NEWER" ]; then
      NF=$(ls "$MEMORY_DIR"/_*.md "$MEMORY_DIR"/pendientes/2*.md 2>/dev/null | wc -l | tr -d ' ')
      NH=$(grep -c '": "' "$FP" 2>/dev/null || echo 0)
      [ "$NF" != "$NH" ] && NEWER=1
    fi
    [ -z "$NEWER" ] && return 0
  fi
  python3 "$BINDIR/journal-compact.py" --memory-dir "$MEMORY_DIR" --check-drift 2>/dev/null
  return 0
}
