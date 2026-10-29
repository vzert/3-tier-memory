#!/usr/bin/env python3
"""
3-tier-memory plugin: emisor de eventos del journal (v2.12.0, Fases 1 y 2).

Los agentes NO editan los indices compartidos de memory/ a mano. Cada cambio entra como un
evento: un archivo JSON propio en memory/.journal/pending/ (escrito en un temporal creado con
O_CREAT|O_EXCL y renombrado al .json ya completo, desde 2.63.34; ver write_event), que
un unico compactador (journal-compact.py) aplica bajo lock. Asi N agentes en la misma
maquina pueden escribir "a la vez" sin pisarse: cada uno solo crea archivos nuevos.

Por que un archivo por evento y no append a uno solo: append concurrente a un mismo archivo
no es atomico entre procesos en todas las plataformas; crear un archivo nuevo con O_EXCL si.
Ver memory/research/concurrent-memory-writes y plans/plan-journal-concurrencia-v2.12.0.

Tipos de evento:
  pendiente.add     --text T --prioridad Alta|Media|Baja --origen O [--creado YYYY-MM-DD]
                    [--titulo TT]   (2.63.47, p-206fd62e68) Tier 2 lleva SOLO TT (<=200 caracteres)
                    y --text va entero a la fila mensual (Tier 3) como detalle. El id es el hash de
                    TT. Sin --titulo y con --text de mas de 200 caracteres avisa por stderr.
                    [--revisar YYYY-MM-DD]   (ventana declarada; la lee expire-pendientes.py)
                    [--bloqueado-por "QUE"]  (espera a algo FUERA de la sesion: otra
                    instalacion, un peer, un PR ajeno; nunca una decision del usuario,
                    que va en el `Proximo paso`; checkpoint-audit.py rechaza un
                    `Proximo paso:` que cite un id con `_bloqueado:` y `_revisar` futuro)
                    (2.63.32) Con --bloqueado-por y sin --revisar, la ventana es hoy+5: un
                    bloqueado sin fecha no volvia a salir nunca (medido 2026-10-20: 50 de 54
                    bloqueados abiertos en 7 proyectos). Lo avisa por stderr.
                    [--relacionado p-<10 hex>|plan-<slug>]...  (repetible, 2.55.0: otro
                    pendiente o un plan con el que este va junto; lo lee pendientes_afines.py,
                    que print-como-retomar.py usa para sumar afines al `Proximo paso`)
                    (2.57.0) Ademas se liga SOLO a los ids del `Proximo paso` que la sesion
                    recibio (sello `hilo_paso` de la ficha de --origen, o la transcripcion:
                    [--transcript RUTA] o la de CLAUDE_CODE_SESSION_ID). Lo avisa por stderr.
                    Imprime el id (p-<10 hex>) por stdout.                              (Fase 1)
  pendiente.resolve --id ID --estado resolved|superseded|abandoned [--sesion S] [--nota N]
                    --nota solo la guardan resolve, learning.retire y learning.add --supersedes;
                    los demas tipos salen con error si la reciben, aun vacia (2.62.10).
                    Lo mismo con cualquier otro flag (2.63.2): un flag que el tipo no lee
                    (FLAGS_DE) sale con error y no escribe evento, aun abreviado o con `=`.
  pendiente.update  --id ID [--text T] [--prioridad Alta|Media|Baja] [--text-prefix P]
                    Corrige el texto y/o la prioridad de un pendiente VIVO conservando su id.
                    El id es el hash con el que NACIO, no el del texto de hoy: cambiarlo
                    romperia las citas del id en fichas, recordatorios y research, que es lo
                    que hacia el unico camino que habia antes (resolve --superseded + add).
                    Un cambio de texto deja `_actualizado: FECHA_` en la linea; esa marca es
                    lo que le dice a repair-dualwrite.py que ese id es el de nacimiento y no
                    un id inventado (sin ella, `--fix-ids --apply` lo renombraria).
                    `--text-prefix` es el guardian contra la actualizacion perdida entre dos
                    sesiones: si no se pasa, se toma de la linea viva. Exige --text y/o
                    --prioridad. Sobre un pendiente ya cerrado o caducado no hace nada.
                    Rechaza --nota: no tiene donde guardarla; va en el --text o en resolve --nota.
  pendiente.expire  --id ID --dias N [--line "<linea verbatim>"]   (caducidad por edad)
  pendiente.reopen  --id ID [--prioridad P]             (reversa de expire y de resolve)
  pendiente.window  --id ID --revisar YYYY-MM-DD                  (pone/actualiza la ventana)
  pendiente.retomar --id ID --retomar YYYY-MM-DD --ficha sessions/<slug>
                    Pone o cambia `_retomar: FECHA sessions/<slug>_`: el pendiente que cita el
                    `Proximo paso` de esa ficha, para que el mod pendientes lo saque en PLANES ACTIVOS.
                    Solo lo lee el mod; 8e, el hilo y el calendario lo ignoran (2.62.8).
  pendiente.retomar --id ID --quitar --ficha sessions/<slug>                       (2.63.42)
                    Quita `_retomar` si todavia apunta a esa ficha: la sesion que retomo su
                    snippet ya lo consumio (marcar-retomar.py). Si la marca ya apunta a otra
                    ficha (otra sesion la movio), no hace nada.
  pendiente.block   --id ID (--bloqueado-por "QUE" | --desbloquear) [--revisar YYYY-MM-DD]
                    Pone, cambia o quita `_bloqueado: QUE_` en un pendiente VIVO. Existe para
                    marcar en Step 3a uno que nacio sin el campo; no cambia el id.
                    (2.63.32) Al bloquear pone tambien `_revisar`: la fecha dada, o hoy+5 si la
                    linea no trae ya un `_revisar` futuro (ese se conserva). Al desbloquear quita
                    `_revisar` (era la fecha de mirar si llego la espera), salvo que se de
                    --revisar, que queda como la ventana nueva.
                    [--text-prefix P]  (si no se da, se toma del archivo si la linea existe)
  pendiente.relate  --id ID (--relacionado X [--relacionado Y ...] | --sin-relacion)
                    Pone (reemplaza) o quita `_relacionado: X, Y_` en un pendiente VIVO
                    (2.55.0). Mismo patron que pendiente.block; no cambia el id.
  pendiente.adopt   (--text-prefix P | --line "<linea entera>" | --id sin-id-<10 hex>[-N]
                     | --todas) [--colapsar]                                          (2.58.0)
                    Le pone su `_id:` a un pendiente que no lo tiene (escrito a mano o anterior
                    al journal): sin id ningun otro evento lo encuentra. Despues, update/resolve
                    normales. El id es el CANONICO de la linea, sha1(texto+creado+origen), el
                    mismo que pone `enrich-memory.py --only creado,id` (la linea queda byte a byte
                    igual), asi que repair-dualwrite no lo ve como inventado. Si falta `_creado`
                    se escribe tambien, con la derivacion de enrich (la llama, no la copia): slug
                    de _origen, `date:` del fichero al que enlaza, mtime de _pendientes.md.
                    Diferencias con enrich: los items con sangria (enrich los salta, adopt y
                    repair-dualwrite no) y un `_id:p-…_` mal espaciado (enrich lo da por id y no
                    lo toca; adopt lo reespacia). --id acepta el id sintetico de /triage-3t. El
                    evento lleva la linea VERBATIM, espacios incluidos: si cambio antes del
                    compactado, se salta con aviso. Mismo id
                    dos veces (lineas identicas, o copia de un pendiente que ya tiene id) = el
                    mismo pendiente: se niega; --colapsar deja una y guarda las copias enteras en
                    .journal/adopt-colapsados.log. --todas adopta todas en un evento y aparta
                    los duplicados. Imprime el id (uno por linea con --todas). Un
                    `_id: p-<10 hex>_` mal espaciado (`_id:p-…_`) se reespacia y CONSERVA su id;
                    otro `_id:` no canonico (`p-1234abcd`, prosa) se deja y el canonico va al final.
  session.add       --slug DATE-SLUG --date D --status ST --summary R [--commit C]      (Fase 2)
                    Fila en _session-index.md (arriba de la tabla). Si la fila del slug ya
                    existe, rellena status/summary/commit con lo que se pase. Imprime s-<slug>.
  session.amend     --slug DATE-SLUG [--date D] [--alias A]
                    [--fecha-vieja V] [--sesion-vieja V]                              (2.40.0)
                    Corrige la Fecha y/o el alias de las filas de tabla cuya celda Sesion es
                    [[sessions/DATE-SLUG|...]]. El slug (nombre del fichero) no cambia, y el
                    fichero de la sesion no se toca. --fecha-vieja/--sesion-vieja son el
                    guardian contra la actualizacion perdida; si no se pasan, se toman de la fila
                    viva (con la misma funcion que usa el compactador). Filas duplicadas que no
                    coinciden: se niega; un session.add de la sesion las fusiona. No poda: una
                    fecha corregida hacia atras no expulsa la fila.
  learning.add      --topic T [--text "**Regla** — detalle"] [--section H] [--quickref Q]
                    [--title TT] [--when W] [--importance N]                            (Fase 2)
                    Regla numerada (max+1, bajo lock) en learnings/<topic>.md; crea el topic
                    file y su fila en _learnings.md si faltan; --quickref agrega la version
                    corta al Quick Reference (numerada, max+1). Sin --text solo registra el
                    topic. Imprime l-<10 hex> (o l-topic-<topic>).
                    [--supersedes N [--nota "<una linea>"] [--quickref-prefix QP]]   (2.45.0)
                    La regla nueva REEMPLAZA a la #N del mismo topic: en el mismo escrito, N
                    queda marcada `— ⊘ RETIRADA (FECHA, superada por #M)`. O las dos o ninguna.
                    --quickref-prefix quita la linea vieja de N del Quick Reference.
                    [--decision nueva|reemplaza:N] [--solo-vecinos]                    (2.47.0)
                    Dedup al emitir: con --text, imprime por STDERR las 8 reglas vivas del topic
                    mas parecidas (Dice ponderado por IDF, bin/learning_vecinos.py); stdout sigue
                    siendo solo el id. Si la mas parecida llega a 0,5 y no hay --decision, sale 1
                    sin escribir. reemplaza:N = --supersedes N. corrige:N sale 1 e imprime
                    el comando exacto de learning.update. La decision va al payload; la lee
                    tools/recall-bench/bloqueos-reales.py (cuantos learning.add la traen). --solo-vecinos imprime la lista y no escribe nada. Exige la
                    forma `**Titulo** — cuerpo`, `**` y comillas invertidas en numero par y un
                    titulo de 200 caracteres como mucho. El mismo texto exacto no se bloquea
                    (el compactador no lo escribe dos veces).
                    [--disparadores "frases=a | b | c; cmd=x, y; path=g/*; tool=Bash"] (2.48.0)
                    OPCIONAL. Como describiria el momento alguien que NO conoce la regla (3-6
                    frases), mas los comandos, rutas y herramientas de ese momento (para la F5).
                    Van al final de la linea como comentario HTML: el recall indexa las frases y
                    no las muestra. Medido en F4: no subieron el recall de prompt al criterio.
  learning.retire   --topic T --match-prefix P --motivo obsoleta|duplicada|superada
                    [--por N] [--nota "<una linea>"] [--quickref-prefix QP]           (2.45.0)
                    Retira una regla SIN borrarla ni renumerarla: anade al final de su linea
                    `— ⊘ RETIRADA (FECHA, <motivo>[ por #N]): <nota>`. El recall deja de
                    servirla. --por (la regla viva que la reemplaza) es obligatorio con
                    duplicada|superada y no se admite con obsoleta. --quickref-prefix quita su
                    linea del Quick Reference (sin renumerar el resto). Imprime l-topic-<T>.
  learning.patch    (--topic T --match-prefix P | --quickref-prefix QP)
                    --viejo "<trozo>" --nuevo "<trozo>"                                  (2.69.0)
                    Cambia un trozo LITERAL de la primera linea de una regla, sin tocar su
                    numero, vineta, marca de retirada ni comentarios. Es la via para las reglas
                    que learning.update no puede reescribir (cuarentena anterior,
                    bloque-multilinea o codigo-antes). El trozo viejo tiene que salir una vez en
                    el texto de la regla y el nuevo ninguna; ninguno lleva saltos de linea,
                    vallas (``` ~~~), `<!--`, `-->` ni ⊘, y --nuevo no puede estar dentro de
                    --viejo. Se comprueba al emitir y otra vez al compactar.
  learning.update   --topic T [--match-prefix P --text "<nuevo>"]
                    [--quickref-prefix QP --quickref "<nuevo>"] [--title TT] [--when W]
                    [--match-prefix P --disparadores "<frases=...>"]                     (2.48.0)
                    [--last-verified YYYY-MM-DD]                                          (2.50.0)
                    [--quickref-prefix QP --quickref-regla <T>#<N>|<T>|ninguna]           (2.51.0)
                    --quickref-regla escribe (o cambia) la marca `<!-- regla: ... -->` que enlaza
                    la linea del Quick Reference con su regla; sin --quickref no toca el texto, y
                    --quickref sin --quickref-regla conserva la marca que tenia.
                    --last-verified pone `last_verified:` en el frontmatter del topic file (lo
                    que /audit-3t mira para la frescura). Solo avanza: una fecha anterior a la
                    que ya tiene no la cambia, asi que un replay viejo no la hace retroceder.
                    --disparadores sin --text enriquece la regla sin cambiar su texto; con
                    --text sin --disparadores, la regla conserva los que tenia; --disparadores
                    REEMPLAZA el juego entero (no anade frases a las que habia).
                    [--match-prefix P --sin-disparadores]                                  (2.60.2)
                    quita el comentario de disparadores entero (texto y marcador intactos): la
                    vuelta atras de un juego de frases que hace perder recall. No va con
                    --disparadores.
                    Corrige una regla YA escrita, CONSERVANDO su numero. Un learning no tiene id
                    en la linea: el ancla es topic + prefijo del texto de hoy. El numero se
                    conserva porque las reglas se citan por numero ("learning 106"); renumerar
                    rompe esas citas igual que renombrar el id de un pendiente. Exige al menos
                    uno de los cuatro campos, y --text/--quickref exigen su prefijo: no se
                    reescribe una regla a ciegas.
  plan.upsert       --slug S --title T --status ST [--date D] [--sesion [[sessions/..]]]
                    [--pendientes N] [--learnings N] [--inline|--promote] [--parent P]  (Fase 2)
                    Fila en _plans-index.md por slug (o titulo, solo filas (inline));
                    actualiza celdas dadas.
                    --inline solo para un plan sin plans/plan-S.md (con el archivo: cuarentena
                    inline-con-archivo).
                    --promote: el plan era --inline y ya tiene plans/plan-S.md; su UNICA fila
                    (inline) titulada T pasa a [[plans/plan-S|T]]. Sin el flag, ese upsert va a
                    cuarentena titulo-ambiguo (la fila (inline) no guarda el slug).
                    --parent anota la celda Status como '<status> (fase de plan-P)'.
  plan.reopen       --slug S [--title T]                                              (2.37.0)
                    Reabre un plan cerrado (completed/abandoned/superseded -> active), conserva
                    '(fase de plan-P)' y deja registro para que el replay del cierre viejo no lo
                    vuelva a cerrar. Es la UNICA forma de reabrir: un plan.upsert que retroceda
                    el status se descarta con aviso. --title solo para un plan --inline.
  research.upsert   --slug S --tema T --status active|completed [--date D] [--next-step N]
                    [--resultado R] [--origen O] [--inline]                             (Fase 2)
                    Fila en Active o Completed de _research-index.md; completed la mueve y
                    marca la celda Archivo con `_completado: D_` (D = --date, hoy por defecto),
                    que es lo que el compactador usa para podar Completed por fecha.
  research.rename   --slug S --tema T [--tema-viejo V]                               (2.38.0)
                    Corrige el tema (celda 0) de la fila cuyo Archivo es [[research/S]], en
                    Active y/o Completed. --tema-viejo es el guardian contra la actualizacion
                    perdida (dos renames del mismo tema); si no se pasa, se toma de la fila
                    viva. Una fila --inline NO se renombra (sin wikilink, su unica identidad es
                    el tema): el compactador la cuarentena. Dale fichero al research primero.

Identidad de un pendiente = sha1(texto normalizado + creado + origen)[:10]. Sin contador,
sin lock: dos agentes que emiten el mismo pendiente el mismo dia producen el mismo id y el
compactador lo aplica una sola vez (deduplicacion). Dos textos distintos con el mismo id
(colision) se cuarentenan en el compactador; nunca se fusionan.

El id es el hash con el que el pendiente NACIO, no el de su texto de hoy: `pendiente.update`
corrige el texto y deja el id intacto, porque ese id ya esta citado en fichas de sesion, en
recordatorios y en research. El precio es que la linea corregida deja de casar con su propio
hash, y hay dos herramientas que miden esa discrepancia — `repair-dualwrite.ids_invented`
(avisa) y `--fix-ids --apply` (RENOMBRA). La marca `_actualizado: FECHA_` que el compactador
deja en la linea es lo que las dos leen para saber que la discrepancia es deliberada.

Salida: 0 ok; 1 argumentos invalidos; 2 no se pudo crear el evento (queda copia en failed/).
Nunca descarta un evento en silencio.

Variables: MEMORY_DIR (o --memory-dir) apunta al directorio memory/. Si no se da, se busca
./memory y luego el auto-memory de Claude Code para el cwd.
"""
# sella-huellas: no (escribe eventos en .journal/pending, nunca un indice)
import argparse
import hashlib
import json
import os
import re
import socket
import sys
import time
import unicodedata
import uuid
from datetime import date, timedelta

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

