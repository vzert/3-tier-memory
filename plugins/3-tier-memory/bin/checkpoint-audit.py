#!/usr/bin/env python3
"""
3-tier-memory plugin: audita el PROPIO checkpoint antes de cerrarlo (checkpoint-3t Step 7a) y
dice, sin que nadie pregunte, que pasos quedaron hechos, saltados, a medias o saltados a
proposito.

Por que existe: Step 7 solo pide reportar lo que SI se hizo (rutas, conteos, hashes). Medido en
14 sesiones reales de un usuario del plugin (2026-09-13 a 2026-09-19): en las 14 el usuario
pregunto "falto algo de tu checkpoint?" y en las 14 el agente enumero omisiones reales que su
propio cierre no mencionaba. La informacion existia dentro de la sesion — al preguntarle la
recitaba exacta — pero nunca llegaba sola al usuario. Un usuario normal del plugin no pregunta:
lee el cierre, lo da por completo, y los huecos se acumulan en silencio.

Frecuencia medida de los huecos (sobre 9 respuestas completas):
  8/8  Step 3a: la tabla de reconciliacion de ~200 pendientes, nunca impresa
  5    el plan enlazado sin bloque `## Estado` o sin `plan.upsert` (fila del indice stale)
  3    un aviso de script (`header_issues=1`) repetido tres veces y nunca reportado
  3    pendientes de otras sesiones que vencian ESE DIA, sin mencionar
  3    el snippet `Como retomar` sin los pendientes que la sesion dejo abiertos
  2    Step 8d sin correr
  2    commits locales sin subir, sin avisar

Y un hallazgo que cambia el diseno: al preguntarle, el agente tambien confiesa cosas que el skill
PERMITE (no hacer `git push`, dejar el hash del commit como referencia adelantada — Step 6c lo
ordena asi). Sin una referencia fija de que cuenta como omision, la confesion libre produce falsos
positivos y el usuario pierde la senal igual. Por eso hay cuatro estados y no dos, y por eso
`POR-DISENO` es un estado de primera clase.

Esto es la regla 57 de este repo aplicada al cierre: una garantia mecanica no se delega al agente,
se mide deterministamente. Lo que ningun script puede ver (una afirmacion sin dueno, un paso
recortado por tamano) se queda en el bloque fijo en prosa de Step 7b — tres preguntas, no una
checklist.

NO repara, NO escribe, NO emite eventos: solo lee `memory/` y el estado de git. Lo que si hace es
imprimir, junto a cada SALTADO que tiene arreglo barato y determinista, el comando exacto que lo
corrige, para que el agente lo ejecute en vez de devolverle el trabajo al usuario.

Modos:
  checkpoint-audit.py <MEMORY_DIR> --session-file <ruta>         bloque para pegar en Step 7
  checkpoint-audit.py <MEMORY_DIR> --session-file <ruta> --count  solo SALTADO+PARCIAL
  ... --repo-root <ruta>   raiz del repo para el chequeo de commits sin subir (default: cwd)
  ... --no-git             omite el chequeo de git (util en pruebas)
"""
# sella-huellas: no (solo lee memory/ y consulta git; no escribe nada)
import argparse
import datetime
import glob
import os
import re
import subprocess
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

HECHO = "HECHO"
SALTADO = "SALTADO"
PARCIAL = "PARCIAL"
DISENO = "POR-DISEÑO"

# Secciones que Step 2 del template declara obligatorias en toda ficha de sesion. Las dos
# condicionales (`## Recordatorios de calendario`, `## Recomendaciones de research sin resolver`)
# NO estan aqui a proposito: Step 8c y 8d las omiten enteras cuando no aplican, y exigirlas
# convertiria un caso legitimo en un falso SALTADO — el error que este script existe para no
# cometer.
SECCIONES_OBLIGATORIAS = [
    "Contexto",
    "Cambios realizados",
    "Bugs fixed",
    "Plans",
    "Research",
    "Learnings generados",
    "Pendientes",
    "Commits",
    "Como retomar",
    "Related",
]

# El cierre `\b` NO sirve aqui: en `_pendientes.md` el id viene entre guiones bajos de cursiva
# (`_id: p-481cd4368e_`) y `_` es caracter de palabra, asi que `\b` no casa entre `e` y `_`. Medido
# contra la memoria real de un usuario: con `\b` salian 24 de 189 pendientes abiertos, y el
# conteo de Step 3a habria mentido por defecto — justo el fallo silencioso que esto audita.
ID_PENDIENTE = re.compile(r"\bp-[0-9a-f]{10}(?![0-9a-f])")
WIKILINK_PLAN = re.compile(r"\[\[plans/([^\]|]+?)(?:\|[^\]]*)?\]\]")
WIKILINK_LEARNING = re.compile(r"\[\[learnings/([^\]|]+?)(?:\|[^\]]*)?\]\]")
WIKILINK_RESEARCH = re.compile(r"\[\[research/([^\]|]+?)(?:\|[^\]]*)?\]\]")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
SEPARADOR_CELDA = re.compile(r"(?<!\\)\|")
RECONCILIACION = re.compile(r"^RECONCILIACION:\s*(\d+)\s+de\s+(\d+)\b", re.M)
FECHA_FRONTMATTER = re.compile(r"^date:\s*(\d{4}-\d{2}-\d{2})\s*$", re.M)
MAS_PENDIENTES = re.compile(r"\+\s*(\d+)\s+m[aá]s", re.I)
LINEA_PENDIENTE = re.compile(r"^-\s*\[[ xX]\]\s")
BLOQUE_CALENDARIO = re.compile(r"^###\s+\d{4}-\d{2}-\d{2}\b", re.M)

