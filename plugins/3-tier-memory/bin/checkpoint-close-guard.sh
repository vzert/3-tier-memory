#!/bin/bash
# sella-huellas: no (hook de solo lectura: lee el transcript y la ficha, y bloquea o avisa)
# 3-tier-memory plugin: Stop hook — el cierre de /checkpoint-3t tiene que LLEGAR al usuario.
#
# POR QUE EXISTE (2.33.0, p-daf3051915). La sesion 5790b9f2 de este repo cerro su propio
# checkpoint cuatro veces seguidas con defectos que el usuario tuvo que senalar a mano:
#   (3) el recordatorio de calendario quedo persistido en la ficha y la respuesta solo decia
#       "ademas deje un recordatorio... persistido en la ficha" — sin el bloque para copiarlo;
#   (4) el snippet `Como retomar` salio de print-como-retomar.py dentro de un tool result, que el
#       usuario no ve, y la respuesta pego solo el del calendario.
# Step 8b ya lo sabia y lo escribio como limite: "elimina la SUSTITUCION, no la OMISION; eso
# requeriria un hook que audite la respuesta final". Este es ese hook. La instruccion "pega la
# salida del script tal cual" se omitio dos veces en la misma sesion: la prosa no es garantia.
#
# Desde 2.40.0 tambien exige la salida de Step 7a (chequeo 4 de `revisar`): antes lo vigilaba un
# PreToolUse en el commit del checkpoint, que es ANTERIOR al audit y avisaba en falso.
#
# Ademas corre `checkpoint-audit.py --solo-snippet` sobre la ficha: Step 7a corre ANTES de que
# Step 8 escriba el snippet, asi que los checks `snippet.*` (defectos 1 y 2: Proximo paso
# bloqueado por un tercero, caso 4 generico, paso sin `_id`) nunca veian el snippet final en el
# flujo normal. Aqui se miden sobre la ficha tal como quedo al terminar el turno.
#
# CUANDO MIRA. Solo en un turno que cerro (o rehizo) un checkpoint:
#   - invoco /checkpoint-3t (Skill o comando), o
#   - corrio print-como-retomar.py, o
#   - edito con Edit/MultiEdit una ficha de memory/sessions/ tocando `## Como retomar`,
#     `Proximo paso:` o `## Recordatorios de calendario`, o
#   - cerro, caduco o bloqueo un pendiente que cita el `## Como retomar` de una ficha de esta
#     sesion: con `journal-emit.py` en el comando (2.33.1), o con `expire-pendientes.py --apply`,
#     cuyos ids se leen de su linea final `EXPIRE ids:` (2.36.0).
# En cualquier otro turno se calla: un Stop que habla en cada turno se aprende a ignorar. Un
# `Write` de ficha NO dispara por si solo (lo hace /backfill-3t con decenas de fichas).
#
# QUE CUENTA COMO "EN LA RESPUESTA". Los bloques `text` del assistant desde el ultimo mensaje real
# del usuario, mas `last_assistant_message` (el transcript puede no traer aun el ultimo). NUNCA un
# tool_result: ese es exactamente el defecto (4). Se compara linea a linea, con los espacios
# colapsados, para que un fence ```markdown o un espacio final no cuenten como omision.
#
# QUE HACE. Si falta algo: {"decision":"block","reason":...} — Claude sigue el turno y lo pega.
# Una sola vez: en el Stop reentrante (`stop_hook_active`) ya no bloquea (evita un bucle), avisa
# al usuario con `systemMessage`. Limite conocido: una segunda omision seguida pasa, con aviso.
# Falla abierto en silencio ante cualquier error propio (transcript ilegible, ficha ausente).

source "$(dirname "$0")/resolve-project-dir.sh"

HOOK_INPUT="$_HOOK_INPUT" BIN_DIR="$(cd "$(dirname "$0")" && pwd)" python3 - <<'PY'
import json, os, re, shlex, subprocess, sys

for _f in (sys.stdout, sys.stderr):
    if hasattr(_f, "reconfigure"):
        _f.reconfigure(encoding="utf-8")

BIN = os.environ.get("BIN_DIR", "")
try:
    d = json.loads(os.environ.get("HOOK_INPUT", "") or "{}")
except Exception:
    sys.exit(0)

reentrante = bool(d.get("stop_hook_active"))
lam = d.get("last_assistant_message")
lam = lam if isinstance(lam, str) else ""
cwd = d.get("cwd") or os.getcwd()
tpath = d.get("transcript_path") or ""
if not tpath or not os.path.isfile(tpath):
    sys.exit(0)
TOPE = int(os.environ.get("_GUARD_TOPE_BYTES") or 0) or 256 * 1024 * 1024
try:
    if os.path.getsize(tpath) > TOPE:
        sys.exit(0)
    with open(tpath, encoding="utf-8", errors="replace") as fh:
        recs = []
        for linea in fh:
            linea = linea.strip()
            if not linea:
                continue
            try:
                recs.append(json.loads(linea))
            except Exception:
                continue
except Exception:
    sys.exit(0)


# La etiqueta del comando tecleado: `/checkpoint-3t` o, si llega con espacio de nombres, `/<x>:checkpoint-3t`
# (adversario de 2.42.0: la forma con prefijo no disparaba nada).
TAG_CHECKPOINT = re.compile(r"<command-name>/(?:[\w.-]+:)?checkpoint-3t</command-name>")


# Mensajes que el harness inyecta como `user` a mitad de un turno y que NO son un prompt del
# usuario: un teammate que escribe, una notificacion de tarea en segundo plano. Contarlos como
# inicio de turno dejaba el cierre del checkpoint FUERA del turno mirado y el hook se callaba
# (adversario externo, ronda 1: la forma existe en el propio transcript 5790b9f2).
INYECTADO = re.compile(r"^\s*(?:Another Claude session sent a message|<teammate-message|"
                       r"<task-notification>|\[SYSTEM NOTIFICATION)")


