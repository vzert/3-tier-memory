#!/usr/bin/env python3
"""
3-tier-memory plugin (2.55.0, 2.56.0): pendientes AFINES al `Proximo paso:` de una ficha.

Por que existe: hasta 2.54 el snippet `Como retomar` llevaba un solo item. Un Media que la sesion
dejaba junto a un Alta no volvia a ningun snippet salvo que venciera su `_revisar` (medido sobre
las 8 ultimas fichas de este repo y de otro proyecto: p-f667380493, p-95d33b9363, p-b0b80cfb23 y
p-564b0bdc82 no volvieron nunca). Y un Alta corta no traia nada con que completar la sesion.

Que hace: toma los anclas que cita la linea `Proximo paso:` de `## Como retomar` (ids `p-…` y
slugs `plan-…`) y devuelve hasta 2 pendientes abiertos Alta o Media ligados a ellos por el campo
`_relacionado:` (journal-emit `--relacionado` / `pendiente.relate`), en CUALQUIER direccion:
  - el candidato cita un ancla en su `_relacionado:`, o
  - un pendiente ancla cita al candidato en su `_relacionado:`, o
  - el candidato y un pendiente ancla citan el mismo `plan-…`.
Sin importar de que sesion vengan: el arrastre entre sesiones es justo el punto.

Nunca devuelve uno con `_bloqueado:`, uno con `_revisar` futuro (ya tiene su recordatorio de
calendario), uno que vence hoy (lo muestra la capa 🔔 de print-pendiente-opcional.py), uno cuyo
texto nombra una fecha ISO posterior a hoy (ver `fecha_futura`) ni uno que ya cita el `Proximo
paso:`. Orden: Alta antes que Media; dentro, el `_creado` mas viejo primero (el que mas tiempo
lleva esperando); a igual fecha, la fila mas arriba. Todo lo demas sale de campos estructurados
(regla 216). En particular NO decide si el paso es "corto": eso no esta en ningun campo, asi que
la linea lo deja dicho como condicion para quien retoma ("si ese paso es corto").

La excepcion de la fecha (2.56.0) es un chequeo de FORMATO, no de significado: una fecha
`AAAA-MM-DD` posterior a hoy en el texto. Caso real (otro proyecto, 2026-10-13): la linea sumo
un pendiente Alta, "revision a 24 h desde el 2026-10-14", sin `_revisar`; el agente que retomo no
pudo hacerlo ese dia. El campo `_revisar` sigue siendo la via principal (Step 3b lo exige); esto
es la red para cuando falta.

Lo usa print-como-retomar.py (la linea `Si ese paso es corto, suma…` dentro del snippet).

Uso directo:  pendientes_afines.py SESSION_FILE [--hoy YYYY-MM-DD]   (las lineas del snippet)
              pendientes_afines.py SESSION_FILE --hilo [--hoy …]   (el hilo en orden, Step 8)

2.57.0: la linea de afines sale del HILO entero (ver "El hilo", mas abajo), no solo de
`_relacionado` al paso, y lleva debajo `quedan N en el hilo: <ids>`.
"""
# sella-huellas: no (solo lee _pendientes.md y la ficha; no escribe nada)
import datetime
import os
import re
import sys

for _flujo in (sys.stdout, sys.stderr):
    if hasattr(_flujo, "reconfigure"):
        _flujo.reconfigure(encoding="utf-8")

PRIORIDAD = {"Alta": 0, "Media": 1}
MAX_AFINES = 2
TEXTO_MAX = 90
ID = re.compile(r"_id:\s*(p-[0-9a-f]{10})(?![0-9a-f])")
ID_CUALQUIERA = re.compile(r"(?<![0-9A-Za-z-])p-[0-9a-f]{10}(?![0-9a-f])")
PLAN_CUALQUIERA = re.compile(r"(?<![0-9A-Za-z-])plan-[A-Za-z0-9][A-Za-z0-9._-]*")
REVISAR = re.compile(r"_revisar:\s*(\d{4}-\d{2}-\d{2})_")
CREADO = re.compile(r"_creado:\s*(\d{4}-\d{2}-\d{2})_")
BLOQUEADO = re.compile(r"—\s*_bloqueado:")
ORIGEN = re.compile(r"_origen:\s*\[\[sessions/([^\]|]+)")
RELACIONADO = re.compile(r"—\s*_relacionado:\s*([^—]*?)_?\s*(?=—|$)")
METADATO = re.compile(r"\s+—\s+_[a-z]+:")
# Una fecha ISO suelta: no la de un slug (`2026-10-14-algo`, `backup_2026-10-14_x`) ni parte de
# un numero mayor. La `T` de un timestamp (`2026-10-14T09:00Z`) si cuenta.
FECHA_ISO = re.compile(r"(?<![\w-])(\d{4}-\d{2}-\d{2})(?![\d_])(?![A-SU-Za-z])(?!-[0-9A-Za-z])")
# El final de un rango ("del 2026-10-01 al 2026-10-14") cuyo inicio ya llego: la ventana esta
# abierta hoy, no es una espera.
INICIO_RANGO = re.compile(r"(\d{4}-\d{2}-\d{2})\s*(?:al|a|hasta|–|—|-)\s*$", re.I)
# Un plazo ("antes del 2026-12-01") se puede cumplir hoy: no es una espera.
PLAZO = re.compile(r"(?:antes\s+del?|a\s+m[aá]s\s+tardar(?:\s+el)?|vence(?:\s+el)?|"
                   r"l[ií]mite:?|plazo:?|deadline:?)\s*$", re.I)