SCHEMA_VERSION = 1
PRIORIDADES = ("Alta", "Media", "Baja")
ESTADOS = ("resolved", "superseded", "abandoned")
ID_RE = re.compile(r"^p-[0-9a-f]{10}$")
# La ficha de `_retomar:` (2.62.8): sessions/<slug>, sin espacios, sin `—` y sin `_` final (el `_`
# cierra el campo en la linea de Tier 2). La misma expresion en journal-compact.py.
FICHA_RETOMAR_RE = re.compile(r"^sessions/[A-Za-z0-9][A-Za-z0-9._-]*(?<!_)$")
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
FECHA_ISO_RE = re.compile(r"\d{4}-\d{2}-\d{2}")   # con fullmatch: sin el `\n` final que `$` deja pasar
RESEARCH_STATUS = ("active", "completed")
MAX_EXCL_RETRIES = 5


# ----------------------------------------------------------------------------- memoria
def resolve_memory_dir(explicit):
    """MEMORY_DIR explicito > env > ./memory (Model B) > auto-memory (Model A)."""
    cand = explicit or os.environ.get("MEMORY_DIR")
    # memhome (2.52.0): en un worktree enlazado de git, la memoria es la del principal.
    import memhome
    if cand:
        return memhome.normaliza(cand)
    proj = memhome.home(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    local = os.path.join(proj, "memory")
    if os.path.isfile(os.path.join(local, "_pendientes.md")):
        return local
    encoded = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(proj))
    auto = os.path.join(os.path.expanduser("~"), ".claude", "projects", encoded, "memory")
    if os.path.isfile(os.path.join(auto, "_pendientes.md")):
        return auto
    return local


# ----------------------------------------------------------------------------- identidad
def normalize_text(text):
    """Forma canonica del texto para el hash: NFC, espacios colapsados, sin bordes."""
    t = unicodedata.normalize("NFC", text or "")
    t = re.sub(r"\s+", " ", t).strip()
    return t


def pendiente_id(text, creado, origen):
    raw = "\n".join([normalize_text(text), (creado or "").strip(), normalize_text(origen)])
    return "p-" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10]


MOTIVOS_RETIRO = ("obsoleta", "duplicada", "superada")   # = learning_marks.MOTIVOS


def numero_regla(valor, flag):
    """Entero >= 1 de --por / --supersedes, o None si no se paso. Acepta `135` y `#135`."""
    v = (valor or "").strip().lstrip("#")
    if not v:
        return None
    if not v.isdigit() or int(v) < 1:
        sys.exit(f"journal-emit: {flag} debe ser el numero de una regla (p. ej. 99), no {valor!r}")
    return int(v)


def numero_por_prefijo(memory_dir, topic, prefijo):
    """Numero de la UNICA regla numerada del topic cuyo texto empieza por `prefijo`, o None.

    Viaja en el evento de learning.retire: el ancla es el texto de hoy, y si un learning.update
    posterior cambia el principio de la regla, en un replay del retire el prefijo ya no casa. Con
    el numero, el compactador reconoce que esa regla ya esta retirada (replay, I3) en vez de
    mandarlo a cuarentena. Misma comparacion que journal-compact (sin `*`, `_`, comillas
    invertidas ni mayusculas)."""
    def plano(t):
        return normalize_text(re.sub(r"[*_`]", "", t)).lower()
    path = os.path.join(memory_dir, "learnings", topic + ".md")
    try:
        with open(path, encoding="utf-8") as f:
            lineas = f.read().splitlines()
    except OSError:
        return None
    pp = plano(prefijo)
    hits = []
    for l in lineas:
        m = re.match(r"^\s*(\d+)\.\s+(.*)$", l)
        if m and pp and plano(m.group(2)).startswith(pp):
            hits.append(int(m.group(1)))
    return hits[0] if len(hits) == 1 else None


def una_linea(texto):
    """La nota del marcador vive en la linea de la regla (I2): sin saltos de linea."""
    return normalize_text(texto or "")


def learning_id(topic, text):
    raw = "\n".join([topic.strip(), normalize_text(text)])
    return "l-" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10]


# Limites de largo de lo que se escribe en los indices Tier 2 (p-206fd62e68, 2.63.47). Medido
# 2026-10-21: pendientes de mas de 800 caracteres por linea (75 de 217 abiertos), Quick Reference de
# ~440 por linea. Solo AVISAN —a stderr, el evento se escribe igual—: un rechazo romperia
# /backfill-3t (reemite pendientes viejos largos) y a los agentes con una plantilla de cierre
# anterior. Solo `--titulo` rechaza, y es un flag nuevo: nadie lo pasaba antes.
TITULO_MAX = 200
QUICKREF_MAX = 300
RESEARCH_TEMA_MAX = 200
RESEARCH_CAMPO_MAX = 300


def avisar_largo(campo, valor, tope, remedio):
    if len(valor) > tope:
        print(f"journal-emit: AVISO {campo} tiene {len(valor)} caracteres (tope recomendado "
              f"{tope}): {remedio}", file=sys.stderr)


def cell(text):
    """Texto apto para una celda de tabla markdown: una linea, `|` suelto escapado.

    Un `\\|` ya escrito por el agente (alias de wikilink, `[[a\\|b]]`) se respeta.
    """
    t = normalize_text(text)
    return re.sub(r"(?<!\\)\|", r"\\|", t)


def need(value, msg):
    v = normalize_text(value or "")
    if not v:
        sys.exit(f"journal-emit: {msg}")
    return v


def check_slug(value, what):
    v = (value or "").strip()
    if not SLUG_RE.match(v):
        sys.exit(f"journal-emit: {what} debe ser un slug (letras, digitos, . _ -), no '{v}'")
    return v


def check_date(value, what, default=None):
    v = (value or default or "").strip()
    if not DATE_RE.match(v):
        sys.exit(f"journal-emit: {what} debe ser YYYY-MM-DD")
    return v


# ----------------------------------------------------------------------------- escritura
def session_id():
    # CLAUDE_CODE_SESSION_ID (2.63.45, p-857fadfbd1): es la que exporta Claude Code a su Bash, con
    # el nombre del .jsonl de la sesion. Sin ella cada evento llevaba un uuid nuevo y el journal no
    # decia que sesion toco un pendiente. Va despues de las dos explicitas: quien las pone, manda.
    sid = (os.environ.get("CLAUDE_SESSION_ID") or os.environ.get("THREET_SESSION_ID")
           or os.environ.get("CLAUDE_CODE_SESSION_ID"))
    if sid:
        return re.sub(r"[^A-Za-z0-9_-]", "-", sid)[:64]
    return uuid.uuid4().hex


def agent_id():
    aid = os.environ.get("THREET_AGENT_ID")
    if aid:
        return aid[:64]
    try:
        host = socket.gethostname()
    except Exception:
        host = "host"
    return f"{os.environ.get('USER') or os.environ.get('USERNAME') or 'user'}@{host}"


def publicar(tmp, path):
    """Renombra el temporal al .json final. Reintenta ante PermissionError como
    replace_with_retry del compactador (Windows: antivirus o indexador con el archivo abierto un
    instante); otro error propaga. No puede pisar un evento ajeno: el destino lleva el mismo
    ts+session+pid+seq que el temporal, que se creo con O_EXCL."""
    for attempt in range(5):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            if attempt == 4:
                raise
            time.sleep(0.05 * (attempt + 1))


