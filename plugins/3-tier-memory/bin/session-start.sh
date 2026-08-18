#!/bin/bash
# 3-tier-memory plugin: SessionStart hook
# Injects open pendientes AND learnings at session start

source "$(dirname "$0")/resolve-project-dir.sh"

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
" 2>/dev/null && echo "AUTO-UPDATE: enabled for 3-tier-memory marketplace."
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

# Exit silently if no memory system found
[ -z "$MEMORY_DIR" ] && exit 0

# Frontmatter integrity (detection only — no mutation here). Surfaces typed Tier-3 files
# that slipped through without a frontmatter block; they run degraded (recall default 5).
# Repair via /enrich-3t, or they self-heal on the next /checkpoint-3t (Step 5c seal).
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py" ]; then
  FM_MISSING=$(python3 "${CLAUDE_PLUGIN_ROOT}/bin/ensure-frontmatter.py" "$MEMORY_DIR" --count 2>/dev/null)
  if [ -n "$FM_MISSING" ] && [ "$FM_MISSING" -gt 0 ] 2>/dev/null; then
    echo "⚠ $FM_MISSING archivo(s) de memoria sin frontmatter — corre /enrich-3t para repararlos (o se auto-sellan en el proximo /checkpoint-3t)."
    echo ""
  fi
fi

# Hook local duplicado (deteccion, warning-only). Un hook propio del proyecto que vuelca
# _pendientes.md se SUMA a este bloque en vez de reemplazarlo — el usuario paga el corpus
# dos veces, una cruda y una curada, cada sesion. Vive aqui y no solo en /migrate porque
# /migrate es opt-in y se corre una vez al adoptar: esta es la unica superficie que alcanza
# a cada instalacion sin que nadie pida nada.
if [ -n "$CLAUDE_PROJECT_DIR" ]; then
  DUP_HOOK=$(CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR" MEMORY_DIR="$MEMORY_DIR" python3 <<'DUPEOF' 2>/dev/null
import json, os, re, sys

proj = os.environ.get("CLAUDE_PROJECT_DIR", "")
mem = os.environ.get("MEMORY_DIR", "")
EVENTS = ("SessionStart", "UserPromptSubmit", "PreCompact")

INTERPRETES = {"bash", "sh", "zsh", "ksh", "dash", "env",
               "/bin/bash", "/bin/sh", "/bin/zsh", "/usr/bin/env"}
MODIFICADORES = {"exec", "nohup", "command", "time", "builtin"}

def scripts_ejecutados(command):
    """Rutas .sh que el comando EJECUTA, no las que solo menciona.

    Buscar cualquier ".sh" en el texto reporta un `echo "…/session-start.sh"` o una
    ruta dentro de un comentario como si fuera un hook activo. Un falso positivo aqui
    manda al usuario a /migrate por nada, asi que se exige posicion de ejecucion:
    primer token del segmento, o segundo detras de un interprete.
    """
    out = []
    for seg in re.split(r"&&|\|\||[;|]", command):
        toks = [t.strip("\"'") for t in seg.split()]
        toks = [t for t in toks if t and not t.startswith("-")]
        # Prefijos que no cambian que se ejecuta: `exec bash x.sh`, `nohup bash x.sh`,
        # `command bash x.sh`, `VAR=1 bash x.sh`. Sin esto el script real queda invisible.
        while toks and (toks[0] in MODIFICADORES or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0])):
            toks = toks[1:]
        if not toks:
            continue
        cand = None
        if toks[0].endswith(".sh"):
            cand = toks[0]
        elif toks[0] in INTERPRETES or os.path.basename(toks[0]) in INTERPRETES:
            cand = next((t for t in toks[1:] if t.endswith(".sh")), None)
        if not cand:
            continue
        # Ruta relativa: se resuelve contra el proyecto, que es el cwd del hook.
        out.append(cand if cand.startswith("/") else os.path.normpath(os.path.join(proj, cand)))
    return out

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
                expanded = cmd.replace("${CLAUDE_PROJECT_DIR}", proj).replace("$CLAUDE_PROJECT_DIR", proj)
                for script in scripts_ejecutados(expanded):
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
    echo "$DUP_HOOK"
    echo ""
  fi
fi

