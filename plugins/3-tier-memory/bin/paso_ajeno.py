#!/usr/bin/env python3
"""Lee transcripts para dos avisos del snippet de cierre (2.63.43, auditoria de 2026-10-22).

`trabajo_propio(transcript, ids)`: que hizo ESTA sesion con cada `p-…` del `Proximo paso`.
`otras_ventanas(transcript, ids)`: que otras sesiones del mismo proyecto actuaron sobre ellos.

Por que el transcript y no el journal: hasta 2.63.44 el `session_id` de un evento salia de
`--session` o de `CLAUDE_SESSION_ID`/`THREET_SESSION_ID`, y sin ellos era un uuid nuevo en cada
llamada; el cierre no pasa `--session` y Claude Code exporta `CLAUDE_CODE_SESSION_ID`, que esa
funcion no leia (medido en otro proyecto: block, relate y retomar de una misma sesion con 3 ids
distintos). Desde 2.63.45 el orden es `--session` > `CLAUDE_SESSION_ID` > `THREET_SESSION_ID` >
`CLAUDE_CODE_SESSION_ID`, y sin ninguna, un uuid por llamada. Aun asi los eventos ya compactados no
guardan su sesion en el indice.
El transcript si dice que sesion toco un pendiente.

Caso real que mide esto (otro proyecto, 2026-10-22): la sesion solo desbloqueo, ligo y marco un
pendiente ajeno y lo dejo como `Proximo paso`; otra ventana corria comandos con ese id desde 2
minutos antes del snippet.

`hilos_sin_reconciliar(transcript, pendientes, ficha_propia)` (2.64.0): pendientes abiertos ligados a un
plan, handoff o ficha que la sesion edito, cuando la sesion no corrigio ni cerro NINGUNO de ese
grupo (o, desde 2.65.0, el que la edicion nombra y la sesion no toco; ver abajo) (`pendiente.update`/`resolve`, en el cierre o fuera) ni creo uno nuevo que NOMBRE el grupo (su
plan, su handoff o su ficha en el comando; un `pendiente.add` suelto no cuenta). Caso que la motivo (otro
proyecto, 2026-10-24): el hecho que volvia falso un pendiente (un servidor ya parchado) vivio en el
plan y en otra ventana, y el texto del pendiente siguio diciendo lo viejo hasta que un 🔔 lo destapo.
Medido por el revisor: en ese caso la sesion tambien actualizo OTRO pendiente del mismo plan, y hasta
2.64.2 este aviso (que se apaga por grupo en cuanto se toca uno) NO lo disparaba. Desde 2.65.0 un
pendiente del grupo cuyo id aparece en el texto de la edicion (old/new de Edit o MultiEdit; el
comando Bash que escribe el plan, si no nombra tambien una ficha) sale aunque otro del grupo se haya
tocado, salvo que la sesion lo actualizo, cerro o bloqueo. Replay del incidente: 1 id, el que quedo
falso (`tools/replay-aviso-b-id-nombrado.py`). Un Write no aporta ids: reescribe el archivo entero y
nombraria todos (medido: era casi todo el ruido de fichas, sobre todo la ficha que la misma sesion
escribio en un cierre anterior); un plan reescrito con Write solo lo ve la regla de grupo.
Solo cruza por ids y campos (`_relacionado`, `_origen`, la ruta del handoff en el texto), nunca
palabras; no ve un hecho que nadie escribio en un plan/handoff/ficha. Una edicion por Bash cuenta si el
comando nombra `memory/plans/<plan>.md` y trae una forma de escritura (`>`, `tee`, `sed -i`, `open(`,
`.write`): heuristica, y puede avisar de mas con un `cat plan > otro`.

Limite declarado: mira ids, no trabajo. Una ventana que nombro el id hace mas de 2 h y sigue viva
no sale. Una sesion que trabajo un pendiente sin nombrar su id ni
emitir `update`/`resolve` sale como "no lo trabajo" (aviso de mas, no bloquea); una ventana que lo
trabaja sin escribir su id en un comando no sale. Solo ve las ventanas del mismo directorio de
transcripts y de los que empiezan por su nombre (worktrees dentro del proyecto). Falla abierto:
un transcript ilegible no produce aviso.
"""
# sella-huellas: no (solo lee transcripts; no escribe nada)
import datetime
import glob
import json
import os
import re
import sys
import time

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

