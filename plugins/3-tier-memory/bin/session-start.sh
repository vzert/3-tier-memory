#!/bin/bash

# Salida de python en UTF-8 SIEMPRE. En Windows, python codifica stdout con la pagina de codigos
# local cuando va a una tuberia (cp1252), no en UTF-8: el texto en espanol de este plugin salia con
# los guiones largos y los acentos rotos. Medido en CI el 2026-09-12 sobre la salida real del hook
# de arranque: `item con id — _creado:` llegaba como `item con id \xef\xbf\xbd _creado:`. Es texto
# que se inyecta en el prompt de cada sesion, asi que lo veia el modelo y lo veia el usuario.
# PYTHONUTF8 necesita 3.7+; PYTHONIOENCODING cubre lo anterior. Los dos son no-op fuera de Windows.
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

# sella-huellas: no (lee e invoca a otros; los indices los escribe el compactador)
# 3-tier-memory plugin: SessionStart hook
# Injects open pendientes AND learnings at session start

source "$(dirname "$0")/resolve-project-dir.sh"

# ---------------------------------------------------------------- salida: dos canales
# Este hook habla con DOS lectores y hasta 2.17.0 solo alcanzaba a uno:
#   - `additionalContext` -> el agente. Ahi iba TODO, via stdout plano.
#   - `systemMessage`     -> la persona. No existia. Por eso los pendientes se acumulaban
#     (2026-09-11: 54 abiertos, 14 con mas de 30 dias). El agente los veia en cada sesion y
#     aun asi no bajaban: cerrarlos es una decision de la persona, y a la persona nunca le
#     llegaban.
# Los dos viajan en UN SOLO objeto JSON impreso al final. Por eso NADA en este script puede
# escribir a stdout por su cuenta: JSON seguido de texto suelto no parsea y se pierde el hook
# entero. `out` acumula para el agente, `human` para la persona.
_AGENT_BUF=""
_HUMAN_BUF=""
out()   { _AGENT_BUF="${_AGENT_BUF}$1
"; }
human() { _HUMAN_BUF="${_HUMAN_BUF}$1
"; }

# ¿Hay una persona a la que dirigirse en esta sesion? UNA sola definicion, que usan tanto el
# aviso de deriva como emit_output: dos copias de esta regla se separan y una de las dos se
# queda rancia.
hay_persona() {
  [ -n "${PAPERCLIP_RUN_ID:-}" ] && return 1          # agente de Paperclip: no hay pantalla
  [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = "0" ] && return 1   # corrida no interactiva
  case "$(hook_source)" in
    startup|resume) return 0 ;;
    *) return 1 ;;                                     # clear/compact: esta a mitad de trabajo
  esac
}

# `source` del payload: startup | resume | clear | compact. El mensaje a la persona solo
# tiene sentido cuando ELLA abre la sesion; en `clear`/`compact` esta a mitad de trabajo.
# Se filtra AQUI y no con el `matcher` de hooks.json a proposito: el matcher apaga el hook
# entero, y en `clear`/`compact` el agente acaba de perder el contexto — es justo cuando mas
# necesita `additionalContext`. Sin stdin utilizable devuelve vacio y la persona no recibe
# nada, que es el lado seguro: repetirle el aviso en cada compact lo vuelve ruido.
hook_source() {
  [ -z "$_HOOK_INPUT" ] && return 0
  printf '%s' "$_HOOK_INPUT" | python3 -c "import json,sys
try:
    print(json.load(sys.stdin).get('source',''))
except Exception:
    print('')" 2>/dev/null
}

# La UNICA escritura a stdout del script. Si la serializacion falla, cae a texto plano con el
# bloque del agente intacto: eso es lo que funciona hoy y es lo que no se puede perder. La
# persona se queda sin mensaje esa sesion; el agente no se queda sin memoria.
emit_output() {
  [ -z "$_AGENT_BUF" ] && [ -z "$_HUMAN_BUF" ] && return 0
  # Nadie delante = nada que decirle. Dos senales, las dos medidas el 2026-09-11:
  #   - `PAPERCLIP_RUN_ID` definida: agente de Paperclip. Sus avisos de secretos y cuarentena
  #     ya estan en el buffer cuando se llega aqui, y sin esto saldrian a una pantalla que no
  #     existe.
  #   - `CLAUDE_CODE_SESSION_ATTENDED=0`: corrida no interactiva. Medido con un hook de
  #     registro: `claude -p` da ATTENDED=0 y ENTRYPOINT=sdk-cli; una sesion interactiva da
  #     ATTENDED=1 y ENTRYPOINT=cli. Solo se apaga con el "0" explicito: si la variable no
  #     existe (CLI mas viejo) se deja pasar, que es el comportamiento de antes.
  hay_persona || _HUMAN_BUF=""
  _JSON_OUT=$(_A="$_AGENT_BUF" _H="$_HUMAN_BUF" python3 -c "import json,os,sys
a = os.environ.get('_A','').strip()
h = os.environ.get('_H','').strip()
o = {'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': a}}
if h:
    o['systemMessage'] = h
sys.stdout.write(json.dumps(o, ensure_ascii=False))" 2>/dev/null)
  if [ -n "$_JSON_OUT" ]; then
    printf '%s' "$_JSON_OUT"
  else
    printf '%s' "$_AGENT_BUF"
  fi
}