def fecha_futura(texto, hoy):
    """La primera fecha `AAAA-MM-DD` de `texto` posterior a `hoy` que no es un plazo, o None.

    Es la red de 2.56.0 para el trabajo que espera una fecha y no trae `_revisar`. La usan la
    linea de afines (excluye el pendiente) y checkpoint-audit.py (`snippet.proximo_paso`). No ve
    fechas escritas de otra forma ("manana", "14-oct", "tras la revision"): esas siguen
    dependiendo de que el pendiente nazca con `--revisar` o `_bloqueado:`."""
    texto = texto or ""
    for m in FECHA_ISO.finditer(texto):
        f = m.group(1)
        antes = texto[max(0, m.start() - 25):m.start()]
        rango = INICIO_RANGO.search(antes)
        if f > hoy and not PLAZO.search(antes) and not (rango and rango.group(1) <= hoy):
            return f
    return None


# El marco del `Proximo paso` (2.60.0, p-88a7cc28c2 + p-3d1c7ab131, research
# hilo-pendientes-relacionados-medicion, Anexo 2). Redes de FORMATO, no juicio: lo que avisan es un
# POR-DISENO que el hook de cierre pone en la revision, nunca un SALTADO (decision de Victor del
# 2026-10-14). La via principal de una espera sigue siendo `_bloqueado:` (regla 216).
# Una espera escrita solo en el texto: el paso depende de que otro decida, responda o actue.
# Medido en 163 snippets con respuesta util (de 211): 27 % de problema contra 8 % de un paso
# limpio. Se busca sin tildes.
# `decidir con el usuario` dejo de ser senal en 2.62.11: es la forma que Step 8 pide para el paso que
# pone delante una decision del usuario, y el aviso le decia al agente que lo bloqueara, que es justo
# como el snippet salio `Ninguno` en claude-vzert (p-341fdf5e59). `decidir con <otro>` sigue siendo
# senal: puede ser un tercero, y el aviso ya dice que una decision del usuario no es espera. Un
# `usuario` con apellido (`usuario externo`, `usuario final`, `usuario-final`, `usuario del
# cliente`) es un tercero y sigue avisando. Un complemento que no nombra a otro (`usuario de la
# tienda`, `del equipo`, `usuario finalmente`) no lo vuelve tercero (p-c501ad10c6): `de/del` solo
# avisa cuando lo sigue cliente, proveedor, tercero u otr(o/a), directamente o tras un articulo
# (`usuario de la otra empresa`, `de los clientes`; p-c0e7c422cb), y `final` solo como palabra entera.
ESPERA_AJENA = re.compile(
    r"\bsi\s+(?:\S+\s+){1,2}(?:lo\s+|la\s+)?(?:decide|aprueba|autoriza|confirma|acepta|quiere|da el ok)\b"
    r"|\bdecidir\s+con\s+(?!(?:el\s+)?usuario\b(?!\s*-|\s+(?:extern|final\b|ajen|client|del?\s+(?:(?:la|el|los|las)\s+)?(?:client|proveedor|tercer|otr))))\S+"
    r"|\b(?:pedir(?:le)?|solicitar)\s+(?:el\s+|su\s+)?(?:permiso|autorizacion|aprobacion|ok|visto bueno)\b"
    r"|\b(?:cuando|en cuanto|una vez que|hasta que|despues de que)\s+(?:\S+\s+){1,3}?"
    r"(?:responda|conteste|apruebe|decida|autorice|confirme|actualice|publique)\b"
    r"|\besperar\s+(?:a\s+|la\s+|el\s+|que\s+|su\s+)?(?:respuesta|decision|aprobacion|confirmacion|"
    r"autorizacion|visto bueno|ok)\b"
    r"|\brevisar\s+si\s+(?:\S+\s+){1,3}?(?:respondio|contesto|actuo|actualizo|aprobo|decidio)\b",
    re.I)
# Una lista "(1)… (2)…" o "(a)… (b)…" dentro del paso: varias tareas o comprobaciones previas.
ITEM_LISTA = re.compile(r"\((?:[1-9]|[a-e])\)")
# "ver tambien p-…" es una referencia, no un segundo objetivo (asi se conto en el Anexo 2).
VER_TAMBIEN = re.compile(r"\bver\s+tambi[eé]n\b.*", re.I | re.S)
ID_P = re.compile(r"\bp-[0-9a-f]{10}\b")
LARGO_AVISO = 600


def _sin_tildes(s):
    import unicodedata
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")