# Version en la que `## Pendientes` empezo a llevar la linea `RECONCILIACION:` (Step 3d, 2.28.0).
# Una ficha anterior no pudo escribirla: exigirsela es un falso positivo garantizado en toda
# corrida retroactiva. La comparacion es ESTRICTA a proposito — un checkpoint de hoy ya corre con
# 2.28.0 y debe cumplir. Borde conocido y aceptado: una ficha escrita hoy ANTES de que la
# instalacion recibiera 2.28.0 sale como SALTADO; dura un dia y se explica sola.
DESDE_RECONCILIACION = "2026-09-19"

# Step 8 pone como mucho 3 pendientes en `Sigue abierto` y cierra con `+N mas en _pendientes.md`.
TOPE_SIGUE_ABIERTO = 3


class Hallazgo:
    def __init__(self, estado, clave, detalle, lineas=None, corrige=None):
        self.estado = estado
        self.clave = clave
        self.detalle = detalle
        self.lineas = lineas or []
        self.corrige = corrige


def leer(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def secciones(texto):
    """{nombre de seccion -> cuerpo} para los encabezados `## ` de nivel 2."""
    out = {}
    actual = None
    buf = []
    for linea in texto.splitlines():
        if linea.startswith("## "):
            if actual is not None:
                out[actual] = "\n".join(buf)
            actual = linea[3:].strip()
            buf = []
        elif actual is not None:
            buf.append(linea)
    if actual is not None:
        out[actual] = "\n".join(buf)
    return out


def seccion_por_prefijo(secs, nombre):
    """Busca por prefijo: una ficha real escribe `## Cierre (2026-09-19 05:20Z-06:05Z)` o
    `## Verificación (clon fresco ...)`. Exigir igualdad exacta marcaria como ausente una seccion
    que esta ahi con su parentesis de contexto."""
    nombre_l = nombre.lower()
    for k, v in secs.items():
        if k.lower() == nombre_l or k.lower().startswith(nombre_l + " "):
            return v
    return None


def pendientes_abiertos(memory_dir):
    """[(id, texto, fecha_revisar|None)] de las lineas `- [ ]` de _pendientes.md."""
    path = os.path.join(memory_dir, "_pendientes.md")
    if not os.path.exists(path):
        return []
    out = []
    for linea in leer(path).splitlines():
        s = linea.strip()
        if not s.startswith("- [ ]"):
            continue
        m_id = ID_PENDIENTE.search(s)
        m_rev = REVISAR.search(s)
        out.append((m_id.group(0) if m_id else None, s[5:].strip(), m_rev.group(1) if m_rev else None))
    return out


def marcados_rezagados(memory_dir):
    path = os.path.join(memory_dir, "_pendientes.md")
    if not os.path.exists(path):
        return []
    return [l.strip() for l in leer(path).splitlines() if l.strip().startswith("- [x]")]


def filas_tabla(path):
    """Filas `| a | b | ... |` de un indice, ya troceadas en celdas."""
    if not os.path.exists(path):
        return []
    filas = []
    for linea in leer(path).splitlines():
        s = linea.strip()
        if not s.startswith("|"):
            continue
        # Partir por `|` a secas rompe toda fila con wikilink de alias: `[[plans/x\|Titulo]]`
        # lleva el `|` ESCAPADO dentro de la celda, y el corte ingenuo la parte en dos, corriendo
        # todas las columnas siguientes una posicion. Asi, la celda `Sesion` de _plans-index.md
        # salia siendo la fecha y el chequeo del plan.upsert daba falso negativo.
        celdas = [c.strip().replace("\\|", "|") for c in SEPARADOR_CELDA.split(s.strip("|"))]
        if all(set(c) <= set("-: ") for c in celdas):   # separador
            continue
        filas.append(celdas)
    return filas


def linea_sigue_abierto(sec_retomar):
    """La linea `Sigue abierto: …` del snippet, o "" si no esta.

    Todo lo del tope se mide SOBRE ESTA LINEA, no sobre el bloque entero: buscar el marcador o
    contar ids en todo `## Como retomar` dejaba pasar tres ids y un `+N mas` correcto escritos en
    cualquier otro renglon (por ejemplo dentro de `No repitas:`), que no es lo que manda Step 8."""
    for l in sec_retomar.splitlines():
        s = l.strip()
        if s.lower().startswith("sigue abierto:"):
            return s
    return ""


def _tope_valido(linea, nombrados, responsabilidad):
    """El tope de Step 8 solo cubre lo omitido si se cumplen las TRES condiciones, y las tres
    medidas sobre la linea `Sigue abierto:`: se nombraron exactamente los 3 del tope, hay marcador
    `+N mas`, y esa N es el numero real de omitidos.

    `responsabilidad` son los pendientes que le tocan a ESTA linea, o sea los abiertos de la
    sesion menos los que ya salen en otra parte del snippet (Step 8 permite que el de
    `Proximo paso` no se repita aqui).

    Sin la aritmetica, `Sigue abierto: +1 mas en _pendientes.md.` — sin nombrar a nadie — tapaba
    diez pendientes abiertos. Y sin acotarlo a la linea, el marcador valia desde cualquier otro
    renglon del bloque. Con varios marcadores se exige que TODOS cuadren, no solo el primero:
    mirar solo el primero dejaba contradicciones sin revisar detras."""
    if not linea:
        return False
    if nombrados != min(TOPE_SIGUE_ABIERTO, responsabilidad):
        return False
    marcadores = MAS_PENDIENTES.findall(linea)
    if not marcadores:
        return False
    return all(int(n) == responsabilidad - nombrados for n in marcadores)


def corre_git(repo_root, *args):
    try:
        r = subprocess.run(["git", "-C", repo_root] + list(args),
                           capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip()


def auditar(memory_dir, session_file, repo_root, usar_git, hoy):
    h = []
    texto = leer(session_file)
    secs = secciones(texto)
    slug = os.path.basename(session_file)
    if slug.endswith(".md"):
        slug = slug[:-3]

    # 1. Secciones obligatorias de la ficha
    faltan = [n for n in SECCIONES_OBLIGATORIAS if seccion_por_prefijo(secs, n) is None]
    if faltan:
        h.append(Hallazgo(SALTADO, "ficha.secciones",
                          f"{len(faltan)} seccion(es) obligatoria(s) sin escribir en la ficha",
                          [f"## {n}" for n in faltan]))
    else:
        h.append(Hallazgo(HECHO, "ficha.secciones",
                          f"{len(SECCIONES_OBLIGATORIAS)}/{len(SECCIONES_OBLIGATORIAS)} "
                          "secciones obligatorias presentes"))

    # 2. Step 3a: reconciliacion. Un pendiente cuenta como REVISADO solo si su id aparece en la
    # seccion donde Step 3d escribe la reconciliacion (`## Pendientes`) o en el bloque de
    # recordatorios de calendario (Step 8c) — NO en cualquier parte del documento.
    #
    # La version anterior buscaba el id en TODO el texto, y eso no medía reconciliacion sino
    # mencion: un adversario construyo una ficha que nombraba de pasada un pendiente vencido hoy
    # en `## Contexto`, con la frase "no se reviso su vencimiento, solo se cito aqui", y el audit
    # devolvia HECHO en 3a y en vencidos — el hueco exacto que este mecanismo existe para romper,
    # blanqueado por el propio instrumento.
    # Y dentro de esas secciones, solo en las LINEAS que reconcilian de verdad:
    #   - en `## Pendientes`, una linea de lista `- [ ]` / `- [x]` (la forma que manda Step 3d);
    #   - en `## Recordatorios de calendario`, solo si la seccion trae al menos un bloque real
    #     (`### YYYY-MM-DD — Titulo`, Step 8c-2), no un id aparcado en prosa.
    # Acotar solo la SECCION no bastaba: un adversario metio dentro de `## Pendientes` la frase
    # "no llegamos a revisar p-9999999999" y el audit devolvio HECHO en 3a, en vencidos y en la
    # linea RECONCILIACION. Mencion sigue sin ser reconciliacion, este la mencion donde este.
    abiertos = pendientes_abiertos(memory_dir)
    _sec_pend_raw = seccion_por_prefijo(secs, "Pendientes") or ""
    _sec_cal = seccion_por_prefijo(secs, "Recordatorios de calendario") or ""
    _lineas_reconcilian = [l for l in _sec_pend_raw.splitlines()
                           if LINEA_PENDIENTE.match(l.strip())]
    if BLOQUE_CALENDARIO.search(_sec_cal):
        _lineas_reconcilian.append(_sec_cal)
    ids_en_ficha = set(ID_PENDIENTE.findall("\n".join(_lineas_reconcilian)))
    revisados = [p for p in abiertos if p[0] and p[0] in ids_en_ficha]
    sin_id = [p for p in abiertos if not p[0]]
    sin_revisar = len(abiertos) - len(revisados)
    if not abiertos:
        h.append(Hallazgo(HECHO, "pendientes.3a", "no hay pendientes abiertos que reconciliar"))
    elif sin_revisar == 0:
        h.append(Hallazgo(HECHO, "pendientes.3a",
                          f"los {len(abiertos)} pendientes abiertos estan reconciliados en la ficha"))
    else:
        # Un pendiente SIN id no se puede casar con la ficha por id: cuenta como sin revisar y se
        # dice aparte, porque el motivo es distinto (linea anterior a 2.12.0, la arregla
        # enrich-memory.py --only id) y callarlo lo haria pasar por revisado.
        extra = f" ({len(sin_id)} sin id, no casables)" if sin_id else ""
        h.append(Hallazgo(PARCIAL, "pendientes.3a",
                          f"{len(revisados)} de {len(abiertos)} revisados — "
                          f"{sin_revisar} sin revisar{extra}, barrido completo en /triage-3t"))

    # 2-bis. La linea `RECONCILIACION:` de Step 3a/3d tiene que quedar EN LA FICHA, no solo
    # impresa. Sin esto el contrato "recortarla en silencio ya no es posible" seria falso: el
    # adversario lo marco como la unica afirmacion del cambio sin nada que la sostenga.
    # Mide ademas que los numeros declarados coincidan con los medidos aqui: una linea con
    # numeros inventados pasa el grep pero no este aserto.
    # La linea se busca SOLO en `## Pendientes`: en cualquier otro sitio no es la linea que Step 3d
    # manda escribir, y aceptarla en cualquier parte volveria el chequeo auto-consistente en vez de
    # exigente.
    m_rec = RECONCILIACION.search(_sec_pend_raw)
    fecha_ficha = FECHA_FRONTMATTER.search(texto)
    fecha_ficha = fecha_ficha.group(1) if fecha_ficha else None
    if not abiertos:
        h.append(Hallazgo(HECHO, "pendientes.reconciliacion_linea",
                          "sin pendientes abiertos: la linea no aplica"))
    elif not m_rec and fecha_ficha and fecha_ficha < DESDE_RECONCILIACION:
        # Una ficha anterior a 2.28.0 no pudo escribir una linea que no existia. Marcarla como
        # SALTADO seria un falso positivo en cada corrida retroactiva, y un muro de falsos
        # positivos ciega igual que el silencio.
        h.append(Hallazgo(DISENO, "pendientes.reconciliacion_linea",
                          f"ficha del {fecha_ficha}, anterior a {DESDE_RECONCILIACION}: la linea "
                          "no existia todavia"))
    elif not m_rec:
        h.append(Hallazgo(SALTADO, "pendientes.reconciliacion_linea",
                          "la ficha no lleva la linea RECONCILIACION: de Step 3d",
                          corrige=f"escribe en `## Pendientes`: RECONCILIACION: {len(revisados)} de "
                                  f"{len(abiertos)} pendientes abiertos revisados — "
                                  f"{sin_revisar} sin revisar, barrido en /triage-3t"))
    elif (int(m_rec.group(1)), int(m_rec.group(2))) != (len(revisados), len(abiertos)):
        h.append(Hallazgo(SALTADO, "pendientes.reconciliacion_linea",
                          f"la linea declara {m_rec.group(1)} de {m_rec.group(2)} y lo medido aqui "
                          f"es {len(revisados)} de {len(abiertos)}",
                          corrige="corrige los numeros de la linea; no los escribas de memoria"))
    else:
        h.append(Hallazgo(HECHO, "pendientes.reconciliacion_linea",
                          "la linea esta en la ficha y sus numeros cuadran"))

    # 3. Pendientes con fecha de revision vencida o de hoy que esta ficha no menciona
    vencidos = [p for p in abiertos
                if p[2] and p[2] <= hoy and (p[0] is None or p[0] not in ids_en_ficha)]
    if vencidos:
        h.append(Hallazgo(SALTADO, "pendientes.vencidos",
                          f"{len(vencidos)} pendiente(s) con revisar<={hoy} que esta ficha no menciona",
                          [f"{p[0] or '(sin id)'} (revisar {p[2]}) — {p[1][:90]}" for p in vencidos]))
    else:
        h.append(Hallazgo(HECHO, "pendientes.vencidos", f"ninguno vence el {hoy} o antes"))

    # 4/5. Planes enlazados: bloque `## Estado` y fila del indice apuntando a ESTA sesion
    sec_plans = seccion_por_prefijo(secs, "Plans") or ""
    planes = sorted(set(WIKILINK_PLAN.findall(sec_plans)))
    if not planes:
        h.append(Hallazgo(HECHO, "plan.estado", "la ficha no enlaza ningun plan"))
    else:
        sin_estado, ausentes = [], []
        for p in planes:
            ruta = os.path.join(memory_dir, "plans", p + ".md")
            if not os.path.exists(ruta):
                ausentes.append(p)
                continue
            if seccion_por_prefijo(secciones(leer(ruta)), "Estado") is None:
                sin_estado.append(p)
        if ausentes:
            h.append(Hallazgo(SALTADO, "plan.archivo",
                              f"{len(ausentes)} plan(es) enlazado(s) que no existen en disco",
                              [f"plans/{p}.md" for p in ausentes]))
        if sin_estado:
            h.append(Hallazgo(SALTADO, "plan.estado",
                              f"{len(sin_estado)} plan(es) sin el bloque `## Estado` que Step 5 exige",
                              [f"plans/{p}.md" for p in sin_estado],
                              corrige="anade `## Estado` (fase actual / proxima accion / bloqueo / fecha) al plan"))
        if not ausentes and not sin_estado:
            h.append(Hallazgo(HECHO, "plan.estado",
                              f"los {len(planes)} plan(es) enlazado(s) tienen `## Estado`"))

        filas = filas_tabla(os.path.join(memory_dir, "_plans-index.md"))
        stale = []
        for p in planes:
            fila = next((f for f in filas if f and ("[[plans/" + p) in f[0]), None)
            if fila is None:
                stale.append((p, "sin fila en _plans-index.md"))
            elif len(fila) < 4 or slug not in fila[3]:
                stale.append((p, "la fila del indice no apunta a esta sesion"))
        if stale:
            h.append(Hallazgo(SALTADO, "plan.indice",
                              f"{len(stale)} fila(s) de _plans-index.md sin actualizar "
                              "(falto el evento plan.upsert)",
                              [f"{p} — {m}" for p, m in stale],
                              corrige=('python3 "$JBIN/journal-emit.py" --type plan.upsert --slug <plan> '
                                       f'--sesion "[[sessions/{slug}]]" … && python3 "$JBIN/journal-compact.py" '
                                       '--memory-dir "$MEMORY_DIR"')))
        else:
            h.append(Hallazgo(HECHO, "plan.indice",
                              "la fila de cada plan enlazado apunta a esta sesion"))

    # 6. Learnings: el topico existe en disco y esta indexado en _learnings.md
    sec_learn = seccion_por_prefijo(secs, "Learnings generados") or ""
    topicos = sorted(set(WIKILINK_LEARNING.findall(sec_learn)))
    if not topicos:
        h.append(Hallazgo(HECHO, "learnings.dualwrite", "la ficha no declara learnings"))
    else:
        idx = leer(os.path.join(memory_dir, "_learnings.md")) \
            if os.path.exists(os.path.join(memory_dir, "_learnings.md")) else ""
        rotos = []
        for t in topicos:
            if not os.path.exists(os.path.join(memory_dir, "learnings", t + ".md")):
                rotos.append((t, "el archivo del topico no existe"))
            elif ("[[learnings/" + t) not in idx:
                rotos.append((t, "el topico no esta en _learnings.md"))
        if rotos:
            h.append(Hallazgo(SALTADO, "learnings.dualwrite",
                              f"{len(rotos)} topico(s) de learning sin dual write completo",
                              [f"{t} — {m}" for t, m in rotos]))
        else:
            h.append(Hallazgo(HECHO, "learnings.dualwrite",
                              f"los {len(topicos)} topico(s) existen y estan en _learnings.md"))

    # 7. Pendientes nuevos de la ficha con su fila mensual (Tier 3)
    sec_pend = seccion_por_prefijo(secs, "Pendientes") or ""
    ids_ficha = sorted(set(ID_PENDIENTE.findall(sec_pend)))
    if not ids_ficha:
        h.append(Hallazgo(HECHO, "pendientes.dualwrite", "la ficha no declara pendientes con id"))
    else:
        mensuales = "\n".join(leer(p) for p in sorted(glob.glob(
            os.path.join(memory_dir, "pendientes", "*.md"))))
        huerfanos = [i for i in ids_ficha if i not in mensuales]
        if huerfanos:
            h.append(Hallazgo(SALTADO, "pendientes.dualwrite",
                              f"{len(huerfanos)} id(s) de la ficha sin fila en pendientes/YYYY-MM.md",
                              huerfanos,
                              corrige='python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"'))
        else:
            h.append(Hallazgo(HECHO, "pendientes.dualwrite",
                              f"los {len(ids_ficha)} id(s) tienen su fila mensual"))

    # 8. El snippet de continuidad nombra los pendientes que la sesion deja abiertos
    sec_retomar = seccion_por_prefijo(secs, "Como retomar") or ""
    # Step 8 excluye de `Sigue abierto` todo pendiente con `_revisar` FUTURO respecto a la ficha:
    # ese ya sale con su Titulo/Descripcion completos en `## Recordatorios de calendario` (Step
    # 8c), y repetirlo pone la misma fecha dos veces en el mismo snippet. Exigirlo aqui era un
    # falso positivo — lo reporto otra sesion sobre un caso real y se verifico contra el template
    # (regla de `<pendientes de esta sesion>`, Step 8).
    rev_por_id = {p[0]: p[2] for p in abiertos if p[0]}
    ref = fecha_ficha or hoy
    abiertos_ficha = []
    excluidos_por_fecha = []
    for l in sec_pend.splitlines():
        if not l.strip().startswith("- [ ]"):
            continue
        m = ID_PENDIENTE.search(l)
        if not m:
            continue
        rev = rev_por_id.get(m.group(0))
        if rev and rev > ref:
            excluidos_por_fecha.append(m.group(0))
        else:
            abiertos_ficha.append(m.group(0))
    if "```" not in sec_retomar and not abiertos_ficha:
        # Step 8 caso 5: el bloque se colapsa a una linea a proposito cuando no hay continuidad.
        # SOLO vale si la sesion no dejo pendientes PROPIOS abiertos: colapsar el bloque teniendo
        # continuidad propia es precisamente la omision, no el caso permitido. (Lo marco el
        # adversario: la version anterior bendecia como POR-DISENO un hueco real, y el arnes lo
        # afirmaba.)
        h.append(Hallazgo(DISENO, "snippet.sigue_abierto",
                          "bloque `Como retomar` colapsado (Step 8, caso 5) — la sesion no deja "
                          "pendientes propios abiertos"))
    elif "```" not in sec_retomar:
        h.append(Hallazgo(SALTADO, "snippet.sigue_abierto",
                          f"bloque `Como retomar` colapsado pero la sesion deja "
                          f"{len(abiertos_ficha)} pendiente(s) propio(s) abierto(s)",
                          abiertos_ficha,
                          corrige="escribe el bloque completo: el caso 5 de Step 8 solo aplica sin "
                                  "continuidad propia"))
    elif not abiertos_ficha:
        extra = (f" ({len(excluidos_por_fecha)} con `_revisar` futuro van al bloque de calendario)"
                 if excluidos_por_fecha else "")
        h.append(Hallazgo(HECHO, "snippet.sigue_abierto",
                          f"la sesion no deja pendientes que toquen esta linea{extra}"))
    else:
        faltan_snip = [i for i in abiertos_ficha if i not in sec_retomar]
        # El tope se mide sobre la linea `Sigue abierto:`, y solo sobre los pendientes que le
        # TOCAN: Step 8 permite no repetir aqui el que ya va en `Proximo paso`.
        linea_sa = linea_sigue_abierto(sec_retomar)
        nombrados_linea = len([i for i in abiertos_ficha if i in linea_sa])
        cubiertos_fuera = len([i for i in abiertos_ficha
                               if i in sec_retomar and i not in linea_sa])
        responsabilidad = len(abiertos_ficha) - cubiertos_fuera
        if not faltan_snip:
            h.append(Hallazgo(HECHO, "snippet.sigue_abierto",
                              f"el snippet nombra los {len(abiertos_ficha)} pendiente(s) que le tocan"))
        elif _tope_valido(linea_sa, nombrados_linea, responsabilidad):
            # Step 8: maximo 3 nombrados de verdad, y el resto cerrado con `+N mas`, con la N
            # correcta. Se comprueba la ARITMETICA, no la presencia del texto: aceptar el
            # marcador a secas dejaba esconder cualquier numero de pendientes detras de un
            # `+1 mas` inventado, nombrando cero. Lo construyeron los dos adversarios.
            h.append(Hallazgo(DISENO, "snippet.sigue_abierto",
                              f"el snippet nombra los {TOPE_SIGUE_ABIERTO} del tope y cierra con "
                              f"`+{len(faltan_snip)} mas`: el resto queda fuera por la regla de Step 8"))
        else:
            h.append(Hallazgo(SALTADO, "snippet.sigue_abierto",
                              f"{len(faltan_snip)} pendiente(s) abierto(s) que el snippet no nombra "
                              f"ni cubre con el tope de {TOPE_SIGUE_ABIERTO}",
                              faltan_snip,
                              corrige="anade su id a la linea `Sigue abierto:` del bloque Como retomar"))

    # 9. Research con recomendaciones sin resolver que ESTA ficha enlaza
    sec_res = seccion_por_prefijo(secs, "Research") or ""
    researches = sorted(set(WIKILINK_RESEARCH.findall(sec_res)))
    pendientes_reco = []
    rotos_reco = []
    for r in researches:
        ruta = os.path.join(memory_dir, "research", r + ".md")
        if not os.path.exists(ruta):
            # Un wikilink de research ROTO no es "sin recomendaciones": es que no se pudo mirar, y
            # callarlo da un HECHO falso — el mismo fallo que print-research-recomendaciones.py ya
            # aprendio en 2.27.0. Lo marco el adversario aqui.
            rotos_reco.append((r, "el archivo del research no existe"))
            continue
        cuerpo = seccion_por_prefijo(secciones(leer(ruta)), "Recomendaciones")
        if cuerpo is None:
            continue
        sin = [l.strip() for l in cuerpo.splitlines() if re.match(r"^-\s*\[\s\]\s+", l.strip())]
        if sin:
            pendientes_reco.append((r, len(sin)))
    if not researches:
        h.append(Hallazgo(HECHO, "research.recomendaciones", "la ficha no enlaza ningun research"))
    elif pendientes_reco or rotos_reco:
        detalle = []
        if pendientes_reco:
            detalle.append(f"{len(pendientes_reco)} con recomendaciones sin resolver")
        if rotos_reco:
            detalle.append(f"{len(rotos_reco)} con wikilink roto")
        h.append(Hallazgo(SALTADO, "research.recomendaciones",
                          "research enlazado(s): " + ", ".join(detalle),
                          [f"{r} — {n} sin marcar" for r, n in pendientes_reco]
                          + [f"{r} — {m}" for r, m in rotos_reco],
                          corrige='python3 "$JBIN/print-research-recomendaciones.py" "$MEMORY_DIR" '
                                  "<SESSION_FILE>   # Step 8d; un wikilink roto se arregla en la ficha"))
    else:
        h.append(Hallazgo(HECHO, "research.recomendaciones",
                          "ningun research enlazado tiene recomendaciones sin marcar"))

    # 10. La ficha tiene fila en _session-index.md
    idx_ses = os.path.join(memory_dir, "_session-index.md")
    if not os.path.exists(idx_ses):
        h.append(Hallazgo(SALTADO, "indice.sesion", "_session-index.md no existe"))
    elif slug in leer(idx_ses):
        h.append(Hallazgo(HECHO, "indice.sesion", "la ficha tiene fila en _session-index.md"))
    else:
        # Step 5b poda el indice a las N sesiones mas recientes. Una ficha vieja SIN fila es esa
        # poda, no un dual write roto: reportarla como SALTADO seria un falso positivo, y un muro
        # de falsos positivos deja al usuario tan ciego como el silencio de hoy.
        n_filas = max(0, len(filas_tabla(idx_ses)) - 1)   # -1 = cabecera
        recientes = sorted(os.path.basename(p)[:-3] for p in
                           glob.glob(os.path.join(memory_dir, "sessions", "*.md")))[-n_filas:]
        if n_filas and slug not in recientes:
            h.append(Hallazgo(DISENO, "indice.sesion",
                              f"ficha fuera de las {n_filas} mas recientes: su fila la podo Step 5b"))
        else:
            h.append(Hallazgo(SALTADO, "indice.sesion",
                              "la ficha no tiene fila en _session-index.md",
                              corrige=f'python3 "$JBIN/journal-emit.py" --type session.add --slug "{slug}" …'))

    # 11. Lineas `- [x]` rezagadas en _pendientes.md (el compactador las quita al resolver)
    rezagadas = marcados_rezagados(memory_dir)
    if rezagadas:
        h.append(Hallazgo(SALTADO, "pendientes.marcados",
                          f"{len(rezagadas)} linea(s) `- [x]` rezagada(s) en _pendientes.md",
                          [l[:100] for l in rezagadas[:5]],
                          corrige="emite pendiente.resolve por cada una y compacta; no las borres a mano"))
    else:
        h.append(Hallazgo(HECHO, "pendientes.marcados", "sin lineas `- [x]` rezagadas"))

    # 12. Journal: nada pendiente de aplicar ni en cuarentena
    pend_dir = os.path.join(memory_dir, ".journal", "pending")
    cuar_dir = os.path.join(memory_dir, ".journal", "quarantine")
    n_pend = len(glob.glob(os.path.join(pend_dir, "*.json"))) if os.path.isdir(pend_dir) else 0
    n_cuar = len(glob.glob(os.path.join(cuar_dir, "*"))) if os.path.isdir(cuar_dir) else 0
    if n_pend or n_cuar:
        h.append(Hallazgo(SALTADO, "journal.limpio",
                          f"journal con {n_pend} evento(s) sin aplicar y {n_cuar} en cuarentena",
                          corrige='python3 "$JBIN/journal-compact.py" --memory-dir "$MEMORY_DIR"'
                                  if n_pend else
                                  "lee memory/.journal/quarantine/*.reason y decide; no se borra solo"))
    else:
        h.append(Hallazgo(HECHO, "journal.limpio", "sin eventos sin aplicar ni en cuarentena"))

    # 13. Avisos de los scripts de Step 3-pre que el cierre suele no reportar.
    # Se vuelven a MEDIR aqui en seco (sin --apply) en vez de confiar en que el agente recuerde lo
    # que imprimieron hace veinte pasos: `header_issues=1` salio tres veces en el corpus medido y
    # nunca llego al usuario.
    repair = os.path.join(os.path.dirname(os.path.abspath(__file__)), "repair-dualwrite.py")
    if os.path.exists(repair):
        try:
            r = subprocess.run([sys.executable, repair, memory_dir],
                               capture_output=True, text=True, timeout=120)
            salida = (r.stdout or "") + (r.stderr or "")
        except Exception as exc:
            salida = ""
            h.append(Hallazgo(SALTADO, "avisos.scripts",
                              f"no se pudo medir repair-dualwrite en seco: {exc}"))
        if salida:
            avisos = []
            for clave in ("header_issues", "odd_values", "unaligned_rows", "unrepairable",
                          "ids_invented", "missing_data", "pipes_broken"):
                m = re.search(clave + r"=(\d+)", salida)
                if m and int(m.group(1)) > 0:
                    avisos.append(f"{clave}={m.group(1)}")
            if avisos:
                h.append(Hallazgo(SALTADO, "avisos.scripts",
                                  "repair-dualwrite en seco reporta avisos que el cierre debe decir",
                                  avisos,
                                  corrige="ninguno automatico: son migraciones. Reportalos en Step 7 "
                                          "diciendo que bloquean, no solo el numero"))
            else:
                h.append(Hallazgo(HECHO, "avisos.scripts", "repair-dualwrite en seco: sin avisos"))

    # 14/15. Git: lo que el skill NO hace a proposito, dicho como tal y no como falla.
    if usar_git:
        rama = corre_git(repo_root, "rev-parse", "--abbrev-ref", "HEAD")
        if rama is None:
            h.append(Hallazgo(DISENO, "git.sin_subir", "sin repo git; el checkpoint no lo necesita"))
        else:
            cuenta = corre_git(repo_root, "rev-list", "--count", f"origin/{rama}..HEAD")
            if cuenta is None:
                h.append(Hallazgo(DISENO, "git.sin_subir",
                                  f"la rama {rama} no tiene remoto rastreado; nada que subir"))
            elif int(cuenta) > 0:
                h.append(Hallazgo(DISENO, "git.sin_subir",
                                  f"{cuenta} commit(s) local(es) sin subir en {rama} — "
                                  "el checkpoint no hace push por diseno; decide tu si subirlos"))
            else:
                h.append(Hallazgo(HECHO, "git.sin_subir", f"{rama} al dia con su remoto"))

        sucio = corre_git(repo_root, "status", "--porcelain", "--", "memory")
        if sucio:
            n = len([l for l in sucio.splitlines() if l.strip()])
            h.append(Hallazgo(DISENO, "git.ficha_sin_commitear",
                              f"{n} fichero(s) de memory/ sin commitear — el hash del commit y el "
                              "snippet entran en el siguiente checkpoint (Step 6c); confirma que "
                              "ninguno es de otra sesion antes de barrerlos"))
        else:
            h.append(Hallazgo(HECHO, "git.ficha_sin_commitear", "memory/ sin cambios sin commitear"))

    return h


def imprimir(hallazgos):
    orden = {SALTADO: 0, PARCIAL: 1, DISENO: 2, HECHO: 3}
    print("AUDITORIA DEL CHECKPOINT (bin/checkpoint-audit.py) — pega este bloque literal")
    for hh in sorted(hallazgos, key=lambda x: (orden[x.estado], x.clave)):
        print(f"  {hh.estado:<11} {hh.clave:<31} {hh.detalle}")
        for l in hh.lineas:
            print(f"  {'':<11} {'':<31}   - {l}")
        if hh.corrige and hh.estado in (SALTADO, PARCIAL):
            print(f"  {'':<11} {'':<31}   corrige: {hh.corrige}")
    c = {e: sum(1 for x in hallazgos if x.estado == e) for e in (HECHO, PARCIAL, SALTADO, DISENO)}
    print(f"  resumen: hecho={c[HECHO]} parcial={c[PARCIAL]} saltado={c[SALTADO]} "
          f"por-diseno={c[DISENO]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("memory_dir")
    ap.add_argument("--session-file", required=True)
    ap.add_argument("--repo-root", default=None)
    ap.add_argument("--no-git", action="store_true")
    ap.add_argument("--count", action="store_true")
    ap.add_argument("--hoy", default=None, help="fecha YYYY-MM-DD; solo para pruebas")
    args = ap.parse_args()

    if not os.path.isdir(args.memory_dir):
        print(f"⚠ checkpoint-audit.py: no existe el directorio de memoria {args.memory_dir}",
              file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(args.session_file):
        # Una ficha que no se puede leer NO es "checkpoint limpio": es "no se pudo mirar", y
        # callarlo seria el mismo fallo silencioso que este script existe para romper.
        print(f"⚠ checkpoint-audit.py: no se pudo leer la ficha {args.session_file}",
              file=sys.stderr)
        sys.exit(1)

    hoy = args.hoy or datetime.date.today().isoformat()
    repo_root = args.repo_root or os.getcwd()
    hallazgos = auditar(args.memory_dir, args.session_file, repo_root, not args.no_git, hoy)

    if args.count:
        print(sum(1 for x in hallazgos if x.estado in (SALTADO, PARCIAL)))
        return
    imprimir(hallazgos)


if __name__ == "__main__":
    main()
