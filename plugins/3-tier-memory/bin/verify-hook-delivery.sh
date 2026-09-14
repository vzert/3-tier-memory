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
# Que hace: monta un proyecto temporal con TRES hooks (PreToolUse, PostToolUse, UserPromptSubmit),
# cada uno imprimiendo un centinela distinto en texto plano con exit 0 — la misma forma que usan
# los hooks reales de este plugin. Corre `claude -p` pidiendole que edite un archivo y que diga,
# en su respuesta final, cuales de los tres centinelas vio. Compara lo que dice contra lo que en
# realidad se escribio (el archivo SI se edito, asi que el hook SI corrio en los tres casos).
#
# Uso: bash bin/verify-hook-delivery.sh   (necesita `claude` en el PATH y autenticado; usa un
# modelo barato por defecto, exportar VERIFY_MODEL para cambiarlo)
# Salida esperada, y la que quedo confirmada el 2026-09-14: PreToolUse=NO PostToolUse=NO
# UserPromptSubmit=SI. Cualquier otra combinacion es una senal de que el comportamiento del
# harness cambio y hay que revisar los comentarios de journal-guard.sh / journal-drift-nudge.sh.

set -u
MODEL="${VERIFY_MODEL:-sonnet}"
D=$(mktemp -d) || { echo "mktemp fallo"; exit 1; }
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/.claude"

SENT_PRE="SENTINEL_PRE_$(date +%s)_a"
SENT_POST="SENTINEL_POST_$(date +%s)_b"
SENT_PROMPT="SENTINEL_PROMPT_$(date +%s)_c"

cat > "$D/hook-pre.sh" <<EOF
#!/bin/bash
echo "$SENT_PRE"
exit 0
EOF
cat > "$D/hook-post.sh" <<EOF
#!/bin/bash
echo "$SENT_POST"
exit 0
EOF
cat > "$D/hook-prompt.sh" <<EOF
#!/bin/bash
echo "$SENT_PROMPT"
exit 0
EOF
chmod +x "$D"/hook-*.sh

cat > "$D/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "bash $D/hook-pre.sh"}]}],
    "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "bash $D/hook-post.sh"}]}],
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "bash $D/hook-prompt.sh"}]}]
  }
}
EOF
printf 'linea original\n' > "$D/note.txt"

RESP=$(cd "$D" && claude -p \
  "Edita note.txt agregando una linea 'hello'. Luego, en tu respuesta final de texto (nada mas), dime EXACTAMENTE cuales de estos tres textos viste en algun resultado de herramienta, salida de hook o system-reminder: '$SENT_PRE', '$SENT_POST', '$SENT_PROMPT'. Responde con tres lineas, una por cada uno, en este formato literal: 'PRE: SI' o 'PRE: NO', 'POST: SI' o 'POST: NO', 'PROMPT: SI' o 'PROMPT: NO'." \
  --permission-mode acceptEdits --settings "$D/.claude/settings.json" --model "$MODEL" < /dev/null 2>&1)

EDITED=$(grep -c 'hello' "$D/note.txt" 2>/dev/null || echo 0)
echo "=== edicion real (confirma que los 3 hooks SI corrieron) ==="
[ "$EDITED" = "1" ] && echo "OK: note.txt fue editado" || echo "AVISO: note.txt NO cambio — la prueba no es valida, revisar permission-mode"
echo
echo "=== lo que el modelo dice haber visto ==="
echo "$RESP" | grep -E '^(PRE|POST|PROMPT):' || echo "$RESP"
echo
echo "=== esperado (confirmado 2026-09-14): PRE: NO / POST: NO / PROMPT: SI ==="
