#!/usr/bin/env bash
# Cada comprobacion editada por portabilidad tiene que FALLAR cuando su codigo se rompe.
#
# Por que existe: el 2026-09-12 se editaron media docena de asertos para que corrieran en Linux y
# en Git Bash —comparar rutas en vez de cadenas, contar CR por bytes en vez de con `grep`, un
# digest portable, un CONTROL reescrito—. Un adversario dio `unfalsified` sobre "no se debilito
# ninguna comprobacion" porque su sandbox no podia mutar nada, y tenia razon en no darlo por bueno:
# un aserto editado que nunca se ha visto fallar no se ha visto funcionar. Dos de las mutaciones de
# la primera pasada no se aplicaron por suposiciones mias sobre el fuente, y de haberme quedado ahi
# habria concluido "vacuo" sobre asertos que si discriminan.
#
# De ahi la regla del arnes: si la suite NO cae, primero se mira si la mutacion llego a aplicarse.
# Cada mutador imprime cuantas sustituciones hizo; CERO significa SIN PROBAR, no aprobado.
#
# Uso:  tools/mutation-check.sh        (exit 0 = todas discriminan)
# Entra en el runner: tarda 13 s, la mitad que las 13 comprobaciones juntas, y un arnes que nadie
# corre se pudre. Si una mutacion deja de aplicarse porque el fuente cambio, esto se pone ROJO con
# "SIN PROBAR" y hay que actualizar el mutador — no es ruido, es que el arnes dejo de verificar lo
# que dice verificar, que es el fallo que este fichero existe para evitar.
#
# sella-huellas: no (trabaja sobre copias en temporales)
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 2
SRC="plugins/3-tier-memory/bin"
MUT="tools/mutaciones"
PEND=0; TOTAL=0

caso() {  # etiqueta | fichero a mutar | mutador | suite | aserto que DEBE caer
  local et="$1" f="$2" m="$3" suite="$4" espera="$5"
  local D; D=$(mktemp -d)/bin; mkdir -p "$D"; cp "$SRC"/* "$D/" 2>/dev/null
  TOTAL=$(( TOTAL + 1 ))
  local n; n=$(python3 "$MUT/$m" "$D/$f" 2>&1)
  case "$n" in
    0\ *) printf '  ?? %-30s LA MUTACION NO SE APLICO (%s) -> SIN PROBAR\n' "$et" "$n"
          PEND=$(( PEND + 1 )); rm -rf "$(dirname "$D")"; return ;;
  esac
  local out rc; out=$(cd "$D" && bash "$D/$suite" 2>&1); rc=$?
  # Un aserto SALTADO no es un aserto vacuo: no llego a correr. En Git Bash el caso "sin jq" se
  # salta porque un `bash.exe` con el PATH reducido no encuentra sus DLL, asi que ahi no hay nada
  # que mutar. Confundir "no evaluable aqui" con "no discrimina" seria acusar al aserto de algo
  # que no hizo — el mismo error que este arnes existe para no cometer. (CI, 2026-09-12.)
  if printf '%s' "$out" | grep -qiE "SKIP.*${espera}"; then
    printf '  -- %-30s no evaluable aqui: %s\n' "$et" \
      "$(printf '%s' "$out" | grep -iE "SKIP.*${espera}" | head -1 | sed 's/^ *//')"
    rm -rf "$(dirname "$D")"; return
  fi
  if [ "$rc" -eq 0 ]; then
    printf '  NO %-30s la suite NO cae (%s) -> el aserto es vacuo\n' "$et" "$n"; PEND=$(( PEND + 1 ))
  elif printf '%s' "$out" | grep -qiE "(FAIL|FALLA).*${espera}"; then
    printf '  ok %-30s cae por «%s» (%s)\n' "$et" "$espera" "$n"
  else
    printf '  ~~ %-30s cae, pero NO por «%s» (%s)\n' "$et" "$espera" "$n"
    printf '%s' "$out" | grep -iE '^\s*(FAIL|FALLA)' | head -2 | sed 's/^/        /'
    PEND=$(( PEND + 1 ))
  fi
  rm -rf "$(dirname "$D")"
}

echo "Cada comprobacion editada, contra su codigo roto"
caso "check_ruta / norm"        resolve-plugin-bin.sh   m_resolver.py        test-plugin-bin-resolver.sh "la estable gana a la prerelease"
caso "CONTROL del resolutor"    test-plugin-bin-resolver.sh m_control.py     test-plugin-bin-resolver.sh "el patron viejo elegia a ciegas"
caso "canon / cabecera_crlf"    normalize-pendientes.py m_crlf_normalize.py  test-normalize-pendientes.sh "crlf"
caso "cr_lineas (mensual)"      journal-compact.py      m_crlf_compact.py    test-monthly-rows.sh        "lineas CRLF no cambia"
caso "huella / md5"             journal-compact.py      m_compact.py         test-expire-reopen.sh       "byte a byte"
caso "norm + SYSTEMROOT"        resolve-project-dir.sh  m_projdir.py         test-resolve-project-dir.sh "el respaldo de python3"
caso "publicacion del .gitignore" journal-compact.py    m_gitignore_publicacion.py test-expire-reopen.sh "fichero ENTERO"
caso "deriva sin lector"        journal-compact.py      m_drift_humano.py    test-expire-reopen.sh       "no se consume"
caso "guarda de la migracion"   journal-compact.py      m_gitignore_migracion.py test-expire-reopen.sh    "NO toca el del usuario"
caso "CRLF de la migracion"     journal-compact.py      m_gitignore_crlf.py  test-expire-reopen.sh       "mismo bloque en CRLF"
caso "applied/ fuera del bloque" journal-compact.py     m_gitignore_applied.py test-expire-reopen.sh     "git IGNORA applied"
caso "re-migracion en bucle"    journal-compact.py      m_gitignore_remigra.py test-expire-reopen.sh     "no re-migra"
caso "tupla de superados (2.21.3)" journal-compact.py   m_gitignore_2213.py  test-expire-reopen.sh       "migra el bloque de 2.21.3"
caso "aviso bajo --quiet"       journal-compact.py      m_migracion_quiet.py test-expire-reopen.sh      "con --quiet el aviso"
caso "aviso a la persona"       session-start.sh        m_migracion_humano.py test-expire-reopen.sh     "canal a la persona"

echo
if [ "$PEND" -eq 0 ]; then echo "LAS EVALUABLES DISCRIMINAN (de $TOTAL)"; else echo "SIN ACLARAR: $PEND de $TOTAL"; fi
exit $(( PEND > 0 ))