def write_event(memory_dir, event):
    """Crea pending/<utc-ns>-<session>-<pid>-<seq>.json entero de una vez. Devuelve la ruta.

    Se escribe en `pending/.<nombre>.tmp` (O_EXCL) y despues se renombra al .json: un
    compactador que lista pending/ solo ve el evento completo o no lo ve. Antes se creaba el
    .json con O_EXCL y se escribia despues; un compactador que lo leia en ese hueco lo
    encontraba vacio, lo mandaba a cuarentena `malformed` y el evento se perdia (p-4c4f8274a6:
    2 de 1000 trials de test-journal-race.sh, y una vez en macos-latest). El temporal queda en
    pending/ y no en otra carpeta porque el rename tiene que ser en el mismo sistema de archivos
    y porque .journal/.gitignore no se reescribe en instalaciones viejas: una carpeta nueva se
    versionaria. Ningun lector toma un `.tmp` (todos filtran `*.json`), y el compactador borra
    el de un emit que murio a medias (`limpiar_temporales`). Si borro el de un emit que solo
    estaba parado, el rename falla y el evento se reescribe con el seq siguiente.

    El nombre ya es unico por construccion (session_id completo + pid + seq). Si aun asi
    O_EXCL falla, se reintenta con seq+1 hasta MAX_EXCL_RETRIES; si se agota, el evento se
    guarda en failed/ con sufijo .err y se sale con 2 — el llamador lo reporta.
    """
    journal = os.path.join(memory_dir, ".journal")
    pending = os.path.join(journal, "pending")
    os.makedirs(pending, exist_ok=True)
    payload = json.dumps(event, ensure_ascii=False, indent=1)
    ts_ns = time.time_ns()
    sid = event["session_id"]
    pid = os.getpid()
    last_err = None
    for seq in range(MAX_EXCL_RETRIES):
        name = f"{ts_ns}-{sid}-{pid}-{seq}.json"
        path = os.path.join(pending, name)
        tmp = os.path.join(pending, f".{name}.tmp")
        if os.path.exists(path):
            last_err = FileExistsError(path)
            continue
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError as e:
            last_err = e
            continue
        # newline="\n": un evento del journal es un artefacto generado; sus bytes son los mismos
        # en cualquier sistema, y asi el hash de un evento no depende de donde se emitio.
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(payload)
        try:
            publicar(tmp, path)
        except FileNotFoundError as e:
            # El temporal ya no esta: este proceso quedo parado mas de STALE_SECONDS (una Mac que
            # se durmio a mitad) y un compactador lo tomo por huerfano y lo borro. Se reescribe
            # con el seq siguiente; agotados los intentos, la copia de failed/ de abajo.
            last_err = e
            continue
        return path
    failed = os.path.join(journal, "failed")
    os.makedirs(failed, exist_ok=True)
    fpath = os.path.join(failed, f"{ts_ns}-{sid}-{pid}.json.err")
    with open(fpath, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(payload)
        fh.write(f"\n# error: {last_err}\n")
    sys.stderr.write(f"journal-emit: no se pudo crear el evento tras {MAX_EXCL_RETRIES} "
                     f"intentos; copia en {fpath}\n")
    sys.exit(2)


# ----------------------------------------------------------------------------- lookup
def find_line_text(memory_dir, pid):
    """Texto de la linea con ese id en _pendientes.md (sin metadatos), o None."""
    path = os.path.join(memory_dir, "_pendientes.md")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("- [ ]") and f"_id: {pid}_" in s:
                    return strip_meta(s[5:].strip())
    except OSError:
        return None
    return None


RESEARCH_OPEN_RE = re.compile(r"^\[\[research/([^\]|\\]+)(?:\\\||\||\]\])")
CELL_SPLIT = re.compile(r"(?<!\\)\|")


def find_research_tema(memory_dir, slug):
    """Tema (celda 0) de la fila de _research-index.md cuya ULTIMA celda abre con
    `[[research/<slug>]]`, o None. Misma regla que `find_research_owned_row` del compactador para
    las tablas canonicas: una fila que solo CITA el research en otra celda no es suya."""
    path = os.path.join(memory_dir, "_research-index.md")
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if not s.startswith("|"):
                    continue
                s = s[1:]
                if s.endswith("|") and not s.endswith("\\|"):
                    s = s[:-1]
                cells = [c.strip() for c in CELL_SPLIT.split(s)]
                m = RESEARCH_OPEN_RE.match(cells[-1]) if cells else None
                if m and m.group(1) == slug and cells[0]:
                    return cells[0]
    except OSError:
        return None
    return None


def _compactador():
    """El modulo journal-compact.py de este mismo directorio. session.amend lee la fila con SU
    `session_owned_rows`, no con una copia: una copia divergia (leia filas `|` sueltas fuera de
    toda tabla, que el compactador no ve), y el valor viejo que emitia no era el de la fila que el
    compactador iba a corregir (adversario de 2.40.0)."""
    import importlib.util
    sys.dont_write_bytecode = True   # sin __pycache__ dentro del plugin instalado
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "journal-compact.py")
    spec = importlib.util.spec_from_file_location("journal_compact", ruta)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def find_session_cells(memory_dir, slug):
    """(Fecha, celda Sesion) de CADA fila de la sesion segun `session_owned_rows` del compactador
    ([] si no hay fila). Mas de un par distinto = filas duplicadas que no coinciden: el llamante se
    niega a emitir."""
    path = os.path.join(memory_dir, "_session-index.md")
    if not os.path.isfile(path):
        return []
    jc = _compactador()
    lines = jc.read_lines(path)
    out = []
    for i in jc.session_owned_rows(lines, slug):
        cells = jc.split_cells(lines[i])
        out.append((cells[0], cells[1]))
    return out


def fecha_real(v):
    """True solo si `v` es AAAA-MM-DD y una fecha del calendario. `re` valida la FORMA: `2026-99-99`
    la pasa, y los consumidores (`triage-scan.py`, `expire-pendientes.py`) revientan al parsearla
    (adversario, ronda 2, 2026-09-11). Y fromisoformat solo no basta: desde Python 3.11 acepta
    `20261016` y `2026-W42-5`, y un `--creado 20261016` atascaba el compactador (2.63.7)."""
    if not (isinstance(v, str) and FECHA_ISO_RE.fullmatch(v)):
        return False
    try:
        date.fromisoformat(v)
        return True
    except ValueError:
        return False


# 2.63.32: ventana de un bloqueado que nace sin fecha. Es la regla 2 de Step 3b de /checkpoint-3t
# ("en cualquier otro caso, 5 dias"), el mismo numero, para que dos agentes lleguen a la misma fecha.
DIAS_BLOQUEADO = 5


def revisar_por_defecto():
    return (date.today() + timedelta(days=DIAS_BLOQUEADO)).isoformat()


def limpiar_bloqueado(valor):
    """Texto de `_bloqueado: …_` en una sola linea y sin el separador de la cola de metadatos.

    Un `—` dentro del valor partiria la cola: los despojadores (`[^—]*`) cortarian ahi y el resto
    del valor se quedaria pegado al TEXTO del pendiente, cambiando su hash re-derivado. Un `_`
    final cerraria la cursiva antes de tiempo."""
    v = normalize_text(valor or "").replace("—", "-").strip().strip("_").strip()
    return v[:160]


# `_relacionado:` (2.55.0): ids de otros pendientes o slugs de plan, separados por `, `. Solo
# formas cerradas: el valor lo lee un script (print-pendiente-opcional.py), no una persona, y un
# texto libre ahi seria el regex-sobre-texto que la regla 216 prohibe.
RELACIONADO_RE = re.compile(r"^(?:p-[0-9a-f]{10}|plan-[A-Za-z0-9][A-Za-z0-9._-]{0,120})$")


def limpiar_relacionados(valores, propio=None):
    """Lista ordenada y sin duplicados de `--relacionado`; sale con error ante una forma invalida
    o ante el propio id (un pendiente relacionado consigo mismo no suma nada)."""
    out = []
    for v in valores or []:
        for parte in str(v).split(","):
            x = parte.strip()
            if not x:
                continue
            if not RELACIONADO_RE.match(x):
                sys.exit(f"journal-emit: --relacionado '{x}' debe ser p-<10 hex> o plan-<slug>")
            if x == propio:
                sys.exit(f"journal-emit: --relacionado no puede ser el propio id ({x})")
            if x not in out:
                out.append(x)
    return out


def paso_recibido(origen, memory_dir, transcript=None):
    """Pieza 1 del hilo (2.57.0, p-b282a8cfc4): los ids del `Proximo paso` que esta sesion recibio
    en su snippet `Retomamos:`. Un pendiente que nace aqui se liga a ellos solo, sin criterio del
    agente (decision de Victor, 2026-10-13: `_relacionado` estaba en 3 de 617 pendientes cuando
    dependia de que el agente lo pusiera).

    Fuente: el sello `hilo_paso` de la ficha de `--origen` (stamp-hilo.py) y, si no esta, la
    transcripcion: `--transcript`, o la de `CLAUDE_CODE_SESSION_ID`. Si no hay ninguna, [] y el
    pendiente nace como antes: nunca falla un `pendiente.add` por esto."""
    import importlib.util
    try:
        ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pendientes_afines.py")
        spec = importlib.util.spec_from_file_location("pendientes_afines", ruta)
        af = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(af)
        m = re.search(r"\[\[sessions/([^\]|]+)", origen or "")
        ficha = os.path.join(memory_dir, "sessions", m.group(1).strip() + ".md") if m else None
        # La transcripcion de la sesion en curso, solo si la ficha de --origen existe (Step 2 la
        # escribe antes de Step 3b) y puede ser de esa sesion (ficha_de_la_sesion): un
        # `pendiente.add` suelto, el de una ficha vieja (/backfill-3t) o el de una prueba corrida
        # dentro de una sesion de Claude Code no hereda el snippet de esa sesion.
        if not transcript and ficha and os.path.isfile(ficha):
            dirs = [os.environ.get("CLAUDE_PROJECT_DIR"), os.getcwd(),
                    os.path.dirname(os.path.abspath(memory_dir))]
            transcript = af.transcripcion_de(os.environ.get("CLAUDE_CODE_SESSION_ID", ""), dirs)
        # Venga de donde venga (tambien `--transcript`), la transcripcion solo cuenta si la ficha
        # puede ser de esa sesion. El id de la sesion es el nombre del `.jsonl`.
        if transcript and not af.ficha_de_la_sesion(
                ficha, transcript, os.path.splitext(os.path.basename(transcript))[0]):
            transcript = None
        return [x for x in af.paso_recibido_de(ficha, transcript) if RELACIONADO_RE.match(x)]
    except Exception as exc:   # la liga es un extra: un fallo aqui no pierde el evento
        print(f"journal-emit: aviso: no se pudo leer el paso recibido ({exc})", file=sys.stderr)
        return []


def strip_meta(text):
    # Las mismas claves que `META_RE` en repair-dualwrite.py, que re-deriva este hash para
    # detectar ids inventados. Si divergen, todo pendiente con la clave que falte se reporta
    # como id inventado. Si anades una clave aqui, anadela alli.
    text = re.sub(r"\s*—\s*_(?:origen|creado|id|revisar|actualizado|bloqueado|relacionado|retomar):[^—]*", "", text)
    return text.strip()


# ----------------------------------------------------------------------------- adopcion (2.58.0)
# Un pendiente sin `_id:` (escrito a mano, o anterior al journal) no lo encuentra ningun evento:
# update/resolve/expire/block/relate buscan `_id: p-…_` en la linea. `pendiente.adopt` le pone su
# id. El id es el CANONICO de la propia linea, sha1(texto+creado+origen) — el mismo que pone
# `enrich-memory.py --only id` y el mismo que `repair-dualwrite.ids_invented` re-deriva —, asi que
# ninguna herramienta lo ve como inventado y `--fix-ids` no lo renombra. Estas funciones las
# importa journal-compact.py: una sola definicion de como se lee la linea y como queda adoptada.
ID_CANONICO_RE = re.compile(r"_id: (p-[0-9a-f]{10})_")        # = journal-compact.ID_RE
# Un `_id: p-<10 hex>_` con otro espaciado (`_id:p-…_`, `_id:  p-…_`): es un id de verdad que
# repair-dualwrite y enrich ya reconocen (ID_RE con `\s*`) y find_id_line no. Se reespacia y se
# CONSERVA el id: puede estar citado. Cualquier otro `_id:` (8 hex, prosa) no se toca.
ID_MAL_ESPACIADO_RE = re.compile(r"_id:\s*(p-[0-9a-f]{10})_")
ORIGEN_LINK_RE = re.compile(r"_origen:\s*\[\[[^\]]+\]\]_")    # = enrich-memory.ORIGEN_RE
CREADO_LINEA_RE = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})")


def abierta_sin_id(line):
    """¿Es un `- [ ]` sin `_id: p-<10 hex>_`? Lo que find_id_line del compactador no encuentra."""
    return line.lstrip().startswith("- [ ]") and not ID_CANONICO_RE.search(line)


