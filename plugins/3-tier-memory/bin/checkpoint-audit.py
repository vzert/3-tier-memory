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
import collections
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
# El id PROPIO de una linea de _pendientes.md va en su campo `_id:`, al final. Ver la nota en
# pendientes_abiertos() sobre por que el primer `p-…` de la linea no sirve.
CAMPO_ID = re.compile(r"_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])")
WIKILINK_PLAN = re.compile(r"\[\[plans/([^\]|]+?)(?:\|[^\]]*)?\]\]")
WIKILINK_LEARNING = re.compile(r"\[\[learnings/([^\]|]+?)(?:\|[^\]]*)?\]\]")
WIKILINK_RESEARCH = re.compile(r"\[\[research/([^\]|]+?)(?:\|[^\]]*)?\]\]")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
# `_bloqueado: QUE_` (2.33.0): el pendiente espera a algo FUERA de la sesion. Lo escribe el
# compactador desde `--bloqueado-por` (pendiente.add) o `pendiente.block`. Es el campo
# estructurado que hace mecanico el defecto 1 de p-daf3051915 sin clasificar prosa (regla 216).
BLOQUEADO = re.compile(r"—\s*_bloqueado:\s*([^—]+?)_?\s*(?=—|$)")
SEPARADOR_CELDA = re.compile(r"(?<!\\)\|")
RECONCILIACION = re.compile(r"^RECONCILIACION:\s*(\d+)\s+de\s+(\d+)\b", re.M)
FECHA_FRONTMATTER = re.compile(r"^date:\s*(\d{4}-\d{2}-\d{2})\s*$", re.M)
MAS_PENDIENTES = re.compile(r"\+\s*(\d+)\s+m[aá]s", re.I)
LINEA_PENDIENTE = re.compile(r"^-\s*\[[ xX]\]\s")
BLOQUE_CALENDARIO = re.compile(r"^###\s+\d{4}-\d{2}-\d{2}\b", re.M)
# El id RESERVADO por un recordatorio de calendario es el de su propia linea `Retomamos:` (Step
# 8c-2, dentro del "Pega esto dentro del evento"), no cualquier id que su Descripcion/Comprueba
# mencionen de paso para dar contexto o decir explicitamente "esto NO es lo que hay que retomar".
# Usar ID_PENDIENTE a secas sobre toda la seccion conto como "duplicado" un id que el propio
# recordatorio citaba solo para excluirlo — falso positivo real, `restos-213-pr220`.
RETOMAMOS_ID_CALENDARIO = re.compile(r"^Retomamos:.*?_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])", re.M)
# La otra forma de reservar un id en `## Recordatorios de calendario` (Step 8c, 2.39.2): el
# pendiente ya tiene recordatorio vivo en otra ficha y aqui solo va su linea de referencia. Cuenta
# igual que un bloque para `pendientes.3a` y `snippet.futuro_duplicado` (un adversario midio que,
# sin esto, la regla nueva dejaba a los dos ciegos); para `calendario.duplicado_entre_fichas` NO es
# un bloque, es justo lo que evita el duplicado.
YA_AGENDADO = re.compile(r"^\s*-\s*(p-[0-9a-f]{10})(?![0-9a-f])\s+ya agendado para\s+(\d{4}-\d{2}-\d{2})\b", re.M)
# Celda Commit que solo PARECE llena: el "Fallback (no JBIN)" de Step 2 escribe `filled in Step 6`
# y la sintaxis de ejemplo de Step 6c es `<short-hash>`. Si Step 6 no la reemplaza, sigue sin hash
# ni N/A. Se marca el relleno CONOCIDO, no se exige una forma: otras instalaciones escriben celdas
# legitimas que una lista blanca (hash o N/A) daria por malas — dos hashes, un "(amend)".
COMMIT_RELLENO = re.compile(r"^\s*$|filled in|<[^>]*hash[^>]*>", re.I)

# Cierre de cada defecto de `## Bugs fixed` (2.34.0, p-272254efc5). Step 2 escribe cada linea de
# primer nivel con UNO de dos campos, decididos al escribirla:
#   `_verificado: <evidencia>_` — el arreglo se comprobo (test, corrida, consulta) en esta sesion;
#   `_pendiente: p-…_`          — no esta cerrado y verificado: su pendiente (Step 3b punto 9).
# Es el mismo patron que `_bloqueado:` (2.33.0): un campo estructurado que el agente decide al
# escribir, no una lectura del texto (regla 216). Sin el, un defecto arreglado "solo con prosa"
# (sesion 5790b9f2) tenia la misma forma que uno verificado y `Proximo paso: ninguno` pasaba.
VERIFICADO = re.compile(r"_verificado:\s*(.*?)_(?=\s|$|[.,;:)\]—])", re.S)
PENDIENTE_BUG = re.compile(r"_pendiente:\s*(p-[0-9a-f]{10})(?![0-9a-f])")
DESDE_BUGS_CIERRE = "2026-09-23"
# 2.35.0: desde esta fecha el snippet `Como retomar` no lleva la linea `Sigue abierto:`.
DESDE_SIN_SIGUE_ABIERTO = "2026-09-23"
BULLET_PRIMER_NIVEL = re.compile(r"^( {0,3})(?:[-*+]|\d+[.)])[ \t]+")
SUB_ITEM = re.compile(r"^\s+(?:[-*+]|\d+[.)])[ \t]+")

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
        # El id de la linea es SU CAMPO `_id:`, nunca el primer `p-…` que aparezca: un pendiente
        # cuyo TEXTO cita el id de otro (cosa normal — "el fix de p-xxxx sigue pendiente") se
        # llevaba el id citado y perdia el suyo. Medido dogfoodeando: 3 "ids duplicados" en la
        # memoria de este repo eran los tres falsos positivos por esa causa, y el pendiente que
        # los denunciaba se auto-provoco el tercero al citarlos. Con el campo: 96 lineas, 96 ids
        # distintos, cero duplicados.
        m_id = CAMPO_ID.search(s) or ID_PENDIENTE.search(s)   # fallback: lineas anteriores a 2.12.0
        m_rev = REVISAR.search(s)
        ident = m_id.group(1) if (m_id and m_id.re is CAMPO_ID) else (m_id.group(0) if m_id else None)
        out.append((ident, s[5:].strip(), m_rev.group(1) if m_rev else None))
    return out