def senales_marco(paso):
    """Las senales del marco que trae el texto de un `Proximo paso` (sin su etiqueta), en orden.

    Cada una es una cadena para el aviso. Vacia = el paso no trae ninguna. Es formato: un paso que
    espera a alguien con otras palabras no sale, y uno que nombra una espera ya resuelta si."""
    paso = (paso or "").strip()
    out = []
    m = ESPERA_AJENA.search(_sin_tildes(paso))
    if m:
        out.append(f"espera una decision o accion de fuera de la sesion (\"{m.group(0).strip()}\"): "
                   "si es asi, el pendiente lleva `_bloqueado:` y no va en el paso; una decision "
                   "del usuario no es espera: escribe el paso como `decidir con el usuario <que>`")
    ids = sorted(set(ID_P.findall(VER_TAMBIEN.sub("", paso))))
    if len(ids) >= 2:
        out.append(f"junta {len(ids)} pendientes ({', '.join(ids)}): un paso es un objetivo; el "
                   "resto del hilo va en la linea de extras")
    if len(set(ITEM_LISTA.findall(paso))) >= 2:
        out.append("trae una lista (1)… (2)…: varias tareas o comprobaciones previas; las "
                   "comprobaciones van a `## Estado` de la ficha")
    if len(paso) > LARGO_AVISO:
        out.append(f"mide {len(paso)} caracteres (guia: unos 300): el porque y el estado van a la "
                   "ficha, no al paso")
    return out


def proximo_paso(ficha_texto):
    """La linea `Proximo paso:` de `## Como retomar`, o None."""
    m = re.search(r"^## Como retomar[^\n]*\n(.*?)(?=^## |\Z)", ficha_texto, re.M | re.S)
    if not m:
        return None
    for l in m.group(1).splitlines():
        s = l.strip().strip("*").strip().lower()
        if s.startswith(("proximo paso:", "próximo paso:")):
            return l
    return None


def lecturas_plan(cita):
    """Todas las lecturas de una cita `plan-…` sacada de prosa o de una celda, la mas larga primero.

    Un slug valido puede terminar en `.`, `-` o `_` (journal-emit lo acepta), y una cita puede
    llevar `.md` y despues el punto de la frase. Ningun regex sabe donde acaba el slug, asi que se
    generan TODAS las lecturas que salen de aplicar, en cualquier orden y hasta agotarlas, dos
    recortes: quitar un signo final y quitar un `.md` final. `plan-a-.md.` da `plan-a-.md.`,
    `plan-a-.md`, `plan-a-` y `plan-a`. La usan esta linea de afines y
    plan-siguiente-hermano.py: una sola definicion (2.55.0; dos copias distintas de esta logica
    dieron tres rondas de adversario seguidas)."""
    vistas, cola = [], [cita]
    while cola:
        v = cola.pop(0)
        if v in vistas or len(v) <= len("plan-") or not v.startswith("plan-"):
            continue
        vistas.append(v)
        if v[-1] in "._-":
            cola.append(v[:-1])
        if v.endswith(".md"):
            cola.append(v[:-3])
    return sorted(vistas, key=len, reverse=True)


def canonica(cita):
    """La lectura mas corta de `lecturas_plan` (sin signos ni `.md` finales), o None."""
    lect = lecturas_plan(cita)
    return lect[-1] if lect else None


def anclas(linea):
    """(ids, planes) que cita la linea. Un `plan-x.md` cuenta como `plan-x`.

    Un slug valido puede terminar en `-`, `.` o `_` (journal-emit lo acepta), y en prosa un `.`
    final suele ser el punto de la frase: se toman las DOS lecturas. Un ancla de mas solo casa
    con un pendiente que cite exactamente ese valor, asi que sobra sin dano."""
    if not linea:
        return set(), set()
    planes = set()
    for p in PLAN_CUALQUIERA.findall(linea):
        planes.update(lecturas_plan(p))
    return set(ID_CUALQUIERA.findall(linea)), planes


def pendientes(path):
    """[{id, texto, prio, creado, revisar, bloqueado, rel, origen, fila}] de las lineas `- [ ]`."""
    out, prio = [], None
    with open(path, encoding="utf-8") as fh:
        for n, l in enumerate(fh):
            s = l.strip()
            m_h = re.match(r"^##\s+(alta|media|baja)\b", s, re.I)
            if m_h:
                prio = m_h.group(1).capitalize()
                continue
            if s.startswith("## "):
                prio = None
                continue
            if not s.startswith("- [ ]"):
                continue
            m_id = ID.search(s)
            if not m_id:
                continue
            m_rel = RELACIONADO.search(s)
            rel = {x.strip() for x in m_rel.group(1).split(",") if x.strip()} if m_rel else set()
            rev, cre, ori = REVISAR.search(s), CREADO.search(s), ORIGEN.search(s)
            out.append({"id": m_id.group(1), "texto": METADATO.split(s[5:].strip(), 1)[0].strip(),
                        "prio": prio, "creado": cre.group(1) if cre else "9999-99-99",
                        "revisar": rev.group(1) if rev else None,
                        "bloqueado": bool(BLOQUEADO.search(s)), "rel": rel,
                        "origen": ori.group(1).strip() if ori else None, "fila": n})
    return out