def datos_linea(line):
    """(texto, creado|None, origen) de una linea de Tier 2, leidos como los lee enrich-memory.

    El origen es solo el wikilink `[[...]]` (un `_origen:` que no es wikilink cuenta como vacio),
    igual que en `enrich_ids` y en `repair-dualwrite.ORIGEN_RE`: si este calculo divergiera de
    aquellos, el id adoptado saldria como inventado en `ids_invented`.
    """
    s = line.strip()
    text = strip_meta(s[5:])
    mc = CREADO_LINEA_RE.search(s)
    mo = ORIGEN_LINK_RE.search(s)
    origen = re.search(r"\[\[[^\]]+\]\]", mo.group(0)).group(0) if mo else ""
    return text, (mc.group(1) if mc else None), origen


def _enriquecedor():
    """El modulo enrich-memory.py vecino (para `linked_file_date`), o None."""
    import importlib.util
    sys.dont_write_bytecode = True
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "enrich-memory.py")
    if not os.path.isfile(ruta):
        return None
    try:
        spec = importlib.util.spec_from_file_location("enrich_memory", ruta)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


def creado_para(memory_dir, line, hoy):
    """La fecha `_creado` de una linea que no la tiene: `enrich-memory.derivar_creado` (slug de
    `_origen`, o `date:` del fichero al que enlaza) y si no, el mtime de `_pendientes.md` con la
    misma funcion de enrich. Es LA MISMA derivacion que `enrich-memory.py --only creado`, llamada,
    no copiada. `hoy` solo si enrich-memory.py no esta al lado.

    Hace falta ESCRIBIRLA al adoptar, no solo usarla para el hash: si la linea quedara sin
    `_creado`, un enrich posterior le pondria uno, el texto+creado+origen de la linea ya no daria
    el id adoptado, `ids_invented` lo contaria y `--fix-ids --apply` lo renombraria — rompiendo
    las citas del id, que es justo lo que adoptarlo viene a permitir.
    """
    enr = _enriquecedor()
    if enr is None:
        return hoy
    mo = enr.ORIGEN_RE.search(line)
    d = enr.derivar_creado(memory_dir, mo.group(1)) if mo else None
    return d or enr.mtime_date(os.path.join(memory_dir, "_pendientes.md"))


def linea_adoptada(line, pid, creado_nuevo=""):
    """La linea con su `_id:` (y su `_creado:` si le faltaba), byte a byte como la dejaria
    `enrich-memory.py --only creado,id`: el creado va justo detras del `_origen:` (o al final si no
    hay), y el id al final. No se borra nada de la linea: un `_id:` que no es canonico (`p-1234abcd`,
    prosa) se queda donde esta, como lo deja enrich, y sigue a la vista quien lo cite."""
    out = line.rstrip("\r\n")
    if creado_nuevo:
        campo = f" — _creado: {creado_nuevo}_"
        mo = ORIGEN_LINK_RE.search(out)
        out = out[:mo.end()] + campo + out[mo.end():] if mo else out + campo
    return out.rstrip() + f" — _id: {pid}_"


def reespaciar_id(line):
    """(linea, id) si la linea lleva un `_id: p-<10 hex>_` mal espaciado; si no, None."""
    m = ID_MAL_ESPACIADO_RE.search(line)
    if not m or ID_CANONICO_RE.search(line):
        return None
    return line[:m.start()] + f"_id: {m.group(1)}_" + line[m.end():], m.group(1)


def id_de_adopcion(line, creado_nuevo=""):
    """El id canonico que recibe la linea al adoptarla (None si no hay creado de donde sacarlo).

    Se lee de la linea YA con su `_creado:` insertado, como lo lee enrich (su pasada de id corre
    sobre lo que dejo la de creado): si el `_origen:` no va detras de una raya (`- [ ] _origen:
    [[…]]_ texto`), el `— _creado: …_` insertado se lleva como metadato el texto que le sigue, y
    hashear la linea original daria otro id que el de enrich."""
    if creado_nuevo:
        line = linea_adoptada(line, "x", creado_nuevo).rsplit(" — _id: x_", 1)[0]
    text, creado, origen = datos_linea(line)
    if not creado:
        return None
    return pendiente_id(text, creado, origen)


def _triage():
    """bin/triage-scan.py, para reconocer su id sintetico `sin-id-<hash>[-N]`, o None."""
    import importlib.util
    sys.dont_write_bytecode = True
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "triage-scan.py")
    try:
        spec = importlib.util.spec_from_file_location("triage_scan", ruta)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


SIN_ID_RE = re.compile(r"^(sin-id-[0-9a-f]{10})(?:-(\d+))?$")   # = el cursor de triage-scan


def candidatas_adopt(memory_dir, a, hoy):
    """[(linea, id, creado_nuevo)] que el selector elige, y los ids canonicos que ya viven.

    El selector se resuelve AQUI, contra el fichero de ahora, y el evento lleva la linea VERBATIM:
    el compactador solo casa por esa linea, nunca por posicion. Importa por el sufijo `-N` del id
    de triage, que es posicional: adoptar `sin-id-X` convierte `sin-id-X-2` en `sin-id-X`.
    """
    path = os.path.join(memory_dir, "_pendientes.md")
    try:
        with open(path, encoding="utf-8") as fh:
            lineas = fh.read().split("\n")
    except OSError:
        sys.exit(f"journal-emit: no existe {path}")
    vivos = {m.group(1) for ln in lineas for m in [ID_CANONICO_RE.search(ln)]
             if m and ln.lstrip().startswith("- [ ]")}
    sin_id = [ln for ln in lineas if abierta_sin_id(ln)]

    if a.todas:
        elegidas = sin_id
    elif a.line is not None:
        elegidas = [ln for ln in sin_id if ln.strip() == a.line.strip()]
        if not elegidas and any(ln.strip() == a.line.strip() for ln in lineas):
            m = ID_CANONICO_RE.search(a.line)
            if m:
                print(m.group(1))      # ya adoptada: nada que hacer
                sys.exit(0)
    elif a.id:
        m = SIN_ID_RE.match(a.id.strip())
        if not m:
            sys.exit("journal-emit: pendiente.adopt --id acepta el id sintetico de /triage-3t "
                     "(sin-id-<10 hex>[-N]); un p-… ya esta adoptado")
        tri = _triage()
        if tri is None:
            sys.exit("journal-emit: no encuentro triage-scan.py junto a este script")
        n_pedido = int(m.group(2) or 1)
        vistos, elegidas = 0, []
        for ln in sin_id:
            texto = re.sub(r"\s+", " ", tri.META.sub("", ln.strip()[5:].strip()))
            if tri.sintetico(texto) == m.group(1):
                vistos += 1
                if vistos == n_pedido:
                    elegidas = [ln]
                    break
    elif a.text_prefix:
        pref = normalize_text(a.text_prefix)
        elegidas = [ln for ln in sin_id if normalize_text(datos_linea(ln)[0]).startswith(pref)]
    else:
        sys.exit("journal-emit: pendiente.adopt necesita --line \"<linea>\", --text-prefix P, "
                 "--id sin-id-… o --todas")

    out = []
    for ln in elegidas:
        r = reespaciar_id(ln)
        if r:                    # ya tiene id, mal espaciado: se conserva, sin _creado nuevo
            out.append((ln.rstrip("\r"), r[1], ""))
            continue
        _t, creado, _o = datos_linea(ln)
        nuevo = "" if creado else creado_para(memory_dir, ln, hoy)
        out.append((ln.rstrip("\r"), id_de_adopcion(ln, nuevo), nuevo))
    return out, vivos


# ----------------------------------------------------------------------------- main
def memory_dir_de(a):
    """El memory/ que este proceso va a usar, para poder mirar si el origen existe."""
    try:
        return resolve_memory_dir(a.memory_dir)
    except Exception:
        return None


def avisar_origen_colgante(origen, mem):
    """Avisa —no bloquea— si --origen apunta a un session file que no existe todavia.

    El orden de /checkpoint-3t es Step 2 (escribir el session file) y DESPUES Step 3 (emitir los
    pendientes), asi que en el flujo normal el fichero ya esta y esto no dispara nunca. Dispara
    cuando alguien emite un pendiente a media sesion con un slug inventado: el enlace de Tier 2
    queda colgando y `check-wikilinks.py` lo delata despues, si alguien lo corre.

    Paso en esta sesion, dos veces con dos slugs distintos, y lo encontro otro agente leyendo el
    indice — no una prueba. Avisa y NO bloquea a proposito: emitir antes de escribir es raro pero
    legitimo si el checkpoint llega luego, y un exit aqui perderia el evento.

    Cubre los tres sitios donde se nombra una sesion: `pendiente.add --origen`,
    `research.upsert --origen` y `plan.upsert --sesion`. Los tres, porque los tres enlaces rotos
    mas viejos de este repo son de PLANES apuntando a sesiones que nunca se escribieron.
    """
    m = re.match(r"^\[\[sessions/([^\]|]+?)(\|[^\]]*)?\]\]$", (origen or "").strip())
    if not m or not mem:
        return
    if not os.path.isfile(os.path.join(mem, "sessions", m.group(1) + ".md")):
        print(f"journal-emit: AVISO — el origen [[sessions/{m.group(1)}]] no existe todavia en "
              f"{os.path.join(mem, 'sessions')}. Si no lo escribes en el checkpoint, el enlace de "
              f"Tier 2 queda roto.", file=sys.stderr)


REFS_SOLAPE = re.compile(r"(?:[\w.-]+/)*[\w.-]+\.(?:md|php|py|sh|js|ts|sql|json|ya?ml)\b|\bplan-[a-z0-9][a-z0-9-]*", re.I)
REFS_GENERICAS = {"readme.md", "changelog.md", "claude.md", "skill.md", "memory.md", "package.json"}


def refs_de_solape(texto):
    """Referencias EXPLICITAS de un texto: un `plan-<slug>`, un handoff/plan/research `.md`, o un
    fichero de codigo/datos. Es lo unico que compara el aviso de solape (regla 216: nunca palabras).
    Se comparan por su ultimo segmento (`module.php`, `PROMPT_x.md`), en minusculas."""
    out = set()
    for m in REFS_SOLAPE.findall(texto or ""):
        base = m.rstrip(".").split("/")[-1].lower()
        if base.startswith("_") or base in REFS_GENERICAS:
            continue
        if base.endswith(".md") and not re.search(r"(?:handoffs|plans|research)/", m, re.I) \
                and not base.startswith(("plan-", "prompt")):
            continue
        out.add(base[:-3] if base.endswith(".md") and base.startswith("plan-") else base)
    return out


def avisar_solape_pendiente(texto, pid, mem, relacionado=()):
    """Avisa —no bloquea— si el pendiente nuevo cita una referencia explicita (un plan, un handoff,
    un fichero) que ya tiene un plan `active` o `proposed` (no cerrado) o un pendiente abierto (2.64.0).

    Caso que lo motivo (otro proyecto, 2026-10-24): un pendiente nuevo se guardo aunque otro
    pendiente ya encargaba trabajo del mismo asunto. OJO, medido por el
    revisor: ese par NO compartia ninguna referencia explicita (el duplicado citaba el handoff, el nuevo
    un fichero) y el plan estaba `proposed`; este aviso no lo habria visto. Mira solo referencias
    explicitas, nunca palabras (regla 216); un solape sin referencia compartida no se ve. Falla abierto."""
    try:
        refs = refs_de_solape(texto)
        if not refs or not mem:
            return
        hallazgos = []
        carpeta = os.path.join(mem, "plans")
        if os.path.isdir(carpeta):
            indice = ""
            if os.path.isfile(os.path.join(mem, "_plans-index.md")):
                indice = open(os.path.join(mem, "_plans-index.md"), encoding="utf-8").read()
            for f in sorted(os.listdir(carpeta)):
                nombre = f[:-3]
                if not f.endswith(".md") or nombre.lower() not in refs:
                    continue
                fila = re.search(r"\[\[plans/" + re.escape(nombre) + r"(?:\|[^\]]*)?\]\]\s*\|\s*([^|]*)\|", indice)
                if fila:
                    activo = fila.group(1).strip().lower().startswith(("active", "proposed"))
                else:
                    cabeza = open(os.path.join(carpeta, f), encoding="utf-8").read(2000)
                    activo = bool(re.search(r"^status:\s*(?:active|proposed)\b", cabeza, re.M | re.I))
                if activo:
                    hallazgos.append(f"el plan abierto {nombre}")
        ruta = os.path.join(mem, "_pendientes.md")
        if os.path.isfile(ruta):
            for l in open(ruta, encoding="utf-8"):
                if not l.lstrip().startswith("- [ ]"):
                    continue
                m = re.search(r"_id:\s*(p-[0-9a-f]{10})", l)
                if not m or m.group(1) == pid or m.group(1) in relacionado:
                    continue
                comun = refs & refs_de_solape(l)
                if comun:
                    hallazgos.append(f"el pendiente abierto {m.group(1)} ({', '.join(sorted(comun))})")
        if hallazgos:
            print("journal-emit: AVISO — este pendiente cita lo mismo que " + "; ".join(hallazgos[:4])
                  + ". Si es el mismo trabajo, no lo dupliques: `pendiente.update` sobre el existente "
                  "o `--relacionado`. Si es otro, sigue.", file=sys.stderr)
    except Exception:
        return


