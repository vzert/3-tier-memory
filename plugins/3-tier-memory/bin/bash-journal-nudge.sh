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
# DOS EVENTOS, dos exactitudes distintas:
#   PreToolUse  — mira el TEXTO del comando. Aproximado: no ve una ruta en variable ni un `eval`.
#                 Llega ANTES, que es cuando sirve.
#   PostToolUse — compara BYTES contra la huella que dejo el compactador. Exacto, cero falsos
#                 positivos, llega un turno tarde. Compuerta de mtime en shell para no pagar el
#                 arranque de python (~30 ms) en cada Bash: sin cambios, no se llama a python.
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
  # Compuerta barata: solo llamar a python si algun indice es mas nuevo que la huella.
  FP="$MEMORY_DIR/.journal/fingerprints.json"
  [ -f "$FP" ] || exit 0
  # `find -newer` exige marca ESTRICTAMENTE posterior, asi que en un sistema con mtime de 1 s una
  # escritura en el mismo segundo que el sellado empata y no se ve. Se compara `>=` con stat.
  # (Ronda 6.) Peor caso si stat no esta: se llama a python siempre, que es correcto y solo cuesta.
  #
  # (2026-09-12, primera corrida en Linux.) La version anterior era
  #     stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
  # y en GNU NO caia al segundo: `-f` no toma argumento, asi que `%m` se lee como OTRO fichero.
  # Ese falla —de ahi el exit distinto de 0 que disparaba el `||`— pero el fichero real SI se
  # imprime, con la info del sistema de ficheros. `2>/dev/null` tapaba el error y la sustitucion se
  # quedaba con las dos salidas pegadas. El `[ "$m" -ge "$FPM" ]` posterior no es un numero, falla,
  # y NEWER nunca se ponia: el aviso no disparaba NUNCA en Linux. Silencioso, que es lo peor que
  # puede hacer una barandilla.
  #
  # Ahora se prueba GNU primero (BSD no tiene `-c`, asi que alli falla y cae) y sobre todo se
  # EXIGE QUE LA SALIDA SEA UN ENTERO: una utilidad que responde otra cosa vale lo mismo que no
  # estar, y en ese caso se devuelve vacio, que el llamador ya sabe tratar.
  _entero() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
  _mt() {
    local m
    m=$(stat -c %Y "$1" 2>/dev/null); _entero "$m" && { printf '%s' "$m"; return 0; }
    m=$(stat -f %m "$1" 2>/dev/null); _entero "$m" && { printf '%s' "$m"; return 0; }
    return 1
  }
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
    [ -z "$NEWER" ] && exit 0
  fi
  python3 "$(dirname "$0")/journal-compact.py" --memory-dir "$MEMORY_DIR" --check-drift 2>/dev/null
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
    "puesta a mano no tiene evento que auditar, no genera su fila de Tier 3, y la siguiente "
    "pasada del compactador puede no encontrar su ancla y mandar el evento a cuarentena. "
    "Usa bin/journal-emit.py (pendiente.add/resolve, session.add, learning.add, plan.upsert, "
    "research.upsert) y luego bin/journal-compact.py. "
    "Si la escritura es una reparacion manual deliberada, hazla y despues corre "
    "`journal-compact.py --reseal` para que no se reporte como deriva. "
    "Esto es un aviso, no un bloqueo: puede equivocarse y no impide nada."
)
PY
exit 0
