#!/usr/bin/env bash
# Falla si algun fichero TRACKEADO coincide con una regla de `.gitignore`.
#
# Por que existe: el commit 4f5b3d3 (2026-04-02) declaro la intencion —"gitignore memory/ — keep
# dev memory local only"— y CUATRO DIAS despues 1b4b0a5 metio `memory/learnings/3tier-memory-
# system.md` en el indice dentro de un commit sobre un arreglo del backfill. Dos session logs
# entraron igual el 2026-09-11. `.gitignore` no des-trackea lo ya trackeado, asi que esos tres
# ficheros se publicaron en el repo publico en cada push desde abril hasta el 2026-09-12.
# La prueba de que fue accidente y no politica: habia 45 session logs y solo 2 trackeados.
#
# Lo cazo un adversario externo al revisar un push, no una prueba. De ahi este guard.
#
# El detalle que lo hacia invisible: `git check-ignore` SALTA los ficheros trackeados por defecto,
# asi que la comprobacion ingenua da limpio siempre. Hace falta `--no-index`.
#
# sella-huellas: no (solo lee el indice y .gitignore)
set -u
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "no es un repo git" >&2; exit 2; }

SUCIOS=$(git ls-files | git check-ignore --no-index --stdin 2>/dev/null)

if [ -n "$SUCIOS" ]; then
  {
    echo "FICHEROS TRACKEADOS QUE .gitignore EXCLUYE — se publican en cada push:"
    printf '%s\n' "$SUCIOS" | sed 's/^/    /'
    echo
    echo "Si es deliberado: documenta la excepcion (quita la regla o anade un ! en .gitignore)."
    echo "Si no lo es:      git rm --cached <fichero>   (lo conserva en disco)"
  } >&2
  exit 1
fi
echo "OK: ningun fichero trackeado esta excluido por .gitignore"