# Auto-enable marketplace auto-update (idempotent, runs silently)
KM_FILE="$HOME/.claude/plugins/known_marketplaces.json"
if [ -f "$KM_FILE" ]; then
  HAS_MARKETPLACE=$(python3 -c "
import json
try:
    d = json.load(open('$KM_FILE'))
    m = d.get('3-tier-memory-marketplace')
    if m and not m.get('autoUpdate'):
        print('fix')
    else:
        print('ok')
except: print('ok')
" 2>/dev/null)

  if [ "$HAS_MARKETPLACE" = "fix" ]; then
    python3 -c "
import json
f = '$KM_FILE'
d = json.load(open(f))
d['3-tier-memory-marketplace']['autoUpdate'] = True
json.dump(d, open(f, 'w'), indent=2)
" 2>/dev/null && out "AUTO-UPDATE: enabled for 3-tier-memory marketplace."
  fi
fi

# Detect memory directory (Model B first, then Model A fallback)
if [ -f "$CLAUDE_PROJECT_DIR/memory/_pendientes.md" ]; then
  MEMORY_DIR="$CLAUDE_PROJECT_DIR/memory"
elif [ -d "$HOME/.claude/projects" ]; then
  # Model A: try auto-memory
  ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
  AUTO_DIR="$HOME/.claude/projects/$ENCODED/memory"
  if [ -f "$AUTO_DIR/_pendientes.md" ]; then
    MEMORY_DIR="$AUTO_DIR"
  fi
fi

# Sin sistema de memoria no hay nada que inyectar — pero el buffer puede traer ya el aviso
# de AUTO-UPDATE, que se emitia antes de esta linea. Vaciarlo aqui o se pierde.
[ -z "$MEMORY_DIR" ] && { emit_output; exit 0; }

# Headers de prioridad (v2.12.1): el compactador ancla cada pendiente.add bajo `## Alta/Media/Baja
# prioridad`; instalaciones anteriores a 2.12.0 a veces no los tienen (`## Abiertos`, secciones
# por tema) y el evento iria a cuarentena. Se anaden los que falten, sin tocar nada mas, con
# el lock del journal. Idempotente: con los tres presentes no escribe. Fail-open.
if [ -f "${CLAUDE_PLUGIN_ROOT}/bin/normalize-pendientes.py" ]; then
  NORM_OUT=$(python3 "${CLAUDE_PLUGIN_ROOT}/bin/normalize-pendientes.py" "$MEMORY_DIR" --apply --quiet --budget 1 2>/dev/null)
  if [ -n "$NORM_OUT" ]; then
    out "NORMALIZADO: _pendientes.md — $NORM_OUT (headers de prioridad que faltaban; los items no se movieron)."
    out ""
  fi
fi

# Journal (v2.12.0): aplicar los eventos que otros agentes dejaron en pending/ ANTES de leer
# los indices, para que lo que se inyecta abajo este fresco. Fast path: solo si pending/
# tiene algo (un listado de directorio). Presupuesto corto (1 s esperando el lock): si otro
# compactador lo tiene en ese momento, el aplicara lo pendiente; nada se pierde.
JOURNAL_PENDING="$MEMORY_DIR/.journal/pending"
if [ -f "${CLAUDE_PLUGIN_ROOT}/bin/journal-compact.py" ] && [ -d "$JOURNAL_PENDING" ] \
   && [ -n "$(ls -A "$JOURNAL_PENDING" 2>/dev/null)" ]; then
  JOURNAL_OUT=$(python3 "${CLAUDE_PLUGIN_ROOT}/bin/journal-compact.py" --memory-dir "$MEMORY_DIR" --budget 1 --quiet 2>/dev/null)
  if [ -n "$JOURNAL_OUT" ]; then
    out "$JOURNAL_OUT"
    out ""
  fi
fi
# Deriva fuera del journal (v2.13.2): journal_strict solo cubre Edit/Write/MultiEdit — Bash no
# esta en el matcher del hook, y una sesion en modo auto tiene instruccion de preferir Bash. Esto
# no lo impide: compara el sha256 de cada indice con el que dejo el compactador. Va FUERA del
# bloque de arriba a proposito: aquel solo corre si pending/ tiene algo, y la deriva que interesa
# es justo la de una sesion que no dejo eventos. Barato: hashear media docena de ficheros cortos.
# NO SE MIRA SI NO HAY QUIEN LO LEA, y esa es toda la solucion. `--check-drift` RE-SELLA la
# linea base al detectar, para que el aviso salga una vez y no en cada sesion. Correcto cuando el
# aviso llega; cuando no llega, el re-sellado lo borra para siempre — la deriva se ve una vez, a
# nadie, y no vuelve.
#
# 2.21.2 intento arreglarlo GUARDANDO el aviso en un fichero para el proximo arranque. Tres
# rondas adversariales despues, ese fichero necesitaba tope, deduplicado, escritura sin carrera,
# su propia linea de .gitignore y una migracion para quien ya hubiera actualizado — y cada capa
# traia un defecto nuevo. La deriva YA ES PERSISTENTE: es un hash que no coincide, y sigue ahi
# hasta que alguien re-selle. No hace falta guardar nada; basta con no consumirla.
#
# Lo que se pierde: en una sesion sin persona el AGENTE tampoco ve el aviso. Es el precio, y es
# barato — en esas sesiones no hay nadie que pueda correr `--reseal` de todos modos.
if [ -f "${CLAUDE_PLUGIN_ROOT}/bin/journal-compact.py" ] && [ -d "$MEMORY_DIR/.journal" ] && hay_persona; then
  DRIFT_OUT=$(python3 "${CLAUDE_PLUGIN_ROOT}/bin/journal-compact.py" --memory-dir "$MEMORY_DIR" --check-drift 2>/dev/null)
  if [ -n "$DRIFT_OUT" ]; then
    out "$DRIFT_OUT"
    out ""
    # Y A LA PERSONA. Hasta 2.21.0 la deriva salia SOLO por additionalContext, o sea solo para
    # el agente — el mismo fallo que 2.17.0 arreglo para los pendientes y que aqui seguia vivo.
    # Lo marco el adversario. Importa mas que en otros avisos: si la causa fue un `git pull`,
    # quien lo hizo es la persona, y quien tiene que correr --reseal tambien.
    DRIFT_N=$(printf '%s' "$DRIFT_OUT" | grep -c 'FUERA DEL JOURNAL')
    if [ "${DRIFT_N:-0}" -gt 0 ] 2>/dev/null; then
      human "⚠ MEMORIA: un indice de memory/ cambio sin pasar por el journal. Si acabas de hacer git pull/checkout/merge es esperado y no se pierde nada: corre \`python3 journal-compact.py --memory-dir memory --reseal\`. Si no, alguien lo edito a mano y ese cambio se pierde en la proxima compactacion."
    fi
  fi
fi

# Cuarentena: eventos que no se pudieron aplicar de forma segura (ancla borrada a mano,
# colision de id, JSON roto). Nunca se borran solos; cada uno lleva un .reason al lado.
JOURNAL_Q="$MEMORY_DIR/.journal/quarantine"
if [ -d "$JOURNAL_Q" ]; then
  JOURNAL_QN=$(ls "$JOURNAL_Q" 2>/dev/null | grep -c '\.json$')
  if [ "${JOURNAL_QN:-0}" -gt 0 ] 2>/dev/null; then
    out "⚠ JOURNAL: $JOURNAL_QN evento(s) en cuarentena en memory/.journal/quarantine/ — lee el .reason de cada uno, aplica el cambio a mano si aplica y borra el par .json/.reason."
    human "⚠ JOURNAL: $JOURNAL_QN evento(s) en cuarentena — hay que revisarlos a mano en memory/.journal/quarantine/."
    out ""
  fi
fi

# Frontmatter integrity (detection only — no mutation here). Surfaces typed Tier-3 files
# that slipped through without a frontmatter block; they run degraded (recall default 5).
# Repair via /enrich-3t, or they self-heal on the next /checkpoint-3t (Step 5c seal).
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py" ]; then
  FM_MISSING=$(python3 "${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py" "$MEMORY_DIR" --count 2>/dev/null)
  if [ -n "$FM_MISSING" ] && [ "$FM_MISSING" -gt 0 ] 2>/dev/null; then
    out "⚠ $FM_MISSING archivo(s) de memoria sin frontmatter — corre /enrich-3t para repararlos (o se auto-sellan en el proximo /checkpoint-3t)."
    out ""
  fi
fi

# Hook local duplicado (deteccion, warning-only). Un hook propio del proyecto que vuelca
# _pendientes.md se SUMA a este bloque en vez de reemplazarlo — el usuario paga el corpus
# dos veces, una cruda y una curada, cada sesion. Vive aqui y no solo en /migrate porque
# /migrate es opt-in y se corre una vez al adoptar: esta es la unica superficie que alcanza
# a cada instalacion sin que nadie pida nada.
if [ -n "$CLAUDE_PROJECT_DIR" ]; then
  DUP_HOOK=$(CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" MEMORY_DIR="$MEMORY_DIR" python3 <<'DUPEOF' 2>/dev/null
import json, os, re, shlex, sys

proj = os.environ.get("CLAUDE_PROJECT_DIR", "")
mem = os.environ.get("MEMORY_DIR", "")
EVENTS = ("SessionStart", "UserPromptSubmit", "PreCompact")

INTERPRETES = {"bash", "sh", "zsh", "ksh", "dash", "env",
               "/bin/bash", "/bin/sh", "/bin/zsh", "/usr/bin/env"}
# Prefijos que NO cambian que se ejecuta. "builtin" queda fuera a proposito:
# `builtin bash x.sh` no ejecuta nada (bash no es un builtin), asi que tratarlo
# como transparente reportaria una ejecucion inexistente.
MODIFICADORES = {"exec", "nohup", "command", "time"}
SEPARADORES = {"&&", "||", ";", "|", "&"}

def scripts_ejecutados(command, proj, _depth=0):
    """Rutas .sh que el comando EJECUTA, no las que solo menciona.

    Buscar cualquier ".sh" en el texto reporta un `echo "…/session-start.sh"` o una
    ruta en un comentario como si fuera un hook activo. Un falso positivo aqui manda
    al usuario a /migrate por nada, asi que se exige posicion de ejecucion: primer
    token del segmento, o posterior detras de un interprete. `-c` se sigue hacia
    adentro en vez de aplanarse, porque su argumento es un programa, no una ruta.
    """
    if _depth > 3:
        return []
    try:
        toks = shlex.split(command, posix=True)
    except ValueError:
        toks = command.split()

    out = []
    seg = []
    for tok in toks + ["&&"]:
        if tok in SEPARADORES:
            out.extend(_segmento(seg, proj, _depth))
            seg = []
        else:
            seg.append(tok)
    return out

def _segmento(toks, proj, depth):
    while toks and (toks[0] in MODIFICADORES or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0])):
        toks = toks[1:]
    if not toks:
        return []

    # `sh -c "<programa>"`: el argumento es codigo, se analiza como comando propio.
    # Solo si quien lo recibe ES una shell: `echo -c "bash x.sh"` no ejecuta nada.
    es_shell = toks[0] in INTERPRETES or os.path.basename(toks[0]) in INTERPRETES
    if es_shell and "-c" in toks:
        i = toks.index("-c")
        if i + 1 < len(toks):
            return scripts_ejecutados(toks[i + 1], proj, depth + 1)
        return []

    args = [t for t in toks if not t.startswith("-")]
    if not args:
        return []
    cand = None
    if args[0].endswith(".sh"):
        cand = args[0]
    elif args[0] in INTERPRETES or os.path.basename(args[0]) in INTERPRETES:
        cand = next((t for t in args[1:] if t.endswith(".sh")), None)
    if not cand:
        return []
    # Ruta relativa: se resuelve contra el proyecto, que es el cwd del hook.
    # `startswith("/")` solo reconoce absolutas de POSIX: una ruta de Windows (`C:\\x`) la daba por
    # relativa y la pegaba detras del proyecto. `os.path.isabs` acierta en las dos plataformas, y se
    # conserva el `/` explicito porque en Windows `isabs("/x")` es False y ahi si es absoluta.
    es_abs = os.path.isabs(cand) or cand.startswith("/")
    return [cand if es_abs else os.path.normpath(os.path.join(proj, cand))]

