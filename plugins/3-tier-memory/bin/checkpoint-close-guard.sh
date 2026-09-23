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
# Ademas corre `checkpoint-audit.py --solo-snippet` sobre la ficha: Step 7a corre ANTES de que
# Step 8 escriba el snippet, asi que los checks `snippet.*` (defectos 1 y 2: Proximo paso
# bloqueado por un tercero, caso 4 generico, paso sin `_id`) nunca veian el snippet final en el
# flujo normal. Aqui se miden sobre la ficha tal como quedo al terminar el turno.
#
# CUANDO MIRA. Solo en un turno que cerro (o rehizo) un checkpoint:
#   - invoco /checkpoint-3t (Skill o comando), o
#   - corrio print-como-retomar.py, o
#   - edito con Edit/MultiEdit una ficha de memory/sessions/ tocando `## Como retomar`,
#     `Proximo paso:` o `## Recordatorios de calendario`.
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


inicio = 0
for i in range(len(recs) - 1, -1, -1):
    if es_prompt_real(recs[i]):
        inicio = i
        break
turno = recs[inicio:]

textos = []            # lo que el usuario vio: bloques text del assistant
disparo = False
fichas = []            # fichas que el turno CERRO: argumento de print-como-retomar.py o Edit con marca
escritas = []          # fichas escritas con Write (Step 2 del checkpoint, o /backfill-3t)
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
        # `/checkpoint-3t` tecleado como comando: la marca va en el prompt del usuario.
        txt = c if isinstance(c, str) else " ".join(
            b.get("text", "") for b in (c or []) if isinstance(b, dict) and b.get("type") == "text")
        if "<command-name>/checkpoint-3t</command-name>" in txt:
            disparo = True
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
            disparo = True
        elif nombre == "Bash":
            cmd = inp.get("command") or ""
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

if lam:
    textos.append(lam)
# Se miden TODAS las fichas que el turno cerro, no solo la ultima: con una sola, una ficha
# ajena escrita despues (un backfill en el mismo turno) tapaba la del checkpoint (adversario
# externo, ronda 1). Un Write suelto solo cuenta si nada mas nombro la ficha: es el caso de un
# /checkpoint-3t que se salto Step 8b entero, y entonces vale la ULTIMA escrita (la de Step 2),
# no todas — /backfill-3t escribe decenas.
fichas = [f for f in fichas if f and os.path.isfile(f)]
if not fichas:
    fichas = [f for f in escritas[-1:] if f and os.path.isfile(f)]
if not disparo or not fichas:
    sys.exit(0)
fichas = list(dict.fromkeys(fichas))


def plano(s):
    return " ".join(s.split())


visto = plano("\n".join(textos))


def falta(lineas):
    return [l for l in lineas if plano(l) and plano(l) not in visto]


def seccion(texto, nombre):
    lineas = texto.splitlines()
    for i, l in enumerate(lineas):
        if l.strip().lower() == "## " + nombre.lower():
            fin = next((j for j in range(i + 1, len(lineas)) if lineas[j].startswith("## ")), len(lineas))
            return "\n".join(lineas[i + 1:fin])
    return None


problemas = []


def revisar(ficha):
    try:
        texto = open(ficha, encoding="utf-8").read()
    except Exception:
        return
    pref = f"[{os.path.basename(ficha)}] " if len(fichas) > 1 else ""

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
        esperado = [l for l in salida.splitlines()
                    if l.strip() and not l.startswith("───") and not l.startswith("Copia y pega esto")]
        if esperado and falta(esperado):
            n = len(falta(esperado))
            problemas.append(pref + 
                f"El snippet `Como retomar` no esta en tu respuesta ({n} de {len(esperado)} lineas "
                "faltan). Solo lo viste tu en la salida de una herramienta. Corre "
                f"`python3 \"$JBIN/print-como-retomar.py\" \"{ficha}\"` y pega su salida tal cual.")

    # 2. Recordatorios de calendario: los 2 primeros completos; el resto con `+N con fecha futura`.
    cal = seccion(texto, "Recordatorios de calendario")
    if cal:
        bloques = re.split(r"(?m)^###\s+(?=\d{4}-\d{2}-\d{2}\b)", cal)[1:]
        for b in bloques[:2]:
            cuerpo = [l for l in b.splitlines()[1:] if l.strip() and not re.fullmatch(r"\s*`{3,}\w*\s*", l)]
            if falta(cuerpo):
                titulo = b.splitlines()[0].strip()
                problemas.append(pref + f"El recordatorio de calendario `{titulo}` esta en la ficha pero no en "
                                 "tu respuesta. Pegalo completo (Titulo, Descripcion y el prompt).")
        if len(bloques) > 2 and not re.search(rf"\+\s*{len(bloques) - 2}\s+con fecha futura", visto):
            problemas.append(pref + f"Hay {len(bloques)} recordatorios de calendario y la respuesta no dice "
                             f"`+{len(bloques) - 2} con fecha futura en _pendientes.md`.")

    # 3. Los checks del snippet sobre la ficha final (Step 7a corrio antes de Step 8).
    memory_dir = os.path.dirname(os.path.dirname(ficha))
    try:
        r = subprocess.run([sys.executable, os.path.join(BIN, "checkpoint-audit.py"), memory_dir,
                            "--session-file", ficha, "--solo-snippet", "--json", "--no-git"],
                           capture_output=True, text=True, timeout=60)
        for x in json.loads(r.stdout or "[]"):
            if x.get("estado") == "SALTADO":
                detalle = "; ".join(x.get("lineas") or []) or x.get("detalle", "")
                problemas.append(pref + f"checkpoint-audit.py {x['clave']}: {x['detalle']} — {detalle}")
    except Exception:
        pass



for _f in fichas:
    revisar(_f)

if not problemas:
    sys.exit(0)

cuerpo = "\n".join(f"- {p}" for p in problemas)
if reentrante:
    print(json.dumps({"systemMessage":
        "3-tier-memory: el cierre del checkpoint sigue incompleto tras un aviso:\n" + cuerpo},
        ensure_ascii=False))
else:
    print(json.dumps({"decision": "block", "reason":
        "Cierre de /checkpoint-3t incompleto (checkpoint-close-guard.sh). Arreglalo antes de "
        "terminar; el usuario solo ve tu texto, no la salida de las herramientas:\n" + cuerpo},
        ensure_ascii=False))
sys.exit(0)
PY
exit 0
