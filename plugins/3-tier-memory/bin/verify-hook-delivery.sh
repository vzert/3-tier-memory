#!/bin/bash
# sella-huellas: no (no toca memory/; monta un proyecto de prueba en un temporal aparte)
#
# Verificacion MANUAL (no vive en bin/test-*.sh: llama a `claude -p` de verdad, cuesta tokens de
# API y necesita el CLI autenticado) de una afirmacion que este plugin depende: que canal de hook
# entrega su salida al MODELO.
#
# Por que existe: una revision adversarial (2026-09-14) marco como "ungrounded" la afirmacion de
# que `journal-drift-nudge.sh` (UserPromptSubmit) SI llega al agente mientras que
# `journal-guard.sh`/`bash-journal-nudge.sh` (PreToolUse/PostToolUse) NO — la unica evidencia era
# un experimento hecho a mano en la conversacion, sin rastro en el repo. Este script es ese mismo
# experimento, guardado para poder repetirlo (por ejemplo, si un dia Claude Code cambia como
# entrega sus hooks) en vez de confiar en que "ya se midio una vez".
#
# Que hace: monta un proyecto temporal con seis hooks, cada uno con un centinela distinto, y corre
# `claude -p` pidiendole tres acciones y que diga en su respuesta final que centinelas vio:
#   - TEXTO PLANO con exit 0 (la forma de journal-guard.sh / bash-journal-nudge.sh), sobre Edit de
#     note.txt: PreToolUse (PRE), PostToolUse (POST) y UserPromptSubmit (PROMPT). Son ademas el
#     control negativo de los casos JSON: mismo evento, otra forma de salida.
#   - JSON hookSpecificOutput.additionalContext SOLO (la forma de action-recall.sh, F5), sobre Write
#     de json.txt: PreToolUse (JPRE) y PostToolUse (JPOST).
#   - JSON permissionDecision deny con el centinela en permissionDecisionReason (el freno de F5),
#     sobre `touch witness.txt` por Bash (DENY). La herramienta NO debe correr: witness.txt no
#     puede existir. Control (regla 81: un deny por permisos se ve igual): el mismo hook deja pasar
#     `touch control.txt`, que SI debe existir; si no existe, el resultado no vale.
#   - Un hook que FALLA no debe bloquear (F5: action-recall.sh no frena nunca por un fallo propio):
#     `touch lento.txt` lo ve un hook que tarda 8 s con timeout de 2 s, y `touch roto.txt` uno que
#     imprime un JSON a medias con "deny" dentro y sale 1. Los dos ficheros SI deben existir.
#   - Los dos hooks REALES del plugin juntos en PreToolUse de Write (F5, hallazgo de la ronda 1 del
#     adversario): journal-guard.sh con journal_strict=1 y action-recall.sh con el aviso encendido
#     y una regla cuyo `path` es memory/_prueba.md. Escribir ese fichero: el guard niega (deny con
#     "journal_strict=1") y action-recall avisa (additionalContext con un centinela). memory/_prueba.md
#     NO debe existir y el modelo debe ver el motivo del guard (GUARD); ACC dice si el aviso de
#     action-recall llego junto al rechazo.
# Compara lo que dice el modelo con lo que paso en el disco.
#
# Uso: bash bin/verify-hook-delivery.sh   (necesita `claude` en el PATH y autenticado; usa un
# modelo barato por defecto, exportar VERIFY_MODEL para cambiarlo)
# Salida esperada: PRE NO, POST NO, PROMPT SI (confirmada el 2026-09-14 y en 2.1.283); JPRE SI,
# JPOST SI y DENY SI con witness.txt ausente y control.txt presente (los seis confirmados el
# 2026-10-03 en 2.1.288); lento.txt y roto.txt presentes; GUARD SI y ACC SI con memory/_prueba.md
# ausente (2026-10-05, 2.1.288). Este script mide QUE llega, no CUANDO: que el JPRE llega despues de
# emitida la llamada, junto a su resultado, se midio a mano el 2026-09-30 (2.1.285, regla 298), y
# por eso el freno de F5 usa deny. Cualquier otra combinacion es una senal de que el harness cambio: revisa
# los comentarios de journal-guard.sh, journal-drift-nudge.sh y action-recall.sh, y la regla 298.

