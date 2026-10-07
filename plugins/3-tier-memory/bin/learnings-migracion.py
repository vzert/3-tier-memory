#!/usr/bin/env python3
"""
3-tier-memory plugin: llevar un corpus viejo de learnings al estado de la F7 (2.51.0).

La F7 del plan de ciclo de vida de learnings se hizo a mano en el repo del plugin: corregir las
reglas que corrigen a otra (H11), decidir los pares casi duplicados, enlazar cada linea del
'## Quick Reference' con su regla y escribir disparadores en esas reglas. Este script es la parte
mecanica de `/migrate-learnings-3t`, que lo hace en la instalacion de cada usuario con su
aprobacion. No edita reglas ni indices: los cambios van por eventos del journal (journal-emit.py),
que emiten --aplicar-enlaces y --aplicar-disparadores; --decidir escribe .migracion-learnings.json.

Modos (uno por llamada):
  --estado     JSON: los criterios de la F7 y lo que falta (para el comando y para /audit-3t).
  --aviso      una linea para el arranque de sesion, o nada. Sale 0 siempre (un aviso no tumba el
               arranque). Barato: no mira pares (O(n^2)). Solo cuenta lo que el comando puede
               arreglar: una linea que el journal no puede reescribir (codigo-antes, ...) no avisa.
  --candidatos JSONL: para cada linea del Quick Reference sin marca de enlace, las 6 reglas vivas
               mas parecidas de TODOS los topics (Dice-IDF, la medida de learning_vecinos). Una vineta,
               o una regla cuyo numero se repite en su topic, es un candidato `<topic>`: no tiene
               `topic#N` univoco.
  --lote       JSONL: reglas vivas sin disparadores que el journal puede reescribir, por prioridad
               (--nivel 1: las enlazadas desde el Quick Reference; 2: citadas como topic#N en fichas
               de sesion de los ultimos 30 dias; 3: nombran un comando o una ruta; 4: el resto).
  --decidir    anota en .migracion-learnings.json que la persona decidio dejar SIN disparadores las
               reglas que se pasan (`topic#N`, varias): el aviso deja de contarlas.
  --aplicar-enlaces F      F es JSONL {"prefijo": ..., "regla": "<topic>#<N>"|"<topic>"|"ninguna"}
               (lo decidido por el juez y la persona). Emite un learning.update --quickref-regla por
               fila y compacta. No decide nada: aplica lo que ya se decidio.
  --aplicar-disparadores F JSONL {"id": "<topic>#<N>", "match_prefix": ..., "frases": [...],
               "cmd": [...], "path": [...], "tool": [...]} (la salida del escritor, con el
               match_prefix de --lote). Valida cada fila, emite learning.update --disparadores en
               lotes de 25 y compacta antes y despues de cada lote.

Medido al escribirlo (2026-10-06): en el corpus de este repo el candidato 1 era la regla correcta
en 154 de 161 lineas y la correcta estaba entre las 6 en 158; en otra instalacion, con 27 topics,
en 18 de 21 y 21 de 21. Por eso el comando no enlaza solo con el candidato 1: lo confirma un juez.

Sin dependencias (I4).
"""
# sella-huellas: no (lee memory/; solo escribe .migracion-learnings.json, que no es un indice)
import argparse
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import date

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

_BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _BIN)
sys.dont_write_bytecode = True   # sin __pycache__ dentro del plugin instalado
import learning_marks  # noqa: E402
import learning_vecinos  # noqa: E402

ESTADO = ".migracion-learnings.json"
C3_MINIMO = 90.0          # % de lineas del Quick Reference enlazadas cuya regla lleva disparadores
K = 6
DIAS_FICHAS = 30
_CMD_O_RUTA = re.compile(r"`[^`]*(/|\b(?:git|gh|npm|python3?|bash|ssh|curl|docker|claude)\b)[^`]*`")