found = []
for name in ("settings.json", "settings.local.json"):
    path = os.path.join(proj, ".claude", name)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        continue
    for event in EVENTS:
        for block in (data.get("hooks", {}) or {}).get(event, []) or []:
            for hook in block.get("hooks", []) or []:
                cmd = hook.get("command", "") or ""
                # El hook del plugin se registra con ${CLAUDE_PLUGIN_ROOT}; no es duplicado de si mismo.
                if "CLAUDE_PLUGIN_ROOT" in cmd:
                    continue
                # Ambas formas de la variable. Y se miran TODOS los segmentos del comando:
                # con un solo candidato, una entrada huerfana al principio esconde al real.
                # `scripts_ejecutados` parte el comando con `shlex.split(posix=True)`, y ahi la
                # barra invertida es un ESCAPE: sustituir una ruta de Windows tal cual
                # (`C:\\Users\\...`) la destruia al tokenizar y el script quedaba sin detectar.
                # Windows acepta barras normales en las rutas, asi que se sustituye esa forma.
                proj_txt = proj.replace("\\", "/")
                expanded = cmd.replace("${CLAUDE_PROJECT_DIR}", proj_txt).replace("$CLAUDE_PROJECT_DIR", proj_txt)
                for script in scripts_ejecutados(expanded, proj):
                    if not os.path.isfile(script):
                        continue   # entrada huerfana: eso lo reporta /migrate, no es duplicacion
                    try:
                        with open(script, encoding="utf-8", errors="replace") as fh:
                            body = fh.read()
                    except Exception:
                        continue
                    if "_pendientes.md" in body and re.search(r"\becho\b", body):
                        found.append((os.path.relpath(script, proj), name))