set -u
MODEL="${VERIFY_MODEL:-sonnet}"
D=$(mktemp -d) || { echo "mktemp fallo"; exit 1; }
T=$(date +%s)
SENT_ACC="SENTINEL_ACC_${T}_g"
BIN="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$D/.claude" "$D/memory"
# Estado de los hooks reales: el directorio por proyecto de Claude Code, bajo las dos formas de la
# ruta (macOS da /var/... y su realpath /private/var/...). Se borran al salir.
SDS=""
for R in "$D" "$(cd "$D" && pwd -P)"; do
  SDS="$SDS $HOME/.claude/projects/$(printf '%s' "$R" | sed 's/[^A-Za-z0-9]/-/g')"
done
trap 'rm -rf "$D" $SDS' EXIT
printf -- '---\ntype: index\n---\n# Pendientes\n' > "$D/memory/_pendientes.md"
printf 'journal_strict=1\naction_recall_aviso=1\n' > "$D/memory/.memory-config"
for SD in $SDS; do
  mkdir -p "$SD"
  printf '{"frenos": 0, "reglas": [{"id": "prueba#1", "topic": "prueba", "n": 1, "texto": "%s", "cmd": [], "path": ["memory/_prueba.md"], "freno": false, "ancla": ""}]}\n' \
    "$SENT_ACC" > "$SD/.action-index.json"
done

SENT_PRE="SENTINEL_PRE_${T}_a"
SENT_POST="SENTINEL_POST_${T}_b"
SENT_PROMPT="SENTINEL_PROMPT_${T}_c"
SENT_JPRE="SENTINEL_JPRE_${T}_d"
SENT_JPOST="SENTINEL_JPOST_${T}_e"
SENT_DENY="SENTINEL_DENY_${T}_f"

for k in pre post prompt; do
  case $k in pre) S=$SENT_PRE ;; post) S=$SENT_POST ;; prompt) S=$SENT_PROMPT ;; esac
  printf '#!/bin/bash\necho "%s"\nexit 0\n' "$S" > "$D/hook-$k.sh"
done
printf '#!/bin/bash\ncat >/dev/null\nprintf %s\nexit 0\n' \
  "'{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"$SENT_JPRE\"}}'" > "$D/hook-jpre.sh"
printf '#!/bin/bash\ncat >/dev/null\nprintf %s\nexit 0\n' \
  "'{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"$SENT_JPOST\"}}'" > "$D/hook-jpost.sh"
cat > "$D/hook-deny.sh" <<EOF
#!/bin/bash
IN=\$(cat)
case "\$IN" in
  *witness.txt*) printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$SENT_DENY"}}' ;;
esac
exit 0
EOF
cat > "$D/hook-falla.sh" <<'EOF'
#!/bin/bash
IN=$(cat)
case "$IN" in
  *lento.txt*) sleep 8 ;;
  *roto.txt*) printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"de'; exit 1 ;;
esac
exit 0
EOF
chmod +x "$D"/hook-*.sh

cat > "$D/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "bash $D/hook-pre.sh"}]},
                   {"matcher": "Write", "hooks": [{"type": "command", "command": "bash $D/hook-jpre.sh"}]},
                   {"matcher": "Edit|Write|MultiEdit", "hooks": [{"type": "command", "command": "bash $BIN/journal-guard.sh"}]},
                   {"matcher": "Bash|Edit|Write|MultiEdit", "hooks": [{"type": "command", "command": "bash $BIN/action-recall.sh"}]},
                   {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash $D/hook-deny.sh"}]},
                   {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash $D/hook-falla.sh", "timeout": 2}]}],
    "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "bash $D/hook-post.sh"}]},
                    {"matcher": "Write", "hooks": [{"type": "command", "command": "bash $D/hook-jpost.sh"}]}],
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "bash $D/hook-prompt.sh"}]}]
  }
}
EOF
printf 'linea original\n' > "$D/note.txt"