def _modulo(nombre, fichero):
    spec = importlib.util.spec_from_file_location(nombre, os.path.join(_BIN, fichero))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


_aviso_mod = None


def consolidate():
    global _aviso_mod
    if _aviso_mod is None:
        _aviso_mod = _modulo("consolidate_aviso", "consolidate-aviso.py")
    return _aviso_mod


_jc = None


def compactador():
    global _jc
    if _jc is None:
        _jc = _modulo("journal_compact", "journal-compact.py")
    return _jc


def quick_reference(mem):
    """[{qr, texto, marca, rota, bloqueo}] de las lineas del '## Quick Reference' (numeradas o
    vinetas: el journal ancla las dos). `qr` es el numero o `v<k>` para la k-esima vineta.
    `bloqueo` es el motivo por el que el journal NO puede reescribir la linea (regla_reescribible
    del compactador: la misma definicion que aplicara al evento), o "" si puede."""
    jc = compactador()
    try:
        lineas = jc.read_lines(os.path.join(mem, "_learnings.md"))
    except OSError:
        return []
    sec = jc.section_bounds(lineas, "## Quick Reference")
    if not sec:
        return []
    s0, s1 = sec
    out, k = [], 0
    for i in range(s0, s1):
        n, t = jc.rule_text(lineas[i])
        if not t:
            continue
        if n is None:
            k += 1
        v = learning_marks.regla_qr_de(t)
        out.append({"qr": n if n is not None else f"v{k}", "texto": learning_marks.sin_regla_qr(t),
                    "marca": v, "rota": bool(learning_marks.sufijo_regla_qr(t)) and v is None,
                    "bloqueo": jc.regla_reescribible(lineas, i, s1) or ""})
    return out


def corpus(mem):
    """{topic: {"numeradas": {n: [texto, ...]}, "vinetas": [texto], "contenido": str}}."""
    out = {}
    for topic, contenido in consolidate().topics(mem):
        num, vin = {}, []
        for _e, n, t in consolidate().reglas(contenido):
            if n is None:
                vin.append(t)
            else:
                num.setdefault(n, []).append(t)
        out[topic] = {"numeradas": num, "vinetas": vin, "contenido": contenido}
    return out


def destino(cor, valor):
    """(ok, motivo) de una marca: apunta a algo que existe hoy y esta vivo."""
    if valor == "ninguna":
        return True, ""
    topic, _, n = valor.partition("#")
    c = cor.get(topic)
    if c is None:
        return False, "el topic no existe"
    if not n:
        return True, ""
    hits = c["numeradas"].get(int(n), [])
    if len(hits) != 1:
        return False, f"hay {len(hits)} reglas #{n} en el topic"
    if learning_marks.regla_retirada(hits[0]):
        return False, f"la regla #{n} esta retirada"
    return True, ""


def leer_decididas(mem):
    try:
        with open(os.path.join(mem, ESTADO), encoding="utf-8") as fh:
            e = json.load(fh)
        d = e.get("sin_disparadores") if isinstance(e, dict) else None
        return {x for x in d if isinstance(x, str)} if isinstance(d, list) else set()
    except (OSError, ValueError):
        return set()


def repetidos(cor):
    return [f"{t}#{n}" for t, c in cor.items() for n, ts in sorted(c["numeradas"].items())
            if len(ts) > 1]


