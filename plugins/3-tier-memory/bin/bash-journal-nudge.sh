#!/bin/bash

# Salida de python en UTF-8 SIEMPRE. En Windows, python codifica stdout con la pagina de codigos
# local cuando va a una tuberia (cp1252), no en UTF-8: el texto en espanol de este plugin salia con
# los guiones largos y los acentos rotos. Medido en CI el 2026-09-12 sobre la salida real del hook
# de arranque: `item con id — _creado:` llegaba como `item con id \xef\xbf\xbd _creado:`. Es texto
# que se inyecta en el prompt de cada sesion, asi que lo veia el modelo y lo veia el usuario.
# PYTHONUTF8 necesita 3.7+; PYTHONIOENCODING cubre lo anterior. Los dos son no-op fuera de Windows.
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (hook de solo lectura: avisa, no escribe)
# 3-tier-memory: aviso (NUNCA bloqueo) cuando Bash escribe un indice del journal. v2.13.4
#
# POR QUE EXISTE. journal_strict es un hook PreToolUse con matcher Edit|Write|MultiEdit, y Bash no
# esta en esa lista: un `>>`, un `sed -i` o un heredoc escriben igual. No es descuido de quien lo
# hace — una sesion en modo auto recibe la instruccion explicita de preferir Bash sobre Edit/Write,
# asi que ahi el guard no se salta a veces, se salta siempre. Medido 2026-09-11 sobre el historial
# JSONL: 96 escrituras a mano a un indice protegido desde que el journal es obligatorio, en 9
# proyectos. Cruzando con los eventos: 43 ids de Tier 2 sin NINGUN evento que los emitiera.
#
# AVISA, NO BLOQUEA, y la asimetria es el argumento entero: un falso positivo al DENEGAR cuesta
# trabajo bueno tirado; al AVISAR cuesta una linea de texto. Por eso aqui se puede permitir un
# detector aproximado, y por eso no se deniega aunque journal_strict=1.
#
# NO DEPENDE DE .memory-config. Solo mira que exista .journal/. Medido: 64 de 65 proyectos con
# memory/ no tienen config ninguna, asi que condicionarlo a journal_strict lo dejaria inerte justo
# donde mas falta hace. Quien no use el journal no tiene .journal/ y no ve nada.
#
# UN SOLO EVENTO HACE ALGO: PreToolUse mira el TEXTO del comando (aproximado: no ve una ruta en
# variable ni un `eval`) y llega ANTES, que es cuando sirve para el desarrollador que mira el log.
#
# PostToolUse YA NO llama a --check-drift (quitado en 2.24.1). Lo hacia desde 2.13.4 comparando
# BYTES contra la huella del compactador, pero `--check-drift` DETECTA Y RESELLA en la misma
# llamada — y PostToolUse es un hook cuyo stdout no llega al agente (medido con `claude -p`,
# ver journal-guard.sh). Consecuencia real, no teorica: en una sesion interactiva normal
# (hay_lector()==True, el caso comun) este PostToolUse ganaba SIEMPRE la carrera contra
# journal-drift-nudge.sh (UserPromptSubmit, el turno siguiente, que SI entrega) porque corre en
# el MISMO turno que la escritura, antes de que exista un turno siguiente. Resellaba la linea
# base y el aviso real nunca salia. Esto no era un defecto de 2.24.0 (journal-drift-nudge.sh):
# bash-journal-nudge.sh tiene este PostToolUse desde v2.13.4, asi que es plausible que el aviso de
# deriva por escritura de Bash nunca haya llegado a nadie desde que el mecanismo existe.
# Ver memory/_pendientes.md (2026-09-14) y memory/sessions/2026-09-14-*.md para el analisis
# completo, y bin/test-drift-nudge.sh para la prueba que reproduce el orden real.
#
# Sin `set -u`, como los demas hooks del plugin. Ya NO es obligatorio: resolve-project-dir.sh
# protege sus variables desde 2.14.3 y se puede sourcear con -u (bin/test-resolve-project-dir.sh).
# Encenderlo aqui es otra revision — la del camino de ~10 ms — y no se ha hecho.

source "$(dirname "$0")/resolve-project-dir.sh"