RESP=$(cd "$D" && claude -p \
  "Haz estas cinco cosas, en orden y una sola vez cada una, sin reintentar ninguna: (1) edita note.txt agregando una linea 'hello'; (2) crea json.txt con el contenido 'x'; (3) corre por Bash exactamente 'touch control.txt' y despues, en otra llamada, exactamente 'touch witness.txt'; (4) corre por Bash 'touch lento.txt' y despues 'touch roto.txt'; (5) con la herramienta Write crea el fichero nuevo memory/_prueba.md con el contenido 'x'. Luego, en tu respuesta final de texto (nada mas), dime EXACTAMENTE cuales de estos textos viste en algun resultado de herramienta, salida de hook, motivo de rechazo o system-reminder: '$SENT_PRE', '$SENT_POST', '$SENT_PROMPT', '$SENT_JPRE', '$SENT_JPOST', '$SENT_DENY', 'journal_strict=1', '$SENT_ACC'. Responde con ocho lineas en este formato literal: 'PRE: SI' o 'PRE: NO', y lo mismo para POST, PROMPT, JPRE, JPOST, DENY, GUARD (el texto journal_strict=1) y ACC." \
  --permission-mode acceptEdits --allowedTools "Bash(touch:*)" --settings "$D/.claude/settings.json" \
  --model "$MODEL" < /dev/null 2>&1)

echo "=== lo que paso en el disco ==="
[ "$(grep -c 'hello' "$D/note.txt" 2>/dev/null)" = "1" ] && echo "OK: note.txt editado (los hooks de Edit corrieron)" \
  || echo "AVISO: note.txt NO cambio — la prueba no es valida, revisar permission-mode"
[ -f "$D/json.txt" ] && echo "OK: json.txt creado (los hooks de Write corrieron)" || echo "AVISO: json.txt no existe — JPRE/JPOST no valen"
[ -f "$D/control.txt" ] && echo "OK: control.txt existe (Bash touch esta permitido: un rechazo de witness es del hook)" \
  || echo "AVISO: control.txt no existe — el rechazo de witness puede ser de permisos (regla 81): DENY no vale"
[ -f "$D/witness.txt" ] && echo "FALLO: witness.txt EXISTE — el deny del hook NO impidio la llamada" \
  || echo "OK: witness.txt no existe — el deny impidio la llamada"
[ -f "$D/lento.txt" ] && echo "OK: lento.txt existe — un hook que se pasa de su timeout no bloquea" \
  || echo "FALLO: lento.txt no existe — un hook lento BLOQUEO la llamada"
[ -f "$D/roto.txt" ] && echo "OK: roto.txt existe — un hook con JSON a medias y exit 1 no bloquea" \
  || echo "FALLO: roto.txt no existe — un hook roto BLOQUEO la llamada"
[ -f "$D/memory/_prueba.md" ] && echo "FALLO: memory/_prueba.md EXISTE — el deny de journal-guard se perdio junto a action-recall" \
  || echo "OK: memory/_prueba.md no existe — el deny de journal-guard se mantiene con action-recall en el mismo matcher"
echo
echo "=== lo que el modelo dice haber visto ==="
echo "$RESP" | grep -E '^(PRE|POST|PROMPT|JPRE|JPOST|DENY|GUARD|ACC):' || echo "$RESP"
echo
echo "=== esperado: PRE NO / POST NO / PROMPT SI / JPRE SI / JPOST SI / DENY SI (witness ausente, control presente), lento y roto presentes / GUARD SI con _prueba.md ausente ==="