def estado(mem, rapido=False):
    """Los criterios de la F7 sobre memory/. `rapido` (el aviso) no calcula pares ni mira si una
    regla es reescribible (eso carga el compactador)."""
    cor = corpus(mem)
    qr = quick_reference(mem)
    decididas = leer_decididas(mem)
    sin_marca = [x["qr"] for x in qr if x["marca"] is None and not x["rota"] and not x["bloqueo"]]
    bloqueadas = [{"qr": x["qr"], "motivo": x["bloqueo"]} for x in qr
                  if x["marca"] is None and x["bloqueo"]]
    rotas, por_tipo = [], {"numerada": 0, "topic": 0, "ninguna": 0}
    enlazadas = []
    for x in qr:
        n, v = x["qr"], x["marca"]
        if x["rota"]:
            rotas.append({"qr": n, "motivo": "marca ilegible"})
            continue
        if v is None:
            continue
        ok, motivo = destino(cor, v)
        if not ok:
            rotas.append({"qr": n, "regla": v, "motivo": motivo})
            continue
        por_tipo["ninguna" if v == "ninguna" else ("numerada" if "#" in v else "topic")] += 1
        if "#" in v:
            enlazadas.append((n, v))
    con_disp, sin_disp = [], []
    for n, v in enlazadas:
        topic, _, num = v.partition("#")
        t = cor[topic]["numeradas"][int(num)][0]
        (con_disp if learning_marks.disparadores_de(t) else sin_disp).append(v)
    sin_disp_vivas = sorted(set(sin_disp) - decididas)
    pct = round(100.0 * len(con_disp) / len(enlazadas), 1) if enlazadas else None
    s = consolidate().senales(mem, con_pares=not rapido)
    e = {
        "quick_reference": len(qr),
        "enlazadas": por_tipo,
        "sin_enlace": sin_marca,
        "sin_enlace_bloqueadas": bloqueadas,
        "enlace_roto": rotas,
        "numeros_repetidos": repetidos(cor),
        "c1_h11": s["h11"],
        "c2_pares": None if rapido else s["pares"],
        "c3": {"enlazadas_a_regla_numerada": len(enlazadas), "con_disparadores": len(con_disp),
               "porcentaje": pct, "minimo": C3_MINIMO,
               "sin_disparadores": sin_disp_vivas,
               "sin_disparadores_por_decision": sorted(set(sin_disp) & decididas)},
        "c4_banco": "fuera del plugin: el banco de recall vive en el repo del plugin "
                    "(tools/recall-bench), no en la instalacion",
    }
    if not rapido:
        jc = compactador()
        bloq = []
        for v in sin_disp_vivas:
            motivo = _no_reescribible(jc, mem, v)
            if motivo:
                bloq.append({"regla": v, "motivo": motivo})
        e["c3"]["no_reescribibles"] = bloq
        e["c5_retiros"] = retiros(mem)
    e["criterios"] = {
        "c1": not e["c1_h11"],
        "c2": None if rapido else not e["c2_pares"],
        "c3": pct is not None and pct >= C3_MINIMO and not sin_marca and not rotas,
        "c3_lineas_que_el_journal_no_puede_marcar": len(bloqueadas),
    }
    return e


def _no_reescribible(jc, mem, v):
    topic, _, n = v.partition("#")
    try:
        lines = jc.read_lines(os.path.join(mem, "learnings", topic + ".md"))
    except OSError:
        return "el topic no existe"
    start, end = jc.body_region(lines)
    idx = jc.reglas_numero(lines, start, end, int(n))
    if not idx:
        return "no existe"
    return jc.regla_reescribible(lines, idx[0], end) if len(idx) == 1 else "numero repetido"


def retiros(mem):
    """learning.retire aplicados (en .journal/applied/, recursivo: van por mes) y cuantos llevan
    una nota que dice "aprobado"."""
    total = aprob = 0
    for f in glob.glob(os.path.join(mem, ".journal", "applied", "**", "*.json"), recursive=True):
        try:
            with open(f, encoding="utf-8") as fh:
                ev = json.load(fh)
        except (OSError, ValueError):
            continue
        if ev.get("type") != "learning.retire":
            continue
        total += 1
        if "aprobado" in str((ev.get("payload") or {}).get("nota") or "").lower():
            aprob += 1
    return {"total": total, "con_nota_de_aprobacion": aprob}