# --- El hilo (2.57.0, p-b282a8cfc4) -----------------------------------------------------------
# Decidido por Victor el 2026-10-13 sobre la medicion de research/hilo-pendientes-relacionados-
# medicion: la linea de afines de 2.55.0 dependia solo de `_relacionado`, y ese campo estaba en 3 de
# 617 pendientes. Lo que se perdia no era el paso: era el paso recibido que no se cerraba (se caia
# del snippet siguiente y no volvia, 8 casos), los hermanos que se separaban (61 de 119 sesiones) y
# las Bajas (57-73 % nunca volvian). Las cinco piezas:
#   (1) liga al nacer: journal-emit `pendiente.add` liga cada pendiente nuevo a los ids del
#       `Proximo paso` que la sesion recibio (`paso_recibido_de`), sin criterio del agente;
#   (2) hilo = lo que la sesion recibio + lo que nacio en ella + el paso que escribe, mas sus
#       vecinos directos por `_relacionado` en las dos direcciones (los `plan-…`, un solo salto: un
#       plan con 30 pendientes volveria el hilo el backlog entero). Hasta 2.61.0 era el cierre
#       transitivo; desde 2.62.0 es un salto, y solo por ids abiertos (ver hilo());
#   (3) orden: prioridad; en empate el nuevo antes que el heredado, salvo el heredado que lleva 2
#       sesiones seguidas saltado (`hilo_saltos` del sello), que va antes que todos;
#   (4) el paso recibido que no se cerro sigue en el hilo (es un heredado mas);
#   (5) hasta 2 extras (Alta > Media > Baja; la Baja solo cuando no queda Alta ni Media) y una linea
#       `quedan N en el hilo: <ids>` con el resto.
# Lo que la sesion recibio NO se lee aqui de la transcripcion: se lee del sello que stamp-hilo.py
# deja en el frontmatter de la ficha (`hilo_paso`, `hilo_heredados`, `hilo_saltos`). El hook de
# cierre vuelve a correr print-como-retomar.py en otro entorno; si esto leyera la transcripcion, su
# salida podria no ser la del Step 8b.

PRIORIDAD_HILO = {"Alta": 0, "Media": 1, "Baja": 2}
EXTRAS_PREFIJO = "Si ese paso es corto, suma"
QUEDAN = re.compile(r"^quedan\s+\d+\s+en\s+el\s+hilo\b", re.I)
# Las etiquetas del snippet de Step 8a. Un campo va desde su etiqueta hasta la siguiente o hasta
# una linea en blanco: los snippets viejos parten el `Proximo paso` en varias lineas (medido: 4 de
# los 10 pasos "mas cortos" eran cortes si se leia solo la primera).
ETIQUETA = re.compile(r"^\s*\**\s*(retomamos:|lee\s|pr[oó]ximo paso:|pr[oó]xima acci[oó]n:|"
                      r"no repitas:|terminas cuando:|antes de actuar|si ese paso es corto|"
                      r"quedan\s+\d+\s+en\s+el\s+hilo)", re.I)
LEE_FICHA = re.compile(r"memory/sessions/([^\s`)\]]+?)\.md")


def campo(snippet, inicio):
    """El texto del campo cuya etiqueta empieza por `inicio` (minusculas), o None."""
    lineas = (snippet or "").splitlines()
    for i, l in enumerate(lineas):
        s = l.strip().strip("*").strip().lower()
        if not s.startswith(inicio):
            continue
        out = [l.strip()]
        for sig in lineas[i + 1:]:
            if not sig.strip() or ETIQUETA.match(sig):
                break
            out.append(sig.strip())
        return " ".join(out)
    return None


def recibido(snippet):
    """Lo que trae un snippet `Retomamos:`: {paso, heredados, retoma}.

    paso      = ids `p-…` y `plan-…` (canonicos) del `Proximo paso` (o `Proxima accion`);
    heredados = ids `p-…` del paso, de la linea de extras y de la linea `quedan N en el hilo`;
    retoma    = el slug de la ficha que el snippet manda leer (la sesion que lo escribio); lo usa
                stamp-hilo.py para leer los `hilo_saltos` de esa ficha."""
    paso = campo(snippet, "proximo paso:") or campo(snippet, "próximo paso:") \
        or campo(snippet, "proxima accion:") or campo(snippet, "próxima acción:")
    if paso is None:
        # El prompt de un recordatorio de calendario (Step 8c) no trae `Proximo paso:`: su id va en
        # `Retomamos: … _id: p-…_`. Sin esto la sesion quedaba sin sello y su hilo solo tenia lo que
        # nacia en ella (caso real de otro proyecto, 2026-10-15). Solo esa
        # linea: las de abajo (`Contexto:`, `Comprueba: … Despues: <otro id>`) no son etiquetas del
        # snippet y `campo` las juntaria.
        paso = next((l for l in (snippet or "").splitlines()
                     if l.strip().strip("*").strip().lower().startswith("retomamos:")), None)
    ids_paso, planes = anclas(paso)
    planes_c = sorted({canonica(x) for x in planes if canonica(x)})
    heredados = set(ids_paso)
    for inicio in ("si ese paso es corto", "quedan"):
        heredados |= anclas(campo(snippet, inicio))[0]
    m = LEE_FICHA.search(snippet or "")
    return {"paso": sorted(ids_paso) + planes_c, "heredados": sorted(heredados),
            "retoma": m.group(1) if m else None}


def frontmatter(texto):
    """{clave: valor} del frontmatter `---` de una ficha ({} si no tiene)."""
    if not (texto or "").startswith("---"):
        return {}
    fin = texto.find("\n---", 3)
    if fin == -1:
        return {}
    out = {}
    for l in texto[3:fin].splitlines():
        if ":" in l and not l.startswith((" ", "\t")):
            k, v = l.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def lista(valor):
    return [x.strip() for x in (valor or "").split(",") if x.strip()]