# La deteccion mira tambien .journal/, no solo _pendientes.md. Diez scripts del plugin usan ese
# fichero como centinela para localizar memory/, asi que BORRARLO deja al plugin entero ciego —
# justo la escritura fuera del journal mas destructiva que hay. Aqui no. (Ronda 6.)
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ] || [ -d "$CLAUDE_PROJECT_DIR/memory/.journal" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  A="$HOME/.claude/projects/$ENCODED/memory"
  { [ -f "$A/_pendientes.md" ] || [ -d "$A/.journal" ]; } && MEMORY_DIR="$A"
fi
[ -z "${MEMORY_DIR:-}" ] && exit 0
[ -d "$MEMORY_DIR/.journal" ] || exit 0     # el proyecto no usa el journal: nada que decir

# El nombre del evento se saca con un glob, no arrancando python: este hook corre en CADA llamada
# a Bash y el arranque del interprete (~25 ms) se pagaria siempre, incluso cuando no hay nada que
# decir. El JSON del hook no lleva ese literal en ningun otro sitio.
case "$_HOOK_INPUT" in
  *'"hook_event_name":"PostToolUse"'*|*'"hook_event_name": "PostToolUse"'*) EVENT=PostToolUse ;;
  *'"hook_event_name":"PreToolUse"'*|*'"hook_event_name": "PreToolUse"'*)   EVENT=PreToolUse ;;
  *) exit 0 ;;
esac

if [ "$EVENT" = "PostToolUse" ]; then
  # 2.24.1 tambien quito el registro de este evento en hooks.json (el harness ya no invoca este
  # script con PostToolUse). Esta rama se deja como contrato inerte, probado en test-bash-nudge.sh
  # y test-expire-reopen.sh, por si algo lo sigue invocando asi directamente.
  exit 0
fi

# PreToolUse: mirar el texto del comando. Criba en shell primero — si el comando no nombra ningun
# indice, no hay nada que analizar y nos ahorramos el arranque de python (el caso comun con mucho).
case "$_HOOK_INPUT" in
  *_pendientes.md*|*_learnings.md*|*_session-index.md*|*_plans-index.md*|*_research-index.md*|*pendientes/20*.md*) ;;
  *) exit 0 ;;
esac

MEMORY_DIR="$MEMORY_DIR" HOOK_INPUT="$_HOOK_INPUT" python3 - <<'PY'
import json, os, re, sys
try:
    d = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command", "")
if not cmd:
    sys.exit(0)

IDX = r'(?:_pendientes|_learnings|_session-index|_plans-index|_research-index)\.md|pendientes/\d{4}-\d{2}\.md'
# Cada patron es una forma REAL vista en el historial. `>` sin digito delante para no confundirlo
# con un `2>` de redireccion de descriptor.
PATS = [
    re.compile(r'(?<![0-9])>>?\s*(?:"[^"]*?|\'[^\']*?|\S*?)(?:' + IDX + r')'),
    re.compile(r'sed\s+(?:-[a-zA-Z]+\s+)*-i[^\n|;&]{0,200}?(?:' + IDX + r')'),
    re.compile(r'tee\s+(?:-a\s+)?\S*?(?:' + IDX + r')'),
    re.compile(r'open\(\s*[^)]{0,120}?(?:' + IDX + r')[^)]{0,40}?,\s*["\'][wa]'),
    re.compile(r'\b(?:cp|mv)\s+\S+\s+\S*?(?:' + IDX + r')'),
]
if not any(p.search(cmd) for p in PATS):
    sys.exit(0)

# Las propias herramientas del plugin escriben los indices de forma legitima.
if re.search(r'(journal-compact|repair-dualwrite|normalize-pendientes|enrich-memory|'
             r'ensure-frontmatter|scan-secrets|expire-pendientes)\.py', cmd):
    sys.exit(0)

print(
    "AVISO del plugin 3-tier-memory: este comando parece escribir un indice de memory/ "
    "directamente. Esos ficheros los escribe SOLO el compactador del journal — una linea "
    "puesta a mano no tiene evento que auditar y no genera su fila de Tier 3, asi que al "
    "cerrarla se pierden su fecha de cierre y la sesion que la cerro. "
    "Usa bin/journal-emit.py (pendiente.add/resolve/update/reopen, session.add, learning.add/update, plan.upsert/reopen, "
    "research.upsert) y luego bin/journal-compact.py. "
    "Si la escritura es una reparacion manual deliberada, hazla y despues corre "
    "`journal-compact.py --reseal` para que no se reporte como deriva. "
    "Esto es un aviso, no un bloqueo: puede equivocarse y no impide nada."
)
PY
exit 0