def linea_aviso(e):
    partes = []
    if e["sin_enlace"]:
        partes.append(f"{len(e['sin_enlace'])} lineas del Quick Reference sin enlace a su regla")
    if e["enlace_roto"]:
        partes.append(f"{len(e['enlace_roto'])} con el enlace roto")
    c3 = e["c3"]
    if c3["porcentaje"] is not None and c3["porcentaje"] < C3_MINIMO and c3["sin_disparadores"]:
        partes.append(f"{len(c3['sin_disparadores'])} reglas del Quick Reference sin disparadores "
                      f"({c3['porcentaje']} % con ellos)")
    if not partes:
        return ""
    return "MIGRAR-LEARNINGS: " + "; ".join(partes) + ". Corre /migrate-learnings-3t."


def candidatos(mem, k=K):
    cor = corpus(mem)
    rep = set(repetidos(cor))
    cand = []
    for topic, c in cor.items():
        # Una regla con numero repetido en su topic (hay corpus que renumeran por seccion) o una
        # vineta no tiene `topic#N` univoco: su candidato es el topic.
        if c["numeradas"]:
            for n, ts in c["numeradas"].items():
                rid = f"{topic}#{n}"
                cand += [(topic if rid in rep else rid, t) for t in ts]
        else:
            cand += [(topic, t) for t in c["vinetas"]]
    qr = quick_reference(mem)
    for x in qr:
        if (x["marca"] is not None and not x["rota"]) or x["bloqueo"]:
            continue
        n, t = x["qr"], x["texto"]
        vistos, top = set(), []
        for s, e, txt in learning_vecinos.vecinos(t, cand, k=k * 4):
            if e in vistos:
                continue
            vistos.add(e)
            top.append({"regla": e, "parecido": round(s, 3),
                        "texto": learning_marks.sin_marca(txt)[:400]})
            if len(top) == k:
                break
        yield {"qr": n, "linea": t, "prefijo": prefijo(t, [y["texto"] for y in qr if y is not x]),
               "candidatas": top}


def prefijo(t, otros=()):
    """El --quickref-prefix / --match-prefix: el principio del texto de hoy, desde ~40 caracteres y
    alargado palabra a palabra hasta que ninguna de `otros` (las demas lineas de la misma seccion)
    empiece igual. Se compara con plain() del compactador, que es como el ancla. Si ni el texto
    entero es unico, se devuelve entero y el compactador lo manda a cuarentena `ambiguous`."""
    jc = compactador()
    t = " ".join(learning_marks.sin_marca(t).split())
    rivales = [jc.plain(o) for o in otros]
    corte = t.rfind(" ", 0, 40) if len(t) > 40 else len(t)
    corte = corte if corte > 10 else min(40, len(t))
    while True:
        cand = t[:corte]
        pc = jc.plain(cand)
        if not any(r.startswith(pc) for r in rivales) or corte >= len(t):
            return cand
        sig = t.find(" ", corte + 1)
        corte = len(t) if sig < 0 else sig


def citadas_en_fichas(mem, dias=DIAS_FICHAS):
    limite = time.time() - dias * 86400
    out = set()
    for f in glob.glob(os.path.join(mem, "sessions", "*.md")):
        try:
            if os.path.getmtime(f) < limite:
                continue
            with open(f, encoding="utf-8", errors="replace") as fh:
                txt = fh.read()
        except OSError:
            continue
        for m in re.finditer(r"([A-Za-z0-9][A-Za-z0-9._-]*)(?:\.md)?\]{0,2}\s*#(\d+)\b", txt):
            out.add(f"{m.group(1).split('/')[-1]}#{m.group(2)}")
    return out