# Plaintext secrets (detection only — no mutation here). Memory committed to a repo with a
# remote leaks any key captured verbatim in a digest. Auto-redacted by /checkpoint-3t Step 5d.
if [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/bin/scan-secrets.py" ]; then
  SEC_FOUND=$(python3 "${CLAUDE_PLUGIN_ROOT}/bin/scan-secrets.py" "$MEMORY_DIR" --count 2>/dev/null)
  if [ -n "$SEC_FOUND" ] && [ "$SEC_FOUND" -gt 0 ] 2>/dev/null; then
    echo "⚠ SECRETS: $SEC_FOUND posible(s) secreto(s) en texto plano en memory/ — corre /checkpoint-3t para redactarlos (Step 5d) y ROTA cualquier key ya pusheada (la redacción no des-filtra el historial)."
    echo ""
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
      echo "REGLAS CRITICAS: $LEARNINGS_COUNT. Revisa _learnings.md para ver el detalle."
      echo ""
    fi
  fi
else
  # CLI: inject pendientes (as directive with inline list) + learnings
  if [ -f "$MEMORY_DIR/_pendientes.md" ]; then
    PENDIENTES_OUTPUT=$(PENDIENTES_FILE="$MEMORY_DIR/_pendientes.md" python3 <<'PYEOF' 2>/dev/null
import os, re, sys
from datetime import date

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
    notes.append("seccion(es) fuera del esquema Alta/Media/Baja, mostradas al final como OTROS: "
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

# ALTA nunca se recorta por cap: esconder un item de alta prioridad es peor que el
# costo de mostrarlo. El cap aplica al resto, con techo duro por seguridad.
CAP = 10
CEILING = 25
altas = [x for x in selected if x[0] == "alta"]
resto = [x for x in selected if x[0] != "alta"]
shown = (altas + resto[: max(0, CAP - len(altas))])[:CEILING]
extra = total - len(shown)

print(f"PENDIENTES ABIERTOS ({total}). Antes de responder, verifica si la peticion del usuario se relaciona con alguno de estos items — si lo resuelves durante la sesion, marcalo en /checkpoint-3t:")
print()
last = None
for prio, (created, text) in shown:
    if prio != last:
        print(f"{prio.upper()}:")
        last = prio
    if created != "9999":
        age = days_old(created)
        stale = " ⚠ posible stale — reconciliar" if age is not None and age > STALE_DAYS else ""
        print(f"  - [ ] {shorten(text)} — _creado: {created}_{stale}")
    else:
        print(f"  - [ ] {shorten(text)}")
if extra > 0:
    print()
    if len(altas) > CEILING:
        print(f"[+ {extra} mas — revisa _pendientes.md. OJO: solo {CEILING} de {len(altas)} ALTA caben aqui]")
    else:
        print(f"[+ {extra} mas — revisa _pendientes.md]")
if any(days_old(c) is not None and days_old(c) > STALE_DAYS for _, (c, _t) in shown):
    print()
    print(f"Items marcados ⚠ tienen >{STALE_DAYS} dias sin cerrar — probables candidatos a resolved/abandoned en /checkpoint-3t Step 3a.")

if notes:
    print()
    print("ESTRUCTURA de _pendientes.md: " + "; ".join(notes) + ".")
PYEOF
)

    if [ -n "$PENDIENTES_OUTPUT" ]; then
      echo "$PENDIENTES_OUTPUT"
      echo ""
    fi
  fi

  if [ -f "$MEMORY_DIR/_learnings.md" ]; then
    LEARNINGS_COUNT=$(sed -n '/## Quick Reference/,/## Related/p' "$MEMORY_DIR/_learnings.md" 2>/dev/null | grep -cE '^([0-9]+\.|[-*] )')
    LEARNINGS_COUNT=${LEARNINGS_COUNT:-0}
    if [ "$LEARNINGS_COUNT" -gt 0 ]; then
      echo "REGLAS CRITICAS: $LEARNINGS_COUNT. Revisa _learnings.md para ver el detalle."
      echo ""
    fi
  fi
fi

# Migrate old command names to -3t suffix (one-time, for existing installs)
CMDS_DIR="$CLAUDE_PROJECT_DIR/.claude/commands"
TEMPLATES_DIR="${CLAUDE_PLUGIN_ROOT}/templates"
MIGRATED=""

for old_cmd in checkpoint status audit backfill; do
  OLD_FILE="$CMDS_DIR/$old_cmd.md"
  NEW_FILE="$CMDS_DIR/${old_cmd}-3t.md"
  if [ -f "$OLD_FILE" ] && [ ! -f "$NEW_FILE" ]; then
    mv "$OLD_FILE" "$NEW_FILE"
    MIGRATED="$MIGRATED /$old_cmd→/${old_cmd}-3t"
  fi
done

if [ -n "$MIGRATED" ]; then
  echo "MIGRADO:$MIGRATED (renamed to avoid collisions with global skills)."
  echo ""
fi

# Auto-update local commands if plugin has newer versions (also installs missing ones)
UPDATED=""
INSTALLED=""

for cmd in checkpoint-3t status-3t audit-3t backfill-3t save-learning consolidate-3t enrich-3t; do
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
  echo "INSTALADO:$INSTALLED (nuevos comandos del plugin)."
  echo ""
fi

if [ -n "$UPDATED" ]; then
  echo "ACTUALIZADO:$UPDATED se actualizaron a la version mas reciente del plugin."
  echo ""
fi

# Notify if JSONL backfill is pending
ENCODED=$(echo "$CLAUDE_PROJECT_DIR" | sed 's/[^A-Za-z0-9]/-/g')
JSONL_DIR="$HOME/.claude/projects/$ENCODED"
if [ -d "$JSONL_DIR" ]; then
  JSONL_COUNT=$(ls "$JSONL_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
  PROCESSED=0
  PROGRESS_FILE="$JSONL_DIR/.backfill-progress.json"
  if [ -f "$PROGRESS_FILE" ]; then
    PROCESSED=$(python3 -c "import json; print(len(json.load(open('$PROGRESS_FILE')).get('processed',[])))" 2>/dev/null || echo 0)
  fi
  REMAINING=$((JSONL_COUNT - PROCESSED - 1))  # -1 for current session
  if [ "$REMAINING" -gt 0 ]; then
    echo "BACKFILL PENDIENTE: $REMAINING sesiones sin procesar. Run /backfill-3t to import past sessions."
    echo ""
  fi
fi

if [ "$IS_PAPERCLIP_AGENT" = true ]; then
  echo "PROTOCOLO: Usar /save-learning cuando descubras un patron o regla nueva."
else
  echo "PROTOCOLO: Dual-write siempre (indice + archivo detalle) para sessions, pendientes y learnings. Plans y research solo si aplica."
  echo "Usar /checkpoint-3t para guardar progreso."
fi