if not found:
    sys.exit(0)

size = 0
try:
    with open(os.path.join(mem, "_pendientes.md"), encoding="utf-8") as fh:
        size = sum(len(l) for l in fh if l.lstrip().startswith("- [ ]"))
except Exception:
    pass

script, settings = found[0]
extra = f" (+{len(found) - 1} mas)" if len(found) > 1 else ""
if size >= 1024:
    cost = f"vuelca ~{size // 1024} KB de pendientes crudos"
elif size > 0:
    cost = f"vuelca {size} B de pendientes crudos"
else:
    cost = "vuelca los pendientes crudos (hoy el archivo esta vacio, pero crece con el)"
print(f"HOOK DUPLICADO: {script}{extra}, registrado en .claude/{settings}, {cost} "
      f"que este bloque ya inyecta curado — se suma, no reemplaza. "
      f"Corre /migrate para recortarlo conservando lo que ese hook tenga de propio.")
DUPEOF
)
  if [ -n "$DUP_HOOK" ]; then
    out "$DUP_HOOK"
    out ""
  fi
fi

# Plaintext secrets (detection only — no mutation here). Memory committed to a repo with a
# remote leaks any key captured verbatim in a digest. Auto-redacted by /checkpoint-3t Step 5d.
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/scan-secrets.py" ]; then
  SEC_FOUND=$(python3 "${CLAUDE_PLUGIN_ROOT}/bin/scan-secrets.py" "$MEMORY_DIR" --count 2>/dev/null)
  if [ -n "$SEC_FOUND" ] && [ "$SEC_FOUND" -gt 0 ] 2>/dev/null; then
    out "⚠ SECRETS: $SEC_FOUND posible(s) secreto(s) en texto plano en memory/ — corre /checkpoint-3t para redactarlos (Step 5d) y ROTA cualquier key ya pusheada (la redacción no des-filtra el historial)."
    human "⚠ SECRETOS: $SEC_FOUND posible(s) en texto plano en memory/ — corre /checkpoint-3t (Step 5d) y ROTA cualquier key que ya este pusheada: redactarla no la des-filtra."
    out ""
  fi
fi

# Detect if running in Paperclip agent
IS_PAPERCLIP_AGENT=false
[ -n "$PAPERCLIP_RUN_ID" ] && IS_PAPERCLIP_AGENT=true

if [ "$IS_PAPERCLIP_AGENT" = true ]; then
  # Paperclip agent: only inject learnings, no pendientes
  if [ -f "$MEMORY_DIR/_learnings.md" ]; then
    LEARNINGS_COUNT=$(sed -n '/## Quick Reference/,/## Related/p' "$MEMORY_DIR/_learnings.md" 2>/dev/null | grep -cE '^([0-9]+\.|[-*] )')
    LEARNINGS_COUNT=${LEARNINGS_COUNT:-0}
    if [ "$LEARNINGS_COUNT" -gt 0 ]; then
      out "REGLAS CRITICAS: $LEARNINGS_COUNT. Revisa _learnings.md para ver el detalle."
      out ""
    fi
  fi
