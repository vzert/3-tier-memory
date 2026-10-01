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
# Entra en el runner, y un arnes que nadie corre se pudre. Tarda ~2,5 min (medido 2026-09-29: 94 s
# con los 15 primeros casos, 125 s con los 24 del contrato de 2.41.4; 2026-09-30: 147 s con los 4
# de escalada a persona; el "13 s" de antes ya no valia). Si una mutacion deja de aplicarse porque el fuente cambio, esto se pone ROJO con
# "SIN PROBAR" y hay que actualizar el mutador — no es ruido, es que el arnes dejo de verificar lo
# que dice verificar, que es el fallo que este fichero existe para evitar.
#
# sella-huellas: no (trabaja sobre copias en temporales)
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 2
SRC="plugins/3-tier-memory/bin"
MUT="tools/mutaciones"
PEND=0; TOTAL=0

caso() {  # etiqueta | fichero a mutar | mutador | suite | aserto que DEBE caer | [arg del mutador]
  local et="$1" f="$2" m="$3" suite="$4" espera="$5" arg="${6:-}"
  local D; D=$(mktemp -d)/bin; mkdir -p "$D"; cp "$SRC"/* "$D/" 2>/dev/null
  # templates/ y commands/ junto a bin/, como en el plugin: test-project-dir-fallback.sh recorre el
  # arbol real (seccion H) y sin ellos caia en CADA copia, mutada o no. Con la suite en rojo de
  # base, "NO ... vacuo" no podia salir nunca y solo el filtro de `espera` separaba los casos.
  cp -R "$SRC/../templates" "$SRC/../commands" "$(dirname "$D")/" 2>/dev/null
  # bin/fixtures/ (carpeta): `cp "$SRC"/*` solo copia ficheros, y test-checkpoint-close-guard.sh lee
  # sus transcripts de ahi. Sin ella esa suite caia sin mutar y el control salia "cae" (2.43.0).
  cp -R "$SRC/fixtures" "$D/" 2>/dev/null
  TOTAL=$(( TOTAL + 1 ))
  local n; n=$(python3 "$MUT/$m" "$D/$f" ${arg:+"$arg"} 2>&1)
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
caso "aviso a la persona"       journal-compact.py      m_migracion_humano.py test-expire-reopen.sh     "canal a la persona"

echo
echo "Cierre al final (2.43.0): el snippet va despues de la revision del cierre"
caso "cierre diferido" checkpoint-close-guard.sh m_cierre_final.py test-checkpoint-close-guard.sh "no reclama el snippet como falta" diferido-apagado
caso "orden tras la revision" checkpoint-close-guard.sh m_cierre_final.py test-checkpoint-close-guard.sh "avisa que el snippet no esta despues de la revision" orden-apagado
caso "anexo al usuario" checkpoint-close-guard.sh m_cierre_final.py test-checkpoint-close-guard.sh "y le ensena el cierre al usuario" sin-anexo
caso "cola tras el cierre" checkpoint-close-guard.sh m_cierre_final.py test-checkpoint-close-guard.sh "reclama la cola" sin-cola
echo
echo "Capas y emojis del cierre (2.44.0): cada pieza, apagada, tumba su aserto"
caso "➕ solo en el caso 5" print-pendiente-opcional.py m_capas_cierre.py test-print-pendiente-opcional.sh "snippet completo y nada vence hoy" capa3-sin-gate
caso "🔔 solo _revisar = hoy" print-pendiente-opcional.py m_capas_cierre.py test-print-pendiente-opcional.sh "el que vence hoy" hoy-incluye-vencidos
caso "🔔 uno cada vez" print-pendiente-opcional.py m_capas_cierre.py test-print-pendiente-opcional.sh "uno solo" hoy-sin-tope
caso "cabecera 🔁 del snippet" print-como-retomar.py m_capas_cierre.py test-print-como-retomar.sh "empieza con la cabecera" sin-cabecera-retomar
caso "🗓️ sin fence" print-recordatorios.py m_capas_cierre.py test-print-recordatorios.sh "sin fences" calendario-con-fence
caso "el hook exige el emoji" checkpoint-close-guard.sh m_capas_cierre.py test-checkpoint-close-guard.sh "reclama el snippet sin emoji" emoji-no-exigido
caso "recomendacion con dueno" checkpoint-audit.py m_capas_cierre.py test-checkpoint-audit.sh "avisa del research" reco-sin-dueno-pasa

echo "Contrato de check-project-dir-fallback.py (2.41.4): cada pieza, rota, tumba su aserto"
caso "verde respaldo" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " respaldo: exit 0" r1-sin-quitar-forma
caso "R1 apagada" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " encoded: fallos" r1-apagada
caso "forma R1 floja" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " llaves: fallos" forma-r1-floja
caso "canonica ignorada" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " canonica: exit 0" canonica-ignorada
caso "canonica en cualquier linea" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " canonica-no-primera: fallos" canonica-en-cualquier-linea
caso "canonica con comentario" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " canonica-con-comentario: fallos" canonica-con-comentario
caso "usos posteriores libres" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " despues-de-canonica: fallos" usos-posteriores-libres
caso "\${PROJECT_DIR sin }" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " despues-de-canonica: fallos" llave-sin-cerrar
caso "R3 apagada" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " comentario-con-dolar: fallos" r3-apagada
caso "R3 sin backtick" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " comentario-con-dolar: fallos" r3-sin-backtick
caso "R2 en comentario apagada" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " comentario-en-heredoc: fallos" r2-en-comentario-apagada
caso "bloques sin etiqueta fuera" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " sin-etiqueta: fallos" sin-etiqueta-fuera
caso "sin bloques" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " mkdir: fallos" sin-bloques
caso "strip() en vez de BLANCO" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " canonica-tab-vertical: fallos" strip-en-vez-de-blanco
caso "canonica insegura" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " canonica en bash" canonica-insegura
caso "R4 apagada" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " ifs: fallos" r4-apagada
caso "sin unir lineas" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " partido-r1: fallos" sin-unir-lineas
caso "barra par tambien une" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " barra-doble: exit 0" barra-par-une
caso "comentario continua" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " comentario-no-continua: fallos" comentario-continua
caso "continuada como comentario" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " comentario-tras-continuacion: fallos" continuada-como-comentario
caso "open() sin newline=''" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " crlf: fallos" sin-newline-vacio
caso "R4 solo IFS" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " opciones: fallos" r4-solo-ifs
caso "R4 sin set" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " opciones: fallos" r4-sin-set
caso "R4 sin options" check-project-dir-fallback.py m_contrato_projdir.py test-project-dir-fallback.sh " opciones: fallos" r4-sin-options

echo
echo "Escalada a persona (p-667f76a40e): sin el rotulo o sin la llamada, el aviso no llega a systemMessage"
caso "rotulo fuera-de-banda" journal-compact.py m_escalada_humana.py test-expire-reopen.sh "el texto a la persona nombra git pull" rotulo-fuera-de-banda
caso "rotulo linea-base-ilegible" journal-compact.py m_escalada_humana.py test-linea-base-corrupta.sh "SI lo entrega .systemMessage nombra la corrupcion" rotulo-linea-base-ilegible
caso "llamada con JOURNAL_OUT" session-start.sh m_escalada_humana.py test-expire-reopen.sh "el canal a la persona lo lleva" llamada-journal-out
caso "llamada con DRIFT_OUT" session-start.sh m_escalada_humana.py test-expire-reopen.sh "el texto a la persona nombra git pull" llamada-drift-out

echo
if [ "$PEND" -eq 0 ]; then echo "LAS EVALUABLES DISCRIMINAN (de $TOTAL)"; else echo "SIN ACLARAR: $PEND de $TOTAL"; fi
exit $(( PEND > 0 ))