def lote(mem, nivel, tam):
    cor = corpus(mem)
    rep = set(repetidos(cor))
    decididas = leer_decididas(mem)
    jc = compactador()
    enl = {x["marca"] for x in quick_reference(mem) if x["marca"] and "#" in x["marca"]}
    cit = citadas_en_fichas(mem) if nivel >= 2 else set()
    out = []
    for topic, c in cor.items():
        for n, ts in sorted(c["numeradas"].items()):
            rid = f"{topic}#{n}"
            t = ts[0]
            if (rid in rep or rid in decididas or learning_marks.regla_retirada(t)
                    or learning_marks.disparadores_de(t)):
                continue
            nv = 1 if rid in enl else 2 if rid in cit else 3 if _CMD_O_RUTA.search(t) else 4
            if nv > nivel:
                continue
            if _no_reescribible(jc, mem, rid):
                continue
            vec = [learning_vecinos.titulo(tv) for _s, _e, tv in learning_vecinos.vecinos(
                t, [(f"{topic}#{m}", x[0]) for m, x in c["numeradas"].items() if m != n], k=3)]
            otros = [x for m, xs in c["numeradas"].items() for x in xs if m != n] + c["vinetas"]
            out.append({"id": rid, "nivel": nv, "match_prefix": prefijo(t, otros),
                        "texto": learning_marks.sin_marca(t), "vecinos": vec})
    out.sort(key=lambda x: x["nivel"])
    return out[:tam] if tam else out


def _emitir(mem, args):
    p = subprocess.run([sys.executable, os.path.join(_BIN, "journal-emit.py"), "--memory-dir", mem,
                        *args], capture_output=True, text=True)
    return p.returncode, (p.stderr or p.stdout).strip()


def _compactar(mem):
    p = subprocess.run([sys.executable, os.path.join(_BIN, "journal-compact.py"), "--memory-dir",
                        mem], capture_output=True, text=True)
    lineas = (p.stdout + p.stderr).strip().splitlines()
    return p.returncode, lineas[-1] if lineas else ""


def _filas(f):
    out = []
    with open(f, encoding="utf-8") as fh:
        for k, l in enumerate(fh, 1):
            if l.strip():
                try:
                    out.append(json.loads(l))
                except ValueError:
                    out.append({"_error": f"linea {k}: no es JSON"})
    return out


def aplicar_enlaces(mem, f):
    res = {"emitidos": 0, "rechazados": []}
    topics_ = [t for t, _c in consolidate().topics(mem)]
    for r in _filas(f):
        v = (r.get("regla") or "").strip()
        if r.get("_error") or not r.get("prefijo") or not learning_marks.valor_regla_qr_valido(v):
            res["rechazados"].append({"fila": r, "motivo": r.get("_error") or "prefijo o regla invalidos"})
            continue
        # learning.update exige --topic; con `ninguna` no hay topic de la regla y cualquiera que
        # exista sirve (con solo --quickref-regla el compactador no toca ningun topic file).
        topic = v.split("#")[0] if v != "ninguna" else (topics_ or ["sin-topic"])[0]
        rc, err = _emitir(mem, ["--type", "learning.update", "--topic", topic,
                                "--quickref-prefix", r["prefijo"], "--quickref-regla", v])
        if rc:
            res["rechazados"].append({"fila": r, "motivo": err[-300:]})
        else:
            res["emitidos"] += 1
    res["compactado"] = _compactar(mem)[1]
    return res


def cadena_disparadores(r):
    partes = ["frases=" + " | ".join(str(x).strip() for x in r.get("frases") or [])]
    for k in ("cmd", "path", "tool"):
        vals = [str(x).strip() for x in r.get(k) or [] if x and str(x).strip()]
        if vals:
            partes.append(f"{k}=" + ", ".join(vals))
    return "; ".join(partes)