else
  # CLI: inject pendientes (as directive with inline list) + learnings
  if [ -f "$MEMORY_DIR/_pendientes.md" ]; then
    # El resumen para la persona no vuelve por stdout: se escribe aqui. Ver el bloque
    # "BLOQUE DE LA PERSONA" mas abajo para por que no se usa una sentinela.
    PEND_HUMANO=$(mktemp 2>/dev/null || echo "")
    PENDIENTES_OUTPUT=$(PENDIENTES_FILE="$MEMORY_DIR/_pendientes.md" HUMANO_FILE="$PEND_HUMANO" python3 <<'PYEOF' 2>/dev/null
import os, re, sys
from datetime import date

# La garantia de UTF-8 vive AQUI, con el codigo que imprime, no solo en el `export` del guion que
# lo llama: este bloque tambien se ejecuta suelto (test-parser lo extrae de aqui), y una garantia
# que depende de quien te invoque no es una garantia. En Windows, python codifica stdout con la
# pagina de codigos local cuando va a una tuberia y los guiones largos salian como `?`.
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass

STALE_DAYS = 30  # a pendiente older than this is flagged as suspect-stale

def days_old(created):
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", created or "")
    if not m:
        return None
    try:
        d = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None
    return (date.today() - d).days

path = os.environ.get("PENDIENTES_FILE", "")
try:
    with open(path, encoding="utf-8") as f:
        content = f.read()
except Exception:
    sys.exit(0)

PRIORITY_ORDER = ["alta", "media", "baja", "otros"]
# Secciones no reconocidas caen en "otros" en vez de descartarse: un archivo con
# encabezados custom perdia esos items Y reportaba un total falso en el header.
# Secciones de documentacion/cierre. Anclado al FINAL a proposito: con match por prefijo,
# "## Scope expansion tasks" o "## Notas pendientes" —secciones vivas— se tragaban enteras.
# Se admite solo un sufijo acotado (parentesis, fecha, "este archivo"), nunca texto libre.
NON_PENDIENTE_RE = re.compile(
    r"^## (?:c[oó]mo usar(?: este archivo)?|related|relacionad[oa]s?|completad[oa]s?"
    r"|scope|notas?)\s*(?:\([^)]*\)|[-–—:]?\s*\d{4}-\d{2}-\d{2})?\s*$")
buckets = {p: [] for p in PRIORITY_ORDER}
odd_sections = []   # headers fuera del esquema de prioridad
skipped = 0         # items bajo secciones cerradas, excluidos a proposito
skip_sections = []  # que secciones los contienen (se reportan, no se ocultan)
seen_headers = set()
dup_headers = []
# Un item puede vivir antes del primer "## " (preambulo del archivo). Descartarlo es el
# mismo fallo silencioso que este parser vino a arreglar, asi que arranca en "otros".
current = "otros"
current_skip_header = ""
_lines = content.splitlines()
_first = next((i for i, l in enumerate(_lines) if l.strip()), None)
_fm_open = _first is not None and _lines[_first].strip() == "---"
for idx, line in enumerate(_lines):
    s = line.strip()
    low = s.lower()
    if _fm_open:
        if idx == _first:
            continue
        if s == "---":
            _fm_open = False
        continue
    if low.startswith("## "):
        if low in seen_headers:
            dup_headers.append(s)
        seen_headers.add(low)
    if low.startswith("## alta"):
        current = "alta"
    elif low.startswith("## media"):
        current = "media"
    elif low.startswith("## baja"):
        current = "baja"
    elif low.startswith("## "):
        if NON_PENDIENTE_RE.match(low):
            current = "skip"
            current_skip_header = s
        else:
            current = "otros"
            odd_sections.append(s)
    elif current == "skip" and re.match(r"^- \[ \]", s):
        skipped += 1   # item en seccion cerrada (Completados/Scope): no se inyecta a proposito
        skip_sections.append(current_skip_header)
    elif current and re.match(r"^- \[ \]", s):
        m = re.search(r"_creado:\s*(\d{4}-\d{2}-\d{2})", s)
        created = m.group(1) if m else None
        text = s[6:]
        text = re.sub(r"\s*—\s*_origen:[^—]*", "", text)
        text = re.sub(r"\s*—\s*_creado:[^—]*", "", text)
        text = re.sub(r"\s*—\s*_id:[^—]*", "", text)   # identidad del journal (v2.12.0), no es texto
        text = re.sub(r"\s*—\s*_revisar:[^—]*", "", text)  # ventana declarada (v2.13.0), no es texto
        text = text.strip()
        buckets[current].append((created or "9999", text))

total = sum(len(v) for v in buckets.values())

# Auto-verificacion del parseo. Un fallo de parseo aqui es INVISIBLE: el header
# imprime un total plausible y nadie lo compara contra el archivo (unifi-expert
# inyecto 0 de 15 pendientes durante meses y se veia igual que "no hay nada").
# Estas dos senales convierten cualquier drift de estructura en algo que se ve.
raw_total = len(re.findall(r"(?m)^[ \t]*- \[ \]", content)) - skipped
notes = []
if odd_sections:
    uniq = list(dict.fromkeys(odd_sections))
    shown_secs = ", ".join(uniq[:3]) + (f" [+{len(uniq) - 3} mas]" if len(uniq) > 3 else "")
    notes.append("seccion(es) fuera del esquema Alta/Media/Baja, cuyos items se inyectan "
                 "arriba como SIN CLASIFICAR: "
                 + shown_secs
                 + " — mueve esos items a Alta/Media/Baja prioridad para que se prioricen")
if dup_headers:
    notes.append("encabezado(s) duplicado(s): " + ", ".join(dict.fromkeys(dup_headers)))
if skipped:
    uniq_skip = list(dict.fromkeys(skip_sections))
    notes.append(f"{skipped} item(s) '- [ ]' bajo secciones cerradas ("
                 + ", ".join(uniq_skip[:3])
                 + (f" [+{len(uniq_skip) - 3} mas]" if len(uniq_skip) > 3 else "")
                 + ") — no se inyectan")
if raw_total != total:
    notes.append(f"el archivo tiene {raw_total} lineas '- [ ]' pero se clasificaron {total} "
                 f"— {abs(raw_total - total)} quedaron fuera del conteo")
if total == 0:
    # Sin items clasificados el bloque no se imprime — pero si el archivo TENIA lineas
    # "- [ ]" en algun lado, callarse aqui es exactamente el fallo original.
    if notes:
        print("ESTRUCTURA de _pendientes.md: " + "; ".join(notes) + ".")
    sys.exit(0)

for k in buckets:
    buckets[k].sort(key=lambda x: x[0])

selected = []
for prio in PRIORITY_ORDER:
    for it in buckets[prio]:
        selected.append((prio, it))

# El cuerpo completo de un pendiente puede pasar de 900 chars; inyectarlo entero en
# CADA sesion ahoga el prompt real del usuario. Se trunca a la primera frase util —
# el detalle vive en _pendientes.md, que el agente abre si el item resulta relevante.
BODY_CAP = 120

def shorten(text):
    if len(text) <= BODY_CAP:
        return text
    cut = text[:BODY_CAP]
    sp = cut.rfind(" ")
    if sp > BODY_CAP * 0.6:
        cut = cut[:sp]
    cut = cut.rstrip(" ,;:—-")
    if cut.count("**") % 2:  # no dejar un bold abierto
        cut += "**"
    return cut + "…"

# --- BLOQUE DEL AGENTE: conteo + ALTA inline + instruccion.
# Hasta 2.17.0 listaba tambien MEDIA/BAJA hasta un cap de 10 y cerraba con "[+N mas]".
# Lo medido: el agente veia el inventario entero en CADA sesion y los pendientes seguian
# subiendo igual (2026-09-11: 54 abiertos, 14 con mas de 30 dias). Cerrar un pendiente es una
# decision de la persona, y hasta esta version el inventario no llegaba a ninguna persona.
# La relevancia por peticion ya la cubre recall.sh (UserPromptSubmit, v2.8.0) — es lo que de
# verdad hace que el agente cruce peticion vs memoria, y llega en el momento que importa.
# Queda ALTA inline (regla 20 de _learnings.md: contenido, no contadores, que sigue viva para
# lo urgente) y el resto vive en _pendientes.md, que el agente abre cuando la peticion lo pide.
# `otros` entra con ALTA, no con el resto: no son items de prioridad media, son items que
# NADIE ha clasificado (seccion fuera del esquema, o preambulo del archivo). Esconderlos es
# el fallo de la regla 11 de _learnings.md — descartar y luego contar — que este parser vino
# a arreglar: el archivo de unifi-expert inyectaba 0 de 15 y el header decia 15.
CEILING = 25
altas = [x for x in selected if x[0] == "alta"]
otros = [x for x in selected if x[0] == "otros"]
shown = (altas + otros)[:CEILING]

print(f"PENDIENTES ABIERTOS ({total}), {len(shown)} de prioridad ALTA o sin clasificar. Antes de responder, "
      f"verifica si la peticion del usuario se relaciona con alguno de estos items o con el "
      f"resto de memory/_pendientes.md — si lo resuelves durante la sesion, marcalo en "
      f"/checkpoint-3t:")
print()
if shown:
    last = None
    for prio, (created, text) in shown:
        if prio != last:
            print("ALTA:" if prio == "alta" else "SIN CLASIFICAR:")
            last = prio
        if created != "9999":
            age = days_old(created)
            stale = " ⚠ posible stale — reconciliar" if age is not None and age > STALE_DAYS else ""
            print(f"  - [ ] {shorten(text)} — _creado: {created}_{stale}")
        else:
            print(f"  - [ ] {shorten(text)}")
    if len(altas) + len(otros) > CEILING:
        print(f"[+ {len(altas) + len(otros) - CEILING} de ALTA o sin clasificar mas — abre _pendientes.md]")
else:
    print("  (ninguno de prioridad ALTA ni sin clasificar — el resto esta en memory/_pendientes.md)")

if any(days_old(c) is not None and days_old(c) > STALE_DAYS for _, (c, _t) in shown):
    print()
    print(f"Items marcados ⚠ tienen >{STALE_DAYS} dias sin cerrar — probables candidatos a resolved/abandoned en /checkpoint-3t Step 3a.")

if notes:
    print()
    print("ESTRUCTURA de _pendientes.md: " + "; ".join(notes) + ".")

# --- BLOQUE DE LA PERSONA. Va a un fichero aparte, NO a stdout: la primera version lo
# separaba con una sentinela en la misma salida, y un pendiente cuyo texto contuviera esa
# sentinela partia el mensaje por donde no debia — mandando texto del pendiente al canal de
# la persona y perdiendo el resto. Con dos destinos distintos esa clase de fallo no existe.
# Es corto a proposito: un aviso que ocupa media pantalla en cada arranque se aprende a
# ignorar, y entonces vuelve a no existir.
hpath = os.environ.get("HUMANO_FILE", "")
if hpath:
    viejos = sorted([(c, t) for _p, (c, t) in selected if c != "9999"], key=lambda x: x[0])
    stale_n = sum(1 for c, _t in viejos if (days_old(c) or 0) > STALE_DAYS)
    cab = f"MEMORIA 3T — {total} pendientes abiertos"
    cab += f", {stale_n} sin cerrar desde hace mas de {STALE_DAYS} dias." if stale_n else "."
    lineas = [cab]
    if viejos[:3]:
        lineas.append("Los mas antiguos:")
        for c, t in viejos[:3]:
            lineas.append(f"  · {shorten(t)}  ({c}, {days_old(c)} dias)")
    lineas.append("Cierra o descarta con /triage-3t. Para reconciliarlos uno a uno: /checkpoint-3t Step 3a.")
    try:
        with open(hpath, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lineas) + "\n")
    except Exception:
        pass   # sin canal a la persona esta sesion; el del agente no depende de esto