def saltos(valor):
    """`p-a=1, p-b=2` → {p-a: 1, p-b: 2}."""
    out = {}
    for x in lista(valor):
        k, _, n = x.partition("=")
        if n.strip().isdigit():
            out[k.strip()] = int(n)
    return out


def sello(ficha_texto):
    """El sello de stamp-hilo.py: (paso, heredados, saltos). Vacio si la ficha no lo tiene."""
    fm = frontmatter(ficha_texto)
    return lista(fm.get("hilo_paso")), lista(fm.get("hilo_heredados")), saltos(fm.get("hilo_saltos"))


def hacible(p, hoy):
    """Se puede hacer en la sesion siguiente: sin `_bloqueado`, sin `_revisar` de hoy o futuro
    (tiene su recordatorio) y sin una fecha `AAAA-MM-DD` futura en el texto."""
    if p["prio"] not in PRIORIDAD_HILO or p["bloqueado"]:
        return False
    if p["revisar"] and p["revisar"] >= hoy:
        return False
    return not fecha_futura(p["texto"], hoy)


def hilo(ficha_texto, pend_path, slug=None, hoy=None):
    """Los pendientes hacibles del hilo de la ficha, en el orden de la regla (3). [] sin datos."""
    hoy = hoy or datetime.date.today().isoformat()
    if not os.path.isfile(pend_path):
        return []
    todos = pendientes(pend_path)
    paso_rec, heredados, salt = sello(ficha_texto)
    ids_pp, planes_pp = anclas(proximo_paso(ficha_texto))
    nuevos = {p["id"] for p in todos if slug and p["origen"] == slug}
    miembros = set(heredados) | nuevos | ids_pp | {x for x in paso_rec if x.startswith("p-")}
    por_id = {p["id"]: p for p in todos}
    nucleo = set(miembros)  # antes de los planes: lo que entra por un plan no abre otro salto
    # Los planes: los del paso que la ficha escribe, los del paso recibido y los que citan las
    # semillas. Un solo salto: no se expande por los planes de los que entran despues.
    planes = set(planes_pp) | {x for x in paso_rec if x.startswith("plan-")}
    for i in miembros:
        if i in por_id:
            planes |= {x for x in por_id[i]["rel"] if x.startswith("plan-")}
    planes = {canonica(x) or x for x in planes}
    for p in todos:
        if {canonica(x) or x for x in p["rel"] if x.startswith("plan-")} & planes:
            miembros.add(p["id"])
    # Un solo salto de `_relacionado` desde las semillas, y solo por ids ABIERTOS (2.62.0, regla de
    # Victor del 2026-10-15; reemplaza el "a cualquier distancia" de 2.57.0). El cierre transitivo
    # cruzaba de un tema a otro: en un proyecto real una sesion de indices llego en 7 saltos, uno
    # por un pendiente ya cerrado, a la sombrilla de un trabajo que llevaba otro agente, y la propuso
    # como `Proximo paso` (y el audit `snippet.hilo` la exigia). Un id cerrado o que ya no esta en
    # `_pendientes.md` no liga nada: su trabajo termino, y lo que lo cita es de quien lo cite.
    semillas = {i for i in nucleo if i in por_id}
    for p in todos:
        ids_rel = {x for x in p["rel"] if x.startswith("p-") and x in por_id}
        if p["id"] in semillas:
            miembros |= ids_rel
        elif ids_rel & semillas:
            miembros.add(p["id"])

    def grupo(p):
        if p["id"] not in nuevos and salt.get(p["id"], 0) >= 2:
            return 0
        return 1 if p["id"] in nuevos else 2

    out = [p for p in todos if p["id"] in miembros and hacible(p, hoy)]
    for p in out:
        # 0 = heredado saltado 2+ sesiones, 1 = nuevo, 2 = heredado (lo lee checkpoint-audit.py)
        p["grupo"] = grupo(p)
    out.sort(key=lambda p: (PRIORIDAD_HILO[p["prio"]], p["grupo"], p["creado"], p["fila"]))
    return out


PASTED = re.compile(r"</?pasted_content[^>]*>")
RUIDO = re.compile(r"<(system-reminder|local-command-caveat|command-name|command-message|"
                   r"command-args|local-command-stdout)>.*?</\1>", re.S)