def prefijo_de_regla(memory_dir, topic, n):
    """Las primeras palabras (hasta ~40 caracteres) de la regla #n viva de un topic, o None.

    Es el --match-prefix con el que learning.update la encuentra: texto de HOY, sin marcador."""
    import learning_marks
    try:
        with open(os.path.join(memory_dir, "learnings", topic + ".md"), encoding="utf-8") as f:
            lineas = f.read().splitlines()
    except OSError:
        return None
    hits = [m.group(2) for l in lineas for m in [re.match(r"^\s*(\d+)\.\s+(.*)$", l)]
            if m and int(m.group(1)) == n]
    if len(hits) != 1:
        return None
    t = normalize_text(learning_marks.sin_marca(hits[0]))
    if len(t) <= 40:
        return t
    corte = t.rfind(" ", 0, 40)
    return t[: corte if corte > 10 else 40]


def decision_de(valor, supersedes_raw, sup, memory_dir="", topic=""):
    """`--decision` de learning.add como `nueva` o `reemplaza:N`, o None si no se paso.

    `--supersedes N` sin `--decision` cuenta como `reemplaza:N`: ya es una decision. `corrige:N`
    no escribe una regla nueva: una regla que "corrige" a otra que sigue viva es el patron que
    deja las dos en el recall (H11 del plan de ciclo de vida); la correccion es learning.update."""
    v = (valor or "").strip().lower().replace(" ", "")
    if not v:
        return f"reemplaza:{sup}" if sup else None
    if v == "nueva":
        if sup:
            sys.exit("journal-emit: --decision nueva con --supersedes se contradicen: la regla que "
                     f"reemplaza a #{sup} es --decision reemplaza:{sup}")
        return "nueva"
    m = re.match(r"^(reemplaza|corrige):#?(\d+)$", v)
    if not m or int(m.group(2)) < 1:
        sys.exit(f"journal-emit: --decision debe ser nueva, reemplaza:N o corrige:N, no {valor!r}")
    n = int(m.group(2))
    if m.group(1) == "corrige":
        import shlex
        pref = prefijo_de_regla(memory_dir, topic, n) if memory_dir and topic else None
        # Copiable tal cual: cada valor citado para el shell (un prefijo puede llevar comillas) y
        # --memory-dir explicito, el directorio contra el que se calculo el prefijo (sin el, el
        # comando resolveria memory/ desde el cwd de quien lo pegue).
        cmd = (f"python3 {shlex.quote(os.path.abspath(__file__))} --memory-dir "
               f"{shlex.quote(memory_dir)} --type learning.update --topic {shlex.quote(topic)} "
               f"--match-prefix {shlex.quote(pref)} --text "
               f"{shlex.quote(f'<texto corregido de la #{n}>')}") if pref else None
        sys.exit(f"journal-emit: --decision corrige:{n} no se emite como learning.add: una regla "
                 f"nueva que corrige a otra viva deja las dos en el recall. Corregir la #{n} es "
                 f"learning.update, que conserva su numero:\n  "
                 + (cmd or f"(learnings/{topic}.md no tiene una sola regla #{n} viva: mira el "
                           f"numero; el comando es --type learning.update --topic {topic} "
                           f"--match-prefix \"<principio de la regla>\" --text \"<texto>\")"))
    if sup and sup != n:
        sys.exit(f"journal-emit: --decision reemplaza:{n} y --supersedes {supersedes_raw} no "
                 f"nombran la misma regla")
    return f"reemplaza:{n}"


EJEMPLO_DISPARADORES = ('--disparadores "frases=ya termine la rama y limpio el worktree | git '
                        'worktree remove se queja de cambios | cleanup de carpetas viejas; '
                        'cmd=git worktree remove; tool=Bash"')


def disparadores_arg(valor, text):
    """--disparadores validado (F4), o "" si no se paso. Sale con error si no vale: un comentario
    roto en la linea de la regla no lo leeria nadie, y el error tiene que salir aqui, donde la
    persona lo puede corregir (el compactador lo mandaria a cuarentena)."""
    import learning_marks
    if text and learning_marks.sufijo_disparadores(text):
        sys.exit("journal-emit: el comentario de disparadores no va pegado a --text: pasalo con "
                 "--disparadores (sin <!-- -->).")
    if valor is None:
        return ""
    v = " ".join(valor.split())
    malos = learning_marks.problemas_disparadores(v)
    if malos:
        sys.exit("journal-emit: --disparadores no vale:\n  - " + "\n  - ".join(malos)
                 + f"\nForma: {EJEMPLO_DISPARADORES}\n(frases: {learning_marks.FRASES_MIN}-"
                 f"{learning_marks.FRASES_MAX}, separadas por '|'; cmd, path y tool opcionales, "
                 f"separados por ','; sin '--' ni '<' '>': un flag largo no hace falta, cmd es un "
                 f"prefijo)")
    return v


def dedup_al_emitir(memory_dir, topic, text, decision, solo_vecinos):
    """Dedup de learning.add (2.47.0): chequeo de forma y vecinos de la regla nueva, por STDERR.

    stdout no cambia (sigue siendo solo el id: las plantillas lo capturan). Sale con error, antes
    de escribir el evento, si la forma esta mal o si un vecino llega a UMBRAL sin --decision. Con
    --solo-vecinos imprime lo mismo y no escribe nada (el paso 0 del Step 4 del checkpoint)."""
    import learning_vecinos as lv

    forma = lv.problemas_de_forma(text)
    if forma and not solo_vecinos:
        sys.exit("journal-emit: la regla nueva tiene problemas de forma:\n  - " + "\n  - ".join(forma)
                 + "\nForma: --text \"**<Titulo>** — <cuerpo en una linea>\"")
    for f in forma:
        print(f"journal-emit: AVISO de forma — {f}", file=sys.stderr)
    tpath = os.path.join(memory_dir, "learnings", topic + ".md")
    try:
        with open(tpath, encoding="utf-8") as fh:
            contenido = fh.read()
    except OSError:
        print(f"journal-emit: learnings/{topic}.md no existe todavia: la regla no tiene vecinos.",
              file=sys.stderr)
        return
    # La identidad es topic + texto exacto, la misma comparacion que el compactador
    # (es_misma_regla, retirada o no): el mismo texto otra vez no se escribe dos veces, asi que no
    # es un duplicado que decidir — y daria parecido 1,0.
    jc = _compactador()
    lineas = contenido.splitlines()
    ini, fin = jc.body_region(lineas)
    for l in lineas[ini:fin]:
        n, t = jc.rule_text(l)
        if t and jc.es_misma_regla(t, text):
            print(f"journal-emit: learnings/{topic}.md ya tiene esta regla con el mismo texto"
                  f"{f' (#{n})' if n else ''}: el compactador no la escribe otra vez.",
                  file=sys.stderr)
            return
    cand = [(f"#{n}" if n else "-", t) for n, t in lv.reglas_de(contenido)]
    vec = lv.vecinos(text, cand)
    print(f"journal-emit: vecinos de la regla nueva en learnings/{topic}.md (parecido Dice-IDF "
          f"0-1; con {lv.UMBRAL} o mas hace falta --decision):", file=sys.stderr)
    if not vec:
        print("  (ninguna regla viva en el topic)", file=sys.stderr)
    for s, e, t in vec:
        print(f"  {e:>5}  {s:.2f}  {lv.titulo(t)}", file=sys.stderr)
    if vec and vec[0][0] >= lv.UMBRAL and not decision and not solo_vecinos:
        sys.exit(f"journal-emit: la regla nueva se parece mucho a {vec[0][1]} ({vec[0][0]:.2f} >= "
                 f"{lv.UMBRAL}). Lee los vecinos de arriba y decide:\n"
                 f"  - es la misma leccion → no emitas nada (`ya existe {vec[0][1]}` en la ficha);\n"
                 f"  - {vec[0][1]} quedo incompleta o falsa → learning.update de esa regla;\n"
                 f"  - la nueva sustituye a {vec[0][1]} → --decision reemplaza:{vec[0][1][1:]};\n"
                 f"  - es otra leccion → --decision nueva.")


# Los flags (dest de argparse) que lee cada tipo, ademas de --type, --memory-dir y --session. Un
# flag de fuera salia rc=0 y se perdia sin avisar: 926 combinaciones tipo x flag en 2.62.10
# (p-7ae84c8ef2, research/flags-sin-lector-journal-emit). Uno que el tipo lee solo en ciertos casos
# va dentro, y su rama dice si sobra (p. ej. --quickref-prefix sin --supersedes en learning.add);
# por eso pendiente.update lleva `nota`: la rechaza su rama, con su mensaje. Un flag nuevo del
# parser que no este en ninguna fila sale con error en todos los tipos. Recoge el rechazo de --nota de
# 2.62.10 (NOTA_LECTORES): leen --nota resolve, learning.retire y learning.add --supersedes.
FLAGS_DE = {
    "pendiente.add": {"text", "prioridad", "origen", "creado", "revisar", "bloqueado_por",
                      "relacionado", "transcript", "titulo"},
    "pendiente.resolve": {"id", "estado", "sesion", "nota", "text_prefix"},
    "pendiente.update": {"id", "text", "prioridad", "text_prefix", "nota"},
    "pendiente.expire": {"id", "dias", "prioridad", "line"},
    "pendiente.reopen": {"id", "prioridad"},
    "pendiente.window": {"id", "revisar"},
    "pendiente.retomar": {"id", "retomar", "ficha", "quitar"},
    "pendiente.block": {"id", "bloqueado_por", "desbloquear", "revisar"},
    "pendiente.relate": {"id", "relacionado", "sin_relacion"},
    "pendiente.adopt": {"todas", "line", "id", "text_prefix", "colapsar"},
    "session.add": {"slug", "date", "status", "summary", "commit"},
    "session.amend": {"slug", "date", "alias", "fecha_vieja", "sesion_vieja"},
    "learning.add": {"topic", "text", "section", "quickref", "title", "when", "importance",
                     "disparadores", "sin_disparadores", "supersedes", "decision", "solo_vecinos",
                     "quickref_prefix", "nota"},
    "learning.update": {"topic", "text", "quickref", "match_prefix", "quickref_prefix", "title",
                        "when", "disparadores", "sin_disparadores", "quickref_regla",
                        "last_verified"},
    "learning.retire": {"topic", "match_prefix", "motivo", "por", "nota", "quickref_prefix"},
    "learning.patch": {"topic", "match_prefix", "quickref_prefix", "viejo", "nuevo"},
    "plan.upsert": {"slug", "parent", "inline", "promote", "title", "status", "date", "sesion",
                    "pendientes", "learnings"},
    "plan.reopen": {"slug", "title"},
    "research.upsert": {"slug", "status", "tema", "date", "next_step", "resultado", "origen",
                        "inline"},
    "research.rename": {"slug", "tema", "tema_viejo"},
}
FLAGS_COMUNES = {"type", "memory_dir", "session"}


def flags_pasados(ap, argv=None):
    """Los dest de los flags que llegaron en la linea de comandos.

    Se mira con el propio parser y no con sys.argv a mano: argparse acepta abreviaturas (`--motiv`
    es `--motivo`) y `--flag=valor`. Con todos los default en SUPPRESS, el namespace solo trae lo
    que se paso; despues se devuelven los default."""
    viejos = [(act, act.default) for act in ap._actions]
    try:
        for act, _ in viejos:
            act.default = argparse.SUPPRESS
        return set(vars(ap.parse_args(argv)))
    finally:
        for act, d in viejos:
            act.default = d


