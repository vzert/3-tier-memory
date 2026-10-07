#!/bin/bash
# sella-huellas: no (solo lee git y el disco; no escribe nada)
# 3-tier-memory plugin: que carpeta del proyecto tiene la memoria, con worktrees de git (2.52.0).
#
# POR QUE EXISTE. Medido el 2026-10-07 (otra sesion, prueba en vivo con
# EnterWorktree): una sesion que entra a un worktree recibe en sus hooks `cwd` = worktree pero
# CLAUDE_PROJECT_DIR = checkout principal. Los hooks leian y escribian la memoria del principal y el
# checkpoint (MEMORY_DIR="memory", relativo) la del worktree: memoria partida. Una sesion LANZADA
# dentro del worktree recibe CLAUDE_PROJECT_DIR = worktree, y con memory/ en .gitignore el worktree
# no tiene memoria. Las dos formas de entrar tienen que llegar a la misma memoria.
#
# REGLA. Una memoria por repo: la del worktree PRINCIPAL. Si DIR esta en un worktree enlazado, se
# toma la misma subcarpeta relativa (`--show-prefix`) dentro del principal y, de ahi hacia arriba
# hasta la raiz del principal, la primera carpeta que tenga memory/. Si ninguna la tiene, DIR sin
# cambios (lo de antes). Fuera de un worktree enlazado, DIR sin cambios: nada cambia para quien no
# usa worktrees.
# Por que no memoria por worktree: el banco f9d (de otro proyecto, 100 corridas x 3 sesiones)
# mide 10 archivos en conflicto por fusion de ramas, y con `merge=union` numeros de regla repetidos
# en 100 de 100 corridas. Opt-out: `memoria_worktree=propia` en memory/.memory-config del principal.
#
# COMO SE DETECTA el worktree enlazado: --git-dir distinto de --git-common-dir, los dos en forma
# absoluta y salidos del mismo git (se comparan cadenas del mismo productor, tambien en Windows).
# El principal es la primera entrada de `git worktree list --porcelain`; si es un repo bare (sin
# arbol), no hay principal y DIR queda sin cambios. Un git sin --path-format (anterior a 2.31) NO
# falla: rev-parse devuelve la opcion como texto; se detecta abajo y DIR queda sin cambios.
#
# Uso:
#   source memory-home.sh; memory_home DIR      -> imprime la carpeta (sin salto final)
#   bash memory-home.sh DIR                     -> igual, con salto final
#   bash memory-home.sh --memory-dir DIR        -> imprime <carpeta>/memory

memory_home() {
  local d="${1:-}" out gd cdir rel main cand
  if [ -z "$d" ] || [ ! -d "$d" ] || ! command -v git >/dev/null 2>&1; then
    printf '%s' "$d"; return 0
  fi
  out=$(git -C "$d" rev-parse --path-format=absolute --git-dir --git-common-dir --show-prefix 2>/dev/null) \
    || { printf '%s' "$d"; return 0; }
  gd=$(printf '%s\n' "$out" | sed -n 1p)
  cdir=$(printf '%s\n' "$out" | sed -n 2p)
  rel=$(printf '%s\n' "$out" | sed -n 3p)
  if [ -z "$gd" ] || [ "$gd" = "$cdir" ]; then
    printf '%s' "$d"; return 0
  fi
  # Un git anterior a 2.31 no conoce --path-format y rev-parse lo DEVUELVE como texto con exit 0
  # (medido en 2.50.1 con una opcion inventada: `--bogus-flag` sale en la primera linea, rc=0).
  # Sin este corte, gd="--path-format=absolute" y todo repo pareceria un worktree enlazado.
  case "$gd" in --*) printf '%s' "$d"; return 0 ;; esac
  main=$(git -C "$d" worktree list --porcelain 2>/dev/null | awk 'NR==1 && /^worktree /{sub(/^worktree /,""); print} NR==2 && /^bare$/{print "BARE"}')
  case "$main" in *BARE*|"") printf '%s' "$d"; return 0 ;; esac
  rel="${rel%/}"
  cand="$main${rel:+/$rel}"
  while :; do
    if [ -d "$cand/memory" ]; then
      if [ -f "$cand/memory/.memory-config" ] && grep -q '^memoria_worktree=propia[[:space:]]*$' "$cand/memory/.memory-config" 2>/dev/null; then
        printf '%s' "$d"; return 0
      fi
      printf '%s' "$cand"; return 0
    fi
    [ "$cand" = "$main" ] && break
    cand=$(dirname "$cand")
    # Nunca por encima del principal (un dirname que no avanza tambien corta).
    case "$cand" in "$main"/*|"$main") ;; *) break ;; esac
  done
  printf '%s' "$d"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  if [ "${1:-}" = "--memory-dir" ]; then
    shift
    printf '%s/memory\n' "$(memory_home "${1:-$PWD}")"
  else
    printf '%s\n' "$(memory_home "${1:-$PWD}")"
  fi
fi