def bloqueados_abiertos(memory_dir):
    """{id: que-espera} de las lineas `- [ ]` de _pendientes.md que llevan `_bloqueado:`."""
    path = os.path.join(memory_dir, "_pendientes.md")
    if not os.path.exists(path):
        return {}
    out = {}
    for linea in leer(path).splitlines():
        s = linea.strip()
        if not s.startswith("- [ ]"):
            continue
        m_id = CAMPO_ID.search(s)
        m_b = BLOQUEADO.search(s)
        if m_id and m_b:
            out[m_id.group(1)] = m_b.group(1).strip()
    return out


ORIGEN_SESION = re.compile(r"_origen:\s*\[\[(?:\.\./)*sessions/([^\]|#]+?)(?:\.md)?(?:[|#][^\]]*)?\]\]")


def origenes_abiertos(memory_dir):
    """{id: slug de la sesion de origen} de las lineas `- [ ]` de _pendientes.md."""
    path = os.path.join(memory_dir, "_pendientes.md")
    if not os.path.exists(path):
        return {}
    out = {}
    for linea in leer(path).splitlines():
        s = linea.strip()
        m_id, m_o = CAMPO_ID.search(s), ORIGEN_SESION.search(s)
        if s.startswith("- [ ]") and m_id and m_o:
            out[m_id.group(1)] = m_o.group(1)
    return out


def bullets_bugs(sec_bugs):
    """Items de primer nivel de `## Bugs fixed`, excluido `Ninguno`, como pares (propio, bloque).
    `bloque` = el item con todo lo que cuelga de el; `propio` = solo su texto, hasta el primer
    sub-item. El campo de cierre se busca en `propio`: un hijo con `_verificado:` no puede tapar a
    un padre sin campo (adversario, ronda 2: `- defecto sin campo` + `  - otro _verificado: x_`
    pasaba como un solo defecto verificado)."""
    out, actual, col = [], None, 0
    for l in sec_bugs.splitlines():
        # Primer nivel = marcador de lista de Markdown con 0-3 espacios delante: `-`, `*`, `+` o
        # `1.`/`1)`. Solo `-`/`*` en la columna 0 dejaba pasar en silencio `+ …`, `1. …` y ` - …`
        # (adversario, ronda 1; una ficha real de otra instalacion usa lista numerada aqui). Como
        # en CommonMark, un marcador sangrado hasta la columna del CONTENIDO del item de arriba
        # (2 espacios bajo `- `, 3 bajo `1. `, o un tab) es un hijo.
        l = l.expandtabs(4)
        m = BULLET_PRIMER_NIVEL.match(l)
        if m and (actual is None or len(m.group(1)) < col):
            col = m.end()
            if actual is not None:
                out.append(actual)
            actual = [l, [l]]          # [propio, lineas del bloque]
        elif actual is not None and l.strip():
            if SUB_ITEM.match(l) or len(actual[1]) > len(actual[0].splitlines()):
                actual[1].append(l)    # un sub-item, o cualquier cosa despues de uno
            else:
                actual[0] += "\n" + l
                actual[1].append(l)
    if actual is not None:
        out.append(actual)
    return [(propio, "\n".join(bl)) for propio, bl in out
            if not re.match(r"^ {0,3}(?:[-*+]|\d+[.)])\s+\**\s*ninguno\**\s*\.?\s*$", propio, re.I)]

def ids_historicos(memory_dir):
    """Todos los `p-…` que la memoria registro alguna vez: abiertos y filas mensuales."""
    ids = set()
    for p in [os.path.join(memory_dir, "_pendientes.md")] + \
            sorted(glob.glob(os.path.join(memory_dir, "pendientes", "*.md"))):
        if os.path.exists(p):
            ids |= set(ID_PENDIENTE.findall(leer(p)))
    return ids


def linea_proximo_paso(sec_retomar):
    """La linea `Proximo paso: …` del snippet (sin `**` y con o sin tilde), o None."""
    for l in sec_retomar.splitlines():
        s = l.strip().strip("*").strip()
        low = s.lower()
        for pref in ("proximo paso:", "próximo paso:", "**proximo paso:**", "**próximo paso:**"):
            if low.startswith(pref):
                return s[len(pref):].strip().strip("*").strip()
    return None


# El caso 4 de `<next-step>` se QUITO en 2.33.0 (p-daf3051915, defecto 2): era la salida generica
# que el agente tomaba teniendo trabajo propio sin cerrar (sesion 5790b9f2: "revisar
# _pendientes.md y proponer siguiente prioridad" mientras el defecto hallado en vivo seguia sin
# registrar). Se reconoce cuando la linea EMPIEZA por su texto, no cuando lo contiene: el snippet
# correcto de esa misma sesion citaba la frase entre comillas para explicar el defecto
# ('el caso 4 ("revisar _pendientes.md…") es una salida generica') y contarla ahi era un falso
# positivo sobre el cierre bueno. Una variante que no empiece asi y no cite id la atrapa igual
# el requisito de `_id` de mas abajo.
CASO4_GENERICO = re.compile(r"^\W*(?:revisar\s+`?_pendientes(?:\.md)?`?|proponer\s+(?:la\s+)?siguiente\s+prioridad)",
                            re.I)


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