# Eventos que no son trabajo sobre el pendiente: ordenarlo, ligarlo, fecharlo o marcarlo.
MANTENIMIENTO = re.compile(r"--type[\s=]+pendiente\.(relate|block|window|retomar)\b|marcar-retomar\.py")
# Eventos que si lo son: corregir su texto o cerrarlo.
TRABAJO = re.compile(r"--type[\s=]+pendiente\.(update|resolve)\b")
ALTA = re.compile(r"--type[\s=]+pendiente\.add\b")
# Para la regla por id nombrado (2.65.0): bloquear tambien reconcilia el pendiente que se nombra.
BLOQUEO = re.compile(r"--type[\s=]+pendiente\.block\b")
HERRAMIENTAS_ACCION = ("Bash", "Edit", "Write", "MultiEdit", "NotebookEdit")
# Copias de checkpoint-close-guard.sh (TAG_CHECKPOINT, INYECTADO): el guard es un heredoc, no un
# modulo importable.
TAG_CHECKPOINT = re.compile(r"<command-name>/(?:[\w.-]+:)?checkpoint-3t</command-name>")
INYECTADO = re.compile(r"^\s*(?:Another Claude session sent a message|<teammate-message|"
                       r"<task-notification>|\[SYSTEM NOTIFICATION)")


def _registros(ruta):
    try:
        with open(ruta, encoding="utf-8", errors="replace") as f:
            for linea in f:
                try:
                    yield linea, json.loads(linea)
                except ValueError:
                    continue
    except OSError:
        return


def _bloques(r):
    c = (r.get("message") or {}).get("content")
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return [b for b in c or [] if isinstance(b, dict)]


def _texto_tool_result(b):
    c = b.get("content")
    if isinstance(c, str):
        return c
    return " ".join(x.get("text", "") for x in c or [] if isinstance(x, dict))


def _es_memoria(ruta):
    return "/memory/" in (ruta or "").replace("\\", "/")


def _es_prompt_real(r):
    """Mensaje que abre un turno (misma regla que es_prompt_real de checkpoint-close-guard.sh)."""
    if r.get("type") != "user" or r.get("isMeta"):
        return False
    partes = [b.get("text", "") for b in _bloques(r) if b.get("type") == "text"]
    return bool(partes) and not any(b.get("type") == "tool_result" for b in _bloques(r)) \
        and not INYECTADO.match(partes[0])


def _es_checkpoint(r):
    if r.get("type") == "user":
        return any(TAG_CHECKPOINT.search(b.get("text", "")) for b in _bloques(r) if b.get("type") == "text")
    return r.get("type") == "assistant" and any(
        b.get("type") == "tool_use" and b.get("name") == "Skill"
        and str((b.get("input") or {}).get("skill", "")).split(":")[-1] == "checkpoint-3t"
        for b in _bloques(r))


def trabajo_propio(transcript, ids):
    """{id: (trabajado: bool, [que hizo])}. Trabajado = lo recibio o lo pidio el usuario, lo creo
    (`pendiente.add` que imprimio el id), o, en un turno que NO corrio /checkpoint-3t, lo corrigio o
    cerro (`update`/`resolve`) o edito fuera de memory/ algo que lo nombra. Lo que hace el cierre
    (Step 3a corrige textos, liga, desbloquea, fecha, marca) es ordenar, no trabajar: en el caso
    real la sesion emitio `pendiente.update` sobre el pendiente ajeno en su checkpoint.
    Ligar, desbloquear, fechar, marcar o leer nunca cuentan."""
    res = {i: [False, []] for i in ids}
    regs = [r for _, r in _registros(transcript)] if ids and transcript else []
    if not regs:
        return None  # sin transcript legible no se sabe: falla abierto, sin aviso
    turno, cierre = [], set()
    t = 0
    for r in regs:
        if _es_prompt_real(r):
            t += 1
        turno.append(t)
        if _es_checkpoint(r):
            cierre.add(t)
    altas = set()
    for k, r in enumerate(regs):
        linea = json.dumps(r, ensure_ascii=False)
        if not any(i in linea for i in ids) and "pendiente.add" not in linea:
            continue
        en_cierre = turno[k] in cierre
        tipo = r.get("type")
        for b in _bloques(r):
            bt = b.get("type")
            if tipo == "user" and bt == "text":
                for i in ids:
                    if i in b.get("text", "") and not r.get("isMeta"):
                        res[i][0] = True
                        res[i][1].append("lo recibio o lo pidio el usuario")
            elif tipo == "user" and bt == "tool_result":
                if b.get("tool_use_id") in altas:
                    t = _texto_tool_result(b)
                    for i in ids:
                        if i in t:
                            res[i][0] = True
                            res[i][1].append("lo creo (pendiente.add)")
            elif tipo == "assistant" and bt == "tool_use":
                inp = b.get("input") or {}
                if b.get("name") == "Bash":
                    cmd = str(inp.get("command", ""))
                    if ALTA.search(cmd):
                        altas.add(b.get("id"))
                    for i in ids:
                        if i not in cmd:
                            continue
                        if TRABAJO.search(cmd) and not en_cierre:
                            res[i][0] = True
                            res[i][1].append("lo corrigio o cerro (" + TRABAJO.search(cmd).group(1) + ")")
                        elif TRABAJO.search(cmd):
                            res[i][1].append("solo " + TRABAJO.search(cmd).group(1) + " en el cierre")
                        elif MANTENIMIENTO.search(cmd):
                            m = MANTENIMIENTO.search(cmd)
                            res[i][1].append("solo " + (m.group(1) or "marcar-retomar"))
                elif b.get("name") in HERRAMIENTAS_ACCION:
                    s = json.dumps(inp, ensure_ascii=False)
                    for i in ids:
                        if i in s and not en_cierre \
                                and not _es_memoria(inp.get("file_path") or inp.get("notebook_path")):
                            res[i][0] = True
                            res[i][1].append("edito " + os.path.basename(inp.get("file_path") or "?"))
    return {i: (v[0], list(dict.fromkeys(v[1]))) for i, v in res.items()}