def es_prompt_real(r):
    """Mensaje que abre un turno: lo escribio el usuario (string o bloque `text`), no un
    tool_result, ni una expansion de skill (`isMeta`, que va DENTRO del turno), ni un mensaje
    inyectado por el harness (INYECTADO)."""
    if r.get("type") != "user" or r.get("isMeta"):
        return False
    c = (r.get("message") or {}).get("content")
    if isinstance(c, str):
        txt = c
    elif isinstance(c, list):
        partes = [b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"]
        if not partes:
            return False
        txt = partes[0]
    else:
        return False
    return not INYECTADO.match(txt)


# Fichas de ESTA sesion, vistas en cualquier turno (no solo en el actual): las que se ESCRIBIERON o
# EDITARON. Una ficha solo impresa con print-como-retomar.py (por ejemplo al leer la de una sesion
# vieja durante un triage) no es de esta sesion salvo que su frontmatter lleve `session_id:` igual al
# de esta sesion (lo sella Step 5c-bis): contarla hacia que resolver un pendiente que esa ficha vieja
# citaba exigiera re-pegar un snippet muerto (adversario, ronda de 2.33.1). Las usa el disparo por
# cambio de estado (abajo).
SID = str(d.get("session_id") or "")
impresas = []
SESION_RE_G = re.compile(r"(?:^|/)memory/sessions/[^/]+\.md$")
fichas_sesion = []
for r in recs:
    if r.get("type") != "assistant":
        continue
    for b in (r.get("message") or {}).get("content") or []:
        if not isinstance(b, dict) or b.get("type") != "tool_use":
            continue
        inp = b.get("input") or {}
        ruta = inp.get("file_path") or ""
        if b.get("name") in ("Write", "Edit", "MultiEdit") and SESION_RE_G.search(ruta):
            fichas_sesion.append(ruta)
        elif b.get("name") == "Bash":
            for m in re.finditer(r"print-como-retomar\.py[\"']?\s+(\"[^\"]+\"|'[^']+'|[^\s;&|]+)",
                                 inp.get("command") or ""):
                impresas.append(m.group(1).strip("\"'"))

# Ultimo veredicto del adversario de goalspec en TODA la sesion (2.34.0, p-272254efc5). Desde
# 2.42.0 cuenta tambien el que llega en un tool_result (el subagente `goal-adversary` o
# `external-adversary.sh`): medido el 2026-09-30, el agente nunca copio su `break` a su texto, el
# veredicto solo estaba en el tool_result, y la ficha cerro sin nombrar el defecto. La marca va a
# inicio de linea y su palabra tiene que ir seguida de espacio o `]`: la plantilla que repiten el
# skill y el adversario externo (`break|hold ungrounded=<n>…`) no es un veredicto. Un
# `[GOAL-CLOSE-WAIVED` solo cuenta en texto propio: es una declaracion del agente, no del
# adversario. `last_assistant_message` va al final: el transcript puede no traer aun el ultimo turno.
# Limite declarado: un tool_result que imprime a inicio de linea el veredicto de OTRA sesion (un
# `cat` de un transcript viejo) cuenta como de esta. Cuesta un aviso de mas, nunca uno de menos.
VEREDICTO_ADV = re.compile(r"^\[ADVERSARY-VERDICT:\s*(break|hold)(?=[\s\]])|^\[GOAL-CLOSE-WAIVED\b", re.M)
VEREDICTO_TOOL = re.compile(r"^\[ADVERSARY-VERDICT:\s*(break|hold)(?=[\s\]])", re.M)
# Fuera de los bloques ``` : un veredicto citado DENTRO de un fence es un ejemplo, no el marcador
# (adversario, ronda 1: un `break` de ejemplo en un fence bloqueaba el cierre).
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,}).*?^ {0,3}\1[`~]*\s*$", re.M | re.S)
ultimo_veredicto = None


def _texto_resultado(bloque):
    rc = bloque.get("content")
    if isinstance(rc, list):
        rc = "\n".join(x.get("text", "") for x in rc if isinstance(x, dict))
    return rc if isinstance(rc, str) else ""


for r in recs:
    for b in (r.get("message") or {}).get("content") or []:
        if not isinstance(b, dict):
            continue
        if r.get("type") == "assistant" and b.get("type") == "text":
            for m in VEREDICTO_ADV.finditer(FENCE.sub("", b.get("text") or "")):
                ultimo_veredicto = m.group(1) or "hold"
        elif r.get("type") == "user" and b.get("type") == "tool_result":
            for m in VEREDICTO_TOOL.finditer(FENCE.sub("", _texto_resultado(b))):
                ultimo_veredicto = m.group(1)
for m in VEREDICTO_ADV.finditer(FENCE.sub("", lam)):
    ultimo_veredicto = m.group(1) or "hold"

inicio = 0
for i in range(len(recs) - 1, -1, -1):
    if es_prompt_real(recs[i]):
        inicio = i
        break
turno = recs[inicio:]

ids_cambiados = set()  # pendientes cerrados/caducados/bloqueados en este turno
ids_a_ciegas = False   # un expire-pendientes.py --apply cuya salida no se pudo leer (ver abajo)
expiraciones = []      # tool_use_id de cada `expire-pendientes.py --apply` del turno
resultados = {}        # tool_use_id -> texto del tool_result
textos = []            # lo que el usuario vio: bloques text del assistant
disparo = False
por_checkpoint = False # el turno corrio /checkpoint-3t (no solo reimprimio un snippet)
fichas = []            # fichas que el turno CERRO: argumento de print-como-retomar.py o Edit con marca
escritas = []          # fichas escritas con Write (Step 2 del checkpoint, o /backfill-3t)
preguntas = []         # tool_use_id de cada AskUserQuestion del turno (Step 3b, 2.53.0)
n_preg = {}            # tool_use_id -> cuantas preguntas lleva ese modal (2.54.0)
con_error = set()      # tool_use_id cuyo tool_result vino con is_error
# El texto con que Claude Code devuelve una herramienta que el USUARIO rechazo. Medido el 2026-10-09
# en los transcripts locales: mas de 200 tool_result que empiezan asi (215-219 segun como se cuente), de cualquier herramienta. Un error con
# otro texto (InputValidationError, herramienta no disponible sin pantalla) no llego a nadie.
RECHAZO_USUARIO = re.compile(r"The user doesn't want to proceed with this tool use")
SESION_RE = re.compile(r"(?:^|/)memory/sessions/[^/]+\.md$")
MARCAS_EDIT = ("## Como retomar", "Proximo paso:", "Próximo paso:", "## Recordatorios de calendario")


def resolver(ruta, base):
    ruta = os.path.expanduser(ruta)
    if "$" in ruta:
        return None
    return ruta if os.path.isabs(ruta) else os.path.normpath(os.path.join(base, ruta))


for r in turno:
    msg = r.get("message") or {}
    c = msg.get("content")
    if r.get("type") == "user":
        for b in c if isinstance(c, list) else []:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                rc = b.get("content")
                if isinstance(rc, list):
                    rc = "\n".join(x.get("text", "") for x in rc if isinstance(x, dict))
                resultados[b.get("tool_use_id")] = rc if isinstance(rc, str) else ""
                if b.get("is_error"):
                    con_error.add(b.get("tool_use_id"))
        # `/checkpoint-3t` tecleado como comando: la marca va en el prompt del usuario.
        txt = c if isinstance(c, str) else " ".join(
            b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
        if TAG_CHECKPOINT.search(txt):
            disparo = por_checkpoint = True
        continue
    if r.get("type") != "assistant" or not isinstance(c, list):
        continue
    for b in c:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            textos.append(b.get("text") or "")
            continue
        if b.get("type") != "tool_use":
            continue
        nombre = b.get("name") or ""
        inp = b.get("input") or {}
        if nombre == "Skill" and str(inp.get("skill", "")).split(":")[-1] == "checkpoint-3t":
            disparo = por_checkpoint = True
        elif nombre == "AskUserQuestion":
            preguntas.append(b.get("id"))
            # Un modal lleva hasta 4 preguntas y Step 3b pone un candidato por pregunta: se cuentan
            # las preguntas, no los modales (adversario externo de 2.54.0). Uno sin lista cuenta 1.
            qs = inp.get("questions")
            n_preg[b.get("id")] = len(qs) if isinstance(qs, list) and qs else 1
        elif nombre == "Bash":
            cmd = inp.get("command") or ""
            # Disparo por CAMBIO DE ESTADO (2.33.1, p-c72a33ae7a): un turno que cierra, caduca o
            # bloquea un pendiente que el `## Como retomar` de una ficha de esta sesion cita deja
            # ese snippet viejo. Medido en vivo: tras el checkpoint de 2.33.0 se resolvio
            # `p-477bb60303` y la respuesta no aviso ni reimprimio el snippet, que seguia
            # listandolo en `Sigue abierto`. Ese turno no corria ni el skill ni el script.
            # Se cuentan TODOS los ids del comando, no solo el que sigue a `--id `: argparse acepta
            # `--id=p-…`, y un `ID=p-…; … --id "$ID"` o un bucle esconden el id detras de una
            # variable (adversario, ronda de 2.33.1: las dos formas pasaban en silencio). El coste
            # es un id citado de paso en `--nota`: si una ficha de esta sesion lo cita, el hook
            # pide revisar el snippet — un aviso de mas, nunca uno de menos.
            if "journal-emit.py" in cmd and re.search(r"--type[\s=]+[\"']?pendiente\.(?:resolve|expire|block)\b", cmd):
                ids_cambiados.update(re.findall(r"\b(p-[0-9a-f]{10})\b", cmd))
            # expire-pendientes.py --apply caduca llamando a journal-emit.py POR DENTRO: ni el
            # script ni los ids aparecen en el comando (2.36.0, p-2dc733a7c3). Los ids salen de la
            # ultima linea que imprime, `EXPIRE ids: …`, leida del tool_result: es salida del
            # script, no prosa. `--revertir` reabre, no cierra. Se mira CADA invocacion por separado
            # (hasta `;`, `&`, `|` o salto de linea): un `--revertir` en el mismo comando no tapa a
            # un `--apply` (adversario de 2.36.0). Antes se unen las lineas continuadas con `\` al
            # final: un `--apply` en la linea siguiente es la misma invocacion (ronda 2).
            n_apply = sum(1 for s in re.findall(r"expire-pendientes\.py[^;&|\n]*",
                                                re.sub(r"\\\r?\n", " ", cmd))
                          if re.search(r"--apply\b", s) and "--revertir" not in s)
            if n_apply:
                expiraciones.append((b.get("id"), n_apply))
            if "print-como-retomar.py" not in cmd:
                continue
            disparo = True
            base = cwd
            m_cd = re.search(r"(?:^|[;&|\n]\s*)cd\s+(\"[^\"]+\"|'[^']+'|\S+)", cmd)
            if m_cd:
                base = resolver(m_cd.group(1).strip("\"'"), cwd) or cwd
            # TODAS las invocaciones del comando, no la primera: dos `print-como-retomar.py` en
            # una sola llamada Bash dejaban la segunda ficha sin revisar (adversario, ronda 2).
            for m in re.finditer(r"print-como-retomar\.py[\"']?\s+(\"[^\"]+\"|'[^']+'|[^\s;&|]+)", cmd):
                f = resolver(m.group(1).strip("\"'"), base)
                if f:
                    fichas.append(f)
        elif nombre in ("Edit", "MultiEdit", "Write"):
            ruta = inp.get("file_path") or ""
            if not SESION_RE.search(ruta):
                continue
            nuevo = inp.get("new_string") or inp.get("content") or ""
            for e in inp.get("edits") or []:
                nuevo += "\n" + (e.get("new_string") or "")
            if nombre == "Write":
                if "## Como retomar" in nuevo:
                    escritas.append(resolver(ruta, cwd))
            elif any(mk in nuevo for mk in MARCAS_EDIT):
                disparo = True
                fichas.append(resolver(ruta, cwd))

# Si la linea `EXPIRE ids:` no esta (salida cortada con `| tail`, mandada a /dev/null, el script
# murio a mitad, o el tool_result aun no llego) no se sabe que caduco: se asume cualquier id que cite
# una ficha de esta sesion. Un aviso de mas, nunca uno de menos (el mismo criterio de 2.33.1).
# TODAS las lineas, no la primera: un bucle `for d in …; do expire-pendientes.py --apply; done` es
# una invocacion en el texto y varias lineas en la salida (adversario de 2.36.0: leer solo la
# primera dejaba fuera el id citado y el respaldo no entraba). Menos lineas que invocaciones
# `--apply` en el texto = alguna salida se perdio: a ciegas.
for _tid, _n in expiraciones:
    _lineas = re.findall(r"(?m)^EXPIRE ids: (.*)$", resultados.get(_tid) or "")
    for _l in _lineas:
        ids_cambiados.update(re.findall(r"p-[0-9a-f]{10}", _l))
    if len(_lineas) < _n:
        ids_a_ciegas = True

if lam:
    textos.append(lam)
# Se miden TODAS las fichas que el turno cerro, no solo la ultima: con una sola, una ficha
# ajena escrita despues (un backfill en el mismo turno) tapaba la del checkpoint (adversario
# externo, ronda 1). Un Write suelto solo cuenta si nada mas nombro la ficha: es el caso de un
# /checkpoint-3t que se salto Step 8b entero, y entonces vale la ULTIMA escrita (la de Step 2),
# no todas — /backfill-3t escribe decenas.
def seccion(texto, nombre):
    lineas = texto.splitlines()
    for i, l in enumerate(lineas):
        if l.strip().lower() == "## " + nombre.lower():
            fin = next((j for j in range(i + 1, len(lineas)) if lineas[j].startswith("## ")), len(lineas))
            return "\n".join(lineas[i + 1:fin])
    return None


def de_esta_sesion(ruta):
    """Una ficha impresa cuenta solo si su frontmatter trae `session_id:` igual al de esta sesion."""
    if not SID:
        return False
    try:
        cabeza = open(ruta, encoding="utf-8").read(2000)
    except Exception:
        return False
    m = re.search(r"(?m)^session_id:\s*(\S+)\s*$", cabeza)
    return bool(m and m.group(1) == SID)


if ids_cambiados or ids_a_ciegas:
    candidatas = [resolver(r, cwd) for r in fichas_sesion]
    candidatas += [f for f in (resolver(r, cwd) for r in impresas) if f and de_esta_sesion(f)]
    for f in dict.fromkeys(candidatas):
        if not f or not os.path.isfile(f):
            continue
        try:
            sec = seccion(open(f, encoding="utf-8").read(), "Como retomar") or ""
        except Exception:
            continue
        if any(i in sec for i in ids_cambiados) or (ids_a_ciegas and re.search(r"p-[0-9a-f]{10}", sec)):
            disparo = True
            fichas.append(f)
fichas = [f for f in fichas if f and os.path.isfile(f)]
if not fichas:
    fichas = [f for f in escritas[-1:] if f and os.path.isfile(f)]
if not disparo or not fichas:
    sys.exit(0)
fichas = list(dict.fromkeys(fichas))


def plano(s):
    return " ".join(s.split())


visto = plano("\n".join(textos))


def falta(lineas, base=None):
    base = visto if base is None else base
    return [l for l in lineas if plano(l) and plano(l) not in base]


problemas = []
# Desde 2.42.0: commits de la sesion en la ficha (chequeo 5) y la revision cerrada del cierre.
DESDE_REVISION = "2026-09-30"
pedir_revision = False
REVISION_CABECERA = "REVISION DEL CIERRE:"
# El cierre al FINAL (2.43.0). Con la revision de 2.42.0 el snippet, el calendario y el prompt
# opcional salian en el primer cierre y la respuesta a la revision caia debajo: medido en los 4
# cierres reales con revision (2026-09-30), en 2 el snippet quedo enterrado bajo 2.400-4.300
# caracteres y en 1 el agente lo repitio. En un turno de /checkpoint-3t que va a pedir la revision,
# el primer cierre ya no los exige: la revision pide pegarlos como ultimo bloque, y el cierre
# reentrante los mide solo en el texto posterior a `REVISION DEL CIERRE:`.
cierre_final = []   # lo que la revision pide pegar al final (primer cierre)
anexo = []          # lo que falto al final, para mostrarselo al usuario (cierre reentrante)
presentes = []      # (orden, lineas, texto) de cada bloque del cierre, para medir orden y cola
# Texto tolerado DESPUES del ultimo bloque del cierre: los separadores `───` que imprimen los
# scripts y una linea corta. Mas que eso ya empuja el cierre hacia arriba (adversario de 2.43.0:
# el cierre duplicado y seguido de mas texto pasaba sin aviso).
COLA_MAX = 300
# Capas y emojis del cierre (2.44.0, reglas de Victor del 2026-10-01): cada bloque abre con su emoji
# (🔁 snippet, 🔔/➕ pendiente, 🗓️ calendario) y el snippet va en un fence. Desde este corte el hook
# exige tambien esas cabeceras; en una ficha anterior, la respuesta se escribio con el formato viejo
# y solo se exige el contenido (las cabeceras se quitan y el `🔁 ` delante de la linea del caso 5).
CORTE_CAPAS = "2026-10-01"
EMOJIS = ("🔁", "🔔", "➕", "🗓️")


def exigidas(salida, nueva):
    """Las lineas de la salida de un script que la respuesta tiene que traer."""
    out = []
    for l in salida.splitlines():
        if not l.strip() or l.startswith("───") or l.startswith(("Copia y pega esto", "Si tienes tiempo")):
            continue
        if not nueva:
            if re.fullmatch(r"\s*`{3,}\s*", l):
                continue
            e = next((e for e in EMOJIS if l.startswith(e)), None)
            if e:
                l = l[len(e):].strip()
                if l.endswith(":"):
                    continue
        out.append(l)
    return out
# La cabecera de la revision cuenta solo al INICIO de una linea (admite marcas de markdown delante).
# Con `rfind` sobre todo el texto, la frase citada dentro de un bloque del cierre (el prompt de un
# recordatorio que dice "tras REVISION DEL CIERRE: vienen...") pasaba por la cabecera y el cierre
# entero quedaba "antes de la revision" (adversario externo de 2.44.0, sobre una ficha real).
CABECERA_RE = re.compile(r"(?m)^[ \t#>*_]*" + re.escape(REVISION_CABECERA))


def inicio_revision(t):
    ms = list(CABECERA_RE.finditer(t))
    return ms[-1].start() if ms else -1


cierre_nuevo = False  # alguna ficha del turno es del corte de capas y va en el cierre diferido
_todo = "\n".join(textos)
_j = inicio_revision(_todo)
visto_tras_revision = plano(_todo[_j:]) if _j >= 0 else ""


def es_checkpoint(r):
    """La invocacion de /checkpoint-3t: la llamada `Skill` o el comando tecleado."""
    c = (r.get("message") or {}).get("content")
    if r.get("type") == "user":
        txt = c if isinstance(c, str) else " ".join(
            b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
        return bool(TAG_CHECKPOINT.search(txt))
    if r.get("type") == "assistant" and isinstance(c, list):
        return any(isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Skill"
                   and str((b.get("input") or {}).get("skill", "")).split(":")[-1] == "checkpoint-3t"
                   for b in c)
    return False


# `[main 83e6926] asunto` o `[main (root-commit) 83e6926] asunto`: la primera linea de `git commit`.
COMMIT_OUT = re.compile(r"(?m)^\[[^\]\n]*?([0-9a-f]{7,40})\] (.*)$")


def commits_de_la_sesion():
    """(hash, asunto) de cada `git commit` de ESTA sesion entre el checkpoint anterior (el que cerro
    la ficha previa) y la invocacion de ESTE checkpoint. Lo posterior a la invocacion queda fuera:
    ahi va el commit de memoria de Step 6, una referencia adelantada por diseno, se llame como se
    llame (adversario de 2.42.0: filtrar por el asunto `checkpoint:` marcaba un Step 6 con otro
    mensaje). Solo los que siguen en la historia de HEAD del directorio de la sesion: un commit
    reescrito por `--amend` o por un rebase, o hecho en otro repositorio, no se exige. Limites
    declarados: los de otro repositorio no se miran, y un `git commit -q` (o una salida sin la linea
    `[rama hash] asunto`) no deja hash que medir. Sin git, lista vacia."""
    # Una invocacion puede dejar DOS marcas (la etiqueta del comando tecleado y la llamada `Skill`):
    # el checkpoint actual empieza en la PRIMERA marca del turno y el anterior termina en la ultima
    # marca antes del turno (adversario de 2.42.0, ronda 2: con las dos marcas, un commit anterior a
    # la etiqueta quedaba fuera de la ventana).
    cks = [i for i, r in enumerate(recs) if es_checkpoint(r)]
    actual = [i for i in cks if i >= inicio]
    if not actual:
        return []
    previos = [i for i in cks if i < inicio]
    desde = previos[-1] if previos else -1
    cmds, vistos = {}, []
    for r in recs[desde + 1:actual[0]]:
        for b in (r.get("message") or {}).get("content") or []:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use" and b.get("name") == "Bash":
                cmd = (b.get("input") or {}).get("command") or ""
                if re.search(r"\bgit\b[^\n]*\bcommit\b", cmd):
                    cmds[b.get("id")] = cmd
            elif b.get("type") == "tool_result" and b.get("tool_use_id") in cmds:
                for m in COMMIT_OUT.finditer(_texto_resultado(b)):
                    vistos.append((m.group(1), m.group(2)))
    out = []
    for h, asunto in dict.fromkeys(vistos):
        try:
            rc = subprocess.run(["git", "-C", cwd, "merge-base", "--is-ancestor", h, "HEAD"],
                                capture_output=True, timeout=10).returncode
        except Exception:
            return []
        if rc == 0:
            out.append((h, asunto))
    return out


def revisar(ficha):
    try:
        texto = open(ficha, encoding="utf-8").read()
    except Exception:
        return
    pref = f"[{os.path.basename(ficha)}] " if len(fichas) > 1 else ""
    m_fecha = re.search(r"^date:\s*(\d{4}-\d{2}-\d{2})\s*$", texto, re.M)
    # Turno de /checkpoint-3t con revision: el cierre (snippet, 8e, calendario) va AL FINAL.
    diferido = bool(por_checkpoint and m_fecha and m_fecha.group(1) >= DESDE_REVISION)
    nueva = bool(m_fecha and m_fecha.group(1) >= CORTE_CAPAS)
    global cierre_nuevo
    cierre_nuevo = cierre_nuevo or (nueva and diferido)
    base = visto_tras_revision if (diferido and reentrante) else visto
    donde = "despues de tu revision del cierre" if diferido else "en tu respuesta"

    def reclamar(etiqueta, lineas, texto_original, orden):
        """Lo que falta: en el primer cierre diferido se pide al final; si no, es un problema, y en
        el reentrante diferido ademas se guarda para ensenarselo al usuario."""
        if diferido and not reentrante:
            cierre_final.append((orden, etiqueta))
            return
        if diferido:
            presentes.append((orden, lineas, texto_original))
        n = len(falta(lineas, base))
        problemas.append(pref + f"{etiqueta[0].upper()}{etiqueta[1:]} no esta {donde} ({n} de "
                         f"{len(lineas)} lineas faltan).")
        if diferido:
            anexo.append((orden, texto_original.strip("\n")))

    # 1. El snippet: lo que print-como-retomar.py imprime HOY desde la ficha (la unica fuente de verdad).
    sec = seccion(texto, "Como retomar")
    if sec is not None and "<filled in Step 8>" in sec:
        problemas.append(pref + "`## Como retomar` de la ficha sigue con su placeholder: Step 8 no corrio.")
    elif sec is not None:
        try:
            r = subprocess.run([sys.executable, os.path.join(BIN, "print-como-retomar.py"), ficha],
                               capture_output=True, text=True, timeout=20)
            salida = r.stdout if r.returncode == 0 else ""
        except Exception:
            salida = ""
        esperado = exigidas(salida, nueva)
        cmd = f"`python3 \"{BIN}/print-como-retomar.py\" \"{ficha}\"`"
        if esperado and (diferido and not reentrante):
            reclamar(f"la salida de {cmd}", esperado, salida, 1)
        elif esperado and diferido and reentrante and not falta(esperado, base):
            presentes.append((1, esperado, salida))
        elif esperado and falta(esperado, base):
            if diferido:
                reclamar("el snippet `Como retomar`", esperado, salida, 1)
            else:
                n = len(falta(esperado))
                problemas.append(pref +
                    f"El snippet `Como retomar` no esta en tu respuesta ({n} de {len(esperado)} lineas "
                    "faltan). Solo lo viste tu en la salida de una herramienta. Corre "
                    f"`python3 \"$JBIN/print-como-retomar.py\" \"{ficha}\"` y pega su salida tal cual.")

    # 1-bis. El bloque de pendiente (Step 8e): lo que print-pendiente-opcional.py imprime AHORA desde
    # `_pendientes.md` — desde 2.44.0, 🔔 el que vence hoy o ➕ el opcional, nunca los dos. Se genera
    # en vivo, no se guarda en la ficha, asi que compararlo aqui contra el estado real es lo que evita
    # pegar uno viejo. Solo para fichas desde el corte: una anterior no tenia Step 8e.
    if sec is not None and "<filled in Step 8>" not in sec and m_fecha and m_fecha.group(1) >= "2026-09-23":
        try:
            r = subprocess.run([sys.executable, os.path.join(BIN, "print-pendiente-opcional.py"), ficha],
                               capture_output=True, text=True, timeout=20)
            salida = r.stdout if r.returncode == 0 else ""
        except Exception:
            salida = ""
        esperado = exigidas(salida, nueva)
        cmd8e = f"`python3 \"{BIN}/print-pendiente-opcional.py\" \"{ficha}\"`"
        if esperado and (diferido and not reentrante):
            reclamar(f"la salida de {cmd8e}", esperado, salida, 2)
        elif esperado and diferido and falta(esperado, base):
            reclamar("el bloque de pendiente (Step 8e)", esperado, salida, 2)
        elif esperado and diferido:
            presentes.append((2, esperado, salida))
        elif esperado and not diferido and falta(esperado):
            problemas.append(pref +
                f"El bloque de pendiente (Step 8e) no esta en tu respuesta ({len(falta(esperado))} de "
                f"{len(esperado)} lineas faltan). Corre `python3 \"$JBIN/print-pendiente-opcional.py\" "
                f"\"{ficha}\"` y pega su salida tal cual.")

    # 2. Recordatorios de calendario (Step 8c): desde 2.44.0, lo que imprime print-recordatorios.py
    # sobre la ficha — los 2 primeros sin fence y `+N con fecha futura` si hay mas. Antes se
    # comparaba el cuerpo de los bloques de la ficha y el agente los copiaba a mano con su fence.
    # (8d, las recomendaciones de research, ya no van en el cierre desde 2.44.0: cada una sin marcar
    # tiene que citar un pendiente, y checkpoint-audit.py lo mide en `research.recomendaciones`.)
    if seccion(texto, "Recordatorios de calendario"):
        try:
            r = subprocess.run([sys.executable, os.path.join(BIN, "print-recordatorios.py"), ficha],
                               capture_output=True, text=True, timeout=20)
            salida = r.stdout if r.returncode == 0 else ""
        except Exception:
            salida = ""
        esperado = exigidas(salida, nueva)
        cmd8c = f"`python3 \"{BIN}/print-recordatorios.py\" \"{ficha}\"`"
        if esperado and (diferido and not reentrante):
            reclamar(f"la salida de {cmd8c}", esperado, salida, 3)
        elif esperado and diferido and falta(esperado, base):
            reclamar("los recordatorios de calendario", esperado, salida, 3)
        elif esperado and diferido:
            presentes.append((3, esperado, salida))
        elif esperado and falta(esperado):
            problemas.append(pref +
                f"Los recordatorios de calendario no estan en tu respuesta ({len(falta(esperado))} de "
                f"{len(esperado)} lineas faltan). Corre `python3 \"$JBIN/print-recordatorios.py\" "
                f"\"{ficha}\"` y pega su salida tal cual.")

    # 3. Los checks del snippet sobre la ficha final (Step 7a corrio antes de Step 8). El ultimo
    # veredicto del adversario de TODA la sesion va como argumento: un `break` sin cerrar con
    # `Proximo paso: ninguno` es un defecto hallado en vivo que nadie registro (p-272254efc5).
    memory_dir = os.path.dirname(os.path.dirname(ficha))
    extra = ["--veredicto-adversario", ultimo_veredicto] if ultimo_veredicto else []
    # Step 3b (2.53.0): cuantos AskUserQuestion del turno llegaron al usuario: los que volvieron
    # con respuesta, y los que el usuario rechazo (un modal cerrado es una decision: Step 3b lo
    # descarta). Un error con otro texto no llego a nadie (llamada mal formada, sin pantalla) y no
    # cuenta: ahi Step 3b manda `sin confirmar` (adversario de 2.53.0, ronda 3). Tampoco cuenta uno
    # sin tool_result (turno interrumpido). Sin ninguno, una decision `guardado`/`hecho`/`descartado` la
    # tomo el agente. Solo en un turno que corrio /checkpoint-3t.
    if por_checkpoint:
        respondidas = sum(n_preg.get(i, 1) for i in preguntas if i in resultados and
                          (i not in con_error or RECHAZO_USUARIO.search(resultados[i])))
        extra += ["--preguntas-usuario", str(respondidas)]
    try:
        r = subprocess.run([sys.executable, os.path.join(BIN, "checkpoint-audit.py"), memory_dir,
                            "--session-file", ficha, "--solo-snippet", "--json", "--no-git"] + extra,
                           capture_output=True, text=True, timeout=60)
        for x in json.loads(r.stdout or "[]"):
            if x.get("estado") == "SALTADO":
                detalle = "; ".join(x.get("lineas") or []) or x.get("detalle", "")
                problemas.append(pref + f"checkpoint-audit.py {x['clave']}: {x['detalle']} — {detalle}")
    except Exception:
        pass

    # 4. La salida de Step 7a en la respuesta (2.40.0, p-532174ff63). Hasta 2.39 lo vigilaba
    # `checkpoint-audit-nudge.sh`, un PreToolUse enganchado al commit del checkpoint — y el commit
    # es Step 6, ANTES de Step 7a, que no puede ir antes porque mide ese commit. Medido sobre los
    # transcripts reales de otros proyectos: en 50 de 67 sesiones el primer commit de checkpoint
    # precedia al audit, asi que el aviso saltaba en casi todo checkpoint bien hecho, y ademas
    # avisaba en falso en 41 de 81 commits con una corrida real (el agente armaba la ruta con
    # `JBIN=$(cat ...)`). Aqui se mira al final del turno, cuando el audit ya tuvo que correr, y no
    # se infiere nada del transcript: el hook corre el audit el mismo y exige en la respuesta su
    # linea `resumen:` y la clave de cada paso que HOY sale SALTADO. No compara los numeros del
    # resumen: Step 8 corre despues de 7a y cambia legitimamente los checks del snippet. Solo en un
    # turno que corrio /checkpoint-3t, y solo para fichas desde el corte: una anterior se cerro con
    # el aviso viejo.
    if por_checkpoint and m_fecha and m_fecha.group(1) >= "2026-09-28":
        # Se exige la FORMA de la salida, no subcadenas sueltas: la clave de un SALTADO en una linea
        # `SALTADO  <clave>` y un `saltado=` pegado que no sea menor que los que el audit ve hoy.
        # Con subcadenas bastaba un `resumen: ... saltado=0` escrito a mano y las claves citadas en
        # prosa (adversario de 2.41.0). Limite declarado: no distingue una salida real presentada
        # como "ejemplo" ni una falsificacion linea a linea; esto vigila la omision, como el snippet.
        faltas = []
        m_res = [int(x) for x in re.findall(r"resumen:\s*hecho=\d+\s+parcial=\d+\s+saltado=(\d+)", visto)]
        if not m_res:
            faltas.append("la linea `resumen:`")
        try:
            r = subprocess.run([sys.executable, os.path.join(BIN, "checkpoint-audit.py"), memory_dir,
                                "--session-file", ficha, "--json", "--no-git"],
                               capture_output=True, text=True, timeout=60)
            saltados = [x["clave"] for x in json.loads(r.stdout or "[]")
                        if x.get("estado") == "SALTADO" and not x["clave"].startswith("snippet.")]
        except Exception:
            saltados = []
        faltas += [f"`{c}` (SALTADO)" for c in saltados
                   if not re.search(r"SALTADO\s+" + re.escape(c) + r"(?!\S)", visto)]
        if m_res and max(m_res) < len(saltados):
            faltas.append(f"un `resumen:` con saltado>={len(saltados)} (el pegado dice {max(m_res)})")
        if faltas:
            problemas.append(pref +
                "La salida de Step 7a no esta en tu respuesta: falta " + ", ".join(faltas) + ". Corre "
                f"`python3 \"$JBIN/checkpoint-audit.py\" \"{memory_dir}\" --session-file \"{ficha}\" "
                "--repo-root .` y pega su salida tal cual; un SALTADO se arregla o se declara, no se calla.")


    # 5. `## Commits` contra los commits de la sesion (2.42.0). Medido en los cierres que el usuario
    # tuvo que preguntar "¿falto algo?": la ficha listaba 1 de 6 commits, o se paraba en el primero.
    # Se exige el hash (7 caracteres) en cualquier parte de la ficha, no solo en `## Commits`: una
    # ficha que lo cita en `## Cambios realizados` ya lo registra.
    global pedir_revision
    if por_checkpoint and m_fecha and m_fecha.group(1) >= DESDE_REVISION:
        pedir_revision = True
        faltan = [f"`{h[:7]}` {asunto[:70]}" for h, asunto in commits_de_la_sesion()
                  if h[:7] not in texto]
        if faltan:
            problemas.append(pref + "La ficha no nombra " + str(len(faltan)) + " commit(s) de esta "
                             "sesion: " + "; ".join(faltan) + ". Anadelos a `## Commits` (y a "
                             "`## Cambios realizados` si cambian lo que hizo la sesion).")


for _f in fichas:
    revisar(_f)

# Orden, unicidad y cola del cierre (2.43.0, adversario ronda 1). Solo en el cierre reentrante de
# un turno de /checkpoint-3t y solo si todos los bloques estan tras la revision: si falta alguno ya
# hay aviso y anexo. Se mide sobre el texto posterior a `REVISION DEL CIERRE:`: un snippet pegado
# ANTES de la revision (aunque no debia) no cuenta como repeticion, porque pegarlo otra vez al
# final es el unico arreglo posible y lo que importa es que sea lo ultimo.
if reentrante and presentes and not anexo:
    v = visto_tras_revision
    # Se recorre el cierre HACIA ADELANTE, linea a linea y bloque a bloque en su orden, desde el
    # ULTIMO inicio del primer bloque: el fin es donde termina esa lectura, no la ultima aparicion
    # de cada linea (adversario de 2.43.0, ronda 2: con `rfind`, una linea de 8e repetida al final
    # tapaba 500 caracteres de cola). Una linea que no aparece despues de la anterior es desorden.
    bloques = [[plano(l) for l in ls if plano(l)] for _, ls, _ in sorted(presentes, key=lambda x: x[0])]
    bloques = [b for b in bloques if b]
    otros = []
    cursor = v.rfind(bloques[0][0]) if bloques else -1
    for b in bloques:
        for l in b:
            pos = v.find(l, cursor)
            if pos < 0:
                otros.append("no van en el orden snippet, pendiente, calendario")
                break
            cursor = pos + len(l)
        else:
            continue
        break
    snip = [plano(l) for o, ls, _ in presentes if o == 1 for l in ls if plano(l)]
    if snip and v.count(snip[0]) > 1:
        otros.append(f"el snippet sale {v.count(snip[0])} veces despues de la revision")
    if bloques and not otros and len(v) - cursor > COLA_MAX:
        otros.append(f"despues del ultimo bloque siguen {len(v) - cursor} caracteres de texto")
    # Solo el snippet va en color (2.44.0, regla 6 de Victor): desde la ultima cabecera 🔁 tras la
    # revision, los unicos fences permitidos son los dos del snippet (ninguno en el caso 5). Un
    # 🔔 o un 🗓️ envuelto en un fence tambien saldria en color (adversario externo de 2.44.0).
    if cierre_nuevo and not otros:
        crudo = _todo[_j:] if _j >= 0 else ""
        cabs = [m.start() for m in re.finditer(r"(?m)^🔁 ", crudo)]
        if cabs:
            # Tambien dentro de una cita markdown (`> ````): tambien sale en color (adversario
            # externo de 2.44.0, ronda 2).
            fences = len(re.findall(r"(?m)^[ \t>]*(?:`{3,}|~{3,})", crudo[cabs[-1]:]))
            permitidos = 2 if any(o == 1 and "```" in ls for o, ls, _ in presentes) else 0
            if fences > permitidos:
                otros.append(f"hay {fences - permitidos} linea(s) de fence fuera del snippet: solo "
                             "Retomamos va en color, el pendiente y el calendario van sin fence")
    if otros:
        problemas.append("El cierre no quedo como lo ultimo y una sola vez: " + "; ".join(otros) + ".")
        anexo = [(o, t.strip("\n")) for o, _, t in presentes]

# La revision cerrada del cierre (2.42.0). Medido en 66 cierres de /checkpoint-3t tras los que
# el usuario pregunto "¿falto algo?": en 62 el MISMO agente, en el MISMO contexto, encontro
# omisiones reales en cuanto se le pregunto; el bloque de autorevision escrito dentro del skill
# (el antiguo Step 7b) se contestaba como tramite. Lo que funcionaba era la pregunta llegando como
# turno nuevo, asi que este hook la hace, una vez, al terminar el turno del checkpoint. Las
# categorias son las que salieron en esos 66 cierres; la lista de lo que NO cuenta es lo que el
# agente confesaba como falla y el skill ordena (el 28 % de lo confesado). "ninguno" es valido en
# cada linea: una lista que empuja a encontrar algo fabrica lo que debe detectar (medido: un
# callejon inventado para llenar la seccion).
REVISION_ITEMS = (
    "Defectos hallados en la sesion (adversario, revisor, test rojo) que no estan en `## Bugs fixed`",
    "Callejones reales (se probo y fallo) que faltan en `## Callejones sin salida`, o uno escrito "
    "que no se probo",
    "Reglas aprendidas que no llegaron a learning (o quedaron solo en otra seccion)",
    "Pendientes: la tabla de reconciliacion de 3a impresa en tu texto y su linea RECONCILIACION al "
    "dia; texto de un pendiente vivo que quedo falso (`pendiente.update`); hallazgos menores o "
    "afirmaciones que no propusiste como candidato en Step 3b",
    "Criterios de cierre que dio el usuario y que no se cumplieron tal como los escribio (dilo, no "
    "los reinterpretes en silencio)",
    "Plan o research que la sesion toco sin `## Estado`, sin su fila al dia o sin upsert",
    "`## Commits` y `## Cambios realizados` contra lo que la sesion hizo, incluido lo posterior al "
    "checkpoint",
    "Avisos de scripts o hooks que viste y no reportaste; pasos que recortaste",
    "El `Proximo paso` del snippet sigue siendo el siguiente paso real",
)
POR_DISENO = ("no publicar los commits (el checkpoint no sube nada); el hash del commit de memoria "
              "como referencia adelantada (lo commitea Step 8f); archivos de otras sesiones sin commitear "
              "(cada sesion commitea lo suyo); el alcance acotado de 3a con su linea RECONCILIACION; "
              "avisos que vienen de otra sesion (`ids_invented`, pendientes ajenos vencidos que no "
              "te toca cerrar); un candidato a learning decidido `ya existe #N` en el paso 0 de "
              "Step 4 (no se emite a proposito); un candidato a pendiente que el usuario "
              "descarto en Step 3b, o que quedo `sin confirmar` sin pantalla; uno que el usuario "
              "eligio `Hacerlo ahora` y quedo `hecho` con su `_verificado:`")


def revision_contestada():
    """El bloque esta en el texto del turno: la cabecera y, despues de ella, una linea por cada
    numero. Mide la FORMA, no el juicio — un bloque de `ninguno` en cada linea lo pasa. Lo que
    fuerza la revision es el turno nuevo, no este chequeo; esto solo avisa al usuario si ni
    siquiera se contesto."""
    resto = "\n".join(textos)
    j = inicio_revision(resto)
    if j < 0:
        return False
    resto = resto[j:]
    for n, etiqueta in enumerate(REVISION_ITEMS, 1):
        m = re.search(rf"(?m)^\s*{n}\.\s*(.*)$", resto)
        if not m:
            return False
        # Una linea que solo repite la etiqueta de la pregunta no es una respuesta (adversario de
        # 2.42.0: pegar las 9 lineas del propio aviso pasaba). Se quita la etiqueta si viene
        # delante y tiene que quedar algo.
        resp = plano(m.group(1).replace("`", ""))
        lab = plano(etiqueta.replace("`", ""))
        if resp.startswith(lab):
            resp = resp[len(lab):].lstrip(" :")
        if not resp:
            return False
    return True


if pedir_revision and reentrante and not revision_contestada():
    problemas.append("No contestaste la revision del cierre (`" + REVISION_CABECERA + "` con sus "
                     + str(len(REVISION_ITEMS)) + " lineas). Preguntale al agente \"¿falto algo de "
                     "tu checkpoint?\" antes de dar el cierre por bueno.")

if not problemas and not (pedir_revision and not reentrante):
    sys.exit(0)

cuerpo = "\n".join(f"- {p}" for p in problemas)
if reentrante:
    msg = "3-tier-memory: el cierre del checkpoint sigue incompleto tras un aviso:\n" + cuerpo
    if anexo:
        # El agente ya no puede pegarlo (no hay segundo bloqueo): se le ensena al usuario, al final.
        msg += ("\n\nEl cierre no quedo al final de la respuesta. Aqui esta, tal como lo imprimen "
                "los scripts sobre la ficha:\n\n" + "\n\n".join(t for _, t in sorted(anexo, key=lambda x: x[0]) if t))
    print(json.dumps({"systemMessage": msg}, ensure_ascii=False))
else:
    partes = []
    if problemas:
        partes.append("Cierre de /checkpoint-3t incompleto (checkpoint-close-guard.sh). Arreglalo antes "
                      "de terminar; el usuario solo ve tu texto, no la salida de las herramientas:\n"
                      + cuerpo)
    if pedir_revision:
        partes.append(
            "Revision del cierre de /checkpoint-3t (checkpoint-close-guard.sh). Relee la sesion "
            "entera y contesta en tu texto con este bloque. Cada linea lleva `ninguno`, o lo que "
            "falto con una cita del transcript o el comando o la edicion con que ya lo corregiste. "
            "`ninguno` es la respuesta correcta cuando no falta nada: no inventes para llenar. "
            "Corrige ahora lo que puedas; declara lo que no.\n"
            + REVISION_CABECERA + "\n"
            + "\n".join(f"{n}. {t}:" for n, t in enumerate(REVISION_ITEMS, 1))
            + "\nNo cuenta como falta (lo ordena el skill): " + POR_DISENO + ".")
        if cierre_final:
            # Al final y una sola vez: se generan DESPUES de la revision, asi que ya reflejan lo que
            # corregiste en ella, y quedan como lo ultimo que ve el usuario.
            partes.append(
                "Despues del bloque de la revision, termina tu respuesta con el cierre, en este orden, "
                "tal cual lo imprimen, sin resumirlo y sin nada despues. No lo pegues antes de la "
                "revision ni dos veces:\n"
                + "\n".join(f"- {e}" for _, e in sorted(dict.fromkeys(cierre_final), key=lambda x: x[0])))
    print(json.dumps({"decision": "block", "reason": "\n\n".join(partes)}, ensure_ascii=False))
sys.exit(0)
PY
exit 0