def main():
    ap = argparse.ArgumentParser(description="Emite un evento al journal de memory/.")
    ap.add_argument("--type", required=True,
                    choices=["pendiente.add", "pendiente.resolve", "pendiente.update",
                             "pendiente.expire", "pendiente.reopen", "pendiente.window",
                             "pendiente.retomar",
                             "pendiente.block", "pendiente.relate", "pendiente.adopt",
                             "session.add", "session.amend",
                             "learning.add", "learning.update", "learning.retire",
                             "learning.patch",
                             "plan.upsert", "plan.reopen", "research.upsert",
                             "research.rename"])
    ap.add_argument("--memory-dir")
    ap.add_argument("--session")
    # pendiente.add
    ap.add_argument("--text")
    ap.add_argument("--titulo")                           # pendiente.add (2.63.47, p-206fd62e68)
    ap.add_argument("--prioridad")
    ap.add_argument("--origen")
    ap.add_argument("--creado")
    ap.add_argument("--revisar")
    ap.add_argument("--retomar")                          # pendiente.retomar (2.62.8)
    ap.add_argument("--ficha")                            # pendiente.retomar
    ap.add_argument("--quitar", action="store_true")      # pendiente.retomar (2.63.42)
    ap.add_argument("--bloqueado-por", dest="bloqueado_por",
                    help="que espera, FUERA de la sesion (otra instalacion, un peer, un PR ajeno); "
                         "nunca una decision del usuario, que va en el Proximo paso")
    ap.add_argument("--desbloquear", action="store_true")
    ap.add_argument("--relacionado", action="append", default=[])   # pendiente.add / .relate
    ap.add_argument("--sin-relacion", dest="sin_relacion", action="store_true")
    ap.add_argument("--transcript")   # pendiente.add: de donde leer el paso recibido (2.57.0)
    ap.add_argument("--todas", action="store_true")        # pendiente.adopt (2.58.0)
    ap.add_argument("--colapsar", action="store_true")     # pendiente.adopt
    # pendiente.resolve
    ap.add_argument("--id")
    ap.add_argument("--estado")
    ap.add_argument("--sesion", default="")
    ap.add_argument("--nota", default=None)   # None = no se paso; pendiente.update lo distingue de ""
    ap.add_argument("--text-prefix")
    # pendiente.expire / pendiente.reopen
    ap.add_argument("--dias")
    ap.add_argument("--line")
    # session.add / plan.upsert / research.upsert
    ap.add_argument("--slug")
    ap.add_argument("--date")
    ap.add_argument("--status")
    ap.add_argument("--summary")
    ap.add_argument("--commit", default="")
    ap.add_argument("--title")
    ap.add_argument("--pendientes", default="")
    ap.add_argument("--learnings", default="")
    ap.add_argument("--inline", action="store_true")
    ap.add_argument("--promote", action="store_true")
    ap.add_argument("--parent")
    ap.add_argument("--tema")
    ap.add_argument("--tema-viejo", dest="tema_viejo")   # research.rename
    ap.add_argument("--alias")                             # session.amend
    ap.add_argument("--fecha-vieja", dest="fecha_vieja")
    ap.add_argument("--sesion-vieja", dest="sesion_vieja")
    ap.add_argument("--next-step", default="")
    ap.add_argument("--resultado", default="")
    # learning.add
    ap.add_argument("--topic")
    ap.add_argument("--section", default="")
    ap.add_argument("--quickref", default="")
    # learning.update: anclas de prefijo (un learning no tiene id que citar)
    ap.add_argument("--match-prefix", default="")
    ap.add_argument("--quickref-prefix", default="")
    ap.add_argument("--when", default="")
    ap.add_argument("--importance", default="")
    # learning.retire / learning.add --supersedes (2.45.0)
    ap.add_argument("--motivo", default="")
    ap.add_argument("--por", default="")
    ap.add_argument("--supersedes", default="")
    # learning.add: dedup al emitir (2.47.0)
    ap.add_argument("--decision", default="")
    ap.add_argument("--solo-vecinos", dest="solo_vecinos", action="store_true")
    # learning.add / learning.update: disparadores (F4, 2.48.0)
    ap.add_argument("--disparadores", default=None)
    # learning.update: quitar el comentario de disparadores entero (2.60.2)
    ap.add_argument("--sin-disparadores", dest="sin_disparadores", action="store_true")
    # learning.update: fecha de la ultima revision del topic (F6, 2.50.0)
    ap.add_argument("--last-verified", dest="last_verified", default="")
    # learning.update: enlace Quick Reference -> regla (F7, 2.51.0)
    ap.add_argument("--quickref-regla", dest="quickref_regla", default="")
    # learning.patch: trozo literal de la primera linea de una regla (2.69.0)
    ap.add_argument("--viejo", default=None)
    ap.add_argument("--nuevo", default=None)
    pasados = flags_pasados(ap)
    a = ap.parse_args()

    # Un flag que el tipo no lee se descartaba sin avisar y quien lo paso creia haberlo dejado
    # escrito: --nota primero (p-3bf672997c, p-a37851219c), luego 926 combinaciones (p-7ae84c8ef2).
    # Cuenta haberlo pasado, no su valor: `--nota ""` tambien esperaba guardar algo.
    sobran = sorted(pasados - FLAGS_COMUNES - FLAGS_DE[a.type])
    if sobran:
        opc = {act.dest: act.option_strings[0] for act in ap._actions if act.option_strings}
        nota = (f" {a.type} no guarda --nota: solo la guardan pendiente.resolve, learning.retire y "
                "learning.add --supersedes; si la nota describe lo que emites, metela en el --text."
                if "nota" in sobran else "")
        sys.exit(f"journal-emit: {a.type} no lee {', '.join(opc[d] for d in sobran)}: el evento no "
                 f"tiene donde guardarlo y se perderia sin avisar. Quitalo, o usa el tipo que lo lee. "
                 f"{a.type} lee: {' '.join(sorted(opc[d] for d in FLAGS_DE[a.type]))}.{nota}")

    memory_dir = resolve_memory_dir(a.memory_dir)
    if not os.path.isdir(memory_dir):
        sys.exit(f"journal-emit: no existe el directorio de memoria: {memory_dir}")

    sid = re.sub(r"[^A-Za-z0-9_-]", "-", a.session)[:64] if a.session else session_id()
    base = {
        "v": SCHEMA_VERSION,
        "type": a.type,
        "ts": time.time_ns(),
        "session_id": sid,
        "agent_id": agent_id(),
    }

    if a.type == "pendiente.add":
        text = normalize_text(a.text or "")
        if not text:
            sys.exit("journal-emit: pendiente.add necesita --text")
        # 2.63.47 (p-206fd62e68): con --titulo, Tier 2 lleva SOLO el titulo y el --text completo va
        # a la fila mensual (Tier 3) como `detalle`. El id es el hash del TITULO, o sea del texto
        # visible de la linea de Tier 2: `repair-dualwrite.ids_invented` rehashea esa linea y un id
        # calculado sobre el detalle saldria como inventado en cada pendiente con titulo (regla 143).
        detalle = ""
        titulo = normalize_text(a.titulo or "")
        if a.titulo is not None and not titulo:
            sys.exit("journal-emit: --titulo no puede ir vacio")
        if titulo:
            if len(titulo) > TITULO_MAX:
                sys.exit(f"journal-emit: --titulo de {len(titulo)} caracteres; el maximo es "
                         f"{TITULO_MAX}. Resumelo: el detalle va en --text")
            if titulo != text:
                detalle, text = text, titulo
        else:
            avisar_largo("pendiente.add --text", text, TITULO_MAX,
                         "pasa --titulo \"<resumen corto>\" y deja este texto como detalle (Tier 3)")
        prio = (a.prioridad or "").strip().capitalize()
        if prio not in PRIORIDADES:
            sys.exit(f"journal-emit: --prioridad debe ser una de {PRIORIDADES}")
        origen = normalize_text(a.origen or "")
        if not origen:
            sys.exit("journal-emit: pendiente.add necesita --origen (p. ej. [[sessions/...]])")
        avisar_origen_colgante(origen, memory_dir_de(a))
        creado = (a.creado or date.today().isoformat()).strip()
        if not fecha_real(creado):
            sys.exit("journal-emit: --creado debe ser una fecha real YYYY-MM-DD")
        revisar = (a.revisar or "").strip()
        if revisar and not fecha_real(revisar):
            sys.exit("journal-emit: --revisar debe ser una fecha real YYYY-MM-DD")
        # `revisar` NO entra en el hash: es la ventana, no la identidad. Anadirla cambiaria el id
        # de un pendiente que ya existe y el compactador lo veria como uno nuevo.
        pid = pendiente_id(text, creado, origen)
        avisar_solape_pendiente(text, pid, memory_dir_de(a), a.relacionado)
        # `bloqueado` tampoco entra en el hash, por lo mismo que `revisar`: es un estado del
        # pendiente, no su identidad.
        bloqueado = limpiar_bloqueado(a.bloqueado_por)
        # 2.63.32: un bloqueado sin ventana no volvia a salir en ningun cierre (ni recordatorio, ni
        # hilo, ni `Proximo paso`). La ventana por defecto es la regla 2 de Step 3b (5 dias).
        if bloqueado and not revisar:
            revisar = revisar_por_defecto()
            print(f"journal-emit: bloqueado sin --revisar: ventana por defecto {revisar} "
                  f"(hoy+{DIAS_BLOQUEADO})", file=sys.stderr)
        # `relacionado` tampoco: es un enlace, no la identidad.
        relacionado = limpiar_relacionados(a.relacionado, pid)
        # Pieza 1 del hilo: se suma el paso recibido a lo que el agente haya pasado.
        auto = [x for x in paso_recibido(origen, memory_dir, a.transcript)
                if x != pid and x not in relacionado]
        if auto:
            relacionado += auto
            print("journal-emit: ligado al paso recibido: " + ", ".join(auto), file=sys.stderr)
        base["payload"] = {"id": pid, "text": text, "prioridad": prio,
                           "origen": origen, "creado": creado, "revisar": revisar}
        if detalle:
            base["payload"]["detalle"] = detalle
        if bloqueado:
            base["payload"]["bloqueado"] = bloqueado
        if relacionado:
            base["payload"]["relacionado"] = relacionado
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type == "session.add":
        slug = check_slug(a.slug, "--slug")
        base["payload"] = {
            "slug": slug,
            "date": check_date(a.date, "--date", default=slug[:10]),
            "status": cell(a.status or ""),
            "summary": cell(a.summary or ""),
            "commit": cell(a.commit or ""),
        }
        if not base["payload"]["status"] and not base["payload"]["summary"] \
                and not base["payload"]["commit"]:
            sys.exit("journal-emit: session.add necesita --status, --summary o --commit")
        write_event(memory_dir, base)
        print(f"s-{slug}")
        return

    if a.type == "session.amend":
        slug = check_slug(a.slug, "--slug")
        # Sin --date no hay campo date: NO se toma slug[:10] por defecto como en session.add. Un
        # amend solo de alias que trajera la fecha del slug desharia un amend de fecha anterior.
        fecha = (a.date or "").strip()
        alias = normalize_text(a.alias or "")
        if not fecha and not alias:
            sys.exit("journal-emit: session.amend necesita --date o --alias")
        if fecha and not (DATE_RE.match(fecha) and fecha_real(fecha)):
            sys.exit("journal-emit: --date debe ser una fecha real YYYY-MM-DD")
        if alias and re.search(r"[|\[\]\\]", alias):
            sys.exit("journal-emit: --alias no puede llevar '|', '[', ']' ni '\\'")
        vivas = find_session_cells(memory_dir, slug)
        fechas = {f for f, _ in vivas}
        sesiones = {c for _, c in vivas}
        if (fecha and a.fecha_vieja is None and len(fechas) > 1) or \
                (alias and a.sesion_vieja is None and len(sesiones) > 1):
            sys.exit(f"journal-emit: sessions/{slug} tiene {len(vivas)} filas que no dicen lo mismo "
                     f"en _session-index.md. Emite antes un session.add de esa sesion (p. ej. "
                     f"--status con el que ya tiene): fusiona las filas duplicadas.")
        fvieja = a.fecha_vieja if a.fecha_vieja is not None else (vivas[0][0] if vivas else None)
        svieja = a.sesion_vieja if a.sesion_vieja is not None else (vivas[0][1] if vivas else None)
        # fvieja puede ser "" (fila con la Fecha vacia): se exige que exista, no que tenga texto.
        if (fecha and fvieja is None) or (alias and not svieja):
            sys.exit(f"journal-emit: no encuentro en _session-index.md una fila cuya celda Sesion "
                     f"sea [[sessions/{slug}...]], asi que no se de que valores se parte. Pasa "
                     f"--fecha-vieja/--sesion-vieja con lo que dice hoy la fila")
        base["payload"] = {"slug": slug}
        if fecha:
            base["payload"].update({"date": fecha, "fecha_vieja": fvieja.strip()})
        if alias:
            base["payload"].update({"alias": alias, "sesion_vieja": svieja.strip()})
        write_event(memory_dir, base)
        print(f"s-{slug}")
        return

    if a.type == "learning.add":
        topic = check_slug(a.topic, "--topic")
        text = normalize_text(a.text or "")
        imp = (a.importance or "").strip()
        if imp and not (imp.isdigit() and 0 <= int(imp) <= 10):
            sys.exit("journal-emit: --importance debe ser un entero 0-10")
        avisar_largo("learning.add --quickref", normalize_text(a.quickref), QUICKREF_MAX,
                     "la linea del Quick Reference es un titulo: la regla entera va en --text")
        base["payload"] = {
            "topic": topic,
            "text": text,
            "section": normalize_text(a.section),
            "quickref": normalize_text(a.quickref),
            "title": normalize_text(a.title or ""),
            "when": cell(a.when),
            "importance": imp,
        }
        base["payload"]["id"] = learning_id(topic, text) if text else f"l-topic-{topic}"
        disp = disparadores_arg(a.disparadores, text)
        if disp and not text:
            sys.exit("journal-emit: --disparadores necesita --text (la regla que los lleva)")
        if a.sin_disparadores:
            sys.exit("journal-emit: --sin-disparadores es de learning.update (quita los de una regla "
                     "ya escrita); un learning.add sin --disparadores ya no los lleva")
        if disp:
            # Opcionales (cierre de F4, 2026-10-02): en el banco no llevaron el recall de prompt al
            # criterio, asi que no se exigen ni se avisa si faltan. cmd/path/tool son para la F5.
            base["payload"]["disparadores"] = disp
        sup = numero_regla(a.supersedes, "--supersedes")
        if (a.decision or a.solo_vecinos) and not text:
            sys.exit("journal-emit: --decision y --solo-vecinos necesitan --text (la regla nueva)")
        decision = decision_de(a.decision, a.supersedes, sup, memory_dir, topic)
        if decision and decision.startswith("reemplaza:"):
            sup = int(decision.split(":")[1])     # reemplaza:N es --supersedes N (F2)
        if a.nota is not None and not sup:   # la nota solo va en la marca de la regla reemplazada
            sys.exit("journal-emit: learning.add solo guarda --nota con --supersedes N (o --decision "
                     "reemplaza:N): va en la marca de la regla vieja. Sin eso, metela en el --text")
        if text:
            dedup_al_emitir(memory_dir, topic, text, decision, a.solo_vecinos)
            if a.solo_vecinos:
                return                            # no escribe nada: solo la lista para decidir
            if decision:
                base["payload"]["decision"] = decision
        qprefix = normalize_text(a.quickref_prefix or "")
        if sup:
            if not text:
                sys.exit("journal-emit: --supersedes necesita --text (la regla que reemplaza a la vieja)")
            base["payload"].update({"supersedes": sup, "nota": una_linea(a.nota or ""),
                                    "quickref_prefix": qprefix,
                                    "fecha": date.today().isoformat()})
        elif qprefix:
            sys.exit("journal-emit: en learning.add, --quickref-prefix solo va con --supersedes "
                     "(quita la linea del Quick Reference de la regla reemplazada)")
        write_event(memory_dir, base)
        print(base["payload"]["id"])
        return

    if a.type == "learning.retire":
        topic = check_slug(a.topic, "--topic")
        mprefix = normalize_text(a.match_prefix or "")
        motivo = (a.motivo or "").strip().lower()
        por = numero_regla(a.por, "--por")
        if not mprefix:
            sys.exit("journal-emit: learning.retire necesita --match-prefix (el prefijo del texto "
                     "ACTUAL de la regla) — una regla no tiene id, sin ancla no se sabe cual retirar")
        if motivo not in MOTIVOS_RETIRO:
            sys.exit(f"journal-emit: --motivo debe ser uno de {MOTIVOS_RETIRO}")
        if motivo == "obsoleta" and por:
            sys.exit("journal-emit: --motivo obsoleta no lleva --por (nada la reemplaza); si otra "
                     "regla la reemplaza, el motivo es duplicada o superada")
        if motivo != "obsoleta" and not por:
            sys.exit(f"journal-emit: --motivo {motivo} necesita --por N (la regla viva que la "
                     f"reemplaza, en el mismo topic)")
        base["payload"] = {
            "topic": topic,
            "match_prefix": mprefix,
            "numero": numero_por_prefijo(memory_dir, topic, mprefix),
            "motivo": motivo,
            "por": por,
            "nota": una_linea(a.nota or ""),
            "quickref_prefix": normalize_text(a.quickref_prefix or ""),
            "fecha": date.today().isoformat(),
        }
        write_event(memory_dir, base)
        print(f"l-topic-{topic}")
        return

    if a.type == "learning.patch":
        # Los trozos van LITERALES (sin normalize_text): tienen que casar byte a byte con el fichero.
        mprefix = normalize_text(a.match_prefix or "")
        qprefix = normalize_text(a.quickref_prefix or "")
        if bool(mprefix) == bool(qprefix):
            sys.exit("journal-emit: learning.patch necesita --match-prefix (regla del topic, con "
                     "--topic) o --quickref-prefix (linea del Quick Reference), uno de los dos")
        topic = check_slug(a.topic, "--topic") if (mprefix or a.topic) else ""
        if a.viejo is None or a.nuevo is None or not a.viejo.strip() or not a.nuevo.strip():
            sys.exit("journal-emit: learning.patch necesita --viejo y --nuevo, los dos con texto")
        jc = _compactador()
        for flag, v in (("--viejo", a.viejo), ("--nuevo", a.nuevo)):
            mal = jc.problema_trozo(v, flag)
            if mal:
                sys.exit(f"journal-emit: {mal}")
        if a.nuevo in a.viejo:
            sys.exit("journal-emit: --nuevo esta dentro de --viejo: el compactador no distinguiria el "
                     "replay del primer cambio. Alarga --nuevo con texto vecino (p. ej. --viejo "
                     "'foo (ver #1) bar' --nuevo 'foo bar')")
        # Se comprueba ya contra el fichero de hoy, para que el error salga donde se puede corregir
        # (el compactador repite todo: es su propia frontera de confianza).
        if mprefix:
            path = os.path.join(memory_dir, "learnings", topic + ".md")
            if not os.path.isfile(path):
                sys.exit(f"journal-emit: learnings/{topic}.md no existe")
            lines = jc.read_lines(path)
            start, end = jc.body_region(lines)
            donde = f"learnings/{topic}.md"
        else:
            path = os.path.join(memory_dir, "_learnings.md")
            lines = jc.read_lines(path) if os.path.isfile(path) else []
            sec = jc.section_bounds(lines, "## Quick Reference")
            if not sec:
                sys.exit("journal-emit: no hay '## Quick Reference' en _learnings.md")
            start, end = sec
            donde = "'## Quick Reference'"
        try:
            i, ya = jc.localizar_parche(lines, start, end, mprefix or qprefix, a.viejo, a.nuevo, donde)
            if not ya:
                _n, t = jc.rule_text(lines[i])
                c = jc.cuerpo_regla(t)
                jc.comprobar_primera_linea(lines[i], jc.con_texto(lines[i], c.replace(a.viejo, a.nuevo, 1)
                                                                 + t[len(c):]), donde, retira=False)
        except jc.Quarantine as e:
            sys.exit(f"journal-emit: {e}")
        if ya:
            print("journal-emit: la regla ya tiene el trozo nuevo; no se emite nada", file=sys.stderr)
            print(f"l-topic-{topic}" if topic else "l-quickref")
            return
        base["payload"] = {
            "topic": topic,
            "match_prefix": mprefix,
            "quickref_prefix": qprefix,
            "viejo": a.viejo,
            "nuevo": a.nuevo,
        }
        write_event(memory_dir, base)
        print(f"l-topic-{topic}" if topic else "l-quickref")
        return

    if a.type == "learning.update":
        topic = check_slug(a.topic, "--topic")
        text = normalize_text(a.text or "")
        quickref = normalize_text(a.quickref or "")
        mprefix = normalize_text(a.match_prefix or "")
        qprefix = normalize_text(a.quickref_prefix or "")
        title = normalize_text(a.title or "")
        when = cell(a.when)
        # Un learning no tiene `_id:` en su linea, asi que el unico ancla posible es el texto de
        # hoy. Reescribir sin ancla seria "corrige la regla que sea": se rechaza en la emision,
        # no en el compactador, para que el error salga donde la persona puede corregirlo.
        if text and not mprefix:
            sys.exit("journal-emit: --text necesita --match-prefix (el prefijo del texto ACTUAL "
                     "de la regla) — una regla no tiene id, sin ancla no se sabe cual reescribir")
        if quickref and not qprefix:
            sys.exit("journal-emit: --quickref necesita --quickref-prefix (el prefijo de la regla "
                     "ACTUAL del Quick Reference)")
        disp = disparadores_arg(a.disparadores, text)
        sin_disp = bool(a.sin_disparadores)
        if disp and sin_disp:
            sys.exit("journal-emit: --disparadores y --sin-disparadores a la vez: o se cambian o se "
                     "quitan")
        if (text or disp or sin_disp) and not mprefix:
            sys.exit("journal-emit: --disparadores/--sin-disparadores necesitan --match-prefix (el "
                     "prefijo del texto ACTUAL de la regla que los lleva)")
        if mprefix and not (text or disp or sin_disp):
            sys.exit("journal-emit: --match-prefix sin --text, --disparadores ni --sin-disparadores "
                     "no corrige nada")
        qregla = (a.quickref_regla or "").strip()
        if qregla:
            import learning_marks
            if not learning_marks.valor_regla_qr_valido(qregla):
                sys.exit(f"journal-emit: --quickref-regla {qregla!r} tiene que ser <topic>#<N>, "
                         f"<topic> o ninguna")
            if qregla != "ninguna" and qregla.split("#")[0] != topic:
                sys.exit(f"journal-emit: --quickref-regla {qregla!r} no es del --topic {topic}")
            if not qprefix:
                sys.exit("journal-emit: --quickref-regla necesita --quickref-prefix (el prefijo de "
                         "la linea ACTUAL del Quick Reference)")
        if qprefix and not (quickref or qregla):
            sys.exit("journal-emit: --quickref-prefix sin --quickref ni --quickref-regla no corrige nada")
        last_verified = (a.last_verified or "").strip()
        if last_verified and not (re.fullmatch(r"\d{4}-\d{2}-\d{2}", last_verified)
                                  and fecha_real(last_verified)):
            sys.exit(f"journal-emit: --last-verified {last_verified!r} no es una fecha YYYY-MM-DD")
        if not (text or quickref or qregla or title or when or disp or sin_disp or last_verified):
            sys.exit("journal-emit: learning.update necesita al menos uno de --text, --quickref, "
                     "--quickref-regla, --title, --when, --disparadores, --sin-disparadores o "
                     "--last-verified")
        base["payload"] = {
            "topic": topic,
            "match_prefix": mprefix,
            "text": text,
            "disparadores": disp,
            "quickref_prefix": qprefix,
            "quickref": quickref,
            "quickref_regla": qregla,
            "title": title,
            "when": when,
            "last_verified": last_verified,
        }
        if sin_disp:
            # Solo cuando se pide: un payload sin la clave es el de antes de 2.60.2, y el replay de
            # un update viejo no tiene que cambiar.
            base["payload"]["sin_disparadores"] = True
        write_event(memory_dir, base)
        print(f"l-topic-{topic}")
        return

    if a.type == "plan.upsert":
        slug = check_slug(a.slug, "--slug")
        parent = check_slug(a.parent, "--parent") if a.parent else ""
        if parent == slug:
            sys.exit("journal-emit: --parent no puede ser el propio plan")
        if parent and a.inline:
            sys.exit("journal-emit: --parent y --inline no se pueden combinar en el mismo evento "
                      "-- un plan --inline no lleva wikilink en el indice y el guardian de ciclos "
                      "no lo puede rastrear como eslabon (compact.py lo rechaza igual si ya era "
                      "--inline de un evento anterior)")
        if a.promote and a.inline:
            sys.exit("journal-emit: --promote y --inline no se pueden combinar -- --promote convierte "
                      "la fila (inline) del plan en una fila con su wikilink")
        base["payload"] = {
            "slug": slug,
            "title": cell(need(a.title, "plan.upsert necesita --title")),
            "status": cell(need(a.status, "plan.upsert necesita --status")),
            "date": check_date(a.date, "--date", default=date.today().isoformat()),
            "sesion": cell(a.sesion),
            "pendientes": cell(a.pendientes),
            "learnings": cell(a.learnings),
            "inline": bool(a.inline),
            "promote": bool(a.promote),
            "parent": parent,
        }
        avisar_origen_colgante(a.sesion, memory_dir)   # en plan.upsert el campo se llama --sesion
        write_event(memory_dir, base)
        print(f"pl-{slug}")
        return

    if a.type == "plan.reopen":
        base["payload"] = {
            "slug": check_slug(a.slug, "--slug"),
            "title": cell(a.title or ""),   # solo hace falta para un plan --inline (sin wikilink)
        }
        write_event(memory_dir, base)
        print(f"pl-{base['payload']['slug']}")
        return

    if a.type == "research.upsert":
        slug = check_slug(a.slug, "--slug")
        status = (a.status or "").strip().lower()
        if status not in RESEARCH_STATUS:
            sys.exit(f"journal-emit: --status debe ser uno de {RESEARCH_STATUS}")
        avisar_largo("research.upsert --tema", cell(a.tema or ""), RESEARCH_TEMA_MAX,
                     "el tema es un titulo; el detalle va en memory/research/<slug>.md")
        avisar_largo("research.upsert --next-step", cell(a.next_step), RESEARCH_CAMPO_MAX,
                     "una linea; el detalle va en memory/research/<slug>.md")
        avisar_largo("research.upsert --resultado", cell(a.resultado), RESEARCH_CAMPO_MAX,
                     "una linea; el detalle va en memory/research/<slug>.md")
        base["payload"] = {
            "slug": slug,
            "tema": cell(need(a.tema, "research.upsert necesita --tema")),
            "status": status,
            "date": check_date(a.date, "--date", default=date.today().isoformat()),
            "next_step": cell(a.next_step),
            "resultado": cell(a.resultado),
            "origen": cell(a.origen or ""),
            "inline": bool(a.inline),
        }
        avisar_origen_colgante(a.origen, memory_dir)
        write_event(memory_dir, base)
        print(f"r-{slug}")
        return

    if a.type == "research.rename":
        slug = check_slug(a.slug, "--slug")
        viejo = a.tema_viejo
        if viejo is None:
            viejo = find_research_tema(memory_dir, slug)
        if not viejo:
            sys.exit(f"journal-emit: no encuentro en _research-index.md una fila cuyo Archivo sea "
                     f"[[research/{slug}]], asi que no se de que tema se parte. Pasa "
                     f"--tema-viejo \"<tema actual>\" (ojo: una fila --inline no se renombra; "
                     f"dale fichero al research primero)")
        base["payload"] = {
            "slug": slug,
            "tema": cell(need(a.tema, "research.rename necesita --tema")),
            "tema_viejo": cell(viejo),
        }
        write_event(memory_dir, base)
        print(f"r-{slug}")
        return

    if a.type == "pendiente.update":
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        # El evento no tiene donde guardar una nota: ni la linea viva ni la fila mensual la llevan.
        # Antes se descartaba sin avisar y quien la paso creia haberla dejado escrita (p-a37851219c).
        if a.nota is not None:   # cualquier --nota pasada, aun vacia: quien la paso esperaba guardarla
            sys.exit("journal-emit: pendiente.update no guarda --nota (no hay campo donde ponerla). "
                     "Si la nota describe el pendiente, metela en el --text; si cierra el "
                     "pendiente, va en pendiente.resolve --nota")
        # El texto que llega puede venir pegado de la linea entera (con sus `— _origen:` y su
        # `— _id:`). Esos sufijos los POSEE el compactador: si entraran aqui, la linea acabaria
        # con dos `_id:` y el pendiente dejaria de resolverse por id. Se quitan y se avisa.
        crudo = normalize_text(a.text or "")
        text = strip_meta(crudo) if crudo else ""
        if crudo and text != crudo:
            print("journal-emit: AVISO — se quitaron los metadatos (_origen/_creado/_id/"
                  "_revisar/_actualizado) del --text; esos campos los conserva el compactador "
                  "de la linea viva, no se reescriben desde el evento.", file=sys.stderr)
        if crudo and not text:
            sys.exit("journal-emit: pendiente.update recibio un --text que es SOLO metadatos")
        prio = (a.prioridad or "").strip().capitalize()
        if prio and prio not in PRIORIDADES:
            sys.exit(f"journal-emit: --prioridad debe ser una de {PRIORIDADES}")
        if not text and not prio:
            sys.exit("journal-emit: pendiente.update necesita --text y/o --prioridad")
        prefix = a.text_prefix
        if prefix is None:
            current = find_line_text(memory_dir, pid)
            prefix = current[:40] if current else ""
        base["payload"] = {"id": pid, "text": text, "prioridad": prio,
                           "text_prefix": normalize_text(prefix),
                           "fecha": date.today().isoformat()}
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type == "pendiente.window":
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        rev = (a.revisar or "").strip()
        if not fecha_real(rev):
            sys.exit("journal-emit: pendiente.window necesita --revisar con una fecha real")
        base["payload"] = {"id": pid, "revisar": rev, "fecha": date.today().isoformat()}
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type == "pendiente.retomar":
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        if a.quitar:
            if a.retomar:
                sys.exit("journal-emit: pendiente.retomar --quitar no lleva --retomar")
            ficha = (a.ficha or "").strip()
            if ficha.endswith(".md"):
                ficha = ficha[:-3]
            if not FICHA_RETOMAR_RE.fullmatch(ficha):
                sys.exit("journal-emit: pendiente.retomar --quitar necesita --ficha sessions/<slug>")
            base["payload"] = {"id": pid, "quitar": True, "ficha": ficha,
                               "fecha": date.today().isoformat()}
            write_event(memory_dir, base)
            print(pid)
            return
        ret = (a.retomar or "").strip()
        # fecha_real (fromisoformat) acepta `20261016` y `2026-W42-5` desde Python 3.11 (en 3.9 no):
        # el compactador los cuarentena y el mod no los lee. Aqui solo AAAA-MM-DD, en cualquier version.
        if not (re.fullmatch(r"\d{4}-\d{2}-\d{2}", ret) and fecha_real(ret)):
            sys.exit("journal-emit: pendiente.retomar necesita --retomar AAAA-MM-DD con una fecha real")
        ficha = (a.ficha or "").strip()
        if ficha.endswith(".md"):
            ficha = ficha[:-3]
        if not FICHA_RETOMAR_RE.fullmatch(ficha):
            sys.exit("journal-emit: pendiente.retomar necesita --ficha sessions/<slug>")
        base["payload"] = {"id": pid, "retomar": ret, "ficha": ficha,
                           "fecha": date.today().isoformat()}
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type == "pendiente.block":
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        bloqueado = limpiar_bloqueado(a.bloqueado_por)
        if bool(bloqueado) == bool(a.desbloquear):
            sys.exit("journal-emit: pendiente.block necesita --bloqueado-por \"QUE\" o "
                     "--desbloquear (uno de los dos)")
        rev = (a.revisar or "").strip()
        if rev and not fecha_real(rev):
            sys.exit("journal-emit: --revisar debe ser una fecha real YYYY-MM-DD")
        base["payload"] = {"id": pid, "bloqueado": bloqueado}
        if not bloqueado:
            # 2.63.32: el `_revisar` de un bloqueado es la fecha de mirar si llego la espera; sin
            # espera sobra, y con el puesto el paso "pedirle a X (p-…)" salia rechazado como
            # `_revisar` futuro (adversario, ronda 1). Un --revisar dado queda como ventana nueva.
            # `quita_revisar` distingue este evento de un desbloqueo anterior a 2.63.32, que no
            # tocaba la ventana y se sigue aplicando igual.
            base["payload"]["quita_revisar"] = True
            if rev:
                base["payload"]["revisar"] = rev
        if bloqueado:
            # 2.63.32: el bloqueo trae su ventana. `revisar_defecto` le dice al compactador que
            # conserve un `_revisar` futuro que la linea ya tenga; una fecha dada lo reemplaza.
            base["payload"]["revisar"] = rev or revisar_por_defecto()
            base["payload"]["revisar_defecto"] = not rev
            base["payload"]["fecha"] = date.today().isoformat()
            if not rev:
                print(f"journal-emit: bloqueado sin --revisar: ventana por defecto "
                      f"{base['payload']['revisar']} (hoy+{DIAS_BLOQUEADO}) si la linea no trae "
                      "ya un `_revisar` futuro", file=sys.stderr)
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type == "pendiente.adopt":
        hoy = date.today().isoformat()
        elegidas, vivos = candidatas_adopt(memory_dir, a, hoy)
        if not elegidas:
            sys.exit("journal-emit: pendiente.adopt no encuentra ninguna linea `- [ ]` sin `_id:` "
                     "que case con el selector" + ("" if a.todas else
                     " (si ya tiene `_id: p-…_`, usa ese id directamente)"))
        # Mas de una linea DISTINTA para un selector de una sola: no se elige por el usuario.
        if not a.todas and len({ln.strip() for ln, _p, _c in elegidas}) > 1:
            sys.exit("journal-emit: el selector casa con varias lineas distintas sin id; afina "
                     "--text-prefix o pasa --line con la linea entera:\n  " +
                     "\n  ".join(ln.strip()[:120] for ln, _p, _c in elegidas[:8]))
        sin_creado = [ln for ln, pid, _c in elegidas if pid is None]
        if sin_creado:   # no pasa: creado_para siempre da una fecha. Guarda, no camino.
            sys.exit("journal-emit: no hay fecha de creado para: " + sin_creado[0].strip()[:120])
        # Duplicados = el MISMO id canonico dos veces: dos lineas con el mismo texto, creado y
        # origen, o una linea sin id que repite un pendiente que ya tiene id. Son el mismo
        # pendiente; adoptar las dos dejaria dos lineas vivas con un id, y resolve solo cerraria
        # una. Sin --colapsar se niega; con el, el compactador deja UNA y guarda el resto entero
        # en .journal/adopt-colapsados.log (lo mismo texto distinto con otro creado u origen: da
        # otro id y no es duplicado).
        cuenta = {}
        for _ln, pid, _c in elegidas:
            cuenta[pid] = cuenta.get(pid, 0) + 1
        dup = {pid for pid, n in cuenta.items() if n > 1 or pid in vivos}
        if dup and not a.colapsar:
            for pid in sorted(dup):
                donde = (f"ya vive como {pid}" if pid in vivos
                         else f"{cuenta[pid]} copias identicas")
                ejemplo = next(ln for ln, p_, _c in elegidas if p_ == pid).strip()[:100]
                print(f"journal-emit: DUPLICADO ({donde}): {ejemplo}", file=sys.stderr)
            if not a.todas or len(dup) == len(cuenta):
                sys.exit("journal-emit: pendiente.adopt no adopta duplicados. Es el mismo "
                         "pendiente: repite con --colapsar para dejar una sola linea (las copias "
                         "quedan enteras en .journal/adopt-colapsados.log)")
            elegidas = [e for e in elegidas if e[1] not in dup]
            print(f"journal-emit: --todas sigue sin esos {len(dup)} id(s) duplicados",
                  file=sys.stderr)
        base["payload"] = {
            "lineas": [{"line": ln, "id": pid, "creado_nuevo": c} for ln, pid, c in elegidas],
            "colapsar": bool(a.colapsar),
            "fecha": hoy,
        }
        write_event(memory_dir, base)
        for pid in dict.fromkeys(pid for _ln, pid, _c in elegidas):
            print(pid)
        return

    if a.type == "pendiente.relate":
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        relacionado = limpiar_relacionados(a.relacionado, pid)
        if bool(relacionado) == bool(a.sin_relacion):
            sys.exit("journal-emit: pendiente.relate necesita --relacionado X o --sin-relacion "
                     "(uno de los dos)")
        base["payload"] = {"id": pid, "relacionado": relacionado}
        write_event(memory_dir, base)
        print(pid)
        return

    if a.type in ("pendiente.expire", "pendiente.reopen"):
        pid = (a.id or "").strip()
        if not ID_RE.match(pid):
            sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
        if a.type == "pendiente.expire":
            dias = (a.dias or "").strip()
            if not dias.isdigit():
                sys.exit("journal-emit: pendiente.expire necesita --dias <entero>")
            prio = (a.prioridad or "").strip().capitalize()
            if prio and prio not in PRIORIDADES:
                sys.exit(f"journal-emit: --prioridad debe ser una de {PRIORIDADES}")
            base["payload"] = {"id": pid, "dias": int(dias), "prioridad": prio,
                               "line": (a.line or "").rstrip("\n"),
                               "fecha": date.today().isoformat()}
        else:
            prio = (a.prioridad or "").strip().capitalize()
            if prio and prio not in PRIORIDADES:
                sys.exit(f"journal-emit: --prioridad debe ser una de {PRIORIDADES}")
            base["payload"] = {"id": pid, "prioridad": prio,
                               "fecha": date.today().isoformat()}
        write_event(memory_dir, base)
        print(pid)
        return

    # pendiente.resolve
    pid = (a.id or "").strip()
    if not ID_RE.match(pid):
        sys.exit("journal-emit: --id debe tener la forma p-<10 hex>")
    estado = (a.estado or "").strip().lower()
    if estado not in ESTADOS:
        sys.exit(f"journal-emit: --estado debe ser uno de {ESTADOS}")
    prefix = a.text_prefix
    if prefix is None:
        current = find_line_text(memory_dir, pid)
        prefix = current[:40] if current else ""
    base["payload"] = {"id": pid, "estado": estado, "sesion": normalize_text(a.sesion),
                       "nota": normalize_text(a.nota or ""), "text_prefix": normalize_text(prefix),
                       "fecha": date.today().isoformat()}
    write_event(memory_dir, base)
    print(pid)


if __name__ == "__main__":
    main()