def aplicar_disparadores(mem, f, tam=25):
    filas = _filas(f)
    res = {"filas": len(filas), "emitidos": 0, "rechazados": [], "lotes": []}
    for i in range(0, len(filas), tam):
        antes = _compactar(mem)[1]
        for r in filas[i:i + tam]:
            rid = r.get("id") or ""
            if r.get("_error") or not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*#[1-9][0-9]*$", rid):
                res["rechazados"].append({"id": rid, "motivo": r.get("_error") or "id invalido (topic#N)"})
                continue
            # Lo que el compactador mandaria a cuarentena se dice aqui, sin emitir: la misma
            # comprobacion (regla_reescribible) y el mismo motivo.
            bloqueo = _no_reescribible(compactador(), mem, rid)
            if bloqueo:
                res["rechazados"].append({"id": rid, "motivo": f"el journal no puede reescribirla: {bloqueo}"})
                continue
            if not r.get("match_prefix"):
                res["rechazados"].append({"id": rid, "motivo": "sin match_prefix (sale de --lote)"})
                continue
            s = cadena_disparadores(r)
            malos = learning_marks.problemas_disparadores(s)
            if malos:
                res["rechazados"].append({"id": rid, "motivo": "; ".join(malos)})
                continue
            rc, err = _emitir(mem, ["--type", "learning.update", "--topic", rid.split("#")[0],
                                    "--match-prefix", r["match_prefix"], "--disparadores", s])
            if rc:
                res["rechazados"].append({"id": rid, "motivo": err[-300:]})
            else:
                res["emitidos"] += 1
        res["lotes"].append({"antes": antes, "despues": _compactar(mem)[1]})
    return res


def decidir(mem, ids):
    previas = leer_decididas(mem)
    nuevas = sorted(previas | set(ids))
    fd, tmp = tempfile.mkstemp(prefix=".migracion-learnings.", suffix=".tmp", dir=mem)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            json.dump({"fecha": date.today().isoformat(), "sin_disparadores": nuevas}, fh,
                      ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, os.path.join(mem, ESTADO))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return nuevas


def main():
    ap = argparse.ArgumentParser(description="Migracion de learnings (F7): estado, candidatos, lotes.")
    ap.add_argument("--memory-dir", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--estado", action="store_true")
    g.add_argument("--aviso", action="store_true")
    g.add_argument("--candidatos", action="store_true")
    g.add_argument("--lote", action="store_true")
    g.add_argument("--decidir", nargs="+", metavar="TOPIC#N")
    g.add_argument("--aplicar-enlaces", dest="aplicar_enlaces", metavar="F")
    g.add_argument("--aplicar-disparadores", dest="aplicar_disparadores", metavar="F")
    ap.add_argument("--nivel", type=int, default=1, choices=(1, 2, 3, 4))
    ap.add_argument("--tam", type=int, default=25)
    a = ap.parse_args()
    mem = a.memory_dir
    if a.aviso:
        try:
            if os.path.isfile(os.path.join(mem, "_learnings.md")):
                l = linea_aviso(estado(mem, rapido=True))
                if l:
                    print(l)
        except Exception:
            pass
        return 0
    if not os.path.isdir(os.path.join(mem, "learnings")):
        sys.exit(f"learnings-migracion: {mem}/learnings no existe")
    if a.estado:
        print(json.dumps(estado(mem), ensure_ascii=False, indent=2))
    elif a.candidatos:
        for c in candidatos(mem):
            print(json.dumps(c, ensure_ascii=False))
    elif a.lote:
        for r in lote(mem, a.nivel, a.tam):
            print(json.dumps(r, ensure_ascii=False))
    elif a.aplicar_enlaces:
        r = aplicar_enlaces(mem, a.aplicar_enlaces)
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 1 if r["rechazados"] else 0
    elif a.aplicar_disparadores:
        r = aplicar_disparadores(mem, a.aplicar_disparadores)
        print(json.dumps(r, ensure_ascii=False, indent=2))
        return 1 if r["rechazados"] else 0
    else:
        malos = [x for x in a.decidir if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*#[1-9][0-9]*$", x)]
        if malos:
            sys.exit(f"learnings-migracion: --decidir espera topic#N, no {malos}")
        print(f"learnings-migracion: {len(decidir(mem, a.decidir))} reglas sin disparadores por decision")
    return 0


if __name__ == "__main__":
    sys.exit(main())
