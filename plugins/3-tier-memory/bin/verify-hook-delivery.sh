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
# Compara lo que dice el modelo con lo que paso en el disco.
#
# Uso: bash bin/verify-hook-delivery.sh   (necesita `claude` en el PATH y autenticado; usa un
# modelo barato por defecto, exportar VERIFY_MODEL para cambiarlo)
# Salida esperada: PRE NO, POST NO, PROMPT SI (confirmada el 2026-09-14 y en 2.1.283); JPRE SI,
# JPOST SI y DENY SI con witness.txt ausente y control.txt presente (los seis confirmados el
# 2026-10-03 en 2.1.288). Este script mide QUE llega, no CUANDO: que el JPRE llega despues de
# emitida la llamada, junto a su resultado, se midio a mano el 2026-09-30 (2.1.285, regla 298), y
# por eso el freno de F5 usa deny. Cualquier otra combinacion es una senal de que el harness cambio: revisa
# los comentarios de journal-guard.sh, journal-drift-nudge.sh y action-recall.sh, y la regla 298.

set -u
MODEL="${VERIFY_MODEL:-sonnet}"
D=$(mktemp -d) || { echo "mktemp fallo"; exit 1; }
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/.claude"

T=$(date +%s)
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
chmod +x "$D"/hook-*.sh

cat > "$D/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "bash $D/hook-pre.sh"}]},
                   {"matcher": "Write", "hooks": [{"type": "command", "command": "bash $D/hook-jpre.sh"}]},
                   {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash $D/hook-deny.sh"}]}],
    "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "bash $D/hook-post.sh"}]},
                    {"matcher": "Write", "hooks": [{"type": "command", "command": "bash $D/hook-jpost.sh"}]}],
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "bash $D/hook-prompt.sh"}]}]
  }
}
EOF
printf 'linea original\n' > "$D/note.txt"

RESP=$(cd "$D" && claude -p \
  "Haz estas tres cosas, en orden y una sola vez cada una, sin reintentar ninguna: (1) edita note.txt agregando una linea 'hello'; (2) crea json.txt con el contenido 'x'; (3) corre por Bash exactamente 'touch control.txt' y despues, en otra llamada, exactamente 'touch witness.txt'. Luego, en tu respuesta final de texto (nada mas), dime EXACTAMENTE cuales de estos textos viste en algun resultado de herramienta, salida de hook, motivo de rechazo o system-reminder: '$SENT_PRE', '$SENT_POST', '$SENT_PROMPT', '$SENT_JPRE', '$SENT_JPOST', '$SENT_DENY'. Responde con seis lineas en este formato literal: 'PRE: SI' o 'PRE: NO', y lo mismo para POST, PROMPT, JPRE, JPOST y DENY." \
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
echo
echo "=== lo que el modelo dice haber visto ==="
echo "$RESP" | grep -E '^(PRE|POST|PROMPT|JPRE|JPOST|DENY):' || echo "$RESP"
echo
echo "=== esperado: PRE NO / POST NO / PROMPT SI / JPRE SI / JPOST SI / DENY SI (witness ausente, control presente) ==="