def _epoch(r, defecto):
    ts = r.get("timestamp")
    if not isinstance(ts, str):
        return defecto
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return defecto


def otras_ventanas(transcript, ids, horas=2, ahora=None):
    """{id: [nombre de transcript]} de otras sesiones que, en las ultimas `horas`, corrieron una
    herramienta de accion (Bash, Edit, Write…) cuyo input nombra el id, y no corrieron
    /checkpoint-3t despues: una sesion que ya cerro no lleva el trabajo, el que retome si.
    Con 24 h y sin mirar el cierre (primera version), el adversario lo midio en 12 de 21 fichas
    reales del 2026-10-22, casi todo sesiones anteriores del mismo hilo; la auditoria tenia 3 choques
    reales en 101 fichas. Sin contar el turno de cierre de la otra sesion ni sus ediciones a
    memory/, y repetido sobre 22 cierres reales del 2026-10-22 con el cierre como "ahora": 1, 2 y
    3 h -> 1 (el caso real); 24 h -> 8. Un registro sin `timestamp` toma la hora del fichero."""
    out = {i: [] for i in ids}
    if not ids or not transcript:
        return out
    carpeta = os.path.dirname(os.path.abspath(transcript))
    raiz, base = os.path.dirname(carpeta), os.path.basename(carpeta)
    propio = os.path.basename(transcript)
    ahora = ahora or time.time()
    candidatos = []
    for d in glob.glob(os.path.join(glob.escape(raiz), glob.escape(base) + "*")):
        if not os.path.isdir(d):
            continue
        for f in glob.glob(os.path.join(glob.escape(d), "*.jsonl")):
            try:
                if os.path.basename(f) == propio or ahora - os.path.getmtime(f) > horas * 3600:
                    continue
            except OSError:
                continue
            candidatos.append(f)
    for f in sorted(candidatos):
        try:
            mtime = os.path.getmtime(f)
        except OSError:
            continue
        vistos = set()
        en_cierre = False
        for linea, r in _registros(f):
            if (_epoch(r, None) or 0) > ahora:
                break  # despues del cierre que se mide (solo pasa al repetir un cierre viejo)
            if _es_prompt_real(r):
                en_cierre = False
            if _es_checkpoint(r):
                # Lo que nombro antes de su cierre ya no lo lleva, y su turno de cierre (la ficha,
                # el plan, los eventos) es ordenar, no trabajar (adversario de 2.63.43, ronda 2:
                # la sesion que cerro seguia contando por el Write de su propia ficha).
                vistos = set()
                en_cierre = True
                continue
            if en_cierre or r.get("type") != "assistant" or not any(i in linea for i in ids) \
                    or ahora - _epoch(r, mtime) > horas * 3600:
                continue
            for b in _bloques(r):
                if b.get("type") == "tool_use" and b.get("name") in HERRAMIENTAS_ACCION \
                        and not _es_memoria((b.get("input") or {}).get("file_path")):
                    s = json.dumps(b.get("input") or {}, ensure_ascii=False)
                    vistos |= {i for i in ids if i in s}
        for i in sorted(vistos):
            out[i].append(os.path.basename(f))
    return out