PYEOF
)

    if [ -n "$PENDIENTES_OUTPUT" ]; then
      out "$PENDIENTES_OUTPUT"
      out ""
    fi
    if [ -n "$PEND_HUMANO" ]; then
      [ -s "$PEND_HUMANO" ] && human "$(cat "$PEND_HUMANO")"
      rm -f "$PEND_HUMANO"
    fi
  fi

  if [ -f "$MEMORY_DIR/_learnings.md" ]; then
    LEARNINGS_COUNT=$(sed -n '/## Quick Reference/,/## Related/p' "$MEMORY_DIR/_learnings.md" 2>/dev/null | grep -cE '^([0-9]+\.|[-*] )')
    LEARNINGS_COUNT=${LEARNINGS_COUNT:-0}
    if [ "$LEARNINGS_COUNT" -gt 0 ]; then
      out "REGLAS CRITICAS: $LEARNINGS_COUNT. Revisa _learnings.md para ver el detalle."
      out ""
    fi
  fi
fi

# Migrate old command names to -3t suffix (one-time, for existing installs)
CMDS_DIR="$CLAUDE_PROJECT_DIR/.claude/commands"
TEMPLATES_DIR="${CLAUDE_PLUGIN_ROOT}/templates"
MIGRATED=""

# Si la sesion se abrio desde $HOME, "$CLAUDE_PROJECT_DIR/.claude/commands" ES
# ~/.claude/commands — o sea el ambito USER, no el del proyecto. Instalar ahi deja
# cada comando duplicado (user + project) en TODOS los demas proyectos, para siempre,
# y el usuario no tiene como saber de donde salio. El hook sigue inyectando memoria
# normalmente; lo unico que se salta es la escritura de comandos.
if [ "$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)" = "$(cd "$HOME" 2>/dev/null && pwd -P)" ]; then
  out "AVISO: la sesion se abrio desde \$HOME, asi que .claude/commands/ es el ambito USER (global)."
  out "No se instalan los comandos -3t aqui: apareceria un duplicado user+project en cada proyecto."
  out "Abre la sesion desde el directorio del proyecto para que se instalen donde corresponde."
  out ""
  SKIP_CMD_INSTALL=1