def _texto_usuario(contenido):
    if isinstance(contenido, str):
        return contenido
    if isinstance(contenido, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in contenido):
            return ""
        return "\n".join(b.get("text", "") for b in contenido
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def snippet_de_transcripcion(ruta):
    """El snippet `Retomamos:` con el que arranco una sesion, o None.

    Es el PRIMER mensaje de usuario con texto (sin los avisos del harness, sin `isMeta`, sin
    resultados de herramientas). Si ese no empieza por `Retomamos:`, la sesion no retomo nada: no
    se busca un `Retomamos:` mas abajo (seria un snippet pegado para otra cosa). El envoltorio
    `<pasted_content …>` se quita: asi llega un snippet pegado como bloque."""
    import json
    try:
        fh = open(ruta, encoding="utf-8", errors="replace")
    except OSError:
        return None
    with fh:
        for linea in fh:
            try:
                d = json.loads(linea)
            except ValueError:
                continue
            # Una linea que no es un objeto, o con `message` que no lo es, se salta como una que no
            # parsea (p-3f22a1cba1: tumbaba stamp-hilo.py con AttributeError).
            if not isinstance(d, dict) or not isinstance(d.get("message"), dict):
                continue
            if d.get("type") != "user" or d.get("isMeta"):
                continue
            texto = RUIDO.sub("", _texto_usuario(d["message"].get("content")))
            texto = PASTED.sub("", texto).strip()
            if not texto:
                continue
            return texto if texto.startswith("Retomamos:") else None
    return None


def transcripcion_de(session_id, dirs_proyecto=(), projects_root=None):
    """La ruta del `.jsonl` de `session_id`, o None. Mira primero el directorio de cada proyecto
    (codificado como Claude Code: todo lo que no es alfanumerico pasa a `-`) y luego
    `<projects_root>/*/<id>.jsonl` si es unico (un id en dos proyectos no identifica nada)."""
    import glob
    if not session_id or not re.match(r"^[0-9A-Za-z-]{8,64}$", session_id):
        return None
    root = projects_root or os.path.join(os.path.expanduser("~"), ".claude", "projects")
    for d in dirs_proyecto:
        if d:
            r = os.path.join(root, re.sub(r"[^A-Za-z0-9]", "-", d), session_id + ".jsonl")
            if os.path.isfile(r):
                return r
    hits = glob.glob(os.path.join(glob.escape(root), "*", glob.escape(session_id) + ".jsonl"))
    return hits[0] if len(hits) == 1 else None


ESCRIBE = ("Write", "Edit", "MultiEdit")


def escribio_la_ficha(transcripcion, nombre):
    """Si la transcripcion tiene una herramienta que ESCRIBIO `sessions/<nombre>`: Write, Edit o
    MultiEdit con ese `file_path`, o un Bash que redirige (`>`, `>>`, `tee`) a esa ruta. Leerla no
    cuenta: la sesion que retoma lee la ficha anterior, y esa es justo la ajena."""
    import json
    # `sessions/` tiene que ser un componente entero de la ruta: `not-sessions/<nombre>` no es la
    # ficha (adversario externo, ronda 3 de 2.57.0).
    redir = re.compile(r"(?:>{1,2}|\btee\s+(?:-a\s+)?)\s*['\"]?(?:[^\s'\"]*/)?sessions/"
                       + re.escape(nombre) + r"(?![\w.-])")
    try:
        fh = open(transcripcion, encoding="utf-8", errors="replace")
    except OSError:
        return False
    with fh:
        for linea in fh:
            if nombre not in linea:
                continue
            try:
                d = json.loads(linea)
            except ValueError:
                continue
            if not (isinstance(d, dict) and isinstance(d.get("message"), dict)):
                continue
            if d.get("type") != "assistant":
                continue
            for b in d["message"].get("content") or []:
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                inp = b.get("input") or {}
                if not isinstance(inp, dict):
                    continue
                ruta = str(inp.get("file_path") or "").replace("\\", "/")
                if b.get("name") in ESCRIBE and (ruta == "sessions/" + nombre
                                                 or ruta.endswith("/sessions/" + nombre)):
                    return True
                # Las barras invertidas de una ruta de Windows valen como `/`, igual que en `file_path`
                # (p-3f22a1cba1).
                if b.get("name") == "Bash" and redir.search(
                        str(inp.get("command") or "").replace("\\", "/")):
                    return True
    return False


def ficha_de_la_sesion(ficha_path, transcripcion, session_id):
    """Si la ficha es de la sesion de esa transcripcion: no esta sellada con OTRO `session_id`, su
    fecha (la del nombre) cae dentro de las fechas de la transcripcion, con un dia de margen (los
    `timestamp` son UTC), y la transcripcion la ESCRIBIO (`escribio_la_ficha`; sin esto, una ficha
    del mismo dia de otra sesion pasaba: adversario externo, ronda 2 de 2.57.0). Falla cerrado.

    Existe para que un `pendiente.add` con `--origen` de OTRA sesion (`/backfill-3t` reconstruye
    pendientes de fichas viejas, una prueba crea fichas de mentira) no herede el snippet de la
    sesion de Claude Code donde corre."""
    if not (ficha_path and transcripcion and os.path.isfile(ficha_path)):
        return False
    with open(ficha_path, encoding="utf-8", errors="replace") as fh:
        sello_sid = frontmatter(fh.read()).get("session_id")
    if sello_sid and sello_sid != session_id:
        return False
    m = re.match(r"(\d{4}-\d{2}-\d{2})", os.path.basename(ficha_path))
    if not m:
        return False
    import json
    fechas = []
    try:
        with open(transcripcion, encoding="utf-8", errors="replace") as fh:
            for linea in fh:
                try:
                    ts = str(json.loads(linea).get("timestamp") or "")
                except (ValueError, AttributeError):
                    continue
                if re.match(r"\d{4}-\d{2}-\d{2}", ts):
                    fechas.append(ts[:10])
    except OSError:
        return False
    if not fechas:
        return False
    try:
        f = datetime.date.fromisoformat(m.group(1))
        a = datetime.date.fromisoformat(min(fechas)) - datetime.timedelta(days=1)
        b = datetime.date.fromisoformat(max(fechas)) + datetime.timedelta(days=1)
    except ValueError:
        return False
    return a <= f <= b and escribio_la_ficha(transcripcion, os.path.basename(ficha_path))


def paso_recibido_de(ficha_path=None, transcripcion=None):
    """Los ids del `Proximo paso` que la sesion recibio (pieza 1). Primero el sello de la ficha
    (`hilo_paso`, si stamp-hilo.py ya corrio); si no, la transcripcion. [] si nada."""
    if ficha_path and os.path.isfile(ficha_path):
        with open(ficha_path, encoding="utf-8", errors="replace") as fh:
            fm = frontmatter(fh.read())
        if "hilo_paso" in fm:
            return lista(fm["hilo_paso"])
    snip = snippet_de_transcripcion(transcripcion) if transcripcion else None
    return recibido(snip)["paso"] if snip else []


# --- Que puede ser extra (2.61.0) ---------------------------------------------------------------
# Medido sobre 22 sesiones que recibieron la linea de extras (35 extras, 2026-10-13..15, medicion
# local del autor, no publicada): los 7 que se cerraron eran tareas de codigo o de doc; los 11 que
# esperaban un OK, una decision, una prueba en vivo o una sesion real no cerraron ninguno y dieron 5
# de las 7 fricciones (el usuario pregunta que es, o el agente los reporta como "no avanzaron"). Y en
# 3 snippets la linea sugeria un id que el `Terminas cuando` del MISMO snippet mandaba a otra sesion.
# Decidido por Victor el 2026-10-15: esos salen de la linea de extras y van a `quedan N`. No salen
# del hilo: `checkpoint-audit.py` (`snippet.hilo`) sigue viendo el mismo orden. Sobre esa muestra el
# filtro, con el texto que cada pendiente tenia en la fecha de su sesion, saca 9 de 35: 3 de las 7
# fricciones y 1 de los 7 cerrados (uno que el `No repitas` de su snippet mandaba a otro PR); las
# otras 4 fricciones este filtro no las ve.
#
# Una prueba que solo puede pasar en uso real: en vivo, en una supervision o un cierre real, en una
# sesion nueva, tras reiniciar o recargar plugins. Se busca sin tildes.
# El verbo va pegado (hasta 3 palabras) a "en vivo"/"en … real": con mas holgura casaba texto que
# cuenta algo ya hecho ("sin verificar saldo (…) — verificado en vivo"). Calibrado contra los 1423
# pendientes abiertos de 7 proyectos el 2026-10-15 (deja fuera 52).
EN_VIVO = re.compile(
    r"\b(?:confirmar|verificar|probar|comprobar|medir|validar)\s+(?:\S+\s+){0,3}?"
    r"(?:en\s+vivo|en\s+uso\s+real|en\s+(?:una?|el|la)\s+(?:\S+\s+){0,2}?real\b|"
    r"en\s+una\s+sesion\s+(?:\S+\s+)?nueva)"
    r"|\btras\s+(?:reiniciar|recargar|/reload-plugins)\b"
    r"|\ben\s+(?:el|la)\s+(?:proxim[oa]|siguiente)\s+(?:\S+\s+){1,2}?real\b",
    re.I)
# Espera un OK o una decision de otro. Tiene que nombrar el OK o a quien decide: `ESPERA_AJENA` (del
# marco del paso) sobre el texto de un pendiente casaba "si se quiere", "decidir con datos" o "si
# GitHub lo acepta", trabajo que el agente si puede hacer. "OK de Victor para el <fecha>" ya dado
# no cuenta: la fecha la cubre `fecha_futura`.
ESPERA_OK = re.compile(
    r"\b(?:falta|faltan|espera|esperan|esperar|requiere|necesita|pendiente\s+de)\s+"
    r"(?:el\s+|su\s+|un\s+|una\s+|la\s+)?(?:ok|visto\s+bueno|aprobacion|autorizacion|decision)\b"
    r"|\b(?:si|cuando|hasta\s+que|una\s+vez\s+que)\s+(?:victor|el\s+usuario|user)\s+(?:lo\s+|la\s+)?"
    r"(?:decide|decida|aprueba|apruebe|autoriza|autorice|quiere|confirma|confirme)\b"
    r"|\b(?:cuando|hasta\s+que)\s+se\s+(?:decida|apruebe|autorice|publique)\b"
    r"|\bdecidir\s+con\s+(?:victor|el\s+usuario)\b"
    r"|\ba\s+la\s+espera\s+de\s+(?:la\s+|el\s+|su\s+)?(?:ok|aprobacion|autorizacion|decision|respuesta|visto\s+bueno)\b"
    r"|\bdepende\s+de\s+que\s+(?:victor|el\s+usuario|user)\s+(?:lo\s+|la\s+)?"
    r"(?:decida|apruebe|autorice|responda|confirme)\b"
    r"|\b(?:pedir(?:le)?|solicitar)\s+(?:el\s+|su\s+)?(?:ok|permiso|autorizacion|aprobacion|visto\s+bueno)\b"
    # "decision de Victor" a secas casi siempre cita una ya tomada ("por decision de Victor del …").
    r"|\bdecision\s+(?:de\s+)?victor\s+pendiente\b|\bpide\s+(?:la\s+|una\s+)?decision\b",
    re.I)


def bloque_retomar(ficha_texto):
    """El texto de `## Como retomar` (fence incluido), o ''."""
    m = re.search(r"^## Como retomar[^\n]*\n(.*?)(?=^## |\Z)", ficha_texto or "", re.M | re.S)
    return m.group(1) if m else ""


def citados_fuera_del_paso(ficha_texto):
    """Los ids `p-…` que el snippet de la ficha cita en `Terminas cuando` o `No repitas`. El agente
    que cierra ya les dio un papel ("va aparte", "va en la siguiente supervision"): sugerirlos como
    extra contradice al mismo snippet."""
    bloque = bloque_retomar(ficha_texto)
    ids = set()
    for inicio in ("terminas cuando:", "no repitas:"):
        ids |= anclas(campo(bloque, inicio))[0]
    return ids


def motivo_no_extra(p, citados=frozenset()):
    """Por que un pendiente del hilo no va en la linea de extras, o None si puede ir."""
    if p["id"] in citados:
        return "citado en Terminas cuando o No repitas"
    t = _sin_tildes(p["texto"])
    if EN_VIVO.search(t):
        return "prueba en uso real"
    if ESPERA_OK.search(t):
        return "espera un OK o una decision"
    return None


def extras_y_quedan(ficha_texto, pend_path, slug=None, hoy=None):
    """(extras, quedan): hasta MAX_AFINES del hilo fuera del paso que se pueden sumar en la misma
    sesion (`motivo_no_extra`), y el resto, en el orden del hilo."""
    ids_pp = anclas(proximo_paso(ficha_texto))[0]
    resto = [p for p in hilo(ficha_texto, pend_path, slug, hoy) if p["id"] not in ids_pp]
    citados = citados_fuera_del_paso(ficha_texto)
    elegibles = [p for p in resto if not motivo_no_extra(p, citados)]
    altas_medias = [p for p in elegibles if p["prio"] in PRIORIDAD]
    extras = (altas_medias or elegibles)[:MAX_AFINES]
    vistos = {p["id"] for p in extras}
    return extras, [p for p in resto if p["id"] not in vistos]


def afines(ficha_texto, pend_path, hoy=None, slug=None):
    """Los extras del hilo (la linea `Si ese paso es corto…`). Se queda el nombre de 2.55.0."""
    return extras_y_quedan(ficha_texto, pend_path, slug, hoy)[0]


def corto(texto):
    t = " ".join(texto.split())
    return t if len(t) <= TEXTO_MAX else t[:TEXTO_MAX - 1].rstrip() + "…"


def linea_snippet(ficha_texto, pend_path, hoy=None, slug=None):
    """Las lineas que print-como-retomar.py mete en el snippet (extras y `quedan N en el hilo`),
    separadas por una linea en blanco, o None si el hilo no tiene nada fuera del paso."""
    extras, quedan = extras_y_quedan(ficha_texto, pend_path, slug, hoy)
    lineas = []
    if extras:
        partes = [f"{p['id']} ({p['prio']}) — {corto(p['texto'])}" for p in extras]
        lineas.append(EXTRAS_PREFIJO + " en la misma sesion: " + "; ".join(partes) + ".")
    if quedan:
        lineas.append(f"quedan {len(quedan)} en el hilo: " + ", ".join(p["id"] for p in quedan) + ".")
    return "\n\n".join(lineas) or None


def main():
    args = sys.argv[1:]
    hoy = None
    if "--hoy" in args:
        i = args.index("--hoy")
        hoy = args[i + 1]
        del args[i:i + 2]
    ver_hilo = "--hilo" in args
    args = [a for a in args if a != "--hilo"]
    if len(args) != 1:
        print("uso: pendientes_afines.py SESSION_FILE [--hilo] [--hoy YYYY-MM-DD]", file=sys.stderr)
        return 2
    ficha = os.path.abspath(args[0])
    memory_dir = os.path.dirname(os.path.dirname(ficha))
    with open(ficha, encoding="utf-8") as fh:
        texto = fh.read()
    slug = os.path.splitext(os.path.basename(ficha))[0]
    pend = os.path.join(memory_dir, "_pendientes.md")
    if ver_hilo:
        # Step 8, casos 2-3: el primero es el `Proximo paso`.
        # Desde 2.61.0 dice tambien cual no ira en la linea de extras y por que: el agente que
        # escribe el snippet ve antes de cerrar que un id de su `Terminas cuando` sale a `quedan N`.
        etiqueta = {0: "heredado, saltado 2+ sesiones", 1: "nuevo", 2: "heredado"}
        citados = citados_fuera_del_paso(texto)
        for p in hilo(texto, pend, slug, hoy):
            motivo = motivo_no_extra(p, citados)
            fuera = f" [no va de extra: {motivo}]" if motivo else ""
            print(f"{p['id']} ({p['prio']}, {etiqueta[p['grupo']]}){fuera} — {corto(p['texto'])}")
        return 0
    l = linea_snippet(texto, pend, hoy, slug)
    if l:
        print(l)
    return 0


if __name__ == "__main__":
    sys.exit(main())