def avisos_script_en_seco(h, memory_dir, nombre_script, claves_problema):
    """Corre <nombre_script> en seco (sin --apply) contra memory_dir y agrega un Hallazgo con
    cualquier clave de `claves_problema` que salga > 0 en su stdout/stderr.

    Por que existe: `header_unrecognized=1` (repair-plans-index.py, repair-research-index.py) es
    el mismo patron que `header_issues=1` (repair-dualwrite.py) que motivo este archivo entero —
    una tabla que el reparador no pudo migrar sin adivinar (columna ambigua, ej. p-ccc013b53d:
    "Session" sostiene el wikilink real en una instalacion y es solo metadata en otras) se queda
    de solo lectura para siempre, y sin este chequeo el cierre solo la reporta si el agente que
    corrio Step 6 se acuerda de un numero que vio antes en Step 3-pre. No se repara aqui — la
    ambiguedad que produjo `header_unrecognized` es precisamente la que ningun script debe
    adivinar; esto solo garantiza que nadie deje de VERLA."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    ruta = os.path.join(script_dir, nombre_script)
    etiqueta = nombre_script.replace(".py", "").replace("repair-", "")
    clave_hallazgo = f"avisos.scripts.{etiqueta}"
    if not os.path.exists(ruta):
        return
    try:
        r = subprocess.run([sys.executable, ruta, memory_dir],
                           capture_output=True, text=True, timeout=120)
        salida = (r.stdout or "") + (r.stderr or "")
    except Exception as exc:
        h.append(Hallazgo(SALTADO, clave_hallazgo,
                          f"no se pudo medir {nombre_script} en seco: {exc}"))
        return
    if r.returncode != 0:
        # No confundir "el script crasheo" con "el script no encontro avisos" — ambos dejan
        # `avisos` vacio si solo se mira si las claves conocidas aparecen en la salida (rio abajo),
        # y sin este chequeo un traceback en stderr (encoding, permisos, un bug del propio
        # reparador) se reportaba como `HECHO ... sin avisos`, exactamente el falso negativo que
        # esta funcion existe para evitar (adversario externo, ronda de p-ccc013b53d).
        h.append(Hallazgo(SALTADO, clave_hallazgo,
                          f"{nombre_script} en seco termino con codigo {r.returncode} — no midio "
                          "nada, no asumas 'sin avisos'",
                          [(salida or "(sin salida)").strip()[-500:]]))
        return
    if not salida:
        return
    avisos = []
    for clave in claves_problema:
        m = re.search(clave + r"=(\d+)", salida)
        if m and int(m.group(1)) > 0:
            avisos.append(f"{clave}={m.group(1)}")
    if avisos:
        h.append(Hallazgo(SALTADO, clave_hallazgo,
                          f"{nombre_script} en seco reporta avisos que el cierre debe decir",
                          avisos,
                          corrige="ninguno automatico: son migraciones o ambiguedades que piden "
                                  "criterio humano. Reportalos en Step 7 diciendo que bloquean, no "
                                  "solo el numero"))
    else:
        h.append(Hallazgo(HECHO, clave_hallazgo, f"{nombre_script} en seco: sin avisos"))


def auditar(memory_dir, session_file, repo_root, usar_git, hoy, solo_snippet=False, veredicto_adv=None):
    h = []
    texto = leer(session_file)
    secs = secciones(texto)
    slug = os.path.basename(session_file)
    if slug.endswith(".md"):
        slug = slug[:-3]
    sec_retomar = seccion_por_prefijo(secs, "Como retomar") or ""

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
    if BLOQUE_CALENDARIO.search(_sec_cal) or YA_AGENDADO.search(_sec_cal):
        _lineas_reconcilian.append(_sec_cal)
    ids_en_ficha = set(ID_PENDIENTE.findall("\n".join(_lineas_reconcilian)))
    # Contar por id DISTINTO, no por linea: `_pendientes.md` puede traer el mismo id en dos lineas
    # abiertas (defecto de datos, ver la comprobacion `pendientes.duplicados` mas abajo), y contar
    # lineas hacia que R e incluso N mintieran — medido dogfoodeando este mismo checkpoint: la
    # linea declaraba 8 de 95 y el audit exigia 9 de 95 porque un id reconciliado estaba dos veces.
    ids_abiertos = {p[0] for p in abiertos if p[0]}
    revisados = ids_abiertos & ids_en_ficha
    sin_id = [p for p in abiertos if not p[0]]
    total_abiertos = len(ids_abiertos) + len(sin_id)
    sin_revisar = total_abiertos - len(revisados)
    if not abiertos:
        h.append(Hallazgo(HECHO, "pendientes.3a", "no hay pendientes abiertos que reconciliar"))
    elif sin_revisar == 0:
        h.append(Hallazgo(HECHO, "pendientes.3a",
                          f"los {total_abiertos} pendientes abiertos estan reconciliados en la ficha"))
    else:
        # Un pendiente SIN id no se puede casar con la ficha por id: cuenta como sin revisar y se
        # dice aparte, porque el motivo es distinto (linea anterior a 2.12.0, la arregla
        # enrich-memory.py --only id) y callarlo lo haria pasar por revisado.
        extra = f" ({len(sin_id)} sin id, no casables)" if sin_id else ""
        h.append(Hallazgo(PARCIAL, "pendientes.3a",
                          f"{len(revisados)} de {total_abiertos} revisados — "
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
                                  f"{total_abiertos} pendientes abiertos revisados — "
                                  f"{sin_revisar} sin revisar, barrido en /triage-3t"))
    elif (int(m_rec.group(1)), int(m_rec.group(2))) != (len(revisados), total_abiertos):
        h.append(Hallazgo(SALTADO, "pendientes.reconciliacion_linea",
                          f"la linea declara {m_rec.group(1)} de {m_rec.group(2)} y lo medido aqui "
                          f"es {len(revisados)} de {total_abiertos}",
                          corrige="corrige los numeros de la linea; no los escribas de memoria"))
    else:
        h.append(Hallazgo(HECHO, "pendientes.reconciliacion_linea",
                          "la linea esta en la ficha y sus numeros cuadran"))

    # 2-ter. Ids duplicados entre lineas abiertas. Es un defecto de datos que `repair-dualwrite`
    # no mira (cuenta filas de Tier 3 que faltan, no lineas de Tier 2 repetidas), y que ademas
    # falsea cualquier conteo por linea. Salio dogfoodeando: 3 ids con dos lineas abiertas cada uno.
    dup = sorted(i for i, n in collections.Counter(
        p[0] for p in abiertos if p[0]).items() if n > 1)
    if dup:
        h.append(Hallazgo(SALTADO, "pendientes.duplicados",
                          f"{len(dup)} id(s) aparecen en mas de una linea abierta de _pendientes.md",
                          dup,
                          corrige="no se arregla solo: decide cual linea sobrevive y cierra la otra "
                                  "con pendiente.resolve --estado superseded"))
    else:
        h.append(Hallazgo(HECHO, "pendientes.duplicados", "ningun id repetido entre los abiertos"))

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

    # 5-bis. Un plan mencionado por su RUTA dentro de `## Como retomar` que `## Plans` no enlaza.
    # Medido en `claude-vzert` (2026-09-22, PR#238): la ficha escribio `## Plans` con "Ninguno —
    # sin cambios al plan desde el checkpoint anterior", y el propio snippet decia en prosa suelta
    # "el trabajo activo real es la Fase 7 pieza 3... ver memory/plans/plan-....md" en vez de usar
    # el caso 1 de `<next-step>` (que lee el `## Estado` de ESE plan y lo habria dado como accion
    # concreta, no generica). Sin el wikilink en `## Plans`, el caso 1 nunca puede aplicar: "sin
    # cambios al plan" no es lo mismo que "el plan no es el contexto de esta sesion", y confundir
    # una cosa con la otra es la misma fuente que la regla 214 de aprendizajes ya nombra (fallo de
    # RELACION, no de PERSISTENCIA). Victor lo vio en vivo ("no hay un paso siguiente de la fase 7
    # en vez de que me des un prompt generico") y el propio agente lo corrigio en la misma sesion.
    # La membresia NO se mide solo contra `planes` (WIKILINK_PLAN exige `[[plans/…]]` exacto):
    # una ficha real enlaza con `[[../plans/plan-x]]` (ruta relativa desde `sessions/`) y ese
    # wikilink es valido, solo que otra forma — `WIKILINK_PLAN_LAXO` acepta cualquier numero de
    # `../` y compara por SLUG exacto, no por substring (un substring `plans/{p}` en el cuerpo de
    # `## Plans` da un falso NEGATIVO: "sin cambios en plans/plan-x (sigue igual)" en prosa suelta
    # cuenta como "enlazado" sin serlo, y un plan `plan-x-v2` enlazado deja pasar la mencion de
    # `plan-x` por prefijo — las dos formas se probaron en la ronda de adversario de esta sesion).
    #
    # La busqueda de menciones se acota a las lineas `Proximo paso:` y `Lee ` — las UNICAS donde
    # Step 8 declara la ruta de un plan (caso 1, y la extension de la linea `Lee` que Step 8
    # documenta mas abajo) — no a `## Como retomar` completo: un plan citado en `No repitas:`
    # ("el enfoque de memory/plans/plan-x.md ya se descarto") o en `Sigue abierto` no es una
    # afirmacion de "este es el proximo paso", y contarlo ahi disparaba SALTADO sobre una mencion
    # inocua (hallazgo real de la ronda de adversario). Ademas exige que el archivo exista: una
    # ruta rota o de otra convencion (`docs/plans/…`) no es "un plan de este proyecto sin
    # enlazar", es un problema distinto que este check no cubre.
    RUTA_PLAN = re.compile(r"\bmemory/plans/([\w.-]+?)\.md\b")
    # `(?:\.md)?` y `(?:#[^\]|]*)?`: un wikilink real puede traer la extension o un ancla de
    # seccion (`[[plans/x.md]]`, `[[plans/x#Estado]]`) sin dejar de ser el mismo plan `x` — sin
    # esto, ese wikilink SI enlaza pero la comparacion por slug exacto no lo reconocia (hallazgo
    # de la ronda de adversario, cero casos en el corpus real pero reproducible).
    WIKILINK_PLAN_LAXO = re.compile(r"\[\[(?:\.\./)*plans/([^\]|#]+?)(?:\.md)?(?:#[^\]|]*)?"
                                    r"(?:\|[^\]]*)?\]\]")
    # El prefijo se compara sin `**negrita**` y admitiendo la tilde real de "Próximo" — dos
    # fichas del corpus la usan (ninguna nombraba un plan ahi, pero el hueco es real, no
    # hipotetico).
    lineas_plan = "\n".join(l for l in sec_retomar.splitlines()
                            if l.strip().strip("*").lower()
                                .startswith(("proximo paso:", "próximo paso:", "lee ")))
    mencionados = set(RUTA_PLAN.findall(lineas_plan))
    planes_laxo = set(WIKILINK_PLAN_LAXO.findall(sec_plans))
    sin_enlazar = sorted(p for p in mencionados
                         if p not in planes_laxo
                         and os.path.isfile(os.path.join(memory_dir, "plans", p + ".md")))
    if sin_enlazar:
        h.append(Hallazgo(SALTADO, "plan.mencionado_no_enlazado",
                          f"{len(sin_enlazar)} plan(es) que `## Como retomar` nombra por ruta y "
                          "`## Plans` no enlaza",
                          [f"plans/{p}.md" for p in sin_enlazar],
                          corrige="si el plan es el contexto real de esta sesion, enlazalo en "
                                  "`## Plans` con `[[plans/<slug>]]` y deja que el caso 1 de Step "
                                  "8 lea su `## Estado`, en vez de nombrarlo suelto en prosa"))
    else:
        h.append(Hallazgo(HECHO, "plan.mencionado_no_enlazado",
                          "todo plan que el snippet nombra por ruta esta enlazado en `## Plans`"))

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
        # Solo los mensuales YYYY-MM.md, no todo `*.md` del directorio. Ahi viven tambien los dos
        # archivos (`_caducados.md` y, desde 2.31.0, `_resueltos.md`), y con el glob ancho un id
        # que SOLO estuviera archivado contaba como "tiene su fila mensual" — el audit daba por
        # hecho un dual-write que no existe. Era falso ya con _caducados.md; _resueltos.md, que
        # crece en cada cierre, lo volvia el caso normal en vez de la excepcion.
        mensuales = "\n".join(leer(p) for p in sorted(glob.glob(
            os.path.join(memory_dir, "pendientes", "*.md")))
            if re.match(r"^\d{4}-\d{2}\.md$", os.path.basename(p)))
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
    sin_sigue_abierto = bool(fecha_ficha and fecha_ficha >= DESDE_SIN_SIGUE_ABIERTO)
    if sin_sigue_abierto and "<filled in Step 8>" not in sec_retomar:
        # 2.35.0: el snippet ya no lleva `Sigue abierto:` (Victor, 2026-09-23: el agente solo
        # actua sobre `Proximo paso` y al humano la lista de ids no le da nada que hacer; lo
        # reemplaza el prompt opcional de print-pendiente-opcional.py, Step 8e). Los pendientes
        # propios quedan en `## Pendientes` de la ficha, que el snippet manda leer. Lo que SIGUE
        # valiendo es la guardia del colapso: el caso 5 de una linea no puede tapar un pendiente
        # propio que se puede hacer ya (sin `_bloqueado`, sin `_revisar` futuro).
        _bloq = bloqueados_abiertos(memory_dir)
        accionables_propios = [i for i in abiertos_ficha if i not in _bloq]
        if "```" not in sec_retomar and accionables_propios:
            h.append(Hallazgo(SALTADO, "snippet.sigue_abierto",
                              f"bloque `Como retomar` colapsado pero la sesion deja "
                              f"{len(accionables_propios)} pendiente(s) propio(s) que se pueden "
                              "hacer ya",
                              accionables_propios,
                              corrige="escribe el bloque completo con ese pendiente en `Proximo "
                                      "paso:` (caso 2 de Step 8)"))
        else:
            h.append(Hallazgo(HECHO, "snippet.sigue_abierto",
                              f"desde {DESDE_SIN_SIGUE_ABIERTO} el snippet no lleva `Sigue abierto:`; "
                              "los pendientes propios estan en `## Pendientes` de la ficha"))
    elif "<filled in Step 8>" in sec_retomar:
        # Step 7a corre ANTES de Step 8 en el template, asi que aqui la seccion todavia lleva su
        # placeholder. Eso no es una omision — es que el paso no ha llegado. Reportarlo como
        # SALTADO ponia un falso positivo en CADA checkpoint, que es justo el muro de ruido que
        # este auditor existe para no crear. Salio en su primer uso real.
        h.append(Hallazgo(DISENO, "snippet.sigue_abierto",
                          "`## Como retomar` aun trae su placeholder: Step 8 corre despues de "
                          "esta auditoria"))
    elif "```" not in sec_retomar and not abiertos_ficha:
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

    # 8-bis. Un id que Step 8c ya reservo para el bloque de calendario (con su Titulo y
    # Descripcion completos, fecha futura) no puede reaparecer en la linea `Sigue abierto:` de
    # `## Como retomar` — esa linea es la lista de lo que "sigue abierto y toca retomar", y listar
    # ahi un id que ya tiene su propio recordatorio con fecha duplica la misma informacion en dos
    # formas. Medido en `claude-vzert` (2026-09-18/19, dos sesiones reales): el mismo id vencia en
    # el bloque de calendario Y volvia a aparecer en `Sigue abierto` del snippet de hoy. La regla
    # de 2.25.7 ("la escalera de `<next-step>` descarta candidatos con `_revisar` futuro") solo
    # mira que ningun id FALTE de esa linea; el check 8 de arriba hereda esa misma direccion —
    # nunca mira si un id que YA tiene su propio recordatorio se colo de vuelta.
    #
    # Acotado a ESTA linea a proposito, no a todo `## Como retomar`: `Proximo paso` puede citar el
    # mismo id de forma legitima para EXPLICAR por que no hay nada accionable hoy ("Proximo paso:
    # ninguno -- el pendiente de esta sesion queda con fecha futura, ver Recordatorios de
    # calendario", o su variante "nada accionable hoy... ver Recordatorios de calendario") — esa
    # cita es el motivo del caso 5, no una duplicacion. Dos falsos positivos reales de esa forma
    # (`remedicion-goalspec-precondicion-no-cumplida`, `nudge-devs-encendido`) salieron en el
    # barrido de sombra antes de acotar el check a `Sigue abierto:`; distinguir "cita como motivo"
    # de "duplica como accion" en `Proximo paso` pide juicio semantico que Step 8 no debe hacer
    # (regla 216) — sigue sin cubrir mecanicamente ese caso, ver el pendiente que deja esta sesion.
    #
    # Solo cuenta el id de la propia linea `Retomamos:` de cada recordatorio (el que Step 8c-2
    # reservo), no cualquier id que su Descripcion/Comprueba mencionen de paso para dar contexto.
    ids_calendario = set(RETOMAMOS_ID_CALENDARIO.findall(_sec_cal)) if BLOQUE_CALENDARIO.search(_sec_cal) else set()
    ids_calendario |= {pid for pid, _f in YA_AGENDADO.findall(_sec_cal)}
    ids_retomar = set(ID_PENDIENTE.findall(linea_sigue_abierto(sec_retomar)))
    colados = sorted(ids_calendario & ids_retomar)
    if not ids_calendario:
        h.append(Hallazgo(HECHO, "snippet.futuro_duplicado",
                          "sin recordatorios de calendario en esta ficha: no aplica"))
    elif colados:
        h.append(Hallazgo(SALTADO, "snippet.futuro_duplicado",
                          f"{len(colados)} id(s) del bloque de calendario reaparecen en la linea "
                          "`Sigue abierto:`",
                          colados,
                          corrige="quita el id de la linea `Sigue abierto:`: ya tiene su propio "
                                  "recordatorio con fecha en `## Recordatorios de calendario`, no "
                                  "repitas la misma fecha en el bloque de hoy"))
    else:
        h.append(Hallazgo(HECHO, "snippet.futuro_duplicado",
                          "ningun id del bloque de calendario se repite en `Sigue abierto:`"))

    # 8-ter. `Proximo paso:` (2.33.0, p-daf3051915). Los tres defectos de `<next-step>` que la
    # sesion 5790b9f2 cometio en su propio cierre, medidos sobre la LINEA, no sobre el bloque:
    #   (a) caso 4 generico: "revisar _pendientes.md y proponer siguiente prioridad". El caso se
    #       quito del template; su texto literal en esta linea es SALTADO siempre.
    #   (b) sin `_id`: fuera del caso 1 (`Fase actual:` con un plan enlazado en `## Plans`) y del
    #       caso 5 (`ninguno — …`), el paso es un pendiente de los casos 2-3, y un pendiente tiene
    #       id. Un paso sin id es trabajo que NUNCA se registro — el mismo hueco que dejo el
    #       defecto hallado en vivo fuera de la escalera. Exigir el id obliga a registrarlo.
    #   (c) no inmediato: un id citado que en `_pendientes.md` trae `_bloqueado:` (espera a algo
    #       fuera de la sesion) o `_revisar` futuro (ya tiene su recordatorio de calendario). La
    #       deteccion es SOLO por esos campos estructurados, nunca por el texto (regla 216).
    #   (d) `ninguno` teniendo trabajo propio: un pendiente de esta ficha abierto, sin
    #       `_bloqueado` y sin `_revisar` futuro, es un candidato real de los casos 2-3.
    # Una linea que empieza por `ninguno` puede citar ids como MOTIVO ("lo unico propio espera a
    # otra instalacion, p-…") — por eso (b) y (c) no miran esa forma; la mira (d).
    bloqueados = bloqueados_abiertos(memory_dir)
    origen_por_id = origenes_abiertos(memory_dir)
    pp = linea_proximo_paso(sec_retomar)
    if seccion_por_prefijo(secs, "Como retomar") is None:
        # Sin la seccion no hay paso que medir; la ausencia ya la marca `ficha.secciones`.
        # Contarla aqui tambien la duplicaba (8 fichas de claude-vzert, todas sin seccion).
        h.append(Hallazgo(HECHO, "snippet.proximo_paso",
                          "la ficha no tiene `## Como retomar` (lo marca ficha.secciones)"))
    elif "<filled in Step 8>" in sec_retomar:
        h.append(Hallazgo(DISENO, "snippet.proximo_paso",
                          "`## Como retomar` aun trae su placeholder: Step 8 corre despues de "
                          "esta auditoria (el hook de cierre la vuelve a correr)"))
    elif "```" not in sec_retomar and not sec_retomar.strip().strip("*").lower().startswith("ninguno"):
        # Sin fence, la unica forma valida es la linea del caso 5 (`Ninguno — …`, Step 8a). Tratar
        # cualquier seccion sin fence como caso 5 dejaba pasar el caso 4 con solo quitarle las
        # comillas triples (adversario externo, ronda 1, sobre una ficha real de claude-vzert).
        h.append(Hallazgo(SALTADO, "snippet.proximo_paso",
                          "`## Como retomar` no tiene bloque de codigo y no es la linea del caso 5 "
                          "(`Ninguno — …`)",
                          corrige="escribe el snippet dentro de ``` (Step 8a) o, si nada se retoma, "
                                  "la linea `Ninguno — <motivo>`"))
    elif "```" not in sec_retomar:
        h.append(Hallazgo(HECHO, "snippet.proximo_paso",
                          "bloque colapsado (caso 5): sin `Proximo paso:` que medir"))
    elif pp is None:
        h.append(Hallazgo(SALTADO, "snippet.proximo_paso",
                          "el bloque `Como retomar` no tiene linea `Proximo paso:`",
                          corrige="escribe la linea con el candidato de la escalera de Step 8"))
    else:
        problemas = []
        # "nada accionable hoy — …" es la misma forma del caso 5 con otras palabras (medido en
        # claude-vzert, `verificar-reaper-y-limpiar-default-herdr`): tratarla como paso sin id era
        # un falso positivo sobre un cierre correcto.
        es_ninguno = pp.lower().startswith(("ninguno", "nada accionable"))
        ids_pp = sorted(set(ID_PENDIENTE.findall(pp)))
        if CASO4_GENERICO.search(pp):
            problemas.append("es el caso 4 generico (\"revisar _pendientes.md y proponer "
                             "siguiente prioridad\"), quitado en 2.33.0: o hay un candidato real "
                             "de los casos 1-3, o es el caso 5 (`ninguno — …`)")
        elif not es_ninguno:
            es_caso1 = pp.lower().startswith("fase actual") and bool(planes_laxo)
            if not ids_pp and not es_caso1:
                problemas.append("no cita el `_id` de ningun pendiente: si es trabajo real, "
                                 "registralo en Step 3b (`pendiente.add`) y cita su id; si nada es "
                                 "accionable hoy, es el caso 5")
            for i in ids_pp:
                if i not in ids_abiertos:
                    # Un id que no esta abierto en `_pendientes.md` no es trabajo registrado: o se
                    # invento, o ya se cerro. Sin esto, citar cualquier `p-…` bastaba para pasar.
                    problemas.append(f"{i} no esta abierto en _pendientes.md: cita el id de un "
                                     "pendiente vivo")
                elif i in bloqueados:
                    problemas.append(f"{i} esta bloqueado (`_bloqueado: {bloqueados[i]}`): "
                                     "espera a algo fuera de la sesion: no va en `Proximo paso`")
                elif rev_por_id.get(i) and rev_por_id[i] > ref:
                    problemas.append(f"{i} tiene `_revisar: {rev_por_id[i]}` futuro: ya sale en "
                                     "`## Recordatorios de calendario`")
        if es_ninguno:
            # Solo los que SIGUEN abiertos en `_pendientes.md`: uno ya cerrado no es trabajo. En
            # el cierre real son todos; importa al re-auditar una ficha vieja (falso positivo
            # medido en `remedicion-goalspec-precondicion-no-cumplida`).
            # Y solo los que NACIERON en esta sesion (`_origen: [[sessions/<esta ficha>]]`): la
            # seccion `## Pendientes` tambien lista los de otras sesiones que Step 3a reconcilio
            # como still-open, y esos no son "trabajo propio" que el caso 5 tape (medido en
            # claude-vzert: `verificar-reaper-…` listaba 4 ajenos y salia SALTADO en falso).
            accionables = [i for i in abiertos_ficha
                           if i in ids_abiertos and i not in bloqueados
                           and origen_por_id.get(i) == slug]
            if accionables:
                problemas.append("dice `ninguno` pero la sesion deja pendiente(s) propio(s) "
                                 "accionables hoy (sin `_bloqueado` ni `_revisar` futuro): "
                                 + ", ".join(accionables))
        if problemas:
            h.append(Hallazgo(SALTADO, "snippet.proximo_paso",
                              "`Proximo paso:` no es un paso inmediato y registrado",
                              problemas,
                              corrige="rehaz `Proximo paso:` con la escalera de Step 8 (casos 1-3 "
                                      "o 5); si falta el pendiente, emitelo antes con "
                                      "journal-emit.py --type pendiente.add"))
        else:
            h.append(Hallazgo(HECHO, "snippet.proximo_paso",
                              "`Proximo paso:` es caso 1, 5, o un pendiente registrado e inmediato"))

    # 8-quinquies. Cada defecto de `## Bugs fixed` declara su cierre (2.34.0, p-272254efc5). La
    # salida que 2.33.0 dejo abierta: un defecto hallado en vivo y "arreglado" solo con prosa
    # tenia la misma forma que uno verificado, no se registraba, y `Proximo paso: ninguno`
    # pasaba todo. Ahora cada linea lleva `_verificado: <evidencia>_` o `_pendiente: p-…_`. Solo
    # se mide el CAMPO (regla 216): un `_verificado:` falso lo pasa — el mismo limite que
    # `_bloqueado:`, documentado en el test. Un defecto que nunca se escribe en la ficha tampoco
    # lo ve: no existe senal estructurada para eso (medido: tools/medir-senal-defecto.py).
    sec_bugs = seccion_por_prefijo(secs, "Bugs fixed") or ""
    bugs = bullets_bugs(sec_bugs)
    # Los `_pendiente:` cuentan para 8-sexies aunque la ficha sea anterior al corte: el corte
    # exime de ESCRIBIR el campo, no ignora el que si se escribio.
    ids_bugs = [i for _, b in bugs for i in PENDIENTE_BUG.findall(b)]
    if fecha_ficha and fecha_ficha < DESDE_BUGS_CIERRE:
        h.append(Hallazgo(DISENO, "bugs.cierre",
                          f"ficha del {fecha_ficha}, anterior a {DESDE_BUGS_CIERRE}: `## Bugs fixed` "
                          "no llevaba `_verificado:`/`_pendiente:`"))
    elif not bugs:
        h.append(Hallazgo(HECHO, "bugs.cierre", "`## Bugs fixed` sin defectos que medir"))
    else:
        historicos = ids_historicos(memory_dir)
        malos = []
        for propio, b in bugs:
            primera = propio.splitlines()[0][:70]
            ids_b = PENDIENTE_BUG.findall(propio)
            evid = [e.strip() for e in VERIFICADO.findall(propio)]
            evid = [e for e in evid if e and not re.fullmatch(r"<[^>]*>", e)]
            if not ids_b and not evid:
                malos.append(f"sin `_verificado: <evidencia>_` ni `_pendiente: p-…_`: {primera}")
            for i in PENDIENTE_BUG.findall(b):
                if i not in historicos:
                    malos.append(f"{i} no existe en la memoria (ni abierto ni en pendientes/): {primera}")
        if malos:
            h.append(Hallazgo(SALTADO, "bugs.cierre",
                              f"{len(malos)} defecto(s) de `## Bugs fixed` sin cierre declarado",
                              malos,
                              corrige="al final de cada linea: `_verificado: <test o corrida que lo "
                                      "comprobo>_`, o registra el defecto con journal-emit.py --type "
                                      "pendiente.add (Step 3b punto 9) y cita `_pendiente: p-…_`"))
        else:
            h.append(Hallazgo(HECHO, "bugs.cierre",
                              f"los {len(bugs)} defecto(s) de `## Bugs fixed` declaran su cierre"))

    # 8-sexies. `ninguno` no puede tapar un defecto abierto (2.34.0, p-272254efc5). Dos senales,
    # las dos estructuradas: (1) un `_pendiente:` de `## Bugs fixed` que sigue abierto e inmediato
    # (sin `_bloqueado`, sin `_revisar` futuro) — cualquier origen: la linea dice que es un defecto
    # de ESTA sesion; (2) el hook de cierre pasa `--veredicto-adversario break` cuando el ultimo
    # veredicto del adversario en el transcript es `break` sin `[GOAL-CLOSE-WAIVED` detras; se
    # levanta citando en `## Bugs fixed` un `_pendiente:` todavia abierto (el defecto quedo
    # registrado). Aplica al caso 5 colapsado y al `Proximo paso: ninguno`/`nada accionable`.
    colapsado = "```" not in sec_retomar and sec_retomar.strip().strip("*").lower().startswith("ninguno")
    es_ninguno_snip = colapsado or bool(pp and pp.lower().startswith(("ninguno", "nada accionable")))
    if "<filled in Step 8>" in sec_retomar or not es_ninguno_snip:
        h.append(Hallazgo(HECHO, "snippet.ninguno_defecto", "el snippet no es `ninguno`: no aplica"))
    else:
        prob = []
        vivos = [i for i in dict.fromkeys(ids_bugs) if i in ids_abiertos]
        inmediatos = [i for i in vivos if i not in bloqueados
                      and not (rev_por_id.get(i) and rev_por_id[i] > ref)]
        if inmediatos:
            prob.append("`## Bugs fixed` registra defecto(s) abierto(s) e inmediato(s): "
                        + ", ".join(inmediatos))
        if veredicto_adv == "break" and not vivos:
            prob.append("el ultimo veredicto del adversario es `break` y ningun `_pendiente:` "
                        "abierto de `## Bugs fixed` lo registra")
        if prob:
            h.append(Hallazgo(SALTADO, "snippet.ninguno_defecto",
                              "el snippet dice `ninguno` con un defecto de la sesion abierto", prob,
                              corrige="registra el defecto (pendiente.add, Step 3b punto 9), citalo "
                                      "con `_pendiente: p-…_` en `## Bugs fixed`, y ponlo como "
                                      "`Proximo paso:` si es inmediato"))
        else:
            h.append(Hallazgo(HECHO, "snippet.ninguno_defecto",
                              "`ninguno` sin defecto abierto registrado ni `break` sin cerrar"))

    # 8-quater. `Sigue abierto:` solo nombra pendientes VIVOS (2.33.1, p-c72a33ae7a). Medido en vivo
    # en la sesion que construyo 2.33.0: tras el checkpoint se resolvio `p-477bb60303` (el push) y
    # el snippet que el usuario ya tenia seguia listandolo como abierto. Hasta aqui solo se miraba
    # que los ids de `Proximo paso:` siguieran abiertos. Se mide sobre la LINEA, igual que 8 y 8-bis.
    linea_sa_viva = linea_sigue_abierto(sec_retomar)
    ids_sa = sorted(set(ID_PENDIENTE.findall(linea_sa_viva)))
    if "<filled in Step 8>" in sec_retomar or not ids_sa:
        h.append(Hallazgo(HECHO, "snippet.ids_vivos",
                          "`Sigue abierto:` no cita ids que medir"))
    else:
        cerrados_sa = [i for i in ids_sa if i not in ids_abiertos]
        if cerrados_sa:
            h.append(Hallazgo(SALTADO, "snippet.ids_vivos",
                              f"{len(cerrados_sa)} id(s) de `Sigue abierto:` ya no estan abiertos en "
                              "_pendientes.md",
                              cerrados_sa,
                              corrige="quita el id de la linea (o cambialo por el pendiente que lo "
                                      "sustituye), vuelve a correr print-como-retomar.py y pega el "
                                      "snippet nuevo en tu respuesta"))
        else:
            h.append(Hallazgo(HECHO, "snippet.ids_vivos",
                              f"los {len(ids_sa)} id(s) de `Sigue abierto:` siguen abiertos"))

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

    # 10-bis. La celda Commit de ESA fila (2.39.2, p-d1a1ce615f). indice.sesion solo miraba que la
    # fila existiera: dos checkpoints seguidos de este repo (2026-09-24 y 25, memory/ en
    # .gitignore) saltaron Step 6 y dejaron la celda vacia en vez de `N/A` (Step 6d), y el audit
    # dio HECHO. Step 7a corre DESPUES de Step 6, asi que a esa altura la celda ya tiene que traer
    # el hash (6c) o `N/A` (6d): vacia no es un estado intermedio legitimo. Sin columna Commit en
    # la cabecera (indice de otra forma) no se inventa nada: no aplica.
    filas_idx = filas_tabla(idx_ses)
    col_commit = None
    if filas_idx:
        col_commit = next((i for i, c in enumerate(filas_idx[0]) if c.strip().lower() == "commit"), None)
    fila_propia = next((f for f in filas_idx[1:] if any(f"sessions/{slug}" in c for c in f)), None)
    if col_commit is None or fila_propia is None:
        h.append(Hallazgo(HECHO, "indice.commit",
                          "sin columna Commit o sin fila de esta ficha: no aplica (lo cubre indice.sesion)"))
    elif col_commit >= len(fila_propia) or COMMIT_RELLENO.search(fila_propia[col_commit]):
        fecha_ficha = slug[:10]
        h.append(Hallazgo(SALTADO, "indice.commit",
                          "la celda Commit de esta ficha en _session-index.md no trae hash ni N/A: "
                          f"[{fila_propia[col_commit].strip() if col_commit < len(fila_propia) else ''}]",
                          corrige=f'python3 "$JBIN/journal-emit.py" --type session.add --slug "{slug}" '
                                  f"--date {fecha_ficha} --commit '`<hash>`'   # o --commit \"N/A\" si "
                                  'Step 6 no comiteo (Step 6d); despues journal-compact.py'))
    else:
        h.append(Hallazgo(HECHO, "indice.commit",
                          f"celda Commit de esta ficha: {fila_propia[col_commit].strip()}"))

    # 10-ter. El mismo pendiente con un recordatorio de calendario VIVO en otra ficha (2.39.2,
    # p-c9410e7764). Caso real (2026-09-25, este repo): p-8472f7f4b7 quedo con un recordatorio para
    # el 26 en la ficha del 24 (viejo: solo cubria 2.39.0) y otro en la del 25. Quien pega los dos
    # en su calendario tiene dos eventos para una tarea, y uno con el alcance equivocado. Solo se
    # vio porque el usuario pregunto. Cuenta la fecha del ENCABEZADO de cada bloque (`### FECHA`,
    # Step 8c-2) y el id de su linea `Retomamos:`; un recordatorio cuya fecha ya paso es historia,
    # no duplicado.
    def _bloques_calendario(texto_seccion):
        """[(fecha, id)] por bloque `### FECHA ...` de una seccion de recordatorios."""
        out = []
        cortes = [m.start() for m in BLOQUE_CALENDARIO.finditer(texto_seccion)] + [len(texto_seccion)]
        for a, b in zip(cortes, cortes[1:]):
            trozo = texto_seccion[a:b]
            fecha = trozo.lstrip("#").strip()[:10]
            for pid in RETOMAMOS_ID_CALENDARIO.findall(trozo):
                out.append((fecha, pid))
        return out

    propios = {pid for fecha, pid in _bloques_calendario(_sec_cal) if fecha >= hoy}
    if not propios:
        h.append(Hallazgo(HECHO, "calendario.duplicado_entre_fichas",
                          "sin recordatorios con fecha futura en esta ficha: no aplica"))
    else:
        repetidos = []
        propia = os.path.abspath(session_file)
        for otra in sorted(glob.glob(os.path.join(memory_dir, "sessions", "*.md"))):
            if os.path.abspath(otra) == propia:
                continue
            sec_otra = seccion_por_prefijo(secciones(leer(otra)), "Recordatorios de calendario") or ""
            for fecha, pid in _bloques_calendario(sec_otra):
                if pid in propios and fecha >= hoy:
                    repetidos.append(f"{pid} tambien en sessions/{os.path.basename(otra)} ({fecha})")
        if repetidos:
            h.append(Hallazgo(SALTADO, "calendario.duplicado_entre_fichas",
                              f"{len(repetidos)} recordatorio(s) de esta ficha ya estan vivos en otra",
                              repetidos,
                              corrige="deja uno solo: reemplaza el bloque de la ficha vieja por una nota "
                                      "que apunte a la nueva (Step 8c-2) y avisa al usuario de que "
                                      "borre el evento viejo si ya lo agendo"))
        else:
            h.append(Hallazgo(HECHO, "calendario.duplicado_entre_fichas",
                              "ningun recordatorio vivo de esta ficha se repite en otra"))

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
    # nunca llego al usuario. Los tres reparadores de Step 3-pre comparten la misma forma de
    # aviso ("no pude migrar esto sin adivinar, quedo de solo lectura") asi que los tres se miden
    # igual — `repair-plans-index.py` y `repair-research-index.py` faltaban aqui hasta esta
    # version: header_unrecognized=1 en cualquiera de los dos es EXACTAMENTE el mismo patron de
    # hueco que motivo este archivo, solo que en una tabla distinta (ver p-ccc013b53d).
    if solo_snippet:
        # Modo del hook de cierre (checkpoint-close-guard.sh): solo lo que Step 8 escribe. Los
        # reparadores en seco tardan segundos y no dependen del snippet; ya los midio Step 7a.
        return [x for x in h if x.clave.startswith(("snippet.", "bugs.")) or x.clave == "plan.mencionado_no_enlazado"]
    avisos_script_en_seco(h, memory_dir, "repair-dualwrite.py",
                          ("header_issues", "odd_values", "unaligned_rows", "unrepairable",
                           "ids_invented", "missing_data", "pipes_broken"))
    avisos_script_en_seco(h, memory_dir, "repair-plans-index.py",
                          ("header_unrecognized", "unrepairable_rows", "possible_duplicates"))
    avisos_script_en_seco(h, memory_dir, "repair-research-index.py",
                          ("active_header_unrecognized", "completed_header_unrecognized",
                           "active_unrepairable", "completed_unrepairable",
                           "active_possible_duplicates", "completed_possible_duplicates"))

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
    ap.add_argument("--solo-snippet", action="store_true",
                    help="solo los checks `snippet.*` (lo que escribe Step 8); lo usa el hook Stop")
    ap.add_argument("--json", action="store_true", help="salida JSON (para el hook Stop)")
    ap.add_argument("--veredicto-adversario", choices=("break", "hold"), default=None,
                    help="ultimo veredicto del adversario en el transcript; lo pasa el hook Stop")
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
    hallazgos = auditar(args.memory_dir, args.session_file, repo_root,
                        not args.no_git and not args.solo_snippet, hoy, args.solo_snippet,
                        args.veredicto_adversario)

    if args.count:
        print(sum(1 for x in hallazgos if x.estado in (SALTADO, PARCIAL)))
        return
    if args.json:
        import json
        print(json.dumps([{"estado": x.estado, "clave": x.clave, "detalle": x.detalle,
                           "lineas": x.lineas, "corrige": x.corrige} for x in hallazgos],
                         ensure_ascii=False))
        return
    imprimir(hallazgos)


if __name__ == "__main__":
    main()