fi

for old_cmd in checkpoint status audit backfill; do
  [ -n "${SKIP_CMD_INSTALL:-}" ] && break
  OLD_FILE="$CMDS_DIR/$old_cmd.md"
  NEW_FILE="$CMDS_DIR/${old_cmd}-3t.md"
  if [ -f "$OLD_FILE" ] && [ ! -f "$NEW_FILE" ]; then
    mv "$OLD_FILE" "$NEW_FILE"
    MIGRATED="$MIGRATED /$old_cmd→/${old_cmd}-3t"
  fi
done

if [ -n "$MIGRATED" ]; then
  out "MIGRADO:$MIGRATED (renamed to avoid collisions with global skills)."
  out ""
fi

# Auto-update local commands if plugin has newer versions (also installs missing ones)
UPDATED=""
INSTALLED=""

for cmd in checkpoint-3t status-3t audit-3t backfill-3t save-learning consolidate-3t enrich-3t triage-3t; do
  [ -n "${SKIP_CMD_INSTALL:-}" ] && break
  LOCAL_CMD="$CMDS_DIR/$cmd.md"
  PLUGIN_CMD="$TEMPLATES_DIR/$cmd.md"
  if [ -f "$PLUGIN_CMD" ]; then
    if [ ! -f "$LOCAL_CMD" ]; then
      mkdir -p "$CMDS_DIR"
      cp "$PLUGIN_CMD" "$LOCAL_CMD"
      INSTALLED="$INSTALLED /$cmd"
    elif ! diff -q "$LOCAL_CMD" "$PLUGIN_CMD" >/dev/null 2>&1; then
      cp "$PLUGIN_CMD" "$LOCAL_CMD"
      UPDATED="$UPDATED /$cmd"
    fi
  fi
done

if [ -n "$INSTALLED" ]; then
  out "INSTALADO:$INSTALLED (nuevos comandos del plugin)."
  out ""
fi

if [ -n "$UPDATED" ]; then
  out "ACTUALIZADO:$UPDATED se actualizaron a la version mas reciente del plugin."
  out ""
fi

