#!/usr/bin/env python3
"""
3-tier-memory plugin: mueve a Tier 3 el texto largo YA escrito en los indices Tier 2
(p-206fd62e68, propuesta f).

Por que existe: 2.63.47 dejo de escribir lineas largas nuevas (`pendiente.add --titulo`, avisos de
journal-emit), pero no toco las que ya estaban. Medido 2026-10-27 en 9 proyectos de esta maquina:
`_pendientes.md` con hasta 88 lineas de mas de 800 caracteres, `_learnings.md` con 206 (filas de
'## Topic Files' que llevan la regla entera), `_research-index.md` con 101. El agente que lee esos
indices paga todo ese texto en cada sesion.

Que hace, por cada linea de mas de --largas caracteres (800, el mismo umbral que
print-tier2-tamano.py) en los tres indices:
  _pendientes.md      `- [ ]` con `_id:`: Tier 2 queda con un titulo (<= 200 caracteres) y
                      `_actualizado:`; el texto entero va a la fila mensual (Tier 3) como
                      `<titulo> — detalle: <texto>`, la forma de 2.63.47. El id NO cambia. Sin
                      fila mensual, la crea (como apply_add_monthly) si la linea trae `_creado:`.
  _learnings.md       fila de tabla, linea numerada o vineta: la parte larga queda en un titulo.
  _research-index.md  fila de tabla: cada celda de mas de 200 caracteres queda en un titulo.
Destino Tier 3 de learnings y research: el fichero al que la linea ya apunta
(`<!-- regla: topic#N -->`, `[[learnings/x]]`, `[[research/x]]`). Si ese fichero ya contiene el
texto (normalizado), solo se acorta Tier 2. Si no, el texto entero se anade al FINAL del fichero
como cita (`> `) bajo `## Texto movido desde <indice> (FECHA)`: una cita no es regla ni vineta,
asi que no cambia la numeracion de learning.add ni lo que el recall cuenta como regla.

Orden: Tier 3 se escribe y se comprueba ANTES de acortar Tier 2. Si la comprobacion falla, esa
linea no se acorta.

Que NO hace (lo lista como `no-migrable: <motivo>` y no lo toca):
  - un pendiente sin `_id:` (adoptalo antes: journal-emit.py --type pendiente.adopt), sin
    `_creado:` y sin fila mensual, con la fila mensual ya cerrada, o largo solo por sus metadatos;
  - una linea de learnings o research sin fichero Tier 3 al que apunte, o que no existe.

Escribe a mano bajo el lock del journal (`.journal/.lock`), como repair-dualwrite.py y
repair-research-index.py, y re-sella las huellas de lo que escribe. Con eventos sin compactar en
`.journal/pending/` no aplica: un `pendiente.update` emitido con el texto viejo caeria en
cuarentena. Antes de escribir copia cada fichero que va a tocar en
`.journal/migrar-tier2/<fecha-hora>/`.

Uso:  migrar-tier2.py MEMORY_DIR [--apply] [--largas CHARS] [--budget SEG]
Sin --apply es un dry-run: lista una linea por candidato y no escribe nada.
Salida: `<indice>:<linea> <estado> -> <destino> | <titulo propuesto>` y un resumen
`candidatos=N migrables=M no_migrables=K`. Codigos: 0 ok; 1 entorno (sin compactador, lock
ocupado, eventos sin compactar); 2 uso.
"""
# sella-huellas: si
import argparse
import importlib.util
import os
import re
import shutil
import sys
import time
import unicodedata
from datetime import date

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

LIM_TITULO = 200
MIN_CORTE = 60
INDICES = ("_pendientes.md", "_learnings.md", "_research-index.md")
ID_RE = re.compile(r"_id:\s*(p-[0-9a-f]{10})_")
CREADO_RE = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
ORIGEN_RE = re.compile(r"_origen:\s*(.*?)_(?=\s*(?:—|$))")
REGLA_RE = re.compile(r"<!--\s*regla:\s*([A-Za-z0-9_.-]+)(?:#\d+)?\s*-->")
LINK_RE = {"learnings": re.compile(r"\[\[learnings/([^\]|#]+)"),
           "research": re.compile(r"\[\[research/([^\]|#]+)")}
