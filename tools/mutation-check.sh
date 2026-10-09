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

# Igual que caso(), pero para un script de tools/ (no de bin/): muta una copia de tools/<f> y corre
# la suite de tools/ con RUN_TESTS apuntando a la copia.
caso_tools() {  # etiqueta | fichero de tools/ | mutador | suite de tools/ | aserto | arg
  local et="$1" f="$2" m="$3" suite="$4" espera="$5" arg="${6:-}"
  local D; D=$(mktemp -d); cp "tools/$f" "$D/$f"
  TOTAL=$(( TOTAL + 1 ))
  local n; n=$(python3 "$MUT/$m" "$D/$f" ${arg:+"$arg"} 2>&1)
  case "$n" in
    0\ *) printf '  ?? %-30s LA MUTACION NO SE APLICO (%s) -> SIN PROBAR\n' "$et" "$n"
          PEND=$(( PEND + 1 )); rm -rf "$D"; return ;;
  esac
  local out rc; out=$(RUN_TESTS="$D/$f" bash "tools/$suite" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  NO %-30s la suite NO cae (%s) -> el aserto es vacuo\n' "$et" "$n"; PEND=$(( PEND + 1 ))
  elif printf '%s' "$out" | grep -qiE "(FAIL|FALLA).*${espera}"; then
    printf '  ok %-30s cae por «%s» (%s)\n' "$et" "$espera" "$n"
  else
    printf '  ~~ %-30s cae, pero NO por «%s» (%s)\n' "$et" "$espera" "$n"
    printf '%s' "$out" | grep -iE '^\s*(FAIL|FALLA)' | head -2 | sed 's/^/        /'
    PEND=$(( PEND + 1 ))
  fi
  rm -rf "$D"
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
caso "cabecera de la revision" checkpoint-close-guard.sh m_capas_cierre.py test-checkpoint-close-guard.sh "la cita no tapa la cabecera" cabecera-rfind
caso "solo Retomamos en color" checkpoint-close-guard.sh m_capas_cierre.py test-checkpoint-close-guard.sh "reclama el fence fuera del snippet" fences-sin-control
caso "fence dentro de una cita" checkpoint-close-guard.sh m_capas_cierre.py test-checkpoint-close-guard.sh "reclama el fence en la cita" fence-sin-cita
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
echo "learning.retire / --supersedes (2.45.0): cada pieza que retira, valida o lee el marcador"
caso "recall sin filtro"       build-recall-index.py m_learning_retire.py test-learning-retire.sh "la retirada con el marcador nuevo no esta" recall-sin-filtro
caso "--por sin validar"       journal-compact.py m_learning_retire.py test-learning-retire.sh "motivo no-anchor que nombra #99" por-sin-validar
caso "ciclo sin detectar"      journal-compact.py m_learning_retire.py test-learning-retire.sh "A por B con B retirada por A: ciclo" ciclo-sin-detectar
caso "update pierde la marca"  journal-compact.py m_learning_retire.py test-learning-retire.sh "texto nuevo \+ el mismo marcador" update-pierde-marca
caso "replay de update"        journal-compact.py m_learning_retire.py test-learning-retire.sh "replay del retire y del update" replay-update-retirada
caso "replay de retire"        journal-compact.py m_learning_retire.py test-learning-retire.sh "replay del retire y del update" retire-replay-sin-numero
caso "QR reutiliza numero"     journal-compact.py m_learning_retire.py test-learning-retire.sh "el numero 3 no se reutiliza" qr-reutiliza-numero
caso "supersedes: QR tarde"    journal-compact.py m_learning_retire.py test-learning-retire.sh "ni la nueva ni la marca se escriben" supersedes-qr-tarde
caso "marca en backticks"      learning_marks.py m_learning_retire.py test-learning-retire.sh "entre comillas invertidas sigue viva" marca-en-backticks
caso "cabecera ignorada"       learning_marks.py m_learning_retire.py test-learning-retire.sh "topic con cabecera retirada" cabecera-ignorada
caso "pie siempre"             recall_rank.py m_learning_retire.py test-learning-retire.sh "sin RECALL_PIE no hay pie" pie-siempre
caso "add no ve la retirada"   journal-compact.py m_learning_retire.py test-learning-retire.sh "replay: una sola regla con ese texto" add-no-ve-retirada
caso "supersedes tras update"  journal-compact.py m_learning_retire.py test-learning-retire.sh "replay del supersedes tras corregir la nueva" supersedes-replay-tras-update
caso "fila antes de validar"   journal-compact.py m_learning_retire.py test-learning-retire.sh "_learnings.md intacto" fila-antes-de-validar
caso "indice viejo se sirve"   recall.sh m_learning_retire.py test-learning-retire.sh "el indice viejo se reconstruyo" indice-viejo-sirve

echo
echo "Dedup al emitir de learning.add (2.47.0): vecinos, bloqueo, forma y learnings.decision"
caso "vecinos por stdout"      journal-emit.py m_learning_dedup.py test-learning-dedup.sh "stdout tiene una sola linea" vecinos-por-stdout
caso "sin bloqueo"             journal-emit.py m_learning_dedup.py test-learning-dedup.sh "casi igual sin --decision: rc 1" sin-bloqueo
caso "solo-vecinos escribe"    journal-emit.py m_learning_dedup.py test-learning-dedup.sh "solo-vecinos: ningun evento" solo-vecinos-escribe
caso "sin identidad"           journal-emit.py m_learning_dedup.py test-learning-dedup.sh "mismo texto sin --decision: rc 0" sin-identidad
caso "decision fuera"          journal-emit.py m_learning_dedup.py test-learning-dedup.sh "la decision viaja en el payload" decision-fuera-del-payload
caso "reemplaza sin supersedes" journal-emit.py m_learning_dedup.py test-learning-dedup.sh "reemplaza:2 lleva supersedes 2" reemplaza-sin-supersedes
caso "corrige sin citar"       journal-emit.py m_learning_dedup.py test-learning-dedup.sh "corrige la #6 en su sitio" corrige-sin-citar
caso "corrige aceptado"        journal-emit.py m_learning_dedup.py test-learning-dedup.sh "corrige:2: rc 1" corrige-aceptado
caso "retirada es vecina"      learning_vecinos.py m_learning_dedup.py test-learning-dedup.sh "casi igual a una RETIRADA" retirada-es-vecina
caso "medida sobre la nueva"   learning_vecinos.py m_learning_dedup.py test-learning-dedup.sh "la primera vecina es #2" medida-sobre-la-nueva
# Disparadores (2.48.0, F4 del plan de ciclo de vida de learnings): cada pieza tiene su aserto.
caso "disparadores sin peso"    recall_rank.py m_learning_disparadores.py test-learning-disparadores.sh "con peso, la regla de las frases gana" sin-peso
caso "frases sin indexar"       build-recall-index.py m_learning_disparadores.py test-learning-disparadores.sh "palabras solo de las frases encuentran" frases-sin-indexar
caso "comentario a la vista"    build-recall-index.py m_learning_disparadores.py test-learning-disparadores.sh "el texto de la unidad no lleva el comentario" mostrar-comentario
caso "update pierde frases"     journal-compact.py m_learning_disparadores.py test-learning-disparadores.sh "texto nuevo . mismo comentario" update-pierde-disparadores
caso "compactador sin validar"  journal-compact.py m_learning_disparadores.py test-learning-disparadores.sh "invalido: cuarentena" compactador-sin-validar
caso "marca detras"             learning_marks.py m_learning_disparadores.py test-learning-disparadores.sh "cuerpo . marcador . comentario" marca-detras
caso "acepta guiones"           learning_marks.py m_learning_disparadores.py test-learning-disparadores.sh "commit ..amend" acepta-guiones
caso "QR duplica la regla"      build-recall-index.py m_learning_disparadores.py test-learning-disparadores.sh "titulo de una regla: se salta" qr-duplica
caso "QR sin numeradas"         build-recall-index.py m_learning_disparadores.py test-learning-disparadores.sh "titulo propio: entra" qr-sin-numeradas
caso "sin plegar acentos"     recall_rank.py m_learning_disparadores.py test-learning-disparadores.sh "acentos plegados" sin-plegar
# Recall en el momento de la accion (F5 del plan de ciclo de vida de learnings).
caso "accion sin especificidad" action_match.py m_action_recall.py test-action-recall.sh "orden esperado git#1" sin-especificidad
caso "accion sin ventana"       action_match.py m_action_recall.py test-action-recall.sh "2.a llamada" sin-ventana
caso "freno siempre"            action_match.py m_action_recall.py test-action-recall.sh "con regla-vista sigue frenando" freno-siempre
caso "sin regla-vista"          action_match.py m_action_recall.py test-action-recall.sh "regla-vista en la primera llamada frena" sin-regla-vista
caso "accion sin sudo"          action_match.py m_action_recall.py test-action-recall.sh "sudo git push. deberia casar" sin-sudo
caso "accion sin rtk"           action_match.py m_action_recall.py test-action-recall.sh "rtk git push. deberia casar" sin-rtk
caso "accion sin separadores"   action_match.py m_action_recall.py test-action-recall.sh "cd x && git push" sin-separadores
caso "accion sin palabras shell" action_match.py m_action_recall.py test-action-recall.sh "do git push; done" sin-palabras-shell
caso "accion sin tope chars"    action_match.py m_action_recall.py test-action-recall.sh "tope de 1.500 caracteres" sin-tope-chars
caso "edit frena"               action_match.py m_action_recall.py test-action-recall.sh "aviso, no deny" edit-frena
caso "path sin sufijo"          action_match.py m_action_recall.py test-action-recall.sh "fragmento bin/test" path-sin-sufijo
caso "estado roto habla"        action_match.py m_action_recall.py test-action-recall.sh "estado sin permiso de escritura" estado-sin-guardar-habla
caso "indice con retiradas"     build-recall-index.py m_action_recall.py test-action-recall.sh "el indice incluye la retirada" indice-con-retiradas
caso "aviso por defecto"        action_match.py m_action_recall.py test-action-recall.sh "git commit avisa sin opt-in" aviso-por-defecto
caso "via rapida ignora opt-in" action-recall.sh m_action_recall.py test-action-recall.sh "con opt-in y sin frenos" via-rapida-ignora-optin
caso "stderr del hook"          action-recall.sh m_action_recall.py test-action-recall.sh "action_match roto .error de sintaxis" stderr-del-hook
caso "reenvia salida rota"      action-recall.sh m_action_recall.py test-action-recall.sh "action_match roto .JSON a medias" reenvia-salida-rota
caso "frenos sin contar"        build-recall-index.py m_action_recall.py test-action-recall.sh "el indice real no cuenta 2 frenos" frenos-sin-contar
# Camino del deny (ronda 1 del adversario de F5): cada arreglo con su aserto.
caso "redireccion separa"       action_match.py m_action_recall.py test-action-recall.sh "falso freno .redireccion de entrada" redireccion-separa
caso "sin heredoc"              action_match.py m_action_recall.py test-action-recall.sh "deberia frenar .heredoc y despues el comando" sin-heredoc
caso "comentario no corta"      action_match.py m_action_recall.py test-action-recall.sh "falso freno .comentario con separadores dentro" comentario-no-corta
caso "interprete sin ruta"      action_match.py m_action_recall.py test-action-recall.sh "falso freno .interprete sin ruta" interprete-sin-ruta
caso "sin bash -c"              action_match.py m_action_recall.py test-action-recall.sh "deberia frenar .bash -c" sin-bash-c
caso "sin sustituciones"        action_match.py m_action_recall.py test-action-recall.sh "deberia frenar .sustitucion" sin-sustituciones
caso "descriptor es programa"   action_match.py m_action_recall.py test-action-recall.sh "deberia frenar .redireccion delante" descriptor-es-programa
caso "vista en cualquier parte" action_match.py m_action_recall.py test-action-recall.sh "marcador dentro de un heredoc" vista-en-cualquier-parte
caso "freno truthy"             action_match.py m_action_recall.py test-action-recall.sh "freno:.no. en el indice frena" freno-truthy
caso "estado ilegible vacio"    action_match.py m_action_recall.py test-action-recall.sh "estado ilegible: volvio a frenar" estado-ilegible-vacio
caso "sin session compartida"   action_match.py m_action_recall.py test-action-recall.sh "sin session_id frena" sin-session-compartida
caso "sin lock"                 action_match.py m_action_recall.py test-action-recall.sh "lock de la sesion tomado" sin-lock
caso "lock viejo se queda"      action_match.py m_action_recall.py test-action-recall.sh "lock de hace 60 s" lock-viejo-se-queda
caso "windows sin minusculas"   action_match.py m_action_recall.py test-action-recall.sh "no normaliza Git.exe" windows-sin-minusculas
caso "heredoc solo letras"      action_match.py m_action_recall.py test-action-recall.sh "deberia frenar .heredoc numerico y despues" heredoc-solo-letras
caso "sin sustitucion proceso"  action_match.py m_action_recall.py test-action-recall.sh "deberia frenar .sustitucion de proceso" sin-sustitucion-de-proceso
caso "estado forma laxa"        action_match.py m_action_recall.py test-action-recall.sh "estado con tipos raros" estado-forma-laxa
caso "incierto adivina"         action_match.py m_action_recall.py test-action-recall.sh "heredoc con delimitador raro" incierto-adivina
caso "comillas adivina"         action_match.py m_action_recall.py test-action-recall.sh "comillas sin cerrar" comillas-adivina
caso "heredoc sin frontera"     action_match.py m_action_recall.py test-action-recall.sh "delimitador con comillas pegadas" heredoc-sin-frontera
caso "heredoc en sustitucion"   action_match.py m_action_recall.py test-action-recall.sh "heredoc dentro de una sustitucion" heredoc-en-sustitucion
caso "aritmetica como heredoc"  action_match.py m_action_recall.py test-action-recall.sh "aritmetica con << y despues" aritmetica-como-heredoc
caso "forma sin titulo"        learning_vecinos.py m_learning_dedup.py test-learning-dedup.sh "sin .*Titulo" forma-sin-titulo
caso "negrita impar"           learning_vecinos.py m_learning_dedup.py test-learning-dedup.sh "\*\* impar: rc 1" negrita-impar
caso "comilla impar"           learning_vecinos.py m_learning_dedup.py test-learning-dedup.sh "comilla invertida impar: rc 1" comilla-impar
caso "titulo largo"            learning_vecinos.py m_learning_dedup.py test-learning-dedup.sh "titulo de 201: rc 1" titulo-largo
caso "audit sin decision"      checkpoint-audit.py m_learning_dedup.py test-learning-dedup.sh "sin decision: SALTADO" audit-sin-decision
caso "audit #N inexistente"    checkpoint-audit.py m_learning_dedup.py test-learning-dedup.sh "#99 que no existe: SALTADO" audit-numero-inexistente

echo
echo "F6 (2.50.0): aviso de consolidar y learning.update --last-verified"
caso "umbral 16"               consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "15 reglas sin estado: avisa" umbral-16
caso "cuenta vivas"            consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "6 retiradas, sigue avisando" cuenta-vivas
caso "estado negativo vale"    consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "-3}}': avisa desde 0" negativo-valido
caso "estado bool vale"        consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "true}}': avisa desde 0" bool-valido
caso "h11 en el cuerpo"        consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "la frase en el cuerpo no avisa" h11-en-cuerpo
caso "h11 sin mayusculas"      consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "'Corregido' en minusculas no avisa" h11-insensible
caso "h11 cuenta retiradas"    consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "una correctora ya retirada no avisa" h11-cuenta-retiradas
caso "cuenta Related"          consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "1 de Related: cuenta 15" cuenta-related
caso "vinetas sin orden"       consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "un par de vinetas se nombra" vinetas-sin-orden
caso "archivados cuentan"      consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "un .archived.md no cuenta" archivados-cuentan
caso "aviso sin guarda"        consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "aviso con un topic ilegible" aviso-sin-guarda
caso "guardar no escribe"      consolidate-aviso.py m_consolidate.py test-consolidate-aviso.sh "estado guardado" guardar-no-escribe
caso "aviso solo al agente"    session-start.sh   m_consolidate.py test-consolidate-aviso.sh "persona: la linea" aviso-solo-agente
caso "paperclip recibe aviso"  session-start.sh   m_consolidate.py test-consolidate-aviso.sh "Paperclip: no hay linea" paperclip-no-detectado
caso "lv retrocede"            journal-compact.py m_consolidate.py test-learning-update.sh "23b una fecha anterior no retrocede" lv-retrocede
caso "lv fecha sin validar"    journal-compact.py m_consolidate.py test-learning-update.sh "23f fecha mala a mano" lv-fecha-sin-validar
caso "lv inventa frontmatter"  journal-compact.py m_consolidate.py test-learning-update.sh "23g sin frontmatter" lv-inventa-frontmatter
caso "lv ignorado"             journal-compact.py m_consolidate.py test-learning-update.sh "23a sin el campo" lv-ignorado-validador
caso "lv emisor sin validar"   journal-emit.py    m_consolidate.py test-learning-update.sh "23d fecha imposible" lv-emisor-sin-validar

echo
echo "Enlace Quick Reference -> regla y learnings-migracion.py (2.51.0, F7)"
L=m_learnings_migracion.py; S=test-learnings-migracion.sh
caso "add sin marca"           journal-compact.py $L $S "linea 3 del QR con la marca topic#N" add-sin-marca
caso "replay del add duplica"  journal-compact.py $L $S "replay del add: una sola linea" add-duplica
caso "numero repetido enlaza"  journal-compact.py $L $S "regla con numero repetido: marca el topic" repetido-numera
caso "update borra la marca"   journal-compact.py $L $S "texto nuevo . misma marca" update-borra-marca
caso "destino sin comprobar"   journal-compact.py $L $S "regla que no existe: cuarentena" sin-comprobar-destino
caso "valor sin validar"       journal-compact.py $L $S "compactador: valor malo a mano" compactador-sin-validar
caso "indice con la marca"     build-recall-index.py $L $S "el indice no lleva la marca" indice-con-marca
caso "recordatorio con marca"  rule-reinject-nudge.sh $L $S "el recordatorio no trae la marca" recordatorio-con-marca
caso "aviso cuenta bloqueadas" learnings-migracion.py $L $S "QR tras un comentario HTML: el aviso calla" aviso-cuenta-bloqueadas
caso "aviso no reescribibles"  learnings-migracion.py $L $S "no reescribible . marca rota bloqueada: el aviso calla" aviso-cuenta-no-reescribibles
caso "aviso rotas bloqueadas"  learnings-migracion.py $L $S "no reescribible . marca rota bloqueada: el aviso calla" aviso-cuenta-rotas-bloqueadas
caso "aplicar sin comprobar"   learnings-migracion.py $L $S "regla tras un bloque de codigo: exit 1" aplicar-sin-comprobar
caso "prefijo no unico"        learnings-migracion.py $L $S "y se aplican sin cuarentena" prefijo-no-unico
caso "candidato repetido"      learnings-migracion.py $L $S "el numero repetido no sale como topic#N" candidatos-con-repetidos
caso "decididas ignoradas"     learnings-migracion.py $L $S "decidir: el aviso calla" decididas-ignoradas
caso "migrar solo al agente"   session-start.sh $L $S "persona: la linea" aviso-solo-agente

echo
echo "Candidatos a pendiente decididos por el usuario (2.53.0)"
L=m_candidatos.py; S=test-checkpoint-audit.sh
caso "pendiente sin guardado"  checkpoint-audit.py $L $S "CA3: pendiente nacido en la sesion" sin-origen
caso "decision sin pregunta"   checkpoint-audit.py $L $S "CP1: decision tomada con 0 preguntas" sin-pregunta
caso "descartado no cierra"    checkpoint-audit.py $L $S "CD1: defecto con _descartado:" descartado-no-cierra
caso "hook sin candidatos"     checkpoint-audit.py $L $S "CP5: --solo-snippet" solo-snippet-sin-candidatos
caso "guard no pasa preguntas" checkpoint-close-guard.sh $L test-checkpoint-close-guard.sh "sin AskUserQuestion: reclama" guard-no-pasa
caso "sin resultado cuenta"    checkpoint-close-guard.sh $L test-checkpoint-close-guard.sh "un AskUserQuestion sin resultado" guard-sin-resultado-cuenta
caso "error ajeno cuenta"      checkpoint-close-guard.sh $L test-checkpoint-close-guard.sh "InputValidationError" guard-error-cuenta
caso "mide sin checkpoint"     checkpoint-close-guard.sh $L test-checkpoint-close-guard.sh "solo reimprime el snippet" guard-sin-checkpoint
caso "descartado sin candidato" checkpoint-audit.py $L $S "CB2: _descartado: sin candidato" descartado-sin-candidato
caso "ninguno sin descartado"  checkpoint-audit.py $L $S "CB5: ninguno . break . defecto descartado" ninguno-ignora-descartado

echo
echo "run-tests.sh (p-46153b135b): una suite que sale 0 sin su linea de resumen es FALLA"
# El aserto esperado de sin-resumen-no-exigido es "exit 0 a mitad", no el del trap: en bash 5
# (ubuntu, Git Bash) la suite del trap sale rc=2 y da FALLA con o sin mutacion (CI 37006005796).
caso_tools "rc=0 sin resumen pasa"  run-tests.sh m_run_tests.py test-run-tests.sh "la que sale con exit 0 a mitad" sin-resumen-no-exigido
caso_tools "resumen en cualquier linea" run-tests.sh m_run_tests.py test-run-tests.sh "un resumen a mitad no la salva" resumen-cualquiera
caso_tools "skip=N no es verde" run-tests.sh m_run_tests.py test-run-tests.sh "un skip=N>0 es salto parcial" skip-n-ignorado
caso_tools "salto sin resumen verde" run-tests.sh m_run_tests.py test-run-tests.sh "FALLA, no salto: «RESULT pass=1 fail=1 skip=2»" parcial-sin-resumen
caso_tools "saltados con cola" run-tests.sh m_run_tests.py test-run-tests.sh "FALLA, no salto: «RESULTADO: 5 ok, 0 fallas, 2 saltados, 1 fallas»" saltados-con-cola
caso_tools "skip=N a cero" run-tests.sh m_run_tests.py test-run-tests.sh "un skip=N>0 es salto parcial: «pass=1 fail=0 skip=2»" skip-a-cero
caso_tools "dos cuentas de saltos" run-tests.sh m_run_tests.py test-run-tests.sh "FALLA, no salto: «RESULT pass=1 fail=0 skip=2, 3 saltados»" dos-cuentas
caso_tools "resumen por prefijo" run-tests.sh m_run_tests.py test-run-tests.sh "FALLA con «TODO VERDE de la seccion 3»" resumen-prefijo
caso_tools "sin bash -n previo" run-tests.sh m_run_tests.py test-run-tests.sh "y lo dice: bash -n" sin-bash-n

echo
if [ "$PEND" -eq 0 ]; then echo "LAS EVALUABLES DISCRIMINAN (de $TOTAL)"; else echo "SIN ACLARAR: $PEND de $TOTAL"; fi
exit $(( PEND > 0 ))