BASH_PLAN = re.compile(r"memory/plans/([\w.-]+)\.md")
ESCRIBE = re.compile(r"(?<![\d&>])>(?![&>]?\s*/dev/null)|\btee\b|sed\s+-i|\bopen\(|\.write")
PLAN_RUTA = re.compile(r"/memory/plans/([^/]+)\.md$")
FICHA_RUTA = re.compile(r"/memory/sessions/([^/]+)\.md$")
EDICION = ("Edit", "Write", "MultiEdit")
BASH_FICHA = re.compile(r"memory/sessions/[\w.-]+\.md")
ID_PEND = re.compile(r"\bp-[0-9a-f]{10}(?![0-9a-f])")


def hilos_sin_reconciliar(transcript, pendientes, ficha_propia=None):
    """[(grupo, [ids])]: por cada plan/handoff/ficha que esta sesion edito y que liga pendientes
    abiertos, los ids si la sesion no actualizo, cerro ni creo ninguno ligado a ese grupo.
    `pendientes` = lista de dicts de pendientes_afines.pendientes (id, texto, rel, origen).
    None si no hay transcript legible (falla abierto)."""
    regs = [r for _, r in _registros(transcript)] if transcript else []
    if not regs:
        return None
    rutas, tocados_ids, bloqueados_ids, altas = [], set(), set(), []
    nombrados = []  # (ruta, ids que nombra el texto de la edicion)
    for r in regs:
        if r.get("type") != "assistant":
            continue
        for b in _bloques(r):
            if b.get("type") != "tool_use":
                continue
            inp = b.get("input") or {}
            if b.get("name") in EDICION:
                ruta = (inp.get("file_path") or "").replace("\\", "/")
                rutas.append(ruta)
                txt = " ".join(str(inp.get(k) or "") for k in ("old_string", "new_string"))
                txt += " ".join(str(e.get("old_string") or "") + " " + str(e.get("new_string") or "")
                                for e in inp.get("edits") or [] if isinstance(e, dict))
                nombrados.append((ruta, set(ID_PEND.findall(txt))))
            elif b.get("name") == "Bash":
                cmd = str(inp.get("command", ""))
                if TRABAJO.search(cmd):
                    tocados_ids |= set(ID_PEND.findall(cmd))
                if BLOQUEO.search(cmd):
                    bloqueados_ids |= set(ID_PEND.findall(cmd))
                if ALTA.search(cmd):
                    altas.append(cmd)
                for pl in BASH_PLAN.findall(cmd):
                    if ESCRIBE.search(cmd):
                        rutas.append("/memory/plans/" + pl + ".md")
                        if not BASH_FICHA.search(cmd):
                            nombrados.append(("/memory/plans/" + pl + ".md", set(ID_PEND.findall(cmd))))
    grupos, rutas_grupo = {}, {}
    propia = (ficha_propia or "").rsplit("/", 1)[-1]
    propia = propia[:-3] if propia.endswith(".md") else propia
    for ruta in rutas:
        m = PLAN_RUTA.search(ruta)
        if m:
            slug = m.group(1)
            claves = {slug, "plan-" + slug}
            ids = [p["id"] for p in pendientes if claves & set(p.get("rel") or ())]
            grupos.setdefault("plan " + slug, ids)
            rutas_grupo.setdefault(ruta, "plan " + slug)
            continue
        m = FICHA_RUTA.search(ruta)
        if m and m.group(1) != propia:
            ids = [p["id"] for p in pendientes if (p.get("origen") or "").rsplit("/", 1)[-1] == m.group(1)]
            grupos.setdefault("ficha " + m.group(1), ids)
            rutas_grupo.setdefault(ruta, "ficha " + m.group(1))
            continue
        if "/handoffs/" in ruta and ruta.endswith(".md"):
            base = os.path.basename(ruta)
            ids = [p["id"] for p in pendientes if base in (p.get("texto") or "")]
            grupos.setdefault("handoff " + base, ids)
            rutas_grupo.setdefault(ruta, "handoff " + base)
    en_texto = {}
    for ruta, ids_txt in nombrados:
        g = rutas_grupo.get(ruta)
        if g:
            en_texto.setdefault(g, set()).update(ids_txt)
    reconciliados = tocados_ids | bloqueados_ids
    out = []
    for g, ids in grupos.items():
        tipo, _, nombre = g.partition(" ")
        claves = {nombre, "plan-" + nombre} if tipo == "plan" else {nombre}
        nombra = any(k in cmd for cmd in altas for k in claves)
        if ids and not nombra and not (set(ids) & tocados_ids):
            out.append((g, ids))
            continue
        sueltos = [i for i in ids if i in en_texto.get(g, ()) and i not in reconciliados]
        if sueltos:
            out.append((g, sueltos))
    return out