SOLO_ENLACE_RE = re.compile(r"^\s*\[\[[^\]]+\]\]\s*$")
CLAVES_META = "origen|creado|id|revisar|actualizado|bloqueado|relacionado|retomar"
# Un metadato termina en el `_` que va seguido de espacio o fin: `[[sessions/a_b]]` lleva `_` dentro.
SEG_META_RE = re.compile(rf"_(?:{CLAVES_META}):.*?_(?=\s|$)")
LISTA_RE = re.compile(r"^(\s*(?:\d+\.|[-*])\s+)(.*?)((?:\s*<!--.*?-->)*)\s*$")


def load_compactor(bin_dir):
    path = os.path.join(bin_dir, "journal-compact.py")
    if not os.path.isfile(path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("jc", path)
        jc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(jc)
        return jc
    except Exception:
        return None


def normalizar(texto):
    """Forma de comparar 'este texto ya esta alli': sin enfasis, sin `\\|`, espacios colapsados."""
    t = unicodedata.normalize("NFC", texto).replace("\\|", "|")
    t = re.sub(r"\*\*|`", "", t)
    return re.sub(r"\s+", " ", t).strip().lower()


def titulo(texto, lim=LIM_TITULO):
    """Recorta a <= lim caracteres por un final de frase o de clausula, nunca a mitad de un
    `[[enlace]]`, sin dejar `**` o comillas invertidas abiertas ni un `\\` suelto al final (en una
    celda escaparia el `|` que la cierra)."""
    t = texto.strip()
    if len(t) <= lim:
        return t
    corte = t[:lim - 5]
    k = -1
    for sep in (". ", "; ", " — ", ": ", ", "):
        k = corte.rfind(sep)
        if k >= MIN_CORTE:
            break
    if k < MIN_CORTE:
        k = corte.rfind(" ")
    if k >= MIN_CORTE:
        corte = corte[:k]
    if corte.count("[[") > corte.count("]]"):
        corte = corte[:corte.rfind("[[")]
    corte = corte.rstrip(" \\,;:—-")
    if corte.count("**") % 2:
        corte += "**"
    if corte.count("`") % 2:
        corte += "`"
    return corte + "…"


# ---------------------------------------------------------------- pendientes

def partir_cola(cola):
    """(metadatos, prosa): la cola reescrita solo con sus `— _clave: valor_` (verbatim, en su
    orden) y el texto libre que habia entre ellos. Medido 2026-10-27: en dos proyectos reales la
    prosa vivia DESPUES de los metadatos (`_id: p-…_ **Alcance ampliado …**`, `_nota …_`)."""
    segs = SEG_META_RE.findall(cola)
    # Solo cae la raya que separa un metadato; una raya de la prosa se queda.
    resto = re.sub(r"\s*—\s*\x00", " ", SEG_META_RE.sub("\x00", cola)).replace("\x00", " ")
    prosa = re.sub(r"\s+", " ", resto).strip()
    return "".join(f" — {g}" for g in segs), prosa


def mensual_sin_tabla(jc, path):
    return os.path.isfile(path) and jc.last_table_line(jc.read_lines(path)) is None


def plan_pendientes(jc, mem, lines, largas):
    """[(n_linea, estado, destino, titulo, accion)] de las lineas largas de _pendientes.md."""
    out = []
    for i, linea in enumerate(lines):
        if len(linea) <= largas:
            continue
        s = linea.lstrip()
        if not s.startswith("- [ ]"):
            out.append(plan_subvineta(jc, mem, lines, i, linea))
            continue
        ids = ID_RE.findall(linea)
        if not ids:
            out.append((i, "no-migrable: sin _id (journal-emit.py --type pendiente.adopt)", "-",
                        "", None))
            continue
        pid = ids[-1]
        m = jc.META_START_RE.search(linea)
        if m is None:
            out.append((i, "no-migrable: sin cola de metadatos", "-", "", None))
            continue
        sangria = linea[:len(linea) - len(s)]
        texto = linea[len(sangria) + 5:m.start()].strip()
        cola, prosa = partir_cola(linea[m.start():])
        if prosa:
            texto = f"{texto} {prosa}"
        if f"_id: {pid}_" not in cola:
            out.append((i, "no-migrable: no se reconoce su `_id:` en la cola", "-", "", None))
            continue
        if len(texto) <= LIM_TITULO:
            out.append((i, "no-migrable: el largo esta en los metadatos, no en el texto", "-",
                        "", None))
            continue
        tit = titulo(texto)
        found = jc.find_monthly_row(mem, pid)
        if found:
            path, _l, _i, cells, _c = found
            if cells[jc.COL_RESUELTO]:
                out.append((i, "no-migrable: su fila mensual ya esta cerrada", os.path.relpath(
                    path, mem), tit, None))
                continue
            destino = os.path.relpath(path, mem)
            estado = ("acorta (Tier 3 ya lo tiene)"
                      if normalizar(texto) in normalizar(jc.detalle_de_celda(cells[jc.COL_TEXT]))
                      else "mueve")
        else:
            c = CREADO_RE.search(linea)
            if not c:
                out.append((i, "no-migrable: sin fila mensual y sin _creado", "-", tit, None))
                continue
            if mensual_sin_tabla(jc, jc.monthly_path(mem, c.group(1))):
                out.append((i, f"no-migrable: pendientes/{c.group(1)[:7]}.md no tiene tabla "
                               "(repair-dualwrite.py)", "-", tit, None))
                continue
            destino = os.path.relpath(jc.monthly_path(mem, c.group(1)), mem) + " (fila nueva)"
            estado = "mueve"
        accion = {"pid": pid, "texto": texto, "titulo": tit, "sangria": sangria, "cola": cola}
        out.append((i, estado, destino, tit, accion))
    return out


def padre_de(lines, i):
    """Indice del `- [ ]` del que cuelga la linea i (subiendo por vinetas de menos sangria: una
    vineta de segundo nivel cuelga del pendiente a traves de la de primero), o None."""
    sang = len(lines[i]) - len(lines[i].lstrip())
    for k in range(i - 1, -1, -1):
        l = lines[k]
        if l.startswith("#"):
            return None
        if l.strip() and len(l) - len(l.lstrip()) < sang:
            if l.lstrip().startswith("- [ ]"):
                return k
            if not LISTA_RE.match(l) or sang == 0:
                return None
            sang = len(l) - len(l.lstrip())
    return None


def plan_subvineta(jc, mem, lines, i, linea):
    """Una vineta con sangria bajo un pendiente abierto es detalle suyo: su texto entero va a la
    fila mensual del padre y Tier 2 queda con el titulo. Medido 2026-10-27: 11 de 103 lineas
    largas de un proyecto real eran estas sub-vinetas."""
    m = LISTA_RE.match(linea)
    k = padre_de(lines, i)
    if not m or not m.group(1).startswith((" ", "\t")) or k is None:
        return (i, "no-migrable: no es un pendiente abierto (`- [ ]`) ni una vineta suya", "-",
                "", None)
    pre, cuerpo, comentarios = m.groups()
    padre = lines[k]
    ids = ID_RE.findall(padre)
    if not ids:
        return (i, "no-migrable: su pendiente padre no tiene _id", "-", "", None)
    pid = ids[-1]
    tit = titulo(cuerpo)
    found = jc.find_monthly_row(mem, pid)
    if found:
        if found[3][jc.COL_RESUELTO]:
            return (i, "no-migrable: la fila mensual de su padre ya esta cerrada", "-", tit, None)
        destino = os.path.relpath(found[0], mem)
        ya = normalizar(cuerpo) in normalizar(jc.detalle_de_celda(found[3][jc.COL_TEXT]))
    else:
        c = CREADO_RE.search(padre)
        mp = jc.META_START_RE.search(padre)
        if not c or mp is None:
            return (i, "no-migrable: su padre no tiene fila mensual ni _creado", "-", tit, None)
        if mensual_sin_tabla(jc, jc.monthly_path(mem, c.group(1))):
            return (i, f"no-migrable: pendientes/{c.group(1)[:7]}.md no tiene tabla "
                       "(repair-dualwrite.py)", "-", tit, None)
        destino = os.path.relpath(jc.monthly_path(mem, c.group(1)), mem) + " (fila nueva)"
        ya = False
    sp = padre.lstrip()
    mp = jc.META_START_RE.search(padre)
    accion = {"pid": pid, "texto": cuerpo, "titulo": tit, "sub": f"{pre}{tit}{comentarios}",
              "padre_i": k, "padre_titulo": titulo(padre[len(padre) - len(sp) + 5:mp.start()].strip())
              if mp else pid, "cola": padre[mp.start():] if mp else ""}
    return (i, f"{'acorta (Tier 3 ya lo tiene)' if ya else 'mueve'} [vineta de {pid}]", destino,
            tit, accion)


def aplicar_pendiente(jc, mem, lines, i, a, hoy):
    """Escribe el detalle en la fila mensual, lo comprueba y solo entonces acorta Tier 2."""
    pid, texto = a["pid"], a["texto"]
    # La fila mensual lleva el titulo del PENDIENTE; el de una sub-vineta solo va a su linea.
    tit = a.get("padre_titulo") or a["titulo"]
    found = jc.find_monthly_row(mem, pid)
    if found:
        path, mlines, mi, cells, cmap = found
        viejo = jc.detalle_de_celda(cells[jc.COL_TEXT])
        if normalizar(texto) in normalizar(viejo):
            detalle = viejo
        else:
            detalle = f"{viejo} — {texto}" if viejo else texto
        nuevas = list(cells)
        # Una sub-vineta no cambia el titulo que la fila ya tiene.
        fila_tit = (re.sub(r"\s*_id:\s*p-[0-9a-f]{10}_\s*$", "", cells[jc.COL_TEXT])
                    .partition(jc.SEP_DETALLE)[0] if "sub" in a else tit)
        nuevas[jc.COL_TEXT] = f"{jc.celda_texto(fila_tit, detalle)} _id: {pid}_"
        if nuevas != cells:
            mlines[mi] = jc.render_row(nuevas, cmap)
            jc.atomic_write(path, mlines)
    else:
        creado = CREADO_RE.search(a["cola"]).group(1)
        o = ORIGEN_RE.search(a["cola"])
        prio = (jc.seccion_de(lines, a.get("padre_i", i)) or "media").capitalize()
        path = jc.monthly_path(mem, creado)
        jc.apply_add_monthly(mem, {"id": pid, "text": tit, "detalle": texto, "prioridad": prio,
                                   "creado": creado, "origen": o.group(1).strip() if o else ""})
    found = jc.find_monthly_row(mem, pid)
    if not found or normalizar(texto) not in normalizar(
            jc.detalle_de_celda(found[3][jc.COL_TEXT])):
        return None, "ERROR: el detalle no quedo en la fila mensual; Tier 2 no se toca"
    if "sub" in a:
        return (a["sub"], path), None
    cola = jc.ACTUALIZADO_RE.sub("", a["cola"]) + f" — _actualizado: {hoy}_"
    nueva = f"{a['sangria']}- [ ] {tit}{cola}"
    if f"_id: {pid}_" not in nueva:
        return None, "ERROR: la linea reconstruida perdio su id; no se toca"
    return (nueva, path), None


# ------------------------------------------------------ learnings y research

def cabecera_de_tabla(lines, i, jc):
    """Celdas de la cabecera de la tabla donde esta la fila i, o []."""
    k = i
    while k > 0 and lines[k - 1].lstrip().startswith("|"):
        k -= 1
    return jc.split_cells(lines[k]) if k < i else []


def destino_de(linea, tipo, mem):
    """Ruta relativa (a memory/) del fichero Tier 3 al que apunta la linea, o None."""
    if tipo == "learnings":
        m = REGLA_RE.search(linea)
        if m:
            return f"learnings/{m.group(1)}.md"
    m = LINK_RE[tipo].search(linea)
    if m:
        return f"{tipo}/{m.group(1).strip()}.md"
    return None


def plan_tabla_o_lista(jc, mem, lines, largas, tipo):
    out = []
    for i, linea in enumerate(lines):
        if len(linea) <= largas:
            continue
        rel = destino_de(linea, tipo, mem)
        if rel is None:
            out.append((i, f"no-migrable: no apunta a ningun fichero de {tipo}/", "-", "", None))
            continue
        if not os.path.isfile(os.path.join(mem, rel)):
            out.append((i, f"no-migrable: {rel} no existe", rel, "", None))
            continue
        piezas = []          # (etiqueta, texto largo, titulo)
        if linea.lstrip().startswith("|"):
            cells = jc.split_cells(linea)
            cab = cabecera_de_tabla(lines, i, jc)
            nuevas = list(cells)
            for c, cel in enumerate(cells):
                if len(cel) > LIM_TITULO and not SOLO_ENLACE_RE.match(cel):
                    nuevas[c] = titulo(cel)
                    piezas.append((cab[c] if c < len(cab) else f"columna {c + 1}", cel, nuevas[c]))
            nueva = jc.join_cells(nuevas)
        elif tipo == "learnings":
            m = LISTA_RE.match(linea)
            if not m:
                out.append((i, "no-migrable: ni fila de tabla ni linea de lista", rel, "", None))
                continue
            pre, cuerpo, comentarios = m.groups()
            tit = titulo(cuerpo)
            piezas.append(("", cuerpo, tit))
            nueva = f"{pre}{tit}{comentarios}"
        else:
            out.append((i, "no-migrable: no es fila de tabla", rel, "", None))
            continue
        if not piezas:
            out.append((i, "no-migrable: ninguna celda pasa de 200 caracteres", rel, "", None))
            continue
        try:
            with open(os.path.join(mem, rel), encoding="utf-8", errors="replace") as fh:
                dest = normalizar(fh.read())
        except OSError:
            dest = ""
        faltan = [p for p in piezas if normalizar(p[1]) not in dest]
        estado = "mueve" if faltan else "acorta (Tier 3 ya lo tiene)"
        if len(nueva) > largas:
            estado += f" (sigue larga: {len(nueva)})"
        out.append((i, estado, rel, " / ".join(p[2] for p in piezas),
                    {"rel": rel, "nueva": nueva, "faltan": faltan, "piezas": piezas}))
    return out


def aplicar_tier3(jc, mem, indice, a, hoy):
    """Anade al fichero destino las piezas que no contiene; comprueba que estan todas."""
    path = os.path.join(mem, a["rel"])
    if a["faltan"]:
        lines = jc.read_lines(path)
        while lines and lines[-1].strip() == "":
            lines.pop()
        cab = f"## Texto movido desde {indice} ({hoy})"
        if cab not in lines:
            lines += ["", cab]
        for etiqueta, texto, _t in a["faltan"]:
            lines += ["", f"> {'**' + etiqueta + ':** ' if etiqueta else ''}{texto}"]
        jc.atomic_write(path, lines + [""])
    with open(path, encoding="utf-8", errors="replace") as fh:
        dest = normalizar(fh.read())
    if any(normalizar(p[1]) not in dest for p in a["piezas"]):
        return "ERROR: el texto no quedo en el destino; Tier 2 no se toca"
    return None


def sigue_en_tier3(jc, mem, a):
    if "pid" in a:
        found = jc.find_monthly_row(mem, a["pid"])
        return bool(found) and normalizar(a["texto"]) in normalizar(
            jc.detalle_de_celda(found[3][jc.COL_TEXT]))
    with open(os.path.join(mem, a["rel"]), encoding="utf-8", errors="replace") as fh:
        dest = normalizar(fh.read())
    return all(normalizar(p[1]) in dest for p in a["piezas"])


# ---------------------------------------------------------------------- main

def respaldar(mem, rutas, carpeta):
    for r in rutas:
        if os.path.isfile(r):
            d = os.path.join(carpeta, os.path.dirname(os.path.relpath(r, mem)))
            os.makedirs(d, exist_ok=True)
            shutil.copy2(r, d)


def main():
    ap = argparse.ArgumentParser(description="Mueve a Tier 3 el texto largo de los indices Tier 2")
    ap.add_argument("memory_dir")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--largas", type=int, default=800)
    ap.add_argument("--budget", type=float, default=2.0)
    a = ap.parse_args()
    mem = os.path.abspath(a.memory_dir)
    jc = load_compactor(os.path.dirname(os.path.abspath(__file__)))
    if jc is None:
        print("migrar-tier2: falta journal-compact.py en el mismo bin/", file=sys.stderr)
        return 1
    if not os.path.isdir(mem):
        print(f"migrar-tier2: no existe {mem}", file=sys.stderr)
        return 1
    hoy = date.today().isoformat()

    lock = None
    if a.apply:
        pend = os.path.join(mem, ".journal", "pending")
        n = len([f for f in os.listdir(pend) if f.endswith(".json")]) if os.path.isdir(pend) else 0
        if n:
            print(f"migrar-tier2: hay {n} evento(s) sin compactar en .journal/pending/; corre "
                  f"journal-compact.py antes (un pendiente.update con el texto viejo caeria en "
                  f"cuarentena)", file=sys.stderr)
            return 1
        lock = jc.Lock(os.path.join(mem, ".journal"), a.budget)
        if not lock.acquire():
            print("migrar-tier2: el lock del journal esta ocupado; reintenta", file=sys.stderr)
            return 1
    try:
        planes = {}
        for nombre in INDICES:
            path = os.path.join(mem, nombre)
            if not os.path.isfile(path):
                continue
            lines = jc.read_lines(path)
            if nombre == "_pendientes.md":
                planes[nombre] = (lines, plan_pendientes(jc, mem, lines, a.largas))
            else:
                tipo = "learnings" if nombre == "_learnings.md" else "research"
                planes[nombre] = (lines, plan_tabla_o_lista(jc, mem, lines, a.largas, tipo))

        total = migrables = 0
        for nombre, (_lines, plan) in planes.items():
            for i, estado, destino, tit, accion in plan:
                total += 1
                migrables += accion is not None
                print(f"{nombre}:{i + 1} {estado} -> {destino} | {tit[:160]}")
        if not a.apply:
            print(f"candidatos={total} migrables={migrables} no_migrables={total - migrables} "
                  f"[dry-run: usa --apply]")
            return 0
        if not migrables:
            print(f"candidatos={total} migrables=0 no_migrables={total} (nada que aplicar)")
            return 0

        # Respaldo de todo lo que se puede tocar, antes de la primera escritura.
        rutas = [os.path.join(mem, n) for n in planes]
        for nombre, (_l, plan) in planes.items():
            for *_x, accion in plan:
                if accion and "rel" in accion:
                    rutas.append(os.path.join(mem, accion["rel"]))
        pdir = os.path.join(mem, "pendientes")
        if os.path.isdir(pdir):
            rutas += [os.path.join(pdir, f) for f in os.listdir(pdir) if f.endswith(".md")]
        carpeta = os.path.join(mem, ".journal", "migrar-tier2", time.strftime("%Y%m%d-%H%M%S"))
        respaldar(mem, sorted(set(rutas)), carpeta)

        escritos, hechos, errores = set(), 0, 0
        for nombre, (lines, plan) in planes.items():
            path = os.path.join(mem, nombre)
            originales = list(lines)
            hechas = []
            for i, _estado, _destino, _tit, accion in plan:
                if accion is None:
                    continue
                try:
                    if nombre == "_pendientes.md":
                        res, err = aplicar_pendiente(jc, mem, lines, i, accion, hoy)
                        if res:
                            lines[i], t3 = res
                            escritos.add(os.path.abspath(t3))
                    else:
                        err = aplicar_tier3(jc, mem, nombre, accion, hoy)
                        if not err:
                            lines[i] = accion["nueva"]
                            escritos.add(os.path.abspath(os.path.join(mem, accion["rel"])))
                except Exception as e:      # una linea rara no deja a medias las demas
                    err = f"ERROR: {type(e).__name__}: {e}; Tier 2 no se toca"
                if err:
                    errores += 1
                    print(f"{nombre}:{i + 1} {err}", file=sys.stderr)
                    continue
                hechas.append((i, accion))
            # Repaso final ANTES de acortar el indice: cada texto sigue en Tier 3 despues de TODAS
            # las escrituras (una posterior al mismo destino, como la sub-vineta que escribe en la
            # fila de su padre, no puede haber borrado una anterior).
            for i, accion in hechas:
                if not sigue_en_tier3(jc, mem, accion):
                    lines[i] = originales[i]
                    errores += 1
                    print(f"{nombre}:{i + 1} ERROR: su texto ya no esta en Tier 3 tras migrar el "
                          f"resto; esta linea no se acorta", file=sys.stderr)
                else:
                    hechos += 1
            if lines != originales:
                jc.atomic_write(path, lines)
                escritos.add(os.path.abspath(path))
        if escritos:
            try:
                jc.guardar_huellas(mem, os.path.join(mem, ".journal"), escritos=sorted(escritos))
            except AttributeError:
                pass
        print(f"candidatos={total} migrables={migrables} no_migrables={total - migrables} "
              f"aplicados={hechos} errores={errores} respaldo={os.path.relpath(carpeta, mem)}")
        return 1 if errores else 0
    finally:
        if lock is not None:
            lock.release()


if __name__ == "__main__":
    sys.exit(main())