# Notify if JSONL backfill is pending
#
# El contador cuenta FICHEROS QUE SIGUEN EN DISCO Y NO ESTAN RESUELTOS. No es una resta de totales.
# La version anterior hacia `ls *.jsonl | wc -l` - len(processed) - 1, y se equivocaba por tres
# lados a la vez (medido en esta instalacion: decia 12 donde lo correcto son 6):
#   1. Ignoraba `skipped[]`, que para /backfill-3t vale lo mismo que `processed[]` — su propia
#      regla dice "Already processed: filename appears in processed **or skipped** arrays -> skip".
#      Toda instalacion que salte sesiones legitimamente (triviales, ya en memoria) se quedaba con
#      el aviso BACKFILL PENDIENTE encendido para siempre. Aqui son 17 entradas.
#   2. Restaba UUIDs que ya no estan en disco. Claude Code borra .jsonl viejos; cada uno que
#      desaparece sigue ocupando su sitio en `processed`/`skipped` y desplaza el numero. Aqui 11
#      de las 18 entradas del progreso son fantasmas.
#   3. Restaba 1 a ciegas "por la sesion actual", que sobra si ese .jsonl aun no existe o si ya
#      esta en processed. Ahora se excluye POR NOMBRE, con `transcript_path`/`session_id` del
#      payload del hook ($_HOOK_INPUT, que bufferiza resolve-project-dir.sh).
#
# SIN PAYLOAD NO SE RESTA NADA, a proposito. Hubo una version con heuristica de mtime (descartar
# el .jsonl escrito en los ultimos 5 minutos) y el adversario la tumbo: no es una prueba de
# identidad, asi que puede descartar un fichero historico recien tocado y SILENCIAR una sesion
# pendiente de verdad. Entre los dos fallos posibles, contar 1 de mas es visible y se corrige solo
# en cuanto llega un payload; silenciar no se ve nunca.
# Lo que esta MEDIDO: en esta instalacion el payload de SessionStart trae `session_id` y
# `transcript_path`, y el contador da el numero exacto. Lo que NO esta auditado: si algun otro
# host, modo o version invoca este hook sin stdin. Si eso pasa, el aviso se queda 1 por encima
# mientras dure — visible y acotado, no el aviso permanente de 12 que este arreglo quita.
#
# Paridad con el glob de antes: se saltan los dotfiles (`.recall-index.jsonl`) y se exige
# `isfile`, porque un DIRECTORIO llamado `algo.jsonl` lo listaba `ls` por su contenido y
# `os.listdir` lo contaba como una sesion.
# Fallos: progreso ausente, ilegible o con tipos que no son los del contrato = nada resuelto, y
# avisa (es el caso de instalacion nueva); fallo del propio python = REMAINING vacio y NO avisa,
# antes que publicar una cifra inventada.
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
JSONL_DIR="$HOME/.claude/projects/$ENCODED"
if [ -d "$JSONL_DIR" ]; then
  REMAINING=$(_HOOK_INPUT="${_HOOK_INPUT:-}" python3 - "$JSONL_DIR" <<'PYEOF' 2>/dev/null
import json, os, sys

d = sys.argv[1]


def stem(name):
    name = os.path.basename(str(name or ""))
    return name[:-6] if name.endswith(".jsonl") else name


def is_session_file(name):
    if not name.endswith(".jsonl") or name.startswith("."):
        return False
    return os.path.isfile(os.path.join(d, name))


pending = {stem(f) for f in os.listdir(d) if is_session_file(f)}

# `processed` y `skipped` valen lo mismo: los dos significan "resuelto, no volver a tocarlo".
# Validacion en dos niveles, distintos a proposito:
#   - la CLAVE que no sea una lista (un numero, un string, null) vale VACIA entera — asi un JSON
#     valido con tipos raros no puebla `done` a medias antes de fallar;
#   - dentro de una lista, el ELEMENTO que no sea una cadena no vacia se ignora uno a uno, y los
#     demas se honran. Tirar la lista entera por un elemento basura descartaria trabajo real ya
#     hecho; un elemento-cadena basura solo puede descontar si coincide con un fichero en disco,
#     que es justo lo que significa estar en la lista.
# Los dos niveles fallan hacia contar de mas, que es la direccion visible.
done = set()
try:
    with open(os.path.join(d, ".backfill-progress.json")) as fh:
        prog = json.load(fh)
    if isinstance(prog, dict):
        for key in ("processed", "skipped"):
            entries = prog.get(key)
            if not isinstance(entries, list):
                continue
            for name in entries:
                if isinstance(name, str) and name.strip():
                    done.add(stem(name))
except Exception:
    done = set()  # sin progreso utilizable: nada resuelto

pending -= done

current = ""
try:
    payload = json.loads(os.environ.get("_HOOK_INPUT") or "{}")
    if isinstance(payload, dict):
        current = stem(payload.get("transcript_path")) or stem(payload.get("session_id"))
except Exception:
    current = ""

if current:
    pending.discard(current)

print(len(pending))
PYEOF
)
  if [ -n "$REMAINING" ] && [ "$REMAINING" -gt 0 ]; then
    out "BACKFILL PENDIENTE: $REMAINING sesiones sin procesar. Run /backfill-3t to import past sessions."
    out ""
  fi
fi

if [ "$IS_PAPERCLIP_AGENT" = true ]; then
  out "PROTOCOLO: Usar /save-learning cuando descubras un patron o regla nueva."
else
  out "PROTOCOLO: Dual-write siempre (indice + archivo detalle) para sessions, pendientes y learnings. Plans y research solo si aplica."
  out "Usar /checkpoint-3t para guardar progreso."
fi

# Nada puede imprimir despues de esto.
emit_output
